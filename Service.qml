import QtQuick
import Quickshell
import Quickshell.Io
import "Logic.js" as Logic

// Everything that talks to helper/omarcal-helper.
//
// The helper always prints one JSON object and exits 0, so a failure arrives
// as `ok: false` with a code rather than as a crash or empty output. Nothing
// here blocks: a sync that is slow or wedged leaves the last cached events on
// screen and sets `error`, which is the whole reason omarcal does not go
// through Evolution Data Server.
QtObject {
  id: root

  property string account: ""
  property string server: ""
  property var accounts: []
  property var events: []
  property var calendars: []
  property bool loading: false
  // Panel preferences, as `status` last reported them. Empty until the first
  // status lands, which is what settingsLoaded says.
  property var settings: ({})
  property bool settingsLoaded: false
  property double cacheBytes: 0
  property int objectCount: 0
  property bool syncing: false
  property string error: ""
  property double lastSync: 0

  // The window currently loaded, as YYYY-MM-DD. The panel widens this as the
  // viewed month changes.
  property string rangeStart: ""
  property string rangeEnd: ""

  readonly property string helper: decodeURIComponent(
    Qt.resolvedUrl("helper/omarcal-helper").toString().replace(/^file:\/\//, ""))

  signal eventsLoaded()
  signal accountAdded()

  property bool addingAccount: false
  property string addError: ""
  // Only held while the panel is showing it, and dropped the moment it stops.
  property string revealedPassword: ""

  function parse(text, fallback) {
    try {
      var payload = JSON.parse(String(text || "").trim())
      return payload && typeof payload === "object" ? payload : null
    } catch (e) {
      root.error = fallback
      return null
    }
  }

  // Load occurrences for a window. Cheap — it reads the local cache and
  // expands only the objects that can fall inside it.
  function load(from, to) {
    if (!from || !to) return
    if (from === rangeStart && to === rangeEnd && events.length > 0) return
    rangeStart = from
    rangeEnd = to
    if (eventsProc.running) eventsProc.running = false
    eventsProc.command = [helper, "events", "--from", from, "--to", to]
    loading = true
    eventsProc.running = true
  }

  function reload() {
    var from = rangeStart, to = rangeEnd
    rangeStart = ""
    rangeEnd = ""
    load(from, to)
  }

  // Pull from the server, then reload the window. An unchanged ctag makes
  // this nearly free, so it is safe to call on a timer.
  function sync() {
    if (syncProc.running) return
    syncProc.command = [helper, "sync"]
    syncing = true
    syncProc.running = true
  }

  // One calendar, for when only that one is suspected of being behind.
  property string syncingCalendar: ""

  function syncCalendar(url) {
    if (syncProc.running) return
    syncingCalendar = url
    syncProc.command = [helper, "sync", "--calendar", url]
    syncing = true
    syncProc.running = true
  }

  // Everything an account brought, and its password with it.
  function removeAccount(user) {
    if (removeProc.running) return
    removeProc.command = [helper, "remove-account", "--user", user]
    removeProc.running = true
  }

  // Stops syncing one calendar and lets go of what was cached for it.
  function forgetCalendar(url) {
    if (removeProc.running) return
    removeProc.command = [helper, "forget-calendar", "--calendar", url]
    removeProc.running = true
  }

  signal removed()

  property Process removeProc: Process {
    running: false
    stdout: StdioCollector { id: removeOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(removeOut.text, "the removal did not report back")
      if (payload && !payload.ok) root.error = payload.error || "could not remove it"
      root.refreshStatus()
      root.reload()
      root.removed()
    }
  }

  // --------------------------------------------------------------- updates
  //
  // The installed version is read from the manifest at runtime rather than
  // written into QML, so it cannot drift from what was released. Everything
  // the check remembers goes in the helper's settings table with the rest —
  // an update reloads the plugin and takes this object with it, so what was
  // in flight has to be written down before it runs.

  property string installedVersion: ""
  property var latestRelease: null
  property bool updateChecking: false
  property string updateError: ""
  property bool updateRunning: false

  readonly property double updateCheckedAt:
    Number(setting("updateCheckedAt", 0)) || 0
  readonly property bool updateCheck: setting("updateCheck", true) !== false
  readonly property string updateDismissed: String(setting("updateDismissed", ""))
  readonly property bool updateAvailable:
    latestRelease !== null && installedVersion !== ""
    && Logic.isNewerVersion(latestRelease.version, installedVersion)

  property FileView manifestFile: FileView {
    path: Qt.resolvedUrl("manifest.json").toString().replace(/^file:\/\//, "")
    printErrors: false
    onLoaded: {
      try {
        root.installedVersion = String(JSON.parse(text()).version || "")
      } catch (e) {
        root.installedVersion = ""
      }
      root.reportUpdateAttempt()
    }
  }

  // What became of an update started before the plugin reloaded. Read once,
  // then cleared: it is a note to whatever loads next, not a setting.
  signal updateFinished(string outcome)

  function reportUpdateAttempt() {
    var raw = String(setting("updateAttempt", ""))
    if (!raw) return
    var attempt = null
    try { attempt = JSON.parse(raw) } catch (e) { attempt = null }
    var outcome = Logic.updateAttemptState(attempt, installedVersion, Date.now())
    if (!outcome) return
    setSetting("updateAttempt", "")
    updateFinished(outcome)
  }

  function checkForUpdate() {
    if (updateChecking) return
    updateChecking = true
    updateError = ""
    var request = new XMLHttpRequest()
    request.open("GET", Logic.releasesApi())
    request.setRequestHeader("Accept", "application/vnd.github+json")
    request.setRequestHeader("User-Agent", "omarcal (" + Logic.releasesPage() + ")")
    request.onreadystatechange = function () {
      if (request.readyState !== XMLHttpRequest.DONE) return
      root.updateChecking = false
      if (request.status === 200) {
        var release = Logic.parseLatestRelease(request.responseText)
        if (release) root.latestRelease = release
        else root.updateError = "GitHub's answer could not be read"
      } else if (request.status === 404) {
        // No release yet is not a failure; it is an answer.
        root.latestRelease = null
      } else {
        root.updateError = "GitHub could not be reached"
      }
      root.setSetting("updateCheckedAt", Date.now())
    }
    request.send()
  }

  // The attempt is written before the command runs, because the command is
  // what stops this object existing.
  function applyUpdate() {
    if (updateRunning || !latestRelease) return
    updateRunning = true
    setSetting("updateAttempt", JSON.stringify(
      { version: latestRelease.version, at: Date.now() }))
    Quickshell.execDetached(Logic.updateCommand())
  }

  function dismissUpdate() {
    if (latestRelease) setSetting("updateDismissed", latestRelease.version)
  }

  property Timer updateTimer: Timer {
    interval: 60 * 60 * 1000
    repeat: true
    running: true
    onTriggered: if (Logic.updateCheckDue(root.updateCheckedAt, Date.now(),
                                          root.updateCheck))
      root.checkForUpdate()
  }

  // ---------------------------------------------------------------- search
  //
  // Runs over the cache, not the server: every calendar that has been synced
  // is already here, so a search is a LIKE over a local table and answers in
  // milliseconds. The panel debounces; this just runs what it is given.

  property var searchResults: []
  property bool searching: false
  property string searchQuery: ""

  function search(query) {
    var text = String(query || "").trim()
    searchQuery = text
    if (!text) { clearSearch(); return }
    searching = true
    searchProc.running = false
    searchProc.command = [helper, "search", "--query", text,
                          "--limit", String(Logic.searchLimit())]
    searchProc.running = true
  }

  function clearSearch() {
    searchProc.running = false
    searchResults = []
    searching = false
  }

  property Process searchProc: Process {
    running: false
    stdout: StdioCollector { id: searchOut; waitForEnd: true }
    onExited: {
      root.searching = false
      var payload = root.parse(searchOut.text, "the search did not come back")
      root.searchResults = payload && payload.ok ? (payload.events || []) : []
    }
  }

  // ------------------------------------------------------------ one event
  //
  // The viewer asks for a single event by uid. A recurring one needs the
  // occurrence's `rid` too, or the helper answers with the master and the
  // viewer shows the wrong day.

  property var eventDetail: null
  property bool eventLoading: false
  property string eventError: ""

  function loadEvent(uid, rid) {
    if (!uid) return
    // The last answer goes immediately: a viewer that opens showing the
    // previous event while this one loads is worse than one that opens empty.
    eventDetail = null
    eventError = ""
    eventLoading = true
    detailProc.running = false
    detailProc.command = rid
      ? [helper, "event", "--uid", uid, "--rid", rid]
      : [helper, "event", "--uid", uid]
    detailProc.running = true
  }

  function clearEvent() {
    detailProc.running = false
    eventDetail = null
    eventError = ""
    eventLoading = false
  }

  property Process detailProc: Process {
    running: false
    stdout: StdioCollector { id: detailOut; waitForEnd: true }
    onExited: {
      root.eventLoading = false
      var payload = root.parse(detailOut.text, "the event did not come back")
      if (!payload) { root.eventError = root.error; return }
      if (!payload.ok) {
        root.eventError = payload.error || "could not read that event"
        return
      }
      root.eventDetail = payload.event || null
    }
  }

  function refreshStatus() {
    if (statusProc.running) return
    statusProc.command = [helper, "status"]
    statusProc.running = true
  }

  // Hand the stored password back so the panel can show it. Its own command
  // rather than part of `status`, so a secret is only ever read on purpose.
  function revealPassword(user) {
    if (revealProc.running) return
    revealProc.command = [helper, "reveal-password", "--user", user]
    revealProc.running = true
  }

  function hidePassword() {
    revealedPassword = ""
  }

  property Process revealProc: Process {
    running: false
    stdout: StdioCollector { id: revealOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(revealOut.text, "")
      root.revealedPassword = payload && payload.ok ? (payload.password || "") : ""
    }
  }

  // Add an account: discover its calendars and store the password. The
  // password goes over stdin, never argv — argv is readable from /proc by
  // anything running as this user, which is how the network panel does it too.
  function addAccount(user, server, password) {
    if (loginProc.running) return
    addError = ""
    addingAccount = true
    loginProc.secret = password
    loginProc.command = [helper, "login", "--user", user, "--server", server]
    loginProc.running = true
  }

  // Nothing the helper does should take this long; if it somehow does, the
  // form has to come back rather than sit on "Saving…" forever.
  property Timer loginTimeout: Timer {
    interval: 60 * 1000
    onTriggered: {
      if (!loginProc.running) return
      loginProc.running = false
      root.addingAccount = false
      root.addError = "the server did not answer in time"
    }
  }

  property Process loginProc: Process {
    property string secret: ""
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: loginOut; waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
      root.loginTimeout.restart()
    }
    onExited: {
      root.loginTimeout.stop()
      root.addingAccount = false
      var payload = root.parse(loginOut.text, "the helper did not report back")
      if (!payload) { root.addError = root.error; return }
      if (!payload.ok) {
        root.addError = payload.error || "could not add the account"
        return
      }
      root.addError = ""
      root.revealedPassword = ""
      root.refreshStatus()
      root.sync()
      root.accountAdded()
    }
  }

  // Show or hide one calendar. The helper stores the flag, so the choice
  // survives a restart; the list is updated locally first so the checkbox
  // responds immediately rather than after a round trip.
  function setCalendarEnabled(url, enabled) {
    if (toggleProc.running) return
    var next = []
    for (var i = 0; i < calendars.length; i++) {
      var entry = calendars[i]
      next.push(entry.url === url ? Object.assign({}, entry, { enabled: enabled }) : entry)
    }
    calendars = next
    toggleProc.command = [helper, "set-calendar", "--calendar", url,
                          "--enabled", enabled ? "true" : "false"]
    toggleProc.running = true
  }

  // Several at once, one after another: the helper writes one calendar per
  // run, and setCalendarEnabled drops a call while another is in flight.
  property var pendingStates: []

  function applyCalendarStates(changes) {
    if (!changes || !changes.length) return
    var queued = []
    for (var i = 0; i < changes.length; i++) queued.push(changes[i])
    pendingStates = queued
    runNextState()
  }

  function runNextState() {
    if (toggleProc.running || !pendingStates.length) return
    var next = pendingStates[0]
    pendingStates = pendingStates.slice(1)
    // Keep the list in step as each one goes, so the switches do not snap
    // back between runs.
    var updated = []
    for (var i = 0; i < calendars.length; i++) {
      var entry = calendars[i]
      updated.push(entry.url === next.url
        ? Object.assign({}, entry, { enabled: next.enabled }) : entry)
    }
    calendars = updated
    toggleProc.command = [helper, "set-calendar", "--calendar", next.url,
                          "--enabled", next.enabled ? "true" : "false"]
    toggleProc.running = true
  }

  property Process toggleProc: Process {
    running: false
    stdout: StdioCollector { id: toggleOut; waitForEnd: true }
    onExited: {
      if (root.pendingStates.length) { root.runNextState(); return }
      root.reload()
      root.refreshStatus()
    }
  }

  property Process eventsProc: Process {
    running: false
    stdout: StdioCollector { id: eventsOut; waitForEnd: true }
    onExited: {
      root.loading = false
      var payload = root.parse(eventsOut.text, "could not read the event list")
      if (!payload) return
      if (payload.ok) {
        root.error = ""
        root.events = payload.events || []
        root.eventsLoaded()
      } else {
        root.error = payload.error || "the calendar could not be read"
      }
    }
  }

  property Process syncProc: Process {
    running: false
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    onExited: {
      root.syncing = false
      root.syncingCalendar = ""
      var payload = root.parse(syncOut.text, "the sync did not report back")
      if (!payload) return
      if (!payload.ok) {
        root.error = payload.error || "the sync failed"
        return
      }
      // Per-calendar errors do not stop the others; surface the first.
      var failed = (payload.calendars || []).filter(function (c) { return c.ok === false })
      root.error = failed.length ? (failed[0].name + ": " + (failed[0].error || "failed")) : ""
      root.lastSync = Date.now()
      var moved = (payload.calendars || []).some(function (c) {
        return c.added || c.changed || c.removedCount
      })
      if (moved) root.reload()
      root.refreshStatus()
    }
  }

  property Process statusProc: Process {
    running: false
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(statusOut.text, "")
      if (!payload || !payload.ok) return
      root.calendars = payload.calendars || []
      root.accounts = payload.accounts || []
      root.account = payload.account ? payload.account.user : ""
      root.server = payload.account ? payload.account.server : ""
      root.settings = payload.settings || ({})
      root.cacheBytes = payload.cacheBytes || 0
      root.objectCount = payload.objects || 0
      root.settingsLoaded = true
    }
  }

  // --------------------------------------------------------------- settings
  //
  // The helper's `settings` table is the only copy: shell.json belongs to the
  // shell and a plugin cannot write it, so the manifest's `defaults` are a
  // starting point and everything after that lives here. `status` carries the
  // whole set, which is why reading them costs no extra call.

  function setting(name, fallback) {
    var value = settings[name]
    return value === undefined || value === null ? fallback : value
  }

  // Applied here first and then written, so a switch moves under the pointer
  // instead of after a round trip. The helper answers with the whole set,
  // which then replaces this optimistic copy.
  function setSetting(name, value) {
    var next = {}
    for (var key in settings) next[key] = settings[key]
    next[name] = value
    settings = next
    settingsQueue.push(name + "=" + JSON.stringify(value))
    runNextSetting()
  }

  property var settingsQueue: []

  function runNextSetting() {
    if (settingProc.running || !settingsQueue.length) return
    var pair = settingsQueue.shift()
    settingProc.command = [helper, "settings", "--set", pair]
    settingProc.running = true
  }

  property Process settingProc: Process {
    running: false
    stdout: StdioCollector { id: settingOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(settingOut.text, "the setting did not save")
      // Only once the queue is empty: an answer from the first of three
      // writes would otherwise undo the two still to go.
      if (payload && payload.ok && payload.settings && !root.settingsQueue.length)
        root.settings = payload.settings
      root.runNextSetting()
    }
  }

  property Timer refreshTimer: Timer {
    // Honours refreshMinutes, and never faster than a minute: the interval is
    // a person's typed number, and a zero here would spin.
    interval: Math.max(1, Number(root.setting("refreshMinutes", 15)) || 15) * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.sync()
  }

  // Nothing here runs while the shell is still loading its plugins.
  //
  // `omarchy plugin add` gives the shell two seconds to rescan, and spawning
  // the helper and reaching for GitHub inside that window is what put the
  // rescan over it. Settings come back almost at once so the bar clock has
  // its face; the sync and the update check are network work nobody is
  // waiting on, and they can start a beat later.
  property Timer settleTimer: Timer {
    interval: 400
    repeat: false
    running: true
    onTriggered: {
      root.refreshStatus()
      slowStartTimer.start()
    }
  }

  property Timer slowStartTimer: Timer {
    interval: 2600
    repeat: false
    onTriggered: {
      root.sync()
      if (Logic.updateCheckDue(root.updateCheckedAt, Date.now(), root.updateCheck))
        root.checkForUpdate()
    }
  }
}
