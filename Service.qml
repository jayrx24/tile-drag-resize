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
import "DispatchQueue.js" as DispatchQueue
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
        root.geometryAt = Date.now();
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

    // ================================================ gap resize: dispatching
    //
    // A resize drag dispatches on every pointer motion, so the cost of the
    // command path matters more than the command: spawning hyprctl per event
    // takes ~3 ms of process time each and forks the shell for every one of
    // them, which is easily enough to leave the window behind the pointer. The
    // command goes over Hyprland's request socket instead — one command per
    // connection, ~0.05 ms — and bursts are absorbed by merging: a drag issues
    // relative resizes, so consecutive ones for the same window simply add up,
    // and only one command is ever in flight.
    //
    // If the socket stops answering, everything falls back to the
    // process-per-command path, which is slow but is what worked before.
    property var dispatchQueue: []
    property bool dispatchBusy: false
    property string dispatchCmd: ""
    property string dispatchReply: ""
    property int dispatchFailures: 0
    property bool dispatchBroken: false

    function queueCommand(entry) {
        if (dispatchBroken) return false;
        dispatchQueue = DispatchQueue.enqueue(dispatchQueue, entry);
        pumpDispatch();
        return true;
    }

    // The wire form of one queued entry. Hyprland's request socket takes one
    // command per connection and no trailing newline, and its Lua API spells
    // its window properties the way the Lua config does.
    function renderCommand(entry) {
        if (entry.kind === "resize") {
            if (Hyprland.usingLua) {
                return "eval hl.dispatch(hl.dsp.window.resize({ x = " + entry.dx + ", y = " + entry.dy
                    + ", relative = true, window = \"address:" + entry.address + "\" }))";
            }
            return "dispatch resizewindowpixel " + entry.dx + " " + entry.dy
                + ",address:" + entry.address;
        }
        if (Hyprland.usingLua) {
            return "eval hl.dispatch(hl.dsp.window.set_prop({ prop = \"" + entry.prop + "\", value = "
                + entry.value + ", window = \"address:" + entry.address + "\" }))";
        }
        return "dispatch setprop " + entry.prop + " " + entry.value + ",address:" + entry.address;
    }

    function pumpDispatch() {
        if (dispatchBusy || dispatchBroken || dispatchQueue.length === 0) return;
        var next = DispatchQueue.take(dispatchQueue);
        dispatchQueue = next.queue;
        if (!next.entry) return;
        dispatchCmd = renderCommand(next.entry);
        dispatchBusy = true;
        dispatchWatch.restart();
        if (dispatchSocket.connected) {
            flushDispatch();
        } else {
            // Connecting; onConnected flushes the queued command.
            dispatchSocket.connected = true;
        }
    }

    // Send and hang up. Hyprland answers each command and closes the connection
    // itself, and its `eval` reply is small enough to arrive together with that
    // close — which Quickshell logs as an error — so the connection is closed
    // from this side the moment the command is out. The reply is not needed:
    // these are fire-and-forget dispatches, and the socket's own write buffer
    // keeps the command intact across the close.
    function flushDispatch() {
        if (dispatchCmd === "") return;
        dispatchSocket.write(dispatchCmd);
        dispatchSocket.flush();
        dispatchCmd = "";
        dispatchSocket.connected = false;
    }

    // A command that never gets out would hold the slot for good, so a few
    // failed connects in a row and the socket is abandoned for good.
    function noteDispatchFailure() {
        if (dispatchSocket.connected) dispatchSocket.connected = false;
        dispatchCmd = "";
        dispatchBusy = false;
        dispatchFailures += 1;
        if (dispatchFailures >= 3) dispatchBroken = true;
        else pumpDispatch();
    }

    function dispatchDiagnostic() {
        return "queue=" + dispatchQueue.length
            + " busy=" + dispatchBusy
            + " failures=" + dispatchFailures
            + " broken=" + dispatchBroken
            + " resize=" + (resizeAddress || "-");
    }

    // Resize a window by a relative amount. The delta is applied in full even
    // when commands are merged: merging is addition.
    function resizeWindow(address, dx, dy) {
        if (!address || (!dx && !dy)) return;
        if (queueCommand({ kind: "resize", address: address, dx: dx, dy: dy })) return;
        if (Hyprland.usingLua) {
            Quickshell.execDetached(["hyprctl", "eval",
                'hl.dispatch(hl.dsp.window.resize({ x = ' + dx + ', y = ' + dy
                + ', relative = true, window = "address:' + address + '" }))']);
        } else {
            Quickshell.execDetached(["hyprctl", "dispatch", "resizewindowpixel",
                dx + " " + dy + ",address:" + address]);
        }
    }

    // ---------------------------------------------- resize: window animation
    //
    // Hyprland animates window size changes (the `windows` animation), and a
    // resize dispatches on every pointer motion, so every command restarts that
    // animation: the edge crawls towards the pointer instead of tracking it,
    // which is what makes a resize feel slow and rubbery.
    //
    // `no_anim` is a per-window *runtime* property, so it is raised for the
    // window being dragged and dropped again on release. No config file is
    // touched, and the property goes away with the window. If the running
    // Hyprland does not know the property, the dispatch is ignored and the
    // resize simply behaves as it did before.
    property string resizeAddress: ""

    function beginResize(address) {
        if (!address || address === resizeAddress) return;
        endResize();
        resizeAddress = address;
        setWindowProp(address, "no_anim", 1, "noanim");
    }

    function endResize() {
        if (resizeAddress === "") return;
        setWindowProp(resizeAddress, "no_anim", 0, "noanim");
        resizeAddress = "";
    }

    function setWindowProp(address, prop, value, legacyName) {
        if (!address) return;
        var name = Hyprland.usingLua ? prop : legacyName;
        if (queueCommand({ kind: "prop", address: address, prop: name, value: value })) return;
        if (Hyprland.usingLua) {
            Quickshell.execDetached(["hyprctl", "eval",
                'hl.dispatch(hl.dsp.window.set_prop({ prop = "' + name + '", value = ' + value
                + ', window = "address:' + address + '" }))']);
        } else {
            Quickshell.execDetached(["hyprctl", "dispatch", "setprop",
                name + " " + value + ",address:" + address]);
        }
    }

    // ============================================== move highlight: inference
    //
    // Middle-dragging a window moves it, but Hyprland emits no drag begin/end
    // event and the shell cannot see the mouse button, so the window being
    // moved is inferred from geometry: a drag is a *pure translation*, so we
    // look for a window that keeps changing position while its size stays put.
    // That also excludes the two cases we must NOT light up — a layout change
    // moves windows once (a single sample), and a gap resize changes the size
    // rather than just the position.
    //
    // Geometry is a good detector and a poor tracker: a geometry sample is only
    // as fresh as the request that produced it, so a border driven by it trails
    // visibly behind the window. The pointer is exact — Hyprland drags a window
    // by keeping the grabbed point under the cursor, so for the whole drag the
    // window's origin is `pointer - grab` — and it is read over Hyprland's
    // request socket, which is the only way to get it (no pointer API, no
    // pointer events). Once the grab offset is known the border is driven
    // straight from the pointer, while geometry keeps running underneath to
    // confirm the window is still following it. That confirmation is also what
    // ends the drag, since no release event exists either: the pointer may
    // wander, but the window has to come with it.
    readonly property int movePollMs: 16        // geometry poll while a move is suspected
    readonly property int moveGraceMs: 600      // hold after motion stops, pointer feed down
    readonly property int moveEpsilon: 2        // px that count as a change
    readonly property int moveConfirmSamples: 2 // consecutive samples to light up
    readonly property int moveLockTol: 20       // px of slip before the lock is doubted
    readonly property int moveLockMisses: 3     // consecutive doubts before dropping
    readonly property int moveFeedMs: 250       // no pointer samples this long = feed lost
    readonly property int moveMaxMs: 20000      // hard stop, so nothing can stick
    readonly property int cursorPollMs: 10      // pointer sample interval while dragging
    readonly property int cursorHistMs: 150     // pointer history kept for alignment

    property string moveAddress: ""
    property string moveMonitor: ""
    property var moveRect: null
    property bool moveActive: false
    property int moveStreak: 0
    property double moveLastAt: 0
    property double moveStartAt: 0
    property var moveRects: ({})
    // How many times the geometry has been sampled; purely diagnostic, and a
    // quick way to spot the poll rate from IPC.
    property int moveSamples: 0

    // Pointer feed. `cursorArmed` is the feed being wanted at all; the socket
    // itself is opened per sample by the pace timer below.
    property string cursorBuf: ""
    property bool cursorArmed: false
    property real cursorX: 0
    property real cursorY: 0
    property double cursorAt: 0
    property var cursorHist: []
    property int cursorSamples: 0
    property int cursorErrors: 0

    // Pointer-locked tracking: while `moveLocked` the border position comes
    // from the pointer, and `moveGrab*` is the offset between the two.
    property bool moveLocked: false
    property real moveGrabX: 0
    property real moveGrabY: 0
    property int moveMiss: 0

    // Why the last drag ended, and what the last geometry sample saw. Kept
    // after the drag so `dragstatus` can explain what happened.
    property string moveEndWhy: ""
    property real moveGap: 0         // age of the newest pointer sample
    property real moveLag: 0         // age of the pointer sample used for the comparison
    property real moveResX: 0        // window position minus pointer-implied position
    property real moveResY: 0
    property real moveResMax: 0      // worst residual seen during a healthy drag

    // When the toplevel data currently in the model was asked for. Samples are
    // taken *before* each new request, so a sample always reads the previous
    // request's data and this is the moment that data reflects. Comparing a
    // window sample with a pointer sample is only meaningful when it is known.
    property double geometryAt: 0

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

    // ------------------------------------------------------ pointer sampling
    //
    // Hyprland's request socket answers exactly one command per connection and
    // then closes it, and a peer-side close is logged as a warning — once per
    // sample would flood the log — so this side closes the connection as soon
    // as the reply has been parsed and the pace timer reopens it. One sample
    // costs a fraction of a millisecond, cheap enough to run near display
    // rates, but the feed only runs while a drag is live.
    function cursorSample(x, y) {
        var now = Date.now();
        cursorX = x;
        cursorY = y;
        cursorAt = now;
        cursorSamples += 1;
        cursorErrors = 0;
        var hist = cursorHist;
        hist.push({ t: now, x: x, y: y });
        cursorHist = GapGeometry.trimCursorHistory(hist, now, cursorHistMs);
        if (moveLocked && moveActive && moveRect) {
            // The pointer is the truth while the drag is locked to it.
            moveRect = {
                x: Math.round(x - moveGrabX), y: Math.round(y - moveGrabY),
                w: moveRect.w, h: moveRect.h
            };
        }
    }

    // Pointer position at time `t`, interpolated between its neighbours. The
    // pointer and the geometry arrive on separate schedules and comparing them
    // is only meaningful when both are read at the same instant.
    function cursorPosAt(t) {
        return GapGeometry.cursorAt(cursorHist, t);
    }

    function armCursor(on) {
        if (cursorArmed === on) return;
        cursorArmed = on;
        if (!on) {
            cursorSocket.connected = false;
            cursorHist = [];
        }
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
        moveLocked = false;
        moveMiss = 0;
        armCursor(false);
    }

    function endMove() {
        var settled = moveActive || moveStreak > 0;
        hideMove();
        if (moveWatch.running) moveWatch.stop();
        // The rails were left alone while the window was moving; derive them
        // again now that the layout has settled.
        if (settled) refreshLayout();
    }

    // Take up the pointer. A drag is rigid, so one sample fixes the offset
    // between the window and the pointer, and the border can then read its
    // position straight off the pointer instead of off stale geometry.
    //
    // The offset is *not* re-taken later on: once the pointer is up and the
    // window parked, a flow of slow pointer movement is indistinguishable from
    // a pause in a drag, so re-learning the offset there would let the border
    // drift off the window instead of noticing that the drag had ended. It is
    // taken from `obsAt`, the moment the geometry being compared reflects, so
    // the pointer position used is the one the window was actually placed from.
    function lockToPointer(obsAt, snap) {
        if (moveLocked || !moveAddress) return;
        var obs = snap[moveAddress];
        var c = cursorPosAt(obsAt);
        if (!obs || !c) return;
        moveGrabX = c.x - obs.x;
        moveGrabY = c.y - obs.y;
        moveLocked = true;
        moveMiss = 0;
        if (moveRect) {
            moveRect = { x: Math.round(c.x - moveGrabX), y: Math.round(c.y - moveGrabY),
                         w: obs.w, h: obs.h };
        }
    }

    // Is the window still where the pointer put it? While the border is locked
    // to the pointer the window has to sit exactly where the pointer says —
    // whether it is moving or resting — so a single test covers both, and it is
    // the only thing that can end a drag: there is no release event, and a
    // window that has stopped moving is just as consistent with a pause as with
    // a finished drag. A feed that has gone quiet leaves nothing to compare
    // against, and the border then times out instead, which also catches a drag
    // that ended without the pointer moving afterwards.
    function checkLock(now, obsAt, snap, fresh) {
        if (now - moveStartAt > moveMaxMs) return true;
        if (!fresh) return false;   // this sample predates the drag: nothing to compare
        var obs = snap[moveAddress];
        if (!obs) return true;
        var c = cursorPosAt(obsAt);
        if (!c) return false;
        moveLag = now - c.t;
        var err = GapGeometry.lockError(obs, c, moveGrabX, moveGrabY);
        if (!err) return false;
        var dx = err.x;
        var dy = err.y;
        moveResX = dx;
        moveResY = dy;
        if (Math.abs(dx) > moveLockTol || Math.abs(dy) > moveLockTol) {
            moveMiss += 1;
            return moveMiss >= moveLockMisses;
        }
        moveMiss = 0;
        moveResMax = Math.max(moveResMax, Math.abs(dx), Math.abs(dy));
        return false;
    }

    function moveEnded(now, obsAt, snap, fresh) {
        if (moveAddress === "") return stopMove("none");
        if (now - moveStartAt > moveMaxMs) return stopMove("cap");
        var obs = snap[moveAddress];
        if (!obs) return stopMove("gone");

        // A size change on its own is not the end of a drag — a live reflow can
        // do that — but the border should keep hugging the window if it does.
        if (Math.abs(obs.w - moveRect.w) > 1 || Math.abs(obs.h - moveRect.h) > 1)
            moveRect = { x: moveRect.x, y: moveRect.y, w: obs.w, h: obs.h };

        moveGap = now - cursorAt;
        if (!(cursorAt > 0 && moveGap <= moveFeedMs)) {
            // Feed lost: fall back to timing out on motion.
            moveLocked = false;
            if (now - moveLastAt > moveGraceMs) return stopMove("feed");
            return false;
        }
        if (!fresh) return false;
        if (!moveLocked) {
            lockToPointer(obsAt, snap);
            if (!moveLocked) {
                if (now - moveLastAt > moveGraceMs) return stopMove("nolock");
                return false;
            }
        }

        if (checkLock(now, obsAt, snap, fresh)) return stopMove("miss");
        // Still following the pointer: hold the border, and hold it through a
        // pause too, since a resting window proves nothing on its own.
        moveLastAt = now;
        return false;
    }

    function stopMove(why) {
        moveEndWhy = why;
        return true;
    }

    // Compare this sample against the previous one and decide whether a window
    // is being dragged.
    function sampleMoves() {
        var now = Date.now();
        var snap = windowSnapshot();
        moveSamples += 1;

        // The toplevel data read here is the previous request's, so `geometryAt`
        // is the moment it reflects: it is the same for the window and for the
        // pointer positions compared against it. It is only good enough to
        // compare when it is recent, which it is while the fast poll runs (and
        // is not on the first sample after the slow tick armed it).
        var obsAt = geometryAt > 0 ? geometryAt : now;
        var fresh = (now - obsAt) <= movePollMs * 2 + 8;

        // A pinned preview wins for as long as it lasts, and tracks the window
        // live (handy for checking the rendering from a screenshot).
        if (previewAddress !== "" && now < previewUntil) {
            var pinned = snap[previewAddress];
            moveRects = snap;
            if (pinned) {
                showMove(previewAddress, pinned);
                moveActive = true;
                moveLocked = false;
                moveLastAt = now;
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
            if (moveStreak === 0) {
                moveStartAt = now;
                moveLocked = false;
                moveMiss = 0;
                moveEndWhy = "";
                moveResMax = 0;
            }
            moveStreak += 1;
            moveLastAt = now;
            showMove(best, snap[best]);
            if (!moveWatch.running) moveWatch.start();
            armCursor(true);
            if (fresh) lockToPointer(obsAt, snap);
            // A drop that re-tiles the window moves it without the pointer
            // moving, and that translation looks exactly like a drag; the lock
            // is what tells the two apart.
            if (moveLocked && checkLock(now, obsAt, snap, fresh)) endMove();
        } else if (moveStreak > 0 || moveActive) {
            if (moveEnded(now, obsAt, snap, fresh)) endMove();
        } else if (now - moveLastAt > moveGraceMs) {
            // Nothing moving and nothing suspected: let the fast poll and the
            // pointer feed go, so an idle shell does no extra work.
            if (moveWatch.running) moveWatch.stop();
            armCursor(false);
        }

        var held = moveLocked || (now - moveLastAt) <= moveGraceMs;
        moveActive = moveStreak >= moveConfirmSamples && held && moveAddress !== "";
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

    // Something happened that could be the start of a drag. Watch the geometry
    // closely for a moment so a translation is caught on the next poll instead
    // of waiting out the slow tick, and bring the pointer feed up with it.
    function armMoveWatch() {
        if (!moveWatch.running) moveWatch.start();
        armCursor(true);
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
    // applications underneath, and drop any window property it raised.
    Component.onDestruction: {
        endResize();
        if (dragEnabled) Quickshell.execDetached(["hyprctl", "eval", unbindScript]);
    }

    // One listener drives both halves: layout events refresh the rails, and a
    // config reload re-asserts the runtime-owned settings and bind. Events that
    // can accompany the start of a drag also bring the fast poll up early.
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
            if (name === "activewindow" || name === "changefloatingmode"
                || name === "movewindow" || name === "fullscreen") {
                armMoveWatch();
            }
            if (name === "configreloaded") reapply();
        }
    }

    // Fallback refresh for geometry that has no matching event. Sampling comes
    // first, so a sample always reads the previous request's data and knows
    // when that data was taken.
    Timer {
        interval: 120
        repeat: true
        running: true
        onTriggered: {
            root.sampleMoves()
            root.refreshLayout()
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
            root.sampleMoves()
            root.geometryAt = Date.now()
            Hyprland.refreshToplevels()
        }
    }

    // The pointer feed. Hyprland's request socket takes one command per
    // connection, so the socket is closed from this side the moment the reply
    // has been parsed (a peer close is logged as a warning, and at display
    // rates that would flood the log) and the pace timer below reopens it. The
    // request deliberately has no trailing newline: the socket treats a
    // newline as part of the command and answers `unknown request`.
    Socket {
        id: cursorSocket

        path: Hyprland.requestSocketPath
        connected: false

        parser: SplitParser {
            onRead: (line) => {
                root.cursorBuf += line;
                if (line.trim().endsWith("}")) {
                    var text = root.cursorBuf.trim();
                    root.cursorBuf = "";
                    if (cursorSocket.connected) cursorSocket.connected = false;
                    var pos = null;
                    try { pos = JSON.parse(text); } catch (e) { pos = null; }
                    if (pos && typeof pos.x === "number" && typeof pos.y === "number")
                        root.cursorSample(pos.x, pos.y);
                }
            }
        }

        onConnectedChanged: {
            if (connected) {
                write("j/cursorpos");
                flush();
            } else {
                root.cursorBuf = "";
            }
        }

        // A failed connect would otherwise be retried (and logged by
        // Quickshell) at the poll rate. Give up on the feed instead and let the
        // border fall back to geometry-only tracking; the next drag arms it
        // again. A successful sample clears the count, so only a run of real
        // failures counts.
        onError: {
            root.cursorErrors += 1;
            if (root.cursorErrors >= 8) root.armCursor(false);
        }
    }

    // Paces the pointer feed: the socket is left disconnected between samples,
    // so this is both what reopens it and what keeps the rate down.
    Timer {
        interval: root.cursorPollMs
        repeat: true
        running: root.cursorArmed
        onTriggered: if (root.cursorArmed && !cursorSocket.connected) cursorSocket.connected = true
    }

    // Commands that run on pointer motion go out here, one per connection, and
    // this side closes each connection as soon as the reply lands so the close
    // is never logged as a peer-closed warning. See the dispatch section above.
    Socket {
        id: dispatchSocket

        path: Hyprland.requestSocketPath
        connected: false

        parser: SplitParser {
            onRead: (line) => {
                // Fire-and-forget: nothing is expected back, but anything that
                // does arrive is only a diagnostic.
                if (line.length > 0) root.dispatchReply = line;
            }
        }

        onConnectedChanged: {
            if (connected) {
                root.flushDispatch();
            } else {
                root.dispatchBusy = false;
                dispatchWatch.stop();
                root.pumpDispatch();
            }
        }

        onError: root.noteDispatchFailure()
    }

    // A reply that never comes must not hold the dispatch slot forever.
    Timer {
        id: dispatchWatch
        interval: 400
        onTriggered: root.noteDispatchFailure()
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
        function dispatchstatus(): string { return root.dispatchDiagnostic() }
        // Drive the resize path without a mouse, which is the only way to check
        // it here:
        //   omarchy shell tile-drag-resize resizeby address:0x1234 40 0
        //   omarchy shell tile-drag-resize noanim address:0x1234 1
        function resizeby(address: string, dx: int, dy: int): void {
            root.resizeWindow(address, dx, dy);
        }
        function noanim(address: string, on: int): void {
            if (on) root.beginResize(address);
            else root.endResize();
        }
        function dragstatus(): string {
            return "moving=" + (root.moveAddress || "-")
                + " active=" + root.moveActive
                + " streak=" + root.moveStreak
                + " locked=" + root.moveLocked
                + " miss=" + root.moveMiss
                + " grab=" + Math.round(root.moveGrabX) + "," + Math.round(root.moveGrabY)
                + " gap=" + Math.round(root.moveGap) + " lag=" + Math.round(root.moveLag)
                + " res=" + Math.round(root.moveResX) + "," + Math.round(root.moveResY)
                + " resmax=" + Math.round(root.moveResMax)
                + " why=" + (root.moveEndWhy || "-")
                + " feed=" + (root.cursorArmed ? "on" : "off")
                + " cursamples=" + root.cursorSamples
                + " cursor=" + (root.cursorAt ? (Date.now() - root.cursorAt) + "ms" : "-")
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
