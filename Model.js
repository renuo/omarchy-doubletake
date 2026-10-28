.pragma library

var GLYPH = "󰀟" // nf-md-airplay
var PIN_LENGTH = 4

function pathFromUrl(url) {
  var s = String(url || "")
  if (s.indexOf("file://") === 0) s = s.substring(7)
  try {
    return decodeURIComponent(s)
  } catch (e) {
    return s
  }
}

function disabled() {
  return { enabled: false, daemon: false, error: "", streams: [], devices: [] }
}

function parseState(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return disabled()
  }
  if (!parsed || parsed.enabled !== true) return disabled()
  if (parsed.daemon !== true) return { enabled: true, daemon: false, error: "", streams: [], devices: [] }
  var status = parsed.status || {}
  return {
    enabled: true,
    daemon: true,
    error: String(status.error || ""),
    streams: list(status.streams).map(toStream),
    devices: list(parsed.devices).map(toDevice)
  }
}

function list(value) {
  return Array.isArray(value) ? value.filter(function (entry) { return entry && typeof entry === "object" }) : []
}

function toStream(entry) {
  var ip = String(entry.device_ip || "")
  return {
    ip: ip,
    name: String(entry.device || ip),
    state: String(entry.state || ""),
    credentialKind: entry.credential_kind === "password" ? "password" : "pin"
  }
}

function toDevice(entry) {
  var ip = String(entry.ip || "")
  return {
    ip: ip,
    name: String(entry.name || ip),
    model: String(entry.model || ""),
    paired: entry.paired === true
  }
}

// The first receiver waiting for a PIN or password, or null.
function prompt(state) {
  for (var i = 0; i < state.streams.length; i++) {
    var stream = state.streams[i]
    if (stream.state === "pin_required") return { ip: stream.ip, name: stream.name, kind: stream.credentialKind }
  }
  return null
}

// disabled: switched off; offline: switched on but the daemon does not answer;
// credential: a receiver asks for a code; sharing: any stream exists,
// connecting or live; idle: free to pick a receiver.
function phase(state) {
  if (!state.enabled) return "disabled"
  if (!state.daemon) return "offline"
  if (prompt(state)) return "credential"
  if (state.streams.length > 0) return "sharing"
  return "idle"
}

// Apple TVs are what one usually shares to, Macs (every Mac advertises a
// receiver by default) rarely, so they sink to the bottom.
function kindRank(device) {
  if (/^AppleTV/.test(device.model)) return 0
  if (/^i?Mac/.test(device.model)) return 2
  return 1
}

function byKindThenName(a, b) {
  return kindRank(a) - kindRank(b) || a.name.localeCompare(b.name) || a.ip.localeCompare(b.ip)
}

// Paired receivers first, then the rest, each sorted by kind, then name.
// Every row knows its section so the panel can draw headers and keep one flat
// cursor.
function deviceRows(devices) {
  var sorted = devices.slice().sort(byKindThenName)
  var paired = sorted.filter(function (d) { return d.paired })
  var unpaired = sorted.filter(function (d) { return !d.paired })
  return paired.map(function (d) { return { section: "paired", device: d } })
    .concat(unpaired.map(function (d) { return { section: "unpaired", device: d } }))
}

function sectionTitle(rows, index) {
  if (index < 0 || index >= rows.length) return ""
  if (index > 0 && rows[index - 1].section === rows[index].section) return ""
  return rows[index].section
}

function codeValid(kind, code) {
  var text = String(code || "")
  if (kind === "pin") return new RegExp("^\\d{" + PIN_LENGTH + "}$").test(text)
  return text.length > 0
}

// Single pass, so a "%2" or "$&" inside a receiver name stays literal text.
function format(template, values) {
  return String(template).replace(/%(\d)/g, function (match, n) {
    var value = values[Number(n) - 1]
    return value === undefined ? match : String(value)
  })
}

function streamStatus(stream, strings) {
  if (stream.state === "streaming") return strings.t("stream.streaming")
  if (stream.state === "pin_required") return strings.t("stream.waiting")
  return strings.t("stream.connecting")
}

function names(streams) {
  return streams.map(function (s) { return s.name }).join(", ")
}

function heroStatus(state, strings) {
  switch (phase(state)) {
  case "disabled": return strings.t("status.disabled")
  case "offline": return strings.t("status.offline")
  case "credential": return format(strings.t("status.credential"), [prompt(state).name])
  case "sharing":
    var live = state.streams.filter(function (s) { return s.state === "streaming" })
    if (live.length > 0) return format(strings.t("status.sharing"), [names(live)])
    return format(strings.t("status.connecting"), [names(state.streams)])
  default: return strings.t("status.idle")
  }
}

function tooltip(state, strings) {
  var current = phase(state)
  if (current === "disabled") return strings.t("tooltip.disabled")
  if (current === "offline") return strings.t("status.offline")
  if (current === "idle") return strings.t("tooltip.idle")
  return heroStatus(state, strings)
}

// The daemon's error from a doubletake-ctl reply, or "" when it succeeded or
// said nothing (an unreachable daemon shows up in the next state poll).
function replyError(raw) {
  try {
    var reply = JSON.parse(String(raw || ""))
    return reply && reply.ok === false ? String(reply.error || "") : ""
  } catch (e) {
    return ""
  }
}

// The daemon prefixes a stream's failure with its receiver's address.
function errorConcerns(error, ip) {
  return ip !== "" && String(error || "").indexOf(ip + ": ") === 0
}

// The keyboard cursor sits on the on/off switch at -1 and on rows below it
// from 0: receivers while idle, the Stop button while sharing.
function cursorRows(currentPhase, rows) {
  if (currentPhase === "idle") return rows.length
  if (currentPhase === "sharing") return 1
  return 0
}

function moveCursor(index, delta, count) {
  return Math.max(-1, Math.min(count - 1, index + delta))
}
