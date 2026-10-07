import QtQuick
import qs.Commons

// Small "git branch" icon followed by a branch name, shown under a
// pipeline's name. Hidden when there is no branch. Drawn with Canvas, so it
// needs no icon font. The name is plain text and is elided to fit.
Item {
    id: root

    property string branch: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family
    property real fontSize: Style.font.caption

    visible: branch !== ""
    height: visible ? Math.ceil(fontSize * 1.4) : 0
    implicitHeight: height

    readonly property real iconSize: Math.ceil(fontSize * 1.1)

    Canvas {
        id: cv
        width: root.iconSize * 2
        height: root.iconSize * 2
        scale: 0.5
        transformOrigin: Item.TopLeft
        x: 0
        y: (root.height - root.iconSize) / 2
        antialiasing: true
        property color col: root.textColor
        onColChanged: requestPaint()
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            var w = width, r = w * 0.12
            ctx.strokeStyle = col
            ctx.fillStyle = col
            ctx.lineWidth = Math.max(2, w * 0.09)
            ctx.lineCap = "round"
            // main line between the two left nodes
            ctx.beginPath(); ctx.moveTo(w * 0.28, w * 0.28); ctx.lineTo(w * 0.28, w * 0.72); ctx.stroke()
            // branch curving from the left line up to the right node
            ctx.beginPath()
            ctx.moveTo(w * 0.72, w * 0.28)
            ctx.quadraticCurveTo(w * 0.72, w * 0.50, w * 0.28, w * 0.58)
            ctx.stroke()
            var nodes = [[0.28, 0.24], [0.28, 0.76], [0.72, 0.24]]
            for (var i = 0; i < nodes.length; i++) {
                ctx.beginPath(); ctx.arc(w * nodes[i][0], w * nodes[i][1], r * 1.5, 0, 2 * Math.PI)
                ctx.fillStyle = "black"; ctx.globalCompositeOperation = "destination-out"; ctx.fill()
                ctx.globalCompositeOperation = "source-over"
                ctx.beginPath(); ctx.arc(w * nodes[i][0], w * nodes[i][1], r * 1.25, 0, 2 * Math.PI)
                ctx.strokeStyle = col; ctx.stroke()
            }
        }
    }

    Text {
        textFormat: Text.PlainText
        text: root.branch
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        anchors.left: parent.left
        anchors.leftMargin: root.iconSize + Style.space(5)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        opacity: 0.6
    }
}
