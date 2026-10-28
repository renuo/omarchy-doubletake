const { describe, it } = require("node:test")
const assert = require("node:assert/strict")
const path = require("node:path")
const { loadModel } = require("./load-model")

const Model = loadModel()

// Values built inside the vm context carry that context's prototypes, which
// deepStrictEqual would reject; compare their JSON shape instead.
const plain = (value) => JSON.parse(JSON.stringify(value))

// Stands in for Commons.Translations, reading the shipped English catalog so a
// renamed or missing key fails here rather than showing up as a raw key.
const catalog = require(path.join(__dirname, "..", "i18n", "en.json"))
const strings = {
  t: (key) => {
    if (!(key in catalog)) throw new Error("missing translation " + key)
    return catalog[key]
  },
}

function daemon(streams, devices) {
  return Model.parseState(JSON.stringify({ enabled: true, daemon: true, status: { ok: true, streams: streams || [] }, devices: devices || [] }))
}

const office = { name: "Office", ip: "192.0.2.11", model: "AppleTV14,1", paired: true }

describe("pathFromUrl", () => {
  it("strips file:// and decodes", () => {
    assert.equal(Model.pathFromUrl("file:///home/me/my%20plugin/ctl.sh"), "/home/me/my plugin/ctl.sh")
  })

  it("passes plain paths through", () => {
    assert.equal(Model.pathFromUrl("/a/ctl.sh"), "/a/ctl.sh")
    assert.equal(Model.pathFromUrl(undefined), "")
  })

  it("keeps an undecodable path as is", () => {
    assert.equal(Model.pathFromUrl("file:///a/%E0%A4%A"), "/a/%E0%A4%A")
  })
})

describe("parseState", () => {
  it("reads streams and devices", () => {
    const state = Model.parseState(JSON.stringify({
      enabled: true,
      daemon: true,
      status: {
        error: "192.0.2.12: connect failed",
        streams: [{ device: "Office", device_ip: "192.0.2.11", state: "pin_required", credential_kind: "password" }],
      },
      devices: [{ name: "Office", ip: "192.0.2.11", model: "AppleTV14,1", paired: true, device_id: "AA" }],
    }))
    assert.deepEqual(plain(state), {
      enabled: true,
      daemon: true,
      error: "192.0.2.12: connect failed",
      streams: [{ ip: "192.0.2.11", name: "Office", state: "pin_required", credentialKind: "password" }],
      devices: [office],
    })
  })

  it("fills in what the daemon leaves out", () => {
    const state = daemon([{ device_ip: "192.0.2.11" }, {}], [{ ip: "192.0.2.12" }, {}, null, "junk"])
    assert.deepEqual(plain(state.streams), [
      { ip: "192.0.2.11", name: "192.0.2.11", state: "", credentialKind: "pin" },
      { ip: "", name: "", state: "", credentialKind: "pin" },
    ])
    assert.deepEqual(plain(state.devices), [
      { ip: "192.0.2.12", name: "192.0.2.12", model: "", paired: false },
      { ip: "", name: "", model: "", paired: false },
    ])
  })

  it("survives a reply without status or lists", () => {
    assert.deepEqual(plain(Model.parseState('{"enabled":true,"daemon":true,"devices":{}}')), { enabled: true, daemon: true, error: "", streams: [], devices: [] })
  })

  it("is disabled when the service is off, whatever else it says, and for garbage", () => {
    const disabled = { enabled: false, daemon: false, error: "", streams: [], devices: [] }
    assert.deepEqual(plain(Model.parseState('{"enabled":false,"daemon":true}')), disabled)
    assert.deepEqual(plain(Model.parseState('{"daemon":true}')), disabled)
    assert.deepEqual(plain(Model.parseState("null")), disabled)
    assert.deepEqual(plain(Model.parseState("not json")), disabled)
    assert.deepEqual(plain(Model.parseState(undefined)), disabled)
  })

  it("is enabled but unreachable when the daemon does not answer", () => {
    assert.deepEqual(plain(Model.parseState('{"enabled":true,"daemon":false}')), { enabled: true, daemon: false, error: "", streams: [], devices: [] })
  })
})

