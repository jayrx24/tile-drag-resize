#!/usr/bin/env bash
# Live end-to-end test for the middle-drag border. Needs a running Hyprland
# session with this plugin enabled, and `foot` for a throwaway window.
#
# A real middle-drag cannot be synthesised without injecting input, but a drag is
# a *rigid* pairing — Hyprland keeps the grabbed point under the pointer — and
# that is easy to reproduce: move the pointer and the window by the same amount.
# What is being tested is the plugin's reaction to a rigidly-moving window, which
# is the same either way.
#
# Checks, in order:
#   1. moving pointer+window together lights the border and locks to the pointer
#   2. holding both still keeps the border (a pause is not a release)
#   3. moving the pointer alone drops it
#   4. everything goes quiet afterwards
#
# Usage:  tests/drag-live.sh
set -u

IPC="omarchy shell tile-drag-resize"
CLASS="tile-drag-test"
fails=0

status() { timeout 3 $IPC dragstatus; }
field() { status | tr ' ' '\n' | sed -n "s/^$1=//p"; }

check() { # name expected actual
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected $2, got $3"
    fails=$((fails + 1))
  fi
}

ev() { hyprctl eval "$1" >/dev/null 2>&1; }

cleanup() {
  [ -n "${FOOT_PID:-}" ] && kill "$FOOT_PID" 2>/dev/null
  wait "$FOOT_PID" 2>/dev/null
}
trap cleanup EXIT

# ---- a test window we own, so nothing else is touched ----------------------
foot -a "$CLASS" >/dev/null 2>&1 &
FOOT_PID=$!
sleep 1.5
ADDR=$(hyprctl -j clients | jq -r --arg c "$CLASS" '[.[] | select(.class==$c)][0].address')
if [ -z "$ADDR" ] || [ "$ADDR" = "null" ]; then
  echo "could not open a $CLASS window (is foot installed?)"; exit 1
fi
if [ "$(hyprctl -j clients | jq -r --arg a "$ADDR" '.[] | select(.address==$a) | .floating')" != "true" ]; then
  ev "hl.dispatch(hl.dsp.window.float({ action = \"toggle\", window = \"address:$ADDR\" }))"
  sleep 0.5
fi
read -r X Y W H <<<"$(hyprctl -j clients | jq -r --arg a "$ADDR" '.[] | select(.address==$a) | "\(.at[0]) \(.at[1]) \(.size[0]) \(.size[1])"')"
CX=$((X + W / 2)); CY=$((Y + H / 2))
ev "hl.dispatch(hl.dsp.cursor.move({ x = $CX, y = $CY }))"
sleep 0.6
echo "test window $ADDR ${W}x${H} at $X,$Y"

check "idle is quiet" "false" "$(field active)"

# ---- 1. drag: pointer and window move together ----------------------------
for _ in $(seq 1 12); do
  CX=$((CX + 24)); CY=$((CY + 8))
  ev "hl.dispatch(hl.dsp.cursor.move({ x = $CX, y = $CY }))
      hl.dispatch(hl.dsp.window.move({ x = 24, y = 8, relative = true, window = \"address:$ADDR\" }))"
  sleep 0.05
done
check "drag detected" "true" "$(field active)"
check "locked to the pointer" "true" "$(field locked)"

# ---- 2. pause: nothing moves, the button is still held --------------------
sleep 1.6
check "border survives a pause" "true" "$(field active)"

# ---- 3. release: the pointer moves and the window does not ----------------
CX=$((CX + 240))
ev "hl.dispatch(hl.dsp.cursor.move({ x = $CX, y = $CY }))"
sleep 0.5
check "release drops the border" "false" "$(field active)"
check "release was seen as a mismatch" "miss" "$(field why)"

# ---- 4. no leftover polling ----------------------------------------------
sleep 0.4                       # let the last in-flight sample land
S1=$(field cursamples)
sleep 1.0
S2=$(field cursamples)
check "pointer feed stopped" "off" "$(field feed)"
check "no samples while idle" "$S1" "$S2"

if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
