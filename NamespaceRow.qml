import QtQuick
import qs.Commons

// One namespace of the "Pods by namespace" list: status icon, name, a bar of
// ready vs. total pods (scaled to the largest namespace so sizes compare at a
// glance) and the pods / deployments ready counters.
Item {
    id: root

    property var ns: ({})
    property real maxPods: 1
    property color textColor: "white"
    property var fontFamily: Style.font.family

    readonly property int podsReady: (ns.pods && ns.pods.ready) || 0
    readonly property int podsTotal: (ns.pods && ns.pods.total) || 0
    readonly property int depsReady: (ns.deployments && ns.deployments.ready) || 0
    readonly property int depsTotal: (ns.deployments && ns.deployments.total) || 0
    readonly property bool podsPartial: podsReady < podsTotal
    readonly property bool depsPartial: depsReady < depsTotal
    readonly property bool healthy: ns.severity === "healthy"
    readonly property real scale: Math.max(1, maxPods)

    height: Math.ceil(Style.font.body * 1.8)

    StatusBadge {
        x: Style.space(2)
        status: root.healthy ? "success" : (root.ns.severity === "failed" ? "failed" : "warning")
        label: ""
        textColor: root.textColor
        anchors.verticalCenter: parent.verticalCenter
    }
    Text {
        x: Style.space(26)
        width: parent.width * 0.26
        textFormat: Text.PlainText
        text: root.ns.name || ""
        elide: Text.ElideRight
        color: root.textColor
        opacity: root.healthy ? 0.7 : 1.0
        font.bold: !root.healthy
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
    }
    Item {
        x: parent.width * 0.34
        width: parent.width * 0.30
        height: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        // Not-ready part (full length of the namespace), then the ready part on top.
        Rectangle {
            visible: root.podsPartial
            width: parent.width * root.podsTotal / root.scale
            height: parent.height
            radius: height / 2
            color: "#f38ba8"
            opacity: 0.55
        }
        Rectangle {
            width: parent.width * root.podsReady / root.scale
            height: parent.height
            radius: height / 2
            color: root.podsPartial ? "#f9e2af" : "#4ec94e"
            opacity: 0.85
        }
    }
    Text {
        x: parent.width * 0.68
        width: parent.width * 0.14
        textFormat: Text.PlainText
        text: root.podsReady + "/" + root.podsTotal + " pods"
        color: root.podsPartial ? "#f9e2af" : root.textColor
        opacity: 0.85
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
    }
    Text {
        x: parent.width * 0.84
        width: parent.width * 0.16
        textFormat: Text.PlainText
        text: root.depsReady + "/" + root.depsTotal + " dep"
        color: root.depsPartial ? "#f9e2af" : root.textColor
        opacity: 0.7
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
    }
}
