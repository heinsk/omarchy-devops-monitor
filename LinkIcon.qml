import QtQuick
import qs.Commons

// "Open in browser" icon for the View column: a drawn square with an arrow
// leaving its corner (the usual external-link symbol), no icon font needed.
// With no link (active == false) it shows a faint dash instead. Hovering
// highlights it with a soft pill; clicking emits clicked().
Item {
    id: root

    property bool active: true
    property color accent: "#89b4fa"
    property color mutedColor: "white"
    property real iconSize: Style.space(16)

    signal clicked()

    height: Math.max(Math.ceil(Style.font.body * 1.4), iconSize + Style.space(4))
    implicitHeight: height

    Rectangle {
        id: pill
        width: root.iconSize + Style.space(8)
        height: root.iconSize + Style.space(4)
        radius: Style.space(5)
        anchors.verticalCenter: parent.verticalCenter
        color: root.accent
        opacity: root.active ? (hover.containsMouse ? 0.28 : 0.12) : 0.0
    }

    Canvas {
        id: cv
        width: root.iconSize * 2
        height: root.iconSize * 2
        scale: 0.5
        transformOrigin: Item.Center
        antialiasing: true
        x: pill.x + (pill.width - root.iconSize) / 2 - root.iconSize / 2
        y: pill.y + (pill.height - root.iconSize) / 2 - root.iconSize / 2
        opacity: root.active ? (hover.containsMouse ? 1.0 : 0.9) : 0.3
        property color col: root.active ? root.accent : root.mutedColor
        property bool on: root.active
        onColChanged: requestPaint()
        onOnChanged: requestPaint()
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
            // Box with an opening at the top-right corner.
            var a = w * 0.18, b = w * 0.82, r = w * 0.10
            ctx.beginPath()
            ctx.moveTo(w * 0.44, a)
            ctx.lineTo(a + r, a); ctx.quadraticCurveTo(a, a, a, a + r)
            ctx.lineTo(a, b - r); ctx.quadraticCurveTo(a, b, a + r, b)
            ctx.lineTo(b - r, b); ctx.quadraticCurveTo(b, b, b, b - r)
            ctx.lineTo(b, w * 0.56)
            ctx.stroke()
            // Arrow towards the top-right corner.
            ctx.beginPath()
            ctx.moveTo(w * 0.46, w * 0.54); ctx.lineTo(w * 0.86, w * 0.14)
            ctx.stroke()
            ctx.beginPath()
            ctx.moveTo(w * 0.60, w * 0.14); ctx.lineTo(w * 0.86, w * 0.14); ctx.lineTo(w * 0.86, w * 0.40)
            ctx.stroke()
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: root.active
        cursorShape: root.active ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.active) root.clicked()
    }
}
