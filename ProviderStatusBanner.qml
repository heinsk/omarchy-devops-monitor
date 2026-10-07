import QtQuick
import qs.Commons

// Generic status banner for a DevOps provider (Azure DevOps, Kubernetes,
// and any future provider — GitLab, Bitbucket, etc.). Renders nothing
// when the provider has no error to show.
//
// Two visual states, driven entirely by data from the provider's Python
// script (never hardcoded per provider here):
//  - Missing dependency (errorCode === "missing_dependency"): a distinct
//    amber "install required" indicator naming the missing CLI/tool, via
//    the "dependency" field.
//  - Any other offline error: the generic red error banner, same as
//    before.
//
// Adding a new provider later needs no new banner markup: have its
// script emit the same { status, error, errorCode, dependency } shape
// via emit_error(), then instantiate this component once with that
// provider's data.
Item {
    id: root

    property var providerData: null   // e.g. root.service.kubernetes
    property var fontFamily: Style.font.family

    readonly property bool _hasError: !!providerData
        && providerData.status === "offline"
        && (providerData.error || "") !== ""
    readonly property bool _missingDependency: _hasError
        && providerData.errorCode === "missing_dependency"
        && (providerData.dependency || "") !== ""

    visible: _hasError
    width: parent ? parent.width : 0
    implicitHeight: _hasError ? bannerRow.implicitHeight : 0
    height: implicitHeight

    Row {
        id: bannerRow
        visible: root._hasError
        width: parent.width
        spacing: Style.space(8)
        leftPadding: Style.space(8)

        Text {
            textFormat: Text.PlainText
            text: root._missingDependency ? "⚙" : "⚠"
            color: root._missingDependency ? "#f0c040" : "#e05050"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            textFormat: Text.PlainText
            text: root._missingDependency
                ? ("Install " + (root.providerData.dependency || "") + " to enable this provider"
                   + ((root.providerData.hint || "") !== "" ? " (" + root.providerData.hint + ")" : ""))
                : (root.providerData ? (root.providerData.error || "") : "")
            color: root._missingDependency ? "#f0c040" : "#e05050"
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            width: parent.width - Style.space(32)
            wrapMode: Text.WordWrap
            anchors.verticalCenter: parent.verticalCenter
        }
    }
}
