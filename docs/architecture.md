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
            az CLI / kubectl
```

## Key Rules

1. **Flat file structure.** All QML files live at the plugin root. Required by Omarchy's plugin loader.

2. **`BarWidget.qml` is the sole entry point.** It instantiates `Service` and loads `Panel.qml` via a `Loader`. The manifest declares only `bar-widget`.

3. **`Service.qml` owns all data fetching.** It reads `config.json` on startup, builds subprocess arguments, and runs the Python scripts. The UI only reads properties.

4. **Python scripts, not shell scripts.** All CLI interaction happens in `scripts/azure_devops.py` and `scripts/kubernetes.py`.

5. **No credentials stored.** Scripts delegate to existing `az` and `kubectl` CLI sessions.

## Components

### `BarWidget.qml`

- Omarchy bar entry point — extends `BarWidget` from `qs.Ui`
- Displays pipeline icon with status dot: healthy `+`, warning `!`, critical `x`
- Instantiates `Service` as a child
- Loads `Panel.qml` via a `Loader`
- Right-click or middle-click triggers manual refresh

### `Service.qml`

- Headless `Item` — no UI
- On startup: reads `config.json` via `cat` subprocess, then runs Python scripts
- Refresh timer (60s default) re-reads config before each fetch
- Exposes: `overallStatus`, `lastUpdated`, `refreshing`, `azureDevOps`, `kubernetes`
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
- Groups by pipeline name, returns current + last status per pipeline
- Checks both `status` and `result` fields (Azure DevOps API quirk — completed runs use `result`)
- Supports `--mock`

### `scripts/kubernetes.py`

- Calls `kubectl get nodes/pods/deployments` per context
- Supports `--context`, `--all-contexts`, `--mock`

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
|-- config.json          <- user configuration
|-- scripts/
|   |-- azure_devops.py  <- Azure DevOps CLI wrapper
|   +-- kubernetes.py    <- kubectl wrapper
+-- mock/
    |-- azure-devops.json
    +-- kubernetes.json
```
