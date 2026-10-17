# Tile Drag & Resize

<https://github.com/jayrx24/tile-drag-resize>

An Omarchy shell plugin that combines two mouse-first window controls into a
single unit:

- **Gap resize** — move the pointer into the real gap between two tiled
  windows. A lightbar appears only over that gap; drag with the left mouse
  button to resize the adjacent tiles. The bar rides along with the seam as you
  drag, and scrolls a colour ramp along its length while it is lit.
- **Middle-drag** — hold the middle mouse button over any window to move it,
  the same way `Super` + left-drag does, without touching the keyboard. While
  the window moves, a thin lightbar border in the same colours flows around it.
  A bar icon toggles the feature on and off.

The two features share one manifest, one service, and one bar icon, so there is
nothing extra to enable or keep in sync.

## Requirements

- Omarchy Quattro with the Quickshell shell.
- Hyprland 0.56+ (Lua config) for the tidiest behaviour; the resize/legacy
  fallbacks keep older builds working.
- A tiled layout (`dwindle` or `master`).

## Install

```bash
omarchy plugin add https://github.com/jayrx24/tile-drag-resize --enable --yes
```

Or from a local checkout:

```bash
omarchy plugin add file:///path/to/tile-drag-resize --enable --yes
```

Then place the icon if you like:

```bash
omarchy bar move io.github.jayrx24.tile-drag-resize --section right
```

> Editing a plugin's QML while the shell is running has no effect: Quickshell
> caches components for the life of the process. Restart the shell
> (`omarchy restart shell`) to load changes.

## Usage

**Gap resize.** Open two or more tiled windows and move the pointer into the
space between adjacent windows. When the lightbar and the resize cursor appear,
drag with the left mouse button. The lightbar tracks the seam while you drag, so
it stays on the edge it is moving. Floating, fullscreen, hidden, and pinned
windows are ignored.

A resize drag dispatches on every pointer motion, so two things matter more than
the command itself. First, the command goes over Hyprland's request socket
rather than through a spawned `hyprctl` — about 0.05 ms instead of 3 ms plus a
fork per event, fast enough for the window to keep up with the pointer. Bursts
are merged: a drag issues *relative* deltas, and consecutive ones for the same
window add up, so at most one command is in flight and none of the motion is
lost (`DispatchQueue.js`). If the socket stops answering, it falls back to the
process-per-resize path.

Second, Hyprland animates window size changes (`windows` in the animation
config, ~260 ms here), and every dispatch would restart that animation, leaving
the edge crawling after the pointer. While a rail is being dragged the window
gets the `no_anim` property, so the edge lands where the pointer puts it, and
the property is dropped again on release. It is a *runtime*, per-window property
— no config file is written, nothing else on screen is affected, and it goes
away with the window. If the running Hyprland does not know the property, the
command is ignored and the resize behaves exactly as it did before.

The bar's colour ramp is derived from the theme accent and scrolls *along* the
bar: up/down for a vertical split, side to side for a horizontal one. One full
colour cycle takes three seconds — `wavePeriod` in `GapOverlay.qml`; lower is
faster. It only animates while a bar is on screen, so an idle shell does no
per-frame colour work.

**Middle-drag.** Click the bar icon once, or right-click it, to toggle the
feature. The icon shows a mouse (`󰍽`) when on and a crossed-out mouse (`󰍾`)
when off.

While you drag a window, a six-pixel lightbar border appears around it and
flows around the perimeter in the same colours as the gap bars.

Hyprland emits no drag begin/end event and the shell cannot see the mouse button,
so the drag is *detected* from geometry: a window that changes position while
keeping its size has been dragged. Two samples in a row are needed, which keeps
ordinary layout changes (one sample) and gap resizes (a size change) from
lighting anything up (`movePollMs`, `moveConfirmSamples`).

Geometry is a poor *tracker*, though — a geometry sample is only as fresh as the
request that produced it, which leaves the border visibly trailing the window.
The pointer is exact: Hyprland drags a window by keeping the grabbed point under
the cursor, so for the whole drag the window's origin is `pointer - grab`. The
pointer is read over Hyprland's request socket (the only way to get it — there is
no cursor API and no pointer events) and, once the grab offset is known, the
border is driven straight from it, near display rates, so it sits on the window
instead of chasing it.

The same lock is what ends the drag. There is no release event either, so the
window has to stay where the pointer says for as long as the button is held: the
pointer may wander, but the window has to come with it. A window that stops
following has been released (or dropped and re-tiled). A pause therefore does
*not* end the drag — the window resting is perfectly consistent with a held
button — and the border disappears as soon as the pointer next moves without the
window. If the pointer feed is ever unavailable, the border falls back to the
geometry-only behaviour (poll, hold for `moveGraceMs` after the motion stops).
`moveLockTol`, `moveLockMisses`, `cursorPollMs`, and `moveFeedMs` in
`Service.qml` tune all of that; `moveMaxMs` is a hard stop so nothing can stick.

