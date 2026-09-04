# Azure DevOps Data Collector

Create a plain-language snapshot of what exists in an Azure DevOps (ADO) organization, what is being used, and where there may be cleanup or platform-support work.

The primary audience is an ADO or Platform administrator. Run the collector against each organization, read the text report first, and use the JSON export when the results need to be shared with another tool or team.

The collector is read-only and, by default, produces **no personal data** — people appear only as counts.

## What the report tells you

The report is an inventory, not an automated cleanup plan. It gives you facts to answer:

- **What do we have?** Projects, repositories, work items, pull requests, pipelines, releases, variable groups, integrations, extensions, users, agent pools, and security alerts.
- **What is active?** User sign-in activity and build activity during a configurable history window.
- **What looks unused or worth reviewing?** Users who have never signed in, inactive pipelines, disabled pipelines, public repositories, oversized repositories, and integrations that need ownership.
- **What does the Platform team operate?** Self-hosted agents, service connections, custom integrations, active users, pipeline change volume, and build demand.
- **What is the real shape of our CI workload?** Job-level minutes rather than wall-clock minutes, the Windows/Linux/macOS mix, concurrency, queue wait, deployment compute, and how much of the estate depends on Marketplace extensions.

“Unused” is deliberately evidence-based. The collector can identify dormant pipelines and inactive users, but it does not assume that an old repository, project, work item, or service connection is safe to delete. Those resources require an owner review.

### Comparing the estate against another CI provider

Sections 16–22 exist because the most common reason to inventory an estate is to evaluate a change of platform. They measure pipeline usage in units that survive a move between CI providers, and they are useful for capacity planning and runner right-sizing even if nothing is migrating.

The distinction they enforce is that **a build minute is not a job minute**:

- Azure DevOps reports **build wall-clock** time.
- Per-job billing models — GitHub Actions among them — charge **per job**, round each job up to a whole minute, and weight by operating system.

A build that fans out to six parallel jobs therefore represents roughly six times its wall-clock duration in a per-job model. Applying a per-minute rate to a raw Azure DevOps minute figure will produce a materially wrong number. Section 16 measures the real expansion ratio from build timelines, section 17 measures the operating-system mix, and section 22 combines them into a single weighted figure.

The operating-system weightings are configurable (`MULT_LINUX`, `MULT_WINDOWS`, `MULT_MACOS`) and default to the GitHub-hosted standard runner ratios. **No prices are applied anywhere** — the collector reports quantities only.

Section 22 also lists, explicitly, the inputs that no Azure DevOps API can supply: self-hosted infrastructure cost, unit prices, internal effort, compliance blockers and any third-party quotes.

### Sharing the report

If you have been asked to run this collector so that someone else can build a cost or migration assessment, section 22 plus the JSON file is the hand-over.

