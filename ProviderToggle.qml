import QtQuick
import qs.Commons

// Small on/off switch for enabling or disabling a provider from the panel.
// Purely presentational: it never writes anything itself, it only emits
// toggled(newValue); the caller decides what to do (see Service.qml's
// setProviderEnabled, which persists it in config.json).
Item {
    id: root

    property bool checked: false
    property bool busy: false          // dims and ignores clicks while true
    property color onColor: "#4ec94e"
    property color offColor: "#585b70"
    property color knobColor: "#ffffff"

    signal toggled(bool newValue)

    implicitWidth: Style.space(34)
    implicitHeight: Style.space(18)
    width: implicitWidth
    height: implicitHeight
    opacity: busy ? 0.4 : 1.0

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.checked ? root.onColor : root.offColor
        opacity: 0.85

        Rectangle {
            width: parent.height - Style.space(4)
            height: width
            radius: width / 2
            color: root.knobColor
            anchors.verticalCenter: parent.verticalCenter
            x: root.checked ? parent.width - width - Style.space(2) : Style.space(2)
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: root.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
        onClicked: if (!root.busy) root.toggled(!root.checked)
    }
}
