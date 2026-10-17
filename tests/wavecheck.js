// Verify that the lightbar's colour wave travels along the bar's length.
//
//   node tests/wavecheck.js <png1> <png2> <elapsedSeconds> <barLengthPx> \
//        <crossCoord> <periodSeconds> <col|row>
//
// Samples a one-pixel line along the bar (a column for a vertical bar, a row for
// a horizontal one) in each capture, converts it to hues, then cross-correlates
// the two profiles to find how far the pattern travelled. `col` measures travel
// down the bar, `row` travel to the right.
//
// A good match has a tiny mean hue error (a few thousandths); a wrong shift
// leaves an error of order 0.2, since the ramp spans a full hue cycle.
"use strict";

const { execFileSync } = require("child_process");

const [, , p1, p2, elapsedArg, lengthArg, crossArg, periodArg, axisArg] = process.argv;
const elapsed = Number(elapsedArg);
const barLength = Number(lengthArg);
const cross = Number(crossArg);
const period = Number(periodArg || 3.0);
const axis = axisArg === "row" ? "row" : "col";

function lineHues(png) {
  // A one-pixel line straight along the bar, cropped out of the capture.
  const crop = axis === "row" ? `${barLength}x1+0+${cross}` : `1x${barLength}+${cross}+0`;
  const txt = execFileSync("magick", [png, "-crop", crop, "+repage", "txt:-"]).toString();
  const hues = [];
  for (const line of txt.split("\n")) {
    const m = line.match(/^(\d+),(\d+):\s*\((\d+),(\d+),(\d+)/);
    if (!m) continue;
    const r = Number(m[3]) / 255;
    const g = Number(m[4]) / 255;
    const b = Number(m[5]) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const d = max - min;
    let h = 0;
    if (d > 0) {
      if (max === r) h = ((g - b) / d) % 6;
      else if (max === g) h = (b - r) / d + 2;
      else h = (r - g) / d + 4;
      h /= 6;
      if (h < 0) h += 1;
    }
    hues.push({ at: Number(axis === "row" ? m[1] : m[2]), h: h });
  }
  return hues;
}

function hueDistance(a, b) {
  const d = Math.abs(a - b) % 1;
  return Math.min(d, 1 - d);
}

const c1 = lineHues(p1);
const c2 = lineHues(p2);
const n = Math.min(c1.length, c2.length);
const where = axis === "row" ? "x" : "y";

console.log(`sampled ${n}px along the bar (1px steps), elapsed ${elapsed.toFixed(3)}s, bar length ${barLength}px`);

console.log(`\nhue along the bar (every 25px):`);
let row = `  ${where}   :`;
for (let i = 0; i < n; i += 25) row += String(c1[i].at).padStart(6);
console.log(row);
row = "  cap1:";
for (let i = 0; i < n; i += 25) row += c1[i].h.toFixed(3).padStart(6);
console.log(row);
row = "  cap2:";
for (let i = 0; i < n; i += 25) row += c2[i].h.toFixed(3).padStart(6);
console.log(row);

// Hue span along the bar proves the ramp runs along the length rather than
// across the thickness.
let lo = 1, hi = 0;
for (const s of c1) { if (s.h < lo) lo = s.h; if (s.h > hi) hi = s.h; }
console.log(`\nhue span along the length: ${lo.toFixed(3)}..${hi.toFixed(3)}`);

// Best shift of cap2 against cap1, searched both ways. shift > 0 means
// cap2(at) matches cap1(at + shift), so the pattern moved by -shift.
let best = null;
for (let shift = -350; shift <= 350; shift++) {
  let err = 0;
  let count = 0;
  for (let i = 0; i < n; i++) {
    const j = i + shift;
    if (j < 0 || j >= n) continue;
    err += hueDistance(c1[j].h, c2[i].h);
    count++;
  }
  if (count < 100) continue;
  err /= count;
  if (!best || err < best.err) best = { shift: shift, err: err, pairs: count };
}

const travel = -best.shift;
const expected = elapsed / period * barLength;
console.log(`\nbest match: cap2(${where}) == cap1(${where} + ${best.shift}) over ${best.pairs}px` +
  `  (mean hue error ${best.err.toFixed(4)})`);
console.log(`=> the pattern travelled ${travel > 0 ? "+" : ""}${travel}px along the bar`);
console.log(`expected ${expected > 0 ? "+" : ""}${expected.toFixed(0)}px`);
const ok = Math.abs(travel - expected) < Math.max(60, Math.abs(expected) * 0.3);
console.log(ok ? "MATCH: the colours scroll along the bar" : "NO MATCH");
process.exitCode = ok ? 0 : 1;
