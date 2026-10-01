// Afterglow -- a live, CRT-styled trajectory plot for the Omarchy
// desktop: a grid, spacecraft trails that cross it and fade, and a
// retro-futurist instrument HUD, all bent through a CRT shader.
//
// It does NOT replace Omarchy's background plugin. It draws on its own
// click-through layer between the wallpaper and your windows, so your
// wallpaper, its transitions and its double-click menus all keep working, and
// removing the plugin leaves nothing behind.
//
// Colours are theme roles resolved against the live Omarchy palette, so the
// plot follows `omarchy theme set` instantly.
//
// Configuration is layered, later files winning key by key:
//   1. defaults.json                                    (this plugin)
//   2. ~/.local/state/omarchy/current/theme/afterglow.json  (the theme)
//   3. ~/.config/omarchy/afterglow.json           (you)

pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string defaultsPath: Qt.resolvedUrl("defaults.json").toString().replace(/^file:\/\//, "")
  readonly property string themeConfigPath: home + "/.local/state/omarchy/current/theme/afterglow.json"
  readonly property string userConfigPath: home + "/.config/omarchy/afterglow.json"

  property var defaultsCfg: ({})
  property var themeCfg: ({})
  property var userCfg: ({})

  function parse(raw) {
    var text = String(raw || "").trim()
    if (!text) return ({})
    try {
      var v = JSON.parse(text)
      return (v && typeof v === "object" && !Array.isArray(v)) ? v : ({})
    } catch (e) {
      console.warn("afterglow: ignoring invalid JSON: " + e)
      return ({})
    }
  }

  // Objects merge key by key; anything else (numbers, strings, arrays such as
  // the trail palette) is replaced outright by the later layer.
  function merge(a, b) {
    var out = ({})
    var k
    for (k in a) out[k] = a[k]
    for (k in b) {
      var av = out[k], bv = b[k]
      if (av && bv && typeof av === "object" && typeof bv === "object"
          && !Array.isArray(av) && !Array.isArray(bv)) out[k] = root.merge(av, bv)
      else out[k] = bv
    }
    return out
  }

  readonly property var baseConfig: root.merge(root.merge(root.defaultsCfg, root.themeCfg), root.userCfg)

  // On battery, the `battery` block (defaults.json: a slower clock and slower
  // sampling) is merged over everything else. Machines without a battery
  // never see it.
  property bool onBattery: false
  readonly property var config: root.onBattery && root.baseConfig.battery
    && typeof root.baseConfig.battery === "object"
    ? root.merge(root.baseConfig, root.baseConfig.battery)
    : root.baseConfig
  readonly property bool pauseWhenCovered: root.config.pauseWhenFullscreen !== false

  // Find the mains adapter once; then poll its `online` file (sysfs files
  // can't be watched). Desktops have no adapter and stay on mains settings.
  property string acOnlinePath: ""
  Process {
    running: true
    command: ["bash", "-c",
      'for d in /sys/class/power_supply/*; do [ "$(cat "$d/type" 2>/dev/null)" = Mains ] && { echo "$d/online"; exit; }; done']
    stdout: SplitParser { onRead: function(line) { root.acOnlinePath = String(line || "").trim() } }
  }
  FileView {
    id: acFile
    path: root.acOnlinePath
    printErrors: false
    onLoaded: root.onBattery = String(text() || "").trim() === "0"
    onLoadFailed: root.onBattery = false
  }
  readonly property bool plotEnabled: root.config.enabled !== false

  FileView {
    path: root.defaultsPath
    printErrors: false
    onLoaded: root.defaultsCfg = root.parse(text())
    onLoadFailed: root.defaultsCfg = ({})
  }

  // The theme directory is replaced wholesale by `omarchy theme set`, which
  // drops inotify watches inside it; re-read whenever the palette changes and
  // on a slow timer as a backstop. text() is stale inside a change signal, so
  // always go back through reload() -> onLoaded.
  FileView {
    id: themeFile
    path: root.themeConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themeCfg = root.parse(text())
    onLoadFailed: root.themeCfg = ({})
  }

  FileView {
    id: userFile
    path: root.userConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.userCfg = root.parse(text())
    onLoadFailed: root.userCfg = ({})
  }

  Connections {
    target: Color
    function onForegroundChanged() { themeFile.reload() }
    function onBackgroundChanged() { themeFile.reload() }
    function onAccentChanged() { themeFile.reload() }
  }

  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: {
      if (root.acOnlinePath) acFile.reload()
      themeFile.reload()
      userFile.reload()
    }
  }

  // ---- setup wizard -----------------------------------------------------------
  //
  // `omarchy plugin add` deliberately runs nothing from a plugin, so the setup
  // is offered here instead: the first time the plugin loads, in a floating
  // themed terminal, the same way Omarchy's own setup wizards appear. It is
  // offered exactly once -- bin/setup marks it offered as soon as it opens --
  // and never when the user already has a config file. It only writes after
  // an explicit "Save". Re-run any time with:
  //
  //   omarchy-shell io.github.swiizerkuh.afterglow setup
  readonly property string setupScript: Qt.resolvedUrl("bin/setup").toString().replace(/^file:\/\//, "")
  readonly property string setupMarker: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state"))
    + "/afterglow/setup-offered"

  function launchSetup(onlyIfFirstRun) {
    var guard = onlyIfFirstRun ? '[[ -e "$1" || -e "$2" ]] && exit 0; ' : ''
    setupProc.command = ["bash", "-c",
      guard + 'exec omarchy-launch-floating-terminal-with-presentation "$3"',
      "afterglow-setup", root.setupMarker, root.userConfigPath, root.setupScript]
    if (!setupProc.running) setupProc.running = true
  }

  Process { id: setupProc }

  // ---- system monitor -----------------------------------------------------------
  //
  // bin/sysmon is started once for the whole session -- not once per screen --
  // and streams a JSON line per sample: RAM and GPU load. It reads /proc and
  // /sys only. Every screen's HUD draws from this one feed.
  readonly property var hudCfg: (root.config && typeof root.config.hud === "object") ? root.config.hud : ({})
  readonly property bool sysmonEnabled: root.plotEnabled
    && root.hudCfg.enabled !== false && root.hudCfg.sysmon !== false
  readonly property int sysmonInterval: Math.max(500, Number(root.hudCfg.sysmonInterval) || 2000)
  readonly property string sysmonScript: Qt.resolvedUrl("bin/sysmon").toString().replace(/^file:\/\//, "")
  property var sys: ({})
  property int sysSeq: 0

  // A running process keeps the command it was started with, so a new
  // interval (e.g. switching to the battery profile) means a restart.
  onSysmonIntervalChanged: {
    if (!sysmonProc.running) return
    sysmonProc.running = false
    Qt.callLater(function() { sysmonProc.running = root.sysmonEnabled })
  }

  Process {
    id: sysmonProc
    command: [root.sysmonScript, String(root.sysmonInterval)]
    running: root.sysmonEnabled
    stdout: SplitParser {
      onRead: function(line) {
        try {
          root.sys = JSON.parse(String(line || ""))
          root.sysSeq += 1
        } catch (e) {
          // a partial or malformed line: skip it, the next sample replaces it
        }
      }
    }
    // If the sampler ever exits while it should be running, bring it back.
    onRunningChanged: if (!running && root.sysmonEnabled) sysmonRestart.restart()
  }

  Timer {
    id: sysmonRestart
    interval: 5000
    onTriggered: if (root.sysmonEnabled && !sysmonProc.running) sysmonProc.running = true
  }

  // A short delay, so a first load at login doesn't race the rest of the
  // session coming up.
  Timer {
    interval: 3000
    running: true
    onTriggered: root.launchSetup(true)
  }

  IpcHandler {
    target: "io.github.swiizerkuh.afterglow"

    function setup(): void {
      root.launchSetup(false)
    }
  }

  // -------------------------------------------------------------- SysBar
  //
  // One system meter: a caps label, a heavy-outlined bar filled with
  // diagonal hatching, the percentage beside it and a dim readout below --
  // after the status bars on the Romulus consoles.
  //
  // The fill is a row of blocks. When the reading changes, the leading block
  // fades from transparent to opaque before the next one starts (and back out
  // again when the reading falls), so the bar crawls to its value in steps.
  // Once settled, the last block re-fills on every new sample, which is the
  // bar visibly taking a reading. Driven by the plot's shared ~10Hz clock.
  component SysBar: Item {
    id: bar

    property var hud: null
    property var clock: null
    property string label: ""
    property string detail: ""
    property real value: -1          // percent; < 0 means no data
    property int seq: 0              // bumps on every sample
    property int blocks: 25
    property real warnAt: 90
    property real barWidth: 240
    property real barHeight: 18

    readonly property bool hasData: bar.value >= 0
    readonly property int target: bar.hasData
      ? Math.max(0, Math.min(bar.blocks, Math.round(bar.value / 100 * bar.blocks))) : 0
    readonly property color tone: bar.hasData && bar.value >= bar.warnAt
      ? (bar.hud ? bar.hud.fault : "#c2233c")
      : (bar.hud ? bar.hud.inkColor : "#ffffff")
    readonly property string mono: bar.hud ? bar.hud.mono : "monospace"

    // Animation state, advanced one step per clock tick.
    property int filled: 0       // blocks fully lit
    property real grow: 0        // opacity of block `filled` while filling up
    property real shrink: 0      // how far block `filled - 1` has faded while emptying
    property real refill: 1      // opacity of the last block while re-sampling

    function step() {
      if (bar.filled < bar.target) {
        bar.shrink = 0
        bar.grow = Math.min(1, bar.grow + 0.25)
        if (bar.grow >= 1) { bar.filled += 1; bar.grow = 0; bar.refill = 1 }
      } else if (bar.filled > bar.target) {
        bar.grow = 0
        bar.shrink = Math.min(1, bar.shrink + 0.25)
        if (bar.shrink >= 1) { bar.filled -= 1; bar.shrink = 0; bar.refill = 1 }
      } else if (bar.refill < 1) {
        bar.refill = Math.min(1, bar.refill + 0.2)
      }
    }

    onSeqChanged: if (bar.filled === bar.target && bar.filled > 0) bar.refill = 0.2

    function blockOpacity(i) {
      if (i < bar.filled - 1) return 1
      if (i === bar.filled - 1) {
        if (bar.filled > bar.target) return 1 - bar.shrink
        return bar.filled === bar.target ? bar.refill : 1
      }
      if (i === bar.filled && bar.filled < bar.target) return bar.grow
      return 0
    }

    Connections {
      target: bar.clock
      enabled: bar.clock !== null
      function onStepped(dt) { bar.step() }
    }

    readonly property real innerX: 4
    readonly property real innerY: 4
    readonly property real innerW: bar.barWidth - 8
    readonly property real innerH: bar.barHeight - 8
    readonly property real blockW: bar.innerW / bar.blocks

    // Hatching for the whole bar, sliced by each block so the stripes run
    // on unbroken across block boundaries.
    readonly property string hatchPath: {
      var out = []
      var h = bar.innerH
      for (var x = -h; x < bar.innerW + h; x += 5) {
        out.push("M" + x.toFixed(1) + " " + h.toFixed(1) + "L" + (x + h).toFixed(1) + " 0")
      }
      return out.join(" ")
    }

    width: bar.barWidth + 76
    height: 16 + bar.barHeight + 18

    Text {
      x: 0; y: 0
      text: bar.label
      color: bar.tone
      opacity: 0.9
      font.family: bar.mono
      font.pixelSize: 10
      font.letterSpacing: 2
      font.bold: true
      renderType: Text.NativeRendering
    }

    Rectangle {
      id: frame
      x: 0; y: 15
      width: bar.barWidth
      height: bar.barHeight
      color: "transparent"
      border.width: 2
      border.color: bar.tone
      antialiasing: false

      Repeater {
        model: bar.blocks
        delegate: Item {
          id: block
          required property int index
          x: bar.innerX + Math.round(block.index * bar.blockW)
          y: bar.innerY
          width: Math.round((block.index + 1) * bar.blockW) - Math.round(block.index * bar.blockW)
          height: bar.innerH
          clip: true
          opacity: bar.blockOpacity(block.index)
          visible: block.opacity > 0

          Shape {
            x: -Math.round(block.index * bar.blockW)
            width: bar.innerW
            height: bar.innerH
            asynchronous: false
            ShapePath {
              strokeColor: bar.tone
              strokeWidth: 1.6
              fillColor: "transparent"
              capStyle: ShapePath.FlatCap
              PathSvg { path: bar.hatchPath }
            }
          }
        }
      }
    }

    Text {
      x: bar.barWidth + 10
      y: frame.y + Math.round((bar.barHeight - implicitHeight) / 2)
      text: bar.hasData ? Math.round(bar.value) + "%" : "--%"
      color: bar.tone
      font.family: bar.mono
      font.pixelSize: 18
      font.bold: true
      renderType: Text.NativeRendering
    }

    Text {
      x: 2
      y: frame.y + bar.barHeight + 4
      text: bar.detail
      color: bar.tone
      opacity: 0.5
      font.family: bar.mono
      font.pixelSize: 9
      font.letterSpacing: 2
      renderType: Text.NativeRendering
    }
  }

  // ------------------------------------------------------------------- HUD
  //
  // Instrument chrome around the trajectory plot: a warped frame with corner
  // brackets and tick rulers, a sliding scale pointer, telemetry columns, an
  // orbital plot, a radar scope, a debris point cloud, station markers and a
  // status strip. Everything is driven by one ~10Hz tick, so like the trails
  // it moves in discrete steps and lets the compositor idle in between.
  //
  // Lines that run along the tube (frame, rulers) are warped with the grid.
  // Readouts and panels sit "on the glass" in screen space, as the overlay on
  // a real scope would, so they stay square and legible.
  component HudLayer: Item {
    id: hud

    property var host: null

    readonly property bool ready: hud.host !== null && hud.host.hudOn
      && hud.width > 0 && hud.height > 0

    function hf(k, d) { return hud.host ? hud.host.hudFlag(k, d) : d }
    function hn(k, d) { return hud.host ? hud.host.hudNum(k, d) : d }
    function w(x, y) { return hud.host ? hud.host.warp(x, y) : Qt.point(x, y) }
    // Stable pseudo-random in [0,1): the same inputs always give the same
    // answer, so things placed from it don't jump about between rebuilds.
    function hash(a, b) {
      var s = Math.sin(a * 12.9898 + b * 78.233) * 43758.5453
      return s - Math.floor(s)
    }
    function pad(n, len) {
      var s = String(Math.floor(Math.abs(n)))
      while (s.length < len) s = "0" + s
      return s
    }
    // Theme roles, resolved by the host from the live Omarchy palette.
    readonly property color inkColor: hud.host ? hud.host.inkColor : hud.inkColor
    readonly property color groundColor: hud.host ? hud.host.groundColor : "#000000"
    function ink(a) {
      return Qt.rgba(hud.inkColor.r, hud.inkColor.g, hud.inkColor.b, Math.max(0, Math.min(1, a)))
    }

    readonly property real alpha: hud.hn("alpha", 0.34)
    readonly property color attention: hud.host ? hud.host.attention : "#ff6a1f"
    readonly property color fault: hud.host ? hud.host.fault : "#c2233c"
    readonly property string mono: hud.host ? hud.host.fontFamily : "monospace"

    // The frame is specified by where its corners should LAND on screen; the
    // unwarped positions are solved for, so the barrel pushes them back out
    // to exactly the inset rather than off the edge of the tube.
    readonly property real inset: hud.hn("inset", 22)
    readonly property real topInset: hud.hn("topInset", 94)
    readonly property point tl: hud.host ? hud.host.unwarp(hud.inset, hud.topInset) : Qt.point(0, 0)
    readonly property point br: hud.host ? hud.host.unwarp(hud.width - hud.inset, hud.height - hud.inset) : Qt.point(0, 0)

    // On-glass panels hang off these, not off fixed insets, so they tuck
    // inside the brackets however hard the curvature pulls them in.
    readonly property point cTL: hud.w(hud.tl.x + 26, hud.tl.y + 26)
    readonly property point cTR: hud.w(hud.br.x - 26, hud.tl.y + 26)
    readonly property point cBL: hud.w(hud.tl.x + 26, hud.br.y - 26)
    readonly property point cBR: hud.w(hud.br.x - 26, hud.br.y - 26)

    property int tick: 0
    property int seed: 0

    // Throttled clocks. Bindings that read one of these re-run only when the
    // integer actually changes, not on every 100ms tick.
    readonly property int secs: Math.floor(hud.tick / 10)
    readonly property int twinkle: Math.floor(hud.tick / 3)
    readonly property int blinkHeader: Math.floor(hud.tick / 7) % 2
    readonly property int blinkStation: Math.floor(hud.tick / 8) % 2
    readonly property int blinkLock: Math.floor(hud.tick / 12) % 3
    readonly property int statusEpoch: Math.floor(hud.tick / 25)
    readonly property int lockEpoch: Math.floor(hud.tick / 40)
    readonly property int plateEpoch: Math.floor(hud.tick / 50)
    readonly property int stationEpoch: Math.floor(hud.tick / 3000)
    property real scaleValue: 0.42
    property real scaleTarget: 0.42
    property var telemetry: []

    visible: hud.ready

    function telemetryValue(i) {
      var k = i % 3
      if (k === 0) return hud.pad(Math.random() * 99, 2) + "." + hud.pad(Math.random() * 99, 2)
      if (k === 1) return Math.floor(Math.random() * 9) + "." + hud.pad(Math.random() * 99, 2)
      return hud.pad(Math.random() * 99, 2)
    }

    function step() {
      if (hud.tick % 12 === 0 && hud.telemetry.length > 0) {
        var t = hud.telemetry.slice()
        var i = Math.floor(Math.random() * t.length)
        t[i] = hud.telemetryValue(i)
        hud.telemetry = t
      }
      if (hud.tick % 60 === 0) hud.scaleTarget = 0.08 + Math.random() * 0.84
      var d = hud.scaleTarget - hud.scaleValue
      if (Math.abs(d) > 0.002) hud.scaleValue += d * 0.07
    }

    Component.onCompleted: {
      hud.seed = Math.floor(Math.random() * 997)
      var t = []
      for (var i = 0; i < 9; i++) t.push(hud.telemetryValue(i))
      hud.telemetry = t
    }

    Connections {
      target: hud.host
      enabled: hud.ready
      function onStepped(dt) {
        hud.tick += 1
        hud.step()
      }
    }

    // ---- warped line work --------------------------------------------------

    // Polyline through unwarped points, subdivided so it bends with the tube.
    function poly(pts, closed) {
      var out = []
      var segs = pts.length - 1 + (closed ? 1 : 0)
      for (var i = 0; i < segs; i++) {
        var a = pts[i]
        var b = pts[(i + 1) % pts.length]
        var n = Math.max(1, Math.ceil(Math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)) / 24))
        for (var s = (i === 0 ? 0 : 1); s <= n; s++) {
          var p = hud.w(a.x + (b.x - a.x) * s / n, a.y + (b.y - a.y) * s / n)
          out.push((i === 0 && s === 0 ? "M" : "L") + p.x.toFixed(1) + " " + p.y.toFixed(1))
        }
      }
      return out.join(" ")
    }

    function seg(x0, y0, x1, y1) {
      var p = hud.w(x0, y0)
      var q = hud.w(x1, y1)
      return "M" + p.x.toFixed(1) + " " + p.y.toFixed(1) + "L" + q.x.toFixed(1) + " " + q.y.toFixed(1)
    }

    function buildFrame() {
      if (!hud.ready) return ""
      var a = hud.tl, b = hud.br
      return hud.poly([a, Qt.point(b.x, a.y), b, Qt.point(a.x, b.y)], true)
    }

    function buildBrackets() {
      if (!hud.ready) return ""
      var g = 26
      var arm = Math.min(110, (hud.br.x - hud.tl.x) * 0.09)
      var L = hud.tl.x + g, T = hud.tl.y + g, R = hud.br.x - g, B = hud.br.y - g
      return [
        hud.poly([Qt.point(L, T + arm), Qt.point(L, T), Qt.point(L + arm, T)], false),
        hud.poly([Qt.point(R - arm, T), Qt.point(R, T), Qt.point(R, T + arm)], false),
        hud.poly([Qt.point(R, B - arm), Qt.point(R, B), Qt.point(R - arm, B)], false),
        hud.poly([Qt.point(L + arm, B), Qt.point(L, B), Qt.point(L, B - arm)], false)
      ].join(" ")
    }

    function buildCrosses() {
      if (!hud.ready) return ""
      var out = []
      var k = 12, arm = 7
      var cs = [Qt.point(hud.tl.x + k, hud.tl.y + k), Qt.point(hud.br.x - k, hud.tl.y + k),
                Qt.point(hud.br.x - k, hud.br.y - k), Qt.point(hud.tl.x + k, hud.br.y - k)]
      for (var i = 0; i < cs.length; i++) {
        var p = hud.w(cs[i].x, cs[i].y)
        out.push("M" + (p.x - arm).toFixed(1) + " " + p.y.toFixed(1) + "L" + (p.x + arm).toFixed(1) + " " + p.y.toFixed(1))
        out.push("M" + p.x.toFixed(1) + " " + (p.y - arm).toFixed(1) + "L" + p.x.toFixed(1) + " " + (p.y + arm).toFixed(1))
      }
      return out.join(" ")
    }

    function buildRulers() {
      if (!hud.ready) return ""
      var out = []
      var a = hud.tl, b = hud.br
      var y0 = a.y + (b.y - a.y) * 0.2
      var y1 = a.y + (b.y - a.y) * 0.8
      var i = 0
      for (var y = y0; y <= y1; y += 8, i++) {
        var len = i % 5 === 0 ? 12 : 5
        out.push(hud.seg(a.x + 12, y, a.x + 12 + len, y))
        out.push(hud.seg(b.x - 12, y, b.x - 12 - len, y))
      }
      out.push(hud.poly([Qt.point(a.x + 12, y0), Qt.point(a.x + 12, y1)], false))
      out.push(hud.poly([Qt.point(b.x - 12, y0), Qt.point(b.x - 12, y1)], false))
      return out.join(" ")
    }

    readonly property string framePath: hud.hf("frame", true) ? hud.buildFrame() : ""
    readonly property string bracketPath: hud.hf("frame", true) ? hud.buildBrackets() : ""
    readonly property string crossPath: hud.hf("frame", true) ? hud.buildCrosses() : ""
    readonly property string rulerPath: hud.hf("rulers", true) ? hud.buildRulers() : ""

    // ---- debris point cloud --------------------------------------------------
    //
    // A mound of raster points rising off the bottom edge -- a lidar return, a
    // debris field. A few twinkle each step.
    function buildCloud() {
      if (!hud.ready || !hud.hf("cloud", true)) return []
      var n = Math.max(0, Math.min(600, Math.round(hud.hn("cloudCount", 220))))
      var cx = hud.width * hud.hn("cloudX", 0.52)
      var spread = hud.width * hud.hn("cloudSpread", 0.2)
      var peak = hud.height * hud.hn("cloudHeight", 0.26)
      var base = hud.height - hud.inset - 10
      var pts = []
      for (var i = 0; i < n; i++) {
        // Sum of uniforms: a cheap bell curve, denser in the middle.
        var g = (hud.hash(i, 1) + hud.hash(i, 2) + hud.hash(i, 3) - 1.5) * 1.6
        var x = cx + g * spread
        var hump = peak * Math.exp(-Math.pow((x - cx) / spread, 2) * 0.9)
        var y = base - hump * Math.pow(hud.hash(i, 4), 1.7)
        var p = hud.w(x, y)
        // Keep the mound inside the frame.
        if (p.x < hud.tl.x + 2 || p.x > hud.br.x - 4 || p.y < hud.tl.y + 2 || p.y > hud.br.y - 4) continue
        pts.push({
          x: Math.round(p.x),
          y: Math.round(p.y),
          a: 0.16 + 0.42 * hud.hash(i, 5),
          s: hud.hash(i, 6) < 0.12 ? 3 : 2
        })
      }
      return pts
    }

    readonly property var cloudPts: hud.buildCloud()

    // Everything in here is static between resizes, so it is rendered once
    // into a texture and composited as a single quad after that.
    Item {
      anchors.fill: parent
      layer.enabled: true

    Shape {
      anchors.fill: parent
      asynchronous: false

      ShapePath {
        // Same 1px white rule as the header boxes, so the frame reads as the
        // same family of line rather than a faint guide.
        strokeColor: hud.ink(0.9)
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: hud.framePath }
      }
      ShapePath {
        strokeColor: hud.ink(hud.alpha * 1.9)
        strokeWidth: 2
        fillColor: "transparent"
        capStyle: ShapePath.FlatCap
        PathSvg { path: hud.bracketPath }
      }
      ShapePath {
        strokeColor: hud.ink(hud.alpha * 1.8)
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: hud.crossPath }
      }
      ShapePath {
        strokeColor: hud.ink(hud.alpha * 1.3)
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: hud.rulerPath }
      }
    }


    // The cloud itself is static: 220 dots with no bindings on the clock.
    Repeater {
      model: hud.cloudPts.length
      delegate: Rectangle {
        required property int index
        readonly property var pt: hud.cloudPts[index]
        x: pt.x
        y: pt.y
        width: pt.s
        height: pt.s
        color: hud.inkColor
        antialiasing: false
        opacity: pt.a
      }
    }
    }

    // Everything plotted ON the field -- sparkles, orbital plot, radar scope,
    // station markers -- is clipped to the frame like the grid and trails, so
    // nothing (the orbit's long sight-lines, say) crosses the border into the
    // header band. On-glass readouts below sit outside this on purpose.
    Item {
      x: hud.tl.x
      y: hud.tl.y
      width: hud.br.x - hud.tl.x
      height: hud.br.y - hud.tl.y
      clip: true

      // Back in HUD coordinates, so nothing inside needs to know it moved.
      Item {
        x: -parent.x
        y: -parent.y
        width: hud.width
        height: hud.height

    // Twinkle comes from a handful of bright sparkles that hop between cloud
    // points, rather than from every dot re-checking the clock.
    Repeater {
      model: hud.cloudPts.length > 0 ? 6 : 0
      delegate: Rectangle {
        required property int index
        readonly property var pt: hud.cloudPts[Math.floor(hud.hash(index + 50, hud.twinkle) * hud.cloudPts.length)]
        x: pt.x
        y: pt.y
        width: pt.s
        height: pt.s
        color: hud.inkColor
        antialiasing: false
        opacity: 0.95
      }
    }

    // ---- orbital plot ----------------------------------------------------------
    Item {
      id: orbit
      visible: hud.hf("orbit", true)
      readonly property real r: hud.height * hud.hn("orbitRadius", 0.12)
      readonly property point c: hud.w(hud.width * hud.hn("orbitX", 0.74), hud.height * hud.hn("orbitY", 0.36))
      readonly property real tilt: -14
      readonly property real ex: orbit.r * 2.25
      readonly property real ey: orbit.r * 0.6
      readonly property real a1: hud.tick * 0.011
      readonly property real a2: 1.3 - hud.tick * 0.007
      readonly property real cx: orbit.width / 2
      readonly property real cy: orbit.height / 2
      width: orbit.r * 5
      height: orbit.r * 5
      x: Math.round(orbit.c.x - orbit.width / 2)
      y: Math.round(orbit.c.y - orbit.height / 2)

      // Orbits, sight-lines and the body never move: cache them.
      Item {
        anchors.fill: parent
        layer.enabled: true

      Shape {
        anchors.fill: parent
        asynchronous: false
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.3)
          strokeWidth: 1
          fillColor: "transparent"
          PathAngleArc {
            centerX: orbit.cx; centerY: orbit.cy
            radiusX: orbit.r; radiusY: orbit.r
            startAngle: 0; sweepAngle: 360
          }
        }
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.2)
          strokeWidth: 2
          fillColor: "transparent"
          strokeStyle: ShapePath.DashLine
          dashPattern: [1, 3]
          capStyle: ShapePath.FlatCap
          PathAngleArc {
            centerX: orbit.cx; centerY: orbit.cy
            radiusX: orbit.r * 1.6; radiusY: orbit.r * 1.6
            startAngle: 0; sweepAngle: 360
          }
        }
        // Long thin sight-lines through the body, as on a navigation plot.
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 0.8)
          strokeWidth: 1
          fillColor: "transparent"
          PathMove { x: 0; y: orbit.cy + orbit.r * 0.28 }
          PathLine { x: orbit.width; y: orbit.cy - orbit.r * 0.28 }
          PathMove { x: orbit.cx + orbit.r * 0.12; y: 0 }
          PathLine { x: orbit.cx - orbit.r * 0.12; y: orbit.height }
        }
      }

      Shape {
        anchors.fill: parent
        asynchronous: false
        rotation: orbit.tilt
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.1)
          strokeWidth: 2
          fillColor: "transparent"
          strokeStyle: ShapePath.DashLine
          dashPattern: [1, 2.5]
          capStyle: ShapePath.FlatCap
          PathAngleArc {
            centerX: orbit.cx; centerY: orbit.cy
            radiusX: orbit.ex; radiusY: orbit.ey
            startAngle: 0; sweepAngle: 360
          }
        }
      }

      Rectangle {
        x: orbit.cx - 5; y: orbit.cy - 5
        width: 10; height: 10; radius: 5
        color: hud.ink(0.85)
      }
      Text {
        x: orbit.cx + 12; y: orbit.cy + 8
        text: "ZETA·2"
        color: hud.inkColor; opacity: hud.alpha * 2
        font.family: hud.mono; font.pixelSize: 9; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }

      }

      // Satellite on the circular orbit.
      Rectangle {
        id: sat1
        x: Math.round(orbit.cx + Math.cos(orbit.a1) * orbit.r) - 4
        y: Math.round(orbit.cy + Math.sin(orbit.a1) * orbit.r) - 4
        width: 8; height: 8; radius: 4
        color: hud.attention
      }
      Text {
        x: orbit.x + sat1.x + 12 + implicitWidth > hud.br.x - 8 ? sat1.x - 4 - implicitWidth : sat1.x + 12
        y: sat1.y - 6
        text: "A·214"
        color: hud.attention; opacity: 0.85
        font.family: hud.mono; font.pixelSize: 9; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }

      // Probe on the tilted ellipse: position in the ellipse's frame, then
      // rotate by the tilt so it rides the dashed line.
      Rectangle {
        id: sat2
        readonly property real lx: Math.cos(orbit.a2) * orbit.ex
        readonly property real ly: Math.sin(orbit.a2) * orbit.ey
        readonly property real t: orbit.tilt * Math.PI / 180
        x: Math.round(orbit.cx + sat2.lx * Math.cos(sat2.t) - sat2.ly * Math.sin(sat2.t)) - 3
        y: Math.round(orbit.cy + sat2.lx * Math.sin(sat2.t) + sat2.ly * Math.cos(sat2.t)) - 3
        width: 6; height: 6
        color: hud.ink(0.9)
        antialiasing: false
      }
      Text {
        // Flip to the left of the probe rather than run into the frame.
        x: orbit.x + sat2.x + 10 + implicitWidth > hud.br.x - 8 ? sat2.x - 4 - implicitWidth : sat2.x + 10
        y: sat2.y - 20
        text: "ECHO PROBE 203"
        color: hud.inkColor; opacity: hud.alpha * 2
        font.family: hud.mono; font.pixelSize: 9; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }
    }

    // ---- radar scope -------------------------------------------------------------
    Item {
      id: scope
      visible: hud.hf("scope", true)
      readonly property real r: hud.height * hud.hn("scopeRadius", 0.11)
      readonly property point c: hud.w(hud.width * hud.hn("scopeX", 0.2), hud.height * hud.hn("scopeY", 0.62))
      readonly property real sweep: (hud.tick * hud.hn("sweepStep", 4)) % 360
      readonly property int epoch: Math.floor(hud.tick / 300)
      readonly property real cx: scope.width / 2
      readonly property real cy: scope.height / 2
      width: scope.r * 2.7
      height: scope.r * 2.7
      x: Math.round(scope.c.x - scope.width / 2)
      y: Math.round(scope.c.y - scope.height / 2)

      // Rings, crosshair, range ticks and centre box never move: cache them.
      Item {
        anchors.fill: parent
        layer.enabled: true

      Shape {
        anchors.fill: parent
        asynchronous: false
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.6)
          strokeWidth: 1
          fillColor: "transparent"
          PathAngleArc {
            centerX: scope.cx; centerY: scope.cy
            radiusX: scope.r; radiusY: scope.r
            startAngle: 0; sweepAngle: 360
          }
        }
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.2)
          strokeWidth: 2
          fillColor: "transparent"
          strokeStyle: ShapePath.DashLine
          dashPattern: [1, 3]
          capStyle: ShapePath.FlatCap
          PathAngleArc {
            centerX: scope.cx; centerY: scope.cy
            radiusX: scope.r * 0.66; radiusY: scope.r * 0.66
            startAngle: 0; sweepAngle: 360
          }
          PathAngleArc {
            centerX: scope.cx; centerY: scope.cy
            radiusX: scope.r * 0.33; radiusY: scope.r * 0.33
            startAngle: 0; sweepAngle: 360
          }
          PathMove { x: scope.cx - scope.r * 1.18; y: scope.cy }
          PathLine { x: scope.cx + scope.r * 1.18; y: scope.cy }
          PathMove { x: scope.cx; y: scope.cy - scope.r * 1.18 }
          PathLine { x: scope.cx; y: scope.cy + scope.r * 1.18 }
        }
      }

      // Range ticks down the right-hand side.
      Repeater {
        model: 7
        delegate: Rectangle {
          required property int index
          x: Math.round(scope.cx + scope.r * 1.12)
          y: Math.round(scope.cy - scope.r * 0.66 + index * scope.r * 0.22)
          width: index === 3 ? 10 : 5
          height: 1
          color: hud.ink(hud.alpha * 1.8)
          antialiasing: false
        }
      }

      Rectangle {
        x: Math.round(scope.cx - 6); y: Math.round(scope.cy - 6)
        width: 12; height: 12
        color: "transparent"
        border.width: 1
        border.color: hud.ink(hud.alpha * 2)
      }

      }

      // Sweep arm plus two fading ghosts: phosphor persistence.
      Repeater {
        model: 3
        delegate: Rectangle {
          required property int index
          x: scope.cx
          y: scope.cy
          width: scope.r
          height: 1
          transformOrigin: Item.TopLeft
          rotation: scope.sweep - index * 5
          color: hud.inkColor
          opacity: [0.75, 0.3, 0.12][index]
        }
      }

      // Contacts light up as the sweep passes, then decay.
      Repeater {
        model: 4
        delegate: Rectangle {
          required property int index
          readonly property real ang: hud.hash(index + 3, scope.epoch + hud.seed) * 360
          readonly property real dist: (0.22 + 0.7 * hud.hash(index + 11, scope.epoch + hud.seed)) * scope.r
          readonly property real since: (((scope.sweep - ang) % 360) + 360) % 360
          x: Math.round(scope.cx + Math.cos(ang * Math.PI / 180) * dist) - 4
          y: Math.round(scope.cy + Math.sin(ang * Math.PI / 180) * dist) - 4
          width: 8; height: 8; radius: 4
          color: "transparent"
          border.width: 1.5
          border.color: index === 0 ? hud.attention : hud.inkColor
          opacity: 0.1 + 0.9 * (since < 160 ? 1 - since / 160 : 0)
        }
      }

      Text {
        x: Math.round(scope.cx - scope.r); y: Math.round(scope.cy + scope.r * 1.08)
        text: "SCAN " + hud.pad(scope.sweep, 3) + "°"
        color: hud.inkColor; opacity: hud.alpha * 2
        font.family: hud.mono; font.pixelSize: 9; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }
    }

    // ---- station markers -------------------------------------------------------
    Repeater {
      model: hud.hf("stations", true) ? 2 : 0
      delegate: Item {
        id: station
        required property int index
        readonly property var names: ["REN.STATION", "RELAY 7", "OUTPOST K", "DEPOT 11"]
        readonly property int epoch: hud.stationEpoch + hud.seed
        readonly property point pos: hud.w(hud.width * (0.34 + hud.hash(index + 21, station.epoch) * 0.3),
                                           hud.height * (0.2 + hud.hash(index + 31, station.epoch) * 0.46))
        x: Math.round(station.pos.x) - 11
        y: Math.round(station.pos.y) - 11
        width: 22
        height: 22

        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: 2
          border.color: hud.ink(hud.alpha * 2.2)
        }
        Rectangle {
          anchors.centerIn: parent
          width: 8; height: 8; radius: 4
          color: station.index === 0 && hud.blinkStation === 0 ? hud.attention : hud.ink(0.7)
        }
        Text {
          x: 32; y: 4
          text: station.names[(station.index + station.epoch) % station.names.length]
          color: hud.inkColor; opacity: hud.alpha * 2.3
          font.family: hud.mono; font.pixelSize: 10; font.letterSpacing: 2
          renderType: Text.NativeRendering
        }
      }
    }
      }
    }

    // ---- on-glass readouts --------------------------------------------------------

    // Scale with a sliding pointer, top centre.
    Item {
      id: scale
      visible: hud.hf("scale", true)
      readonly property real span: Math.round(Math.min(320, hud.width * 0.24))
      readonly property real px: 60 + hud.scaleValue * scale.span
      readonly property string ticks: {
        var out = []
        for (var i = 0; i * 8 <= scale.span; i++) {
          var x = 60 + i * 8 + 0.5
          out.push("M" + x + " 22L" + x + " " + (22 + (i % 5 === 0 ? 9 : 4)))
        }
        return out.join(" ")
      }
      width: scale.span + 120
      height: 48
      x: Math.round(hud.width / 2 - scale.width / 2)
      y: Math.round(hud.w(hud.width / 2, hud.tl.y).y + 6)

      Rectangle {
        x: 0; y: 14; width: 48; height: 16
        color: "transparent"; border.width: 1; border.color: hud.ink(hud.alpha * 2)
        Text {
          anchors.centerIn: parent
          text: (hud.scaleValue * 9.9).toFixed(2)
          color: hud.inkColor; opacity: hud.alpha * 2.4
          font.family: hud.mono; font.pixelSize: 10
          renderType: Text.NativeRendering
        }
      }
      Rectangle {
        x: scale.width - 48; y: 14; width: 48; height: 16
        color: "transparent"; border.width: 1; border.color: hud.ink(hud.alpha * 2)
        Text {
          anchors.centerIn: parent
          text: (1 + hud.scaleValue * 6.9).toFixed(2)
          color: hud.inkColor; opacity: hud.alpha * 2.4
          font.family: hud.mono; font.pixelSize: 10
          renderType: Text.NativeRendering
        }
      }
      Rectangle { x: 60; y: 22; width: scale.span; height: 1; color: hud.ink(hud.alpha * 1.6) }
      Shape {
        anchors.fill: parent
        asynchronous: false
        ShapePath {
          strokeColor: hud.ink(hud.alpha * 1.6)
          strokeWidth: 1
          fillColor: "transparent"
          PathSvg { path: scale.ticks }
        }
      }
      // Pointer: a solid down-triangle riding the scale.
      Shape {
        x: Math.round(scale.px - 5); y: 10
        width: 10; height: 9
        asynchronous: false
        ShapePath {
          strokeColor: "transparent"
          fillColor: hud.ink(0.85)
          startX: 0; startY: 0
          PathLine { x: 10; y: 0 }
          PathLine { x: 5; y: 8 }
          PathLine { x: 0; y: 0 }
        }
      }
      Text {
        x: Math.round(scale.px - implicitWidth / 2); y: 34
        text: "BRG " + hud.pad(hud.scaleValue * 360, 3)
        color: hud.inkColor; opacity: hud.alpha * 2
        font.family: hud.mono; font.pixelSize: 9; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }
    }

    // Header band, above the frame (after the Alien: Romulus nav plot): a
    // filled status bar on the left and a segmented ident plate on the right.
    // Both are placed by where their corners should land on the glass and
    // solved back through the barrel, like the frame, so the tube bends them
    // without pushing them under the bar.
    readonly property real bandTop: hud.hn("bandTop", 38)
    readonly property real bandBottom: hud.topInset - 8

    function glass(x, y) { return hud.host ? hud.host.unwarp(x, y) : Qt.point(x, y) }

    Item {
      id: tracking
      visible: hud.hf("headers", true)
      // Sized from its OUTER (left) edge: solving opposite corners instead
      // lets the barrel squash the box to half height along the diagonal.
      readonly property point a: hud.glass(hud.inset, hud.bandTop + 12)
      readonly property point a2: hud.glass(hud.inset, hud.bandBottom)
      readonly property point b: hud.glass(hud.inset + hud.width * 0.4, hud.bandTop + 12)
      x: Math.round(tracking.a.x)
      y: Math.round(tracking.a.y)
      width: Math.round(tracking.b.x - tracking.a.x)
      height: Math.round(tracking.a2.y - tracking.a.y)

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: hud.ink(0.95)
      }
      Rectangle {
        anchors.fill: parent
        anchors.margins: 3
        color: hud.ink(0.88)

        Text {
          id: trackingText
          x: 12
          anchors.verticalCenter: parent.verticalCenter
          text: hud.host ? hud.host.hudText("tracking", "TRACKING:ACTIVE") : "TRACKING:ACTIVE"
          color: hud.groundColor
          font.family: hud.mono
          font.pixelSize: 13
          font.letterSpacing: 3
          font.bold: true
          renderType: Text.NativeRendering
        }
        // Block cursor, blinking, as if the line were still being typed.
        Rectangle {
          x: trackingText.x + trackingText.implicitWidth + 6
          anchors.verticalCenter: parent.verticalCenter
          width: 8
          height: 13
          color: hud.groundColor
          visible: hud.blinkHeader === 0
        }
      }
    }

    Item {
      id: ident
      visible: hud.hf("headers", true)
      readonly property real w0: Math.min(340, hud.width * 0.26)
      // Sized from its outer (right) edge, for the same reason.
      readonly property point tr: hud.glass(hud.width - hud.inset, hud.bandTop)
      readonly property point br: hud.glass(hud.width - hud.inset, hud.bandBottom)
      readonly property point tl: hud.glass(hud.width - hud.inset - ident.w0, hud.bandTop)
      readonly property real rowH: Math.round(ident.height * 0.53)
      readonly property real logoW: 78
      x: Math.round(ident.tl.x)
      y: Math.round(ident.tr.y)
      width: Math.round(ident.tr.x - ident.tl.x)
      height: Math.round(ident.br.y - ident.tr.y)

      Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: hud.ink(0.9)
      }
      Rectangle { x: 0; y: ident.rowH; width: ident.width; height: 1; color: hud.ink(0.7) }
      Rectangle { x: ident.width - ident.logoW; y: 0; width: 1; height: ident.rowH; color: hud.ink(0.7) }

      Text {
        x: 10
        y: Math.round((ident.rowH - implicitHeight) / 2)
        text: hud.host ? hud.host.hudText("identTitle", "Heracles Mk. 1") : ""
        color: hud.inkColor
        font.family: hud.mono
        font.pixelSize: 12
        font.letterSpacing: 2
        font.bold: true
        renderType: Text.NativeRendering
      }

      // Corporate mark: swept twin wings either side of a descending blade.
      // Hidden with hud.identLogo: false.
      // An original mark for a made-up company, drawn as one filled path.
      Shape {
        visible: hud.hf("identLogo", true)
        width: 64
        height: 18
        x: Math.round(ident.width - ident.logoW + (ident.logoW - width) / 2)
        y: Math.round((ident.rowH - height) / 2)
        asynchronous: false
        ShapePath {
          strokeColor: "transparent"
          fillColor: hud.attention
          PathSvg {
            path: "M2 2L27 2L29 6L7 6Z M9 9L27 9L29 13L14 13Z"
                + " M62 2L37 2L35 6L57 6Z M55 9L37 9L35 13L50 13Z"
                + " M30 2L34 2L34 12L32 17L30 12Z"
          }
        }
      }

      Text {
        x: 10
        y: Math.round(ident.rowH + (ident.height - ident.rowH - implicitHeight) / 2)
        text: hud.host ? hud.host.hudText("identName", "OMEGA OVERWATCH") : ""
        color: hud.inkColor
        opacity: 0.92
        font.family: hud.mono
        font.pixelSize: 10
        font.letterSpacing: 3
        font.bold: true
        renderType: Text.NativeRendering
      }
      Text {
        x: Math.round(ident.width - 10 - implicitWidth)
        y: Math.round(ident.rowH + (ident.height - ident.rowH - implicitHeight) / 2)
        text: hud.host ? hud.host.hudText("identCode", "89 721 042") : ""
        color: hud.inkColor
        opacity: 0.55
        font.family: hud.mono
        font.pixelSize: 10
        font.letterSpacing: 2
        renderType: Text.NativeRendering
      }
    }

    // System meters: RAM over GPU, top-left of the field, aligned with the
    // telemetry column below them.
    readonly property var sys: hud.host && hud.host.sysShown ? hud.host.sysShown : ({})
    function sysNum(v) { return (typeof v === "number" && isFinite(v)) ? v : -1 }
    function hudLabel(key, fallback) { return hud.host ? hud.host.hudText(key, fallback) : fallback }
    readonly property real meterX: Math.round(hud.w(hud.tl.x + 12, hud.cTL.y + 30).x + 24)
    readonly property real meterY: Math.round(hud.cTL.y + 22)

    SysBar {
      visible: hud.hf("sysmon", true)
      x: hud.meterX
      y: hud.meterY
      hud: hud
      clock: hud.host
      warnAt: hud.hn("sysmonWarnAt", 90)
      label: hud.hudLabel("ramLabel", "MEMORY ALLOCATION")
      value: hud.sysNum(hud.sys.ram)
      seq: hud.host ? hud.host.sysSeqShown : 0
      detail: hud.sysNum(hud.sys.ramTotal) > 0
        ? "USED " + hud.sys.ramUsed.toFixed(1) + "G  ·  TOTAL " + hud.sys.ramTotal.toFixed(1) + "G"
        : "AWAITING TELEMETRY"
    }

    SysBar {
      visible: hud.hf("sysmon", true)
      x: hud.meterX
      y: hud.meterY + 58
      hud: hud
      clock: hud.host
      warnAt: hud.hn("sysmonWarnAt", 90)
      label: hud.hudLabel("gpuLabel", "GRAPHICS PROCESSOR LOAD")
      value: hud.sysNum(hud.sys.gpu)
      seq: hud.host ? hud.host.sysSeqShown : 0
      detail: hud.sys.gpuSource === "none" || hud.sys.gpuSource === undefined
        ? (hud.sys.gpuSource === "none" ? "NO GPU TELEMETRY" : "AWAITING TELEMETRY")
        : String(hud.sys.gpuName || "").toUpperCase() + "  ·  " + String(hud.sys.gpuSource).toUpperCase()
    }

    // Telemetry columns down the left-hand side.
    Repeater {
      model: hud.hf("telemetry", true) ? 9 : 0
      delegate: Text {
        required property int index
        readonly property int group: Math.floor(index / 3)
        readonly property real ty: hud.topInset + (hud.height - hud.topInset) * [0.24, 0.42, 0.6][group] + (index % 3) * 13
        x: Math.round(hud.w(hud.tl.x + 12, ty).x + 24)
        y: Math.round(ty)
        text: hud.telemetry.length > index ? hud.telemetry[index] : ""
        color: hud.inkColor; opacity: hud.alpha * 1.9
        font.family: hud.mono; font.pixelSize: 10; font.letterSpacing: 1
        renderType: Text.NativeRendering
      }
    }

    // Status strip, bottom left: indicator cells and an elapsed-time counter.
    Row {
      visible: hud.hf("status", true)
      x: Math.round(hud.cBL.x + 14)
      y: Math.round(hud.cBL.y - 24)
      spacing: 4

      Repeater {
        model: 14
        delegate: Rectangle {
          required property int index
          readonly property bool lit: hud.hash(index, hud.statusEpoch + hud.seed) > 0.5
          readonly property color c: index === 4 ? hud.attention : hud.ink(hud.alpha * 2.2)
          anchors.verticalCenter: parent.verticalCenter
          width: 7; height: 7
          color: lit ? c : "transparent"
          border.width: 1
          border.color: c
          antialiasing: false
        }
      }
      Item { width: 10; height: 1 }
      // Whole seconds: a tenths digit would relayout this text ten times a
      // second for no real gain.
      Text {
        text: hud.pad(Math.floor(hud.secs / 3600), 3) + " " + hud.pad(Math.floor(hud.secs / 60) % 60, 2)
          + ":" + hud.pad(hud.secs % 60, 2)
        color: hud.inkColor; opacity: hud.alpha * 2.3
        font.family: hud.mono; font.pixelSize: 10; font.letterSpacing: 2
        renderType: Text.NativeRendering
      }
    }

    // Lock readout, bottom right.
    Row {
      id: lockRow
      visible: hud.hf("status", true)
      x: Math.round(hud.cBR.x - 14 - lockRow.implicitWidth)
      y: Math.round(hud.cBR.y - 24)
      spacing: 8
      Text {
        text: "LOCK"
        color: hud.inkColor; opacity: hud.alpha * 2.6
        font.family: hud.mono; font.pixelSize: 10; font.letterSpacing: 3; font.bold: true
        renderType: Text.NativeRendering
      }
      Text {
        text: hud.pad(hud.hash(hud.lockEpoch, hud.seed + 5) * 99999999, 8) + " "
          + hud.pad(hud.hash(hud.lockEpoch, hud.seed + 6) * 99, 2)
        color: hud.inkColor; opacity: hud.alpha * 1.9
        font.family: hud.mono; font.pixelSize: 10; font.letterSpacing: 1
        renderType: Text.NativeRendering
      }
      Repeater {
        model: 4
        delegate: Rectangle {
          required property int index
          anchors.verticalCenter: parent.verticalCenter
          width: 9; height: 9
          color: index === 1 && hud.blinkLock === 0 ? hud.fault : hud.ink(hud.alpha * (1.2 + index * 0.4))
          antialiasing: false
        }
      }
    }
  }

  // ------------------------------------------------------------ flight paths
  //
  // The plot: a fixed
  // white grid, and a handful of spacecraft whose dotted trails crawl across
  // it, hold, then fade out and are replaced by a fresh heading.
  //
  // Everything snaps to a raster (`snap()`) so the trails read as lit cells on
  // a phosphor display rather than smooth vector curves.
  //
  // The CRT treatment is applied to the GEOMETRY, not as a post-process pass.
  // A fullscreen distortion shader would resample the 1px rules into mush;
  // warping the points before they are drawn keeps every line crisp while
  // still bowing the plot around a tube. Halation is the one genuine
  // post-process, because a glow has to come from somewhere bright.
  //
  // Cost control: a dot's opacity depends on `headIndex`, an integer that only
  // changes once per dot rather than once per frame, so revealing a trail is
  // a few dozen binding evaluations per second, not thousands. The grid is
  // three Shapes built from generated SVG paths, rebuilt only on resize.
  component FlightPathsLayer: Item {
    id: fpl

    property bool active: false
    // Set while nothing of the plot can be seen (a fullscreen window over this
    // screen). The clock stops, so no frames are drawn at all; the last frame
    // simply stays put underneath.
    property bool paused: false
    property var cfg: ({})
    // Latest system sample from the service-level monitor (bin/sysmon).
    property var sys: ({})
    property int sysSeq: 0
    // What the meters draw: the live feed, held still while paused so a new
    // reading can't trigger a redraw nobody can see.
    property var sysShown: ({})
    property int sysSeqShown: 0
    function syncSys() {
      if (fpl.paused) return
      fpl.sysShown = fpl.sys
      fpl.sysSeqShown = fpl.sysSeq
    }
    onSysChanged: fpl.syncSys()
    onPausedChanged: fpl.syncSys()

    // ---- theme ----------------------------------------------------------------
    //
    // Every colour is a ROLE resolved against the live Omarchy palette, so the
    // plot re-colours itself the moment the user switches theme. Config values
    // may be a role name or a literal colour:
    //   foreground | accent | urgent | muted | background | "#rrggbb"
    //   foreground  lines, text, the grid      (colors.toml: foreground)
    //   accent      attention: target lock     (colors.toml: accent)
    //   urgent      fault: warnings            (colors.toml: red)
    //   background  fills behind text          (colors.toml: background)
    readonly property color inkColor: Color.foreground
    readonly property color attention: Color.accent
    readonly property color fault: Color.urgent
    readonly property color groundColor: Color.background
    readonly property string fontFamily: Style.fontFamily || "monospace"

    function luma(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
    // Light themes get a light ground and dark ink; a few effects that only
    // make sense as light-on-dark (phosphor glow) back off on them.
    readonly property bool lightTheme: fpl.luma(fpl.groundColor) > 0.5

    function resolve(v, fallback) {
      if (v === undefined || v === null || v === "") v = fallback
      var s = String(v)
      if (s === "foreground" || s === "ink") return fpl.inkColor
      if (s === "accent" || s === "attention") return fpl.attention
      if (s === "urgent" || s === "red" || s === "fault") return fpl.fault
      if (s === "background" || s === "ground") return fpl.groundColor
      if (s === "muted") return Color.muted
      return s
    }

    // Whichever of ink / ground reads better on top of `c`.
    function contrastOn(c) {
      var l = fpl.luma(c)
      return Math.abs(fpl.luma(fpl.inkColor) - l) >= Math.abs(fpl.luma(fpl.groundColor) - l)
        ? fpl.inkColor : fpl.groundColor
    }

    function hudText(key, fallback) {
      var t = (fpl.cfg && fpl.cfg.hud && fpl.cfg.hud.text) ? fpl.cfg.hud.text[key] : undefined
      return (t === undefined || t === null) ? fallback : String(t)
    }

    function opt(key, fallback) {
      var v = (fpl.cfg && typeof fpl.cfg === "object") ? fpl.cfg[key] : undefined
      return v === undefined || v === null ? fallback : v
    }
    function num(key, fallback) {
      var v = fpl.opt(key, fallback)
      return (typeof v === "number" && isFinite(v)) ? v : fallback
    }
    function flag(key, fallback) {
      var v = fpl.opt(key, fallback)
      return (typeof v === "boolean") ? v : fallback
    }
    // CRT settings live in their own nested object.
    function crtOpt(key, fallback) {
      var c = (fpl.cfg && typeof fpl.cfg === "object") ? fpl.cfg.crt : undefined
      if (!c || typeof c !== "object") return fallback
      var v = c[key]
      return v === undefined || v === null ? fallback : v
    }
    function crtNum(key, fallback) {
      var v = fpl.crtOpt(key, fallback)
      return (typeof v === "number" && isFinite(v)) ? v : fallback
    }
    function crtFlag(key, fallback) {
      var v = fpl.crtOpt(key, fallback)
      return (typeof v === "boolean") ? v : fallback
    }
    // HUD settings live in their own nested object too.
    function hudOpt(key, fallback) {
      var h = (fpl.cfg && typeof fpl.cfg === "object") ? fpl.cfg.hud : undefined
      if (!h || typeof h !== "object") return fallback
      var v = h[key]
      return v === undefined || v === null ? fallback : v
    }
    function hudNum(key, fallback) {
      var v = fpl.hudOpt(key, fallback)
      return (typeof v === "number" && isFinite(v)) ? v : fallback
    }
    function hudFlag(key, fallback) {
      var v = fpl.hudOpt(key, fallback)
      return (typeof v === "boolean") ? v : fallback
    }
    function randRange(minKey, minDef, maxKey, maxDef) {
      var lo = fpl.num(minKey, minDef)
      var hi = fpl.num(maxKey, maxDef)
      if (hi < lo) hi = lo
      return Math.round(lo + Math.random() * (hi - lo))
    }

    readonly property real cell: Math.max(8, fpl.num("cell", 48))
    readonly property int majorEvery: Math.max(1, Math.round(fpl.num("gridMajorEvery", 4)))
    readonly property int raster: Math.max(1, Math.round(fpl.num("raster", 3)))
    readonly property int dotSize: Math.max(1, Math.round(fpl.num("dotSize", 3)))
    readonly property real dotSpacing: Math.max(4, fpl.num("dotSpacing", 18))
    readonly property color gridColor: fpl.resolve(fpl.opt("gridColor", "foreground"), "foreground")
    readonly property real gridAlpha: fpl.num("gridAlpha", 0.06)
    readonly property real gridMajorAlpha: fpl.num("gridMajorAlpha", 0.13)
    readonly property bool showGrid: fpl.active && fpl.flag("grid", true)
    readonly property bool showMarks: fpl.active && fpl.flag("marks", true)
    readonly property bool showLabels: fpl.flag("labels", true)
    readonly property int pathCount: fpl.active
      ? Math.max(0, Math.min(8, Math.round(fpl.num("paths", 3))))
      : 0

    // Raw role names / colours; trails resolve them live so a theme switch
    // recolours contacts already in flight.
    readonly property var trailPalette: {
      var v = fpl.opt("colors", null)
      return (Array.isArray(v) && v.length > 0)
        ? v
        : ["foreground", "foreground", "foreground", "foreground", "accent", "urgent"]
    }

    // ---- CRT ----------------------------------------------------------------
    readonly property bool crt: fpl.active && fpl.crtFlag("enabled", true)
    readonly property real curvature: fpl.crt ? Math.max(0, Math.min(0.4, fpl.crtNum("curvature", 0.055))) : 0

    // The CRT is a real post-process now: the whole plot -- text and panels
    // included -- is rendered to a texture and pushed through crt.frag. That
    // is the only way everything bends the same way; warping geometry could
    // curve lines but never a text label or a filled box. With the shader on,
    // geometric warp drops to identity. unwarp() still uses the full
    // curvature, because it answers "where in the source does this screen
    // point come from", which is exactly what placing the HUD needs.
    readonly property bool shaderCrt: fpl.crt && fpl.crtFlag("shader", true)
    readonly property real geomCurvature: fpl.shaderCrt ? 0 : fpl.curvature
    // Render scale of the tube before the warp. 1.0 is native resolution and
    // the default: every step above it multiplies the pixels drawn per frame
    // (1.5 is 2.25x), which was the single largest GPU cost measured. Raise it
    // only for the last bit of crispness on a desktop that is plugged in.
    readonly property real supersample: Math.max(1, Math.min(2, fpl.crtNum("supersample", 1.0)))
    readonly property real aberration: Math.max(0, fpl.crtNum("aberration", 0.8))
    readonly property bool showScanlines: fpl.crt && fpl.crtFlag("scanlines", true)
    readonly property int scanPitch: Math.max(2, Math.round(fpl.crtNum("scanlinePitch", 3)))
    readonly property real scanAlpha: fpl.crtNum("scanlineAlpha", 0.28)
    readonly property bool showMask: fpl.crt && fpl.crtFlag("mask", false)
    readonly property real maskAlpha: fpl.crtNum("maskAlpha", 0.14)
    readonly property bool showHalation: fpl.crt && fpl.crtFlag("halation", true)
      && (!fpl.lightTheme || fpl.crtFlag("halationOnLight", false))
    readonly property real halationStrength: fpl.crtNum("halationStrength", 0.55)
    readonly property real halationRadius: Math.max(1, fpl.crtNum("halationRadius", 22))
    readonly property color halationTint: fpl.resolve(fpl.crtOpt("halationTint", "accent"), "accent")
    readonly property real halationColorize: fpl.crtNum("halationColorize", 0.3)
    readonly property bool pixelateGrid: fpl.crtFlag("pixelateGrid", false)

    // ---- HUD ------------------------------------------------------------------
    readonly property bool hudOn: fpl.active && fpl.hudFlag("enabled", true)

    // One clock for everything. Separate timers per trail and for the HUD,
    // each ticking at its own phase, would dirty the scene several times per
    // interval; a shared one lands every change in the same frame.
    property int clock: 0
    signal stepped(int dt)

    Timer {
      interval: Math.max(40, Math.round(fpl.num("tickMs", 100)))
      repeat: true
      running: fpl.active && !fpl.paused && fpl.width > 0 && fpl.height > 0
      onTriggered: {
        fpl.clock += 1
        fpl.stepped(interval)
      }
    }
    readonly property bool showCallouts: fpl.hudOn && fpl.hudFlag("callouts", true)

    // The field: the rectangle inside the HUD's outer frame. The grid, the
    // trails and the debris cloud live inside it and nothing of theirs
    // reaches the edge of the screen. It is solved back through the barrel
    // exactly as the frame is, so the clip and the frame line coincide.
    // Without the HUD frame, the field is the whole screen.
    readonly property bool fieldClip: fpl.hudOn && fpl.hudFlag("frame", true) && fpl.hudFlag("clipToFrame", true)
    readonly property point fieldTL: fpl.fieldClip
      ? fpl.unwarp(fpl.hudNum("inset", 22), fpl.hudNum("topInset", 94))
      : Qt.point(0, 0)
    readonly property point fieldBR: fpl.fieldClip
      ? fpl.unwarp(fpl.width - fpl.hudNum("inset", 22), fpl.height - fpl.hudNum("inset", 22))
      : Qt.point(fpl.width, fpl.height)
    readonly property bool showVignette: fpl.crt && fpl.crtFlag("vignette", true)
    readonly property real vignetteAlpha: fpl.crtNum("vignetteAlpha", 0.5)
    readonly property real vignetteSpread: Math.max(0.02, Math.min(0.6, fpl.crtNum("vignetteSpread", 0.26)))

    // Barrel distortion about the centre of the tube. Points are pushed
    // outward proportional to r^2, so straight rules bow and the corners
    // stretch past the bezel -- which `clip` then trims, as a real one would.
    function warp(x, y) {
      if (fpl.geomCurvature <= 0 || fpl.width <= 0 || fpl.height <= 0) return Qt.point(x, y)
      var cx = fpl.width / 2
      var cy = fpl.height / 2
      var nx = (x - cx) / cx
      var ny = (y - cy) / cy
      var f = 1 + fpl.geomCurvature * (nx * nx + ny * ny)
      return Qt.point(cx + nx * cx * f, cy + ny * cy * f)
    }

    // Inverse of warp(), by fixed-point iteration: where to put a point so
    // that after the barrel it lands on (x, y). Used to pin the HUD frame's
    // corners to the screen inset instead of letting them bow off the tube.
    function unwarp(x, y) {
      if (fpl.curvature <= 0 || fpl.width <= 0 || fpl.height <= 0) return Qt.point(x, y)
      var cx = fpl.width / 2
      var cy = fpl.height / 2
      var tx = (x - cx) / cx
      var ty = (y - cy) / cy
      var nx = tx
      var ny = ty
      for (var i = 0; i < 10; i++) {
        var f = 1 + fpl.curvature * (nx * nx + ny * ny)
        nx = tx / f
        ny = ty / f
      }
      return Qt.point(cx + nx * cx, cy + ny * cy)
    }

    function snap(v) {
      return Math.round(v / fpl.raster) * fpl.raster
    }

    function bezier(a, b, c, d, t) {
      var u = 1 - t
      var w0 = u * u * u
      var w1 = 3 * u * u * t
      var w2 = 3 * u * t * t
      var w3 = t * t * t
      return Qt.point(a.x * w0 + b.x * w1 + c.x * w2 + d.x * w3,
                      a.y * w0 + b.y * w1 + c.y * w2 + d.y * w3)
    }

    // A point just outside the given edge of the FIELD: craft come in across
    // the frame and leave across it, rather than from off-screen.
    function edgePoint(side, t, margin) {
      var L = fpl.fieldTL.x, T = fpl.fieldTL.y, R = fpl.fieldBR.x, B = fpl.fieldBR.y
      if (side === 0) return Qt.point(L + t * (R - L), T - margin)
      if (side === 1) return Qt.point(R + margin, T + t * (B - T))
      if (side === 2) return Qt.point(L + t * (R - L), B + margin)
      return Qt.point(L - margin, T + t * (B - T))
    }

    function callsign() {
      var pre = ["TRJ", "AX", "KX", "VG", "LN", "SR", "OM", "DV"]
      return pre[Math.floor(Math.random() * pre.length)]
        + "·" + (Math.floor(Math.random() * 8900) + 100)
    }

    // ---- generated grid geometry -------------------------------------------
    //
    // One SVG path string per weight. A warped line has to be drawn as a
    // polyline, so each rule is sampled into `segs` pieces; with curvature at
    // 0 the samples fall on a straight line and cost nothing extra.
    // A warped rule has to be drawn as a polyline. Snapping each vertex to the
    // raster makes the curve stair-step exactly the way a bent scanline does,
    // which keeps the grid reading as pixels rather than as smooth vector art.
    // The half-pixel offset lands the 1px stroke on a pixel centre.
    // A warped rule has to be drawn as a polyline, and a polyline alone will
    // not pixelate: sampling a curve and rounding each vertex just draws a
    // gentle diagonal between samples, which reads as a wobble. A real
    // staircase needs the corner stated explicitly -- run along the old
    // column to the new row, then step across. Only the cross axis is
    // quantised; doing both makes an almost-axis-aligned rule ripple between
    // neighbouring columns. The half-pixel offset lands the 1px stroke on a
    // pixel centre.
    //
    // Near the middle of the tube the warp is small and the rules come out
    // straight; the steps appear where the curvature actually is, out at the
    // edges and corners.
    function buildGridPath(wantMajor) {
      if (fpl.width <= 0 || fpl.height <= 0 || fpl.cell <= 0) return ""
      var pad = fpl.cell * 2
      var out = []
      var i, s, segs, span, p, cross, along, prev, first

      function emit(x, y) { out.push("L" + x.toFixed(1) + " " + y.toFixed(1)) }

      // Vertical rules: quantise x, run in y.
      var nx = Math.ceil(fpl.width / fpl.cell) + 3
      span = fpl.height + pad * 2
      segs = fpl.geomCurvature > 0 ? Math.max(8, Math.min(96, Math.ceil(span / 14))) : 1
      for (i = -2; i <= nx; i++) {
        if (((i % fpl.majorEvery) + fpl.majorEvery) % fpl.majorEvery === 0 !== wantMajor) continue
        first = true
        prev = 0
        for (s = 0; s <= segs; s++) {
          p = fpl.warp(i * fpl.cell, -pad + (s / segs) * span)
          cross = fpl.pixelateGrid ? fpl.snap(p.x) + 0.5 : p.x
          along = p.y
          if (first) {
            out.push("M" + cross.toFixed(1) + " " + along.toFixed(1))
            first = false
          } else {
            if (fpl.pixelateGrid && cross !== prev) emit(prev, along)
            emit(cross, along)
          }
          prev = cross
        }
      }

      // Horizontal rules: quantise y, run in x.
      var ny = Math.ceil(fpl.height / fpl.cell) + 3
      span = fpl.width + pad * 2
      segs = fpl.geomCurvature > 0 ? Math.max(8, Math.min(96, Math.ceil(span / 14))) : 1
      for (i = -2; i <= ny; i++) {
        if (((i % fpl.majorEvery) + fpl.majorEvery) % fpl.majorEvery === 0 !== wantMajor) continue
        first = true
        prev = 0
        for (s = 0; s <= segs; s++) {
          p = fpl.warp(-pad + (s / segs) * span, i * fpl.cell)
          cross = fpl.pixelateGrid ? fpl.snap(p.y) + 0.5 : p.y
          along = p.x
          if (first) {
            out.push("M" + along.toFixed(1) + " " + cross.toFixed(1))
            first = false
          } else {
            if (fpl.pixelateGrid && cross !== prev) emit(along, prev)
            emit(along, cross)
          }
          prev = cross
        }
      }
      return out.join(" ")
    }

    // Registration crosses on every second major intersection.
    function buildMarkPath() {
      if (fpl.width <= 0 || fpl.height <= 0 || !fpl.showMarks) return ""
      var step = fpl.cell * fpl.majorEvery * 2
      if (step <= 0) return ""
      var arm = 4
      var out = []
      for (var y = step; y < fpl.height; y += step) {
        for (var x = step; x < fpl.width; x += step) {
          var p = fpl.warp(x, y)
          var px = p.x.toFixed(1)
          var py = p.y.toFixed(1)
          out.push("M" + (p.x - arm).toFixed(1) + " " + py + "L" + (p.x + arm).toFixed(1) + " " + py)
          out.push("M" + px + " " + (p.y - arm).toFixed(1) + "L" + px + " " + (p.y + arm).toFixed(1))
        }
      }
      return out.join(" ")
    }

    readonly property string fineGridPath: fpl.buildGridPath(false)
    readonly property string majorGridPath: fpl.buildGridPath(true)
    readonly property string markPath: fpl.buildMarkPath()

    visible: fpl.active
    clip: true

    // Everything on the tube. Rendered to a texture and fed through the CRT
    // shader below when that is on; drawn directly when it is off.
    Item {
      id: tube
      anchors.fill: parent

      // Optional wash of the theme's background over the user's wallpaper,
      // inside the tube so the CRT vignette and curvature apply to it too.
      Rectangle {
        anchors.fill: parent
        color: fpl.groundColor
        opacity: Math.max(0, Math.min(1, fpl.num("backdrop", 0.55)))
        visible: fpl.active && opacity > 0
      }

    // Grid, clipped to the field.
    Item {
      x: fpl.fieldTL.x
      y: fpl.fieldTL.y
      width: fpl.fieldBR.x - fpl.fieldTL.x
      height: fpl.fieldBR.y - fpl.fieldTL.y
      clip: true

      // Back in tube coordinates, so nothing inside needs to know it moved.
      Item {
        x: -parent.x
        y: -parent.y
        width: fpl.width
        height: fpl.height

    Shape {
      anchors.fill: parent
      visible: fpl.showGrid
      asynchronous: false
      // Static: render once to a texture instead of re-tessellating every tick.
      layer.enabled: true

      ShapePath {
        strokeColor: Qt.rgba(fpl.gridColor.r, fpl.gridColor.g, fpl.gridColor.b, fpl.gridAlpha)
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: fpl.fineGridPath }
      }
      ShapePath {
        strokeColor: Qt.rgba(fpl.gridColor.r, fpl.gridColor.g, fpl.gridColor.b, fpl.gridMajorAlpha)
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: fpl.majorGridPath }
      }
      ShapePath {
        strokeColor: Qt.rgba(fpl.gridColor.r, fpl.gridColor.g, fpl.gridColor.b,
                             Math.min(1, fpl.gridMajorAlpha * 2.1))
        strokeWidth: 1
        fillColor: "transparent"
        PathSvg { path: fpl.markPath }
      }
    }
      }
    }

    // ---- trajectories -------------------------------------------------------
    //
    // Held in their own item so halation can be sourced from the bright things
    // only: blooming the grid as well would just haze the whole tube.
    Item {
      id: plot
      anchors.fill: parent
      // An offscreen copy of the plot is only needed to feed the fallback
      // blur below; with the CRT shader on, glow comes from mipmaps instead.
      layer.enabled: fpl.showHalation && !fpl.shaderCrt
      layer.smooth: true

      HudLayer {
        anchors.fill: parent
        host: fpl
      }

    // Trails, clipped to the field: they are only drawn once they cross the frame.
    Item {
      x: fpl.fieldTL.x
      y: fpl.fieldTL.y
      width: fpl.fieldBR.x - fpl.fieldTL.x
      height: fpl.fieldBR.y - fpl.fieldTL.y
      clip: true

      // Back in tube coordinates, so nothing inside needs to know it moved.
      Item {
        x: -parent.x
        y: -parent.y
        width: fpl.width
        height: fpl.height

      Repeater {
        model: fpl.pathCount

        delegate: Item {
          id: trail
          required property int index
          anchors.fill: parent

          property point p0: Qt.point(0, 0)
          property point p1: Qt.point(0, 0)
          property point p2: Qt.point(0, 0)
          property point p3: Qt.point(0, 0)
          // A trail remembers WHICH colour it is -- a palette slot, or its
          // callout -- never the colour itself, and resolves it live. Storing
          // the value would carry the old theme's colours into the new one
          // for the rest of the flight.
          property int paletteIndex: 0
          readonly property color tint: trail.flag === "warning"
            ? fpl.resolve(fpl.hudOpt("warningColor", "urgent"), "urgent")
            : trail.flag === "target"
              ? fpl.resolve(fpl.hudOpt("targetColor", "accent"), "accent")
              : fpl.resolve(fpl.trailPalette[trail.paletteIndex % Math.max(1, fpl.trailPalette.length)], "foreground")
          property string tag: ""
          property int dots: 40
          property real progress: 0
          property int crossDuration: 30000
          property int holdDuration: 4000
          property int fadeDuration: 7000
          // "" for an ordinary contact, or "warning" / "target" for one the
          // plot has singled out -- those take burgundy / orange and a callout.
          property string flag: ""
          property int beat: 0

          // Integer: changes once per dot, not once per frame.
          readonly property int headIndex: Math.floor(trail.progress * trail.dots)
          readonly property point head: fpl.warp(
            fpl.bezier(trail.p0, trail.p1, trail.p2, trail.p3, trail.progress).x,
            fpl.bezier(trail.p0, trail.p1, trail.p2, trail.p3, trail.progress).y)

          opacity: 0
          visible: trail.opacity > 0

          // The fade gradient moves in steps of 4 dots. Every dot's opacity
          // depends on it, so tracking headIndex directly would re-evaluate
          // the whole trail each time the head advanced a single dot; at 4
          // the difference can't be seen and the work drops by three quarters.
          readonly property int fadeIndex: Math.floor(trail.headIndex / 4) * 4

          // Bright at the head, dimming back along the trail.
          // Must not read headIndex: visibility past the head is the dot's own
          // `visible` binding, and reading it here would undo the stepping.
          function alphaAt(i) {
            var d = Math.max(0, trail.fadeIndex - i)
            var span = Math.max(1, trail.dots * 0.8)
            return 0.12 + 0.76 * (1 - Math.min(1, d / span))
          }

          function respawn() {
            if (fpl.width <= 0 || fpl.height <= 0) return

            var margin = 60
            var from = Math.floor(Math.random() * 4)
            // Leave by the opposite edge, or one of its neighbours, so the path
            // actually crosses the screen instead of clipping a corner.
            var to = (from + 2 + (Math.floor(Math.random() * 3) - 1) + 4) % 4
            if (to === from) to = (from + 2) % 4

            var s = fpl.edgePoint(from, 0.12 + Math.random() * 0.76, margin)
            var e = fpl.edgePoint(to, 0.12 + Math.random() * 0.76, margin)

            var dx = e.x - s.x
            var dy = e.y - s.y
            var len = Math.sqrt(dx * dx + dy * dy)
            if (len < 1) return

            // Bow the path off the straight line by a random perpendicular offset.
            var px = -dy / len
            var py = dx / len
            var bow = (Math.random() - 0.5) * 0.36 * len

            trail.p0 = s
            trail.p1 = Qt.point(s.x + dx * 0.33 + px * bow, s.y + dy * 0.33 + py * bow)
            trail.p2 = Qt.point(s.x + dx * 0.66 + px * bow * 0.55, s.y + dy * 0.66 + py * bow * 0.55)
            trail.p3 = e

            trail.dots = Math.max(8, Math.min(260, Math.round(len / fpl.dotSpacing)))
            var roll = Math.random()
            var pWarn = fpl.showCallouts ? fpl.hudNum("warningChance", 0.12) : 0
            var pLock = fpl.showCallouts ? fpl.hudNum("targetChance", 0.14) : 0
            if (roll < pWarn) {
              trail.flag = "warning"
            } else if (roll < pWarn + pLock) {
              trail.flag = "target"
            } else {
              trail.flag = ""
              trail.paletteIndex = Math.floor(Math.random() * fpl.trailPalette.length)
            }
            trail.tag = fpl.callsign()
            trail.crossDuration = fpl.randRange("crossMin", 26000, "crossMax", 44000)
            trail.holdDuration = fpl.randRange("holdMin", 2500, "holdMax", 6000)
            trail.fadeDuration = fpl.randRange("fadeMin", 5000, "fadeMax", 9000)
          }

          // Stepped clock rather than a NumberAnimation. A continuous
          // animation would pin the compositor at 60fps for as long as any
          // desktop is visible, which is a poor trade on a laptop. Ticking at
          // ~10Hz lets the scene go idle between steps, and the trail advancing
          // in discrete jumps suits a radar plot better than smooth motion does.
          property int phase: 0      // 0 gap, 1 draw, 2 hold, 3 fade
          property int elapsed: 0
          property int gapDuration: 3000

          function advance(dt) {
            trail.elapsed += dt
            trail.beat += 1

            if (trail.phase === 0) {
              if (trail.elapsed >= trail.gapDuration) trail.begin()
              return
            }

            if (trail.phase === 1) {
              trail.progress = Math.min(1, trail.elapsed / Math.max(1, trail.crossDuration))
              if (trail.elapsed >= trail.crossDuration) {
                trail.phase = 2
                trail.elapsed = 0
              }
              return
            }

            if (trail.phase === 2) {
              if (trail.elapsed >= trail.holdDuration) {
                trail.phase = 3
                trail.elapsed = 0
              }
              return
            }

            trail.opacity = Math.max(0, 1 - trail.elapsed / Math.max(1, trail.fadeDuration))
            if (trail.elapsed >= trail.fadeDuration) {
              trail.opacity = 0
              trail.phase = 0
              trail.elapsed = 0
              trail.gapDuration = fpl.randRange("gapMin", 1500, "gapMax", 11000)
            }
          }

          function begin() {
            trail.respawn()
            trail.progress = 0
            trail.opacity = 1
            trail.phase = 1
            trail.elapsed = 0
          }

          Component.onCompleted: {
            // Stagger the first launch so they don't all set off together.
            trail.gapDuration = Math.round(Math.random() * 12000) + trail.index * 2600
            trail.respawn()
          }

          Connections {
            target: fpl
            function onStepped(dt) { trail.advance(dt) }
          }

          // The dotted trail itself.
          Repeater {
            model: trail.dots
            delegate: Rectangle {
              required property int index
              // Referencing p0..p3 keeps this bound to the current trajectory.
              readonly property point at: fpl.bezier(trail.p0, trail.p1, trail.p2, trail.p3,
                                                    (index + 0.5) / Math.max(1, trail.dots))
              readonly property point pos: fpl.warp(at.x, at.y)
              x: fpl.snap(pos.x)
              y: fpl.snap(pos.y)
              width: fpl.dotSize
              height: fpl.dotSize
              color: trail.tint
              antialiasing: false
              visible: index <= trail.headIndex
              opacity: trail.alphaAt(index)
            }
          }

          // Tracking reticle at the head of the trail: an X in corner brackets.
          Item {
            id: reticle
            readonly property int arm: 8
            width: 34
            height: 34
            x: fpl.snap(trail.head.x) - width / 2
            y: fpl.snap(trail.head.y) - height / 2
            visible: trail.inFlight && trail.flag !== "target"

            Rectangle {
              anchors.centerIn: parent
              width: 19; height: 2
              color: trail.tint
              rotation: 45
            }
            Rectangle {
              anchors.centerIn: parent
              width: 19; height: 2
              color: trail.tint
              rotation: -45
            }

            Repeater {
              model: 4
              delegate: Item {
                id: corner
                required property int index
                readonly property bool onRight: index === 1 || index === 2
                readonly property bool onBottom: index >= 2
                x: corner.onRight ? reticle.width - reticle.arm : 0
                y: corner.onBottom ? reticle.height - reticle.arm : 0
                width: reticle.arm
                height: reticle.arm
                opacity: 0.55
                Rectangle {
                  x: 0
                  y: corner.onBottom ? corner.height - 1 : 0
                  width: corner.width; height: 1
                  color: trail.tint
                  antialiasing: false
                }
                Rectangle {
                  x: corner.onRight ? corner.width - 1 : 0
                  y: 0
                  width: 1; height: corner.height
                  color: trail.tint
                  antialiasing: false
                }
              }
            }
          }

          // Callouts sit on whichever side of the head has room.
          readonly property int headX: fpl.snap(trail.head.x)
          readonly property int headY: fpl.snap(trail.head.y)
          readonly property int side: trail.headX > fpl.fieldBR.x - 280 ? -1 : 1
          // Tracking -- reticle, callsign, callouts -- only once the head has
          // crossed into the field. Outside it the craft is unobserved.
          readonly property bool inField: trail.headX >= fpl.fieldTL.x && trail.headX <= fpl.fieldBR.x
            && trail.headY >= fpl.fieldTL.y && trail.headY <= fpl.fieldBR.y
          readonly property bool inFlight: trail.progress > 0.001 && trail.progress < 0.999 && trail.inField

          Text {
            readonly property int off: trail.flag === "target" ? 37 : (trail.flag === "warning" ? 55 : 27)
            visible: fpl.showLabels && trail.inFlight
            x: trail.side > 0 ? trail.headX + off : trail.headX - off - implicitWidth
            y: trail.flag === "" ? trail.headY - 20 : trail.headY + 12
            text: trail.tag
            color: trail.tint
            opacity: 0.8
            font.family: fpl.fontFamily
            font.pixelSize: 11
            font.letterSpacing: 2
            renderType: Text.NativeRendering
          }

          // WARNING: leader, crossed box, and a filled bar that blinks.
          Item {
            id: warn
            visible: fpl.showCallouts && trail.inFlight && trail.flag === "warning"
            width: 150
            height: 16
            x: trail.side > 0 ? trail.headX + 17 : trail.headX - 17 - warn.width
            y: trail.headY - 8
            opacity: Math.floor(trail.beat / 5) % 2 === 0 ? 1 : 0.35

            Rectangle {
              x: trail.side > 0 ? 0 : warn.width - 18
              y: 8; width: 18; height: 1
              color: trail.tint
            }
            Item {
              x: trail.side > 0 ? 18 : warn.width - 34
              width: 16; height: 16
              Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: trail.tint }
              Rectangle { anchors.centerIn: parent; width: 15; height: 1; rotation: 45; color: trail.tint }
              Rectangle { anchors.centerIn: parent; width: 15; height: 1; rotation: -45; color: trail.tint }
            }
            Rectangle {
              x: trail.side > 0 ? 38 : 0
              width: 112; height: 16
              color: trail.tint
              Text {
                anchors.centerIn: parent
                text: "WARNING"
                color: fpl.contrastOn(trail.tint)
                font.family: fpl.fontFamily
                font.pixelSize: 10
                font.letterSpacing: 4
                font.bold: true
                renderType: Text.NativeRendering
              }
            }
          }

          // TARGET LOCK: heavy brackets round a solid dot, and a title.
          Item {
            id: lock
            readonly property int arm: 13
            visible: fpl.showCallouts && trail.inFlight && trail.flag === "target"
            width: 58
            height: 58
            x: trail.headX - lock.width / 2
            y: trail.headY - lock.height / 2

            Rectangle {
              anchors.centerIn: parent
              width: 11; height: 11; radius: 5.5
              color: trail.tint
            }
            Repeater {
              model: 4
              delegate: Item {
                id: lc
                required property int index
                readonly property bool onRight: index === 1 || index === 2
                readonly property bool onBottom: index >= 2
                x: lc.onRight ? lock.width - lock.arm : 0
                y: lc.onBottom ? lock.height - lock.arm : 0
                width: lock.arm
                height: lock.arm
                Rectangle {
                  x: 0; y: lc.onBottom ? lc.height - 2 : 0
                  width: lc.width; height: 2
                  color: trail.tint
                  antialiasing: false
                }
                Rectangle {
                  x: lc.onRight ? lc.width - 2 : 0; y: 0
                  width: 2; height: lc.height
                  color: trail.tint
                  antialiasing: false
                }
              }
            }
          }
          Text {
            id: lockTitle
            visible: lock.visible
            x: trail.side > 0 ? lock.x + lock.width + 8 : lock.x - 8 - implicitWidth
            y: lock.y - 2
            text: "TARGET LOCK"
            color: trail.tint
            font.family: fpl.fontFamily
            font.pixelSize: 14
            font.letterSpacing: 2
            font.bold: true
            renderType: Text.NativeRendering
          }
          Rectangle {
            visible: lock.visible
            x: lockTitle.x
            y: lockTitle.y + lockTitle.implicitHeight + 1
            width: lockTitle.implicitWidth
            height: 1
            color: trail.tint
            opacity: 0.6
          }
        }
      }
      }
    }
    }

    // ---- halation ------------------------------------------------------------
    //
    // Phosphor bleed: a blurred copy of the bright plot laid back over itself.
    // Against a black tube, alpha compositing reads as additive, so this glows
    // rather than fogs. Warmed slightly, the way an aging phosphor does.
    // Fallback glow, used only when the CRT shader is switched off. With the
    // shader on, glow is two mipmap reads inside crt.frag: no extra buffer, no
    // multi-pass blur -- measured as the second-largest GPU cost before.
    MultiEffect {
      anchors.fill: plot
      source: plot
      visible: fpl.showHalation && !fpl.shaderCrt
      blurEnabled: true
      blur: 1.0
      blurMax: Math.round(fpl.halationRadius)
      // Auto-padding enlarges the effect to fit the blur spill, and under
      // fractional display scaling the enlarged copy comes back misregistered
      // -- every glow sat ~15px up and to the right of what cast it. The plot
      // is already fullscreen, so there is nothing outside it to pad for.
      autoPaddingEnabled: false
      paddingRect: Qt.rect(0, 0, 0, 0)
      opacity: fpl.halationStrength
      colorization: fpl.halationColorize
      colorizationColor: fpl.halationTint
    }
    }


    // ---- CRT pass -----------------------------------------------------------
    ShaderEffectSource {
      id: tubeTexture
      // Mip levels feed the shader's glow; built only when glow is on.
      mipmap: fpl.showHalation
      sourceItem: tube
      hideSource: fpl.shaderCrt
      live: true
      smooth: true
      visible: false
      textureSize: Qt.size(Math.round(fpl.width * Screen.devicePixelRatio * fpl.supersample),
                           Math.round(fpl.height * Screen.devicePixelRatio * fpl.supersample))
    }

    ShaderEffect {
      anchors.fill: parent
      visible: fpl.shaderCrt
      fragmentShader: Qt.resolvedUrl("crt.frag.qsb")

      property variant source: tubeTexture
      property real curvature: fpl.curvature
      property real scanAlpha: fpl.showScanlines ? fpl.scanAlpha : 0
      property real scanPitch: fpl.scanPitch
      property real maskAlpha: fpl.showMask ? fpl.maskAlpha : 0
      property real vignetteAlpha: fpl.showVignette ? fpl.vignetteAlpha : 0
      property real vignetteSpread: fpl.vignetteSpread
      property real aberration: fpl.aberration
      property size resolution: Qt.size(fpl.width, fpl.height)
      property real glowStrength: fpl.showHalation ? fpl.halationStrength * 0.9 : 0
      // halationRadius in px -> mip level: each level halves the resolution.
      property real glowLod: Math.max(1, Math.min(7,
        Math.log(Math.max(2, fpl.halationRadius * Screen.devicePixelRatio * fpl.supersample) / 3) / Math.LN2))
      property real glowColorize: fpl.halationColorize
      property color glowTint: fpl.halationTint
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      // The Hyprland monitor this panel sits on, and whether its active
      // workspace is fullscreen -- then nothing of the plot shows.
      readonly property var hyprMonitor: Hyprland.monitorFor(panel.screen)
      readonly property bool covered: !!(panel.hyprMonitor && panel.hyprMonitor.activeWorkspace
        && panel.hyprMonitor.activeWorkspace.hasFullscreen)

      screen: modelData
      visible: root.plotEnabled
      color: "transparent"
      anchors { top: true; bottom: true; left: true; right: true }

      // Bottom layer: above the wallpaper (Background layer), below windows.
      WlrLayershell.namespace: "afterglow"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      // Click-through: an empty input region, so clicks (and the wallpaper's
      // own double-click menus) land on whatever is underneath.
      mask: Region {}

      FlightPathsLayer {
        anchors.fill: parent
        active: root.plotEnabled
        cfg: root.config
        paused: root.pauseWhenCovered && panel.covered
        sys: root.sys
        sysSeq: root.sysSeq
      }
    }
  }
}
