// GapOverlay.qml — one transparent layer-shell surface per monitor.
//
// The surface covers the whole output but its input mask is only the measured
// gap corridors, so everywhere else it stays click-through and never steals a
// click from the windows below. Moving the pointer into a real gap reveals a
// lightbar with a bidirectional resize cursor; dragging it resizes the
// adjacent tiles through the service, and the lightbar rides along with the
// seam so the highlight tracks the pointer instead of staying behind.

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

    // Current rails (monitor-local rectangles) and their last fingerprint.
    property var rails: []
    property string railsKey: ""
    property var liveRegions: []

    // ---- lightbar colour state --------------------------------------------
    //
    // Every lit rail shares one drifting hue so the whole bar cycles colours
    // together instead of each rail picking its own phase. `litRails` gates the
    // animation: an idle shell does no per-frame colour work.
    property real huePhase: 0
    property int litRails: 0

    NumberAnimation {
        target: overlay
        property: "huePhase"
        from: 0
        to: 1
        duration: 16000
        loops: Animation.Infinite
        running: overlay.litRails > 0
    }

    // A point on the lightbar's colour ramp: `along` runs 0..1 from one end of
    // the bar to the other and `alpha` is baked in. The ramp starts at the
    // theme accent, drifts with the shared phase, and spreads a little across
    // the length so the bar is not a flat slab of one colour.
    function lightColor(along, alpha) {
        var base = Color.accent;
        var hue = base.hslHue + overlay.huePhase + along * 0.12;
        hue = hue - Math.floor(hue);
        var sat = Math.max(0.5, Math.min(1.0, base.hslSaturation));
        var lit = Math.max(0.55, Math.min(0.78, base.hslLightness + 0.05));
        return Qt.hsla(hue, sat, lit, alpha === undefined ? 1 : alpha);
    }

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

    // Recompute rails for this monitor, skipping while a drag is in progress.
    // The geometry churns continuously during a resize and the delegate is
    // already tracking the seam visually, so re-deriving mid-drag would only
    // make the lightbar stutter.
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

    // One delegate per rail: a lightbar plus a drag handle.
    Repeater {
        id: railRepeater
        model: overlay.rails

        delegate: Item {
            id: rail
            required property var modelData

            readonly property bool vertical: modelData.orientation === "vertical"
            property bool dragging: false
            // Pointer travel since the press. The seam follows the pointer, so
            // the lightbar is offset by the same amount and appears to travel
            // with the window edge.
            property real dragTotal: 0
            property real lastX: 0
            property real lastY: 0
            readonly property bool lit: dragging || handle.containsMouse

            // Feeds the shared hue animation; balanced again on teardown.
            onLitChanged: overlay.litRails += lit ? 1 : -1
            Component.onDestruction: if (lit) overlay.litRails -= 1

            // The delegate itself stays where the geometry puts it. Only the
            // artwork below is offset, because a MouseArea that slid along with
            // the bar would move out from under the pointer and the reported
            // deltas would feed back into themselves.
            x: modelData.x
            y: modelData.y
            width: modelData.w
            height: modelData.h

            Item {
                id: art

                x: rail.vertical ? rail.dragTotal : 0
                y: rail.vertical ? 0 : rail.dragTotal
                width: rail.width
                height: rail.height
                opacity: rail.dragging ? 1.0 : (rail.lit ? 0.9 : 0)
                visible: opacity > 0.01
                Behavior on opacity { NumberAnimation { duration: 90 } }

                // Soft spill. A wider wash whose edges fade out, which is what
                // makes the bar read as light rather than as paint.
                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: rail.vertical ? -6 : 0
                    anchors.rightMargin: rail.vertical ? -6 : 0
                    anchors.topMargin: rail.vertical ? 0 : -6
                    anchors.bottomMargin: rail.vertical ? 0 : -6
                    radius: Math.min(width, height) / 2
                    opacity: 0.45
                    gradient: Gradient {
                        orientation: rail.vertical ? Gradient.Horizontal : Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0) }
                        GradientStop { position: 0.5; color: overlay.lightColor(0.5, 0.8) }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0) }
                    }
                }

                // The bar proper: a colour ramp running from end to end.
                Rectangle {
                    anchors.fill: parent
                    radius: Math.min(width, height) / 2
                    gradient: Gradient {
                        orientation: rail.vertical ? Gradient.Vertical : Gradient.Horizontal
                        GradientStop { position: 0.0; color: overlay.lightColor(0.0, 0.92) }
                        GradientStop { position: 0.5; color: overlay.lightColor(0.5, 0.92) }
                        GradientStop { position: 1.0; color: overlay.lightColor(1.0, 0.92) }
                    }
                }

                // The filament: a bright core line down the middle.
                Rectangle {
                    anchors.fill: parent
                    radius: Math.min(width, height) / 2
                    opacity: 0.55
                    gradient: Gradient {
                        orientation: rail.vertical ? Gradient.Horizontal : Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
                        GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.9) }
                        GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
                    }
                }
            }

            MouseArea {
                id: handle
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: rail.vertical ? Qt.SizeHorCursor : Qt.SizeVerCursor

                onPressed: function(mouse) {
                    rail.dragging = true;
                    rail.dragTotal = 0;
                    rail.lastX = mouse.x;
                    rail.lastY = mouse.y;
                }

                onPositionChanged: function(mouse) {
                    if (!rail.dragging || !overlay.service) return;
                    var dx = rail.vertical ? Math.round(mouse.x - rail.lastX) : 0;
                    var dy = rail.vertical ? 0 : Math.round(mouse.y - rail.lastY);
                    rail.lastX = mouse.x;
                    rail.lastY = mouse.y;
                    // The seam travels with the pointer, so the lightbar does
                    // too. The delta needs no per-window sign flip: Hyprland
                    // moves the resized window's split-facing edge by exactly
                    // the requested amount, whichever neighbour it is.
                    rail.dragTotal += rail.vertical ? dx : dy;
                    overlay.service.resizeWindow(modelData.resizeAddress, dx, dy);
                }

                // Re-derive from the real geometry as soon as the drag ends so
                // the bar settles onto the true seam.
                onReleased: {
                    rail.dragging = false;
                    if (overlay.service) overlay.service.refreshLayout();
                }
                onCanceled: rail.dragging = false
            }
        }
    }
}
