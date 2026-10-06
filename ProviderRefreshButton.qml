import QtQuick
import qs.Commons

// Per-provider "last updated + refresh icon" control, used in each
// provider's header on the Status tab. Generic: any future provider can
// reuse it by binding its own refreshing / lastUpdated values and handling
// clicked(). While refreshing, the icon spins and clicks are ignored.
Row {
    id: root

    property bool refreshing: false
    property string lastUpdated: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family

    signal clicked()

    spacing: Style.space(6)

    Text {
        textFormat: Text.PlainText
        text: root.lastUpdated
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        opacity: 0.5
        anchors.verticalCenter: parent.verticalCenter
    }

    // Fixed-size hit area so the icon is easy to click and the row does not
    // jiggle while the glyph rotates.
    Item {
        id: iconBox
        width: Style.space(22)
        height: Style.space(22)
        anchors.verticalCenter: parent.verticalCenter

        // Drawn with Canvas (part of plain QtQuick) instead of a font glyph:
        // JetBrains Mono has no circular-arrow character, so a glyph would
        // depend on whichever fallback font the system picks. Rendered at 2x
        // and scaled down by 0.5 to stay crisp.
        Canvas {
            id: icon
            readonly property real logical: Style.space(16)
            width: logical * 2
            height: logical * 2
            scale: 0.5
            anchors.centerIn: parent
            antialiasing: true
            transformOrigin: Item.Center
            property color strokeColor: root.textColor
            opacity: root.refreshing ? 0.4 : (hover.containsMouse ? 1.0 : 0.8)

            onStrokeColorChanged: requestPaint()
            onWidthChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d")
                ctx.reset()
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2, cy = height / 2
                var r = width * 0.30
                var start = -50 * Math.PI / 180
                var end = start + 280 * Math.PI / 180
                ctx.strokeStyle = strokeColor
                ctx.fillStyle = strokeColor
                ctx.lineWidth = Math.max(2, width * 0.095)
                ctx.lineCap = "round"
                ctx.beginPath()
                ctx.arc(cx, cy, r, start, end, false)
                ctx.stroke()
                // Arrow head at the end of the arc, pointing along the motion.
                var ex = cx + r * Math.cos(end), ey = cy + r * Math.sin(end)
                var tx = -Math.sin(end), ty = Math.cos(end)   // tangent (clockwise)
                var nx = Math.cos(end),  ny = Math.sin(end)   // radial
                var len = r * 0.95, half = r * 0.62
                ctx.beginPath()
                ctx.moveTo(ex + tx * len, ey + ty * len)
                ctx.lineTo(ex + nx * half, ey + ny * half)
                ctx.lineTo(ex - nx * half, ey - ny * half)
                ctx.closePath()
                ctx.fill()
            }

            NumberAnimation on rotation {
                id: spin
                from: 0
                to: 360
                duration: 900
                loops: Animation.Infinite
                running: root.refreshing
                onRunningChanged: if (!running) icon.rotation = 0
            }
        }

        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: root.refreshing ? Qt.ArrowCursor : Qt.PointingHandCursor
            onClicked: if (!root.refreshing) root.clicked()
        }
    }
}
