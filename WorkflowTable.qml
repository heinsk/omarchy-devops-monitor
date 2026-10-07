import QtQuick
import qs.Commons

// One repository's workflows (latest run of each), styled like the Azure
// DevOps pipelines table. Data comes from scripts/github_actions.py:
//   repoData = { repo, status, error?, pipelineList: [
//       { name, status, lastStatus, durationMin, url, detail } ] }
// Opening a link is delegated to the caller through openUrl(url), which is
// where the host allow-list lives.
Column {
    id: root

    property var repoData: null
    property color textColor: "white"
    property var fontFamily: Style.font.family

    signal openUrl(string url)

    readonly property var _items: (repoData && repoData.pipelineList) || []
    readonly property bool _hasError: !!repoData && repoData.status === "offline"
        && (repoData.error || "") !== ""

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    function _statusLabel(s) {
        if (s === "success")   return "Success"
        if (s === "running")   return "Running"
        if (s === "failed")    return "Failed"
        if (s === "cancelled") return "Cancelled"
        if (s === "skipped")   return "Skipped"
        return "Unknown"
    }

    // Repository name
    Text {
        textFormat: Text.PlainText
        text: root.repoData ? (root.repoData.repo || "") : ""
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        opacity: 0.8
        leftPadding: Style.space(8)
        width: parent.width
        elide: Text.ElideRight
    }

    // Repository-level problem (not found, no access, timeout...)
    Text {
        textFormat: Text.PlainText
        visible: root._hasError
        text: root._hasError ? ("\u26A0 " + root.repoData.error) : ""
        color: "#e05050"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        leftPadding: Style.space(16)
        width: parent.width
        wrapMode: Text.WordWrap
    }

    Text {
        visible: root._items.length > 0
        text: "WORKFLOWS"
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        opacity: 0.4
        leftPadding: Style.space(16)
    }

    Text {
        textFormat: Text.PlainText
        visible: !root._hasError && root._items.length === 0
        text: "No workflow runs yet"
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.5
        leftPadding: Style.space(16)
    }

    Row {
        visible: root._items.length > 0
        leftPadding: Style.space(16)
        width: parent.width - Style.space(16)
        spacing: 0
        Text { text: "Name";   width: parent.width * 0.50; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
        Text { text: "Status"; width: parent.width * 0.18; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
        Text { text: "Last";   width: parent.width * 0.12; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
        Text { text: "Time";   width: parent.width * 0.12; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
        Text { text: "View";   width: parent.width * 0.08; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
    }

    Repeater {
        model: root._items
        delegate: Column {
            width: root.width - Style.space(16)
            x: Style.space(16)
            spacing: 0

            Row {
                width: parent.width
                spacing: 0

                Text {
                    textFormat: Text.PlainText
                    text: modelData.name || ""
                    width: parent.width * 0.50
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    opacity: modelData.status === "failed" ? 1.0 : 0.8
                    elide: Text.ElideRight
                }
                StatusBadge {
                    width: parent.width * 0.18
                    status: modelData.status || "unknown"
                    label: root._statusLabel(modelData.status)
                    textColor: root.textColor
                    fontFamily: root.fontFamily
                }
                StatusBadge {
                    width: parent.width * 0.12
                    status: modelData.lastStatus || ""
                    textColor: root.textColor
                    animate: false
                }
                Text {
                    textFormat: Text.PlainText
                    width: parent.width * 0.12
                    text: modelData.durationMin >= 0 ? modelData.durationMin + "m" : "\u2014"
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    opacity: 0.7
                }
                LinkIcon {
                    width: parent.width * 0.08
                    active: !!modelData.url
                    mutedColor: root.textColor
                    onClicked: root.openUrl(modelData.url)
                }
            }

            // Branch · event of the latest run
            Text {
                textFormat: Text.PlainText
                visible: (modelData.detail || "") !== ""
                text: "   " + (modelData.detail || "")
                color: modelData.status === "running" ? "#89b4fa" : root.textColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                opacity: modelData.status === "running" ? 0.8 : 0.45
                width: parent.width
                elide: Text.ElideRight
            }
        }
    }
}
