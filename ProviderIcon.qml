import QtQuick
import qs.Commons

// Provider mark shown before a provider's name on the Status tab.
//
// Looks for an optional image at  assets/<iconName>.svg  (or .png) inside
// the plugin folder and shows it; if the file is not there (or cannot be
// decoded) it falls back to a coloured text glyph. The glyphs used by the
// panel (see Panel.qml) are plain Unicode characters that exist in the
// main JetBrains Mono / DejaVu Sans Mono fonts, so they do not depend on
// fallback fonts or Nerd Fonts. The plugin does not ship any third-party
// logo: drop your own file(s) in assets/ (see docs/setup.md). Any future
// provider can reuse this component.
Item {
    id: root

    property string iconName: ""          // e.g. "azure-devops", "kubernetes"
    property string glyph: "*"            // fallback when there is no image
    property color fallbackColor: "white"
    property var fontFamily: Style.font.family

    readonly property int _size: Style.space(16)
    width: _size
    height: _size

    // Try .svg first, then .png.
    Image {
        id: svgImage
        anchors.fill: parent
        visible: status === Image.Ready
        source: root.iconName ? Qt.resolvedUrl("assets/" + root.iconName + ".svg") : ""
        sourceSize: Qt.size(root._size * 2, root._size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: false
        cache: true
    }

    Image {
        id: pngImage
        anchors.fill: parent
        visible: svgImage.status !== Image.Ready && status === Image.Ready
        source: (svgImage.status === Image.Error && root.iconName)
            ? Qt.resolvedUrl("assets/" + root.iconName + ".png") : ""
        sourceSize: Qt.size(root._size * 2, root._size * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: false
        cache: true
    }

    Text {
        anchors.centerIn: parent
        visible: svgImage.status !== Image.Ready && pngImage.status !== Image.Ready
        textFormat: Text.PlainText
        text: root.glyph
        color: root.fallbackColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
    }
}
