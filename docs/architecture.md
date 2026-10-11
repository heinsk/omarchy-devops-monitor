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
- Per-pipeline table: Name | Status | Last | Time | View
- `ScrollView` handles overflow
- `Qt.openUrlExternally()` opens pipeline URLs in the browser

### `scripts/azure_devops.py`

- Accepts `--target ORG PROJECT` (repeatable for multiple projects)
- Calls `az pipelines runs list` and `az pipelines release list`
- Groups by pipeline name, returns current + last status per pipeline, plus the branch of the latest run (`sourceBranch`, shortened)
- Checks both `status` and `result` fields (Azure DevOps API quirk — completed runs use `result`)
- Supports `--mock`

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

- Drawn "open in browser" icon for the View column; emits `clicked()` (the panel validates the URL before opening it)

### `K8sClusterDetail.qml` / `K8sIssueRow.qml` / `NamespaceRow.qml`

- Shown under each cluster's counters: **Needs attention** (one `K8sIssueRow` per issue) and a collapsible **Pods by namespace** (one `NamespaceRow` per namespace)
- Collapsed by default with a one-line summary; open shows only the namespaces with problems (at most 8); **Show all** opens the full list in a fixed-height area with its own scroll, so a cluster with dozens of namespaces never makes the card grow
- The open / show-all state is kept by `Panel.qml` (`k8sView`) because the cluster list is rebuilt on every refresh

### `NamespaceChips.qml`

- Label plus wrapping "chips", used by the Configuration tab to show the Kubernetes namespace filter (included / excluded)

### `WorkflowTable.qml`

- Per-repository table used by the GitHub Actions card: Name | Status | Last | Time | View, with `branch · event` under each workflow

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
