# Configuration

The plugin reads `config.json` from the plugin folder on every refresh.

Location: `~/.config/omarchy/plugins/heinsk.devops/config.json`

## Full Example

```json
{
  "providers": {
    "azureDevOps": true,
    "kubernetes": false
  },
  "refresh": {
    "azureDevOps": 60
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

### `refresh`

| Key           | Type    | Default | Description                    |
|---------------|---------|---------|--------------------------------|
| `azureDevOps` | integer | `60`    | Refresh interval in seconds    |
| `kubernetes`  | integer | `30`    | Refresh interval in seconds    |

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

### `development`

| Key        | Type    | Default | Description                                    |
|------------|---------|---------|------------------------------------------------|
| `mockData` | boolean | `false` | Use mock files instead of real CLI/API calls   |

Mock files: `mock/azure-devops.json`, `mock/kubernetes.json`

## Applying Changes

Config is re-read on every refresh cycle. To apply immediately, click the refresh button in the panel or restart the shell:

```bash
omarchy-restart-shell
```
