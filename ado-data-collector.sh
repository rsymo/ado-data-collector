#!/bin/bash

# ========================================
# Azure DevOps Data Collector
# ========================================
# This script builds a read-only inventory of an Azure DevOps organization:
# what exists, what is actually being used, and what the platform team
# operates. It is useful for estate review, cleanup and consolidation work on
# its own.
#
# Because the most common reason to inventory an estate is to evaluate a move,
# later sections additionally express pipeline usage in units that can be
# compared against other CI providers - notably job-level minutes and the
# operating-system mix, which is how GitHub Actions bills. Nothing is priced;
# the collector reports quantities only.
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
# Set SKIP_TIMELINE=1 to skip per-build timeline collection. Timelines are the
# only source of JOB-level durations, the unit per-job models bill on.
# Leave it enabled unless the run must be fast.
SKIP_TIMELINE=${SKIP_TIMELINE:-0}
# Ceiling on how many builds have their timeline fetched. The collector samples
# evenly across the collected build history when the estate is larger than this,
# then extrapolates. Raising it improves precision at the cost of one extra API
# call per additional build.
TIMELINE_SAMPLE_MAX=${TIMELINE_SAMPLE_MAX:-1500}
# Cost multipliers used to convert the observed operating-system mix into a
# single Linux-equivalent figure. These default to the GitHub-hosted standard
# runner ratios published at the time of writing. Rates change and vary by
# plan and runner size, so confirm them against current pricing and override
# here if they differ.
# Per-user detail (display names and email addresses) is personal data and is
# never needed to size an estate. Set EXPORT_USER_DETAILS=1 to additionally
# write the per-user CSV for internal use; by default only counts are produced.
EXPORT_USER_DETAILS=${EXPORT_USER_DETAILS:-0}
# Secret scanning detail identifies the file path, line number and branch where
# each credential was detected. That is security-sensitive: it is a map of where
# the unremediated secrets are. Alert COUNTS are always reported; set
# EXPORT_SECRET_DETAILS=1 to additionally write the per-alert files, which also
# costs one extra API call per alert.
EXPORT_SECRET_DETAILS=${EXPORT_SECRET_DETAILS:-0}

# HTTP behaviour. Azure DevOps allows 200 TSTUs per sliding five-minute window
# per identity; a large estate is thousands of sequential calls, so being
# throttled at some point is normal rather than exceptional.
#   API_RETRIES        attempts after the first for a retryable failure. curl
#                      honours the Retry-After header Azure DevOps returns.
#   API_RETRY_MAX_TIME ceiling in seconds on the total time ONE call may spend
#                      retrying. Without it a long Retry-After multiplied by the
#                      retry count can stall a run for minutes per request.
#   API_PACING_MS      fixed delay inserted before every request. Normally 0;
#                      raise it to be deliberately gentle on a busy organization.
#                      Pacing also escalates automatically once throttling starts.
API_RETRIES=${API_RETRIES:-5}
API_RETRY_MAX_TIME=${API_RETRY_MAX_TIME:-120}
API_PACING_MS=${API_PACING_MS:-0}
MULT_LINUX=${MULT_LINUX:-1}
MULT_WINDOWS=${MULT_WINDOWS:-2}
MULT_MACOS=${MULT_MACOS:-10}
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

for _tool in az jq curl; do
    if ! command -v "$_tool" &> /dev/null; then
        echo "ERROR: Required tool is not installed: $_tool" >&2
        exit 1
    fi
done
unset _tool

# Validate numeric configuration up front. Unlike an API failure - which must
# degrade to zero so a partial report is still produced - a malformed setting is
# a caller error that would otherwise yield a confident-looking report built on
# a nonsense window (e.g. HISTORY_DAYS=abc silently becoming a 0-day window).
# Fail fast so the mistake is corrected before anyone relies on the numbers.
for _cfg in HISTORY_DAYS MAX_BUILDS_PER_PROJECT TOKEN_MAX_AGE TIMELINE_SAMPLE_MAX API_RETRY_MAX_TIME; do
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

# These two may legitimately be zero (no retries, no pacing), so they are
# checked for "non-negative integer" rather than reusing the loop above.
for _cfg in API_RETRIES API_PACING_MS; do
    eval "_val=\${$_cfg}"
    case "$_val" in
        ''|*[!0-9]*)
            echo "ERROR: $_cfg must be a non-negative integer (got: '$_val')" >&2
            exit 1
            ;;
    esac
done
unset _cfg _val

# Cost multipliers are validated separately: they may legitimately be decimals
# (a plan or runner size whose ratio is not a whole number), but a zero or
# negative value would silently collapse the Linux-equivalent figure to nothing.
for _cfg in MULT_LINUX MULT_WINDOWS MULT_MACOS; do
    eval "_val=\${$_cfg}"
    case "$_val" in
        ''|*[!0-9.]*|*.*.*|.|*.)
            echo "ERROR: $_cfg must be a positive number (got: '$_val')" >&2
            exit 1
            ;;
    esac
    case "$_val" in
        0|0.|0.0|0.00|.0|.00)
            echo "ERROR: $_cfg must be greater than zero (got: '$_val')" >&2
            exit 1
            ;;
    esac
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
    local new_token=$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null </dev/null)
    if [ -n "$new_token" ]; then
        ADO_TOKEN="$new_token"
        # Recreate curl config with new token
        create_curl_config
        TOKEN_ISSUED_AT=$(date +%s)
        echo "$TOKEN_ISSUED_AT" > "$TOKEN_STATE_FILE"
        [ "$DEBUG" = "1" ] && echo "[DEBUG] Token refreshed successfully" >&2
    else
        # Back off ~60s before trying again instead of leaving the clock stale.
        # Without this a broken `az` would be re-invoked on every subsequent
        # request for the rest of the run.
        echo "$(( $(date +%s) - TOKEN_MAX_AGE + 60 ))" > "$TOKEN_STATE_FILE"
        [ "$DEBUG" = "1" ] && echo "[DEBUG] WARNING: Failed to refresh token, continuing with existing token" >&2
    fi
}

# Refresh the token only when it is old enough to be worth replacing.
# Called at the start of every section so long runs never fail mid-collection
# on an expired token (Azure AD tokens last ~60 minutes).
TOKEN_ISSUED_AT=$(date +%s)
TOKEN_MAX_AGE=${TOKEN_MAX_AGE:-2400}

# The token clock lives in a file, not just a variable. Requests are made inside
# command substitution, so a refresh triggered by a request happens in a
# subshell: the refreshed token itself propagates (it is written to the curl
# config file), but a variable holding the issue time would not, and every later
# request would then re-invoke `az`. This matters more now that a throttled run
# can spend far longer inside a single section than the token's lifetime.
TOKEN_STATE_FILE="$TEMP_DATA_DIR/token_issued_at"
echo "$TOKEN_ISSUED_AT" > "$TOKEN_STATE_FILE"

maybe_refresh_token() {
    local now age issued
    now=$(date +%s)
    issued=$(cat "$TOKEN_STATE_FILE" 2>/dev/null); : "${issued:=$TOKEN_ISSUED_AT}"
    age=$((now - issued))
    if [ "$age" -ge "$TOKEN_MAX_AGE" ]; then
        refresh_token
    fi
}

# -------- HTTP TRANSPORT --------
#
# Every request goes through _http_exec, which exists to make one distinction
# the original implementation could not: WHY a request failed.
#
# curl -f was removed deliberately. It suppresses the response body and exits 22
# for every HTTP error alike, so a 429 ("slow down, try again") looked identical
# to a 403 ("you will never be allowed to read this"). Those demand opposite
# responses from the operator, and silently reporting a throttled endpoint as a
# genuine zero is the most expensive mistake this tool can make. Status handling
# is therefore explicit here: anything outside 2xx becomes API_ERROR, exactly as
# before, but the status is recorded first.
#
# Throttling behaviour:
#   - Azure DevOps returns Retry-After on 429 and curl honours it natively.
#   - --retry-max-time bounds the total time a single call may spend retrying,
#     so one long Retry-After cannot stall the run for minutes.
#   - Every 429 escalates a process-wide inter-request delay, so a run that
#     starts being throttled backs off instead of continuing to push against
#     the limit.
#
# State lives in files, not variables: call_api is invoked through command
# substitution, and a subshell cannot report anything back through a variable.

HTTP_STATE_DIR="$TEMP_DATA_DIR/http"
mkdir -p "$HTTP_STATE_DIR" 2>/dev/null
HTTP_LAST_STATUS_FILE="$HTTP_STATE_DIR/last_status"
HTTP_STATUS_LOG="$HTTP_STATE_DIR/status_log"      # one non-2xx status per line
HTTP_THROTTLE_FILE="$HTTP_STATE_DIR/throttle_count"
: > "$HTTP_STATUS_LOG"
echo 0 > "$HTTP_THROTTLE_FILE"
echo 0 > "$HTTP_LAST_STATUS_FILE"

http_throttle_count() { cat "$HTTP_THROTTLE_FILE" 2>/dev/null || echo 0; }
http_last_status()    { cat "$HTTP_LAST_STATUS_FILE" 2>/dev/null || echo 0; }

# Plain-language cause for a status code. Used to make warnings actionable:
# "rate-limited" and "permission denied" need completely different responses.
http_status_hint() {
    case "$1" in
        429)     echo "rate-limited by Azure DevOps (HTTP 429) - the figure may be incomplete" ;;
        401)     echo "authentication failed or the token expired (HTTP 401)" ;;
        403)     echo "permission denied (HTTP 403)" ;;
        404)     echo "not found (HTTP 404) - the resource or API version may not exist here" ;;
        5??)     echo "Azure DevOps server error (HTTP $1)" ;;
        000|0|"") echo "network failure, timeout, or no response" ;;
        *)       echo "HTTP $1" ;;
    esac
}

# Inter-request delay in seconds. Starts at API_PACING_MS and escalates as
# throttling is observed, so the run slows itself down rather than being
# throttled harder. It never decreases: once an organization has shown it will
# throttle this identity, backing off again would just re-trigger it.
_http_pace() {
    local throttles base
    throttles=$(http_throttle_count)
    base="$API_PACING_MS"
    if   [ "$throttles" -ge 11 ]; then [ "$base" -lt 2000 ] && base=2000
    elif [ "$throttles" -ge 6 ];  then [ "$base" -lt 1000 ] && base=1000
    elif [ "$throttles" -ge 3 ];  then [ "$base" -lt 500 ]  && base=500
    elif [ "$throttles" -ge 1 ];  then [ "$base" -lt 250 ]  && base=250
    fi
    [ "$base" -le 0 ] && return 0
    # Integer milliseconds -> fractional seconds without needing bc.
    sleep "$((base / 1000)).$(printf '%03d' "$((base % 1000))")" 2>/dev/null
}

# Core transport. Echoes the response body, or the literal API_ERROR.
#   $1 url   $2 max-time   $3 header dump file ("" for none)
#   $4 method (GET|POST)   $5 POST body ("" for none)   $6 follow redirects (1|0)
_http_exec() {
    local url="$1" max_time="$2" hdr_file="$3" method="$4" data="$5" follow="$6"
    local status rc body_file
    local -a opts=()

    # Defence in depth. Both callers already assert before calling, but this is
    # now the single point through which every request in the tool passes, so
    # re-asserting here means a future caller cannot bypass the read-only
    # guarantee by forgetting to. Both assertions are idempotent.
    if [ "$method" = "POST" ]; then
        assert_read_only_query_url "$url"
    else
        assert_read_only_url "$url"
    fi

    # A long, throttled section can now outlive the token, so the check happens
    # per request rather than only at section boundaries.
    maybe_refresh_token
    _http_pace

    body_file=$(mktemp "$HTTP_STATE_DIR/body.XXXXXX") || { echo "API_ERROR"; return 0; }

    [ "$follow" = "1" ] && opts+=(-L)
    [ -n "$hdr_file" ] && opts+=(-D "$hdr_file")
    if [ "$method" = "POST" ]; then
        opts+=(-H "Content-Type: application/json" -X POST -d "$data")
    else
        opts+=(-X GET)
    fi

    # stdin is closed so a call made inside a `while read` loop cannot consume
    # the loop's input.
    status=$(curl -s --max-time "$max_time" \
        --retry "$API_RETRIES" --retry-delay 1 --retry-max-time "$API_RETRY_MAX_TIME" \
        "${CURL_SAFE_OPTS[@]}" \
        --config "$CURL_CONFIG_FILE" \
        "${opts[@]}" \
        -o "$body_file" -w '%{http_code}' \
        "$url" 2>/dev/null </dev/null)
    rc=$?
    [ -z "$status" ] && status=0

    echo "$status" > "$HTTP_LAST_STATUS_FILE"

    case "$status" in
        2??)
            cat "$body_file"
            rm -f "$body_file"
            return 0
            ;;
    esac

    # Record the failure class so the end of the run can explain what went wrong
    # rather than leaving a wall of zeros with no cause.
    echo "$status" >> "$HTTP_STATUS_LOG"
    if [ "$status" = "429" ]; then
        echo "$(( $(http_throttle_count) + 1 ))" > "$HTTP_THROTTLE_FILE"
        [ "$DEBUG" = "1" ] && echo "[DEBUG] throttled (429), pacing escalated: $url" >&2
    fi
    [ "$DEBUG" = "1" ] && echo "[DEBUG] HTTP $status (curl rc=$rc): $url" >&2

    rm -f "$body_file"
    echo "API_ERROR"
    return 0
}

