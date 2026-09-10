import QtQuick
import Quickshell
import Quickshell.Io

// Discovers per-account Claude Code usage records written by
// bin/claude-acc-usage-update (one JSON file per claude-acc account, in
// ~/.local/state/claude-acc-shell/usage) and keeps them fresh. All the real
// work happens in that script and in Omarchy's own omarchy-agent-usage-claude
// collector it shells out to per account; this file only discovers, watches,
// and reshapes the records for Panel.qml.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string pluginDir: home + "/.config/omarchy/plugins/claude-acc.usage"
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/claude-acc-shell/usage"

  // ------------------------------------------------------------- discovery

  property var accountKeys: []
  property var agents: []
  property int dataRevision: 0

  Process {
    id: listProcess
    running: false
    command: ["find", root.usageDir, "-maxdepth", "1", "-name", "*.json", "-printf", "%f\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyListing(text)
    }
  }

  function rescan() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyListing(output) {
    var keys = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") keys.push(name.slice(0, -5))
    }
    keys.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(keys) !== JSON.stringify(accountKeys)) accountKeys = keys
  }

  Instantiator {
    id: agentInstantiator
    model: root.accountKeys

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; only the advising accounts rerun.
  property var retryKeys: []

  Timer {
    id: limitsRetry
    interval: 30000
    repeat: false
    onTriggered: root.runUpdate("limits", root.retryKeys)
  }

  function scheduleLimitsRetry() {
    var advising = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.retryAdvised === true) advising.push(String(record.accountKey))
    }
    retryKeys = advising
    if (advising.length > 0) limitsRetry.restart()
    else limitsRetry.stop()
  }

  Component.onCompleted: rescan()

  // -------------------------------------------------------------- refresh

  property int refreshIntervalSec: Math.max(60, Number(setting("refreshIntervalSec", 900)))
  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate("normal")
  }

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescan()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("claude-acc.usage", text.trim())
    }
  }

  function updateCommand(kind, keys) {
    var command = ["python3", root.pluginDir + "/bin/claude-acc-usage-update"]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    if (keys) for (var i = 0; i < keys.length; i++) command.push(keys[i])
    return command
  }

  function runUpdate(kind, keys) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = updateCommand(kind, keys)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collector reuses its
  // recent scan in this mode.
  function refreshLimits() { runUpdate("limits") }

  // -------------------------------------------------------------- accounts

  // An account earns a place in the panel by having actually produced
  // numbers. With nothing to show, the whole module collapses out of the
  // bar rather than sitting there with an empty account list.
  readonly property var enabledAccounts: {
    var rev = dataRevision
    var result = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record) continue
      var display = displayAccount(record)
      if (accountHasData(display)) result.push(display)
    }
    result.sort(function(a, b) {
      if (a.active !== b.active) return a.active ? -1 : 1
      return a.accountLabel < b.accountLabel ? -1 : (a.accountLabel > b.accountLabel ? 1 : 0)
    })
    return result
  }

  function accountHasData(a) {
    return numberValue(a.totalPrompts) > 0 || numberValue(a.totalSessions) > 0
      || numberValue(a.activeDays) > 0 || numberValue(a.todayPrompts) > 0
      || numberValue(a.todaySessions) > 0 || (a.limits && a.limits.length > 0)
  }

  function displayAccount(record) {
    return {
      accountKey: String(record.accountKey || ""),
      accountLabel: String(record.accountLabel || record.accountKey || ""),
      accountEmail: String(record.accountEmail || ""),
      active: record.active === true,
      ready: record.ready === true,
      usageStatusText: String(record.usageStatusText || ""),
      authHelpText: String(record.authHelpText || ""),
      limits: Array.isArray(record.limits) ? record.limits : [],
      tierLabel: String(record.tierLabel || ""),
      todayPrompts: numberValue(record.todayPrompts),
      todaySessions: numberValue(record.todaySessions),
      todayTotalTokens: numberValue(record.todayTotalTokens),
      todayTokensByModel: record.todayTokensByModel || {},
      recentDays: record.recentDays || [],
      totalPrompts: numberValue(record.totalPrompts),
      totalSessions: numberValue(record.totalSessions),
      activeDays: numberValue(record.activeDays),
      modelUsage: record.modelUsage || {},
      hasPromptStats: record.hasPromptStats !== false
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function numberValue(value) {
    var n = Number(value || 0)
    return isFinite(n) ? Math.round(n) : 0
  }

  // ---------------------------------------------------------------- format

  function formatTokenCount(n) {
    if (n === undefined || n === null) return "0"
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function modelWordCase(word) {
    if (word === "gpt") return "GPT"
    if (word === "deepseek") return "DeepSeek"
    return word.charAt(0).toUpperCase() + word.slice(1)
  }

  // Model ids arrive hyphenated with the version split across segments
  // (`claude-opus-4-8`). Rejoin the numeric run into one version and
  // title-case the words around it.
  function friendlyModelName(id) {
    if (!id) return "Unknown"
    var name = String(id).replace(/^claude-/, "").replace(/-\d{8}$/, "")
    var parts = name.split("-")
    var words = []
    var version = []
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i]
      if (part === "") continue
      if (/^\d/.test(part)) {
        version.push(part)
        continue
      }
      if (version.length > 0) {
        words.push(version.join("."))
        version = []
      }
      words.push(modelWordCase(part))
    }
    if (version.length > 0) words.push(version.join("."))
    return words.length > 0 ? words.join(" ") : "Unknown"
  }
}
