import QtQuick
import qs.Commons

// Small filled triangle in front of a provider's name: pointing right when the
// card is collapsed, down when it is open. Drawn with Canvas (plain QtQuick)
// so it does not depend on any font glyph. Purely presentational.
Canvas {
    id: root
    objectName: "collapseChevron"

    property bool open: true
    property color tint: "white"

    width: Style.space(10)
    height: Style.space(10)
    antialiasing: true
    opacity: 0.6

    onOpenChanged: requestPaint()
    onTintChanged: requestPaint()
    onWidthChanged: requestPaint()

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        var w = width
        ctx.fillStyle = tint
        ctx.beginPath()
        if (open) { ctx.moveTo(w * 0.10, w * 0.28); ctx.lineTo(w * 0.90, w * 0.28); ctx.lineTo(w * 0.50, w * 0.80) }
        else      { ctx.moveTo(w * 0.28, w * 0.10); ctx.lineTo(w * 0.80, w * 0.50); ctx.lineTo(w * 0.28, w * 0.90) }
        ctx.closePath()
        ctx.fill()
    }
}