# Function to make Azure DevOps API calls (GET requests)
# Uses secure curl config file to avoid token exposure in process listings.
# The method is pinned to GET with -X so that accidentally adding a body flag
# (-d/--data) later cannot silently promote this to a POST.
call_api() {
    local endpoint="$1"
    assert_read_only_url "$endpoint"
    [ "$DEBUG" = "1" ] && echo "[DEBUG] GET: $endpoint" >&2
    _http_exec "$endpoint" 30 "" GET "" 1
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
    # Redirects are NOT followed here (final argument 0). This is the only
    # request in the tool that carries a body, and replaying that body against
    # a redirect target would send the query somewhere the read-only allow-list
    # never vetted.
    _http_exec "$endpoint" 30 "" POST "$data" 0
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

# Decimal-safe counterpart to num(). Ratios and averages are not integers, and
# num() would silently flatten them to zero, so any fractional value bound with
# --argjson must pass through here instead.
numf() {
    local v
    v=$(printf '%s' "${1:-0}" | tr -d '[:space:]')
    case "$v" in
        ''|*[!0-9.]*|*.*.*|.|*.) echo "0" ;;
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
        body=$(_http_exec "$url" 60 "$hdr_file" GET "" 1)

        # A failure here is invisible to the caller: it just receives fewer
        # records, or none. Both cases must be recorded, because a permission
        # boundary and a genuine zero are indistinguishable downstream - and
        # reporting "0 service connections to migrate" when the account simply
        # could not read them is the most expensive mistake this tool can make.
        if [ "$body" = "API_ERROR" ] || ! echo "$body" | jq empty 2>/dev/null; then
            local why
            why=$(http_status_hint "$(http_last_status)")
            if [ "$page" -gt 0 ]; then
                report_warn "Pagination failed on page $page for ${endpoint%%\?*} - $why - results are TRUNCATED"
            else
                report_warn "No data read from ${endpoint%%\?*} - $why. This section reads as ZERO; confirm it is genuinely zero before sizing from it."
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
            if [ "$page" -gt 0 ]; then
                report_warn "Pagination failed on page $page for ${endpoint%%\?*} - results are TRUNCATED"
            else
                report_warn "No data read from ${endpoint%%\?*} - the request failed (auth, permission, or endpoint unavailable). This section reads as ZERO; confirm it is genuinely zero before sizing from it."
            fi
            break
        fi

        local n
        n=$(echo "$body" | jq -r "${jq_path} | length" 2>/dev/null || echo "0")
        case "$n" in
            ''|*[!0-9]*)
                report_warn "Unexpected pagination response from ${endpoint%%\?*} - results are TRUNCATED"
                break
                ;;
        esac
        [ "$n" -eq 0 ] && break

        echo "$body" | jq -c "${jq_path}[]?" 2>/dev/null

        # A short page means we've reached the end
        [ "$n" -lt "$page_size" ] && break
        skip=$((skip + page_size))
        page=$((page + 1))
    done

    if [ "$page" -ge "$max_pages" ]; then
        report_warn "Hit page limit ($max_pages) for ${endpoint%%\?*} - results may be truncated"
    fi
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
    
    # Repository listings are capped, so drain continuation-token pages instead
    # of silently undercounting large projects.
    project_repos_ndjson="$TEMP_DATA_DIR/repos_${project_count}.ndjson"
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/git/repositories?api-version=$API_VERSION" \
        '.value' > "$project_repos_ndjson"

    repo_count=$(wc -l < "$project_repos_ndjson" | tr -d ' ')
    total_repos=$((total_repos + repo_count))
    
    # Store repo details for later analysis, including project visibility
    # Use jq --arg to safely pass project name and visibility (handles quotes and backslashes)
    jq -c --arg proj "$project" --arg vis "$project_visibility" \
        '{project: $proj, projectVisibility: $vis, name: .name, id: .id, size: .size, defaultBranch: .defaultBranch, remoteUrl: .remoteUrl}' \
        "$project_repos_ndjson" >> "$REPO_DETAILS_FILE.tmp" 2>/dev/null
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
            repo_id=$(echo "$repo" | jq -r '.id')
            
            [ "$DEBUG" = "1" ] && echo "  Scanning $project/$repo_name..." | tee -a "$REPORT_FILE"
            
            # URL encode project name for clone URL
            project_encoded=$(url_encode "$project")
            
            # Create temp directory for this repo
            repo_temp_dir="$ORIGINAL_DIR/$TEMP_DATA_DIR/scan_${repo_id}_$$"
            mkdir -p "$repo_temp_dir"
            cd "$repo_temp_dir"
            
            # Clone as bare repository (faster, includes all history)
            # Use Azure AD Bearer token with http.extraHeader for authentication, securely via a temporary file
            header_file="$repo_temp_dir/git_header.txt"
            repo_encoded=$(url_encode "$repo_name")
            clone_url="https://dev.azure.com/$ORG/$project_encoded/_git/$repo_encoded"
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
                # committer counts are a common licensing unit for security tooling,
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
        echo "NOTE: most Git hosts enforce a per-file size limit, commonly a" | tee -a "$REPORT_FILE"
        echo "warning around 50MB and a hard block around 100MB. Large binaries" | tee -a "$REPORT_FILE"
        echo "also slow every clone and fetch. Git LFS is the usual remedy." | tee -a "$REPORT_FILE"
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
    echo "Why this matters:" | tee -a "$REPORT_FILE"
    echo "  - most Git hosts warn above ~50MB and block above ~100MB per file" | tee -a "$REPORT_FILE"
    echo "  - large binaries slow every clone, fetch and CI checkout" | tee -a "$REPORT_FILE"
    echo "  - Git LFS is the usual remedy for binary files and large assets" | tee -a "$REPORT_FILE"
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
write_section "7. Work Items, Pull Requests & Project Metadata"

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
                # Pull-request listings are paginated; count every returned
                # object rather than trusting the first page's count.
                pr_count=$(call_api_paged \
                    "$ORG_URL/$project_encoded/_apis/git/repositories/$repo_id/pullrequests?api-version=$API_VERSION" \
                    '.value' | jq -s 'length')
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

    # Task groups rarely port directly - each becomes a reusable unit
    # or reusable workflow, so the count is a direct effort input.
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/taskgroups?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{project: $proj, id: .id, name: (.name // null)}' \
        >> "$TEMP_DATA_DIR/taskgroups.ndjson" 2>/dev/null

    # Variable groups map to Actions variables / environment secrets. The secret
    # count is separated because secrets cannot be exported from Azure DevOps -
    # every one is a manual re-entry during migration, so it is an effort input
    # in its own right rather than just a variable count.
    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/variablegroups?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            id: .id,
            name: (.name // null),
            variableCount: ((.variables // {}) | length),
            secretCount: ((.variables // {}) | to_entries
                          | map(select((.value.isSecret // false) == true)) | length),
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
total_secret_variables=$(jq '[.[].secretCount] | add // 0' "$VARGROUPS_FILE")
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
echo "  Secret variables (manual re-entry on migration): $total_secret_variables" | tee -a "$REPORT_FILE"
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
    
    # Initialize secret scanning detail files only when explicitly requested.
    # Alert counts are collected either way.
    if [ "$EXPORT_SECRET_DETAILS" = "1" ]; then
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
    fi
    
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
                    
                    # Export detailed secret scanning information if alerts are
                    # found AND per-alert detail was explicitly requested.
                    if [ "$secret_count" -gt 0 ] && [ "$EXPORT_SECRET_DETAILS" = "1" ]; then
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
        if [ "$EXPORT_SECRET_DETAILS" = "1" ]; then
            echo "Detailed secret scanning report saved to: $SECRET_SCANNING_REPORT" | tee -a "$REPORT_FILE"
            echo "Secret scanning CSV (Excel-compatible) saved to: $SECRET_SCANNING_CSV" | tee -a "$REPORT_FILE"
            echo "Secret scanning JSON (machine-readable) saved to: $SECRET_SCANNING_JSON" | tee -a "$REPORT_FILE"
            echo "  These files record WHERE each credential was found (file path," | tee -a "$REPORT_FILE"
            echo "  line and branch), never the value. Treat them as security-" | tee -a "$REPORT_FILE"
            echo "  sensitive and share only with the remediation team." | tee -a "$REPORT_FILE"
        else
            echo "Per-alert detail was NOT exported. The counts above are all that" | tee -a "$REPORT_FILE"
            echo "  estate review requires. Set EXPORT_SECRET_DETAILS=1 to write the" | tee -a "$REPORT_FILE"
            echo "  file paths and line numbers for the remediation team." | tee -a "$REPORT_FILE"
        fi
    fi
else
    echo "Advanced Security is NOT enabled for this organization" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "NOTE: Azure DevOps Advanced Security is a paid add-on feature that includes:" | tee -a "$REPORT_FILE"
    echo "  - Secret scanning (credentials, tokens, keys)" | tee -a "$REPORT_FILE"
    echo "  - Dependency scanning (vulnerable packages)" | tee -a "$REPORT_FILE"
    echo "  - Code scanning (security vulnerabilities)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "If scanning coverage is a requirement, it is currently being met by" | tee -a "$REPORT_FILE"
    echo "third-party tooling in the pipelines, or not at all. Section 10 lists" | tee -a "$REPORT_FILE"
    echo "the security extensions actually in use." | tee -a "$REPORT_FILE"
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
    # carried into the seat count on a platform without a free tier.
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
    echo "  NOTE: Stakeholder access is free in Azure DevOps. Most other" | tee -a "$REPORT_FILE"
    echo "  platforms have no equivalent free tier, so Stakeholders who still" | tee -a "$REPORT_FILE"
    echo "  need access can convert to paid seats under a different licensing" | tee -a "$REPORT_FILE"
    echo "  model. They are counted separately here so seat planning can test" | tee -a "$REPORT_FILE"
    echo "  that assumption rather than inherit it." | tee -a "$REPORT_FILE"

    # Per-user detail is personal data (names and email addresses) and is not
    # needed for estate sizing or cost modelling - the counts above already
    # cover that. It is therefore opt-in, so the default output of this script
    # can be shared without disclosing who works at the organization.
    if [ "$EXPORT_USER_DETAILS" = "1" ]; then
        # Written to the working directory so it survives the temp-directory
        # cleanup trap.
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
        echo "  This file contains PERSONAL DATA (names and email addresses)." | tee -a "$REPORT_FILE"
        echo "  Keep it internal. It is not required for estate sizing." | tee -a "$REPORT_FILE"
    else
        echo "" | tee -a "$REPORT_FILE"
        echo "  Per-user detail (names, email addresses) was NOT exported." | tee -a "$REPORT_FILE"
        echo "  The counts above are all that estate sizing requires. Set" | tee -a "$REPORT_FILE"
        echo "  EXPORT_USER_DETAILS=1 to write the per-user CSV for internal use." | tee -a "$REPORT_FILE"
    fi
else
    echo "WARNING: No user entitlement data retrieved." | tee -a "$REPORT_FILE"
    echo "  This usually means the account lacks Member Entitlement Management" | tee -a "$REPORT_FILE"
    echo "  permissions on the organization." | tee -a "$REPORT_FILE"
fi

# Unique committers over the history window - a common licensing unit for
# security and code-quality tooling. Only available when repositories were cloned.
unique_committers=0
if [ "$SCAN_LARGE_FILES" = "1" ] && [ -f "$TEMP_DATA_DIR/committers.txt" ]; then
    # `grep -c .` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback
    # would fire in addition to grep's own output and yield the two-line string
    # "0\n0" - which later aborts the whole `jq -n --argjson` export.
    unique_committers=$(LC_ALL=C sort -u "$TEMP_DATA_DIR/committers.txt" | grep -c . )
    unique_committers=$(num "$unique_committers")
    echo "" | tee -a "$REPORT_FILE"
    echo "Unique Committers (last $HISTORY_DAYS days): $unique_committers" | tee -a "$REPORT_FILE"
    echo "  Security and code-quality products are often licensed per active" | tee -a "$REPORT_FILE"
    echo "  committer rather than per user, so this is usually a smaller and" | tee -a "$REPORT_FILE"
    echo "  more accurate seat count than total provisioned users." | tee -a "$REPORT_FILE"
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
avg_concurrency=0
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
                id: .id,
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
                avgConcurrency: (
                    (($totalSec / ($days * 86400)) * 100 | floor) / 100),
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
        avg_concurrency=$(jq -r '.avgConcurrency // 0' "$BUILD_STATS_FILE")

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
        echo "  Average concurrent builds:       $avg_concurrency" | tee -a "$REPORT_FILE"
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
        echo "SIZING CAVEAT: the minutes above are BUILD wall-clock time, which is" | tee -a "$REPORT_FILE"
        echo "  not the unit per-job billing models charge on. Those bill per JOB" | tee -a "$REPORT_FILE"
        echo "  and round each job up to a whole minute, so a build running" | tee -a "$REPORT_FILE"
        echo "  four jobs in parallel bills roughly four times its wall-clock." | tee -a "$REPORT_FILE"
        echo "  Multipliers then apply (Windows ${MULT_WINDOWS}x, macOS ${MULT_MACOS}x against Linux)." | tee -a "$REPORT_FILE"
        echo "  Section 16 measures the job-level figure; section 17 measures the" | tee -a "$REPORT_FILE"
        echo "  operating-system mix that drives the multiplier. Use those two" | tee -a "$REPORT_FILE"
        echo "  sections for cost modelling, not the wall-clock total above." | tee -a "$REPORT_FILE"
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

    call_api_paged "$ORG_URL/_apis/distributedtask/pools/$pool_id/agents?includeCapabilities=true&api-version=$API_VERSION" '.value' \
        | jq -c --arg pool "$pool_name" '
            (.systemCapabilities // {}) as $c
            | {
                pool: $pool,
                name: (.name // "unknown"),
                osDescription: (.osDescription // "unknown"),
                enabled: (.enabled // false),
                status: (.status // "unknown"),
                version: (.version // null),
                cpuCount: (($c["NUMBER_OF_PROCESSORS"] // $c["Agent.CPUCount"] // null)
                           | if . == null then null else (tonumber? // null) end),
                osArch: ($c["Agent.OSArchitecture"] // null),
                osVersion: ($c["Agent.OSVersion"] // null)
              }' >> "$TEMP_DATA_DIR/agents.ndjson" 2>/dev/null
done < <(jq -c '.[] | select(.isHosted != true)' "$POOLS_FILE" 2>/dev/null)

ndjson_to_array "$TEMP_DATA_DIR/agents.ndjson" "$AGENTS_FILE"

total_agents=$(jq 'length' "$AGENTS_FILE")
online_agents=$(jq '[.[] | select(.status == "online")] | length' "$AGENTS_FILE")
enabled_agents=$(jq '[.[] | select(.enabled == true)] | length' "$AGENTS_FILE")
total_vcpu=0
agents_with_cpu=0

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

    # Agent size is what an equivalent hosted or self-hosted runner must match,
    # and is the multiplier on the self-hosted infrastructure cost you supply
    # from your own cloud or datacentre billing. Reported from agent-declared capabilities, which are only
    # present for agents that have connected at least once.
    agents_with_cpu=$(jq '[.[] | select(.cpuCount != null)] | length' "$AGENTS_FILE")
    if [ "$agents_with_cpu" -gt 0 ]; then
        total_vcpu=$(jq '[.[] | .cpuCount // 0] | add // 0' "$AGENTS_FILE")
        echo "" | tee -a "$REPORT_FILE"
        echo "Self-Hosted Agent Sizes (declared capabilities):" | tee -a "$REPORT_FILE"
        echo "  Agents reporting CPU count: $agents_with_cpu of $total_agents" | tee -a "$REPORT_FILE"
        echo "  Total vCPU across self-hosted fleet: $total_vcpu" | tee -a "$REPORT_FILE"
        jq -r '[.[] | select(.cpuCount != null) | .cpuCount]
               | group_by(.) | map({cpu: .[0], count: length}) | sort_by(.cpu) | .[]
               | "  - \(.cpu) vCPU: \(.count) agents"' "$AGENTS_FILE" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "  Use the vCPU total as the sizing basis, together with the per-VM" | tee -a "$REPORT_FILE"
        echo "  or per-node cost of this fleet from your infrastructure billing." | tee -a "$REPORT_FILE"
    else
        total_vcpu=0
        echo "" | tee -a "$REPORT_FILE"
        echo "Self-Hosted Agent Sizes: not reported by the API for this account." | tee -a "$REPORT_FILE"
        echo "  Agent capabilities require pool read permission. Re-run with an" | tee -a "$REPORT_FILE"
        echo "  account that has it, or record the VM sizes behind these pools." | tee -a "$REPORT_FILE"
    fi
fi

echo "" | tee -a "$REPORT_FILE"
echo "Reading this for a platform comparison:" | tee -a "$REPORT_FILE"
echo "  Microsoft-hosted pools are vendor-run compute, normally billed per" | tee -a "$REPORT_FILE"
echo "  minute. Their usage carries over as metered spend on any hosted-runner" | tee -a "$REPORT_FILE"
echo "  model. Self-hosted pools carry no vendor compute charge on either side," | tee -a "$REPORT_FILE"
echo "  but the underlying infrastructure cost stays with you and does not" | tee -a "$REPORT_FILE"
echo "  appear in any vendor quote." | tee -a "$REPORT_FILE"
echo "  Peak concurrency (section 12) sizes the fleet; total minutes size the" | tee -a "$REPORT_FILE"
echo "  hosted-compute portion." | tee -a "$REPORT_FILE"

# ========================================
# 14. INTEGRATION REPLACEMENT EFFORT
# ========================================
write_section "14. Integration Replacement Effort"

echo "Classifying each detected integration by how much work it would take to" | tee -a "$REPORT_FILE"
echo "reproduce on a different CI platform." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Effort categories:" | tee -a "$REPORT_FILE"
echo "  OOB     - a native platform feature covers it; no integration work" | tee -a "$REPORT_FILE"
echo "  MARKET  - an off-the-shelf marketplace component exists" | tee -a "$REPORT_FILE"
echo "  PARTNER - the publisher ships and supports its own integration" | tee -a "$REPORT_FILE"
echo "  CUSTOM  - no ready-made equivalent; expect bespoke work" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "The category is the portable finding. The named component after each" | tee -a "$REPORT_FILE"
echo "entry is a worked example against GitHub Actions, included to show why" | tee -a "$REPORT_FILE"
echo "the item was graded that way - substitute the equivalent for whichever" | tee -a "$REPORT_FILE"
echo "platform you are evaluating." | tee -a "$REPORT_FILE"
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
    echo "Service Connections:" | tee -a "$REPORT_FILE"
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
    echo "Marketplace Extensions:" | tee -a "$REPORT_FILE"
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
    echo "  Off-the-shelf component:         $market_count" | tee -a "$REPORT_FILE"
    echo "  Publisher-supported integration: $partner_count" | tee -a "$REPORT_FILE"
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
# SECTION 16-22 COLLECTION DEFAULTS
# ========================================
# Every figure produced by sections 16-22 is initialised here so that a skipped
# or permission-denied section still leaves the summary and the JSON export with
# a defined, honest zero rather than an unset variable.
timeline_stride=1
timeline_is_sample=0
timeline_target=0
timeline_fetched=0
timeline_failed=0
timeline_sampled=0
timeline_jobs=0
avg_jobs_per_build=0
job_expansion_ratio=0
billable_job_minutes_window=0
billable_job_minutes_month=0
raw_job_minutes_month=0
distinct_tasks_used=0
ext_tasks_used=0
jobreq_total=0
jobreq_window_days=0
os_multiplier_factor=0
weighted_minutes_month=0
total_deployments=0
deployment_minutes_window=0
deployment_minutes_month=0
total_environments=0
env_checks_checked=0
env_approvals=0
env_gates=0
env_other_checks=0
release_env_count=0
release_manual_approvals=0
release_gates=0
total_secure_files=0
complexity_observed=0
complexity_simple=0
complexity_moderate=0
complexity_complex=0
hosted_parallel_purchased=0
hosted_parallel_used=0
selfhosted_parallel_purchased=0
selfhosted_parallel_used=0

# ========================================
# 16. JOB-LEVEL COMPUTE & BILLABLE MINUTES
# ========================================
write_section "16. Job-Level Compute & Billable Minutes (per-job billing model)"
maybe_refresh_token

# Section 12 measures BUILD wall-clock, which is what Azure DevOps reports.
# GitHub Actions bills per JOB and rounds every job up to the next whole minute,
# so a build that fans out to six parallel jobs bills roughly six times its
# wall-clock duration. The build timeline is the only endpoint that exposes
# job-level start and finish times, so it is the only way to produce a figure
# that can be priced against Actions without guessing.
#
# One timeline call is needed per build. On a large estate that is too many
# calls, so the collector samples evenly across the collected build history and
# extrapolates using the measured job-to-wall-clock ratio. The sample size and
# the ratio are both reported so the reader can judge the confidence.

TIMELINE_RAW_NDJSON="$TEMP_DATA_DIR/timeline_raw.ndjson"
TIMELINE_JOBS_FILE="$TEMP_DATA_DIR/timeline_jobs.json"
TIMELINE_TASKS_FILE="$TEMP_DATA_DIR/timeline_tasks.json"
TIMELINE_PERBUILD_FILE="$TEMP_DATA_DIR/timeline_perbuild.json"
TIMELINE_STATS_FILE="$TEMP_DATA_DIR/timeline_stats.json"
TIMELINE_OK_IDS="$TEMP_DATA_DIR/timeline_ok_ids.txt"
TIMELINE_OK_BUILDS_FILE="$TEMP_DATA_DIR/timeline_ok_builds.json"
SAMPLED_BUILDS_FILE="$TEMP_DATA_DIR/sampled_builds.json"
ORG_TASKS_FILE="$TEMP_DATA_DIR/org_tasks.json"
TASK_USAGE_FILE="$TEMP_DATA_DIR/task_usage.json"

echo "{}" > "$TIMELINE_STATS_FILE"
for _f in "$TIMELINE_JOBS_FILE" "$TIMELINE_TASKS_FILE" "$TIMELINE_PERBUILD_FILE" \
          "$TIMELINE_OK_BUILDS_FILE" "$SAMPLED_BUILDS_FILE" "$ORG_TASKS_FILE" "$TASK_USAGE_FILE"; do
    echo "[]" > "$_f"
done
unset _f
: > "$TIMELINE_RAW_NDJSON"
: > "$TIMELINE_OK_IDS"

if [ "$SKIP_BUILD_HISTORY" = "1" ]; then
    echo "Skipped: build history was not collected (SKIP_BUILD_HISTORY=1)." | tee -a "$REPORT_FILE"
    echo "Job-level minutes require build history. Re-run without that flag to" | tee -a "$REPORT_FILE"
    echo "produce a figure comparable to a per-job billing model." | tee -a "$REPORT_FILE"
elif [ "$SKIP_TIMELINE" = "1" ]; then
    echo "Skipped: SKIP_TIMELINE=1." | tee -a "$REPORT_FILE"
    echo "Without this section the only compute figure available is build" | tee -a "$REPORT_FILE"
    echo "wall-clock, which understates Actions billing on any parallel pipeline." | tee -a "$REPORT_FILE"
elif [ "${total_builds:-0}" -eq 0 ]; then
    echo "Skipped: no builds were found in the last $HISTORY_DAYS days." | tee -a "$REPORT_FILE"
else
    # Even sampling across the whole collected history. Because builds were
    # collected project by project, taking every Nth record spreads the sample
    # across every project in proportion to its build volume.
    if [ "${total_builds:-0}" -le "$TIMELINE_SAMPLE_MAX" ]; then
        timeline_stride=1
        timeline_is_sample=0
    else
        timeline_stride=$(( (total_builds + TIMELINE_SAMPLE_MAX - 1) / TIMELINE_SAMPLE_MAX ))
        timeline_is_sample=1
    fi

    jq -c --argjson stride "$timeline_stride" \
        '[to_entries[] | select((.key % $stride) == 0) | .value | select(.id != null)]' \
        "$BUILDS_FILE" > "$SAMPLED_BUILDS_FILE" 2>/dev/null || echo "[]" > "$SAMPLED_BUILDS_FILE"
    timeline_target=$(num "$(jq 'length' "$SAMPLED_BUILDS_FILE" 2>/dev/null)")

    if [ "$timeline_is_sample" = "1" ]; then
        echo "Sampling every ${timeline_stride}th build: $timeline_target of ${total_builds} builds." | tee -a "$REPORT_FILE"
        echo "Population figures below are extrapolated from this sample." | tee -a "$REPORT_FILE"
    else
        echo "Reading the timeline of all $timeline_target builds (no sampling)." | tee -a "$REPORT_FILE"
    fi
    echo "One API call per build - this is the slowest section." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"

    while IFS=$'\t' read -r s_project s_buildid s_defid; do
        [ -z "$s_project" ] && continue
        case "$s_buildid" in ''|*[!0-9]*) continue ;; esac
        s_defid=$(num "$s_defid")

        timeline_fetched=$((timeline_fetched + 1))
        if [ $((timeline_fetched % 200)) -eq 0 ]; then
            maybe_refresh_token
            echo "  ... $timeline_fetched of $timeline_target timelines read"
        fi

        s_project_enc=$(url_encode "$s_project")
        timeline_body=$(call_api "$ORG_URL/$s_project_enc/_apis/build/builds/$s_buildid/timeline?api-version=$API_VERSION")

        if [ "$timeline_body" = "API_ERROR" ] || ! echo "$timeline_body" | jq empty 2>/dev/null; then
            timeline_failed=$((timeline_failed + 1))
            continue
        fi

        echo "$s_buildid" >> "$TIMELINE_OK_IDS"

        # Jobs carry the billable duration; tasks identify which marketplace and
        # custom tasks are genuinely executed, as opposed to merely installed.
        echo "$timeline_body" | jq -c \
            --arg proj "$s_project" \
            --argjson bid "$s_buildid" \
            --argjson did "$s_defid" '
            (.records // []) as $r
            | ($r[] | select(.type == "Job")
               | {k: "job", project: $proj, buildId: $bid, definitionId: $did,
                  name: (.name // ""), worker: (.workerName // null),
                  s: (.startTime // null), f: (.finishTime // null),
                  result: (.result // "unknown")}),
              ($r[] | select(.type == "Task")
               | {k: "task", project: $proj, buildId: $bid, definitionId: $did,
                  taskId: (.task.id // null),
                  taskName: (.task.name // .name // "unknown")})
            ' >> "$TIMELINE_RAW_NDJSON" 2>/dev/null
    done < <(jq -r '.[] | [.project, (.id | tostring), ((.definitionId // 0) | tostring)] | @tsv' \
                "$SAMPLED_BUILDS_FILE" 2>/dev/null)

    if [ "$timeline_failed" -gt 0 ]; then
        report_warn "$timeline_failed of $timeline_target build timelines could not be read - job-level minutes are based on the remainder."
    fi

    if [ -s "$TIMELINE_RAW_NDJSON" ]; then
        jq -s '[.[] | select(.k == "job")]' "$TIMELINE_RAW_NDJSON" \
            > "$TIMELINE_JOBS_FILE" 2>/dev/null || echo "[]" > "$TIMELINE_JOBS_FILE"
        jq -s '[.[] | select(.k == "task")]' "$TIMELINE_RAW_NDJSON" \
            > "$TIMELINE_TASKS_FILE" 2>/dev/null || echo "[]" > "$TIMELINE_TASKS_FILE"
    fi

    # The wall-clock denominator must cover exactly the builds whose timeline was
    # actually read, otherwise the ratio is computed against builds with no jobs.
    jq -c --slurpfile ok <(jq -R -s 'split("\n") | map(select(length > 0) | tonumber? // empty)' \
                              "$TIMELINE_OK_IDS" 2>/dev/null || echo '[]') \
        '[ .[] | select(.id as $i | (($ok[0] // []) | index($i)) != null) ]' \
        "$SAMPLED_BUILDS_FILE" > "$TIMELINE_OK_BUILDS_FILE" 2>/dev/null \
        || echo "[]" > "$TIMELINE_OK_BUILDS_FILE"

    jq -n \
        --slurpfile jobs "$TIMELINE_JOBS_FILE" \
        --slurpfile okb "$TIMELINE_OK_BUILDS_FILE" \
        --argjson windowDays "$(num "${HISTORY_DAYS:-90}")" \
        --argjson populationMinutes "$(num "${total_build_minutes:-0}")" '
        def epoch:
            if (. == null or . == "") then null
            else (sub("\\.[0-9]+";"") | fromdateiso8601? // null) end;

        (($jobs[0] // [])
         | map(. + {_s: (.s | epoch), _f: (.f | epoch)})
         | map(select(._s != null and ._f != null and ._f >= ._s))
         | map(. + {_d: (._f - ._s)})) as $j
        | (($okb[0] // [])
           | map(. + {_s: (.startTime | epoch), _f: (.finishTime | epoch)})
           | map(select(._s != null and ._f != null and ._f >= ._s))
           | map(._f - ._s)) as $bd
        | ($bd | add // 0) as $buildSec
        | ($j | map(._d) | add // 0) as $jobSec
        # Actions rounds every job up to a whole minute, with a one-minute floor.
        | ($j | map(if ._d < 60 then 1 else ((._d + 59) / 60 | floor) end) | add // 0) as $billable
        | (($okb[0] // []) | length) as $sampleBuilds
        | (if $buildSec > 0 then (($jobSec / $buildSec) * 1000 | floor) / 1000 else 0 end) as $rawRatio
        | (if $buildSec > 0 then ((($billable * 60) / $buildSec) * 1000 | floor) / 1000 else 0 end) as $billRatio
        | {
            sampleBuilds: $sampleBuilds,
            sampleJobs: ($j | length),
            sampleBuildWallClockMinutes: (($buildSec / 60) | floor),
            sampleRawJobMinutes: (($jobSec / 60) | floor),
            sampleBillableJobMinutes: $billable,
            avgJobsPerBuild:
                (if $sampleBuilds > 0
                 then (((($j | length) / $sampleBuilds) * 100) | floor) / 100 else 0 end),
            avgJobMinutes:
                (if ($j | length) > 0
                 then ((($jobSec / ($j | length) / 60) * 100) | floor) / 100 else 0 end),
            rawJobToWallClockRatio: $rawRatio,
            billableToWallClockRatio: $billRatio,
            estimatedBillableJobMinutesWindow: (($populationMinutes * $billRatio) | floor),
            estimatedBillableJobMinutesPerMonth:
                (((($populationMinutes * $billRatio) / $windowDays) * 30) | floor),
            estimatedRawJobMinutesPerMonth:
                (((($populationMinutes * $rawRatio) / $windowDays) * 30) | floor),
            jobResultBreakdown:
                ($j | group_by(.result)
                    | map({key: (.[0].result // "unknown"), count: length})
                    | sort_by(-.count))
          }' > "$TIMELINE_STATS_FILE" 2>/dev/null

    if [ ! -s "$TIMELINE_STATS_FILE" ]; then
        echo "{}" > "$TIMELINE_STATS_FILE"
        report_warn "Job-level statistics could not be computed from the collected timelines."
    fi

    timeline_sampled=$(num "$(jq -r '.sampleBuilds // 0' "$TIMELINE_STATS_FILE")")
    timeline_jobs=$(num "$(jq -r '.sampleJobs // 0' "$TIMELINE_STATS_FILE")")
    avg_jobs_per_build=$(jq -r '.avgJobsPerBuild // 0' "$TIMELINE_STATS_FILE")
    job_expansion_ratio=$(jq -r '.billableToWallClockRatio // 0' "$TIMELINE_STATS_FILE")
    billable_job_minutes_window=$(num "$(jq -r '.estimatedBillableJobMinutesWindow // 0' "$TIMELINE_STATS_FILE")")
    billable_job_minutes_month=$(num "$(jq -r '.estimatedBillableJobMinutesPerMonth // 0' "$TIMELINE_STATS_FILE")")
    raw_job_minutes_month=$(num "$(jq -r '.estimatedRawJobMinutesPerMonth // 0' "$TIMELINE_STATS_FILE")")

    echo "Sample:" | tee -a "$REPORT_FILE"
    echo "  Builds with a readable timeline: $timeline_sampled" | tee -a "$REPORT_FILE"
    echo "  Jobs observed:                   $timeline_jobs" | tee -a "$REPORT_FILE"
    echo "  Average jobs per build:          $avg_jobs_per_build" | tee -a "$REPORT_FILE"
    echo "  Average job duration (min):      $(jq -r '.avgJobMinutes // 0' "$TIMELINE_STATS_FILE")" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Measured in the sample:" | tee -a "$REPORT_FILE"
    echo "  Build wall-clock minutes:        $(jq -r '.sampleBuildWallClockMinutes // 0' "$TIMELINE_STATS_FILE")" | tee -a "$REPORT_FILE"
    echo "  Raw job minutes:                 $(jq -r '.sampleRawJobMinutes // 0' "$TIMELINE_STATS_FILE")" | tee -a "$REPORT_FILE"
    echo "  Billable job minutes (rounded):  $(jq -r '.sampleBillableJobMinutes // 0' "$TIMELINE_STATS_FILE")" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Expansion ratio (billable job minutes per build wall-clock minute): $job_expansion_ratio" | tee -a "$REPORT_FILE"
    echo "  A ratio above 1.0 means parallel jobs and per-job rounding make the" | tee -a "$REPORT_FILE"
    echo "  Actions-billable figure larger than the Azure DevOps minute count." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "APPLIED TO THE FULL ESTATE:" | tee -a "$REPORT_FILE"
    echo "  Billable job minutes (${HISTORY_DAYS}d): $billable_job_minutes_window" | tee -a "$REPORT_FILE"
    echo "  Billable job minutes per month:  $billable_job_minutes_month" | tee -a "$REPORT_FILE"
    if [ "$timeline_is_sample" = "1" ]; then
        echo "  Basis: EXTRAPOLATED from $timeline_sampled sampled builds" | tee -a "$REPORT_FILE"
    else
        echo "  Basis: MEASURED across every build in the window" | tee -a "$REPORT_FILE"
    fi
    echo "" | tee -a "$REPORT_FILE"
    echo "This is the measurement a cost model needs. Whoever prepares the" | tee -a "$REPORT_FILE"
    echo "estimate applies current runner rates to it, after weighting by the" | tee -a "$REPORT_FILE"
    echo "operating-system mix in section 17 and removing any workload that" | tee -a "$REPORT_FILE"
    echo "would stay on self-hosted runners." | tee -a "$REPORT_FILE"

    # ---- Executed task inventory -------------------------------------------
    # The extensions list in section 10 shows what is installed. This shows what
    # actually runs, which is the set that has to be replaced in Actions.
    maybe_refresh_token
    call_api_paged "$ORG_URL/_apis/distributedtask/tasks?api-version=7.1-preview.1" '.value' \
        | jq -c '{id: (.id // null), name: (.name // "unknown"),
                  contributionIdentifier: (.contributionIdentifier // null)}' \
        > "$TEMP_DATA_DIR/org_tasks.ndjson" 2>/dev/null
    ndjson_to_array "$TEMP_DATA_DIR/org_tasks.ndjson" "$ORG_TASKS_FILE"

    jq -n --slurpfile tasks "$TIMELINE_TASKS_FILE" --slurpfile catalog "$ORG_TASKS_FILE" '
        ((($catalog[0] // []) | map(select(.id != null))
          | group_by(.id) | map({key: .[0].id, value: .[0]}) | from_entries)) as $cat
        | (($tasks[0] // [])
           | group_by((.taskId // "") + "|" + (.taskName // "unknown"))
           | map({
               taskId: (.[0].taskId),
               name: (.[0].taskName // "unknown"),
               executions: length,
               pipelines: ([.[].definitionId] | unique | length),
               extension: (($cat[(.[0].taskId // "")] // {}) | .contributionIdentifier)
             })
           | sort_by(-.executions))' > "$TASK_USAGE_FILE" 2>/dev/null \
        || echo "[]" > "$TASK_USAGE_FILE"

    distinct_tasks_used=$(num "$(jq 'length' "$TASK_USAGE_FILE" 2>/dev/null)")
    ext_tasks_used=$(num "$(jq '[.[] | select(.extension != null)] | length' "$TASK_USAGE_FILE" 2>/dev/null)")

    if [ "$distinct_tasks_used" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Tasks Actually Executed (from the sampled builds):" | tee -a "$REPORT_FILE"
        echo "  Distinct tasks in use:                 $distinct_tasks_used" | tee -a "$REPORT_FILE"
        echo "  Provided by a Marketplace extension:   $ext_tasks_used" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "  Top 20 tasks by execution count:" | tee -a "$REPORT_FILE"
        jq -r '.[:20][] | "    - \(.name): \(.executions) runs across \(.pipelines) pipelines\(if .extension != null then "  [extension: \(.extension)]" else "" end)"' \
            "$TASK_USAGE_FILE" | tee -a "$REPORT_FILE"

        if [ "$ext_tasks_used" -gt 0 ]; then
            echo "" | tee -a "$REPORT_FILE"
            echo "  Extension-provided tasks in use (each needs an Actions equivalent):" | tee -a "$REPORT_FILE"
            jq -r '[.[] | select(.extension != null)]
                   | group_by(.extension)
                   | map({extension: .[0].extension,
                          tasks: length,
                          executions: ([.[].executions] | add // 0)})
                   | sort_by(-.executions) | .[]
                   | "    - \(.extension): \(.tasks) task(s), \(.executions) executions"' \
                "$TASK_USAGE_FILE" | tee -a "$REPORT_FILE"
        fi
    fi

    # ---- Per-build rollup, consumed by the complexity section ---------------
    jq -n --slurpfile jobs "$TIMELINE_JOBS_FILE" \
          --slurpfile tasks "$TIMELINE_TASKS_FILE" \
          --slurpfile usage "$TASK_USAGE_FILE" '
        ((($usage[0] // []) | map(select(.extension != null) | .taskId)
          | map(select(. != null)))) as $extIds
        | (($jobs[0] // []) | group_by(.buildId)
           | map({buildId: .[0].buildId, definitionId: .[0].definitionId,
                  project: .[0].project, jobs: length})) as $jb
        | (($tasks[0] // []) | group_by(.buildId)
           | map({buildId: .[0].buildId,
                  tasks: length,
                  distinctTasks: ([.[].taskId] | unique | length),
                  extTasks: ([.[] | select((.taskId as $t | $extIds | index($t)) != null) | .taskId]
                             | unique | length)})
           | map({key: (.buildId | tostring), value: .}) | from_entries) as $tmap
        | $jb | map(. + (($tmap[(.buildId | tostring)] // {})
                         | {tasks: (.tasks // 0),
                            distinctTasks: (.distinctTasks // 0),
                            extTasks: (.extTasks // 0)}))' \
        > "$TIMELINE_PERBUILD_FILE" 2>/dev/null || echo "[]" > "$TIMELINE_PERBUILD_FILE"
fi

# ========================================
# 17. RUNNER IMAGE & OPERATING SYSTEM MIX
# ========================================
write_section "17. Runner Image & Operating System Mix"
maybe_refresh_token

# Total minutes alone cannot be priced: per-job models weight Linux at 1x,
# Windows at 2x and macOS at 10x. The agent job-request queue is the only
# endpoint that reports the image each job actually ran on, so it is the only
# source for the multiplier weighting.
#
# Azure DevOps keeps a limited history of job requests, and does not document
# how much. The observed window is therefore measured from the data returned
# and reported alongside the mix, so a short retention is visible rather than
# silently treated as a full-period sample.

JOBREQ_FILE="$TEMP_DATA_DIR/jobrequests.json"
JOBREQ_STATS_FILE="$TEMP_DATA_DIR/jobrequest_stats.json"
echo "[]" > "$JOBREQ_FILE"
echo "{}" > "$JOBREQ_STATS_FILE"
rm -f "$TEMP_DATA_DIR/jobrequests.ndjson"
touch "$TEMP_DATA_DIR/jobrequests.ndjson"

while IFS= read -r pool_line; do
    [ -z "$pool_line" ] && continue
    jr_pool_id=$(echo "$pool_line" | jq -r '.id // empty')
    jr_pool_name=$(echo "$pool_line" | jq -r '.name // "unknown"')
    jr_pool_hosted=$(echo "$pool_line" | jq -r 'if (.isHosted == true) then "true" else "false" end')
    [ -z "$jr_pool_id" ] && continue

    jr_body=$(call_api "$ORG_URL/_apis/distributedtask/pools/$jr_pool_id/jobrequests?api-version=7.1-preview.1")
    [ "$jr_body" = "API_ERROR" ] && continue
    echo "$jr_body" | jq empty 2>/dev/null || continue

    echo "$jr_body" | jq -c --arg pool "$jr_pool_name" --argjson hosted "$jr_pool_hosted" '
        .value[]? | {
            pool: $pool,
            hosted: $hosted,
            image: (.agentSpecification.vmImage // .agentSpecification.identifier // null),
            demands: ((.demands // []) | map(tostring) | join(";")),
            queueTime: (.queueTime // null),
            assignTime: (.assignTime // null),
            finishTime: (.finishTime // null),
            result: (.result // "unknown"),
            definition: (.definition.name // null)
        }' >> "$TEMP_DATA_DIR/jobrequests.ndjson" 2>/dev/null
done < <(jq -c '.[]' "$POOLS_FILE" 2>/dev/null)

ndjson_to_array "$TEMP_DATA_DIR/jobrequests.ndjson" "$JOBREQ_FILE"
jobreq_total=$(num "$(jq 'length' "$JOBREQ_FILE" 2>/dev/null)")

if [ "$jobreq_total" -eq 0 ]; then
    echo "No agent job requests were returned." | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "The operating-system mix of hosted minutes could not be measured." | tee -a "$REPORT_FILE"
    echo "This is the single largest cost variable, because Windows bills at ${MULT_WINDOWS}x" | tee -a "$REPORT_FILE"
    echo "and macOS at ${MULT_MACOS}x Linux. Record the Windows, Linux and macOS split from" | tee -a "$REPORT_FILE"
    echo "your pipeline definitions, or grant pool read permission and re-run." | tee -a "$REPORT_FILE"
    report_warn "Agent job requests returned no data - the OS mix behind hosted minutes is UNKNOWN and must be established another way."
else
    jq '
        def epoch:
            if (. == null or . == "") then null
            else (sub("\\.[0-9]+";"") | fromdateiso8601? // null) end;
        def osfam($s):
            if ($s == null or $s == "") then "Unknown"
            elif ($s | test("(?i)windows|win-|win2|windows_nt|vs2017|vs2019")) then "Windows"
            elif ($s | test("(?i)macos|mac-|osx|darwin")) then "macOS"
            elif ($s | test("(?i)ubuntu|linux|debian|rhel|centos|fedora|alpine|suse")) then "Linux"
            else "Unknown" end;

        map(. + {_img: (if (.image != null and .image != "") then .image else .demands end)})
        | map(. + {os: osfam(._img),
                   _q: (.queueTime | epoch),
                   _a: (.assignTime | epoch),
                   _f: (.finishTime | epoch)})
        | map(. + {_start: (._a // ._q)})
        | map(. + {_d: (if (._start != null and ._f != null and ._f >= ._start)
                        then (._f - ._start) else null end)})
        | . as $r
        | {
            requests: ($r | length),
            withTiming: ($r | map(select(._d != null)) | length),
            observedFrom: ($r | map(._q) | map(select(. != null))
                           | (if length == 0 then null else (min | todate) end)),
            observedTo: ($r | map(._f) | map(select(. != null))
                         | (if length == 0 then null else (max | todate) end)),
            byOs: ($r | group_by(.os)
                   | map({
                       os: .[0].os,
                       requests: length,
                       minutes: (((map(select(._d != null) | ._d) | add // 0) / 60) | floor),
                       billableMinutes:
                           (map(select(._d != null)
                                | (if ._d < 60 then 1 else ((._d + 59) / 60 | floor) end))
                            | add // 0)
                     })
                   | sort_by(-.billableMinutes)),
            byImage: ($r | group_by(._img // "unspecified")
                      | map({
                          image: (.[0]._img // "unspecified"),
                          hosted: (.[0].hosted),
                          requests: length,
                          minutes: (((map(select(._d != null) | ._d) | add // 0) / 60) | floor)
                        })
                      | sort_by(-.minutes) | .[:15]),
            byHosted: ($r | group_by(.hosted)
                       | map({
                           hosted: .[0].hosted,
                           requests: length,
                           minutes: (((map(select(._d != null) | ._d) | add // 0) / 60) | floor)
                         }))
          }' "$JOBREQ_FILE" > "$JOBREQ_STATS_FILE" 2>/dev/null

    [ -s "$JOBREQ_STATS_FILE" ] || echo "{}" > "$JOBREQ_STATS_FILE"

    jr_from=$(jq -r '.observedFrom // "unknown"' "$JOBREQ_STATS_FILE")
    jr_to=$(jq -r '.observedTo // "unknown"' "$JOBREQ_STATS_FILE")
    jobreq_window_days=$(jq -rn --slurpfile s "$JOBREQ_STATS_FILE" '
        ($s[0].observedFrom // null) as $a | ($s[0].observedTo // null) as $b
        | if ($a == null or $b == null) then 0
          else ((($b | fromdateiso8601) - ($a | fromdateiso8601)) / 86400 * 10 | floor) / 10 end' 2>/dev/null)
    jobreq_window_days=${jobreq_window_days:-0}

    echo "Job requests returned: $jobreq_total" | tee -a "$REPORT_FILE"
    echo "Observed window:       $jr_from  ->  $jr_to  (${jobreq_window_days} days)" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "IMPORTANT: Azure DevOps retains job requests for a limited, undocumented" | tee -a "$REPORT_FILE"
    echo "  period. Treat the window above as the true coverage of this section." | tee -a "$REPORT_FILE"
    echo "  If it is materially shorter than the ${HISTORY_DAYS}-day build window," | tee -a "$REPORT_FILE"
    echo "  use the MIX below as a proportion and apply it to the job minutes in" | tee -a "$REPORT_FILE"
    echo "  section 16 - do not use these absolute minutes as a monthly total." | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
    echo "Operating System Mix (the Actions cost multiplier):" | tee -a "$REPORT_FILE"
    jq -r '
        (.byOs // []) as $o
        | ($o | map(.billableMinutes) | add // 0) as $t
        | $o[]
        | "  - \(.os): \(.requests) jobs, \(.minutes) min, \(.billableMinutes) billable min"
          + (if $t > 0 then "  (\((.billableMinutes / $t * 1000 | floor) / 10)% of billable)" else "" end)
        ' "$JOBREQ_STATS_FILE" | tee -a "$REPORT_FILE"

    # Weighted factor: how many Linux-equivalent minutes one billable minute of
    # this workload costs, given the observed mix.
    os_multiplier_factor=$(jq -rn --slurpfile s "$JOBREQ_STATS_FILE" \
        --argjson ml "$(numf "$MULT_LINUX")" \
        --argjson mw "$(numf "$MULT_WINDOWS")" \
        --argjson mm "$(numf "$MULT_MACOS")" '
        (($s[0].byOs // [])
         | map(. + {mult: (if .os == "Windows" then $mw
                           elif .os == "macOS" then $mm
                           else $ml end)})) as $o
        | ($o | map(.billableMinutes) | add // 0) as $t
        | if $t > 0
          then ((($o | map(.billableMinutes * .mult) | add // 0) / $t) * 100 | floor) / 100
          else 0 end' 2>/dev/null)
    os_multiplier_factor=${os_multiplier_factor:-0}

    echo "" | tee -a "$REPORT_FILE"
    echo "Weighted multiplier for this mix: ${os_multiplier_factor}x" | tee -a "$REPORT_FILE"
    echo "  (Linux ${MULT_LINUX}x, Windows ${MULT_WINDOWS}x, macOS ${MULT_MACOS}x. A figure of 1.00 means an" | tee -a "$REPORT_FILE"
    echo "  all-Linux estate; anything higher is the premium the current mix" | tee -a "$REPORT_FILE"
    echo "  carries. Confirm these ratios against current published rates.)" | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
    echo "Hosted vs Self-Hosted (by job request):" | tee -a "$REPORT_FILE"
    jq -r '(.byHosted // [])[]
           | "  - \(if .hosted then "Microsoft-hosted" else "self-hosted" end): \(.requests) jobs, \(.minutes) min"' \
        "$JOBREQ_STATS_FILE" | tee -a "$REPORT_FILE"

    echo "" | tee -a "$REPORT_FILE"
    echo "Top Images / Demands:" | tee -a "$REPORT_FILE"
    jq -r '(.byImage // [])[] | "  - \(.image): \(.requests) jobs, \(.minutes) min"' \
        "$JOBREQ_STATS_FILE" | tee -a "$REPORT_FILE"
fi

# ========================================
# 18. DEPLOYMENT (RELEASE) COMPUTE
# ========================================
write_section "18. Deployment (Release) Compute"
maybe_refresh_token

# Build history covers pipelines only. Classic release pipelines run on the same
# agents and consume the same parallel jobs, but are invisible to the build API.
# Omitting them understates the compute that has to be replaced in Actions.

DEPLOY_FILE="$TEMP_DATA_DIR/deployments.json"
DEPLOY_STATS_FILE="$TEMP_DATA_DIR/deployment_stats.json"
echo "[]" > "$DEPLOY_FILE"
echo "{}" > "$DEPLOY_STATS_FILE"
rm -f "$TEMP_DATA_DIR/deployments.ndjson"
touch "$TEMP_DATA_DIR/deployments.ndjson"

if [ "${total_release_defs:-0}" -eq 0 ]; then
    echo "No classic release pipelines were found, so there is no separate" | tee -a "$REPORT_FILE"
    echo "deployment compute to account for." | tee -a "$REPORT_FILE"
else
    echo "Collecting deployments since $HISTORY_START..." | tee -a "$REPORT_FILE"
    for project in "${projects[@]}"; do
        [ -z "$project" ] && continue
        maybe_refresh_token
        project_encoded=$(url_encode "$project")
        call_api_paged \
            "https://vsrm.dev.azure.com/$ORG/$project_encoded/_apis/release/deployments?minStartedTime=$HISTORY_START&api-version=$API_VERSION" \
            '.value' \
            | jq -c --arg proj "$project" '{
                project: $proj,
                startedOn: (.startedOn // null),
                completedOn: (.completedOn // null),
                status: (.deploymentStatus // "unknown"),
                environment: (.releaseEnvironment.name // "unknown"),
                definition: (.releaseDefinition.name // "unknown")
              }' >> "$TEMP_DATA_DIR/deployments.ndjson" 2>/dev/null
    done

    ndjson_to_array "$TEMP_DATA_DIR/deployments.ndjson" "$DEPLOY_FILE"
    total_deployments=$(num "$(jq 'length' "$DEPLOY_FILE" 2>/dev/null)")

    if [ "$total_deployments" -eq 0 ]; then
        echo "No deployments were returned for the window." | tee -a "$REPORT_FILE"
    else
        jq --argjson days "$(num "${HISTORY_DAYS:-90}")" '
            def epoch:
                if (. == null or . == "") then null
                else (sub("\\.[0-9]+";"") | fromdateiso8601? // null) end;
            map(. + {_s: (.startedOn | epoch), _f: (.completedOn | epoch)})
            | map(. + {_d: (if (._s != null and ._f != null and ._f >= ._s)
                            then (._f - ._s) else null end)})
            | . as $d
            | ($d | map(select(._d != null) | ._d) | add // 0) as $sec
            | {
                deployments: ($d | length),
                windowDays: $days,
                minutesInWindow: (($sec / 60) | floor),
                minutesPerMonth: ((($sec / 60) / $days * 30) | floor),
                deploymentsPerMonth: ((($d | length) / $days * 30) | floor),
                byStatus: ($d | group_by(.status)
                           | map({status: .[0].status, count: length})
                           | sort_by(-.count)),
                topEnvironments: ($d | group_by(.environment)
                                  | map({environment: .[0].environment,
                                         deployments: length,
                                         minutes: (((map(select(._d != null) | ._d) | add // 0) / 60) | floor)})
                                  | sort_by(-.minutes) | .[:10])
              }' "$DEPLOY_FILE" > "$DEPLOY_STATS_FILE" 2>/dev/null

        [ -s "$DEPLOY_STATS_FILE" ] || echo "{}" > "$DEPLOY_STATS_FILE"

        deployment_minutes_window=$(num "$(jq -r '.minutesInWindow // 0' "$DEPLOY_STATS_FILE")")
        deployment_minutes_month=$(num "$(jq -r '.minutesPerMonth // 0' "$DEPLOY_STATS_FILE")")

        echo "" | tee -a "$REPORT_FILE"
        echo "Deployments in last $HISTORY_DAYS days: $total_deployments" | tee -a "$REPORT_FILE"
        echo "Deployments per month:                 $(jq -r '.deploymentsPerMonth // 0' "$DEPLOY_STATS_FILE")" | tee -a "$REPORT_FILE"
        echo "Deployment minutes ($HISTORY_DAYS days):  $deployment_minutes_window" | tee -a "$REPORT_FILE"
        echo "Deployment minutes per month:          $deployment_minutes_month" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Outcomes:" | tee -a "$REPORT_FILE"
        jq -r '(.byStatus // [])[] | "  - \(.status): \(.count)"' "$DEPLOY_STATS_FILE" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "Busiest Environments:" | tee -a "$REPORT_FILE"
        jq -r '(.topEnvironments // [])[] | "  - \(.environment): \(.deployments) deployments, \(.minutes) min"' \
            "$DEPLOY_STATS_FILE" | tee -a "$REPORT_FILE"
        echo "" | tee -a "$REPORT_FILE"
        echo "These minutes are ADDITIONAL to the build minutes in section 12 and" | tee -a "$REPORT_FILE"
        echo "must be included in the Actions compute estimate." | tee -a "$REPORT_FILE"
    fi
fi

# ========================================
# 19. APPROVALS, GATES, ENVIRONMENTS & SECRETS
# ========================================
write_section "19. Approvals, Gates, Environments & Secrets"
maybe_refresh_token

# None of these migrate automatically. Each approval, gate, secret and secure
# file is manual re-implementation effort in Actions, so the counts are a direct
# input to the one-off migration effort rather than the ongoing run-rate.

ENVIRONMENTS_FILE="$TEMP_DATA_DIR/environments.json"
CHECKS_FILE="$TEMP_DATA_DIR/checks.json"
SECUREFILES_FILE="$TEMP_DATA_DIR/securefiles.json"
RELEASE_APPROVALS_FILE="$TEMP_DATA_DIR/release_approvals.json"
MAX_ENV_CHECK_LOOKUPS=300

rm -f "$TEMP_DATA_DIR"/environments.ndjson "$TEMP_DATA_DIR"/checks.ndjson \
      "$TEMP_DATA_DIR"/securefiles.ndjson "$TEMP_DATA_DIR"/release_approvals.ndjson
touch "$TEMP_DATA_DIR"/environments.ndjson "$TEMP_DATA_DIR"/checks.ndjson \
      "$TEMP_DATA_DIR"/securefiles.ndjson "$TEMP_DATA_DIR"/release_approvals.ndjson

for project in "${projects[@]}"; do
    [ -z "$project" ] && continue
    maybe_refresh_token
    project_encoded=$(url_encode "$project")

    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/environments?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{project: $proj, id: (.id // null), name: (.name // "unknown")}' \
        >> "$TEMP_DATA_DIR/environments.ndjson" 2>/dev/null

    call_api_paged \
        "$ORG_URL/$project_encoded/_apis/distributedtask/securefiles?api-version=7.1-preview.1" \
        '.value' \
        | jq -c --arg proj "$project" '{project: $proj, name: (.name // "unknown")}' \
        >> "$TEMP_DATA_DIR/securefiles.ndjson" 2>/dev/null

    # Classic release approvals and gates. $expand=environments returns the
    # approval and gate configuration inline, avoiding a call per definition.
    call_api_paged \
        "https://vsrm.dev.azure.com/$ORG/$project_encoded/_apis/release/definitions?%24expand=environments&api-version=$API_VERSION" \
        '.value' \
        | jq -c --arg proj "$project" '{
            project: $proj,
            name: (.name // "unknown"),
            environments: ((.environments // []) | length),
            manualApprovals: ([(.environments // [])[]
                | select((((.preDeployApprovals.approvals // [])
                           + (.postDeployApprovals.approvals // []))
                          | map(select(.isAutomated == false)) | length) > 0)]
                | length),
            gates: ([(.environments // [])[]
                | select((((.preDeploymentGates.gates // [])
                           + (.postDeploymentGates.gates // [])) | length) > 0)]
                | length)
          }' >> "$TEMP_DATA_DIR/release_approvals.ndjson" 2>/dev/null
done

ndjson_to_array "$TEMP_DATA_DIR/environments.ndjson" "$ENVIRONMENTS_FILE"
ndjson_to_array "$TEMP_DATA_DIR/securefiles.ndjson" "$SECUREFILES_FILE"
ndjson_to_array "$TEMP_DATA_DIR/release_approvals.ndjson" "$RELEASE_APPROVALS_FILE"

total_environments=$(num "$(jq 'length' "$ENVIRONMENTS_FILE" 2>/dev/null)")
total_secure_files=$(num "$(jq 'length' "$SECUREFILES_FILE" 2>/dev/null)")
release_env_count=$(num "$(jq '[.[].environments] | add // 0' "$RELEASE_APPROVALS_FILE" 2>/dev/null)")
release_manual_approvals=$(num "$(jq '[.[].manualApprovals] | add // 0' "$RELEASE_APPROVALS_FILE" 2>/dev/null)")
release_gates=$(num "$(jq '[.[].gates] | add // 0' "$RELEASE_APPROVALS_FILE" 2>/dev/null)")

# YAML environment checks are configured per environment, so they need one
# lookup each. Capped to keep the runtime predictable on very large estates.
if [ "$total_environments" -gt 0 ]; then
    while IFS=$'\t' read -r c_project c_envid; do
        if [ -z "$c_envid" ] || [ "$c_envid" = "null" ]; then
            continue
        fi
        if [ "$env_checks_checked" -ge "$MAX_ENV_CHECK_LOOKUPS" ]; then
            break
        fi
        env_checks_checked=$((env_checks_checked + 1))
        [ $((env_checks_checked % 100)) -eq 0 ] && maybe_refresh_token

        c_project_enc=$(url_encode "$c_project")
        checks_body=$(call_api "$ORG_URL/$c_project_enc/_apis/pipelines/checks/configurations?resourceType=environment&resourceId=$c_envid&api-version=7.1-preview.1")
        [ "$checks_body" = "API_ERROR" ] && continue
        echo "$checks_body" | jq empty 2>/dev/null || continue
        echo "$checks_body" | jq -c --arg proj "$c_project" '
            .value[]? | {project: $proj, type: (.type.name // "Unknown")}' \
            >> "$TEMP_DATA_DIR/checks.ndjson" 2>/dev/null
    done < <(jq -r '.[] | [.project, ((.id // "null") | tostring)] | @tsv' "$ENVIRONMENTS_FILE" 2>/dev/null)

    if [ "$total_environments" -gt "$MAX_ENV_CHECK_LOOKUPS" ]; then
        report_warn "Only the first $MAX_ENV_CHECK_LOOKUPS of $total_environments environments were inspected for approvals and gates - those counts are a LOWER BOUND."
    fi
fi

ndjson_to_array "$TEMP_DATA_DIR/checks.ndjson" "$CHECKS_FILE"
env_approvals=$(num "$(jq '[.[] | select(.type == "Approval")] | length' "$CHECKS_FILE" 2>/dev/null)")
env_gates=$(num "$(jq '[.[] | select(.type == "Task Check" or .type == "CheckTask" or (.type | test("(?i)gate|invoke")))] | length' "$CHECKS_FILE" 2>/dev/null)")
env_other_checks=$(num "$(jq 'length' "$CHECKS_FILE" 2>/dev/null)")
env_other_checks=$((env_other_checks - env_approvals - env_gates))
[ "$env_other_checks" -lt 0 ] && env_other_checks=0

echo "YAML Environments: $total_environments" | tee -a "$REPORT_FILE"
echo "  Environments inspected for checks: $env_checks_checked" | tee -a "$REPORT_FILE"
echo "  Manual approval checks:            $env_approvals" | tee -a "$REPORT_FILE"
echo "  Gate / invoke checks:              $env_gates" | tee -a "$REPORT_FILE"
echo "  Other checks (locks, hours, etc):  $env_other_checks" | tee -a "$REPORT_FILE"
if [ "$env_other_checks" -gt 0 ] || [ "$env_approvals" -gt 0 ] || [ "$env_gates" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "  Check types in use:" | tee -a "$REPORT_FILE"
    jq -r 'group_by(.type) | map({type: .[0].type, count: length}) | sort_by(-.count) | .[]
           | "    - \(.type): \(.count)"' "$CHECKS_FILE" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "Classic Release Approvals & Gates:" | tee -a "$REPORT_FILE"
echo "  Release stages (environments):     $release_env_count" | tee -a "$REPORT_FILE"
echo "  Stages with a manual approval:     $release_manual_approvals" | tee -a "$REPORT_FILE"
echo "  Stages with a deployment gate:     $release_gates" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "Secrets & Secure Files to Recreate:" | tee -a "$REPORT_FILE"
echo "  Secret variables in variable groups: ${total_secret_variables:-0}" | tee -a "$REPORT_FILE"
echo "  Key Vault backed variable groups:    ${keyvault_vargroups:-0}" | tee -a "$REPORT_FILE"
echo "  Secure files (certs, keystores):     $total_secure_files" | tee -a "$REPORT_FILE"
echo "  Service connections to re-auth:      ${total_service_connections:-0}" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Secret VALUES are never readable through the API and are not collected." | tee -a "$REPORT_FILE"
echo "Every item above is a manual re-entry during migration - this is the count" | tee -a "$REPORT_FILE"
echo "to multiply by an effort-per-item assumption." | tee -a "$REPORT_FILE"

# ========================================
# 20. PIPELINE MIGRATION COMPLEXITY
# ========================================
write_section "20. Pipeline Migration Complexity"

# Grouping pipelines by conversion difficulty turns a pipeline count into a
# migration estimate. Classification uses only observed facts: the pipeline
# type, and the job, task and extension-task counts seen in the timeline sample.
# Pipelines that did not run during the window cannot be classified and are
# reported separately rather than assumed simple.

COMPLEXITY_FILE="$TEMP_DATA_DIR/complexity.json"
echo "[]" > "$COMPLEXITY_FILE"

if [ "$(num "$(jq 'length' "$TIMELINE_PERBUILD_FILE" 2>/dev/null)")" -eq 0 ]; then
    echo "Not available: no job-level data was collected (see section 16)." | tee -a "$REPORT_FILE"
    echo "Without it, pipelines can only be split by type:" | tee -a "$REPORT_FILE"
    echo "  YAML:    ${yaml_pipelines:-0}" | tee -a "$REPORT_FILE"
    echo "  Classic: ${classic_pipelines:-0}  (classic always converts as complex)" | tee -a "$REPORT_FILE"
else
    jq -n --slurpfile pb "$TIMELINE_PERBUILD_FILE" --slurpfile defs "$PIPELINE_DEFS_FILE" '
        (($defs[0] // [])
         | map({key: ((.project // "") + "#" + ((.id // 0) | tostring)), value: .})
         | from_entries) as $dmap
        | (($pb[0] // [])
           | map(. + {_key: ((.project // "") + "#" + ((.definitionId // 0) | tostring))})
           | group_by(._key)
           | map({
               key: .[0]._key,
               project: .[0].project,
               definitionId: .[0].definitionId,
               jobs: ([.[].jobs // 0] | max),
               distinctTasks: ([.[].distinctTasks // 0] | max),
               extTasks: ([.[].extTasks // 0] | max),
               observedBuilds: length
             }))
        | map(. + {
            name: (($dmap[.key] // {}) | .name // "unknown"),
            processType: (($dmap[.key] // {}) | .processType // 0)
          })
        | map(. + {
            complexity:
                (if (.processType == 1) or (.jobs >= 3) or (.distinctTasks >= 30) or (.extTasks >= 3)
                 then "complex"
                 elif (.jobs >= 2) or (.distinctTasks >= 10) or (.extTasks >= 1)
                 then "moderate"
                 else "simple" end)
          })' > "$COMPLEXITY_FILE" 2>/dev/null || echo "[]" > "$COMPLEXITY_FILE"

    complexity_observed=$(num "$(jq 'length' "$COMPLEXITY_FILE" 2>/dev/null)")
    complexity_simple=$(num "$(jq '[.[] | select(.complexity == "simple")] | length' "$COMPLEXITY_FILE" 2>/dev/null)")
    complexity_moderate=$(num "$(jq '[.[] | select(.complexity == "moderate")] | length' "$COMPLEXITY_FILE" 2>/dev/null)")
    complexity_complex=$(num "$(jq '[.[] | select(.complexity == "complex")] | length' "$COMPLEXITY_FILE" 2>/dev/null)")

    echo "Classification rules (all observed, none assumed):" | tee -a "$REPORT_FILE"
    echo "  simple   - YAML, 1 job, under 10 distinct tasks, no extension tasks" | tee -a "$REPORT_FILE"
    echo "  moderate - 2 jobs, 10+ distinct tasks, or 1-2 extension tasks" | tee -a "$REPORT_FILE"
    echo "  complex  - classic, 3+ jobs, 30+ distinct tasks, or 3+ extension tasks" | tee -a "$REPORT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Pipelines observed in the timeline sample: $complexity_observed" | tee -a "$REPORT_FILE"
    echo "  Simple:   $complexity_simple" | tee -a "$REPORT_FILE"
    echo "  Moderate: $complexity_moderate" | tee -a "$REPORT_FILE"
    echo "  Complex:  $complexity_complex" | tee -a "$REPORT_FILE"

    if [ "$complexity_observed" -gt 0 ] && [ "${active_pipelines:-0}" -gt "$complexity_observed" ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Extrapolated to all ${active_pipelines} active pipelines (same proportions):" | tee -a "$REPORT_FILE"
        jq -rn --argjson active "$(num "${active_pipelines:-0}")" \
               --argjson obs "$complexity_observed" \
               --argjson s "$complexity_simple" \
               --argjson m "$complexity_moderate" \
               --argjson c "$complexity_complex" '
            "  Simple:   \(($s / $obs * $active) | round)",
            "  Moderate: \(($m / $obs * $active) | round)",
            "  Complex:  \(($c / $obs * $active) | round)"' | tee -a "$REPORT_FILE"
    fi

    if [ "$complexity_complex" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "Most complex pipelines observed (top 15):" | tee -a "$REPORT_FILE"
        jq -r '[.[] | select(.complexity == "complex")]
               | sort_by(-(.extTasks * 100 + .distinctTasks + .jobs)) | .[:15][]
               | "  - \(.project) / \(.name): \(.jobs) jobs, \(.distinctTasks) distinct tasks, \(.extTasks) extension tasks"' \
            "$COMPLEXITY_FILE" | tee -a "$REPORT_FILE"
    fi

    echo "" | tee -a "$REPORT_FILE"
    echo "Dormant pipelines (${dead_pipelines:-0}) are excluded - they should be" | tee -a "$REPORT_FILE"
    echo "retired rather than migrated, and are the cleanup group to confirm." | tee -a "$REPORT_FILE"
fi

# ========================================
# 21. AZURE DEVOPS COMMERCIAL BASELINE
# ========================================
write_section "21. Azure DevOps Commercial Baseline"
maybe_refresh_token

# The quantities that make up the current Azure DevOps bill. Prices are
# deliberately not applied: unit price depends on your own agreement and
# is not exposed by any API. These are the multiplicands only.

RESOURCE_USAGE_FILE="$TEMP_DATA_DIR/resource_usage.json"
ENTITLEMENT_FILE="$TEMP_DATA_DIR/entitlement_summary.json"
echo "[]" > "$RESOURCE_USAGE_FILE"
echo "{}" > "$ENTITLEMENT_FILE"
rm -f "$TEMP_DATA_DIR/resource_usage.ndjson"
touch "$TEMP_DATA_DIR/resource_usage.ndjson"

while IFS=' ' read -r ru_tag ru_hosted; do
    [ -z "$ru_tag" ] && continue
    ru_body=$(call_api "$ORG_URL/_apis/distributedtask/resourceusage?parallelismTag=$ru_tag&poolIsHosted=$ru_hosted&includeRunningRequests=false&api-version=7.1-preview.1")
    [ "$ru_body" = "API_ERROR" ] && continue
    echo "$ru_body" | jq empty 2>/dev/null || continue
    echo "$ru_body" | jq -c --arg tag "$ru_tag" --argjson hosted "$ru_hosted" '{
        parallelismTag: $tag,
        hosted: $hosted,
        purchasedCount: (.resourceLimit.totalCount // .totalCount // null),
        includedMinutes: (.resourceLimit.totalMinutes // null),
        usedCount: (.usedCount // null),
        usedMinutes: (.usedMinutes // null)
      }' >> "$TEMP_DATA_DIR/resource_usage.ndjson" 2>/dev/null
done <<'RU_COMBOS'
Private true
Private false
Public true
RU_COMBOS
ndjson_to_array "$TEMP_DATA_DIR/resource_usage.ndjson" "$RESOURCE_USAGE_FILE"

hosted_parallel_purchased=$(num "$(jq -r '[.[] | select(.hosted == true and .parallelismTag == "Private") | .purchasedCount // 0] | max // 0' "$RESOURCE_USAGE_FILE" 2>/dev/null)")
hosted_parallel_used=$(num "$(jq -r '[.[] | select(.hosted == true and .parallelismTag == "Private") | .usedCount // 0] | max // 0' "$RESOURCE_USAGE_FILE" 2>/dev/null)")
selfhosted_parallel_purchased=$(num "$(jq -r '[.[] | select(.hosted == false and .parallelismTag == "Private") | .purchasedCount // 0] | max // 0' "$RESOURCE_USAGE_FILE" 2>/dev/null)")
selfhosted_parallel_used=$(num "$(jq -r '[.[] | select(.hosted == false and .parallelismTag == "Private") | .usedCount // 0] | max // 0' "$RESOURCE_USAGE_FILE" 2>/dev/null)")

echo "Parallel Jobs (the Azure Pipelines billing unit):" | tee -a "$REPORT_FILE"
if [ "$(num "$(jq 'length' "$RESOURCE_USAGE_FILE" 2>/dev/null)")" -eq 0 ]; then
    echo "  Not available to this account - take the purchased parallel job" | tee -a "$REPORT_FILE"
    echo "  Microsoft-hosted and self-hosted parallel job counts." | tee -a "$REPORT_FILE"
    report_warn "Parallel job entitlement could not be read - take the Azure DevOps pipeline cost baseline from your billing statement."
else
    jq -r '.[] | "  - \(.parallelismTag) / \(if .hosted then "Microsoft-hosted" else "self-hosted" end): purchased \(.purchasedCount // "unknown"), in use \(.usedCount // "unknown")\(if .includedMinutes != null then ", included minutes \(.includedMinutes)" else "" end)"' \
        "$RESOURCE_USAGE_FILE" | tee -a "$REPORT_FILE"
fi

ent_body=$(call_api "https://vsaex.dev.azure.com/$ORG/_apis/userentitlementsummary?select=licenses&api-version=7.1-preview.2")
if [ "$ent_body" != "API_ERROR" ] && echo "$ent_body" | jq empty 2>/dev/null; then
    echo "$ent_body" > "$ENTITLEMENT_FILE"
    echo "" | tee -a "$REPORT_FILE"
    echo "Licence Entitlements (quantities, not prices):" | tee -a "$REPORT_FILE"
    jq -r '
        (.licenses // []) as $l
        | if ($l | length) == 0 then "  Not reported by the API."
          else ($l[] | "  - \(.licenseName // .accountLicenseType // .license // "unknown"): assigned \(.assigned // 0) of \(.total // 0)")
          end' "$ENTITLEMENT_FILE" 2>/dev/null | tee -a "$REPORT_FILE"
else
    echo "" | tee -a "$REPORT_FILE"
    echo "Licence Entitlements: not available to this account." | tee -a "$REPORT_FILE"
    echo "  Section 11 still provides per-user access levels as a substitute." | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "Also part of the current bill, and NOT readable from Azure DevOps:" | tee -a "$REPORT_FILE"
echo "  - unit prices and any enterprise agreement discount" | tee -a "$REPORT_FILE"
echo "  - infrastructure cost of the self-hosted agent fleet" | tee -a "$REPORT_FILE"
echo "  - Azure Artifacts storage tier and any storage overage" | tee -a "$REPORT_FILE"
echo "  - internal or partner effort operating the platform" | tee -a "$REPORT_FILE"

# ========================================
# 22. MIGRATION ASSESSMENT SUMMARY
# ========================================
write_section "22. MIGRATION ASSESSMENT SUMMARY"

# One page containing every figure a cost model needs, each labelled with how it
# was obtained. Anything the API cannot answer is listed explicitly so it is
# recorded as an explicit assumption rather than silently guessed.

if [ "$(num "${jobreq_total:-0}")" -gt 0 ] && [ "$(num "${billable_job_minutes_month:-0}")" -gt 0 ]; then
    weighted_minutes_month=$(jq -rn \
        --argjson m "$(num "${billable_job_minutes_month:-0}")" \
        --argjson f "$(numf "${os_multiplier_factor:-0}")" \
        '($m * $f) | floor' 2>/dev/null)
fi
weighted_minutes_month=$(num "${weighted_minutes_month:-0}")

total_compute_minutes_month=$(( $(num "${billable_job_minutes_month:-0}") + $(num "${deployment_minutes_month:-0}") ))

echo "Organization: $ORG" | tee -a "$REPORT_FILE"
echo "Measurement window: $HISTORY_DAYS days from $HISTORY_START" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "This section is the hand-over summary. If you have been asked to share" | tee -a "$REPORT_FILE"
echo "these findings with a migration or licensing assessment, this page plus" | tee -a "$REPORT_FILE"
echo "the JSON file is what they need." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "Every line is labelled with its basis:" | tee -a "$REPORT_FILE"
echo "  MEASURED     - read directly from the Azure DevOps API" | tee -a "$REPORT_FILE"
echo "  EXTRAPOLATED - measured on a sample, scaled to the estate" | tee -a "$REPORT_FILE"
echo "  UNKNOWN      - not exposed by the API; supply it yourself" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"

echo "A. COMPUTE - inputs to a per-job billing model" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Build wall-clock minutes / month" "${minutes_per_month:-0}" "MEASURED" | tee -a "$REPORT_FILE"
if [ "${timeline_sampled:-0}" -gt 0 ]; then
    if [ "${timeline_is_sample:-0}" = "1" ]; then
        printf '  %-46s %12s  %s\n' "Billable JOB minutes / month" "${billable_job_minutes_month:-0}" "EXTRAPOLATED (${timeline_sampled} builds)" | tee -a "$REPORT_FILE"
    else
        printf '  %-46s %12s  %s\n' "Billable JOB minutes / month" "${billable_job_minutes_month:-0}" "MEASURED" | tee -a "$REPORT_FILE"
    fi
    printf '  %-46s %12s  %s\n' "Job-to-wall-clock expansion ratio" "${job_expansion_ratio:-0}" "MEASURED" | tee -a "$REPORT_FILE"
    printf '  %-46s %12s  %s\n' "Average jobs per build" "${avg_jobs_per_build:-0}" "MEASURED" | tee -a "$REPORT_FILE"
else
    printf '  %-46s %12s  %s\n' "Billable JOB minutes / month" "n/a" "UNKNOWN - section 16 did not run" | tee -a "$REPORT_FILE"
fi
printf '  %-46s %12s  %s\n' "Deployment (release) minutes / month" "${deployment_minutes_month:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "TOTAL compute minutes / month" "$total_compute_minutes_month" "derived" | tee -a "$REPORT_FILE"
if [ "$(num "${jobreq_total:-0}")" -gt 0 ]; then
    printf '  %-46s %12s  %s\n' "OS weighted multiplier (L${MULT_LINUX}/W${MULT_WINDOWS}/M${MULT_MACOS})" "${os_multiplier_factor:-0}x" "MEASURED (${jobreq_window_days}d window)" | tee -a "$REPORT_FILE"
    printf '  %-46s %12s  %s\n' "Linux-equivalent minutes / month" "${weighted_minutes_month:-0}" "derived" | tee -a "$REPORT_FILE"
else
    printf '  %-46s %12s  %s\n' "OS weighted multiplier" "n/a" "UNKNOWN - Win/Linux/macOS split unmeasured" | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "B. RUNNER FLEET SIZING" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Peak concurrent builds" "${peak_concurrency:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Average concurrent builds" "${avg_concurrency:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Queue wait P95 (seconds)" "${queue_p95:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Self-hosted pools" "${selfhosted_pools:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Self-hosted agents" "${total_agents:-0}" "MEASURED" | tee -a "$REPORT_FILE"
if [ "${agents_with_cpu:-0}" -gt 0 ]; then
    printf '  %-46s %12s  %s\n' "Self-hosted fleet vCPU" "${total_vcpu:-0}" "MEASURED (${agents_with_cpu} agents)" | tee -a "$REPORT_FILE"
else
    printf '  %-46s %12s  %s\n' "Self-hosted fleet vCPU" "n/a" "UNKNOWN - ask for VM sizes" | tee -a "$REPORT_FILE"
fi
printf '  %-46s %12s  %s\n' "Self-hosted infrastructure cost" "n/a" "UNKNOWN - supply this" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "C. SEATS" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Total users" "${user_count:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Active users (90 days)" "${active_90:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Never signed in" "${never_accessed:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Stakeholders (free in ADO, often paid elsewhere)" "${stakeholder_count:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Unique committers (committer-licensing unit)" "${unique_committers:-0}" "MEASURED" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "D. CURRENT AZURE DEVOPS BASELINE" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "MS-hosted parallel jobs purchased" "${hosted_parallel_purchased:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Self-hosted parallel jobs purchased" "${selfhosted_parallel_purchased:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Unit prices / EA discount" "n/a" "UNKNOWN - supply this" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Artifacts storage cost" "n/a" "UNKNOWN - supply this" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "E. MIGRATION EFFORT" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Active pipelines (in scope)" "${active_pipelines:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Dormant pipelines (retire, do not migrate)" "${dead_pipelines:-0}" "MEASURED" | tee -a "$REPORT_FILE"
if [ "${complexity_observed:-0}" -gt 0 ]; then
    printf '  %-46s %12s  %s\n' "Observed simple / moderate / complex" "${complexity_simple}/${complexity_moderate}/${complexity_complex}" "MEASURED" | tee -a "$REPORT_FILE"
else
    printf '  %-46s %12s  %s\n' "Complexity split" "n/a" "UNKNOWN - section 16 did not run" | tee -a "$REPORT_FILE"
fi
printf '  %-46s %12s  %s\n' "Classic release pipelines (rewrite)" "${total_release_defs:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Task groups (become composite actions)" "${total_taskgroups:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Extension tasks actually in use" "${ext_tasks_used:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Service connections to recreate" "${total_service_connections:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Secret variables to re-enter" "${total_secret_variables:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Secure files to re-upload" "${total_secure_files:-0}" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Approvals + gates to rebuild" "$(( env_approvals + env_gates + release_manual_approvals + release_gates ))" "MEASURED" | tee -a "$REPORT_FILE"
printf '  %-46s %12s  %s\n' "Integrations needing custom work" "${custom_count:-0}" "MEASURED" | tee -a "$REPORT_FILE"

echo "" | tee -a "$REPORT_FILE"
echo "F. PLEASE PROVIDE THESE ALONGSIDE THE REPORT" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
echo "  None of the following is exposed by any Azure DevOps API, so it cannot" | tee -a "$REPORT_FILE"
echo "  be collected automatically. Whoever prepares the cost assessment will" | tee -a "$REPORT_FILE"
echo "  need it. Rough figures or ranges are fine - where something is genuinely" | tee -a "$REPORT_FILE"
echo "  unknown, say so and it will be recorded as a stated assumption." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "  1. Cost of the self-hosted agent infrastructure (VMs, storage, network)." | tee -a "$REPORT_FILE"
echo "  2. Azure DevOps unit prices and any enterprise agreement discount." | tee -a "$REPORT_FILE"
echo "  3. Internal or partner effort operating the platform today (FTE)." | tee -a "$REPORT_FILE"
echo "  4. Whether the comparison should cover the current estate or the estate" | tee -a "$REPORT_FILE"
echo "     after retiring the ${dead_pipelines:-0} dormant pipelines." | tee -a "$REPORT_FILE"
echo "  5. Workloads that cannot move for compliance, networking or technical" | tee -a "$REPORT_FILE"
echo "     reasons, and therefore stay on self-hosted runners." | tee -a "$REPORT_FILE"
echo "  6. Whether migration and professional services are in or out of scope." | tee -a "$REPORT_FILE"
echo "  7. The unit rates current at the time of your analysis for whichever" | tee -a "$REPORT_FILE"
echo "     platforms you are comparing, plus any vendor quotes held." | tee -a "$REPORT_FILE"
if [ "$(num "${jobreq_total:-0}")" -eq 0 ]; then
    echo "  8. The Windows, Linux and macOS split of pipeline minutes - this could" | tee -a "$REPORT_FILE"
    echo "     not be measured and is the largest single cost variable." | tee -a "$REPORT_FILE"
fi

echo "" | tee -a "$REPORT_FILE"
echo "RECONCILIATION NOTE" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
echo "If another report quotes a minute figure that differs from the numbers above," | tee -a "$REPORT_FILE"
echo "establish which measure it is before comparing anything:" | tee -a "$REPORT_FILE"
echo "  - build wall-clock            -> section 12 (${minutes_per_month:-0} /month)" | tee -a "$REPORT_FILE"
echo "  - job execution time          -> section 16 (${raw_job_minutes_month:-0} /month)" | tee -a "$REPORT_FILE"
echo "  - job time with Actions round -> section 16 (${billable_job_minutes_month:-0} /month)" | tee -a "$REPORT_FILE"
echo "  - agent lease or availability -> not measured here; ask how it was produced" | tee -a "$REPORT_FILE"
echo "A figure that matches none of these is most likely agent availability or a" | tee -a "$REPORT_FILE"
echo "different reporting period, and must not have an Actions rate applied to it." | tee -a "$REPORT_FILE"

# Sharing is the point of this report, so state plainly what is and is not in
# it. An administrator should be able to satisfy themselves in one screen that
# nothing sensitive leaves the organization.
echo "" | tee -a "$REPORT_FILE"
echo "BEFORE YOU SHARE THIS REPORT" | tee -a "$REPORT_FILE"
echo "----------------------------------------------------------------" | tee -a "$REPORT_FILE"
echo "This report was produced by read-only API calls. Nothing was created," | tee -a "$REPORT_FILE"
echo "changed or deleted in Azure DevOps." | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "This report CONTAINS:" | tee -a "$REPORT_FILE"
echo "  - counts, durations, dates and aggregate statistics" | tee -a "$REPORT_FILE"
echo "  - names of projects, repositories, pipelines, agent pools," | tee -a "$REPORT_FILE"
echo "    environments, variable groups and service connections" | tee -a "$REPORT_FILE"
echo "  - names of installed extensions and the tasks pipelines execute" | tee -a "$REPORT_FILE"
if [ "$SCAN_LARGE_FILES" = "1" ]; then
    echo "  - paths of large files found in repositories (SCAN_LARGE_FILES=1)" | tee -a "$REPORT_FILE"
fi
echo "" | tee -a "$REPORT_FILE"
echo "It does NOT contain:" | tee -a "$REPORT_FILE"
echo "  - any secret, password, token, certificate or variable VALUE" | tee -a "$REPORT_FILE"
echo "  - source code or file contents" | tee -a "$REPORT_FILE"
echo "  - work item titles, descriptions or comments (only a count is read)" | tee -a "$REPORT_FILE"
echo "  - build logs, test output or commit messages" | tee -a "$REPORT_FILE"
echo "  - names or email addresses of individual people" | tee -a "$REPORT_FILE"
echo "  - the location of any secret scanning finding (counts only)" | tee -a "$REPORT_FILE"
echo "" | tee -a "$REPORT_FILE"
echo "People appear only as COUNTS (licence totals, active users, distinct" | tee -a "$REPORT_FILE"
echo "pipeline authors). No individual is identified." | tee -a "$REPORT_FILE"
if [ "$EXPORT_USER_DETAILS" = "1" ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "EXCEPTION - you ran with EXPORT_USER_DETAILS=1:" | tee -a "$REPORT_FILE"
    echo "  A separate users CSV was written containing DISPLAY NAMES and" | tee -a "$REPORT_FILE"
    echo "  EMAIL ADDRESSES. That file is personal data. It is not part of" | tee -a "$REPORT_FILE"
    echo "  this report and is not needed for estate sizing - keep it" | tee -a "$REPORT_FILE"
    echo "  internal and do not include it when sharing these findings." | tee -a "$REPORT_FILE"
fi
if [ "$EXPORT_SECRET_DETAILS" = "1" ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "EXCEPTION - you ran with EXPORT_SECRET_DETAILS=1:" | tee -a "$REPORT_FILE"
    echo "  Separate secret scanning files were written identifying the FILE" | tee -a "$REPORT_FILE"
    echo "  PATH, LINE NUMBER and BRANCH of each detected credential (never the" | tee -a "$REPORT_FILE"
    echo "  values). That is a map of where your unremediated secrets are. It" | tee -a "$REPORT_FILE"
    echo "  is not part of this report and is not needed for estate sizing -" | tee -a "$REPORT_FILE"
    echo "  keep it internal and do not include it when sharing these findings." | tee -a "$REPORT_FILE"
fi
echo "" | tee -a "$REPORT_FILE"
echo "Project and pipeline names can still be commercially sensitive. Review" | tee -a "$REPORT_FILE"
echo "this report before sending it outside your organization and redact any" | tee -a "$REPORT_FILE"
echo "names you would rather not disclose - the counts and minutes stay" | tee -a "$REPORT_FILE"
echo "usable without them." | tee -a "$REPORT_FILE"

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
echo "Stakeholder users (free in ADO): ${stakeholder_count:-0}" | tee -a "$REPORT_FILE"
echo "Unique committers: ${unique_committers:-0}" | tee -a "$REPORT_FILE"

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
echo "--- 4. Integrations & Extensions ---" | tee -a "$REPORT_FILE"
echo "Service Connections: ${total_service_connections:-0}" | tee -a "$REPORT_FILE"
echo "Marketplace Extensions: ${total_extensions:-0}" | tee -a "$REPORT_FILE"
echo "Service Hooks: $total_hooks" | tee -a "$REPORT_FILE"
echo "Native platform feature: ${oob_count:-0}" | tee -a "$REPORT_FILE"
echo "Off-the-shelf component: ${market_count:-0}" | tee -a "$REPORT_FILE"
echo "Publisher-supported: ${partner_count:-0}" | tee -a "$REPORT_FILE"
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
  --argjson tlSampled "$(num "${timeline_sampled:-0}")" \
  --argjson tlStride "$(num "${timeline_stride:-1}")" \
  --argjson tlIsSample "$(num "${timeline_is_sample:-0}")" \
  --argjson tlJobs "$(num "${timeline_jobs:-0}")" \
  --argjson avgJobsPerBuild "$(numf "${avg_jobs_per_build:-0}")" \
  --argjson expansionRatio "$(numf "${job_expansion_ratio:-0}")" \
  --argjson billableWindow "$(num "${billable_job_minutes_window:-0}")" \
  --argjson billableMonth "$(num "${billable_job_minutes_month:-0}")" \
  --argjson rawJobMonth "$(num "${raw_job_minutes_month:-0}")" \
  --argjson tasksUsed "$(num "${distinct_tasks_used:-0}")" \
  --argjson extTasksUsed "$(num "${ext_tasks_used:-0}")" \
  --argjson jobReqTotal "$(num "${jobreq_total:-0}")" \
  --argjson jobReqDays "$(numf "${jobreq_window_days:-0}")" \
  --argjson osFactor "$(numf "${os_multiplier_factor:-0}")" \
  --argjson multLinux "$(numf "$MULT_LINUX")" \
  --argjson multWindows "$(numf "$MULT_WINDOWS")" \
  --argjson multMacos "$(numf "$MULT_MACOS")" \
  --argjson weightedMonth "$(num "${weighted_minutes_month:-0}")" \
  --argjson avgConcurrency "$(numf "${avg_concurrency:-0}")" \
  --argjson fleetVcpu "$(num "${total_vcpu:-0}")" \
  --argjson agentsWithCpu "$(num "${agents_with_cpu:-0}")" \
  --argjson deployments "$(num "${total_deployments:-0}")" \
  --argjson deployMinutesWindow "$(num "${deployment_minutes_window:-0}")" \
  --argjson deployMinutesMonth "$(num "${deployment_minutes_month:-0}")" \
  --argjson environments "$(num "${total_environments:-0}")" \
  --argjson envInspected "$(num "${env_checks_checked:-0}")" \
  --argjson envApprovals "$(num "${env_approvals:-0}")" \
  --argjson envGates "$(num "${env_gates:-0}")" \
  --argjson envOtherChecks "$(num "${env_other_checks:-0}")" \
  --argjson relEnvs "$(num "${release_env_count:-0}")" \
  --argjson relApprovals "$(num "${release_manual_approvals:-0}")" \
  --argjson relGates "$(num "${release_gates:-0}")" \
  --argjson secureFiles "$(num "${total_secure_files:-0}")" \
  --argjson secretVariables "$(num "${total_secret_variables:-0}")" \
  --argjson cxObserved "$(num "${complexity_observed:-0}")" \
  --argjson cxSimple "$(num "${complexity_simple:-0}")" \
  --argjson cxModerate "$(num "${complexity_moderate:-0}")" \
  --argjson cxComplex "$(num "${complexity_complex:-0}")" \
  --argjson hostedPurchased "$(num "${hosted_parallel_purchased:-0}")" \
  --argjson hostedUsed "$(num "${hosted_parallel_used:-0}")" \
  --argjson selfPurchased "$(num "${selfhosted_parallel_purchased:-0}")" \
  --argjson selfUsed "$(num "${selfhosted_parallel_used:-0}")" \
  --slurpfile osMix <(jq '.byOs // []' "${JOBREQ_STATS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile imageMix <(jq '.byImage // []' "${JOBREQ_STATS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile taskUsage <(jq '.[:50]' "${TASK_USAGE_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile checkTypes <(jq 'group_by(.type) | map({type: .[0].type, count: length}) | sort_by(-.count)' "${CHECKS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile resourceUsage <(cat "${RESOURCE_USAGE_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile deployStats <(cat "${DEPLOY_STATS_FILE:-/dev/null}" 2>/dev/null || echo '{}') \
  --slurpfile buildStats "${BUILD_STATS_FILE:-/dev/null}" \
  --slurpfile connTypes <(jq 'group_by(.type) | map({type: .[0].type, count: length}) | sort_by(-.count)' "${SERVICE_CONN_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile extList <(jq 'map({publisher, name})' "${EXTENSIONS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --slurpfile warnList <(jq -R -s 'split("\n") | map(select(length > 0))' "${WARNINGS_FILE:-/dev/null}" 2>/dev/null || echo '[]') \
  --argjson throttled "$(num "$(http_throttle_count)")" \
  --slurpfile httpErrors <(jq -R -s 'split("\n") | map(select(length > 0)) | group_by(.) | map({status: .[0], count: length}) | sort_by(-.count)' "${HTTP_STATUS_LOG:-/dev/null}" 2>/dev/null || echo '[]') \
  '{
    meta: {
      organization: $org,
      generatedUtc: $generated,
      historyWindowDays: $historyDays,
      historyStart: $historyStart,
      dataComplete: ((($warnList[0] // []) | length) == 0),
      warnings: ($warnList[0] // []),
      throttledRequests: $throttled,
      failedRequestsByStatus: ($httpErrors[0] // []),
      schemaVersion: "1.2"
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
      averageConcurrentBuilds: $avgConcurrency,
      queueWaitP50Seconds: $queueP50,
      queueWaitP95Seconds: $queueP95,
      agentPools: { total: $totalPools, microsoftHosted: $hostedPools, selfHosted: $selfHostedPools },
      selfHostedAgents: { registered: $totalAgents, online: $onlineAgents, reportingCpu: $agentsWithCpu, totalVcpu: $fleetVcpu },
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
    },
    tco: {
      jobCompute: {
        basis: (if $tlSampled == 0 then "not-collected"
                elif $tlIsSample == 1 then "extrapolated"
                else "measured" end),
        sampleBuilds: $tlSampled,
        sampleStride: $tlStride,
        sampleJobs: $tlJobs,
        averageJobsPerBuild: $avgJobsPerBuild,
        billableToWallClockRatio: $expansionRatio,
        billableJobMinutesInWindow: $billableWindow,
        billableJobMinutesPerMonth: $billableMonth,
        rawJobMinutesPerMonth: $rawJobMonth,
        distinctTasksExecuted: $tasksUsed,
        extensionTasksExecuted: $extTasksUsed,
        topTasks: ($taskUsage[0] // [])
      },
      runnerMix: {
        basis: (if $jobReqTotal == 0 then "not-available" else "measured" end),
        jobRequestsObserved: $jobReqTotal,
        observedWindowDays: $jobReqDays,
        weightedMultiplier: $osFactor,
        multipliersApplied: { linux: $multLinux, windows: $multWindows, macos: $multMacos },
        linuxEquivalentMinutesPerMonth: $weightedMonth,
        byOperatingSystem: ($osMix[0] // []),
        byImage: ($imageMix[0] // [])
      },
      deployments: {
        countInWindow: $deployments,
        minutesInWindow: $deployMinutesWindow,
        minutesPerMonth: $deployMinutesMonth,
        byStatus: ($deployStats[0].byStatus // []),
        topEnvironments: ($deployStats[0].topEnvironments // [])
      },
      approvalsAndSecrets: {
        yamlEnvironments: $environments,
        yamlEnvironmentsInspected: $envInspected,
        yamlApprovalChecks: $envApprovals,
        yamlGateChecks: $envGates,
        yamlOtherChecks: $envOtherChecks,
        checkTypes: ($checkTypes[0] // []),
        releaseStages: $relEnvs,
        releaseManualApprovals: $relApprovals,
        releaseGates: $relGates,
        secretVariables: $secretVariables,
        secureFiles: $secureFiles,
        totalToRebuild: ($envApprovals + $envGates + $relApprovals + $relGates)
      },
      complexity: {
        basis: (if $cxObserved == 0 then "not-collected" else "observed-sample" end),
        pipelinesObserved: $cxObserved,
        simple: $cxSimple,
        moderate: $cxModerate,
        complex: $cxComplex
      },
      commercial: {
        microsoftHostedParallelJobsPurchased: $hostedPurchased,
        microsoftHostedParallelJobsInUse: $hostedUsed,
        selfHostedParallelJobsPurchased: $selfPurchased,
        selfHostedParallelJobsInUse: $selfUsed,
        rawResourceUsage: ($resourceUsage[0] // [])
      },
      inputsYouMustSupply: [
        "self-hosted agent infrastructure cost",
        "Azure DevOps unit prices and enterprise agreement discount",
        "internal or partner effort operating the platform (FTE)",
        "whether the scope is the current or post-cleanup estate",
        "workloads that cannot move for compliance or networking reasons",
        "whether migration and professional services are in scope",
        "any competing quote and what it includes"
      ]
        + (if $jobReqTotal == 0
           then ["Windows / Linux / macOS split of pipeline minutes"]
           else [] end)
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

# API health. Throttling is the one failure mode that is entirely recoverable
# by re-running, so it is separated from permission errors (which are not) to
# stop an operator concluding the tool "does not work" when it simply needs a
# quieter moment or a narrower window.
throttle_total=$(num "$(http_throttle_count)")
http_fail_total=$(num "$(grep -c . "$HTTP_STATUS_LOG" 2>/dev/null)")
if [ "$http_fail_total" -gt 0 ]; then
    echo "" | tee -a "$REPORT_FILE"
    echo "API request failures by cause:" | tee -a "$REPORT_FILE"
    sort "$HTTP_STATUS_LOG" 2>/dev/null | uniq -c | sort -rn | while read -r c code; do
        echo "  $c x $(http_status_hint "$code")" | tee -a "$REPORT_FILE"
    done
    if [ "$throttle_total" -gt 0 ]; then
        echo "" | tee -a "$REPORT_FILE"
        echo "  Azure DevOps rate-limited $throttle_total request(s). The collector" | tee -a "$REPORT_FILE"
        echo "  automatically slowed itself down and retried, but any section that" | tee -a "$REPORT_FILE"
        echo "  still reported a warning above may be understated." | tee -a "$REPORT_FILE"
        echo "  To reduce throttling, re-run at a quieter time, lower HISTORY_DAYS," | tee -a "$REPORT_FILE"
        echo "  or set API_PACING_MS=250 to pace requests from the start." | tee -a "$REPORT_FILE"
    fi
fi

echo "" | tee -a "$REPORT_FILE"
echo "========================================" | tee -a "$REPORT_FILE"
echo "Report generation complete!" | tee -a "$REPORT_FILE"
echo "Report saved to: $REPORT_FILE" | tee -a "$REPORT_FILE"
[ -s "$SIZING_JSON" ] && echo "Structured sizing data saved to: $SIZING_JSON" | tee -a "$REPORT_FILE"
[ "$EXPORT_USER_DETAILS" = "1" ] && [ -s "$USER_CSV" ] && \
    echo "User export saved to: $USER_CSV (contains personal data - keep internal)" | tee -a "$REPORT_FILE"
if [ "$EXPORT_SECRET_DETAILS" = "1" ] && [ "$total_secret_alerts" -gt 0 ] && [ -f "$SECRET_SCANNING_REPORT" ]; then
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