describe("phase and prompt", () => {
  it("is disabled while the service is off", () => {
    assert.equal(Model.phase(Model.disabled()), "disabled")
  })

  it("is offline when enabled but the daemon does not answer", () => {
    assert.equal(Model.phase(Model.parseState('{"enabled":true,"daemon":false}')), "offline")
  })

  it("is idle with no streams", () => {
    assert.equal(Model.phase(daemon([], [office])), "idle")
    assert.equal(Model.prompt(daemon()), null)
  })

  it("is sharing while connecting or streaming", () => {
    assert.equal(Model.phase(daemon([{ device_ip: "192.0.2.11", state: "connecting" }])), "sharing")
    assert.equal(Model.phase(daemon([{ device_ip: "192.0.2.11", state: "streaming" }])), "sharing")
  })

  it("asks for the code of the first waiting receiver before anything else", () => {
    const state = daemon([
      { device: "Living Room", device_ip: "192.0.2.10", state: "streaming" },
      { device: "Office", device_ip: "192.0.2.11", state: "pin_required", credential_kind: "pin" },
    ])
    assert.equal(Model.phase(state), "credential")
    assert.deepEqual(plain(Model.prompt(state)), { ip: "192.0.2.11", name: "Office", kind: "pin" })
  })
})

describe("deviceRows", () => {
  it("lists paired receivers first, each section by name", () => {
    const rows = Model.deviceRows([
      { name: "Kitchen", ip: "192.0.2.3", paired: false },
      { name: "Office", ip: "192.0.2.2", paired: true },
      { name: "Bedroom", ip: "192.0.2.4", paired: false },
      { name: "Office", ip: "192.0.2.1", paired: true },
    ])
    assert.deepEqual(plain(rows.map((r) => [r.section, r.device.name, r.device.ip])), [
      ["paired", "Office", "192.0.2.1"],
      ["paired", "Office", "192.0.2.2"],
      ["unpaired", "Bedroom", "192.0.2.4"],
      ["unpaired", "Kitchen", "192.0.2.3"],
    ])
  })

  it("puts Apple TVs first and Macs last within each section", () => {
    const rows = Model.deviceRows([
      { name: "Anna's MacBook Pro", ip: "1", model: "MacBookPro18,3", paired: false },
      { name: "Bar", ip: "2", model: "Mac16,10", paired: false },
      { name: "Cinema", ip: "3", model: "iMac21,1", paired: false },
      { name: "Zimmer", ip: "4", model: "AppleTV14,1", paired: false },
      { name: "Lobby", ip: "5", model: "Samsung TU8300", paired: false },
      { name: "Unknown", ip: "6", model: "", paired: false },
      { name: "Studio", ip: "7", model: "Mac14,2", paired: true },
      { name: "Wohnzimmer", ip: "8", model: "AppleTV11,1", paired: true },
    ])
    assert.deepEqual(plain(rows.map((r) => r.section + ":" + r.device.name)), [
      "paired:Wohnzimmer",
      "paired:Studio",
      "unpaired:Zimmer",
      "unpaired:Lobby",
      "unpaired:Unknown",
      "unpaired:Anna's MacBook Pro",
      "unpaired:Bar",
      "unpaired:Cinema",
    ])
  })

  it("titles only the first row of each section", () => {
    const rows = Model.deviceRows([
      { name: "A", ip: "1", paired: true },
      { name: "B", ip: "2", paired: true },
      { name: "C", ip: "3", paired: false },
    ])
    assert.deepEqual([0, 1, 2].map((i) => Model.sectionTitle(rows, i)), ["paired", "", "unpaired"])
    assert.equal(Model.sectionTitle(rows, -1), "")
    assert.equal(Model.sectionTitle(rows, 3), "")
  })
})

describe("codeValid", () => {
  it("wants exactly four digits for a PIN", () => {
    assert.equal(Model.codeValid("pin", "1234"), true)
    assert.equal(Model.codeValid("pin", "123"), false)
    assert.equal(Model.codeValid("pin", "12345"), false)
    assert.equal(Model.codeValid("pin", "12a4"), false)
    assert.equal(Model.codeValid("pin", undefined), false)
  })

  it("takes any non-empty password", () => {
    assert.equal(Model.codeValid("password", "open sesame"), true)
    assert.equal(Model.codeValid("password", ""), false)
  })
})