Nothing runs while idle: the pointer feed and the fast geometry poll only start
once a drag is suspected (or a focus event suggests one is coming) and stop again
when it ends. While a window is moving, the gap bars are left alone so they do
not flicker along with the shifting layout.

The border is `thickness` pixels wide — 6, set in `GapOverlay.qml` next to the
colour ramp — and it is drawn inside the window's edges, so a thicker border
covers more of the window.

The service turns off Hyprland's own border resizing (`general:resize_on_border`
and `general:hover_icon_on_border`) at runtime so the gap overlay owns the
window edges. No configuration file is written; restore border resizing after
removing the plugin with:

```bash
hyprctl keyword general:resize_on_border true
hyprctl keyword general:hover_icon_on_border true
```

## IPC

```bash
omarchy shell tile-drag-resize toggle    # flip middle-drag on/off
omarchy shell tile-drag-resize enable    # middle-drag on
omarchy shell tile-drag-resize disable   # middle-drag off
omarchy shell tile-drag-resize status    # prints "enabled" or "disabled"
omarchy shell tile-drag-resize reapply   # re-assert border settings and the bind
omarchy shell tile-drag-resize preview   # pin the move border on for 8s (visual check)
omarchy shell tile-drag-resize dragstatus # what the move detector currently sees
omarchy shell tile-drag-resize snapshot  # every window rectangle the detector tracks
omarchy shell tile-drag-resize resizeby 40 0  # resize the focused window (checks the dispatch path)
omarchy shell tile-drag-resize noanim 1       # raise/drop no_anim on the focused window
omarchy shell tile-drag-resize dispatchstatus # queue and socket state of the resize path
```

`preview` outlines one window for eight seconds without dragging anything, which
is the quickest way to check the border's styling. `dragstatus` prints what the
detector sees (`moving=`, `active=`, `streak=`, `locked=`, `miss=`, `grab=`,
`gap=`/`lag=` for how old the pointer sample was, `res=` for how far the window
sat from where the pointer put it, `resmax=` for the worst that got during a
healthy drag, `feed=` whether the pointer feed is running, `why=` why the last
drag ended, `rect=`) and is the first thing to reach for if the border does not
appear while dragging; `snapshot` dumps the rectangles it is comparing, which
shows whether the window is being seen at all.

State lives at `$XDG_STATE_HOME/tile-drag-resize/enabled` (`~/.local/state` by
default).

## Keybinding

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + M", "Toggle Tile Drag & Resize", "omarchy shell tile-drag-resize toggle")
```

## Layout

| File | Role |
| --- | --- |
| `manifest.json` | Plugin id, kinds (`service`, `bar-widget`), entry points. |
| `Service.qml` | Owns both features: gap geometry refresh, overlay construction, resize dispatch, middle-drag state, bind management, IPC. |
| `GapOverlay.qml` | One transparent layer-shell surface per monitor; only gap corridors take input. Also draws the drag border. |
| `GapGeometry.js` | Pure geometry that turns tiled-window rectangles into draggable gap rails, plus the pure-translation test that recognises a drag and the pointer-tracking maths (time-aligned sample lookup, lock error). Unit-tested under Node. |
| `DispatchQueue.js` | Pure queue for commands sent over Hyprland's request socket: merges consecutive resizes of the same window, so a drag issues one command at a time without losing any motion. Unit-tested under Node. |
| `BarWidget.qml` | The bar icon and its click behaviour. |
| `Panel.qml` | The options dropdown. |

## Tests

```bash
node tests/geometry.test.js
```

30 assertions cover window extraction (including the floating-window exception
the drag border needs), seam detection, full-height merging, resize targeting,
move detection (a drag is a position change with no size change; layout shifts,
resizes, and sub-pixel jitter are all rejected), the pointer-tracking maths
(time-aligned interpolation, history trimming, the lock error a release leaves
behind), monitor-local conversion, and the QML window-list shapes the shell
actually hands the module. Six more cover the dispatch queue: resizes merging,
resizes *not* merging past a queued property change, and the queue staying
immutable and bounded.

The middle-drag path also has a live end-to-end test:

```bash
tests/drag-live.sh
```

It opens its own throwaway window (via `foot`), drags it the way a real drag
moves — pointer and window together — and then checks the four things that
matter: the border lights up and locks to the pointer, it survives a pause
*without* the pointer moving, it drops as soon as the pointer moves and the
window does not, and nothing keeps polling afterwards. It takes over the pointer
for a few seconds and needs a running Hyprland session.

Two live diagnostics are included as well:

```bash
node tests/probe-live.js    # the rails the compositor is really producing
node tests/wavecheck.js <png1> <png2> <elapsed> <len> <cross> <period> col|row
```

`probe-live` is the first thing to reach for when a gap does not light up.
`wavecheck` measures the colour wave from two screenshots taken a known time
apart along a bar, and is what confirmed the ramp runs along the bar's length
and travels down it (or along it) at the expected speed; it needs `grim` and
ImageMagick.

## License

MIT.
