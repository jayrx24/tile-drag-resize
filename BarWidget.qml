// BarWidget.qml — the Tile Drag & Resize icon in the Omarchy bar.
//
// The bar builds one widget per monitor but the on/off state lives in the
// service, so every icon reads the same value and they never disagree.
//
//   left click   open the options panel
//   right click  toggle middle-button dragging

import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
    id: widget
    moduleName: "io.github.jayrx24.tile-drag-resize"

    // Filled in lazily; the service can finish loading after the bar does and
    // serviceFor() is not a notifying property.
    property var service: null

    readonly property bool dragOn: widget.service ? widget.service.dragEnabled === true : false
    readonly property bool panelOpen: panelLoader.item ? panelLoader.item.opened === true : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

    function wirePanel() {
        if (!panelLoader.item) return
        panelLoader.item.bar = widget.bar
        panelLoader.item.anchorItem = iconButton
        panelLoader.item.hostWidget = widget
        panelLoader.item.service = widget.service
    }

    function findService() {
        if (widget.service) return
        var host = widget.bar ? widget.bar.shell : null
        widget.service = host && typeof host.serviceFor === "function"
            ? host.serviceFor(widget.moduleName) : null
    }

    onBarChanged: {
        findService()
        wirePanel()
    }
    onServiceChanged: wirePanel()
    Component.onCompleted: findService()

    implicitWidth: iconButton.implicitWidth
    implicitHeight: iconButton.implicitHeight

    // Keep polling until the service shows up.
    Timer {
        interval: 500
        repeat: true
        running: widget.service === null
        onTriggered: widget.findService()
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            widget.wirePanel()
            Qt.callLater(widget.wirePanel)
        }
    }

    BarIconButton {
        id: iconButton
        anchors.fill: parent
        bar: widget.bar
        // nf-md-mouse / nf-md-mouse_off
        text: widget.dragOn ? "\u{F037D}" : "\u{F037E}"
        slotSize: Style.bar.statusSlot
        active: widget.dragOn || widget.panelOpen
        useActiveColor: true
        tooltipText: widget.dragOn
            ? "Tile Drag & Resize on: middle-drag moves windows \u2014 click for options, right-click to turn off"
            : "Tile Drag & Resize off: click for options, right-click to turn on"
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton) {
                if (widget.service) widget.service.toggleDrag()
            } else if (buttonCode === Qt.LeftButton) {
                widget.togglePanel()
            }
        }
    }
}
