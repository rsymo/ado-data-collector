# Azure DevOps Data Collector

Create a plain-language snapshot of what exists in an Azure DevOps (ADO) organization, what is being used, and where there may be cleanup or platform-support work.

The primary audience is an ADO or Platform administrator. Run the collector against each organization, read the text report first, and use the JSON and CSV files when the results need to be shared with another tool or team.

## What the report tells you

The report is an inventory, not an automated cleanup plan. It gives you facts to answer:

- **What do we have?** Projects, repositories, work items, pull requests, pipelines, releases, variable groups, integrations, extensions, users, agent pools, and security alerts.
- **What is active?** User sign-in activity and build activity during a configurable history window.
- **What looks unused or worth reviewing?** Users who have never signed in, inactive pipelines, disabled pipelines, public repositories, oversized repositories, and integrations that need ownership.
- **What does the Platform team operate?** Self-hosted agents, service connections, custom integrations, active users, pipeline change volume, and build demand.
- **What would GitHub Actions cost?** Job-level billable minutes in the Actions billing model, the operating-system mix that drives the Linux/Windows/macOS multiplier, deployment compute, and the migration work items that no tool converts automatically.

“Unused” is deliberately evidence-based. The collector can identify dormant pipelines and inactive users, but it does not assume that an old repository, project, work item, or service connection is safe to delete. Those resources require an owner review.

### Total cost of ownership

Sections 16–22 exist to answer one question: what would this estate cost on GitHub Actions, and what would it cost to move it. They are designed so an administrator can run the script unchanged and hand the report over — nothing needs to be edited, and nothing is written back to Azure DevOps.

The key distinction the report enforces is that **Azure DevOps minutes and GitHub Actions minutes are not the same unit**:

- Azure DevOps reports **build wall-clock** time.
- GitHub Actions bills **per job**, rounding each job up to a whole minute, and multiplies by **1x Linux, 2x Windows, 10x macOS**.

A build that fans out to six parallel jobs therefore bills roughly six times its wall-clock duration. Applying an Actions rate to a raw Azure DevOps minute figure will produce a materially wrong number. Section 16 measures the real expansion ratio from build timelines, section 17 measures the operating-system mix, and section 22 combines them into a single Linux-equivalent figure that can safely be priced.

Section 22 also lists, explicitly, the inputs that no Azure DevOps API can supply — self-hosted infrastructure cost, unit prices, internal effort, compliance blockers and competing quotes. Those have to come from the customer.

## Run it

### Prerequisites

Install:

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli)
- `jq`
- `curl`
- `git` only when using `SCAN_LARGE_FILES=1`

Your account must be able to access the organization. A **Project Collection Administrator**, or an account with equivalent permissions, provides the most complete result. Lower permissions do not necessarily stop the run; affected sections may show zero or a warning.

Enable **Third-party application access via OAuth** in **Organization settings > Policies > Security**.

### Authenticate and run

```bash
az login
az account show
chmod +x ado-data-collector.sh

# Standard inventory; build history covers the last 90 days
ORG="your-org-name" ./ado-data-collector.sh

# Include file-level large-file scanning and unique committers
ORG="your-org-name" SCAN_LARGE_FILES=1 ./ado-data-collector.sh
```

For a first pass on a large organization, use a shorter window:

```bash
ORG="your-org-name" HISTORY_DAYS=7 DEBUG=1 ./ado-data-collector.sh
```

## Options

| Variable | Default | Use |
|---|---:|---|
| `ORG` | required | ADO organization name |
| `HISTORY_DAYS` | `90` | Build-history window used for activity and runner sizing |
| `SCAN_LARGE_FILES` | `0` | Clone repositories and find files larger than 50 MB; also count unique committers |
| `SKIP_BUILD_HISTORY` | `0` | Skip build collection when runner data is not needed |
| `MAX_BUILDS_PER_PROJECT` | `20000` | Safety cap on builds fetched per project |
| `SKIP_TIMELINE` | `0` | Skip job-level timeline collection (section 16). Faster, but removes the only Actions-comparable minute figure |
| `TIMELINE_SAMPLE_MAX` | `1500` | Maximum build timelines to read. Above this the collector samples evenly and extrapolates, reporting the sample size |
| `TOKEN_MAX_AGE` | `2400` | Seconds before the Azure AD token is refreshed |
| `DEBUG` | `0` | Print API calls and diagnostic details |

