import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property string overallStatus: "unknown"
    property string lastUpdated: ""
    // Derived: non-empty while a provider's last refresh timed out.
    readonly property string lastError: _azureTimeout || _kubernetesTimeout || _githubTimeout
    // Derived: true while any provider is refreshing.
    readonly property bool refreshing: azureRefreshing || kubernetesRefreshing || githubRefreshing

    // Per-provider refresh state (drives the per-provider refresh buttons).
    property bool   azureRefreshing: false
    property bool   kubernetesRefreshing: false
    property bool   githubRefreshing: false
    property string azureLastUpdated: ""
    property string kubernetesLastUpdated: ""
    property string githubLastUpdated: ""

    property var azureDevOps: ({ status: "unknown", pipelines: null, deployments: null, targets: [] })
    property var kubernetes:  ({ status: "unknown", clusters: [] })
    property var github:      ({ status: "unknown", repos: [] })
    property var _config: ({})
    property string configError: ""  // non-empty when config.json was rejected or invalid
    property string toggleError: ""  // non-empty when writing a provider toggle failed
    property bool   toggling: false  // true while write_config.py is running

    // Resolve plugin dir from QML file location — immune to HOME env manipulation
    readonly property string _pluginDir: Qt.resolvedUrl(".").toString()
        .replace(/^file:\/\//, "").replace(/\/$/, "")

    property string _azureOutput: ""
    property string _azureError:  ""
    property string _azureTimeout: ""
    property string _kubernetesOutput: ""
    property string _kubernetesError:  ""
    property string _kubernetesTimeout: ""
    property string _githubOutput: ""
    property string _githubError:  ""
    property string _githubTimeout: ""
    property string _configRaw:   ""
    property string _configErr:   ""
    property bool   _configDone:  false  // guard against double-start
    property string _toggleErr:   ""

    // Providers waiting for the config read currently in flight, and those
    // that asked while it was already running (they need a fresh read, since
    // config.json may have changed in between, e.g. a just-written toggle).
    property var _waiters: []
    property var _lateWaiters: []

    // Refresh interval limits (seconds) for refresh.<provider> in config.json.
    readonly property int _minIntervalSec: 30
    readonly property int _maxIntervalSec: 3600
    readonly property int _defaultIntervalSec: 60

    // ── Config reader ──────────────────────────────────────────────────────────
    // Runs scripts/read_config.py, which enforces a byte cap and rejects
    // config.json if it's not a regular file. On any rejection or parse
    // failure we fall back to cfg = {} and surface a short reason via
    // configError so the panel can show the person why their settings
    // aren't being read. Every provider refresh goes through here so that
    // edits to config.json (and toggles) are picked up on the next refresh.

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
            if (cfg === null || typeof cfg !== "object" || Array.isArray(cfg)) {
                cfg = {}
                err = "config.json root must be an object — using defaults"
            }
            root.configError = err
            root._config = cfg
            root._applyIntervals(cfg)

            var waiting = root._waiters
            root._waiters = []
            for (var i = 0; i < waiting.length; i++) root._startProvider(waiting[i], cfg)

            // Anyone who asked while this read was running gets a fresh read.
            if (root._lateWaiters.length > 0) {
                root._waiters = root._lateWaiters
                root._lateWaiters = []
                root._runConfigReader()
            }
        }
    }

    // ── Provider toggle writer ─────────────────────────────────────────────────
    // Runs scripts/write_config.py <provider> <true|false>. Whatever the
    // outcome, we re-read config.json afterwards so the UI always reflects
    // what is really on disk.

    Process {
        id: toggleWriter
        running: false
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._toggleErr = text
        }
        onExited: function() {
            var reason = String(root._toggleErr || "").trim()
                .replace(/[^\x20-\x7E]/g, "")
                .substring(0, 200)
            root.toggleError = reason
            root.toggling = false
            root.refreshProvider(root._toggledProvider)
        }
    }
    property string _toggledProvider: ""

    // ── Per-provider timers ────────────────────────────────────────────────────
    // Intervals come from refresh.azureDevOps / .kubernetes / .github in
    // config.json (seconds, clamped to 30..3600) and are applied each time
    // the config is read. They start after the first config read.

    Timer {
        id: azureTimer
        interval: root._defaultIntervalSec * 1000
        repeat: true
        running: false
        onTriggered: root.refreshProvider("azureDevOps")
    }

    Timer {
        id: kubernetesTimer
        interval: root._defaultIntervalSec * 1000
        repeat: true
        running: false
        onTriggered: root.refreshProvider("kubernetes")
    }

    Timer {
        id: githubTimer
        interval: root._defaultIntervalSec * 1000
        repeat: true
        running: false
        onTriggered: root.refreshProvider("github")
    }

    // ── Watchdogs — force-reset a provider if its refresh hangs beyond 120 s ──

    Timer {
        id: azureWatchdog
        interval: 120000
        repeat: false
        running: false
        onTriggered: {
            if (root.azureRefreshing) {
                if (azureProcess.running) azureProcess.terminate()
                root.azureRefreshing = false
                root._azureTimeout = "Azure DevOps refresh timed out"
                root.azureLastUpdated = Qt.formatTime(new Date(), "HH:mm")
                root.lastUpdated = root.azureLastUpdated
            }
        }
    }

    Timer {
        id: kubernetesWatchdog
        interval: 120000
        repeat: false
        running: false
        onTriggered: {
            if (root.kubernetesRefreshing) {
                if (kubernetesProcess.running) kubernetesProcess.terminate()
                root.kubernetesRefreshing = false
                root._kubernetesTimeout = "Kubernetes refresh timed out"
                root.kubernetesLastUpdated = Qt.formatTime(new Date(), "HH:mm")
                root.lastUpdated = root.kubernetesLastUpdated
            }
        }
    }

    Timer {
        id: githubWatchdog
        interval: 120000
        repeat: false
        running: false
        onTriggered: {
            if (root.githubRefreshing) {
                if (githubProcess.running) githubProcess.terminate()
                root.githubRefreshing = false
                root._githubTimeout = "GitHub refresh timed out"
                root.githubLastUpdated = Qt.formatTime(new Date(), "HH:mm")
                root.lastUpdated = root.githubLastUpdated
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
            root._finishProvider("azureDevOps")
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
            root._finishProvider("kubernetes")
        }
    }

    // ── GitHub Actions process ─────────────────────────────────────────────────

    Process {
        id: githubProcess
        running: false
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._githubOutput = text
        }
        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: root._githubError = text
        }
        onExited: function() {
            var out = String(root._githubOutput || "").trim()
            if (out) {
                try { root.github = JSON.parse(out) }
                catch(e) { root.github = { status: "offline", error: "Parse error", repos: [] } }
            } else {
                // Sanitize stderr: printable ASCII only, max 200 chars
                var errMsg = String(root._githubError || "No output from script")
                    .replace(/[^\x20-\x7E]/g, "")
                    .substring(0, 200)
                root.github = { status: "offline", error: errMsg, repos: [] }
            }
            root._finishProvider("github")
        }
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    // Refresh every provider (bar click, header "Refresh" button).
    function refresh() {
        refreshProvider("azureDevOps")
        refreshProvider("kubernetes")
        refreshProvider("github")
    }

    // Refresh a single provider ("azureDevOps" | "kubernetes" | "github").
    function refreshProvider(name) {
        if (name === "azureDevOps") {
            if (azureRefreshing) return
            azureRefreshing = true
            _azureTimeout = ""
            azureWatchdog.restart()
        } else if (name === "kubernetes") {
            if (kubernetesRefreshing) return
            kubernetesRefreshing = true
            _kubernetesTimeout = ""
            kubernetesWatchdog.restart()
        } else if (name === "github") {
            if (githubRefreshing) return
            githubRefreshing = true
            _githubTimeout = ""
            githubWatchdog.restart()
        } else {
            return
        }
        _requestConfig(name)
    }

    // Persist providers.<name> = enabled in config.json (via the hardened
    // scripts/write_config.py) and refresh that provider afterwards.
    function setProviderEnabled(name, enabled) {
        if (toggling) return
        if (name !== "azureDevOps" && name !== "kubernetes" && name !== "github") return
        toggling = true
        toggleError = ""
        _toggleErr = ""
        _toggledProvider = name
        toggleWriter.command = ["/usr/bin/python3",
                                root._pluginDir + "/scripts/write_config.py",
                                name, enabled ? "true" : "false"]
        toggleWriter.running = true
    }

    // ── Internals ──────────────────────────────────────────────────────────────

    function _runConfigReader() {
        _configDone = false
        _configRaw  = ""
        _configErr  = ""
        // Read via a small, hardened Python helper instead of /bin/cat:
        // it enforces a byte cap and refuses to follow config.json through
        // to a special file (FIFO/device). Absolute path — no PATH dependency.
        configReader.command = ["/usr/bin/python3", root._pluginDir + "/scripts/read_config.py"]
        configReader.running = true
    }

    function _requestConfig(name) {
        if (configReader.running) {
            if (_lateWaiters.indexOf(name) === -1) _lateWaiters = _lateWaiters.concat([name])
            return
        }
        if (_waiters.indexOf(name) === -1) _waiters = _waiters.concat([name])
        _runConfigReader()
    }

    function _intervalMs(cfg, name) {
        var sec = cfg && cfg.refresh ? cfg.refresh[name] : undefined
        if (typeof sec !== "number" || !isFinite(sec)) sec = _defaultIntervalSec
        sec = Math.round(sec)
        if (sec < _minIntervalSec) sec = _minIntervalSec
        if (sec > _maxIntervalSec) sec = _maxIntervalSec
        return sec * 1000
    }

    function _applyIntervals(cfg) {
        var a = _intervalMs(cfg, "azureDevOps")
        if (azureTimer.interval !== a) azureTimer.interval = a
        if (!azureTimer.running) azureTimer.start()
        var k = _intervalMs(cfg, "kubernetes")
        if (kubernetesTimer.interval !== k) kubernetesTimer.interval = k
        if (!kubernetesTimer.running) kubernetesTimer.start()
        var g = _intervalMs(cfg, "github")
        if (githubTimer.interval !== g) githubTimer.interval = g
        if (!githubTimer.running) githubTimer.start()
    }

    function _startProvider(name, cfg) {
        var mock = cfg.development && cfg.development.mockData

        if (name === "azureDevOps") {
            _azureOutput = ""
            _azureError  = ""
            var azureEnabled = cfg.providers && cfg.providers.azureDevOps
            if (azureEnabled || mock) {
                // Absolute path for python3 — no PATH dependency
                var azureArgs = ["/usr/bin/python3",
                                 root._pluginDir + "/scripts/azure_devops.py"]
                if (mock) {
                    azureArgs.push("--mock")
                    // Dev aid: force a synthetic error from azure_devops.py to
                    // test the panel's error UI (e.g. the missing-dependency
                    // banner) without touching the real az CLI. Only the two
                    // values the script's --mock-error accepts are forwarded.
                    var azureMockError = cfg.development && cfg.development.mockError
                        && cfg.development.mockError.azureDevOps
                    if (azureMockError === "missing-dependency" || azureMockError === "generic") {
                        azureArgs.push("--mock-error", azureMockError)
                    }
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
                _finishProvider("azureDevOps")
            }
        } else if (name === "kubernetes") {
            _kubernetesOutput = ""
            _kubernetesError  = ""
            var k8sEnabled = cfg.providers && cfg.providers.kubernetes
            if (k8sEnabled || mock) {
                // Absolute path for python3 — no PATH dependency
                var k8sArgs = ["/usr/bin/python3",
                               root._pluginDir + "/scripts/kubernetes.py"]
                if (mock) {
                    k8sArgs.push("--mock")
                    // Same dev aid as azure_devops.py above, forwarded only
                    // to kubernetes.py's --mock-error.
                    var k8sMockError = cfg.development && cfg.development.mockError
                        && cfg.development.mockError.kubernetes
                    if (k8sMockError === "missing-dependency" || k8sMockError === "generic") {
                        k8sArgs.push("--mock-error", k8sMockError)
                    }
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
                _finishProvider("kubernetes")
            }
        } else if (name === "github") {
            _githubOutput = ""
            _githubError  = ""
            var ghEnabled = cfg.providers && cfg.providers.github
            if (ghEnabled || mock) {
                // Absolute path for python3 — no PATH dependency
                var ghArgs = ["/usr/bin/python3",
                              root._pluginDir + "/scripts/github_actions.py"]
                if (mock) {
                    ghArgs.push("--mock")
                    // Same dev aid as the other providers, forwarded only
                    // to github_actions.py's --mock-error.
                    var ghMockError = cfg.development && cfg.development.mockError
                        && cfg.development.mockError.github
                    if (ghMockError === "missing-dependency" || ghMockError === "generic") {
                        ghArgs.push("--mock-error", ghMockError)
                    }
                } else {
                    var repos = (cfg.github && cfg.github.repos) || []
                    var MAX_REPOS = 20  // matches github_actions.py MAX_REPOS
                    var ghCount = Math.min(repos.length, MAX_REPOS)
                    // Optional absolute path to gh (e.g. installed with mise). Passed as
                    // ONE "--gh-path=value" argument; the script validates it again.
                    var ghPath = cfg.github && cfg.github.ghPath
                    if (typeof ghPath === "string" && ghPath.length > 0 && ghPath.length <= 300)
                        ghArgs.push("--gh-path=" + ghPath)
                    for (var r = 0; r < ghCount; r++) {
                        // "--repo=value" as ONE argument: a value starting with
                        // "-" can never be mistaken for an option. The script
                        // validates every repo name strictly.
                        if (typeof repos[r] === "string")
                            ghArgs.push("--repo=" + repos[r])
                    }
                }
                githubProcess.command = ghArgs
                githubProcess.running = true
            } else {
                root.github = { status: "disabled", repos: [] }
                _finishProvider("github")
            }
        }
    }

    // Called when a provider's process has exited (or it was found disabled).
    function _finishProvider(name) {
        var now = Qt.formatTime(new Date(), "HH:mm")
        if (name === "azureDevOps") {
            // A watchdog reset may already have closed this refresh.
            if (!azureRefreshing) return
            azureWatchdog.stop()
            azureLastUpdated = now
            azureRefreshing = false
        } else if (name === "kubernetes") {
            if (!kubernetesRefreshing) return
            kubernetesWatchdog.stop()
            kubernetesLastUpdated = now
            kubernetesRefreshing = false
        } else if (name === "github") {
            if (!githubRefreshing) return
            githubWatchdog.stop()
            githubLastUpdated = now
            githubRefreshing = false
        } else {
            return
        }
        lastUpdated = now
        _updateOverall()
    }

    function _updateOverall() {
        // Combine the providers' statuses, ignoring whichever are disabled.
        var statuses = []
        if (azureDevOps.status !== "disabled") statuses.push(azureDevOps.status)
        if (kubernetes.status  !== "disabled") statuses.push(kubernetes.status)
        if (github.status      !== "disabled") statuses.push(github.status)

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
    }
}
