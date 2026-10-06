# Setup Guide

> **Changelog**
> - Section 4: Kubernetes is now fully wired up (kubectl install, requirements, verify, config, test, troubleshooting) — previously only had a partial config snippet
> - Removed the GitHub Actions (future) section — not implemented, and not currently planned

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

### Requirements

- `kubectl`, configured with the cluster(s) you want to monitor (`~/.kube/config`)

### Install kubectl

`kubectl` is in Arch's official `extra` repository (unlike `azure-cli`, it doesn't need the AUR):

```bash
sudo pacman -S kubectl
```

Verify the install:

```bash
kubectl version --client
```

If you'd rather track upstream releases directly, the AUR package works too:

```bash
yay -S kubectl-bin
```

If your cluster isn't already in your kubeconfig, add it next. For example, for AKS clusters:

```bash
az aks get-credentials --resource-group YOUR-RG --name YOUR-CLUSTER
```

### Verify

```bash
kubectl config get-contexts
```

Confirm the context name(s) you want to monitor appear in this list — that's the exact string to use in `contexts` below.

### Enable in config

```json
{
  "providers": {
    "kubernetes": true
  },
  "kubernetes": {
    "contexts": ["production"],
    "allContexts": false
  }
}
```

- `contexts`: specific context names to monitor (from `kubectl config get-contexts`). Supports multiple.
- `allContexts`: set to `true` to monitor every context in your kubeconfig — this overrides `contexts` when enabled.
- If both `contexts` is empty and `allContexts` is `false`, the plugin falls back to whatever `kubectl config current-context` reports.

Example monitoring multiple contexts explicitly:

```json
"kubernetes": {
  "contexts": ["production", "staging"],
  "allContexts": false
}
```

### Test

```bash
python3 ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor/scripts/kubernetes.py \
  --context production
```

This prints the same normalized JSON the panel consumes — node/pod/deployment ready-vs-total counts per cluster.

### What's shown

Once enabled, the panel's **Status** tab adds a **Kubernetes** section below Azure DevOps, listing each monitored cluster with its health (`Healthy` / `Warning` / `Offline`) and Nodes/Pods/Deployments ready counts. The **Configuration** tab shows which contexts are configured under **Kubernetes Contexts**. If the provider itself fails (see Troubleshooting below), a red error banner appears in place of the cluster list instead of failing silently.

### Troubleshooting

| Symptom | Fix |
|---------|-----|
| `kubectl not found — install kubectl` | Install `kubectl` and ensure it's on `/usr/local/bin`, `/usr/bin`, or `/bin` |
| `No active kubectl context — run: kubectl config use-context <name>` | Set a context with `kubectl config use-context <name>`, or configure `contexts`/`allContexts` explicitly |
| `Too many contexts configured (...) — max is 20` | Reduce the `contexts` list, or don't combine a huge list with `allContexts: true` |
| Cluster shows `Offline` | The kubectl command for that context failed or timed out (20s) — check the error text in the panel's banner, or run the **Test** command above for the exact kubectl error |
| Cluster shows `Warning` | One or more nodes/pods/deployments aren't ready — this reflects real cluster state, not a plugin issue |

## Per-provider refresh and enable/disable

- Each provider refreshes on its own timer: `refresh.azureDevOps` and
  `refresh.kubernetes` in `config.json` (seconds, clamped to 30–3600,
  default 60).
- On the **Status** tab each enabled provider has its own refresh icon
  (↻); disabled providers are hidden. Right-click the bar icon to refresh
  all.
- On the **Configuration** tab, the switch next to each provider enables
  or disables it and saves the choice to `providers.<name>` in
  `config.json`. If `config.json` is a symlink the panel refuses to write
  and shows an error; edit the file by hand instead.
- With `development.mockData` enabled both providers run in mock mode
  regardless of the switches.

## Provider icons (optional)

The Status tab shows a coloured text symbol before each provider's name
(`▶` for Azure DevOps, `◈` for Kubernetes — characters that exist in the
main JetBrains Mono / DejaVu Sans Mono fonts, so no icon font is needed).
To show an image instead, put it in the plugin's `assets/` folder:

| Provider     | File (first one found is used)                     |
|--------------|----------------------------------------------------|
| Azure DevOps | `assets/azure-devops.svg`, then `assets/azure-devops.png` |
| Kubernetes   | `assets/kubernetes.svg`, then `assets/kubernetes.png`     |

- The plugin does **not** ship any third-party logo. Get the official
  artwork from the vendor (Microsoft / the Kubernetes project) and check
  its brand and licensing terms before committing it to a public repo.
- A square image works best; it is drawn at about 16 px, preserving
  aspect ratio.
- If a file is missing or can't be decoded, the text symbol is shown. Quickshell
  may log a harmless "Cannot open ... assets/..." line in that case.

## 5. Reload

```bash
omarchy-restart-shell
```

The bar shows the pipeline icon with a status dot. Click to open the panel.

## 6. Development with mock data

```json
"development": { "mockData": true }
```

Test scripts directly:

```bash
python3 scripts/azure_devops.py --mock | python3 -m json.tool
python3 scripts/kubernetes.py   --mock | python3 -m json.tool
```

### Simulating an error state in the panel

To see the panel's error banners (including the "missing dependency"
indicator) without uninstalling anything, add `mockError` under
`development`:

```json
"development": {
  "mockData": true,
  "mockError": {
    "azureDevOps": "missing-dependency",
    "kubernetes": "generic"
  }
}
```

Both keys are optional and independent — set one, both, or neither.
Allowed values are `"missing-dependency"` (renders the amber "Install
<tool>" indicator) and `"generic"` (renders the regular red error
banner). Any other value is ignored and the provider runs in normal
mock mode. This only has an effect while `mockData` is `true`; it's
silently ignored otherwise.
