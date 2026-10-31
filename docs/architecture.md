# Architecture

## Overview

```
                         Omarchy Shell
                              |
                    BarWidget.qml (entry point)
                              |
                    +---------+---------+
                    |                   |
               Service.qml         Panel.qml
               (headless)          (popup UI)
                    |
            reads config.json
                    |
              Python scripts
                    |
        az CLI / kubectl / gh
```

## Key Rules

1. **Flat file structure.** All QML files live at the plugin root. Required by Omarchy's plugin loader.

2. **`BarWidget.qml` is the sole entry point.** It instantiates `Service` and loads `Panel.qml` via a `Loader`. The manifest declares only `bar-widget`.

3. **`Service.qml` owns all data fetching.** It reads `config.json` on startup, builds subprocess arguments, and runs the Python scripts. The UI only reads properties.

4. **Python scripts, not shell scripts.** All CLI interaction happens in `scripts/azure_devops.py`, `scripts/kubernetes.py` and `scripts/github_actions.py`.

5. **No credentials stored.** Scripts delegate to existing `az`, `kubectl` and `gh` CLI sessions.

## Components

### `BarWidget.qml`

- Omarchy bar entry point — extends `BarWidget` from `qs.Ui`
- Displays pipeline icon with status dot: healthy `+`, warning `!`, critical `x`
- Instantiates `Service` as a child
- Loads `Panel.qml` via a `Loader`
- Right-click or middle-click triggers manual refresh

### `Service.qml`

- Headless `Item` — no UI
- On startup: reads `config.json` via `scripts/read_config.py`, then runs Python scripts
- One refresh timer and watchdog per provider (`refresh.<provider>` seconds, clamped 30–3600); every provider refresh re-reads config first
- Exposes: `overallStatus`, `lastUpdated`, `refreshing`, `azureDevOps`, `kubernetes`, `github`, per-provider `azureRefreshing` / `kubernetesRefreshing` / `githubRefreshing` / `azureLastUpdated` / `kubernetesLastUpdated` / `githubLastUpdated`
- Functions: `refresh()` (all), `refreshProvider(name)`, `setProviderEnabled(name, bool)` (persists `providers.<name>` via `scripts/write_config.py`, then refreshes that provider)
- Uses `Process` + `StdioCollector` from `Quickshell.Io`

### `Panel.qml`

- Extends `Panel` from `qs.Ui` with `KeyboardPanel`
- Header: title, timestamp (`HH:mm`), refresh button
- Azure DevOps section groups projects and their pipelines
- Pipelines and releases use `RunTable.qml`: Name | Status | Last | Time | Link (Copy URL + Open link); rows with details can be expanded
- `ScrollView` handles overflow
- `Qt.openUrlExternally()` opens pipeline URLs in the browser

### `scripts/azure_devops.py`

- Accepts `--target ORG PROJECT` (repeatable for multiple projects)
- Calls `az pipelines runs list` and `az pipelines release list`
- Groups by pipeline name, returns current + last status per pipeline, plus the branch of the latest run (`sourceBranch`, shortened)
- Checks both `status` and `result` fields (Azure DevOps API quirk — completed runs use `result`)
- Supports `--mock`

### `scripts/job_detail.py`

- Reads the jobs, tasks and error messages of ONE run, only when the panel asks (a row was expanded). Read-only
- `--azure-build ORG PROJECT BUILD_ID`: `az devops invoke --area build --resource timeline` (the same call used for running pipelines); error messages come from each record's `issues`
- `--github-run OWNER/REPO RUN_ID`: `gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs`, and for failed jobs (at most 5) `gh api repos/OWNER/REPO/check-runs/JOB_ID/annotations` for the failure messages (GET requests only)
- Arguments are validated again, no shell, absolute paths, output and time capped, every text printable and bounded. `--mock azure|github ID` reads `mock/job-detail.json`
- Azure DevOps **releases** are not read here: `azure_devops.py` adds `stages` (name, status and the tasks that need attention, with their messages) to each release from the release it already reads, within a budget of 60 tasks per target

### `scripts/kubernetes.py`

- Reads nodes, pods and deployments per context with `kubectl get --raw`, one page of 50 objects at a time (size-capped, slimmed on arrival, `kubectl` memory-limited; see `scripts/kubernetes.py`)
- Builds the list of things needing attention (not-ready nodes, pods and deployments, with the reason) and a per-namespace breakdown, capped at 20 issues / 50 namespaces per cluster
- Supports `--context`, `--all-contexts`, `--namespace=NAME`, `--exclude-namespace=NAME` (validated, max 50 each; exclusion wins) and `--mock`

### `scripts/github_actions.py`

- Accepts `--repo OWNER/REPO` (repeatable, max 20, validated against a strict pattern) plus `--mock` / `--mock-error`
- Finds `gh` in the trusted `PATH`, then a few per-user locations (`~/.local/bin`, mise), or uses `github.ghPath`; the file must be owned by you and not world-writable
- Runs `gh run list --repo OWNER/REPO --json ...` per repository (no shell, absolute path, trusted `PATH`, output and time limits)
- Groups runs by workflow, keeps the latest run and the previous finished result; only `https://github.com/` links are kept
- `cancelled` / `skipped` runs are not counted as failures
- Checks `gh auth status` only after a repository fails, to say "Not logged in"

