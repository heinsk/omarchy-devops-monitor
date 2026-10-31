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
          "branch": "main",
          "runId": 204
        }
      ],
      "releaseList": [
        {
          "name": "Release - API",
          "status": "success",
          "lastStatus": "success",
          "durationMin": 6,
          "url": "https://dev.azure.com/org/project/_release?definitionId=1",
          "releaseId": 12,
          "stages": [
            { "name": "Production", "status": "failed", "messages": [],
              "tasks": [ { "name": "Deploy to AKS", "status": "failed", "durationSec": 480,
                           "messages": ["kubectl rollout status timed out"] } ] }
          ]
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
  "allContexts": false,
  "namespaces": [],
  "excludeNamespaces": ["kube-system"]
}
```

`namespaces` / `excludeNamespaces` are passed to the script as `--namespace=NAME` / `--exclude-namespace=NAME` (repeatable, max 50 each, validated as Kubernetes namespace names). Nodes are not filtered. With 1–10 included namespaces the pods and deployments of each one are read from `/api/v1/namespaces/NAME/pods` and `/apis/apps/v1/namespaces/NAME/deployments`; otherwise the cluster-wide lists are read and filtered afterwards.

Every list is read with `kubectl get --raw` in pages of 50 objects (`?limit=50&continue=...`). `--raw` streams the API response, so `kubectl` does not collect the whole list in memory the way `-o json` does, and the Kubernetes API limits each object's annotations to 256 KiB, so a page stays small by construction. Limits, all enforced by the script:

| Limit | Value | When exceeded |
|-------|-------|---------------|
| One page | 16 MB (the process is killed while reading) | warning, set `namespaces` |
| Objects per kind | 20,000 | warning, set `namespaces` |
| Time to read one list | 25 s (20 s per request) | warning |
| `kubectl` memory | 1 GiB data segment (`ulimit -d`) | warning "kubectl ran out of memory" |

Each object is cut down to the handful of short fields the panel uses (name, namespace, phase, container states, replica counts, node conditions) as soon as its page is parsed, so annotations, specs and managed fields are never kept.

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
      "deployments": { "ready": 12, "total": 12 },
      "issues": [
        { "kind": "pod", "severity": "failed", "name": "payments-api-7d9f8b-x2k4q",
          "namespace": "payments", "reason": "CrashLoopBackOff", "restarts": 23 }
      ],
      "namespaces": [
        { "name": "payments", "severity": "failed",
          "pods": { "ready": 8, "total": 9 }, "deployments": { "ready": 3, "total": 3 } }
      ]
    }
  ]
}
```

- `issues` lists what is not healthy: nodes that are `NotReady` or under `MemoryPressure` / `DiskPressure` / `PIDPressure`, pods that are not ready (with the reason, e.g. `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled`, `Evicted`, `Pending`, and the restart count) and deployments with missing replicas. It is exactly the set the ready/total counters leave out, sorted failed first, at most 20 (`issuesTotal` gives the real count when more).
- `severity` is `failed` for broken things (crash loops, OOM kills, evictions, a node that is not Ready, a deployment with no ready replica) and `warning` for things that are not ready yet or only partly ready (image pulls, pending, a probe not passing, some replicas missing).
- `namespaces` has one entry per namespace with its pods / deployments ready counters, worst first, at most 50 (`namespacesTotal` gives the real count when more). Names and reasons coming from the cluster are sanitised before they are emitted.
- A query that fails or exceeds the cap is reported in `warnings` (at most 3, control characters removed, cut at 160 characters). `kubectl`'s repeated log lines are reduced to one sentence ("Cannot reach the cluster API server (host:port)", "The cluster rejected the credentials", otherwise the first meaningful line without the log prefix), and identical messages are shown once. An `offline` cluster has empty `nodes` / `pods` / `deployments` objects, which the panel draws as `—/—` and the cluster is at least `warning`; it is `offline` only when nodes, pods and deployments all fail.
- If the whole output would exceed 256 KB, the namespace list and then the issue list are trimmed before giving up.

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
          "detail": "main · push",
          "runId": 1002
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

## Notices

When a provider cannot work, its script adds a `notice` next to the usual `status` / `error`:

```json
{
  "status": "offline",
  "error": "Not logged in to Azure — run: az login",
  "notice": {
    "kind": "setup",
    "title": "Not signed in to Azure",
    "message": "The Azure CLI is installed, but there is no active session.",
    "steps": [{ "label": "Sign in", "command": "az login" }],
    "footer": "The panel checks again on the next refresh."
  }
}
```

| `kind` | Color | Meaning |
|--------|-------|---------|
| `setup` | amber | Something is missing: a CLI to install, a login |
| `error` | red | The provider tried to read and could not (for example an unreachable cluster) |
| `empty` | blue | Nothing is configured yet; the footer opens `config.json` |

The text is fixed by the scripts (`scripts/provider_notice.py` cleans and bounds it: title 80, message 240, at most 5 steps of 200 characters). The only outside value is a kubectl context name, accepted only when it contains no shell syntax. Install commands (package managers, `sudo`) are deliberately not shown. Preview any of them without the real tool using `development.mockError` (see Mock Data).

---

## Mock Data

Enable with `"development": { "mockData": true }` in `config.json`.

Edit mock files to simulate states:

```bash
# Simulate a failed pipeline
nano ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor/mock/azure-devops.json
```

Status values for testing: `"healthy"`, `"warning"`, `"critical"`, `"offline"`, `"unknown"`

## Job details (on demand)

`runId` (pipelines, workflows) and `stages` (releases) feed the expandable rows
of the panel. Jobs of a pipeline or workflow are read only when a row is
expanded, with `scripts/job_detail.py`:

```json
{
  "ok": true,
  "provider": "azure-devops",
  "jobs": [
    { "name": "Test", "stage": "CI", "status": "failed", "durationSec": 300, "messages": [],
      "tasks": [ { "name": "Run unit tests", "status": "failed", "durationSec": 240,
                   "messages": ["Process completed with exit code 1."] } ] }
  ]
}
```

Statuses: `success`, `failed`, `running`, `pending`, `cancelled`, `skipped`, `unknown`.
On failure the script prints `{ "ok": false, "error": "short reason" }`.

- **Azure DevOps builds**: `az devops invoke --area build --resource timeline --api-version 7.1`; jobs are the `Job` records and tasks their `Task` children; `messages` are the record's `issues` of type `error`.
- **Azure DevOps releases**: read from the `environments → deploySteps → releaseDeployPhases → deploymentJobs → tasks` of the release that `az pipelines release show` already returned (latest attempt; only tasks that need attention, with their `issues` and the phase `errorLog`). Missing or unexpected parts are skipped.
- **GitHub Actions**: `gh api repos/OWNER/REPO/actions/runs/RUN_ID/jobs` for jobs and steps; for failed jobs, `gh api repos/OWNER/REPO/check-runs/JOB_ID/annotations` (level `failure`) for the messages.
