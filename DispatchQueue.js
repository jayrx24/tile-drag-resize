// DispatchQueue.js
//
// Pure queue logic for the commands the shell sends Hyprland over its request
// socket. No QML and no side effects, so it can be unit-tested under Node as
// well as loaded by the shell through `import "DispatchQueue.js" as ...`.
//
// The queue exists for one reason: a drag issues *relative* resize deltas far
// faster than the socket round trip, and only one command can be in flight at a
// time. Rather than let the queue grow, a resize merges with the resize already
// waiting for the same window — relative deltas add up, so merging loses
// nothing, and the seam always ends up exactly where the pointer left it.
//
// Entries are plain objects:
//   { kind: "resize", address, dx, dy }
//   { kind: "prop",   address, prop, value, flag }

"use strict";

// Far more than a drag can produce once resizes merge; a hard cap so a broken
// consumer can never grow the queue without bound.
var LIMIT = 32;

// Add `entry` to `queue`, returning the new queue. A resize only ever merges
// with the *last* entry, so it can never overtake a property change already
// queued (the property must land first).
function enqueue(queue, entry) {
  var q = queue ? queue.slice() : [];
  if (entry && entry.kind === "resize" && q.length > 0) {
    var last = q[q.length - 1];
    if (last.kind === "resize" && last.address === entry.address) {
      // Copy rather than mutate: callers hand us their live queue.
      q[q.length - 1] = {
        kind: "resize",
        address: last.address,
        dx: (last.dx || 0) + (entry.dx || 0),
        dy: (last.dy || 0) + (entry.dy || 0)
      };
      return q;
    }
  }
  q.push(entry);
  while (q.length > LIMIT) q.shift();
  return q;
}

// Take the oldest entry, returning { entry, queue } (entry is null when the
// queue is empty).
function take(queue) {
  var q = queue ? queue.slice() : [];
  if (q.length === 0) return { entry: null, queue: q };
  return { entry: q.shift(), queue: q };
}

var api = {
  LIMIT: LIMIT,
  enqueue: enqueue,
  take: take
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = api;
}
