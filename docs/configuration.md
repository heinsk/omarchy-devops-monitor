# Configuration

The plugin reads `config.json` from the plugin folder on every refresh.

Location: `~/.config/omarchy/plugins/heinsk.devops/config.json`

## Full Example

```json
{
  "providers": {
    "azureDevOps": true,
    "kubernetes": false,
    "github": false
  },
  "refresh": {
    "azureDevOps": 60,
    "kubernetes": 30,
    "github": 60
  },
  "azureDevOps": {
    "top": 50,
    "targets": [
      {
        "organization": "https://dev.azure.com/your-org",
        "project": "your-project"
      },
      {
        "organization": "https://dev.azure.com/your-org",
        "project": "another-project"
      }
    ]
  },
  "kubernetes": {
    "contexts": ["production", "staging"],
    "allContexts": false,
    "namespaces": [],
    "excludeNamespaces": ["kube-system"]
  },
  "github": {
    "repos": ["your-user/your-repo"]
  },
  "development": {
    "mockData": false
  }
}
```

## Reference

### `providers`

| Key           | Type    | Default | Description           |
|---------------|---------|---------|-----------------------|
| `azureDevOps` | boolean | `true`  | Azure DevOps provider |
| `kubernetes`  | boolean | `false` | Kubernetes provider   |
| `github`      | boolean | `false` | GitHub Actions provider |

### `refresh`

| Key           | Type    | Default | Description                    |
|---------------|---------|---------|--------------------------------|
| `azureDevOps` | integer | `60`    | Refresh interval in seconds    |
| `kubernetes`  | integer | `30`    | Refresh interval in seconds    |
| `github`      | integer | `60`    | Refresh interval in seconds    |

Each provider has its own independent timer. Values are clamped to
**30–3600** seconds; a missing or non-numeric value falls back to `60`.
Changes are picked up on the next refresh of that provider.

> `providers.azureDevOps` / `providers.kubernetes` / `providers.github` can also be changed
> from the panel (Configuration tab → switch next to the provider). The
> plugin then edits only that boolean in `config.json`
> (`scripts/write_config.py`); it refuses to write if `config.json` is a
> symlink, not a regular file, invalid JSON, or larger than 256 KB.

### `azureDevOps`

| Key       | Type    | Default | Description                          |
|-----------|---------|---------|--------------------------------------|
| `top`     | integer | `50`    | Max pipeline runs to fetch per query |
| `targets` | array   | `[]`    | List of `{ organization, project }`  |

Each target:

```json
{
  "organization": "https://dev.azure.com/your-org",
  "project": "your-project"
}
```

Multiple targets are supported — different projects in the same org, or across different organizations.

### `kubernetes`

| Key          | Type            | Default | Description                              |
|--------------|-----------------|---------|------------------------------------------|
| `contexts`   | array of string | `[]`    | Specific contexts to monitor             |
| `allContexts`| boolean         | `false` | Monitor all contexts in kubeconfig       |
| `namespaces` | array of string | `[]`    | Only count these namespaces (empty = all), max 50 |
| `excludeNamespaces` | array of string | `[]` | Ignore these namespaces, max 50. **An excluded namespace always wins** over `namespaces` |

If both `contexts` and `allContexts` are empty/false, the current active context is used.

Namespace names must be valid Kubernetes namespace names (lowercase letters, digits and `-`, up to 63 characters). An invalid name is reported as an error in the panel instead of being ignored. The filter applies to pods and deployments (nodes are cluster-wide), so the counters, the "Needs attention" list and "Pods by namespace" all agree with it. The Configuration tab shows the active filter under **Kubernetes Namespaces**.

**Large clusters:** with up to 10 names in `namespaces`, each namespace is queried directly, so only those pods and deployments are downloaded. Without a filter (or with more than 10 names) the whole cluster is listed page by page (50 objects per request) up to 20,000 objects per kind and 25 seconds per list; beyond that the panel shows a warning asking you to set `namespaces`. `excludeNamespaces` is applied after download, so it does not reduce the size.

