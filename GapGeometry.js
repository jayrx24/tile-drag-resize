// GapGeometry.js
//
// Pure geometry for finding the draggable gaps between tiled windows.
//
// This file has no QML and no side effects: every function maps rectangle
// inputs to rectangle outputs. That keeps it unit-testable under Node as
// well as loadable by the shell through `import "GapGeometry.js" as ...`.
//
// Coordinate convention: input windows are given in global (compositor)
// coordinates. `collect` shifts the results into monitor-local coordinates
// so the overlay layer can place them directly.

"use strict";

// ---- small numeric helpers ------------------------------------------------

function isNumber(v) {
  return typeof v === "number" && isFinite(v);
}

function near(a, b, epsilon) {
  return Math.abs(a - b) <= (epsilon || 0.5);
}

// ---- window extraction ----------------------------------------------------

// Turn a raw Hyprland toplevel object (as exposed by the Quickshell Hyprland
// module, either directly or through `lastIpcObject`) into a simple rectangle,
// or null when the surface is not a window we care about.
//
// `options.allowFloating` keeps floating (and pinned) windows. The gap-rail
// search never wants them, but the move highlight does: Hyprland can float a
// window for the duration of a drag.
function windowRect(toplevel, options) {
  var data = toplevel && toplevel.lastIpcObject ? toplevel.lastIpcObject : toplevel;
  if (!data) return null;

  // Skip anything that is not a visible, ordinary window.
  if (data.mapped === false || data.hidden === true) return null;
  if (!options || !options.allowFloating) {
    if (data.floating === true || data.pinned === true) return null;
  }
  if (data.fullscreen && Number(data.fullscreen) !== 0) return null;

  var at = data.at || data.position;
  var size = data.size;
  if (!at || !size || at.length < 2 || size.length < 2) return null;

  var x = Number(at[0]);
  var y = Number(at[1]);
  var w = Number(size[0]);
  var h = Number(size[1]);
  if (!isNumber(x) || !isNumber(y) || !isNumber(w) || !isNumber(h)) return null;
  if (w <= 0 || h <= 0) return null;

  return {
    address: data.address || "",
    x: x,
    y: y,
    w: w,
    h: h,
    right: x + w,
    bottom: y + h
  };
}

// ---- primitive gap detection ----------------------------------------------

// Find every pair of windows whose shared gap is a valid resize seam.
//
// A pair forms a vertical seam when one window sits directly to the left of
// the other (small horizontal gap, enough vertical overlap). It forms a
// horizontal seam when one sits directly above the other. Each seam becomes a
// "rail" rectangle placed exactly over the shared gap.
//
// Rails are returned in global coordinates. Each rail records the two adjacent
// window addresses plus which one to resize while dragging.
function findRails(windows, maxGap, minOverlap, minGap) {
  var rails = [];
  var n = windows.length;
  var i, j;

  for (i = 0; i < n; i++) {
    for (j = i + 1; j < n; j++) {
      var a = windows[i];
      var b = windows[j];

      // Vertical seam: windows side by side.
      var left = a.x <= b.x ? a : b;
      var right = a.x <= b.x ? b : a;
      var vGap = right.x - left.right;
      var vOverlapTop = Math.max(left.y, right.y);
      var vOverlapBottom = Math.min(left.bottom, right.bottom);
      var vOverlap = vOverlapBottom - vOverlapTop;

      if (vGap >= minGap && vGap <= maxGap && vOverlap >= minOverlap) {
        rails.push({
          orientation: "vertical",
          x: left.right,
          y: vOverlapTop,
          w: vGap,
          h: vOverlap,
          first: left.address,
          second: right.address,
          resizeAddress: left.address
        });
      }

      // Horizontal seam: windows stacked one above the other.
      var top = a.y <= b.y ? a : b;
      var bottom = a.y <= b.y ? b : a;
      var hGap = bottom.y - top.bottom;
      var hOverlapLeft = Math.max(top.x, bottom.x);
      var hOverlapRight = Math.min(top.right, bottom.right);
      var hOverlap = hOverlapRight - hOverlapLeft;

      if (hGap >= minGap && hGap <= maxGap && hOverlap >= minOverlap) {
        rails.push({
          orientation: "horizontal",
          x: hOverlapLeft,
          y: top.bottom,
          w: hOverlap,
          h: hGap,
          first: top.address,
          second: bottom.address,
          resizeAddress: top.address
        });
      }
    }
  }

  return rails;
}

