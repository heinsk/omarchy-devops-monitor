import QtQuick
import Quickshell

// Desktop notifications for the DevOps Monitor (v0.3.6).
//
// Service.qml hands every successful provider reading to evaluate(). This
// component keeps the last set of "alerts" (failed pipelines / workflows /
// releases, failed Kubernetes items, unreachable clusters) per provider and
// only notifies on TRANSITIONS:
//   - the first reading of a provider after the shell starts (or after the
//     provider was off) only sets the starting point: it never notifies;
//   - an alert that is still there on the next reading does not notify again;
//   - a reading that failed (offline) is ignored: the previous set is kept, so
//     a provider coming back does not look like a wave of new failures;
//   - at most `maxPerHour` notifications per provider and hour; beyond that,
//     one summary per hour;
//   - alerts that appear while the provider is silenced (or notifications are
//     off) are consumed silently: unmuting never replays them.
//
// Security: notifications go out through notify-send, started with an
// argument array (no shell), absolute path, and "--" before the text so that
// nothing in a title or body can be read as an option. The text comes from the
// providers' data, so it is cleaned again here (control characters removed,
// bounded) and escaped for notification servers that render markup.
QtObject {
    id: root

    // Normalized by Service.qml: { enabled, providers[], onRecovery, branches[], maxPerHour }
    property var config: ({ enabled: false, providers: [], onRecovery: false, branches: [], maxPerHour: 5 })
    // Executable that shows a notification (overridable for tests only through this property).
    property string notifySend: "/usr/bin/notify-send"
    // False when notify-send is missing: nothing can be shown, so nothing is sent.
    property bool deliveryReady: true
    // Moves the clock forward (milliseconds); only tests set this.
    property real clockShiftMs: 0
    function nowMs() { return Date.now() + clockShiftMs }

    readonly property int maxTitle: 100
    readonly property int maxBody: 200
    readonly property int maxAlertsPerReading: 500

    property var _previous: ({})   // provider -> { key: alert } (null = no starting point yet)
    property var _sent: ({})       // provider -> [timestamps of notifications in the last hour]
    property var _summaryAt: ({})  // provider -> timestamp of the last summary

    readonly property var providerNames: ({ azureDevOps: "Azure DevOps", kubernetes: "Kubernetes", github: "GitHub" })

    // ── Text helpers ──────────────────────────────────────────────────────────
    function clean(value, limit) {
        if (typeof value !== "string") return ""
        // C0/C1 controls, zero-width marks and bidirectional overrides/isolates (a name with U+202E
        // could otherwise reorder what the notification shows).
        return value.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]/g, " ")
                    .replace(/\s+/g, " ").trim().substring(0, limit)
    }
    // Servers that render markup would otherwise read "<b>" in a pod name as markup.
    function escapeMarkup(text) {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    // ── Branch filter ─────────────────────────────────────────────────────────
    // Patterns: an exact name, or a prefix ending in "*" ("release/*"). An
    // empty list means every branch. Items without a branch are never filtered.
    function branchAllowed(branch) {
        var list = config.branches || []
        if (list.length === 0 || !branch) return true
        for (var i = 0; i < list.length; i++) {
            var p = list[i]
            if (typeof p !== "string" || p === "") continue
            if (p === "*" || p === branch) return true
            if (p.charAt(p.length - 1) === "*" && branch.indexOf(p.substring(0, p.length - 1)) === 0) return true
        }
        return false
    }

    // ── Alert extraction (one function per provider data shape) ───────────────
    function _arr(v) { return (v && typeof v.length === "number") ? v : [] }

    function _alertsAzure(data) {
        var out = {}, n = 0
        var targets = _arr(data.targets)
        for (var t = 0; t < targets.length && n < maxAlertsPerReading; t++) {
            var target = targets[t] || {}
            var project = clean(target.project, 80)
            var lists = [["pipeline", _arr(target.pipelineList)], ["release", _arr(target.releaseList)]]
            for (var l = 0; l < lists.length; l++) {
                var items = lists[l][1]
                for (var i = 0; i < items.length && n < maxAlertsPerReading; i++) {
                    var it = items[i] || {}
                    if (it.status !== "failed") continue
                    var branch = clean(it.branch, 80)
                    if (lists[l][0] === "pipeline" && !branchAllowed(branch)) continue
                    var name = clean(it.name, 80) || lists[l][0]
                    var where = (branch ? " on " + branch : "") + (project ? " (" + project + ")" : "")
                    out["az|" + clean(target.organization, 120) + "|" + project + "|" + lists[l][0] + "|" + name] = {
                        title: "Azure DevOps · " + name,
                        body: (lists[l][0] === "pipeline" ? "Pipeline failed" : "Release failed") + where
                    }
                    n++
                }
            }
        }
        return out
    }

    function _alertsKubernetes(data) {
        var out = {}, n = 0
        var clusters = _arr(data.clusters)
        for (var c = 0; c < clusters.length && n < maxAlertsPerReading; c++) {
            var cl = clusters[c] || {}
            var cname = clean(cl.name, 100)
            if (cl.status === "offline") {
                out["k8s|" + cname + "|offline"] = { title: "Kubernetes · " + cname, body: "Cluster is not reachable" }
                n++
                continue
            }
            var issues = _arr(cl.issues)
            for (var i = 0; i < issues.length && n < maxAlertsPerReading; i++) {
                var is = issues[i] || {}
                if (is.severity !== "failed") continue
                var name = clean(is.name, 100), ns = clean(is.namespace, 63), reason = clean(is.reason, 70)
                var kind = clean(is.kind, 20)
                out["k8s|" + cname + "|" + kind + "|" + ns + "|" + name] = {
                    title: "Kubernetes · " + name,
                    body: (reason || "Failed") + (ns ? " in " + ns : "") + " (cluster " + cname + ")"
                }
                n++
            }
        }
        return out
    }

    function _alertsGithub(data) {
        var out = {}, n = 0
        var repos = _arr(data.repos)
        for (var r = 0; r < repos.length && n < maxAlertsPerReading; r++) {
            var repo = repos[r] || {}
            var rname = clean(repo.repo, 140)
            var items = _arr(repo.pipelineList)
            for (var i = 0; i < items.length && n < maxAlertsPerReading; i++) {
                var it = items[i] || {}
                if (it.status !== "failed") continue
                var detail = clean(it.detail, 120)
                var branch = clean(it.branch, 80) || detail.split(" · ")[0]
                if (!branchAllowed(branch)) continue
                var name = clean(it.name, 80) || "workflow"
                out["gh|" + rname + "|" + name] = {
                    title: "GitHub · " + rname + " · " + name,
                    body: "Run failed" + (detail ? " on " + detail : "")
                }
                n++
            }
        }
        return out
    }

    function alertsOf(provider, data) {
        if (!data || typeof data !== "object") return {}
        if (provider === "azureDevOps") return _alertsAzure(data)
        if (provider === "kubernetes") return _alertsKubernetes(data)
        if (provider === "github") return _alertsGithub(data)
        return {}
    }

    // ── Main entry point ──────────────────────────────────────────────────────
    // muted: true when this provider is silenced right now.
    // Returns how many notifications were sent (for tests and the tooltip).
    function evaluate(provider, data, muted) {
        if (!providerNames[provider] || !data) return 0
        var status = data.status
        if (status === "disabled" || status === "unknown" || status === undefined) {
            _previous[provider] = null          // off or unknown: next reading is a new starting point
            return 0
        }
        if (status === "offline") return 0      // could not read: keep the previous set

        var current = alertsOf(provider, data)
        var before = _previous[provider]
        _previous[provider] = current
        if (before === null || before === undefined) return 0   // starting point: never notifies

        var added = [], recovered = [], k
        for (k in current) if (!(k in before)) added.push(current[k])
        for (k in before) if (!(k in current)) recovered.push(before[k])

        if (!config.enabled || !deliveryReady || muted || (config.providers || []).indexOf(provider) < 0) return 0
        return _send(provider, added, recovered)
    }

    function _send(provider, added, recovered) {
        var now = nowMs()
        var sent = (_sent[provider] || []).filter(function(t) { return now - t < 3600000 })
        var limit = Math.max(1, Math.min(30, config.maxPerHour || 5))
        var allowance = limit - sent.length
        var count = 0

        if (added.length > 0) {
            if (added.length <= allowance) {
                for (var i = 0; i < added.length; i++) { _notify(added[i].title, added[i].body, "normal"); sent.push(now); count++ }
                allowance -= added.length
            } else {
                var last = _summaryAt[provider]
                if (last === undefined || now - last >= 3600000) {
                    var total = added.length >= maxAlertsPerReading ? maxAlertsPerReading + "+" : String(added.length)
                    _notify(providerNames[provider] + " · " + total + " new problems",
                            "Too many alerts in the last hour — showing a summary. Open the panel for details.", "normal")
                    _summaryAt[provider] = now
                    sent.push(now); count++
                    allowance -= 1
                }
            }
        }
        if (config.onRecovery) {
            for (var j = 0; j < recovered.length && allowance > 0; j++) {
                _notify("Recovered · " + recovered[j].title, "Back to normal", "low")
                sent.push(now); count++; allowance--
            }
        }
        _sent[provider] = sent
        return count
    }

    function _notify(title, body, urgency) {
        var t = escapeMarkup(clean(title, maxTitle))
        var b = escapeMarkup(clean(body, maxBody))
        if (t === "") return
        Quickshell.execDetached([notifySend, "--app-name=DevOps Monitor", "--urgency=" + urgency, "--", t, b])
    }
}
