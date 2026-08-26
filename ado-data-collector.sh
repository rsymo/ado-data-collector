#!/bin/bash

# ========================================
# Azure DevOps Data Collector
# ========================================
# This script collects data from Azure DevOps organizations
# for GitHub migration planning.
#
# READ-ONLY GUARANTEE
#   This collector never writes to Azure DevOps. It only reads.
#   Enforced (see "READ-ONLY ENFORCEMENT" below), not merely intended:
#     - Every HTTP request is pinned to GET, except one allow-listed read-only
#       query endpoint (WIQL) that Azure DevOps only exposes over POST.
#     - Every URL is checked against an allow-list of Azure DevOps read hosts
#       and must be HTTPS; redirects cannot downgrade the scheme.
#     - Git repositories are cloned bare (a fetch) and inspected locally; the
#       clone is configured with an unusable push URL.
#     - Azure CLI is used only for `az account show` and
#       `az account get-access-token`.
#     - Any violation aborts the run immediately.
#   All output is written to the local working directory.
#
# Prerequisites:
#   - Azure CLI installed and logged in (az login)
#   - jq installed for JSON parsing
#
# Usage:
#   az login
#   ./ado-data-collector.sh

# Note: set -e is NOT used to allow graceful error handling

# -------- CONFIGURATION --------
# Set DEBUG=1 to see detailed API calls, DEBUG=0 for cleaner output
DEBUG=${DEBUG:-0}
# Set SCAN_LARGE_FILES=1 to clone repos and scan for large files (slower but accurate)
SCAN_LARGE_FILES=${SCAN_LARGE_FILES:-0}
# Set SKIP_BUILD_HISTORY=1 to skip build history collection (faster, but no runner sizing data)
SKIP_BUILD_HISTORY=${SKIP_BUILD_HISTORY:-0}
# Number of days of build history to analyse for runner sizing
HISTORY_DAYS=${HISTORY_DAYS:-90}
# Maximum builds to retrieve per project (guards against very large orgs)
MAX_BUILDS_PER_PROJECT=${MAX_BUILDS_PER_PROJECT:-20000}
# Seconds before the Azure AD token is proactively refreshed. Defaulted here
# (not just at the refresh helper) so it can be validated with the other
# numeric settings below.
TOKEN_MAX_AGE=${TOKEN_MAX_AGE:-2400}
# Azure DevOps organization name
ORG="${ORG:-}"
if [ -z "$ORG" ]; then
    echo "ERROR: ORG environment variable is not set"
    echo "Please set it to your Azure DevOps organization name:"
    echo "  export ORG=your-org-name"
    echo "  ./ado-data-collector.sh"
    echo ""
    echo "Or set it inline:"
    echo "  ORG=your-org-name ./ado-data-collector.sh"
    exit 1
fi
ORG_URL="https://dev.azure.com/$ORG"

# Validate numeric configuration up front. Unlike an API failure - which must
# degrade to zero so a partial report is still produced - a malformed setting is
# a caller error that would otherwise yield a confident-looking report built on
# a nonsense window (e.g. HISTORY_DAYS=abc silently becoming a 0-day window).
# Fail fast so the mistake is corrected before anyone relies on the numbers.
for _cfg in HISTORY_DAYS MAX_BUILDS_PER_PROJECT TOKEN_MAX_AGE; do
    eval "_val=\${$_cfg}"
    case "$_val" in
        ''|*[!0-9]*)
            echo "ERROR: $_cfg must be a positive integer (got: '$_val')" >&2
            exit 1
            ;;
    esac
    if [ "$_val" -lt 1 ]; then
        echo "ERROR: $_cfg must be at least 1 (got: '$_val')" >&2
        exit 1
    fi
done
unset _cfg _val

# Shared timestamp so all artefacts from one run share a suffix
RUN_STAMP="$(date +%Y%m%d-%H%M%S)-${RANDOM}"
# Report output file with microsecond precision and random component for uniqueness
REPORT_FILE="ado-data-report-${RUN_STAMP}.txt"
# Machine-readable sizing export consumed by cost models
SIZING_JSON="ado-sizing-${RUN_STAMP}.json"
# User export (written to the working directory, not the temp dir, so it survives cleanup)
USER_CSV="ado-users-${RUN_STAMP}.csv"
# Secret scanning details report (separate file for detailed security findings)
SECRET_SCANNING_REPORT="ado-secret-scanning-${RUN_STAMP}.txt"
SECRET_SCANNING_CSV="ado-secret-scanning-${RUN_STAMP}.csv"
SECRET_SCANNING_JSON="ado-secret-scanning-${RUN_STAMP}.json"
# Use PID to create unique temp directory to avoid conflicts with concurrent runs
TEMP_DATA_DIR="temp_migration_data_$$"
mkdir -p "$TEMP_DATA_DIR"

# Collects data-completeness warnings (truncated pagination, page limits) so the
# summary can tell the reader whether the figures are complete.
WARNINGS_FILE="$TEMP_DATA_DIR/warnings.txt"
: > "$WARNINGS_FILE"

# Marker written by fatal_read_only_violation before it signals the main shell.
# It lets the signal handler distinguish "the operator pressed Ctrl-C" from
# "the read-only policy was breached" and report the correct cause.
READ_ONLY_VIOLATION_FLAG="$TEMP_DATA_DIR/.read-only-violation"

# Set up cleanup trap to remove temp directory and secure files on exit (success or failure)
# This ensures bearer tokens in curl config are always cleaned up
cleanup() {
    rm -rf "$TEMP_DATA_DIR"
    # Explicitly remove curl config if it exists outside temp dir
    [ -n "$CURL_CONFIG_FILE" ] && rm -f "$CURL_CONFIG_FILE" 2>/dev/null
}

# Signal handling must terminate the run, not merely tidy up. A handler that
# only cleans up leaves Bash to resume the next statement, so the script would
# carry on against deleted temp files - which is both how a Ctrl-C used to be
# ignored and how a read-only violation could otherwise fail to stop the run.
on_terminating_signal() {
    local violation=0
    [ -f "$READ_ONLY_VIOLATION_FLAG" ] && violation=1
    cleanup
    if [ "$violation" -eq 1 ]; then
        echo "Run aborted: read-only policy violation. Nothing was written to Azure DevOps." >&2
        exit 3
    fi
    echo "" >&2
    echo "Interrupted - cleaning up and exiting." >&2
    exit 130
}

trap cleanup EXIT
trap on_terminating_signal INT TERM

# API version
API_VERSION="7.1"

# -------- AUTHENTICATION --------
# Get Azure AD Bearer token using Azure CLI
# Azure DevOps resource ID: 499b84ac-1321-427f-aa17-267ca6975798

echo "Authenticating with Azure AD..."

if ! command -v az &> /dev/null; then
    echo "ERROR: Azure CLI is not installed"
    echo "Please install Azure CLI: https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo "ERROR: Not logged in to Azure CLI"
    echo "Please run: az login"
    exit 1
fi

# Get Bearer token for Azure DevOps
ADO_TOKEN=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)

if [ -z "$ADO_TOKEN" ]; then
    echo "ERROR: Failed to get Azure AD token for Azure DevOps"
    echo "Please ensure you have access to Azure DevOps organization: $ORG"
    exit 1
fi

echo "Authentication successful!"
echo ""

# -------- READ-ONLY ENFORCEMENT --------
# This collector is strictly READ-ONLY against Azure DevOps. It exists to size a
# migration, never to modify the source estate. The checks below turn that from a
# convention into an enforced invariant, so a future edit cannot quietly
# introduce a mutating call.
#
# The rules, in order of strength:
#   1. Every HTTP request is pinned to GET, except a single allow-listed
#      read-only query endpoint (WIQL) that Azure DevOps only exposes over POST.
#   2. Every URL must be HTTPS and must target a known Azure DevOps read host.
#   3. Redirects may not downgrade to plain HTTP, and may not replay a request
#      body to a new target.
#   4. Any violation aborts the entire run rather than degrading silently.
#
# PID of the top-level shell. API helpers run inside $(...) command
# substitution, where a bare `exit` would only kill the subshell and let the
# run continue. Signalling this PID terminates the real script and fires the
# cleanup trap that removes the bearer token.
MAIN_PID=$$

# Hosts this collector is permitted to contact. Adding a host here is a
# deliberate act: keep it to Azure DevOps endpoints that are read from.
ADO_ALLOWED_HOSTS="
dev.azure.com
vsrm.dev.azure.com
vsaex.dev.azure.com
advsec.dev.azure.com
extmgmt.dev.azure.com
"

# Endpoints that are semantically reads but that Azure DevOps only serves over
# POST. WIQL runs a work-item query and returns matching IDs; it creates and
# changes nothing. Matching is on the URL path only, so query strings cannot be
# used to smuggle a different endpoint past the check.
ADO_ALLOWED_POST_PATHS="
/_apis/wit/wiql
"

# Abort the whole run. Used only for read-only violations, which are programming
# errors rather than environmental ones, so degrading to a partial report would
# be the wrong outcome - the operator must see it.
fatal_read_only_violation() {
    echo "" >&2
    echo "FATAL: read-only policy violation - aborting." >&2
    echo "  $*" >&2
    echo "" >&2
    echo "  This collector must never write to Azure DevOps. If you are adding a" >&2
    echo "  new call, confirm the endpoint is a read, then extend" >&2
    echo "  ADO_ALLOWED_HOSTS or ADO_ALLOWED_POST_PATHS explicitly." >&2
    # Record the cause before signalling, so the handler in the main shell can
    # tell this apart from an operator interrupt.
    : > "$READ_ONLY_VIOLATION_FLAG" 2>/dev/null
    kill -s TERM "$MAIN_PID" 2>/dev/null
    exit 3
}

# Extract the host from a URL without spawning a subprocess.
url_host() {
    local rest="${1#*://}"
    rest="${rest%%/*}"
    rest="${rest%%\?*}"
    echo "${rest%%:*}"
}

# Extract the path from a URL, discarding any query string.
url_path() {
    local rest="${1#*://}"
    case "$rest" in
        */*) rest="/${rest#*/}" ;;
        *)   rest="/" ;;
    esac
    echo "${rest%%\?*}"
}

# Guard applied to every outbound request: HTTPS only, known host only.
assert_read_only_url() {
    local url="$1"
    local host

    case "$url" in
        https://*) ;;
        *) fatal_read_only_violation "Non-HTTPS request blocked: $url" ;;
    esac

    host=$(url_host "$url")
    case "
$ADO_ALLOWED_HOSTS" in
        *"
$host
"*) ;;
        *) fatal_read_only_violation "Host '$host' is not on the read-only allow-list: $url" ;;
    esac
}

# Additional guard for the POST path: the endpoint must be one of the
# allow-listed read-only query endpoints. Matching is an exact suffix match on
# the URL path, which has already had its query string stripped - so neither a
# query parameter nor a longer endpoint name (e.g. .../wiqlSomethingElse) can
# be used to slip past the check.
assert_read_only_query_url() {
    local url="$1"
    local path allowed

    assert_read_only_url "$url"

    path=$(url_path "$url")
    while IFS= read -r allowed; do
        [ -z "$allowed" ] && continue
        case "$path" in
            *"$allowed") return 0 ;;
        esac
    done <<EOF
$ADO_ALLOWED_POST_PATHS
EOF

    fatal_read_only_violation "POST to '$path' is not an allow-listed read-only query endpoint: $url"
}

# Flags applied to every curl invocation. --proto and --proto-redir stop a
# redirect from downgrading to cleartext or to a non-HTTP scheme, which would
# otherwise expose the bearer token.
CURL_SAFE_OPTS=(--proto '=https' --proto-redir '=https')

# -------- HELPER FUNCTIONS --------

# Create a secure curl config file with authentication header
# This prevents token exposure in process listings
# Use mktemp for secure, unpredictable filename to prevent race conditions
CURL_CONFIG_FILE=$(mktemp "$TEMP_DATA_DIR/curl_config.XXXXXX")
chmod 600 "$CURL_CONFIG_FILE"  # Ensure restrictive permissions from the start

create_curl_config() {
    # Write headers to config file (already has 600 permissions from mktemp)
    cat > "$CURL_CONFIG_FILE" << EOF
header = "Authorization: Bearer $ADO_TOKEN"
header = "Accept: application/json"
EOF
}

# Initialize curl config on first call
create_curl_config

# Function to refresh Azure AD token for long-running operations
# Tokens typically expire after 1 hour, so refresh before long operations
refresh_token() {
    [ "$DEBUG" = "1" ] && echo "[DEBUG] Refreshing Azure AD token..." >&2
    local new_token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)
    if [ -n "$new_token" ]; then
        ADO_TOKEN="$new_token"
        # Recreate curl config with new token
        create_curl_config
        TOKEN_ISSUED_AT=$(date +%s)
        [ "$DEBUG" = "1" ] && echo "[DEBUG] Token refreshed successfully" >&2
    else
        [ "$DEBUG" = "1" ] && echo "[DEBUG] WARNING: Failed to refresh token, continuing with existing token" >&2
    fi
}

# Refresh the token only when it is old enough to be worth replacing.
# Called at the start of every section so long runs never fail mid-collection
# on an expired token (Azure AD tokens last ~60 minutes).
TOKEN_ISSUED_AT=$(date +%s)
TOKEN_MAX_AGE=${TOKEN_MAX_AGE:-2400}

maybe_refresh_token() {
    local now age
    now=$(date +%s)
    age=$((now - TOKEN_ISSUED_AT))
    if [ "$age" -ge "$TOKEN_MAX_AGE" ]; then
        refresh_token
    fi
}

# Function to make Azure DevOps API calls (GET requests)
# Uses secure curl config file to avoid token exposure in process listings.
# The method is pinned to GET with -X so that accidentally adding a body flag
# (-d/--data) later cannot silently promote this to a POST.
call_api() {
    local endpoint="$1"
    assert_read_only_url "$endpoint"
    [ "$DEBUG" = "1" ] && echo "[DEBUG] GET: $endpoint" >&2
    curl -s -f -L --max-time 30 --retry 2 --retry-delay 1 \
        "${CURL_SAFE_OPTS[@]}" \
        --config "$CURL_CONFIG_FILE" \
        -X GET \
        "$endpoint" 2>/dev/null || echo "API_ERROR"
}

# Function to run a read-only Azure DevOps query that the API only exposes over
# POST (currently WIQL, which returns matching work item IDs and mutates
# nothing). The endpoint is checked against an allow-list before the request is
# made, so this helper cannot be repurposed into a write.
#
# Redirects are deliberately NOT followed here: a 307/308 would replay the
# request body against a different target, which is exactly the accidental
# write this policy exists to prevent.
call_api_readonly_query() {
    local endpoint="$1"
    local data="$2"
    assert_read_only_query_url "$endpoint"
    [ "$DEBUG" = "1" ] && echo "[DEBUG] POST (read-only query): $endpoint" >&2
    curl -s -f --max-time 30 --retry 2 --retry-delay 1 \
        "${CURL_SAFE_OPTS[@]}" \
        --config "$CURL_CONFIG_FILE" \
        -H "Content-Type: application/json" \
        -X POST -d "$data" "$endpoint" 2>/dev/null || echo "API_ERROR"
}

