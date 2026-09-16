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

    // Resolve plugin dir from QML file location — immune to HOME env manipulation
    readonly property string _pluginDir: Qt.resolvedUrl(".").toString()
        .replace(/^file:\/\//, "").replace(/\/$/, "")

    property string _azureOutput: ""
    property string _azureError:  ""
    property bool   _azureDone:   false
    property string _configRaw:   ""
    property bool   _configDone:  false  // guard against double-start

    // ── Config reader ──────────────────────────────────────────────────────────

    Process {
        id: configReader
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            maxLength: 65536       // 64 KB cap — config files are small
            onStreamFinished: root._configRaw = text
        }
        onExited: function() {
            if (root._configDone) return  // prevent double-start
            root._configDone = true
            var raw = String(root._configRaw || "").trim()
            var cfg = {}
            if (raw) {
                try { cfg = JSON.parse(raw) } catch(e) {}
            }
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
            maxLength: 524288      // 512 KB cap
            onStreamFinished: root._azureOutput = text
        }
        stderr: StdioCollector {
            waitForEnd: true
            maxLength: 16384       // 16 KB cap
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

    // ── Public API ─────────────────────────────────────────────────────────────

    function refresh() {
        if (refreshing) return
        refreshing = true
        _configDone = false
        _configRaw  = ""
        watchdog.restart()
        // Use absolute path for cat — no PATH dependency
        configReader.command = ["/bin/cat", root._pluginDir + "/config.json"]
        configReader.running = true
    }

    function _startRefresh(cfg) {
        _azureDone    = false
        _azureOutput  = ""
        _azureError   = ""
        lastError     = ""

        var mock         = cfg.development && cfg.development.mockData
        var azureEnabled = cfg.providers   && cfg.providers.azureDevOps

        if (azureEnabled || mock) {
            // Absolute path for python3 — no PATH dependency
            var azureArgs = ["/usr/bin/python3",
                             root._pluginDir + "/scripts/azure_devops.py"]
            if (mock) {
                azureArgs.push("--mock")
            } else {
                var targets = cfg.azureDevOps && cfg.azureDevOps.targets
                if (targets && targets.length > 0) {
                    for (var i = 0; i < targets.length; i++) {
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
    }

    function _checkDone() {
        if (!_azureDone) return
        var s = azureDevOps.status
        if      (s === "critical") overallStatus = "critical"
        else if (s === "warning")  overallStatus = "warning"
        else if (s === "offline")  overallStatus = "warning"
        else if (s === "healthy")  overallStatus = "healthy"
        else                       overallStatus = "unknown"
        watchdog.stop()
        lastUpdated = Qt.formatTime(new Date(), "HH:mm")
        refreshing  = false
    }
}
