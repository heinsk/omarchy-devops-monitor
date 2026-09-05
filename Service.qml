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

    readonly property string _pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.heinsk.devops-monitor"

    property string _azureOutput: ""
    property string _azureError: ""
    property bool _azureDone: false
    property string _configRaw: ""

    Process {
        id: configReader
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._configRaw = text
        }
        onExited: function() {
            var raw = String(root._configRaw || "").trim()
            if (raw) {
                try {
                    var parsed = JSON.parse(raw)
                    root._config = parsed
                    root._startRefresh(parsed)
                } catch(e) {
                    root._config = {}
                    root._startRefresh({})
                }
            } else {
                root._config = {}
                root._startRefresh({})
            }
        }
    }

    Timer {
        interval: 60000
        repeat: true
        running: true
        triggeredOnStart: false
        onTriggered: root.refresh()
    }

    Component.onCompleted: {
        configReader.command = ["cat", root._pluginDir + "/config.json"]
        configReader.running = true
    }

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
                catch(e) { root.azureDevOps = { status: "offline", error: "Parse error: " + e } }
            } else {
                root.azureDevOps = { status: "offline", error: String(root._azureError || "No output") }
            }
            root._azureDone = true
            root._checkDone()
        }
    }

    function refresh() {
        if (refreshing) return
        _configRaw = ""
        configReader.command = ["cat", root._pluginDir + "/config.json"]
        configReader.running = true
    }

    function _startRefresh(cfg) {
        if (refreshing) return
        refreshing = true
        lastError = ""
        _azureDone = false
        _azureOutput = ""
        _azureError = ""

        var mock = cfg.development && cfg.development.mockData
        var azureEnabled = cfg.providers && cfg.providers.azureDevOps

        if (azureEnabled || mock) {
            var azureArgs = ["python3", root._pluginDir + "/scripts/azure_devops.py"]
            if (mock) {
                azureArgs.push("--mock")
            } else {
                var targets = cfg.azureDevOps && cfg.azureDevOps.targets
                if (targets && targets.length > 0) {
                    for (var i = 0; i < targets.length; i++) {
                        azureArgs.push("--target", targets[i].organization, targets[i].project)
                    }
                }
            }
            azureProcess.command = azureArgs
            azureProcess.running = true
        } else {
            root.azureDevOps = { status: "disabled", pipelines: null, deployments: null, targets: [] }
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
        lastUpdated = Qt.formatTime(new Date(), "HH:mm")
        refreshing = false
    }
}
