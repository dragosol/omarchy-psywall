import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "ViewModel.js" as VM

// What the psywall light show is doing.
//
// Bar: a miniature of the room, each light a dot in its live colour at its
// place in the room (side lights as rings). Still and dim while psywall is off
// or silent. Hover for a preview; click to pin (the same behaviour as
// a spectrum popup): the preview closes ~300 ms after the pointer leaves the
// widget and the card; a pin stays until the widget is clicked again, Escape
// or the × control, and clicks in other windows don't close it.
//
// Popup: room map (hover a light for its name and what drives its colour),
// a slow soundscape of the last 30 s with the big moments marked, the
// Director's state, recent moments, output + delay, and controls.
//
// Data: files the psywall service (Service.qml) writes to $XDG_RUNTIME_DIR/psywall/ —
// status.json (on change), audio.json (15/s while heard), show.json (<=10/s
// while the lights stream). Polled, not watched: they are replaced atomically
// many times a second. This widget never captures audio; controls go through
// `omarchy-shell psywall ...`.
//
// Hue setup lives here too, entirely in the card: find the bridge (mDNS,
// else Signify's discovery service, else an address typed in), press its
// link button, choose which lights follow the beat and which glow, then place
// each light where it really stands — click one and it blinks in the room,
// drag it to its spot. bin/psywall-hue-setup does the bridge work; the room
// (no secrets) is ~/.config/psywall/lights.json, which also draws the bar
// miniature, so the bar always shows exactly the lights that are paired.
//
// IPC: omarchy-shell psywall-view open (pin) | close | toggle | preview | setup | arrange | state
Panel {
  id: root
  moduleName: "io.github.dragosol.psywall"
  ipcTarget: "psywall-view"
  manageIpc: false

  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/psywall"
  readonly property string pluginDir: {
    var here = decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
    return here.endsWith("/") ? here.slice(0, -1) : here
  }
  readonly property string setupBin: pluginDir + "/bin/psywall-hue-setup"
  readonly property string roomPath: Quickshell.env("HOME") + "/.config/psywall/lights.json"

  // ---- state from the files ------------------------------------------------
  property var status: null
  property var audio: null
  property var show: null
  // The paired room (lights.json): every light chosen at setup, where it
  // stands, and whether it streams live or takes slow fades. Empty until paired.
  property var room: null
  readonly property bool paired: !!(room && room.bridge)
  // A room written before the bridge's light ids were known (an older
  // pairing): drawn, but not movable until the first stream fills the ids in.
  readonly property bool roomComplete: layout.length > 0 && layout.every(function(l) { return !!l.id && l.id !== "undefined" })
  readonly property var layout: (room && room.lights ? room.lights : []).map(function(l) {
    // Files from before per-light modes: "glow" meant slow, "beat" streamed.
    var live = l.live !== undefined ? !!l.live : l.mode !== "glow"
    var mode = l.live !== undefined ? String(l.mode || "dynamic") : (live ? "dynamic" : "glow")
    return { id: String(l.id), name: String(l.name || "Light"), room: String(l.room || ""),
             x: Number(l.x) || 0, y: Number(l.y) || 0, fast: live, mode: mode }
  })
  // The show's own light order (channel order) can differ from the room's:
  // each room light's slot in show.lights, matched by name.
  property var showLayout: []
  readonly property var showIndex: {
    var at = {}
    for (var j = 0; j < showLayout.length; j++) if (at[showLayout[j].name] === undefined) at[showLayout[j].name] = j
    return layout.map(function(e) { return at[e.name] === undefined ? -1 : at[e.name] })
  }
  property real nowT: Date.now() / 1000
  property bool statusFileOk: false

  // History for the soundscape: {t, b, m, h, l, i, sec, pal}; accents: {t, k}.
  property var history: []
  property var accents: []
  property real lastAudioT: 0   // newest audible sample (history is mutated in place, so bind to this)
  readonly property real historySpan: 30

  readonly property bool enabled: !!(status && status.enabled)
  // Off counts as paused: hover stops previewing, a click still opens the card.
  readonly property bool paused: !!status && !status.enabled
  readonly property bool statusStale: !!status && status.enabled && statusFileOk && (nowT - Number(status.t || 0)) > 16
  readonly property bool audioLive: !!audio && !audio.quiet && audio.src !== "-" && (nowT - Number(audio.t || 0)) < 2.2
  readonly property bool showLive: !!show && !show.stopped && (nowT - Number(show.t || 0)) < 2.6
  readonly property bool live: enabled && !statusStale && (audioLive || showLive)
  readonly property bool hueOn: !!(status && status.hue)
  readonly property bool heard: !!(status && status.heard)
  readonly property string source: status ? String(status.source || "silent") : "silent"

  readonly property var palette: {
    var p = showLive && show.palette_rgb && show.palette_rgb.length >= 3 ? show.palette_rgb : null
    if (p) return p.map(function(c) { return Qt.rgba(c[0], c[1], c[2], 1) })
    return [Util.alpha(popupText, 0.9), Util.alpha(popupText, 0.6), Color.accent]
  }

  // ---- theme ---------------------------------------------------------------
  readonly property color popupText: Color.popups.text
  readonly property color popupDim: Util.alpha(Color.popups.text, 0.55)
  readonly property color popupFaint: Util.alpha(Color.popups.text, 0.32)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- one-line summary ----------------------------------------------------
  readonly property string outputShort: status && status.output ? VM.shortOutput(status.output) + " " + VM.delayText(status.delay) : ""
  readonly property string summary: {
    if (!status) return "Psywall: no status yet"
    if (!status.enabled) return "Psywall off · click for controls"
    if (statusStale) return "Psywall not responding"
    var parts = []
    if (showLive) {
      parts.push(show.section || "warming up")
      parts.push("intensity " + Math.round(VM.clamp01(show.intensity) * 100) + "%")
    } else if (audioLive) {
      parts.push(source === "mic" ? "listening to the room" : "music")
      parts.push(hueOn ? "lights waiting" : "lights off")
    } else {
      parts.push(source === "mic" ? "listening to the room" : "waiting for music")
    }
    if (outputShort && source !== "mic") parts.push(outputShort)
    return parts.join(" · ")
  }

  // ---- popup state: hover preview + click-to-pin (as in a spectrum widget) ------
  property bool pinned: false
  property bool hoverPreview: false
  property bool suppressHover: false   // after a click-close, until the pointer leaves
  property bool focusOnPin: false      // take keyboard focus (Escape) on this pin?
  readonly property bool hovering: button.tooltipHovered || (popup.visible && popup.containsMouse)
  readonly property bool popupVisible: pinned || hoverPreview

  function stateString() { return pinned ? "pinned" : (hoverPreview ? "preview" : "closed") }

  // withFocus: true for a real click on the widget/card (Escape should work
  // at once); false for scripts/IPC, so a pin never steals keystrokes from
  // the window being typed in.
  function pin(withFocus) {
    suppressHover = false
    graceTimer.stop()
    focusOnPin = !!withFocus
    pinned = true
  }

  // Overrides Panel.close(): unpins and drops the preview; a click-close
  // doesn't immediately reopen as a preview under the pointer.
  function close(reason) {
    openDelay.stop()
    graceTimer.stop()
    pinned = false
    hoverPreview = false
    if (hovering) suppressHover = true
  }
  function open() { pin(false) }
  function toggle() { if (pinned) close("toggle"); else pin(false) }
  function clickWidget() { if (pinned) close("widget click"); else pin(true) }

  onHoveringChanged: {
    if (hovering) {
      graceTimer.stop()
      if (!pinned && !hoverPreview && !suppressHover && !paused) openDelay.restart()
    } else {
      openDelay.stop()
      suppressHover = false
      if (hoverPreview && !pinned) graceTimer.restart()
    }
  }

  // Paused: hovering no longer previews (a click still pins, to resume).
  onPausedChanged: if (paused) { openDelay.stop(); if (hoverPreview && !pinned) hoverPreview = false }

  onPinnedChanged: {
    popup.focusPrimed = false
    if (pinned) {
      hoverPreview = false
      focusPrimeTimer.restart()
    } else {
      focusPrimeTimer.stop()
      // Closing the card leaves setup, except mid-pairing or mid-save, which
      // carry on (the bridge button may be a walk away) and show on reopen.
      if (setupOpen && setupStep !== "link" && setupStep !== "saving") closeSetup()
      arranging = false
    }
  }

  Timer {
    id: openDelay
    interval: 140
    onTriggered: if (root.hovering && !root.pinned && !root.suppressHover && !root.paused) root.hoverPreview = true
  }

  Timer {
    id: graceTimer
    interval: 300
    onTriggered: if (!root.hovering && !root.pinned) root.hoverPreview = false
  }

  // Click-pins: brief Exclusive keyboard focus so Escape works straight away.
  // Every pin then settles on OnDemand: other windows stay usable and a click
  // on the card refocuses it.
  Timer {
    id: focusPrimeTimer
    interval: 75
    onTriggered: {
      if (!root.pinned) return
      popup.focusPrimed = true
      if (root.focusOnPin) keyItem.forceActiveFocus()
    }
  }

  // ---- IPC -------------------------------------------------------------------
  IpcHandler {
    target: "psywall-view"
    function open(): void { root.pin(false) }
    function show(): void { root.pin(false) }
    function close(): void { root.close("ipc") }
    function hide(): void { root.close("ipc") }
    function toggle(): void { root.toggle() }
    function preview(): void { if (!root.pinned) root.hoverPreview = true }
    function setup(): void { root.openSetup() }
    function arrange(): void { root.pin(false); root.arranging = true }
    function state(): string {
      return JSON.stringify({ open: root.popupVisible, pinned: root.pinned, setup: root.setupOpen ? root.setupStep : "", arranging: root.arranging,
        paired: root.paired, lights: root.layout.length, live: root.live, audioLive: root.audioLive,
        showLive: root.showLive, history: root.history.length, summary: root.summary })
    }
  }

  // ---- reading -------------------------------------------------------------
  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return null }
  }

  function ingestStatus(o) {
    if (!o) return
    status = o
  }

  function ingestAudio(o) {
    if (!o || (audio && audio.t === o.t)) return
    audio = o
    if (o.quiet) return
    lastAudioT = o.t
    var sl = showLive
    history.push({ t: o.t, b: VM.clamp01(o.b), m: VM.clamp01(o.m), h: VM.clamp01(o.h), l: VM.clamp01(o.l),
      i: sl ? VM.clamp01(show.intensity) : -1, sec: sl ? show.section : "", pal: sl ? show.palette_rgb : null })
    var cut = o.t - historySpan - 3
    var k = 0
    while (k < history.length && history[k].t < cut) k++
    if (k > 0) history.splice(0, k)
  }

  function ingestShow(o) {
    if (!o || (show && show.seq === o.seq && show.t === o.t)) return
    var ev = o.events || []
    for (var i = 0; i < ev.length; i++) {
      var kind = String(ev[i]).split(" ")[0]
      if (kind === "glint" || kind === "pop" || kind === "blast") accents.push({ t: o.t, k: kind })
    }
    var cut = o.t - historySpan - 3
    var k = 0
    while (k < accents.length && accents[k].t < cut) k++
    if (k > 0) accents.splice(0, k)
    // The show's light order rarely changes: a cheap structural check, not
    // a stringify per frame.
    var nl = o.layout
    var sl = showLayout
    if (nl && (nl.length !== sl.length || (nl.length && (nl[0].name !== sl[0].name || nl[nl.length - 1].name !== sl[sl.length - 1].name))))
      showLayout = nl
    show = o
  }

  FileView {
    id: statusIn
    path: root.runDir + "/status.json"
    printErrors: false
    onLoaded: { root.statusFileOk = true; root.ingestStatus(root.parse(text())) }
    onLoadFailed: root.statusFileOk = false
  }
  FileView {
    id: audioIn
    path: root.runDir + "/audio.json"
    printErrors: false
    onLoaded: root.ingestAudio(root.parse(text()))
  }
  FileView {
    id: showIn
    path: root.runDir + "/show.json"
    printErrors: false
    onLoaded: root.ingestShow(root.parse(text()))
  }
  FileView {
    id: roomIn
    path: root.roomPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var r = root.parse(text())
      root.room = r && typeof r === "object" && !Array.isArray(r) ? r : null
    }
    onLoadFailed: root.room = null
  }
  // A file that appears later (the first pairing) isn't watched yet: look again.
  Timer { interval: 3000; repeat: true; running: !root.room; onTriggered: roomIn.reload() }

  // Status: a small file, re-read once a second (and soon after a control).
  // The widget's clock: once a second (the popup's own timer adds nothing
  // faster). Fast timers never touch it, so bindings don't churn at 25/s.
  Timer {
    interval: 1000; repeat: true; running: true
    onTriggered: { root.nowT = Date.now() / 1000; statusIn.reload() }
  }
  Timer { id: statusSoon; interval: 350; onTriggered: statusIn.reload() }

  // Audio + show only while there is something to read.
  Timer {
    interval: 66; repeat: true
    running: root.enabled && (root.heard || root.audioLive)
    onTriggered: audioIn.reload()
  }
  Timer {
    interval: 100; repeat: true
    running: root.enabled && root.hueOn && (String(root.status.hueState).indexOf("streaming") === 0 || root.showLive)
    onTriggered: showIn.reload()
  }

  // Before psywall writes status.json (an older service), ask it — slowly.
  Process {
    id: statusIpc
    command: ["omarchy-shell", "psywall", "status"]
    stdout: StdioCollector {
      onStreamFinished: {
        var o = root.parse(text)
        if (o && !root.statusFileOk) { o.t = Date.now() / 1000; root.status = o }
      }
    }
  }
  Timer {
    interval: 5000; repeat: true; triggeredOnStart: true
    running: !root.statusFileOk
    onTriggered: if (!statusIpc.running) statusIpc.running = true
  }

  // ---- controls --------------------------------------------------------------
  function ipc(args) {
    Quickshell.execDetached(["omarchy-shell", "psywall"].concat(args))
    statusSoon.restart()
  }
  function patchStatus(key, value) {
    if (!status) return
    var s = Object.assign({}, status)
    s[key] = value
    status = s
  }
  function setLights(on) { if (!!status.hue !== on) { patchStatus("hue", on); ipc(["toggleHue"]) } }
  function setWallpaper(on) { if (!!status.wallpaperEffect !== on) { patchStatus("wallpaperEffect", on); ipc(["toggleWallpaper"]) } }
  function setHueStrength(v) { v = Math.round(v * 20) / 20; patchStatus("hueStrength", v); ipc(["hueStrength", String(v)]) }
  function setStrength(v) { v = Math.round(v * 20) / 20; patchStatus("strength", v); ipc(["strength", String(v)]) }
  function setAggression(v) { v = Math.round(v * 20) / 20; patchStatus("hueAggression", v); ipc(["aggression", String(v)]) }
  function nudgeDelay(step) {
    if (!status || !status.output) return
    var d = Math.max(0, Math.min(5, Math.round((Number(status.delay || 0) + step) * 100) / 100))
    patchStatus("delay", d)
    ipc(["delay", d.toFixed(2)])
  }
  // Pause/resume everything: the audio capture, the wallpaper effect and the
  // lights (which are handed back). Paused, psywall costs nothing — the point
  // of the button while on battery.
  function setEnabled(on) { if (status && !!status.enabled !== on) { patchStatus("enabled", on); ipc(["toggle"]) } }
  function turnOn() { setEnabled(true) }

  // ---- Hue setup ---------------------------------------------------------------
  // Steps: "find" (bridges on the network, or an address) -> "link" (press
  // the bridge's button) -> "lights" (beat / glow / off per light, or an
  // existing entertainment area) -> saved, and the room map opens in arrange
  // mode. The streaming helper is held off meanwhile (lights handed back).
  property bool setupOpen: false
  property string setupStep: "find"
  property bool setupBusy: false
  property string setupError: ""
  property var bridges: []
  property bool searched: false
  property string pairAddr: ""
  property string pairName: ""
  property int pairLeft: 0
  property bool pairReachable: true
  property var inventory: null       // {lights, areas, room}
  property var choice: ({})          // light id -> "beat" | "dynamic" | "glow" | "off"
  property string chosenArea: ""     // an existing area to use as-is
  property bool arranging: false
  property string selectedLight: ""
  readonly property int maxBeat: 10

  // Which of the chosen lights would stream live: beat and dynamic ones
  // (an existing area's lights, if one was picked), then glow ones while
  // there's room; the bridge streams ten at most. The rest fade slowly.
  readonly property var liveSet: {
    var out = {}, n = 0
    var inv = inventory ? inventory.lights : []
    if (chosenArea && inventory) {
      var area = inventory.areas.filter(function(a) { return a.id === chosenArea })[0]
      if (area) for (var a = 0; a < area.lights.length; a++) if (choice[area.lights[a]] && choice[area.lights[a]] !== "off") out[area.lights[a]] = true
      return out
    }
    for (var i = 0; i < inv.length; i++) { var m = choice[inv[i].id]; if ((m === "beat" || m === "dynamic") && n < maxBeat) { out[inv[i].id] = true; n++ } }
    for (var j = 0; j < inv.length; j++) if (choice[inv[j].id] === "glow" && n < maxBeat) { out[inv[j].id] = true; n++ }
    return out
  }
  readonly property int onCount: { var n = 0; for (var k in choice) if (choice[k] !== "off") n++; return n }
  readonly property int liveCount: Object.keys(liveSet).length
  readonly property int rhythmCount: { var n = 0; for (var k in choice) if (choice[k] === "beat" || choice[k] === "dynamic") n++; return n }

  function openSetup() {
    pin(true)
    arranging = false
    setupOpen = true
    setupError = ""
    ipcQuiet(["hueHold"])
    if (paired) { setupStep = "lights"; loadInventory() }
    else { setupStep = "find"; discover() }
  }
  function closeSetup() {
    setupOpen = false
    setupBusy = false
    for (var i = 0; i < setupProcs.length; i++) setupProcs[i].running = false
    ipcQuiet(["hueResume"])
  }
  function setupRun(proc, args) {
    proc.running = false
    proc.command = [root.setupBin].concat(args)
    proc.running = true
  }
  function discover() {
    bridges = []; searched = false; setupError = ""; setupBusy = true
    setupRun(discoverProc, ["discover"])
  }
  function pairWith(addr, name) {
    addr = String(addr).trim()
    if (!addr) return
    pairAddr = addr; pairName = name || "Hue Bridge"; pairLeft = 120; pairReachable = true
    setupError = ""; setupStep = "link"; setupBusy = true
    setupRun(pairProc, ["pair", addr, "120"])
  }
  function loadInventory() {
    setupError = ""; setupBusy = true; inventory = null
    setupRun(invProc, ["inventory"])
  }
  function initChoice(inv) {
    var c = {}
    var r = inv.room && inv.room.lights ? inv.room.lights : []
    for (var i = 0; i < inv.lights.length; i++) if (inv.lights[i].color && inv.lights[i].ent) c[inv.lights[i].id] = "off"
    if (r.length) {
      for (var j = 0; j < r.length; j++) {
        if (c[r[j].id] === undefined) continue
        var live = r[j].live !== undefined ? !!r[j].live : r[j].mode !== "glow"
        c[r[j].id] = r[j].live !== undefined ? String(r[j].mode || "dynamic") : (live ? "dynamic" : "glow")
      }
    } else {
      // First time: ten lights on Dynamic, any others Glow.
      var n = 0
      for (var k in c) c[k] = n++ < maxBeat ? "dynamic" : "glow"
    }
    chosenArea = inv.room && inv.room.area && inv.room.area !== inv.room.ownArea ? String(inv.room.area) : ""
    choice = c
  }
  function setMode(id, mode) {
    var rhythm = mode === "beat" || mode === "dynamic"
    var was = choice[id]
    if (rhythm && was !== "beat" && was !== "dynamic" && rhythmCount >= maxBeat) {
      setupError = "Up to 10 lights can follow the beat (a Hue bridge streams 10 at once). Set another to Glow or Off first."
      return
    }
    setupError = ""
    // Leaving a picked area: a light outside it now follows the beat, or one
    // of its lights was switched off.
    if (chosenArea && inventory) {
      var area = inventory.areas.filter(function(a) { return a.id === chosenArea })[0]
      var inArea = area && area.lights.indexOf(id) >= 0
      if ((rhythm && !inArea) || (mode === "off" && inArea)) chosenArea = ""
    }
    var c = Object.assign({}, choice)
    c[id] = mode
    choice = c
  }
  function useArea(area) {
    if (chosenArea === area.id) { chosenArea = ""; return }
    var c = Object.assign({}, choice)
    // Its lights join (keeping a mode already chosen); lights outside it can
    // only glow, since a bridge streams one area at a time.
    for (var k in c) if ((c[k] === "beat" || c[k] === "dynamic") && area.lights.indexOf(k) < 0) c[k] = "glow"
    for (var i = 0; i < area.lights.length; i++) if (c[area.lights[i]] !== undefined && c[area.lights[i]] === "off") c[area.lights[i]] = "dynamic"
    chosenArea = area.id
    choice = c
    setupError = ""
  }
  function saveLights() {
    var modes = {}
    for (var k in choice) if (choice[k] !== "off") modes[k] = choice[k]
    if (!Object.keys(modes).length) { setupError = "Turn on at least one light."; return }
    setupError = ""; setupBusy = true; setupStep = "saving"
    setupRun(applyProc, ["apply", JSON.stringify({ modes: modes, area: chosenArea })])
  }
  function forgetBridge() {
    setupBusy = true
    setupRun(forgetProc, ["forget"])
  }
  // Arrange: click = blink that light in the room, drag = put it where it is.
  function identifyLight(id) {
    selectedLight = id
    if (showLive) ipcQuiet(["hueIdentify", id])
    else Quickshell.execDetached([root.setupBin, "identify", id])
  }
  function moveLight(id, x, y) {
    var r = Object.assign({}, room)
    r.lights = (room.lights || []).map(function(l) { return l.id === id ? Object.assign({}, l, { x: x, y: y }) : l })
    room = r   // at once; the file catches up a moment later
    moveQueue.push([id, x.toFixed(3), y.toFixed(3)])
    if (!moveProc.running) nextMove()
  }
  property var moveQueue: []
  function nextMove() {
    if (!moveQueue.length) { ipcQuiet(["hueLayout"]); return }
    var m = moveQueue.shift()
    setupRun(moveProc, ["move"].concat(m))
  }
  function ipcQuiet(args) { Quickshell.execDetached(["omarchy-shell", "psywall"].concat(args)); statusSoon.restart() }
  function installMissing() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      "omarchy-pkg-add " + String(status.missing).replace(/[^a-z0-9.+_-]/g, "") + " && omarchy-shell psywall retry"])
  }

  function parseEvents(text, fn) {
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (!lines[i]) continue
      var o = parse(lines[i])
      if (o && o.event) fn(o)
    }
  }
  readonly property var setupProcs: [discoverProc, pairProc, invProc, applyProc, forgetProc]

  Process {
    id: discoverProc
    stdout: SplitParser {
      onRead: function(line) {
        var o = root.parse(line)
        if (!o) return
        if (o.event === "bridge") root.bridges = root.bridges.concat([o])
        else if (o.event === "done") { root.searched = true; root.setupBusy = false }
      }
    }
    onExited: { root.searched = true; root.setupBusy = false }
  }
  Process {
    id: pairProc
    stdout: SplitParser {
      onRead: function(line) {
        var o = root.parse(line)
        if (!o) return
        if (o.event === "waiting") { root.pairLeft = o.left; root.pairReachable = o.reachable !== false }
        else if (o.event === "paired") { root.pairName = o.name; root.setupStep = "lights"; root.loadInventory() }
        else if (o.event === "timeout") { root.setupBusy = false; root.pairLeft = 0 }
        else if (o.event === "error") { root.setupBusy = false; root.setupError = o.message; root.setupStep = "find" }
      }
    }
  }
  Process {
    id: invProc
    stdout: StdioCollector {
      onStreamFinished: root.parseEvents(text, function(o) {
        root.setupBusy = false
        if (o.event === "inventory") { root.initChoice(o); root.inventory = o }
        else if (o.event === "error") {
          root.setupError = o.message
          if (o.code === "unpaired" || o.code === "pin") root.setupStep = "find"
        }
      })
    }
  }
  Process {
    id: applyProc
    stdout: StdioCollector {
      onStreamFinished: root.parseEvents(text, function(o) {
        root.setupBusy = false
        if (o.event === "applied") {
          roomIn.reload()
          root.closeSetup()
          root.arranging = true
        } else if (o.event === "error") { root.setupError = o.message; root.setupStep = "lights" }
      })
    }
  }
  Process {
    id: forgetProc
    stdout: StdioCollector {
      onStreamFinished: root.parseEvents(text, function(o) {
        root.setupBusy = false
        if (o.event === "forgotten") { root.room = null; root.inventory = null; root.setupStep = "find"; root.discover() }
      })
    }
  }
  Process {
    id: moveProc
    onExited: root.nextMove()
  }

  // ---- per-light helpers -----------------------------------------------------
  function lightAt(i) {
    var j = i < showIndex.length ? showIndex[i] : -1
    return showLive && show.lights && j >= 0 && j < show.lights.length ? VM.light(show.lights[j]) : null
  }
  function driverAt(i) {
    var j = i < showIndex.length ? showIndex[i] : -1
    return showLive && show.drivers && j >= 0 && j < show.drivers.length ? String(show.drivers[j]) : "drift"
  }
  // With the lights off but music playing, the dots follow the audio: each
  // light on its own band, so they never move as one.
  function audioGlow(i) {
    if (!audioLive) return 0
    var band = [audio.b, audio.m, audio.h][i % 3]
    return VM.clamp01(band) * (0.55 + 0.45 * ((i * 7) % 5) / 4)
  }

  // ======================================================================
  // bar
  // ======================================================================
  readonly property int barThickness: bar ? bar.barSize : Style.bar.sizeHorizontal
  readonly property bool verticalBar: bar ? bar.vertical : false
  // The bar miniature is the paired room as a two-row strip: one dot per
  // light, the top half of the room map on top, the bottom half below, each row
  // in room order (x); glow lights are rings. A literal x/y map is a blob at
  // this size. Nothing paired: a bulb glyph instead.
  readonly property int miniDot: Math.max(3, Math.round(barThickness * 0.13))
  readonly property int miniSlot: miniDot + 2
  readonly property var miniSlots: {
    var front = [], back = [], side = []
    for (var i = 0; i < layout.length; i++) {
      if (Number(layout[i].y) > 0) front.push(i)
      else back.push(i)
    }
    // Rows no more than ~2:1 out of balance, so the strip stays compact.
    var L = layout
    var byY = function(a, b) { return Number(L[a].y) - Number(L[b].y) }
    while (front.length > back.length * 2 + 1) { front.sort(byY); back.push(front.shift()) }
    while (back.length > front.length * 2 + 1) { back.sort(byY); front.push(back.pop()) }
    var byX = function(a, b) { return Number(L[a].x) - Number(L[b].x) }
    front.sort(byX); back.sort(byX)
    var gap = 0
    var w0 = front.length * miniSlot - 2
    var w1 = (back.length + side.length) * miniSlot - 2 + gap
    var W = Math.max(w0, w1, miniSlot)
    var pos = []
    for (var k = 0; k < front.length; k++) pos[front[k]] = { x: Math.round((W - w0) / 2) + k * miniSlot, y: 0 }
    for (var j = 0; j < back.length; j++) pos[back[j]] = { x: Math.round((W - w1) / 2) + j * miniSlot, y: miniDot + 3 }
    for (var s = 0; s < side.length; s++) pos[side[s]] = { x: Math.round((W - w1) / 2) + (back.length + s) * miniSlot + gap, y: miniDot + 3 }
    return { pos: pos, w: W }
  }
  readonly property int miniH: miniDot * 2 + 3
  readonly property int miniW: layout.length ? Math.round(miniSlots.w) : Math.round(barThickness * 0.5)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.verticalBar ? -1 : root.miniW + Style.space(12)
    fixedHeight: root.verticalBar ? root.miniW + Style.space(12) : -1
    tooltipText: ""   // the hover preview replaces the tooltip
    onPressed: function(b) { root.clickWidget() }

    Item {
      id: mini
      anchors.centerIn: parent
      width: root.miniW
      height: root.miniH
      rotation: root.verticalBar ? -90 : 0

      readonly property real dot: Math.max(3, Math.round(root.miniH * 0.26))

      Text {
        textFormat: Text.PlainText
        visible: root.layout.length === 0
        anchors.centerIn: parent
        rotation: root.verticalBar ? 90 : 0
        text: "󰛨"
        color: root.barForeground
        opacity: root.enabled ? 0.75 : 0.4
        font.family: root.fontFamily
        font.pixelSize: Math.round(root.barThickness * 0.48)
      }

      Repeater {
        model: root.layout
        delegate: Item {
          id: md
          required property var modelData
          required property int index
          readonly property bool fast: modelData.fast !== false
          readonly property var lt: root.lightAt(index)
          readonly property real glow: lt ? lt.v : root.audioGlow(index)
          readonly property color tint: lt && lt.v > 0 ? Qt.rgba(lt.r, lt.g, lt.b, 1) : root.barForeground
          readonly property var p: root.miniSlots.pos[index] || ({ x: 0, y: 0 })
          x: p.x
          y: p.y
          width: root.miniDot
          height: root.miniDot

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: md.fast ? md.tint : "transparent"
            border.width: md.fast ? 0 : 1
            border.color: md.tint
            opacity: root.live ? 0.3 + 0.7 * Math.pow(md.glow, 0.6) : (root.enabled ? 0.34 : 0.2)
          }
        }
      }

      // pinned marker: a hairline under the room strip, like a pinned bar popup
      Rectangle {
        visible: root.pinned
        anchors.top: parent.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter
        width: parent.width
        height: 1
        color: root.barForeground
        opacity: 0.5
      }
    }
  }

  // ======================================================================
  // popup
  // ======================================================================
  readonly property bool popupShown: popup.visible
  readonly property real screenH: popup.screenH > 0 ? popup.screenH : 900

  // Clock for the popup's relative times, only while it is open.
  Timer {
    interval: 1000; repeat: true; running: root.popupShown
    onTriggered: root.rebuildMoments()
  }
  onPopupVisibleChanged: if (popupVisible) { nowT = Date.now() / 1000; rebuildMoments() }

  property var momentRows: []
  function rebuildMoments() {
    var src = show && show.moments ? show.moments : []
    // One row per happening: a palette change rides on the section change or
    // release it came with, and a release absorbs its own section change.
    var rows = []
    for (var i = 0; i < src.length; i++) {
      var info = VM.eventInfo(src[i].e)
      if (info.weight < 1) continue
      var last = rows.length ? rows[rows.length - 1] : null
      var near = last && Math.abs(src[i].t - last.t) < 0.6
      if (near && info.kind === "palette" && (last.kind === "section" || last.kind === "RELEASE")) {
        last.label += " · " + info.label
        continue
      }
      if (near && info.kind === "RELEASE" && last.kind === "section") {
        var cut = last.label.indexOf(" · ")
        rows[rows.length - 1] = { kind: info.kind, label: info.label + (cut >= 0 ? last.label.substring(cut) : ""), weight: info.weight, t: src[i].t }
        continue
      }
      rows.push({ kind: info.kind, label: info.label, weight: info.weight, t: src[i].t })
    }
    var now = nowT
    momentRows = rows.slice(-7).reverse().map(function(r) { return { label: r.label, weight: r.weight, ago: VM.ago(now - r.t) } })
  }
  readonly property real sectionSince: {
    var src = show && show.moments ? show.moments : []
    for (var i = src.length - 1; i >= 0; i--) {
      var e = String(src[i].e)
      if (e.indexOf("section ") === 0 || e.indexOf("RELEASE") === 0) return src[i].t
    }
    return 0
  }

  // A card-sized layer surface under the widget, placed like the shell's
  // KeyboardPanel (as in a spectrum widget): hover previews it, a click pins it, and
  // there's no focus grab, so a pinned card survives clicks in other windows.
  PanelWindow {
    id: popup

    readonly property var anchorWindow: button.QsWindow.window
    readonly property string barPos: root.bar ? root.bar.position : "top"
    readonly property int gap: Style.gapsOut
    readonly property int margin: Style.gapsOut
    readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    readonly property real screenW: screen ? screen.width : 0
    readonly property real screenH: screen ? screen.height : 0
    readonly property real barW: anchorWindow ? anchorWindow.width : screenW
    readonly property real barH: anchorWindow ? anchorWindow.height : 0
    readonly property bool containsMouse: cardHover.hovered
    property bool focusPrimed: false

    readonly property real insetsX: card.contentLeftInset + card.contentRightInset
    readonly property real insetsY: card.contentTopInset + card.contentBottomInset
    readonly property int cardW: Math.round(Math.min(Style.space(620) + insetsX, screenW > 0 ? screenW - 2 * margin : 100000))
    readonly property int cardH: Math.round(Math.min((popupLoader.item ? popupLoader.item.implicitHeight : Style.space(780)) + insetsY,
                                                     screenH > 0 ? screenH - barH - 2 * margin : 100000))

    TransformWatcher {
      id: anchorWatcher
      a: popup.anchorWindow ? popup.anchorWindow.contentItem : null
      b: button
    }

    readonly property point anchorPos: {
      anchorWatcher.transform  // reactive dependency
      if (!popup.anchorWindow) return Qt.point(0, 0)
      return button.mapToItem(popup.anchorWindow.contentItem, 0, 0)
    }

    // Same placement rules as the shell's KeyboardPanel.
    readonly property point origin: {
      var x = 0, y = 0
      if (barPos === "bottom") {
        x = anchorPos.x + button.width / 2 - cardW / 2
        y = screenH - barH - cardH - gap
      } else if (barPos === "left") {
        x = barW + gap
        y = anchorPos.y + button.height / 2 - cardH / 2
      } else if (barPos === "right") {
        x = screenW - barW - cardW - gap
        y = anchorPos.y + button.height / 2 - cardH / 2
      } else {
        x = anchorPos.x + button.width / 2 - cardW / 2
        y = barH + gap
      }
      x = Math.max(margin, Math.min(x, screenW - cardW - margin))
      y = Math.max(margin, Math.min(y, screenH - cardH - margin))
      return Qt.point(Math.round(x), Math.round(y))
    }

    screen: anchorWindow ? anchorWindow.screen : null
    visible: root.popupVisible || card.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: cardW
    implicitHeight: cardH
    anchors {
      top: true
      left: true
    }
    margins {
      top: origin.y
      left: origin.x
    }

    WlrLayershell.namespace: "psywall-view"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: !root.pinned ? WlrKeyboardFocus.None
      : (focusPrimed ? WlrKeyboardFocus.OnDemand
        : (root.focusOnPin ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None))

    BorderSurface {
      id: card
      anchors.fill: parent
      color: Color.popups.background
      borderSpec: popup.borderSpec
      padding: Style.spacing.popupPadding
      radius: Style.cornerRadius
      opacity: root.popupVisible ? 1.0 : 0

      Behavior on opacity {
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }

      HoverHandler { id: cardHover }

      // A click on the card itself (not on one of its controls) pins a preview.
      TapHandler {
        enabled: !root.pinned
        onTapped: root.pin(true)
      }

      Item {
        id: keyItem
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) { root.close("escape"); event.accepted = true }
        }
      }

      Item {
        id: contentHolder
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // The popup's content only exists while it is on screen: closed, none of
        // its bindings (two light Repeaters, meters, the soundscape) re-evaluate
        // on the 10/s show updates.
        Loader {
          id: popupLoader
          width: parent.width
          active: popup.visible
          sourceComponent: root.setupOpen ? setupPage : mainPage
          Component {
            id: setupPage
            HueSetup { width: popupLoader.width; view: root }
          }
          Component {
            id: mainPage
        Column {
          id: panelColumn
          width: parent.width
          spacing: Style.space(14)

          // ---- header ------------------------------------------------------------
          Item {
            width: parent.width
            implicitHeight: Math.max(titleCol.implicitHeight, closeBtn.height)

            Column {
              id: titleCol
              anchors.left: parent.left
              anchors.right: closeBtn.left
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(3)

              Row {
                spacing: Style.space(10)
                Text {
                  textFormat: Text.PlainText
                  id: titleText
                  text: "Psywall"
                  color: root.popupText
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.baseline: titleText.baseline
                  text: !root.enabled ? "OFF"
                    : root.statusStale ? "NOT RESPONDING"
                    : root.showLive ? String(root.show.section || "warming up").toUpperCase()
                    : root.audioLive ? (root.source === "mic" ? "LISTENING" : "MUSIC")
                    : "SILENT"
                  color: root.showLive ? root.palette[0] : root.popupDim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.4
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.baseline: titleText.baseline
                  text: root.pinned ? "󰐃 PINNED" : "CLICK TO PIN"
                  color: root.popupDim
                  opacity: root.pinned ? 0.9 : 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1.2
                }
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: !root.status ? "" : !root.status.enabled ? "capture, wallpaper and lights are all off"
                  : (root.hueOn ? "lights " + String(root.status.hueState || "") : "lights off")
                    + " · wallpaper " + (root.status.wallpaperEffect === false ? "off" : "on")
                color: root.popupDim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Rectangle {
              id: closeBtn
              anchors.right: parent.right
              anchors.top: parent.top
              opacity: root.pinned ? 1 : 0.45
              width: Style.space(24)
              height: Style.space(24)
              radius: Style.cornerRadius
              color: closeArea.containsMouse ? Style.hoverFill : "transparent"
              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "󰅖"
                color: root.popupText
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }
              MouseArea {
                id: closeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.close("× button")
              }
            }
          }

          // ---- a package psywall needs ---------------------------------------
          Rectangle {
            visible: !!(root.status && root.status.missing)
            width: parent.width
            implicitHeight: missRow.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Util.alpha(Color.accent, 0.12)
            border.width: 1
            border.color: Util.alpha(Color.accent, 0.45)
            Item {
              id: missRow
              anchors.fill: parent
              anchors.margins: Style.space(8)
              implicitHeight: Math.max(missText.implicitHeight, missBtn.implicitHeight)
              Text {
                id: missText
                anchors.left: parent.left
                anchors.right: missBtn.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "Psywall listens through " + String(root.status ? root.status.missing : "") + ", which isn't installed yet. Install it (asks for your password in a terminal) and the wallpaper and lights start."
                color: root.popupText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Button {
                id: missBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Install"
                fontFamily: root.fontFamily
                foreground: root.popupText
                bordered: true
                onClicked: root.installMissing()
              }
            }
          }

          // ---- room + now ------------------------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(18)

            Column {
              id: roomCol
              // Arranging: the whole card is the room, so places are precise.
              width: root.arranging ? parent.width : Math.round((parent.width - parent.spacing) * 0.5)
              spacing: Style.space(6)

              Item {
                width: parent.width
                height: Math.max(roomLabel.implicitHeight, arrangeBtn.implicitHeight)
                SectionLabel {
                  id: roomLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.arranging ? "ROOM · ARRANGING" : (root.paired ? "ROOM · " + root.layout.length + (root.layout.length === 1 ? " LIGHT" : " LIGHTS") : "ROOM")
                  fg: root.popupText; family: root.fontFamily
                }
                Button {
                  id: arrangeBtn
                  visible: root.paired && root.roomComplete
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.arranging ? "Done" : "Arrange"
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  foreground: root.popupText
                  bordered: true
                  selected: root.arranging
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(1)
                  tooltipText: root.arranging ? "Keep these places" : "Place each light where it stands in your room"
                  onClicked: { root.arranging = !root.arranging; root.selectedLight = "" }
                }
              }

              Item {
                id: room
                width: parent.width
                height: Math.round(width * (root.arranging ? 0.52 : 0.66))
                readonly property real pad: Style.space(18)
                // Room coordinates are the Hue entertainment ones, -1..1 on
                // both axes. Nothing but the lights is drawn: the room is
                // whatever the user makes of it.
                function px(x) { return pad + VM.clamp01((Number(x) + 1) / 2) * (width - 2 * pad) }
                function py(y) { return pad + VM.clamp01((1 - Number(y)) / 2) * (height - 2 * pad) }
                function rx(X) { return Math.max(-1, Math.min(1, (X - pad) / Math.max(1, width - 2 * pad) * 2 - 1)) }
                function ry(Y) { return Math.max(-1, Math.min(1, 1 - (Y - pad) / Math.max(1, height - 2 * pad) * 2)) }
                property int hovered: -1

                Rectangle {
                  anchors.fill: parent
                  radius: Math.max(Style.cornerRadius, Style.space(6))
                  color: Util.alpha(root.popupText, root.arranging ? 0.045 : 0.025)
                  border.width: 1
                  border.color: Util.alpha(root.popupText, root.arranging ? 0.22 : 0.08)
                }
                // Glow: big soft discs, blurred on the GPU. Only while the
                // popup is open (the whole window is unmapped otherwise).
                Item {
                  id: glowSrc
                  anchors.fill: parent
                  visible: false
                  layer.enabled: root.popupShown
                  Repeater {
                    model: root.layout
                    delegate: Rectangle {
                      required property var modelData
                      required property int index
                      readonly property var lt: root.lightAt(index)
                      readonly property real sz: (modelData.fast !== false ? 30 : 24) * (0.6 + 0.8 * (lt ? lt.v : 0))
                      x: room.px(modelData.x) - sz / 2
                      y: room.py(modelData.y) - sz / 2
                      width: sz
                      height: sz
                      radius: sz / 2
                      color: lt && lt.v > 0 ? Qt.rgba(lt.r, lt.g, lt.b, 1) : "transparent"
                      opacity: lt ? Math.min(1, 0.25 + lt.v * 1.1) : 0
                    }
                  }
                }
                MultiEffect {
                  anchors.fill: glowSrc
                  source: glowSrc
                  visible: root.showLive
                  blurEnabled: true
                  blur: 1.0
                  blurMax: 40
                  autoPaddingEnabled: false
                  saturation: 0.15
                }

                // Cores: drag them while arranging; a click blinks the light.
                Repeater {
                  model: root.layout
                  delegate: Item {
                    id: core
                    required property var modelData
                    required property int index
                    readonly property bool fast: modelData.fast !== false
                    readonly property var lt: root.lightAt(index)
                    readonly property string drv: root.driverAt(index)
                    readonly property color tint: lt && lt.v > 0 ? Qt.rgba(lt.r, lt.g, lt.b, 1) : root.popupText
                    readonly property real d: fast ? Style.space(9) : Style.space(10)
                    readonly property bool selected: root.arranging && root.selectedLight === modelData.id
                    property bool dragging: false
                    property real dragX: 0
                    property real dragY: 0
                    x: (dragging ? dragX : room.px(modelData.x)) - width / 2
                    y: (dragging ? dragY : room.py(modelData.y)) - height / 2
                    z: dragging ? 5 : 1
                    width: Style.space(26)
                    height: Style.space(26)

                    // a driver ring: this light is taking its turn following
                    // the tempo or one part of the spectrum
                    Rectangle {
                      visible: (core.drv !== "drift" && root.showLive) || core.selected
                      anchors.centerIn: parent
                      width: core.d + Style.space(core.selected ? 12 : 8)
                      height: width
                      radius: width / 2
                      color: "transparent"
                      border.width: core.selected ? 2 : 1
                      border.color: core.selected ? Color.accent : Util.alpha(root.popupText, 0.55)
                    }
                    Rectangle {
                      anchors.centerIn: parent
                      width: core.d
                      height: core.d
                      radius: width / 2
                      color: core.fast ? core.tint : "transparent"
                      border.width: core.fast ? 0 : Math.max(1.5, Style.space(2))
                      border.color: core.tint
                      opacity: core.lt ? 0.35 + 0.65 * Math.pow(core.lt.v, 0.5) : (root.arranging ? 0.85 : 0.4)
                    }
                    Text {
                      visible: root.arranging ? (core.selected || core.dragging || room.hovered === core.index)
                                              : (core.drv !== "drift" && root.showLive)
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.top: parent.bottom
                      anchors.topMargin: -Style.space(3)
                      textFormat: Text.PlainText
                      text: root.arranging ? core.modelData.name : VM.driverShort(core.drv)
                      color: core.selected ? root.popupText : root.popupDim
                      font.family: root.fontFamily
                      font.pixelSize: root.arranging ? Style.font.caption : Math.max(8, Style.font.caption - 2)
                      font.bold: root.arranging
                    }
                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: root.arranging ? (core.dragging ? Qt.ClosedHandCursor : Qt.OpenHandCursor) : Qt.ArrowCursor
                      preventStealing: true
                      property point start
                      property bool moved: false
                      onContainsMouseChanged: room.hovered = containsMouse ? core.index : (room.hovered === core.index ? -1 : room.hovered)
                      onPressed: function(m) {
                        if (!root.arranging) return
                        start = Qt.point(m.x, m.y); moved = false
                        core.dragX = room.px(core.modelData.x); core.dragY = room.py(core.modelData.y)
                      }
                      onPositionChanged: function(m) {
                        if (!root.arranging || !pressed) return
                        if (!moved && Math.abs(m.x - start.x) + Math.abs(m.y - start.y) < 4) return
                        moved = true
                        core.dragging = true
                        var p = mapToItem(room, m.x, m.y)
                        core.dragX = Math.max(room.pad, Math.min(room.width - room.pad, p.x))
                        core.dragY = Math.max(room.pad, Math.min(room.height - room.pad, p.y))
                      }
                      onReleased: {
                        if (!root.arranging) return
                        if (moved) root.moveLight(core.modelData.id, room.rx(core.dragX), room.ry(core.dragY))
                        else root.identifyLight(core.modelData.id)
                        core.dragging = false
                      }
                      onClicked: if (!root.arranging && root.paired && root.roomComplete) { root.arranging = true; root.identifyLight(core.modelData.id) }
                    }
                  }
                }

                // hover label
                Rectangle {
                  id: tip
                  readonly property var entry: !root.arranging && room.hovered >= 0 && room.hovered < root.layout.length ? root.layout[room.hovered] : null
                  visible: entry !== null
                  color: Color.tooltip.background
                  border.width: 1
                  border.color: Util.alpha(Color.tooltip.text, 0.25)
                  radius: Style.cornerRadius
                  width: Math.min(room.width, tipText.implicitWidth + Style.space(14))
                  height: tipText.implicitHeight + Style.space(8)
                  x: entry ? Math.max(0, Math.min(room.width - width, room.px(entry.x) - width / 2)) : 0
                  y: entry ? (room.py(entry.y) > room.height / 2 ? room.py(entry.y) - height - Style.space(14) : room.py(entry.y) + Style.space(14)) : 0
                  z: 10
                  Text {
                    id: tipText
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, room.width - Style.space(14))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: tip.entry ? (tip.entry.name || "Light") + " · " + (tip.entry.fast === false ? "glow, slow fades (a bridge streams 10 at most)"
                      : tip.entry.mode === "glow" ? "glow" : tip.entry.mode === "beat" ? "beat · takes the rhythm" : VM.driverText(root.driverAt(room.hovered))) : ""
                    color: Color.tooltip.text
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Column {
                  anchors.centerIn: parent
                  visible: !root.showLive && !root.arranging
                  spacing: Style.space(8)
                  Text {
                    textFormat: Text.PlainText
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: !root.paired ? "no Hue lights connected" : !root.enabled ? "psywall is off" : (!root.hueOn ? "lights are off" : "lights resting")
                    color: root.popupFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1.2
                  }
                  Button {
                    visible: !root.paired
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Connect Hue lights"
                    iconText: "󰛨"
                    fontFamily: root.fontFamily
                    foreground: root.popupText
                    bordered: true
                    onClicked: root.openSetup()
                  }
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.arranging
                  ? "Click a light: it blinks in your room. Drag it to where it stands."
                  : "● streamed live   ○ slow fades   ◌ taking a turn"
                color: root.arranging ? root.popupDim : root.popupFaint
                font.family: root.fontFamily
                font.pixelSize: Math.max(8, Style.font.caption - 1)
              }
            }

            // ---- now -----------------------------------------------------------
            Column {
              visible: !root.arranging
              width: parent.width - roomCol.width - parent.spacing
              spacing: Style.space(9)

              SectionLabel { text: "NOW"; fg: root.popupText; family: root.fontFamily }

              Column {
                spacing: Style.space(1)
                width: parent.width
                Row {
                  spacing: Style.space(8)
                  Text {
                    textFormat: Text.PlainText
                    id: secText
                    text: root.showLive ? VM.cap(root.show.section || "warming up") : (root.audioLive ? "Listening" : "Quiet")
                    color: root.popupText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.baseline: secText.baseline
                    visible: root.showLive && root.sectionSince > 0
                    text: "for " + VM.duration(root.nowT - root.sectionSince)
                    color: root.popupDim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.showLive ? VM.sectionBlurb(root.show.section) : (root.hueOn ? "the lights start with the music" : "lights are switched off")
                  color: root.popupDim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Meter { label: "Intensity"; value: root.showLive ? root.show.intensity : 0; tint: root.palette[0]; valueText: Math.round(value * 100) + "%"; fg: root.popupText; family: root.fontFamily; width: parent.width }
              Meter { label: "Tension"; value: root.showLive ? root.show.tension : 0; tint: root.palette[1]; valueText: value > 0.5 ? "building" : Math.round(value * 100) + "%"; fg: root.popupText; family: root.fontFamily; width: parent.width }
              Meter {
                readonly property real heat: root.showLive ? VM.clamp01(root.show.heat) : 0
                label: "Budget"
                value: 1 - heat
                tint: root.palette[2]
                valueText: !root.showLive ? "—" : heat > 0.75 ? "spent" : heat > 0.3 ? "recovering" : "ready"
                fg: root.popupText; family: root.fontFamily; width: parent.width
              }

              InfoRow {
                label: "Tempo"
                fg: root.popupText; family: root.fontFamily; width: parent.width
                value: root.showLive ? root.show.bpm + " bpm" : "—"
                detail: !root.showLive ? "" : (Number(root.show.conf) < 0.2 ? "searching" : "lock " + Math.round(VM.clamp01(root.show.conf) * 100) + "%")
              }

              Item {
                width: parent.width
                height: Math.max(palLabel.implicitHeight, swatches.height)
                Text {
                  textFormat: Text.PlainText
                  id: palLabel
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(70)
                  text: "Palette"
                  color: root.popupDim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Row {
                  id: swatches
                  anchors.left: palLabel.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)
                  Repeater {
                    model: 3
                    delegate: Rectangle {
                      required property int index
                      width: Style.space(12)
                      height: width
                      radius: width / 2
                      color: root.palette[index]
                      opacity: root.showLive ? 1 : 0.25
                      border.width: index === 2 ? 1 : 0
                      border.color: Util.alpha(root.popupText, 0.5)
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    leftPadding: Style.space(4)
                    text: root.showLive ? String(root.show.palette || "") : ""
                    color: root.popupText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }

              InfoRow {
                label: "Beat"
                fg: root.popupText; family: root.fontFamily; width: parent.width
                value: root.showLive ? String(root.show.style || "") : "—"
                detail: root.showLive ? VM.styleBlurb(root.show.style) : ""
              }
            }
          }

          // ---- soundscape --------------------------------------------------------
          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              height: scLabel.implicitHeight
              SectionLabel { id: scLabel; text: "SOUNDSCAPE · LAST 30 S"; fg: root.popupText; family: root.fontFamily }
              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.baseline: scLabel.baseline
                text: "bass · mids · highs  —  intensity"
                color: root.popupFaint
                font.family: root.fontFamily
                font.pixelSize: Math.max(8, Style.font.caption - 1)
              }
            }

            Item {
              id: sound
              width: parent.width
              height: Style.space(118)
              clip: true
              readonly property real pps: width / root.historySpan
              readonly property real extra: Math.ceil(pps * 0.8)
              property real paintT: 0     // time at the canvas's right edge, as last painted
              property real pendingT: 0
              readonly property bool running: root.popupShown && root.live

              Rectangle {
                anchors.fill: parent
                radius: Math.max(Style.cornerRadius, Style.space(6))
                color: Util.alpha(root.popupText, 0.025)
              }

              Canvas {
                id: scape
                y: 0
                width: sound.width + sound.extra
                height: sound.height
                renderStrategy: Canvas.Cooperative
                // right edge sits at `paintT`, then slides left until the next paint
                x: sound.width - width

                onPaint: root.paintScape(getContext("2d"), width, height, sound.pendingT, sound.pps)
                onPainted: { sound.paintT = sound.pendingT; x = sound.width - width }
              }

              // Scroll between paints on the GPU; repaint 4x a second.
              FrameAnimation {
                running: sound.running
                onTriggered: {
                  var now = Date.now() / 1000
                  if (now - sound.pendingT > 0.25 || sound.pendingT === 0) {
                    sound.pendingT = now
                    scape.requestPaint()
                  } else {
                    scape.x = sound.width - scape.width - (now - sound.paintT) * sound.pps
                  }
                }
              }
              Connections {
                target: root
                function onPopupShownChanged() { if (root.popupShown) { sound.pendingT = Date.now() / 1000; scape.requestPaint() } }
              }

              // soft edges: the past fades in, "now" fades out the repaint seam
              Rectangle {
                anchors.left: parent.left
                width: Style.space(28); height: parent.height
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: Color.popups.background }
                  GradientStop { position: 1; color: Util.alpha(Color.popups.background, 0) }
                }
              }
              Rectangle {
                anchors.right: parent.right
                width: Style.space(22); height: parent.height
                gradient: Gradient {
                  orientation: Gradient.Horizontal
                  GradientStop { position: 0; color: Util.alpha(Color.popups.background, 0) }
                  GradientStop { position: 1; color: Color.popups.background }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: root.lastAudioT === 0 || (root.nowT - root.lastAudioT) > 30
                text: !root.enabled ? "psywall is off" : "silent · the soundscape draws while music plays"
                color: root.popupFaint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1.1
              }
            }

            Item {
              width: parent.width
              height: axisL.implicitHeight
              Text { textFormat: Text.PlainText; id: axisL; text: "−30 s"; color: root.popupFaint; font.family: root.fontFamily; font.pixelSize: Math.max(8, Style.font.caption - 1) }
              Text { textFormat: Text.PlainText; anchors.horizontalCenter: parent.horizontalCenter; text: "−15 s"; color: root.popupFaint; font.family: root.fontFamily; font.pixelSize: Math.max(8, Style.font.caption - 1) }
              Text { textFormat: Text.PlainText; anchors.right: parent.right; text: "now"; color: root.popupFaint; font.family: root.fontFamily; font.pixelSize: Math.max(8, Style.font.caption - 1) }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.popupText; strength: 0.08 }

          // ---- moments | output + controls --------------------------------------
          Row {
            width: parent.width
            spacing: Style.space(18)

            Column {
              id: momentsCol
              width: Math.round((parent.width - parent.spacing) * 0.5)
              spacing: Style.space(6)

              SectionLabel { text: "RECENT MOMENTS"; fg: root.popupText; family: root.fontFamily }

              Repeater {
                model: root.momentRows
                delegate: Item {
                  required property var modelData
                  width: momentsCol.width
                  height: Math.max(mLabel.implicitHeight, Style.space(20))
                  readonly property bool big: modelData.weight >= 3
                  Rectangle {
                    id: mDot
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.big ? Style.space(7) : Style.space(5)
                    height: width
                    radius: width / 2
                    x: parent.big ? 0 : Style.space(1)
                    color: parent.big ? root.palette[2] : "transparent"
                    border.width: parent.big ? 0 : 1
                    border.color: root.popupDim
                  }
                  Text {
                    id: mLabel
                    anchors.left: mDot.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: mAgo.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: parent.modelData.label
                    color: parent.big ? root.popupText : root.popupDim
                    font.family: root.fontFamily
                    font.pixelSize: parent.big ? Style.font.bodySmall : Style.font.caption
                    font.bold: parent.big
                    font.letterSpacing: parent.big ? 0.6 : 0
                  }
                  Text {
                    textFormat: Text.PlainText
                    id: mAgo
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: parent.modelData.ago
                    color: root.popupFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
              Text {
                textFormat: Text.PlainText
                visible: root.momentRows.length === 0
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Nothing big yet. Hits, releases and bursts are rationed by the heat budget."
                color: root.popupFaint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Column {
              id: ctlCol
              width: parent.width - momentsCol.width - parent.spacing
              spacing: Style.space(8)

              SectionLabel { text: "OUTPUT"; fg: root.popupText; family: root.fontFamily }

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.status ? VM.prettyOutput(root.status.output) : "—"
                color: root.popupText
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Item {
                width: parent.width
                height: delayRow.height
                Text {
                  textFormat: Text.PlainText
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Delay"
                  color: root.popupDim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Row {
                  id: delayRow
                  anchors.right: parent.right
                  spacing: Style.space(4)
                  Button {
                    text: "−"
                    fontFamily: root.fontFamily
                    foreground: root.popupText
                    bordered: true
                    horizontalPadding: Style.space(9)
                    verticalPadding: Style.space(2)
                    enabled: !!(root.status && root.status.output)
                    opacity: enabled ? 1 : 0.4
                    tooltipText: "0.05 s earlier"
                    onClicked: root.nudgeDelay(-0.05)
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(58)
                    horizontalAlignment: Text.AlignHCenter
                    text: root.status ? Number(root.status.delay || 0).toFixed(2) + " s" : "—"
                    color: root.popupText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Button {
                    text: "+"
                    fontFamily: root.fontFamily
                    foreground: root.popupText
                    bordered: true
                    horizontalPadding: Style.space(9)
                    verticalPadding: Style.space(2)
                    enabled: !!(root.status && root.status.output)
                    opacity: enabled ? 1 : 0.4
                    tooltipText: "0.05 s later"
                    onClicked: root.nudgeDelay(0.05)
                  }
                }
              }
              InfoRow {
                label: "Source"
                fg: root.popupText; family: root.fontFamily; width: parent.width
                value: root.source
                detail: root.source === "mic" ? "lights follow music only" : (root.status && root.status.delaying ? "delayed to match the speakers" : "")
              }

              PanelSeparator { width: parent.width; foreground: root.popupText; strength: 0.08 }

              // Psywall off: one way back, nothing else to control.
              Button {
                visible: !!root.status && !root.status.enabled
                text: "Resume psywall"
                fontFamily: root.fontFamily
                foreground: root.popupText
                bordered: true
                onClicked: root.turnOn()
              }

              Column {
                visible: !!root.status && root.status.enabled
                width: parent.width
                spacing: Style.space(6)

                // Everything off in one press: nothing captures, draws or
                // streams, so psywall costs no CPU (and no battery).
                Item {
                  width: parent.width
                  implicitHeight: pauseBtn.implicitHeight

                  Button {
                    id: pauseBtn
                    text: "Pause psywall"
                    fontFamily: root.fontFamily
                    foreground: root.popupText
                    bordered: true
                    tooltipText: "Stop the audio capture, the wallpaper effect and the lights (the lights go back to normal)"
                    onClicked: root.setEnabled(false)
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.left: pauseBtn.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: parent.right
                    anchors.verticalCenter: pauseBtn.verticalCenter
                    elide: Text.ElideRight
                    text: "frees the CPU while on battery"
                    color: root.popupFaint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                SwitchRow {
                  visible: root.paired
                  label: "Lights"
                  checked: root.hueOn
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onToggled: root.setLights(!root.hueOn)
                }
                Item {
                  width: parent.width
                  implicitHeight: hueBtn.implicitHeight
                  Text {
                    anchors.left: parent.left
                    anchors.right: hueBtn.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.paired ? String((root.room.bridge || {}).name || "Hue Bridge") + " · " + root.layout.length + (root.layout.length === 1 ? " light" : " lights")
                                      : "Philips Hue lights"
                    color: root.popupDim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Button {
                    id: hueBtn
                    anchors.right: parent.right
                    text: root.paired ? "Lights…" : "Connect"
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    foreground: root.popupText
                    bordered: true
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(1)
                    tooltipText: root.paired ? "Choose which lights take part, or pair another bridge" : "Pair a Philips Hue bridge"
                    onClicked: root.openSetup()
                  }
                }
                SwitchRow {
                  label: "Mic when nothing plays"
                  checked: !!(root.status && root.status.micFallback)
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onToggled: { root.patchStatus("micFallback", !root.status.micFallback); root.ipc(["toggleMic"]) }
                }
                SwitchRow {
                  label: "Wallpaper"
                  checked: !!(root.status && root.status.wallpaperEffect !== false)
                  enabled: !!(root.status && root.status.wallpaperEffect !== undefined)
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onToggled: root.setWallpaper(!(root.status.wallpaperEffect !== false))
                }
                SliderRow {
                  label: "Brightness"
                  bar: root.bar
                  value: root.status ? Number(root.status.hueStrength) : 1
                  maximum: 2
                  valueText: Math.round(value * 100) + "%"
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onCommitted: function(v) { root.setHueStrength(v) }
                }
                SliderRow {
                  label: "Aggression"
                  bar: root.bar
                  value: root.status && root.status.hueAggression !== undefined ? Number(root.status.hueAggression) : 1
                  maximum: 2
                  ticks: 3
                  leftHint: "Calm"
                  rightHint: "Wild"
                  valueText: Math.abs(value - 1) < 0.001 ? "1.0 · default" : value.toFixed(2)
                  enabled: !!(root.status && root.status.hueAggression !== undefined)
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onCommitted: function(v) { root.setAggression(v) }
                }
                SliderRow {
                  label: "Wallpaper strength"
                  bar: root.bar
                  value: root.status ? Number(root.status.strength) : 1
                  maximum: 2
                  valueText: Math.round(value * 100) + "%"
                  fg: root.popupText; family: root.fontFamily; width: parent.width
                  onCommitted: function(v) { root.setStrength(v) }
                }
              }
            }
          }
        }
          }
        }
      }
    }
  }

  // ======================================================================
  // soundscape painter
  // ======================================================================
  function paintScape(ctx, W, H, tp, pps) {
    ctx.reset()
    var hist = history
    var n = hist.length
    if (n < 2 || !tp) return
    function X(t) { return W - (tp - t) * pps }
    var t0 = tp - historySpan - 1
    var first = 0
    while (first < n - 1 && hist[first + 1].t < t0) first++
    var fg = popupText

    // section bands behind everything
    var runStart = first
    for (var i = first + 1; i <= n; i++) {
      if (i === n || hist[i].sec !== hist[runStart].sec) {
        var sec = hist[runStart].sec
        var xa = X(hist[runStart].t), xb = i === n ? W : X(hist[i].t)
        var a = sec === "peak" ? 0.075 : sec === "groove" ? 0.035 : 0
        if (a > 0) {
          ctx.fillStyle = VM.css(fg.r, fg.g, fg.b, a)
          ctx.fillRect(xa, 0, xb - xa, H)
        }
        if (sec && xb - xa > 46) {
          ctx.fillStyle = VM.css(fg.r, fg.g, fg.b, 0.42)
          ctx.font = Math.max(8, Style.font.caption - 1) + "px sans-serif"
          ctx.fillText(sec, xa + 5, H - 5)
        }
        runStart = i
      }
    }

    // smoothed bands (~0.9 s window): the shape of the music, not its waveform
    var xs = [], sb = [], sm = [], sh = [], si = []
    for (var k = first; k < n; k++) {
      var lo = Math.max(first, k - 7), hi = Math.min(n - 1, k + 7), cnt = 0, b = 0, m = 0, h = 0, it = 0, ic = 0
      for (var j = lo; j <= hi; j++) {
        b += hist[j].b; m += hist[j].m; h += hist[j].h; cnt++
        if (hist[j].i >= 0) { it += hist[j].i; ic++ }
      }
      xs.push(X(hist[k].t)); sb.push(b / cnt); sm.push(m / cnt); sh.push(h / cnt); si.push(ic ? it / ic : -1)
    }
    var mid = H * 0.5

    function gradient(idx, alpha) {
      var g = ctx.createLinearGradient(0, 0, W, 0)
      var stepK = Math.max(1, Math.floor((n - first) / 12))
      var any = false
      for (var q = first; q < n; q += stepK) {
        var p = hist[q].pal
        var pos = Math.max(0, Math.min(1, X(hist[q].t) / W))
        if (p && p[idx]) { g.addColorStop(pos, VM.css(p[idx][0], p[idx][1], p[idx][2], alpha)); any = true }
        else g.addColorStop(pos, VM.css(fg.r, fg.g, fg.b, alpha * 0.55))
      }
      var pl = hist[n - 1].pal
      g.addColorStop(1, pl && pl[idx] ? VM.css(pl[idx][0], pl[idx][1], pl[idx][2], alpha) : VM.css(fg.r, fg.g, fg.b, alpha * 0.55))
      return g
    }

    // a ribbon mirrored about the midline, drawn through midpoints so it flows
    function ribbon(vals, scale, floor, style) {
      var L = xs.length
      ctx.beginPath()
      ctx.moveTo(xs[0], mid - (floor + vals[0]) * scale)
      for (var r = 1; r < L - 1; r++) {
        var xm = (xs[r] + xs[r + 1]) / 2, ym = mid - (floor + (vals[r] + vals[r + 1]) / 2) * scale
        ctx.quadraticCurveTo(xs[r], mid - (floor + vals[r]) * scale, xm, ym)
      }
      ctx.lineTo(xs[L - 1], mid - (floor + vals[L - 1]) * scale)
      ctx.lineTo(xs[L - 1], mid + (floor + vals[L - 1]) * scale)
      for (var s = L - 2; s > 0; s--) {
        var xm2 = (xs[s] + xs[s - 1]) / 2, ym2 = mid + (floor + (vals[s] + vals[s - 1]) / 2) * scale
        ctx.quadraticCurveTo(xs[s], mid + (floor + vals[s]) * scale, xm2, ym2)
      }
      ctx.lineTo(xs[0], mid + (floor + vals[0]) * scale)
      ctx.closePath()
      ctx.fillStyle = style
      ctx.fill()
    }

    ribbon(sb, H * 0.40, 0.04, gradient(0, 0.20))
    ribbon(sm, H * 0.26, 0.02, gradient(1, 0.30))
    ribbon(sh, H * 0.10, 0.01, gradient(2, 0.55))

    // intensity: one quiet line across the top half
    ctx.beginPath()
    var started = false
    for (var z = 0; z < xs.length; z++) {
      if (si[z] < 0) { started = false; continue }
      var yy = H * 0.94 - si[z] * H * 0.86
      if (!started) { ctx.moveTo(xs[z], yy); started = true } else ctx.lineTo(xs[z], yy)
    }
    ctx.strokeStyle = VM.css(fg.r, fg.g, fg.b, 0.5)
    ctx.lineWidth = 1.2
    ctx.stroke()

    // melody accents: small ticks along the bottom edge
    var pl2 = hist[n - 1].pal
    for (var u = 0; u < accents.length; u++) {
      var ac = accents[u]
      if (ac.t < t0) continue
      var ax = X(ac.t)
      var big = ac.k === "blast"
      var col = pl2 && pl2[2] ? pl2[2] : [fg.r, fg.g, fg.b]
      ctx.fillStyle = VM.css(col[0], col[1], col[2], ac.k === "glint" ? 0.28 : 0.7)
      ctx.beginPath()
      ctx.arc(ax, big ? 7 : H - 16, big ? 2.4 : (ac.k === "pop" ? 1.6 : 1.1), 0, Math.PI * 2)
      ctx.fill()
    }

    // big moments and section changes
    var ms = show && show.moments ? show.moments : []
    ctx.font = "bold " + Math.max(8, Style.font.caption - 1) + "px sans-serif"
    for (var v = 0; v < ms.length; v++) {
      if (ms[v].t < t0) continue
      var info = VM.eventInfo(ms[v].e)
      var mx = X(ms[v].t)
      if (info.weight >= 3) {
        ctx.fillStyle = VM.css(fg.r, fg.g, fg.b, 0.7)
        ctx.fillRect(Math.round(mx), 12, 1, H - 12)
        ctx.fillStyle = VM.css(fg.r, fg.g, fg.b, 0.92)
        ctx.fillText(info.kind === "RELEASE" ? info.label.replace("RELEASE ", "REL ") : info.label, mx + 4, 10)
      } else if (info.kind === "section") {
        ctx.fillStyle = VM.css(fg.r, fg.g, fg.b, 0.22)
        for (var dy = 0; dy < H; dy += 5) ctx.fillRect(Math.round(mx), dy, 1, 2)
      }
    }
  }

  // ======================================================================
  // small building blocks
  // ======================================================================
  component SectionLabel: Text {
    textFormat: Text.PlainText
    property color fg: "white"
    property string family: "monospace"
    color: Qt.rgba(fg.r, fg.g, fg.b, 0.5)
    font.family: family
    font.pixelSize: Math.max(8, Style.font.caption - 1)
    font.bold: true
    font.letterSpacing: 1.6
  }

  component Meter: Item {
    id: meter
    property string label: ""
    property real value: 0
    property color tint: "white"
    property string valueText: ""
    property color fg: "white"
    property string family: "monospace"
    implicitHeight: Math.max(mText.implicitHeight, Style.space(14))
    Text {
      textFormat: Text.PlainText
      id: mText
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(70)
      text: meter.label
      color: Qt.rgba(meter.fg.r, meter.fg.g, meter.fg.b, 0.55)
      font.family: meter.family
      font.pixelSize: Style.font.caption
    }
    Rectangle {
      id: track
      anchors.left: mText.right
      anchors.right: mVal.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(3, Style.space(4))
      radius: height / 2
      color: Qt.rgba(meter.fg.r, meter.fg.g, meter.fg.b, 0.09)
      Rectangle {
        height: parent.height
        radius: parent.radius
        width: Math.max(0, Math.min(1, meter.value)) * parent.width
        color: meter.tint
        Behavior on width { NumberAnimation { duration: 180 } }
      }
    }
    Text {
      textFormat: Text.PlainText
      id: mVal
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(74)
      horizontalAlignment: Text.AlignRight
      text: meter.valueText
      color: meter.fg
      font.family: meter.family
      font.pixelSize: Style.font.caption
    }
  }

  component InfoRow: Item {
    id: info
    property string label: ""
    property string value: ""
    property string detail: ""
    property color fg: "white"
    property string family: "monospace"
    implicitHeight: iLabel.implicitHeight
    Text {
      textFormat: Text.PlainText
      id: iLabel
      width: Style.space(70)
      text: info.label
      color: Qt.rgba(info.fg.r, info.fg.g, info.fg.b, 0.55)
      font.family: info.family
      font.pixelSize: Style.font.caption
    }
    Text {
      textFormat: Text.PlainText
      id: iValue
      anchors.left: iLabel.right
      anchors.baseline: iLabel.baseline
      text: info.value
      color: info.fg
      font.family: info.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      anchors.left: iValue.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.baseline: iLabel.baseline
      elide: Text.ElideRight
      text: info.detail
      color: Qt.rgba(info.fg.r, info.fg.g, info.fg.b, 0.5)
      font.family: info.family
      font.pixelSize: Style.font.caption
    }
  }

  component SwitchRow: Item {
    id: sw
    property string label: ""
    property bool checked: false
    property color fg: "white"
    property string family: "monospace"
    signal toggled()
    implicitHeight: swSwitch.implicitHeight
    opacity: enabled ? 1 : 0.4
    Text {
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: sw.label
      color: sw.fg
      font.family: sw.family
      font.pixelSize: Style.font.caption
    }
    ToggleSwitch {
      id: swSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      trackHeight: Style.space(16)
      cursorRing: false
      checked: sw.checked
      foreground: sw.fg
      interactive: sw.enabled
      onToggled: sw.toggled()
    }
  }

  component SliderRow: Column {
    id: sr
    property string label: ""
    property real value: 0
    property real maximum: 1
    property int ticks: 0
    property string valueText: ""
    property string leftHint: ""
    property string rightHint: ""
    property var bar: null
    property color fg: "white"
    property string family: "monospace"
    signal committed(real v)
    spacing: 0
    opacity: enabled ? 1 : 0.4
    Item {
      width: sr.width
      height: srLabel.implicitHeight
      Text {
        textFormat: Text.PlainText
        id: srLabel
        text: sr.label
        color: sr.fg
        font.family: sr.family
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        anchors.right: parent.right
        text: sr.valueText
        color: Qt.rgba(sr.fg.r, sr.fg.g, sr.fg.b, 0.55)
        font.family: sr.family
        font.pixelSize: Style.font.caption
      }
    }
    PanelSlider {
      width: sr.width
      bar: sr.bar
      value: sr.value
      maximum: sr.maximum
      step: 0.05
      tickCount: sr.ticks
      enabled: sr.enabled
      onReleased: function(v) { sr.committed(v) }
    }
    Item {
      visible: sr.leftHint !== "" || sr.rightHint !== ""
      width: sr.width
      height: visible ? hintL.implicitHeight : 0
      Text { textFormat: Text.PlainText; id: hintL; text: sr.leftHint; color: Qt.rgba(sr.fg.r, sr.fg.g, sr.fg.b, 0.4); font.family: sr.family; font.pixelSize: Math.max(8, Style.font.caption - 1) }
      Text { textFormat: Text.PlainText; anchors.right: parent.right; text: sr.rightHint; color: Qt.rgba(sr.fg.r, sr.fg.g, sr.fg.b, 0.4); font.family: sr.family; font.pixelSize: Math.max(8, Style.font.caption - 1) }
    }
  }
}
