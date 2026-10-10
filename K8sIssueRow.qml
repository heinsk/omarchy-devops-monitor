import QtQuick
import qs.Commons

// One line of a cluster's "Needs attention" list: severity icon, what kind of
// object it is, its name, namespace, the reason and (for pods) the restart
// count. Presentational only; every string comes from the cluster API, so it
// is always rendered as plain text.
Item {
    id: root

    property var issue: ({})
    property color textColor: "white"
    property var fontFamily: Style.font.family

    readonly property bool failed: issue.severity === "failed"
    readonly property color failedColor: "#f38ba8"
    readonly property color warningColor: "#f9e2af"

    height: Math.ceil(Style.font.body * 1.9)

    Row {
        x: Style.space(2)
        width: parent.width - Style.space(2)
        spacing: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter

        StatusBadge {
            id: badge
            status: root.failed ? "failed" : "warning"
            label: ""
            textColor: root.textColor
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: kindText
            textFormat: Text.PlainText
            text: root.issue.kind || ""
            width: Style.space(66)
            color: root.textColor
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: nameText
            textFormat: Text.PlainText
            text: root.issue.name || ""
            color: root.textColor
            font.bold: true
            opacity: 0.9
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideMiddle
            width: Math.min(implicitWidth, Math.max(Style.space(80), root.width * 0.38))
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: nsText
            textFormat: Text.PlainText
            visible: !!root.issue.namespace
            text: root.issue.namespace || ""
            color: "#89b4fa"
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: reasonText
            textFormat: Text.PlainText
            text: root.issue.reason || ""
            elide: Text.ElideRight
            // Whatever room is left on the line after the other pieces; a long
            // reason is cut with "..." instead of running out of the card.
            width: Math.max(Style.space(40), Math.min(implicitWidth,
                   root.width - Style.space(2) - badge.width - kindText.width - nameText.width
                   - (nsText.visible ? nsText.width : 0) - (restartsText.visible ? restartsText.width : 0)
                   - Style.space(6) * (restartsText.visible ? 5 : 4) - Style.space(4)))
            color: root.failed ? root.failedColor : root.warningColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            id: restartsText
            textFormat: Text.PlainText
            visible: (root.issue.restarts || 0) > 0
            text: "↻ " + (root.issue.restarts || 0)
            color: root.failedColor
            opacity: 0.9
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
