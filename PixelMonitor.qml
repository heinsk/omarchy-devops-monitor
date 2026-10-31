import QtQuick
import qs.Commons

// Small pixel-art animation of a delivery process being watched: a crate
// travels through commit -> build -> test -> deploy. The first run succeeds
// (a burst of pixels at deploy); the second one fails its tests (red "!",
// the crate bounces back and the deploy is skipped). 18 seconds, in a loop.
//
// It is a demo drawing, not live data. It costs nothing while it is not
// shown: the timer only runs while `running` is true AND the item is visible,
// and a stopped monitor draws one still frame.
//
// Drawn on a 144 x 40 grid at a whole-number scale, so every pixel stays sharp.
Canvas {
    id: root
    objectName: "pixelMonitor"

    property bool running: false
    property real availableWidth: 576          // the widest the drawing may be
    readonly property int gridW: 144
    readonly property int gridH: 40
    readonly property int pixelScale: Math.max(2, Math.floor(availableWidth / gridW))
    property real t: 7.4                       // seconds into the loop (still frame: "deployed")
    property string caption: ""
    readonly property real _loop: 18

    property real _start: Date.now()

    width: gridW * pixelScale
    height: gridH * pixelScale
    antialiasing: false
    onPixelScaleChanged: requestPaint()

    onRunningChanged: {
        if (running) { _start = Date.now() - t * 1000 }
        requestPaint()
    }

    Timer {
        interval: 100
        repeat: true
        running: root.running && root.visible
        onTriggered: {
            root.t = ((Date.now() - root._start) / 1000) % root._loop
            root.requestPaint()
        }
    }

    // Colours
    readonly property var tones: ({
        bg: "#070d1c", line: "#1d2a4a", dim: "#3a4a7a",
        ok: "#3ecf5a", okd: "#1f7a33", bad: "#ff5b5b", badd: "#8a2a2a",
        blue: "#4c8dff", blued: "#24478a", amb: "#f0b35a"
    })
    readonly property var icons: ({
        commit: ["..aaaa..", ".a....a.", "a..bb..a", "aabbbbaa", "a..bb..a", ".a....a.", "..aaaa..", "........"],
        build:  ["...aa...", "..aaaa..", "aaa..aaa", "a.b..b.a", "a.b..b.a", "aaa..aaa", "..aaaa..", "...aa..."],
        test:   ["aaaaaaaa", "a......a", "a.....ba", "a....bb.", "ab..bb.a", "abbbb..a", "a.bb...a", "aaaaaaaa"],
        deploy: ["...aa...", "..aaaa..", ".aabbaa.", ".aabbaa.", ".aaaaaa.", "aa.aa.aa", "a..cc..a", "...cc..."]
    })
    readonly property var crate: ["aaaaaa", "abbbba", "abccba", "abccba", "abbbba", "aaaaaa"]
    readonly property var stageNames: ["commit", "build", "test", "deploy"]
    readonly property var stageX: [16, 52, 88, 124]

    function _px(ctx, x, y, c) {
        ctx.fillStyle = c
        ctx.fillRect(Math.round(x), Math.round(y), 1, 1)
    }
    function _rect(ctx, x, y, w, h, c) {
        ctx.fillStyle = c
        ctx.fillRect(Math.round(x), Math.round(y), w, h)
    }
    function _sprite(ctx, rows, x, y, map) {
        for (var j = 0; j < rows.length; j++) {
            var r = rows[j]
            for (var i = 0; i < r.length; i++) {
                var ch = r.charAt(i)
                if (ch !== "." && map[ch]) _px(ctx, x + i, y + j, map[ch])
            }
        }
    }

    function _draw(ctx, tt) {
        var Cc = tones
        var t = tt % _loop
        var fail = t >= 9
        var lt = fail ? t - 9 : t
        var stops = [0, 1.5, 3.5, 5.5, 7]
        _rect(ctx, 0, 0, gridW, gridH, Cc.bg)

        // stars
        for (var s = 0; s < 14; s++) {
            var sx = (s * 37 + 11) % gridW, sy = (s * 17 + 3) % 12
            _px(ctx, sx, sy, ((Math.floor(t * 2) + s) % 5 === 0) ? Cc.dim : Cc.line)
        }
        // track
        for (var x = stageX[0]; x <= stageX[3]; x += 2) _px(ctx, x, 26, Cc.line)

        // crate position
        var cx = stageX[0]
        for (var i = 0; i < 3; i++) {
            if (lt >= stops[i] + 0.5)
                cx = stageX[i] + (stageX[i + 1] - stageX[i]) * Math.min(1, (lt - stops[i] - 0.5) / 1.0)
            else if (lt >= stops[i])
                cx = stageX[i]
        }
        if (lt >= stops[3]) cx = stageX[3]

        var bounceFrom = stops[2] + 1.5
        for (var k = 0; k < 4; k++) {
            var state = "wait"
            if (k === 0) state = "ok"
            if (k === 1) state = lt < stops[1] + 0.5 ? "wait" : (lt < stops[1] + 1.5 ? "run" : "ok")
            if (k === 2) state = lt < stops[2] ? "wait" : (lt < stops[2] + 1.5 ? "run" : (fail ? "bad" : "ok"))
            if (k === 3) state = lt < stops[3] ? "wait" : (fail ? "skip" : "ok")
            var a = Cc.dim, b = Cc.line, c = Cc.dim
            if (state === "ok")  { a = Cc.ok;  b = Cc.okd;  c = Cc.amb }
            if (state === "bad") { a = Cc.bad; b = Cc.badd; c = Cc.bad }
            if (state === "run") { a = Cc.blue; b = Cc.blued; c = Cc.blue }
            var oy = (state === "bad" && Math.floor(t * 10) % 2 === 0) ? 1 : 0
            _sprite(ctx, icons[stageNames[k]], stageX[k] - 4, 14 + oy, { a: a, b: b, c: c })
            if (k === 1 && state === "run" && Math.floor(t * 6) % 2 === 0) {
                _px(ctx, stageX[k] - 1, 13, Cc.blue); _px(ctx, stageX[k], 13, Cc.blue)
            }
            var led = state === "ok" ? Cc.ok : state === "bad" ? Cc.bad
                    : state === "run" ? (Math.floor(t * 4) % 2 ? Cc.blue : Cc.blued) : Cc.line
            _rect(ctx, stageX[k] - 1, 28, 3, 2, led)
            var nl = stageNames[k].length
            for (var d = 0; d < nl; d++)
                _px(ctx, stageX[k] - nl * 1.5 + d * 3, 33, (state === "wait" || state === "skip") ? Cc.line : led)
        }

        // crate (red and bouncing back after a failed test)
        var bouncing = fail && lt > bounceFrom && lt < stops[2] + 4
        if (bouncing) {
            var f = (lt - bounceFrom) / 2.5
            _sprite(ctx, crate, stageX[2] - f * 26 - 3, 19 - Math.abs(Math.sin(f * 6)) * 4,
                    { a: Cc.bad, b: Cc.badd, c: "#ffb0b0" })
        } else if (lt < stops[3] + 1.5 && !(fail && lt >= stops[2] + 4)) {
            _sprite(ctx, crate, cx - 3, 19, { a: Cc.amb, b: "#a8741f", c: "#ffe3a0" })
        }

        // success burst at deploy
        if (!fail && lt >= stops[3]) {
            var ft = lt - stops[3]
            for (var p = 0; p < 10; p++) {
                var ang = p * 0.63, rr = ft * 7 + 2
                _px(ctx, stageX[3] + Math.cos(ang) * rr, 17 + Math.sin(ang) * rr * 0.8, p % 2 ? Cc.ok : Cc.amb)
            }
        }
        // failure alert over the test stage
        if (fail && lt >= bounceFrom && Math.floor(t * 4) % 2 === 0) {
            _rect(ctx, stageX[2] - 1, 6, 2, 5, Cc.bad); _rect(ctx, stageX[2] - 1, 12, 2, 1, Cc.bad)
        }
        // the watcher: a small monitor whose eyes follow the result
        var failing = fail && lt > bounceFrom
        _sprite(ctx, ["aaaaaaaa", "abbbbbba", "ab.bb.ba", "abbbbbba", "aaaaaaaa", "..aaaa..", ".aaaaaa."], 2, 31,
                { a: Cc.dim, b: "#0d1630" })
        if (Math.floor(t * 0.8) % 7 !== 0) {
            _px(ctx, 5, 34, failing ? Cc.bad : Cc.ok); _px(ctx, 8, 34, failing ? Cc.bad : Cc.ok)
        }
        // run counter
        for (var q = 0; q < 6; q++) {
            var done = lt > q * 1.3
            _px(ctx, gridW - 12 + q * 2, 36, done ? (fail && q >= 3 ? Cc.bad : Cc.ok) : Cc.line)
        }

        var text = fail ? (lt < bounceFrom ? "Run #2 · running tests…" : "Run #2 · tests failed — deploy skipped")
                        : (lt < stops[3] ? "Run #1 · in progress…" : "Run #1 · deployed")
        if (text !== caption) caption = text
    }

    onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.scale(pixelScale, pixelScale)
        _draw(ctx, t)
    }

    Component.onCompleted: requestPaint()
}