// ---- seam merging ---------------------------------------------------------

// Minimal union-find helpers. `parent` is the array of parent indices; the
// finder compresses paths as it goes so repeated lookups stay cheap.
function makeFinder(parent) {
  return function find(n) {
    while (parent[n] !== n) {
      parent[n] = parent[parent[n]];
      n = parent[n];
    }
    return n;
  };
}

function union(parent, find, p, q) {
  var rp = find(p);
  var rq = find(q);
  if (rp !== rq) parent[rq] = rp;
}

// Two rails share a side when their left/top windows match or their
// right/bottom windows match.
function sharesWindow(p, q) {
  return p.first === q.first || p.second === q.second;
}

// Rails on the same seam that share a window are two pieces of one split.
// Merging them gives "full-height" resizing: a tall window beside a column of
// stacked windows exposes a single long rail along its whole edge instead of a
// handful of short ones.
//
// Two rails belong together when they sit on the same line (same coordinate
// and thickness) and their window pairs overlap on one side. That relation is
// transitive, so the merged rail is the connected component of the relation.
//
// `axis` is "vertical" or "horizontal":
//   vertical   -> line is x, thickness is w, length spans y..y+h
//   horizontal -> line is y, thickness is h, length spans x..x+w
function mergeSeam(rails, axis) {
  var vertical = axis === "vertical";
  var lineKey = vertical ? "x" : "y";
  var thickKey = vertical ? "w" : "h";
  var startKey = vertical ? "y" : "x";
  var lenKey = vertical ? "h" : "w";

  var rail, i, j;

  // Group rails that share the same seam line and thickness.
  var groups = [];
  for (i = 0; i < rails.length; i++) {
    rail = rails[i];
    var placed = false;
    for (j = 0; j < groups.length; j++) {
      if (near(groups[j].line, rail[lineKey]) && near(groups[j].thick, rail[thickKey])) {
        groups[j].items.push(rail);
        placed = true;
        break;
      }
    }
    if (!placed) {
      groups.push({ line: rail[lineKey], thick: rail[thickKey], items: [rail] });
    }
  }

  var merged = [];
  for (j = 0; j < groups.length; j++) {
    var items = groups[j].items;
    var count = items.length;

    // Union-find over the group so sharing a window joins rails transitively.
    var parent = [];
    for (i = 0; i < count; i++) parent.push(i);
    var find = makeFinder(parent);

    for (i = 0; i < count; i++) {
      for (var k = i + 1; k < count; k++) {
        if (sharesWindow(items[i], items[k])) union(parent, find, i, k);
      }
    }

    // Fold each component into a single rail.
    var byRoot = {};
    for (i = 0; i < count; i++) {
      var r = find(i);
      var item = items[i];
      var bucket = byRoot[r];
      if (!bucket) {
        bucket = {
          orientation: axis,
          start: item[startKey],
          end: item[startKey] + item[lenKey],
          first: item.first,
          second: item.second,
          commonFirst: true,
          commonSecond: true,
          resizeAddress: item.resizeAddress
        };
        byRoot[r] = bucket;
      } else {
        bucket.start = Math.min(bucket.start, item[startKey]);
        bucket.end = Math.max(bucket.end, item[startKey] + item[lenKey]);
        if (bucket.first !== item.first) bucket.commonFirst = false;
        if (bucket.second !== item.second) bucket.commonSecond = false;
      }
    }

    for (var key in byRoot) {
      var c = byRoot[key];
      // Resize the window that every piece of the seam shares. Whichever
      // neighbour we pick, the seam travels *with* the drag delta: Hyprland
      // moves the resized window's edge that faces the split by the requested
      // amount. Growing the left/top window pushes that edge right/down, and
      // shrinking the right/bottom window pulls its facing edge the same way,
      // so the signed delta needs no per-window correction.
      var address = c.resizeAddress;
      if (c.commonFirst && !c.commonSecond) {
        address = c.first;
      } else if (c.commonSecond && !c.commonFirst) {
        address = c.second;
      }

      var out = { orientation: axis, resizeAddress: address };
      if (vertical) {
        out.x = groups[j].line;
        out.y = c.start;
        out.w = groups[j].thick;
        out.h = c.end - c.start;
      } else {
        out.x = c.start;
        out.y = groups[j].line;
        out.w = c.end - c.start;
        out.h = groups[j].thick;
      }
      merged.push(out);
    }
  }

  return merged;
}

