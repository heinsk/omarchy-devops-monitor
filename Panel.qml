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
    readonly property string pluginVersion: "0.3.6"

    // Open / show-all state of each cluster's "Pods by namespace" section.
    // Kept here (not in the delegates) because the cluster list is rebuilt on
    // every refresh, which would otherwise collapse the section again.
    property var k8sView: ({})
    function setK8sView(key, open, all) {
        var next = {}
        for (var k in k8sView) next[k] = k8sView[k]
        next[key] = { open: !!open, all: !!open && !!all }
        k8sView = next
    }

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
        contentHeight: panel.fittedContentHeight(Style.space(640))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(dir) { root.switchPanel(dir) }

            // Security: only open validated HTTPS Azure DevOps URLs. The script already
            // validates them (azure_devops.py); this is the second, UI-side check.
            function isTrustedAzureUrl(url) {
                if (typeof url !== "string" || url === "" || url.indexOf("https://") !== 0) return false
                if (/[\s\\\u0000-\u001f\u007f]/.test(url)) return false
                var allowed = ["dev.azure.com", "vsrm.dev.azure.com", "visualstudio.com"]
                // Authority = what is between "https://" and the first / ? or #. Any "@"
                // means user information ("https://dev.azure.com:443@evil.com/"): refuse it.
                var authority = url.substring(8).split(/[\/?#]/)[0]
                if (authority.indexOf("@") >= 0) return false
                var host = authority.split(":")[0].toLowerCase()
                for (var i = 0; i < allowed.length; i++) {
                    // exact host, or a real subdomain ("." + allowed host at the very end)
                    var suffix = "." + allowed[i]
                    if (host === allowed[i]
                            || (host.length > suffix.length && host.substring(host.length - suffix.length) === suffix))
                        return true
                }
                return false
            }

            function openAzureUrl(url) {
                if (isTrustedAzureUrl(url)) Qt.openUrlExternally(url)
            }

            // Security: only open validated HTTPS github.com URLs (the script
            // already drops anything else; this is the second, UI-side check).
            function openGithubUrl(url) {
                if (!url || typeof url !== "string") return
                if (url.indexOf("https://github.com/") !== 0) return
                if (/\s/.test(url) || url.length > 300) return
                Qt.openUrlExternally(url)
            }

            // Opens config.json in the person's own editor (see the "Open
            // config.json in terminal" row in the Configuration tab for how this
            // stays safe). Also used by the "empty" provider notices.
            function openConfigFile() {
                if (root.service && root.service._pluginDir) {
                    var path = root.service._pluginDir + "/config.json"
                    Quickshell.execDetached(
                        ["/usr/share/omarchy/bin/omarchy-launch-config-editor", path])
                }
            }

            // Builds the github.com page of a configured "owner/repo" entry, or
            // "" when the entry is not a plain, valid repository name. Same rule
            // as REPO_RE in github_actions.py, plus: a name made only of dots
            // ("." or "..") is never a repository and would alter the URL path.
            function githubRepoUrl(name) {
                if (typeof name !== "string") return ""
                if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/.test(name)) return ""
                if (/^\.+$/.test(name.split("/")[1])) return ""
                return "https://github.com/" + name
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
                    // Fill what is left of the panel below the header and tabs
                    // (a fixed 420 left a gap on tall panels and overflowed on short ones).
                    height: keyCatcher.height > 0
                            ? Math.max(Style.space(160), keyCatcher.height - y - Style.space(4))
                            : Style.space(420)
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

                        SilenceControl {
                            anchors.right: azureRefresh.left
                            anchors.rightMargin: Style.space(10)
                            anchors.verticalCenter: parent.verticalCenter
                            service: root.service
                            provider: "azureDevOps"
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        }

                        ProviderRefreshButton {
                            id: azureRefresh
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            refreshing: !!root.service && root.service.azureRefreshing
                            lastUpdated: root.service ? root.service.azureLastUpdated : ""
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                            onClicked: if (root.service) root.service.refreshProvider("azureDevOps")
                        }
                        }

                        // Notice / error card — generic component, shared with
                        // Kubernetes, GitHub and any future provider (see
                        // ProviderNotice.qml).
                        ProviderNotice {
                            width: parent.width
                            providerData: root.service ? root.service.azureDevOps : null
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                            onOpenConfigRequested: keyCatcher.openConfigFile()
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

                            SilenceControl {
                                anchors.right: k8sRefresh.left
                                anchors.rightMargin: Style.space(10)
                                anchors.verticalCenter: k8sRefresh.verticalCenter
                                service: root.service
                                provider: "kubernetes"
                                textColor: root.barForeground
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                            }

                            ProviderRefreshButton {
                                id: k8sRefresh
                                anchors.right: parent.right
                                anchors.bottom: parent.bottom
                                refreshing: !!root.service && root.service.kubernetesRefreshing
                                lastUpdated: root.service ? root.service.kubernetesLastUpdated : ""
                                textColor: root.barForeground
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                onClicked: if (root.service) root.service.refreshProvider("kubernetes")
                            }
                            }

                            // Notice / error card — shown when the provider itself
                            // failed (kubectl missing, no auth, bad context).
                            // Generic component, shared with any other
                            // provider (see ProviderNotice.qml).
                            ProviderNotice {
                                width: parent.width
                                providerData: root.service ? root.service.kubernetes : null
                                textColor: root.barForeground
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                onOpenConfigRequested: keyCatcher.openConfigFile()
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

                                delegate: Column {
                                    id: clusterBlock
                                    width: parent.width - Style.space(16)
                                    x: Style.space(16)
                                    spacing: Style.space(2)
                                    readonly property string stateKey: "c:" + (modelData.name || "")

                                    Row {
                                        width: parent.width
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

                                    K8sClusterDetail {
                                        width: parent.width
                                        cluster: modelData
                                        textColor: root.barForeground
                                        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                        expanded: !!(root.k8sView[clusterBlock.stateKey] && root.k8sView[clusterBlock.stateKey].open)
                                        showAll: !!(root.k8sView[clusterBlock.stateKey] && root.k8sView[clusterBlock.stateKey].all)
                                        onExpandedToggled: function(open) { root.setK8sView(clusterBlock.stateKey, open, false) }
                                        onShowAllToggled: function(all) { root.setK8sView(clusterBlock.stateKey, true, all) }
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

                                SilenceControl {
                                    anchors.right: githubRefresh.left
                                    anchors.rightMargin: Style.space(10)
                                    anchors.verticalCenter: parent.verticalCenter
                                    service: root.service
                                    provider: "github"
                                    textColor: root.barForeground
                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                }

                                ProviderRefreshButton {
                                    id: githubRefresh
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    refreshing: !!root.service && root.service.githubRefreshing
                                    lastUpdated: root.service ? root.service.githubLastUpdated : ""
                                    textColor: root.barForeground
                                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                    onClicked: if (root.service) root.service.refreshProvider("github")
                                }
                            }

                            ProviderNotice {
                                width: parent.width
                                providerData: root.service ? root.service.github : null
                                textColor: root.barForeground
                                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                                onOpenConfigRequested: keyCatcher.openConfigFile()
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
                    height: keyCatcher.height > 0
                            ? Math.max(Style.space(160), keyCatcher.height - y - Style.space(4))
                            : Style.space(420)
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
                    readonly property var k8sNamespaces: Array.isArray(k8sConfig.namespaces) ? k8sConfig.namespaces : []
                    readonly property var k8sExcluded: Array.isArray(k8sConfig.excludeNamespaces) ? k8sConfig.excludeNamespaces : []

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
                                    id: tgtRow
                                    width: parent.width - Style.space(8) - Style.space(4)
                                    x: Style.space(4)
                                    readonly property real gap: 0   // no spaces: org/project reads like the real URL path
                                    readonly property real avail: width - tgtLink.width - Style.space(6)
                                    readonly property real sepW: sepText.implicitWidth + gap * 2
                                    readonly property real lineH: Math.max(orgText.implicitHeight, tgtLink.height)
                                    // Organization and project share one line when both fit; otherwise
                                    // the project goes on its own line. Either way each one can use the
                                    // whole width before it is cut.
                                    readonly property bool sameLine: !!modelData.project
                                        && orgText.implicitWidth + sepW + projText.implicitWidth <= avail
                                    height: sameLine || !modelData.project
                                        ? lineH
                                        : lineH + Math.ceil(projText.implicitHeight) + Style.space(2)

                                    Text {
                                        id: orgText
                                        objectName: "targetOrganization"
                                        textFormat: Text.PlainText
                                        text: modelData.organization || ""
                                        color: "#89b4fa"
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        opacity: 0.8
                                        elide: Text.ElideMiddle
                                        width: Math.min(implicitWidth, tgtRow.avail)
                                        y: (tgtRow.lineH - height) / 2

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: keyCatcher.openAzureUrl(modelData.organization)
                                        }
                                    }
                                    Text {
                                        id: sepText
                                        visible: tgtRow.sameLine && !!modelData.organization
                                        text: "/"
                                        color: root.barForeground
                                        opacity: 0.35
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        x: orgText.width + tgtRow.gap
                                        y: (tgtRow.lineH - height) / 2
                                    }
                                    Text {
                                        id: projText
                                        objectName: "targetProject"
                                        visible: !!modelData.project
                                        textFormat: Text.PlainText
                                        text: modelData.project || ""
                                        color: "#89b4fa"
                                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                        font.pixelSize: Style.font.body
                                        elide: Text.ElideRight
                                        width: tgtRow.sameLine ? implicitWidth : tgtRow.width
                                        x: tgtRow.sameLine ? (modelData.organization ? orgText.width + tgtRow.sepW : 0) : 0
                                        y: tgtRow.sameLine ? (tgtRow.lineH - height) / 2 : tgtRow.lineH + Style.space(2)
                                    }

                                    LinkIcon {
                                        id: tgtLink
                                        width: iconSize + Style.space(8)
                                        anchors.right: parent.right
                                        y: 0
                                        active: !!modelData.organization
                                        mutedColor: root.barForeground
                                        onClicked: keyCatcher.openAzureUrl(modelData.organization)
                                    }
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

                    // Kubernetes namespace filter (kubernetes.namespaces / excludeNamespaces)
                    SectionCard {
                        tint: root.barForeground
                        spacing: Style.space(6)
                        visible: configTab.k8sEnabled

                        Text {
                            text: "KUBERNETES NAMESPACES"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        NamespaceChips {
                            width: parent.width
                            label: "Included"
                            names: configTab.k8sNamespaces
                            emptyText: "All namespaces"
                            chipColor: "#89b4fa"
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        }

                        NamespaceChips {
                            width: parent.width
                            label: "Excluded"
                            names: configTab.k8sExcluded
                            emptyText: "None"
                            chipColor: "#f38ba8"
                            textColor: root.barForeground
                            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                        }

                        Text {
                            width: parent.width
                            wrapMode: Text.WordWrap
                            leftPadding: Style.space(8)
                            text: "Set kubernetes.namespaces / excludeNamespaces in config.json. An excluded namespace is always ignored."
                            color: root.barForeground
                            opacity: 0.35
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
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
                            delegate: Item {
                                id: repoRow
                                width: parent.width
                                height: Math.max(repoText.implicitHeight, repoLink.height)
                                readonly property string repoUrl: keyCatcher.githubRepoUrl(modelData)

                                Text {
                                    id: repoText
                                    objectName: "githubRepoName"
                                    textFormat: Text.PlainText
                                    text: String(modelData)
                                    color: "#89b4fa"
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    leftPadding: Style.space(8)
                                    elide: Text.ElideRight
                                    width: parent.width - repoLink.width - Style.space(6)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                LinkIcon {
                                    id: repoLink
                                    objectName: "githubRepoLink"
                                    width: iconSize + Style.space(8)
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    active: repoRow.repoUrl !== ""
                                    mutedColor: root.barForeground
                                    onClicked: keyCatcher.openGithubUrl(repoRow.repoUrl)
                                }
                            }
                        }
                    }

                    // Desktop notifications (read-only here; edit notifications in config.json)
                    SectionCard {
                        id: notifyCard
                        tint: root.barForeground
                        spacing: Style.space(6)
                        readonly property var nc: root.service ? root.service.notifyConfig : ({ enabled: false, providers: [], onRecovery: false, branches: [], maxPerHour: 5 })
                        readonly property var names: ({ azureDevOps: "Azure DevOps", kubernetes: "Kubernetes", github: "GitHub" })

                        Text {
                            text: "NOTIFICATIONS"
                            color: root.barForeground
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            opacity: 0.4
                        }

                        // Master switch (shown only when notify-send exists): writes notifications.enabled.
                        Row {
                            objectName: "notifyToggleRow"
                            visible: !!root.service && root.service.notifyDelivery === "ready"
                            spacing: Style.space(10)
                            leftPadding: Style.space(8)
                            Text {
                                text: "Desktop alerts"
                                width: Style.space(120)
                                color: root.barForeground
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.body
                                opacity: 0.7
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            Text {
                                objectName: "notifyState"
                                text: notifyCard.nc.enabled ? "On" : "Off"
                                color: notifyCard.nc.enabled ? "#4ec94e" : "#585b70"
                                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                font.pixelSize: Style.font.caption
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            ProviderToggle {
                                objectName: "notifyToggle"
                                anchors.verticalCenter: parent.verticalCenter
                                checked: notifyCard.nc.enabled === true
                                busy: !root.service || root.service.toggling
                                onToggled: function(v) { root.service.setNotificationsEnabled(v) }
                            }
                        }

                        Repeater {
                            model: [
                                { label: "Desktop alerts", value: (root.service && root.service.notifyDelivery === "missing") ? "Unavailable \u2014 notify-send not found" : (notifyCard.nc.enabled ? "On" : "Off \u2014 set notifications.enabled to true in config.json") },
                                { label: "Providers", value: notifyCard.nc.providers.length === 0 ? "none" : notifyCard.nc.providers.map(function(p) { return notifyCard.names[p] || p }).join(", ") },
                                { label: "On recovery", value: notifyCard.nc.onRecovery ? "Yes" : "No" },
                                { label: "Branches", value: notifyCard.nc.branches.length === 0 ? "all" : notifyCard.nc.branches.join(", ") },
                                { label: "Max per hour", value: String(notifyCard.nc.maxPerHour) + " per provider" },
                                { label: "Delivery", value: !root.service ? "unknown"
                                    : (root.service.notifyDelivery === "ready" ? "notify-send found"
                                    : (root.service.notifyDelivery === "missing"
                                        ? "notify-send not found \u2014 install libnotify; alerts stay in the panel and bar"
                                        : "checking\u2026")) }
                            ].filter(function(r) {
                                // Without notify-send the other settings mean nothing: show only why.
                                var d = root.service ? root.service.notifyDelivery : ""
                                if (d === "ready" && r.label === "Desktop alerts") return false   // the switch above shows it
                                return d !== "missing" || r.label === "Desktop alerts" || r.label === "Delivery"
                            })
                            delegate: Row {
                                spacing: Style.space(10)
                                leftPadding: Style.space(8)
                                Text {
                                    textFormat: Text.PlainText
                                    text: modelData.label
                                    width: Style.space(120)
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    opacity: 0.7
                                }
                                Text {
                                    objectName: "notifyValue"
                                    textFormat: Text.PlainText
                                    text: modelData.value
                                    width: notifyCard.width - Style.space(150) - Style.space(20)
                                    wrapMode: Text.WordWrap
                                    color: root.barForeground
                                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                                    font.pixelSize: Style.font.body
                                    opacity: 0.8
                                }
                            }
                        }

                        Text {
                            textFormat: Text.PlainText
                            visible: !!root.service && root.service.muteError !== ""
                            text: "A silence could not be saved (it lasts until the shell restarts): " + (root.service ? root.service.muteError : "")
                            color: "#f9e2af"
                            wrapMode: Text.WordWrap
                            width: parent.width
                            font.family: root.bar ? root.bar.fontFamily : Style.font.family
                            font.pixelSize: Style.font.caption
                            leftPadding: Style.space(8)
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
                            onClicked: keyCatcher.openConfigFile()

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
