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
    "allContexts": false
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

If both are empty/false, the current active context is used.

### `github`

| Key     | Type            | Default | Description                                       |
|---------|-----------------|---------|---------------------------------------------------|
| `repos` | array of string | `[]`    | Repositories to monitor, `"owner/repo"`, max 20   |
| `ghPath`| string          | (none)  | Absolute path to `gh` when it is not in `/usr/bin` etc. (e.g. installed with mise) |

Requires the GitHub CLI (`gh`) logged in to `github.com`. For each
repository the latest run of every workflow is shown.

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
