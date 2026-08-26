# Azure DevOps Data Collection Report

A script to collect data from Azure DevOps organizations.
This is designed as an easy script for Azure DevOps Administrators to run on each organization to understand their ADO landscape. 
Solving "As an ADO Administrator I don't want to write a custom API script or click through many pages to get visibility into ADO data."

## Overview

The `ado-data-collector.sh` script automates the collection of data from your Azure DevOps organization. It analyzes projects, repositories, pipelines, integrations, users, and metadata, producing a data-driven report.

It answers two related questions:

1. **What is in this Azure DevOps organization?** — repositories, work items, users, security alerts.
2. **What would it cost to move CI/CD to GitHub Actions?** — runner compute, seat count, pipeline conversion volume, integration surface, and the denominators needed to size ongoing support.

The report states **factual data only**. It does not price anything or make recommendations — it produces the inputs a cost model or a proposal needs.

### Read-only guarantee

**This script never writes to Azure DevOps.** It only reads. That is enforced in code, not left to convention, so an accidental write cannot slip in through a later change:

| Guard | What it does |
|---|---|
| **Method pinning** | Every HTTP request is sent with an explicit `-X GET`. Adding a body flag (`-d`) to a read helper cannot silently promote it to a `POST`. |
| **POST allow-list** | Exactly one endpoint is reached over `POST`: `_apis/wit/wiql`. WIQL runs a work-item *query* and returns matching IDs — it changes nothing, and Azure DevOps offers no `GET` form of it. Any other `POST` target aborts the run. |
| **Host allow-list** | Requests must be HTTPS and must target a known Azure DevOps read host (`dev.azure.com`, `vsrm.`, `vsaex.`, `advsec.`, `extmgmt.`). |
| **Redirect safety** | Redirects cannot downgrade to plain HTTP, and the WIQL query does not follow redirects at all, so a `307`/`308` cannot replay its body against a different target. |
| **Git** | Repositories are cloned `--bare` (a fetch) and inspected locally with `log`, `rev-list`, and `cat-file`. The clone is configured with an unusable push URL, so an accidental `git push` fails locally. |
| **Azure CLI** | Used only for `az account show` and `az account get-access-token`. |
| **Fail closed** | Any violation aborts the entire run immediately with exit code `3`, rather than degrading quietly. |

Everything the script produces is written to your local working directory.

If you extend the script, a new host or a new `POST` endpoint must be added deliberately to `ADO_ALLOWED_HOSTS` or `ADO_ALLOWED_POST_PATHS` in the `READ-ONLY ENFORCEMENT` section — otherwise the run stops with a clear error. Verify the enforcement yourself at any time:

```bash
# Should print exactly one -X POST, inside call_api_readonly_query
grep -nE '\-X (POST|PUT|PATCH|DELETE)' ado-data-collector.sh

# Should print exactly three curl calls, each preceded by an assert_read_only_* guard
grep -n 'curl ' ado-data-collector.sh
```

### Relationship to GitHub Actions Importer

