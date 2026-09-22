# DevTools

A concise overview of the technologies used to build and run the DevOps Monitor plugin, and why each one is used.

## Platform

**[Omarchy](https://omarchy.org/)**
The Linux desktop distribution/shell this plugin extends. Defines the plugin manifest format (`manifest.json`), the plugin loading conventions (flat file structure, `bar-widget` entry point), and the CLI used to install/enable/remove plugins (`omarchy plugin add|enable|remove`).

**Quickshell (`qs.Ui`, `Quickshell.Io`)**
The Qt/QML-based shell toolkit that Omarchy's bar is built on. The plugin extends Quickshell's `BarWidget`/`Panel`/`KeyboardPanel` base types for UI, and uses `Quickshell.Io`'s `Process` + `StdioCollector` to run subprocesses (`cat`, `python3`) and collect their output asynchronously without blocking the shell.

## UI Layer

**QML (Qt Modeling Language)**
The declarative UI/scripting language used for all three plugin components:
- [`BarWidget.qml`](/home/heinsk/Documents/dev/personal/plugins/omarchy-devops-monitor/BarWidget.qml) — the bar entry point; shows the pipeline icon and status dot, instantiates the `Service` and loads the `Panel` via a `Loader`.
- [`Service.qml`](/home/heinsk/Documents/dev/personal/plugins/omarchy-devops-monitor/Service.qml) — a headless `Item` that owns all data fetching: reads `config.json`, runs the Python scripts, exposes state (`azureDevOps`, `kubernetes`, `overallStatus`, etc.) as bindable properties.
- [`Panel.qml`](/home/heinsk/Documents/dev/personal/plugins/omarchy-devops-monitor/Panel.qml) — the popup UI that renders pipeline/release tables and opens pipeline URLs in the browser via `Qt.openUrlExternally()`.

Qt's property binding system is what keeps the UI reactive: components read `Service` properties directly rather than through manual event wiring.

## Data Fetching / Scripting

**Python 3**
Used for all CLI interaction with external tools, kept out of QML/shell scripts for testability and cleaner argument/JSON handling.
- [`scripts/azure_devops.py`](/home/heinsk/Documents/dev/personal/plugins/omarchy-devops-monitor/scripts/azure_devops.py) — wraps `az pipelines runs list` / `az pipelines release list`, normalizes multi-project/organization results into a single JSON object.
- [`scripts/kubernetes.py`](/home/heinsk/Documents/dev/personal/plugins/omarchy-devops-monitor/scripts/kubernetes.py) — wraps `kubectl get nodes/pods/deployments` across one or more contexts.

Both scripts use only the Python standard library (`subprocess`, `json`, `argparse`), avoiding extra dependencies, and support a `--mock` flag for development without live infrastructure.

**JSON**
The interchange format used everywhere data crosses a process boundary: script stdout, `config.json` (user configuration), `manifest.json` (plugin metadata), and the `mock/` fixtures used for development.

## External CLIs (delegated, not bundled)

**Azure CLI (`az`) + `azure-devops` extension**
Provides authentication and data access for Azure DevOps pipelines and releases. The plugin never stores credentials — it shells out to an already-authenticated `az` session (`az login` is a prerequisite, done outside the plugin).

**kubectl**
Provides cluster access for the optional Kubernetes provider, using the user's existing `~/.kube/config` context(s). Also not bundled or configured by the plugin.

**k9s** *(optional)*
An optional terminal UI for Kubernetes that the plugin can launch as an external cluster viewer; not required for the status data itself.

## Configuration & Metadata

**`config.json`**
User-editable configuration (which providers are enabled, refresh intervals, Azure DevOps organization/project targets, mock-data toggle). Read by `Service.qml` on startup and on every refresh cycle.

**`manifest.json`**
Omarchy plugin metadata (id, version, entry point, bar-widget display settings) consumed by the Omarchy plugin loader.

## Documentation

**Markdown**
Used for all project documentation (`README.md`, `SECURITY.md`, and the `docs/` guides for setup, configuration, providers, architecture, and testing), keeping docs versioned alongside the code with no separate doc-site tooling required.
