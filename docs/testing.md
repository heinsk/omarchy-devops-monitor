# Testing Guide

## 0. Automated tests (run these first)

The `tests/` folder holds the plugin's own tests. They need only Python 3 (no
packages) and never touch your real `az`, `kubectl` or `gh`: each test builds
small stand-ins in a temporary folder and removes them when it finishes.

```bash
python3 tests/run_all.py          # every test; exit code 0 = all passed
python3 tests/test_notices.py     # a single test file
```

| File | What it checks |
|------|----------------|
| `test_notices.py` | The "what to do next" notices: CLI missing, not signed in, nothing configured, cluster unreachable; every notice is plain text, bounded, and carries no install command |
| `test_k8s_backend.py` | Kubernetes counters, issues, namespace filters, caps and the 256 KB output limit |
| `test_k8s_errors.py` | kubectl failures turn into one readable message, never raw log dumps |
| `test_k8s_large.py` | Big clusters: paged reads, memory / object / page / time caps, hostile objects and context names |
| `test_hardening.py` | Text from the services is stripped of control, zero-width and bidirectional characters; Azure DevOps links must point to a real Azure DevOps host (no `user@` tricks); a failed state write leaves no temporary file |
| `test_state_store.py` | The silence state file: private permissions, symlinks refused, corrupt or huge files ignored, concurrent writers |
| `test_job_detail.py` | Jobs, tasks and error messages (Azure DevOps timeline and releases, GitHub jobs and annotations): parsing, caps, text cleaning, argument validation, read-only requests, mock mode |
| `test_mock_and_config.py` | Mock mode of the three providers; `read_config.py` and `write_config.py` (symlink, invalid JSON, size) |

GitHub runs the same command on every pull request (`.github/workflows/test.yml`):
a red mark next to "Checks" means a test failed.

The panel itself (QML) is not covered by these tests; check it by hand with
mock mode (section 4).

## Real clusters checklist

The Kubernetes reads (`kubectl get --raw`, paged) are tested with a stand-in
`kubectl`. Before a release, repeat this on a real cluster and note the result
in the table at the end. The environments worth covering are k3d, kind,
minikube and one managed remote cluster (for example AKS or EKS).

For each environment:

1. Create a few namespaces with healthy pods and with broken ones:
   ```bash
   kubectl create namespace demo-ok
   kubectl -n demo-ok create deployment web --image=nginx --replicas=2
   kubectl create namespace demo-broken
   kubectl -n demo-broken create deployment bad --image=nginx:does-not-exist
   kubectl -n demo-broken run crash --image=busybox -- sh -c "exit 1"
   ```
2. Compare the panel with `kubectl get pods -A`: the pods counter (ready / total),
   the deployments counter and the namespace list must match.
3. Check the limits: `kubectl get --raw "/api/v1/pods?limit=2" --context YOUR-CONTEXT | head -c 300`
   must answer, and the panel must still refresh in a few seconds.
4. Edge cases, one by one:
   - Stop the cluster (for k3d: `k3d cluster stop NAME`): the card shows
     "Cannot reach NAME" with the steps to check and start it.
   - Expire the login (managed clusters): a message about the credentials.
   - Use a context without permission to list pods: a warning, not a healthy cluster.
   - Set `kubernetes.contexts` to a name that does not exist: an error, not a crash.

| Environment | Version | Date | Result | Differences found |
|-------------|---------|------|--------|-------------------|
| k3d | | | | |
| kind | | | | |
| minikube | | | | |
| AKS / EKS / GKE | | | | |

## 1. Test Python scripts directly

```bash
cd ~/.config/omarchy/plugins/io.github.heinsk.devops-monitor

# With mock data
python3 scripts/azure_devops.py --mock | python3 -m json.tool
python3 scripts/kubernetes.py   --mock | python3 -m json.tool
python3 scripts/github_actions.py --mock | python3 -m json.tool

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

### Test pipeline links

Click `↗` on any pipeline row — the browser should open the Azure DevOps URL.
Click the icon to its left (Copy URL) — it should show "Copied", and pasting
(`wl-paste`) should give the same link.

### Test the About tab

Click **About**: the pixel animation should move (a crate through commit, build,
test and deploy; the second run fails its tests) and stop when you switch to
another tab. **Copy** next to the repository should show "Copied".

### Test jobs, tasks and errors

With `development.mockData` on, click the name of **Deploy — Production**: the
jobs of the run and the red task "Run unit tests" with its error message appear.
Do the same on **Release — Frontend** (stage "Production") and on the failed
**Deploy** workflow of `my-org/web-app`. The Copy icon next to an error copies
the message. From a terminal: `python3 scripts/job_detail.py --mock azure 203`.

## 5. Pre-commit checklist

```
[ ] python3 scripts/azure_devops.py --mock | python3 -m json.tool  -- valid JSON
[ ] python3 scripts/kubernetes.py   --mock | python3 -m json.tool  -- valid JSON
[ ] python3 scripts/github_actions.py --mock | python3 -m json.tool -- valid JSON
[ ] python3 -m json.tool manifest.json                             -- valid JSON
[ ] python3 -m json.tool config.json                               -- valid JSON
[ ] Bar widget shows icon + status dot
[ ] Clicking bar opens panel
[ ] Panel shows Azure DevOps section with project and pipelines
[ ] Refresh button updates timestamp
[ ] Open link opens the browser; Copy URL copies the link
[ ] Expanding a failed row shows its jobs, tasks and error message
[ ] About tab shows the summary and the animation; it stops when leaving the tab
[ ] Failed pipeline shows red status
[ ] Last column shows previous run status
[ ] ScrollView works when many pipelines exist
[ ] No credentials appear in script output or logs
```
