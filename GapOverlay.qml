// GapOverlay.qml — one transparent layer-shell surface per monitor.
//
// The surface covers the whole output but its input mask is only the measured
// gap corridors, so everywhere else it stays click-through and never steals a
// click from the windows below. Moving the pointer into a real gap reveals a
// theme-accent rail with a bidirectional resize cursor; dragging it resizes
// the adjacent tiles through the service.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons

PanelWindow {
    id: overlay

    // Injected by the Variants delegate in Service.qml.
    required property var modelData

    // The owning service, for geometry and resize dispatch.
    property var service: null

    readonly property var monitor: Hyprland.monitorFor(modelData)
    readonly property color railColor: Color.accent

    // Current rails (monitor-local rectangles) and their last fingerprint.
    property var rails: []
    property string railsKey: ""
    property var liveRegions: []

    screen: modelData
    color: "transparent"
    aboveWindows: true
    focusable: false
    // Span the full output without reserving any space.
    exclusiveZone: -1
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "io.github.jayrx24.tile-drag-resize"

    // Only the gap rectangles accept input.
    mask: inputMask

    Region { id: inputMask }
    Component { id: regionFactory; Region {} }

    function anyDragging() {
        for (var i = 0; i < railRepeater.count; i++) {
            var item = railRepeater.itemAt(i);
            if (item && item.dragging) return true;
        }
        return false;
    }

    // Recompute rails for this monitor, skipping while a drag is in progress
    // (geometry churns during the resize and would make the rail jump).
    function refreshRails() {
        if (anyDragging()) return;
        var next = service ? service.railsFor(monitor) : [];
        var key = JSON.stringify(next);
        if (key === railsKey) return;
        railsKey = key;
        rails = next;
    }

    // Rebuild the input mask to match the current rails.
    //
    // `regions` is a read-only list property: it can only be appended to or
    // popped, never assigned. Appending notifies the compositor, but destroying
    // a child drops it from the region silently, so the list is emptied
    // explicitly and `changed()` is emitted to force a recompute even when the
    // new rail set is empty.
    function rebuildMask() {
        for (var i = 0; i < liveRegions.length; i++) {
            if (liveRegions[i]) liveRegions[i].destroy();
        }
        liveRegions = [];
        while (inputMask.regions.length > 0) inputMask.regions.pop();

        var created = [];
        for (var j = 0; j < rails.length; j++) {
            var rail = rails[j];
            var region = regionFactory.createObject(null, {
                x: Math.round(rail.x),
                y: Math.round(rail.y),
                width: Math.round(rail.w),
                height: Math.round(rail.h)
            });
            if (region) {
                inputMask.regions.push(region);
                created.push(region);
            }
        }
        liveRegions = created;
        inputMask.changed();
    }

    onRailsChanged: rebuildMask()

    // The service bumps layoutEpoch on every compositor event and on its
    // fallback timer.
    Connections {
        target: overlay.service
        function onLayoutEpochChanged() { overlay.refreshRails() }
    }

    Component.onCompleted: {
        refreshRails();
        Qt.callLater(rebuildMask);
    }

    // One delegate per rail: a thin highlight plus a drag handle.
    Repeater {
        id: railRepeater
        model: overlay.rails

        delegate: Item {
            id: rail
            required property var modelData

            readonly property bool vertical: modelData.orientation === "vertical"
            property bool dragging: false
            property real lastX: 0
            property real lastY: 0

            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h

            Rectangle {
                anchors.fill: parent
                color: overlay.railColor
                opacity: rail.dragging ? 0.5 : (handle.containsMouse ? 0.82 : 0)
                Behavior on opacity { NumberAnimation { duration: 80 } }
            }

            MouseArea {
                id: handle
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: rail.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor

                onPressed: function(mouse) {
                    rail.dragging = true;
                    rail.lastX = mouse.x;
                    rail.lastY = mouse.y;
                }

                onPositionChanged: function(mouse) {
                    if (!rail.dragging || !overlay.service) return;
                    var dx = rail.vertical ? Math.round(mouse.x - rail.lastX) : 0;
                    var dy = rail.vertical ? 0 : Math.round(mouse.y - rail.lastY);
                    rail.lastX = mouse.x;
                    rail.lastY = mouse.y;
                    var factor = modelData.resizeFactor || 1;
                    overlay.service.resizeWindow(modelData.resizeAddress, dx * factor, dy * factor);
                }

                onReleased: rail.dragging = false
                onCanceled: rail.dragging = false
            }
        }
    }
}
