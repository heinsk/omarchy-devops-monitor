import QtQuick
import qs.Commons

// "About" tab: a pixel animation of a monitored process, a short summary of
// what the plugin does and where it comes from. Static text only; nothing
// here reads or changes any data. The animation runs only while `active`.
Column {
    id: root
    objectName: "aboutTab"

    property color textColor: "white"
    property var fontFamily: Style.font.family
    property string version: ""
    property bool active: false

    readonly property string repoUrl: "https://github.com/heinsk/omarchy-devops-monitor"

    signal openUrl(string url)

    width: parent ? parent.width : 0
    spacing: Style.space(12)

    readonly property var _features: [
        { color: "#4c8dff", title: "Azure DevOps",   text: "Pipelines and releases per project: status, previous run, time and branch." },
        { color: "#b57cf6", title: "GitHub Actions", text: "Latest run of each workflow per repository, with its branch and event." },
        { color: "#5fa8ff", title: "Kubernetes",     text: "Nodes, pods, deployments and what needs attention, by namespace." },
        { color: "#f0b35a", title: "Jobs and errors", text: "Expand a run to see its jobs, tasks and the error message of the failing one." },
        { color: "#3ecf5a", title: "Copy and open",  text: "Copy URL and Open link on every row." },
        { color: "#ff5b5b", title: "Alerts",         text: "Opt-in desktop notifications, silence per provider and a problem counter on the bar." }
    ]

    // Live process (animation)
    SectionCard {
        tint: root.textColor
        spacing: Style.space(6)

        Text {
            text: "LIVE PROCESS"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            opacity: 0.5
        }
        Item {
            width: parent.width
            height: monitor.height
            PixelMonitor {
                id: monitor
                anchors.horizontalCenter: parent.horizontalCenter
                availableWidth: parent.width
                running: root.active
            }
        }
        Item {
            width: parent.width
            height: caption.implicitHeight
            Text {
                id: caption
                objectName: "pixelCaption"
                textFormat: Text.PlainText
                text: monitor.caption
                color: root.textColor
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
            Text {
                anchors.right: parent.right
                textFormat: Text.PlainText
                text: "Demo animation · runs only while this tab is open"
                color: root.textColor
                opacity: 0.4
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
            }
        }
    }

    // What it does
    SectionCard {
        tint: root.textColor
        spacing: Style.space(6)

        Text {
            text: "WHAT IT DOES"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            opacity: 0.5
        }
        Text {
            objectName: "aboutSummary"
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Watches your delivery stack from the Omarchy bar and tells you when something breaks. "
                + "Read-only: it uses your own az, kubectl and gh sessions and stores no credentials."
            color: root.textColor
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }
        Grid {
            id: featureGrid
            width: parent.width
            columns: 2
            spacing: Style.space(8)
            Repeater {
                model: root._features
                delegate: Rectangle {
                    width: (featureGrid.width - featureGrid.spacing) / 2
                    height: Math.max(featureText.implicitHeight + featureTitle.implicitHeight + Style.space(18), Style.space(60))
                    radius: Style.space(5)
                    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.04)
                    border.width: 1
                    border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.14)
                    Row {
                        id: featureTitle
                        x: Style.space(10); y: Style.space(8)
                        spacing: Style.space(6)
                        Rectangle { width: Style.space(8); height: Style.space(8); color: modelData.color; anchors.verticalCenter: parent.verticalCenter }
                        Text {
                            objectName: "featureTitle"
                            textFormat: Text.PlainText
                            text: modelData.title
                            color: root.textColor
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }
                    }
                    Text {
                        id: featureText
                        x: Style.space(10)
                        y: Style.space(8) + featureTitle.height + Style.space(4)
                        width: parent.width - Style.space(20)
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        text: modelData.text
                        color: root.textColor
                        opacity: 0.65
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }
    }

    // About
    SectionCard {
        tint: root.textColor
        spacing: Style.space(4)

        Text {
            text: "ABOUT"
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            opacity: 0.5
        }
        Repeater {
            model: [
                { label: "Version",  value: root.version },
                { label: "Author",   value: "heinsk" },
                { label: "License",  value: "MIT" },
                { label: "Needs",    value: "az (azure-devops extension), kubectl and gh — only for the providers you enable" },
                { label: "Optional", value: "wl-clipboard (Copy), libnotify (desktop alerts)" }
            ]
            delegate: Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                    width: Style.space(90)
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.textColor
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
                Text {
                    objectName: "aboutValue"
                    width: parent.width - Style.space(98)
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    text: modelData.value
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                }
            }
        }
        Row {
            width: parent.width
            spacing: Style.space(8)
            Text {
                width: Style.space(90)
                anchors.verticalCenter: parent.verticalCenter
                text: "Source"
                color: root.textColor
                opacity: 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
            }
            Text {
                objectName: "aboutRepo"
                width: parent.width - Style.space(90) - Style.space(8) - Style.space(60)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "github.com/heinsk/omarchy-devops-monitor"
                color: "#89b4fa"
                elide: Text.ElideRight
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
            }
            CopyIcon {
                objectName: "aboutCopy"
                text: root.repoUrl
                mutedColor: root.textColor
                fontFamily: root.fontFamily
                tip: "Copy URL"
            }
            LinkIcon {
                objectName: "aboutOpen"
                width: Style.space(24)
                mutedColor: root.textColor
                onClicked: root.openUrl(root.repoUrl)
            }
        }
    }
}