`SKIP_BUILD_HISTORY=1` makes the run faster, but removes build activity and runner-sizing data. Increase `HISTORY_DAYS` for quarterly or annual pipelines; otherwise they can appear dormant simply because they did not run during the selected window.

## Read the report in this order

The generated `ado-data-report-RUN.txt` contains these sections:

| Sections | What to look for |
|---|---|
| 1–6: Repositories | Project and repository totals, public repositories, repositories over 1 GB, the largest and oldest repositories, and optional files over 50 MB |
| 7: ADO metadata | Work items, pull requests, and projects with boards or teams |
| 8: Pipelines | YAML versus Classic, disabled pipelines, non-Azure-Repos sources, Classic release pipelines, task groups, variable groups, Key Vault-backed groups, and pipeline counts by project |
| 9: Security | Advanced Security status and secret, dependency, and code-scanning alerts |
| 10: Integrations | Service hooks, service connections, and installed Marketplace extensions |
| 11: Users | Total users, access levels, license source, sign-in recency, stakeholders, likely service accounts, and unique committers |
| 12: Build activity | Builds and compute minutes, duration and queue-time percentiles, outcomes, pool usage, concurrency, and dormant pipelines |
| 13: Agents | Microsoft-hosted and self-hosted pools, registered/online/enabled agents, operating systems, and per-pool details |
| 14: Capability mapping | Integrations grouped as `OOB`, `MARKET`, `PARTNER`, or `CUSTOM` |
| 15: Platform denominators | Estate scale, change volume, and support surface for planning team capacity |
| 16: Job-level compute | Billable job minutes in the Actions model, the job-to-wall-clock expansion ratio, average jobs per build, and the tasks and Marketplace extensions actually executed |
| 17: Runner image and OS mix | Windows, Linux and macOS split of job minutes, the weighted cost multiplier, hosted versus self-hosted, and the top runner images |
| 18: Deployment compute | Classic release deployment minutes, which are additional to build minutes and invisible to the build API |
| 19: Approvals, gates and secrets | YAML environment checks, classic release approvals and gates, secret variables, secure files and service connections — all manual rebuild work |
| 20: Migration complexity | Active pipelines grouped simple, moderate and complex from observed jobs, tasks and extension tasks |
| 21: Commercial baseline | Purchased and in-use parallel jobs and licence entitlement quantities |
| 22: TCO input summary | One answer sheet, each figure labelled `MEASURED`, `EXTRAPOLATED` or `UNKNOWN`, plus the list of inputs to request from the customer |

### Admin review guide

1. **Confirm the scope.** Check the organization name, generated timestamp, project and repository totals, and whether any sections contain warnings.
2. **Review exposure and risk.** Start with public repositories, security alerts, large files, Classic pipelines, Key Vault-backed variable groups, and custom integrations.
3. **Separate active from inactive.** Use 30/60/90-day user activity and the build-history window. Treat “never signed in” users and dormant pipelines as review queues, not automatic deletion lists.
4. **Find the operating burden.** Review self-hosted agents, agent operating systems, service connections, extensions, active users, queue wait, and peak concurrency.
5. **Assign owners.** Every cleanup candidate, security alert, service connection, and `CUSTOM` integration should have a named owner and a follow-up decision.
6. **Build the cost case.** Read section 22 last. It restates every figure a cost model needs, labelled by how it was obtained, and ends with the short list of inputs that must come from the customer.

## Output files

Each run uses the same `RUN` identifier (`YYYYMMDD-HHMMSS-XXXXX`):

- `ado-data-report-RUN.txt` — human-readable report for administrators
- `ado-sizing-RUN.json` — structured export for dashboards, models, or automation
- `ado-users-RUN.csv` — user display name, access level, license type, and last-access data
- `ado-secret-scanning-RUN.txt`, `.csv`, `.json` — detailed secret-alert exports when alerts are found

The JSON top-level keys are `meta`, `content`, `infrastructure`, `licensing`, `migrationEffort`, `integrations`, `operatingModel`, `security`, and `tco`.

`tco` contains `jobCompute`, `runnerMix`, `deployments`, `approvalsAndSecrets`, `complexity`, `commercial`, and `requiredFromCustomer`. The `basis` field on `jobCompute`, `runnerMix` and `complexity` reports whether a figure was measured, extrapolated from a sample, or unavailable — check it before using any of them.

Useful examples:

```bash
# Check whether the collection is complete before using the figures
jq '.meta | {dataComplete, warnings}' ado-sizing-*.json

# The figure to price against GitHub Actions
jq '{
  basis: .tco.jobCompute.basis,
  billableJobMinutesPerMonth: .tco.jobCompute.billableJobMinutesPerMonth,
  expansionRatio: .tco.jobCompute.billableToWallClockRatio,
  osMultiplier: .tco.runnerMix.weightedMultiplier,
  linuxEquivalentMinutesPerMonth: .tco.runnerMix.linuxEquivalentMinutesPerMonth,
  stillNeeded: .tco.requiredFromCustomer
}' ado-sizing-*.json

# Current-state headline numbers
jq '{
  projects: .content.projects,
  repositories: .content.repositories,
  users: .licensing.totalUsers,
  activeUsers90d: .licensing.active90d,
  neverSignedIn: .licensing.neverSignedIn,
  pipelines: .migrationEffort.buildPipelines.total,
  dormantPipelines: .migrationEffort.buildPipelines.dormant
}' ado-sizing-*.json
```

## Trust and limitations

The collector reports what the ADO APIs return for the account running it. If a request fails or a page cap is reached, the run continues with partial data and:

- writes a warning to stderr and the text report;
- lists all warnings in **DATA COMPLETENESS**;
- sets `meta.dataComplete` to `false` in the JSON.

Do not use a number for planning until `dataComplete` and `warnings` have been reviewed. A zero in a permission-limited section means “not returned,” not necessarily “none exist.”

Build minutes are summed from build wall-clock durations; they are not an Azure billing reconciliation. Peak concurrency describes observed overlap during the selected window. Repository API size is not the same as a file-level Git history scan, and file-level results require `SCAN_LARGE_FILES=1`.

Limitations specific to the TCO sections:

- **Job-level minutes are sampled on large estates.** Reading a build timeline costs one API call per build, so above `TIMELINE_SAMPLE_MAX` the collector samples evenly and scales up using the measured expansion ratio. Only the *ratio* is extrapolated — the population minute total it is applied to is measured. The sample size and `basis` are always reported.
- **Section 16 is the slowest part of the run.** Set `SKIP_TIMELINE=1` to skip it, accepting that the report then has no Actions-comparable minute figure.
- **The operating-system mix has a short history.** Azure DevOps retains agent job requests for a limited and undocumented period. Section 17 reports the observed window it actually got. If that window is much shorter than `HISTORY_DAYS`, use the mix as a *proportion* and apply it to the section 16 minutes — do not treat its absolute minutes as a monthly total.
- **Concurrency is measured at build level.** Average and peak concurrent *builds* are exact and taken from the full population. Concurrent *jobs* will be higher, in proportion to average jobs per build.
- **Complexity grouping is a heuristic.** It classifies from observed jobs, distinct tasks and extension tasks, and covers only pipelines that ran during the window. Pipelines that did not run are reported separately rather than assumed simple.
- **Approvals and gates are capped.** Environment checks require one call per environment; the collector inspects the first 300 and warns when there are more, making those counts a lower bound.
- **No prices are applied anywhere.** The collector reports quantities only. Unit prices, discounts and infrastructure costs depend on the customer's agreements and are listed in section 22 as inputs to request.

The collector complements [`gh actions-importer audit azure-devops`](https://docs.github.com/en/actions/migrating-to-github-actions/using-github-actions-importer). The Importer assesses individual pipeline conversion compatibility; this project provides the broader estate, activity, ownership, and operating-model inventory.

## Security and privacy

Authentication uses `az login` and short-lived Azure AD tokens; no PAT is required. Temporary data is cleaned up when the run finishes or is interrupted.

Reports contain organizational information. `ado-users-*.csv` includes display names and email addresses, and the JSON includes organization, project, and estate counts. Keep generated files in an approved, access-controlled location and do not commit them to source control.

## Troubleshooting

- **Authentication failed:** run `az login`, confirm `az account show`, and verify organization access.
- **A section is zero or missing:** check permissions and the **DATA COMPLETENESS** section; run with `DEBUG=1`.
- **The run is slow:** use `HISTORY_DAYS=30` or `SKIP_BUILD_HISTORY=1`; large-file scanning requires repository clones and is slower.
- **Too few pipelines appear active:** increase `HISTORY_DAYS` to include infrequent release trains.
- **`jq` is missing:** install it with your operating system package manager.

Open an issue in this repository with the command used, the affected section, and the non-sensitive error output.