# Function to safely extract a numeric value from JSON.
# Returns 0 if the API call fails (input is "API_ERROR"), JSON is invalid, or the path doesn't exist.
safe_jq_count() {
    local json="$1"
    local path="$2"
    if [ "$json" = "API_ERROR" ] || ! echo "$json" | jq empty 2>/dev/null; then
        echo "0"
    else
        echo "$json" | jq -r "$path // 0" 2>/dev/null || echo "0"
    fi
}

# Function to URL encode strings (for project names with special characters)
# This version properly handles UTF-8 and all special characters
url_encode() {
    local string="$1"
    local length="${#string}"
    local encoded=""
    local pos c o
    
    for (( pos=0; pos<length; pos++ )); do
        c="${string:pos:1}"
        case "$c" in
            [-_.~a-zA-Z0-9]) 
                # Keep safe characters as-is
                encoded+="$c" 
                ;;
            *)
                # Convert to hex using printf - works with UTF-8
                printf -v o '%%%02X' "'$c"
                encoded+="$o"
                ;;
        esac
    done
    echo "$encoded"
}

# Function to write section header to report
write_section() {
    local title="$1"
    echo "" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
    echo "$title" | tee -a "$REPORT_FILE"
    echo "========================================" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
}

# Normalise a value to a plain non-negative integer. Guards the JSON export:
# `jq -n --argjson` aborts the ENTIRE document if any value is not valid JSON,
# so a stray empty string, a "0\n0" from `grep -c`, or a non-numeric override
# would silently cost the user the whole sizing file.
num() {
    local v
    v=$(printf '%s' "${1:-0}" | tr -d '[:space:]')
    case "$v" in
        ''|*[!0-9]*) echo "0" ;;
        *) echo "$v" ;;
    esac
}

# Record a warning. Deliberately avoids stdout: the pagination helpers stream
# NDJSON on stdout, so anything written there would corrupt the data. Warnings
# go to stderr and are appended to the report so a truncated collection is
# visible in the artefact that gets shared, not just in the console.
report_warn() {
    echo "[WARN] $*" >&2
    if [ -n "$REPORT_FILE" ]; then
        echo "[WARN] $*" >> "$REPORT_FILE" 2>/dev/null
    fi
    if [ -n "$WARNINGS_FILE" ]; then
        echo "$*" >> "$WARNINGS_FILE" 2>/dev/null
    fi
}

# -------- PAGINATION HELPERS --------
# Azure DevOps caps most list endpoints at 100-1000 items per response. Without
# following the continuation token the collector silently returns a truncated
# count with no error, which understates licensing and pipeline numbers on any
# real enterprise estate. These helpers always drain the full result set.
#
# Both helpers emit newline-delimited JSON objects on stdout so callers can
# accumulate them with `jq -s` or append straight to a file.

# Continuation-token pagination (build definitions, builds, release definitions).
# Usage: call_api_paged <url> [jq_array_path] [max_pages]
call_api_paged() {
    local endpoint="$1"
    local jq_path="${2:-.value}"
    local max_pages="${3:-500}"
    local continuation=""
    local prev_continuation=""
    local page=0
    local sep="?"
    case "$endpoint" in *\?*) sep="&" ;; esac

    local hdr_file
    hdr_file=$(mktemp "$TEMP_DATA_DIR/hdr.XXXXXX") || return 0
    chmod 600 "$hdr_file" 2>/dev/null

    while [ "$page" -lt "$max_pages" ]; do
        local url="$endpoint"
        if [ -n "$continuation" ]; then
            url="${endpoint}${sep}continuationToken=$(url_encode "$continuation")"
        fi

        [ "$DEBUG" = "1" ] && echo "[DEBUG] GET (paged $page): $url" >&2

        : > "$hdr_file"
        local body
        assert_read_only_url "$url"
        body=$(curl -s -f -L --max-time 60 --retry 2 --retry-delay 1 \
            "${CURL_SAFE_OPTS[@]}" \
            --config "$CURL_CONFIG_FILE" -D "$hdr_file" -X GET "$url" 2>/dev/null) || body="API_ERROR"

        # A failure here is invisible to the caller: it just receives fewer
        # records, or none. Both cases must be recorded, because a permission
        # boundary and a genuine zero are indistinguishable downstream - and
        # reporting "0 service connections to migrate" when the account simply
        # could not read them is the most expensive mistake this tool can make.
        if [ "$body" = "API_ERROR" ] || ! echo "$body" | jq empty 2>/dev/null; then
            if [ "$page" -gt 0 ]; then
                report_warn "Pagination failed on page $page for ${endpoint%%\?*} - results are TRUNCATED"
            else
                report_warn "No data read from ${endpoint%%\?*} - the request failed (auth, permission, or endpoint unavailable). This section reads as ZERO; confirm it is genuinely zero before sizing from it."
            fi
            break
        fi

        echo "$body" | jq -c "${jq_path}[]?" 2>/dev/null

        # Continuation token may arrive as a response header or in the body
        prev_continuation="$continuation"
        continuation=$(grep -i '^x-ms-continuationtoken:' "$hdr_file" 2>/dev/null \
            | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r\n')
        if [ -z "$continuation" ]; then
            continuation=$(echo "$body" | jq -r '.continuationToken // empty' 2>/dev/null)
        fi

        [ -z "$continuation" ] && break

        # Some endpoints echo a static continuation token even on the last page.
        # Without this guard that becomes an infinite re-fetch of the same page,
        # duplicating every record until the page limit is reached.
        if [ "$continuation" = "$prev_continuation" ]; then
            [ "$DEBUG" = "1" ] && echo "[DEBUG] continuation token did not advance - stopping" >&2
            break
        fi

        page=$((page + 1))
    done

    if [ "$page" -ge "$max_pages" ]; then
        report_warn "Hit page limit ($max_pages) for ${endpoint%%\?*} - results may be truncated"
    fi

    rm -f "$hdr_file"
}

# Skip-based pagination ($top/$skip) used by the vsaex user entitlement API.
# Usage: call_api_paged_skip <url> [jq_array_path] [page_size] [max_pages]
call_api_paged_skip() {
    local endpoint="$1"
    local jq_path="${2:-.items}"
    local page_size="${3:-100}"
    local max_pages="${4:-500}"
    local skip=0
    local page=0
    local sep="?"
    case "$endpoint" in *\?*) sep="&" ;; esac

    while [ "$page" -lt "$max_pages" ]; do
        local url="${endpoint}${sep}%24top=${page_size}&%24skip=${skip}"
        local body
        body=$(call_api "$url")

        if [ "$body" = "API_ERROR" ] || ! echo "$body" | jq empty 2>/dev/null; then
            break
        fi

        local n
        n=$(echo "$body" | jq -r "${jq_path} | length" 2>/dev/null || echo "0")
        [ -z "$n" ] && n=0
        [ "$n" -eq 0 ] && break

        echo "$body" | jq -c "${jq_path}[]?" 2>/dev/null

        # A short page means we've reached the end
        [ "$n" -lt "$page_size" ] && break
        skip=$((skip + page_size))
        page=$((page + 1))
    done
}

# Collapse newline-delimited JSON into a JSON array file.
# Guarantees a valid `[]` even when the source produced nothing.
ndjson_to_array() {
    local src="$1"
    local dest="$2"
    if [ -s "$src" ]; then
        jq -s '.' "$src" > "$dest" 2>/dev/null || echo "[]" > "$dest"
    else
        echo "[]" > "$dest"
    fi
}

# -------- DATE HELPERS --------
# Date arithmetic is done in jq rather than date(1) because BSD date (macOS)
# and GNU date (Linux) take incompatible flags for relative dates.
iso_days_ago() {
    local days="$1"
    jq -rn --argjson d "$days" '(now - ($d * 86400)) | todate' 2>/dev/null
}

# -------- START REPORT --------
echo "Generating Azure DevOps Data Collection Report..." | tee "$REPORT_FILE"
echo "Organization: $ORG" | tee -a "$REPORT_FILE"
echo "Generated: $(date)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# Validate authentication and organization access early
echo "Validating organization access..." | tee -a "$REPORT_FILE"
validation_test=$(call_api "$ORG_URL/_apis/projects?%24top=1&api-version=$API_VERSION")
if [ "$validation_test" = "API_ERROR" ]; then
    echo "ERROR: Failed to access Azure DevOps organization" | tee -a "$REPORT_FILE"
    echo "Please verify:" | tee -a "$REPORT_FILE"
    echo "  1. Organization name is correct: $ORG" | tee -a "$REPORT_FILE"
    echo "  2. You are logged in with 'az login'" | tee -a "$REPORT_FILE"
    echo "  3. Your account has access to this organization" | tee -a "$REPORT_FILE"
    exit 1
fi
echo "Organization access confirmed!" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

# ========================================
# 1. REPOSITORY COUNT
# ========================================
write_section "1. Repository Count"

echo "Collecting repository data..." | tee -a "$REPORT_FILE"

# Get all projects (paginated - large orgs exceed the default page size)
PROJECTS_FILE="$TEMP_DATA_DIR/projects.json"
call_api_paged "$ORG_URL/_apis/projects?api-version=$API_VERSION" '.value' > "$TEMP_DATA_DIR/projects.ndjson"
ndjson_to_array "$TEMP_DATA_DIR/projects.ndjson" "$PROJECTS_FILE"

# Validate we retrieved something usable
if [ "$(jq 'length' "$PROJECTS_FILE" 2>/dev/null || echo 0)" -eq 0 ]; then
    # Fall back to a single unpaginated call to distinguish "empty org" from "API broken"
    projects_response=$(call_api "$ORG_URL/_apis/projects?api-version=$API_VERSION")
    if [ "$projects_response" = "API_ERROR" ] || ! echo "$projects_response" | jq empty 2>/dev/null; then
        echo "ERROR: Failed to retrieve projects from Azure DevOps API" | tee -a "$REPORT_FILE"
        exit 1
    fi
fi

# Use while-read loop to handle project names with spaces/special characters (Bash 3.2 compatible)
# Filter out null and empty values
projects=()
while IFS= read -r project; do
    [ -n "$project" ] && projects+=("$project")
done < <(jq -r '.[].name | select(. != null and . != "")' "$PROJECTS_FILE")

