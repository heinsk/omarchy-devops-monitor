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
          "url": "https://dev.azure.com/org/project/_build?definitionId=1",
          "branch": "main"
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
- Name (with the branch of the latest run underneath), Status, Last (previous run), Time (duration in minutes), View (link to browser)

`branch` comes from the run's `sourceBranch`: `refs/heads/x` is shown as `x`,
`refs/pull/N/merge` as `PR #N` and `refs/tags/x` as `tag x`. Releases have no
branch. If a run reports none the line is simply not shown.

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

## GitHub Actions (`scripts/github_actions.py`)

**Authentication:** existing GitHub CLI login (`gh auth login`) — no credentials stored.

**Requirements:**
- `gh` (package `github-cli`)

**Configuration:**

```json
"github": {
  "repos": ["my-org/web-app", "my-org/api"],
  "ghPath": "/optional/absolute/path/to/gh"
}
```

**Output shape:**

```json
{
  "provider": "github-actions",
  "status": "warning",
  "repos": [
    {
      "repo": "my-org/web-app",
      "status": "warning",
      "pipelineList": [
        {
          "name": "Deploy",
          "status": "failed",
          "lastStatus": "success",
          "durationMin": 5,
          "url": "https://github.com/my-org/web-app/actions/runs/1002",
          "detail": "main · push"
        }
      ]
    }
  ]
}
```

Status mapping of the latest run: not completed → `running`; `success`
→ `success`; `failure` / `timed_out` / `startup_failure` → `failed`;
`cancelled` → `cancelled`; `skipped` / `neutral` / `stale` → `skipped`;
anything else → `unknown`. Only `failed` makes a repository `warning`.

---

## Mock Data

Enable with `"development": { "mockData": true }` in `config.json`.

Edit mock files to simulate states:

```bash
# Simulate a failed pipeline
nano ~/.config/omarchy/plugins/heinsk.devops/mock/azure-devops.json
```

Status values for testing: `"healthy"`, `"warning"`, `"critical"`, `"offline"`, `"unknown"`
