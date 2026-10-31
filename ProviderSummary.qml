import QtQuick
import qs.Commons

// One-line summary of a provider, shown in its header while the card is
// collapsed:  ● Warning  2 repos  ◔ 1 running  ✖ 1 failed
//
// It reads the data the provider script already produced (nothing new is
// fetched) and never changes it. Every number is coerced to a bounded integer
// and every string is cleaned again here, so odd data cannot break the layout.
//
//   kind "azure"       providerData = service.azureDevOps
//   kind "kubernetes"  providerData = service.kubernetes
//   kind "github"      providerData = service.github
Item {
    id: root
    objectName: "providerSummary"

    property string kind: ""
    property var providerData: null
    property color textColor: "white"
    property var fontFamily: Style.font.family

    // Same palette as StatusIcon.qml
    readonly property color _green: "#4ec94e"
    readonly property color _red:   "#e05050"
    readonly property color _blue:  "#89b4fa"
    readonly property color _amber: "#f0c040"

    function _int(v) {
        var n = Number(v)
        return (isFinite(n) && n > 0) ? Math.min(Math.floor(n), 99999) : 0
    }
    function _text(v, limit) {
        if (typeof v !== "string") return ""
        return v.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁤⁦-⁯﻿]/g, " ")
                .replace(/\s+/g, " ").trim().substring(0, limit)
    }
    function _arr(v) { return (v && typeof v.length === "number") ? v : [] }
    function _plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

    // Counts {running, success, failed} of a provider's "pipelines"/"deployments" block.
    function _runs(block) {
        return block ? { running: _int(block.running), success: _int(block.success), failed: _int(block.failed) }
                     : { running: 0, success: 0, failed: 0 }
    }

    // { label, color, chips: [{ text, color }] } for the current data.
    readonly property var summary: {
        var d = providerData
        var st = d ? String(d.status || "unknown") : "unknown"
        var label = "Unknown", color = root.textColor
        if (st === "healthy")       { label = "Healthy";  color = root._green }
        else if (st === "warning")  { label = "Warning";  color = root._amber }
        else if (st === "critical") { label = "Critical"; color = root._red }
        else if (st === "offline") {
            // The provider could not read anything: say why, in a few words.
            var n = d && d.notice && typeof d.notice === "object" ? root._text(d.notice.title, 60) : ""
            label = n || root._text(d ? d.error : "", 60) || "Unavailable"
            color = root._red
        }
        var chips = []
        if (st !== "offline" && d) {
            if (kind === "azure") {
                var targets = root._arr(d.targets).length
                if (targets > 0) chips.push({ text: root._plural(targets, "project", "projects"), color: root.textColor })
                var p = root._runs(d.pipelines), r = root._runs(d.deployments)
                var failed = p.failed + r.failed, running = p.running + r.running, ok = p.success + r.success
                if (failed > 0)  chips.push({ text: "✖ " + failed + " failed",   color: root._red })
                if (running > 0) chips.push({ text: "◔ " + running + " running", color: root._blue })
                if (ok > 0)      chips.push({ text: "✔ " + ok,                    color: root._green })
            } else if (kind === "github") {
                var repos = root._arr(d.repos).length
                if (repos > 0) chips.push({ text: root._plural(repos, "repo", "repos"), color: root.textColor })
                var g = root._runs(d.pipelines)
                if (g.failed > 0)  chips.push({ text: "✖ " + g.failed + " failed",   color: root._red })
                if (g.running > 0) chips.push({ text: "◔ " + g.running + " running", color: root._blue })
                if (g.success > 0) chips.push({ text: "✔ " + g.success,              color: root._green })
            } else if (kind === "kubernetes") {
                var clusters = root._arr(d.clusters)
                if (clusters.length > 0) chips.push({ text: root._plural(clusters.length, "cluster", "clusters"), color: root.textColor })
                var bad = 0, warn = 0
                for (var i = 0; i < clusters.length; i++) {
                    var issues = root._arr(clusters[i] ? clusters[i].issues : null)
                    for (var j = 0; j < issues.length; j++) {
                        var sev = issues[j] ? issues[j].severity : ""
                        if (sev === "failed") bad++
                        else if (sev === "warning") warn++
                    }
                }
                if (bad > 0)  chips.push({ text: "✖ " + bad,  color: root._red })
                if (warn > 0) chips.push({ text: "⚠ " + warn, color: root._amber })
            }
        }
        return { label: label, color: color, chips: chips }
    }

    // Clipped to the room the header leaves (the Silence control can widen).
    clip: true
    implicitHeight: row.implicitHeight
    height: implicitHeight

    Row {
        id: row
        spacing: Style.space(10)

        Row {
            spacing: Style.space(5)
            anchors.verticalCenter: parent.verticalCenter
            Rectangle {
                width: Style.space(8); height: Style.space(8); radius: width / 2
                color: root.summary.color
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                objectName: "summaryLabel"
                textFormat: Text.PlainText
                text: root.summary.label
                color: root.summary.color
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Repeater {
            model: root.summary.chips
            delegate: Text {
                objectName: "summaryChip"
                textFormat: Text.PlainText
                text: modelData.text
                color: modelData.color
                opacity: modelData.color === root.textColor ? 0.7 : 1.0
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