# Check if we actually have any projects
if [ ${#projects[@]} -eq 0 ] || [ -z "${projects[0]:-}" ]; then
    echo "WARNING: No projects found in organization" | tee -a "$REPORT_FILE"
    echo "Total Projects: 0" | tee -a "$REPORT_FILE"
    echo "Total Repositories: 0" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Nothing to migrate - exiting" | tee -a "$REPORT_FILE"
    exit 0
fi

total_repos=0
project_count=0

# Create temporary file for repo details
REPO_DETAILS_FILE="$TEMP_DATA_DIR/repo_details.json"
echo "[]" > "$REPO_DETAILS_FILE"

for project in "${projects[@]}"; do
    # Skip empty project names (shouldn't happen after filtering, but safety check)
    [ -z "$project" ] && continue
    
    project_count=$((project_count + 1))
    
    # URL encode project name to handle special characters
    project_encoded=$(url_encode "$project")
    
    # Get project details to determine visibility
    project_details=$(call_api "$ORG_URL/_apis/projects/$project_encoded?api-version=$API_VERSION")
    project_visibility="private"  # default to private
    if [ "$project_details" != "API_ERROR" ] && echo "$project_details" | jq empty 2>/dev/null; then
        project_visibility=$(echo "$project_details" | jq -r '.visibility // "private"')
    fi
    
    # Get repos for this project
    repos_json=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories?api-version=$API_VERSION")
    
    # Validate JSON response before processing
    if [ "$repos_json" = "API_ERROR" ] || ! echo "$repos_json" | jq empty 2>/dev/null; then
        echo "WARNING: Failed to retrieve repositories for project '$project' (skipping)" | tee -a "$REPORT_FILE"
        continue
    fi
    
    repo_count=$(echo "$repos_json" | jq -r '.value | length')
    total_repos=$((total_repos + repo_count))
    
    # Store repo details for later analysis, including project visibility
    # Use jq --arg to safely pass project name and visibility (handles quotes and backslashes)
    echo "$repos_json" | jq -c --arg proj "$project" --arg vis "$project_visibility" '.value[] | {project: $proj, projectVisibility: $vis, name: .name, id: .id, size: .size, defaultBranch: .defaultBranch, remoteUrl: .remoteUrl}' >> "$REPO_DETAILS_FILE.tmp"
done

# Consolidate all repo details into a single JSON array
if [ -f "$REPO_DETAILS_FILE.tmp" ] && [ -s "$REPO_DETAILS_FILE.tmp" ]; then
    # File exists and has content
    jq -s '.' "$REPO_DETAILS_FILE.tmp" > "$REPO_DETAILS_FILE"
    rm "$REPO_DETAILS_FILE.tmp"
else
    # No repos found in any project, keep empty array
    echo "[]" > "$REPO_DETAILS_FILE"
    [ -f "$REPO_DETAILS_FILE.tmp" ] && rm "$REPO_DETAILS_FILE.tmp"
fi

echo "Total Projects: $project_count" | tee -a "$REPORT_FILE"
echo "Total Repositories: $total_repos" | tee -a "$REPORT_FILE"

# ========================================
# 2. PUBLIC REPOSITORIES
# ========================================
write_section "2. Public Repositories"

echo "Checking for public repositories..." | tee -a "$REPORT_FILE"

if [ -f "$REPO_DETAILS_FILE" ]; then
    # Count public repositories
    public_repo_count=$(jq -r '[.[] | select(.projectVisibility == "public")] | length' "$REPO_DETAILS_FILE")
    
    if [ "$public_repo_count" -gt 0 ]; then
        echo "Found $public_repo_count public repositories:" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        
        # List all public repositories with their details
        jq -r '.[] | select(.projectVisibility == "public") | "  Project: \(.project)\n  Repository: \(.name)\n  URL: \(.remoteUrl)\n"' "$REPO_DETAILS_FILE" | tee -a "$REPORT_FILE"
        
        echo "⚠️  WARNING: These repositories are currently PUBLIC and accessible to anyone." | tee -a "$REPORT_FILE"
        echo "   Consider reviewing their visibility settings before migration." | tee -a "$REPORT_FILE"
    else
        echo "No public repositories found. All repositories are private." | tee -a "$REPORT_FILE"
    fi
else
    echo "No repository data available to analyze." | tee -a "$REPORT_FILE"
fi

# ========================================
# 3. REPOSITORIES OVER 1GB (API-REPORTED SIZE)
# ========================================
write_section "3. Repositories Over 1GB (API-Reported Size)"

echo "Analyzing repository sizes from Azure DevOps API..." | tee -a "$REPORT_FILE"

large_repos=0
ONE_GB_KB=1048576  # 1GB in kilobytes (Azure DevOps API returns size in KB)

if [ -f "$REPO_DETAILS_FILE" ]; then
    large_repos_json=$(jq "[.[] | select(.size != null and (.size | tonumber) > $ONE_GB_KB)]" "$REPO_DETAILS_FILE")
    large_repos=$(echo "$large_repos_json" | jq 'length')
    
    echo "Repositories over 1GB: $large_repos" | tee -a "$REPORT_FILE"
    
    if [ "$large_repos" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Large Repository Details:" | tee -a "$REPORT_FILE"
        echo "$large_repos_json" | jq -r '.[] | "\(.project)/\(.name): \((.size/1024/1024*100|floor)/100)GB"' | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not analyze repository sizes - no data available" | tee -a "$REPORT_FILE"
fi

# ========================================
# 4. LARGEST REPOSITORY (API-REPORTED SIZE)
# ========================================
write_section "4. Largest Repository (API-Reported Size)"

if [ -f "$REPO_DETAILS_FILE" ]; then
    # Check if any repos have size data
    has_size=$(jq 'any(.size != null)' "$REPO_DETAILS_FILE")
    if [ "$has_size" = "true" ]; then
        # Size is in KB, so divide by 1024 to get MB
        largest_repo=$(jq -r 'max_by(.size // 0) | "\(.project)/\(.name): \((.size/1024*100|floor)/100)MB"' "$REPO_DETAILS_FILE")
        echo "Largest Repository: $largest_repo" | tee -a "$REPORT_FILE"
    else
        echo "No repository size data available" | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not determine largest repository" | tee -a "$REPORT_FILE"
fi

# ========================================
# 5. OLDEST REPOSITORY
# ========================================
write_section "5. Oldest Repository"

echo "Finding oldest repository (by first commit date)..." | tee -a "$REPORT_FILE"

oldest_date=""
oldest_repo=""
oldest_commit=""

# Clear any existing oldest_commits.txt file
rm -f "$TEMP_DATA_DIR/oldest_commits.txt"

if [ -f "$REPO_DETAILS_FILE" ]; then
    # Check if file has valid content (more than just [])
    repo_count_check=$(jq 'length' "$REPO_DETAILS_FILE" 2>/dev/null || echo "0")
    if [ "$repo_count_check" -gt 0 ]; then
        # Use process substitution instead of pipe to avoid subshell issues
        while read -r repo; do
            project=$(echo "$repo" | jq -r '.project')
            repo_name=$(echo "$repo" | jq -r '.name')
            repo_id=$(echo "$repo" | jq -r '.id')
        
        echo "Checking commits for $project/$repo_name..." | tee -a "$REPORT_FILE"
        
        # URL encode project name
        project_encoded=$(url_encode "$project")
        
        # Get oldest commit (order by date ascending, take first)
        # Add error handling to prevent script from exiting on API failures
        # URL encode $ as %24 to prevent curl errors
        commit_data=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories/$repo_id/commits?%24top=1&%24orderby=committer/date%20asc&api-version=$API_VERSION")
        
        # Validate JSON before processing
        if [ "$commit_data" = "API_ERROR" ] || ! echo "$commit_data" | jq empty 2>/dev/null; then
            echo "  WARNING: Invalid API response for $project/$repo_name (skipping)" | tee -a "$REPORT_FILE"
            continue
        fi
        
        commit_count=$(echo "$commit_data" | jq -r '.count // 0' 2>/dev/null || echo "0")
        
        if [ "$commit_count" -gt 0 ]; then
            commit_date=$(echo "$commit_data" | jq -r '.value[0].committer.date' 2>/dev/null || echo "")
            commit_id=$(echo "$commit_data" | jq -r '.value[0].commitId' 2>/dev/null || echo "")
            
            if [ -n "$commit_date" ] && [ "$commit_date" != "null" ]; then
                # Use tab as delimiter to avoid conflicts with special characters in names
                printf '%s\t%s\t%s\n' "$commit_date" "$project/$repo_name" "$commit_id" >> "$TEMP_DATA_DIR/oldest_commits.txt"
            else
                echo "  No valid commit date found for $project/$repo_name" | tee -a "$REPORT_FILE"
            fi
        else
            echo "  No commits found in $project/$repo_name" | tee -a "$REPORT_FILE"
        fi
    done < <(jq -c '.[]' "$REPO_DETAILS_FILE")
    
    if [ -f "$TEMP_DATA_DIR/oldest_commits.txt" ] && [ -s "$TEMP_DATA_DIR/oldest_commits.txt" ]; then
        # Sort by first field (date) explicitly using tab as separator
        oldest_line=$(LC_ALL=C sort -t$'\t' -k1,1 "$TEMP_DATA_DIR/oldest_commits.txt" | head -n 1)
        oldest_date=$(echo "$oldest_line" | cut -f1)
        oldest_repo=$(echo "$oldest_line" | cut -f2)
        oldest_commit=$(echo "$oldest_line" | cut -f3)
        
        echo "Oldest Repository: $oldest_repo" | tee -a "$REPORT_FILE"
        echo "First Commit Date: $oldest_date" | tee -a "$REPORT_FILE"
        echo "Commit ID: $oldest_commit" | tee -a "$REPORT_FILE"
    else
        echo "No commit history found" | tee -a "$REPORT_FILE"
    fi
    else
        echo "No repositories with valid data found" | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: Could not determine oldest repository" | tee -a "$REPORT_FILE"
fi

# ========================================
# 6. LARGE FILES SCAN (INDIVIDUAL FILE SIZES)
# ========================================
write_section "6. Large Files Scan (Individual File Sizes)"

# Check if Git is available and user opted in for scanning
if [ "$SCAN_LARGE_FILES" = "1" ] && command -v git &> /dev/null; then
    # Refresh token before long-running operation (cloning can take time)
    refresh_token
    
    echo "Scanning repositories for large files (>50MB)..." | tee -a "$REPORT_FILE"
    echo "This will clone repositories and may take some time..." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Size threshold: 50MB in bytes
    LARGE_FILE_THRESHOLD_BYTES=52428800  # 50MB
    total_large_files=0
    repos_with_large_files=0
    
    # Create temp file for large files (use absolute path)
    LARGE_FILES_LIST="$PWD/$TEMP_DATA_DIR/large_files.txt"
    > "$LARGE_FILES_LIST"
    
    # Committer emails harvested during the clone, used for GHAS seat sizing
    COMMITTERS_LIST="$PWD/$TEMP_DATA_DIR/committers.txt"
    > "$COMMITTERS_LIST"
    
    # Save original directory
    ORIGINAL_DIR="$PWD"
    
    if [ -f "$REPO_DETAILS_FILE" ]; then
        while read -r repo; do
            project=$(echo "$repo" | jq -r '.project')
            repo_name=$(echo "$repo" | jq -r '.name')
            
            [ "$DEBUG" = "1" ] && echo "  Scanning $project/$repo_name..." | tee -a "$REPORT_FILE"
            
            # URL encode project name for clone URL
            project_encoded=$(url_encode "$project")
            
            # Create temp directory for this repo
            repo_temp_dir="$ORIGINAL_DIR/$TEMP_DATA_DIR/scan_${repo_name}_$$"
            mkdir -p "$repo_temp_dir"
            cd "$repo_temp_dir"
            
            # Clone as bare repository (faster, includes all history)
            # Use Azure AD Bearer token with http.extraHeader for authentication, securely via a temporary file
            header_file="$repo_temp_dir/git_header.txt"
            clone_url="https://dev.azure.com/$ORG/$project_encoded/_git/$repo_name"
            # Read-only by construction: clone fetches, and the only Git commands
            # run afterwards (log, rev-list, cat-file) are local reads. The URL is
            # checked against the same allow-list as the REST calls, and the clone
            # is given an unusable push URL as defence in depth, so a `git push`
            # added here later fails locally instead of reaching Azure DevOps.
            assert_read_only_url "$clone_url"
            echo "Authorization: Bearer $ADO_TOKEN" > "$header_file"
            chmod 600 "$header_file"
            GIT_TERMINAL_PROMPT=0 git -c http.extraHeader=@"$header_file" \
                -c remote.origin.pushurl="no-push-read-only-collector" \
                clone --bare --quiet "$clone_url" repo.git 2>/dev/null
            # Capture the clone result before anything else runs: the token file
            # must be removed immediately, and `rm` would otherwise overwrite $?
            # and make every failed clone look like a success.
            clone_status=$?
            rm -f "$header_file"
            
            if [ "$clone_status" -eq 0 ] && [ -d "repo.git" ]; then
                cd repo.git
                
                # Capture distinct commit authors in the history window. Unique
                # committers are the billing unit for GitHub Advanced Security,
                # so this is collected while the clone is already local.
                git log --all --since="${HISTORY_DAYS} days ago" --format='%ae' 2>/dev/null \
                    | tr '[:upper:]' '[:lower:]' \
                    | grep -v '^$' >> "$COMMITTERS_LIST" 2>/dev/null
                
                # Find all large blobs in Git history
                large_blobs=$(git rev-list --objects --all | \
                    git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
                    awk -v threshold=$LARGE_FILE_THRESHOLD_BYTES '$1 == "blob" && $3 > threshold {printf "%.2f|%s\n", $3/1024/1024, $4}' | \
                    sort -t'|' -k1 -rn)
                
                if [ -n "$large_blobs" ]; then
                    file_count=$(echo "$large_blobs" | wc -l | tr -d ' ')
                    repos_with_large_files=$((repos_with_large_files + 1))
                    total_large_files=$((total_large_files + file_count))
                    
                    echo "    Found $file_count large file(s):" | tee -a "$REPORT_FILE"
                    echo "$large_blobs" | while IFS='|' read -r size_mb path; do
                        echo "      - $path (${size_mb}MB)" | tee -a "$REPORT_FILE"
                        echo "$project/$repo_name|$path|${size_mb}MB" >> "$LARGE_FILES_LIST"
                    done
                else
                    echo "    No large files found" | tee -a "$REPORT_FILE"
                fi
                
                cd "$ORIGINAL_DIR" > /dev/null
            else
                echo "    WARNING: Failed to clone repository" | tee -a "$REPORT_FILE"
            fi
            
            # Cleanup this repo's temp directory
            cd "$ORIGINAL_DIR" > /dev/null
            rm -rf "$repo_temp_dir"
            
        done < <(jq -c '.[]' "$REPO_DETAILS_FILE")
    fi
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Total Large Files (>50MB): $total_large_files" | tee -a "$REPORT_FILE"
    echo "Repositories with Large Files: $repos_with_large_files" | tee -a "$REPORT_FILE"
    
    if [ "$total_large_files" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "NOTE: GitHub warns about files >50MB and blocks files >100MB." | tee -a "$REPORT_FILE"
        echo "Consider using Git LFS for these files during migration." | tee -a "$REPORT_FILE"
    fi
    
else
    # Original API limitation message
    if [ "$SCAN_LARGE_FILES" = "1" ] && ! command -v git &> /dev/null; then
        echo "WARNING: SCAN_LARGE_FILES=1 but Git is not installed" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
    fi
    
    echo "NOTE: Azure DevOps API does not provide file size information via REST API." | tee -a "$REPORT_FILE"
    echo "To detect large files (>50MB), run this script with: SCAN_LARGE_FILES=1 ./ado-data-collector.sh" | tee -a "$REPORT_FILE"
    echo "This will clone repositories and scan for large files (requires Git installed)." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Alternative methods:" | tee -a "$REPORT_FILE"
    echo "  1. Clone repositories locally and run: git ls-files -z | xargs -0 du -h | sort -rh | head" | tee -a "$REPORT_FILE"
    echo "  2. Use Azure Repos web interface to browse repository contents" | tee -a "$REPORT_FILE"
    echo "  3. Check if Git LFS is already configured: git lfs ls-files" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "GitHub migration considerations:" | tee -a "$REPORT_FILE"
    echo "  - GitHub warns about files >50MB" | tee -a "$REPORT_FILE"
    echo "  - GitHub blocks files >100MB" | tee -a "$REPORT_FILE"
    echo "  - Consider using Git LFS for binary files and large assets" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Initialize variables for summary
    total_large_files=0
    repos_with_large_files=0
    
    if [ "$large_repos" -gt 0 ]; then
        echo "Repositories over 1GB (likely to contain large files):" | tee -a "$REPORT_FILE"
        echo "$large_repos_json" | jq -r '.[] | "  - \(.project)/\(.name)"' | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Recommend manual inspection of these repositories for large files." | tee -a "$REPORT_FILE"
    fi
fi

# ========================================
# 7. METADATA DATA
# ========================================
write_section "7. Metadata Data"

echo "Checking for work items, pull requests, and boards..." | tee -a "$REPORT_FILE"

total_work_items=0
total_pull_requests=0
projects_with_boards=0

for project in "${projects[@]}"; do
    [ "$DEBUG" = "1" ] && echo "  Checking metadata for project: $project" | tee -a "$REPORT_FILE"
    
    # URL encode project name
    project_encoded=$(url_encode "$project")
    
    # Count work items via WIQL. This is a POST because that is the only shape
    # the WIQL endpoint offers; it runs a query and returns IDs, and is
    # allow-listed as a read in the read-only enforcement section above.
    wi_response=$(call_api_readonly_query "$ORG_URL/$project_encoded/_apis/wit/wiql?api-version=$API_VERSION" '{"query": "Select [System.Id] From WorkItems"}')
    work_items=$(safe_jq_count "$wi_response" '.workItems | length')
    
    total_work_items=$((total_work_items + work_items))
    
    # Check for pull requests
    if [ -f "$REPO_DETAILS_FILE" ]; then
        # Use while-read loop to safely handle repo IDs (Bash 3.2 compatible), use jq --arg for safe string passing
        project_repos=()
        while IFS= read -r repo_id; do
            [ -n "$repo_id" ] && project_repos+=("$repo_id")
        done < <(jq -r --arg proj "$project" '.[] | select(.project == $proj) | .id' "$REPO_DETAILS_FILE")
        
        # Only loop if we actually have repo IDs (skip empty array)
        if [ ${#project_repos[@]} -gt 0 ] && [ -n "${project_repos[0]}" ]; then
            for repo_id in "${project_repos[@]}"; do
                pr_response=$(call_api "$ORG_URL/$project_encoded/_apis/git/repositories/$repo_id/pullrequests?api-version=$API_VERSION")
                pr_count=$(safe_jq_count "$pr_response" '.count')
                total_pull_requests=$((total_pull_requests + pr_count))
            done
        fi
    fi
    
    # Check for boards (teams indicate board usage)
    teams_response=$(call_api "$ORG_URL/_apis/projects/$project_encoded/teams?api-version=$API_VERSION")
    teams=$(safe_jq_count "$teams_response" '.count')
    if [ "$teams" -gt 0 ]; then
        projects_with_boards=$((projects_with_boards + 1))
    fi
done

echo "Total Work Items: $total_work_items" | tee -a "$REPORT_FILE"
echo "Total Pull Requests: $total_pull_requests" | tee -a "$REPORT_FILE"
echo "Projects with Boards/Teams: $projects_with_boards" | tee -a "$REPORT_FILE"

# ========================================
# 8. PIPELINE INVENTORY
# ========================================
write_section "8. Pipeline Inventory"
maybe_refresh_token

echo "Collecting pipeline definitions..." | tee -a "$REPORT_FILE"

PIPELINE_DEFS_FILE="$TEMP_DATA_DIR/pipeline_defs.json"
RELEASE_DEFS_FILE="$TEMP_DATA_DIR/release_defs.json"
TASKGROUPS_FILE="$TEMP_DATA_DIR/taskgroups.json"
VARGROUPS_FILE="$TEMP_DATA_DIR/variablegroups.json"
rm -f "$TEMP_DATA_DIR"/pipeline_defs.ndjson "$TEMP_DATA_DIR"/release_defs.ndjson \
      "$TEMP_DATA_DIR"/taskgroups.ndjson "$TEMP_DATA_DIR"/variablegroups.ndjson

for project in "${projects[@]}"; do
    [ -z "$project" ] && continue
    [ "$DEBUG" = "1" ] && echo "  Checking pipelines for project: $project" | tee -a "$REPORT_FILE"

    project_encoded=$(url_encode "$project")

    # Build definitions. includeAllProperties=true is required to expose
    # process.type, which is how classic (designer) pipelines are told apart
    # from YAML pipelines - the single biggest driver of migration effort.
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/build/definitions?includeAllProperties=true&api-version=$API_VERSION" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            id: .id,
            name: .name,
            processType: (.process.type // 0),
            queueStatus: (.queueStatus // "enabled"),
            repoId: (.repository.id // null),
            repoName: (.repository.name // null),
            repoType: (.repository.type // null),
            authoredBy: (.authoredBy.displayName // null),
            createdDate: (.createdDate // null),
            queueName: (.queue.name // null),
            poolId: (.queue.pool.id // null),
            poolIsHosted: (.queue.pool.isHosted?)
          }' >> "$TEMP_DATA_DIR/pipeline_defs.ndjson" 2>/dev/null

    # Classic release pipelines live on a different host (vsrm.dev.azure.com)
    # and are invisible to build/definitions. They almost always need a full
    # rewrite as Actions deployment workflows.
    call_api_paged \
        "https://vsrm.dev.azure.com/$ORG/$project_encoded/_apis/release/definitions?api-version=$API_VERSION" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            id: .id,
            name: .name,
            createdBy: (.createdBy.displayName // null),
            createdOn: (.createdOn // null)
          }' >> "$TEMP_DATA_DIR/release_defs.ndjson" 2>/dev/null

    # Task groups have no GitHub equivalent - each becomes a composite action
    # or reusable workflow, so the count is a direct effort input.
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/taskgroups?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{project: $proj, id: .id, name: (.name // null)}' \
        >> "$TEMP_DATA_DIR/taskgroups.ndjson" 2>/dev/null

    # Variable groups map to Actions variables / environment secrets
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/variablegroups?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            id: .id,
            name: (.name // null),
            variableCount: ((.variables // {}) | length),
            isKeyVault: ((.type // "Vsts") != "Vsts")
          }' >> "$TEMP_DATA_DIR/variablegroups.ndjson" 2>/dev/null
done

ndjson_to_array "$TEMP_DATA_DIR/pipeline_defs.ndjson" "$PIPELINE_DEFS_FILE"
ndjson_to_array "$TEMP_DATA_DIR/release_defs.ndjson" "$RELEASE_DEFS_FILE"
ndjson_to_array "$TEMP_DATA_DIR/taskgroups.ndjson" "$TASKGROUPS_FILE"
ndjson_to_array "$TEMP_DATA_DIR/variablegroups.ndjson" "$VARGROUPS_FILE"

total_pipelines=$(jq 'length' "$PIPELINE_DEFS_FILE")
yaml_pipelines=$(jq '[.[] | select(.processType == 2)] | length' "$PIPELINE_DEFS_FILE")
classic_pipelines=$(jq '[.[] | select(.processType == 1)] | length' "$PIPELINE_DEFS_FILE")
unknown_pipelines=$((total_pipelines - yaml_pipelines - classic_pipelines))
disabled_pipelines=$(jq '[.[] | select(.queueStatus != "enabled")] | length' "$PIPELINE_DEFS_FILE")
repos_with_pipelines=$(jq '[.[] | (.repoId // .repoName) | select(. != null)] | unique | length' "$PIPELINE_DEFS_FILE")
nongit_pipelines=$(jq '[.[] | select(.repoType != null and .repoType != "TfsGit")] | length' "$PIPELINE_DEFS_FILE")

total_release_defs=$(jq 'length' "$RELEASE_DEFS_FILE")
total_taskgroups=$(jq 'length' "$TASKGROUPS_FILE")
total_vargroups=$(jq 'length' "$VARGROUPS_FILE")
total_variables=$(jq '[.[].variableCount] | add // 0' "$VARGROUPS_FILE")
keyvault_vargroups=$(jq '[.[] | select(.isKeyVault)] | length' "$VARGROUPS_FILE")

echo "Total Build Pipelines: $total_pipelines" | tee -a "$REPORT_FILE"
echo "  YAML pipelines: $yaml_pipelines" | tee -a "$REPORT_FILE"
echo "  Classic (designer) pipelines: $classic_pipelines" | tee -a "$REPORT_FILE"
[ "$unknown_pipelines" -gt 0 ] && echo "  Undetermined type: $unknown_pipelines" | tee -a "$REPORT_FILE"
echo "  Disabled/paused pipelines: $disabled_pipelines" | tee -a "$REPORT_FILE"
echo "Repositories with Pipelines: $repos_with_pipelines" | tee -a "$REPORT_FILE"
[ "$nongit_pipelines" -gt 0 ] && echo "Pipelines on non-Azure-Repos sources: $nongit_pipelines" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Classic Release Pipelines: $total_release_defs" | tee -a "$REPORT_FILE"
echo "Task Groups: $total_taskgroups" | tee -a "$REPORT_FILE"
echo "Variable Groups: $total_vargroups (containing $total_variables variables)" | tee -a "$REPORT_FILE"
echo "  Azure Key Vault backed groups: $keyvault_vargroups" | tee -a "$REPORT_FILE"

# Per-project pipeline distribution helps identify which teams carry the load
if [ "$total_pipelines" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "Pipelines by Project (top 15):" | tee -a "$REPORT_FILE"
    jq -r 'group_by(.project) | map({project: .[0].project, total: length,
             yaml: ([.[] | select(.processType == 2)] | length),
             classic: ([.[] | select(.processType == 1)] | length)})
           | sort_by(-.total) | .[:15][]
           | "  \(.project): \(.total) total (\(.yaml) YAML, \(.classic) classic)"' \
        "$PIPELINE_DEFS_FILE" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "NOTE: Classic pipelines, release pipelines and task groups carry the" | tee -a "$REPORT_FILE"
echo "      highest conversion effort. Run 'gh actions-importer audit azure-devops'" | tee -a "$REPORT_FILE"
echo "      for per-pipeline conversion rates and unsupported-task detail." | tee -a "$REPORT_FILE"

# ========================================
# 9. SECURITY SCANNING (ADVANCED SECURITY)
# ========================================
write_section "9. Security Scanning (Advanced Security)"

echo "Checking for Azure DevOps Advanced Security alerts..." | tee -a "$REPORT_FILE"

# Note: Advanced Security is a paid add-on feature in Azure DevOps
# API: https://advsec.dev.azure.com/{org}/_apis/...
# Uses the same Azure AD Bearer token for authentication

total_secret_alerts=0
total_dependency_alerts=0
total_code_alerts=0
repos_with_alerts=0

# Check if Advanced Security is enabled by testing the API
# Note: Using call_api with Bearer token (same auth as all other APIs)
advsec_test=$(call_api "https://advsec.dev.azure.com/$ORG/_apis/management/enablement?api-version=7.2-preview.1")

if [ "$advsec_test" != "API_ERROR" ] && echo "$advsec_test" | jq empty 2>/dev/null; then
    echo "Advanced Security is enabled for this organization" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    
    # Initialize secret scanning detailed report
    echo "Azure DevOps Secret Scanning Detailed Report" > "$SECRET_SCANNING_REPORT"
    echo "Organization: $ORG" >> "$SECRET_SCANNING_REPORT"
    echo "Generated: $(date)" >> "$SECRET_SCANNING_REPORT"
    echo "" >> "$SECRET_SCANNING_REPORT"
    echo "========================================" >> "$SECRET_SCANNING_REPORT"
    echo "" >> "$SECRET_SCANNING_REPORT"
    
    # Initialize CSV file with headers
    echo "Project,Repository,Repository ID,Alert ID,Secret Type,Severity,Confidence,State,Validation Status,Validation Message,File Path,Start Line,End Line,Branch,Introduced Date,First Seen,Last Seen,Detection Tools,Alert URL" > "$SECRET_SCANNING_CSV"
    
    # Initialize JSON file with metadata and empty alerts array
    jq -n \
        --arg org "$ORG" \
        --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{organization: $org, generated: $generated, alerts: []}' > "$SECRET_SCANNING_JSON"
    
    # Iterate through all projects and their repositories
    for project in "${projects[@]}"; do
        [ "$DEBUG" = "1" ] && echo "  Checking Advanced Security for project: $project" | tee -a "$REPORT_FILE"
        
        # URL encode project name
        project_encoded=$(url_encode "$project")
        
        # Get repositories for this project from the cached repo details
        if [ -f "$REPO_DETAILS_FILE" ]; then
            while IFS= read -r repo_line; do
                repo_name=$(echo "$repo_line" | jq -r '.name')
                repo_id=$(echo "$repo_line" | jq -r '.id')
                
                [ -z "$repo_id" ] || [ "$repo_id" = "null" ] && continue
                
                echo "    Checking repo: $repo_name ($repo_id)" | tee -a "$REPORT_FILE"
                
                # Query each alert type separately using criteria.alertType filter
                # alertType values: 1=dependency, 2=secret, 3=code
                # criteria.states=1 means active alerts only
                # 
                # Note on confidence levels:
                # - Secret alerts (type 2) use confidence levels (High, Medium, Low, Other) because they use ML-based detection
                # - Dependency alerts (type 1) don't use confidence levels; they're based on CVE databases (deterministic)
                # - Code alerts (type 3) use severity levels, not confidence levels
                
                # Secret alerts (alertType=2) - include all confidence levels and all validity states
                # Using the criteria.validity parameter to get all active secrets regardless of validation status
                secret_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=2&criteria.states=1&criteria.confidenceLevels=High&criteria.confidenceLevels=Medium&criteria.confidenceLevels=Low&criteria.confidenceLevels=Other&api-version=7.2-preview.1")
                if [ "$secret_alerts" != "API_ERROR" ] && echo "$secret_alerts" | jq empty 2>/dev/null; then
                    secret_count=$(echo "$secret_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                    [ "$DEBUG" = "1" ] && echo "[DEBUG] Secret alerts response: $secret_alerts" >&2
                    
                    # Export detailed secret scanning information if alerts are found
                    if [ "$secret_count" -gt 0 ]; then
                        echo "----------------------------------------" >> "$SECRET_SCANNING_REPORT"
                        echo "Project: $project" >> "$SECRET_SCANNING_REPORT"
                        echo "Repository: $repo_name" >> "$SECRET_SCANNING_REPORT"
                        echo "Repository ID: $repo_id" >> "$SECRET_SCANNING_REPORT"
                        echo "Total Active Secret Alerts: $secret_count" >> "$SECRET_SCANNING_REPORT"
                        echo "" >> "$SECRET_SCANNING_REPORT"
                        
                        # Get detailed information for each alert using the Get Alert API
                        # https://learn.microsoft.com/en-us/rest/api/azure/devops/advancedsecurity/alerts/get
                        alert_ids=$(echo "$secret_alerts" | jq -r '.value[]?.alertId // empty' 2>/dev/null)
                        
                        if [ -n "$alert_ids" ]; then
                            alert_num=1
                            while IFS= read -r alert_id; do
                                [ -z "$alert_id" ] && continue
                                
                                # Get detailed alert information
                                alert_detail=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/Alert/repositories/$repo_id/Alerts/$alert_id?api-version=7.2-preview.1")
                                
                                if [ "$alert_detail" != "API_ERROR" ] && echo "$alert_detail" | jq empty 2>/dev/null; then
                                    echo "  Alert #$alert_num (ID: $alert_id)" >> "$SECRET_SCANNING_REPORT"
                                    echo "    Secret Type: $(echo "$alert_detail" | jq -r '.title // "Unknown"' 2>/dev/null)" >> "$SECRET_SCANNING_REPORT"
                                    echo "    Severity: $(echo "$alert_detail" | jq -r '.severity // "Unknown"' 2>/dev/null)" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Confidence level - map numeric to text or use confidenceLevel field
                                    confidence=$(echo "$alert_detail" | jq -r 'if .confidenceLevel then .confidenceLevel elif .confidence then (if .confidence == 1 then "High" elif .confidence == 2 then "Medium" elif .confidence == 3 then "Low" else "Other" end) else "Not Available" end' 2>/dev/null)
                                    echo "    Confidence: $confidence" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # State - map numeric to text or use state field
                                    state=$(echo "$alert_detail" | jq -r 'if .state then (if .state == 1 or .state == "active" then "Active" elif .state == 2 or .state == "dismissed" then "Dismissed" elif .state == 4 or .state == "resolved" then "Resolved" else .state end) else "Unknown" end' 2>/dev/null)
                                    echo "    State: $state" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Validation result information
                                    validation_status=$(echo "$alert_detail" | jq -r 'if .validationResult then (.validationResult.validationStatus // "Not Validated") else "Not Validated" end' 2>/dev/null)
                                    echo "    Validation Status: $validation_status" >> "$SECRET_SCANNING_REPORT"
                                    
                                    if [ "$validation_status" != "Not Validated" ] && [ "$validation_status" != "null" ]; then
                                        validation_message=$(echo "$alert_detail" | jq -r '.validationResult.message // ""' 2>/dev/null)
                                        [ -n "$validation_message" ] && [ "$validation_message" != "null" ] && echo "    Validation Message: $validation_message" >> "$SECRET_SCANNING_REPORT"
                                    fi
                                    
                                    # Location information - handle array properly
                                    file_path=$(echo "$alert_detail" | jq -r 'if .physicalLocations then (.physicalLocations[0].filePath // "Not Available") else "Not Available" end' 2>/dev/null)
                                    echo "    File Path: $file_path" >> "$SECRET_SCANNING_REPORT"
                                    
                                    start_line=$(echo "$alert_detail" | jq -r 'if .physicalLocations then (.physicalLocations[0].region.startLine // "N/A") else "N/A" end' 2>/dev/null)
                                    echo "    Start Line: $start_line" >> "$SECRET_SCANNING_REPORT"
                                    
                                    end_line=$(echo "$alert_detail" | jq -r 'if .physicalLocations then (.physicalLocations[0].region.endLine // "N/A") else "N/A" end' 2>/dev/null)
                                    echo "    End Line: $end_line" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Branch information - logicalLocations can be array or object
                                    branch=$(echo "$alert_detail" | jq -r 'if .logicalLocations then (if (.logicalLocations | type) == "array" then .logicalLocations[0].branch else .logicalLocations.branch end // "Not Available") else "Not Available" end' 2>/dev/null)
                                    echo "    Branch: $branch" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Introduction information
                                    introduced_date=$(echo "$alert_detail" | jq -r '.introducedDate // "Not Available"' 2>/dev/null)
                                    echo "    Introduced Date: $introduced_date" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # First detection
                                    first_seen=$(echo "$alert_detail" | jq -r '.firstSeenDate // "Not Available"' 2>/dev/null)
                                    echo "    First Seen: $first_seen" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Last seen
                                    last_seen=$(echo "$alert_detail" | jq -r '.lastSeenDate // "Not Available"' 2>/dev/null)
                                    echo "    Last Seen: $last_seen" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Tools information
                                    tools=$(echo "$alert_detail" | jq -r '.tools[]?.name // empty' 2>/dev/null | paste -sd "," -)
                                    if [ -n "$tools" ]; then
                                        echo "    Detection Tools: $tools" >> "$SECRET_SCANNING_REPORT"
                                    else
                                        tools="Not Available"
                                        echo "    Detection Tools: $tools" >> "$SECRET_SCANNING_REPORT"
                                    fi
                                    
                                    # Alert URL
                                    alert_url="https://dev.azure.com/$ORG/$project/_git/$repo_name/alerts/$alert_id"
                                    echo "    Alert URL: $alert_url" >> "$SECRET_SCANNING_REPORT"
                                    
                                    echo "" >> "$SECRET_SCANNING_REPORT"
                                    
                                    # Write to CSV using jq to properly escape fields
                                    # This ensures commas, quotes, and newlines in data are handled correctly
                                    secret_type=$(echo "$alert_detail" | jq -r '.title // "Unknown"' 2>/dev/null)
                                    severity=$(echo "$alert_detail" | jq -r '.severity // "Unknown"' 2>/dev/null)
                                    
                                    # Build a JSON object with all fields and use jq @csv for proper escaping
                                    # Output raw with -r to avoid double-quoting the entire line
                                    jq -n -r \
                                        --arg project "$project" \
                                        --arg repo "$repo_name" \
                                        --arg repo_id "$repo_id" \
                                        --arg alert_id "$alert_id" \
                                        --arg secret_type "$secret_type" \
                                        --arg severity "$severity" \
                                        --arg confidence "$confidence" \
                                        --arg state "$state" \
                                        --arg validation_status "$validation_status" \
                                        --arg validation_message "$validation_message" \
                                        --arg file_path "$file_path" \
                                        --arg start_line "$start_line" \
                                        --arg end_line "$end_line" \
                                        --arg branch "$branch" \
                                        --arg introduced_date "$introduced_date" \
                                        --arg first_seen "$first_seen" \
                                        --arg last_seen "$last_seen" \
                                        --arg tools "$tools" \
                                        --arg alert_url "$alert_url" \
                                        '[$project, $repo, $repo_id, $alert_id, $secret_type, $severity, $confidence, $state, $validation_status, $validation_message, $file_path, $start_line, $end_line, $branch, $introduced_date, $first_seen, $last_seen, $tools, $alert_url] | @csv' \
                                        >> "$SECRET_SCANNING_CSV"
                                    
                                    # Add alert to JSON file
                                    # Read current JSON, add new alert, write back
                                    jq \
                                        --arg project "$project" \
                                        --arg repo "$repo_name" \
                                        --arg repo_id "$repo_id" \
                                        --arg alert_id "$alert_id" \
                                        --arg secret_type "$secret_type" \
                                        --arg severity "$severity" \
                                        --arg confidence "$confidence" \
                                        --arg state "$state" \
                                        --arg validation_status "$validation_status" \
                                        --arg validation_message "$validation_message" \
                                        --arg file_path "$file_path" \
                                        --arg start_line "$start_line" \
                                        --arg end_line "$end_line" \
                                        --arg branch "$branch" \
                                        --arg introduced_date "$introduced_date" \
                                        --arg first_seen "$first_seen" \
                                        --arg last_seen "$last_seen" \
                                        --arg tools "$tools" \
                                        --arg alert_url "$alert_url" \
                                        '.alerts += [{
                                            project: $project,
                                            repository: $repo,
                                            repositoryId: $repo_id,
                                            alertId: $alert_id,
                                            secretType: $secret_type,
                                            severity: $severity,
                                            confidence: $confidence,
                                            state: $state,
                                            validationStatus: $validation_status,
                                            validationMessage: $validation_message,
                                            filePath: $file_path,
                                            startLine: $start_line,
                                            endLine: $end_line,
                                            branch: $branch,
                                            introducedDate: $introduced_date,
                                            firstSeen: $first_seen,
                                            lastSeen: $last_seen,
                                            detectionTools: $tools,
                                            alertUrl: $alert_url
                                        }]' "$SECRET_SCANNING_JSON" > "$SECRET_SCANNING_JSON.tmp" && mv "$SECRET_SCANNING_JSON.tmp" "$SECRET_SCANNING_JSON"
                                fi
                                
                                alert_num=$((alert_num + 1))
                            done <<< "$alert_ids"
                        fi
                        
                        echo "" >> "$SECRET_SCANNING_REPORT"
                    fi
                else
                    secret_count=0
                fi
                
                # Dependency alerts (alertType=1)
                dependency_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=1&criteria.states=1&api-version=7.2-preview.1")
                if [ "$dependency_alerts" != "API_ERROR" ] && echo "$dependency_alerts" | jq empty 2>/dev/null; then
                    dependency_count=$(echo "$dependency_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                else
                    dependency_count=0
                fi
                
                # Code scanning alerts (alertType=3)
                code_alerts=$(call_api "https://advsec.dev.azure.com/$ORG/$project_encoded/_apis/alert/repositories/$repo_id/alerts?criteria.alertType=3&criteria.states=1&api-version=7.2-preview.1")
                if [ "$code_alerts" != "API_ERROR" ] && echo "$code_alerts" | jq empty 2>/dev/null; then
                    code_count=$(echo "$code_alerts" | jq '.count // 0' 2>/dev/null || echo "0")
                else
                    code_count=0
                fi
                
                total_secret_alerts=$((total_secret_alerts + secret_count))
                total_dependency_alerts=$((total_dependency_alerts + dependency_count))
                total_code_alerts=$((total_code_alerts + code_count))
                
                if [ "$secret_count" -gt 0 ] || [ "$dependency_count" -gt 0 ] || [ "$code_count" -gt 0 ]; then
                    repos_with_alerts=$((repos_with_alerts + 1))
                    echo "      Found: $secret_count secret, $dependency_count dependency, $code_count code alerts" | tee -a "$REPORT_FILE"
                fi
            done < <(jq -c --arg proj "$project" '.[] | select(.project == $proj)' "$REPO_DETAILS_FILE")
        fi
    done
    
    echo "" | tee -a "$REPORT_FILE"
    echo "Total Secret Scanning Alerts: $total_secret_alerts" | tee -a "$REPORT_FILE"
    echo "Total Dependency Scanning Alerts: $total_dependency_alerts" | tee -a "$REPORT_FILE"
    echo "Total Code Scanning Alerts: $total_code_alerts" | tee -a "$REPORT_FILE"
    echo "Repositories with Security Alerts: $repos_with_alerts" | tee -a "$REPORT_FILE"
    
    # Add reference to detailed secret scanning report if secrets were found
    if [ "$total_secret_alerts" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Detailed secret scanning report saved to: $SECRET_SCANNING_REPORT" | tee -a "$REPORT_FILE"
        echo "Secret scanning CSV (Excel-compatible) saved to: $SECRET_SCANNING_CSV" | tee -a "$REPORT_FILE"
        echo "Secret scanning JSON (machine-readable) saved to: $SECRET_SCANNING_JSON" | tee -a "$REPORT_FILE"
    fi
else
    echo "Advanced Security is NOT enabled for this organization" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "NOTE: Azure DevOps Advanced Security is a paid add-on feature that includes:" | tee -a "$REPORT_FILE"
    echo "  - Secret scanning (credentials, tokens, keys)" | tee -a "$REPORT_FILE"
    echo "  - Dependency scanning (vulnerable packages)" | tee -a "$REPORT_FILE"
    echo "  - Code scanning (security vulnerabilities)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Alternative: Consider using third-party security scanning tools or" | tee -a "$REPORT_FILE"
    echo "GitHub Advanced Security after migration." | tee -a "$REPORT_FILE"
fi

# ========================================
# 10. INTEGRATIONS, EXTENSIONS & SERVICE CONNECTIONS
# ========================================
write_section "10. Integrations, Extensions & Service Connections"
maybe_refresh_token

echo "Checking for service hooks, extensions and service connections..." | tee -a "$REPORT_FILE"

total_hooks=0
rm -f "$TEMP_DATA_DIR/hook_types.txt" "$TEMP_DATA_DIR/service_connections.ndjson"

SERVICE_CONN_FILE="$TEMP_DATA_DIR/service_connections.json"
EXTENSIONS_FILE="$TEMP_DATA_DIR/extensions.json"

for project in "${projects[@]}"; do
    [ -z "$project" ] && continue
    [ "$DEBUG" = "1" ] && echo "  Checking integrations for project: $project" | tee -a "$REPORT_FILE"

    project_encoded=$(url_encode "$project")

    # Service hooks
    hooks=$(call_api "$ORG_URL/$project_encoded/_apis/hooks/subscriptions?api-version=$API_VERSION")
    hook_count=$(safe_jq_count "$hooks" '.count')

    if [ "$hook_count" -gt 0 ]; then
        total_hooks=$((total_hooks + hook_count))
        if [ "$hooks" != "API_ERROR" ] && echo "$hooks" | jq empty 2>/dev/null; then
            echo "$hooks" | jq -r '.value[].consumerType' 2>/dev/null >> "$TEMP_DATA_DIR/hook_types.txt"
        fi
    fi

    # Service connections are the strongest signal of third-party coupling.
    # The connection *type* (salesforce, sonarqube, artifactory, kubernetes...)
    # tells you exactly which external systems the pipelines depend on.
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/serviceendpoint/endpoints?api-version=$API_VERSION" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            name: (.name // null),
            type: (.type // "unknown"),
            scheme: (.authorization.scheme // null),
            isShared: (.isShared // false)
          }' >> "$TEMP_DATA_DIR/service_connections.ndjson" 2>/dev/null
done

ndjson_to_array "$TEMP_DATA_DIR/service_connections.ndjson" "$SERVICE_CONN_FILE"

# Installed marketplace extensions (organization-scoped, different host)
call_api_paged \
    "https://extmgmt.dev.azure.com/$ORG/_apis/extensionmanagement/installedextensions?api-version=7.1-preview.1" \
    '.value' \
    | jq -c 'select(((.flags // "") | ascii_downcase | contains("builtin")) | not) | {
        publisher: (.publisherName // .publisherId // "unknown"),
        name: (.extensionName // .extensionId // "unknown"),
        id: ((.publisherId // "unknown") + "." + (.extensionId // "unknown")),
        version: (.version // null)
      }' > "$TEMP_DATA_DIR/extensions.ndjson" 2>/dev/null
ndjson_to_array "$TEMP_DATA_DIR/extensions.ndjson" "$EXTENSIONS_FILE"

total_service_connections=$(jq 'length' "$SERVICE_CONN_FILE")
distinct_connection_types=$(jq '[.[].type] | unique | length' "$SERVICE_CONN_FILE")
total_extensions=$(jq 'length' "$EXTENSIONS_FILE")

echo "" | tee -a "$REPORT_FILE"
echo "Total Service Hooks: $total_hooks" | tee -a "$REPORT_FILE"

if [ -f "$TEMP_DATA_DIR/hook_types.txt" ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "Service Hook Consumer Types:" | tee -a "$REPORT_FILE"
    sort "$TEMP_DATA_DIR/hook_types.txt" | uniq -c | sort -rn | while read -r count hook; do
        echo "  - $hook: $count" | tee -a "$REPORT_FILE"
    done
fi

echo "" | tee -a "$REPORT_FILE"
echo "Total Service Connections: $total_service_connections ($distinct_connection_types distinct types)" | tee -a "$REPORT_FILE"

if [ "$total_service_connections" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "Service Connection Types (by usage):" | tee -a "$REPORT_FILE"
    jq -r 'group_by(.type) | map({type: .[0].type, count: length})
           | sort_by(-.count) | .[] | "  - \(.type): \(.count)"' \
        "$SERVICE_CONN_FILE" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "Installed Marketplace Extensions: $total_extensions" | tee -a "$REPORT_FILE"

if [ "$total_extensions" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    jq -r '.[] | "  - \(.publisher).\(.name)"' "$EXTENSIONS_FILE" \
        | sort | uniq | tee -a "$REPORT_FILE"
fi

# ========================================
# 11. LICENSING & USER ACTIVITY
# ========================================
write_section "11. Licensing & User Activity"
maybe_refresh_token

echo "Collecting user entitlement information..." | tee -a "$REPORT_FILE"

# Get organization users (requires vsaex subdomain).
# The unpaginated call caps at 100 users, which silently understates the
# licence count on any real organisation. From api-version 6.0 onward this
# endpoint is continuation-token paged - it does NOT honour $top/$skip, so
# skip-based paging would re-fetch page 0 until the page limit was hit and
# report the same 100 users hundreds of times over.
# The response array is `members` on 7.x and `items` on older versions.
USERS_FILE="$TEMP_DATA_DIR/users.json"
call_api_paged \
    "https://vsaex.dev.azure.com/$ORG/_apis/userentitlements?api-version=$API_VERSION" \
    '(.members // .items // [])' > "$TEMP_DATA_DIR/users.ndjson"
ndjson_to_array "$TEMP_DATA_DIR/users.ndjson" "$USERS_FILE"

user_count=$(jq 'length' "$USERS_FILE")

echo "Total Users in Organization: $user_count" | tee -a "$REPORT_FILE"

active_30=0
active_60=0
active_90=0
never_accessed=0
stakeholder_count=0
basic_count=0
basictest_count=0
vs_subscriber_count=0
service_account_count=0

if [ "$user_count" -gt 0 ]; then
    # Access level breakdown
    echo "" | tee -a "$REPORT_FILE"
    echo "User Access Level Breakdown:" | tee -a "$REPORT_FILE"
    jq -r 'group_by(.accessLevel.accountLicenseType // "unknown")
           | map({level: (.[0].accessLevel.accountLicenseType // "unknown"), count: length})
           | sort_by(-.count) | .[] | "  - \(.level): \(.count) users"' \
        "$USERS_FILE" | tee -a "$REPORT_FILE"

    stakeholder_count=$(jq '[.[] | select((.accessLevel.accountLicenseType // "") == "stakeholder")] | length' "$USERS_FILE")
    basic_count=$(jq '[.[] | select((.accessLevel.accountLicenseType // "") == "express")] | length' "$USERS_FILE")
    basictest_count=$(jq '[.[] | select((.accessLevel.accountLicenseType // "") == "advanced")] | length' "$USERS_FILE")
    vs_subscriber_count=$(jq '[.[] | select((.accessLevel.licensingSource // "") == "msdn")] | length' "$USERS_FILE")

    # Activity windows. lastAccessedDate is unset (year 0001) for users who
    # have never signed in - those are pure licence waste and should not be
    # carried into the GitHub seat count.
    active_30=$(jq --arg c "$(iso_days_ago 30)" \
        '[.[] | select((.lastAccessedDate // "") > $c)] | length' "$USERS_FILE")
    active_60=$(jq --arg c "$(iso_days_ago 60)" \
        '[.[] | select((.lastAccessedDate // "") > $c)] | length' "$USERS_FILE")
    active_90=$(jq --arg c "$(iso_days_ago 90)" \
        '[.[] | select((.lastAccessedDate // "") > $c)] | length' "$USERS_FILE")
    never_accessed=$(jq '[.[] | select((.lastAccessedDate // "") | (. == "" or startswith("0001")))] | length' "$USERS_FILE")

    # Heuristic service/bot account detection - excluded from seat planning
    service_account_count=$(jq '[.[] | select(
        ((.user.displayName // "") + " " + (.user.principalName // "") | ascii_downcase) as $n
        | ($n | test("service account|build service|(^|[^a-z])svc([^a-z]|$)|(^|[^a-z])bot([^a-z]|$)|automation|deploy(ment)? account|pipeline agent|no[-_ ]?reply"))
      )] | length' "$USERS_FILE")

    echo "" | tee -a "$REPORT_FILE"
    echo "User Activity (sign-in recency):" | tee -a "$REPORT_FILE"
    echo "  Active in last 30 days: $active_30" | tee -a "$REPORT_FILE"
    echo "  Active in last 60 days: $active_60" | tee -a "$REPORT_FILE"
    echo "  Active in last 90 days: $active_90" | tee -a "$REPORT_FILE"
    echo "  Never signed in:        $never_accessed" | tee -a "$REPORT_FILE"
    echo "  Likely service/bot accounts: $service_account_count" | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
    echo "Seat Planning Inputs:" | tee -a "$REPORT_FILE"
    echo "  Total provisioned users:      $user_count" | tee -a "$REPORT_FILE"
    echo "  Active (90d) users:           $active_90" | tee -a "$REPORT_FILE"
    echo "  Stakeholder users:            $stakeholder_count" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "  IMPORTANT: Stakeholder access is free in Azure DevOps but has no" | tee -a "$REPORT_FILE"
    echo "  free equivalent on GitHub - every Stakeholder who needs access" | tee -a "$REPORT_FILE"
    echo "  becomes a paid GitHub Enterprise seat. This is the most common" | tee -a "$REPORT_FILE"
    echo "  source of budget surprise in ADO-to-GitHub licensing models." | tee -a "$REPORT_FILE"

    # Export user list to CSV in the working directory so it survives the
    # temp-directory cleanup trap.
    echo "displayName,emailAddress,accessLevel,licensingSource,lastAccessDate,dateCreated" > "$USER_CSV"
    jq -r '.[] | [
            (.user.displayName // ""),
            (.user.mailAddress // ""),
            (.accessLevel.accountLicenseType // ""),
            (.accessLevel.licensingSource // ""),
            (.lastAccessedDate // ""),
            (.dateCreated // "")
          ] | @csv' "$USERS_FILE" >> "$USER_CSV" 2>/dev/null
    echo "" | tee -a "$REPORT_FILE"
    echo "User details exported to: $USER_CSV" | tee -a "$REPORT_FILE"
else
    echo "WARNING: No user entitlement data retrieved." | tee -a "$REPORT_FILE"
    echo "  This usually means the account lacks Member Entitlement Management" | tee -a "$REPORT_FILE"
    echo "  permissions on the organization." | tee -a "$REPORT_FILE"
fi

# Unique committers over the history window - the billing unit for GitHub
# Advanced Security. Only available when repositories were cloned.
unique_committers=0
if [ "$SCAN_LARGE_FILES" = "1" ] && [ -f "$TEMP_DATA_DIR/committers.txt" ]; then
    # `grep -c .` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback
    # would fire in addition to grep's own output and yield the two-line string
    # "0\n0" - which later aborts the whole `jq -n --argjson` export.
    unique_committers=$(LC_ALL=C sort -u "$TEMP_DATA_DIR/committers.txt" | grep -c . )
    unique_committers=$(num "$unique_committers")
    echo "" | tee -a "$REPORT_FILE"
    echo "Unique Committers (last $HISTORY_DAYS days): $unique_committers" | tee -a "$REPORT_FILE"
    echo "  This is the billing unit for GitHub Advanced Security." | tee -a "$REPORT_FILE"
else
    echo "" | tee -a "$REPORT_FILE"
    echo "Unique Committers: not collected (re-run with SCAN_LARGE_FILES=1)" | tee -a "$REPORT_FILE"
fi

# ========================================
# 12. BUILD ACTIVITY & RUNNER SIZING
# ========================================
write_section "12. Build Activity & Runner Sizing"
maybe_refresh_token

HISTORY_START=$(iso_days_ago "$HISTORY_DAYS")
BUILDS_FILE="$TEMP_DATA_DIR/builds.json"
POOLS_FILE="$TEMP_DATA_DIR/pools.json"
BUILD_STATS_FILE="$TEMP_DATA_DIR/build_stats.json"

# Agent pools are org-scoped and tell us which builds ran on Microsoft-hosted
# infrastructure versus self-managed agents.
call_api_paged "$ORG_URL/_apis/distributedtask/pools?api-version=$API_VERSION" '.value' \
    | jq -c '{
        id: .id,
        name: (.name // "unknown"),
        isHosted: (.isHosted // false),
        poolType: (.poolType // "automation"),
        size: (.size // 0)
      }' > "$TEMP_DATA_DIR/pools.ndjson" 2>/dev/null
ndjson_to_array "$TEMP_DATA_DIR/pools.ndjson" "$POOLS_FILE"

echo "[]" > "$BUILDS_FILE"
# Always initialise the stats file so the JSON export at the end can slurp it
# even when build history is skipped or the organization has no builds.
echo "{}" > "$BUILD_STATS_FILE"
total_builds=0
total_build_minutes=0
builds_per_month=0
minutes_per_month=0
peak_concurrency=0
queue_p50=0
queue_p95=0
failure_rate=0
dead_pipelines=0
active_pipelines=0

if [ "$SKIP_BUILD_HISTORY" = "1" ]; then
    echo "Build history collection skipped (SKIP_BUILD_HISTORY=1)." | tee -a "$REPORT_FILE"
    echo "Runner sizing requires build history - re-run without this flag." | tee -a "$REPORT_FILE"
else
    echo "Collecting build history since $HISTORY_START ($HISTORY_DAYS days)..." | tee -a "$REPORT_FILE"
    echo "This is the slowest section on large organizations." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"

    rm -f "$TEMP_DATA_DIR/builds.ndjson"
    touch "$TEMP_DATA_DIR/builds.ndjson"

    # Builds are fetched 1000 per page, so translate the documented per-project
    # build cap into a page cap that call_api_paged will actually enforce.
    # Without this the cap was cosmetic: the real ceiling was the helper's
    # default of 500 pages (500,000 builds per project).
    builds_page_cap=$((MAX_BUILDS_PER_PROJECT / 1000))
    [ "$builds_page_cap" -lt 1 ] && builds_page_cap=1
    # The ceiling actually applied, which is the page cap rounded to whole
    # pages (never zero). The truncation check below must compare against THIS,
    # not the raw setting, or a cap under 1000 flags complete data as truncated.
    effective_build_cap=$((builds_page_cap * 1000))

    for project in "${projects[@]}"; do
        [ -z "$project" ] && continue
        maybe_refresh_token

        project_encoded=$(url_encode "$project")
        [ "$DEBUG" = "1" ] && echo "  Collecting builds for project: $project" >&2

        before_count=$(wc -l < "$TEMP_DATA_DIR/builds.ndjson" | tr -d ' ')

        call_api_paged \
            "$ORG_URL/$project_encoded/_apis/build/builds?minTime=$HISTORY_START&%24top=1000&api-version=$API_VERSION" \
            '.value' \
            "$builds_page_cap" \
            | jq -c --arg proj "$project" '{
                project: $proj,
                definitionId: (.definition.id // null),
                definitionName: (.definition.name // null),
                result: (.result // "unknown"),
                status: (.status // "unknown"),
                reason: (.reason // "unknown"),
                queueTime: (.queueTime // null),
                startTime: (.startTime // null),
                finishTime: (.finishTime // null),
                poolId: (.queue.pool.id // null),
                poolName: (.queue.pool.name // .queue.name // "unknown"),
                poolIsHosted: (.queue.pool.isHosted?),
                requestedFor: (.requestedFor.displayName // null)
              }' >> "$TEMP_DATA_DIR/builds.ndjson" 2>/dev/null

        after_count=$(wc -l < "$TEMP_DATA_DIR/builds.ndjson" | tr -d ' ')
        collected=$((after_count - before_count))

        if [ "$collected" -ge "$effective_build_cap" ]; then
            report_warn "Project '$project' hit the per-project build cap ($effective_build_cap) - its build figures are a LOWER BOUND. Raise MAX_BUILDS_PER_PROJECT or lower HISTORY_DAYS."
        fi
    done

    ndjson_to_array "$TEMP_DATA_DIR/builds.ndjson" "$BUILDS_FILE"
    total_builds=$(jq 'length' "$BUILDS_FILE")

    if [ "$total_builds" -eq 0 ]; then
        echo "No builds found in the last $HISTORY_DAYS days." | tee -a "$REPORT_FILE"
        echo "Either the organization is inactive or the account lacks build read access." | tee -a "$REPORT_FILE"
    else
        # All time arithmetic happens in jq. Azure DevOps returns fractional
        # seconds ("...T10:30:00.123Z") which fromdateiso8601 rejects, so the
        # fraction is stripped first.
        jq --argjson days "$HISTORY_DAYS" '
            def epoch:
                if (. == null or . == "") then null
                else (sub("\\.[0-9]+";"") | fromdateiso8601? // null) end;
            def pct($p):
                if length == 0 then 0
                else (sort | .[(((length - 1) * $p) | floor)]) end;

            map(. + {
                _q: (.queueTime | epoch),
                _s: (.startTime  | epoch),
                _f: (.finishTime | epoch)
            })
            | map(. + {
                _dur:  (if (._s != null and ._f != null and ._f >= ._s) then (._f - ._s) else null end),
                _wait: (if (._q != null and ._s != null and ._s >= ._q) then (._s - ._q) else null end)
            })
            | . as $b
            | ($b | map(select(._dur != null) | ._dur) | add // 0) as $totalSec
            | ($b | map(select(._wait != null) | ._wait)) as $waits
            | {
                totalBuilds: ($b | length),
                buildsWithDuration: ($b | map(select(._dur != null)) | length),
                windowDays: $days,
                totalComputeMinutes: (($totalSec / 60) | floor),
                buildsPerMonth: ((($b | length) / $days * 30) | floor),
                computeMinutesPerMonth: ((($totalSec / 60) / $days * 30) | floor),
                avgDurationMinutes: (
                    ($b | map(select(._dur != null) | ._dur)) as $d
                    | if ($d | length) == 0 then 0
                      else ((($d | add) / ($d | length) / 60) * 100 | floor) / 100 end),
                medianDurationMinutes: (
                    (($b | map(select(._dur != null) | ._dur) | pct(0.5)) / 60 * 100 | floor) / 100),
                p95DurationMinutes: (
                    (($b | map(select(._dur != null) | ._dur) | pct(0.95)) / 60 * 100 | floor) / 100),
                queueWaitP50Seconds: (($waits | pct(0.5)) | floor),
                queueWaitP95Seconds: (($waits | pct(0.95)) | floor),
                peakConcurrency: (
                    [ $b[] | select(._s != null and ._f != null)
                      | ({t: ._s, d: 1}, {t: ._f, d: -1}) ]
                    | sort_by(.t, .d)
                    | reduce .[] as $e ({c: 0, m: 0};
                        .c += $e.d | .m = (if .c > .m then .c else .m end))
                    | .m),
                resultBreakdown: (
                    $b | group_by(.result)
                       | map({key: (.[0].result // "unknown"), count: length})
                       | sort_by(-.count)),
                byPool: (
                    $b | group_by(.poolName)
                       | map({
                           pool: (.[0].poolName // "unknown"),
                           isHosted: (.[0].poolIsHosted),
                           builds: length,
                           minutes: ((map(select(._dur != null) | ._dur) | add // 0) / 60 | floor)
                         })
                       | sort_by(-.minutes)),
                activeDefinitionKeys: (
                    $b | map(select(.definitionId != null)
                             | "\(.project)#\(.definitionId)") | unique)
              }' "$BUILDS_FILE" > "$BUILD_STATS_FILE" 2>/dev/null

        if [ ! -s "$BUILD_STATS_FILE" ]; then
            echo "WARNING: Failed to compute build statistics." | tee -a "$REPORT_FILE"
            echo "{}" > "$BUILD_STATS_FILE"
        fi

        total_build_minutes=$(jq -r '.totalComputeMinutes // 0' "$BUILD_STATS_FILE")
        builds_per_month=$(jq -r '.buildsPerMonth // 0' "$BUILD_STATS_FILE")
        minutes_per_month=$(jq -r '.computeMinutesPerMonth // 0' "$BUILD_STATS_FILE")
        peak_concurrency=$(jq -r '.peakConcurrency // 0' "$BUILD_STATS_FILE")
        queue_p50=$(jq -r '.queueWaitP50Seconds // 0' "$BUILD_STATS_FILE")
        queue_p95=$(jq -r '.queueWaitP95Seconds // 0' "$BUILD_STATS_FILE")

        echo "Builds in last $HISTORY_DAYS days: $total_builds" | tee -a "$REPORT_FILE"
        echo "Builds per month (normalised):     $builds_per_month" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Compute Consumption:" | tee -a "$REPORT_FILE"
        echo "  Total build minutes ($HISTORY_DAYS days): $total_build_minutes" | tee -a "$REPORT_FILE"
        echo "  Build minutes per month:                  $minutes_per_month" | tee -a "$REPORT_FILE"
        echo "  Average build duration (min): $(jq -r '.avgDurationMinutes // 0' "$BUILD_STATS_FILE")" | tee -a "$REPORT_FILE"
        echo "  Median build duration (min):  $(jq -r '.medianDurationMinutes // 0' "$BUILD_STATS_FILE")" | tee -a "$REPORT_FILE"
        echo "  P95 build duration (min):     $(jq -r '.p95DurationMinutes // 0' "$BUILD_STATS_FILE")" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Concurrency & Queueing:" | tee -a "$REPORT_FILE"
        echo "  Peak concurrent builds observed: $peak_concurrency" | tee -a "$REPORT_FILE"
        echo "  Queue wait P50: ${queue_p50}s" | tee -a "$REPORT_FILE"
        echo "  Queue wait P95: ${queue_p95}s" | tee -a "$REPORT_FILE"

        echo "" | tee -a "$REPORT_FILE"
        echo "Build Outcomes:" | tee -a "$REPORT_FILE"
        jq -r '.resultBreakdown[]? | "  - \(.key): \(.count)"' "$BUILD_STATS_FILE" | tee -a "$REPORT_FILE"

        echo "" | tee -a "$REPORT_FILE"
        echo "Compute by Agent Pool:" | tee -a "$REPORT_FILE"
        jq -r '.byPool[]? |
               "  - \(.pool) [\(if .isHosted == true then "Microsoft-hosted" elif .isHosted == false then "self-hosted" else "unknown" end)]: \(.builds) builds, \(.minutes) min"' \
            "$BUILD_STATS_FILE" | tee -a "$REPORT_FILE"

        # Dead pipeline detection: definitions that exist but never ran in the
        # window. Typically 30-50% of an estate and should be decommissioned
        # rather than migrated.
        if [ -f "$PIPELINE_DEFS_FILE" ] && [ "$total_pipelines" -gt 0 ]; then
            active_pipelines=$(jq -r --slurpfile stats "$BUILD_STATS_FILE" '
                ($stats[0].activeDefinitionKeys // []) as $active
                | [.[] | select(("\(.project)#\(.id)") as $k | $active | index($k))] | length
              ' "$PIPELINE_DEFS_FILE" 2>/dev/null || echo "0")
            dead_pipelines=$((total_pipelines - active_pipelines))

            echo "" | tee -a "$REPORT_FILE"
            echo "Pipeline Activity:" | tee -a "$REPORT_FILE"
            echo "  Pipelines that ran in last $HISTORY_DAYS days: $active_pipelines" | tee -a "$REPORT_FILE"
            echo "  Pipelines with NO runs (migration candidates for retirement): $dead_pipelines" | tee -a "$REPORT_FILE"
            if [ "$total_pipelines" -gt 0 ]; then
                dead_pct=$(jq -rn --argjson d "$dead_pipelines" --argjson t "$total_pipelines" \
                    '(($d / $t) * 100) | floor')
                echo "  Dormant share: ${dead_pct}% of all pipeline definitions" | tee -a "$REPORT_FILE"
            fi
        fi

        echo "" | tee -a "$REPORT_FILE"
        echo "SIZING CAVEAT: Azure DevOps minutes do not convert 1:1 to GitHub" | tee -a "$REPORT_FILE"
        echo "  Actions minutes. Actions bills per job, rounds each job up to the" | tee -a "$REPORT_FILE"
        echo "  next whole minute, and applies multipliers (Windows 2x, macOS 10x)" | tee -a "$REPORT_FILE"
        echo "  against Linux. Runner hardware also differs. Treat the figures" | tee -a "$REPORT_FILE"
        echo "  above as the input to a modelled range, not a firm figure." | tee -a "$REPORT_FILE"
    fi
fi

# ========================================
# 13. AGENT POOLS & SELF-HOSTED INFRASTRUCTURE
# ========================================
write_section "13. Agent Pools & Self-Hosted Infrastructure"
maybe_refresh_token

echo "Collecting agent pool and agent inventory..." | tee -a "$REPORT_FILE"

AGENTS_FILE="$TEMP_DATA_DIR/agents.json"
rm -f "$TEMP_DATA_DIR/agents.ndjson"
touch "$TEMP_DATA_DIR/agents.ndjson"

total_pools=$(jq 'length' "$POOLS_FILE" 2>/dev/null || echo "0")
hosted_pools=$(jq '[.[] | select(.isHosted == true)] | length' "$POOLS_FILE" 2>/dev/null || echo "0")
selfhosted_pools=$((total_pools - hosted_pools))

# Enumerate agents only for self-hosted pools. Microsoft-hosted pools report
# ephemeral agents that carry no migration signal.
while IFS= read -r pool_line; do
    [ -z "$pool_line" ] && continue
    pool_id=$(echo "$pool_line" | jq -r '.id')
    pool_name=$(echo "$pool_line" | jq -r '.name')
    { [ -z "$pool_id" ] || [ "$pool_id" = "null" ]; } && continue

    call_api_paged "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?api-version=$API_VERSION" '.value' \
        | jq -c --arg pool "$pool_name" '{
            pool: $pool,
            name: (.name // "unknown"),
            osDescription: (.osDescription // "unknown"),
            enabled: (.enabled // false),
            status: (.status // "unknown"),
            version: (.version // null)
          }' >> "$TEMP_DATA_DIR/agents.ndjson" 2>/dev/null
done < <(jq -c '.[] | select(.isHosted != true)' "$POOLS_FILE" 2>/dev/null)

ndjson_to_array "$TEMP_DATA_DIR/agents.ndjson" "$AGENTS_FILE"

total_agents=$(jq 'length' "$AGENTS_FILE")
online_agents=$(jq '[.[] | select(.status == "online")] | length' "$AGENTS_FILE")
enabled_agents=$(jq '[.[] | select(.enabled == true)] | length' "$AGENTS_FILE")

echo "" | tee -a "$REPORT_FILE"
echo "Agent Pools: $total_pools total" | tee -a "$REPORT_FILE"
echo "  Microsoft-hosted pools: $hosted_pools" | tee -a "$REPORT_FILE"
echo "  Self-hosted pools:      $selfhosted_pools" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Self-Hosted Agents: $total_agents registered" | tee -a "$REPORT_FILE"
echo "  Online:  $online_agents" | tee -a "$REPORT_FILE"
echo "  Enabled: $enabled_agents" | tee -a "$REPORT_FILE"

if [ "$total_agents" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "Agent Operating Systems:" | tee -a "$REPORT_FILE"
    # Normalise the verbose osDescription string into a coarse OS family,
    # which is what actually drives runner cost multipliers.
    jq -r '[.[] | (.osDescription // "unknown") as $o
            | if ($o | test("(?i)windows|microsoft")) then "Windows"
              elif ($o | test("(?i)darwin|mac")) then "macOS"
              elif ($o | test("(?i)linux|ubuntu|debian|rhel|centos|fedora|alpine")) then "Linux"
              else "Other/Unknown" end]
           | group_by(.) | map({os: .[0], count: length}) | sort_by(-.count)
           | .[] | "  - \(.os): \(.count) agents"' "$AGENTS_FILE" | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
    echo "Self-Hosted Pool Detail:" | tee -a "$REPORT_FILE"
    jq -r 'group_by(.pool) | map({pool: .[0].pool, agents: length,
             online: ([.[] | select(.status == "online")] | length)})
           | sort_by(-.agents) | .[]
           | "  - \(.pool): \(.agents) agents (\(.online) online)"' \
        "$AGENTS_FILE" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "GitHub equivalent: Microsoft-hosted pools map to GitHub-hosted runners" | tee -a "$REPORT_FILE"
echo "  (per-minute billing). Self-hosted pools map to either self-hosted" | tee -a "$REPORT_FILE"
echo "  runners or Actions Runner Controller (ARC) on Kubernetes - no GitHub" | tee -a "$REPORT_FILE"
echo "  compute charge, but you keep the infrastructure cost." | tee -a "$REPORT_FILE"
echo "  Peak concurrency (section 12) sizes the runner fleet; total minutes" | tee -a "$REPORT_FILE"
echo "  size the GitHub-hosted spend." | tee -a "$REPORT_FILE"

# ========================================
# 14. ADO TO GITHUB CAPABILITY MAPPING
# ========================================
write_section "14. Azure DevOps to GitHub Capability Mapping"

echo "Mapping detected integrations to GitHub equivalents..." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Effort categories:" | tee -a "$REPORT_FILE"
echo "  OOB     - supported out of the box by a GitHub feature" | tee -a "$REPORT_FILE"
echo "  MARKET  - GitHub Marketplace action exists" | tee -a "$REPORT_FILE"
echo "  PARTNER - publisher provides a supported GitHub App or action" | tee -a "$REPORT_FILE"
echo "  CUSTOM  - no direct equivalent; expect bespoke work" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

map_service_connection() {
    case "$1" in
        git|github|githubenterprise|githubboards)
            echo "OOB|Native GitHub repository access" ;;
        azurerm|azure|azdoazurerm)
            echo "OOB|azure/login with OIDC federated credentials" ;;
        dockerregistry|acr)
            echo "MARKET|docker/login-action" ;;
        kubernetes)
            echo "MARKET|azure/k8s-set-context or equivalent cloud auth action" ;;
        aws)
            echo "MARKET|aws-actions/configure-aws-credentials with OIDC" ;;
        gcp|googlecloud)
            echo "MARKET|google-github-actions/auth with Workload Identity" ;;
        sonarqube|sonarcloud)
            echo "PARTNER|SonarSource/sonarqube-scan-action + SonarQube GitHub App" ;;
        artifactoryService|jfrogArtifactoryService|jfrog*)
            echo "PARTNER|jfrog/setup-jfrog-cli" ;;
        nuget|npm|pypi|maven)
            echo "OOB|GitHub Packages or the existing external registry" ;;
        salesforce*|sfdx*)
            echo "PARTNER|Salesforce sf CLI in a workflow; Copado/Gearset/Flosum Apps. Verify SSO and named-credential parity" ;;
        servicenow*)
            echo "PARTNER|ServiceNow DevOps GitHub App (change approval gates)" ;;
        jenkins)
            echo "CUSTOM|Usually retired during migration; otherwise trigger via API" ;;
        externaltfs|tfs)
            echo "CUSTOM|Legacy TFS connection - review whether still required" ;;
        ssh)
            echo "OOB|SSH key stored as an encrypted Actions secret" ;;
        generic|externalgitendpoint)
            echo "CUSTOM|Generic endpoint - inspect target system individually" ;;
        incomingwebhook|webhook)
            echo "OOB|repository_dispatch or workflow_dispatch triggers" ;;
        *)
            echo "CUSTOM|No known mapping - assess individually" ;;
    esac
}

map_extension() {
    case "$1" in
        *sonarqube*|*sonarcloud*|*sonarsource*)
            echo "PARTNER|SonarQube GitHub App + scan action" ;;
        *snyk*)
            echo "PARTNER|snyk/actions" ;;
        *checkmarx*)
            echo "PARTNER|Checkmarx GitHub Action, or consolidate into GHAS code scanning" ;;
        *veracode*)
            echo "PARTNER|Veracode GitHub Action, or consolidate into GHAS" ;;
        *whitesource*|*mend*)
            echo "PARTNER|Mend GitHub App, or consolidate into GHAS Dependabot" ;;
        *blackduck*|*synopsys*|*coverity*)
            echo "PARTNER|Third-party action, or consolidate into GHAS" ;;
        *slack*)
            echo "OOB|GitHub Slack App or slackapi/slack-github-action" ;;
        *teams*)
            echo "OOB|Microsoft Teams GitHub connector" ;;
        *jira*|*atlassian*)
            echo "PARTNER|Jira GitHub App (Atlassian) - two-way issue linking" ;;
        *servicenow*)
            echo "PARTNER|ServiceNow DevOps GitHub App" ;;
        *salesforce*|*sfdx*|*copado*|*gearset*|*flosum*)
            echo "PARTNER|Third-party GitHub App (Copado/Gearset/Flosum) or sf CLI in workflows" ;;
        *terraform*|*hashicorp*)
            echo "PARTNER|hashicorp/setup-terraform, or HCP Terraform GitHub App" ;;
        *sonatype*|*nexus*)
            echo "PARTNER|Sonatype GitHub integration" ;;
        *docker*)
            echo "MARKET|docker/build-push-action" ;;
        *kubernetes*|*helm*)
            echo "MARKET|azure/setup-helm, azure/k8s-deploy" ;;
        *token*|*variable*|*yaml*)
            echo "OOB|Actions expressions, environment variables and secrets" ;;
        *test*|*junit*|*nunit*)
            echo "MARKET|Test reporter actions (e.g. dorny/test-reporter)" ;;
        *)
            echo "CUSTOM|Review individually against GitHub Marketplace" ;;
    esac
}

oob_count=0
market_count=0
partner_count=0
custom_count=0
CUSTOM_ITEMS_FILE="$TEMP_DATA_DIR/custom_items.txt"
: > "$CUSTOM_ITEMS_FILE"

tally_category() {
    case "$1" in
        OOB)     oob_count=$((oob_count + 1)) ;;
        MARKET)  market_count=$((market_count + 1)) ;;
        PARTNER) partner_count=$((partner_count + 1)) ;;
        *)       custom_count=$((custom_count + 1)); echo "$2" >> "$CUSTOM_ITEMS_FILE" ;;
    esac
}

if [ "${total_service_connections:-0}" -gt 0 ]; then
    echo "Service Connection Mapping:" | tee -a "$REPORT_FILE"
    while IFS='|' read -r conn_type conn_count; do
        [ -z "$conn_type" ] && continue
        mapping=$(map_service_connection "$conn_type")
        category="${mapping%%|*}"
        guidance="${mapping#*|}"
        printf '  [%-7s] %s (x%s)\n              -> %s\n' \
            "$category" "$conn_type" "$conn_count" "$guidance" | tee -a "$REPORT_FILE"
        tally_category "$category" "service-connection: $conn_type (x$conn_count)"
    done < <(jq -r 'group_by(.type) | map({type: .[0].type, count: length})
                    | sort_by(-.count) | .[] | "\(.type)|\(.count)"' "$SERVICE_CONN_FILE")
    echo "" | tee -a "$REPORT_FILE"
fi

if [ "${total_extensions:-0}" -gt 0 ]; then
    echo "Marketplace Extension Mapping:" | tee -a "$REPORT_FILE"
    while IFS= read -r ext_id; do
        [ -z "$ext_id" ] && continue
        mapping=$(map_extension "$(echo "$ext_id" | tr '[:upper:]' '[:lower:]')")
        category="${mapping%%|*}"
        guidance="${mapping#*|}"
        printf '  [%-7s] %s\n              -> %s\n' \
            "$category" "$ext_id" "$guidance" | tee -a "$REPORT_FILE"
        tally_category "$category" "extension: $ext_id"
    done < <(jq -r '.[] | "\(.publisher).\(.name)"' "$EXTENSIONS_FILE" | sort -u)
    echo "" | tee -a "$REPORT_FILE"
fi

total_mapped=$((oob_count + market_count + partner_count + custom_count))

if [ "$total_mapped" -gt 0 ]; then
    echo "Integration Effort Summary (counted per distinct integration type," | tee -a "$REPORT_FILE"
    echo "not per instance - solving a type once covers all its instances):" | tee -a "$REPORT_FILE"
    echo "  Out of the box (no work):        $oob_count" | tee -a "$REPORT_FILE"
    echo "  GitHub Marketplace action:       $market_count" | tee -a "$REPORT_FILE"
    echo "  Partner / third-party action:    $partner_count" | tee -a "$REPORT_FILE"
    echo "  Custom build / needs assessment: $custom_count" | tee -a "$REPORT_FILE"

    if [ -s "$CUSTOM_ITEMS_FILE" ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "  Items requiring individual assessment:" | tee -a "$REPORT_FILE"
        sed 's/^/    - /' "$CUSTOM_ITEMS_FILE" | tee -a "$REPORT_FILE"
    fi

    echo "" | tee -a "$REPORT_FILE"
    echo "  CUSTOM items are the ones that need a named owner and an estimate." | tee -a "$REPORT_FILE"
else
    echo "No service connections or extensions detected to map." | tee -a "$REPORT_FILE"
fi

# ========================================
# 15. OPERATING MODEL DENOMINATORS (PLATFORM TEAM SIZING)
# ========================================
write_section "15. Operating Model Denominators (Platform Team Sizing)"

echo "These are the factual denominators a support model is sized against." | tee -a "$REPORT_FILE"
echo "No staffing recommendation is made - that is a commercial decision." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

distinct_pipeline_authors=$(jq '[.[].authoredBy | select(. != null)] | unique | length' "$PIPELINE_DEFS_FILE" 2>/dev/null || echo "0")
distinct_build_requesters=0
if [ -f "$BUILDS_FILE" ] && [ "${total_builds:-0}" -gt 0 ]; then
    distinct_build_requesters=$(jq '[.[].requestedFor | select(. != null)] | unique | length' "$BUILDS_FILE" 2>/dev/null || echo "0")
fi

echo "Estate Scale:" | tee -a "$REPORT_FILE"
echo "  Projects:                         $project_count" | tee -a "$REPORT_FILE"
echo "  Repositories:                     $total_repos" | tee -a "$REPORT_FILE"
echo "  Build pipelines:                  $total_pipelines" | tee -a "$REPORT_FILE"
echo "  Classic release pipelines:        $total_release_defs" | tee -a "$REPORT_FILE"
echo "  Task groups (become actions):     $total_taskgroups" | tee -a "$REPORT_FILE"
echo "  Variable groups:                  $total_vargroups" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Change Volume:" | tee -a "$REPORT_FILE"
echo "  Builds per month:                 ${builds_per_month:-0}" | tee -a "$REPORT_FILE"
echo "  Distinct pipeline authors:        $distinct_pipeline_authors" | tee -a "$REPORT_FILE"
echo "  Distinct build requesters:        $distinct_build_requesters" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Support Surface:" | tee -a "$REPORT_FILE"
echo "  Self-hosted pools to operate:     $selfhosted_pools" | tee -a "$REPORT_FILE"
echo "  Self-hosted agents to patch:      $total_agents" | tee -a "$REPORT_FILE"
echo "  Service connections to re-auth:   ${total_service_connections:-0}" | tee -a "$REPORT_FILE"
echo "  Integrations needing custom work: $custom_count" | tee -a "$REPORT_FILE"
echo "  Active users to support:          ${active_90:-0}" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Use these denominators to compare in-house, partner, and managed" | tee -a "$REPORT_FILE"
echo "service options on the same basis." | tee -a "$REPORT_FILE"

# ========================================
# SUMMARY
# ========================================
write_section "Migration Data Summary"

echo "--- Content & Repositories ---" | tee -a "$REPORT_FILE"
echo "Total Projects: $project_count" | tee -a "$REPORT_FILE"
echo "Total Repositories: $total_repos" | tee -a "$REPORT_FILE"
echo "Large Repositories (>1GB): $large_repos" | tee -a "$REPORT_FILE"
echo "Large Files (>50MB): $total_large_files" | tee -a "$REPORT_FILE"
echo "Repositories with Large Files: $repos_with_large_files" | tee -a "$REPORT_FILE"
echo "Total Work Items: $total_work_items" | tee -a "$REPORT_FILE"
echo "Total Pull Requests: $total_pull_requests" | tee -a "$REPORT_FILE"
echo "Projects with Boards/Teams: $projects_with_boards" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- 1. Infrastructure (Runners) ---" | tee -a "$REPORT_FILE"
echo "Builds (last $HISTORY_DAYS days): ${total_builds:-0}" | tee -a "$REPORT_FILE"
echo "Builds per month: ${builds_per_month:-0}" | tee -a "$REPORT_FILE"
echo "Build minutes per month: ${minutes_per_month:-0}" | tee -a "$REPORT_FILE"
echo "Peak concurrent builds: ${peak_concurrency:-0}" | tee -a "$REPORT_FILE"
echo "Queue wait P95: ${queue_p95:-0}s" | tee -a "$REPORT_FILE"
echo "Self-hosted pools: ${selfhosted_pools:-0}" | tee -a "$REPORT_FILE"
echo "Self-hosted agents: ${total_agents:-0}" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- 2. Licensing ---" | tee -a "$REPORT_FILE"
echo "Total Users: $user_count" | tee -a "$REPORT_FILE"
echo "Active users (90d): ${active_90:-0}" | tee -a "$REPORT_FILE"
echo "Never signed in: ${never_accessed:-0}" | tee -a "$REPORT_FILE"
echo "Stakeholder users (become paid GitHub seats): ${stakeholder_count:-0}" | tee -a "$REPORT_FILE"
echo "Unique committers (GHAS billing unit): ${unique_committers:-0}" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- 3. Migration Effort (ADO transform) ---" | tee -a "$REPORT_FILE"
echo "Total Build Pipelines: $total_pipelines" | tee -a "$REPORT_FILE"
echo "  YAML: ${yaml_pipelines:-0} | Classic: ${classic_pipelines:-0}" | tee -a "$REPORT_FILE"
echo "Dormant pipelines (no runs in ${HISTORY_DAYS}d): ${dead_pipelines:-0}" | tee -a "$REPORT_FILE"
echo "Classic Release Pipelines: ${total_release_defs:-0}" | tee -a "$REPORT_FILE"
echo "Task Groups: ${total_taskgroups:-0}" | tee -a "$REPORT_FILE"
echo "Variable Groups: ${total_vargroups:-0}" | tee -a "$REPORT_FILE"
echo "Repositories with Pipelines: $repos_with_pipelines" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- 4. Integrations & GitHub Apps ---" | tee -a "$REPORT_FILE"
echo "Service Connections: ${total_service_connections:-0}" | tee -a "$REPORT_FILE"
echo "Marketplace Extensions: ${total_extensions:-0}" | tee -a "$REPORT_FILE"
echo "Service Hooks: $total_hooks" | tee -a "$REPORT_FILE"
echo "Mapped out-of-the-box: ${oob_count:-0}" | tee -a "$REPORT_FILE"
echo "Mapped to Marketplace action: ${market_count:-0}" | tee -a "$REPORT_FILE"
echo "Mapped to Partner App: ${partner_count:-0}" | tee -a "$REPORT_FILE"
echo "Needing custom work: ${custom_count:-0}" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- 5. Operating Model Denominators ---" | tee -a "$REPORT_FILE"
echo "Distinct pipeline authors: ${distinct_pipeline_authors:-0}" | tee -a "$REPORT_FILE"
echo "Distinct build requesters: ${distinct_build_requesters:-0}" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "--- Security Posture ---" | tee -a "$REPORT_FILE"
echo "Total Secret Scanning Alerts: $total_secret_alerts" | tee -a "$REPORT_FILE"
echo "Total Dependency Scanning Alerts: $total_dependency_alerts" | tee -a "$REPORT_FILE"
echo "Total Code Scanning Alerts: $total_code_alerts" | tee -a "$REPORT_FILE"
echo "Repositories with Security Alerts: $repos_with_alerts" | tee -a "$REPORT_FILE"

# ========================================
# MACHINE-READABLE SIZING EXPORT
# ========================================
# Emitted as a single JSON document so a cost model can consume the figures
# directly instead of scraping the text report.
jq -n \
  --arg org "$ORG" \
  --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson historyDays "$(num "${HISTORY_DAYS:-90}")" \
  --arg historyStart "${HISTORY_START:-}" \
  --argjson projects "${project_count:-0}" \
  --argjson repos "${total_repos:-0}" \
  --argjson largeRepos "${large_repos:-0}" \
  --argjson largeFiles "${total_large_files:-0}" \
  --argjson workItems "${total_work_items:-0}" \
  --argjson pullRequests "${total_pull_requests:-0}" \
  --argjson totalBuilds "${total_builds:-0}" \
  --argjson buildsPerMonth "${builds_per_month:-0}" \
  --argjson minutesPerMonth "${minutes_per_month:-0}" \
  --argjson totalBuildMinutes "${total_build_minutes:-0}" \
  --argjson peakConcurrency "${peak_concurrency:-0}" \
  --argjson queueP50 "${queue_p50:-0}" \
  --argjson queueP95 "${queue_p95:-0}" \
  --argjson totalPools "${total_pools:-0}" \
  --argjson hostedPools "${hosted_pools:-0}" \
  --argjson selfHostedPools "${selfhosted_pools:-0}" \
  --argjson totalAgents "${total_agents:-0}" \
  --argjson onlineAgents "${online_agents:-0}" \
  --argjson totalUsers "${user_count:-0}" \
  --argjson active30 "${active_30:-0}" \
  --argjson active60 "${active_60:-0}" \
  --argjson active90 "${active_90:-0}" \
  --argjson neverAccessed "${never_accessed:-0}" \
  --argjson stakeholders "${stakeholder_count:-0}" \
  --argjson basicUsers "${basic_count:-0}" \
  --argjson vsSubscribers "${vs_subscriber_count:-0}" \
  --argjson serviceAccounts "${service_account_count:-0}" \
  --argjson uniqueCommitters "${unique_committers:-0}" \
  --argjson totalPipelines "${total_pipelines:-0}" \
  --argjson yamlPipelines "${yaml_pipelines:-0}" \
  --argjson classicPipelines "${classic_pipelines:-0}" \
  --argjson disabledPipelines "${disabled_pipelines:-0}" \
  --argjson activePipelines "${active_pipelines:-0}" \
  --argjson deadPipelines "${dead_pipelines:-0}" \
  --argjson releaseDefs "${total_release_defs:-0}" \
  --argjson taskGroups "${total_taskgroups:-0}" \
  --argjson variableGroups "${total_vargroups:-0}" \
  --argjson variables "${total_variables:-0}" \
  --argjson serviceConnections "${total_service_connections:-0}" \
  --argjson extensions "${total_extensions:-0}" \
  --argjson serviceHooks "${total_hooks:-0}" \
  --argjson mapOob "${oob_count:-0}" \
  --argjson mapMarket "${market_count:-0}" \
  --argjson mapPartner "${partner_count:-0}" \
  --argjson mapCustom "${custom_count:-0}" \
  --argjson pipelineAuthors "${distinct_pipeline_authors:-0}" \
  --argjson buildRequesters "${distinct_build_requesters:-0}" \
  --argjson secretAlerts "${total_secret_alerts:-0}" \
  --argjson dependencyAlerts "${total_dependency_alerts:-0}" \
  --argjson codeAlerts "${total_code_alerts:-0}" \
  --slurpfile buildStats "${BUILD_STATS_FILE:-/dev/null}" \
  --slurpfile connTypes <(jq 'group_by(.type) | map({type: .[0].type, count: length}) | sort_by(-.count)' "${SERVICE_CONN_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile extList <(jq 'map({publisher, name})' "${EXTENSIONS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile warnList <(jq -R -s 'split("\n") | map(select(length > 0))' "${WARNINGS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  '{
    meta: {
      organization: $org,
      generatedUtc: $generated,
      historyWindowDays: $historyDays,
      historyStart: $historyStart,
      dataComplete: ((($warnList[0] // []) | length) == 0),
      warnings: ($warnList[0] // []),
      schemaVersion: "1.0"
    },
    content: {
      projects: $projects,
      repositories: $repos,
      repositoriesOver1Gb: $largeRepos,
      filesOver50Mb: $largeFiles,
      workItems: $workItems,
      pullRequests: $pullRequests
    },
    infrastructure: {
      buildsInWindow: $totalBuilds,
      buildsPerMonth: $buildsPerMonth,
      computeMinutesInWindow: $totalBuildMinutes,
      computeMinutesPerMonth: $minutesPerMonth,
      peakConcurrentBuilds: $peakConcurrency,
      queueWaitP50Seconds: $queueP50,
      queueWaitP95Seconds: $queueP95,
      agentPools: { total: $totalPools, microsoftHosted: $hostedPools, selfHosted: $selfHostedPools },
      selfHostedAgents: { registered: $totalAgents, online: $onlineAgents },
      byPool: ($buildStats[0].byPool // []),
      durationStats: {
        averageMinutes: ($buildStats[0].avgDurationMinutes // 0),
        medianMinutes: ($buildStats[0].medianDurationMinutes // 0),
        p95Minutes: ($buildStats[0].p95DurationMinutes // 0)
      },
      resultBreakdown: ($buildStats[0].resultBreakdown // [])
    },
    licensing: {
      totalUsers: $totalUsers,
      activeUsers30d: $active30,
      activeUsers60d: $active60,
      activeUsers90d: $active90,
      neverSignedIn: $neverAccessed,
      stakeholderUsers: $stakeholders,
      basicUsers: $basicUsers,
      visualStudioSubscribers: $vsSubscribers,
      likelyServiceAccounts: $serviceAccounts,
      uniqueCommitters: $uniqueCommitters
    },
    migrationEffort: {
      buildPipelines: {
        total: $totalPipelines,
        yaml: $yamlPipelines,
        classic: $classicPipelines,
        disabled: $disabledPipelines,
        activeInWindow: $activePipelines,
        dormant: $deadPipelines
      },
      releasePipelines: $releaseDefs,
      taskGroups: $taskGroups,
      variableGroups: { count: $variableGroups, variables: $variables }
    },
    integrations: {
      serviceConnections: $serviceConnections,
      serviceConnectionTypes: ($connTypes[0] // []),
      marketplaceExtensions: $extensions,
      extensionList: ($extList[0] // []),
      serviceHooks: $serviceHooks,
      effortMapping: {
        outOfTheBox: $mapOob,
        marketplaceAction: $mapMarket,
        partnerApp: $mapPartner,
        customWork: $mapCustom
      }
    },
    operatingModel: {
      distinctPipelineAuthors: $pipelineAuthors,
      distinctBuildRequesters: $buildRequesters,
      selfHostedPoolsToOperate: $selfHostedPools,
      selfHostedAgentsToPatch: $totalAgents,
      serviceConnectionsToReauth: $serviceConnections,
      integrationsNeedingCustomWork: $mapCustom,
      activeUsersToSupport: $active90
    },
    security: {
      secretScanningAlerts: $secretAlerts,
      dependencyScanningAlerts: $dependencyAlerts,
      codeScanningAlerts: $codeAlerts
    }
  }' > "$SIZING_JSON" 2>/dev/null

if [ ! -s "$SIZING_JSON" ]; then
    echo "WARNING: Failed to generate structured JSON export" | tee -a "$REPORT_FILE"
    rm -f "$SIZING_JSON"
fi

echo "" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
echo "DATA COMPLETENESS" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
warn_count=$(num "$(grep -c . "$WARNINGS_FILE" 2>/dev/null)")
if [ "$warn_count" -eq 0 ]; then
    echo "No collection warnings. All figures reflect a complete read of the" | tee -a "$REPORT_FILE"
    echo "data this account has permission to see." | tee -a "$REPORT_FILE"
else
    echo "$warn_count warning(s) were raised during collection. Some figures below" | tee -a "$REPORT_FILE"
    echo "are a LOWER BOUND - do not size infrastructure from them without re-running:" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    while IFS= read -r w; do
        [ -n "$w" ] && echo "  - $w" | tee -a "$REPORT_FILE"
    done < "$WARNINGS_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
echo "Report generation complete!" | tee -a "$REPORT_FILE"
echo "Report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
[ -s "$SIZING_JSON" ] && echo "Structured sizing data saved to: $SIZING_JSON" | tee -a "$REPORT_FILE"
[ -s "$USER_CSV" ] && echo "User export saved to: $USER_CSV" | tee -a "$REPORT_FILE"
if [ "$total_secret_alerts" -gt 0 ] && [ -f "$SECRET_SCANNING_REPORT" ]; then
    echo "Secret scanning details saved to: $SECRET_SCANNING_REPORT" | tee -a "$REPORT_FILE"
    echo "Secret scanning CSV saved to: $SECRET_SCANNING_CSV" | tee -a "$REPORT_FILE"
    echo "Secret scanning JSON saved to: $SECRET_SCANNING_JSON" | tee -a "$REPORT_FILE"
fi
echo "" | tee -a "$REPORT_FILE"
echo "NEXT STEP: run 'gh actions-importer audit azure-devops' for per-pipeline" | tee -a "$REPORT_FILE"
echo "conversion rates and unsupported-task detail. This report sizes the" | tee -a "$REPORT_FILE"
echo "runner spend, seat count and integration surface that the Importer" | tee -a "$REPORT_FILE"
echo "audit does not cover." | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"

# Temp directory will be automatically cleaned up by trap on exit
