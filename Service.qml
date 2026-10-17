// Service.qml — the combined "Tile Drag & Resize" service.
//
// One headless service owns both halves of the plugin:
//
//   1. Gap resize. A transparent layer-shell overlay is drawn on every monitor.
//      Only the measured gaps between tiled windows accept pointer input; the
//      rest of the surface stays click-through. Dragging a gap resizes the
//      window on one side of it through Hyprland.
//
//   2. Middle-button drag. Toggling the feature binds `mouse:274` to Hyprland's
//      window-drag dispatcher so a middle click drags any window. The on/off
//      state is persisted and re-applied after config reloads.
//
// Both features live here so the plugin is a single unit: one manifest, one
// service, one bar widget.

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "GapGeometry.js" as GapGeometry

Item {
    id: root

    // Injected by omarchy-shell when the plugin is a third-party service.
    property var shell: null
    property var manifest: null

    // ------------------------------------------------------------ gap tuning
    // Gaps thicker than this are ignored, so a wide empty space is never
    // mistaken for a split. Very short overlaps are ignored for the same
    // reason. Touching edges (and compositor rounding noise) fall below the
    // floor and produce no rail.
    readonly property int gapCeiling: 56
    readonly property int overlapFloor: 24
    readonly property int gapFloor: 2

    // Bumped on every layout refresh. Read from railsFor() so the overlays can
    // react to a change without re-deriving geometry themselves.
    property int layoutEpoch: 0

    // ------------------------------------------------------------- drag state
    readonly property string dragButton: "mouse:274"
    readonly property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/tile-drag-resize/enabled"

    readonly property string unbindScript: 'hl.unbind("' + dragButton + '")'
    readonly property string bindScript: unbindScript
        + '; hl.bind("' + dragButton + '", hl.dsp.window.drag(),'
        + ' { mouse = true, description = "Tile Drag & Resize: move window" })'

    property bool stateReady: false
    property bool dragEnabled: true
    property bool bindPending: false

    // =================================================== gap resize: commands

    // Re-read monitor/workspace/toplevel state and announce a new epoch. The
    // overlay refreshes its rails when the epoch changes.
    function refreshLayout() {
        Hyprland.refreshMonitors();
        Hyprland.refreshWorkspaces();
        Hyprland.refreshToplevels();
        layoutEpoch += 1;
    }

    // Rails (draggable gap rectangles, monitor-local) for one monitor.
    function railsFor(monitor) {
        // Reference the epoch so callers re-derive on every refresh.
        var epoch = layoutEpoch;
        if (!monitor || !monitor.activeWorkspace) return [];
        return GapGeometry.collect(
            monitor.x,
            monitor.y,
            monitor.activeWorkspace.toplevels.values,
            { maxGap: gapCeiling, minOverlap: overlapFloor, minGap: gapFloor }
        );
    }

    // Take over the window edges: Hyprland's own border resize grabs a band
    // around every window, which would fight the gap overlay. Turn it off at
    // runtime (no config file is touched) and restore nothing on exit.
    function suppressNativeResize() {
        Quickshell.execDetached(["hyprctl", "eval",
            "hl.config({ general = { resize_on_border = false, hover_icon_on_border = false } })"]);
        if (!Hyprland.usingLua) {
            Quickshell.execDetached(["hyprctl", "keyword", "general:resize_on_border", "false"]);
            Quickshell.execDetached(["hyprctl", "keyword", "general:hover_icon_on_border", "false"]);
        }
    }

    // Resize a window by a relative amount. On Lua-capable Hyprland we go
    // through the dispatcher API; otherwise the legacy dispatcher.
    function resizeWindow(address, dx, dy) {
        if (!address || (!dx && !dy)) return;
        if (Hyprland.usingLua) {
            Quickshell.execDetached(["hyprctl", "eval",
                'hl.dispatch(hl.dsp.window.resize({ x = ' + dx + ', y = ' + dy
                + ', relative = true, window = "address:' + address + '" }))']);
        } else {
            Quickshell.execDetached(["hyprctl", "dispatch", "resizewindowpixel",
                dx + " " + dy + ",address:" + address]);
        }
    }

    // ============================================== move highlight: inference
    //
    // Middle-dragging a window moves it, but Hyprland emits no drag
    // begin/end event and the shell cannot see the mouse button, so the window
    // being moved is inferred from geometry instead: a drag is a *pure
    // translation*, so we look for a window that keeps changing position while
    // its size stays put. That also excludes the two cases we must NOT light up
    // — a layout change moves windows once (a single sample), and a gap resize
    // changes the size rather than just the position.
    readonly property int movePollMs: 16        // fast poll while a move is suspected
    readonly property int moveGraceMs: 600      // hold the border through a pause
    readonly property int moveEpsilon: 2        // px that count as a change
    readonly property int moveConfirmSamples: 2 // consecutive samples to light up

    property string moveAddress: ""
    property string moveMonitor: ""
    property var moveRect: null
    property bool moveActive: false
    property int moveStreak: 0
    property double moveLastAt: 0
    property var moveRects: ({})
    // How many times the geometry has been sampled; purely diagnostic, and a
    // quick way to spot the poll rate from IPC.
    property int moveSamples: 0

    // `omarchy shell tile-drag-resize preview` pins the border onto one window
    // for a few seconds, so the highlight can be looked at without dragging
    // anything (and so it can be checked from a screenshot).
    property string previewAddress: ""
    property double previewUntil: 0

    // Every mapped window keyed by address, with its monitor name. Floating
    // windows are included: Hyprland can float a window for the duration of a
    // drag, and that window is exactly the one we want to outline.
    function windowSnapshot() {
        var out = ({});
        var screens = GapGeometry.toArray(Quickshell.screens);
        for (var s = 0; s < screens.length; s++) {
            var mon = Hyprland.monitorFor(screens[s]);
            if (!mon || !mon.activeWorkspace) continue;
            var tops = GapGeometry.toArray(mon.activeWorkspace.toplevels.values);
            for (var i = 0; i < tops.length; i++) {
                var r = GapGeometry.windowRect(tops[i], { allowFloating: true });
                if (!r || !r.address) continue;
                out[r.address] = { x: r.x, y: r.y, w: r.w, h: r.h, monitor: mon.name };
            }
        }
        return out;
    }

    function showMove(address, rect) {
        moveAddress = address;
        moveMonitor = rect.monitor;
        moveRect = { x: rect.x, y: rect.y, w: rect.w, h: rect.h };
    }

    function hideMove() {
        moveAddress = "";
        moveMonitor = "";
        moveRect = null;
        moveStreak = 0;
        moveActive = false;
    }

    // Compare this sample against the previous one and decide whether a window
    // is being dragged.
    function sampleMoves() {
        var now = Date.now();
        var snap = windowSnapshot();
        moveSamples += 1;

        // A pinned preview wins for as long as it lasts, and tracks the window
        // live (handy for checking the rendering from a screenshot).
        if (previewAddress !== "" && now < previewUntil) {
            var pinned = snap[previewAddress];
            moveRects = snap;
            if (pinned) {
                showMove(previewAddress, pinned);
                moveActive = true;
                if (!moveWatch.running) moveWatch.start();
                return;
            }
            previewAddress = "";
        } else if (previewAddress !== "") {
            // The preview just expired. Drop its pinned state unless a real
            // drag has taken over the same sample.
            previewAddress = "";
            if (moveStreak === 0) hideMove();
        }

        // The largest pure translation since the previous sample wins. A size
        // change (a resize) or a one-off layout change never qualifies.
        var best = GapGeometry.detectMove(moveRects, snap, moveEpsilon);
        moveRects = snap;

        if (best !== "") {
            moveStreak += 1;
            moveLastAt = now;
            showMove(best, snap[best]);
            if (!moveWatch.running) moveWatch.start();
        } else if (now - moveLastAt > moveGraceMs) {
            // Everything has settled: drop the border and re-derive the rails,
            // which were suppressed while the window was moving.
            if (moveStreak > 0) {
                hideMove();
                refreshLayout();
            }
            if (moveWatch.running) moveWatch.stop();
        }

        moveActive = moveStreak >= moveConfirmSamples && (now - moveLastAt) <= moveGraceMs;
    }

    function previewMove() {
        var snap = windowSnapshot();
        var first = "";
        for (var addr in snap) { first = addr; break; }
        if (!first) return;
        previewAddress = first;
        previewUntil = Date.now() + 8000;
        if (!moveWatch.running) moveWatch.start();
        sampleMoves();
    }

    // ================================================== drag: state and binds

    function persistState(on) {
        Quickshell.execDetached(["sh", "-c",
            'mkdir -p "${1%/*}" && printf "%s\\n" "$2" > "$1"',
            "tile-drag-resize", statePath, on ? "1" : "0"]);
    }

    function setDrag(on) {
        dragEnabled = !!on;
        stateReady = true;
        persistState(dragEnabled);
        applyBind();
    }

    function toggleDrag() {
        setDrag(!dragEnabled);
    }

    // (Re)apply the bind to match the current state. Coalesces bursts: if a
    // call lands mid-apply, one more apply runs when the process exits.
    function applyBind() {
        if (!stateReady) return;
        if (bindProc.running) {
            bindPending = true;
            return;
        }
        bindProc.command = ["hyprctl", "eval", dragEnabled ? bindScript : unbindScript];
        bindProc.running = true;
    }

    // Re-assert everything the runtime owns. Exposed over IPC and used after a
    // Hyprland config reload, which drops runtime settings and binds.
    function reapply() {
        suppressNativeResize();
        applyBind();
    }

    // ============================================================== lifecycle

    Component.onCompleted: {
        suppressNativeResize();
        refreshLayout();
    }

    // Disabling or removing the plugin must hand the middle button back to the
    // applications underneath.
    Component.onDestruction: {
        if (dragEnabled) Quickshell.execDetached(["hyprctl", "eval", unbindScript]);
    }

    // One listener drives both halves: layout events refresh the rails, and a
    // config reload re-asserts the runtime-owned settings and bind.
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            var name = event && event.name ? event.name : "";
            if (name === "workspace" || name === "focusedmon" || name === "openwindow"
                || name === "closewindow" || name === "movewindow" || name === "openlayer"
                || name === "closelayer" || name === "changefloatingmode"
                || name === "activewindow" || name === "monitoradded"
                || name === "monitorremoved" || name === "fullscreen") {
                refreshLayout();
            }
            if (name === "configreloaded") reapply();
        }
    }

    // Fallback refresh for geometry that has no matching event.
    Timer {
        interval: 180
        repeat: true
        running: true
        onTriggered: {
            root.refreshLayout()
            root.sampleMoves()
        }
    }

    // Fast poll while a window looks like it is being dragged, so the border
    // keeps up with the pointer. Started on demand and stopped again once the
    // geometry settles, so an idle shell does no extra IPC traffic.
    Timer {
        id: moveWatch
        interval: root.movePollMs
        repeat: true
        onTriggered: {
            Hyprland.refreshToplevels()
            root.sampleMoves()
        }
    }

    // Applies bind changes to Hyprland, one process at a time.
    Process {
        id: bindProc
        onRunningChanged: {
            if (running || !root.bindPending) return;
            root.bindPending = false;
            root.applyBind();
        }
    }

    // Persisted on/off switch. Missing file means "first run", which starts on.
    FileView {
        id: stateView
        path: root.statePath
        printErrors: false
        onLoaded: {
            root.dragEnabled = String(text()).trim() !== "0";
            root.stateReady = true;
            startupApply.restart();
        }
        onLoadFailed: {
            root.stateReady = true;
            startupApply.restart();
        }
    }

    // A hot reload destroys the old service (which unbinds) immediately before
    // creating this one, so give that detached unbind a moment to land.
    Timer {
        id: startupApply
        interval: 400
        onTriggered: root.applyBind()
    }

    // Reverse-DNS name of the plugin folder, used as the IPC target:
    //   omarchy shell tile-drag-resize toggle
    IpcHandler {
        target: "tile-drag-resize"
        function toggle(): void { root.toggleDrag() }
        function enable(): void { root.setDrag(true) }
        function disable(): void { root.setDrag(false) }
        function status(): string { return root.dragEnabled ? "enabled" : "disabled" }
        function reapply(): void { root.reapply() }
        function preview(): void { root.previewMove() }
        function dragstatus(): string {
            return "moving=" + (root.moveAddress || "-")
                + " active=" + root.moveActive
                + " streak=" + root.moveStreak
                + " tracked=" + Object.keys(root.moveRects).length
                + " samples=" + root.moveSamples
                + " rect=" + (root.moveRect ? JSON.stringify(root.moveRect) : "-")
        }
        function snapshot(): string { return JSON.stringify(root.moveRects) }
    }

    // ============================================================== overlays

    // One transparent overlay per output. The delegate reads modelData (the
    // screen) and reports back to this service for geometry and resizing.
    Variants {
        model: Quickshell.screens

        delegate: Component {
            GapOverlay {
                service: root
            }
        }
    }
}
