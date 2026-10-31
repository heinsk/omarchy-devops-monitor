import QtQuick
import qs.Commons

// One repository's workflows (latest run of each), styled like the Azure
// DevOps pipelines table. Data comes from scripts/github_actions.py:
//   repoData = { repo, status, error?, pipelineList: [
//       { name, status, lastStatus, durationMin, url, detail, runId } ] }
// Opening a link is delegated to the caller through openUrl(url), which is
// where the host allow-list lives.
Column {
    id: root

    property var repoData: null
    property color textColor: "white"
    property var fontFamily: Style.font.family

    // Jobs of each run (answered by the host) and which rows are open
    property var details: ({})
    property var openKeys: ({})
    property var isTrusted: function(url) { return false }

    signal openUrl(string url)
    signal toggleDetail(string openKey)
    signal detailRequested(string dataKey, var spec, bool force)

    readonly property var _items: (repoData && repoData.pipelineList) || []
    readonly property bool _hasError: !!repoData && repoData.status === "offline"
        && (repoData.error || "") !== ""

    width: parent ? parent.width : 0
    spacing: Style.space(4)

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
        textFormat: Text.PlainText
        visible: !root._hasError && root._items.length === 0
        text: "No workflow runs yet"
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.5
        leftPadding: Style.space(16)
    }

    RunTable {
        visible: root._items.length > 0
        width: root.width
        title: "WORKFLOWS"
        kind: "workflow"
        scope: "gh|" + (root.repoData ? (root.repoData.repo || "") : "")
        repo: root.repoData ? (root.repoData.repo || "") : ""
        items: root._items
        details: root.details
        openKeys: root.openKeys
        isTrusted: root.isTrusted
        textColor: root.textColor
        fontFamily: root.fontFamily
        onOpenUrl: function(url) { root.openUrl(url) }
        onToggleDetail: function(key) { root.toggleDetail(key) }
        onDetailRequested: function(key, spec, force) { root.detailRequested(key, spec, force) }
    }
}
