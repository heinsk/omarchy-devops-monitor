import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "io.github.heinsk.devops-monitor"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null

    function open()  { root.controller.show() }
    function close() { root.controller.hide() }
    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.hostWidget || root, direction)
        return false
    }

    readonly property var service: hostWidget ? hostWidget.children[0] : null

    KeyboardPanel {
        id: panel
        anchorItem: root.anchorItem
        owner: root.hostWidget || root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(640))
        contentHeight: panel.fittedContentHeight(Style.space(520))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir) { root.switchPanel(dir) }

            Column {
                width: parent.width
                spacing: 0

                // ── Header ────────────────────────────────────────────────────

                Item {
                    width: parent.width
                    height: headerTitle.implicitHeight + Style.space(4)

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Text {
                            text: "󰓋"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: 18
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            id: headerTitle
                            text: "DevOps Monitor"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.subtitle
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                            text: root.service ? root.service.lastUpdated : ""
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            opacity: 0.5
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: (root.service && root.service.refreshing) ? "Refreshing..." : "Refresh"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            opacity: (root.service && root.service.refreshing) ? 0.4 : 0.8
                            anchors.verticalCenter: parent.verticalCenter

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var svc = root.service
                                    if (svc && !svc.refreshing) svc.refresh()
                                }
                            }
                        }
                    }
                }

                // ── Tabs ──────────────────────────────────────────────────────

                property int _tab: 0

                Row {
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                        model: ["Pipelines", "Configuration"]
                        delegate: Item {
                            width: (parent.width - Style.space(4)) / 2
                            height: tabLabel.implicitHeight + Style.space(10)

                            readonly property bool active: parent.parent._tab === index

                            Rectangle {
                                anchors.fill: parent
                                color: active
                                    ? Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, 0.12)
                                    : "transparent"
                                border.color: Qt.rgba(root.barForeground.r, root.barForeground.g, root.barForeground.b, active ? 0.3 : 0.1)
                                border.width: 1
                                radius: 4
                            }

                            Text {
                                id: tabLabel
                                anchors.centerIn: parent
                                text: modelData
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                font.bold: active
                                opacity: active ? 1.0 : 0.5
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: parent.parent.parent._tab = index
                            }
                        }
                    }
                }

                Item { width: 1; height: Style.space(8) }

                // ── Tab: Pipelines ────────────────────────────────────────────

                ScrollView {
                    id: pipelineScroll
                    visible: parent._tab === 0
                    width: parent.width
                    height: Style.space(420)
                    clip: true
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    Column {
                        width: pipelineScroll.width
                        spacing: Style.space(4)

                        // Azure DevOps label
                        Row {
                            spacing: Style.space(8)

                            Text {
                                text: "󰓊"
                                color: "#0078d4"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: "Azure DevOps"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                font.bold: true
                                opacity: 0.6
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Repeater {
                            model: root.service ? (root.service.azureDevOps.targets || []) : []

                            delegate: Column {
                                width: parent.width
                                spacing: Style.space(4)

                                Text {
                                    text: modelData.project || ""
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    opacity: 0.8
                                    leftPadding: Style.space(8)
                                }

                                // Pipelines
                                Text {
                                    text: "PIPELINES"
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    opacity: 0.4
                                    leftPadding: Style.space(16)
                                }

                                Row {
                                    leftPadding: Style.space(16)
                                    width: parent.width - Style.space(16)
                                    spacing: 0
                                    Text { text: "Name";   width: parent.width * 0.50; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Status"; width: parent.width * 0.18; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Last";   width: parent.width * 0.12; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Time";   width: parent.width * 0.12; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "View";   width: parent.width * 0.08; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                }

                                Repeater {
                                    model: modelData.pipelineList || []
                                    delegate: Column {
                                        width: parent.width - Style.space(16)
                                        x: Style.space(16)
                                        spacing: 0

                                        Row {
                                            width: parent.width
                                            spacing: 0
                                            Text {
                                                text: modelData.name || ""
                                                width: parent.width * 0.50
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.status === "failed" ? 1.0 : 0.8
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                width: parent.width * 0.18
                                                text: modelData.status === "success" ? "✓ Success" : modelData.status === "running" ? "● Running" : modelData.status === "failed" ? "✕ Failed" : "○ Unknown"
                                                color: modelData.status === "success" ? "#4ec94e" : modelData.status === "running" ? "#89b4fa" : modelData.status === "failed" ? "#e05050" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                            }
                                            Text {
                                                width: parent.width * 0.12
                                                text: modelData.lastStatus === "success" ? "✓" : modelData.lastStatus === "running" ? "●" : modelData.lastStatus === "failed" ? "✕" : "—"
                                                color: modelData.lastStatus === "success" ? "#4ec94e" : modelData.lastStatus === "running" ? "#89b4fa" : modelData.lastStatus === "failed" ? "#e05050" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.lastStatus ? 1.0 : 0.3
                                            }
                                            Text {
                                                width: parent.width * 0.12
                                                text: modelData.durationMin >= 0 ? modelData.durationMin + "m" : "—"
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: 0.7
                                            }
                                            Text {
                                                width: parent.width * 0.08
                                                text: modelData.url ? "↗" : "—"
                                                color: modelData.url ? "#89b4fa" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.url ? 1.0 : 0.3
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                    onClicked: { if (modelData.url) Qt.openUrlExternally(modelData.url) }
                                                }
                                            }
                                        }

                                        // Current stage — shown only when running and stage is known
                                        Text {
                                            visible: modelData.status === "running" && (modelData.currentStage || "") !== ""
                                            text: "   " + (modelData.currentStage || "")
                                            color: "#89b4fa"
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.caption
                                            opacity: 0.8
                                            width: parent.width
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                // Releases
                                Text {
                                    visible: (modelData.releaseList || []).length > 0
                                    text: "RELEASES"
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    opacity: 0.4
                                    leftPadding: Style.space(16)
                                }

                                Row {
                                    visible: (modelData.releaseList || []).length > 0
                                    leftPadding: Style.space(16)
                                    width: parent.width - Style.space(16)
                                    spacing: 0
                                    Text { text: "Name";   width: parent.width * 0.50; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Status"; width: parent.width * 0.18; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Last";   width: parent.width * 0.12; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "Time";   width: parent.width * 0.12; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                    Text { text: "View";   width: parent.width * 0.08; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                }

                                Repeater {
                                    model: modelData.releaseList || []
                                    delegate: Row {
                                        leftPadding: Style.space(16)
                                        width: parent.width - Style.space(16)
                                        spacing: 0
                                        Column {
                                            width: parent.width * 0.50
                                            spacing: 1
                                            Text {
                                                text: modelData.name || ""
                                                width: parent.width
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.status === "failed" ? 1.0 : 0.8
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                visible: (modelData.releaseName || "") !== ""
                                                text: modelData.releaseName || ""
                                                width: parent.width
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.caption
                                                opacity: 0.4
                                                elide: Text.ElideRight
                                            }
                                        }
                                        Text {
                                            width: parent.width * 0.18
                                            text: modelData.status === "success" ? "✓ Success" : modelData.status === "running" ? "● Running" : modelData.status === "failed" ? "✕ Failed" : "○ Unknown"
                                            color: modelData.status === "success" ? "#4ec94e" : modelData.status === "running" ? "#89b4fa" : modelData.status === "failed" ? "#e05050" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                        }
                                        Text {
                                            width: parent.width * 0.12
                                            text: modelData.lastStatus === "success" ? "✓" : modelData.lastStatus === "running" ? "●" : modelData.lastStatus === "failed" ? "✕" : "—"
                                            color: modelData.lastStatus === "success" ? "#4ec94e" : modelData.lastStatus === "running" ? "#89b4fa" : modelData.lastStatus === "failed" ? "#e05050" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: modelData.lastStatus ? 1.0 : 0.3
                                        }
                                        Text {
                                            width: parent.width * 0.12
                                            text: modelData.durationMin >= 0 ? modelData.durationMin + "m" : "—"
                                            color: root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: 0.7
                                        }
                                        Text {
                                            width: parent.width * 0.08
                                            text: modelData.url ? "↗" : "—"
                                            color: modelData.url ? "#89b4fa" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: modelData.url ? 1.0 : 0.3
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: { if (modelData.url) Qt.openUrlExternally(modelData.url) }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ── Tab: Configuration ────────────────────────────────────────

                Column {
                    id: configTab
                    visible: parent._tab === 1
                    width: parent.width
                    spacing: Style.space(12)

                    // Helper to safely read config
                    readonly property var cfg: root.service ? (root.service._config || {}) : {}
                    readonly property var providers: configTab.cfg.providers || {}
                    readonly property var targets: (configTab.cfg.azureDevOps && configTab.cfg.azureDevOps.targets) || []
                    readonly property int refreshSecs: (configTab.cfg.refresh && configTab.cfg.refresh.azureDevOps) ? configTab.cfg.refresh.azureDevOps : 60
                    readonly property bool mockMode: !!(configTab.cfg.development && configTab.cfg.development.mockData)
                    readonly property bool azureEnabled: !!configTab.providers.azureDevOps
                    readonly property bool k8sEnabled: !!configTab.providers.kubernetes

                    // Providers
                    Column {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                            text: "PROVIDERS"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)

                            Text {
                                text: configTab.azureEnabled ? "●" : "○"
                                color: configTab.azureEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Azure DevOps"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: configTab.azureEnabled ? 1.0 : 0.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: Style.space(120)
                            }
                            Text {
                                text: configTab.azureEnabled ? "Active" : "Disabled"
                                color: configTab.azureEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)

                            Text {
                                text: configTab.k8sEnabled ? "●" : "○"
                                color: configTab.k8sEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Kubernetes"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: configTab.k8sEnabled ? 1.0 : 0.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: Style.space(120)
                            }
                            Text {
                                text: configTab.k8sEnabled ? "Active" : "Disabled"
                                color: configTab.k8sEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    // Targets
                    Column {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                            text: "AZURE DEVOPS TARGETS"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        Repeater {
                            model: configTab.targets
                            delegate: Column {
                                width: parent.width
                                spacing: Style.space(2)
                                leftPadding: Style.space(8)

                                Text {
                                    text: "Target " + (index + 1)
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.caption
                                    font.bold: true
                                    opacity: 0.5
                                }
                                Row {
                                    leftPadding: Style.space(8)
                                    spacing: Style.space(6)

                                    Text {
                                        text: (modelData.organization || "") + "  ↗"
                                        color: "#89b4fa"
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (modelData.organization)
                                                    Qt.openUrlExternally(modelData.organization)
                                            }
                                        }
                                    }
                                }

                                Text {
                                    text: modelData.project || ""
                                    color: "#89b4fa"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    leftPadding: Style.space(8)
                                }
                            }
                        }
                    }

                    // Auto-refresh
                    Column {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                            text: "AUTO-REFRESH"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        Row {
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)
                            Text {
                                text: "Azure DevOps"
                                width: Style.space(120)
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.7
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "Every " + configTab.refreshSecs + " seconds"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                    }

                    // Mock mode warning
                    Row {
                        visible: configTab.mockMode
                        spacing: Style.space(8)
                        leftPadding: Style.space(8)

                        Text {
                            text: "⚠"
                            color: "#f0c040"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            text: "Mock data mode is active"
                            color: "#f0c040"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }
}
