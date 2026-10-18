import QtQuick
import qs.Commons

// Detail shown under a cluster's counters row:
//   NEEDS ATTENTION    nodes / pods / deployments that are not healthy
//   PODS BY NAMESPACE  collapsible; open = the namespaces with problems (worst
//                      first, at most 8) plus a "Show all" list of fixed height
//                      with its own scroll, so a cluster with dozens of
//                      namespaces never makes the card grow.
// The open / show-all state lives in the parent (it survives the model being
// rebuilt on every refresh); this item only reports what the person clicked.
Column {
    id: root

    property var cluster: ({})
    property color textColor: "white"
    property var fontFamily: Style.font.family
    property bool expanded: false
    property bool showAll: false

    signal expandedToggled(bool open)
    signal showAllToggled(bool all)
    signal openConfigRequested()

    readonly property int maxProblemRows: 8
    readonly property int listRows: 10
    // The cluster object arrives through a ListView/Repeater model, where nested
    // arrays are not plain JS arrays (Array.isArray() is false), so copy them.
    function toArray(v) {
        var out = []
        if (v && typeof v.length === "number")
            for (var i = 0; i < v.length; i++) out.push(v[i])
        return out
    }
    readonly property var issues: toArray(cluster.issues)
    readonly property var namespaces: toArray(cluster.namespaces)
    // A cluster whose API server did not answer carries a notice (next steps)
    // that replaces its plain warning line.
    readonly property bool hasNotice: !!cluster.notice && typeof cluster.notice === "object"
    readonly property var warnings: hasNotice ? [] : toArray(cluster.warnings)
    readonly property int issuesHidden: Math.max(0, (cluster.issuesTotal || 0) - issues.length)
    readonly property int namespacesTotal: Math.max(namespaces.length, cluster.namespacesTotal || 0)
    readonly property var problems: namespaces.filter(function(n) { return n.severity !== "healthy" })
    readonly property int problemCount: problems.length
    readonly property int healthyCount: Math.max(0, namespacesTotal - problemCount)
    // "Show all" only makes sense when it reveals something the summary does not:
    // healthy namespaces, problem namespaces beyond the summary rows, or cut-off ones.
    readonly property bool canShowAll: !listAllInSummary && (healthyCount > 0
        || problemCount > maxProblemRows
        || namespacesTotal > namespaces.length)
    // Nothing is wrong and there are only a few namespaces: list them right away
    // instead of a bare "N healthy namespaces" line behind a button.
    readonly property bool listAllInSummary: problemCount === 0
        && namespaces.length > 0
        && namespaces.length <= maxProblemRows
        && namespacesTotal <= namespaces.length
    // Namespaces are already sorted worst-first by the script.
    readonly property real maxPods: {
        var mx = 1
        for (var i = 0; i < namespaces.length; i++)
            mx = Math.max(mx, (namespaces[i].pods && namespaces[i].pods.total) || 0)
        return mx
    }
    readonly property real rowHeight: Math.ceil(Style.font.body * 1.8)

    width: parent ? parent.width : 0
    spacing: Style.space(1)
    visible: hasNotice || issues.length > 0 || namespaces.length > 0 || warnings.length > 0

    ProviderNotice {
        visible: root.hasNotice
        width: root.width
        providerData: root.cluster
        textColor: root.textColor
        fontFamily: root.fontFamily
        onOpenConfigRequested: root.openConfigRequested()
    }

    // ── Queries that failed (too large, no permission, timeout) ───────────────
    // Never shown as an empty, healthy list: say what went wrong.
    Repeater {
        model: root.warnings
        delegate: Row {
            width: root.width
            spacing: Style.space(6)
            leftPadding: Style.space(2)
            topPadding: Style.space(2)
            StatusIcon {
                status: "warning"
                size: Style.space(13)
                anchors.top: parent.top
                anchors.topMargin: Style.space(3)
            }
            Text {
                textFormat: Text.PlainText
                text: modelData
                width: parent.width - Style.space(27)
                wrapMode: Text.WordWrap
                color: "#f9e2af"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }

    // ── Needs attention ───────────────────────────────────────────────────────
    Text {
        visible: root.issues.length > 0
        text: "NEEDS ATTENTION"
        leftPadding: Style.space(2)
        topPadding: Style.space(4)
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        opacity: 0.4
    }
    Repeater {
        model: root.issues
        delegate: K8sIssueRow {
            width: root.width
            issue: modelData
            textColor: root.textColor
            fontFamily: root.fontFamily
        }
    }
    Text {
        visible: root.issuesHidden > 0
        textFormat: Text.PlainText
        text: "+ " + root.issuesHidden + " more not shown"
        leftPadding: Style.space(2)
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.45
    }

    // ── Pods by namespace ─────────────────────────────────────────────────────
    Item {
        id: header
        visible: root.namespaces.length > 0
        width: root.width
        height: visible ? Math.ceil(Style.font.body * 1.9) : 0

        Rectangle {
            anchors.fill: parent
            radius: Style.space(5)
            color: root.textColor
            opacity: headerMouse.containsMouse ? 0.08 : 0.0
        }
        Canvas {
            id: chevron
            width: Style.space(10)
            height: Style.space(10)
            x: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            rotation: root.expanded ? 90 : 0
            antialiasing: true
            property color col: root.textColor
            onColChanged: requestPaint()
            Behavior on rotation { NumberAnimation { duration: 120 } }
            onPaint: {
                var c = getContext("2d")
                c.reset()
                c.strokeStyle = col
                c.lineWidth = 2
                c.lineCap = "round"
                c.lineJoin = "round"
                c.beginPath()
                c.moveTo(width * 0.30, height * 0.12)
                c.lineTo(width * 0.72, height * 0.5)
                c.lineTo(width * 0.30, height * 0.88)
                c.stroke()
            }
        }
        Text {
            id: headerTitle
            x: Style.space(24)
            text: "PODS BY NAMESPACE"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            opacity: 0.55
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            x: headerTitle.x + headerTitle.width + Style.space(10)
            textFormat: Text.PlainText
            text: root.namespacesTotal + (root.namespacesTotal === 1 ? " namespace" : " namespaces")
            color: root.textColor
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
        Row {
            visible: root.problemCount > 0
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(5)
            StatusIcon {
                status: "warning"
                size: Style.space(13)
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                textFormat: Text.PlainText
                text: root.problemCount + " with issues"
                color: "#f9e2af"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: headerMouse
            objectName: "namespacesHeader"
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.expandedToggled(!root.expanded)
        }
    }

    // Open, summary view: only the namespaces that have problems.
    Repeater {
        model: (root.expanded && !root.showAll)
               ? (root.listAllInSummary ? root.namespaces : root.problems.slice(0, root.maxProblemRows))
               : []
        delegate: NamespaceRow {
            width: root.width
            ns: modelData
            maxPods: root.maxPods
            textColor: root.textColor
            fontFamily: root.fontFamily
        }
    }

    // Open: summary line + "Show all" / "Hide list" button.
    Item {
        visible: root.expanded && root.namespaces.length > 0 && (root.showAll || root.canShowAll)
        width: root.width
        height: visible ? Math.ceil(Style.font.body * 1.9) : 0

        Row {
            visible: !root.showAll && root.healthyCount > 0
            x: Style.space(2)
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            StatusBadge {
                status: "success"
                label: ""
                textColor: root.textColor
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                textFormat: Text.PlainText
                text: root.healthyCount + (root.healthyCount === 1 ? " healthy namespace" : " healthy namespaces")
                color: root.textColor
                opacity: 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        Text {
            visible: root.showAll
            x: Style.space(2)
            textFormat: Text.PlainText
            text: root.namespacesTotal > root.namespaces.length
                  ? "Worst " + root.namespaces.length + " of " + root.namespacesTotal + " namespaces"
                  : "All " + root.namespaces.length + " namespaces, issues first"
            color: root.textColor
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
        Rectangle {
            id: toggleButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: toggleText.implicitWidth + Style.space(16)
            height: Style.space(20)
            radius: Style.space(5)
            color: "#89b4fa"
            opacity: toggleMouse.containsMouse ? 0.28 : 0.14
        }
        Text {
            id: toggleText
            anchors.centerIn: toggleButton
            text: root.showAll ? "Hide list ▴" : "Show all ▾"
            color: "#89b4fa"
            font.bold: true
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
        MouseArea {
            id: toggleMouse
            objectName: "namespacesShowAll"
            anchors.fill: toggleButton
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.showAllToggled(!root.showAll)
        }
    }

    // Show all: fixed height (listRows rows), scrolls inside.
    Flickable {
        id: allList
        objectName: "namespacesList"
        visible: root.expanded && root.showAll
        width: root.width
        height: visible ? Math.min(root.rowHeight * root.listRows, allColumn.height) : 0
        contentWidth: width
        contentHeight: allColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: allColumn
            width: allList.width - Style.space(10)
            Repeater {
                model: (root.expanded && root.showAll) ? root.namespaces : []
                delegate: NamespaceRow {
                    width: allColumn.width
                    ns: modelData
                    maxPods: root.maxPods
                    textColor: root.textColor
                    fontFamily: root.fontFamily
                }
            }
        }
        // Thin scroll indicator.
        Rectangle {
            visible: allList.contentHeight > allList.height
            x: allList.width - Style.space(4)
            width: Style.space(3)
            radius: width / 2
            color: root.textColor
            opacity: 0.35
            y: allList.contentY / allList.contentHeight * allList.height
            height: allList.height * allList.height / allList.contentHeight
        }
    }
}
