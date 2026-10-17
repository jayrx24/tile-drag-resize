// Probe the live compositor and show what rails GapFloater would create.
// Run:  node tests/probe-live.js
"use strict";

const { execFileSync } = require("child_process");
const G = require("../GapGeometry.js");

const OPTS = { maxGap: 56, minOverlap: 24, minGap: 2 };

function hyprctlJson(args) {
  return JSON.parse(execFileSync("hyprctl", ["-j", ...args]).toString());
}

const monitors = hyprctlJson(["monitors"]);
const clients = hyprctlJson(["clients"]);

for (const mon of monitors) {
  const ws = mon.activeWorkspace;
  const toplevels = clients.filter(
    (c) => c.workspace && c.workspace.id === ws.id && c.monitor === mon.id
  );
  const rails = G.collect(mon.x, mon.y, toplevels, OPTS);
  console.log(
    `monitor ${mon.name} (${mon.width}x${mon.height} @ ${mon.x},${mon.y}) ws "${ws.name}" ` +
      `windows=${toplevels.length} rails=${rails.length}`
  );
  for (const t of toplevels) {
    console.log(`    win ${t.address} at=${JSON.stringify(t.at)} size=${JSON.stringify(t.size)} float=${t.floating}`);
  }
  for (const r of rails) {
    console.log(
      `    rail ${r.orientation.padEnd(10)} x=${r.x} y=${r.y} w=${r.w} h=${r.h} ` +
        `-> resize ${r.resizeAddress}`
    );
  }
}
