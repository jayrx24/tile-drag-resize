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

    // Rectangle (monitor-local) of the window currently being dragged with the
    // middle button, or null. The service infers the drag from geometry alone;
    // see the move-highlight section of Service.qml.
    readonly property var moveFrame: {
        var r = service ? service.moveRect : null;
        if (!r || !service.moveActive) return null;
        if (!monitor || service.moveMonitor !== monitor.name) return null;
        return { x: r.x - monitor.x, y: r.y - monitor.y, w: r.w, h: r.h };
    }

    // ---- lightbar colour state --------------------------------------------
    //
    // Every lit rail shares one wave phase so the whole bar scrolls together
    // instead of each rail picking its own timing. `litRails` gates the
    // animation: an idle shell does no per-frame colour work.
    //
    // One full colour cycle takes `wavePeriod`; lower is faster.
    readonly property int wavePeriod: 3000

    property real wavePhase: 0
    property int litRails: 0

    NumberAnimation {
        target: overlay
        property: "wavePhase"
        from: 0
        to: 1
        duration: overlay.wavePeriod
        loops: Animation.Infinite
        running: overlay.litRails > 0 || overlay.moveFrame !== null
    }

    // Colour of the lightbar at `along`, which runs 0..1 from one end of the
    // bar to the other; `alpha` is baked in.
    //
    // Sampling a periodic ramp that is *offset* by the wave phase is what makes
    // the colours travel instead of shifting in place: a point of a given
    // colour moves toward along = 1 as the phase advances, so a vertical split
    // scrolls up/down and a horizontal split scrolls side to side.
    function lightColor(along, alpha) {
        var u = along - overlay.wavePhase;
        u = u - Math.floor(u);
        var base = Color.accent;
        var hue = base.hslHue + u;
        hue = hue - Math.floor(hue);
        var sat = Math.max(0.5, Math.min(1.0, base.hslSaturation));
        var lit = Math.max(0.55, Math.min(0.78, base.hslLightness + 0.05));
        return Qt.hsla(hue, sat, lit, alpha === undefined ? 1 : alpha);
    }

    // Colour at a point on the moving-window border. `p0` and `p1` are the
    // perimeter fractions at the two ends of one edge and `t` runs 0..1 along
    // it, so all four edges share one continuous ramp: the wave travels around
    // the window instead of restarting in every corner.
    function moveColor(p0, p1, t) {
        return lightColor(p0 + (p1 - p0) * t, 0.95);
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
        // While a window is being dragged around, the layout underneath is in
        // flux. Leave the rails alone so the gap lightbars do not flicker; the
        // service refreshes them again once the drag settles.
        if (service && service.moveActive) return;
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

                // The bar proper: a scrolling colour ramp running from end to
                // end. It is sampled at many stops because QML interpolates
                // gradients in RGB, not in hue: adjacent stops have to stay
                // within ~30 degrees of each other or the gaps between them
                // read as muddy grey bands.
                Rectangle {
                    anchors.fill: parent
                    radius: Math.min(width, height) / 2
                    gradient: Gradient {
                        orientation: rail.vertical ? Gradient.Vertical : Gradient.Horizontal
                        GradientStop { position: 0.000; color: overlay.lightColor(0.000, 0.92) }
                        GradientStop { position: 0.091; color: overlay.lightColor(0.091, 0.92) }
                        GradientStop { position: 0.182; color: overlay.lightColor(0.182, 0.92) }
                        GradientStop { position: 0.273; color: overlay.lightColor(0.273, 0.92) }
                        GradientStop { position: 0.364; color: overlay.lightColor(0.364, 0.92) }
                        GradientStop { position: 0.455; color: overlay.lightColor(0.455, 0.92) }
                        GradientStop { position: 0.545; color: overlay.lightColor(0.545, 0.92) }
                        GradientStop { position: 0.636; color: overlay.lightColor(0.636, 0.92) }
                        GradientStop { position: 0.727; color: overlay.lightColor(0.727, 0.92) }
                        GradientStop { position: 0.818; color: overlay.lightColor(0.818, 0.92) }
                        GradientStop { position: 0.909; color: overlay.lightColor(0.909, 0.92) }
                        GradientStop { position: 1.000; color: overlay.lightColor(1.000, 0.92) }
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

    // A thin lightbar border around the tile being dragged with the middle
    // button, in the same colours as the gap bars. The perimeter is walked
    // clockwise from the top-left corner, so the four edges pick up one shared
    // colour ramp and the wave flows around the window.
    Item {
        id: moveBorder

        x: overlay.moveFrame ? overlay.moveFrame.x : 0
        y: overlay.moveFrame ? overlay.moveFrame.y : 0
        width: overlay.moveFrame ? overlay.moveFrame.w : 0
        height: overlay.moveFrame ? overlay.moveFrame.h : 0
        opacity: overlay.moveFrame ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 110 } }

        readonly property real thickness: 6
        // Corner fractions: the top/bottom edges own `fx`, the sides own `fy`.
        readonly property real perimeter: Math.max(1, 2 * width + 2 * height)
        readonly property real fx: width / perimeter
        readonly property real fy: height / perimeter

        Rectangle {
            x: 0
            y: 0
            width: parent.width
            height: moveBorder.thickness
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.00; color: overlay.moveColor(0, moveBorder.fx, 0.00) }
                GradientStop { position: 0.25; color: overlay.moveColor(0, moveBorder.fx, 0.25) }
                GradientStop { position: 0.50; color: overlay.moveColor(0, moveBorder.fx, 0.50) }
                GradientStop { position: 0.75; color: overlay.moveColor(0, moveBorder.fx, 0.75) }
                GradientStop { position: 1.00; color: overlay.moveColor(0, moveBorder.fx, 1.00) }
            }
        }

        Rectangle {
            x: parent.width - moveBorder.thickness
            y: 0
            width: moveBorder.thickness
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.00; color: overlay.moveColor(moveBorder.fx, moveBorder.fx + moveBorder.fy, 0.00) }
                GradientStop { position: 0.25; color: overlay.moveColor(moveBorder.fx, moveBorder.fx + moveBorder.fy, 0.25) }
                GradientStop { position: 0.50; color: overlay.moveColor(moveBorder.fx, moveBorder.fx + moveBorder.fy, 0.50) }
                GradientStop { position: 0.75; color: overlay.moveColor(moveBorder.fx, moveBorder.fx + moveBorder.fy, 0.75) }
                GradientStop { position: 1.00; color: overlay.moveColor(moveBorder.fx, moveBorder.fx + moveBorder.fy, 1.00) }
            }
        }

        // Reversed: the bottom edge runs right to left, the left edge bottom to
        // top, so the ramp keeps advancing clockwise around the perimeter.
        Rectangle {
            x: 0
            y: parent.height - moveBorder.thickness
            width: parent.width
            height: moveBorder.thickness
            gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.00; color: overlay.moveColor(2 * moveBorder.fx + moveBorder.fy, moveBorder.fx + moveBorder.fy, 0.00) }
                GradientStop { position: 0.25; color: overlay.moveColor(2 * moveBorder.fx + moveBorder.fy, moveBorder.fx + moveBorder.fy, 0.25) }
                GradientStop { position: 0.50; color: overlay.moveColor(2 * moveBorder.fx + moveBorder.fy, moveBorder.fx + moveBorder.fy, 0.50) }
                GradientStop { position: 0.75; color: overlay.moveColor(2 * moveBorder.fx + moveBorder.fy, moveBorder.fx + moveBorder.fy, 0.75) }
                GradientStop { position: 1.00; color: overlay.moveColor(2 * moveBorder.fx + moveBorder.fy, moveBorder.fx + moveBorder.fy, 1.00) }
            }
        }

        Rectangle {
            x: 0
            y: 0
            width: moveBorder.thickness
            height: parent.height
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.00; color: overlay.moveColor(1, 2 * moveBorder.fx + moveBorder.fy, 0.00) }
                GradientStop { position: 0.25; color: overlay.moveColor(1, 2 * moveBorder.fx + moveBorder.fy, 0.25) }
                GradientStop { position: 0.50; color: overlay.moveColor(1, 2 * moveBorder.fx + moveBorder.fy, 0.50) }
                GradientStop { position: 0.75; color: overlay.moveColor(1, 2 * moveBorder.fx + moveBorder.fy, 0.75) }
                GradientStop { position: 1.00; color: overlay.moveColor(1, 2 * moveBorder.fx + moveBorder.fy, 1.00) }
            }
        }
    }
}
