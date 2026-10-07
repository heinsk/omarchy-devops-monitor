import QtQuick
import qs.Commons

// Status icon followed by an optional text label (label == "" -> icon only).
// Purely presentational; used by the pipeline, workflow and cluster tables.
Row {
    id: root

    property string status: ""
    property string label: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family
    property real fontSize: Style.font.body
    property real iconSize: Style.space(15)
    property bool animate: true

    spacing: Style.space(6)
    // Same row height as a text line, so icon-only cells line up with the
    // text cells next to them.
    height: Math.max(Math.ceil(fontSize * 1.4), iconSize)

    StatusIcon {
        id: icon
        status: root.status
        size: root.iconSize
        animate: root.animate
        mutedColor: root.textColor
        anchors.verticalCenter: parent.verticalCenter
    }
    Text {
        visible: root.label !== ""
        textFormat: Text.PlainText
        text: root.label
        color: icon.iconColor
        opacity: (icon.kind === "cancelled" || icon.kind === "skipped" || icon.kind === "unknown") ? 0.6 : 1.0
        font.family: root.fontFamily
        font.pixelSize: root.fontSize
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
    }
}
