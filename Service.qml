import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string overallStatus: "unknown"
    property string lastUpdated: ""
    property string lastError: ""
    property bool refreshing: false

    property var azureDevOps: ({ status: "unknown", pipelines: null, deployments: null, targets: [] })
    property var kubernetes:  ({ status: "unknown", clusters: [] })
    property var _config: ({})
    property string configError: ""  // non-empty when config.json was rejected or invalid

    // Resolve plugin dir from QML file location — immune to HOME env manipulation
    readonly property string _pluginDir: Qt.resolvedUrl(".").toString()
        .replace(/^file:\/\//, "").replace(/\/$/, "")

    property string _azureOutput: ""
    property string _azureError:  ""
    property bool   _azureDone:   false
    property string _kubernetesOutput: ""
    property string _kubernetesError:  ""
    property bool   _kubernetesDone:   false
    property string _configRaw:   ""
    property string _configErr:   ""
    property bool   _configDone:  false  // guard against double-start

    // ── Config reader ──────────────────────────────────────────────────────────
    // Runs scripts/read_config.py, which enforces a byte cap and rejects
    // config.json if it's not a regular file (see refresh()). On any
    // rejection or parse failure we fall back to cfg = {} exactly as
    // before, but also surface a short reason via configError so the
    // panel can show the person why their settings aren't being read.

    Process {
        id: configReader
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._configRaw = text
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._configErr = text
        }
        onExited: function() {
            if (root._configDone) return  // prevent double-start
            root._configDone = true
            var raw = String(root._configRaw || "").trim()
            var cfg = {}
            var err = ""
            if (raw) {
                try {
                    cfg = JSON.parse(raw)
                } catch(e) {
                    err = "config.json contains invalid JSON — using defaults"
                }
            } else {
                // Sanitize stderr from read_config.py: printable ASCII only, max 200 chars
                var reason = String(root._configErr || "").trim()
                    .replace(/[^\x20-\x7E]/g, "")
                    .substring(0, 200)
                err = reason || "config.json could not be read — using defaults"
            }
            root.configError = err
            root._config = cfg
            root._startRefresh(cfg)
        }
    }

    // ── Refresh timer ──────────────────────────────────────────────────────────

    Timer {
        interval: 60000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: root.refresh()
    }

    // ── Watchdog — force-reset if refresh hangs beyond 120 s ──────────────────

    Timer {
        id: watchdog
        interval: 120000
        repeat: false
        running: false
        onTriggered: {
            if (root.refreshing) {
                // Terminate any process trees still running before resetting state
                if (azureProcess.running)      azureProcess.terminate()
                if (kubernetesProcess.running) kubernetesProcess.terminate()
                root.refreshing = false
                root.lastError = "Refresh timed out"
                root.lastUpdated = Qt.formatTime(new Date(), "HH:mm")
            }
        }
    }

    Component.onCompleted: {
        root.refresh()
    }

    // ── Azure DevOps process ───────────────────────────────────────────────────

    Process {
        id: azureProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._azureOutput = text
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._azureError = text
        }
        onExited: function() {
            var out = String(root._azureOutput || "").trim()
            if (out) {
                try { root.azureDevOps = JSON.parse(out) }
                catch(e) { root.azureDevOps = { status: "offline", error: "Parse error" } }
            } else {
                // Sanitize stderr: printable ASCII only, max 200 chars
                var errMsg = String(root._azureError || "No output from script")
                    .replace(/[^\x20-\x7E]/g, "")
                    .substring(0, 200)
                root.azureDevOps = { status: "offline", error: errMsg }
            }
            root._azureDone = true
            root._checkDone()
        }
    }

    // ── Kubernetes process ─────────────────────────────────────────────────────

    Process {
        id: kubernetesProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._kubernetesOutput = text
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._kubernetesError = text
        }
        onExited: function() {
            var out = String(root._kubernetesOutput || "").trim()
            if (out) {
                try { root.kubernetes = JSON.parse(out) }
                catch(e) { root.kubernetes = { status: "offline", error: "Parse error", clusters: [] } }
            } else {
                // Sanitize stderr: printable ASCII only, max 200 chars
                var errMsg = String(root._kubernetesError || "No output from script")
                    .replace(/[^\x20-\x7E]/g, "")
                    .substring(0, 200)
                root.kubernetes = { status: "offline", error: errMsg, clusters: [] }
            }
            root._kubernetesDone = true
            root._checkDone()
        }
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    function refresh() {
        if (refreshing) return
        refreshing = true
        _configDone = false
        _configRaw  = ""
        _configErr  = ""
        watchdog.restart()
        // Read via a small, hardened Python helper instead of /bin/cat:
        // it enforces a byte cap and refuses to follow config.json through
        // to a special file (FIFO/device) if it has been replaced by a
        // symlink to one. Absolute path — no PATH dependency.
        configReader.command = ["/usr/bin/python3", root._pluginDir + "/scripts/read_config.py"]
        configReader.running = true
    }

    function _startRefresh(cfg) {
        _azureDone       = false
        _azureOutput     = ""
        _azureError      = ""
        _kubernetesDone  = false
        _kubernetesOutput = ""
        _kubernetesError  = ""
        lastError     = ""

        var mock         = cfg.development && cfg.development.mockData
        var azureEnabled = cfg.providers   && cfg.providers.azureDevOps
        var k8sEnabled   = cfg.providers   && cfg.providers.kubernetes

        if (azureEnabled || mock) {
            // Absolute path for python3 — no PATH dependency
            var azureArgs = ["/usr/bin/python3",
                             root._pluginDir + "/scripts/azure_devops.py"]
            if (mock) {
                azureArgs.push("--mock")
            } else {
                var targets = cfg.azureDevOps && cfg.azureDevOps.targets
                var MAX_TARGETS = 20  // matches azure_devops.py MAX_TARGETS
                if (targets && targets.length > 0) {
                    var count = Math.min(targets.length, MAX_TARGETS)
                    for (var i = 0; i < count; i++) {
                        azureArgs.push("--target",
                                       targets[i].organization,
                                       targets[i].project)
                    }
                }
            }
            azureProcess.command = azureArgs
            azureProcess.running = true
        } else {
            root.azureDevOps = {
                status: "disabled", pipelines: null, deployments: null, targets: []
            }
            _azureDone = true
            _checkDone()
        }

        if (k8sEnabled || mock) {
            // Absolute path for python3 — no PATH dependency
            var k8sArgs = ["/usr/bin/python3",
                           root._pluginDir + "/scripts/kubernetes.py"]
            if (mock) {
                k8sArgs.push("--mock")
            } else {
                var k8sCfg = cfg.kubernetes || {}
                if (k8sCfg.allContexts) {
                    k8sArgs.push("--all-contexts")
                } else {
                    var contexts = k8sCfg.contexts || []
                    var MAX_CONTEXTS = 20  // matches kubernetes.py MAX_CONTEXTS
                    var k8sCount = Math.min(contexts.length, MAX_CONTEXTS)
                    for (var j = 0; j < k8sCount; j++) {
                        k8sArgs.push("--context", contexts[j])
                    }
                    // If neither allContexts nor any contexts are configured,
                    // kubernetes.py falls back to the current kubectl context.
                }
            }
            kubernetesProcess.command = k8sArgs
            kubernetesProcess.running = true
        } else {
            root.kubernetes = { status: "disabled", clusters: [] }
            _kubernetesDone = true
            _checkDone()
        }
    }

    function _checkDone() {
        if (!_azureDone || !_kubernetesDone) return

        // Combine both providers' statuses, ignoring whichever are disabled.
        var statuses = []
        if (azureDevOps.status !== "disabled") statuses.push(azureDevOps.status)
        if (kubernetes.status  !== "disabled") statuses.push(kubernetes.status)

        if (statuses.length === 0) {
            overallStatus = "unknown"
        } else if (statuses.indexOf("critical") !== -1) {
            overallStatus = "critical"
        } else if (statuses.indexOf("warning") !== -1 || statuses.indexOf("offline") !== -1) {
            overallStatus = "warning"
        } else if (statuses.every(function(s) { return s === "healthy" })) {
            overallStatus = "healthy"
        } else {
            overallStatus = "unknown"
        }

        watchdog.stop()
        lastUpdated = Qt.formatTime(new Date(), "HH:mm")
        refreshing  = false
    }
}
