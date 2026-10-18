import QtQuick
import qs.Commons

// "Silence ▾" control in a provider's header (v0.3.6). Silences only the
// DESKTOP NOTIFICATIONS of that provider; its data keeps refreshing.
//
//   normal:   [Silence ▾]                      click -> the choices below
//   choosing: [1 hour] [until 08:00] [indefinitely] [x]
//   silenced: silenced until 14:30  [Unmute]
//
// Hidden unless notifications are on and the provider is one of the notified
// providers. All state lives in Service.qml (muted / muteProvider / ...).
Row {
    id: root

    property var service: null
    property string provider: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family

    property bool choosing: false

    readonly property bool _active: !!service && !!service.notifyConfig && service.notificationsUsable
        && (service.notifyConfig.providers || []).indexOf(provider) >= 0
    readonly property bool _muted: _active && service.isMuted(provider)

    visible: _active
    spacing: Style.space(6)

    on_MutedChanged: choosing = false

    // The end of the silence, e.g. "14:30". Shown only while silenced.
    Text {
        objectName: "silenceStatus"
        visible: root._muted
        textFormat: Text.PlainText
        text: root._muted ? "silenced " + (root.service.mutedUntilLabel(root.provider) === "until unmuted"
                                            ? "until unmuted" : "until " + root.service.mutedUntilLabel(root.provider)) : ""
        color: "#f9e2af"
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
    }

    component Pill: Rectangle {
        id: pill
        property string label: ""
        property color accent: root.textColor
        signal clicked()
        width: pillText.implicitWidth + Style.space(14)
        height: Style.space(20)
        radius: height / 2
        color: Qt.rgba(accent.r, accent.g, accent.b, area.containsMouse ? 0.22 : 0.10)
        border.width: 1
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.30)
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        Text {
            id: pillText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: pill.label
            color: pill.accent
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

    Pill {
        objectName: "silenceOpen"
        visible: root._active && !root._muted && !root.choosing
        label: "Silence ▾"
        onClicked: root.choosing = true
    }

    Pill {
        objectName: "silenceUnmute"
        visible: root._muted
        label: "Unmute"
        accent: "#f9e2af"
        onClicked: root.service.unmuteProvider(root.provider)
    }

    Row {
        visible: root._active && !root._muted && root.choosing
        spacing: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        Pill { objectName: "silenceHour"; label: "1 hour"; onClicked: root.service.muteProvider(root.provider, "hour") }
        Pill {
            objectName: "silenceMorning"
            label: "until 08:00"
            onClicked: root.service.muteProvider(root.provider, "morning")
        }
        Pill { objectName: "silenceForever"; label: "indefinitely"; onClicked: root.service.muteProvider(root.provider, "forever") }
        Pill { objectName: "silenceCancel"; label: "✕"; onClicked: root.choosing = false }
    }
}
