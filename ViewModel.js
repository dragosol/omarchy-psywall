.pragma library

// Pure helpers for BarWidget.qml.

// What an OwnTone speaker actually is, for the output line.
var KNOWN_SPEAKERS = {}

function clamp01(x) {
  x = Number(x)
  return isFinite(x) ? Math.max(0, Math.min(1, x)) : 0
}

function cap(s) {
  s = String(s || "")
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : ""
}

// A light's rgb (0..1, already scaled by brightness) as a hue at full value
// plus how bright it is.
function light(rgb) {
  if (!rgb || rgb.length < 3) return { r: 0, g: 0, b: 0, v: 0 }
  var r = Number(rgb[0]) || 0, g = Number(rgb[1]) || 0, b = Number(rgb[2]) || 0
  var v = Math.max(r, g, b)
  if (v < 0.004) return { r: 0, g: 0, b: 0, v: 0 }
  return { r: r / v, g: g / v, b: b / v, v: v }
}

function css(r, g, b, a) {
  return "rgba(" + Math.round(r * 255) + "," + Math.round(g * 255) + "," + Math.round(b * 255) + "," + a + ")"
}

function speakers(list) {
  var names = String(list || "").split(/\s*[,+]\s*/).filter(function(s) { return s })
  return names
}

// "owntone:Kitchen" -> "Kitchen via OwnTone" (with a KNOWN_SPEAKERS note if set)
function prettyOutput(out) {
  out = String(out || "")
  if (!out) return "No output seen yet"
  if (out.indexOf("owntone:") === 0) {
    var names = speakers(out.substring(8))
    if (!names.length) return "OwnTone (no speaker selected)"
    var what = names.map(function(n) { return KNOWN_SPEAKERS[n] }).filter(function(k) { return k })
    return names.join(" + ") + " (" + (what.length === names.length ? what.join(" + ") + " via OwnTone" : "via OwnTone") + ")"
  }
  if (out.indexOf("raop_sink.") === 0) return cleanSink(out.substring(10)) + " (AirPlay)"
  if (/sofsoundwire|speaker/i.test(out)) return "Laptop speakers"
  if (/hdmi/i.test(out)) return "HDMI"
  if (/bluez/i.test(out)) return "Bluetooth"
  if (/usb/i.test(out)) return "USB audio"
  return cleanSink(out)
}

// "owntone:Kitchen" -> "Kitchen via OwnTone"
function shortOutput(out) {
  out = String(out || "")
  if (out.indexOf("owntone:") === 0) return (speakers(out.substring(8)).join(" + ") || "OwnTone") + " via OwnTone"
  return prettyOutput(out).replace(/ \((.*)\)$/, " · $1")
}

function cleanSink(s) {
  return String(s).replace(/^alsa_output\./, "").replace(/[._-]+/g, " ").replace(/\s+/g, " ").trim()
}

function delayText(d) {
  d = Number(d) || 0
  return (d > 0 ? "+" : "") + d.toFixed(2) + " s"
}

function ago(seconds) {
  var s = Math.max(0, Math.round(seconds))
  if (s < 2) return "now"
  if (s < 60) return s + " s ago"
  var m = Math.floor(s / 60)
  if (m < 60) return m + " min ago"
  return Math.floor(m / 60) + " h ago"
}

function duration(seconds) {
  var s = Math.max(0, Math.round(seconds))
  if (s < 60) return s + " s"
  return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
}

// weight: 3 = an aggressive moment, 2 = a blast, 1 = a change of scene
function eventInfo(e) {
  var parts = String(e || "").split(" ")
  var kind = parts[0], rest = parts.slice(1).join(" ")
  if (kind === "HIT") return { kind: "HIT", label: "HIT", detail: "an impact: a few lights crack to white", weight: 3 }
  if (kind === "RELEASE") return { kind: "RELEASE", label: rest ? "RELEASE (" + rest + ")" : "RELEASE", detail: rest === "drop" ? "the drop after a breakdown: fresh palette, room cascade" : "the build lets go: fresh palette, room cascade", weight: 3 }
  if (kind === "BURST") return { kind: "BURST", label: "BURST", detail: "the climax: two bars of left/right on the half-beat", weight: 3 }
  if (kind === "blast") return { kind: "blast", label: "blast", detail: "a big melody accent over a few lights", weight: 2 }
  if (kind === "section") return { kind: "section", label: "→ " + rest, detail: sectionBlurb(rest), weight: 1 }
  if (kind === "palette") return { kind: "palette", label: rest + " palette", detail: "sweeps across the room", weight: 1 }
  return { kind: kind, label: e, detail: "", weight: 0 }
}

function sectionBlurb(s) {
  if (s === "breakdown") return "the room rests"
  if (s === "groove") return "steady, the beat handed around"
  if (s === "peak") return "the loud part of the song"
  return ""
}

function styleBlurb(s) {
  if (s === "walk") return "walks across the room"
  if (s === "scatter") return "lands on scattered lights"
  if (s === "pairs") return "two lights answer each other"
  if (s === "still") return "rests; lights only drift"
  return ""
}

function driverText(d) {
  if (d === "tempo") return "changing colour with the tempo (a cycle per bar)"
  if (d === "bass") return "following the bass"
  if (d === "mids") return "following the mids"
  if (d === "highs") return "following the highs"
  return "drifting on its own"
}

function driverShort(d) {
  if (d === "tempo") return "tempo"
  if (d === "bass" || d === "mids" || d === "highs") return d
  return ""
}
