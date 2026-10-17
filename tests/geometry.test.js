// Unit tests for GapGeometry.js — run with: node tests/geometry.test.js
"use strict";

const assert = require("assert");
const G = require("../GapGeometry.js");

const OPTS = { maxGap: 56, minOverlap: 24, minGap: 2 };

function win(address, x, y, w, h, extra) {
  const o = { address, at: [x, y], size: [w, h], mapped: true, hidden: false, floating: false, pinned: false, fullscreen: 0 };
  return Object.assign(o, extra || {});
}

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log("  ok   " + name);
  } catch (e) {
    console.error("  FAIL " + name);
    console.error("       " + e.message);
    process.exitCode = 1;
  }
}

// --- window extraction -----------------------------------------------------

test("rejects floating windows", () => {
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 100, 100, { floating: true })), null);
});

test("rejects fullscreen windows", () => {
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 100, 100, { fullscreen: 2 })), null);
});

test("rejects hidden / unmapped windows", () => {
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 100, 100, { hidden: true })), null);
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 100, 100, { mapped: false })), null);
});

test("accepts a normal tiled window and computes edges", () => {
  const r = G.windowRect(win("0xa", 10, 20, 100, 50));
  assert.strictEqual(r.address, "0xa");
  assert.strictEqual(r.right, 110);
  assert.strictEqual(r.bottom, 70);
});

test("reads lastIpcObject wrappers", () => {
  const r = G.windowRect({ lastIpcObject: win("0xa", 0, 0, 10, 10) });
  assert.strictEqual(r.address, "0xa");
});

test("windowRect keeps floating windows only when asked", () => {
  const f = win("0xa", 0, 0, 100, 100, { floating: true });
  // Rail search: a floating window is not part of the tiling.
  assert.strictEqual(G.windowRect(f), null);
  assert.strictEqual(G.collect(0, 0, [f, win("0xb", 106, 0, 100, 100)], OPTS).length, 0);
  // Move highlight: Hyprland can float a window while it is being dragged.
  const kept = G.windowRect(f, { allowFloating: true });
  assert.strictEqual(kept.address, "0xa");
  assert.deepStrictEqual([kept.x, kept.y, kept.w, kept.h], [0, 0, 100, 100]);
  // Pinned windows come along with the same flag.
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 1, 1, { pinned: true })), null);
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 1, 1, { pinned: true }), { allowFloating: true }).address, "0xa");
  // Hidden and fullscreen windows stay out either way.
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 1, 1, { hidden: true }), { allowFloating: true }), null);
  assert.strictEqual(G.windowRect(win("0xa", 0, 0, 1, 1, { fullscreen: 2 }), { allowFloating: true }), null);
});

// --- move detection (the middle-button drag highlight) ----------------------

function rects(list) {
  const out = {};
  for (const [addr, x, y, w, h] of list) out[addr] = { x, y, w, h };
  return out;
}

test("detectMove finds a window that moved without resizing", () => {
  const before = rects([["0xa", 0, 0, 100, 100], ["0xb", 110, 0, 100, 100]]);
  const after = rects([["0xa", 40, 25, 100, 100], ["0xb", 110, 0, 100, 100]]);
  assert.strictEqual(G.detectMove(before, after, 2), "0xa");
});

test("detectMove ignores resizes, layout shifts and jitter", () => {
  const before = rects([["0xa", 0, 0, 100, 100], ["0xb", 110, 0, 100, 100]]);
  // A gap resize changes the size of the window being resized.
  assert.strictEqual(G.detectMove(before, rects([["0xa", 0, 0, 140, 100], ["0xb", 150, 0, 60, 100]]), 2), "");
  // A layout change moves and resizes the passengers.
  assert.strictEqual(G.detectMove(before, rects([["0xa", 0, 0, 60, 100], ["0xb", 70, 0, 140, 100]]), 2), "");
  // A sub-pixel nudge is noise, not a drag.
  assert.strictEqual(G.detectMove(before, rects([["0xa", 1, 1, 100, 100], ["0xb", 110, 0, 100, 100]]), 2), "");
  // A window that only appeared or only vanished is not a move.
  assert.strictEqual(G.detectMove(before, rects([["0xa", 0, 0, 100, 100], ["0xc", 300, 0, 100, 100]]), 2), "");
});

test("detectMove picks the largest move and tolerates rounding", () => {
  const before = rects([["0xa", 0, 0, 100, 100], ["0xb", 110, 0, 100, 100]]);
  // Both shifted; the one that travelled furthest is the one being dragged.
  const after = rects([["0xa", 10, 0, 100, 100], ["0xb", 150, 0, 100, 100]]);
  assert.strictEqual(G.detectMove(before, after, 2), "0xb");
  // A one-pixel size change (compositor rounding) still counts as a move.
  const rounded = rects([["0xa", 40, 0, 101, 100], ["0xb", 110, 0, 100, 100]]);
  assert.strictEqual(G.detectMove(before, rounded, 2), "0xa");
  // Missing snapshots are handled rather than thrown on.
  assert.strictEqual(G.detectMove(null, before, 2), "");
  assert.strictEqual(G.detectMove(before, null, 2), "");
});