### `StatusIcon.qml` / `StatusBadge.qml`

- `StatusIcon` draws a state as a Canvas icon (one shape per state); `StatusBadge` is the icon plus an optional text label, used by every table

### `BranchLabel.qml`

- Drawn git-branch icon plus the branch name, shown under each Azure DevOps pipeline name (hidden when there is no branch)

### `LinkIcon.qml`

- Drawn "open in browser" icon for the Link column; emits `clicked()` (the panel validates the URL before opening it)

### `CopyIcon.qml`

- Drawn "copy" icon for the Link column and for error messages. Copies its `text` with `/usr/bin/wl-copy -- TEXT` (argument array, no shell) and shows "Copied" or "No wl-copy". The caller only gives it text that already passed the same checks as the Open link icon (`isTrustedAzureUrl` / `isTrustedGithubUrl`), or an error message that was cleaned

### `RunTable.qml` / `RunRow.qml` / `RunHeader.qml` / `JobDetail.qml` / `ErrorMessage.qml`

- `RunTable` draws a titled table of pipelines, releases or workflows (one `RunRow` each, under a `RunHeader`); `WorkflowTable` uses it too
- A row with details has a chevron; clicking the name emits `toggleDetail(openKey)`. `Panel.qml` keeps which rows are open (`detailOpen`) because the lists are rebuilt on every refresh
- `JobDetail` shows the jobs (release stages) and tasks of the open row; the failing task is highlighted and `ErrorMessage` shows its message with a Copy icon. Everything is plain text, cleaned and bounded again in QML
- For pipelines and workflows the table emits `detailRequested(key, spec, force)` and `Service.loadJobDetail()` answers in `Service.jobDetails[key]` (`loading` / `done` / `error`): one request at a time, a short queue, a 60 s watchdog and a cache of at most 40 entries. Releases need no request: their stages come with the refresh

### `K8sClusterDetail.qml` / `K8sIssueRow.qml` / `NamespaceRow.qml`

- Shown under each cluster's counters: **Needs attention** (one `K8sIssueRow` per issue) and a collapsible **Pods by namespace** (one `NamespaceRow` per namespace)
- Collapsed by default with a one-line summary; open shows only the namespaces with problems (at most 8); **Show all** opens the full list in a fixed-height area with its own scroll, so a cluster with dozens of namespaces never makes the card grow
- The open / show-all state is kept by `Panel.qml` (`k8sView`) because the cluster list is rebuilt on every refresh

### `ProviderNotice.qml`

- The "what to do next" card shown when a provider cannot work: a missing CLI (amber), a failed read (red) or nothing configured yet (blue). It also replaces the plain warning of a cluster whose API server does not answer
- Driven by the optional `notice` object that the provider scripts send next to the error (built by `scripts/provider_notice.py`, fixed text only); without one it shows the plain error line, so a new provider needs no extra markup
- Commands are only displayed and copied to the clipboard (`wl-copy`, argument array, no shell); nothing in the panel runs them. All text is plain and bounded again in QML
- Provider-script test doubles and the Python tests live in `tests/` (see `docs/testing.md`)

### `Notifier.qml` / `SilenceControl.qml` / `scripts/state_store.py`

- `Notifier` compares each provider reading with the previous one and sends a desktop alert (`notify-send`, argument array, no shell) only for items that turned failing. It applies the first-reading baseline, the branch filter, the per-provider hourly limit with a summary, and optional recovery alerts. Text is cleaned and escaped before it is sent
- `Service.qml` owns the notifier, the silence state and the problem counter used by the bar (`barMark`, `barTooltip`)
- `SilenceControl` is the inline "Silence" chip row in each provider header
- The Configuration tab's **Desktop alerts** switch calls `Service.setNotificationsEnabled()`, which runs `scripts/write_config.py notifications <true|false>` (only `notifications.enabled` can be changed)
- `scripts/state_store.py` reads and writes the silences in a private state file (0700 folder, 0600 file, no symlinks, file lock, atomic rename, 16 KiB cap)

### `NamespaceChips.qml`

- Label plus wrapping "chips", used by the Configuration tab to show the Kubernetes namespace filter (included / excluded)

### `WorkflowTable.qml`

- Per-repository table used by the GitHub Actions card: Name | Status | Last | Time | Link, with `branch · event` under each workflow (the list itself is a `RunTable`)

## Data Flow

```
Component.onCompleted
  -> cat config.json
  -> parse targets
  -> python3 scripts/azure_devops.py --target ORG PROJECT
  -> az pipelines runs list
  -> JSON stdout
  -> Service.azureDevOps updated
  -> Panel reads via property binding
  -> Timer fires every 60s -> repeat
```

## File Structure

```
heinsk.devops/
|-- manifest.json
|-- BarWidget.qml        <- bar entry point
|-- Service.qml          <- data and state
|-- Panel.qml            <- popup UI
|-- K8sClusterDetail.qml, K8sIssueRow.qml, NamespaceRow.qml, NamespaceChips.qml  <- Kubernetes detail views
|-- config.json          <- user configuration
|-- scripts/
|   |-- azure_devops.py  <- Azure DevOps CLI wrapper
|   |-- kubernetes.py    <- kubectl wrapper
|   +-- github_actions.py <- gh wrapper
+-- mock/
    |-- azure-devops.json
    |-- kubernetes.json
    +-- github-actions.json
```
