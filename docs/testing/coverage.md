# Current native coverage

What the Swift test bundle asserts, one section per `Tests/Unit/<Domain>/`
folder. This is the inventory behind `python3 scripts/test.py`; the strategy,
layers, tiers and evidence policy live in [README.md](README.md). Read it to
find out whether a behavior is already covered before adding a test, and where a
claim stops: "Not covered" notes name what the tests do not establish. Nothing
here starts the app, opens a window or touches the desktop.

Entries are class names, so `python3 scripts/test.py --only <Class>` runs one.
Where a feature document has its own Verification section it owns the detail and
is linked from the domain; the shared limits are collected at the end.

## Appearance

- `AppThemeTests` — a chosen theme survives recreation and reset leaves other
  preferences alone; an invalid change cannot overwrite saved values; a damaged
  saved accent or an unknown icon does not discard the rest.
- Offscreen `ControlPanelShellTests` commit the real Appearance controls through
  the native bridge (mode, accent, tone), reset them and check the saved
  preferences.

## Automation

`AutomationCommandTests`, `AppAutomationTests`, `HotKeyPreferencesTests`,
`GlobalHotKeysTests`, `WallpaperAutomationPlannerTests`,
`WallpaperAutomationStoreTests`, `WallpaperAutomationSchedulerTests`,
`WallpaperFocusFilterTests` and offscreen `ControlPanelAutomationTests`: rules,
solar and DST boundaries, appearance selection, Focus recovery and manual
precedence, editor round trips and preference validation. `WallpaperBackupTests`
covers rule merging and local recovery-state rollback. What each covers, and what
needs the running app, is in [automation](../features/automation.md#verification).

## Desktop

### Posters (Mission Control)

`DesktopWallpaperTests` use synthetic renderer pixels, an in-memory workspace,
unattached `CAMetalLayer`s and injected notification and encoding services:

- Pixels and delivery: JPEG dimensions, channel order and orientation within
  lossy tolerance; a new wallpaper and the first ready frame reach every Space
  without visiting it; the newer frame wins whatever order encodes finish in;
  late frames and encodes from another Space or an old layer are rejected; a
  frame identical to the poster is neither encoded nor written.
- Capture timing: a Space change applies the existing poster at once and asks for
  a fresh frame; settling captures after a new wallpaper and after a resume;
  periodic captures only while enabled; later captures skip displays that are not
  presenting.
- Refusals: a desktop that keeps refusing posters is left alone until the next
  Space change; a poster that reads back late is confirmed without counting a
  refusal; a failed Space neither blocks the others nor loses its old poster.
- Originals and quit: inherited (pathless) selections resolve through the public
  API before any poster write and are never replaced by an unresolved poster;
  independent per-Space originals survive; a user's own wallpaper change is not
  overwritten on restore; quit waits for the native reload, every read-back and
  in-flight writes, keeps the original when restoration fails persistently, and
  cannot be blocked forever by an unreachable reference; cancelling a restoration
  that is waiting (a logout's deadline) stops it and leaves the journal entry and the
  poster for a later run to finish.
- Retention: frame URLs are immutable and pruned only after every Space updates;
  displays on the current-Space fallback or with an unreadable Space keep a
  bounded number of the newest posters.

Not covered: what Mission Control actually shows and its refresh latency, and
macOS accepting or restoring native selections. Both are on
[manual-smoke.md](manual-smoke.md). Behavior: [desktop picture](../features/desktop-picture.md).

### Wallpaper activation

`WallpaperActivationRecoveryTests` use a fake renderer bridge: they cover
application preflight and recovery, not decoded frames or desktop playback.
Missing, empty and non-file video entries are rejected before any change; an
original synthetic H.264 Matroska clip applies through Apply and Apply changes
with either backend preference; decoder failures keep the error and leave the
library usable for retry; history changes only after a successful activation;
playback-environment changes (suspend/resume, unload/reload, audio) and library
refreshes wait for an in-flight apply and the reverse, while explicit Pause still
interrupts; the first-wallpaper support prompt follows only a successful
downloaded activation; only the user's own activation reports a manual choice,
and an update reload gives way to a choice the user is waiting on; a wallpaper
held back after a crash keeps its display assignment, so only the user's choice
of it reaches the bridge to lift the hold, while a playlist, rule or layout
finds it already shown and stops. The same suite
covers Retry for a scene that stopped drawing over the two-display fake: it takes
the wallpaper off the named display and applies it again and touches no other, a
display with no wallpaper gets an error and no change, a mirroring display reloads
the display it mirrors (and a mirror of an empty display gets the error), a retry
that waited behind a command switching its display leaves the switch alone, one that
arrives while the user's switch runs there gives way at once, and a newer
choice replaces a retry still waiting; reloading everywhere after an update still
reloads every display. `UserCommandQueueTests` — commands run in arrival order, a
newer command in the same slot replaces a waiting one, a playlist, rule or
update reload never replaces a user command waiting in its slot (it returns at
once and leaves the slot revision alone), and a choice noted without a command
counts once in each slot named and replaces nothing that waits.
`WallpaperReapplyTests` and `WallpaperReapplyPanelTests` — the inspector's
**Reapply wallpaper** takes the wallpaper off its display once and applies it
again from an empty display, as the user's choice but not as a first apply
(history and the support prompt stay as they were); it refuses before any
eject when the wallpaper's files, the display or an unfinished edit would make
the apply fail; a wallpaper the display does not show is simply applied; and
through the real panel only that button restarts, while a tile's double-click
leaves the shown wallpaper running. Not covered: whether a scene reload flashes
on the desktop ([manual-smoke.md](manual-smoke.md)).

### Playback policy

- `WallpaperPresentationPolicyTests` — display sleep and wake, session lock
  (asked only when it can have changed, re-asked on wake and user switch, a
  missed unlock clearing at the next evaluation), full occlusion and a covered
  working area suspending after the settle delay, per-display independence,
  reconnect handling, retried failed suspends and resumes, `stop()` resuming
  every suspended surface, and the resume announcement (`onResumed`) after a global
  or per-display resume, but not after a suspend, a refused delivery or teardown.
- `SystemWakeRevalidatorTests` — against a private notification center and
  injected delays, idle wait and bridge call: a wake's two notifications are one
  check, a check waits for the command queue, a wake at the lock screen is checked
  when presentation resumes, a newer wake supersedes a waiting one, `stop()`
  cancels, a bridge failure is reported and not thrown, and the summary counts
  repaired, skipped and still-stopped displays (as counts, with the warning that
  goes with a repair; one test pins the wording of the log lines, which are the
  ones the diagnostics doc shows). The bridge's half is `wake_revalidation` in
  `wallpaper-bridge`.
- `PlaybackPolicyCompositionTests`, `PlaybackPreferencesTests`,
  `AppRuleMonitorTests`, `OtherAudioMonitorTests` — how sleep, lock, app rules
  and other-app audio compose (Stop beats Pause, Keep running ignores audio),
  defaults and corrupt stored values, running versus frontmost rules, and the
  other-audio settle.
- `SystemConditionMonitorTests` use injected Low Power Mode and thermal readings
  and a private notification center: Low Power Mode acts only once an action is
  chosen, only serious and critical heat counts, a Focus filter joins the other
  conditions and survives a new instance, and `stop()` releases every action.
  `WallpaperFocusFilterTests` pin the filter's default to the choice that lets
  wallpapers run, since macOS performs it with defaults when a Focus ends.
- `PowerSourceMonitorTests` use an injected reading: only a different source is
  reported (the system notification also fires as the charge moves), a change made
  before `start()` is not lost, and the snapshot refresh after a change repeats until
  the bridge reports the source the system did, survives a failed refresh, stops after
  the last delay and on cancellation. The notification itself, and the race between
  the renderer's power thread and the app's observer, need a real plug or unplug and
  are not covered.
- `DisplayRefreshCoalescerTests` — a burst during a refresh is answered by one
  more; screen changes that leave the displays as they were refresh nothing; a
  failed refresh is retried. `DisplayTitleResolverTests` — localized display
  names replace the renderer's label; `DisplayGeometry` finds a screen by id or
  by the title's live id, clamps its shape and has none for an unattached display.
- `WallpaperWindowAuditorTests` — against injected window observations and
  recorded delays, asserting the reports the auditor makes (fault, window, look,
  repairs done) and pinning the wording of the log lines in one test: a healthy
  desktop writes nothing and looks once; a window off
  its Space is reported at the first look and again at the last, repaired only with
  the hidden preference and never beyond the two-step ladder or its budget; a
  burst of triggers keeps one schedule; nothing happens while presentation is
  paused or for a Space fault in a full-screen Space; repeated reports are
  throttled; only a new window number or a moved display starts a check.

Not covered: the real Focus Settings pane and a real Low Power Mode; real
wallpaper windows on another Space and the effect of either repair step; whether
a scene surface stops producing frames across a real sleep and wake, and whether
the wake check's repair restores it (needs a desktop run).

### Spaces

`WallpaperSpaceMonitorTests`, the Space scenarios in
`WallpaperAutomationSchedulerTests`, store and backup migration checks, and
offscreen `ControlPanelSpaceWallpaperTests`. `DesktopWallpaperTests` covers
Space-scoped writes, late frames and encodes, replacement gaps and restoration.
Not covered: real Space transitions and installed desktop behavior; see
[Spaces](../features/spaces.md).

### Display layouts and transfer

`WallpaperDisplayTransferTests` and `WallpaperDisplayTransferIntegrationTests`
cover capture of stable display identity, complete validation before any write,
copy and swap, rollback and recovery (including cancellation and empty
destinations), one history entry per display, newer manual commands and a
transfer counting as the user's choice for each display it gives a wallpaper
to, from the moment it is asked for.
`WallpaperDisplayLayoutStoreTests` (Library) covers bounded persistence, and
offscreen `ControlPanelDisplayLayoutTests` covers save, rename, apply, delete,
copy/swap failure feedback, keyboard focus, missing screens and compact locales.
Not covered: real WindowServer transitions, visible appearance and separate
per-Space assignments; see
[display layouts](../features/display-layouts.md#code-and-verification).

## Diagnostics

- `AppLogRouterTests` — lines logged before the bridge keep their time and order
  and are written when it attaches; overflow is reported, not silent; loads start
  only once the log is open; concurrent lines all arrive.
- `DiagnosticsRedactorTests` — home paths in all forms, user and account names
  as whole tokens only, SteamCMD sign-in names, credential values, the beta
  identifier of macOS reports.
- `DiagnosticsBundleTests` — newest sessions first (including `-N` suffix order),
  the byte budget with tail truncation, crash-report prefix, age and count
  filters, a missing extension log noted, the load journal, resource, spin and
  hang reports from both report folders (prefix, extension, age, `Retired/`,
  count, the host name dropped from stored names, an oversized file's tail, an
  unreadable system folder noted without failing the export), and the zip's
  actual entries.
- `SessionLedgerTests` — a record is classified as clean quit, stalled quit,
  unexpected end, system restart or exception (the exception outranks the phase),
  with the boot session compared exactly and an unknown one never called a restart;
  the ring keeps five sessions and counts unexpected ends in a row; an unreadable
  or foreign-format file reads as a first run and is replaced; a refused quit goes
  back to running; a session writes the file three times and nothing writes it
  again; an older copy does not rewrite a newer copy's record; every quit reason
  survives to the next launch and is named in its report, for a finished quit and a
  stalled one.
- `CrashReportIndexTests` — a report is matched by process id and boot session in
  its body, not by name; wrong prefix, wrong extension, another boot, an older
  file, a header without a body and a malformed body are passed over.
- `UncaughtExceptionLogTests` — an exception is logged as one line with its name
  and reason, and the next launch reads it from the ledger.
- `DiagnosticEnvironmentTests` — a running scene's report line carries the
  renderer's live mode (a scene stopped after a failure reads apart from a paused
  one), keeps where it runs and what drew it, and says nothing about the mode
  when there is no reading.
- `RuntimeCountersTests`, `RuntimeDiagnosticsReportTests` and
  `RuntimeDiagnosticsWindowTests` — counters record only inside an open,
  self-expiring session, per surface, with a bounded table; the report keeps
  surface-exclusive and shared work apart, never labels present requests as
  displayed frames, and states the milliseconds it counted.
- `MemoryPressureMonitorTests` and `ProcessFootprintTests` — each pressure level's
  report with the footprint and presenting-scene count, the length of a stretch of
  pressure, the 5-second collapse of repeats, an unreadable footprint staying unknown
  rather than zero, one test pinning the wording of the two lines the diagnostics doc
  shows, and the footprint of the test process growing with the memory it touches.
  A real pressure transition is not provoked.
- `EnergyUsageMonitorTests` and `WallpaperEnergyRatingsTests` — coalition
  readings, contention, before/after comparisons, grades, battery share and the
  rating recorder; two `testKernelCounters…` cases read the test process's real
  kernel counters.

Log line format, retention and the verbose setting are covered in Rust; see
[diagnostics](../features/diagnostics.md#verification).

## GitHub

`AppUpdateTests` use fixture JSON, a fake client and isolated `URLSession`
responses; they never contact GitHub, download a real release or replace the
running app.

- Checking: version comparison, disk-image asset selection, the manifest path
  that spends no API request, host allowlisting, SHA-256 digest requirement,
  rate limits, progress clamping, classified errors and install retry/timeout. A
  missing latest release is normal only after the repository is confirmed
  reachable; missing repositories, failed lookups and malformed metadata remain
  errors, and rechecking clears stale notes and availability.
- Installing, against real disk images made with `hdiutil`: the app is copied out
  without following the `Applications` link, a foreign bundle is refused, the
  image is detached either way, and an app that cannot install in place opens
  the downloaded image.
- The offscreen About flow (`ControlPanelShellTests`) checks again from the
  no-release state before downloading a fixture update.

`WhatsNewTests` — what a launch announces across fresh installs, upgrades that
skip versions, downgrades and language choice. Not covered: a live release
check, the published disk image and replacing the app in Applications; these are
on [manual-smoke.md](manual-smoke.md).

## Library

- `ImportTests` — atomic adoption, duplicates never overwrite, concurrent
  destinations keep one whole project, cancellation never commits an incomplete
  project, rejection of traversal, links, special and incomplete content, and a
  bad sibling not blocking a good one; downloaded projects move whole, an update
  replaces the installed tree, and Workshop presets are assembled on a base that
  was downloaded with them, is installed, or sits beside them in a Steam library,
  and are rejected without a usable base. Where a chosen folder is searched (a
  Steam library, `steamapps`, a Wallpaper Engine install or a copy of it, its
  `projects` folder and either half), a chosen `project.json`, `scene.json` or
  `.pkg` standing for its folder, and links refused in the file, its folder and
  the manifest beside it, are covered, as is the Workshop id a renamed project
  takes from its manifest or link (and the values that are not one), which
  follows the duplicate policy when already installed. **Keep both** copying
  nothing the library already holds is covered for folders, videos and HTML files
  (a one-byte change across chunk boundaries, a same-length manifest edit, added,
  missing, renamed and resized files and folders, Finder's `.DS_Store` on either
  side, the app's `.mwe-user-assets` bridge in the installed project, links in the source and in the library, a preset, an identical folder that
  is not a wallpaper, and cancelling during the comparison). **Replace if changed**
  is covered for a changed folder (the old tree gone, not merged, no staging left),
  identical content left unswapped, one import mixing changed, identical and new
  projects, repairing an install that cannot play, refusing a folder without a
  manifest, a file and a link, a failed swap (a locked folder) keeping the installed
  project, cancelling, and a single file; the panel's choice naming the policy
  (anything unknown stays on skip) and `LibraryImportStore` reloading only replaced
  projects, after the rescan, are covered too, as is a quit not waiting for a rescan or a
  reload still running and starting none it had not begun. Not covered: the speed
  of comparing a multi-gigabyte project on an external drive, and a display
  reloading a replaced wallpaper. Fetching a preset's
  base in the same SteamCMD run is in `DownloaderLifecycleTests`.
- `ImageImportTests` import real ImageIO pictures as the still `web` project with
  the original's bytes kept and the file name kept out of the page, the fit
  chosen from the picture's shape, a JPEG display copy for a TIFF, an undecodable
  file refused, **Keep both** keeping the `image-` prefix for a different picture
  and copying nothing for the same one, and `LibraryImportStore` refusing a second
  import and rescanning once.
  `StillImagePlacementTests`, `StillImagePageUpgradeTests` and
  `StillImagePageRenderingTests` (offscreen) cover per-display placement
  persistence, fit-aware geometry, the version-bound upgrade of generated pages
  (never overwriting an author edit), actual resource changes and reset races.
- `WallpaperImportPickerTests` exercise real child processes: cancellation before
  launch, reaping after cancellation, cleanup when activation fails, invalid
  handshakes, failed exits not treated as user cancellation, and concurrent
  helpers. `WallpaperImportStagingTests` — a live claim protects an import and a
  released one is reclaimed. Not covered: the native picker's localization and
  the selection-to-parent URL handoff (these tests open no picker), and the
  Finder/Dock hand-off.
- `DeletionTests` and `BatchDeletionTests` — only the managed copy goes to the
  Trash, the source is preserved, traversal and symlinks are rejected, a Trash
  failure leaves the wallpaper in the library, a batch continues past failures
  and refreshes once.
- `WallpaperCollectionStoreTests` — stable identity and ordered membership across
  reload, rename and deletion; invalid names apply nothing. `NextWallpaperTests`
  — library order, skipping unsupported wallpapers, wrapping.
  `WallpaperHistoryStoreTests` — per-display persistence, bounded recent lists,
  repeated Previous, removal and clearing.
- `WallpaperPresetStoreTests` — typed applied-property snapshots, portable managed
  attachments, size limits, alias rejection, draft and permission rollback, and
  applied-source retention after deleting a preset.
- `WallpaperBackupTests` — real package export, preview, staged next-launch
  restore, conflict policy (Keep existing, Replace), parser and schema rejection,
  authorization, rollback and interrupted recovery, persistent-only preferences,
  full-size preset archives and manifest preflight. Offscreen
  `ControlPanelBackupFlowTests` drive the real controls against isolated package
  writes and open no file panels.
- `WallpaperCompatibilityTests` — target, content and configuration generations
  and truthful unknown states. They do not establish complete scene or on-screen
  compatibility.
- `LibraryMetricsTests`, `ClientPreferencesTests` — folder size and date measured
  off the snapshot path, manifest approval and tags, and an explicit defaults
  suite staying independent of the application's own preferences.
- `LibraryCoverStampsTests` — preview stamps read after the snapshot answered and
  announced once per pass, a rescan that replaced nothing announcing nothing, a
  replaced preview (by size or by time) keeping its old stamp until the new one is
  read and then announced, a wallpaper that left or whose preview moved having
  nothing known, an unreadable preview stamped 0, and an ask made while a pass was
  reading not being lost.

## Lifecycle

- `QuitReasonTests` — the reason a quit is given for every combination of what the system
  told the app: a signal beats everything, the system leaving beats an update, an update
  beats a plain quit, the event's own reason beats the power-off announcement, an unknown
  code is not taken for the user's; the codes match the SDK's; the reason is read from a
  real `NSAppleEventDescriptor` parameter and not from an attribute, text or an integer; an
  announcement stops counting after its lifetime and after a refused quit. They also pin which
  reasons make a power-off quit (the three kinds, and a signal that arrives during an announced
  shutdown, but not a user's quit, an update or an unknown reason) and the text the session
  ledger keeps for a quit that left the desktop unrestored or a stage running.
- `QuitTimingsTests` — stages keep their own duration in the order they were settled, a stage
  that failed is timed and says why in the log, a stage that was left behind is marked and keeps
  how long it was waited for, the total covers the work between stages, one line per stage plus
  one summary. A scripted clock, no sleeping.
- `QuitSupervisorTests` — stages run in order and every duration is logged once; restoration
  that throws or never returns cancels the quit and teardown does not start; a stage that
  finishes after its deadline changes neither the outcome nor the log; a hanging teardown
  stage is named and the stages after it still run; teardown stages share one budget, a stage
  with no time left is still started, and the last one keeps its floor; a teardown stage that
  throws does not stop the quit; the exit fuse is shorter after a stalled stage and fires
  once, off the main thread. The deadline is a scripted sleep fired by the test and the
  budget each stage was given is the sleep it waits for, so nothing depends on machine
  speed; one test runs the real timer with tiny budgets. `FirstResultTests` pin that the race
  resumes its waiter once however many results arrive. For a logout, restart or shutdown
  (`QuitMode.powerOff`): restoration that throws or never returns lets the quit go on
  without refusing it, the teardown still runs, the restoration is waited for 3 seconds
  and not 20, the teardown has 1.5 seconds with a one-second floor for the last stage, and
  the same failure still refuses a user's quit. `QuitRequestAnswerTests` pin the answer to
  a request that arrives mid-quit: a second user quit is refused, a logout during one waits
  for it, and anything during a power-off quit waits.
- `AppUpdateTests` (GitHub) also pin when an install counts as pending: not while the
  update is prepared, yes once the installer waits and the app is asked to quit, not when
  the installer could not start. They also pin that a refused quit stops the waiting
  installer once, leaves the update to install again, does nothing when no installer
  waits, and keeps a helper that would not stop owned.
- `TerminationSignalRelayTests` — real SIGUSR1 and SIGUSR2 stand in for SIGTERM and SIGHUP, so
  a failed install cannot take the test host down, and the forced end is always injected: one
  signal asks for one quit and the process survives, a second signal or the deadline forces
  the default action instead of asking again, back-to-back signals are one request and one
  force, a reset after a refused quit lets the next signal ask again, each signal arrives
  with its own number, `stop` restores the disposition that was there (not the default), an
  ignored signal stays ignored, a child started with `posix_spawn` sees the default
  disposition (the probe is first shown to see an inherited ignore, which Foundation's
  `Process` would hide by resetting every signal) and both pipe ends are close-on-exec and
  non-blocking. `QuitReasonTests` pin the ledger text of a signal's quit, `QuitSupervisorTests`
  the longest a quit can take (the signal deadline) and `SessionLedgerTests` that a run cut
  short before it began quitting reads as a quit that did not finish, not a crash.
- `ProcessSignalsTests` — SIGPIPE is set back to its default before each call and the guard is
  checked before any write, so a guard that failed to install costs one test and not the
  test host: a write to a pipe whose reader is closed fails with `EPIPE` and the process
  survives, a `FileHandle` write throws it as a POSIX `EPIPE` error, a second call keeps the
  same handler, an ignored SIGPIPE or a handler already in place is left alone, and a child
  started with `posix_spawn` sees the default disposition (the shared `ChildSignalProbe` is
  first shown to see an inherited ignore, as in the relay's test).
- `InstanceLockTests` use temporary folders, an injected clock and an injected process table:
  the claim and its recorded holder, a second claim turned away after the grace, hand-over on
  release, a quitting holder waited for beyond the grace and for as long as the longest
  interactive quit may take, a claim never inherited by a surviving child, a dead, unreadable
  or unusable lock never blocking launch, the decision table, and the classification of the
  running holder. See
  [crash recovery](../features/crash-recovery.md#single-instance).
- Not covered: a real quit, logout or restart; `applicationShouldTerminate` itself needs
  the running app (hosted tests short-circuit it), so the alert, the panel coming back, the
  "Quitting…" menu line, the exit fuse's `_exit`, whether macOS shows its cancelled-logout
  dialog, how AppKit treats a request answered with `terminateLater` while another is
  pending, the retry of a user's quit that a logout interrupted, and a real `kill -TERM`
  ending in an ordered quit (including whether the main run loop wakes for it while the
  panel's modal alert is up) are desktop-only observations ([manual smoke](manual-smoke.md#native-desktop-posters-and-mission-control)).
  The single-instance hand-over is not covered either: activating the first copy, the alert
  for a copy from another path and the post-update relaunch need a desktop run
  ([manual smoke](manual-smoke.md#launch-and-window)).

## Localization

`AppLanguageTests` cover the preference store: system matching, persistence, the
`AppleLanguages` mirror, rejected tags and the snapshot offering every shipped
language under its own name. The Python catalog checks
(`scripts/tests/test_panel_localization.py`) keep the registries, catalogs and
`.xcstrings` naming the same languages and keys; see
[localization](../localization.md).

## LockScreen

The native-selection and service suites run against a synthetic store and injected
services. They never mutate LaunchServices or PlugInKit, select a real wallpaper
or depend on a second physical monitor.

- `LockScreenWallpaperTests` (selection journal) — per-display ownership with
  independent originals; external Desktop changes survive; a reload failure
  leaves a recoverable journal; inherited, linked and system-copied selections
  restore, or stay recoverable after a reload failure; later global Desktop and
  Idle edits are preserved; malformed baselines are rejected without store
  writes; an unchanged journal is not rewritten; a concurrent store change keeps
  the union.
- `LockScreenWallpaperServiceTests` — activation failure hands the Desktop back
  to the poster provider; surviving lock screens are not cleared by topology
  changes; screen-saver-only, lock-only and both modes disable and roll back
  independently; shared-extension and Idle-only publication failures roll back;
  stale failure reports are ignored while a current renderer failure restores the
  selection; one bounded automatic retry repairs a wrong extension copy; shutdown
  restores native choices before waiting for Desktop restoration.
- `LockScreenExtensionRegistrationTests` use synthetic app bundles and an
  injected registry: current-copy selection, duplicate and removed-copy cleanup,
  symlink aliases, invalid inventory rejection, cancellation, command failures.
  `LockScreenExtensionDiagnosticsTests`, `LockScreenSurfaceRegistryTests`,
  `LockScreenIdleExitTests` and `LockScreenFrameBackingTests` (snapshot pixels
  composited under a Metal layer without a drawable) cover the extension side.
- `WallpaperPresentationAuthorityTests` — both display/host wake orders, user
  pause surviving sleep and wake, a lock-screen surface presenting only while
  locked, and an unlocked one settling for `desktopSettleBudget` before it holds
  a frame.

Not covered: real lock-screen visual timing, private XPC snapshot transport, live
registration repair and macOS choosing the intended extension copy; these need an
authorized runtime check ([lock-screen](../features/lock-screen.md#verification)).

## NativeVideo

- `NativeVideoAdmissionTests` — the frame-rate rules (whole-number and NTSC
  rates against the target, variable-rate clips judged by their fastest interval,
  a zero target not meaning unlimited) and refusal of corrupt, missing, audio-only
  and interlaced content.
- `NativeVideoWallpaperHostTests` — startup waits for surface readiness, refused
  wallpapers are handed back to the scene engine with their reason, re-evaluation
  when the target rate changes, one surface per display, mirrors judged by their
  group's strictest target, hidden-display and user-pause handling, a clip stopped
  by a reading taken while the desktop (or one display) was covered playing again
  once `WallpaperHosts.reconcile` has the host read the bridge again (that
  `AppDelegate` makes the call after each delivery is not run by any test), and
  posters from replaced surfaces not published. `NativeVideoPlaybackFailureTests` — the
  reported failure keeps the codes under the localized message and a clip with
  sound is rebuilt with its picture alone.
- `SyntheticVideoFixtureTests` cover the generated-clip writer's input-ready
  waiting. `NativeVideoPlayerMediaTests` drive the real player and are opt-in
  (`WALLPAPER_MACHINE_MEDIA_TESTS=1`, see
  [README.md](README.md#opt-in-layers)).

Not covered: first frames presented on a real display.

## Panel

Offscreen `WKWebView` suites share `ControlPanelTestCase` (`PanelFixture`) and
never order a window on screen. Tests that read rendered labels must pass
`appLanguage: .english()` (`Tests/Unit/Support/TestAppLanguage.swift`) or a store
built with explicit `systemLanguages`: the default `AppLanguageStore.shared`
follows the developer's in-app language choice.

- `ControlPanelShellTests` — the bundled interface loads under its custom scheme,
  routes `navigate` to Settings and denies a non-allowlisted external URL; the
  `NSHostingController` accepts 760×560, 960×640 and 1240×800 proposals in every
  shipped language without forcing a taller window; the panel renders in the
  controller's language and switches in place, offering every shipped language
  and refusing an unshipped tag; About/update actions; the top bar stays centered
  and does not overlap at the minimum width; the first-run guide, background
  focus isolation, Steam prompt focus, ownership notices and a revealed password
  that never reaches the HTML; settings keep drafts, disclosure and scroll across
  snapshots; the Downloads-at-once choice reaches the queue; tabs stay usable
  after a render throws mid-send.
- `ControlPanelLibraryTests` — sorting, tile marks, filter sidebar, hold-and-drag
  selection, the inspector report link, download setup, a rejected download
  account staying visible, and error dismissal (library and download failures
  stay suppressed until they recur), Installed tiles showing cached covers and
  animating only the pointed-at tile (dwell, sweep, drag, blur, hide, tab change),
  the snapshot offering animation only to gif/webp/apng previews, a tile showing
  no image while its cover's stamp is read, a rescan that replaced no preview
  leaving every cover address and page node alone while a replaced preview
  redoes only its own tile, and a tile falling back to the preview file when its
  cover cannot be made. Not covered:
  WebKit's own `:focus-visible` verdict for real keyboard input (the test states
  it), and how the animation looks or what it saves in power.
- `ControlPanelDiscoverTests` — pagination does not navigate with the page number
  and clamps to Steam's page limit, the grid keeps square tiles in at least three
  columns, download rings and telemetry, and previews that play without canvas
  readback and release offscreen images. This does not reproduce a GPU-process
  hang or prove on-screen smoothness.
- `ControlPanelSyncTests` (hidden-panel pushes, option fetches, display titles),
  `ControlPanelSnapshotDeliveryTests` (library reuse during download progress,
  full fallback for an unknown delta revision), `ControlPanelHostStateTests`
  (the inspector's per-display host states and exact retry) and
  `ControlPanelRemediationTests` (crash budget, favorites, placement queue).
- `ControlPanelWindowSizingTests` — size floor, key-view loop, full-screen layout
  keeping navigation reachable and restoring windowed bounds, and WebKit's color
  picker anchor following its control. Not covered: opening the picker, entering
  a full-screen Space or the live Split View transition.
- Feature pages that live here and are described under their domain:
  `ControlPanelAutomationTests`, `ControlPanelBackupFlowTests`,
  `ControlPanelDisplayLayoutTests`, `ControlPanelPixivTests`,
  `ControlPanelPlaybackToolsTests`, `ControlPanelPreviewTests`,
  `ControlPanelSpaceWallpaperTests`.
- Controller-level suites without a web view: `WebPanelAssetsTests` (thumbnail
  routes serve only announced previews; the listed core modules and non-English
  locale catalogs are served, unknown names and traversal refused),
  `WebPanelAssetPropertiesTests`, `WebPanelCompatibilityTests`,
  `WebPanelDeliveryStatusTests`, `WebPanelEnergyUsageTests` (sampling only while
  Settings is visible), `WebPanelExternalLinkTests` (every fixed link in
  `WebUI/*.js` passes the allowlist), `WebPanelGeneralSettingsTests`,
  `WebPanelPerformanceSettingsTests` and `WebPanelSceneSettingsTests` (unknown,
  non-boolean or non-numeric values are refused, out-of-range ones clamped; the
  Retry on a stopped scene refuses an id that names no enabled display, is
  disabled while it runs, and reloads that display (or, for a mirror, the display
  it mirrors) from a click on the real page),
  `WebPanelPropertyLabelTests` (author markup is reduced to text),
  `WebPanelSupportPromptTests`, `WebPanelWorkshopSourceTests`,
  `WebPanelWorkshopUpdateTests`, `WebPanelImagePlacementRaceTests` and
  `WebPanelAssetProvenanceTests`. `WallpaperEditorStateTests` cover locale
  scaling, invalid raw text and independent drafts; `PropertyImageCacheTests`
  cover bounded transfers and that author images cannot become a network proxy.

These checks are windowless; they do not prove desktop presentation or animation
smoothness.

## Pixiv

`Tests/Unit/Pixiv/`, `WebPanelPixivTests` and offscreen `ControlPanelPixivTests`
cover decoding of pixiv's answer shapes, search and ranking addresses, ratings
including R-18 and R-18G, request pacing, the session cookie reaching
`https://www.pixiv.net` only, sign-in, log out, a keychain refusal and expiry
against an in-memory store, resumable thumbnail and download transport, the
download queue (concurrency, cancel, retry, shutdown) and packaging (sniffed
formats, scaled display copies, staging reclaim). None of it reaches pixiv: its
signed-in answers and the real sign-in page are not covered
([pixiv](../features/pixiv.md#verification)).

## Playlist

`PlaylistPlannerTests` (candidates, order, shuffle rounds, day/night boundaries),
`PlaylistStoreTests` (persistence, custom intervals, reordering, plans copied
across displays and detached on manual edit, cleanup when wallpapers or
collections go), `PlaylistSchedulerTests` (fake clock, library and activation;
no renderer: failure cooldowns, paused catch-up, a newer manual command
outranking a failed automatic switch, a rotation yielding to a waiting Apply), `WebPanelPlaylistTests` and offscreen
`ControlPanelPlaybackToolsTests` (drag and button sorting, keyboard focus,
stale-drag rejection, escaped history titles, clearing only the target display).
What each covers: [playlists](../features/playlists.md#verification).

## Preview

`WallpaperPreviewSessionTests` — hidden-load deferral, pause composition,
replacement and close generation guards, failure teardown, reload, readiness
timeout and pointer conversion, using injected surfaces.
`WallpaperPreviewRequestTests` — installed-path bounds, symlink escape, stale
manifests, resource checks, and copying unapplied values without changing bridge
state. `WebWallpaperPreviewSurfaceTests` use real offscreen WebKit for typed
properties, isolated temporary storage and mute. `ControlPanelPreviewTests` drive
the inspector action without opening a window, and `WallpaperPreviewLayoutTests`
check the 480-point content view in English, Chinese and Japanese, the window size
for 16:9, ultrawide, 4:3 and portrait displays on ordinary and tiny screens, and
the stage (shape, centring, bars and the surface following it) without an
`NSWindow`. Rust `wallpaper_preview` tests cover read-only draft export and Web
combo types. Not covered: native window presentation, how the stage looks in a
real window on a portrait or ultrawide display, scene or video first frames in
that window and OS visibility events.

## Steam

- `SteamCMDSetupTests` — against isolated preferences and directories,
  `URLProtocol` archives, the real system `tar` and owned child processes:
  publication and replacement, strict package manifests and both checksums, HTTP
  encoded versus decoded lengths, duplicate package paths, zip backslash
  normalization, execute permissions, traversal/link/archive-size boundaries,
  monotonic progress, network failures, signature-policy blocking, cancellation
  with no late writes, and retained blocked candidates surviving relaunch. An
  installation-to-downloader regression runs the published executable through the
  real PTY downloader and asserts imported manifest and media bytes.
- `SteamCMDRuntimeValidationTests` (Workshop folder) — arm64 only; Intel-only
  copies are rejected and need a native reinstall; Mach-O load commands and
  nested executable dependencies.
- `SteamCMDApprovalTests` use isolated fixtures: exact SHA-256 receipts, policy
  failure rejection, stale candidates, changed resources, private copies,
  quarantine scope and explicit discard. `SteamCMDReportedFailureTests` — which
  reported reasons count as credential rejection.

Not covered: whether Valve's current distribution passes this Mac's policy. The
opt-in `SteamCMDLiveInstallTests` check that with a temporary native package
install and a no-login smoke run (see [README.md](README.md#opt-in-layers)).

## Support

`SupportPromptStoreTests` — a downloaded wallpaper qualifies only after a
successful activation, a pending prompt survives relaunch and further downloads,
and a presented prompt never returns. `Support/` also holds the shared fixtures
(`TemporaryDefaults`, `TestAppLanguage`, bridge snapshots).

## SystemMedia

`AdapterSystemMediaProviderTests`, `SystemMediaTransportTests`,
`FallbackSystemMediaProviderTests`, `AppleScriptMediaProviderTests`,
`MediaArtworkTests`, `SceneMediaSinkTests` and `SystemMediaEventCodecTests` run
against fake streams, injected script results and a manual timer scheduler. They
cover fragmented messages and timeline
interpolation, consumer lifetime and late callbacks, unexpected exit without a
restart loop, the adapter-to-AppleScript fallback, artwork caching and
downscaling, the cleared cover reaching scenes before metadata, and the wire
format. Not covered: a real player or OS version publishing every field
([media integration](../features/media-integration.md#verification)).

## UserAssets

Behavior: [user files](../features/user-files.md).

`UserAssetStoreTests` — importing a file or directory property into managed
staging (extension filters, one-level directories, file-count limit, no second
copy of unchanged bytes), retained files surviving an unavailable source,
serialized preparation off the main thread with cancellation, authorization
rollback that cannot revoke a newer selection, and purge that keeps every asset
the manifest lists. `DirectoryWatcherTests` — a burst settles into one
notification. `UserAssetPreparationPerformanceTests` — synthetic directory
preparation and main-actor latency.

## WebWallpaper

`Tests/Unit/WebWallpaper/` runs real offscreen `WKWebView`s and injected hosts,
with no desktop window. It covers the page contract (`WebWallpaperPageTests`,
`WebWallpaperLocalRequestTests`, which also covers the file-request fixes in iframe,
`srcdoc` and script-created frames), property payloads and file staging
(`WebWallpaperPropertyPayloadTests`), the author API (`WebWallpaperAuthorAPITests`:
audio, media, random-file and directory listeners), audio delivery, output and
single-owner rules (`WebWallpaperAudioMediaTests`, `WebWallpaperAudioOutputTests`,
`WebWallpaperAudioOwnershipTests`), host lifecycle, crash budget and reload
recovery (`WebWallpaperHostLifecycleTests`, `WebWallpaperRecoveryTests`),
suspension by presentation and by pause, with the first-frame grace (counted only
while the view is in the window), edits drawn on a paused page, and a measured stop of
frames, timers and CSS (`WebWallpaperSuspensionTests`), the frame-rate limit
on `requestAnimationFrame` against a fake display cadence and in a real page with a
measured live change, and the rate a slow or full-refresh page draws at
(`WebWallpaperFramePacingTests`), a page rebuilt across a fast display's refresh with
its render scale, pause and limit (`WebWallpaperHostLifecycleTests`), the render scale on
`devicePixelRatio` with its resize event, start-of-document value and descriptor
following (`WebWallpaperRenderScaleTests`, plus the render-scale cases of
`WebWallpaperHostLifecycleTests`), pointer routing
(`WebWallpaperMouseRoutingTests`), pointer-move pacing and coalescing
(`WebWallpaperMoveThrottleTests`, and the interval a page asks for in
`WebWallpaperPageTests`), the opt-in Web Inspector switch
(`WebWallpaperInspectionTests`, plus the running and new page cases of
`WebWallpaperHostLifecycleTests`) and the screen-saver surface
(`ScreenSaverWebSurfaceTests`). Detail and limits:
[web wallpapers](../features/web-wallpapers.md#verification).

## Workshop

### Search and sources

- `WorkshopStoreTests` — pagination follows the displayed query until a draft is
  submitted; a failed page or submission retries its own query; superseded and
  racing requests cannot publish over a newer search; pages are Steam's own pages
  served from cache, capped at Steam's page limit, with the next page prefetched;
  the sidebar defaults match Wallpaper Engine's.
- `WorkshopTests` — query and tag encoding, sort mapping, the details request and
  its answers (served, withdrawn and other apps' items). The two `testLive…`
  cases fetch Steam's real pages and are opt-in
  (`WALLPAPER_MACHINE_NETWORK_TESTS=1`, see
  [README.md](README.md#opt-in-layers)); the page format stays covered offline
  through the real parser against fixture markup.
- `WorkshopSourceTests` (fixture protocol, nothing reaches the network) — Steam's
  session cookie read and never sent off Steam Community, author pages, a
  collection's order, collections marked on browse pages, the sidebar's rules on
  unfiltered pages, age-rating sampling of collections, every subscription page
  read with the session, a page whose entries cannot be read failing instead of
  passing for empty, and the store's back history, sign-in, ended session and
  sign-out. `WebPanelWorkshopSourceTests` (Panel) cover the panel's source
  actions, sign-in through an injected window and refusing to download a
  collection. Steam's real sign-in window is not covered.
- `WorkshopThumbnailCacheTests` — one download per URL under concurrent requests,
  disk hits across instances, no cache entry after a failed fetch, the concurrency
  cap, oldest-first pruning, still-frame extraction from animated previews
  (skipping a black fade-in), animations relayed on their own lane, a cache that
  keeps no animation writing stills only, and the source size limit. The scheme
  handler refuses ids it has not announced and answers library covers as small
  JPEGs only for images inside the library (`WebPanelAssetsTests`).
- `LibraryPreviewFetcherTests` — which files an Installed cover may be made from
  (inside the library, no symlink out, images only, size limit), a replaced
  preview getting a new cover, and the stamp in a cover's address changing with
  the preview's size or modification time only.

### Downloads

`DownloaderTestCase` is shared by `DownloadQueueTests`, `DownloaderLifecycleTests`,
`DownloaderSessionTests`, `DownloadTelemetryTests`, `SteamCMDRuntimeValidationTests`
and `WorkshopDownloadPersistenceTests`:

- Queue: private terminals per job; transfers side by side up to the slot limit
  once the first sign-in is accepted; serial order without a saved sign-in; a
  "logged in elsewhere" kick re-queuing the job and turning the queue serial; the
  ceiling changing mid-queue (raising starts waiting jobs, lowering never stops a
  running one); FIFO handoff after failure or cancel; shutdown never launching
  queued work. The ceiling is clamped to 1–6, persists across relaunch and
  reaches Swift from the Settings select as a number.
- Sign-in and ownership: per-job secrets, saved-sign-in handoff and relaunch
  without resubmitting secrets, account switching never restoring the previous
  account's credentials, stale credential rejections not erasing a newer session,
  ownership checks (owned, missing, unconfirmed, split output), and an anonymous
  account unable to start a download.
- Content: staging reclaim limited to directories nothing is writing to,
  partial content never published on cancel or incomplete download, scene-asset
  installation keeping only validated assets, pause and checkpoint recovery of
  content and queue order.
- `DownloadTelemetryTests` — download-speed sampling, including real `nettop`
  streaming (detail in [renderer.md](renderer.md)); `DownloaderLifecycleTests`
  report progress from disk growth against the listed size and stay
  indeterminate without one.
- `WorkshopDownloadIntentTests` — a download request retained across setup,
  account and shared-resource consent, surviving browsing and relaunch, removal
  preventing resumption, and explicit consent including reinstall. Reinstall from
  Workshop is covered for an id that is not a Workshop number (Steam is not asked),
  an item Steam no longer serves (the installed folder untouched), an Application,
  the current version queued through the ordinary queue, and a repeat while a
  download runs or waits for setup doing nothing.
- `WorkshopApplyOnArrivalTests` — Download and apply with the two-display test
  bridge and `finishInstall` standing in for the arrival: the wallpaper applied once
  and only on the asked display; the person's own choice for that display, made
  before or while the apply waits its turn, withdrawing it with a note, while a
  playlist change or a choice for the other display does not; two asks for one
  display, where the later one is applied whichever wallpaper arrives first and
  asks for different displays leave each other alone; copying to, swapping or
  applying a layout naming the display withdrawing it, while a copy from it or a
  layout for the other display does not; the hour; a failed
  apply or a display that went away leaving the display alone and saying why; a
  failed library rescan; an Application, a collection or an unusable display
  getting a plain download; a scene waiting for its shared assets and being
  dropped with a note when their job ends without them; cancel and dismiss; a
  failed download; and a relaunch restoring the downloads but not the choice.
  `WorkshopDownloadAndApplyPanelTests` covers what the panel accepts, and
  `ControlPanelDiscoverTests` where the inspector offers the button and what it
  says. Not covered: a real download followed by the apply (needs a Steam
  sign-in and a display), and the assets job's completion calling the same
  settle step (needs a finished SteamCMD job).

### Updates

`WorkshopUpdateStoreTests` — what counts as outdated, recorded downloads and
imports against `project.json` dates, non-Workshop ids never sent, results kept
across a relaunch, a download making an item current, the daily limit and its
switch, a failed check keeping what was known, and forgetting deleted items;
`WebPanelWorkshopUpdateTests` — only an outdated wallpaper is marked and can be
updated, and a reinstall needs an installed wallpaper and the user's yes before
Steam is asked; `ImportTests` covers the swap that replaces an installed tree,
including a copy missing its entry file or with a manifest that does not parse,
and a folder whose `project.json` is a link left alone;
`ControlPanelLibraryTests` covers where the inspector and the Compatibility check
offer Reinstall from Workshop. Not covered: the reload of a wallpaper on screen
after its update or reinstall (needs a renderer), and a real reinstall (needs a
Steam sign-in).

## What native tests do not establish

macOS acceptance and restoration of native wallpaper selections, live GitHub
release install and Applications replacement, how Finder draws the disk-image
window, Steam CDN throughput, live-account session reuse, Mission Control cache
refresh, real audio capture and any visual timing. Those stay on
[manual-smoke.md](manual-smoke.md).
