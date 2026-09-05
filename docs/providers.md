# Providers

## Status Values

| Status     | Meaning                                        |
|------------|------------------------------------------------|
| `healthy`  | All pipelines succeeded                        |
| `warning`  | One or more pipelines failed or are offline    |
| `critical` | Critical failures detected                     |
| `unknown`  | Not yet queried                                |
| `offline`  | CLI unavailable or authentication failed       |
| `disabled` | Provider disabled in configuration             |

---

## Azure DevOps (`scripts/azure_devops.py`)

**Authentication:** existing `az` / `az devops` CLI session — no credentials stored.

**Requirements:**
- `azure-cli` — `yay -S azure-cli`
- `azure-devops` extension — `az extension add --name azure-devops`
- Logged in — `az login`

**Supports multiple targets** (organizations and projects):

```json
"azureDevOps": {
  "targets": [
    { "organization": "https://dev.azure.com/org-one", "project": "project-a" },
    { "organization": "https://dev.azure.com/org-two", "project": "project-b" }
  ]
}
```

**Output shape:**

```json
{
  "provider": "azure-devops",
  "status": "warning",
  "pipelines":   { "running": 1, "success": 14, "failed": 1 },
  "deployments": { "running": 0, "success": 8,  "failed": 0 },
  "targets": [
    {
      "organization": "https://dev.azure.com/org",
      "project": "my-project",
      "status": "warning",
      "pipelines":   { "running": 1, "success": 14, "failed": 1 },
      "deployments": { "running": 0, "success": 8,  "failed": 0 },
      "pipelineList": [
        {
          "name": "CI - Build",
          "status": "failed",
          "lastStatus": "success",
          "durationMin": 8,
          "url": "https://dev.azure.com/org/project/_build?definitionId=1"
        }
      ],
      "releaseList": [
        {
          "name": "Release - API",
          "status": "success",
          "lastStatus": "success",
          "durationMin": 6,
          "url": "https://dev.azure.com/org/project/_release?definitionId=1"
        }
      ]
    }
  ]
}
```

**Important:** Azure DevOps API returns completed runs with `status: "completed"` and the actual
outcome in a separate `result` field (`"succeeded"`, `"failed"`, `"canceled"`). The script checks
both fields — do not rely on `status` alone.

**Panel display:** Per-project sections with pipeline and release tables showing:
- Name, Status, Last (previous run), Time (duration in minutes), View (link to browser)

---

## Kubernetes (`scripts/kubernetes.py`)

**Authentication:** existing `kubectl` configuration — no credentials stored.

**Requirements:**
- `kubectl`

**Configuration:**

```json
"kubernetes": {
  "contexts": ["production", "staging"],
  "allContexts": false
}
```

**Output shape:**

```json
{
  "provider": "kubernetes",
  "status": "healthy",
  "clusters": [
    {
      "name": "production",
      "status": "healthy",
      "nodes":       { "ready": 8,  "total": 8  },
      "pods":        { "ready": 47, "total": 47 },
      "deployments": { "ready": 12, "total": 12 }
    }
  ]
}
```

---

## Mock Data

Enable with `"development": { "mockData": true }` in `config.json`.

Edit mock files to simulate states:

```bash
# Simulate a failed pipeline
nano ~/.config/omarchy/plugins/heinsk.devops/mock/azure-devops.json
```

Status values for testing: `"healthy"`, `"warning"`, `"critical"`, `"offline"`, `"unknown"`