### `github`

| Key     | Type            | Default | Description                                       |
|---------|-----------------|---------|---------------------------------------------------|
| `repos` | array of string | `[]`    | Repositories to monitor, `"owner/repo"`, max 20   |
| `ghPath`| string          | (none)  | Absolute path to `gh` when it is not in `/usr/bin` etc. (e.g. installed with mise) |

Requires the GitHub CLI (`gh`) logged in to `github.com`. For each
repository the latest run of every workflow is shown.

### `notifications`

Desktop alerts when something starts failing. **Off by default.**

```json
"notifications": {
  "enabled": false,
  "providers": ["azureDevOps", "kubernetes", "github"],
  "onRecovery": false,
  "branches": [],
  "maxPerHour": 5
}
```

| Key          | Type            | Default | Description |
|--------------|-----------------|---------|-------------|
| `enabled`    | boolean         | `false` | Turn desktop alerts on |
| `providers`  | array of string | all three | Providers that may notify (`azureDevOps`, `kubernetes`, `github`) |
| `onRecovery` | boolean         | `false` | Also notify when a failing item is healthy again (low urgency) |
| `branches`   | array of string | `[]` (all) | Only alert for these branches; exact name or a trailing `*` (`release/*`). Applies to pipelines and workflows |
| `maxPerHour` | integer         | `5`     | Alerts per provider per hour, 1..30. Extra problems are folded into one "N new problems" summary |

How it behaves:

- An alert is sent only when an item **changes** to a failing state. The first reading after the shell starts is the baseline and never notifies; offline readings are ignored.
- Alerts are sent with `notify-send` (package `libnotify`, `/usr/bin/notify-send`), which talks to your notification server (mako on Omarchy) over the standard D-Bus interface. The plugin checks at startup that it exists and the Configuration tab shows **Delivery: notify-send found / not found**. Without it desktop alerts are disabled: the **Silence** controls are hidden, the Notifications card says "Unavailable — notify-send not found" and nothing is sent, while the panel and the bar counter keep working.
- **Silence**: with notifications on, each provider header has a **Silence** control (1 hour, until 08:00, indefinitely). Problems that appear while silenced are consumed silently, so unmuting never replays them. Silences are kept in `$XDG_STATE_HOME/io.github.heinsk.devops-monitor/state.json` (default `~/.local/state/...`), a private file (0600) in a private folder (0700); the plugin never writes anything else outside its own config.
- The bar shows a problem count (`! 7`) and the tooltip lists the count per provider.
- The Configuration tab has a **Desktop alerts** switch under **Notifications** (shown only when `notify-send` exists). It writes `notifications.enabled` in `config.json` the same way the provider switches write `providers.*`, and a config without a `notifications` block gets `{ "enabled": true }`. The other settings are shown read-only; edit them in `config.json`.
- **Testing with mock data:** Omarchy reloads a plugin whenever a file inside its folder changes, and after a reload the first reading is the new baseline, so editing `mock/*.json` in place never produces an alert. Keep the mock outside the folder and link it: `cp mock/azure-devops.json ~/azure-devops-mock.json && mv mock/azure-devops.json mock/azure-devops.json.orig && ln -s ~/azure-devops-mock.json mock/azure-devops.json`, then edit the copy in your home folder.

### `development`

| Key        | Type    | Default | Description                                    |
|------------|---------|---------|------------------------------------------------|
| `mockData` | boolean | `false` | Use mock files instead of real CLI/API calls   |

Mock files: `mock/azure-devops.json`, `mock/kubernetes.json`, `mock/github-actions.json`

## Applying Changes

Config is re-read on every refresh cycle. To apply immediately, click the refresh button in the panel or restart the shell:

```bash
omarchy-restart-shell
```
