import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "io.github.heinsk.devops-monitor"
    manageIpc: false

    // Keep in sync with the "version" field in manifest.json on every release.
    readonly property string pluginVersion: "0.1.0"

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

            // Security: only open validated HTTPS Azure DevOps URLs
            function openAzureUrl(url) {
                if (!url) return
                if (url.indexOf("https://") !== 0) return
                var allowed = ["dev.azure.com", "vsrm.dev.azure.com", "visualstudio.com"]
                var host = url.replace("https://", "").split("/")[0].split(":")[0].toLowerCase()
                var trusted = false
                for (var i = 0; i < allowed.length; i++) {
                    if (host === allowed[i] || host.lastIndexOf("." + allowed[i]) === host.length - allowed[i].length - 1) {
                        trusted = true
                        break
                    }
                }
                if (trusted) Qt.openUrlExternally(url)
            }

            Column {
                width: parent.width
                spacing: 0

                // -- Header ----------------------------------------------------

                Item {
                    width: parent.width
                    height: headerTitle.implicitHeight + Style.space(4)

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Text {
                            text: "*"
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
                            font.pixelSize: 18
                            font.bold: true
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            textFormat: Text.PlainText
                            text: "v" + root.pluginVersion
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            opacity: 0.4
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(8)

                        Text {
                            textFormat: Text.PlainText
                            text: root.service ? root.service.lastUpdated : ""
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            opacity: 0.5
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            textFormat: Text.PlainText
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

                // -- Tabs ------------------------------------------------------

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

                // -- Tab: Pipelines --------------------------------------------

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
                                text: "*"
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

                                // Project name
                                Text {
                                    textFormat: Text.PlainText
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
                                                textFormat: Text.PlainText
                                                text: modelData.name || ""
                                                width: parent.width * 0.50
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.status === "failed" ? 1.0 : 0.8
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                width: parent.width * 0.18
                                                text: modelData.status === "success" ? "✓ Success" : modelData.status === "running" ? "● Running" : modelData.status === "failed" ? "✕ Failed" : "○ Unknown"
                                                color: modelData.status === "success" ? "#4ec94e" : modelData.status === "running" ? "#89b4fa" : modelData.status === "failed" ? "#e05050" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                width: parent.width * 0.12
                                                text: modelData.lastStatus === "success" ? "✓" : modelData.lastStatus === "running" ? "●" : modelData.lastStatus === "failed" ? "✕" : "—"
                                                color: modelData.lastStatus === "success" ? "#4ec94e" : modelData.lastStatus === "running" ? "#89b4fa" : modelData.lastStatus === "failed" ? "#e05050" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.lastStatus ? 1.0 : 0.3
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                width: parent.width * 0.12
                                                text: modelData.durationMin >= 0 ? modelData.durationMin + "m" : "—"
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: 0.7
                                            }
                                            Text {
                                                textFormat: Text.PlainText
                                                width: parent.width * 0.08
                                                text: modelData.url ? "↗" : "—"
                                                color: modelData.url ? "#89b4fa" : root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.url ? 1.0 : 0.3
                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                    onClicked: keyCatcher.openAzureUrl(modelData.url)
                                                }
                                            }
                                        }

                                        // Current stage for running pipelines
                                        Text {
                                            textFormat: Text.PlainText
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
                                                textFormat: Text.PlainText
                                                text: modelData.name || ""
                                                width: parent.width
                                                color: root.barForeground
                                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                                font.pixelSize: Style.font.body
                                                opacity: modelData.status === "failed" ? 1.0 : 0.8
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                textFormat: Text.PlainText
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
                                            textFormat: Text.PlainText
                                            width: parent.width * 0.18
                                            text: modelData.status === "success" ? "✓ Success" : modelData.status === "running" ? "● Running" : modelData.status === "failed" ? "✕ Failed" : "○ Unknown"
                                            color: modelData.status === "success" ? "#4ec94e" : modelData.status === "running" ? "#89b4fa" : modelData.status === "failed" ? "#e05050" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            width: parent.width * 0.12
                                            text: modelData.lastStatus === "success" ? "✓" : modelData.lastStatus === "running" ? "●" : modelData.lastStatus === "failed" ? "✕" : "—"
                                            color: modelData.lastStatus === "success" ? "#4ec94e" : modelData.lastStatus === "running" ? "#89b4fa" : modelData.lastStatus === "failed" ? "#e05050" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: modelData.lastStatus ? 1.0 : 0.3
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            width: parent.width * 0.12
                                            text: modelData.durationMin >= 0 ? modelData.durationMin + "m" : "—"
                                            color: root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: 0.7
                                        }
                                        Text {
                                            textFormat: Text.PlainText
                                            width: parent.width * 0.08
                                            text: modelData.url ? "↗" : "—"
                                            color: modelData.url ? "#89b4fa" : root.barForeground
                                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                            font.pixelSize: Style.font.body
                                            opacity: modelData.url ? 1.0 : 0.3
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                                                onClicked: keyCatcher.openAzureUrl(modelData.url)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Kubernetes label + clusters
                        Column {
                            width: parent.width
                            visible: root.service && root.service.kubernetes
                                && root.service.kubernetes.status !== "disabled"
                            spacing: Style.space(4)

                            Row {
                                spacing: Style.space(8)
                                topPadding: Style.space(10)

                                Text {
                                    text: "*"
                                    color: "#326ce5"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Text {
                                    text: "Kubernetes"
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    opacity: 0.6
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // Error banner — shown when the provider itself
                            // failed (kubectl missing, no auth, bad context)
                            Row {
                                visible: root.service && root.service.kubernetes
                                    && root.service.kubernetes.status === "offline"
                                    && (root.service.kubernetes.error || "") !== ""
                                width: parent.width
                                spacing: Style.space(8)
                                leftPadding: Style.space(8)

                                Text {
                                    text: "⚠"
                                    color: "#e05050"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    textFormat: Text.PlainText
                                    text: root.service ? (root.service.kubernetes.error || "") : ""
                                    color: "#e05050"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    width: parent.width - Style.space(32)
                                    wrapMode: Text.WordWrap
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // Column headers — same style as the Azure DevOps
                            // pipeline/release tables above.
                            Row {
                                visible: (root.service && (root.service.kubernetes.clusters || []).length > 0)
                                leftPadding: Style.space(16)
                                width: parent.width - Style.space(16)
                                spacing: 0
                                Text { text: "Cluster";     width: parent.width * 0.28; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                Text { text: "Status";      width: parent.width * 0.20; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                Text { text: "Nodes";       width: parent.width * 0.17; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                Text { text: "Pods";        width: parent.width * 0.17; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                                Text { text: "Deployments"; width: parent.width * 0.18; color: root.barForeground; font.family: root.bar ? root.bar.fontFamily : Style.font.family; font.pixelSize: Style.font.caption; font.bold: true; opacity: 0.4 }
                            }

                            Repeater {
                                model: root.service ? (root.service.kubernetes.clusters || []) : []

                                delegate: Row {
                                    width: parent.width - Style.space(16)
                                    x: Style.space(16)
                                    spacing: 0

                                    Text {
                                        textFormat: Text.PlainText
                                        text: modelData.name || ""
                                        width: parent.width * 0.28
                                        color: root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        opacity: 0.85
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width * 0.20
                                        text: modelData.status === "healthy" ? "✓ Healthy"
                                            : modelData.status === "warning" ? "⚠ Warning"
                                            : modelData.status === "offline" ? "✕ Offline"
                                            : "○ Unknown"
                                        color: modelData.status === "healthy" ? "#4ec94e"
                                            : modelData.status === "warning" ? "#f0c040"
                                            : modelData.status === "offline" ? "#e05050"
                                            : root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width * 0.17
                                        text: {
                                            var n = modelData.nodes || {}
                                            return (n.ready !== undefined ? n.ready : "—") + "/" + (n.total !== undefined ? n.total : "—")
                                        }
                                        color: root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width * 0.17
                                        text: {
                                            var p = modelData.pods || {}
                                            return (p.ready !== undefined ? p.ready : "—") + "/" + (p.total !== undefined ? p.total : "—")
                                        }
                                        color: root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8
                                    }
                                    Text {
                                        textFormat: Text.PlainText
                                        width: parent.width * 0.18
                                        text: {
                                            var d = modelData.deployments || {}
                                            return (d.ready !== undefined ? d.ready : "—") + "/" + (d.total !== undefined ? d.total : "—")
                                        }
                                        color: root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8
                                    }
                                }
                            }
                        }
                    }
                }

                // -- Tab: Configuration ----------------------------------------

                Column {
                    id: configTab
                    visible: parent._tab === 1
                    width: parent.width
                    spacing: Style.space(12)

                    readonly property var cfg: root.service ? (root.service._config || {}) : {}
                    readonly property var providers: configTab.cfg.providers || {}
                    readonly property var targets: (configTab.cfg.azureDevOps && configTab.cfg.azureDevOps.targets) || []
                    readonly property int refreshSecs: (configTab.cfg.refresh && configTab.cfg.refresh.azureDevOps) ? configTab.cfg.refresh.azureDevOps : 60
                    readonly property bool mockMode: !!(configTab.cfg.development && configTab.cfg.development.mockData)
                    readonly property bool azureEnabled: !!configTab.providers.azureDevOps
                    readonly property bool k8sEnabled: !!configTab.providers.kubernetes
                    readonly property var k8sConfig: configTab.cfg.kubernetes || {}
                    readonly property var k8sContexts: k8sConfig.contexts || []
                    readonly property bool k8sAllContexts: !!k8sConfig.allContexts

                    // Config read error/rejection banner
                    Row {
                        visible: root.service && root.service.configError !== ""
                        width: parent.width
                        spacing: Style.space(8)
                        leftPadding: Style.space(8)

                        Text {
                            text: "⚠"
                            color: "#e05050"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            anchors.verticalCenter: parent.verticalCenter
                        }
                        Text {
                            textFormat: Text.PlainText
                            text: root.service ? root.service.configError : ""
                            color: "#e05050"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            width: parent.width - Style.space(32)
                            wrapMode: Text.WordWrap
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

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
                                textFormat: Text.PlainText
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
                                textFormat: Text.PlainText
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

                                Item {
                                    width: parent.width - Style.space(8)
                                    height: orgText.implicitHeight
                                    x: Style.space(8)

                                    Text {
                                        id: orgText
                                        textFormat: Text.PlainText
                                        text: modelData.organization || ""
                                        color: "#89b4fa"
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8
                                        elide: Text.ElideRight
                                        width: parent.width - Style.space(24)
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: keyCatcher.openAzureUrl(modelData.organization)
                                        }
                                    }

                                    Text {
                                        text: "↗"
                                        color: "#89b4fa"
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        anchors.right: parent.right
                                        anchors.verticalCenter: parent.verticalCenter

                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: keyCatcher.openAzureUrl(modelData.organization)
                                        }
                                    }
                                }

                                Text {
                                    textFormat: Text.PlainText
                                    text: modelData.project || ""
                                    color: "#89b4fa"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    leftPadding: Style.space(8)
                                }
                            }
                        }
                    }

                    // Kubernetes contexts
                    Column {
                        width: parent.width
                        spacing: Style.space(6)
                        visible: configTab.k8sEnabled

                        Text {
                            text: "KUBERNETES CONTEXTS"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: configTab.k8sAllContexts
                            text: "All contexts in kubeconfig"
                            color: "#89b4fa"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            leftPadding: Style.space(8)
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: !configTab.k8sAllContexts && configTab.k8sContexts.length === 0
                            text: "Current active context (none specified)"
                            color: root.barForeground
                            opacity: 0.5
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            leftPadding: Style.space(8)
                        }

                        Repeater {
                            model: configTab.k8sAllContexts ? [] : configTab.k8sContexts
                            delegate: Text {
                                textFormat: Text.PlainText
                                text: modelData
                                color: "#89b4fa"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                leftPadding: Style.space(8)
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
                                textFormat: Text.PlainText
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
