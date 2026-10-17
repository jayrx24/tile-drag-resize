# Tile Drag & Resize

<https://github.com/jayrx24/tile-drag-resize>

An Omarchy shell plugin that combines two mouse-first window controls into a
single unit:

- **Gap resize** — move the pointer into the real gap between two tiled
  windows. A lightbar appears only over that gap; drag with the left mouse
  button to resize the adjacent tiles. The bar rides along with the seam as you
  drag, and cycles through a slow colour ramp while it is lit.
- **Middle-drag** — hold the middle mouse button over any window to move it,
  the same way `Super` + left-drag does, without touching the keyboard. A bar
  icon toggles it on and off.

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

The bar's colour ramp is derived from the theme accent and drifts through the
hue wheel over about sixteen seconds; it only animates while a bar is on
screen, so an idle shell does no per-frame colour work.

**Middle-drag.** Click the bar icon once, or right-click it, to toggle the
feature. The icon shows a mouse (`󰍽`) when on and a crossed-out mouse (`󰍾`)
when off.

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
```

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
| `GapOverlay.qml` | One transparent layer-shell surface per monitor; only gap corridors take input. |
| `GapGeometry.js` | Pure geometry that turns tiled-window rectangles into draggable gap rails. Unit-tested under Node. |
| `BarWidget.qml` | The bar icon and its click behaviour. |
| `Panel.qml` | The options dropdown. |

## Tests

```bash
node tests/geometry.test.js
```

18 assertions cover window extraction, seam detection, full-height merging,
resize targeting, monitor-local conversion, and the QML window-list shapes the
shell actually hands the module.

## License

MIT.
