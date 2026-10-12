# Crash recovery: wallpapers held back after repeated crashes

The saved configuration is replayed at every launch. A wallpaper whose scene kills the
process while it loads (a renderer fault, an out-of-memory kill, a bad driver state)
would kill the next launch the same way, and the one after it, so the app could never
start again without the user editing files. The **load journal** breaks that loop. A
wallpaper that was being opened when the app died twice in a row is **held back**: the
app starts without it, says so, and opens it again when the user applies it.
Nothing is deleted, moved or disabled, and the assignment stays in the configuration.

The journal is Rust, in the bridge crate (`engine/load_journal.rs`). The Swift side only
names the build (`ClientPaths.buildStamp`).

## What the user sees

- After the second crash in a row while one wallpaper loads, the next launch starts
  normally and leaves that wallpaper's display without a live scene. The control panel
  shows a **banner** under the top bar, one row per held wallpaper, with a sentence
  naming it (`"<title>" was not restored: WallpaperMachine quit unexpectedly twice in a
  row while loading it. Nothing was deleted.`) and a **Try again** button. The menu-bar
  menu carries a disabled line, **A wallpaper was held back after a crash**, so a login
  launch with the panel closed still shows the state. Both come from
  `BridgeAppSnapshot.held_wallpaper_ids` and are localized in the app and panel catalogs.
- **Try again** opens that wallpaper on its display(s) and lifts the hold. If the engine
  refuses, the panel's error banner shows the reason and the banner row stays: a retry
  that opened nothing is not a release.
- **Apply** in the inspector, or choosing the wallpaper again from the library, also opens it
  again, even when nothing in its draft changed, and clears the hold and the banner. Only the
  user's own choice does, which is what `BridgeStore` calls `userInitiated` (a Shortcuts or
  URL command that names the wallpaper counts as one, and so does the options dialog's OK). A
  playlist rotation, an automatic rule or a Space or Focus rule that comes round to the
  wallpaper leaves the hold and the strike count alone, so the rotation cannot reopen the
  wallpaper that crashed the app each time it reaches it: that display stays empty and the
  banner says why. Apply is as careful as Try again: if the engine refuses, the wallpaper
  stays held, and if the app dies while it loads, the next launch holds it again.
- A hold on a wallpaper that no display is assigned to is kept but not shown; the banner
  returns if the wallpaper is assigned again.
- Installing an app update releases every hold, because the code that crashed is gone.
- Other wallpapers on other displays load as usual.

What a held wallpaper's display shows in the meantime is decided by the desktop picture
code, not by the journal; see [desktop-picture.md](desktop-picture.md). The journal only
keeps the scene from opening. The lock screen is built from the same plan, so a held
wallpaper is not exported to it either until it is applied again.

## What is recorded, and when

`LoadJournal` keeps `<support>/load-journal.json` (`<support>` is the folder that holds
`config.toml`). It is written only when something can go wrong:

1. **Before a load.** `reconcile_with` (`actor/bridge.rs`) builds the scenes it is about
   to hand to the engine, asks which of them will actually open or replace a scene
   (`displays_awaiting_first_frame`, the same test the first-frame wait uses, judged
   against the engine's live display snapshot), and records those `(wallpaper, display)`
   pairs. A scene that is already running is not a suspect, and a reconcile that opens
   nothing, such as a display refresh or `presentation_unloaded`, writes nothing. A mirror's scene
   belongs to its source's wallpaper (`ActivationInputs::build_owned`).
2. **After the first frame.** When the reconcile finishes, including the audio, mute and
   render-scale calls that follow the scene (the changelog records a launch crash after
   applying a render scale, a call made on a scene that is already open), the entries are
   marked settled and stay for a
   **settle window** of 20 seconds. A crash just after a load is still attributed to
   the wallpaper.
3. **When the window ends.** The entries and the wallpaper's strikes are cleared. This is
   the only way strikes are cleared by success.

**Closing the record on a quit.** `WallpaperBridge::shutdown` closes the journal itself
(`LoadJournal::clean_shutdown`) before it asks the actor to shut down; the actor's `Shutdown`
handler does so too. It has to be outside the actor: the actor handles one message at a time,
and `Bootstrap`, a display refresh and the other reconciles hold it until the scenes they
opened show a first frame. A quit that waited its turn would leave the record open for the
whole load, which for a heavy scene is longer than a logout or a quit's own deadlines allow,
and the next launch would count a strike against a wallpaper that was fine. Closing also
latches the journal: a scene that starts opening after the quit began (something queued
behind it) is not recorded, and the `succeed` of the load that was cut short does nothing.

A reconcile that fails, returns early or panics drops its record without a strike: the
process is alive and the failure was reported. Quitting on purpose clears the record too
(`Shutdown` calls `clean_shutdown`), so quitting during a load is not a crash. The `quit:`
log line says who asked for the quit and how long each stage took, so a quit that was cut short
by a logout or a kill can be told apart from one the user chose; see
[diagnostics.md](diagnostics.md#why-the-app-quit).

## Strikes and the hold

At launch `LoadJournal::open` reads the file. Entries left by a different session mean
that session died mid-load, so each wallpaper in them earns **one strike** (one per
wallpaper, however many displays it was opening on). At **two consecutive strikes**
(`HOLD_AFTER_STRIKES`) the wallpaper is held.

| State | Meaning | Leaves it |
|---|---|---|
| Clear | no strikes | |
| Suspect (1) | the previous session died while opening it | a load that survives the settle window clears it; a second death holds it |
| Held (2 or more) | not opened by any plan | the user applying it again (Apply, Try again), an app update, the wallpaper being removed from the library |

A hold is applied in `ActivationInputs`: `slots()` skips held wallpaper ids, so the scene,
web and native-video plans, the backend report and the lock-screen export all agree.
`Bootstrap` reads the held set after the library scan, drops strikes for wallpapers that
are no longer installed (`prune`, only after a successful scan) and keeps the set in
`BridgeActorState::held_wallpapers`. `BridgeAppSnapshot.held_wallpaper_ids` is that set
restricted to wallpapers a display is assigned to, sorted; it is state for the panel to
word, not an entry in `errors`.

There are two ways back. `ApplyWallpaperOptions` takes the id out of the held set when it
carries `user_initiated` (`BridgeStore` passes its `userInitiated` flag through
`WallpaperBridge.apply_wallpaper_options`), so that the reconcile plans the wallpaper, and
when that lifts a hold it also forces the reconcile that an unchanged draft would otherwise
skip. It calls `forgive` only once that reconcile has succeeded; a reconcile that fails puts
the id back into the held set (`ReconcileFailed.restore_hold`, before the repair that follows
a failed reconcile plans from the set). An apply that reconciles nothing has no load to wait
for and calls `forgive` at once, which is how the user choosing a suspect (one strike)
again starts its count over. An apply without the flag never calls `forgive`: it neither lifts
a hold nor starts a strike count over.
`ReleaseHeldWallpaper` (`WallpaperBridge.release_held_wallpaper`, **Try again**) takes the
id out of the held set, reconciles the configuration and only then calls `forgive`. The
order matters for both: if the reconcile fails the id goes back into the set and the journal
still holds its strikes, and if the process dies during the attempt the next launch counts a
third strike and holds the wallpaper again, where forgiving first would have made the crash
a first offence, opened at startup and crashing the app again before the user could do
anything. A release for a wallpaper that is not held changes nothing and does not touch the
engine.

## Limits

- A force quit, a `kill -9`, a power loss or a logout kill during a load or its settle
  window looks like a crash and counts one strike. Two in a row hold the wallpaper,
  which is why one is not enough. Releasing is one Apply or one Try again.
- A launch that opens several displays at once makes every wallpaper still opening a
  suspect; the journal cannot tell which one killed the process.
- A crash later than the settle window is not attributed to a load.
- Whether the run before a launch really crashed is a separate record. The session
  ledger logs `previous session: …` at every launch, so a strike that comes with
  `ended by a restart, shutdown or power loss` is not necessarily the wallpaper's doing; see
  [diagnostics.md](diagnostics.md#how-the-previous-session-ended).
- Isolated support roots (`WALLPAPER_MACHINE_HOME`, tests) have their own journal,
  because it lives beside `config.toml`.
- The journal is not in the Settings backup package. It is in the diagnostics report (see
  below).
- A file that cannot be parsed, or has an unknown version, is renamed to
  `load-journal.json.corrupt` and the journal starts empty. If it cannot be written the
  load goes ahead; the journal never blocks one.

## The file

```json
{
  "version": 1,
  "build": "1.3.2 (45)",
  "session": "9f3a6c0d2b81e475",
  "strikes": { "3177024520": { "count": 1, "last_at": 1791800000, "display": 7 } },
  "in_flight": [
    { "wallpaper": "3470764447", "display": 8, "started_at": 1791800100, "settled_until": 1791800120 }
  ]
}
```

`build` is `WALLPAPER_MACHINE_BUILD`, which the host sets from the bundle version and
build number; without it (tests, tools) the bridge crate version is used. A file written
by another build is discarded whole, strikes and in-flight entries alike. `session`
identifies the process that wrote the file. Times are Unix seconds. Writes go through a
temporary file and a rename and are not synced: the file has to survive the process
dying, which the page cache does, not a power cut.

## In the diagnostics report

**Export…** under Settings → Storage → Troubleshooting → Diagnostics report puts a copy of
`load-journal.json` at the root of the zip (`DiagnosticsBundle.collectLoadJournal`,
see [diagnostics.md](diagnostics.md#diagnostics-report)), so a bug report about a held
wallpaper carries the strike history. It goes through the same redaction as the logs
(the file holds no paths today, so this only guards later fields) and `README.txt` lists
it. A missing file is a note under "Not included" (`load-journal.json was not present`),
not a failure: the file is written only once a scene has been opened. One that exists but
cannot be read is noted as not readable. The crash report of the run that died is picked
up by the existing `crash-reports/*.ips` rule, and the `load journal:` lines in the
exported logs name the same wallpaper ids.

## Logging

The session log (see [diagnostics.md](diagnostics.md)) carries:

- `WARN load journal: previous session died while opening <id> (display N); strike k/2`
- `WARN load journal: holding <id>` at every launch while it is held
- `INFO load journal: released <id> (by the user)` for Apply and Try again, and `released N held wallpaper(s) after update`
- `WARN load journal: set aside an unusable journal ...` and `could not write ...`
- `DEBUG` lines when a load is recorded and when it settles

## Verification

Device-free, against the fake engine and a temporary support root:

- `engine::load_journal::tests` in the bridge crate: one strike per dead session and per
  wallpaper, the hold at two and its persistence, the settle window (long and short),
  dropped and succeeded tickets, clean shutdown (also from another thread, and nothing
  recorded after it), a new build, forgive, a corrupt file,
  an empty load never touching the disk, and pruning.
- `tests::crash_loop_guard`: bootstrap leaves a held wallpaper out and lists it in the
  snapshot (sorted, only while a display is assigned to it), Apply and
  `release_held_wallpaper` bring it back and release the hold, a release of a wallpaper that
  is not held or whose reconcile fails changes nothing, an Apply whose reconcile fails leaves
  it held (and the repair after the failure plans without it), a crash while an Apply is
  loading it counts a third strike at the next launch, later reconciles keep skipping it,
  an apply that is not the user's (a rotation coming back to a held wallpaper) leaves the hold
  and a strike count alone while the user's apply releases and resets them,
  the record is on disk while a load runs and through its settle window, a quit that arrives
  while startup still holds the actor (or a load that begins after the quit) leaves no
  strike, only scenes that
  really open are recorded, quitting and failing loads leave no strike.
- `DiagnosticsBundleTests`: the journal is exported at the zip root, redacted and listed
  in `README.txt`, its strike history survives redaction, and a missing or unreadable
  journal is noted while the rest of the report is still exported.
- `ControlPanelHeldWallpaperTests` (hosted, windowless web view): the panel snapshot names
  each held wallpaper with the localized sentence, `releaseHeld` reaches the bridge once for
  a held wallpaper and rejects an installed one that is not held, the banner lists the rows
  and its button posts the action, and a refused retry keeps the row and shows the error.
- `tests::activation_plan`: a held wallpaper gets no scene, web or native-video
  descriptor; `build_owned` names the owner of every scene, mirrors included.

Not verifiable headlessly: a real engine crash while a scene loads, and how the banner and
the menu line look in the real panel and status menu. The fake engine cannot take the
process down, so the crash is played by a record that never ends. The check on a desktop is
to kill the app with `SIGSEGV` during a restore twice, relaunch, confirm the banner and the
menu line, then press **Try again** and confirm the wallpaper loads; that needs an
explicitly authorized run.
