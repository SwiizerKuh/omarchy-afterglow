# Trajectory Plot

A live, cassette-futurist trajectory plot for the Omarchy desktop.

![Trajectory Plot](preview.png)

Spacecraft cross a plotting grid, leaving dotted trails that hold and then
fade before the next heading comes in. Around them sits an instrument HUD
in the style of late-70s and early-80s sci-fi screens: an orbital plot, a
radar scope with a stepped sweep, station markers, a debris point cloud, tick
rulers, telemetry readouts, and callouts that flag the occasional contact
with a blinking `WARNING` or a `TARGET LOCK`. The whole thing is bent through
a CRT shader with curvature, scanlines, phosphor glow and edge fringing.

It **follows your Omarchy theme.** Every colour comes from the active
theme's palette and updates live when you run `omarchy theme set`. It works
on dark and light themes alike.

## Install

```sh
omarchy plugin add https://github.com/SwiizerKuh/omarchy-trajectory-plot.git --enable
```

It appears on every monitor straight away.

### Setup

`omarchy plugin add` never runs code from a plugin, so the setup comes a
moment later instead. The first time the plugin loads, a short setup opens
in a floating terminal, styled to your theme:

![Setup](docs/setup.png)

1. **Customize the Trajectory Plot?** Choose *Not now* to keep the defaults.
2. **CRT effects:** on (curvature, scanlines, phosphor glow) or off.
3. **Visuals:** *Full*, or *Minimal* without the radar scope.
4. **Save?** Nothing is written until you confirm.

Your answers are merged into `~/.config/omarchy/trajectory-plot.json`. Only
the keys it asked about (`crt.enabled`, `hud.scope`) are set; anything else
in the file is kept. The setup is offered once, and never if you already have
a config file. Run it again any time:

```sh
omarchy-shell io.github.swiizerkuh.trajectory-plot setup
```

## Remove

```sh
omarchy plugin remove io.github.swiizerkuh.trajectory-plot
```

The plugin only writes to your configuration when you choose *Save* in the
setup. To remove every trace, also delete `~/.config/omarchy/trajectory-plot.json`
(if you saved settings) and `~/.local/state/trajectory-plot/` (a one-line
marker recording that the setup was offered).

## How it sits on your desktop

Trajectory Plot does **not** replace Omarchy's background plugin. It draws on
its own layer between your wallpaper and your windows:

- your wallpaper, wallpaper cycling, transitions and the desktop's
  double-click menus keep working as before;
- the layer is click-through, so it never takes input;
- removing or disabling the plugin leaves your desktop exactly as it was.

By default a soft wash of your theme's background colour (`backdrop`) sits
behind the plot, so it stays legible over busy photo wallpapers. Set it to
`0` on a dark, plain wallpaper for the purest look.

## Requirements

- Omarchy with the Quattro shell (the Quickshell-based `omarchy-shell`).
- `gum` and `jq` for the setup. Both ship with Omarchy.
- Nothing else. There are no services, daemons or elevated privileges. The
  CRT shader ships precompiled as `crt.frag.qsb`, with its source in
  `crt.frag`.

## Configure

Settings are JSON, layered, with later layers overriding earlier ones key
by key:

| Layer | File | Who it's for |
|---|---|---|
| 1 | `defaults.json` in this plugin | the reference for every key |
| 2 | `trajectory-plot.json` in the **active theme** | theme authors |
| 3 | `~/.config/omarchy/trajectory-plot.json` | you |

You only need to include the keys you want to change. Your file and the
theme's file are watched, so edits apply straight away.

```json
{
  "backdrop": 0.35,
  "paths": 4,
  "crt": { "curvature": 0.03, "scanlineAlpha": 0.15 },
  "hud": {
    "scope": false,
    "text": { "tracking": "UPLINK:NOMINAL", "identTitle": "Pathfinder Mk. 2" }
  }
}
```

### Colours

Colour settings take either a **theme role** or a literal `"#rrggbb"`.
Roles keep the plot in step with whatever theme is active:

| Role | Comes from `colors.toml` | Used for |
|---|---|---|
| `foreground` | `foreground` | grid, HUD lines, text, most trails |
| `accent` | `accent` | attention: `TARGET LOCK`, lamps, the logo |
| `urgent` | `red` | fault: `WARNING` |
| `muted` | `muted` | available for your own palette |
| `background` | `background` | the backdrop, text on filled bars |

