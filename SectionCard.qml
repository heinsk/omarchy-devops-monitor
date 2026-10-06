import QtQuick
import qs.Commons

// Bordered, slightly tinted card used to group each block of the
// Configuration tab (Providers, Azure DevOps targets, ...). Children are
// placed in an inner Column, so they can keep using `width: parent.width`.
// Colours are derived from `tint` (pass the panel's foreground colour) so
// the card follows whatever theme the bar uses.
Rectangle {
    id: root

    property color tint: "white"
    property int spacing: Style.space(6)
    property int padding: Style.space(10)

    default property alias content: inner.data

    width: parent ? parent.width : 0
    implicitHeight: inner.implicitHeight + padding * 2
    height: implicitHeight

    radius: Style.space(6)
    color: Qt.rgba(tint.r, tint.g, tint.b, 0.04)
    border.width: 1
    border.color: Qt.rgba(tint.r, tint.g, tint.b, 0.22)

    Column {
        id: inner
        x: root.padding
        y: root.padding
        width: root.width - root.padding * 2
        spacing: root.spacing
    }
}
