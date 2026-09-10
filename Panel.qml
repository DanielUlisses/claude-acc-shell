import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standalone bar widget: read-only view of every claude-acc-tracked Claude
// Code account and its rate limits. Talks to `claude-acc` directly via
// bin/claude-acc-roster — no switching, this is a viewer only.
Panel {
  id: root
  moduleName: "claude-acc.usage"
  ipcTarget: "claude-acc.usage"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: home + "/.config/omarchy/plugins/claude-acc.usage"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var accounts: []
  property bool hasLoaded: false
  property string loadError: ""
  property bool binaryMissing: false

  readonly property var activeAccount: {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i] && accounts[i].active) return accounts[i]
    return null
  }

  readonly property real headlinePercent: {
    if (!activeAccount) return -1
    return Math.max(Number(activeAccount.sessionPercent || 0), Number(activeAccount.weeklyPercent || 0))
  }
  readonly property bool alarming: headlinePercent >= 0.9

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function refreshNow() {
    if (!rosterProcess.running) rosterProcess.running = true
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  property int refreshIntervalSec: Math.max(30, Number(setting("refreshIntervalSec", 300)))

  // Stay hidden until the first roster fetch resolves (avoids a startup
  // flash), but once loaded, stay visible even with zero accounts or a
  // load error so that state is reachable by clicking the bar icon.
  visible: hasLoaded
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: rosterProcess
    running: false
    command: ["python3", root.pluginDir + "/bin/claude-acc-roster"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyRoster(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("claude-acc.usage", text.trim())
    }
  }

  function applyRoster(output) {
    try {
      var parsed = JSON.parse(String(output || "{}"))
      root.accounts = Array.isArray(parsed.accounts) ? parsed.accounts : []
      root.loadError = parsed.error ? String(parsed.error) : ""
      root.binaryMissing = !!parsed.binaryMissing
    } catch (e) {
      root.loadError = "Failed to read claude-acc accounts"
      root.accounts = []
      root.binaryMissing = false
    }
    root.hasLoaded = true
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  onOpenedChanged: if (opened) {
    if (panelFlick) panelFlick.contentY = 0
    refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓥"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ---------- Hero: mark · active account ----------
          PanelHero {
            id: hero
            visible: !!root.activeAccount
            width: parent.width
            title: "Claude Code"
            meta: root.activeAccount ? root.activeAccount.email : ""
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                id: heroMark
                width: Style.font.display
                height: Style.font.display

                Image {
                  id: heroMarkImage
                  anchors.fill: parent
                  source: Qt.resolvedUrl("assets/claude.svg")
                  sourceSize.width: Style.font.display * 2
                  sourceSize.height: Style.font.display * 2
                  fillMode: Image.PreserveAspectFit
                }

                Text {
                  anchors.centerIn: parent
                  visible: heroMarkImage.status !== Image.Ready
                  text: button.text
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Text {
            visible: root.accounts.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: root.binaryMissing
              ? "claude-acc isn't installed yet."
              : (root.loadError !== "" ? root.loadError : "No claude-acc accounts yet.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Accounts ----------
          PanelSeparator {
            visible: accountsSection.visible
            foreground: root.foreground
          }

          Column {
            id: accountsSection
            visible: root.accounts.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "ACCOUNTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.accounts

              AccountRow {
                required property var modelData
                width: accountsSection.width
                account: modelData
              }
            }
          }
        }
      }
    }
  }

  // One row per claude-acc-tracked account: name, email, plan, and both
  // rate-limit windows at a glance. Read-only — the active row is picked
  // out with a check and a border, nothing here is clickable.
  component AccountRow: Item {
    id: accountRow
    property var account: null

    readonly property bool active: !!account && account.active === true

    implicitHeight: rowContent.implicitHeight + Style.spacing.md * 2

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: accountRow.active ? root.alpha(root.foreground, 0.08) : root.alpha(root.foreground, 0.03)
      border.width: accountRow.active ? 1 : 0
      border.color: root.alpha(root.foreground, 0.3)
    }

    Column {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.spacing.md
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: (accountRow.active ? "✓ " : "") + (accountRow.account ? accountRow.account.name : "")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: accountRow.active
        elide: Text.ElideRight
      }

      Text {
        readonly property string email: accountRow.account ? String(accountRow.account.email || "") : ""
        readonly property string plan: accountRow.account ? String(accountRow.account.plan || "") : ""
        visible: text !== ""
        width: parent.width
        text: email + (plan !== "" ? " · " + plan : "")
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Text {
        readonly property string err: accountRow.account ? String(accountRow.account.error || "") : ""
        visible: err !== ""
        width: parent.width
        text: err
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      Row {
        visible: !accountRow.account || accountRow.account.error === ""
        width: parent.width
        spacing: Style.spacing.md

        readonly property real halfWidth: (width - spacing) / 2

        Column {
          width: parent.halfWidth
          spacing: Style.space(4)

          Text {
            readonly property real pct: accountRow.account ? Number(accountRow.account.sessionPercent) : -1
            text: "5h · " + (pct >= 0 ? Math.round(pct * 100) + "%" : "—")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Meter {
            width: parent.width
            value: accountRow.account ? Number(accountRow.account.sessionPercent) : -1
            alarming: accountRow.account && Number(accountRow.account.sessionPercent) >= 0.9
          }

          Text {
            readonly property string label: accountRow.account ? String(accountRow.account.sessionResetLabel || "") : ""
            visible: label !== ""
            text: "Resets in " + label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Column {
          width: parent.halfWidth
          spacing: Style.space(4)

          Text {
            readonly property real pct: accountRow.account ? Number(accountRow.account.weeklyPercent) : -1
            text: "7d · " + (pct >= 0 ? Math.round(pct * 100) + "%" : "—")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Meter {
            width: parent.width
            value: accountRow.account ? Number(accountRow.account.weeklyPercent) : -1
            alarming: accountRow.account && Number(accountRow.account.weeklyPercent) >= 0.9
          }

          Text {
            readonly property string label: accountRow.account ? String(accountRow.account.weeklyResetLabel || "") : ""
            visible: label !== ""
            text: "Resets in " + label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }
  }
}