describe("format", () => {
  it("keeps placeholders inside values literal", () => {
    assert.equal(Model.format("%1 and %2", ["$& %2", "x"]), "$& %2 and x")
    assert.equal(Model.format("%1 %3", ["a"]), "a %3")
  })
})

describe("texts", () => {
  it("describes each stream", () => {
    assert.equal(Model.streamStatus({ state: "streaming" }, strings), "Sharing your screen")
    assert.equal(Model.streamStatus({ state: "pin_required" }, strings), "Waiting for the code")
    assert.equal(Model.streamStatus({ state: "connecting" }, strings), "Connecting…")
  })

  it("headlines the panel and the tooltip", () => {
    const disabled = Model.disabled()
    assert.equal(Model.heroStatus(disabled, strings), "Off")
    assert.equal(Model.tooltip(disabled, strings), "AirPlay is off")

    const offline = Model.parseState('{"enabled":true,"daemon":false}')
    assert.equal(Model.heroStatus(offline, strings), "doubletake is not responding")
    assert.equal(Model.tooltip(offline, strings), "doubletake is not responding")

    const idle = daemon()
    assert.equal(Model.heroStatus(idle, strings), "Not sharing")
    assert.equal(Model.tooltip(idle, strings), "AirPlay: share your screen")

    const connecting = daemon([{ device: "Office", device_ip: "1", state: "connecting" }, { device: "Kitchen", device_ip: "2", state: "connecting" }])
    assert.equal(Model.heroStatus(connecting, strings), "Connecting to Office, Kitchen")

    const sharing = daemon([{ device: "Office", device_ip: "1", state: "streaming" }, { device: "Kitchen", device_ip: "2", state: "connecting" }])
    assert.equal(Model.heroStatus(sharing, strings), "Sharing to Office")
    assert.equal(Model.tooltip(sharing, strings), "Sharing to Office")

    const waiting = daemon([{ device: "Office", device_ip: "1", state: "pin_required" }])
    assert.equal(Model.heroStatus(waiting, strings), "Office asks for a code")
  })
})

describe("replyError", () => {
  it("returns the daemon's refusal", () => {
    assert.equal(Model.replyError('{"ok":false,"error":"no available devices found"}'), "no available devices found")
    assert.equal(Model.replyError('{"ok":false}'), "")
  })

  it("is empty for success, silence and garbage", () => {
    assert.equal(Model.replyError('{"ok":true}'), "")
    assert.equal(Model.replyError(""), "")
    assert.equal(Model.replyError("null"), "")
    assert.equal(Model.replyError("error: connect to daemon"), "")
  })
})

describe("errorConcerns", () => {
  it("matches the receiver the error is about", () => {
    assert.equal(Model.errorConcerns("192.0.2.1: pin pairing: wrong PIN", "192.0.2.1"), true)
    assert.equal(Model.errorConcerns("192.0.2.10: connect failed", "192.0.2.1"), false)
  })

  it("matches nothing without an error or a receiver", () => {
    assert.equal(Model.errorConcerns("", "192.0.2.1"), false)
    assert.equal(Model.errorConcerns(undefined, "192.0.2.1"), false)
    assert.equal(Model.errorConcerns("192.0.2.1: x", ""), false)
  })
})

describe("cursor", () => {
  const rows = Model.deviceRows([office, { name: "Kitchen", ip: "192.0.2.12", paired: false }])

  it("counts the rows below the switch in each phase", () => {
    assert.equal(Model.cursorRows("idle", rows), 2)
    assert.equal(Model.cursorRows("sharing", rows), 1)
    assert.equal(Model.cursorRows("disabled", rows), 0)
    assert.equal(Model.cursorRows("offline", rows), 0)
    assert.equal(Model.cursorRows("credential", rows), 0)
  })

  it("moves between the switch (-1) and the last row", () => {
    assert.equal(Model.moveCursor(0, -1, 2), -1)
    assert.equal(Model.moveCursor(-1, -1, 2), -1)
    assert.equal(Model.moveCursor(-1, 1, 2), 0)
    assert.equal(Model.moveCursor(1, 1, 2), 1)
    assert.equal(Model.moveCursor(5, 0, 2), 1)
    assert.equal(Model.moveCursor(0, 1, 0), -1)
  })
})
