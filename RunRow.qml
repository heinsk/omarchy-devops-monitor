import QtQuick
import qs.Commons

// One row of a run table (a pipeline, a release or a workflow): name with an
// optional branch / sub line, status, previous status, time and the Link
// column, which holds two icons: Copy URL first, then Open link.
//
// This component only draws and reports clicks. The caller decides what is
// allowed: `copyUrl` must already be a validated link (empty = nothing to
// copy) and the open request is checked again by the panel before the
// browser is started.
//
// With `expandable` the name column gets a chevron and clicking the name (or
// the chevron) emits toggled(); the caller shows the detail under the row.
Column {
    id: root
    objectName: "runRow"

    property string name: ""
    property string branch: ""          // shown with the branch icon
    property string subtitle: ""        // plain line under the name
    property bool   subtitleAccent: false
    property string stage: ""           // current stage of a running run (blue)
    property string status: ""
    property string lastStatus: ""
    property int    durationMin: -1
    property string url: ""             // link the Open icon opens (the caller validates it)
    property string copyUrl: ""         // link the Copy icon copies ("" = none)
    property bool   expandable: false
    property bool   expanded: false
    property color  textColor: "white"
    property var    fontFamily: Style.font.family

    signal openRequested()
    signal toggled()

    leftPadding: Style.space(16)
    spacing: 0

    readonly property real _w: width - leftPadding
    readonly property var _states: ["success", "running", "failed", "cancelled", "skipped"]

    function _label(s) {
        if (s === "success")   return "Success"
        if (s === "running")   return "Running"
        if (s === "failed")    return "Failed"
        if (s === "cancelled") return "Cancelled"
        if (s === "skipped")   return "Skipped"
        return "Unknown"
    }

    Row {
        spacing: 0

        // Name (+ chevron)
        Item {
            id: nameCell
            width: root._w * 0.46
            height: nameCol.height

            Canvas {
                id: chevron
                objectName: "chevron"
                visible: root.expandable
                width: Style.space(10) * 2
                height: Style.space(10) * 2
                scale: 0.5
                transformOrigin: Item.TopLeft
                antialiasing: true
                x: 0
                y: Math.ceil(Style.font.body * 1.4) / 2 - Style.space(10) / 2
                property color col: root.textColor
                property bool open: root.expanded
                onColChanged: requestPaint()
                onOpenChanged: requestPaint()
                onWidthChanged: requestPaint()
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.clearRect(0, 0, width, height)
                    var w = width
                    ctx.fillStyle = col
                    ctx.beginPath()
                    if (open) { ctx.moveTo(w * 0.15, w * 0.30); ctx.lineTo(w * 0.85, w * 0.30); ctx.lineTo(w * 0.50, w * 0.78) }
                    else      { ctx.moveTo(w * 0.30, w * 0.15); ctx.lineTo(w * 0.78, w * 0.50); ctx.lineTo(w * 0.30, w * 0.85) }
                    ctx.closePath()
                    ctx.fill()
                }
                opacity: 0.55
            }

            Column {
                id: nameCol
                x: Style.space(14)      // room for the chevron, so rows with and without detail line up
                width: parent.width - x
                spacing: 1
                Text {
                    objectName: "runName"
                    textFormat: Text.PlainText
                    text: root.name
                    width: parent.width
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    opacity: root.status === "failed" ? 1.0 : 0.8
                    elide: Text.ElideRight
                }
                BranchLabel {
                    width: parent.width
                    branch: root.branch
                    textColor: root.textColor
                    fontFamily: root.fontFamily
                }
                Text {
                    objectName: "runSubtitle"
                    textFormat: Text.PlainText
                    visible: root.subtitle !== ""
                    text: root.subtitle
                    width: parent.width
                    color: root.subtitleAccent ? "#89b4fa" : root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    opacity: root.subtitleAccent ? 0.8 : 0.45
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                objectName: "toggleArea"
                anchors.fill: parent
                enabled: root.expandable
                cursorShape: root.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.toggled()
            }
        }

        StatusBadge {
            width: root._w * 0.17
            status: root._states.indexOf(root.status) >= 0 ? root.status : "unknown"
            label: root._label(root.status)
            textColor: root.textColor
            fontFamily: root.fontFamily
        }
        StatusBadge {
            width: root._w * 0.11
            status: root._states.indexOf(root.lastStatus) >= 0 ? root.lastStatus : ""
            textColor: root.textColor
            animate: false
        }
        Text {
            textFormat: Text.PlainText
            width: root._w * 0.11
            text: root.durationMin >= 0 ? root.durationMin + "m" : "—"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            opacity: 0.7
        }

        // Link column: Copy URL, then Open link
        Item {
            width: root._w * 0.15
            height: Math.max(copyIcon.height, linkIcon.height)
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(3)
                CopyIcon {
                    id: copyIcon
                    objectName: "copyUrl"
                    text: root.copyUrl
                    mutedColor: root.textColor
                    fontFamily: root.fontFamily
                    tip: "Copy URL"
                }
                LinkIcon {
                    id: linkIcon
                    objectName: "openLink"
                    width: Style.space(16) + Style.space(8)
                    active: !!root.url
                    mutedColor: root.textColor
                    onClicked: root.openRequested()
                }
            }
        }
    }

    // Current stage of a running pipeline
    Text {
        objectName: "runStage"
        textFormat: Text.PlainText
        visible: root.status === "running" && root.stage !== ""
        text: "   " + root.stage
        color: "#89b4fa"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.8
        width: root._w
        elide: Text.ElideRight
    }
}
