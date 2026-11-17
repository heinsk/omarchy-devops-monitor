import QtQuick
import qs.Commons

// Editor for the settings the panel is allowed to change (v0.3.8):
// Azure DevOps targets, GitHub repositories, Kubernetes contexts and namespaces.
//
// It works on a DRAFT (the lists below). Nothing is written while typing: the
// person presses "Review & save", the backend (config_edit.py, through
// Service.previewConfigEdit) checks every value again and returns the lines that
// would change, and only "Save" writes -- once. The checks in this file are early
// hints that mirror the backend rules; the backend is the authority.
Column {
    id: root
    objectName: "configEditor"

    property var service: null
    property color textColor: "white"
    property var fontFamily: Style.font.family

    signal closed()

    readonly property color accent: "#89b4fa"
    readonly property color bad: "#e05050"
    readonly property int maxTargets: 20
    readonly property int maxRepos: 20
    readonly property int maxContexts: 20
    readonly property int maxNamespaces: 50

    spacing: Style.space(12)

    // ── Draft ────────────────────────────────────────────────────────────────
    ListModel { id: targetsModel }      // { organization, project }
    ListModel { id: reposModel }        // { value }
    ListModel { id: nsModel }           // { value }   included namespaces
    ListModel { id: exModel }           // { value }   excluded namespaces
    property var ctxSelected: []        // selected kubectl context names
    property bool allContexts: false
    property bool mockData: false       // development.mockData
    property string nsPending: ""       // text typed in the "add" boxes but not added yet
    property string exPending: ""
    property int rev: 0                 // bumped on every edit so the bindings below refresh
    property string original: ""        // collect() as JSON right after loading

    function _arr(v) { return (v && typeof v.length === "number") ? v : [] }

    function load() {
        var cfg = (service && service._config) ? service._config : {}
        targetsModel.clear(); reposModel.clear(); nsModel.clear(); exModel.clear()
        var t = _arr(cfg.azureDevOps ? cfg.azureDevOps.targets : null)
        for (var i = 0; i < t.length; i++)
            if (t[i] && typeof t[i] === "object")
                targetsModel.append({ organization: String(t[i].organization || ""), project: String(t[i].project || "") })
        var r = _arr(cfg.github ? cfg.github.repos : null)
        for (var j = 0; j < r.length; j++) if (typeof r[j] === "string") reposModel.append({ value: r[j] })
        var k = cfg.kubernetes || {}
        var sel = [], c = _arr(k.contexts)
        for (var m = 0; m < c.length; m++) if (typeof c[m] === "string") sel.push(c[m])
        ctxSelected = sel
        allContexts = k.allContexts === true
        mockData = !!(cfg.development && cfg.development.mockData === true)
        var n = _arr(k.namespaces), e = _arr(k.excludeNamespaces)
        for (var a = 0; a < n.length; a++) if (typeof n[a] === "string") nsModel.append({ value: n[a] })
        for (var b = 0; b < e.length; b++) if (typeof e[b] === "string") exModel.append({ value: e[b] })
        nsPending = ""; exPending = ""
        original = JSON.stringify(collect())
        rev++
        if (service) service.loadKubeContexts()
    }

    function _values(model, key) {
        var out = []
        for (var i = 0; i < model.count; i++) out.push(String(model.get(i)[key]).trim())
        return out
    }

    // The changes in the shape config_edit.py expects. Rows left completely
    // blank are ignored.
    function collect() {
        var targets = []
        for (var i = 0; i < targetsModel.count; i++) {
            var o = String(targetsModel.get(i).organization).trim(), p = String(targetsModel.get(i).project).trim()
            if (o !== "" || p !== "") targets.push({ organization: o, project: p })
        }
        var repos = _values(reposModel, "value").filter(function(s) { return s !== "" })
        return {
            azureDevOps: { targets: targets },
            github: { repos: repos },
            kubernetes: {
                contexts: ctxSelected.slice(),
                allContexts: allContexts,
                namespaces: _values(nsModel, "value"),
                excludeNamespaces: _values(exModel, "value")
            },
            development: { mockData: mockData }
        }
    }

    // ── Early checks (same rules as the backend) ─────────────────────────────
    readonly property var azureHosts: ["dev.azure.com", "visualstudio.com"]
    function orgError(s) {
        if (s === "") return "Required"
        if (s.length > 200 || /[\s\\\u0000-\u001f\u007f]/.test(s)) return "Use https://dev.azure.com/<organization>"
        var m = /^https:\/\/([^\/@:?#]+)(?::\d+)?(\/[^?#]*)?$/.exec(s)
        if (!m) return "Use https://dev.azure.com/<organization>"
        var host = m[1].toLowerCase()
        for (var i = 0; i < azureHosts.length; i++)
            if (host === azureHosts[i] || host.endsWith("." + azureHosts[i])) return ""
        return "Use https://dev.azure.com/<organization>"
    }
    function projectError(s) {
        if (s === "") return "Required"
        return /^\w[\w\s.\-]{0,63}$/.test(s) ? "" : "Letters, digits, spaces, '-', '.' and '_' (max 64)"
    }
    function repoError(s) {
        if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}$/.test(s)) return "Use owner/repo, for example my-org/web-app"
        return /^\.+$/.test(s.split("/")[1]) ? "Use owner/repo, for example my-org/web-app" : ""
    }
    function nsError(s) {
        return (s.length <= 63 && /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(s)) ? "" : "Lowercase letters, digits and '-' (a Kubernetes namespace)"
    }
    function contextError(s) {
        return /^[A-Za-z0-9][A-Za-z0-9._:\/@=+,~#-]{0,252}$/.test(s) ? "" : "Not a valid context name"
    }

    // field -> message, for what is wrong right now (own checks + the backend's last answer)
    readonly property var errors: {
        rev
        var out = {}
        var seen = {}, i, v
        for (i = 0; i < targetsModel.count; i++) {
            var o = String(targetsModel.get(i).organization).trim(), p = String(targetsModel.get(i).project).trim()
            if (o === "" && p === "") continue
            var eo = orgError(o), ep = projectError(p)
            if (eo) out["azureDevOps.targets." + i + ".organization"] = eo
            if (ep) out["azureDevOps.targets." + i + ".project"] = ep
            if (!eo && !ep) {
                var key = o.replace(/\/+$/, "").toLowerCase() + "|" + p.toLowerCase()
                if (seen[key]) out["azureDevOps.targets." + i] = "Listed twice"
                seen[key] = true
            }
        }
        seen = {}
        for (i = 0; i < reposModel.count; i++) {
            v = String(reposModel.get(i).value).trim()
            if (v === "") continue
            var er = repoError(v)
            if (er) out["github.repos." + i] = er
            else if (seen[v.toLowerCase()]) out["github.repos." + i] = "Listed twice"
            else seen[v.toLowerCase()] = true
        }
        if (targetsModel.count > maxTargets) out["azureDevOps.targets"] = "At most " + maxTargets + " targets"
        if (nsPending.trim() !== "") out["kubernetes.namespaces.add"] = "Press Enter to add it, or clear the box"
        if (exPending.trim() !== "") out["kubernetes.excludeNamespaces.add"] = "Press Enter to add it, or clear the box"
        var srv = service ? service.editErrors : null
        if (srv) for (var f in srv) if (out[f] === undefined) out[f] = String(srv[f])
        return out
    }
    readonly property int errorCount: { var n = 0; for (var k in errors) n++; return n }
    readonly property bool dirty: { rev; return JSON.stringify(collect()) !== original }
    readonly property int changedGroups: {
        rev
        var a = JSON.parse(original || "{}"), b = collect(), n = 0
        function differs(x, y) { return JSON.stringify(x) !== JSON.stringify(y) }
        if (differs(a.azureDevOps, b.azureDevOps)) n++
        if (differs(a.github, b.github)) n++
        if (differs(a.kubernetes ? [a.kubernetes.contexts, a.kubernetes.allContexts] : 0, [b.kubernetes.contexts, b.kubernetes.allContexts])) n++
        if (differs(a.kubernetes ? [a.kubernetes.namespaces, a.kubernetes.excludeNamespaces] : 0, [b.kubernetes.namespaces, b.kubernetes.excludeNamespaces])) n++
        if (differs(a.development ? a.development.mockData : false, b.development.mockData)) n++
        return n
    }
    function err(field) { return errors[field] || "" }

    readonly property string editState: service ? service.editState : "idle"
    readonly property bool inReview: editState === "review" || editState === "nochange" || editState === "saving"
                                     || editState === "saved" || editState === "error" || editState === "previewing"

    function toggleContext(name) {
        var cur = ctxSelected.slice(), at = cur.indexOf(name)
        if (at >= 0) cur.splice(at, 1)
        else if (cur.length < maxContexts) cur.push(name)
        ctxSelected = cur
        rev++
    }
    function addNamespace(model, pendingProp, field, text) {
        var s = String(text).trim()
        if (s === "") return ""
        var e = nsError(s)
        if (e) return e
        if (_values(model, "value").indexOf(s) >= 0) return "Listed twice"
        if (model.count >= maxNamespaces) return "At most " + maxNamespaces + " namespaces"
        model.append({ value: s })
        rev++
        return ""
    }

    function review() {
        if (errorCount > 0 || !dirty || !service) return
        service.previewConfigEdit(collect())
    }
    function discard() {
        if (service) service.resetConfigEdit()
        load()
        closed()
    }
    function save() { if (service) service.applyConfigEdit() }
    function backToForm() {
        if (service) service.resetConfigEdit()
        rev++
    }

    Component.onCompleted: load()

    // When the backend rejects a value the form is shown again with its message.
    // The message belongs to the draft that was sent: the next edit clears it, so
    // a corrected field is never held back by an old answer.
    onRevChanged: { if (service && service.editState === "invalid") service.resetConfigEdit() }
    // After a successful save the editor closes; the panel shows the new values.
    Timer {
        id: closeSoon
        interval: 900
        onTriggered: { if (root.service) root.service.resetConfigEdit(); root.closed() }
    }
    Connections {
        target: root.service
        function onEditStateChanged() { if (root.service.editState === "saved") closeSoon.restart() }
    }

    // ── Pieces ───────────────────────────────────────────────────────────────
    component Caption: Text {
        color: root.textColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        opacity: 0.4
    }

    component Hint: Text {
        width: parent ? parent.width : 0
        wrapMode: Text.WordWrap
        color: root.textColor
        opacity: 0.45
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }

    component Problem: Text {
        property string message: ""
        visible: message !== ""
        width: parent ? parent.width : 0
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: message
        color: root.bad
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
    }

    // A single-line text box.
    component Field: Rectangle {
        id: field
        property alias text: input.text
        property string placeholder: ""
        property bool invalid: false
        property int limit: 200
        signal edited()
        signal accepted()
        property alias input: input
        height: Style.space(26)
        radius: Style.space(4)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.06)
        border.width: 1
        border.color: invalid ? root.bad : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, input.activeFocus ? 0.5 : 0.22)
        clip: true
        TextInput {
            id: input
            objectName: "fieldInput"
            anchors.fill: parent
            anchors.leftMargin: Style.space(7)
            anchors.rightMargin: Style.space(7)
            verticalAlignment: TextInput.AlignVCenter
            color: root.textColor
            selectionColor: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            maximumLength: field.limit
            selectByMouse: true
            onTextEdited: field.edited()
            onAccepted: field.accepted()
        }
        Text {
            visible: input.text === "" && !input.activeFocus
            anchors.fill: input
            verticalAlignment: Text.AlignVCenter
            text: field.placeholder
            textFormat: Text.PlainText
            color: root.textColor
            opacity: 0.3
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
        }
    }

    // Small round "x" (remove) and text buttons.
    component IconButton: Rectangle {
        id: ib
        property string glyph: "×"
        signal clicked()
        width: Style.space(24); height: Style.space(24)
        radius: width / 2
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, ibArea.containsMouse ? 0.16 : 0.0)
        Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: ib.glyph
            color: root.textColor
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }
        MouseArea { id: ibArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: ib.clicked() }
    }

    component Button: Rectangle {
        id: btn
        property string label: ""
        property bool primary: false
        property bool enabledButton: true
        signal clicked()
        width: btnText.implicitWidth + Style.space(22)
        height: Style.space(28)
        radius: Style.space(5)
        opacity: enabledButton ? 1.0 : 0.4
        color: primary ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, btnArea.containsMouse && enabledButton ? 0.40 : 0.28)
                       : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, btnArea.containsMouse && enabledButton ? 0.14 : 0.06)
        border.width: 1
        border.color: primary ? root.accent : Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.25)
        Text {
            id: btnText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: btn.label
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: btn.primary
        }
        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: btn.enabledButton ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: { if (btn.enabledButton) btn.clicked() }
        }
    }

    component Card: Rectangle {
        id: card
        default property alias content: inner.data
        width: parent ? parent.width : 0
        implicitHeight: inner.implicitHeight + Style.space(20)
        height: implicitHeight
        radius: Style.space(6)
        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.04)
        border.width: 1
        border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.22)
        Column {
            id: inner
            x: Style.space(10); y: Style.space(10)
            width: card.width - Style.space(20)
            spacing: Style.space(6)
        }
    }

    // Chips (with an "x") + an "add" box for a list of namespaces.
    component NsEditor: Column {
        id: ns
        property string label: ""
        property var model: null
        property color chipColor: root.accent
        property string field: ""          // "kubernetes.namespaces"
        property string pendingText: ""
        signal pendingChanged(string text)
        property string localError: ""
        width: parent ? parent.width : 0
        spacing: Style.space(4)

        Text {
            text: ns.label
            color: root.textColor
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }
        Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
                model: ns.model
                delegate: Rectangle {
                    width: chipText.implicitWidth + chipX.width + Style.space(12)
                    height: Style.space(24)
                    radius: Style.space(5)
                    color: Qt.rgba(ns.chipColor.r, ns.chipColor.g, ns.chipColor.b, 0.16)
                    border.width: 1
                    border.color: Qt.rgba(ns.chipColor.r, ns.chipColor.g, ns.chipColor.b, 0.30)
                    Text {
                        id: chipText
                        x: Style.space(8)
                        anchors.verticalCenter: parent.verticalCenter
                        textFormat: Text.PlainText
                        text: model.value
                        color: ns.chipColor
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                    }
                    IconButton {
                        id: chipX
                        objectName: "removeNamespace"
                        x: parent.width - width - Style.space(2)
                        anchors.verticalCenter: parent.verticalCenter
                        width: Style.space(20); height: Style.space(20)
                        onClicked: { ns.model.remove(index); root.rev++ }
                    }
                }
            }
        }
        Field {
            id: addBox
            objectName: "addNamespace"
            width: parent.width
            placeholder: "Add a namespace and press Enter"
            limit: 63
            invalid: ns.localError !== "" || root.err(ns.field + ".add") !== ""
            onEdited: { ns.localError = ""; ns.pendingChanged(text) }
            onAccepted: {
                var e = root.addNamespace(ns.model, "", ns.field, text)
                ns.localError = e
                if (e === "") { text = ""; ns.pendingChanged("") }
            }
        }
        Problem { message: ns.localError !== "" ? ns.localError : root.err(ns.field + ".add") }
        Repeater {
            model: ns.model
            delegate: Problem { message: root.err(ns.field + "." + index) }
        }
    }

    // ── The form ─────────────────────────────────────────────────────────────
    Column {
        id: form
        width: parent.width
        spacing: Style.space(12)
        visible: !root.inReview

        Text {
            objectName: "editorIntro"
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Changes stay here until you press “Review & save”. Nothing is written before that."
            color: root.textColor
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
        }

        Text {
            objectName: "editorBackendError"
            visible: root.editState === "invalid"
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Some values were not accepted. Fix the marked fields and try again."
            color: root.bad
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
        }

        // Azure DevOps
        Card {
            Caption { text: "AZURE DEVOPS TARGETS" }
            Repeater {
                model: targetsModel
                delegate: Column {
                    width: parent.width
                    spacing: Style.space(3)
                    Row {
                        width: parent.width
                        spacing: Style.space(4)
                        Column {
                            width: parent.width - Style.space(28)
                            spacing: Style.space(4)
                            Field {
                                objectName: "targetOrganization"
                                width: parent.width
                                placeholder: "https://dev.azure.com/my-org"
                                invalid: root.err("azureDevOps.targets." + index + ".organization") !== ""
                                Component.onCompleted: text = model.organization
                                onEdited: { targetsModel.setProperty(index, "organization", text); root.rev++ }
                            }
                            Problem { message: root.err("azureDevOps.targets." + index + ".organization") }
                            Field {
                                objectName: "targetProject"
                                width: parent.width
                                placeholder: "Project name"
                                limit: 64
                                invalid: root.err("azureDevOps.targets." + index + ".project") !== ""
                                Component.onCompleted: text = model.project
                                onEdited: { targetsModel.setProperty(index, "project", text); root.rev++ }
                            }
                            Problem { message: root.err("azureDevOps.targets." + index + ".project") }
                            Problem { message: root.err("azureDevOps.targets." + index) }
                        }
                        IconButton {
                            objectName: "removeTarget"
                            onClicked: { targetsModel.remove(index); root.rev++ }
                        }
                    }
                    Rectangle {
                        visible: index < targetsModel.count - 1
                        width: parent.width; height: 1
                        color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.10)
                    }
                }
            }
            Problem { message: root.err("azureDevOps.targets") }
            Button {
                objectName: "addTarget"
                label: "+ Add target"
                enabledButton: targetsModel.count < root.maxTargets
                onClicked: { targetsModel.append({ organization: "", project: "" }); root.rev++ }
            }
        }

        // Kubernetes contexts
        Card {
            Caption { text: "KUBERNETES CONTEXTS" }
            Row {
                spacing: Style.space(8)
                Rectangle {
                    objectName: "allContextsBox"
                    width: Style.space(16); height: Style.space(16); radius: Style.space(3)
                    color: root.allContexts ? root.accent : "transparent"
                    border.width: 1
                    border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
                    anchors.verticalCenter: parent.verticalCenter
                    Text { anchors.centerIn: parent; visible: root.allContexts; text: "✓"; textFormat: Text.PlainText; color: "black"; font.pixelSize: Style.font.caption }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.allContexts = !root.allContexts; root.rev++ } }
                }
                Text {
                    text: "All contexts in kubeconfig"
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Hint {
                visible: !root.allContexts && root.ctxSelected.length === 0
                text: "None selected: the current kubectl context is used."
            }
            Hint {
                visible: root.service && root.service.kubeContexts.state === "loading"
                text: "Reading your kubectl contexts…"
            }
            Problem {
                message: (root.service && root.service.kubeContexts.state === "error")
                         ? "Could not list your kubectl contexts (" + root.service.kubeContexts.error + ")" : ""
            }
            Column {
                visible: !root.allContexts
                width: parent.width
                spacing: Style.space(2)
                Repeater {
                    // kubectl's contexts, plus any selected one kubectl no longer lists
                    model: {
                        root.rev
                        var names = root.service ? root.service.kubeContexts.names.slice() : []
                        for (var i = 0; i < root.ctxSelected.length; i++)
                            if (names.indexOf(root.ctxSelected[i]) < 0) names.push(root.ctxSelected[i])
                        return names
                    }
                    delegate: Row {
                        spacing: Style.space(8)
                        readonly property bool picked: { root.rev; return root.ctxSelected.indexOf(modelData) >= 0 }
                        Rectangle {
                            objectName: "contextBox"
                            width: Style.space(16); height: Style.space(16); radius: Style.space(3)
                            color: picked ? root.accent : "transparent"
                            border.width: 1
                            border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
                            anchors.verticalCenter: parent.verticalCenter
                            Text { anchors.centerIn: parent; visible: picked; text: "✓"; textFormat: Text.PlainText; color: "black"; font.pixelSize: Style.font.caption }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleContext(modelData) }
                        }
                        Text {
                            width: form.width - Style.space(60)
                            textFormat: Text.PlainText
                            text: modelData
                            elide: Text.ElideMiddle
                            color: root.contextError(modelData) === "" ? root.accent : root.bad
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
            Problem { message: root.err("kubernetes.contexts") }
        }

        // Kubernetes namespaces
        Card {
            Caption { text: "KUBERNETES NAMESPACES" }
            NsEditor {
                label: "Included (empty = all namespaces)"
                model: nsModel
                field: "kubernetes.namespaces"
                chipColor: root.accent
                onPendingChanged: function(t) { root.nsPending = t }
            }
            NsEditor {
                label: "Excluded (always ignored)"
                model: exModel
                field: "kubernetes.excludeNamespaces"
                chipColor: "#f38ba8"
                onPendingChanged: function(t) { root.exPending = t }
            }
        }

        // GitHub
        Card {
            Caption { text: "GITHUB REPOSITORIES" }
            Repeater {
                model: reposModel
                delegate: Column {
                    width: parent.width
                    spacing: Style.space(3)
                    Row {
                        width: parent.width
                        spacing: Style.space(4)
                        Field {
                            objectName: "repoField"
                            width: parent.width - Style.space(28)
                            placeholder: "owner/repo"
                            limit: 140
                            invalid: root.err("github.repos." + index) !== ""
                            Component.onCompleted: text = model.value
                            onEdited: { reposModel.setProperty(index, "value", text); root.rev++ }
                        }
                        IconButton {
                            objectName: "removeRepo"
                            onClicked: { reposModel.remove(index); root.rev++ }
                        }
                    }
                    Problem { message: root.err("github.repos." + index) }
                }
            }
            Problem { message: root.err("github.repos") }
            Button {
                objectName: "addRepo"
                label: "+ Add repository"
                enabledButton: reposModel.count < root.maxRepos
                onClicked: { reposModel.append({ value: "" }); root.rev++ }
            }
        }

        // Development
        Card {
            Caption { text: "DEVELOPMENT" }
            Row {
                spacing: Style.space(8)
                Rectangle {
                    objectName: "mockDataBox"
                    width: Style.space(16); height: Style.space(16); radius: Style.space(3)
                    color: root.mockData ? root.accent : "transparent"
                    border.width: 1
                    border.color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.5)
                    anchors.verticalCenter: parent.verticalCenter
                    Text { anchors.centerIn: parent; visible: root.mockData; text: "\u2713"; textFormat: Text.PlainText; color: "black"; font.pixelSize: Style.font.caption }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.mockData = !root.mockData; root.rev++ } }
                }
                Text {
                    text: "Use mock data (demo data)"
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Hint { text: "development.mockData: the three providers show sample data from the mock/ files and never call az, kubectl or gh. Turn it off to see your real services." }
        }

        // Bottom bar
        Card {
            Row {
                width: parent.width
                spacing: Style.space(8)
                Text {
                    objectName: "editorStatus"
                    width: parent.width - discardBtn.width - reviewBtn.width - Style.space(16)
                    anchors.verticalCenter: parent.verticalCenter
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: !root.dirty ? "No changes yet"
                          : (root.changedGroups === 1 ? "1 section changed" : root.changedGroups + " sections changed")
                            + (root.errorCount > 0 ? " · " + (root.errorCount === 1 ? "1 field needs attention" : root.errorCount + " fields need attention") : "")
                    color: root.errorCount > 0 ? root.bad : root.textColor
                    opacity: root.dirty ? 0.85 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                }
                Button { id: discardBtn; objectName: "discardEdits"; label: root.dirty ? "Discard" : "Close"; onClicked: root.discard() }
                Button {
                    id: reviewBtn
                    objectName: "reviewSave"
                    label: "Review & save"
                    primary: true
                    enabledButton: root.dirty && root.errorCount === 0
                    onClicked: root.review()
                }
            }
        }
    }

    // ── Review / result ──────────────────────────────────────────────────────
    Card {
        objectName: "reviewCard"
        visible: root.inReview

        Caption { text: "REVIEW CHANGES" }

        Text {
            objectName: "reviewStatus"
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            color: root.editState === "error" ? root.bad : root.textColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            text: root.editState === "previewing" ? "Checking the values…"
                : root.editState === "nochange" ? "Nothing would change."
                : root.editState === "saving" ? "Saving…"
                : root.editState === "saved" ? "Saved. The providers are refreshing with the new settings."
                : root.editState === "error" ? "Could not continue: " + (root.service ? root.service.editError : "")
                : "These lines of config.json will change. The previous content is kept as config.json.bak."
        }

        Column {
            visible: root.editState === "review" || root.editState === "saving"
            width: parent.width
            spacing: 1
            Repeater {
                model: root.service ? root.service.editPreview.diff : []
                delegate: Rectangle {
                    width: parent.width
                    height: diffText.implicitHeight + 2
                    color: modelData.t === "+" ? Qt.rgba(0.3, 0.8, 0.3, 0.14) : modelData.t === "-" ? Qt.rgba(0.88, 0.31, 0.31, 0.16) : "transparent"
                    Text {
                        id: diffText
                        objectName: "diffLine"
                        x: Style.space(4)
                        width: parent.width - Style.space(8)
                        textFormat: Text.PlainText
                        text: modelData.t + " " + modelData.s
                        elide: Text.ElideRight
                        color: modelData.t === "+" ? "#4ec94e" : modelData.t === "-" ? "#e05050" : root.textColor
                        opacity: modelData.t === " " ? 0.55 : 1.0
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }
        Hint {
            visible: root.service && root.service.editPreview.truncated && root.editState === "review"
            text: "Only the first lines are shown here."
        }
        Hint {
            visible: root.service && root.service.editPreview.reformat && root.editState === "review"
            text: "The file will also be re-formatted (2-space JSON); your other settings are kept as they are."
        }

        Row {
            spacing: Style.space(8)
            Button {
                objectName: "backToForm"
                label: root.editState === "saved" ? "Close" : "Back"
                enabledButton: root.editState !== "saving" && root.editState !== "previewing"
                onClicked: { if (root.editState === "saved") { closeSoon.stop(); root.service.resetConfigEdit(); root.closed() } else root.backToForm() }
            }
            Button {
                objectName: "confirmSave"
                visible: root.editState === "review"
                label: "Save"
                primary: true
                onClicked: root.save()
            }
        }
    }
}
