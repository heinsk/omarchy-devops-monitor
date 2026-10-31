import QtQuick
import Quickshell.Io
import qs.Commons

// "Copy" icon for the Link column (and for error messages): copies `text` to
// the Wayland clipboard with wl-copy, started with an argument array (no
// shell) and "--" so a text that starts with "-" is never read as an option.
//
// The caller decides WHAT may be copied: bind `text` to a value that already
// passed the same checks as the open-link button (for a link) or to a message
// that was cleaned (for an error). With an empty `text` the icon is a faint
// dash and does nothing.
//
// Feedback: the icon turns into a green check and a small "Copied" label
// appears for about two seconds; if wl-copy is missing or fails, the icon is
// amber and the label says "No wl-copy".
Item {
    id: root

    property string text: ""
    property color accent: "#89b4fa"
    property color mutedColor: "white"
    property real iconSize: Style.space(16)
    property var fontFamily: Style.font.family
    property string tip: "Copy"          // label shown while hovering (when idle)

    readonly property bool active: text !== ""
    // idle | copied | failed
    property string copyState: "idle"

    signal copied()

    height: Math.max(Math.ceil(Style.font.body * 1.4), iconSize + Style.space(4))
    implicitHeight: height
    width: iconSize + Style.space(8)

    readonly property color _color: copyState === "copied" ? "#a6e3a1"
                                  : copyState === "failed" ? "#f9e2af" : accent

    function copy() {
        if (!active || copier.running) return
        copier.command = ["/usr/bin/wl-copy", "--", root.text]
        copier.running = true
    }

    Rectangle {
        id: pill
        width: root.iconSize + Style.space(8)
        height: root.iconSize + Style.space(4)
        radius: Style.space(5)
        anchors.verticalCenter: parent.verticalCenter
        color: root._color
        opacity: root.active ? (hover.containsMouse || root.copyState !== "idle" ? 0.28 : 0.12) : 0.0
    }

    Canvas {
        id: cv
        objectName: "copyCanvas"
        width: root.iconSize * 2
        height: root.iconSize * 2
        scale: 0.5
        transformOrigin: Item.Center
        antialiasing: true
        x: pill.x + (pill.width - root.iconSize) / 2 - root.iconSize / 2
        y: pill.y + (pill.height - root.iconSize) / 2 - root.iconSize / 2
        opacity: root.active ? (hover.containsMouse ? 1.0 : 0.9) : 0.3
        property color col: root.active ? root._color : root.mutedColor
        property bool on: root.active
        property string mode: root.copyState
        onColChanged: requestPaint()
        onOnChanged: requestPaint()
        onModeChanged: requestPaint()
        onWidthChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            var w = width
            ctx.strokeStyle = col
            ctx.fillStyle = col
            ctx.lineWidth = Math.max(2, w * 0.10)
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            if (!on) {
                ctx.beginPath(); ctx.moveTo(w * 0.34, w * 0.5); ctx.lineTo(w * 0.66, w * 0.5); ctx.stroke()
                return
            }
            if (mode === "copied") {
                ctx.beginPath()
                ctx.moveTo(w * 0.20, w * 0.52); ctx.lineTo(w * 0.42, w * 0.74); ctx.lineTo(w * 0.80, w * 0.26)
                ctx.stroke()
                return
            }
            if (mode === "failed") {
                ctx.beginPath(); ctx.moveTo(w * 0.5, w * 0.18); ctx.lineTo(w * 0.5, w * 0.58); ctx.stroke()
                ctx.beginPath(); ctx.arc(w * 0.5, w * 0.78, w * 0.045, 0, Math.PI * 2); ctx.fill()
                return
            }
            // Two overlapping sheets: the one behind is open at its bottom-right corner.
            var r = w * 0.08
            ctx.beginPath()                                   // sheet in front
            ctx.moveTo(w * 0.40 + r, w * 0.38); ctx.lineTo(w * 0.80 - r, w * 0.38)
            ctx.quadraticCurveTo(w * 0.80, w * 0.38, w * 0.80, w * 0.38 + r)
            ctx.lineTo(w * 0.80, w * 0.80 - r)
            ctx.quadraticCurveTo(w * 0.80, w * 0.80, w * 0.80 - r, w * 0.80)
            ctx.lineTo(w * 0.40 + r, w * 0.80)
            ctx.quadraticCurveTo(w * 0.40, w * 0.80, w * 0.40, w * 0.80 - r)
            ctx.lineTo(w * 0.40, w * 0.38 + r)
            ctx.quadraticCurveTo(w * 0.40, w * 0.38, w * 0.40 + r, w * 0.38)
            ctx.stroke()
            ctx.beginPath()                                   // sheet behind (its corner hides under the front one)
            ctx.moveTo(w * 0.40, w * 0.62)
            ctx.lineTo(w * 0.18 + r, w * 0.62)
            ctx.quadraticCurveTo(w * 0.18, w * 0.62, w * 0.18, w * 0.62 - r)
            ctx.lineTo(w * 0.18, w * 0.18 + r)
            ctx.quadraticCurveTo(w * 0.18, w * 0.18, w * 0.18 + r, w * 0.18)
            ctx.lineTo(w * 0.60 - r, w * 0.18)
            ctx.quadraticCurveTo(w * 0.60, w * 0.18, w * 0.60, w * 0.18 + r)
            ctx.lineTo(w * 0.60, w * 0.38)
            ctx.stroke()
        }
    }

    // Small floating label: feedback after a click, or the hint while hovering.
    Rectangle {
        id: bubble
        objectName: "copyBubble"
        readonly property string label: root.copyState === "copied" ? "Copied"
                                     : root.copyState === "failed" ? "No wl-copy"
                                     : (hover.containsMouse && root.active ? root.tip : "")
        visible: label !== ""
        z: 10
        anchors.right: pill.left
        anchors.rightMargin: Style.space(4)
        anchors.verticalCenter: pill.verticalCenter
        width: bubbleText.implicitWidth + Style.space(12)
        height: bubbleText.implicitHeight + Style.space(4)
        radius: Style.space(4)
        color: Qt.rgba(0.11, 0.14, 0.25, 0.96)
        border.width: 1
        border.color: Qt.rgba(root._color.r, root._color.g, root._color.b, 0.55)
        Text {
            id: bubbleText
            objectName: "copyBubbleText"
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: bubble.label
            color: root.copyState === "idle" ? "#e8dcc0" : root._color
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
    }

    MouseArea {
        id: hover
        objectName: "copyArea"
        anchors.fill: parent
        hoverEnabled: root.active
        cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: root.copy()
    }

    Process {
        id: copier
        running: false
        onExited: function(exitCode, exitStatus) {
            root.copyState = exitCode === 0 ? "copied" : "failed"
            if (exitCode === 0) root.copied()
            reset.restart()
        }
    }

    Timer {
        id: reset
        interval: 1800
        onTriggered: root.copyState = "idle"
    }
}