This script **complements** [`gh actions-importer audit azure-devops`](https://docs.github.com/en/actions/migrating-to-github-actions/using-github-actions-importer); it does not replace it.

| Question | Use |
|---|---|
| How hard is each individual pipeline to convert? Which tasks are unsupported? | `gh actions-importer audit` |
| How much runner compute does the estate consume? How many seats? Which pipelines are dead? What third-party tools are we coupled to? | This script |

Run both. The Importer gives per-pipeline conversion rates; this script gives the spend and scope numbers the Importer does not collect.

## Prerequisites

Before running the script, ensure you have the following:

### Azure DevOps Organization Settings

1. **Third-Party application access via OAuth** must be enabled:
   - Go to your Azure DevOps organization: `https://dev.azure.com/{your-org}`
   - Click **Organization settings** (bottom left)
   - Navigate to **Policies** under Security
   - Enable **Third-party application access via OAuth**

2. **Azure account access**: Your Azure account must have access to the Azure DevOps organization you want to scan

3. **Permissions**: A **Project Collection Administrator** (or equivalent) account returns complete data. With lower privilege the script still runs, but some sections degrade silently to zero:

   | Data | Needed for | If not permitted |
   |---|---|---|
   | User entitlements (`vsaex`) | Section 11 licensing | User count reports 0 |
   | Agent pools and agents | Sections 12, 13 runner sizing | Pool/agent counts report 0 |
   | Service connections | Sections 10, 14 | Connections report 0 |
   | Installed extensions (`extmgmt`) | Sections 10, 14 | Extensions report 0 |
   | Release definitions (`vsrm`) | Section 8 | Release pipelines report 0 |

   Run with `DEBUG=1` to see which calls fail.

### Required Tools

1. **Azure CLI** (for authentication):
   ```bash
   # macOS
   brew install azure-cli
   
   # Linux (Ubuntu/Debian)
   curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
   
   # Linux (RHEL/CentOS)
   sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
   sudo dnf install azure-cli
   ```

2. **jq** (JSON processor):
   ```bash
   # macOS
   brew install jq
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install jq
   
   # Linux (RHEL/CentOS)
   sudo yum install jq
   ```

3. **curl** (usually pre-installed on most systems)

4. **git** (required only if using `SCAN_LARGE_FILES=1` option):
   ```bash
   # macOS
   brew install git
   
   # Linux (Ubuntu/Debian)
   sudo apt-get install git
   
   # Linux (RHEL/CentOS)
   sudo yum install git
   ```

## Setup Instructions

### Step 1: Login to Azure

The script uses Azure AD authentication via the Azure CLI. This is more secure than PAT tokens and provides access to all Azure DevOps APIs including Advanced Security.

```bash
# Login to Azure (opens browser for authentication)
az login

# Verify you're logged in
az account show
```

**Note**: Your Azure account must have access to the Azure DevOps organization you want to scan.

### Step 2: Set Organization Name

The script requires you to specify your Azure DevOps organization name via the `ORG` environment variable:

```bash
# Set your organization name
export ORG="your-org-name"

# Or set it inline when running the script
ORG="your-org-name" ./ado-data-collector.sh
```

**Note**: The script will fail with a clear error message if `ORG` is not set, preventing accidental runs against invalid organizations.

### Step 3: Make the Script Executable

```bash
chmod +x ado-data-collector.sh
```

### Step 4: Run the Script

```bash
# Run with default mode (API-only, faster)
ORG="your-org-name" ./ado-data-collector.sh

# Run with large file scanning (clones repos, slower but detects individual
# large files AND counts unique committers for GHAS sizing)
ORG="your-org-name" SCAN_LARGE_FILES=1 ./ado-data-collector.sh

# Run with debug output to see API calls
ORG="your-org-name" DEBUG=1 ./ado-data-collector.sh

# Combine options
ORG="your-org-name" DEBUG=1 SCAN_LARGE_FILES=1 ./ado-data-collector.sh
```

> **First run on a new organization:** start small to confirm access and shape
> before committing to a long run:
> ```bash
> ORG="your-org-name" HISTORY_DAYS=7 DEBUG=1 ./ado-data-collector.sh
> ```
> Check the section 12 build counts look plausible, then re-run with defaults.

#### Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `ORG` | *(required)* | Azure DevOps organization name |
| `DEBUG` | `0` | Print every API call to stderr |
| `SCAN_LARGE_FILES` | `0` | Clone repos to find files >50MB and count unique committers |
| `HISTORY_DAYS` | `90` | Build history window used for runner sizing. Lower it for a fast first pass |
| `SKIP_BUILD_HISTORY` | `0` | Set to `1` to skip section 12 entirely — much faster, but you lose all runner-cost data |
| `MAX_BUILDS_PER_PROJECT` | `20000` | Safety cap on builds fetched per project. Enforced as a page cap (1000 builds/page), so it is rounded to whole pages, with a floor of one page (1000 builds). If a project hits the cap, the run warns and flags its figures as a lower bound |
| `TOKEN_MAX_AGE` | `2400` | Seconds before the Azure AD token is proactively refreshed |

### Trusting the numbers: data completeness

Sizing infrastructure from a silently truncated collection is the most expensive
mistake this tool could cause, so incomplete reads are made loud rather than quiet.

If pagination fails part-way through (an expired token, a permission boundary, a
transient 5xx that outlives the retries) or a page cap is reached, the run does
**not** fail — partial data is still more useful than none. Instead it:

1. writes a `[WARN]` line to stderr,
2. appends the warning inline in the report where it happened,
3. aggregates every warning under a **DATA COMPLETENESS** section at the end of the report, and
4. sets `meta.dataComplete: false` and lists the warnings in `meta.warnings[]` in the JSON.

Before relying on any runner or licensing figure, check that section:

```bash
jq '.meta | {dataComplete, warnings}' ado-sizing-*.json
```

`dataComplete: true` means every figure reflects a complete read of the data your
account is permitted to see. `false` means at least one number is a lower bound —
re-run, usually with a shorter `HISTORY_DAYS` or a token with broader scope.

Note the distinction the script draws between two kinds of failure:

- **API failures degrade.** A permission boundary or a transient error never aborts the run; you still get a report, with the affected section flagged.
- **Configuration errors fail fast.** `HISTORY_DAYS`, `MAX_BUILDS_PER_PROJECT` and `TOKEN_MAX_AGE` are validated as positive integers before any work starts. A typo exits immediately rather than producing a plausible-looking report built on a nonsense window.

The script will:
- Validate authentication before starting
- Display progress information in the console
- Generate a timestamped report file: `ado-data-report-YYYYMMDD-HHMMSS-XXXXX.txt`
- Generate a machine-readable `ado-sizing-YYYYMMDD-HHMMSS-XXXXX.json`
- Automatically clean up temporary data on completion or interruption

**Expected Runtime**: 
- **Default mode**: 10-30 minutes depending on organization size. Build history collection (section 12) is the slowest part — it fetches up to `HISTORY_DAYS` of builds for every project
- **With `SKIP_BUILD_HISTORY=1`**: 5-15 minutes
- **With `SCAN_LARGE_FILES=1`**: add 10-30 minutes (clones repositories)

## Features

### Complete Result Sets
- All list endpoints follow Azure DevOps continuation tokens, so counts are not silently truncated on large estates
- User entitlements use `$top`/`$skip` paging
- Azure AD tokens are refreshed automatically during long runs

### Robust Error Handling
- Early authentication validation with clear error messages
- Graceful handling of API failures and network timeouts
- Automatic retry logic for transient failures (30-second timeout, 2 retries)
- Concurrent execution safety with unique temp directories per run

### Edge Case Support
- Handles project/repository names with spaces, special characters, UTF-8, quotes, and backslashes
- Safely processes empty organizations or projects with no repositories
- Properly encodes all URLs for API compatibility
- Locale-independent sorting for consistent results
- Date arithmetic performed in `jq`, so it behaves identically on macOS (BSD) and Linux (GNU)

## Report Contents

The generated report includes factual data only, it does not make assessments or recommendations:

### 1. **Repository Count**
   - Total number of projects and repositories

### 2. **Repositories Over 1GB (API-Reported Size)**
   - List of repositories exceeding 1GB based on Azure DevOps API size metric
   - Sizes shown in GB

### 3. **Largest Repository (API-Reported Size)**
   - Repository with the largest API-reported size
   - Size shown in MB or GB

### 4. **Oldest Repository**
   - Repository with the earliest commit
   - First commit date and ID

### 5. **Large Files Scan (Individual File Sizes)**
   - **Default mode**: Shows instructions for manual inspection
   - **With SCAN_LARGE_FILES=1**: Automatically scans Git history for files >50MB
     - Lists all large files with exact sizes
     - Includes files from entire Git history (even if deleted)
     - Provides GitHub migration guidance (50MB warning, 100MB block)

### 6. **Metadata Data**
   - Work items count
   - Pull requests count
   - Projects with boards/teams

### 7. **Pipeline Data**
   - Total pipelines count
   - Repositories with pipelines

### 8. **Pipeline Inventory** (migration effort)
   - **YAML vs Classic split** — the single biggest driver of conversion effort. Classic (designer) pipelines have no YAML source and must be rebuilt
   - Disabled pipelines
   - Pipelines sourced from somewhere other than Azure Repos
   - **Classic release pipelines** (collected from `vsrm.dev.azure.com` — invisible to the build API, and almost always a full rewrite)
   - **Task groups** — no GitHub equivalent; each becomes a composite action or reusable workflow
   - **Variable groups** and variable counts, flagging Key Vault-backed groups
   - Per-project distribution (top 15)

### 9. **Security Scanning (Advanced Security)**
   - **If Advanced Security is enabled**: Reports on security alerts
     - Secret scanning alerts (credentials, tokens, API keys)
       - **Detailed export**: All secret alert details exported to separate report file
       - Includes validation status, file locations, severity, confidence levels, and timelines
     - Dependency scanning alerts (vulnerable packages)
     - Code scanning alerts (security vulnerabilities)
     - Repositories with security alerts
   - **If not enabled**: Provides information about the feature and alternatives
   - Note: Azure DevOps Advanced Security is a paid add-on feature

### 10. **Integrations, Extensions & Service Connections**
   - Service hooks, with consumer types and counts
   - **Service connections** by type (Azure RM, Salesforce, Artifactory, Docker registries, etc.)
   - **Installed Marketplace extensions** (first-party built-ins excluded)

### 11. **Licensing & User Activity**
   - Total users and access-level breakdown
   - **Active in 30 / 60 / 90 days** and **never signed in** — dormant accounts are licence waste that should not be carried into a GitHub seat count
   - **Stakeholder count**, with an explicit warning: Azure DevOps Stakeholder licences are free, but the equivalent GitHub user consumes a paid seat
   - Visual Studio subscriber count (`licensingSource = msdn`)
   - Likely service/bot accounts (name heuristic)
   - **Unique committers** (only with `SCAN_LARGE_FILES=1`) — the GitHub Advanced Security billing unit
   - Exported user list (CSV)

### 12. **Build Activity & Runner Sizing** (infrastructure cost)
   - Builds in the history window, normalised to builds/month
   - **Total and monthly compute minutes**
   - Average / median / P95 build duration
   - **Peak concurrent builds** (sweep-line over start/finish times) — this sizes the runner fleet
   - Queue wait P50 / P95 — evidence of existing capacity pressure
   - Build outcome breakdown
   - **Minutes by agent pool**, split Microsoft-hosted vs self-hosted
   - **Dormant pipelines** — definitions with no runs in the window. These are retirement candidates, not migration candidates, and typically remove a meaningful slice of the conversion effort

   > **Sizing caveat:** Azure DevOps minutes do not convert 1:1 to GitHub Actions minutes. Actions bills per job, rounds each job up to the next whole minute, and applies multipliers (Windows 2x, macOS 10x) against Linux. Runner hardware also differs. Treat these figures as the input to a modelled range, not a firm figure.

### 13. **Agent Pools & Self-Hosted Infrastructure**
   - Pool inventory split Microsoft-hosted vs self-hosted
   - Registered / online / enabled agent counts
   - **Agent operating systems** (Windows / macOS / Linux) — drives the Actions minute multiplier and whether ARC is viable
   - Per-pool agent detail
   - GitHub equivalence guidance (GitHub-hosted runners vs self-hosted vs Actions Runner Controller)

### 14. **Azure DevOps to GitHub Capability Mapping** (GitHub Apps / Marketplace)
   Every detected service connection and Marketplace extension is categorised:

   | Category | Meaning |
   |---|---|
   | `OOB` | Supported out of the box by a GitHub feature |
   | `MARKET` | A GitHub Marketplace action exists |
   | `PARTNER` | The publisher provides a supported GitHub App or action |
   | `CUSTOM` | No direct equivalent — expect bespoke work |

   Counted **per distinct integration type, not per instance** — solving a type once covers all its instances. The `CUSTOM` list is the set of items that need a named owner and an estimate.

### 15. **Operating Model Denominators (Platform Team Sizing)**
   Deliberately emits **denominators only** — no staffing model, no FTE numbers. These are the inputs a support model is sized against:
   - Estate scale (projects, repos, pipelines)
   - Change volume (builds/month, distinct pipeline authors, distinct build requesters)
   - Support surface (self-hosted pools and agents to patch, service connections to re-authenticate, custom integrations, active users to support)

### **Migration Data Summary**
   - Consolidated statistics grouped by cost bucket
   - Includes large file counts when `SCAN_LARGE_FILES=1`
   - Includes security alert counts if Advanced Security is enabled

## Output Files

After running the script, you'll find (where `RUN` is `YYYYMMDD-HHMMSS-XXXXX`, shared by every artefact from the same run):

- **`ado-data-report-RUN.txt`** — Main human-readable report
- **`ado-sizing-RUN.json`** — **Machine-readable sizing export.** Every headline figure in one JSON document so a cost model can consume it directly instead of scraping text
- **`ado-users-RUN.csv`** — User list with access levels, licence type and last-access date
- **`ado-secret-scanning-RUN.txt` / `.csv` / `.json`** — Detailed secret scanning exports (only generated if secret alerts are found)

### Structured Sizing Export (`ado-sizing-RUN.json`)

Top-level keys: `meta`, `content`, `infrastructure`, `licensing`, `migrationEffort`, `integrations`, `operatingModel`, `security`.

```bash
# Monthly build minutes and peak concurrency
jq '.infrastructure | {computeMinutesPerMonth, peakConcurrentBuilds}' ado-sizing-*.json

# Seat count excluding dormant accounts
jq '.licensing | .totalUsers - .neverSignedIn' ado-sizing-*.json

# Pipelines actually worth migrating
jq '.migrationEffort.buildPipelines | .total - .dormant' ado-sizing-*.json

# Integrations needing bespoke work
jq '.integrations.effortMapping.customWork' ado-sizing-*.json

# Roll several orgs into one view
jq -s 'map(.infrastructure.computeMinutesPerMonth) | add' ado-sizing-*.json
```

The export carries `meta.schemaVersion` so downstream models can detect format changes.

### Secret Scanning Report Details

When Azure DevOps Advanced Security is enabled and secret alerts are detected, three separate reports are generated:

#### Text Report (`.txt`)
Human-readable format containing:
- **Alert Identification**: Alert ID, secret type, and severity
- **Validation Information**: Validation status and messages from Azure DevOps
- **Location Details**: File path, line numbers, and branch information
- **Timeline**: When the secret was introduced, first seen, and last seen
- **Detection Tools**: Which scanning tools detected the secret
- **Direct Links**: URLs to view alerts in Azure DevOps

#### CSV Report (`.csv`)
Excel-compatible format with the same information in tabular form, allowing system administrators to:
- Sort and filter by severity, confidence, or validation status
- Identify patterns across projects and repositories
- Track remediation progress
- Generate pivot tables and charts
- Share filtered subsets with teams

#### JSON Report (`.json`)
Machine-readable format with structured data, enabling:
- Programmatic processing and automation
- Integration with security tools and dashboards
- Custom reporting and analytics pipelines
- API consumption by other systems
- Version control and diff tracking

This detailed report helps security teams prioritize remediation efforts before migration to GitHub.

Note: Temporary data is automatically cleaned up on script completion or interruption.

## Troubleshooting

### "Authentication Failed" on Startup
- Run `az login` to authenticate with Azure
- Verify your Azure account has access to the Azure DevOps organization
- Run `az account show` to confirm you're logged in
- Check that the organization name is correct (no spaces or special characters in URL)

### "Command not found: jq"
- Install jq using the commands in the Prerequisites section

### Network Timeouts
- Script includes 30-second timeout with 2 automatic retries
- Check your network connection if multiple API calls fail
- Large organizations may take longer but should complete within timeout limits

### Empty or Missing Data in Report
- Some repositories may not report size via API
- Empty projects (no repositories) are automatically skipped
- If all projects are empty, script will exit early with a message

### Script Interrupted (Ctrl+C)
- Temporary files are automatically cleaned up
- Report file (if partially created) will remain
- Safe to re-run the script

### Section 12 Is Taking Too Long
Build history is the slowest part of the run. Either shorten the window or skip it:
```bash
ORG="your-org" HISTORY_DAYS=30 ./ado-data-collector.sh
ORG="your-org" SKIP_BUILD_HISTORY=1 ./ado-data-collector.sh
```
Skipping it removes all runner-cost data (sections 12 and the `infrastructure` JSON block), so only do that if you already have the compute figures elsewhere.

### "Pipelines that ran" Looks Too Low
Check `HISTORY_DAYS`. A 90-day window will not see pipelines that run quarterly or on an annual release train, and those will be counted as dormant. For estates with long release cadences use `HISTORY_DAYS=180` or higher.

### Build Minutes Look Wrong Versus the Azure DevOps Billing Page
They measure different things. This script sums build wall-clock duration from the build records. The Azure DevOps billing page reports *billed* parallel-job consumption, which excludes self-hosted execution and applies its own rounding. Use this script's figure to model relative Actions consumption, not to reconcile an Azure invoice.

### Counts Look Higher Than Expected
Some resources are project-scoped and are counted per project. If several projects share a service connection name or an agent pool, they are counted once per project. Section 14 deduplicates by integration *type* for exactly this reason.

## Using the Report

The generated report provides factual data to support migration planning discussions. Use the data to:
- Understand the scope of content to migrate
- Identify which repositories contain the most data
- Document existing integrations and their types
- Export user lists for account mapping planning

### Mapping the Report to CI/CD Migration Cost Buckets

When sizing an "Azure Pipelines to GitHub Actions" business case, these are the numbers that matter and where to find them:

| Cost bucket | Report section | Key figures | JSON path |
|---|---|---|---|
| **1. Infrastructure (runners)** | 12, 13 | Build minutes/month, peak concurrency, minutes split hosted vs self-hosted, agent OS mix, queue wait P95 | `.infrastructure` |
| **2. Licensing** | 11 | Total users, active 30/60/90d, never signed in, Stakeholder count, unique committers | `.licensing` |
| **3. AzDO cleanup / transform / transfer** | 8, 12 | YAML vs Classic split, classic release pipelines, task groups, variable groups, **dormant pipelines** | `.migrationEffort` |
| **4. GitHub Apps / Marketplace** | 10, 14 | Service connections and extensions categorised OOB / MARKET / PARTNER / CUSTOM | `.integrations` |
| **5. Ongoing support / platform team** | 15 | Self-hosted pools and agents to patch, service connections to re-auth, custom integrations, change volume, active users | `.operatingModel` |

Notes for building the model:

- **Bucket 1** — peak concurrency sizes the *fleet*; total minutes size the *spend*. Apply the Actions billing caveat (per-job billing, whole-minute rounding, Windows 2x / macOS 10x) and present a range.
- **Bucket 2** — subtract `neverSignedIn` before sizing a seat count. Call out Stakeholders explicitly: they are free in Azure DevOps and are **not** free in GitHub. `uniqueCommitters` is the GHAS billing unit and requires `SCAN_LARGE_FILES=1`.
- **Bucket 3** — subtract `dormant` from `total` before estimating conversion effort; dormant pipelines are retirement candidates. Then run `gh actions-importer audit azure-devops` for per-pipeline conversion rates on what remains. Classic pipelines, classic release pipelines and task groups are the expensive items.
- **Bucket 4** — the `customWork` count is the number of distinct integrations needing a named owner and an estimate. Everything in `OOB`/`MARKET`/`PARTNER` is configuration, not development.
- **Bucket 5** — the report gives denominators only, on purpose. Apply your own staffing ratios to them so the assumptions stay visible and challengeable.

### Platform-Neutral Denominators

The same denominators drive any platform's model. Because the export is structured, the platform-specific assumptions stay separate from the estate facts:

```bash
jq '{
  runnerMinutes: .infrastructure.computeMinutesPerMonth,
  peakConcurrency: .infrastructure.peakConcurrentBuilds,
  seats: (.licensing.totalUsers - .licensing.neverSignedIn),
  pipelinesToConvert: (.migrationEffort.buildPipelines.total - .migrationEffort.buildPipelines.dormant),
  classicRewrites: (.migrationEffort.buildPipelines.classic + .migrationEffort.releasePipelines),
  customIntegrations: .integrations.effortMapping.customWork,
  selfHostedAgentsToOperate: .operatingModel.selfHostedAgentsToPatch
}' ado-sizing-*.json
```

### Multi-Organization Estates

Run the script once per organization, then aggregate:

```bash
jq -s '{
  orgs: length,
  minutesPerMonth: (map(.infrastructure.computeMinutesPerMonth) | add),
  peakConcurrency: (map(.infrastructure.peakConcurrentBuilds) | add),
  users: (map(.licensing.totalUsers) | add),
  pipelines: (map(.migrationEffort.buildPipelines.total) | add),
  dormant: (map(.migrationEffort.buildPipelines.dormant) | add)
}' ado-sizing-*.json
```

Note that summing `peakConcurrency` across organizations is an upper bound — peaks may not coincide.

## Example Scripts

This repository also includes example scripts:
- `report-generator-example-1.sh` - Repository size analysis with LFS details
- `report-generator-example-2a.sh` - Basic repository metrics with oldest commits
- `report-generator-example-2b.sh` - Filter repositories by size

These are standalone reference snippets, not part of the collector. They are also read-only against Azure DevOps (`GET` requests, `az ... list` commands, and `git clone`/`git lfs fetch`), but they do **not** carry the enforcement guards described above and, unlike the collector, they authenticate with a PAT. Review them before running.

## Security Best Practices

- **Read-Only by Enforcement**: The script never writes to Azure DevOps. Requests are pinned to `GET`, hosts are allow-listed, the single `POST` (the WIQL *query* endpoint) is allow-listed by path, Git clones are configured with an unusable push URL, and any violation aborts the run with exit code `3`. See [Read-only guarantee](#read-only-guarantee).
- **Token Security**: Azure AD bearer tokens are stored in secure temporary files with restrictive permissions (600)
  - Never exposed in process listings or command-line arguments
  - Automatically cleaned up on script exit (success, failure, or interruption)
  - Uses `mktemp` for unpredictable filenames to prevent race conditions
- **Transport Security**: All requests are HTTPS-only (`--proto '=https'`), and redirects cannot downgrade the scheme (`--proto-redir '=https'`), so a redirect cannot leak the bearer token over cleartext
- **Token Lifecycle**: Tokens automatically expire after 1 hour; script includes refresh logic for long-running operations
- **No Secrets in Code**: Authentication uses `az login` - no PAT tokens or credentials stored in script
- **Clean Output**: Progress messages hidden by default; use `DEBUG=1` for detailed output
- **Secure Cleanup**: Trap handlers ensure temporary files are removed even if script is interrupted; `Ctrl-C` cleans up and stops the run
- **Report Security**:
  - All generated output is already covered by `.gitignore`: `ado-data-report-*`, `ado-sizing-*`, `ado-users-*`, `ado-secret-scanning-*`
  - `ado-users-*.csv` contains display names and email addresses. Treat it as personal data and handle it under your own data protection obligations
  - `ado-sizing-*.json` contains the organization name, project names and full estate counts
  - Store reports securely as they contain organizational information
  - Consider encrypting reports if storing long-term

## Advanced Usage

### Debug Mode
Enable debug output to see all API calls:
```bash
DEBUG=1 ./ado-data-collector.sh
```

### Large File Scanning
Enable automatic large file detection (requires Git):
```bash
SCAN_LARGE_FILES=1 ./ado-data-collector.sh
```

**How it works:**
- Clones each repository as a bare repository (faster, no working directory)
- Scans entire Git object database for all blobs
- Detects files >50MB anywhere in Git history
- Identifies files even if they were deleted in later commits
- Reports exact file sizes and paths

**When to use:**
- Planning GitHub migration (GitHub warns at 50MB, blocks at 100MB)
- Identifying candidates for Git LFS conversion
- Understanding true repository size vs API-reported size
- Finding large files that may have been deleted but still bloat the repo

**Performance note:** This mode is slower as it clones repositories, but provides accurate file-level analysis.

### Concurrent Execution
The script is safe for concurrent execution:
- Each run creates a unique temporary directory using process ID
- Report files include random number to prevent collisions
- Multiple instances can run simultaneously without conflicts

### Environment Variables
Configure the script using environment variables:
```bash
# Required: Set your organization name
export ORG="your-org-name"

# Optional: Enable large file scanning
export SCAN_LARGE_FILES=1

# Optional: Enable debug output
export DEBUG=1

# Run the script
./ado-data-collector.sh
```

**Configuration Options:**
- `ORG` (required): Your Azure DevOps organization name
- `SCAN_LARGE_FILES` (optional, default=0): Set to 1 to scan for large files and count unique committers
- `DEBUG` (optional, default=0): Set to 1 for detailed API call output
- `HISTORY_DAYS` (optional, default=90): Build history window used for runner sizing
- `SKIP_BUILD_HISTORY` (optional, default=0): Set to 1 to skip build history collection
- `MAX_BUILDS_PER_PROJECT` (optional, default=20000): Safety cap on builds fetched per project
- `TOKEN_MAX_AGE` (optional, default=2400): Seconds before the Azure AD token is proactively refreshed

**Note**: Authentication is handled via `az login` - no PAT required.

### Unique Committer Counting

`SCAN_LARGE_FILES=1` also collects unique commit author emails across all cloned repositories, over the same `HISTORY_DAYS` window. This is reported in section 11 as **unique committers**, which is the billing unit for GitHub Advanced Security.

This is usually much lower than total user count, and it is the figure GHAS cost should be based on. Without `SCAN_LARGE_FILES=1` it reports 0.

## Support

For issues or questions:
1. Review the troubleshooting section above
2. Check that all prerequisites are installed correctly
3. Verify you're logged in with `az login` and have access to the organization
4. Open an issue in this repository with error details
