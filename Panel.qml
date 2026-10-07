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
    readonly property string pluginVersion: "0.3.0"

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

            // Security: only open validated HTTPS github.com URLs (the script
            // already drops anything else; this is the second, UI-side check).
            function openGithubUrl(url) {
                if (!url || typeof url !== "string") return
                if (url.indexOf("https://github.com/") !== 0) return
                if (/\s/.test(url) || url.length > 300) return
                Qt.openUrlExternally(url)
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
                            // Same icon as the bar button (BarWidget.qml), same font family.
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

                    // Refreshing indicator only — each provider has its own
                    // refresh icon (with last-updated time) on the Status tab.
                    Text {
                        textFormat: Text.PlainText
                        visible: !!root.service && root.service.refreshing
                        text: "Refreshing..."
                        color: root.barForeground
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                        opacity: 0.5
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                // -- Tabs ------------------------------------------------------

                property int _tab: 0

                Row {
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                        model: ["Status", "Configuration"]
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

                // -- Tab: Status (Azure DevOps pipelines + Kubernetes clusters) --

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
                        spacing: Style.space(8)

                        // Nothing enabled -> say so instead of showing an empty tab
                        Text {
                            visible: !!root.service
                                && root.service.azureDevOps.status === "disabled"
                                && root.service.kubernetes.status === "disabled"
                                && root.service.github.status === "disabled"
                            text: "No providers enabled. Turn one on in the Configuration tab."
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            opacity: 0.5
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }

                        // Azure DevOps card (label + refresh, banner, projects)
                        SectionCard {
                            tint: root.barForeground
                            spacing: Style.space(4)
                            visible: !!root.service && root.service.azureDevOps.status !== "disabled"

                        // Azure DevOps label + per-provider refresh
                        Item {
                            width: parent.width
                            height: azureLabelRow.implicitHeight

                        Row {
                            id: azureLabelRow
                            spacing: Style.space(8)

                            ProviderIcon {
                                iconName: "azure-devops"
                                glyph: "\u25B6"  // ▶ pipelines
                                fallbackColor: "#0078d4"
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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

                        ProviderRefreshButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            refreshing: !!root.service && root.service.azureRefreshing
                            lastUpdated: root.service ? root.service.azureLastUpdated : ""
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                            onClicked: if (root.service) root.service.refreshProvider("azureDevOps")
                        }
                        }

                        // Error banner — generic component, shared with
                        // Kubernetes and any future provider (see
                        // ProviderStatusBanner.qml). Azure DevOps had no
                        // visible error state before this.
                        ProviderStatusBanner {
                            width: parent.width
                            providerData: root.service ? root.service.azureDevOps : null
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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
                                                BranchLabel {
                                                    width: parent.width
                                                    branch: modelData.branch || ""
                                                    textColor: root.barForeground
                                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                                }
                                            }
                                            StatusBadge {
                                                width: parent.width * 0.18
                                                status: ["success", "running", "failed"].indexOf(modelData.status) >= 0 ? modelData.status : "unknown"
                                                label: modelData.status === "success" ? "Success" : modelData.status === "running" ? "Running" : modelData.status === "failed" ? "Failed" : "Unknown"
                                                textColor: root.barForeground
                                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                            }
                                            StatusBadge {
                                                width: parent.width * 0.12
                                                status: ["success", "running", "failed"].indexOf(modelData.lastStatus) >= 0 ? modelData.lastStatus : ""
                                                textColor: root.barForeground
                                                animate: false
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
                                            LinkIcon {
                                                width: parent.width * 0.08
                                                active: !!modelData.url
                                                mutedColor: root.barForeground
                                                onClicked: keyCatcher.openAzureUrl(modelData.url)
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
                                        StatusBadge {
                                            width: parent.width * 0.18
                                            status: ["success", "running", "failed"].indexOf(modelData.status) >= 0 ? modelData.status : "unknown"
                                            label: modelData.status === "success" ? "Success" : modelData.status === "running" ? "Running" : modelData.status === "failed" ? "Failed" : "Unknown"
                                            textColor: root.barForeground
                                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                        }
                                        StatusBadge {
                                            width: parent.width * 0.12
                                            status: ["success", "running", "failed"].indexOf(modelData.lastStatus) >= 0 ? modelData.lastStatus : ""
                                            textColor: root.barForeground
                                            animate: false
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
                                        LinkIcon {
                                            width: parent.width * 0.08
                                            active: !!modelData.url
                                            mutedColor: root.barForeground
                                            onClicked: keyCatcher.openAzureUrl(modelData.url)
                                        }
                                    }
                                }
                            }
                        }
                        }

                        // Kubernetes card (label + refresh, banner, clusters)
                        SectionCard {
                            tint: root.barForeground
                            visible: root.service && root.service.kubernetes
                                && root.service.kubernetes.status !== "disabled"
                            spacing: Style.space(4)

                            Item {
                                width: parent.width
                                height: k8sLabelRow.implicitHeight

                            Row {
                                id: k8sLabelRow
                                spacing: Style.space(8)

                                ProviderIcon {
                                    iconName: "kubernetes"
                                    glyph: "\u25C8"  // ◈ cluster
                                    fallbackColor: "#326ce5"
                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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

                            ProviderRefreshButton {
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                refreshing: !!root.service && root.service.kubernetesRefreshing
                                lastUpdated: root.service ? root.service.kubernetesLastUpdated : ""
                                textColor: root.barForeground
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                onClicked: if (root.service) root.service.refreshProvider("kubernetes")
                            }
                            }

                            // Error banner — shown when the provider itself
                            // failed (kubectl missing, no auth, bad context).
                            // Generic component, shared with any other
                            // provider (see ProviderStatusBanner.qml).
                            ProviderStatusBanner {
                                width: parent.width
                                providerData: root.service ? root.service.kubernetes : null
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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
                                    StatusBadge {
                                        width: parent.width * 0.20
                                        status: modelData.status || "unknown"
                                        label: modelData.status === "healthy" ? "Healthy" : modelData.status === "warning" ? "Warning" : modelData.status === "offline" ? "Offline" : "Unknown"
                                        textColor: root.barForeground
                                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
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

                        // GitHub Actions card (label + refresh, banner, repositories)
                        SectionCard {
                            tint: root.barForeground
                            visible: !!root.service && root.service.github.status !== "disabled"
                            spacing: Style.space(4)

                            Item {
                                width: parent.width
                                height: githubLabelRow.implicitHeight

                                Row {
                                    id: githubLabelRow
                                    spacing: Style.space(8)

                                    ProviderIcon {
                                        iconName: "github"
                                        glyph: "\u25C6"  // ◆ repositories
                                        fallbackColor: "#a371f7"
                                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    Text {
                                        text: "GitHub Actions"
                                        color: root.barForeground
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        font.bold: true
                                        opacity: 0.6
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                }

                                ProviderRefreshButton {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    refreshing: !!root.service && root.service.githubRefreshing
                                    lastUpdated: root.service ? root.service.githubLastUpdated : ""
                                    textColor: root.barForeground
                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                    onClicked: if (root.service) root.service.refreshProvider("github")
                                }
                            }

                            ProviderStatusBanner {
                                width: parent.width
                                providerData: root.service ? root.service.github : null
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                            }

                            Repeater {
                                model: root.service ? (root.service.github.repos || []) : []
                                delegate: WorkflowTable {
                                    width: parent.width
                                    repoData: modelData
                                    textColor: root.barForeground
                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                    onOpenUrl: function(url) { keyCatcher.openGithubUrl(url) }
                                }
                            }
                        }
                    }
                }

                // -- Tab: Configuration ----------------------------------------
                // Wrapped in a ScrollView (same as Status) so content
                // that grows taller than the panel — like an expanded
                // "View config.json" — scrolls and clips instead of
                // overflowing past the panel's edges.

                ScrollView {
                    id: configScroll
                    visible: parent._tab === 1
                    width: parent.width
                    height: Style.space(420)
                    clip: true
                    ScrollBar.vertical.policy: ScrollBar.AsNeeded
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                Column {
                    id: configTab
                    width: configScroll.width
                    spacing: Style.space(12)

                    readonly property var cfg: root.service ? (root.service._config || {}) : {}
                    readonly property var providers: configTab.cfg.providers || {}
                    readonly property var targets: (configTab.cfg.azureDevOps && configTab.cfg.azureDevOps.targets) || []
                    // Effective per-provider refresh interval — same rule as
                    // Service.qml (_intervalMs): default 60 s, clamped to 30..3600.
                    function effectiveSecs(v) {
                        if (typeof v !== "number" || !isFinite(v)) return 60
                        return Math.min(3600, Math.max(30, Math.round(v)))
                    }
                    readonly property int azureRefreshSecs: effectiveSecs(configTab.cfg.refresh ? configTab.cfg.refresh.azureDevOps : undefined)
                    readonly property int k8sRefreshSecs: effectiveSecs(configTab.cfg.refresh ? configTab.cfg.refresh.kubernetes : undefined)
                    readonly property int ghRefreshSecs: effectiveSecs(configTab.cfg.refresh ? configTab.cfg.refresh.github : undefined)
                    readonly property bool mockMode: !!(configTab.cfg.development && configTab.cfg.development.mockData)
                    readonly property bool azureEnabled: !!configTab.providers.azureDevOps
                    readonly property bool k8sEnabled: !!configTab.providers.kubernetes
                    readonly property bool ghEnabled: !!configTab.providers.github
                    readonly property var ghRepos: (configTab.cfg.github && Array.isArray(configTab.cfg.github.repos)) ? configTab.cfg.github.repos : []
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
                    SectionCard {
                        tint: root.barForeground
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
                            ProviderToggle {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: configTab.azureEnabled
                                busy: !root.service || root.service.toggling || root.service.azureRefreshing
                                onToggled: function(v) { root.service.setProviderEnabled("azureDevOps", v) }
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
                            ProviderToggle {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: configTab.k8sEnabled
                                busy: !root.service || root.service.toggling || root.service.kubernetesRefreshing
                                onToggled: function(v) { root.service.setProviderEnabled("kubernetes", v) }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)
                            Text {
                                text: configTab.ghEnabled ? "●" : "○"
                                color: configTab.ghEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                text: "GitHub Actions"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: configTab.ghEnabled ? 1.0 : 0.4
                                anchors.verticalCenter: parent.verticalCenter
                                width: Style.space(120)
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: configTab.ghEnabled ? "Active" : "Disabled"
                                color: configTab.ghEnabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            ProviderToggle {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: configTab.ghEnabled
                                busy: !root.service || root.service.toggling || root.service.githubRefreshing
                                onToggled: function(v) { root.service.setProviderEnabled("github", v) }
                            }
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: !!root.service && root.service.toggleError !== ""
                            text: root.service ? ("Could not save: " + root.service.toggleError) : ""
                            color: "#f38ba8"
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }
                    }

                    // Targets
                    SectionCard {
                        tint: root.barForeground
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
                    SectionCard {
                        tint: root.barForeground
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

                    // GitHub repositories
                    SectionCard {
                        tint: root.barForeground
                        spacing: Style.space(6)
                        visible: configTab.ghEnabled

                        Text {
                            text: "GITHUB REPOSITORIES"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: configTab.ghRepos.length === 0
                            text: "None yet \u2014 add \"owner/repo\" entries under github.repos in config.json"
                            color: root.barForeground
                            opacity: 0.5
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.body
                            leftPadding: Style.space(8)
                            wrapMode: Text.WordWrap
                            width: parent.width
                        }

                        Repeater {
                            model: configTab.ghRepos
                            delegate: Text {
                                textFormat: Text.PlainText
                                text: String(modelData)
                                color: "#89b4fa"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                leftPadding: Style.space(8)
                            }
                        }
                    }

                    // Auto-refresh
                    SectionCard {
                        tint: root.barForeground
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
                                text: "Every " + configTab.azureRefreshSecs + " seconds"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Row {
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)
                            Text {
                                text: "Kubernetes"
                                width: Style.space(120)
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.7
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: "Every " + configTab.k8sRefreshSecs + " seconds"
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.8
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Row {
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)
                            Text {
                                text: "GitHub Actions"
                                width: Style.space(120)
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.7
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                textFormat: Text.PlainText
                                text: "Every " + configTab.ghRefreshSecs + " seconds"
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

                    // Open config.json — delegates to Omarchy's own
                    // omarchy-launch-config-editor, which resolves
                    // whatever terminal + editor the person actually
                    // picked in Setup > Defaults (foot/nvim by default,
                    // but user-changeable) instead of this plugin
                    // guessing or hardcoding a pair. The path is built
                    // entirely from the plugin's own resolved install
                    // directory (Service.qml's _pluginDir, derived from
                    // Qt.resolvedUrl, never from user/network input), so
                    // there's nothing here for an attacker to redirect.
                    //
                    // Launched via Quickshell.execDetached() — fire-and-
                    // forget, not killed when the panel closes. No shell
                    // is involved: each argument is its own array entry,
                    // so there is no string for a shell to re-interpret.
                    Row {
                        spacing: Style.space(8)
                        topPadding: Style.space(6)
                        leftPadding: Style.space(8)

                        MouseArea {
                            width: openConfigRow.implicitWidth
                            height: openConfigRow.implicitHeight
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (root.service && root.service._pluginDir) {
                                    var path = root.service._pluginDir + "/config.json"
                                    Quickshell.execDetached(
                                        ["/usr/share/omarchy/bin/omarchy-launch-config-editor", path])
                                }
                            }

                            Row {
                                id: openConfigRow
                                spacing: Style.space(8)

                                Text {
                                    textFormat: Text.PlainText
                                    text: "⧉"
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    opacity: 0.6
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: "Open config.json in terminal"
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    opacity: 0.6
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }
                }
            }
        }
    }
}