Read the **Before you share this report** block at the end of section 22 first. It states exactly what the report does and does not contain, and confirms that no secret, token or variable *value* is ever read. By default the report identifies no individual — see [Personal data](#personal-data) below.

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
| `EXPORT_USER_DETAILS` | `0` | Set to `1` to additionally write a per-user CSV containing display names and email addresses. Off by default so the standard output contains no personal data |
| `EXPORT_SECRET_DETAILS` | `0` | Set to `1` to additionally write per-alert secret scanning files naming the file path, line number and branch of each detected credential. Off by default; alert **counts** are always reported. Also adds one API call per alert |
| `MULT_LINUX` | `1` | Cost weighting for Linux job minutes |
| `MULT_WINDOWS` | `2` | Cost weighting for Windows job minutes |
| `MULT_MACOS` | `10` | Cost weighting for macOS job minutes. Defaults reflect GitHub-hosted standard runner ratios at the time of writing — confirm against current pricing |
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
| 22: Migration assessment summary | One hand-over page, each figure labelled `MEASURED`, `EXTRAPOLATED` or `UNKNOWN`, plus the inputs no API can supply and a statement of what the report does and does not contain |

### Admin review guide

1. **Confirm the scope.** Check the organization name, generated timestamp, project and repository totals, and whether any sections contain warnings.
2. **Review exposure and risk.** Start with public repositories, security alerts, large files, Classic pipelines, Key Vault-backed variable groups, and custom integrations.
3. **Separate active from inactive.** Use 30/60/90-day user activity and the build-history window. Treat “never signed in” users and dormant pipelines as review queues, not automatic deletion lists.
4. **Find the operating burden.** Review self-hosted agents, agent operating systems, service connections, extensions, active users, queue wait, and peak concurrency.
5. **Assign owners.** Every cleanup candidate, security alert, service connection, and `CUSTOM` integration should have a named owner and a follow-up decision.
6. **Read the hand-over page.** Section 22 restates every figure a cost model needs, labelled by how it was obtained. It ends with the inputs no Azure DevOps API can supply, and a plain statement of what the report does and does not contain — read that before sharing the report outside your organization.

## Output files

Each run uses the same `RUN` identifier (`YYYYMMDD-HHMMSS-XXXXX`):

- `ado-data-report-RUN.txt` — human-readable report for administrators, and the file to share if someone else is building the assessment
- `ado-sizing-RUN.json` — structured export for dashboards, models, or automation
- `ado-users-RUN.csv` — **only when `EXPORT_USER_DETAILS=1`.** Per-user display name, email address, access level, licence type and last-access date. This is personal data; see [Personal data](#personal-data)
- `ado-secret-scanning-RUN.txt`, `.csv`, `.json` — **only when `EXPORT_SECRET_DETAILS=1`.** Per-alert detail naming the file path, line number and branch of each detected credential (never the value). This is security-sensitive; see [Personal data](#personal-data)

The JSON top-level keys are `meta`, `content`, `infrastructure`, `licensing`, `migrationEffort`, `integrations`, `operatingModel`, `security`, and `tco`.

`tco` contains `jobCompute`, `runnerMix`, `deployments`, `approvalsAndSecrets`, `complexity`, `commercial`, and `inputsYouMustSupply`. The `basis` field on `jobCompute`, `runnerMix` and `complexity` reports whether a figure was measured, extrapolated from a sample, or unavailable — check it before using any of them.

Useful examples:

```bash
# Check whether the collection is complete before using the figures
jq '.meta | {dataComplete, warnings}' ado-sizing-*.json

# The job-level minute figure a per-job cost model needs
jq '{
  basis: .tco.jobCompute.basis,
  billableJobMinutesPerMonth: .tco.jobCompute.billableJobMinutesPerMonth,
  expansionRatio: .tco.jobCompute.billableToWallClockRatio,
  osMultiplier: .tco.runnerMix.weightedMultiplier,
  linuxEquivalentMinutesPerMonth: .tco.runnerMix.linuxEquivalentMinutesPerMonth,
  stillNeeded: .tco.inputsYouMustSupply
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

Limitations specific to sections 16-22:

- **Job-level minutes are sampled on large estates.** Reading a build timeline costs one API call per build, so above `TIMELINE_SAMPLE_MAX` the collector samples evenly and scales up using the measured expansion ratio. Only the *ratio* is extrapolated — the population minute total it is applied to is measured. The sample size and `basis` are always reported.
- **Section 16 is the slowest part of the run.** Set `SKIP_TIMELINE=1` to skip it, accepting that the report then has no Actions-comparable minute figure.
- **The operating-system mix has a short history.** Azure DevOps retains agent job requests for a limited and undocumented period. Section 17 reports the observed window it actually got. If that window is much shorter than `HISTORY_DAYS`, use the mix as a *proportion* and apply it to the section 16 minutes — do not treat its absolute minutes as a monthly total.
- **Concurrency is measured at build level.** Average and peak concurrent *builds* are exact and taken from the full population. Concurrent *jobs* will be higher, in proportion to average jobs per build.
- **Complexity grouping is a heuristic.** It classifies from observed jobs, distinct tasks and extension tasks, and covers only pipelines that ran during the window. Pipelines that did not run are reported separately rather than assumed simple.
- **Approvals and gates are capped.** Environment checks require one call per environment; the collector inspects the first 300 and warns when there are more, making those counts a lower bound.
- **No prices are applied anywhere.** The collector reports quantities only. Unit prices, discounts and infrastructure costs depend on your own agreements and are listed in section 22 as inputs to provide separately.
- **Cost multipliers are assumptions, not live pricing.** `MULT_LINUX`, `MULT_WINDOWS` and `MULT_MACOS` default to the GitHub-hosted standard runner ratios published at the time of writing. Rates change and vary by plan and runner size, so confirm them against current pricing and override them if they differ. The values actually used are recorded in the JSON under `tco.runnerMix.multipliersApplied`.

The collector complements [`gh actions-importer audit azure-devops`](https://docs.github.com/en/actions/migrating-to-github-actions/using-github-actions-importer). The Importer assesses individual pipeline conversion compatibility; this project provides the broader estate, activity, ownership, and operating-model inventory.

## Security and privacy

Authentication uses `az login` and short-lived Azure AD tokens; no PAT is required. Temporary data is cleaned up when the run finishes or is interrupted.

Reports contain organizational information: project, repository, pipeline, agent pool, environment and service connection names, plus estate counts. Keep generated files in an approved, access-controlled location and do not commit them to source control.

No secret, password, token, certificate or variable **value** is ever read. Work items are counted via a query that selects only `System.Id`, so no titles or descriptions are retrieved. Build logs, test output, commit messages and file contents are never collected.

### Personal data

**By default this collector produces no personal data.** People appear only as counts — licence totals, active users, never-signed-in users, distinct pipeline authors, unique committers. No individual is identified in the text report or the JSON export.

Set `EXPORT_USER_DETAILS=1` to additionally write `ado-users-RUN.csv`, which lists every user by display name and email address. That file exists for internal administrative review, such as licence reconciliation or offboarding. It is **not** required for estate sizing or cost modelling, and it should not be included when sharing findings outside your organization.

### Secret scanning detail

By default the report gives **counts only** for secret, code and dependency scanning alerts. That is all estate sizing needs, and it means the report cannot be used to locate an unremediated credential.

Set `EXPORT_SECRET_DETAILS=1` to additionally write the `ado-secret-scanning-*` files, which record the file path, line number and branch of each detected credential — never the value. Those files are effectively a map of where your unremediated secrets are. They exist for the team remediating the alerts, are **not** required for estate sizing, and should not be included when sharing findings outside your organization.

## Troubleshooting

- **Authentication failed:** run `az login`, confirm `az account show`, and verify organization access.
- **A section is zero or missing:** check permissions and the **DATA COMPLETENESS** section; run with `DEBUG=1`.
- **The run is slow:** use `HISTORY_DAYS=30` or `SKIP_BUILD_HISTORY=1`; large-file scanning requires repository clones and is slower.
- **Too few pipelines appear active:** increase `HISTORY_DAYS` to include infrequent release trains.
- **`jq` is missing:** install it with your operating system package manager.

Open an issue in this repository with the command used, the affected section, and the non-sensitive error output.
