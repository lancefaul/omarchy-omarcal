import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Logic.js" as Logic

// The calendar popup, in three columns: the calendar list, the month — a
// six-by-seven grid, all-day events as bars spanning the days they cover,
// timed events as chips — and the selected day.
//
// The side columns follow the shape omedia-controls uses: one hairline
// between each, a header above each, the same width either side.
//
// Every layout decision comes from Logic.js, which is tested headlessly. This
// file only draws.
Panel {
  id: root
  moduleName: "lancefaul.omarcal"
  ipcTarget: "omarcal"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null

  property date today: new Date()
  readonly property string todayKey: Qt.formatDate(today, "yyyy-MM-dd")

  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth() + 1     // Logic.js months are 1-based
  property string selectedKey: todayKey

  // Preferences live in the helper's own store, because shell.json belongs to
  // the shell and a plugin cannot write it. Until the first `status` lands,
  // the manifest defaults that the shell did write stand in, so the month is
  // drawn once with the right week start rather than redrawn a moment later.
  function pref(name, fallback) {
    if (service && service.settingsLoaded) return service.setting(name, fallback)
    return setting(name, fallback)
  }

  function setPref(name, value) { if (service) service.setSetting(name, value) }

  readonly property int weekStartDay: Number(pref("weekStartDay", 0)) || 0
  readonly property string timeFormat: String(pref("timeFormat", "12h"))
  readonly property bool showWeekNumbers: pref("showWeekNumbers", false) === true
  readonly property int refreshMinutes: Number(pref("refreshMinutes", 15)) || 15
  readonly property string clockFormat:
    String(pref("format", Logic.settingDefault("format")))
  readonly property string verticalClockFormat:
    String(pref("verticalFormat", Logic.settingDefault("verticalFormat")))
  // ------------------------------------------------------------- the viewer
  //
  // One event, in full. The list already holds enough to head the card —
  // title, colour, when — so the viewer opens on that and fills in the rest
  // when `event --uid` answers, rather than opening on a spinner.
  property bool viewerOpen: false
  property var viewerSeed: null
  readonly property var viewerEvent: Logic.mergeOccurrence(
    viewerSeed, service ? service.eventDetail : null)

  function openEvent(event) {
    if (!event || !event.uid) return
    if (editorDirty) { requestCancel(function () { root.openEvent(event) }); return }
    dayNotice = ""
    cancelEdit()
    viewerSeed = event
    viewerOpen = true
    if (service) service.loadEvent(event.uid, event.rid || "", event.allDay ? "" : String(event.start || ""))
  }

  function closeEvent() {
    cancelEdit()
    viewerOpen = false
    viewerSeed = null
    if (service) service.clearEvent()
  }

  // ------------------------------------------------------------- the editor
  //
  // The event's form takes the viewer's place in the same column, on a
  // draft made from what the viewer was showing. Saving and deleting ask
  // the question a series needs asked, and then — until the helper can
  // write — say plainly that nothing was sent.
  property bool editorOpen: false
  property var draft: null
  property var draftBase: null
  // "save" or "delete" while its question is on screen, with the answers
  // it offers. An empty list of scopes is a plain yes or no.
  property string pendingAction: ""
  property var pendingScopes: []
  property string editNotice: ""

  readonly property bool viewerEditable: Logic.canEdit(viewerEvent)
  readonly property var draftChanges: editorOpen && draft && draftBase
    ? Logic.draftChanges(draft, draftBase) : []
  readonly property string draftProblem: draft ? Logic.draftProblem(draft, inviteeText) : ""
  readonly property var editCalendars: draft
    ? Logic.editableCalendars(calendars, draft.calendarUrl) : []

  // The viewer's own zone: what a new event's times are in, and the zone
  // the pickers offer first.
  readonly property string localZone: service ? service.localZone : ""

  // True while the form is making a new event rather than changing one.
  property bool creating: false
  // Where a new event goes: the one chosen in settings, or the busiest.
  readonly property string newEventCalendar: Logic.defaultCalendar(
    calendars, String(pref("defaultCalendar", "")), service ? service.account : "")

  // The form, on a blank event for the selected day. The column the viewer
  // uses holds it, so it opens where an event would be read.
  function startNew() {
    if (newEventCalendar === "") return
    if (editorDirty) { requestCancel(function () { root.startNew() }); return }
    dayNotice = ""
    if (viewerOpen) closeEvent()
    settingsOpen = false
    searchOpen = false
    dayOptionsOpen = false
    var base = Logic.newEvent(selectedKey, todayKey,
                              Qt.formatTime(new Date(), "HH:mm"), newEventCalendar)
    creating = true
    draftBase = base
    draft = Logic.editDraft(base, localZone)
    if (service) service.loadZones()
    editNotice = ""
    viewerSeed = null
    viewerOpen = true
    editorOpen = true
  }

  // True once the viewer holds the event's detail, not only the list row.
  readonly property bool viewerLoaded: !!(viewerEvent && viewerEvent.href)
  // The new event the form holds is a copy of the one that was open.
  property bool duplicating: false

  // A copy of the open event, in the new-event form. It goes to the calendar
  // new events go to when the original's cannot be written to.
  function startDuplicate() {
    if (!viewerLoaded || newEventCalendar === "") return
    var base = Logic.duplicateOf(viewerEvent)
    var writable = false
    var usable = Logic.editableCalendars(calendars, "")
    for (var i = 0; i < usable.length; i++) if (usable[i].value === base.calendarUrl) writable = true
    if (!writable) base.calendarUrl = newEventCalendar
    creating = true
    duplicating = true
    draftBase = base
    draft = Logic.editDraft(base, localZone)
    if (service) service.loadZones()
    editNotice = ""
    editorOpen = true
  }

  function startEdit() {
    if (!viewerEditable) return
    draftBase = viewerEvent
    draft = Logic.editDraft(viewerEvent, localZone)
    if (service) service.loadZones()
    editNotice = ""
    editorOpen = true
  }

  function cancelEdit() {
    editorOpen = false
    // A new event has no viewer to go back to: cancelling it is leaving. A
    // copy does — the original is still open behind it.
    if (creating) {
      if (!duplicating) viewerOpen = false
      creating = false
      duplicating = false
    }
    attachError = ""
    inviteeDismissed = false
    placeQuery = ""
    if (service) service.clearPlaces()
    inviteeText = ""
    inviteeTried = false
    draft = null
    draftBase = null
    pendingAction = ""
    pendingScopes = []
    editNotice = ""
  }

  function setDraft(field, value) {
    if (draft) draft = Logic.withField(draft, field, value)
  }

  function setRule(part, value) { if (draft) draft = Logic.withRule(draft, part, value) }
  function toggleRuleDay(code) { if (draft) draft = Logic.withDayToggled(draft, code) }
  function setAlert(slot, value) { if (draft) draft = Logic.withAlert(draft, slot, value) }

  // Invitees. The address being typed lives here rather than in the draft:
  // it is not part of the event until it is added.
  property string inviteeText: ""
  // Set when the contact suggestions are clicked away from or dismissed
  // with Escape; typing again brings them back.
  property bool inviteeDismissed: false
  // Set by a failed Add, so the reason shows even before an @ is typed.
  property bool inviteeTried: false
  // The account the event's calendar belongs to — the organiser, for an
  // event it is inviting people to.
  readonly property string organizerAccount: {
    if (!draftBase) return ""
    var url = draft ? draft.calendarUrl : draftBase.calendarUrl
    for (var i = 0; i < calendars.length; i++)
      if (calendars[i].url === url) return calendars[i].account || ""
    return service ? service.account : ""
  }
  readonly property bool canInviteHere: !!draftBase && Logic.canInvite(draftBase, organizerAccount)
  readonly property string inviteeProblem: draft
    ? Logic.inviteeProblem(draft, inviteeText, organizerAccount) : ""
  readonly property var inviteeSuggestions: draft && service && service.contactsEnabled
    ? Logic.contactSuggestions(service.contacts, inviteeText, draft, 5) : []

  function addInvitee(email, name) {
    if (!draft) return
    var problem = Logic.inviteeProblem(draft, email, organizerAccount)
    if (!String(email || "").trim() || problem !== "") { inviteeTried = true; return }
    draft = Logic.withInvitee(draft, email, name)
    inviteeText = ""
    inviteeTried = false
  }

  function removeInvitee(email) { if (draft) draft = Logic.withoutInvitee(draft, email) }
  function removeAttachment(index) {
    if (draft) draft = Logic.withoutAttachment(draft, index)
    attachError = ""
  }

  // What is being typed in Address, while it is being typed — the
  // suggestions follow this rather than the draft, so opening a form on an
  // event does not start suggesting its own address back.
  property string placeQuery: ""
  readonly property var placeMatches: draft && service
    ? Logic.placeSuggestions(service.placesHistory, placeQuery, 5) : []
  readonly property var placeLookups: service && service.placeResultsFor !== ""
    && service.placeResultsFor === placeQuery.trim() ? service.placeResults : []
  readonly property string placesProvider: service ? service.placesProvider : "none"

  // The suggestion the keyboard is on: the calendar's own first, then the
  // lookup's, counted as one list. -1 is none; typing starts over.
  property int placeCurrent: -1
  onPlaceQueryChanged: placeCurrent = -1
  property int inviteeCurrent: -1
  onInviteeTextChanged: inviteeCurrent = -1

  // Up, Down and Enter from the field a suggestion list hangs under. Only
  // while the list is open, so the field keeps its own keys otherwise.
  function suggestKey(event, count, current, choose) {
    if (event.key === Qt.Key_Down) { event.accepted = true; return Math.min(count - 1, current + 1) }
    if (event.key === Qt.Key_Up) { event.accepted = true; return Math.max(-1, current - 1) }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && current >= 0) {
      event.accepted = true
      choose(current)
      return -1
    }
    return current
  }

  function typePlace(text) {
    placeQuery = text
    if (placesProvider === "photon") placeDebounce.restart()
  }

  function pickPlace(suggestion) {
    if (!draft) return
    draft = Logic.withPlace(draft, suggestion)
    placeQuery = ""
    if (service) service.clearPlaces()
  }

  // Photon is asked once typing pauses, not on every key.
  Timer {
    id: placeDebounce
    interval: 400
    onTriggered: if (root.service && root.placesProvider === "photon")
      root.service.searchPlaces(root.placeQuery)
  }

  // Nominatim's rules allow one search a second at most.
  property bool nominatimResting: false
  Timer {
    id: nominatimRest
    interval: 1100
    onTriggered: root.nominatimResting = false
  }

  function searchNominatim() {
    if (!service || nominatimResting || placesProvider !== "nominatim") return
    nominatimResting = true
    nominatimRest.restart()
    service.searchPlaces(placeQuery)
  }

  // Why the last file picked was not added, shown under the list.
  property string attachError: ""

  // Picking a file to attach. The card steps aside for the desktop's own
  // file dialog — a window that takes focus would close it anyway — and
  // comes back on the same form, which closing the card never discards.
  // The dialog is xdg-desktop-portal's, through the helper: every Omarchy
  // install has the portal, where zenity is not guaranteed.
  function pickAttachment() {
    if (!draft || filePicker.running) return
    editNotice = ""
    attachError = ""
    close()
    filePicker.running = true
  }

  Process {
    id: filePicker
    running: false
    command: [service ? service.helper : "", "pick-file"]
    stdout: StdioCollector { id: pickedOut; waitForEnd: true }
    onExited: function (exitCode, exitStatus) {
      var file = Logic.parsePicked(pickedOut.text)
      if (file && file.error) {
        root.editNotice = file.error
        root.editNoticeBad = true
      } else if (file && root.draft) {
        var problem = Logic.attachmentProblem(root.draft, file)
        if (problem) root.attachError = problem
        else root.draft = Logic.withAttachment(root.draft, file)
      }
      root.open()
    }
  }

  // The question asked before anything leaves the machine: "contacts" for
  // reading iCloud Contacts, "photon" or "nominatim" for sending addresses
  // to a lookup service. Empty when nothing is being asked. Nothing is read
  // or sent until Allow.
  property string consentKind: ""

  function allowConsent() {
    var kind = consentKind
    consentKind = ""
    if (!service) return
    if (kind === "contacts") service.enableContacts()
    else if (kind === "photon" || kind === "nominatim") service.setPlacesProvider(kind)
  }

  // A one-off event saves without a question; a series asks how far.
  function requestSave() {
    if (!draft || draftProblem !== "") return
    if (creating) { finishAction("save", ""); return }
    if (draftChanges.length === 0) return
    var scopes = Logic.scopeChoices(draftBase, draftChanges)
    if (scopes.length) { pendingScopes = scopes; pendingAction = "save" }
    else finishAction("save", "")
  }

  // A delete always asks, series or not.
  function requestDelete() {
    if (!viewerEditable) return
    pendingScopes = Logic.scopeChoices(viewerEvent, [])
    pendingAction = "delete"
  }

  function dismissAction() {
    pendingAction = ""
    pendingScopes = []
  }

  // Unsaved changes are asked about before they are thrown away — by Cancel,
  // by Escape, and by opening another event or a new one over the form.
  readonly property bool editorDirty: editorOpen && draftChanges.length > 0
  // What to do once the changes are discarded, if leaving was for something.
  property var discardThen: null

  function requestCancel(then) {
    if (!editorDirty) {
      cancelEdit()
      if (then) then()
      return
    }
    discardThen = then || null
    pendingScopes = []
    pendingAction = "discard"
  }

  function finishAction(action, scope) {
    if (action === "discard") {
      var then = discardThen
      discardThen = null
      dismissAction()
      cancelEdit()
      if (then) then()
      return
    }
    if (action !== "save" && action !== "delete") return
    dismissAction()
    if (!service || service.writing) return
    editNotice = ""
    editNoticeBad = false
    if (action === "delete")
      service.deleteEvent(Logic.deleteRequest(viewerEvent, viewerSeed, scope))
    else
      service.saveEvent(Logic.saveRequest(draft, draftBase, viewerSeed, scope,
                                          creating, organizerAccount))
  }

  // Whether the foot's note is a failure, so it can say so in red.
  property bool editNoticeBad: false
  // What the last write came to, said at the top of the day once the form
  // has closed on it — the form it would have been said in is gone.
  property string dayNotice: ""
  property bool dayNoticeBad: true

  Connections {
    target: root.service
    function onWriteFinished(action, payload) {
      var outcome = Logic.writeOutcome(action, payload)
      if (!outcome.done) {
        // The form stays open with everything typed in it, and says why.
        root.editNotice = outcome.message
        root.editNoticeBad = true
        return
      }
      // Done: back to the day, where the change now shows. Anything that
      // went wrong on the way (an attachment refused) is said there, and so
      // is a change kept on this computer until iCloud can be reached.
      root.closeEvent()
      root.dayNoticeBad = !outcome.queued
      root.dayNotice = outcome.message === "Saved." || outcome.message === "Deleted."
        ? "" : outcome.message
    }
  }

  // Whether a long title or address in the day panel wraps or is cut off.
  readonly property bool wrapEvents: pref("wrapEvents", false) === true
  // The slice of a day both rails run. One window, so the day and the week
  // are narrowed by the same setting rather than each having an opinion.
  readonly property var dayWindow: Logic.dayWindow(
    pref("dayStartHour", 0), pref("dayEndHour", 24))
  // The gear on the day panel, which offers exactly that one choice.
  property bool dayOptionsOpen: false

  // -1 when the stored format is one the person typed rather than picked.
  readonly property int clockPreset: Logic.clockPresetIndex(clockFormat)

  readonly property var refreshChoices: {
    var out = [], options = Logic.refreshOptions()
    for (var i = 0; i < options.length; i++)
      out.push({ value: options[i], label: Logic.refreshLabel(options[i]) })
    return out
  }

  // Each face is labelled with an example of itself, so the list is the
  // preview. The last row is the way out to a format string.
  readonly property var clockChoices: {
    var out = [], presets = Logic.clockPresets()
    for (var i = 0; i < presets.length; i++)
      out.push({ value: String(i), label: presets[i].label })
    out.push({ value: "custom", label: "Custom\u2026" })
    return out
  }

  readonly property var cells: Logic.monthGrid(viewYear, viewMonth, weekStartDay, todayKey)
  readonly property var rows: Logic.monthRows(cells)
  readonly property var events: service ? service.events : []
  readonly property var calendars: service ? service.calendars : []
  readonly property var buckets: Logic.bucketByDay(events, cells.map(function (c) { return c.key }))
  readonly property var selected: buckets[selectedKey] || ({ allDay: [], timed: [] })

  // Subdued text, lifted to WCAG AA against whatever the theme's popup
  // background actually is. Several Omarchy themes ship a `muted` that is
  // close to unreadable — Hackerman's is 1.59:1.
  readonly property color subdued: Logic.ensureContrast(
    String(Color.muted), String(Color.popups.background), 4.5)
  // "Stored and active" is a good-news colour, lifted to AA like the rest.
  readonly property color stored: Logic.ensureContrast(
    "#3fb950", String(Color.popups.background), 4.5)

  // Anything destructive or failed. A fixed red rather than Color.urgent,
  // because a theme may define urgent as anything it likes — Hackerman's is
  // #50f872, a green, which is the wrong promise on a button that deletes an
  // account and the wrong colour on a sync that failed. Muted rather than a
  // full-saturation red: it marks two controls on a panel of calm text, and a
  // signal that loud reads as an alarm going off.
  readonly property color danger: Logic.ensureContrast(
    "#d76f6a", String(Color.popups.background), 4.5)

  readonly property color hairline: Logic.ensureContrast(
    String(Color.muted), String(Color.popups.background), 3.0)

  // The month is a fixed width whether or not the week column is showing:
  // the column comes out of the day cells rather than being added beside
  // them, so turning week numbers on narrows the cells by a few pixels
  // instead of widening the whole card and shifting everything in it.
  readonly property int gridWidth: Style.space(115) * 7
  readonly property int cellWidth: Math.floor((gridWidth - weekColumnWanted) / 7)
  // One height for everything that sits in a day cell. An all-day bar and an
  // appointment are both one line, so a week's rows line up across it instead
  // of drifting apart by a couple of pixels per cell.
  readonly property int slotHeight: Style.space(18)
  readonly property int slotGap: 2
  readonly property int slotPitch: slotHeight + slotGap
  // Four a day, shared by both kinds. All-day bars take theirs from the top,
  // appointments fill what is left, and the last becomes "+N more" when the
  // day holds more than four.
  readonly property int slotCount: 4

  // ------------------------------------------------------------- day view
  readonly property int hourHeight: Style.space(34)
  // The rail's own column, wide enough for "12 AM" with air either side.
  readonly property int hourGutter: Style.space(46)
  // An hour's name is centred on its rule, so half of it sits above. The rail
  // is padded by that much or the topmost label is cut off by the clip.
  readonly property int railTop: Math.round(captionLine / 2)
  // How wide an hour's name is, for a rail that lays them across the top.
  readonly property int hourLabelWidth: hourProbe.implicitWidth
  // And how wide a weekday's, so the week's number can be centred over the
  // date bubbles that sit after it rather than guessed at.
  readonly property int weekdayTagWidth: weekdayProbe.implicitWidth

  Text {
    id: weekdayProbe
    visible: false
    text: "SUN"
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.weight: Font.DemiBold
  }

  Text {
    id: hourProbe
    visible: false
    text: "12 AM"
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.weight: Font.DemiBold
  }
  readonly property var dayBlocks:
    Logic.layoutTimed(selected.timed, selectedKey)

  // ------------------------------------------------------------ week view
  readonly property var weekKeys: Logic.weekDays(selectedKey, weekStartDay)
  readonly property var weekBars: Logic.allDayBars(events, weekKeys)
  readonly property int weekLanes: Logic.laneCount(weekBars)
  readonly property var weekHead: Logic.weekHeading(weekKeys)
  // Bars stop one lane short of that. A bar spans days, so it cannot be
  // dropped on the one day that needs room for a count and kept on the
  // others — leaving the last slot to the cell guarantees every day can say
  // what it is not showing. The cost is a day with exactly four all-day
  // events and nothing else, which draws three and "+1 more" rather than
  // four; the gain is that a day of bars over a day of appointments never
  // swallows the appointments silently.
  readonly property int barLanes: slotCount - 1
  readonly property int slotTop: bubbleSize + Style.spacing.xxs
  // Derived rather than a round number, so four slots always fit exactly.
  readonly property int cellHeight:
    slotTop + slotCount * slotPitch + Style.spacing.sm
  readonly property int weekColumnWanted: showWeekNumbers ? Style.space(28) : 0
  // Whatever the cells left over, so the seven of them plus this are exactly
  // `gridWidth` and the card never changes size.
  readonly property int weekColumn: gridWidth - cellWidth * 7
  // Wide enough for "Birthdays & Anniversaries" without eliding, which is
  // the longest calendar name a stock iCloud account has.
  readonly property int sidebarWidth: Style.space(240)
  readonly property int cellPadding: Style.spacing.sm
  // A true circle: one size used for both axes, radius exactly half.
  readonly property int bubbleSize: Style.space(26)
  // A weekend ground just distinct enough to read as a band.
  readonly property color weekendFill: Util.alpha(foreground, 0.045)

  // ------------------------------------------------------------- searching
  //
  // Over the cache, so it reaches back through every synced year rather than
  // the window the month happens to be showing.
  property bool searchOpen: false
  property string searchText: ""
  readonly property var searchGroups:
    Logic.searchGroups(service ? service.searchResults : [])
  readonly property int searchCount:
    service && service.searchResults ? service.searchResults.length : 0

  function openSearch() {
    closeSetup()
    settingsOpen = false
    searchOpen = true
  }

  function closeSearch() {
    searchOpen = false
    searchText = ""
    if (service) service.clearSearch()
  }

  function toggleSearch() {
    if (searchOpen) closeSearch()
    else openSearch()
  }

  property bool settingsOpen: false

  function openSettings() {
    closeSetup()
    searchOpen = false
    settingsOpen = true
  }

  function closeSettings() { settingsOpen = false }

  function toggleSettings() {
    if (settingsOpen) closeSettings()
    else openSettings()
  }

  // The account form, which takes over the calendar column while open. Only
  // iCloud is offered, so the server is the preset's and never asked for.
  property bool setupOpen: false
  property bool setupEditing: false
  property string setupUser: ""
  property string setupPassword: ""
  property bool setupChangingPassword: false
  property bool helpOpen: false

  // What the calendar switches are set to, against what is stored. Seeded
  // when the list arrives, then the person's own choices until they save.
  property var setupSelection: ({})
  property string setupNotice: ""
  // True once this form has something to list: the account being edited
  // already has calendars, a new one has none until it connects. Without it
  // the list is bound to whatever account is already set up, and Add offers
  // to switch off calendars belonging to an account it is not adding.
  property bool setupHasCalendars: false
  // Pressed once to ask, once more to mean it.
  property bool confirmRemove: false
  // The calendar whose switch was just pushed off, held between the push and
  // the answer. Off here is a delete, not a filter, so it is asked about.
  property var pendingForget: null
  readonly property var setupCalendars:
    setupHasCalendars && service ? service.calendars : []

  // Connecting needs a password actually typed: reconnecting with the stored
  // one proves nothing the account list does not already show.
  readonly property bool canConnect:
    setupPassword !== "" && Logic.accountProblem(
      setupUser, setupPreset.server, setupPassword, false) === ""

  readonly property var setupChanges: {
    var out = []
    for (var i = 0; i < setupCalendars.length; i++) {
      var entry = setupCalendars[i]
      var wanted = setupSelection[entry.url]
      if (wanted === undefined) continue
      if (wanted !== (entry.enabled !== false))
        out.push({ url: entry.url, enabled: wanted })
    }
    return out
  }

  function seedSelection() {
    var next = {}
    for (var i = 0; i < setupCalendars.length; i++)
      next[setupCalendars[i].url] = setupCalendars[i].enabled !== false
    setupSelection = next
  }

  function toggleSelection(url) {
    var next = {}
    for (var key in setupSelection) next[key] = setupSelection[key]
    next[url] = !next[url]
    setupSelection = next
  }

  // Switching one on is only a choice, saved with the rest. Switching one off
  // throws away every event cached for it, so it is asked about first — and
  // only on an account that has some: a calendar picked during Add has
  // nothing behind it yet.
  function requestToggle(entry) {
    if (setupEditing && setupSelection[entry.url] !== false) pendingForget = entry
    else toggleSelection(entry.url)
  }

  function confirmForget() {
    if (!pendingForget) return
    var url = pendingForget.url
    pendingForget = null
    if (service) service.forgetCalendar(url)
    // The switch follows, or Save would offer to turn straight back on what
    // was just deleted.
    if (setupSelection[url] !== false) toggleSelection(url)
  }

  function removeAccount() {
    if (!service || !setupUser) return
    confirmRemove = false
    pendingForget = null
    service.removeAccount(setupUser)
    closeSetup()
  }

  function saveSelection() {
    if (service && setupChanges.length) service.applyCalendarStates(setupChanges)
    closeSetup()
  }
  readonly property var setupPreset: Logic.presetFor("iCloud")
  // An account being edited already holds a password, so the empty box is it
  // not being shown rather than an unanswered field — unless it is being
  // replaced, in which case the new one has to be typed.
  readonly property bool setupPasswordHeld:
    setupEditing && !setupChangingPassword
  readonly property bool passwordRevealed:
    !!(service && service.revealedPassword)
  readonly property string setupProblem: Logic.accountProblem(
    setupUser, setupPreset.server, setupPassword, setupPasswordHeld)

  function openSetup() {
    settingsOpen = false
    searchOpen = false
    setupEditing = false
    setupChangingPassword = false
    setupUser = ""
    setupPassword = ""
    setupNotice = ""
    setupSelection = ({})
    setupHasCalendars = false
    confirmRemove = false
    pendingForget = null
    if (service) service.hidePassword()
    setupOpen = true
  }

  // The same form, filled in: a password cannot be read back out of the
  // keyring, so editing means entering it again.
  function editAccount() {
    settingsOpen = false
    searchOpen = false
    setupEditing = true
    setupChangingPassword = false
    setupUser = service ? service.account : ""
    setupPassword = ""
    setupNotice = ""
    setupHasCalendars = true
    confirmRemove = false
    pendingForget = null
    if (service) service.hidePassword()
    seedSelection()
    setupOpen = true
  }

  function startPasswordChange() {
    setupChangingPassword = true
    setupPassword = ""
    if (service) service.hidePassword()
  }

  function closeSetup() {
    setupOpen = false
    setupChangingPassword = false
    setupPassword = ""
    setupNotice = ""
    setupSelection = ({})
    setupHasCalendars = false
    confirmRemove = false
    pendingForget = null
    if (service) service.hidePassword()
  }

  function connectAccount() {
    if (!canConnect || !service) return
    setupNotice = ""
    service.addAccount(setupUser.trim(), setupPreset.server, setupPassword)
  }

  // Which view the month column shows. Only Month draws today; Day and Week
  // are next, so the group selects but the grid below it does not change yet.
  // Seeded from the setting the first time it arrives, and written back
  // whenever the view changes: picking Week and closing the card should not
  // put you back on Month, and the setting is what "opens on" means.
  property string viewMode: "Month"
  property bool viewSeeded: false

  function seedView() {
    if (viewSeeded || !service || !service.settingsLoaded) return
    viewSeeded = true
    viewMode = Logic.viewFromKey(service.setting("defaultView", "month"))
  }

  function setView(mode) {
    viewMode = mode
    if (viewSeeded) setPref("defaultView", Logic.viewKey(mode))
  }



  // A rule is set off from what it divides by the same distance the card
  // holds at its own edge, so headers and the footer read as bands of even
  // depth. The columns space their children by md, so spacers make up the
  // difference where the gap is not an anchor margin — less twice the
  // spacing, since a Column applies it on both sides of the spacer.
  readonly property int ruleGap: Style.spacing.popupPadding

  // Half that, for the places a heading should read as belonging to what
  // follows it rather than sitting between two sections: the day column's two
  // headings, the calendar list under its rule, the weekday row under its.
  readonly property int halfRuleGap: Math.round(ruleGap / 2)

  // A rule between two groups of a form — the edit form's and the
  // settings' — gets twice the space a rule gets anywhere else on the card,
  // so a long form reads as groups rather than as one list. Title bars keep
  // the card's own spacing.
  //
  // The column already puts `md` either side of the rule; FormRule adds
  // another `md` inside its own height. Not a pair of spacer Items: a
  // Column skips an Item of zero height, spacing and all, so spacers that
  // came out at zero were never there — and one that is not zero adds its
  // own gap of spacing as well.
  readonly property int formRuleInset: Style.spacing.md

  // Square, so a glyph sits dead centre both ways. Text buttons take the same
  // height so a row of them has one baseline.
  readonly property int controlSize: Style.space(30)

  // Every box in a form is one height, so a field, the dropdown under it and
  // the square button beside it share their top and bottom edges. A
  // TextField sizes itself from its font and a Button from `controlSize`, and
  // the two do not land on the same number on their own — this takes
  // whichever is taller. omedia measures a row off a hidden probe the same
  // way, rather than guessing at the arithmetic.
  readonly property int fieldHeight: Math.max(controlSize, fieldProbe.implicitHeight)

  TextField {
    id: fieldProbe
    visible: false
    text: "Ag"
  }

  // How tall one line of each size actually is, measured rather than guessed
  // from the pixel size — a marker that has to sit on a line needs the line's
  // real height, and a font's ascent and descent are its own business.
  readonly property int bodyLine: bodyProbe.implicitHeight
  readonly property int captionLine: captionProbe.implicitHeight
  readonly property int titleLine: titleProbe.implicitHeight
  readonly property int bodySmallLine: bodySmallProbe.implicitHeight

  Text {
    id: bodySmallProbe
    visible: false
    text: "Ag"
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Text {
    id: titleProbe
    visible: false
    text: "Ag"
    font.family: root.fontFamily
    font.pixelSize: Style.font.title
    font.bold: true
  }

  Text {
    id: bodyProbe
    visible: false
    text: "Ag"
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  Text {
    id: captionProbe
    visible: false
    text: "Ag"
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  signal addCalendarRequested()

  // omedia sources both of these from the bar and uses them on every label
  // and control; the fallbacks are only for a panel built without one.
  readonly property color foreground: bar ? bar.foreground : Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // omedia's rules are 2px, through a local alias over PanelSeparator.
  component Rule: PanelSeparator {
    height: 2
  }

  component FormRule: Item {
    width: parent ? parent.width : 0
    height: 2 + root.formRuleInset * 2

    Rule {
      y: root.formRuleInset
      width: parent.width
    }
  }

  // One row of a dropdown — the Picker's, and every suggestion list's — so
  // the two cannot drift apart. A label, an optional note on the right in
  // the subdued colour, the hover fill, bold when it is the current value.
  component MenuRow: Rectangle {
    id: menuRow
    property string label: ""
    property string note: ""
    property bool chosen: false
    // Wrapping rows grow to fit their label instead of eliding it.
    property bool wrap: false
    // Lit by the keyboard, the way the pointer lights it by hovering.
    property bool highlighted: false
    readonly property bool lit: menuRowArea.containsMouse || highlighted
    signal activated()

    height: wrap
      ? Math.max(Style.spacing.popupRowHeight,
                 menuRowLabel.implicitHeight + Style.spacing.controlPaddingY * 2)
      : Style.spacing.popupRowHeight
    radius: Style.spacing.labelGap
    color: lit ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"

    Text {
      id: menuRowNote
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Style.spacing.controlPaddingX
      // At most half the row, so a long address never crowds out the label.
      width: Math.min(implicitWidth, menuRow.width * 0.5)
      elide: Text.ElideMiddle
      visible: menuRow.note !== ""
      textFormat: Text.PlainText
      text: menuRow.note
      color: root.subdued
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: menuRowLabel
      anchors.left: parent.left
      anchors.right: menuRowNote.visible ? menuRowNote.left : parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.controlPaddingX
      textFormat: Text.PlainText
      text: menuRow.label
      wrapMode: menuRow.wrap ? Text.WordWrap : Text.NoWrap
      elide: menuRow.wrap ? Text.ElideNone : Text.ElideRight
      color: menuRow.lit
        ? Style.hoverStateColor(root.foreground, Color.accent)
        : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: menuRow.chosen
    }

    MouseArea {
      id: menuRowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: menuRow.activated()
    }
  }

  // A line in a dropdown that is not a choice — "Searching…", a failure,
  // a credit — set in from the edge the way a row's label is.
  component MenuCaption: Item {
    property alias text: menuCaptionText.text
    property alias color: menuCaptionText.color
    height: Math.max(Style.spacing.popupRowHeight, menuCaptionText.implicitHeight)

    Text {
      id: menuCaptionText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.controlPaddingX
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      color: root.subdued
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // The popup every dropdown on the card opens, as tall as its rows plus
  // the padding. The same flat outline every other surface on the card
  // wears. The kit's dropdown uses `Color.popups.border` here, which on this
  // theme is a green gradient: it brightens around the shape and blazes at
  // the corners, so a two-line menu ends up the loudest thing on screen and
  // matches nothing next to it — least of all the trigger it drops out of.
  component MenuPopup: Popup {
    padding: Style.spacing.hairline

    background: BorderSurface {
      color: Color.popups.background
      radius: Style.cornerRadius
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
    }
  }

  // A dropdown of suggestions under a field that is still being typed in.
  // It never covers that field: it opens below it when the rows fit there,
  // above it when there is more room above, and scrolls when neither side
  // holds them all. The room is the card's own — a list that ran past the
  // card's edge would be drawn over whatever is behind it.
  component SuggestMenu: MenuPopup {
    id: suggestMenu
    property Item anchor: null
    default property alias rows: suggestRows.data
    readonly property real natural: suggestRows.implicitHeight + topPadding + bottomPadding

    focus: false
    margins: -1
    closePolicy: Popup.CloseOnPressOutsideParent

    function fit() {
      if (!anchor) return
      var gap = Style.spacing.xxs
      var edge = Style.spacing.md
      var top = anchor.mapToItem(keyCatcher, 0, 0).y
      var below = keyCatcher.height - (top + anchor.height + gap) - edge
      var above = top - gap - edge
      var downward = natural <= below || below >= above
      height = Math.max(Style.spacing.popupRowHeight,
                        Math.min(natural, downward ? below : above))
      y = downward ? anchor.height + gap : -height - gap
    }

    onAboutToShow: fit()
    onNaturalChanged: if (opened) fit()

    contentItem: Flickable {
      clip: true
      contentHeight: suggestRows.implicitHeight
      boundsBehavior: Flickable.StopAtBounds
      ScrollBar.vertical: ScrollBar {
        policy: suggestRows.implicitHeight > suggestMenu.availableHeight
                ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      }

      Column {
        id: suggestRows
        width: suggestMenu.availableWidth
        spacing: Style.spacing.labelGap
      }
    }
  }

  // A dropdown that does not move under the pointer.
  //
  // qs.Ui's `Dropdown` sizes its popup by hand — every row, plus the gaps,
  // plus `xxs` — and then pays the border and hairline padding out of that
  // total. The list ends up two pixels shorter than its own content, so the
  // last row is clipped; hovering it sets the ListView's currentIndex, the
  // view scrolls two pixels to contain it, and every row jumps. The shortfall
  // is `xxs - 2 * (1 + hairline)`, which does not depend on the row height or
  // the number of options, so no caller can size its way out of it.
  //
  // This one has no arithmetic to get wrong: a Column of rows inside a Popup
  // that takes its height from them. A list that always fits cannot scroll,
  // and a list that cannot scroll cannot jump. The trigger is the kit's, down
  // to the fill and border states, so it still looks like every other control
  // on the card.
  component Picker: Item {
    id: picker
    property var options: []
    property string value: ""
    property int rowHeight: root.fieldHeight

    implicitHeight: rowHeight
    height: rowHeight
    signal picked(string value)

    readonly property bool open: menu.opened
    // The row the keyboard is on while the menu is open.
    property int current: -1

    function step(by) {
      if (!options.length) return
      current = Math.max(0, Math.min(options.length - 1, (current < 0 ? -1 : current) + by))
    }

    function labelFor(wanted) {
      for (var i = 0; i < options.length; i++)
        if (String(options[i].value) === String(wanted)) return options[i].label
      return wanted
    }

    // The chosen row's note, shown on the closed trigger as in the list, so
    // two options with one name can be told apart before it is opened.
    function noteFor(wanted) {
      for (var i = 0; i < options.length; i++)
        if (String(options[i].value) === String(wanted)) return options[i].note || ""
      return ""
    }

    BorderSurface {
      id: trigger
      anchors.fill: parent
      radius: Style.cornerRadius

      readonly property bool hot: triggerArea.containsMouse || menu.opened
      color: Style.controlFill(menu.opened, trigger.hot, root.foreground, Color.accent)
      borderSpec: Border.controlSpec(menu.opened ? "focus"
                                   : trigger.hot ? "hover-cursor" : "normal",
                                     root.foreground, Color.accent)

      Text {
        id: triggerNote
        anchors.right: chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.md
        width: Math.min(implicitWidth, trigger.width * 0.45)
        elide: Text.ElideMiddle
        visible: text !== ""
        textFormat: Text.PlainText
        text: picker.noteFor(picker.value)
        color: root.subdued
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.left: parent.left
        anchors.right: triggerNote.visible ? triggerNote.left : chevron.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.spacing.controlPaddingX
        anchors.rightMargin: Style.spacing.md
        textFormat: Text.PlainText
        text: picker.labelFor(picker.value)
        elide: Text.ElideRight
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      Text {
        id: chevron
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.spacing.controlGap
        textFormat: Text.PlainText
        text: "\udb80\udd40"
        color: Qt.darker(root.foreground, 1.2)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      MouseArea {
        id: triggerArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menu.opened ? menu.close() : menu.open()
      }
    }

    MenuPopup {
      id: menu
      y: picker.rowHeight + Style.spacing.xxs
      width: picker.width
      // No implicitHeight of its own: it is however tall the rows are plus
      // the padding, which is the whole point.

      // Opened by the pointer or not, the keyboard can take it from there:
      // arrows move, Enter or Space picks, Escape closes.
      onOpened: {
        picker.current = -1
        for (var i = 0; i < picker.options.length; i++)
          if (String(picker.options[i].value) === String(picker.value)) picker.current = i
        menuRows.forceActiveFocus()
      }
      onClosed: keyCatcher.forceActiveFocus()

      contentItem: Column {
        id: menuRows
        spacing: Style.spacing.labelGap
        focus: true

        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Down) { picker.step(1); event.accepted = true }
          else if (event.key === Qt.Key_Up) { picker.step(-1); event.accepted = true }
          else if (event.key === Qt.Key_Escape) { menu.close(); event.accepted = true }
          else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space) && picker.current >= 0) {
            var chosen = picker.options[picker.current]
            menu.close()
            picker.picked(String(chosen.value))
            event.accepted = true
          }
        }

        Repeater {
          model: picker.options

          MenuRow {
            required property var modelData
            required property int index
            highlighted: index === picker.current
            width: menu.availableWidth
            label: modelData.label
            note: modelData.note || ""
            chosen: String(modelData.value) === String(picker.value)
            onActivated: {
              menu.close()
              picker.picked(String(modelData.value))
            }
          }
        }
      }
    }
  }

  // The same rule stood on its end, for the lines between the columns. Built
  // on `PanelSeparator` like the horizontal one rather than hand-rolled, so
  // the two cannot drift apart in weight or tint — they were 1px against the
  // horizontal rules' 2 until this.
  component VRule: PanelSeparator {
    width: 2
  }

  // Every list in the card scrolls the same way, and its bar belongs beside
  // what it is scrolling rather than on top of it. The viewport reaches
  // `gutter` further right than its content — into the padding the layout
  // already leaves before the next rule — and the bar rides in there, so a
  // list that overflows never loses its last few pixels of text.
  //
  // `contentWidth` stops short of the gutter, which is what keeps the
  // content where it was: a child bound to `parent.width` still measures the
  // column, not the column plus the bar.
  //
  // Callers give it a top, a bottom and a `contentHeight`. The sides, the
  // clipping and the bar are the same everywhere.
  component Scroller: Flickable {
    id: scroller
    property int gutter: root.ruleGap

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.rightMargin: -gutter
    contentWidth: Math.max(0, width - gutter)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    ScrollBar.vertical: ScrollBar {
      // Centred in the gutter rather than shoved against the rule beyond it.
      rightPadding: Math.max(2, Math.round((scroller.gutter - 6) / 2))
      policy: scroller.contentHeight > scroller.height
              ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
    }
  }

  // A preference and its switch, laid out the way omedia lays its own out:
  // the name over an explanation of what turning it off costs, the switch on
  // the right, the whole row clickable.
  component SettingSwitch: Item {
    id: settingSwitch
    property string label: ""
    property string hint: ""
    property bool checked: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(settingText.implicitHeight, settingToggle.implicitHeight)
    height: implicitHeight

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: settingSwitch.toggled()
    }

    Column {
      id: settingText
      anchors.left: parent.left
      anchors.right: settingToggle.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: settingSwitch.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        visible: text !== ""
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        text: settingSwitch.hint
        color: root.subdued
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    ToggleSwitch {
      id: settingToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: settingSwitch.checked
      foreground: root.foreground
      onToggled: settingSwitch.toggled()
    }
  }

  // A preference with a handful of answers, as a row of equal buttons — the
  // shape omedia gives its seek and volume steps. `options` is [{value,label}]
  // and `value` is compared as a string, because that is what a Dropdown
  // beside it would emit and one comparison rule is easier to hold than two.
  component SettingChoice: Column {
    id: settingChoice
    property string label: ""
    property string hint: ""
    property var options: []
    property string value: ""
    signal picked(string value)

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: settingChoice.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      width: parent.width
      visible: text !== ""
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
      text: settingChoice.hint
      color: root.subdued
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      id: choiceRow
      width: parent.width
      spacing: Style.spacing.sm

      Repeater {
        model: settingChoice.options

        Button {
          required property var modelData
          width: (choiceRow.width - choiceRow.spacing * (settingChoice.options.length - 1))
                 / settingChoice.options.length
          height: root.controlSize
          bordered: true
          text: modelData.label
          selected: String(settingChoice.value) === String(modelData.value)
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: settingChoice.picked(String(modelData.value))
        }
      }
    }
  }

  // A calendar in the list, built on the row omedia's library browses with:
  // a BorderSurface at Style.space(30), filled when selected and again under
  // the pointer, outlined when selected, with a glyph and one label. Its
  // search results use a taller two-line row; this list is the browse one.
  component CalendarRow: BorderSurface {
    id: row
    property var entry: ({})
    property color foreground: "white"
    property string fontFamily: ""
    readonly property bool picked: entry.enabled !== false
    readonly property bool failed: !!entry.error
    readonly property bool syncing:
      !!(root.service && root.service.syncingCalendar === entry.url)
    signal toggled()
    signal syncRequested()

    // The calendar's own colour, not the theme accent: on a list where every
    // row is a different calendar, the fill is the quickest way to tell which
    // is which, and it already matches the events on the month. A departure
    // from omedia's library row, which has one accent because it lists one
    // kind of thing.
    readonly property color tint: entry.color || Color.accent

    height: Style.space(30)
    radius: Style.spacing.labelGap
    color: row.picked ? Util.alpha(row.tint, 0.2)
         : rowArea.containsMouse ? Style.normalFillFor(row.foreground, Color.accent)
         : "transparent"
    // No outline. The fill is the calendar's colour and it already says which
    // rows are on; a border around it only competed with that.
    borderSpec: Border.none()

    MouseArea {
      id: rowArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: row.toggled()
    }

    // This calendar alone, for when only it is suspected of being behind.
    // Always there rather than appearing under the pointer: a control that
    // only exists while you are on top of it cannot be found by looking.
    // Its own sibling, not part of the row beside it, so the gap before it
    // can be tighter than the one between the box and the name.
    Button {
      id: rowSync
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      height: Style.space(22)
      iconText: "\uf021"
      iconSize: Style.font.caption
      iconSpinning: row.syncing
      horizontalPadding: Style.space(3)
      verticalPadding: Style.space(1)
      tooltipText: "Sync this calendar"
      foreground: row.foreground
      fontFamily: row.fontFamily
      onClicked: row.syncRequested()
    }

    Row {
      anchors.left: parent.left
      anchors.right: rowSync.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      // The calendar's own colour carries the identity, so the box takes it
      // rather than the foreground a track row uses. Hidden is the same box
      // as an outline, so the colour still reads.
      Text {
        id: rowIcon
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: row.picked ? "\uf14a" : "\uf096"
        color: row.entry.color || Color.accent
        opacity: row.picked ? 1.0 : 0.7
        font.family: row.fontFamily
        font.pixelSize: Style.font.icon
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - rowIcon.width - parent.spacing
        textFormat: Text.PlainText
        // One line, like the browse row. A calendar that failed to sync says
        // so by colour; the message itself is in the panel's footer.
        text: Logic.singleLine(row.entry.name)
        elide: Text.ElideRight
        color: row.failed ? root.danger : row.foreground
        font.family: row.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: row.picked
      }
    }
  }

  // One labelled block in the event viewer: a caps label over however many
  // lines it has, and gone entirely when it has none. Most of what a CalDAV
  // event carries is absent most of the time, and a viewer full of empty
  // headings says less than one that only shows what is there.
  component DetailField: Column {
    property string label: ""
    property var lines: []

    width: parent ? parent.width : 0
    visible: lines.length > 0
    spacing: Style.space(2)

    // Every part is ruled off from what is above it, and the rule travels
    // with the part — so one that has nothing to say takes its divider with
    // it and never leaves a line over a gap. The header's own rule is this
    // one on whichever part comes first.
    Rule { width: parent.width }

    Item {
      width: 1
      height: Math.max(0, Style.spacing.md - Style.space(2) * 2)
    }

    PanelSectionHeader { width: parent.width; text: parent.label }

    Repeater {
      model: parent.lines

      Text {
        required property string modelData
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: modelData
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  // ------------------------------------------------------- editor controls
  //
  // The kit has a single-line field and a dropdown, and nothing for a date,
  // a time or a paragraph. These three are built from the same parts as the
  // Picker — a BorderSurface trigger in the kit's fill and border states, a
  // Popup in the card's flat outline — so the form reads as one set.

  // One suggestion under a field: a line of what it is, a line of detail,
  // the whole row clickable. The shape the invitee suggestions use.
  component SuggestionRow: Rectangle {
    id: suggestion
    property string title: ""
    property string detail: ""
    signal chosen()

    width: parent ? parent.width : 0
    height: suggestionLines.implicitHeight + Style.space(8)
    radius: Style.spacing.labelGap
    color: suggestionHover.containsMouse
      ? Style.hoverFillFor(root.foreground, Color.accent)
      : Style.normalFillFor(root.foreground, Color.accent)

    Column {
      id: suggestionLines
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.spacing.controlPaddingX
      anchors.verticalCenter: parent.verticalCenter

      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: suggestion.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        visible: suggestion.detail !== ""
        elide: Text.ElideRight
        textFormat: Text.PlainText
        text: suggestion.detail
        color: root.subdued
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: suggestionHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: suggestion.chosen()
    }
  }

  // A label over whatever field follows it, in the settings' own type.
  component FormLabel: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  // The trigger every popup field opens from: its value, a glyph on the
  // right, and the kit's states. `open` is the popup's, so it lights while
  // the popup is up the way the Picker does.
  component FieldTrigger: BorderSurface {
    id: fieldTrigger
    property string text: ""
    property string glyph: "\udb80\udd40"
    property bool open: false
    signal clicked()

    height: root.fieldHeight
    radius: Style.cornerRadius
    readonly property bool hot: fieldArea.containsMouse || open
    color: Style.controlFill(open, hot, root.foreground, Color.accent)
    borderSpec: Border.controlSpec(open ? "focus" : hot ? "hover-cursor" : "normal",
                                   root.foreground, Color.accent)

    Text {
      anchors.left: parent.left
      anchors.right: fieldGlyph.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.spacing.controlPaddingX
      anchors.rightMargin: Style.space(6)
      textFormat: Text.PlainText
      text: fieldTrigger.text
      elide: Text.ElideRight
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: fieldGlyph
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: Style.spacing.controlGap
      textFormat: Text.PlainText
      text: fieldTrigger.glyph
      color: Qt.darker(root.foreground, 1.2)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: fieldArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: fieldTrigger.clicked()
    }
  }

  // A time zone, picked from all of them by typing part of a place: the
  // list is the helper's, searched here. Opened, it takes the keyboard —
  // type to narrow, Up and Down to move, Enter to choose, Escape to leave.
  component ZoneField: Item {
    id: zoneField
    property string value: ""
    signal picked(string value)

    implicitHeight: root.fieldHeight
    height: root.fieldHeight

    property string query: ""
    property int current: 0
    readonly property var zones: root.service ? root.service.zones : []
    readonly property var rows: Logic.zoneChoices(zones, query, root.localZone, 40)
    onQueryChanged: current = 0

    function choose(i) {
      if (i < 0 || i >= rows.length) return
      zonePop.close()
      zoneField.picked(rows[i].value)
    }

    FieldTrigger {
      anchors.fill: parent
      text: Logic.zoneLabel(zoneField.value, zoneField.zones, root.localZone)
      glyph: "\uf0ac"
      open: zonePop.opened
      onClicked: zonePop.opened ? zonePop.close() : zonePop.open()
    }

    MenuPopup {
      id: zonePop
      y: zoneField.height + Style.spacing.xxs
      width: zoneField.width
      height: Math.min(Style.space(300),
                       zoneColumn.implicitHeight + topPadding + bottomPadding)
      margins: 0

      onOpened: { zoneField.query = ""; zoneSearch.text = ""; zoneSearch.forceActiveFocus() }
      onClosed: keyCatcher.forceActiveFocus()

      contentItem: Column {
        id: zoneColumn
        spacing: Style.spacing.labelGap

        TextField {
          id: zoneSearch
          width: zonePop.availableWidth
          height: root.fieldHeight
          placeholderText: "Search a city or region"
          foreground: root.foreground
          onTextEdited: zoneField.query = text
          Keys.onPressed: function (event) {
            if (event.key === Qt.Key_Down) {
              zoneField.current = Math.min(zoneField.rows.length - 1, zoneField.current + 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              zoneField.current = Math.max(0, zoneField.current - 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              zoneField.choose(zoneField.current)
              event.accepted = true
            } else if (event.key === Qt.Key_Escape) {
              zonePop.close()
              event.accepted = true
            }
          }
        }

        Flickable {
          id: zoneScroll
          width: zonePop.availableWidth
          height: Math.min(contentHeight, Style.space(240))
          contentHeight: zoneList.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: zoneList
            width: zoneScroll.width
            spacing: Style.spacing.labelGap

            Repeater {
              model: zoneField.rows
              MenuRow {
                required property var modelData
                required property int index
                width: zoneList.width
                label: modelData.label
                note: modelData.note
                chosen: modelData.value === zoneField.value
                highlighted: index === zoneField.current
                onActivated: zoneField.choose(index)
              }
            }
          }
        }

        MenuCaption {
          visible: zoneField.rows.length === 0
          width: zonePop.availableWidth
          text: zoneField.zones.length ? "No time zone matches that." : "Loading time zones\u2026"
        }
      }
    }
  }

  // A date, picked off a month. The month is the card's own grid function,
  // so the week starts where the card's does and today is marked the same.
  component DateField: Item {
    id: dateField
    property string value: ""
    signal picked(string value)

    implicitHeight: root.fieldHeight
    height: root.fieldHeight

    // The month on show in the popup, reset to the value's each time it
    // opens rather than left wherever it was last paged to.
    property int shownYear: 2026
    property int shownMonth: 1

    function page(step) {
      var m = shownMonth + step, y = shownYear
      while (m < 1) { m += 12; y -= 1 }
      while (m > 12) { m -= 12; y += 1 }
      shownYear = y
      shownMonth = m
    }

    FieldTrigger {
      anchors.fill: parent
      text: Logic.shortDate(dateField.value)
      glyph: "\uf073"
      open: calendarPop.opened
      onClicked: {
        if (calendarPop.opened) { calendarPop.close(); return }
        var p = Logic.parseKey(Logic.isDateKey(dateField.value)
                               ? dateField.value : root.todayKey)
        dateField.shownYear = p.y
        dateField.shownMonth = p.m
        calendarPop.open()
      }
    }

    Popup {
      id: calendarPop
      y: dateField.height + Style.spacing.xxs
      width: Math.max(dateField.width, Style.space(224))
      padding: Style.spacing.md
      // Kept inside the card: near the foot of the form the month moves up
      // over its field rather than running off the bottom.
      margins: 0

      background: BorderSurface {
        color: Color.popups.background
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
      }

      contentItem: Column {
        spacing: Style.space(4)

        Item {
          width: calendarPop.availableWidth
          height: root.controlSize

          Button {
            anchors.left: parent.left
            width: root.controlSize
            height: root.controlSize
            iconText: "\uf053"
            tooltipText: "Previous month"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: dateField.page(-1)
          }

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: Logic.monthLabel(dateField.shownYear, dateField.shownMonth)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          Button {
            anchors.right: parent.right
            width: root.controlSize
            height: root.controlSize
            iconText: "\uf054"
            tooltipText: "Next month"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: dateField.page(1)
          }
        }

        Grid {
          id: dateGrid
          columns: 7
          readonly property real cell: calendarPop.availableWidth / 7

          Repeater {
            model: Logic.weekdayLabels(root.weekStartDay, 2)

            Text {
              required property string modelData
              width: dateGrid.cell
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: modelData
              color: root.subdued
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: Logic.monthGrid(dateField.shownYear, dateField.shownMonth,
                                   root.weekStartDay, root.todayKey)

            Rectangle {
              required property var modelData
              readonly property bool chosen: modelData.key === dateField.value
              width: dateGrid.cell
              height: Math.round(dateGrid.cell * 0.9)
              radius: Style.spacing.labelGap
              color: chosen ? Style.selectedFillFor(root.foreground, Color.accent)
                   : dayArea.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent)
                   : "transparent"
              border.width: modelData.isToday ? 1 : 0
              border.color: Color.accent

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: String(parent.modelData.day)
                color: parent.modelData.inMonth ? root.foreground : root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: parent.chosen
              }

              MouseArea {
                id: dayArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  calendarPop.close()
                  dateField.picked(parent.modelData.key)
                }
              }
            }
          }
        }
      }
    }
  }

  // A time, off a list of every quarter hour. Ninety-six rows do not fit
  // on a card the way a Picker's handful do, so this one scrolls — and it
  // opens scrolled to the time it holds, not to midnight.
  component TimeField: Item {
    id: timeField
    property string value: ""
    signal picked(string value)

    implicitHeight: root.fieldHeight
    height: root.fieldHeight

    readonly property var choices: Logic.timeChoices(root.timeFormat, value)

    function labelFor(wanted) {
      for (var i = 0; i < choices.length; i++)
        if (choices[i].value === wanted) return choices[i].label
      return wanted
    }

    FieldTrigger {
      anchors.fill: parent
      text: timeField.labelFor(timeField.value)
      open: timePop.opened
      onClicked: timePop.opened ? timePop.close() : timePop.open()
    }

    Popup {
      id: timePop
      y: timeField.height + Style.spacing.xxs
      width: Math.max(timeField.width, Style.space(110))
      height: Math.min(Style.space(220), timeList.implicitHeight + padding * 2)
      padding: Style.spacing.hairline
      margins: 0

      onOpened: {
        for (var i = 0; i < timeField.choices.length; i++) {
          if (timeField.choices[i].value !== timeField.value) continue
          var row = Style.spacing.popupRowHeight + Style.spacing.labelGap
          // A few rows of context above it, so it is not the top line.
          timeScroll.contentY = Math.max(0, Math.min(
            i * row - row * 3, timeScroll.contentHeight - timeScroll.height))
          break
        }
      }

      background: BorderSurface {
        color: Color.popups.background
        radius: Style.cornerRadius
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
      }

      contentItem: Flickable {
        id: timeScroll
        clip: true
        contentHeight: timeList.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: timeList
          width: timeScroll.width
          spacing: Style.spacing.labelGap

          Repeater {
            model: timeField.choices

            Rectangle {
              required property var modelData
              readonly property bool chosen: modelData.value === timeField.value
              width: timeList.width
              height: Style.spacing.popupRowHeight
              radius: Style.spacing.labelGap
              color: timeArea.containsMouse
                ? Style.hoverFillFor(root.foreground, Color.accent)
                : chosen ? Style.selectedFillFor(root.foreground, Color.accent)
                : "transparent"

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.controlPaddingX
                textFormat: Text.PlainText
                text: parent.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: parent.chosen
              }

              MouseArea {
                id: timeArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  timePop.close()
                  timeField.picked(parent.modelData.value)
                }
              }
            }
          }
        }
      }
    }
  }

  // A paragraph. The kit's TextField is one line, and notes are rarely one,
  // so this is Qt's TextArea dressed the way that field dresses itself.
  component NoteField: TextArea {
    id: noteField
    readonly property var edgeSpec: Border.controlSpec(
      activeFocus ? "focus" : hovered ? "hover-cursor" : "normal",
      root.foreground, Color.accent)

    wrapMode: TextEdit.Wrap
    textFormat: TextEdit.PlainText
    color: root.foreground
    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
    selectedTextColor: root.foreground
    placeholderTextColor: Qt.darker(root.foreground, 1.6)
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    leftPadding: Style.spacing.controlPaddingX + Border.left(edgeSpec)
    rightPadding: Style.spacing.controlPaddingX + Border.right(edgeSpec)
    topPadding: Style.spacing.inputPaddingY + Border.top(edgeSpec)
    bottomPadding: Style.spacing.inputPaddingY + Border.bottom(edgeSpec)
    // Three lines before it grows, so it looks like somewhere to write.
    property int minLines: 3
    implicitHeight: Math.max(contentHeight, root.bodyLine * minLines)
                    + topPadding + bottomPadding

    background: BorderSurface {
      color: Style.controlFill(noteField.activeFocus, noteField.hovered,
                               root.foreground, Color.accent)
      borderSpec: noteField.edgeSpec
      radius: Style.cornerRadius
    }
  }

  // A heading over its count, in the shape the calendar list uses for its
  // provider over its account.
  component DaySection: Column {
    property string title: ""
    property int count: 0
    // Set when the line under the heading counts something that is not an
    // event, as the calendar chooser's does.
    property string subtitle: ""
    spacing: Style.space(2)

    PanelSectionHeader {
      width: parent.width
      elide: Text.ElideRight
      text: parent.title
      // PanelSectionHeader darkens its foreground by 1.4, which is right for
      // a label introducing the rows under it. Every DaySection names a whole
      // panel instead — SETTINGS, CALENDARS, ALL DAY, SCHEDULED — so each one
      // is lit, and the titles are written upper-case at the call site the
      // way omedia writes UPDATES and KEYBOARD.
      color: root.foreground
    }

    Text {
      width: parent.width
      elide: Text.ElideRight
      text: parent.subtitle !== "" ? parent.subtitle
                                   : Logic.eventCountLabel(parent.count)
      color: root.subdued
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One event in the selected day: time over title over location, with the
  // calendar's colour as a rule down the left.
  component DayEntry: Item {
    id: dayEntry
    property var event: ({})
    property string timeFormat: "12h"
    // Cut off at the column's edge, or wrapped onto as many lines as it
    // takes. The time line never wraps: it is eight characters and always
    // fits, and letting it wrap would only ever be a rendering accident.
    property bool wrap: false
    signal activated()

    implicitHeight: entry.implicitHeight

    // The ground under the whole row, so the pointer has something to land
    // on either side of the text as well as on it.
    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.spacing.xs
      anchors.rightMargin: -Style.spacing.xs
      anchors.topMargin: -Style.spacing.xxs
      anchors.bottomMargin: -Style.spacing.xxs
      radius: Style.spacing.labelGap
      color: entryArea.containsMouse
        ? Style.normalFillFor(root.foreground, Color.accent) : "transparent"
    }

    // The card has one grammar for this: a bar is an all-day event, a dot is
    // one with a time. The month already reads that way — bars spanning the
    // days they cover, dotted chips for appointments — so the day column and
    // the viewer say it the same way rather than marking everything alike.
    readonly property bool wholeDay: !!dayEntry.event.allDay

    Rectangle {
      visible: dayEntry.wholeDay
      width: Style.space(3)
      height: entry.implicitHeight
      // Square, like every other block of colour on the month.
      color: root.colorOf(dayEntry.event)
    }

    // Sat on the title rather than the time above it: the title is what the
    // dot marks, and it is the line the eye lands on.
    Rectangle {
      visible: !dayEntry.wholeDay
      width: Style.space(5)
      height: width
      radius: width / 2
      y: root.captionLine + Math.round((root.bodyLine - height) / 2)
      color: root.colorOf(dayEntry.event)
    }

    Column {
      id: entry
      // The same gap the list rows put between their glyph and their label.
      x: Style.space(10)
      width: dayEntry.width - Style.space(10)
      spacing: 0

      Text {
        width: parent.width
        elide: Text.ElideRight
        // A change of ours not yet on iCloud says so where its time is.
        text: Logic.formatRange(dayEntry.event, dayEntry.timeFormat)
          + (dayEntry.event.pending ? "  \u00b7  \uf017 not sent yet" : "")
        color: root.subdued
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        wrapMode: dayEntry.wrap ? Text.WordWrap : Text.NoWrap
        elide: dayEntry.wrap ? Text.ElideNone : Text.ElideRight
        // Still collapsed to one logical line first: iCloud writes titles
        // across several, and wrapping is meant to follow the column's width
        // rather than whatever the server happened to put a newline in.
        text: Logic.singleLine(dayEntry.event.title)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      // One line per line of the address, each elided on its own — a single
      // Text would draw every line and only trim the last.
      Repeater {
        model: Logic.locationLines(dayEntry.event.location)

        Text {
          required property string modelData
          width: entry.width
          wrapMode: dayEntry.wrap ? Text.WordWrap : Text.NoWrap
          elide: dayEntry.wrap ? Text.ElideNone : Text.ElideRight
          text: modelData
          color: root.subdued
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Declared last so it sits over the text rather than under it.
    MouseArea {
      id: entryArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: dayEntry.activated()
    }
  }

  // PanelHero indents its labels a fixed distance from its icon slot, and
  // applies that margin whether or not there is an icon — so a column without
  // one is pushed in for no reason. Same two lines, same trailing slot, same
  // type, flush to the column.
  component ColumnHeader: Item {
    id: header
    property string title: ""
    property string meta: ""
    property Component centerControl: null
    property Component trailingControl: null

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(labels.implicitHeight, centre.implicitHeight,
                             trailing.implicitHeight)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: parent.right
      // Stop short of whichever slot comes first. A centred slot begins at
      // (width - its width) / 2, so the labels must end that far from the
      // right edge plus a gap.
      anchors.rightMargin: centre.item
        ? Math.round((header.width + centre.width) / 2) + Style.space(12)
        : (trailing.item ? trailing.width + Style.space(12) : 0)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: text !== ""
        text: header.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        visible: text !== ""
        text: header.meta.toUpperCase()
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.2
        elide: Text.ElideRight
      }
    }

    Loader {
      id: centre
      sourceComponent: header.centerControl
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.verticalCenter: parent.verticalCenter
    }

    Loader {
      id: trailing
      sourceComponent: header.trailingControl
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // A date is centred in its circular bubble, so its glyphs start further in
  // than the bubble's own left edge. The weekday label above it takes the
  // same inset, measured rather than guessed so it holds at any font scale.
  // Two digits, since that is what all but nine of the cells carry.
  TextMetrics {
    id: dateMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    text: "30"
  }

  readonly property int dateInset:
    cellPadding + Math.round(Math.max(0, bubbleSize - dateMetrics.width) / 2)

  function loadWindow() {
    if (!service || !cells.length) return
    // One day of slack each side so an event running into the grid is caught.
    service.load(Logic.addDays(cells[0].key, -1),
                 Logic.addDays(cells[cells.length - 1].key, 2))
  }

  function stepMonth(delta) {
    var month = viewMonth + delta
    var year = viewYear
    while (month > 12) { month -= 12; year += 1 }
    while (month < 1) { month += 12; year -= 1 }
    viewMonth = month
    viewYear = year
    loadWindow()
  }

  // Days in Day view, months in the others. The arrows, the brackets and the
  // wheel all go through this so they cannot disagree about what a step is.
  function stepDay(delta) {
    var next = Logic.addDays(selectedKey, delta)
    selectedKey = next
    var moved = Logic.parseKey(next)
    if (moved.y !== viewYear || moved.m !== viewMonth) {
      viewYear = moved.y
      viewMonth = moved.m
    }
    loadWindow()
  }

  function stepView(delta) {
    if (viewMode === "Day") stepDay(delta)
    else if (viewMode === "Week") stepDay(delta * 7)
    else stepMonth(delta)
  }

  function goToday() {
    today = new Date()
    viewYear = today.getFullYear()
    viewMonth = today.getMonth() + 1
    selectedKey = todayKey
    loadWindow()
  }

  function refresh() {
    today = new Date()
    if (service) service.sync()
  }

  // Opening by hotkey or IPC moves no pointer, so a hover the bar is still
  // holding would keep the centre indicators revealed behind the panel. The
  // clock and weather panels shut them the same way.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function colorOf(event) {
    return event && event.color ? event.color : Color.accent
  }

  // The form has no way of knowing the helper succeeded; the service does.
  // Without this it sat there after a successful save, which reads as though
  // nothing happened.
  // A connection that worked says so and leaves the form open: the calendars
  // it just found are the point, and they are chosen here.
  property Connections settingsWatch: Connections {
    target: root.service
    function onSettingsLoadedChanged() { root.seedView() }
  }

  property Connections serviceWatch: Connections {
    target: root.service

    // `status` is a round trip, so the account and its calendars can arrive
    // after the form has already opened. Fill in what was not there yet
    // rather than leaving a blank field and an unseeded list.
    function onAccountChanged() {
      if (root.setupEditing && root.setupUser === "")
        root.setupUser = root.service.account
    }

    function onCalendarsChanged() {
      if (root.setupOpen && root.setupHasCalendars
          && Object.keys(root.setupSelection).length === 0)
        root.seedSelection()
    }

    function onAccountAdded() {
      root.setupChangingPassword = false
      root.setupPassword = ""
      root.setupNotice = "Connected."
      root.setupHasCalendars = true
      root.seedSelection()
    }
  }

  onOpenedChanged: {
    setCenterHoverRevealSuppressed(opened)
    if (opened) { today = new Date(); loadWindow() }
    // Dismissing the card drops the form with it, password included. Leaving
    // it staged would reopen on a half-filled form holding a secret.
    else closeSetup()
  }
  Component.onCompleted: {
    loadWindow()
    // The setting may already be in hand if this panel was built after a
    // status came back; if not, settingsWatch picks it up when it lands.
    seedView()
  }

  // KeyboardPanel, not PopupCard: it is the surface Omarchy's own panels and
  // the other bar plugins use, and it is what actually maps against the bar.
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(columns.width + panel.padding * 2)
    contentHeight: panel.fittedContentHeight(columns.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (dx !== 0) root.stepView(dx)
        // A vertical step is a bigger one of whatever the view counts in:
        // a week of days, four weeks, a year of months.
        if (dy !== 0) {
          if (root.viewMode === "Day") root.stepDay(dy * 7)
          else if (root.viewMode === "Week") root.stepDay(dy * 28)
          else root.stepMonth(dy * 12)
        }
      }
      onActivateRequested: root.goToday()
      // Escape peels one layer at a time: whatever is over the card goes
      // first, and only a card with nothing over it closes.
      onCloseRequested: {
        if (root.placeQuery !== "") root.placeQuery = ""
        else if (root.inviteeSuggestions.length > 0 && !root.inviteeDismissed)
          root.inviteeDismissed = true
        else if (root.consentKind !== "") root.consentKind = ""
        else if (root.pendingAction !== "") root.dismissAction()
        else if (root.editorOpen) root.requestCancel(null)
        else if (root.viewerOpen) root.closeEvent()
        else if (root.searchOpen) root.closeSearch()
        else if (root.pendingForget) root.pendingForget = null
        else if (root.helpOpen) root.helpOpen = false
        else root.close()
      }
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (key) {
        if (key === "[") root.stepView(-1)
        else if (key === "]") root.stepView(1)
        else if (key === "t" || key === "T") root.goToday()
      }

      Row {
        id: columns
        spacing: 0
        width: root.sidebarWidth * 2 + divider.width + dayDivider.width
               + calendarColumn.width

        // ------------------------------------------------- calendars panel

        Item {
          id: sidebar
          width: root.sidebarWidth
          // As tall as the month beside it, so the footer can sit on the
          // bottom of the card rather than under the list.
          implicitHeight: calendarColumn.implicitHeight

          Column {
            id: sidebarHead
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.md

          // Same hero the omedia popup is headed by: glyph, title over a
          // letter-spaced meta line, and a trailing control.
          PanelHero {
            width: sidebar.width
            title: "Calendar"
            // PanelHero uppercases and letter-spaces this line itself.
            meta: "Omarcal"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "\uf073"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            // omedia builds every control from qs.Ui's Button, always
            // bordered, always taking its colour and family from the bar.
            trailingControl: Component {
              Row {
                spacing: Style.spacing.md

                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf002"
                  tooltipText: "Search"
                  selected: root.searchOpen
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.toggleSearch()
                }

                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf021"
                  // The glyph turns while the sync runs, which is the only
                  // sign a warm sync gives: it answers in well under a second.
                  iconSpinning: !!(root.service && root.service.syncing)
                  tooltipText: "Sync now"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.sync()
                }

                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf013"
                  tooltipText: "Settings"
                  selected: root.settingsOpen
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.toggleSettings()
                }
              }
            }
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Rule { width: sidebar.width }

          }

          // Fills what the hero and the footer leave, so a second account or
          // a long list of calendars scrolls instead of growing the card.
          Scroller {
            visible: !root.setupOpen && !root.settingsOpen && !root.searchOpen
            anchors.top: sidebarHead.bottom
            anchors.bottom: sidebarFoot.top
            anchors.topMargin: root.halfRuleGap
            anchors.bottomMargin: root.ruleGap
            contentHeight: calendarList.implicitHeight

          Column {
            id: calendarList
            width: sidebar.width
            spacing: Style.spacing.md

          // Each source is headed by the service it comes from — "iCloud"
          // rather than a generic "Calendars" — with the account under it.
          // Upper-cased and lit, like the headings that name the other two
          // columns: what a column is comes before what is in it, and a
          // provider read as a brand name sat too close in weight to the
          // account line under it. Paired the way PanelHero stacks its own
          // two lines, not spaced like separate sections, with the account's
          // own settings beside it.
          Item {
            width: sidebar.width
            implicitHeight: Math.max(accountLabels.implicitHeight,
                                     accountEdit.implicitHeight)

            Column {
              id: accountLabels
              anchors.left: parent.left
              anchors.right: accountEdit.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              PanelSectionHeader {
                width: parent.width
                elide: Text.ElideRight
                // Upper-cased here rather than in Logic, which answers with
                // the provider's own spelling for anywhere it is read as a
                // name rather than used as a heading.
                text: Logic.providerName(
                  root.service ? root.service.server : "").toUpperCase()
                color: root.foreground
              }

              Text {
                width: parent.width
                elide: Text.ElideRight
                text: root.service && root.service.account
                      ? root.service.account : "No account"
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Button {
              id: accountEdit
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: !!(root.service && root.service.account)
              width: root.controlSize
              height: root.controlSize
              bordered: true
              iconText: "\uf013"
              tooltipText: "Account settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.editAccount()
            }
          }

          Column {
            width: sidebar.width
            // Twice omedia's library spacing. Its rows are one list of one
            // kind of thing; these are separate calendars, each carrying its
            // own colour, and they read better as distinct bands than as a
            // block.
            spacing: Style.space(4)

          Repeater {
            model: root.calendars

            // omedia's library row: a BorderSurface that fills on hover and
            // again when selected, a leading glyph, and a label over a quieter
            // second line that hides when empty.
            CalendarRow {
              required property var modelData
              width: sidebar.width
              entry: modelData
              foreground: root.foreground
              fontFamily: root.fontFamily
              onToggled: if (root.service)
                root.service.setCalendarEnabled(modelData.url, !picked)
              onSyncRequested: if (root.service)
                root.service.syncCalendar(modelData.url)
            }
          }
          }

          Text {
            visible: root.calendars.length === 0
            width: sidebar.width
            wrapMode: Text.WordWrap
            text: "No calendars yet."
            color: root.subdued
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
            }
          }

          // Settings take the same space the list does, and are saved as
          // they are changed — there is no Save here, and nothing in it is
          // destructive. Its own scroller, because the clock faces alone are
          // taller than the sidebar.
          // The search box, pinned: what it finds scrolls under it, and the
          // field never leaves the top no matter how far down the years the
          // matches run.
          Column {
            id: searchHead
            visible: root.searchOpen
            anchors.top: sidebarHead.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.halfRuleGap
            spacing: Style.spacing.md

            Item {
              width: sidebar.width
              implicitHeight: root.fieldHeight

              TextField {
                id: searchField
                anchors.fill: parent
                leftPadding: Style.space(28)
                placeholderText: "Search"
                text: root.searchText
                foreground: root.foreground
                onTextChanged: root.searchText = text
                // Typing is not a search; a pause is. Two hundred ms is long
                // enough that a name is not searched a letter at a time and
                // short enough that it never feels like waiting.
                onTextEdited: searchDebounce.restart()
                onAccepted: {
                  searchDebounce.stop()
                  if (root.service) root.service.search(root.searchText)
                }
              }

              // A glyph inside the field rather than a button beside it: this
              // one does not do anything, it says what the box is for.
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\uf002"
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Item { width: 1; height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2) }

            Rule { width: sidebar.width }

            Item { width: 1; height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2) }

            Text {
              width: sidebar.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: Logic.searchSummary(
                root.searchText, root.searchCount,
                !!(root.service && root.service.searching),
                root.searchCount >= Logic.searchLimit())
              color: root.subdued
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Timer {
            id: searchDebounce
            interval: 200
            onTriggered: if (root.service) root.service.search(root.searchText)
          }

          Scroller {
            id: searchPane
            visible: root.searchOpen
            anchors.top: searchHead.bottom
            anchors.bottom: parent.bottom
            anchors.topMargin: root.ruleGap
            anchors.bottomMargin: root.ruleGap
            contentHeight: searchList.implicitHeight

            Column {
              id: searchList
              width: sidebar.width
              // The same gap the entries keep between themselves, so a rule
              // has equal air above and below it.
              spacing: Style.spacing.md * 2

              Repeater {
                model: root.searchGroups

                Column {
                  required property var modelData
                  width: sidebar.width
                  spacing: Style.spacing.md * 2

                  // Each day is ruled off from the one above it, and the rule
                  // travels with the day — the same way the viewer's parts
                  // carry theirs, so there is never a line over a gap. The
                  // first one doubles as the line under the count.
                  Rule { width: parent.width }

                  // The whole date: a search crosses years, and a bare
                  // weekday would say nothing about which one.
                  PanelSectionHeader {
                    width: parent.width
                    elide: Text.ElideRight
                    text: modelData.label
                    color: root.foreground
                  }

                  Repeater {
                    model: parent.modelData.events

                    DayEntry {
                      required property var modelData
                      width: sidebar.width
                      event: modelData
                      timeFormat: root.timeFormat
                      wrap: root.wrapEvents
                      onActivated: {
                        root.selectedKey = Logic.dateKey(modelData.start)
                        root.openEvent(modelData)
                      }
                    }
                  }
                }
              }
            }
          }

          // Pinned, like the hero above it: the settings scroll under their
          // own title rather than carrying it off the top.
          Column {
            id: settingsHead
            visible: root.settingsOpen
            anchors.top: sidebarHead.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.halfRuleGap
            spacing: Style.spacing.md

            // The way out sits above what it is leaving, not under it:
            // settings have no Save, so this is the only thing the foot would
            // have held, and it reads as a step back from the card's own
            // header rather than as an action on the settings below it.
            Button {
              width: sidebar.width
              height: root.controlSize
              bordered: true
              iconText: "\uf053"
              text: "Back to calendars"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.closeSettings()
            }

            Item { width: 1; height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2) }

            Rule { width: sidebar.width }

            Item { width: 1; height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2) }

            DaySection {
              width: sidebar.width
              title: "SETTINGS"
              subtitle: "Saved as you change them"
            }

            Item { width: 1; height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2) }

            Rule { width: sidebar.width }

            // Two lines whose height never depends on what they say, so
            // nothing below them moves while a check runs.
            Text {
              id: updateLineProbe
              visible: false
              text: "Ag"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Scroller {
            id: settingsPane
            visible: root.settingsOpen
            anchors.top: settingsHead.bottom
            anchors.bottom: sidebarFoot.top
            anchors.topMargin: root.ruleGap
            anchors.bottomMargin: root.ruleGap * 2
            contentHeight: settingsList.implicitHeight

            Column {
              id: settingsList
              width: sidebar.width
              spacing: Style.spacing.md

              // ------------------------------------------------- updates

              PanelSectionHeader { width: parent.width; text: "UPDATES" }

              Column {
                width: parent.width
                spacing: 0

                Text {
                  width: parent.width
                  height: updateLineProbe.implicitHeight
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.service
                    ? Logic.updateStatusLine(root.service.installedVersion,
                                             root.service.latestRelease,
                                             root.service.updateError,
                                             root.service.updateCheckedAt)
                    : ""
                  color: root.service && root.service.updateAvailable
                    ? root.stored : root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  height: updateLineProbe.implicitHeight
                  wrapMode: Text.NoWrap
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: root.service
                    ? Logic.updateCheckedLine(root.service.updateCheckedAt,
                                              root.service.updateChecking,
                                              root.today.getTime())
                    : ""
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                width: parent.width
                spacing: Style.spacing.md

                Button {
                  width: (parent.width - parent.spacing) / 2
                  // Both the height every other button on the card takes.
                  // omedia sizes its changing button off its fixed one, which
                  // is only needed where the height is left implicit; here it
                  // is set, so "Checking…" cannot resize anything, and taking
                  // the *implicit* height of the other one made this the
                  // taller of the two.
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf021"
                  iconSpinning: !!(root.service && root.service.updateChecking)
                  text: root.service && root.service.updateChecking
                    ? "Checking\u2026" : "Check now"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: if (root.service) root.service.checkForUpdate()
                }

                Button {
                  id: notesButton
                  width: (parent.width - parent.spacing) / 2
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf08e"
                  text: "Releases"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: Quickshell.execDetached(
                    ["xdg-open", root.service && root.service.latestRelease
                      ? root.service.latestRelease.url : Logic.releasesPage()])
                }
              }

              // Only when there is one, and only until it is waved off.
              Button {
                width: parent.width
                height: root.controlSize
                bordered: true
                visible: !!(root.service && root.service.updateAvailable
                  && root.service.updateDismissed
                     !== root.service.latestRelease.version)
                iconText: "\uf019"
                text: root.service && root.service.updateRunning
                  ? "Updating\u2026"
                  : "Update to " + (root.service && root.service.latestRelease
                      ? root.service.latestRelease.version : "")
                enabled: !(root.service && root.service.updateRunning)
                opacity: enabled ? 1.0 : 0.4
                foreground: root.stored
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.applyUpdate()
              }

              SettingSwitch {
                label: "Check for updates daily"
                hint: "Asks GitHub once a day for the latest release. "
                    + "Nothing is sent but the request."
                checked: !!(root.service && root.service.updateCheck)
                onToggled: root.setPref(
                  "updateCheck", !(root.service && root.service.updateCheck))
              }

              // The command shown as text, selectable, with a copy beside it:
              // somebody should be able to read what a button is about to run
              // and type it themselves instead. The app-password steps make
              // the same offer.
              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Or run it yourself"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                BorderSurface {
                  width: parent.width
                  height: Math.max(updateCommandText.implicitHeight + Style.space(12),
                                   root.controlSize)
                  radius: Style.spacing.labelGap
                  color: Style.normalFillFor(root.foreground, Color.accent)
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                  TextEdit {
                    id: updateCommandText
                    anchors.left: parent.left
                    anchors.right: copyUpdateCommand.left
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    textFormat: TextEdit.PlainText
                    text: Logic.updateCommand().join(" ")
                    color: root.foreground
                    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Button {
                    id: copyUpdateCommand
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    bordered: true
                    iconText: "\uf0c5"
                    iconSize: Style.font.caption
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(1)
                    tooltipText: "Copy"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: Quickshell.execDetached(
                      ["wl-copy", "--", Logic.updateCommand().join(" ")])
                  }
                }
              }

              FormRule { }

              // ------------------------------------------------- the month

              PanelSectionHeader { width: parent.width; text: "MONTH" }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Week starts on"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                // Seven answers is a menu rather than a row of buttons; the
                // popup also has room for the full day names.
                Picker {
                  width: parent.width
                  options: Logic.weekStartOptions()
                  value: String(root.weekStartDay)
                  onPicked: function (choice) {
                    root.setPref("weekStartDay", Number(choice))
                  }
                }
              }

              SettingChoice {
                label: "Time format"
                options: Logic.timeFormatOptions()
                value: root.timeFormat
                onPicked: function (picked) { root.setPref("timeFormat", picked) }
              }

              SettingChoice {
                label: "Opens on"
                hint: "Also where the Day, Week and Month buttons leave it."
                options: Logic.viewOptions()
                value: Logic.viewKey(root.viewMode)
                onPicked: function (choice) { root.setView(Logic.viewFromKey(choice)) }
              }

              SettingSwitch {
                label: "Show week numbers"
                hint: "The ISO week down the left of the month."
                checked: root.showWeekNumbers
                onToggled: root.setPref("showWeekNumbers", !root.showWeekNumbers)
              }

              FormRule { }

              // ------------------------------------------- day and week

              PanelSectionHeader { width: parent.width; text: "DAY AND WEEK" }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "The hours the day and week rails draw. Narrow it and "
                    + "the same events fill more of the width."
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Day starts at"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Picker {
                  width: parent.width
                  options: Logic.dayStartOptions()
                  value: String(root.dayWindow.from)
                  onPicked: function (choice) {
                    root.setPref("dayStartHour", Number(choice))
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Day ends at"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Picker {
                  width: parent.width
                  options: Logic.dayEndOptions()
                  value: String(root.dayWindow.to)
                  onPicked: function (choice) {
                    root.setPref("dayEndHour", Number(choice))
                  }
                }
              }

              FormRule { }

              // -------------------------------------------------- syncing

              PanelSectionHeader { width: parent.width; text: "SYNCING" }

              SettingChoice {
                label: "Check for changes every"
                hint: "A sync with nothing to fetch costs one request per "
                    + "calendar and finishes in well under a second."
                options: root.refreshChoices
                value: String(root.refreshMinutes)
                onPicked: function (picked) {
                  root.setPref("refreshMinutes", Number(picked))
                }
              }

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                visible: !!root.service
                text: root.service
                  ? Logic.cacheLabel(root.service.cacheBytes, root.service.objectCount)
                  : ""
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              FormRule { }

              // ------------------------------------------------- contacts

              PanelSectionHeader { width: parent.width; text: "CONTACTS" }

              // On asks first, in so many words; off deletes what was kept.
              SettingSwitch {
                label: "Suggest invitees from iCloud Contacts"
                hint: root.service ? Logic.contactsStatusLine(
                  root.service.contactsEnabled, root.service.contactCount,
                  root.service.contactsError) : ""
                checked: !!root.service && root.service.contactsEnabled
                onToggled: {
                  if (!root.service) return
                  if (root.service.contactsEnabled) root.service.disableContacts()
                  else root.consentKind = "contacts"
                }
              }

              Button {
                visible: !!root.service && root.service.contactsEnabled
                width: parent.width
                height: root.controlSize
                bordered: true
                iconText: "\uf021"
                iconSpinning: !!root.service && root.service.contactsSyncing
                text: "Refresh contacts"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.service.syncContacts()
              }

              FormRule { }

              // ----------------------------------------------- new events

              PanelSectionHeader { width: parent.width; text: "NEW EVENTS" }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Add new events to"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Picker {
                  width: parent.width
                  options: Logic.editableCalendars(root.calendars, root.newEventCalendar)
                  value: root.newEventCalendar
                  onPicked: function (choice) { root.setPref("defaultCalendar", choice) }
                }

                Text {
                  width: parent.width
                  readonly property string said: Logic.defaultCalendarNote(
                    root.calendars, String(root.pref("defaultCalendar", "")),
                    root.service ? root.service.account : "")
                  visible: said !== ""
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: said
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              FormRule { }

              // ------------------------------------------- address search

              PanelSectionHeader { width: parent.width; text: "ADDRESS SEARCH" }

              // The calendar's own addresses are always suggested. Choosing
              // a service asks first, because what is typed goes to it.
              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Look up new places with"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Picker {
                  width: parent.width
                  options: Logic.placeProviders()
                  value: root.placesProvider
                  onPicked: function (choice) {
                    if (!root.service || choice === root.placesProvider) return
                    if (choice === "none") root.service.setPlacesProvider("none")
                    else root.consentKind = choice
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: Logic.placesStatusLine(root.placesProvider)
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              FormRule { }

              // ------------------------------------------------ bar clock

              PanelSectionHeader { width: parent.width; text: "BAR CLOCK" }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: "Clock face"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Picker {
                  width: parent.width
                  options: root.clockChoices
                  value: root.clockPreset >= 0 ? String(root.clockPreset) : "custom"
                  // "Custom" is not a face of its own: it opens the box below
                  // on whatever is already set.
                  onPicked: function (choice) {
                    if (choice === "custom") return
                    root.setPref("format", Logic.clockPresets()[Number(choice)].format)
                  }
                }
              }

              // The format box only once the dropdown says Custom, so the
              // common case is a list of faces rather than a format string to
              // get wrong.
              TextField {
                width: parent.width
                height: root.fieldHeight
                visible: root.clockPreset < 0
                text: root.clockFormat
                foreground: root.foreground
                onTextChanged: if (text !== root.clockFormat)
                  root.setPref("format", text)
              }

              // Whichever way the face was chosen, this is what it renders —
              // wrapped, because the full one does not fit on a sidebar line
              // and a preview that elides is not a preview.
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: Qt.formatDateTime(root.today, root.clockFormat)
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Column {
                width: parent.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Vertical bar"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Used only when the bar runs down a side. One line "
                      + "per row, so \\n is where it breaks."
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                TextField {
                  width: parent.width
                  height: root.fieldHeight
                  // The stored value holds real newlines; a one-line box has
                  // to show them as something typeable.
                  text: root.verticalClockFormat.replace(/\n/g, "\\n")
                  foreground: root.foreground
                  onTextChanged: {
                    var real = text.replace(/\\n/g, "\n")
                    if (real !== root.verticalClockFormat)
                      root.setPref("verticalFormat", real)
                  }
                }
              }
            }
          }

          // The form takes the same space the list does.
          Column {
            id: setupForm
            visible: root.setupOpen
            anchors.top: sidebarHead.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: root.halfRuleGap
            spacing: Style.spacing.md

            // The provider, shown and not chosen: there is one. Disabled
            // rather than absent so it is clear what the account will be, and
            // that more is meant to follow.
            Column {
              width: sidebar.width
              spacing: Style.space(2)

              PanelSectionHeader {
                width: parent.width
                elide: Text.ElideRight
                text: "Provider"
              }

              Item {
                width: parent.width
                implicitHeight: providerPick.implicitHeight

                Dropdown {
                  id: providerPick
                  width: parent.width
                  rowHeight: root.fieldHeight
                  enabled: false
                  opacity: 0.6
                  showLabel: false
                  options: Logic.providerPresets()
                  value: "iCloud"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // The Dropdown carries no tooltip of its own, and a disabled
                // one would swallow the hover anyway, so the reason it cannot
                // be changed is told from an item above it.
                MouseArea {
                  id: providerHover
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.NoButton

                  PanelToolTip {
                    visible: providerHover.containsMouse
                    text: "iCloud support only. Other options coming soon."
                  }
                }
              }
            }

            // Under the provider, because it is the provider's requirement
            // and will say something else when there is another one.
            Column {
              width: sidebar.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Apple requires their customers to set up an app-specific "
                    + "password to give a third party access to your calendar."
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                id: helpLink
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Set up an app-specific password."
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.underline: true

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.helpOpen = true
                }
              }
            }

            Column {
              width: sidebar.width
              spacing: Style.space(2)

              PanelSectionHeader {
                width: parent.width
                elide: Text.ElideRight
                text: "Apple ID or Phone Number"
              }

              TextField {
                width: parent.width
                height: root.fieldHeight
                text: root.setupUser
                foreground: root.foreground
                onTextChanged: root.setupUser = text
              }
            }

            Column {
              width: sidebar.width
              spacing: Style.space(2)

              PanelSectionHeader {
                width: parent.width
                elide: Text.ElideRight
                text: "Password"
              }

              // What is already held, said plainly: an empty box under a
              // password label otherwise reads as one that was lost.
              Row {
                visible: root.setupPasswordHeld
                spacing: Style.spacing.xs

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "\uf00c"
                  color: root.stored
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Password stored and active."
                  color: root.stored
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Item {
                width: parent.width
                implicitHeight: root.fieldHeight

                TextField {
                  id: passwordField
                  anchors.left: parent.left
                  anchors.right: root.setupPasswordHeld ? changeKey.left : parent.right
                  anchors.rightMargin: root.setupPasswordHeld ? Style.spacing.md : 0
                  anchors.verticalCenter: parent.verticalCenter
                  height: root.fieldHeight
                  // While one is held the box shows it, masked, and is not
                  // typed into — the key beside it is how it gets replaced.
                  enabled: !root.setupPasswordHeld
                  password: !root.setupPasswordHeld || !root.passwordRevealed
                  text: root.setupPasswordHeld
                    ? (root.passwordRevealed ? root.service.revealedPassword
                                             : "\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022")
                    : root.setupPassword
                  rightPadding: root.setupPasswordHeld
                    ? reveal.width + Style.spacing.md : Style.spacing.controlPaddingX
                  foreground: root.foreground
                  onTextChanged: if (!root.setupPasswordHeld) root.setupPassword = text
                  onAccepted: root.connectAccount()
                }

                // A sibling of the field, not a child of it: `enabled`
                // propagates down in QML, so a button inside the disabled box
                // is disabled too and never sees the click.
                Button {
                  id: reveal
                  visible: root.setupPasswordHeld
                  anchors.right: passwordField.right
                  anchors.rightMargin: Style.spacing.xs
                  anchors.verticalCenter: passwordField.verticalCenter
                  width: root.fieldHeight - Style.spacing.md
                  height: root.fieldHeight - Style.spacing.md
                  iconText: root.passwordRevealed ? "\uf070" : "\uf06e"
                  tooltipText: root.passwordRevealed ? "Hide password" : "Show password"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: {
                    if (!root.service) return
                    if (root.passwordRevealed) root.service.hidePassword()
                    else root.service.revealPassword(root.setupUser)
                  }
                }

                Button {
                  id: changeKey
                  visible: root.setupPasswordHeld
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  // Square, and as tall as the box it stands beside.
                  width: root.fieldHeight
                  height: root.fieldHeight
                  bordered: true
                  iconText: "\uf084"
                  tooltipText: "Change password"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.startPasswordChange()
                }
              }
            }

            Button {
              width: sidebar.width
              height: root.controlSize
              bordered: true
              iconText: "\uf0c1"
              text: root.service && root.service.addingAccount
                ? "Connecting…" : "Connect"
              enabled: root.canConnect
                       && !(root.service && root.service.addingAccount)
              // qs.Ui's Button does not dim when disabled; omedia dims it
              // itself, and a control that cannot be pressed has to say so.
              opacity: enabled ? 1.0 : 0.4
              // Green only once it will actually do something, so the colour
              // is the signal that the form is complete, not decoration.
              foreground: enabled ? root.stored : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.connectAccount()
            }

            // A connection that worked says so and stays put; the calendars
            // it found are chosen below.
            Row {
              visible: root.setupNotice !== ""
              spacing: Style.spacing.xs

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\uf00c"
                color: root.stored
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: root.setupNotice
                color: root.stored
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              width: sidebar.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              // The server's own words when it refused, ours when the form is
              // not filled in yet — and nothing at all until something is.
              text: root.service && root.service.addError
                ? root.service.addError
                : (root.setupUser || root.setupPassword ? root.setupProblem : "")
              color: root.danger
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Removing the account is its own act, and a confirmed one: it
            // takes the calendars and the stored password with it.
            Button {
              visible: root.setupEditing
              width: sidebar.width
              height: root.controlSize
              bordered: true
              iconText: "\uf1f8"
              text: root.confirmRemove ? "Remove this account?" : "Disconnect account"
              foreground: root.danger
              fontFamily: root.fontFamily
              onClicked: {
                if (root.confirmRemove) root.removeAccount()
                else root.confirmRemove = true
              }
            }

            Text {
              visible: root.confirmRemove
              width: sidebar.width
              wrapMode: Text.WordWrap
              text: "Its calendars and their cached events go too, and the "
                  + "stored password is deleted. The calendars stay on iCloud."
              color: root.subdued
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // ------------------------------------------------- calendars

            Item {
              width: 1
              height: Math.max(0, root.ruleGap - Style.spacing.md * 2)
              visible: calendarPick.visible
            }

            Rule { width: sidebar.width; visible: calendarPick.visible }

            Item {
              width: 1
              height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2)
              visible: calendarPick.visible
            }

            DaySection {
              id: calendarPick
              width: sidebar.width
              visible: root.setupCalendars.length > 0
              title: "CALENDARS"
              subtitle: Logic.availableLabel(root.setupCalendars.length)
            }

            Item {
              width: 1
              height: Math.max(0, root.halfRuleGap - Style.spacing.md * 2)
              visible: calendarPick.visible
            }

            Rule { width: sidebar.width; visible: calendarPick.visible }
          }

          // The calendars found, each with a switch. Its own scroller, so a
          // long list does not push Connect off the top.
          Scroller {
            id: calendarChoices
            visible: root.setupOpen && root.setupCalendars.length > 0
            anchors.top: setupForm.bottom
            anchors.bottom: sidebarFoot.top
            anchors.topMargin: root.ruleGap
            anchors.bottomMargin: root.ruleGap
            contentHeight: choiceList.implicitHeight

            Column {
              id: choiceList
              width: sidebar.width
              // Twice omedia's list spacing, matching the calendar list in
              // the sidebar: these are separate calendars, not one list of
              // one kind of thing.
              spacing: Style.space(4)

              Repeater {
                model: root.setupCalendars

                BorderSurface {
                  id: choice
                  required property var modelData
                  readonly property bool on:
                    root.setupSelection[modelData.url] !== false

                  width: sidebar.width
                  height: Style.space(36)
                  radius: Style.spacing.labelGap
                  // At rest it is the panel behind it; under the pointer it
                  // is the calendar's own colour, the same 20% the sidebar
                  // list fills a chosen row with.
                  color: choiceArea.containsMouse
                    ? Util.alpha(choice.modelData.color || Color.accent, 0.2)
                    : "transparent"
                  // No outline, like the sidebar rows and like the labelled
                  // switches in Settings: the switch says what the state is
                  // and the hover fill says where the pointer is.
                  borderSpec: Border.none()

                  MouseArea {
                    id: choiceArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requestToggle(choice.modelData)
                  }

                  // The colour the provider gave it, which is how the same
                  // calendar is recognised on the month beside this. Flush to
                  // the row's edge and its full height, the same geometry a
                  // day entry's bar has: at the left, as tall as the thing it
                  // marks, with the name ten from the row's edge.
                  Rectangle {
                    id: choiceMark
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: Style.space(3)
                    color: choice.modelData.color || Color.accent
                    opacity: choice.on ? 1.0 : 0.45
                  }

                  Text {
                    anchors.left: choiceMark.right
                    anchors.right: choiceState.left
                    // Seven, so the gap from the bar's own left edge is the
                    // ten a day entry leaves.
                    anchors.leftMargin: Style.space(7)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Logic.singleLine(choice.modelData.name)
                    color: choice.on ? root.foreground : root.subdued
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    id: choiceState
                    anchors.right: choiceSwitch.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: choice.on ? "On" : "Off"
                    color: root.subdued
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  // No delete button beside it: the switch is the delete, and
                  // it asks before it does anything.
                  ToggleSwitch {
                    id: choiceSwitch
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    checked: choice.on
                    foreground: root.foreground
                    onToggled: root.requestToggle(choice.modelData)
                  }
                }
              }
            }
          }

          Column {
            id: sidebarFoot
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.md

            Rule {
              width: sidebar.width
              visible: !root.settingsOpen && !root.searchOpen
            }

            Item {
              width: 1
              visible: !root.settingsOpen && !root.searchOpen
              height: Math.max(0, root.ruleGap - Style.spacing.md * 2)
            }

            Button {
              visible: !root.setupOpen && !root.settingsOpen && !root.searchOpen
              width: sidebar.width
              height: root.controlSize
              bordered: true
              iconText: "\uf067"
              text: "Add calendar"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openSetup()
            }

            Row {
              visible: root.setupOpen
              width: sidebar.width
              spacing: Style.spacing.md

              Button {
                width: (sidebar.width - Style.spacing.md) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf00c"
                text: "Save"
                // Nothing to save until a switch has been moved.
                enabled: root.setupChanges.length > 0
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.saveSelection()
              }

              Button {
                width: (sidebar.width - Style.spacing.md) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf00d"
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeSetup()
              }
            }
          }
        }

        // --------------------------------------------------------- divider

        Item {
          id: divider
          width: root.ruleGap * 2 + 2
          height: calendarColumn.implicitHeight

          VRule {
            anchors.horizontalCenter: parent.horizontalCenter
            height: parent.height
          }
        }

        // ----------------------------------------------------- the calendar

        Column {
          id: calendarColumn
          width: Math.max(grid.width, Style.space(672))
          // Written out rather than spaced by the column: the weekday row sits
          // half a gap under its rule, which is less than the spacing.
          spacing: 0

          // ------------------------------------------------------- header

          // Headed like the calendar column: name over a quieter second
          // line, then a rule.
          ColumnHeader {
            width: calendarColumn.width
            // The day names itself in Day view; the month does in the others.
            title: root.viewMode === "Day"
              ? Logic.formatDayLabel(root.selectedKey)
              : root.viewMode === "Week" ? root.weekHead.title
              : Logic.monthName(root.viewMonth)
            meta: root.viewMode === "Day"
              ? Logic.weekdayOfName(root.selectedKey)
              : root.viewMode === "Week" ? root.weekHead.meta
              : String(root.viewYear)

            // qs.Ui's ButtonGroup sizes each chip to its own label; omedia
            // sizes a row of buttons off one shared cell width, which is what
            // makes the three read as a single control.
            centerControl: Component {
              Row {
                id: viewGroup
                spacing: Style.spacing.md
                readonly property real cellWidth: Math.max(dayView.implicitWidth,
                                                           weekView.implicitWidth,
                                                           monthView.implicitWidth)

                Button {
                  id: dayView
                  width: viewGroup.cellWidth
                  height: root.controlSize
                  bordered: true
                  text: "Day"
                  selected: root.viewMode === "Day"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setView("Day")
                }
                Button {
                  id: weekView
                  width: viewGroup.cellWidth
                  height: root.controlSize
                  bordered: true
                  text: "Week"
                  selected: root.viewMode === "Week"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setView("Week")
                }
                Button {
                  id: monthView
                  width: viewGroup.cellWidth
                  height: root.controlSize
                  bordered: true
                  text: "Month"
                  selected: root.viewMode === "Month"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.setView("Month")
                }
              }
            }

            trailingControl: Component {
              Row {
                spacing: Style.spacing.md

                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf053"
                  tooltipText: root.viewMode === "Day" ? "Previous day"
                    : root.viewMode === "Week" ? "Previous week"
                    : "Previous month"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.stepView(-1)
                }
                Button {
                  height: root.controlSize
                  bordered: true
                  text: "Today"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.goToday()
                }
                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf054"
                  tooltipText: root.viewMode === "Day" ? "Next day"
                    : root.viewMode === "Week" ? "Next week" : "Next month"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.stepView(1)
                }

                // Moving through time on the left of the line, making
                // something on the right of it.
                VRule { height: root.controlSize }

                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf067"
                  tooltipText: "New event on " + Logic.formatDayLabel(root.selectedKey)
                  enabled: root.newEventCalendar !== ""
                  opacity: enabled ? 1.0 : 0.4
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.startNew()
                }
              }
            }
          }

          Item { width: 1; height: root.ruleGap }

          Rule { width: calendarColumn.width }

          Item {
            width: 1
            height: root.halfRuleGap
            visible: root.viewMode === "Month"
          }

          // ----------------------------------------------- weekday header

          Row {
            visible: root.viewMode === "Month"
            spacing: 0
            x: root.weekColumn

            Repeater {
              model: Logic.weekdayLabels(root.weekStartDay, 3)

              Text {
                required property string modelData
                width: root.cellWidth
                // Left-aligned over the dates, which are left-aligned too.
                horizontalAlignment: Text.AlignLeft
                leftPadding: root.dateInset
                elide: Text.ElideRight
                text: modelData.toUpperCase()
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.weight: Font.DemiBold
              }
            }
          }

          Item {
            width: 1
            height: Style.spacing.md
            visible: root.viewMode === "Month"
          }

          // ---------------------------------------------------- the grid

          Column {
            id: grid
            visible: root.viewMode === "Month"
            spacing: 0
            // A Column computes implicitWidth from its children, so the
            // intended width is set directly.
            width: root.gridWidth

            Repeater {
              model: root.rows

              // One week: the day cells, with the all-day bars drawn across.
              Item {
                id: week
                required property var modelData
                readonly property var days: modelData.map(function (c) { return c.key })
                readonly property var bars: Logic.allDayBars(root.events, days)
                // How deep the all-day stack is over each day, not over the
                // week: a day with nothing reserves nothing. Capped at the
                // two lanes the month draws.
                readonly property var barDepths:
                  Logic.barDepths(bars, days.length, root.barLanes)
                readonly property bool isThisWeek: days.indexOf(root.todayKey) >= 0

                width: grid.width
                implicitHeight: root.cellHeight

                // The week number reads as one of the numbers in its row, so
                // it takes the date's size and sits in a box the same height
                // as the date bubble, at the same y — the two line up on the
                // same centre rather than near each other.
                Text {
                  visible: root.showWeekNumbers
                  y: Style.spacing.xxs
                  width: root.weekColumn
                  height: root.bubbleSize
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  textFormat: Text.PlainText
                  text: Logic.isoWeekNumber(week.days[0])
                  // The week being lived in is the one worth finding; the
                  // rest are there to count from.
                  color: week.isThisWeek ? root.foreground : root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.weight: week.isThisWeek ? Font.Bold : Font.Normal
                }

                Row {
                  id: dayRow
                  x: root.weekColumn
                  spacing: 0

                  Repeater {
                    model: week.modelData

                    Rectangle {
                      required property var modelData
                      readonly property bool isSelected: modelData.key === root.selectedKey
                      readonly property var bucket: root.buckets[modelData.key]
                                                    || ({ allDay: [], timed: [] })
                      // How many slots this day's all-day bars have already
                      // taken. The bars are drawn over the whole week, so the
                      // appointments have to start under them.
                      //
                      // Found by date rather than by the delegate's `index`:
                      // the two disagreed by one and the appointments landed
                      // on top of a bar. The day knows its own key, and one
                      // lookup down a seven-item row costs nothing.
                      readonly property int column: week.days.indexOf(modelData.key)
                      readonly property int barSlots:
                        column < 0 ? 0 : (week.barDepths[column] || 0)
                      readonly property int barSpace:
                        root.slotTop + barSlots * root.slotPitch
                      readonly property var slots: Logic.cellSlots(
                        barSlots, bucket.allDay.length, bucket.timed.length,
                        root.slotCount)
                      readonly property int shownTimed: slots.shownTimed
                      readonly property int hidden: slots.hidden

                      width: root.cellWidth
                      height: root.cellHeight
                      // Weekends sit on a lighter ground; the selected day is
                      // lighter still. Today is marked by its bubble, not by
                      // the cell.
                      color: isSelected ? Style.selectedFill
                           : modelData.isWeekend ? root.weekendFill : "transparent"

                      // Top and bottom rules on every cell. Drawn as children
                      // rather than as a border so the sides stay open and the
                      // rules of adjacent cells meet.
                      Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        height: 1
                        color: root.hairline
                        opacity: 0.35
                      }

                      Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: root.hairline
                        opacity: 0.35
                      }

                      // The date, in a bubble that is a true circle: one size
                      // for both axes, radius exactly half of it.
                      Rectangle {
                        id: bubble
                        x: root.cellPadding
                        y: Style.spacing.xxs
                        width: root.bubbleSize
                        height: root.bubbleSize
                        radius: width / 2
                        color: modelData.isToday ? Color.accent : "transparent"

                        Text {
                          anchors.centerIn: parent
                          text: modelData.day
                          color: modelData.isToday ? Color.popups.background
                               : modelData.inMonth ? root.foreground : root.subdued
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.weight: modelData.isToday ? Font.Bold : Font.Normal
                        }
                      }

                      // Timed events sit below the all-day lanes.
                      Column {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: root.cellPadding
                        anchors.rightMargin: Style.spacing.xs
                        anchors.topMargin: parent.barSpace
                        spacing: root.slotGap

                        Repeater {
                          model: parent.parent.shownTimed

                          // One slot tall, like a bar, so the two kinds of
                          // event sit on the same rows across the week.
                          Row {
                            required property int index
                            height: root.slotHeight
                            spacing: Style.spacing.md

                            Rectangle {
                              width: Style.space(5)
                              height: Style.space(5)
                              radius: width / 2
                              anchors.verticalCenter: parent.verticalCenter
                              color: root.colorOf(bucket.timed[index])
                            }

                            Text {
                              anchors.verticalCenter: parent.verticalCenter
                              width: root.cellWidth - Style.space(20)
                              elide: Text.ElideRight
                              text: Logic.singleLine(bucket.timed[index].title)
                              color: root.foreground
                              font.family: root.fontFamily
                              font.pixelSize: Style.font.caption
                            }
                          }
                        }

                        // Takes the last free slot rather than sitting under
                        // the others, so it lines up with every other row.
                        Text {
                          visible: slots.more
                          width: root.cellWidth - root.cellPadding * 2
                          height: root.slotHeight
                          verticalAlignment: Text.AlignVCenter
                          elide: Text.ElideRight
                          text: "+" + hidden + " more"
                          color: root.subdued
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        anchors.fill: parent
                        onClicked: root.selectedKey = modelData.key
                      }
                    }
                  }
                }

                // All-day bars span days, so they are drawn over the row
                // rather than inside any one cell.
                Repeater {
                  model: week.bars

                  Rectangle {
                    required property var modelData
                    x: dayRow.x + modelData.startCol * root.cellWidth + 1
                    y: root.slotTop + modelData.lane * root.slotPitch
                    width: modelData.span * root.cellWidth - 2
                    height: root.slotHeight
                    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(3)
                    // Fill only, like the calendar rows in the sidebar: the
                    // colour says which calendar it belongs to and an outline
                    // in the same colour only doubled up on that.
                    color: Util.alpha(root.colorOf(modelData.event), 0.30)
                    visible: modelData.lane < root.barLanes

                    Text {
                      anchors.fill: parent
                      anchors.leftMargin: Style.spacing.sm
                      anchors.rightMargin: Style.spacing.sm
                      verticalAlignment: Text.AlignVCenter
                      elide: Text.ElideRight
                      // A bar continuing from the previous week reads as one.
                      text: (modelData.continuesBefore ? "◂ " : "")
                            + Logic.singleLine(modelData.event.title)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    MouseArea {
                      anchors.fill: parent
                      onClicked: root.selectedKey = Logic.dateKey(modelData.event.start)
                    }
                  }
                }
              }
            }
          }

          // ------------------------------------------------- the day rail
          //
          // The same day the column beside this lists, drawn against the
          // clock: a band of all-day bars over a rail of hours, with each
          // appointment where its time puts it and as wide as the events it
          // overlaps leave it.

          Column {
            id: dayView
            visible: root.viewMode === "Day"
            width: calendarColumn.width
            spacing: 0

            // A narrowed day should use the room it has rather than leave
            // half the column empty, so the hours stretch to fill it. A day
            // that would not fit keeps its natural height and scrolls.
            readonly property int hourHeight: Math.max(
              root.hourHeight,
              Math.floor((dayRail.height - root.railTop)
                         / Math.max(1, root.dayWindow.hours)))

            Item { width: 1; height: root.halfRuleGap }

            // All-day events have no place on a clock, so they sit above it
            // — full width, as bars, the way the month draws them.
            Column {
              id: dayBand
              width: calendarColumn.width
              spacing: root.slotGap
              visible: root.selected.allDay.length > 0

              Repeater {
                model: root.selected.allDay

                Rectangle {
                  required property var modelData
                  x: root.hourGutter
                  width: calendarColumn.width - root.hourGutter
                  height: root.slotHeight
                  radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(3)
                  color: Util.alpha(root.colorOf(modelData), 0.30)

                  Text {
                    anchors.fill: parent
                    anchors.leftMargin: Style.spacing.sm
                    anchors.rightMargin: Style.spacing.sm
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Logic.singleLine(modelData.title)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.openEvent(modelData)
                  }
                }
              }
            }

            Item {
              width: 1
              height: root.halfRuleGap
              visible: dayBand.visible
            }

            Rule { width: calendarColumn.width; visible: dayBand.visible }

            Scroller {
              id: dayRail
              width: calendarColumn.width
              height: Math.max(root.hourHeight * 6,
                               root.cellHeight * 6 - dayBand.height
                               - (dayBand.visible ? root.ruleGap : 0))
              contentHeight: railBody.height
              // A narrowed day may fit whole, in which case there is nothing
              // to scroll and nothing to open on.
              interactive: contentHeight > height

              // Opens where the day starts rather than at midnight, and
              // follows the day as the arrows walk through it.
              function toOpeningHour() {
                var hour = Math.max(root.dayWindow.from,
                                    Logic.openingHour(root.dayBlocks))
                contentY = Math.min(
                  Math.max(0, contentHeight - height),
                  Logic.hourOffset(hour - root.dayWindow.from, dayView.hourHeight))
              }

              Component.onCompleted: toOpeningHour()

              Connections {
                target: root
                function onSelectedKeyChanged() { Qt.callLater(dayRail.toOpeningHour) }
                function onViewModeChanged() {
                  if (root.viewMode === "Day") Qt.callLater(dayRail.toOpeningHour)
                }
              }

              Item {
                id: railBody
                width: dayRail.contentWidth
                height: dayView.hourHeight * root.dayWindow.hours + root.railTop

                // One rule per hour, with the hour named in the gutter, and
                // one more at the foot so the rail is closed at both ends.
                Repeater {
                  model: root.dayWindow.hours + 1

                  Item {
                    required property int index
                    readonly property int hour: root.dayWindow.from + index
                    readonly property string modelData:
                      Logic.hourLabels(root.timeFormat)[hour % 24]
                    y: root.railTop + index * dayView.hourHeight
                    width: railBody.width
                    height: dayView.hourHeight

                    Rectangle {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.leftMargin: root.hourGutter
                      height: 1
                      color: root.hairline
                      opacity: 0.35
                    }

                    Text {
                      x: 0
                      width: root.hourGutter - Style.spacing.sm
                      y: -Math.round(root.captionLine / 2)
                      horizontalAlignment: Text.AlignRight
                      textFormat: Text.PlainText
                      // Midnight has no rule above it to label.
                      text: modelData
                      color: root.subdued
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Repeater {
                  model: root.dayBlocks

                  Rectangle {
                    required property var modelData
                    readonly property var box: Logic.blockGeometry(
                      modelData, dayView.hourHeight, root.slotHeight, root.dayWindow)
                    readonly property var column: Logic.blockColumn(
                      modelData, railBody.width - root.hourGutter, root.slotGap * 2)

                    visible: Logic.inWindow(modelData, root.dayWindow)
                    x: root.hourGutter + column.x
                    y: root.railTop + box.y
                    width: column.width
                    height: box.height
                    radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(3)
                    color: Util.alpha(root.colorOf(modelData.event), 0.22)

                    Column {
                      anchors.fill: parent
                      anchors.margins: Style.spacing.xs
                      spacing: 0
                      clip: true

                      Row {
                        spacing: Style.spacing.xs

                        // A dot, because it has a time — the same mark the
                        // month and the day list give an appointment.
                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(5)
                          height: width
                          radius: width / 2
                          color: root.colorOf(modelData.event)
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          width: parent.parent.width - Style.space(5)
                                 - Style.spacing.xs
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          text: Logic.singleLine(modelData.event.title)
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }

                      Text {
                        // Only where the block is tall enough to hold it.
                        visible: parent.height > root.captionLine * 2.4
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: Logic.formatRange(modelData.event, root.timeFormat)
                        color: root.subdued
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.openEvent(modelData.event)
                    }
                  }
                }

                // Now, as a line across the rail — only on the day it is,
                // and declared last so nothing is drawn over it.
                Rectangle {
                  visible: root.selectedKey === root.todayKey
                  x: root.hourGutter
                  width: railBody.width - root.hourGutter
                  readonly property int nowMinute:
                    root.today.getHours() * 60 + root.today.getMinutes()
                  y: root.railTop
                     + Math.round((Math.max(root.dayWindow.startMinute,
                                   Math.min(root.dayWindow.endMinute, nowMinute))
                                   - root.dayWindow.startMinute)
                                  * dayView.hourHeight / 60)
                  height: 2
                  color: Color.accent
                }
              }
            }
          }

          // ------------------------------------------------ the week rail
          //
          // Days down, hours across — the other way round from every calendar
          // that ships with anything. A day *is* a length of time, so it is
          // drawn as one: seven timelines stacked, and the shape of the week
          // readable by running your eye down the left of them.
          //
          // The pay-off is overlap. Laid out in columns, two appointments at
          // once halve a day's width and a third makes it unreadable; laid
          // out in rows they stack, so a busy day grows taller and every
          // event keeps its full length.

          Column {
            id: weekView
            visible: root.viewMode === "Week"
            width: calendarColumn.width
            spacing: 0

            // Wide enough for "SAT 12" with air after it.
            readonly property int dayGutter: Style.space(56)
            // Where the date bubbles sit, so the week's number can be put
            // over them and every row lines up under it.
            readonly property int bubbleCentre:
              Style.spacing.sm + root.weekdayTagWidth + Style.spacing.xs
              + Math.round(root.bubbleSize / 2)

            // A light week should use the room it has rather than huddle at
            // the top of it. What the rows want comes from the events, not
            // from the rows — a row about to be stretched cannot also be what
            // decides the stretching — and whatever is left over is shared
            // out evenly. A week too tall to fit gets nothing and scrolls.
            readonly property int naturalHeight:
              Logic.weekNaturalRows(root.weekKeys, root.buckets) * root.slotPitch
              + root.weekKeys.length * root.ruleGap
            readonly property int rowBonus: Math.max(
              0, Math.floor((weekRail.height - naturalHeight)
                            / Math.max(1, root.weekKeys.length)))
            readonly property int railWidth: calendarColumn.width - dayGutter
            // An hour of margin either side of the day, so the first and
            // last marks can straddle their tick like the rest, and an event
            // that spills out of the day has somewhere to show it.
            readonly property var rail: Logic.railWindow(root.dayWindow)
            readonly property int tickStep: Logic.hourTickStep(
              railWidth, root.hourLabelWidth, rail.hours)

            Item { width: 1; height: root.halfRuleGap }

            // The clock, along the top. Ticks every hour, named as often as
            // they will fit without touching.
            Item {
              id: weekHours
              width: calendarColumn.width
              implicitHeight: Math.max(root.captionLine, weekNumber.implicitHeight)

              // The gutter's own heading, in the same column and the same
              // voice as the day names under it: a quiet three-letter tag,
              // then the number it belongs to.
              Text {
                x: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                width: root.weekdayTagWidth
                textFormat: Text.PlainText
                text: "WK#"
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.DemiBold
              }

              // The week's own number, over the dates it numbers. Lit rather
              // than subdued: in a week view the week is the subject, not a
              // note in the margin the way it is on a month.
              Text {
                id: weekNumber
                x: weekView.bubbleCentre - Math.round(width / 2)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: Logic.isoWeekNumber(root.weekKeys[0])
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              // Every hour the day covers, ends included, and every one of
              // them centred on its own tick. The margins are unnamed: they
              // belong to yesterday and tomorrow.
              Repeater {
                model: root.dayWindow.hours + 1

                Text {
                  required property int index
                  readonly property int hour: root.dayWindow.from + index
                  visible: index === root.dayWindow.hours
                           || index % weekView.tickStep === 0
                  x: weekView.dayGutter
                     + Logic.hourAcross(hour, weekView.railWidth, weekView.rail)
                     - Math.round(width / 2)
                  anchors.verticalCenter: parent.verticalCenter
                  width: root.hourLabelWidth
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: Logic.hourLabels(root.timeFormat)[((hour % 24) + 24) % 24]
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.weight: Font.DemiBold
                }
              }
            }

            Item { width: 1; height: root.halfRuleGap }

            Rule { width: calendarColumn.width }

            Scroller {
              id: weekRail
              width: calendarColumn.width
              // What the month's grid would have taken, less the clock and
              // its rule above this — so the card is the same height in every
              // view and switching between them does not resize it.
              height: Math.max(root.hourHeight * 6,
                               root.cellHeight * 6 - weekHours.height
                               - root.ruleGap)
              contentHeight: weekRows.implicitHeight

              Column {
                id: weekRows
                width: weekRail.contentWidth
                spacing: 0

                Repeater {
                  model: root.weekKeys

                  Item {
                    id: dayRow
                    required property string modelData
                    required property int index
                    readonly property bool isToday: modelData === root.todayKey
                    readonly property bool isSelected: modelData === root.selectedKey
                    readonly property var bucket:
                      root.buckets[modelData] || ({ allDay: [], timed: [] })
                    readonly property var blocks:
                      Logic.layoutTimed(bucket.timed, modelData)
                    readonly property int depth:
                      Logic.dayDepth(bucket.allDay.length, blocks)

                    width: weekRows.width
                    implicitHeight: depth * root.slotPitch + root.ruleGap
                                    + weekView.rowBonus

                    // The weekend's lighter ground, and the selected day's
                    // lighter still — the same two the month uses.
                    Rectangle {
                      anchors.fill: parent
                      color: dayRow.isSelected ? Style.selectedFill
                           : Logic.isWeekend(Logic.weekdayOf(dayRow.modelData))
                             ? root.weekendFill : "transparent"
                    }

                    // The margins, dimmed: what is drawn there is yesterday
                    // and tomorrow, and should not read as part of this row.
                    Rectangle {
                      x: weekView.dayGutter
                      width: Logic.hourAcross(root.dayWindow.from,
                                              weekView.railWidth, weekView.rail)
                      height: dayRow.height
                      color: Color.popups.background
                      opacity: 0.55
                    }

                    Rectangle {
                      x: weekView.dayGutter
                         + Logic.hourAcross(root.dayWindow.to,
                                            weekView.railWidth, weekView.rail)
                      width: weekView.railWidth - x + weekView.dayGutter
                      height: dayRow.height
                      color: Color.popups.background
                      opacity: 0.55
                    }

                    // The hour grid, behind everything the day holds. The
                    // day's own two ends are drawn like the hours between
                    // them, which is what the margins made room for.
                    Repeater {
                      model: root.dayWindow.hours + 1

                      Rectangle {
                        required property int index
                        x: weekView.dayGutter
                           + Logic.hourAcross(root.dayWindow.from + index,
                                              weekView.railWidth, weekView.rail)
                        y: 0
                        width: 1
                        height: dayRow.height
                        color: root.hairline
                        opacity: index === 0 || index === root.dayWindow.hours
                          ? 0.5 : index % weekView.tickStep === 0 ? 0.35 : 0.15
                      }
                    }

                    // The day, named and numbered, with today in its bubble.
                    Row {
                      x: Style.spacing.sm
                      y: Math.round((root.slotHeight - root.bubbleSize) / 2)
                        + Math.round(root.ruleGap / 2)
                      spacing: Style.spacing.xs

                      Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.weekdayTagWidth
                        textFormat: Text.PlainText
                        text: Logic.weekdayLabels(
                          Logic.weekdayOf(dayRow.modelData), 3)[0].toUpperCase()
                        color: root.subdued
                        font.family: root.fontFamily
                        // The day's name is the same size as its number: they
                        // are one label in two parts, not a label and a note.
                        font.pixelSize: Style.font.bodySmall
                        font.weight: Font.DemiBold
                      }

                      Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.bubbleSize
                        height: root.bubbleSize
                        radius: width / 2
                        color: dayRow.isToday ? Color.accent : "transparent"

                        Text {
                          anchors.centerIn: parent
                          textFormat: Text.PlainText
                          text: Logic.parseKey(dayRow.modelData).d
                          color: dayRow.isToday ? Color.popups.background
                                                : root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          font.weight: dayRow.isToday || dayRow.isSelected
                            ? Font.Bold : Font.Normal
                        }
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.selectedKey = dayRow.modelData
                    }

                    // All-day events take the top rows, the whole day wide,
                    // because that is exactly how long they are.
                    Repeater {
                      model: dayRow.bucket.allDay

                      Rectangle {
                        required property var modelData
                        required property int index
                        readonly property var flow:
                          Logic.eventOverflow(modelData, dayRow.modelData)
                        readonly property var box: Logic.blockSpan(
                          Logic.spilledSpan(root.dayWindow.startMinute,
                                            root.dayWindow.endMinute,
                                            flow, weekView.rail),
                          weekView.railWidth - 1, root.slotHeight, weekView.rail)

                        x: weekView.dayGutter + box.x
                        y: Math.round(root.ruleGap / 2) + index * root.slotPitch
                        width: box.width
                        height: root.slotHeight
                        radius: Style.cornerRadius > 0 ? Style.cornerRadius
                                                       : Style.space(3)
                        color: Util.alpha(root.colorOf(modelData), 0.30)

                        Text {
                          anchors.fill: parent
                          anchors.leftMargin: Style.spacing.sm
                          anchors.rightMargin: Style.spacing.sm
                          verticalAlignment: Text.AlignVCenter
                          elide: Text.ElideRight
                          textFormat: Text.PlainText
                          text: Logic.singleLine(modelData.title)
                          color: root.foreground
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.openEvent(modelData)
                        }
                      }
                    }

                    // Then the timed ones, each as long as it lasts, stacked
                    // where they collide.
                    Repeater {
                      model: dayRow.blocks

                      Rectangle {
                        required property var modelData
                        readonly property var flow: Logic.eventOverflow(
                          modelData.event, dayRow.modelData)
                        readonly property var box: Logic.blockSpan(
                          Logic.spilledSpan(modelData.startMinute,
                                            modelData.endMinute,
                                            flow, weekView.rail),
                          weekView.railWidth - 1, root.slotHeight, weekView.rail)

                        visible: Logic.inWindow(modelData, root.dayWindow)
                        x: weekView.dayGutter + box.x
                        y: Math.round(root.ruleGap / 2)
                           + (dayRow.bucket.allDay.length + modelData.lane)
                             * root.slotPitch
                        width: box.width
                        height: root.slotHeight
                        radius: Style.cornerRadius > 0 ? Style.cornerRadius
                                                       : Style.space(3)
                        color: Util.alpha(root.colorOf(modelData.event), 0.30)

                        Row {
                          anchors.fill: parent
                          anchors.leftMargin: Style.spacing.xs
                          anchors.rightMargin: Style.spacing.xs
                          spacing: Style.spacing.xxs
                          clip: true

                          Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Style.space(4)
                            height: width
                            radius: width / 2
                            color: root.colorOf(modelData.event)
                          }

                          Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - Style.space(4)
                                   - Style.spacing.xxs
                            elide: Text.ElideRight
                            textFormat: Text.PlainText
                            text: Logic.singleLine(modelData.event.title)
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: root.openEvent(modelData.event)
                        }
                      }
                    }

                    // Now, down today's row alone.
                    Rectangle {
                      visible: dayRow.isToday
                      readonly property int nowMinute:
                        root.today.getHours() * 60 + root.today.getMinutes()
                      x: weekView.dayGutter
                         + Math.round((Math.max(root.dayWindow.startMinute,
                                       Math.min(root.dayWindow.endMinute, nowMinute))
                                       - weekView.rail.startMinute)
                                      * weekView.railWidth
                                      / (weekView.rail.hours * 60))
                      y: 0
                      width: 2
                      height: dayRow.height
                      color: Color.accent
                    }

                    Rule {
                      width: weekRows.width
                      anchors.bottom: parent.bottom
                    }
                  }
                }
              }
            }
          }


          // -------------------------------------------------------- footer

          Item {
            width: 1
            height: Style.spacing.md
            visible: errorText.visible
          }

          Text {
            id: errorText
            visible: !!(root.service && root.service.error)
            width: calendarColumn.width
            wrapMode: Text.WordWrap
            text: root.service ? root.service.error : ""
            color: root.danger
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Saved here while iCloud could not be reached, and not sent yet.
          Text {
            visible: !!root.service && root.service.pendingCount > 0
            width: calendarColumn.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: !root.service ? "" : (root.service.pendingCount === 1
              ? "1 change is waiting to be sent to iCloud."
              : root.service.pendingCount + " changes are waiting to be sent to iCloud.")
              + " It goes with the next sync."
            color: root.subdued
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // And any iCloud refused when they were sent: already taken off the
          // calendar, said here until the person has seen it.
          Repeater {
            model: root.service ? root.service.pendingProblems : []

            Item {
              required property var modelData
              width: calendarColumn.width
              height: Math.max(problemText.implicitHeight, root.controlSize)

              Text {
                id: problemText
                anchors.left: parent.left
                anchors.right: dismissProblem.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "\u201c" + (modelData.title || "An event") + "\u201d wasn\u2019t "
                  + (modelData.action === "delete" ? "deleted" : "saved") + " on iCloud: "
                  + modelData.error
                color: root.danger
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                id: dismissProblem
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: root.controlSize
                height: root.controlSize
                bordered: true
                iconText: "\uf00d"
                tooltipText: "Dismiss"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.service.dismissPending(modelData.id)
              }
            }
          }
        }

        // --------------------------------------------------------- divider

        Item {
          id: dayDivider
          width: root.ruleGap * 2 + 2
          height: calendarColumn.implicitHeight

          VRule {
            anchors.horizontalCenter: parent.horizontalCenter
            height: parent.height
          }
        }

        // ------------------------------------------------- the selected day

        Item {
          id: daySidebar
          width: root.sidebarWidth
          // As tall as the month, so the scheduled list has somewhere to go.
          implicitHeight: calendarColumn.implicitHeight

          Column {
            id: dayHead
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            // Spaced explicitly rather than by the column, so each gap is
            // exactly what it says and not that plus a spacing.
            spacing: 0

            ColumnHeader {
              width: daySidebar.width
              title: Logic.weekdayOfName(root.selectedKey)
              meta: Logic.formatDayLabel(root.selectedKey)

              trailingControl: Component {
                Button {
                  // Nothing to set while the viewer has the column: the one
                  // choice here is about the list it replaced.
                  visible: !root.viewerOpen
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf013"
                  tooltipText: "Day options"
                  selected: root.dayOptionsOpen
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.dayOptionsOpen = !root.dayOptionsOpen
                }
              }
            }

            Item { width: 1; height: root.ruleGap }

            Rule { width: daySidebar.width }

            // One choice, so it is the choice itself under the header rather
            // than a panel to go and find it in. Folded away until the gear
            // asks for it, because a list of events is what this column is
            // for and a control sitting over it permanently is not.
            Column {
              width: daySidebar.width
              spacing: 0
              visible: root.dayOptionsOpen && !root.viewerOpen

              Item { width: 1; height: root.halfRuleGap }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Long titles and addresses"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Item { width: 1; height: Style.space(4) }

              Picker {
                width: parent.width
                options: Logic.wrapOptions()
                value: root.wrapEvents ? "true" : "false"
                onPicked: function (choice) {
                  root.setPref("wrapEvents", choice === "true")
                }
              }

              Item { width: 1; height: root.halfRuleGap }

              Rule { width: daySidebar.width }
            }

            // The day's own lists, which step aside while the viewer has
            // the column. Its own Column so the gaps between them go too.
            Column {
              id: dayLists
              width: daySidebar.width
              spacing: 0
              visible: !root.viewerOpen

              // What the last save or delete came to, when it was not simply
              // done: an attachment iCloud refused, say.
              Text {
                width: daySidebar.width
                visible: root.dayNotice !== ""
                topPadding: root.halfRuleGap
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.dayNotice
                color: root.dayNoticeBad ? root.danger : root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

            // The whole section goes when the day has none: a heading reading
            // "All Day / None" over nothing is a row of furniture, not
            // information. Its closing rule goes with it, leaving the day's
            // own rule directly above Scheduled.
            Column {
              width: daySidebar.width
              spacing: 0
              visible: root.selected.allDay.length > 0

              Item { width: 1; height: root.halfRuleGap }

              DaySection {
                width: daySidebar.width
                title: "ALL DAY"
                  count: root.selected.allDay.length
              }

              Item { width: 1; height: root.halfRuleGap }

              Rule { width: daySidebar.width }

              Item { width: 1; height: root.ruleGap }

              // All-day events are few by nature, so this one does not scroll.
              Column {
                width: daySidebar.width
                spacing: Style.spacing.md * 2

                Repeater {
                  model: root.selected.allDay
                  DayEntry {
                    required property var modelData
                    width: daySidebar.width
                    event: modelData
                    timeFormat: root.timeFormat
                    wrap: root.wrapEvents
                    onActivated: root.openEvent(modelData)
                  }
                }
              }

              Item { width: 1; height: root.ruleGap }

              Rule { width: daySidebar.width }
            }

            Item { width: 1; height: root.halfRuleGap }

            DaySection {
              width: daySidebar.width
              title: "SCHEDULED"
              count: root.selected.timed.length
            }

            Item { width: 1; height: root.halfRuleGap }

            Rule { width: daySidebar.width }
            }

            // The event takes the same column, the way settings take the
            // calendar list's: a way back over its title, then the record
            // under it. Not a modal — reading an event is what this column is
            // for, so it belongs in it rather than over the whole card.
            Column {
              id: viewerHead
              width: daySidebar.width
              spacing: 0
              visible: root.viewerOpen && !root.editorOpen

              Item { width: 1; height: root.halfRuleGap }

              Button {
                width: daySidebar.width
                height: root.controlSize
                bordered: true
                iconText: "\uf053"
                text: "Back to " + Logic.weekdayOfName(root.selectedKey)
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.closeEvent()
              }

              Item { width: 1; height: root.halfRuleGap }

              Rule { width: daySidebar.width }

              Item { width: 1; height: root.halfRuleGap }

              Item {
                width: daySidebar.width
                implicitHeight: viewerTitle.implicitHeight

                readonly property bool wholeDay:
                  !!(root.viewerEvent && root.viewerEvent.allDay)
                readonly property color mark: root.viewerEvent
                  ? (root.viewerEvent.color || Color.accent) : Color.accent

                // The same grammar as the list this was opened from: a bar
                // for an all-day event, a dot for one with a time. The bar
                // runs the height of the title it marks and grows with a
                // title that wraps; the dot sits on the title's first line.
                Rectangle {
                  visible: parent.wholeDay
                  anchors.left: parent.left
                  anchors.top: parent.top
                  width: Style.space(3)
                  height: viewerTitle.implicitHeight
                  color: parent.mark
                }

                Rectangle {
                  visible: !parent.wholeDay
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.topMargin: Math.round((root.titleLine - height) / 2)
                  width: Style.space(5)
                  height: width
                  radius: width / 2
                  color: parent.mark
                }

                Column {
                  id: viewerTitle
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(10)
                  anchors.top: parent.top
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: root.viewerEvent
                      ? Logic.singleLine(root.viewerEvent.title) : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: root.viewerEvent
                      ? String(root.viewerEvent.calendar || "").toUpperCase() : ""
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.2
                  }
                }
              }

              Item { width: 1; height: root.halfRuleGap }
            }

            // The form's own heading, where the event's title was: the title
            // is the first field now, and the heading says what the column
            // has become and whether anything in it has been changed.
            Column {
              id: editorHead
              width: daySidebar.width
              spacing: 0
              visible: root.editorOpen

              Item { width: 1; height: root.halfRuleGap }

              DaySection {
                width: daySidebar.width
                title: root.creating ? "NEW EVENT" : "EDIT EVENT"
                subtitle: root.duplicating ? "A copy \u2014 not saved yet"
                  : root.creating ? "Not saved yet"
                  : root.draftChanges.length === 0 ? "No changes yet"
                  : root.draftChanges.length === 1 ? "1 unsaved change"
                  : root.draftChanges.length + " unsaved changes"
              }

              Item { width: 1; height: root.halfRuleGap }

              Rule { width: daySidebar.width }
            }
          }

          // The event's own parts, each ruled off from the one above it.
          Scroller {
            visible: root.viewerOpen && !root.editorOpen
            anchors.top: dayHead.bottom
            anchors.bottom: dayFoot.top
            anchors.bottomMargin: root.ruleGap
            contentHeight: viewerBody.implicitHeight

            Column {
              id: viewerBody
              width: daySidebar.width
              spacing: Style.spacing.md

              // Saved here while iCloud could not be reached.
              Text {
                width: parent.width
                visible: !!(root.viewerSeed && root.viewerSeed.pending)
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "\uf017  Not sent to iCloud yet \u2014 it goes with the next sync."
                color: root.subdued
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              DetailField {
                label: "When"
                lines: root.viewerEvent
                  ? Logic.eventWhen(root.viewerEvent, root.timeFormat) : []
              }

              DetailField {
                label: "Repeats"
                lines: {
                  var said = root.viewerEvent
                    ? Logic.describeRecurrence(root.viewerEvent.rrule) : ""
                  return said ? [said] : []
                }
              }

              DetailField {
                label: "Where"
                lines: root.viewerEvent
                  ? Logic.locationLines(root.viewerEvent.location) : []
              }

              DetailField {
                label: "Alerts"
                lines: root.viewerEvent
                  ? Logic.alarmLines(root.viewerEvent.alarms) : []
              }

              DetailField {
                label: "Travel time"
                lines: {
                  var minutes = root.viewerEvent && !root.viewerEvent.allDay
                    ? Logic.durationMinutes(root.viewerEvent.travel) : null
                  return minutes > 0 ? [Logic.travelLabel(Math.round(minutes))] : []
                }
              }

              DetailField {
                label: "Organiser"
                lines: root.viewerEvent && root.viewerEvent.organizer
                  ? [root.viewerEvent.organizer] : []
              }

              DetailField {
                label: "Invitees"
                lines: root.viewerEvent && root.viewerEvent.attendees
                  ? root.viewerEvent.attendees : []
              }

              // Selectable, because a note is the part of an event somebody
              // actually needs to copy out of it.
              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: !!(root.viewerEvent && root.viewerEvent.description)

                Rule { width: parent.width }

                Item {
                  width: 1
                  height: Math.max(0, Style.spacing.md - Style.space(2) * 2)
                }

                PanelSectionHeader { width: parent.width; text: "Notes" }

                TextEdit {
                  width: parent.width
                  readOnly: true
                  selectByMouse: true
                  wrapMode: TextEdit.Wrap
                  textFormat: TextEdit.PlainText
                  text: root.viewerEvent ? (root.viewerEvent.description || "") : ""
                  color: root.foreground
                  selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              DetailField {
                label: "Attachments"
                lines: root.viewerEvent
                  ? Logic.attachmentLines(root.viewerEvent.attachments) : []
              }

              // The link readable and copiable as well as clickable, the way
              // the app-password steps show theirs. Opening is only offered for
              // one a browser can use: iCloud writes sms:// and message:// URLs
              // that would go nowhere.
              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: !!(root.viewerEvent
                  && (root.viewerEvent.url || root.viewerEvent.meetingUrl))

                readonly property string link: root.viewerEvent
                  ? String(root.viewerEvent.meetingUrl || root.viewerEvent.url || "")
                  : ""

                Rule { width: parent.width }

                Item {
                  width: 1
                  height: Math.max(0, Style.spacing.md - Style.space(2) * 2)
                }

                PanelSectionHeader {
                  width: parent.width
                  text: root.viewerEvent && root.viewerEvent.meetingUrl
                    ? "Meeting" : "Link"
                }

                BorderSurface {
                  width: parent.width
                  height: Math.max(viewerLink.implicitHeight + Style.space(12),
                                   root.controlSize)
                  radius: Style.spacing.labelGap
                  color: Style.normalFillFor(root.foreground, Color.accent)
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                  TextEdit {
                    id: viewerLink
                    anchors.left: parent.left
                    anchors.right: copyViewerLink.left
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    textFormat: TextEdit.PlainText
                    text: parent.parent.link
                    color: root.foreground
                    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
            }

            Button {
              id: copyViewerLink
              anchors.right: openViewerLink.visible
                ? openViewerLink.left : parent.right
              anchors.rightMargin: openViewerLink.visible
                ? Style.space(6) : Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              bordered: true
              iconText: "\uf0c5"
              iconSize: Style.font.caption
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(1)
              tooltipText: "Copy"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Quickshell.execDetached(
                ["wl-copy", "--", parent.parent.link])
            }

            Button {
              id: openViewerLink
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              visible: Logic.isWebLink(parent.parent.link)
              bordered: true
              iconText: "\uf08e"
              iconSize: Style.font.caption
              horizontalPadding: Style.space(5)
              verticalPadding: Style.space(1)
              tooltipText: "Open in browser"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: Quickshell.execDetached(
                ["xdg-open", parent.parent.link])
            }
          }
        }

        // Only while the rest is still coming: the card already shows the
        // title and the when from the list it was opened from.
        Text {
          width: parent.width
          visible: !!(root.service && root.service.eventLoading)
          textFormat: Text.PlainText
          text: "Reading the rest\u2026"
          color: root.subdued
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          visible: !!(root.service && root.service.eventError)
          textFormat: Text.PlainText
          text: root.service ? root.service.eventError : ""
          color: root.danger
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
            }
          }

          // The form, in the order the event reads in the viewer: what, which
          // calendar, when, how often, what reminds you, then the rest.
          Scroller {
            visible: root.editorOpen
            anchors.top: dayHead.bottom
            anchors.bottom: dayFoot.top
            anchors.topMargin: root.ruleGap
            anchors.bottomMargin: root.ruleGap * 2
            contentHeight: editorBody.implicitHeight

            Column {
              id: editorBody
              width: daySidebar.width
              spacing: Style.spacing.md

              readonly property real dateWidth:
                Math.round((width - Style.spacing.sm) * 0.6)
              readonly property var d: root.draft || ({})

              // Grouped the way the viewer reads, each group headed and ruled
              // off from the next, like the settings.

              PanelSectionHeader { width: parent.width; text: "EVENT" }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Title" }
                TextField {
                  width: parent.width
                  height: root.fieldHeight
                  text: editorBody.d.title || ""
                  foreground: root.foreground
                  onTextEdited: root.setDraft("title", text)
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Calendar" }
                Picker {
                  width: parent.width
                  options: root.editCalendars
                  value: editorBody.d.calendarUrl || ""
                  onPicked: function (choice) { root.setDraft("calendarUrl", choice) }
                }

                // Only for an event that already exists somewhere: a new one
                // is not being moved, just put in the other account.
                Text {
                  width: parent.width
                  readonly property string said: root.creating || !root.draftBase ? ""
                    : Logic.moveNote(root.calendars, root.draftBase.calendarUrl,
                                     editorBody.d.calendarUrl)
                  visible: said !== ""
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: said
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "SCHEDULE" }

              SettingSwitch {
                label: "All day"
                checked: !!editorBody.d.allDay
                onToggled: root.setDraft("allDay", !editorBody.d.allDay)
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Starts" }
                Row {
                  width: parent.width
                  spacing: Style.spacing.sm
                  DateField {
                    width: editorBody.d.allDay ? parent.width : editorBody.dateWidth
                    value: editorBody.d.startDate || ""
                    onPicked: function (key) { root.setDraft("startDate", key) }
                  }
                  TimeField {
                    visible: !editorBody.d.allDay
                    width: parent.width - editorBody.dateWidth - parent.spacing
                    value: editorBody.d.startTime || ""
                    onPicked: function (clock) { root.setDraft("startTime", clock) }
                  }
                }

                ZoneField {
                  visible: !editorBody.d.allDay
                  width: parent.width
                  value: editorBody.d.startZone || ""
                  onPicked: function (zone) { root.setDraft("startZone", zone) }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Ends" }
                Row {
                  width: parent.width
                  spacing: Style.spacing.sm
                  DateField {
                    width: editorBody.d.allDay ? parent.width : editorBody.dateWidth
                    value: editorBody.d.endDate || ""
                    onPicked: function (key) { root.setDraft("endDate", key) }
                  }
                  TimeField {
                    visible: !editorBody.d.allDay
                    width: parent.width - editorBody.dateWidth - parent.spacing
                    value: editorBody.d.endTime || ""
                    onPicked: function (clock) { root.setDraft("endTime", clock) }
                  }
                }

                ZoneField {
                  visible: !editorBody.d.allDay
                  width: parent.width
                  value: editorBody.d.endZone || ""
                  onPicked: function (zone) { root.setDraft("endZone", zone) }
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "REPEAT" }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Repeat" }
                Picker {
                  width: parent.width
                  options: root.draft ? Logic.repeatChoices(root.draft) : []
                  value: editorBody.d.repeat || "none"
                  onPicked: function (choice) { root.setDraft("repeat", choice) }
                }
              }

              // Custom: every how many of what, and on which days. Only
              // what the start date can be is offered, so a rule never
              // lands on a day the event is not on.
              Column {
                id: customBox
                visible: editorBody.d.repeat === "custom"
                width: parent.width
                spacing: Style.space(4)

                readonly property var rule: editorBody.d.rule || ({})

                FormLabel { text: "Every" }
                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  NumberField {
                    id: intervalField
                    fieldWidth: Style.space(70)
                    from: 1
                    to: 99
                    value: customBox.rule.interval || 1
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onModified: function (value) { root.setRule("interval", value) }
                  }

                  Picker {
                    width: parent.width - intervalField.width - parent.spacing
                    options: Logic.freqOptions().map(function (f) {
                      return { value: f.value,
                               label: Logic.freqUnit(f.value, customBox.rule.interval) }
                    })
                    value: customBox.rule.freq || "WEEKLY"
                    onPicked: function (choice) { root.setRule("freq", choice) }
                  }
                }

                Row {
                  id: dayRow
                  visible: customBox.rule.freq === "WEEKLY"
                  width: parent.width
                  spacing: Style.space(4)
                  readonly property var days: customBox.rule.days || []

                  Repeater {
                    model: Logic.dayToggles(root.weekStartDay)

                    Button {
                      required property var modelData
                      width: (dayRow.width - dayRow.spacing * 6) / 7
                      height: root.controlSize
                      bordered: true
                      text: modelData.label
                      tooltipText: modelData.name
                      selected: dayRow.days.indexOf(modelData.value) !== -1
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.toggleRuleDay(modelData.value)
                    }
                  }
                }

                Picker {
                  visible: customBox.rule.freq === "MONTHLY" || customBox.rule.freq === "YEARLY"
                  width: parent.width
                  options: Logic.monthByOptions(editorBody.d.startDate, customBox.rule.freq)
                  value: customBox.rule.monthBy || "date"
                  onPicked: function (choice) { root.setRule("monthBy", choice) }
                }
              }

              // How it ends, for any rule the form can say — a preset or a
              // custom one alike. A kept rule keeps its own end.
              Column {
                id: endBox
                visible: editorBody.d.repeat !== "none" && editorBody.d.repeat !== "kept"
                width: parent.width
                spacing: Style.space(4)

                readonly property var rule: editorBody.d.rule || ({})

                FormLabel { text: "End repeat" }
                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Picker {
                    id: endPicker
                    width: endBox.rule.ends === "never"
                      ? parent.width : Math.round((parent.width - parent.spacing) * 0.4)
                    options: Logic.endOptions()
                    value: endBox.rule.ends || "never"
                    onPicked: function (choice) { root.setRule("ends", choice) }
                  }

                  DateField {
                    visible: endBox.rule.ends === "on"
                    width: parent.width - endPicker.width - parent.spacing
                    value: endBox.rule.until || ""
                    onPicked: function (key) { root.setRule("until", key) }
                  }

                  Row {
                    visible: endBox.rule.ends === "after"
                    spacing: Style.spacing.sm

                    NumberField {
                      fieldWidth: Style.space(70)
                      from: 1
                      to: 999
                      value: endBox.rule.count || 1
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onModified: function (value) { root.setRule("count", value) }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: (endBox.rule.count || 1) === 1 ? "time" : "times"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                // The rule read back in words, so what will be kept is
                // what the person sees before saving it.
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.draft ? Logic.ruleSummary(root.draft) : ""
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "LOCATION" }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Address" }
                // iCloud stores an address on several lines, and they go
                // back on the lines they came on — so a box that can hold
                // them, starting at one.
                // The address, and what it might be, in a dropdown under it
                // the way a Picker drops its list: the calendar's own
                // addresses first, then the lookup service's, if one is on.
                // It never takes focus from the field, so typing goes on.
                Item {
                  id: addressBox
                  width: parent.width
                  height: addressField.height

                  readonly property bool wanted: root.placeQuery.trim().length >= 2
                    && (root.placeMatches.length > 0 || root.placesProvider !== "none")
                  onWantedChanged: wanted ? placePop.open() : placePop.close()

                  NoteField {
                    id: addressField
                    width: parent.width
                    minLines: 1
                    Keys.onPressed: function (event) {
                      if (!placePop.opened) return
                      var list = root.placeMatches.concat(root.placeLookups)
                      root.placeCurrent = root.suggestKey(event, list.length, root.placeCurrent,
                        function (i) { root.pickPlace(list[i]) })
                      // Enter on nothing chosen asks Nominatim, when it is the one on.
                      if (!event.accepted && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                          && root.placesProvider === "nominatim" && root.placeQuery.trim().length >= 3) {
                        root.searchNominatim()
                        event.accepted = true
                      }
                    }
                    text: editorBody.d.location || ""
                    onTextChanged: {
                      if (!root.draft || text === root.draft.location) return
                      root.setDraft("location", text)
                      // Only what the person types starts suggestions, not the
                      // form filling itself in.
                      if (activeFocus) root.typePlace(text)
                    }
                  }

                  SuggestMenu {
                    id: placePop
                    anchor: addressBox
                    width: addressBox.width
                    // Clicked away from: the suggestions are done with.
                    onClosed: if (addressBox.wanted) root.placeQuery = ""

                    // Addresses run long, so each wraps in full, and a rule
                    // between them keeps where one ends and the next begins.
                    Repeater {
                      model: root.placeMatches
                      Column {
                        required property var modelData
                        required property int index
                        width: placePop.availableWidth
                        spacing: Style.spacing.labelGap

                        Rule { visible: index > 0; width: parent.width }

                        MenuRow {
                          width: parent.width
                          wrap: true
                          highlighted: parent.index === root.placeCurrent
                          label: Logic.singleLine(modelData.text)
                          onActivated: root.pickPlace(modelData)
                        }
                      }
                    }

                    // Nominatim only searches when asked; its rules forbid
                    // suggesting as you type. The ask is a row like the rest.
                    MenuRow {
                      visible: root.placesProvider === "nominatim"
                        && root.placeQuery.trim().length >= 3
                        && !(root.service && root.service.placesSearching)
                      width: placePop.availableWidth
                      label: "Search OpenStreetMap"
                      note: root.nominatimResting ? "a moment\u2026" : ""
                      onActivated: root.searchNominatim()
                    }

                    Repeater {
                      model: root.placeLookups
                      Column {
                        required property var modelData
                        required property int index
                        width: placePop.availableWidth
                        spacing: Style.spacing.labelGap

                        // Ruled off from the calendar's own suggestions too.
                        Rule {
                          visible: index > 0 || root.placeMatches.length > 0
                          width: parent.width
                        }

                        MenuRow {
                          width: parent.width
                          wrap: true
                          highlighted: parent.index + root.placeMatches.length === root.placeCurrent
                          label: Logic.singleLine(modelData.text)
                          onActivated: root.pickPlace(modelData)
                        }
                      }
                    }

                    MenuCaption {
                      visible: !!root.service && root.service.placesSearching
                      width: placePop.availableWidth
                      text: "Searching\u2026"
                    }

                    MenuCaption {
                      visible: !!root.service && root.service.placesError !== ""
                      width: placePop.availableWidth
                      text: root.service ? root.service.placesError : ""
                      color: root.danger
                    }

                    // OpenStreetMap's licence asks for this wherever its
                    // data is shown.
                    MenuCaption {
                      visible: root.placeLookups.length > 0
                      width: placePop.availableWidth
                      text: "\u00a9 OpenStreetMap contributors"
                    }
                  }
                }
              }

              // A video call or dial-in, kept in its own field (RFC 7986
              // CONFERENCE) rather than in the event's URL, so an event can
              // have both. The viewer offers to join it.
              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Video call or conference" }
                TextField {
                  width: parent.width
                  height: root.fieldHeight
                  text: editorBody.d.conference || ""
                  placeholderText: "https://zoom.us/j/\u2026"
                  foreground: root.foreground
                  onTextEdited: root.setDraft("conference", text)
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "INVITEES" }

              // Who is invited, and how they answered. Only the organiser
              // can change the list; anyone else sees it and why.
              Column {
                width: parent.width
                spacing: Style.space(4)

                Repeater {
                  model: editorBody.d.invitees || []

                  Item {
                    required property var modelData
                    width: editorBody.width
                    height: Math.max(inviteeLines.implicitHeight, root.controlSize)

                    Column {
                      id: inviteeLines
                      anchors.left: parent.left
                      anchors.right: removeInviteeButton.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: modelData.name || modelData.email
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: (modelData.name ? modelData.email + " \u00b7 " : "")
                            + Logic.inviteeStatus(modelData.status)
                        color: root.subdued
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Button {
                      id: removeInviteeButton
                      visible: root.canInviteHere
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      width: root.controlSize
                      height: root.controlSize
                      bordered: true
                      iconText: "\uf00d"
                      tooltipText: "Remove " + (modelData.name || modelData.email)
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.removeInvitee(modelData.email)
                    }
                  }
                }

                Text {
                  width: parent.width
                  visible: !root.canInviteHere
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Only " + (root.draftBase && root.draftBase.organizer
                    ? root.draftBase.organizer : "the organiser")
                    + " can change who\u2019s invited."
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // The address being typed, and the contacts it could be in a
                // dropdown under it, the same as the address field's.
                Item {
                  id: inviteeBox
                  visible: root.canInviteHere
                  width: parent.width
                  height: inviteeRow.height

                  readonly property bool wanted: root.canInviteHere
                    && root.inviteeSuggestions.length > 0 && !root.inviteeDismissed
                  onWantedChanged: wanted ? inviteePop.open() : inviteePop.close()

                  Row {
                    id: inviteeRow
                    width: parent.width
                    spacing: Style.spacing.sm

                    TextField {
                      id: inviteeField
                      width: parent.width - addInviteeButton.width - parent.spacing
                      height: root.fieldHeight
                      text: root.inviteeText
                      placeholderText: "Add by email"
                      foreground: root.foreground
                      onTextEdited: { root.inviteeText = text; root.inviteeDismissed = false }
                      onAccepted: root.addInvitee(root.inviteeText, "")
                      Keys.onPressed: function (event) {
                        if (!inviteePop.opened) return
                        var list = root.inviteeSuggestions
                        root.inviteeCurrent = root.suggestKey(event, list.length, root.inviteeCurrent,
                          function (i) { root.addInvitee(list[i].email, list[i].name) })
                      }
                    }

                    Button {
                      id: addInviteeButton
                      width: root.controlSize
                      height: root.fieldHeight
                      bordered: true
                      iconText: "\uf067"
                      tooltipText: "Add invitee"
                      enabled: root.inviteeText.trim() !== "" && root.inviteeProblem === ""
                      opacity: enabled ? 1.0 : 0.4
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.addInvitee(root.inviteeText, "")
                    }
                  }

                  SuggestMenu {
                    id: inviteePop
                    anchor: inviteeBox
                    width: inviteeBox.width
                    // Clicked away from: stays shut until the address changes.
                    onClosed: if (inviteeBox.wanted) root.inviteeDismissed = true

                    Repeater {
                      model: root.inviteeSuggestions
                      MenuRow {
                        required property var modelData
                        required property int index
                        highlighted: index === root.inviteeCurrent
                        width: inviteePop.availableWidth
                        label: modelData.name || modelData.email
                        note: modelData.name ? modelData.email : ""
                        onActivated: root.addInvitee(modelData.email, modelData.name)
                      }
                    }
                  }
                }

                // Said as it is typed, once there is enough to judge.
                Text {
                  width: parent.width
                  visible: root.canInviteHere && root.inviteeProblem !== ""
                    && (root.inviteeText.indexOf("@") !== -1 || root.inviteeTried)
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.inviteeProblem
                  color: root.danger
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // The way to suggestions, for someone who has not turned
                // them on. It asks; it does not switch anything by itself.
                // Bordered like every other button on the card, so its box
                // is the edge the section ends on rather than empty padding.
                Button {
                  visible: root.canInviteHere && !!root.service && !root.service.contactsEnabled
                  width: parent.width
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf2bb"
                  text: "Suggest from iCloud Contacts\u2026"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.consentKind = "contacts"
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "OPTIONS" }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Alert" }
                Picker {
                  width: parent.width
                  options: root.draft ? Logic.alertChoices(root.draft, 0) : []
                  value: editorBody.d.alerts ? editorBody.d.alerts[0] : "none"
                  onPicked: function (choice) { root.setAlert(0, choice) }
                }
              }

              // A second only once there is a first, the way a phone offers
              // it — or if the event already has one.
              Column {
                visible: !!editorBody.d.alerts
                  && (editorBody.d.alerts[0] !== "none" || editorBody.d.alerts[1] !== "none")
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Second alert" }
                Picker {
                  width: parent.width
                  options: root.draft ? Logic.alertChoices(root.draft, 1) : []
                  value: editorBody.d.alerts ? editorBody.d.alerts[1] : "none"
                  onPicked: function (choice) { root.setAlert(1, choice) }
                }
              }

              // Blocked out before the event, as Apple does. None for an
              // all-day event, which Apple does not give one.
              Column {
                visible: !editorBody.d.allDay
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Travel time" }
                Picker {
                  width: parent.width
                  options: root.draft ? Logic.travelChoices(root.draft) : []
                  value: editorBody.d.travel || "0"
                  onPicked: function (choice) { root.setDraft("travel", choice) }
                }
              }

              FormRule { }

              PanelSectionHeader { width: parent.width; text: "DETAILS" }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Notes" }
                NoteField {
                  width: parent.width
                  text: editorBody.d.notes || ""
                  onTextChanged: if (root.draft && text !== root.draft.notes)
                    root.setDraft("notes", text)
                }
              }

              // Files on the event, each removable, and a way to pick more.
              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "Attachments" }

                Button {
                  width: parent.width
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf0c6"
                  text: "Add file\u2026"
                  // Twenty is iCloud's most for one event.
                  enabled: !editorBody.d.attachments
                    || editorBody.d.attachments.length < 20
                  opacity: enabled ? 1.0 : 0.4
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.pickAttachment()
                }

                Repeater {
                  model: editorBody.d.attachments || []

                  Item {
                    required property var modelData
                    required property int index
                    width: editorBody.width
                    height: root.controlSize

                    Text {
                      anchors.left: parent.left
                      anchors.right: removeAttachmentButton.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideMiddle
                      textFormat: Text.PlainText
                      text: Logic.attachmentLabel(modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Button {
                      id: removeAttachmentButton
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      width: root.controlSize
                      height: root.controlSize
                      bordered: true
                      iconText: "\uf00d"
                      tooltipText: "Remove " + modelData.name
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.removeAttachment(index)
                    }
                  }
                }

                // "None", or how much of iCloud's allowance is used.
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: Logic.attachmentSummary(editorBody.d.attachments || [])
                  color: root.subdued
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  width: parent.width
                  visible: root.attachError !== ""
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: root.attachError
                  color: root.danger
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(4)
                FormLabel { text: "URL" }
                TextField {
                  width: parent.width
                  height: root.fieldHeight
                  text: editorBody.d.url || ""
                  placeholderText: "https://"
                  foreground: root.foreground
                  onTextEdited: root.setDraft("url", text)
                }
              }

            }
          }

          // Pinned to the foot of the column, under whatever scrolls above:
          // Edit and Delete while reading an event, Save and Cancel while
          // changing one. The same foot the calendar list keeps its Add on.
          Column {
            id: dayFoot
            visible: root.viewerOpen
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.spacing.md

            // Why Save is not lit, said where Save is.
            Text {
              width: parent.width
              // Not on a new event nobody has touched yet: a blank form is
              // not a mistake, and Save being off already says so.
              visible: root.editorOpen && root.draftProblem !== ""
                && !(root.creating && root.draftChanges.length === 0)
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.draftProblem
              color: root.danger
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // And why Edit and Delete are not, once the event has loaded.
            Text {
              width: parent.width
              visible: !root.editorOpen && !!root.viewerEvent
                && !!root.viewerEvent.readonly
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "This calendar is shared read-only, so its events can\u2019t be changed here."
              color: root.subdued
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.editNotice !== ""
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.editNotice
              color: root.editNoticeBad ? root.danger : root.subdued
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Rule { width: parent.width }

            Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

            Row {
              visible: !root.editorOpen
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - Style.spacing.md * 2 - root.controlSize) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf040"
                text: "Edit"
                enabled: root.viewerEditable
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.startEdit()
              }

              // A copy, as a new event: open as soon as the event's detail
              // is in, and whatever calendar it is in — a read-only one's
              // events can still be copied into a calendar of one's own.
              Button {
                width: (parent.width - Style.spacing.md * 2 - root.controlSize) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf0c5"
                text: "Duplicate"
                enabled: root.viewerLoaded && root.newEventCalendar !== ""
                  && !(root.service && root.service.writing)
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.startDuplicate()
              }

              // Square, a glyph and its tooltip: the one action here that
              // asks before it does anything, so it can spare its label to
              // give Edit and Duplicate room for theirs.
              Button {
                width: root.controlSize
                height: root.controlSize
                bordered: true
                iconText: "\uf1f8"
                tooltipText: "Delete event"
                enabled: root.viewerEditable && !(root.service && root.service.writing)
                opacity: enabled ? 1.0 : 0.4
                foreground: root.danger
                fontFamily: root.fontFamily
                onClicked: root.requestDelete()
              }
            }

            Row {
              visible: root.editorOpen
              width: parent.width
              spacing: Style.spacing.md

              Button {
                width: (parent.width - Style.spacing.md) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf00c"
                text: root.service && root.service.writing ? "Saving\u2026" : "Save"
                // Nothing to save until something has changed, and nothing
                // that would not survive being saved.
                enabled: !(root.service && root.service.writing)
                  && (root.creating || root.draftChanges.length > 0)
                  && root.draftProblem === ""
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.requestSave()
              }

              Button {
                width: (parent.width - Style.spacing.md) / 2
                height: root.controlSize
                bordered: true
                iconText: "\uf00d"
                text: "Cancel"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.requestCancel(null)
              }
            }
          }

          // The timed list takes what is left and scrolls, since a busy day
          // here runs to a dozen appointments.
          Scroller {
            visible: !root.viewerOpen
            anchors.top: dayHead.bottom
            anchors.bottom: parent.bottom
            anchors.topMargin: root.ruleGap
            contentHeight: timedList.implicitHeight

            Column {
              id: timedList
              width: daySidebar.width
              spacing: Style.spacing.md * 2

              Repeater {
                model: root.selected.timed
                DayEntry {
                  required property var modelData
                  width: daySidebar.width
                  event: modelData
                  timeFormat: root.timeFormat
                  wrap: root.wrapEvents
                  onActivated: root.openEvent(modelData)
                }
              }
            }
          }
        }
      }
    }
    // The instructions, over the card. Every link is readable and copiable as
    // well as clickable: someone being asked for a password should be able to
    // see where a button would send them, and type it themselves if they
    // would rather not trust the button. omedia shows an update command the
    // same way.
    Rectangle {
      id: helpModal
      anchors.fill: parent
      // Declared after the calendar, and z above it: siblings paint in
      // declaration order, so a modal written first sits under what it is
      // meant to cover.
      z: 1
      visible: root.helpOpen
      color: Util.alpha(Color.popups.background, 0.88)

      // Swallows anything aimed at the card behind it, and dismisses.
      MouseArea {
        anchors.fill: parent
        onClicked: root.helpOpen = false
      }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(Style.space(520), parent.width - root.ruleGap * 2)
        height: Math.min(helpBody.implicitHeight + root.ruleGap * 2,
                         parent.height - root.ruleGap * 2)
        radius: Style.cornerRadius
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        // Clicks inside the card are not dismissals.
        MouseArea { anchors.fill: parent }

        Scroller {
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          anchors.topMargin: root.ruleGap
          anchors.bottomMargin: root.ruleGap
          anchors.leftMargin: root.ruleGap
          // The modal pads itself, so its gutter is already inside the card:
          // the viewport reaches the card's edge instead of past it, and the
          // right-hand padding is what the bar sits in.
          anchors.rightMargin: 0
          contentHeight: helpBody.implicitHeight

          Column {
            id: helpBody
            width: parent.width
            spacing: Style.spacing.md

            ColumnHeader {
              width: parent.width
              title: "App-specific password"
              meta: "iCloud"

              trailingControl: Component {
                Button {
                  width: root.controlSize
                  height: root.controlSize
                  bordered: true
                  iconText: "\uf00d"
                  tooltipText: "Close"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.helpOpen = false
                }
              }
            }

            Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

            Rule { width: parent.width }

            Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

            Repeater {
              model: Logic.appPasswordSteps()

              Column {
                required property var modelData
                required property int index
                width: helpBody.width
                spacing: Style.space(2)

                Row {
                  width: parent.width
                  spacing: Style.space(10)

                  Text {
                    id: stepNumber
                    width: Style.space(18)
                    horizontalAlignment: Text.AlignRight
                    textFormat: Text.PlainText
                    text: (index + 1)
                    color: root.subdued
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  // The step named, then what to do in it: a reader looking
                  // for where they got to reads the titles, not the prose.
                  Column {
                    width: parent.width - stepNumber.width - parent.spacing
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      wrapMode: Text.WordWrap
                      textFormat: Text.PlainText
                      text: modelData.title
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }

                    Text {
                      width: parent.width
                      wrapMode: Text.WordWrap
                      textFormat: Text.PlainText
                      text: modelData.text
                      color: root.subdued
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                // The link itself, selectable, with a copy beside it and an
                // open beside that.
                BorderSurface {
                  visible: !!modelData.link
                  x: Style.space(18) + Style.space(10)
                  width: helpBody.width - x
                  height: visible ? Math.max(linkText.implicitHeight + Style.space(12),
                                             root.controlSize) : 0
                  radius: Style.spacing.labelGap
                  color: Style.normalFillFor(root.foreground, Color.accent)
                  borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

                  TextEdit {
                    id: linkText
                    anchors.left: parent.left
                    anchors.right: copyLink.left
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.WrapAnywhere
                    textFormat: TextEdit.PlainText
                    text: modelData.link
                    color: root.foreground
                    selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Button {
                    id: copyLink
                    anchors.right: openLink.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    bordered: true
                    iconText: "\uf0c5"
                    iconSize: Style.font.caption
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(1)
                    tooltipText: "Copy"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: Quickshell.execDetached(["wl-copy", "--", modelData.link])
                  }

                  Button {
                    id: openLink
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    bordered: true
                    iconText: "\uf08e"
                    iconSize: Style.font.caption
                    horizontalPadding: Style.space(5)
                    verticalPadding: Style.space(1)
                    tooltipText: "Open in browser"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: Quickshell.execDetached(["xdg-open", modelData.link])
                  }
                }
              }
            }
          }
        }
      }
    }

    // Switching a calendar off in settings deletes what has been cached for
    // it, which is not what the same switch means on the month beside this —
    // there it only hides one. A control that means two different things has
    // to say which, so this one asks.
    Rectangle {
      id: forgetModal
      anchors.fill: parent
      // Above the help modal for the same reason that one is above the card.
      z: 2
      visible: !!root.pendingForget
      color: Util.alpha(Color.popups.background, 0.88)

      // Clicking away is the same answer as No: the switch has not moved yet.
      MouseArea {
        anchors.fill: parent
        onClicked: root.pendingForget = null
      }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(Style.space(420), parent.width - root.ruleGap * 2)
        height: forgetBody.implicitHeight + root.ruleGap * 2
        radius: Style.cornerRadius
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        MouseArea { anchors.fill: parent }

        Column {
          id: forgetBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: root.ruleGap
          spacing: Style.spacing.md

          ColumnHeader {
            width: parent.width
            title: root.pendingForget
              ? Logic.singleLine(root.pendingForget.name) : ""
            meta: "Delete calendar"
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Rule { width: parent.width }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Omarcal stops syncing this calendar and deletes every "
                + "event it has cached for it. The calendar itself stays on "
                + "iCloud, untouched — switching it back on downloads it "
                + "again from scratch.\n\nTo hide one without deleting "
                + "anything, close settings and click it in the calendar "
                + "list."
            color: root.subdued
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: "\uf1f8"
              text: "Yes, delete"
              foreground: root.danger
              fontFamily: root.fontFamily
              onClicked: root.confirmForget()
            }

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: "\uf00d"
              text: "No, cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.pendingForget = null
            }
          }
        }
      }
    }

    // The question a save or a delete asks before it goes: yes or no for a
    // delete, and for anything in a series, how far it reaches. The same
    // shape as the calendar question above it, answered by clicking away
    // or with Escape the same way.
    Rectangle {
      id: actionModal
      anchors.fill: parent
      z: 2
      visible: root.pendingAction !== ""
      color: Util.alpha(Color.popups.background, 0.88)

      readonly property bool deleting: root.pendingAction === "delete"
      readonly property bool discarding: root.pendingAction === "discard"

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismissAction()
      }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(Style.space(420), parent.width - root.ruleGap * 2)
        height: actionBody.implicitHeight + root.ruleGap * 2
        radius: Style.cornerRadius
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        MouseArea { anchors.fill: parent }

        Column {
          id: actionBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: root.ruleGap
          spacing: Style.spacing.md

          ColumnHeader {
            width: parent.width
            title: root.viewerEvent ? Logic.singleLine(root.viewerEvent.title)
              : root.draft ? (Logic.singleLine(root.draft.title) || "New event") : ""
            meta: actionModal.deleting ? "Delete event"
              : actionModal.discarding ? "Unsaved changes" : "Save changes"
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Rule { width: parent.width }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: Logic.actionPrompt(root.pendingAction, root.pendingScopes, root.draftChanges)
            color: root.subdued
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          // A one-off delete: the same pair the calendar question has.
          Row {
            visible: root.pendingScopes.length === 0
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: "\uf1f8"
              text: actionModal.discarding ? "Discard changes" : "Yes, delete"
              foreground: root.danger
              fontFamily: root.fontFamily
              onClicked: root.finishAction(root.pendingAction, "")
            }

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: actionModal.discarding ? "\uf040" : "\uf00d"
              text: actionModal.discarding ? "Keep editing" : "No, cancel"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.dismissAction()
            }
          }

          // A series: one button per answer, each saying exactly what it
          // reaches, and a way out under them.
          Repeater {
            model: root.pendingScopes

            Button {
              required property var modelData
              width: actionBody.width
              height: root.controlSize
              bordered: true
              iconText: actionModal.deleting ? "\uf1f8" : "\uf00c"
              text: modelData.label
              foreground: actionModal.deleting ? root.danger : root.foreground
              fontFamily: root.fontFamily
              onClicked: root.finishAction(root.pendingAction, modelData.value)
            }
          }

          Button {
            visible: root.pendingScopes.length > 0
            width: parent.width
            height: root.controlSize
            bordered: true
            iconText: "\uf00d"
            text: "Cancel"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.dismissAction()
          }
        }
      }
    }

    // Anything that leaves the machine is asked for plainly, once, before
    // any of it happens: what is read or sent, where it goes, and how to
    // undo it. Contacts and address lookups share the one question.
    Rectangle {
      id: consentModal
      anchors.fill: parent
      z: 3
      visible: root.consentKind !== ""
      color: Util.alpha(Color.popups.background, 0.88)

      // Clicking away is the same answer as Don't allow.
      MouseArea {
        anchors.fill: parent
        onClicked: root.consentKind = ""
      }

      BorderSurface {
        anchors.centerIn: parent
        width: Math.min(Style.space(420), parent.width - root.ruleGap * 2)
        height: contactsBody.implicitHeight + root.ruleGap * 2
        radius: Style.cornerRadius
        color: Color.popups.background
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)

        MouseArea { anchors.fill: parent }

        Column {
          id: contactsBody
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: root.ruleGap
          spacing: Style.spacing.md

          ColumnHeader {
            width: parent.width
            title: root.consentKind === "contacts" ? "iCloud Contacts"
                 : root.consentKind === "nominatim" ? "Nominatim" : "Photon"
            meta: root.consentKind === "contacts" ? "Allow access?" : "Send addresses?"
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Rule { width: parent.width }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.consentKind === "contacts" ? Logic.contactsPermissionText()
                : Logic.placesPermissionText(root.consentKind)
            color: root.subdued
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Item { width: 1; height: Math.max(0, root.ruleGap - Style.spacing.md * 2) }

          Row {
            width: parent.width
            spacing: Style.spacing.md

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: "\uf00c"
              text: "Allow"
              // Green for yes and red for no, so the answer reads before
              // the label does.
              foreground: root.stored
              fontFamily: root.fontFamily
              onClicked: root.allowConsent()
            }

            Button {
              width: (parent.width - Style.spacing.md) / 2
              height: root.controlSize
              bordered: true
              iconText: "\uf00d"
              text: "Don\u2019t allow"
              foreground: root.danger
              fontFamily: root.fontFamily
              onClicked: root.consentKind = ""
            }
          }
        }
      }
    }
  }
}
