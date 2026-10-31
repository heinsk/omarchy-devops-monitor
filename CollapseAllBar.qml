import QtQuick
import qs.Commons

// "Collapse all" / "Expand all" pills above the provider cards on the Status
// tab. The panel decides what they do (it owns the open/closed state).
Row {
    id: root
    objectName: "collapseAllBar"

    property color textColor: "white"
    property var fontFamily: Style.font.family

    signal collapseAll()
    signal expandAll()

    spacing: Style.space(6)
    layoutDirection: Qt.RightToLeft   // right-aligned inside a full-width parent

    component Pill: Rectangle {
        id: pill
        property string label: ""
        signal clicked()
        width: pillText.implicitWidth + Style.space(14)
        height: Style.space(20)
        radius: height / 2
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, area.containsMouse ? 0.18 : 0.06)
        border.width: 1
        border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.25)
        Text {
            id: pillText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: pill.label
            color: root.textColor
            opacity: 0.75
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
        MouseArea {
            id: area
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pill.clicked()
        }
    }

    // RightToLeft: the first child is the right-most one.
    Pill { objectName: "expandAll";   label: "Expand all";   onClicked: root.expandAll() }
    Pill { objectName: "collapseAll"; label: "Collapse all"; onClicked: root.collapseAll() }
}
