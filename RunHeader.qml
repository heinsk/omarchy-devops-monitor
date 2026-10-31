import QtQuick
import qs.Commons

// Column titles of a run table (pipelines, releases, workflows). The widths
// must match RunRow.qml, which draws the rows under it.
Row {
    id: root

    property color textColor: "white"
    property var fontFamily: Style.font.family

    leftPadding: Style.space(16)
    spacing: 0

    readonly property real _w: width - leftPadding

    Text { text: "Name";   width: root._w * 0.46; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
    Text { text: "Status"; width: root._w * 0.17; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
    Text { text: "Last";   width: root._w * 0.11; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
    Text { text: "Time";   width: root._w * 0.11; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
    Text { text: "Link";   width: root._w * 0.15; color: root.textColor; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4; horizontalAlignment: Text.AlignHCenter }
}