// --- seams -----------------------------------------------------------------

test("side-by-side pair yields one vertical rail", () => {
  const rails = G.collect(0, 0, [win("0xa", 0, 0, 100, 100), win("0xb", 106, 0, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 1);
  const r = rails[0];
  assert.strictEqual(r.orientation, "vertical");
  assert.deepStrictEqual([r.x, r.y, r.w, r.h], [100, 0, 6, 100]);
  assert.strictEqual(r.resizeAddress, "0xa");
});

test("stacked pair yields one horizontal rail", () => {
  const rails = G.collect(0, 0, [win("0xa", 0, 0, 100, 100), win("0xb", 0, 106, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 1);
  const r = rails[0];
  assert.strictEqual(r.orientation, "horizontal");
  assert.deepStrictEqual([r.x, r.y, r.w, r.h], [0, 100, 100, 6]);
  assert.strictEqual(r.resizeAddress, "0xa");
});

test("gap larger than maxGap produces no rail", () => {
  const rails = G.collect(0, 0, [win("0xa", 0, 0, 100, 100), win("0xb", 500, 0, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 0);
});

test("overlap smaller than minOverlap produces no rail", () => {
  const rails = G.collect(0, 0, [win("0xa", 0, 0, 100, 100), win("0xb", 106, 95, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 0);
});

test("touching edges are ignored (gap below minGap)", () => {
  const rails = G.collect(0, 0, [win("0xa", 0, 0, 100, 100), win("0xb", 100, 0, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 0);
});

// --- full-height merging ---------------------------------------------------

test("tall window beside a column merges into one full-height rail", () => {
  const toplevels = [
    win("0xL", 0, 0, 100, 1000),
    win("0x1", 106, 0, 100, 330),
    win("0x2", 106, 336, 100, 330),
    win("0x3", 106, 672, 100, 328)
  ];
  const rails = G.collect(0, 0, toplevels, OPTS);

  const vertical = rails.filter((r) => r.orientation === "vertical");
  assert.strictEqual(vertical.length, 1, "expected exactly one merged vertical rail");
  assert.deepStrictEqual([vertical[0].x, vertical[0].y, vertical[0].w, vertical[0].h], [100, 0, 6, 1000]);
  assert.strictEqual(vertical[0].resizeAddress, "0xL");

  // The two horizontal seams between the stacked windows remain.
  const horizontal = rails.filter((r) => r.orientation === "horizontal");
  assert.strictEqual(horizontal.length, 2);
});

test("column beside a tall window merges and resizes the shared tall window", () => {
  const toplevels = [
    win("0x1", 0, 0, 100, 330),
    win("0x2", 0, 336, 100, 330),
    win("0x3", 0, 672, 100, 328),
    win("0xR", 106, 0, 100, 1000)
  ];
  const rails = G.collect(0, 0, toplevels, OPTS);
  const vertical = rails.filter((r) => r.orientation === "vertical");
  assert.strictEqual(vertical.length, 1);
  assert.deepStrictEqual([vertical[0].x, vertical[0].y, vertical[0].w, vertical[0].h], [100, 0, 6, 1000]);
  // The column does not share a single window, so the seam is driven by the
  // one window every piece of it touches: the tall right-hand window.
  assert.strictEqual(vertical[0].resizeAddress, "0xR");
});

test("rails carry no resize factor (the seam follows the delta for either neighbour)", () => {
  // Hyprland moves the resized window's split-facing edge by the requested
  // amount, so a shared left/top window and a shared right/bottom window both
  // travel the same way. A per-window factor would invert one of them.
  const left = G.collect(0, 0, [win("0xL", 0, 0, 100, 1000), win("0x1", 106, 0, 100, 500), win("0x2", 106, 506, 100, 494)], OPTS);
  const right = G.collect(0, 0, [win("0x1", 0, 0, 100, 500), win("0x2", 0, 506, 100, 494), win("0xR", 106, 0, 100, 1000)], OPTS);
  const lv = left.filter((r) => r.orientation === "vertical")[0];
  const rv = right.filter((r) => r.orientation === "vertical")[0];
  assert.strictEqual(lv.resizeAddress, "0xL");
  assert.strictEqual(rv.resizeAddress, "0xR");
  assert.strictEqual(lv.resizeFactor, undefined);
  assert.strictEqual(rv.resizeFactor, undefined);
});

test("different seams on the same x do not merge without a shared window", () => {
  const toplevels = [
    win("0xa", 0, 0, 100, 100),
    win("0xb", 106, 0, 100, 100),
    win("0xc", 0, 200, 100, 100),
    win("0xd", 106, 200, 100, 100)
  ];
  const rails = G.collect(0, 0, toplevels, OPTS);
  const vertical = rails.filter((r) => r.orientation === "vertical" && r.h === 100);
  // Two independent vertical splits; no window is shared across them.
  assert.strictEqual(vertical.length, 2);
});

// --- monitor-local coordinates ---------------------------------------------

test("collect shifts rails into monitor-local coordinates", () => {
  const rails = G.collect(2000, 40, [win("0xa", 2000, 40, 100, 100), win("0xb", 2106, 40, 100, 100)], OPTS);
  assert.strictEqual(rails.length, 1);
  assert.deepStrictEqual([rails[0].x, rails[0].y], [100, 0]);
});

test("accepts a QML-style { values: [...] } list", () => {
  const rails = G.collect(0, 0, { values: [win("0xa", 0, 0, 100, 100), win("0xb", 106, 0, 100, 100)] }, OPTS);
  assert.strictEqual(rails.length, 1);
});

test("accepts a QML sequence (array-like whose `.values` is the Array iterator)", () => {
  // Mirrors what Quickshell hands QML for `toplevels.values`: indexable with a
  // numeric `length`, but Array.isArray() is false and `.values` resolves to
  // Array.prototype.values — a truthy *function*. Treating that as the list is
  // what produced zero rails in the shell.
  function sequence(items) {
    const o = {};
    items.forEach((item, i) => { o[i] = item; });
    o.length = items.length;
    o.values = Array.prototype.values;
    return o;
  }
  const s = sequence([win("0xa", 0, 0, 100, 100), win("0xb", 106, 0, 100, 100)]);
  assert.strictEqual(Array.isArray(s), false);
  assert.strictEqual(typeof s.values, "function");

  const rails = G.collect(0, 0, s, OPTS);
  assert.strictEqual(rails.length, 1);
  assert.deepStrictEqual([rails[0].x, rails[0].y, rails[0].w, rails[0].h], [100, 0, 6, 100]);
});

test("toArray never mistakes a function-valued `values` for a list", () => {
  assert.strictEqual(G.toArray(null).length, 0);
  assert.strictEqual(G.toArray(undefined).length, 0);
  assert.strictEqual(G.toArray([]).length, 0);
  assert.strictEqual(G.toArray([1, 2, 3]).length, 3);
  assert.strictEqual(G.toArray({ values: Array.prototype.values }).length, 0);
  assert.strictEqual(G.toArray({ values: [1, 2] }).length, 2);
});

// --- pointer tracking ------------------------------------------------------

const hist = [
  { t: 1000, x: 0, y: 0 },
  { t: 1010, x: 10, y: 20 },
  { t: 1020, x: 30, y: 20 }
];

test("cursorAt interpolates between the samples that bracket a time", () => {
  const mid = G.cursorAt(hist, 1005);
  assert.strictEqual(mid.x, 5);
  assert.strictEqual(mid.y, 10);
  const late = G.cursorAt(hist, 1015);
  assert.strictEqual(late.x, 20);
  assert.strictEqual(late.y, 20);
});

test("cursorAt returns the sample itself on an exact hit", () => {
  assert.strictEqual(G.cursorAt(hist, 1010).x, 10);
  assert.strictEqual(G.cursorAt(hist, 1020).x, 30);
});

test("cursorAt clamps outside the history instead of extrapolating", () => {
  const early = G.cursorAt(hist, 500);
  assert.strictEqual(early.x, 0);
  const late = G.cursorAt(hist, 9999);
  assert.strictEqual(late.x, 30);
});

test("cursorAt copes with an empty history and a single sample", () => {
  assert.strictEqual(G.cursorAt([], 100), null);
  assert.strictEqual(G.cursorAt(null, 100), null);
  const one = G.cursorAt([{ t: 5, x: 1, y: 2 }], 500);
  assert.strictEqual(one.x, 1);
});

test("trimCursorHistory drops old samples but always keeps one", () => {
  const kept = G.trimCursorHistory(hist, 1015, 8);
  assert.deepStrictEqual(kept.map((s) => s.t), [1010, 1020]);
  const all = G.trimCursorHistory([{ t: 1, x: 0, y: 0 }], 99999, 10);
  assert.strictEqual(all.length, 1);
  assert.strictEqual(G.trimCursorHistory([], 10, 10).length, 0);
});

test("trimCursorHistory does not mutate the history it is given", () => {
  const copy = hist.slice();
  G.trimCursorHistory(copy, 1015, 8);
  assert.deepStrictEqual(copy.map((s) => s.t), [1000, 1010, 1020]);
});

test("lockError is zero while the window rides with the pointer", () => {
  const err = G.lockError({ x: 100, y: 50 }, { x: 140, y: 60 }, 40, 10);
  assert.strictEqual(err.x, 0);
  assert.strictEqual(err.y, 0);
});

test("lockError grows when a release leaves the window behind", () => {
  // Pointer moved 220px right after the button came up: the window stayed.
  const err = G.lockError({ x: 100, y: 50 }, { x: 360, y: 60 }, 40, 10);
  assert.strictEqual(err.x, -220);
  assert.strictEqual(err.y, 0);
  assert.strictEqual(G.lockError(null, { x: 1, y: 1 }, 0, 0), null);
});

console.log("\n" + passed + " checks passed" + (process.exitCode ? " (with failures)" : ""));
