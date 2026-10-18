import QtQuick
import Quickshell.Io
import qs.Commons

// Uniform "what to do next" card for a DevOps provider (Azure DevOps,
// Kubernetes, GitHub Actions and any future provider). Replaces the old
// one-line ProviderStatusBanner and is driven entirely by data from the
// provider's Python script, never hardcoded per provider here.
//
// Three situations, three colors:
//  - "setup" (amber): something is missing: a CLI to install or a login.
//  - "error" (red):   the provider tried to read and could not.
//  - "empty" (blue):  nothing is configured yet.
//
// The script sends an optional `notice` object next to the error:
//   { kind, title, message, steps: [{ label, command }], footer }
// (see scripts/provider_notice.py). When it is absent, the plain `error`
// string is shown as a single line, exactly like the old banner, so a new
// provider works with no extra markup (emit { status, error } and, for a
// missing tool, errorCode "missing_dependency" + dependency).
//
// Security: every string is plain text (never rich text), cleaned and bounded
// here again, even though the scripts already did it. The commands are only
// DISPLAYED and COPIED to the clipboard (wl-copy, argument array, no shell);
// nothing in this component ever runs them.
Item {
    id: root

    property var providerData: null   // e.g. root.service.kubernetes (or one cluster)
    property color textColor: "white"
    property var fontFamily: Style.font.family

    // Emitted when a notice of kind "empty" asks to edit config.json.
    signal openConfigRequested()

    // ── Sanitizing helpers ────────────────────────────────────────────────────
    function clip(value, limit) {
        if (typeof value !== "string") return ""
        return value.replace(/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u206f\ufeff]/g, " ")
                    .replace(/\s+/g, " ").trim().substring(0, limit)
    }

    readonly property var _notice: {
        var n = providerData ? providerData.notice : null
        if (!n || typeof n !== "object") return null
        var title = clip(n.title, 80)
        if (title === "") return null
        var kind = (n.kind === "setup" || n.kind === "error" || n.kind === "empty") ? n.kind : "error"
        var steps = []
        var raw = (n.steps && typeof n.steps.length === "number") ? n.steps : []
        for (var i = 0; i < raw.length && steps.length < 5; i++) {
            var cmd = raw[i] ? clip(raw[i].command, 200) : ""
            if (cmd !== "") steps.push({ label: clip(raw[i].label, 60), command: cmd })
        }
        return { kind: kind, title: title, message: clip(n.message, 240), steps: steps, footer: clip(n.footer, 160) }
    }

    readonly property bool _hasError: !!providerData
        && providerData.status === "offline"
        && (providerData.error || "") !== ""
    // Plain-line fallback (no notice from the script).
    readonly property bool _plain: _hasError && _notice === null
    readonly property bool _missingDependency: _plain
        && providerData.errorCode === "missing_dependency"
        && (providerData.dependency || "") !== ""

    readonly property string _kind: _notice ? _notice.kind : (_missingDependency ? "setup" : "error")
    readonly property color accent: _kind === "error" ? "#e05050" : (_kind === "empty" ? "#89b4fa" : "#f0c040")

    visible: _plain || _notice !== null
    width: parent ? parent.width : 0
    implicitHeight: _notice !== null ? card.implicitHeight : (_plain ? plainRow.implicitHeight : 0)
    height: implicitHeight

    // ── Plain one-line fallback ───────────────────────────────────────────────
    Row {
        id: plainRow
        visible: root._plain
        width: parent.width
        spacing: Style.space(8)
        leftPadding: Style.space(8)

        Text {
            textFormat: Text.PlainText
            text: root._missingDependency ? "⚙" : "⚠"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            textFormat: Text.PlainText
            text: root._missingDependency
                ? ("Install " + root.clip(root.providerData.dependency, 60) + " to enable this provider"
                   + ((root.providerData.hint || "") !== "" ? " (" + root.clip(root.providerData.hint, 100) + ")" : ""))
                : root.clip(root.providerData ? root.providerData.error : "", 300)
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            width: parent.width - Style.space(32)
            wrapMode: Text.WordWrap
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    // ── Notice card ───────────────────────────────────────────────────────────
    Rectangle {
        id: card
        visible: root._notice !== null
        width: parent.width
        implicitHeight: body.implicitHeight + Style.space(20)
        height: implicitHeight
        radius: Style.space(6)
        color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.07)
        border.width: 1
        border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.35)

        Rectangle {
            width: Style.space(3); height: parent.height - Style.space(12)
            x: Style.space(1); y: Style.space(6); radius: 2; color: root.accent
        }

        Column {
            id: body
            x: Style.space(14); y: Style.space(10)
            width: card.width - Style.space(28)
            spacing: Style.space(6)

            Row {
                spacing: Style.space(8)
                Text {
                    textFormat: Text.PlainText
                    text: root._kind === "error" ? "⚠" : (root._kind === "empty" ? "○" : "⚙")
                    color: root.accent
                    font.family: root.fontFamily; font.pixelSize: Style.font.body
                }
                Text {
                    objectName: "noticeTitle"
                    textFormat: Text.PlainText
                    text: root._notice ? root._notice.title : ""
                    color: root.accent; font.bold: true
                    font.family: root.fontFamily; font.pixelSize: Style.font.body
                }
            }

            Text {
                objectName: "noticeMessage"
                textFormat: Text.PlainText
                visible: text !== ""
                text: root._notice ? root._notice.message : ""
                width: parent.width; wrapMode: Text.WordWrap
                color: root.textColor; opacity: 0.75
                font.family: root.fontFamily; font.pixelSize: Style.font.caption + 1
            }

            Repeater {
                model: root._notice ? root._notice.steps : []
                delegate: Column {
                    id: stepCol
                    width: body.width
                    spacing: Style.space(3)
                    readonly property int stepIndex: index

                    Text {
                        textFormat: Text.PlainText
                        visible: text !== ""
                        text: modelData.label
                        color: root.textColor; opacity: 0.55
                        font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    }

                    Rectangle {
                        width: parent.width; height: Style.space(24); radius: Style.space(4)
                        color: Qt.rgba(0, 0, 0, 0.35)
                        border.width: 1; border.color: Qt.rgba(1, 1, 1, 0.10)

                        Text {
                            objectName: "noticeCommand"
                            textFormat: Text.PlainText
                            x: Style.space(8); anchors.verticalCenter: parent.verticalCenter
                            text: "$ " + modelData.command
                            color: "#a6e3a1"
                            font.family: root.fontFamily; font.pixelSize: Style.font.caption + 1
                            elide: Text.ElideRight; width: parent.width - Style.space(84)
                        }

                        Rectangle {
                            id: copyPill
                            objectName: "noticeCopy"
                            anchors.right: parent.right; anchors.rightMargin: Style.space(4)
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(70); height: Style.space(17); radius: Style.space(4)
                            readonly property bool done: root._copiedIndex === stepCol.stepIndex
                            readonly property bool failed: root._copyFailedIndex === stepCol.stepIndex
                            color: failed ? "#e05050" : (done ? "#a6e3a1" : "#89b4fa")
                            opacity: copyArea.containsMouse ? 0.32 : 0.18

                            MouseArea {
                                id: copyArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root._copy(stepCol.stepIndex, modelData.command)
                            }
                        }
                        Text {
                            anchors.centerIn: copyPill
                            textFormat: Text.PlainText
                            text: copyPill.failed ? "No wl-copy" : (copyPill.done ? "Copied" : "Copy")
                            color: copyPill.failed ? "#e05050" : (copyPill.done ? "#a6e3a1" : "#89b4fa")
                            font.bold: true
                            font.family: root.fontFamily; font.pixelSize: Style.font.caption
                        }
                    }
                }
            }

            // Closing line. For an "empty" notice it is the shortcut to config.json.
            Text {
                objectName: "noticeFooter"
                textFormat: Text.PlainText
                visible: text !== ""
                text: root._notice ? root._notice.footer : ""
                width: parent.width; wrapMode: Text.WordWrap
                color: "#89b4fa"
                font.family: root.fontFamily; font.pixelSize: Style.font.caption
                font.underline: root._kind === "empty" && footerArea.containsMouse

                MouseArea {
                    id: footerArea
                    anchors.fill: parent
                    enabled: root._kind === "empty"
                    hoverEnabled: enabled
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.openConfigRequested()
                }
            }
        }
    }

    // ── Copy to clipboard ─────────────────────────────────────────────────────
    // wl-copy, started with an argument array (no shell). "--" ends option
    // parsing so a command that starts with "-" can never be read as an option.
    property int _copiedIndex: -1
    property int _copyFailedIndex: -1
    property int _copyingIndex: -1

    function _copy(index, command) {
        if (copier.running || typeof command !== "string" || command === "") return
        _copyingIndex = index
        copier.command = ["/usr/bin/wl-copy", "--", command]
        copier.running = true
    }

    Process {
        id: copier
        running: false
        onExited: function(exitCode, exitStatus) {
            if (exitCode === 0) { root._copiedIndex = root._copyingIndex; root._copyFailedIndex = -1 }
            else { root._copyFailedIndex = root._copyingIndex; root._copiedIndex = -1 }
            copyReset.restart()
        }
    }

    Timer {
        id: copyReset
        interval: 1800
        onTriggered: { root._copiedIndex = -1; root._copyFailedIndex = -1 }
    }
}
