import QtQuick
import qs.Commons

// A titled table of runs: Azure DevOps pipelines or releases, or GitHub
// workflows. One RunRow per item; rows that have details can be expanded to
// show their jobs and tasks (and the error messages) under the row.
//
//   kind = "pipeline"  items from scripts/azure_devops.py  pipelineList (runId)
//   kind = "release"   items from scripts/azure_devops.py  releaseList (stages)
//   kind = "workflow"  items from scripts/github_actions.py pipelineList (runId)
//
// Releases bring their stages with the regular refresh. For pipelines and
// workflows the jobs are asked for ONLY when a row is expanded: this table
// emits detailRequested(dataKey, spec, force) and the host (Service.qml)
// answers by filling `details[dataKey] = { state, jobs, error }`.
//
// What is open is kept by the host (`openKeys`), because the lists are
// rebuilt on every refresh. `isTrusted(url)` is the host's link check: the
// Copy icon is only given links that pass it.
Column {
    id: root
    objectName: "runTable"

    property string title: ""
    property string kind: "pipeline"       // pipeline | release | workflow
    property string scope: ""              // unique prefix of this table, e.g. "az|org|project"
    property string org: ""
    property string project: ""
    property string repo: ""
    property var items: []
    property var details: ({})
    property var openKeys: ({})
    property var isTrusted: function(url) { return false }
    property color textColor: "white"
    property var fontFamily: Style.font.family

    signal openUrl(string url)
    signal toggleDetail(string openKey)
    signal detailRequested(string dataKey, var spec, bool force)

    // Lists reached through modelData are not always real JS arrays; they are
    // recognised by their length (see JobDetail.qml).
    function _arr(v) { return (v && typeof v === "object" && typeof v.length === "number") ? v : [] }

    readonly property var _items: _arr(items)

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Text {
        objectName: "tableTitle"
        visible: root._items.length > 0
        text: root.title
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        opacity: 0.4
        leftPadding: Style.space(16)
    }

    RunHeader {
        visible: root._items.length > 0
        width: root.width
        textColor: root.textColor
        fontFamily: root.fontFamily
    }

    Repeater {
        model: root._items
        delegate: Column {
            id: cell
            width: root.width
            spacing: Style.space(4)

            readonly property var it: modelData || ({})
            readonly property bool hasDetail: root.kind === "release"
                ? (root._arr(it.stages).length > 0)
                : (typeof it.runId === "number" && it.runId > 0)
            readonly property string openKey: root.scope + "|" + root.kind + "|" + (it.name || "")
                                              + (root.kind === "release" ? "|" + (it.releaseName || "") : "")
            readonly property string dataKey: root.scope + "|" + (it.runId || 0) + "|" + (it.status || "")
            readonly property bool expanded: hasDetail && root.openKeys[openKey] === true
            readonly property var record: root.details[dataKey]
            property bool _ready: false

            function spec() {
                if (root.kind === "workflow") return { kind: "github", repo: root.repo, id: cell.it.runId }
                return { kind: "azure", org: root.org, project: root.project, id: cell.it.runId }
            }

            Component.onCompleted: {
                _ready = true
                // A refresh rebuilds this row: if it was open and its details are
                // not known yet (new run or new state), ask for them.
                if (expanded && root.kind !== "release" && !record)
                    root.detailRequested(dataKey, spec(), false)
            }
            onExpandedChanged: {
                // Opened by the user: always ask again (a running job moves on).
                if (_ready && expanded && root.kind !== "release")
                    root.detailRequested(dataKey, spec(), true)
            }

            RunRow {
                width: root.width
                name: cell.it.name || ""
                branch: root.kind === "pipeline" ? (cell.it.branch || "") : ""
                subtitle: root.kind === "release" ? (cell.it.releaseName || "")
                        : root.kind === "workflow" ? (cell.it.detail || "") : ""
                subtitleAccent: root.kind === "workflow" && cell.it.status === "running"
                stage: cell.it.currentStage || ""
                status: cell.it.status || ""
                lastStatus: cell.it.lastStatus || ""
                durationMin: typeof cell.it.durationMin === "number" ? cell.it.durationMin : -1
                url: cell.it.url || ""
                copyUrl: (cell.it.url && root.isTrusted(cell.it.url)) ? cell.it.url : ""
                expandable: cell.hasDetail
                expanded: cell.expanded
                textColor: root.textColor
                fontFamily: root.fontFamily
                onOpenRequested: root.openUrl(cell.it.url)
                onToggled: root.toggleDetail(cell.openKey)
            }

            JobDetail {
                visible: cell.expanded
                x: Style.space(16)
                width: root.width - Style.space(16)
                loadState: root.kind === "release" ? "done" : (cell.record ? cell.record.state : "loading")
                groups: root.kind === "release" ? (cell.it.stages || [])
                                                : (cell.record && cell.record.jobs ? cell.record.jobs : [])
                error: cell.record && cell.record.error ? cell.record.error : ""
                textColor: root.textColor
                fontFamily: root.fontFamily
            }
        }
    }
}
