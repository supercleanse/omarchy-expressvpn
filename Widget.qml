import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// ExpressVPN in the bar, driven headlessly through `expressvpnctl` (the
// daemon runs as expressvpn-service with background mode enabled, so the
// ExpressVPN GUI is never needed).
//
// Live state comes from a long-running `expressvpnctl monitor
// connectionstate`, restarted with backoff whenever it exits. A light
// `status` poll detects login state and an unreachable daemon (one-shot
// commands time out when the service is down; the monitor just hangs), and a
// small info poll reads region, smart region, public IP and VPN IP.
Panel {
  id: root
  moduleName: "supercleanse.expressvpn"
  ipcTarget: "supercleanse.expressvpn"
  manageIpc: false

  // ------------------------------------------------------------ config
  // ctlPath is a development hook (see dev/fake-expressvpnctl.sh); leave it
  // unset in normal use.
  readonly property string ctl: String(setting("ctlPath", "/usr/bin/expressvpnctl"))
  readonly property int refreshSec: Math.max(15, Math.min(3600, Number(setting("refreshIntervalSec", 60)) || 60))
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/supercleanse-expressvpn"
  readonly property string configPath: configDir + "/config.json"
  readonly property string loginScript: decodeURIComponent(String(Qt.resolvedUrl("login.sh")).replace(/^file:\/\//, ""))

  // ------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color barDim: Qt.darker(barFg, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------ daemon state
  property string vpnState: ""          // one of Model.STATES, "" until known
  property bool serviceDown: false
  property bool needsLogin: false
  property string region: ""
  property string smartRegion: ""
  property string pubIp: ""
  property string vpnIp: ""
  property string networkLock: ""
  property var regions: []
  property var favorites: []
  property var configObj: ({})

  readonly property string kind: Model.kindFor(vpnState, serviceDown, needsLogin)
  readonly property bool engaged: Model.isEngaged(vpnState)
  readonly property bool usable: !serviceDown && !needsLogin
  readonly property string networkLockText: Model.networkLockLabel(vpnState, networkLock)

  // ------------------------------------------------------------ ui state
  property string pendingRegion: ""     // optimistic selection until the daemon agrees
  readonly property string shownRegion: pendingRegion !== "" ? pendingRegion : region
  property string actionLabel: ""       // what the running action is doing
  property string actionError: ""
  property string loginError: ""
  property string loginNote: ""
  property bool confirmLogout: false
  property string query: ""
  property int cursor: -1
  property string _loginCode: ""        // lives only until written to the helper's stdin
  property double openedAtMs: 0

  // A panel opened by keybinding or IPC can appear under the pointer while a
  // click meant for another window is on its way. Ignore clicks on anything
  // that acts for a moment after opening.
  function settled() { return Date.now() - openedAtMs > 600 }

  // Monitor restart bookkeeping.
  property int monitorFailures: 0
  property double monitorStartedMs: 0
  property bool monitorWanted: true

  readonly property bool busy: actionProc.running || loginProc.running

  readonly property color stateColor: {
    switch (kind) {
    case "connected": return accent
    case "transition": return foreground
    case "interrupted":
    case "serviceDown":
    case "login": return urgent
    }
    return dim
  }
  readonly property color barStateColor: {
    switch (kind) {
    case "connected": return accent
    case "transition": return barFg
    case "interrupted":
    case "serviceDown":
    case "login": return urgent
    }
    return barDim
  }

  // Rows for the location list: section headers plus region rows. Region
  // rows carry `idx`, their position in the keyboard cursor order.
  readonly property var listRows: {
    var rows = []
    var n = 0
    var q = query.trim()
    var smartEntry = { slug: "smart", name: "Smart location", sub: smartRegion ? Model.prettyRegion(smartRegion) : "" }
    if (q === "") {
      rows.push({ type: "region", slug: "smart", name: smartEntry.name, sub: smartEntry.sub, idx: n++ })
      if (favorites.length > 0) {
        rows.push({ type: "header", name: "FAVORITES" })
        for (var f = 0; f < favorites.length; f++)
          rows.push({ type: "region", slug: favorites[f], name: Model.prettyRegion(favorites[f]), sub: "", idx: n++ })
      }
      if (regions.length > 0) {
        rows.push({ type: "header", name: "ALL LOCATIONS" })
        for (var i = 0; i < regions.length; i++)
          rows.push({ type: "region", slug: regions[i].slug, name: regions[i].name, sub: "", idx: n++ })
      }
    } else {
      if (Model.matches(smartEntry, q) || Model.matches({ name: "smart", slug: "smart" }, q))
        rows.push({ type: "region", slug: "smart", name: smartEntry.name, sub: smartEntry.sub, idx: n++ })
      for (var j = 0; j < regions.length; j++)
        if (Model.matches(regions[j], q))
          rows.push({ type: "region", slug: regions[j].slug, name: regions[j].name, sub: "", idx: n++ })
    }
    return rows
  }
  readonly property int selectableCount: {
    var c = 0
    for (var i = 0; i < listRows.length; i++) if (listRows[i].type === "region") c++
    return c
  }
  onListRowsChanged: if (cursor >= selectableCount) cursor = selectableCount - 1

  // ------------------------------------------------------------ helpers
  function isFavorite(slug) { return favorites.indexOf(slug) !== -1 }

  function toggleFavorite(slug) {
    if (!slug || slug === "smart" || !settled()) return
    var next = favorites.slice()
    var at = next.indexOf(slug)
    if (at === -1) next.push(slug)
    else next.splice(at, 1)
    favorites = next
    var obj = Object.assign({}, configObj)
    obj.favorites = next
    configObj = obj
    configFile.setText(JSON.stringify(obj, null, 2) + "\n")
  }

  function applyConfig(text) {
    var obj = {}
    try { obj = JSON.parse(String(text || "{}")) || {} } catch (e) { obj = {} }
    if (typeof obj !== "object" || Array.isArray(obj)) obj = {}
    var favs = []
    var raw = obj.favorites instanceof Array ? obj.favorites : []
    for (var i = 0; i < raw.length; i++) {
      var s = String(raw[i] || "").trim()
      if (s !== "" && s !== "smart" && favs.indexOf(s) === -1) favs.push(s)
    }
    configObj = obj
    favorites = favs
  }

  function regionAt(idx) {
    for (var i = 0; i < listRows.length; i++)
      if (listRows[i].type === "region" && listRows[i].idx === idx) return listRows[i]
    return null
  }

  function moveCursor(delta) {
    if (selectableCount === 0) return
    if (cursor < 0) cursor = delta > 0 ? 0 : selectableCount - 1
    else cursor = Math.max(0, Math.min(selectableCount - 1, cursor + delta))
  }

  function ensureVisible(item) {
    if (!item || !listFlick) return
    var p = item.mapToItem(listColumn, 0, 0)
    if (p.y < listFlick.contentY) listFlick.contentY = p.y
    else if (p.y + item.height > listFlick.contentY + listFlick.height)
      listFlick.contentY = Math.min(listFlick.contentHeight - listFlick.height, p.y + item.height - listFlick.height)
  }

  // Enter acts only on a row the user has walked to with the arrow keys.
  // The panel takes keyboard focus when it opens, so stray typing plus Enter
  // must never switch (or reconnect) the VPN on its own.
  function activateCursor() {
    if (cursor < 0) return
    var row = regionAt(cursor)
    if (row) chooseRegion(row.slug)
  }

  function runAction(args, label) {
    if (actionProc.running) return false
    actionError = ""
    actionLabel = label || ""
    actionProc.command = [root.ctl, "-t", "30"].concat(args)
    actionProc.running = true
    return true
  }

  function toggleConnection() {
    if (!usable || busy || !settled()) return
    if (engaged) runAction(["disconnect"], "Disconnecting…")
    else runAction(["connect"], "Connecting…")
  }

  // Connected (or on the way): reconnect to the new location. Disconnected:
  // just make it the default for the next connect.
  function chooseRegion(slug) {
    if (!usable || busy || !slug || !settled()) return
    if (slug === shownRegion && !engaged) return
    pendingRegion = slug
    if (engaged) runAction(["connect", slug], "Switching to " + Model.prettyRegion(slug) + "…")
    else runAction(["set", "region", slug], "")
  }

  function submitLogin() {
    var code = loginField.text.replace(/\s+/g, "")
    if (code === "" || loginProc.running) return
    loginError = ""
    loginNote = ""
    _loginCode = code
    loginField.text = ""
    loginProc.running = true
  }

  function logout() {
    if (!settled()) return
    confirmLogout = false
    runAction(["logout"], "Logging out…")
  }

  function refreshStatus() { if (!statusProc.running) statusProc.running = true }
  function refreshInfo() { if (!infoProc.running) infoProc.running = true; else infoAgain.restart() }
  function refreshRegions() { if (!regionsProc.running) regionsProc.running = true }
  function refreshAll() { refreshStatus(); refreshInfo() }

  function restartMonitor() {
    monitorFailures = 0
    if (monitorProc.running) monitorProc.running = false  // onExited schedules the restart
    else monitorRestart.restart()
  }

  function handleMonitorLine(line) {
    var st = Model.normalizeState(line)
    if (st === "") return
    var changed = st !== vpnState
    vpnState = st
    if (changed) {
      // IPs and the region settle a moment after the state flips.
      infoSoon.restart()
      infoLater.restart()
    }
  }

  function applyStatus(exitCode, out, err) {
    var text = String(out || "") + "\n" + String(err || "")
    var parsed = Model.parseStatus(out)
    var wasDown = serviceDown
    if (parsed.notLoggedIn || Model.looksNotLoggedIn(err)) {
      serviceDown = false
      needsLogin = true
    } else if (exitCode === 0 && parsed.state !== "") {
      serviceDown = false
      needsLogin = false
      vpnState = parsed.state
      if (parsed.location !== "") region = parsed.location
      networkLock = parsed.networkLock
    } else {
      // A timeout (exit 2) or any unexpected failure: the daemon is not
      // answering. The monitor hangs silently in that case, so this poll is
      // the only thing that notices.
      serviceDown = true
      if (!Model.looksServiceDown(text)) console.warn("supercleanse.expressvpn status:", Model.oneLine(text))
    }
    if (wasDown && !serviceDown) {
      restartMonitor()
      refreshInfo()
    }
    if (pendingRegion !== "" && pendingRegion === region) pendingRegion = ""
  }

  function applyInfo(out) {
    var lines = String(out || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(\w+)=(.*)$/)
      if (!m) continue
      var v = m[2].trim()
      if (m[1] === "region" && v !== "" && !/^unknown$/i.test(v) && !/timed out/i.test(v)) region = v
      else if (m[1] === "smart" && v !== "" && !/timed out/i.test(v)) smartRegion = /^unknown$/i.test(v) ? "" : v
      else if (m[1] === "pubip") pubIp = Model.cleanIp(v)
      else if (m[1] === "vpnip") vpnIp = Model.cleanIp(v)
    }
    if (pendingRegion !== "" && pendingRegion === region) pendingRegion = ""
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    openedAtMs = Date.now()
    query = ""
    cursor = -1
    confirmLogout = false
    actionError = ""
    if (searchField) searchField.text = ""
    if (listFlick) listFlick.contentY = 0
    refreshAll()
    if (regions.length === 0) refreshRegions()
  }

  // A different ctl binary (the ctlPath setting) needs a fresh monitor, and
  // a poll started against the old binary may still be in flight.
  onCtlChanged: {
    regions = []
    smartRegion = ""
    restartMonitor()
    ctlSettle.restart()
  }

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", root.configDir])
    monitorRestart.interval = 200
    monitorRestart.start()
  }

  // ------------------------------------------------------------ processes
  Process {
    id: monitorProc
    command: [root.ctl, "monitor", "connectionstate"]
    running: false
    stdout: SplitParser { onRead: function(line) { root.handleMonitorLine(line) } }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("supercleanse.expressvpn monitor:", Model.oneLine(text))
    }
    onStarted: root.monitorStartedMs = Date.now()
    onExited: function(exitCode) {
      if (!root.monitorWanted) return
      // A monitor that ran for a while and then ended (daemon restart) gets a
      // fast retry; one that keeps dying quickly backs off up to 30 seconds.
      if (Date.now() - root.monitorStartedMs > 60000) root.monitorFailures = 0
      monitorRestart.interval = Math.min(30000, 1000 * Math.pow(2, root.monitorFailures))
      root.monitorFailures = Math.min(root.monitorFailures + 1, 5)
      monitorRestart.restart()
      root.refreshStatus()
    }
  }

  Timer {
    id: monitorRestart
    repeat: false
    onTriggered: if (root.monitorWanted && !monitorProc.running) monitorProc.running = true
  }

  Process {
    id: statusProc
    command: [root.ctl, "-t", "8", "status"]
    running: false
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    stderr: StdioCollector { id: statusErr; waitForEnd: true }
    onExited: function(exitCode) { root.applyStatus(exitCode, statusOut.text, statusErr.text) }
  }

  Process {
    id: infoProc
    // One process, four quick reads. `ctl` is passed as $1, never spliced
    // into the script text.
    command: ["bash", "-c",
      "for k in region smart pubip vpnip; do printf '%s=' \"$k\"; \"$1\" -t 8 get \"$k\" 2>&1 | head -n 1; done",
      "supercleanse-expressvpn-info", root.ctl]
    running: false
    stdout: StdioCollector { id: infoOut; waitForEnd: true }
    onExited: root.applyInfo(infoOut.text)
  }

  Process {
    id: regionsProc
    command: [root.ctl, "-t", "10", "get", "regions"]
    running: false
    stdout: StdioCollector { id: regionsOut; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) return
      var list = Model.parseRegions(regionsOut.text)
      if (list.length > 0) root.regions = list
    }
  }

  Process {
    id: actionProc
    running: false
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var msg = Model.oneLine(String(actionErr.text || "").trim() || String(actionOut.text || "").trim())
      if (exitCode !== 0) {
        root.pendingRegion = ""
        root.actionError = msg !== "" ? msg : "ExpressVPN command failed"
        if (Model.looksNotLoggedIn(msg)) root.needsLogin = true
      }
      root.actionLabel = ""
      root.refreshAll()
      infoLater.restart()
    }
  }

  Process {
    id: loginProc
    command: ["bash", root.loginScript, root.ctl]
    running: false
    stdinEnabled: true
    onStarted: {
      write(root._loginCode + "\n")
      root._loginCode = ""
      stdinEnabled = false
    }
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    stderr: StdioCollector { id: loginErr; waitForEnd: true }
    onExited: function(exitCode) {
      root._loginCode = ""
      stdinEnabled = true
      var msg = Model.oneLine(String(loginErr.text || "").trim() || String(loginOut.text || "").trim())
      if (exitCode !== 0) root.loginError = msg !== "" ? msg : "Login failed"
      else root.loginNote = msg
      root.refreshAll()
    }
  }

  Timer {
    // Status poll: slow when healthy, quick while the daemon is unreachable
    // so the widget recovers soon after the service comes back.
    interval: root.serviceDown ? 5000 : root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    interval: root.refreshSec * 1000
    running: !root.serviceDown
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshInfo()
  }

  Timer { id: ctlSettle; interval: 1500; onTriggered: { root.refreshAll(); if (root.opened) root.refreshRegions() } }
  Timer { id: infoSoon; interval: 1500; onTriggered: root.refreshInfo() }
  Timer { id: infoLater; interval: 6000; onTriggered: root.refreshInfo() }
  Timer { id: infoAgain; interval: 800; onTriggered: root.refreshInfo() }

  // Pulse for Connecting / Reconnecting / Disconnecting.
  property real pulse: 1.0
  SequentialAnimation on pulse {
    running: root.kind === "transition"
    loops: Animation.Infinite
    NumberAnimation { from: 1.0; to: 0.3; duration: 700; easing.type: Easing.InOutSine }
    NumberAnimation { from: 0.3; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) root.pulse = 1.0
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.applyConfig("{}")
  }

  // An IPC target reaches only one of the per-monitor copies, so route the
  // call ourselves: an open copy wins (so toggle closes it), otherwise the
  // copy on the monitor Hyprland has focused.
  function copies() {
    var items = root.bar && typeof root.bar.moduleWidgets === "function" ? root.bar.moduleWidgets(root.moduleName) : []
    return items && items.length > 0 ? items : [root]
  }

  function screenNameOf(item) {
    var w = item && item.QsWindow ? item.QsWindow.window : null
    return w && w.screen ? String(w.screen.name || "") : ""
  }

  function focusedCopy() {
    var items = copies()
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened) return items[i]
    for (var j = 0; j < items.length; j++) if (items[j] && screenNameOf(items[j]) === focused) return items[j]
    return root
  }

  function anyOpen() {
    var items = copies()
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened) return true
    return false
  }

  function closeAll() {
    var items = copies()
    for (var i = 0; i < items.length; i++) if (items[i] && typeof items[i].close === "function") items[i].close()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.focusedCopy().open() }
    function close(): void { root.closeAll() }
    function show(): void { root.focusedCopy().open() }
    function hide(): void { root.closeAll() }
    function toggle(): void {
      if (root.anyOpen()) root.closeAll()
      else root.focusedCopy().open()
    }
    function refresh(): string {
      var items = root.copies()
      for (var i = 0; i < items.length; i++) if (items[i] && typeof items[i].refreshAll === "function") items[i].refreshAll()
      return "ok"
    }
    function status(): string { return Model.stateLabel(root.vpnState, root.serviceDown, root.needsLogin) }
  }

  // ------------------------------------------------------------ bar item
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    labelVisible: false
    hasVisualContent: true
    tooltipText: Model.tooltip(root.vpnState, root.serviceDown, root.needsLogin, root.region, root.vpnIp, root.pubIp)
    fixedWidth: vertical ? -1 : Style.bar.iconSlot
    fixedHeight: vertical ? Style.bar.iconSlot : -1

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refreshAll()
      else root.toggle()
    }

    Item {
      anchors.centerIn: parent
      width: Style.bar.iconCanvas
      height: Style.bar.iconCanvas

      OpticalGlyph {
        anchors.fill: parent
        text: Model.glyph(root.kind)
        fontFamily: root.fontFamily
        fontSize: Style.bar.iconFont
        color: root.barStateColor
        opacity: root.kind === "transition" ? root.pulse : 1.0
      }
    }
  }

  // ------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.needsLogin && !root.serviceDown ? loginField : (root.usable ? searchField : navSink)
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    FocusScope {
      id: keyRoot
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel(event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
        }
      }

      Item { id: navSink; width: 0; height: 0; focus: true }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Header ----------
        PanelHero {
          id: hero
          width: parent.width
          title: Model.stateLabel(root.vpnState, root.serviceDown, root.needsLogin)
          meta: root.serviceDown ? "expressvpn-service is not answering"
            : (root.needsLogin ? "Log in to use ExpressVPN" : (root.shownRegion ? Model.prettyRegion(root.shownRegion) : "ExpressVPN"))
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: Model.glyph(root.kind)
              color: root.stateColor
              opacity: root.kind === "transition" ? root.pulse : 1.0
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            PanelActionButton {
              iconText: Model.glyph("refresh")
              tooltipText: "Refresh"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !statusProc.running
              onClicked: { root.refreshAll(); if (root.regions.length === 0) root.refreshRegions() }
            }
          }
        }

        // ---------- Details ----------
        Grid {
          visible: root.usable
          width: parent.width
          columns: 2
          columnSpacing: Style.space(12)
          rowSpacing: Style.space(3)

          // `get pubip` keeps returning the pre-VPN (home) address while the
          // tunnel is up, so it is labeled Public IP only while disconnected.
          // Engaged, the VPN IP comes first and the home IP is shown dimmed.
          DetailKey { visible: !root.engaged; text: "PUBLIC IP" }
          DetailValue { visible: !root.engaged; text: root.pubIp || "—" }
          DetailKey { visible: root.engaged; text: "VPN IP" }
          DetailValue { visible: root.engaged; text: root.vpnIp || "—" }
          DetailKey { visible: root.engaged && root.pubIp !== ""; text: "HOME IP" }
          DetailValue {
            visible: root.engaged && root.pubIp !== ""
            text: root.pubIp + "  (hidden)"
            color: root.dim
          }
          DetailKey { visible: root.networkLockText !== ""; text: "NETWORK LOCK" }
          DetailValue { visible: root.networkLockText !== ""; text: root.networkLockText }
        }

        // ---------- Connect / Disconnect ----------
        Button {
          visible: root.usable
          width: parent.width
          text: actionProc.running && root.actionLabel !== "" ? root.actionLabel
            : (root.vpnState === "Connecting" ? "Cancel"
            : (root.engaged ? "Disconnect" : "Connect"))
          iconText: Model.glyph(root.engaged ? "disconnected" : "connected")
          bordered: true
          selected: root.engaged
          enabled: !root.busy && root.vpnState !== "Disconnecting"
          foreground: root.foreground
          fontFamily: root.fontFamily
          fontSize: Style.font.subtitle
          iconSize: Style.font.heading
          verticalPadding: Style.space(9)
          onClicked: root.toggleConnection()
        }

        Text {
          visible: root.actionError !== ""
          width: parent.width
          textFormat: Text.PlainText
          text: root.actionError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // ---------- Service not running ----------
        Column {
          visible: root.serviceDown
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "The ExpressVPN daemon isn't answering. Start it with:"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "sudo systemctl start expressvpn-service"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WrapAnywhere
          }
          Button {
            text: statusProc.running ? "Checking…" : "Retry"
            iconText: Model.glyph("refresh")
            bordered: true
            enabled: !statusProc.running
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            onClicked: root.refreshAll()
          }
        }

        // ---------- Login ----------
        Column {
          visible: root.needsLogin && !root.serviceDown
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator { foreground: root.foreground }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "Paste your activation code from expressvpn.com/setup to log in."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(loginField.implicitHeight, loginButton.implicitHeight)

            TextField {
              id: loginField
              anchors.left: parent.left
              anchors.right: loginButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              password: true
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "Activation code"
              enabled: !loginProc.running
              onAccepted: root.submitLogin()
              Keys.onEscapePressed: root.close()
            }

            Button {
              id: loginButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: loginProc.running ? "Logging in…" : "Log in"
              iconText: Model.glyph("key")
              bordered: true
              enabled: !loginProc.running && loginField.text.trim() !== ""
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.bodySmall
              verticalPadding: Style.spacing.inputPaddingY - 1
              onClicked: root.submitLogin()
            }
          }

          Text {
            visible: root.loginError !== "" || root.loginNote !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.loginError !== "" ? root.loginError : root.loginNote
            color: root.loginError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Location picker ----------
        PanelSeparator { visible: root.usable; foreground: root.foreground }

        Column {
          visible: root.usable
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "LOCATION"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          TextField {
            id: searchField
            width: parent.width
            foreground: root.foreground
            font.family: root.fontFamily
            placeholderText: "Search locations…"
            onTextChanged: { root.query = text; root.cursor = -1; if (listFlick) listFlick.contentY = 0 }
            onAccepted: root.activateCursor()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) { root.moveCursor(1); event.accepted = true }
              else if (event.key === Qt.Key_Up) { root.moveCursor(-1); event.accepted = true }
              else if (event.key === Qt.Key_Escape) {
                if (text !== "") text = ""
                else root.close()
                event.accepted = true
              }
            }
          }

          Flickable {
            id: listFlick
            width: parent.width
            height: Math.min(listColumn.implicitHeight, Style.space(300))
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: listColumn
              width: listFlick.width - (listFlick.interactive ? Style.space(8) : 0)
              spacing: Style.space(1)

              Repeater {
                model: root.listRows
                delegate: Loader {
                  required property var modelData
                  width: listColumn.width
                  sourceComponent: modelData.type === "header" ? headerDelegate : rowDelegate
                  property var entry: modelData
                }
              }

              Text {
                visible: root.query.trim() !== "" && root.selectableCount === 0
                width: listColumn.width
                textFormat: Text.PlainText
                text: "No locations match “" + root.query.trim() + "”"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                topPadding: Style.space(4)
                leftPadding: Style.space(6)
              }

              Text {
                visible: root.query.trim() === "" && root.regions.length === 0
                width: listColumn.width
                textFormat: Text.PlainText
                text: regionsProc.running ? "Loading locations…" : "Locations unavailable"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                topPadding: Style.space(4)
                leftPadding: Style.space(6)
              }
            }
          }
        }

        // ---------- Footer: log out ----------
        Item {
          visible: !root.serviceDown && !root.needsLogin
          width: parent.width
          implicitHeight: root.confirmLogout ? confirmRow.implicitHeight : logoutLink.implicitHeight

          Text {
            id: logoutLink
            visible: !root.confirmLogout
            anchors.left: parent.left
            textFormat: Text.PlainText
            text: Model.glyph("logout") + "  Log out"
            color: logoutMouse.containsMouse ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.underline: logoutMouse.containsMouse
            MouseArea {
              id: logoutMouse
              anchors.fill: parent
              anchors.margins: -Style.space(3)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              enabled: !root.busy
              onClicked: if (root.settled()) root.confirmLogout = true
            }
          }

          Row {
            id: confirmRow
            visible: root.confirmLogout
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.engaged ? "Log out? This also disconnects." : "Log out of ExpressVPN?"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            Button {
              text: "Log out"
              bordered: true
              foreground: root.urgent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              verticalPadding: Style.space(3)
              horizontalPadding: Style.space(8)
              onClicked: root.logout()
            }
            Button {
              text: "Cancel"
              bordered: true
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              verticalPadding: Style.space(3)
              horizontalPadding: Style.space(8)
              onClicked: root.confirmLogout = false
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  Component {
    id: headerDelegate
    Item {
      implicitHeight: hdr.implicitHeight + Style.space(10)
      PanelSectionHeader {
        id: hdr
        anchors.left: parent.left
        anchors.leftMargin: Style.space(4)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(3)
        text: parent.parent ? parent.parent.entry.name : ""
        foreground: root.dim
        fontFamily: root.fontFamily
      }
    }
  }

  Component {
    id: rowDelegate
    RegionRow { entry: parent ? parent.entry : null }
  }

  component DetailKey: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.1
  }

  component DetailValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component RegionRow: CursorSurface {
    id: rr
    property var entry: null
    readonly property string slug: entry ? String(entry.slug || "") : ""
    readonly property bool isSmart: slug === "smart"
    readonly property bool isCurrent: slug !== "" && slug === root.shownRegion
    readonly property bool fav: root.isFavorite(slug)
    readonly property bool keyed: !!entry && entry.idx === root.cursor
    readonly property bool switching: actionProc.running && root.pendingRegion === slug

    hasCursor: rowHover.hovered || keyed
    current: isCurrent
    foreground: root.foreground
    implicitHeight: Math.max(rowLabels.implicitHeight, starButton.implicitHeight) + Style.space(6)
    onKeyedChanged: if (keyed) root.ensureVisible(rr)

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      enabled: !root.busy
      onClicked: root.chooseRegion(rr.slug)
    }

    Text {
      id: rowGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(18)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: Model.glyph(rr.isSmart ? "smart" : (rr.isCurrent ? "check" : "marker"))
      color: rr.isCurrent ? root.accent : root.dim
      opacity: rr.switching ? root.pulse : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Column {
      id: rowLabels
      anchors.left: rowGlyph.right
      anchors.leftMargin: Style.space(6)
      anchors.right: starButton.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: 0

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: rr.entry ? rr.entry.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: rr.isCurrent
        elide: Text.ElideRight
      }
      Text {
        visible: text !== ""
        width: parent.width
        textFormat: Text.PlainText
        text: rr.entry && rr.entry.sub ? "Now " + rr.entry.sub : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    PanelActionButton {
      id: starButton
      anchors.right: parent.right
      anchors.rightMargin: Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
      size: Math.round(Style.font.body * 1.7)
      visible: !rr.isSmart
      opacity: rr.fav || rowHover.hovered || rr.keyed ? 1.0 : 0.0
      iconText: Model.glyph(rr.fav ? "star" : "starOutline")
      tooltipText: rr.fav ? "Remove from favorites" : "Add to favorites"
      foreground: rr.fav ? root.accent : root.dim
      fontFamily: root.fontFamily
      fontSize: Style.font.bodySmall
      onClicked: root.toggleFavorite(rr.slug)
    }
  }
}
