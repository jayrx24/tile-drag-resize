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

console.log("\n" + passed + " checks passed" + (process.exitCode ? " (with failures)" : ""));