Keys: `gridColor`, `colors` (the trail palette, e.g.
`["foreground", "foreground", "accent"]`; repeat an entry to weight it),
`crt.halationTint`, `hud.warningColor`, `hud.targetColor`.

On light themes the phosphor glow switches off, because glow reads as a
smudge on a light ground. Set `crt.halationOnLight` to `true` to keep it.

### Main keys

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Turn the whole plot off without removing the plugin. |
| `backdrop` | `0.55` | Opacity of the theme-background wash over your wallpaper. |
| `paths` | `3` | Concurrent trajectories (max 8). |
| `tickMs` | `100` | Clock step. Motion is deliberately stepped (see below). |
| `cell`, `gridMajorEvery`, `gridAlpha`, `gridMajorAlpha` | | The grid. |
| `raster`, `dotSize`, `dotSpacing` | | Trail dots and the pixel grid they snap to. |
| `crossMin/Max`, `holdMin/Max`, `fadeMin/Max`, `gapMin/Max` | | Trajectory timing in ms. |

### `crt`

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | The whole CRT treatment. |
| `curvature` | `0.042` | Barrel strength, 0–0.4. |
| `scanlines`, `scanlinePitch`, `scanlineAlpha` | on, 3, 0.22 | Scanlines, which bend with the tube. |
| `mask`, `maskAlpha` | off | Vertical shadow mask. |
| `halation`, `halationStrength`, `halationRadius`, `halationTint`, `halationColorize` | on | Phosphor glow. |
| `vignette`, `vignetteAlpha`, `vignetteSpread` | on | Edge falloff. |
| `aberration` | `0.8` | R/B fringing at the edges, in px. |
| `supersample` | `1.5` | Render scale before the warp, which keeps 1px lines crisp. |

### `hud`

Every element can be switched on or off: `frame`, `rulers`, `scale`,
`headers`, `telemetry`, `status`, `orbit`, `scope`, `stations`, `cloud`,
`callouts`, `identLogo`. Also available:

| Key | Default | Meaning |
|---|---|---|
| `alpha` | `0.34` | Brightness of the HUD line work. |
| `inset`, `topInset`, `bandTop` | 22, 94, 38 | Frame and header-band placement. |
| `clipToFrame` | `true` | Keep the grid, trails and instruments inside the frame. |
| `orbitX/Y/Radius`, `scopeX/Y/Radius` | | Instrument placement (fractions of the screen). |
| `cloudCount/X/Spread/Height` | | The debris field. |
| `warningChance`, `targetChance` | 0.12, 0.14 | Odds that a trajectory gets a callout. |
| `text.tracking`, `text.identTitle`, `text.identName`, `text.identCode` | | Header text. |

`defaults.json` lists every key with its default.

## For theme authors

Ship a `trajectory-plot.json` in your theme directory to style the plot for
your theme. It is picked up when your theme is applied and dropped when the
user switches away. See [`examples/cassette-futurism.json`](examples/cassette-futurism.json)
for a complete example: a black-and-white theme with orange and burgundy
accents, and no backdrop.

## Performance

Measured on a 2256×1504 laptop panel (Intel, Omarchy Quattro), as CPU of the
shell process with the plugin enabled versus disabled:

| Configuration | Shell CPU |
|---|---|
| Plugin disabled | ~1% |
| Defaults | ~10% of one core |
| `"tickMs": 200` | ~6% |
| Battery saver (below) | ~4% |

Nearly all of the cost is the clock rate: each step re-renders the plot and
runs the CRT pass. For a laptop on battery:

```json
{ "tickMs": 250, "paths": 2, "crt": { "halation": false, "supersample": 1.0 } }
```

Motion is stepped on purpose. One shared clock drives everything, so the
scene sits idle between steps instead of redrawing at 60fps, and discrete
jumps suit a radar plot better than smooth motion. Static artwork (grid,
frame, rings, point cloud) is drawn once and reused, and the CRT pass runs on
the GPU.

## Updating

```sh
omarchy plugin update io.github.swiizerkuh.trajectory-plot
omarchy restart shell
```

Service plugins are not re-created on hot reload, so restart the shell after
an update. Config file changes do not need a restart.

## Editing the shader

```sh
/usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o crt.frag.qsb crt.frag
omarchy restart shell
```

`qsb` is in the `qt6-shadertools` package. You only need it to change the
shader, not to run the plugin.

## License

MIT. See [LICENSE](LICENSE).
