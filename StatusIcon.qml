import QtQuick
import qs.Commons

// Drawn status icon (no icon font needed). Each state has its own SHAPE and
// colour, so states stay distinguishable without relying on colour alone:
//   success  filled disc + check        failed   filled disc + cross
//   running  open ring + spinning arc   warning  filled triangle + "!"
//   cancelled ring + slash              skipped  ring + chevron
//   unknown  ring + dot                 none     short dash
// Accepts pipeline states (success/failed/running/cancelled/skipped) and
// cluster states (healthy/warning/offline/critical) so every provider can
// reuse it. Rendered at 2x and scaled by 0.5 to stay crisp.
Item {
    id: root

    property string status: ""
    property real size: Style.space(14)
    property color mutedColor: "white"       // used for neutral states
    property bool animate: true              // spin the running ring while visible

    readonly property string kind: {
        var s = status
        if (s === "success" || s === "healthy") return "success"
        if (s === "failed" || s === "offline" || s === "critical") return "failed"
        if (s === "running") return "running"
        if (s === "warning") return "warning"
        if (s === "cancelled") return "cancelled"
        if (s === "skipped") return "skipped"
        if (s === "") return "none"
        return "unknown"
    }
    readonly property color iconColor: {
        if (kind === "success") return "#4ec94e"
        if (kind === "failed") return "#e05050"
        if (kind === "running") return "#89b4fa"
        if (kind === "warning") return "#f0c040"
        return mutedColor
    }

    width: size
    height: size
    implicitWidth: size
    implicitHeight: size

    Canvas {
        id: cv
        width: root.size * 2
        height: root.size * 2
        scale: 0.5
        anchors.centerIn: parent
        antialiasing: true
        transformOrigin: Item.Center
        opacity: (root.kind === "cancelled" || root.kind === "skipped" || root.kind === "unknown" || root.kind === "none") ? 0.6 : 1.0

        property string kind: root.kind
        property color col: root.iconColor
        onKindChanged: requestPaint()
        onColChanged: requestPaint()
        onWidthChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            ctx.clearRect(0, 0, width, height)
            var w = width, cx = w / 2, cy = w / 2, r = w * 0.45
            var lw = Math.max(2, w * 0.11)
            ctx.strokeStyle = col
            ctx.fillStyle = col
            ctx.lineWidth = lw
            ctx.lineCap = "round"
            ctx.lineJoin = "round"

            function disc() { ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.fill() }
            function ring() { ctx.beginPath(); ctx.arc(cx, cy, r - lw / 2, 0, 2 * Math.PI); ctx.stroke() }
            // Cut a glyph out of the filled shape (works on any background).
            function cut() { ctx.globalCompositeOperation = "destination-out"; ctx.strokeStyle = "black"; ctx.lineWidth = lw * 1.1 }

            if (kind === "success") {
                disc(); cut()
                ctx.beginPath()
                ctx.moveTo(cx - r * 0.42, cy + r * 0.02)
                ctx.lineTo(cx - r * 0.08, cy + r * 0.36)
                ctx.lineTo(cx + r * 0.45, cy - r * 0.30)
                ctx.stroke()
            } else if (kind === "failed") {
                disc(); cut()
                var d = r * 0.34
                ctx.beginPath()
                ctx.moveTo(cx - d, cy - d); ctx.lineTo(cx + d, cy + d)
                ctx.moveTo(cx + d, cy - d); ctx.lineTo(cx - d, cy + d)
                ctx.stroke()
            } else if (kind === "running") {
                ctx.globalAlpha = 0.28; ring(); ctx.globalAlpha = 1.0
                ctx.beginPath()
                ctx.arc(cx, cy, r - lw / 2, -Math.PI / 2, Math.PI * 0.35, false)
                ctx.stroke()
            } else if (kind === "warning") {
                var top = cy - r * 0.92, bot = cy + r * 0.78, half = r * 0.98
                ctx.beginPath()
                ctx.moveTo(cx, top); ctx.lineTo(cx + half, bot); ctx.lineTo(cx - half, bot); ctx.closePath()
                ctx.fill(); ctx.stroke()
                cut()
                ctx.beginPath(); ctx.moveTo(cx, cy - r * 0.28); ctx.lineTo(cx, cy + r * 0.18); ctx.stroke()
                ctx.beginPath(); ctx.arc(cx, cy + r * 0.50, lw * 0.35, 0, 2 * Math.PI); ctx.fill()
            } else if (kind === "cancelled") {
                ring()
                var k = r * 0.52
                ctx.beginPath(); ctx.moveTo(cx - k, cy + k); ctx.lineTo(cx + k, cy - k); ctx.stroke()
            } else if (kind === "skipped") {
                ring()
                ctx.beginPath()
                ctx.moveTo(cx - r * 0.16, cy - r * 0.40)
                ctx.lineTo(cx + r * 0.24, cy)
                ctx.lineTo(cx - r * 0.16, cy + r * 0.40)
                ctx.stroke()
            } else if (kind === "unknown") {
                ring()
                ctx.beginPath(); ctx.arc(cx, cy, lw * 0.55, 0, 2 * Math.PI); ctx.fill()
            } else {
                ctx.beginPath(); ctx.moveTo(cx - r * 0.45, cy); ctx.lineTo(cx + r * 0.45, cy); ctx.stroke()
            }
        }

        // Spin only the running ring, only while on screen.
        NumberAnimation on rotation {
            from: 0; to: 360; duration: 1000
            loops: Animation.Infinite
            running: root.animate && root.kind === "running" && root.visible
            onRunningChanged: if (!running) cv.rotation = 0
        }
    }
}
