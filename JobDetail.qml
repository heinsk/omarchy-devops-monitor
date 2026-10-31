import QtQuick
import qs.Commons

// Jobs (or release stages) of one run with their tasks, shown under an
// expanded row. The failing task is highlighted and its error message is
// shown under it, with a Copy icon.
//
//   groups = [ { name, stage?, status, durationSec?, messages: [str],
//                tasks: [ { name, status, durationSec?, messages: [str] } ] } ]
//
// Data comes from scripts/job_detail.py (Azure DevOps builds, GitHub runs)
// or from the release that the Azure DevOps refresh already read (stages).
// Everything is displayed as plain text.
Rectangle {
    id: root
    objectName: "jobDetail"

    property string loadState: "done"     // loading | done | error
    property var groups: []
    property string error: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family

    // Objects reached through a Repeater's modelData are not always real JS
    // arrays (Array.isArray() is false for them), so lists are recognised by
    // their length instead.
    function _arr(v) { return (v && typeof v === "object" && typeof v.length === "number") ? v : [] }

    readonly property var _groups: _arr(groups)

    function _clip(s, n) {
        return String(s === undefined || s === null ? "" : s)
            .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁤⁦-⁯﻿]/g, "")
            .substring(0, n)
    }

    function duration(sec) {
        if (typeof sec !== "number" || !isFinite(sec) || sec < 0) return ""
        var s = Math.floor(sec)
        if (s < 60) return s + "s"
        var m = Math.floor(s / 60)
        if (m >= 10 || s % 60 === 0) return m + "m"
        return m + "m " + (s % 60) + "s"
    }

    function _status(s) {
        return ["success", "failed", "running", "cancelled", "skipped"].indexOf(s) >= 0 ? s : "unknown"
    }

    width: parent ? parent.width : 0
    implicitHeight: col.implicitHeight + Style.space(10)
    height: implicitHeight
    radius: Style.space(5)
    color: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.04)
    border.width: 1
    border.color: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.14)

    Column {
        id: col
        x: Style.space(8)
        y: Style.space(5)
        width: root.width - Style.space(16)
        spacing: Style.space(2)

        Text {
            objectName: "detailLoading"
            visible: root.loadState === "loading"
            textFormat: Text.PlainText
            text: "Loading details…"
            color: root.textColor; opacity: 0.6
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
            objectName: "detailError"
            visible: root.loadState === "error"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: "Could not load the details" + (root.error !== "" ? ": " + root._clip(root.error, 200) : "")
            color: "#e05050"
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
            objectName: "detailEmpty"
            visible: root.loadState === "done" && root._groups.length === 0
            textFormat: Text.PlainText
            text: "No job details for this run"
            color: root.textColor; opacity: 0.5
            font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }

        Repeater {
            model: root.loadState === "done" ? root._groups : []
            delegate: Column {
                id: grp
                width: col.width
                spacing: Style.space(1)
                readonly property var g: modelData || ({})

                Row {
                    width: parent.width
                    spacing: Style.space(6)
                    StatusIcon {
                        status: root._status(grp.g.status)
                        size: Style.space(13)
                        mutedColor: root.textColor
                        animate: false
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        objectName: "groupName"
                        textFormat: Text.PlainText
                        text: root._clip((grp.g.stage ? grp.g.stage + " · " : "") + (grp.g.name || ""), 120)
                        width: parent.width - Style.space(13) - Style.space(6) - durText.width - Style.space(6)
                        elide: Text.ElideRight
                        color: root.textColor
                        opacity: grp.g.status === "failed" ? 1.0 : 0.85
                        font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        id: durText
                        textFormat: Text.PlainText
                        text: root.duration(grp.g.durationSec)
                        color: root.textColor; opacity: 0.55
                        font.family: root.fontFamily; font.pixelSize: Style.font.caption
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Repeater {
                    model: root._arr(grp.g.messages)
                    delegate: ErrorMessage {
                        x: Style.space(19)
                        width: grp.width - Style.space(19)
                        message: String(modelData)
                        textColor: root.textColor
                        fontFamily: root.fontFamily
                    }
                }

                Repeater {
                    model: root._arr(grp.g.tasks)
                    delegate: Column {
                        id: tk
                        x: Style.space(19)
                        width: grp.width - Style.space(19)
                        spacing: Style.space(1)
                        readonly property var t: modelData || ({})
                        Rectangle {
                            width: parent.width
                            height: taskRow.height + Style.space(2)
                            radius: Style.space(3)
                            color: tk.t.status === "failed" ? Qt.rgba(0.88, 0.31, 0.31, 0.08) : "transparent"
                            Row {
                                id: taskRow
                                x: Style.space(4)
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - Style.space(8)
                                spacing: Style.space(6)
                                StatusIcon {
                                    status: root._status(tk.t.status)
                                    size: Style.space(11)
                                    mutedColor: root.textColor
                                    animate: false
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    objectName: "taskName"
                                    textFormat: Text.PlainText
                                    text: root._clip(tk.t.name, 100)
                                    width: parent.width - Style.space(11) - Style.space(6) - taskDur.width - Style.space(6)
                                    elide: Text.ElideRight
                                    color: tk.t.status === "failed" ? "#e05050" : root.textColor
                                    opacity: tk.t.status === "failed" ? 1.0 : 0.7
                                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    id: taskDur
                                    textFormat: Text.PlainText
                                    text: root.duration(tk.t.durationSec)
                                    color: root.textColor; opacity: 0.45
                                    font.family: root.fontFamily; font.pixelSize: Style.font.caption
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                        Repeater {
                            model: root._arr(tk.t.messages)
                            delegate: ErrorMessage {
                                x: Style.space(14)
                                width: tk.width - Style.space(14)
                                message: String(modelData)
                                textColor: root.textColor
                                fontFamily: root.fontFamily
                            }
                        }
                    }
                }
            }
        }
    }
}
