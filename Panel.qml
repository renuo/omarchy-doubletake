import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup. A switch in the header starts and stops the daemon
// (and keeps it that way across logins). Idle, the popup lists receivers,
// paired ones first; picking a paired one connects straight away, an unpaired
// one asks to pair first. While sharing, it offers a single Stop. All daemon
// and systemd traffic goes through ctl.sh.
Panel {
  id: root
  moduleName: "renuo.doubletake"
  ipcTarget: "doubletake"

  readonly property string ctlPath: Model.pathFromUrl(Qt.resolvedUrl("ctl.sh"))

  property var daemonState: Model.disabled()
  property bool loaded: false
  readonly property string phase: Model.phase(daemonState)
  readonly property var prompt: Model.prompt(daemonState)
  readonly property string promptKey: prompt ? prompt.ip + "/" + prompt.kind : ""
  readonly property var deviceRows: Model.deviceRows(daemonState.devices)
  readonly property int cursorRows: Model.cursorRows(phase, deviceRows)

  // What the switch was last asked for, until a state poll started after
  // systemd finished shows the outcome. null when nothing is in flight.
  property var pendingEnabled: null
  property int serviceActionsDone: 0
  readonly property bool switchOn: pendingEnabled !== null ? pendingEnabled : daemonState.enabled

  // The unpaired receiver whose row is asking "Pair first?".
  property string confirmIp: ""
  // Set by this instance's own connect, so only the widget that started a
  // connection pops its panel back open for a code or an error, not the one
  // on every monitor.
  property string initiatedIp: ""
  property string actionError: ""

  property bool cursorActive: false
  // -1 is the on/off switch, rows below it count from 0.
  property int rowIndex: -1

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Commons.Color.accent)

  readonly property string errorText: actionError !== "" ? actionError : daemonState.error

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function refresh() {
    if (stateProc.running) stateProc.again = true
    else stateProc.running = true
  }

  function setService(on) {
    if (pendingEnabled !== null) return
    actionError = ""
    pendingEnabled = on
    serviceProc.command = ["bash", ctlPath, on ? "enable" : "disable"]
    serviceProc.running = true
  }

  function run(args) {
    actionError = ""
    actionProc.command = ["bash", ctlPath].concat(args)
    actionProc.running = true
  }

  function connectTo(device) {
    if (!device || phase !== "idle") return
    if (!device.paired && confirmIp !== device.ip) {
      confirmIp = device.ip
      return
    }
    confirmIp = ""
    initiatedIp = device.ip
    run(["connect", device.ip])
    closeForPicker()
  }

  function submitCode(code) {
    if (!prompt || !Model.codeValid(prompt.kind, code)) return
    actionError = ""
    codeProc.secret = code
    codeProc.command = ["bash", ctlPath, "code", prompt.ip]
    codeProc.running = true
    closeForPicker()
  }

  // doubletake asks the portal for the screen next, and Omarchy's share
  // picker is a window of its own that the open panel would cover and keep
  // the keyboard from.
  function closeForPicker() {
    close()
  }

  function showActionError(text) {
    var error = Model.replyError(text)
    if (error === "") return
    open()
    actionError = error
  }

  function stop() {
    initiatedIp = ""
    run(["stop"])
  }

  function moveCursor(dy) {
    rowIndex = Model.moveCursor(rowIndex, dy, cursorRows)
  }

  function activateCursor() {
    if (rowIndex < 0) setService(!switchOn)
    else if (phase === "sharing") stop()
    else if (phase === "idle" && rowIndex < deviceRows.length) connectTo(deviceRows[rowIndex].device)
  }

  onCursorRowsChanged: rowIndex = Model.moveCursor(rowIndex, 0, cursorRows)

  onPhaseChanged: if (phase !== "idle") confirmIp = ""

  // Not in onPhaseChanged: prompt may not have re-evaluated yet when phase
  // changes, and promptKey is derived from it.
  onPromptKeyChanged: if (prompt && prompt.ip === initiatedIp) open()

  // A wrong code or a failed setup ends the stream with only this error left.
  readonly property string daemonError: daemonState.error
  onDaemonErrorChanged: if (Model.errorConcerns(daemonError, initiatedIp)) open()

  onOpenedChanged: if (opened) {
    cursorActive = false
    rowIndex = cursorRows > 0 ? 0 : -1
    confirmIp = ""
    actionError = ""
    refresh()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: stateProc
    property string lastText: ""
    // A refresh asked for mid-poll runs once more after it, so an action's
    // outcome is never read from a poll that started before the action.
    property bool again: false
    property int startedAfter: 0
    command: ["bash", root.ctlPath, "state"]
    onStarted: startedAfter = root.serviceActionsDone
    onRunningChanged: if (!running && again) {
      again = false
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      // Unchanged polls keep the old objects, so the rows are not rebuilt
      // under the mouse every tick.
      onStreamFinished: {
        if (root.pendingEnabled !== null && !serviceProc.running && stateProc.startedAfter === root.serviceActionsDone)
          root.pendingEnabled = null
        if (root.loaded && text === stateProc.lastText) return
        stateProc.lastText = text
        root.daemonState = Model.parseState(text)
        root.loaded = true
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.showActionError(text)
        root.refresh()
      }
    }
  }

  Process {
    id: serviceProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.serviceActionsDone += 1
        root.showActionError(text)
        root.refresh()
      }
    }
  }

  // The code goes over stdin, never into this process's argv.
  Process {
    id: codeProc
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.showActionError(text)
        root.refresh()
      }
    }
  }

  // Fast while something is moving or someone is looking, slow otherwise, and
  // slowest while switched off, when a poll only asks systemd.
  Timer {
    interval: root.opened || root.phase === "credential" || root.phase === "sharing" ? 1500
      : root.phase === "disabled" ? 30000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.GLYPH
    active: root.phase === "sharing" || root.phase === "credential"
    dimmed: root.loaded && (root.phase === "disabled" || root.phase === "offline")
    tooltipText: Model.tooltip(root.daemonState, strings)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.setService(!root.switchOn)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // The code field takes the keys while a receiver waits for its code.
    focusTarget: panel.loadedContent && root.phase === "credential" ? panel.loadedContent.codeField : panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias codeField: codeField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: codeField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive || root.phase === "sharing") root.activateCursor()
      onCloseRequested: {
        if (root.confirmIp !== "") root.confirmIp = ""
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if ((t === "s" || t === "S") && root.phase === "sharing") root.stop()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        PanelHero {
          id: hero
          width: parent.width
          title: strings.t("title")
          meta: Model.heroStatus(root.daemonState, strings)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.phase === "disabled" || root.phase === "offline" ? 0.5 : 1.0
          iconComponent: Component {
            Text {
              text: Model.GLYPH
              textFormat: Text.PlainText
              color: hero.foreground
              font.family: hero.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: serviceSwitch
              checked: root.switchOn
              busy: root.pendingEnabled !== null
              hasCursor: root.cursorActive && root.rowIndex < 0
              foreground: hero.foreground
              onHovered: function(on) {
                if (!on) return
                root.cursorActive = true
                root.rowIndex = -1
              }
              onToggled: root.setService(!root.switchOn)

              PanelToolTip {
                visible: serviceSwitch.containsMouse
                text: strings.t(root.switchOn ? "toggle.off" : "toggle.on")
                fontFamily: root.fontFamily
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Text {
          visible: root.errorText !== ""
          width: parent.width
          text: root.errorText
          textFormat: Text.PlainText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          visible: root.phase === "offline" || root.phase === "disabled"
          width: parent.width
          text: strings.t(root.phase === "disabled" ? "disabled.hint" : "offline.hint")
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // ---------- A receiver asks for its PIN or password ----------
        Column {
          visible: root.phase === "credential"
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: root.prompt
              ? Model.format(strings.t(root.prompt.kind === "password" ? "prompt.password" : "prompt.pin"), [root.prompt.name])
              : ""
            textFormat: Text.PlainText
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          TextField {
            id: codeField
            width: parent.width
            password: root.prompt !== null && root.prompt.kind === "password"
            maximumLength: password ? 32767 : Model.PIN_LENGTH
            foreground: root.foreground
            onAccepted: root.submitCode(text)
            Keys.onEscapePressed: root.stop()
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: strings.t("prompt.cancel")
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.stop()
            }

            Button {
              text: strings.t("prompt.submit")
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: root.prompt !== null && Model.codeValid(root.prompt.kind, codeField.text)
              onClicked: root.submitCode(codeField.text)
            }
          }

          // A fresh prompt starts empty and focused; the receiver shows a new
          // code after every failed attempt anyway.
          Connections {
            target: root
            function onPromptKeyChanged() {
              codeField.text = ""
              if (root.prompt) Qt.callLater(function() { codeField.forceActiveFocus() })
            }
          }
        }

        // ---------- Sharing: what is live, and one Stop ----------
        Column {
          visible: root.phase === "sharing"
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: strings.t("section.sharing")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.phase === "sharing" ? root.daemonState.streams : []

            DeviceLine {
              required property var modelData
              width: parent.width
              name: modelData.name
              detail: Model.streamStatus(modelData, strings)
              live: modelData.state === "streaming"
            }
          }

          Button {
            text: strings.t("action.stop")
            iconText: "󰓛" // nf-md-stop
            foreground: root.foreground
            fontFamily: root.fontFamily
            hasCursor: root.cursorActive && root.rowIndex === 0
            onClicked: root.stop()
          }
        }

        // ---------- Idle: pick a receiver ----------
        Column {
          visible: root.phase === "idle"
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: root.deviceRows.length === 0
            width: parent.width
            text: strings.t("empty.searching")
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.phase === "idle" ? root.deviceRows : []

            Column {
              id: entry
              required property var modelData
              required property int index
              readonly property string section: Model.sectionTitle(root.deviceRows, index)

              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                visible: entry.section !== ""
                text: entry.section !== "" ? strings.t("section." + entry.section) : ""
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              DeviceRow {
                width: parent.width
                device: entry.modelData.device
                rowIndex: entry.index
              }
            }
          }
        }
      }
    }
  }

  component DeviceLine: Item {
    id: line
    property string name: ""
    property string detail: ""
    property bool live: false
    property bool paired: true

    implicitHeight: Math.max(lineIcon.implicitHeight, lineText.implicitHeight)

    Text {
      id: lineIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: line.paired ? "󰕼" : "󰕽" // nf-md-television, nf-md-television-off
      textFormat: Text.PlainText
      color: line.live ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }

    Column {
      id: lineText
      anchors.left: lineIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        text: line.name
        textFormat: Text.PlainText
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        visible: line.detail !== ""
        width: parent.width
        text: line.detail
        textFormat: Text.PlainText
        color: line.live ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  component DeviceRow: CursorSurface {
    id: row
    required property var device
    required property int rowIndex
    readonly property bool confirming: root.confirmIp === device.ip

    hasCursor: root.cursorActive && root.rowIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: rowColumn.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) {
        root.cursorActive = true
        root.rowIndex = row.rowIndex
      }
      onClicked: root.connectTo(row.device)
    }

    Column {
      id: rowColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      DeviceLine {
        width: parent.width
        name: row.device.name
        detail: row.confirming ? strings.t("device.pairQuestion") : row.device.model
        paired: row.device.paired
        live: row.confirming
      }

      Button {
        visible: row.confirming
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        text: strings.t("device.pair")
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.connectTo(row.device)
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && !row.confirming
      text: row.device.paired ? strings.t("device.connect") : strings.t("device.pair")
      fontFamily: root.fontFamily
    }
  }
}
