import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.UPower

// Psychedelic wallpaper: an oil-slick tint in the dark parts of the wallpaper
// that follows whatever is playing — or the microphone when nothing is.
//
// A transparent, click-through layer on the Bottom layer: above the stock
// omarchy-background surface, below every window. The stock wallpaper (and its
// theme-switch reveal) keeps drawing underneath; this only recolours where the
// image is dark. The wallpaper texture is loaded here too, as the mask.
//
// Audio and wallpaper analysis come from bin/psywall-audio (see its header).
// Nothing renders while it is silent or every screen shows a fullscreen window:
// the layer fades out, the frame loop stops and the window unmaps.
//
// Settings: ~/.config/omarchy/psywall.json (hot-reloads)
//   enabled         true | false (everything: capture, wallpaper, lights)
//   micFallback     listen to the mic when nothing is playing
//   strength        0..2, how much colour
//   wallpaperEffect draw the tint (off leaves the lights running alone)
//   hue             also play it on the Hue lights (music only, never the mic)
//   hueStrength     0..2, light brightness
//   hueAggression   0..2, big moments on the lights: 0 none, 1 normal, 2 wild
//   outputDelays    s the lights and wallpaper wait, per output device
//                   (a sink name, or owntone:<speakers>; "prefix*" patterns ok)
// IPC: omarchy-shell psywall toggle | toggleMic | strength <0..2>
//      | toggleWallpaper | toggleHue | hueStrength <0..2> | aggression <0..2>
//      | delay <s> (for the device playing now) | delays | tee <path|off> | status
//      | hueHold | hueResume (the pane's Hue setup: lights handed back meanwhile)
//      | hueLayout (lights moved) | hueIdentify <light id> | retry
//
// Hue pairing, the choice of lights and where they stand are made in the
// pane (BarWidget.qml + bin/psywall-hue-setup); this service only streams.
//
// Runtime state for the bar widget (BarWidget.qml), in
// $XDG_RUNTIME_DIR/psywall/, so a bar widget can follow the show without a
// second audio capture or fast IPC polling:
//   status.json  settings + state: on change, plus a 5 s heartbeat while enabled
//   audio.json   bands/level/beats/accent/src, 15/s while something is heard
//   show.json    the lights' Director (bin/psywall-hue I lines), <=10/s while
//                streaming, with the room layout and the last 30 big moments
Item {
  id: root

  // Supplied by the shell's plugin loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginDir: {
    if (manifest && manifest.__sourceDir) return String(manifest.__sourceDir)
    var here = decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
    return here.endsWith("/") ? here.slice(0, -1) : here
  }
  readonly property string helper: pluginDir + "/bin/psywall-audio"

  // A library the audio helper can't find (libfftw3f: part of every Omarchy
  // install, so only a damaged system shows this).
  property string missing: ""

  // ---- settings -----------------------------------------------------------
  FileView {
    id: settingsFile
    path: Quickshell.env("HOME") + "/.config/omarchy/psywall.json"
    watchChanges: true
    onFileChanged: reload()
    onAdapterUpdated: writeAdapter()
    onLoadFailed: function(error) { if (error === FileViewError.FileNotFound) writeAdapter() }

    JsonAdapter {
      id: settings
      property bool enabled: true
      // Off until the user turns it on: listening to the room is opt-in.
      property bool micFallback: false
      property real strength: 1.0
      property bool wallpaperEffect: true
      property bool hue: true
      property real hueStrength: 1.0
      // 0 = no big moments (HIT/RELEASE/BURST, blasts), 1 = normal, 2 = wild.
      property real hueAggression: 1.0
      // Seconds the lights and wallpaper wait for each output device, so they
      // land with the sound. Exact device names win over "prefix*" patterns.
      property var outputDelays: ({ "raop_sink.*": 1.75, "owntone:*": 2.0 })
    }
  }

  // ---- audio --------------------------------------------------------------
  // Raw targets from the helper, and the smoothed values the shader sees.
  property real tBass: 0
  property real tMids: 0
  property real tHighs: 0
  property real tLevel: 0
  property real bass: 0
  property real mids: 0
  property real highs: 0
  property real level: 0
  property real beat: 0
  property real hue: 0
  property string src: "-"
  property string output: ""   // default sink, as the helper last saw it

  // Wallpaper mask: path and its dark range, from the helper's W lines.
  property string wallPath: ""
  property int maskStatus: Image.Null
  property real darkLo: 0
  property real darkHi: 0.25

  // The delay for an output device: its exact entry, else the longest
  // matching "prefix*" pattern, else none (the laptop's own speakers).
  function delayFor(out) {
    var table = settings.outputDelays || {}
    if (out && table[out] !== undefined) return Number(table[out])
    var best = -1, value = 0
    for (var key in table) {
      if (key.charAt(key.length - 1) !== "*") continue
      var prefix = key.substring(0, key.length - 1)
      if (out.indexOf(prefix) === 0 && prefix.length > best) { best = prefix.length; value = Number(table[key]) }
    }
    return value
  }

  function sendDelay() {
    if (proc.running) proc.write("delay " + delayFor(output) + "\n")
  }

  function handleLine(line) {
    var c = line.charAt(0)
    if (c === "A") {
      if (hueProc.running) hueProc.write(line + "\n")
      var v = line.split(" ")
      tBass = Number(v[1]); tMids = Number(v[2]); tHighs = Number(v[3]); tLevel = Number(v[4])
      if (v[5] === "1") beat = 1
      src = v[6] || "-"
      if (tLevel > 0.08) { heard = true; silenceTimer.restart() }
      // Peaks since the last audio.json frame (a plain JS object: no bindings).
      var a = audioAcc
      if (tBass > a.b) a.b = tBass
      if (tMids > a.m) a.m = tMids
      if (tHighs > a.h) a.h = tHighs
      if (tLevel > a.l) a.l = tLevel
      if (v[5] === "1") a.beats++
      var acc = Number(v[7]) || 0
      if (acc > a.acc) a.acc = acc
      a.n++
    } else if (c === "W") {
      var m = line.match(/^W (\S+) (\S+) (.*)$/)
      if (m) { darkLo = Number(m[1]); darkHi = Number(m[2]); wallPath = m[3] }
    } else if (c === "S") {
      if (line.indexOf("S missing ") === 0) {
        root.missing = line.substring(10)
        return
      }
      if (line.indexOf("S output ") === 0) {
        output = line.substring(9)
        sendDelay()
      }
      console.log("psywall:", line.substring(2))
    }
  }

  Process {
    id: proc
    running: settings.enabled
    command: [root.helper].concat(settings.micFallback ? [] : ["--no-mic"])
    stdinEnabled: true
    onStarted: { root.missing = ""; root.sendDelay() }
    stdout: SplitParser { onRead: function(line) { root.handleLine(line) } }
    stderr: SplitParser { onRead: function(line) { console.warn("psywall:", line) } }
    onExited: {
      root.tBass = root.tMids = root.tHighs = root.tLevel = 0
      if (settings.enabled) restartTimer.restart()
    }
  }

  Connections {
    target: settings
    function onMicFallbackChanged() { if (proc.running) proc.write("mic " + (settings.micFallback ? "on" : "off") + "\n") }
    function onOutputDelaysChanged() { root.sendDelay() }
  }

  Timer {
    id: restartTimer
    // A missing package won't appear by itself quickly: check now and then.
    interval: root.missing ? 15000 : 2000
    onTriggered: if (settings.enabled && !proc.running) proc.running = true
  }

  // ---- Hue lights ---------------------------------------------------------
  // bin/psywall-hue gets the same audio lines and streams them to the lights
  // chosen in the pane's Hue setup while music (not the mic) plays.
  readonly property string hueHelper: pluginDir + "/bin/psywall-hue"
  // The pane holds the helper off while it pairs or changes the lights.
  property bool hueHeld: false
  readonly property bool hueWanted: settings.enabled && settings.hue && !hueHeld
  property string hueState: "stopped"

  Process {
    id: hueProc
    running: root.hueWanted
    command: [root.hueHelper]
    stdinEnabled: true
    stdout: SplitParser {
      onRead: function(line) {
        var c = line.charAt(0)
        if (c === "I") { root.handleInfo(line.substring(2)); return }
        if (c !== "S") return
        root.hueState = line.substring(2)
        console.log("psywall: hue", root.hueState)
      }
    }
    stderr: SplitParser { onRead: function(line) { console.warn("psywall: hue:", line) } }
    onStarted: {
      write("strength " + settings.hueStrength + "\n")
      write("aggression " + settings.hueAggression + "\n")
    }
    onExited: {
      root.hueState = "stopped"
      root.writeShow({ stopped: true })
      // Backstop for a hard kill: put back any lights it saved but didn't
      // get to restore. A no-op when there's nothing left to do.
      Quickshell.execDetached([root.hueHelper, "--restore"])
      if (root.hueWanted) hueRestartTimer.restart()
    }
  }

  // A hold never outlives a pane that went away mid-setup.
  Timer {
    id: holdRelease
    interval: 10 * 60 * 1000
    onTriggered: root.hueHeld = false
  }

  Timer {
    id: hueRestartTimer
    interval: 5000
    onTriggered: if (root.hueWanted && !hueProc.running) hueProc.running = true
  }

  Connections {
    target: settings
    function onHueStrengthChanged() { if (hueProc.running) hueProc.write("strength " + settings.hueStrength + "\n") }
    function onHueAggressionChanged() { if (hueProc.running) hueProc.write("aggression " + settings.hueAggression + "\n") }
  }

  // ---- presence -----------------------------------------------------------
  // `heard` stays true until 2.5 s after the last audible frame.
  property bool heard: false
  Timer {
    id: silenceTimer
    interval: 2500
    onTriggered: root.heard = false
  }

  readonly property bool allCovered: {
    var ms = Hyprland.monitors.values
    if (!ms.length) return false
    for (var i = 0; i < ms.length; i++)
      if (!(ms[i].activeWorkspace && ms[i].activeWorkspace.hasFullscreen)) return false
    return true
  }

  readonly property bool wanted: settings.enabled && settings.wallpaperEffect && heard && !allCovered && wallPath !== ""
  property real presence: 0
  readonly property bool animating: wanted || presence > 0.001
  readonly property real intensity: presence * Math.max(0, Math.min(2, settings.strength))

  // Nothing here moves fast, so updates are capped at 30/s (20 on battery).
  property real pending: 0

  FrameAnimation {
    running: root.animating
    onTriggered: {
      root.pending += Math.min(frameTime, 0.1)
      if (root.pending < 1 / (UPower.onBattery ? 21 : 31)) return
      var dt = root.pending
      root.pending = 0
      var up = 1 - Math.exp(-dt * 12)
      var down = 1 - Math.exp(-dt * 4)
      root.bass += (root.tBass - root.bass) * (root.tBass > root.bass ? up : down)
      root.mids += (root.tMids - root.mids) * (root.tMids > root.mids ? up : down)
      root.highs += (root.tHighs - root.highs) * (root.tHighs > root.highs ? up : down)
      root.level += (root.tLevel - root.level) * (root.tLevel > root.level ? up : down)
      root.beat *= Math.exp(-dt * 2.5)
      root.hue += dt * (0.015 + 0.05 * root.highs)
      var target = root.wanted ? 1 : 0
      var step = dt * (target > root.presence ? 1.0 : 0.6)
      root.presence = target > root.presence ? Math.min(target, root.presence + step) : Math.max(target, root.presence - step)
    }
  }

  // ---- runtime state for the psywall view ---------------------------------
  // Written only; nothing here reads them back. Each writer stops when there
  // is nothing new to say.
  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/psywall"
  property bool runReady: false

  Process {
    running: true
    command: ["mkdir", "-p", root.runDir]
    onExited: { root.runReady = true; root.writeStatus() }
  }

  FileView { id: statusOut; path: root.runDir + "/status.json"; preload: false; printErrors: false }
  FileView { id: audioOut; path: root.runDir + "/audio.json"; preload: false; printErrors: false }
  FileView { id: showOut; path: root.runDir + "/show.json"; preload: false; printErrors: false }

  function r3(x) { return Math.round(x * 1000) / 1000 }

  function statusObject() {
    return {
      enabled: settings.enabled, micFallback: settings.micFallback, strength: settings.strength,
      wallpaperEffect: settings.wallpaperEffect,
      source: root.src === "m" ? "music" : (root.src === "i" ? "mic" : "silent"),
      presence: Math.round(root.presence * 100) / 100, wallpaper: root.wallPath,
      mask: ["none", "ready", "loading", "error"][root.maskStatus] || String(root.maskStatus),
      covered: root.allCovered,
      hue: settings.hue, hueStrength: settings.hueStrength, hueAggression: settings.hueAggression,
      hueState: settings.hue ? (root.hueHeld ? "setting up" : root.hueState) : "off",
      missing: root.missing,
      output: root.output, delay: root.delayFor(root.output),
      delaying: root.src === "m" && root.delayFor(root.output) > 0,
      darkLo: root.darkLo, darkHi: root.darkHi
    }
  }

  function writeStatus() {
    if (!runReady) return
    var s = statusObject()
    s.t = Date.now() / 1000
    s.heard = root.heard
    statusOut.setText(JSON.stringify(s))
  }

  Timer { id: statusSoon; interval: 150; onTriggered: root.writeStatus() }
  Timer { interval: 5000; repeat: true; running: settings.enabled && root.runReady; onTriggered: root.writeStatus() }

  Connections {
    target: settings
    function onEnabledChanged() { statusSoon.restart() }
    function onMicFallbackChanged() { statusSoon.restart() }
    function onStrengthChanged() { statusSoon.restart() }
    function onWallpaperEffectChanged() { statusSoon.restart() }
    function onHueChanged() { statusSoon.restart() }
    function onHueStrengthChanged() { statusSoon.restart() }
    function onHueAggressionChanged() { statusSoon.restart() }
    function onOutputDelaysChanged() { statusSoon.restart() }
  }
  onSrcChanged: statusSoon.restart()
  onOutputChanged: statusSoon.restart()
  onHueStateChanged: statusSoon.restart()
  onHueHeldChanged: statusSoon.restart()
  onMissingChanged: statusSoon.restart()
  onHeardChanged: statusSoon.restart()
  onWallPathChanged: statusSoon.restart()

  // Audio: the peaks of each ~66 ms, while anything is heard, then one quiet
  // frame so the view settles instead of freezing mid-beat.
  property var audioAcc: ({ b: 0, m: 0, h: 0, l: 0, beats: 0, acc: 0, n: 0 })

  function writeAudio(quiet) {
    var a = audioAcc
    if (!runReady || (!quiet && a.n === 0)) return
    audioOut.setText(JSON.stringify(quiet
      ? { t: Date.now() / 1000, b: 0, m: 0, h: 0, l: 0, beats: 0, acc: 0, src: root.src, quiet: true }
      : { t: Date.now() / 1000, b: r3(a.b), m: r3(a.m), h: r3(a.h), l: r3(a.l), beats: a.beats, acc: r3(a.acc), src: root.src }))
    a.b = a.m = a.h = a.l = a.acc = 0
    a.beats = a.n = 0
  }

  Timer {
    interval: 66
    repeat: true
    running: settings.enabled && root.heard && root.runReady
    onTriggered: root.writeAudio(false)
    onRunningChanged: if (!running) root.writeAudio(true)
  }

  // Show: every I line from bin/psywall-hue, stamped (the helper sends no
  // time), with the room layout from the stream start and the big moments.
  property int showSeq: 0
  property var showLayout: []
  property var moments: []

  function handleInfo(text) {
    var o
    try { o = JSON.parse(text) } catch (e) { return }
    if (!o || typeof o !== "object") return
    if (o.layout) { showLayout = o.layout; return }
    if (o.stopped) { writeShow({ stopped: true }); return }
    var now = Date.now() / 1000
    var ev = o.events || []
    for (var i = 0; i < ev.length; i++) {
      var e = String(ev[i])
      var kind = e.split(" ")[0]
      if (kind === "glint" || kind === "pop" || kind === "style") continue
      moments.push({ t: now, e: e })
    }
    if (moments.length > 30) moments.splice(0, moments.length - 30)
    writeShow(o)
  }

  function writeShow(o) {
    if (!runReady) return
    showSeq++
    o.t = Date.now() / 1000
    o.seq = showSeq
    o.layout = showLayout
    o.moments = moments
    showOut.setText(JSON.stringify(o))
  }

  // ---- IPC ----------------------------------------------------------------
  IpcHandler {
    target: "psywall"

    function toggle(): void { settings.enabled = !settings.enabled }
    function toggleMic(): void { settings.micFallback = !settings.micFallback }
    function strength(value: real): void { settings.strength = Math.max(0, Math.min(2, value)) }
    function toggleWallpaper(): void { settings.wallpaperEffect = !settings.wallpaperEffect }
    function toggleHue(): void { settings.hue = !settings.hue }
    function hueStrength(value: real): void { settings.hueStrength = Math.max(0, Math.min(2, value)) }
    function aggression(value: real): void { settings.hueAggression = Math.max(0, Math.min(2, value)) }
    // Tune by ear: sets the delay for whichever device is playing right now.
    function delay(seconds: real): string {
      if (!root.output) return "no output device seen yet"
      var table = Object.assign({}, settings.outputDelays || {})
      table[root.output] = Math.round(Math.max(0, Math.min(5, seconds)) * 100) / 100
      settings.outputDelays = table
      return root.output + " -> " + table[root.output] + " s"
    }
    function delays(): string { return JSON.stringify(settings.outputDelays) }
    function tee(path: string): void { if (proc.running) proc.write("tee " + path + "\n") }
    function status(): string { return JSON.stringify(root.statusObject()) }
    function hueHold(): void { root.hueHeld = true; holdRelease.restart() }
    function hueResume(): void { holdRelease.stop(); root.hueHeld = false; if (root.hueWanted && !hueProc.running) hueProc.running = true }
    function hueLayout(): void { if (hueProc.running) hueProc.write("layout\n") }
    function hueIdentify(id: string): void { if (hueProc.running && /^[0-9a-f-]{8,64}$/.test(id)) hueProc.write("identify " + id + "\n") }
    function retry(): void { root.missing = ""; if (settings.enabled && !proc.running) proc.running = true }
  }

  // ---- surfaces -----------------------------------------------------------
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: panel
      required property var modelData

      screen: modelData
      readonly property var hyprMonitor: Hyprland.monitorFor(modelData)
      readonly property bool covered: !!(hyprMonitor && hyprMonitor.activeWorkspace && hyprMonitor.activeWorkspace.hasFullscreen)
      // Not gated on the mask image: it loads inside this window, and
      // maskFade keeps the effect dark until it is ready.
      visible: root.animating && !covered

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "psywall"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      // Visual only: clicks (the double-click wallpaper picker) go through.
      mask: Region {}

      // Mask source; same file the stock background shows. Mipmapped so the
      // shader can take a heavily blurred sample for the hue.
      Image {
        id: wallImg
        visible: false
        source: root.wallPath ? "file://" + root.wallPath : ""
        asynchronous: true
        cache: false
        mipmap: true
      }

      // Swap masks behind a quick fade so a theme switch doesn't pop.
      property real maskFade: 0
      Connections {
        target: root
        function onWallPathChanged() { panel.maskFade = 0 }
      }
      Connections {
        target: wallImg
        function onStatusChanged() {
          root.maskStatus = wallImg.status
          if (wallImg.status === Image.Ready) fadeIn.restart()
        }
      }
      NumberAnimation { id: fadeIn; target: panel; property: "maskFade"; to: 1; duration: 600; easing.type: Easing.InOutQuad }

      ShaderEffect {
        anchors.fill: parent
        fragmentShader: Qt.resolvedUrl("shaders/psywall.frag.qsb")

        property var wall: wallImg
        property real hue: root.hue
        property real bass: root.bass
        property real mids: root.mids
        property real level: root.level
        property real beat: root.beat
        property real intensity: root.intensity * panel.maskFade
        property real darkLo: root.darkLo
        property real darkHi: root.darkHi

        // PreserveAspectCrop, centred — the same framing as the stock background.
        readonly property real aspect: width / Math.max(1, height)
        readonly property real imgAspect: wallImg.implicitWidth / Math.max(1, wallImg.implicitHeight)
        property vector2d cropScale: imgAspect > aspect ? Qt.vector2d(aspect / imgAspect, 1) : Qt.vector2d(1, imgAspect / aspect)
        property vector2d cropOffset: Qt.vector2d((1 - cropScale.x) / 2, (1 - cropScale.y) / 2)
      }
    }
  }
}
