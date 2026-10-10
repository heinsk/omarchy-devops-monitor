import QtQuick
import qs.Commons

// A label ("Included" / "Excluded") followed by a wrapping row of namespace
// "chips"; shows `emptyText` when the list is empty. Used by the Configuration
// tab to display the Kubernetes namespace filter. Plain text only.
Row {
    id: root

    property string label: ""
    property var names: []
    property string emptyText: ""
    property color chipColor: "#89b4fa"
    property color textColor: "white"
    property var fontFamily: Style.font.family
    property real labelWidth: Style.space(70)

    readonly property var list: {
        var out = []
        if (names && typeof names.length === "number")
            for (var i = 0; i < names.length; i++) {
                var n = names[i]
                if (typeof n === "string" && n.length > 0 && n.length <= 63) out.push(n)
            }
        return out
    }

    spacing: Style.space(8)
    leftPadding: Style.space(8)

    Text {
        text: root.label
        width: root.labelWidth
        color: root.textColor
        opacity: 0.5
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
    }
    Text {
        visible: root.list.length === 0
        textFormat: Text.PlainText
        text: root.emptyText
        color: root.chipColor
        opacity: root.chipColor === "#89b4fa" ? 1.0 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
    }
    Flow {
        visible: root.list.length > 0
        width: Math.max(0, root.width - root.labelWidth - root.leftPadding - root.spacing)
        spacing: Style.space(6)

        Repeater {
            model: root.list
            delegate: Rectangle {
                width: chipText.implicitWidth + Style.space(14)
                height: chipText.implicitHeight + Style.space(6)
                radius: Style.space(5)
                color: Qt.rgba(root.chipColor.r, root.chipColor.g, root.chipColor.b, 0.16)
                border.width: 1
                border.color: Qt.rgba(root.chipColor.r, root.chipColor.g, root.chipColor.b, 0.30)

                Text {
                    id: chipText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData
                    color: root.chipColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
            }
        }
    }
}
