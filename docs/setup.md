# Setup Guide

> **Changelog**
> - Added Section 5: GitHub Actions integration (planned — not yet implemented)

## 1. Install the plugin

```bash
omarchy plugin add https://github.com/YOUR_USER/devops-monitor.git --enable
```

Or copy manually:

```bash
cp -a ~/path/to/devops-monitor ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor
omarchy plugin enable io.github.heinsk.devops-monitor
omarchy-restart-shell
```

## 2. Configure

Create or edit `~/.config/omarchy/plugins/io.github.heinsk.devops-monitor/config.json`:

```json
{
  "providers": {
    "azureDevOps": true,
    "kubernetes": false
  },
  "azureDevOps": {
    "top": 50,
    "targets": [
      {
        "organization": "https://dev.azure.com/your-org",
        "project": "your-project"
      }
    ]
  },
  "development": {
    "mockData": false
  }
}
```

## 3. Connect Azure DevOps

### Install Azure CLI

```bash
yay -S azure-cli
az extension add --name azure-devops
```

### Log in

```bash
az login
```

For headless sessions:

```bash
az login --use-device-code
```

### Verify extension

```bash
az extension show --name azure-devops
```

### Test

```bash
python3 ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor/scripts/azure_devops.py \
  --target https://dev.azure.com/your-org your-project
```

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| `az CLI not found` | `yay -S azure-cli` |
| `az devops extension not installed` | `az extension add --name azure-devops` |
| `Not logged in` | `az login` |
| Empty pipeline list | Verify org/project names; run `az pipelines runs list` manually |
| Status shows "Unknown" | Azure DevOps API quirk — the script checks both `status` and `result` fields automatically |

## 4. Connect Kubernetes (optional)

```bash
# For AKS clusters
az aks get-credentials --resource-group YOUR-RG --name YOUR-CLUSTER
```

Add to config:

```json
"kubernetes": {
  "contexts": ["production"]
}
```

## 5. Connect GitHub Actions (future)

> GitHub integration is not yet implemented. This section describes the planned approach.

### Requirements

- `gh` CLI — `yay -S github-cli`
- Logged in — `gh auth login`

### Planned configuration

```json
"github": {
  "targets": [
    {
      "owner": "your-org",
      "repo": "your-repo"
    }
  ]
}
```

### What will be shown

- Workflow run status per repository (latest run per workflow)
- Current and last status columns, same as Azure DevOps
- Duration in minutes
- Link to the run in the browser

### Authentication

```bash
gh auth login
gh auth status   # verify
```

The plugin will use `gh run list` — no tokens are stored. Authentication delegates entirely to the existing `gh` CLI session.

### Contribute

To implement GitHub support, create `scripts/github.py` following the same pattern as `scripts/azure_devops.py`:

1. Accept `--target OWNER REPO` arguments (repeatable)
2. Call `gh run list --repo OWNER/REPO --json name,status,conclusion,startedAt,updatedAt,url`
3. Group by workflow name, return current + last status
4. Output normalized JSON matching the provider shape

The `Service.qml` already has a placeholder for GitHub — enable it by setting `"github": true` in `providers` and wiring the script call in `Service.qml`.

## 6. Reload

```bash
omarchy-restart-shell
```

The bar shows the pipeline icon with a status dot. Click to open the panel.

## 7. Development with mock data

```json
"development": { "mockData": true }
```

Test scripts directly:

```bash
python3 scripts/azure_devops.py --mock | python3 -m json.tool
python3 scripts/kubernetes.py   --mock | python3 -m json.tool
```