function mergeRails(rails) {
  var vertical = [];
  var horizontal = [];
  var i;
  for (i = 0; i < rails.length; i++) {
    if (rails[i].orientation === "vertical") vertical.push(rails[i]);
    else horizontal.push(rails[i]);
  }
  return mergeSeam(vertical, "vertical").concat(mergeSeam(horizontal, "horizontal"));
}

// Resolve a window list that may arrive as a plain array, as a QML sequence
// (array-like, indexable, with `length`), or as a Quickshell object model that
// exposes `.values`. Returns a plain array either way.
//
// Careful: never trust `x.values` blindly — a QML sequence inherits
// `Array.prototype.values` (the iterator function), which is truthy.
function toArray(model) {
  if (!model) return [];

  var out = [];
  var i;

  if (typeof model.length === "number") {
    for (i = 0; i < model.length; i++) out.push(model[i]);
    if (out.length > 0) return out;
  }

  var nested = model.values;
  if (nested && typeof nested !== "function" && typeof nested.length === "number") {
    for (i = 0; i < nested.length; i++) out.push(nested[i]);
  }
  return out;
}

// ---- move detection -------------------------------------------------------

// Hyprland never announces "a window started being dragged", so the middle
// button drag is inferred from geometry instead: a drag is a *pure
// translation*, so a window that kept its size but changed position between two
// samples is the one being moved. That also rules out the two things that must
// not light up — a layout change moves windows once, and a gap resize changes
// the size rather than just the position.
//
// `prev` and `next` are maps of address -> { x, y, w, h }. Returns the address
// of the largest such move, or "" when there is none.
function detectMove(prev, next, epsilon) {
  var slop = Number(epsilon) > 0 ? Number(epsilon) : 2;
  var best = "";
  var bestDist = 0;
  if (!prev || !next) return best;

  for (var address in next) {
    var a = next[address];
    var b = prev[address];
    if (!b) continue;
    if (Math.abs(a.w - b.w) + Math.abs(a.h - b.h) > slop) continue;
    var dist = Math.abs(a.x - b.x) + Math.abs(a.y - b.y);
    if (dist > slop && dist > bestDist) {
      bestDist = dist;
      best = address;
    }
  }
  return best;
}

// ---- public entry point ---------------------------------------------------

// Compute the draggable gap rails for one monitor's active workspace.
//
//   monitorX / monitorY : top-left of the monitor in global coordinates.
//   toplevels           : iterable of Hyprland toplevel objects.
//   opts                : { maxGap, minOverlap, minGap }
//
// Returns an array of rail objects in monitor-local coordinates, each with:
//   orientation    "vertical" | "horizontal"
//   x, y, w, h     rail rectangle (x/y are the top-left)
//   resizeAddress  window address to resize while dragging; the drag delta is
//                  applied to it unchanged, since the seam follows the delta
function collect(monitorX, monitorY, toplevels, opts) {
  opts = opts || {};
  var maxGap = Math.max(0, Number(opts.maxGap) || 0);
  var minOverlap = Math.max(1, Number(opts.minOverlap) || 1);
  var minGap = Math.max(1, Number(opts.minGap) || 1);

  var windows = [];
  var i;
  var list = toArray(toplevels);
  for (i = 0; i < list.length; i++) {
    var rect = windowRect(list[i]);
    if (rect && rect.address) windows.push(rect);
  }

  var rails = mergeRails(findRails(windows, maxGap, minOverlap, minGap));

  var out = [];
  var ox = Number(monitorX) || 0;
  var oy = Number(monitorY) || 0;
  for (i = 0; i < rails.length; i++) {
    var r = rails[i];
    out.push({
      orientation: r.orientation,
      x: r.x - ox,
      y: r.y - oy,
      w: r.w,
      h: r.h,
      resizeAddress: r.resizeAddress
    });
  }
  return out;
}

// Expose the pieces for unit tests and the aggregate for the shell.
var api = {
  collect: collect,
  toArray: toArray,
  windowRect: windowRect,
  findRails: findRails,
  mergeSeam: mergeSeam,
  mergeRails: mergeRails,
  detectMove: detectMove
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = api;
}
