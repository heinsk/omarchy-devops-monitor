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
        scripts/azure_devops.py
                    |
                 az CLI
```

> **Note:** `scripts/kubernetes.py` exists and is fully functional standalone
> (`python3 scripts/kubernetes.py --mock`), but `Service.qml` does not yet spawn
> it — the `kubernetes` property stays at its static placeholder value and
> `Panel.qml`'s Configuration tab only reflects the `providers.kubernetes`
> config flag, not real cluster data. See "Kubernetes provider status" below.

## Key Rules

1. **Flat file structure.** All QML files live at the plugin root. Required by Omarchy's plugin loader.

2. **`BarWidget.qml` is the sole entry point.** It instantiates `Service` and loads `Panel.qml` via a `Loader`. The manifest declares only `bar-widget`.

3. **`Service.qml` owns all data fetching.** It reads `config.json` on startup, builds subprocess arguments, and runs the Python scripts. The UI only reads properties. Today this only covers the Azure DevOps provider (see "Kubernetes provider status" below).

4. **Python scripts, not shell scripts.** All CLI interaction happens in `scripts/azure_devops.py` (wired into `Service.qml`) and `scripts/kubernetes.py` (standalone only, not yet wired in).

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
- On startup: reads `config.json` via a `cat` subprocess, then runs `scripts/azure_devops.py` (the Kubernetes provider is not fetched — see note below)
- Refresh timer (60s default) re-reads config before each fetch
- Exposes: `overallStatus`, `lastUpdated`, `refreshing`, `azureDevOps`, `kubernetes` (the latter stays at its static placeholder value: `{ status: "unknown", clusters: [] }`)
- Uses `Process` + `StdioCollector` from `Quickshell.Io`
- Hardening: invokes `cat`/`python3` via absolute paths (`/bin/cat`, `/usr/bin/python3`) rather than relying on `$PATH`; resolves the plugin directory from the QML file's own URL rather than `$HOME`; runs a 120s watchdog timer that force-terminates a hung `az` process tree and resets state; sanitizes stderr (printable ASCII only, 200-char cap) before surfacing it as `lastError`

### `Panel.qml`

- Extends `Panel` from `qs.Ui` with `KeyboardPanel`
- Header: title, timestamp (`HH:mm`), refresh button
- Two tabs: **Pipelines** and **Configuration**
  - *Pipelines* tab: Azure DevOps section groups projects and their pipelines/releases; per-pipeline table (Name | Status | Last | Time | View); `ScrollView` handles overflow
  - *Configuration* tab: shows provider enabled/disabled state (Azure DevOps, Kubernetes), refresh interval, mock-mode indicator, and configured targets — this reflects `config.json` only, not live cluster health
- `Qt.openUrlExternally()` opens pipeline URLs in the browser, gated by an HTTPS + host-allowlist check (`dev.azure.com`, `vsrm.dev.azure.com`, `visualstudio.com`)

### `scripts/azure_devops.py`

- Accepts `--target ORG PROJECT` (repeatable for multiple projects)
- Calls `az pipelines runs list` and `az pipelines release list`
- Groups by pipeline name, returns current + last status per pipeline
- Checks both `status` and `result` fields (Azure DevOps API quirk — completed runs use `result`)
- Supports `--mock`
- Invoked directly by `Service.qml` on every refresh

### `scripts/kubernetes.py`

- Calls `kubectl get nodes/pods/deployments` per context
- Supports `--context`, `--all-contexts`, `--mock`
- **Not currently invoked by `Service.qml`.** Fully functional standalone (see `docs/providers.md` for its output shape), but the QML wiring to fetch and render its output has not been implemented yet. Test it directly with `python3 scripts/kubernetes.py --mock`.

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

## Kubernetes provider status

`scripts/kubernetes.py` is fully implemented and documented (see `docs/providers.md`), but it is **not yet wired into the live plugin data flow**:

- `Service.qml` never spawns it — there is no `kubernetesProcess`, and the `kubernetes` property is a static placeholder that is never updated or factored into `overallStatus`.
- `Panel.qml`'s Configuration tab shows Kubernetes as "Active"/"Disabled" purely from the `providers.kubernetes` flag in `config.json` — it does not reflect real cluster health.
- The script can be exercised manually today via `python3 scripts/kubernetes.py --mock` (see the README's Development section), but full integration (spawning it from `Service.qml`, exposing `kubernetes.clusters`, and rendering a cluster table in `Panel.qml`) is future work.

## File Structure

```
heinsk.devops/
|-- manifest.json
|-- BarWidget.qml        <- bar entry point
|-- Service.qml          <- data and state
|-- Panel.qml            <- popup UI
|-- config.json          <- user configuration
|-- scripts/
|   |-- azure_devops.py  <- Azure DevOps CLI wrapper (wired into Service.qml)
|   +-- kubernetes.py    <- kubectl wrapper (standalone only, not yet wired into Service.qml)
+-- mock/
    |-- azure-devops.json
    +-- kubernetes.json
```
