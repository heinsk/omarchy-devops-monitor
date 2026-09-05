# Testing Guide

## 1. Test Python scripts directly

```bash
cd ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor

# With mock data
python3 scripts/azure_devops.py --mock | python3 -m json.tool
python3 scripts/kubernetes.py   --mock | python3 -m json.tool

# With real credentials
python3 scripts/azure_devops.py \
  --target https://dev.azure.com/your-org your-project

# Verify exit codes
python3 scripts/azure_devops.py --mock; echo "Exit: $?"   # should be 0
```

## 2. Simulate error states

Edit `mock/azure-devops.json` to trigger specific UI states:

**All healthy:**
```json
{ "provider": "azure-devops", "status": "healthy",
  "pipelines": { "running": 0, "success": 12, "failed": 0 },
  "deployments": { "running": 0, "success": 5, "failed": 0 }, "targets": [] }
```

**Failed pipeline:**
```json
{ "provider": "azure-devops", "status": "warning",
  "pipelines": { "running": 0, "success": 11, "failed": 1 },
  "deployments": { "running": 0, "success": 5, "failed": 0 }, "targets": [] }
```

**Offline:**
```json
{ "provider": "azure-devops", "status": "offline",
  "error": "az CLI not found" }
```

## 3. Validate manifest JSON

```bash
python3 -m json.tool manifest.json
python3 -m json.tool config.json
python3 -m json.tool mock/azure-devops.json
```

## 4. Test on Omarchy

### Install

```bash
PLUGIN=~/.config/omarchy/plugins/io.github.heinsk.devops-monitor
rm -rf "$PLUGIN"
cp -a ~/code/devops-monitor "$PLUGIN"
omarchy-restart-shell
```

### Check log

```bash
NEWEST=$(ls -t /run/user/$UID/quickshell/by-pid/ | head -1)
grep "heinsk" /run/user/$UID/quickshell/by-pid/$NEWEST/log.log | grep -v reloading
```

### Enable mock mode for UI testing

```bash
# Edit config.json
nano ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor/config.json
# Set "mockData": true, then restart shell
omarchy-restart-shell
```

### Cycle states without restarting

Edit `mock/azure-devops.json` directly — the next refresh cycle picks it up automatically (no restart needed).

### Test refresh

Click the `↺ Refresh` button in the panel — the timestamp should update.

### Test pipeline View links

Click `↗` on any pipeline row — the browser should open the Azure DevOps URL.

## 5. Pre-commit checklist

```
[ ] python3 scripts/azure_devops.py --mock | python3 -m json.tool  -- valid JSON
[ ] python3 scripts/kubernetes.py   --mock | python3 -m json.tool  -- valid JSON
[ ] python3 -m json.tool manifest.json                             -- valid JSON
[ ] python3 -m json.tool config.json                               -- valid JSON
[ ] Bar widget shows icon + status dot
[ ] Clicking bar opens panel
[ ] Panel shows Azure DevOps section with project and pipelines
[ ] Refresh button updates timestamp
[ ] View links open in browser
[ ] Failed pipeline shows red status
[ ] Last column shows previous run status
[ ] ScrollView works when many pipelines exist
[ ] No credentials appear in script output or logs
```
