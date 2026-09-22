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
  // Changes saved while offline and not yet on iCloud, and those iCloud
  // refused when they were sent — as `status` last reported them.
  property int pendingCount: 0
  property var pendingProblems: []

  function dismissPending(id) {
    if (dismissProc.running) return
    dismissProc.command = [helper, "pending-dismiss", "--id", String(id)]
    dismissProc.running = true
  }

  property Process dismissProc: Process {
    running: false
    stdout: StdioCollector { id: dismissOut; waitForEnd: true }
    onExited: root.refreshStatus()
  }

  // The machine's zone, by IANA name, as the helper reads it.
  property string localZone: ""

  // Every zone, with today's offset, for the form's zone pickers. Asked for
  // once, the first time a form wants it.
  property var zones: []

  function loadZones() {
    if (zones.length || zonesProc.running) return
    zonesProc.command = [helper, "zones"]
    zonesProc.running = true
  }

  property Process zonesProc: Process {
    running: false
    stdout: StdioCollector { id: zonesOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(zonesOut.text, "the time zones did not come back")
      if (payload && payload.ok) {
        root.zones = payload.zones || []
        if (payload.local) root.localZone = payload.local
      }
    }
  }
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

  // Asked through the helper, which bounds the request: a timeout on every
  // read, a deadline on the whole, and a cap on the answer's size before any
  // of it is buffered. The shell is long-lived; an unbounded request here
  // could hang the check or fill its memory. The timer below is the shell's
  // own backstop, in case the helper itself does not come back.
  function checkForUpdate() {
    if (updateChecking) return
    updateChecking = true
    updateError = ""
    updateProc.command = [helper, "update-check"]
    updateProc.running = true
    updateDeadline.restart()
  }

  property Process updateProc: Process {
    running: false
    stdout: StdioCollector { id: updateOut; waitForEnd: true }
    onExited: {
      updateDeadline.stop()
      if (!root.updateChecking) return
      root.updateChecking = false
      var payload = root.parse(updateOut.text, "")
      if (!payload || !payload.ok) {
        root.updateError = payload && payload.error ? payload.error : "GitHub could not be reached"
      } else if (payload.status === 404) {
        // No release yet is not a failure; it is an answer.
        root.latestRelease = null
      } else {
        var release = Logic.parseLatestRelease(payload.body)
        if (release) root.latestRelease = release
        else root.updateError = "GitHub's answer could not be read"
      }
      root.setSetting("updateCheckedAt", Date.now())
    }
  }

  property Timer updateDeadline: Timer {
    interval: 25000
    repeat: false
    onTriggered: {
      if (!root.updateChecking) return
      root.updateChecking = false
      updateProc.running = false
      root.updateError = "GitHub took too long to answer"
      root.setSetting("updateCheckedAt", Date.now())
    }
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

  // `at` is the open occurrence's start, so the helper can say what its
  // times read in the event's own zones for that occurrence, not the first.
  function loadEvent(uid, rid, at) {
    if (!uid) return
    // The last answer goes immediately: a viewer that opens showing the
    // previous event while this one loads is worse than one that opens empty.
    eventDetail = null
    eventError = ""
    eventLoading = true
    detailProc.running = false
    var command = [helper, "event", "--uid", uid]
    if (rid) command = command.concat(["--rid", rid])
    if (at) command = command.concat(["--at", at])
    detailProc.command = command
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
      if (moved) { root.reload(); root.loadPlacesHistory() }
      root.refreshStatus()
      // An address book changes slowly and has no sync token here, so it is
      // fetched whole — once a day is plenty.
      if (root.contactsEnabled && Date.now() - root.contactsSyncedAt > 24 * 60 * 60 * 1000)
        root.syncContacts()
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
      root.localZone = payload.localZone || ""
      root.pendingCount = payload.pending || 0
      root.pendingProblems = payload.pendingProblems || []
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
      // Contacts are read only after the yes has been written down, so the
      // helper — which refuses while the setting is off — sees it on.
      if (root.contactsSyncWanted && !root.settingsQueue.length && !root.settingProc.running) {
        root.contactsSyncWanted = false
        root.syncContacts()
      }
    }
  }

  // -------------------------------------------------------------- writes
  //
  // Saving and deleting one event. The request goes to the helper as one
  // line of JSON on stdin — a Process cannot close its stdin, so the helper
  // reads a line rather than to the end — and the answer is handed to
  // whoever asked, then the window is reloaded so the change shows.

  property bool writing: false
  property string writeAction: ""
  property var writeRequest: null
  signal writeFinished(string action, var payload)

  function saveEvent(request) { startWrite("save", request) }
  function deleteEvent(request) { startWrite("delete", request) }

  function startWrite(action, request) {
    if (writeProc.running) return
    writing = true
    writeAction = action
    writeRequest = request
    writeProc.command = [helper, action]
    writeProc.running = true
  }

  property Process writeProc: Process {
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: writeOut; waitForEnd: true }
    onStarted: {
      write(JSON.stringify(root.writeRequest) + "\n")
      root.writeRequest = null
    }
    onExited: {
      var action = root.writeAction
      root.writing = false
      var payload = root.parse(writeOut.text, "the save did not report back")
      // A conflict means the cache is behind iCloud; a sync brings it level
      // so reopening the event shows what changed it.
      if (payload && !payload.ok && payload.code === "conflict") root.sync()
      if (payload && payload.ok) root.reload()
      root.refreshStatus()
      root.writeFinished(action, payload)
    }
  }

  // -------------------------------------------------------------- places
  //
  // The calendar's own addresses, always, read from the cache and never
  // sent anywhere; and a lookup service only once one has been chosen,
  // which the helper checks for itself before it sends a thing.

  readonly property string placesProvider: String(setting("placesProvider", "none"))
  property var placesHistory: []
  property var placeResults: []
  property string placeResultsFor: ""
  property bool placesSearching: false
  property string placesError: ""

  function loadPlacesHistory() {
    if (placesHistoryProc.running) return
    placesHistoryProc.command = [helper, "places-history"]
    placesHistoryProc.running = true
  }

  property Process placesHistoryProc: Process {
    running: false
    stdout: StdioCollector { id: placesHistoryOut; waitForEnd: true }
    onExited: {
      var payload = root.parse(placesHistoryOut.text, "addresses did not come back")
      if (payload && payload.ok) root.placesHistory = payload.places || []
    }
  }

  function searchPlaces(query) {
    var text = String(query || "").trim()
    if (placesProvider === "none" || text.length < 3) { clearPlaces(); return }
    placesProc.running = false
    placeResultsFor = text
    placesSearching = true
    placesError = ""
    placesProc.command = [helper, "places", "--query", text]
    placesProc.running = true
  }

  function clearPlaces() {
    placesProc.running = false
    placeResults = []
    placeResultsFor = ""
    placesSearching = false
    placesError = ""
  }

  function setPlacesProvider(provider) {
    clearPlaces()
    setSetting("placesProvider", provider)
  }

  property Process placesProc: Process {
    running: false
    stdout: StdioCollector { id: placesOut; waitForEnd: true }
    onExited: {
      root.placesSearching = false
      var payload = root.parse(placesOut.text, "the address search did not come back")
      if (!payload) return
      if (!payload.ok) { root.placesError = payload.error || "the address search failed"; root.placeResults = []; return }
      root.placeResults = payload.places || []
    }
  }

  // ------------------------------------------------------------ contacts
  //
  // Opt-in. Nothing here runs until the person has said yes in the panel's
  // own words; saying no again deletes what was kept. The helper enforces
  // both on its side too, so this is not the only thing standing between a
  // setting and an address book.

  readonly property bool contactsEnabled: setting("contactsEnabled", false) === true
  property var contacts: []
  property int contactCount: 0
  property string contactsError: ""
  property bool contactsSyncing: false
  property double contactsSyncedAt: 0
  property bool contactsSyncWanted: false

  function enableContacts() {
    contactsSyncWanted = true
    setSetting("contactsEnabled", true)
  }

  function disableContacts() {
    contactsSyncWanted = false
    contactsProc.running = false
    contacts = []
    contactCount = 0
    contactsError = ""
    setSetting("contactsEnabled", false)
  }

  function syncContacts() {
    if (!contactsEnabled || contactsProc.running) return
    contactsSyncing = true
    contactsProc.command = [helper, "contacts-sync"]
    contactsProc.running = true
  }

  // What is already kept, without going to iCloud for it.
  function loadContacts() {
    if (!contactsEnabled || contactsProc.running) return
    contactsProc.command = [helper, "contacts"]
    contactsProc.running = true
  }

  property Process contactsProc: Process {
    running: false
    stdout: StdioCollector { id: contactsOut; waitForEnd: true }
    onExited: {
      var syncing = root.contactsSyncing
      root.contactsSyncing = false
      var payload = root.parse(contactsOut.text, "contacts did not come back")
      if (!payload) return
      if (!payload.ok) { root.contactsError = payload.error || "contacts could not be read"; return }
      // Switched off while this was running: what came back is not wanted.
      if (!root.contactsEnabled) { root.contacts = []; root.contactCount = 0; return }
      root.contacts = payload.contacts || []
      root.contactCount = payload.count || 0
      root.contactsError = payload.error || ""
      if (syncing) root.contactsSyncedAt = Date.now()
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
      root.loadPlacesHistory()
      if (Logic.updateCheckDue(root.updateCheckedAt, Date.now(), root.updateCheck))
        root.checkForUpdate()
    }
  }
}
