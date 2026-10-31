import QtQuick
import qs.Commons

// One error message of a job or task: a red bar, the text (plain, wrapped)
// and a Copy icon. The text was already cleaned and bounded by the provider
// script; it is cleaned and bounded once more here before it is shown or
// copied, and it is never interpreted as markup.
Rectangle {
    id: root
    objectName: "errorMessage"

    property string message: ""
    property color textColor: "white"
    property var fontFamily: Style.font.family

    readonly property string clean: String(message || "")
        .replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁠-⁤⁦-⁯﻿]/g, " ")
        .replace(/\s+/g, " ").trim().substring(0, 300)

    visible: clean !== ""
    width: parent ? parent.width : 0
    implicitHeight: visible ? Math.max(body.implicitHeight, copyIcon.height) + Style.space(6) : 0
    height: implicitHeight
    radius: Style.space(3)
    color: Qt.rgba(0.88, 0.31, 0.31, 0.10)

    Rectangle {
        width: Style.space(3)
        height: parent.height
        radius: width / 2
        color: "#e05050"
    }

    Text {
        id: body
        objectName: "errorText"
        textFormat: Text.PlainText
        text: root.clean
        color: "#f1b7b7"
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        x: Style.space(10)
        y: Style.space(3)
        width: parent.width - Style.space(10) - copyIcon.width - Style.space(8)
    }

    CopyIcon {
        id: copyIcon
        objectName: "errorCopy"
        text: root.clean
        accent: "#f1b7b7"
        iconSize: Style.space(12)
        fontFamily: root.fontFamily
        tip: "Copy error"
        anchors.right: parent.right
        anchors.rightMargin: Style.space(4)
        anchors.top: parent.top
    }
}
