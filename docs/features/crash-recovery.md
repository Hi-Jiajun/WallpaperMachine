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
  normally, leaves that wallpaper's display without a live scene and reports, in the
  same error line the control panel already shows for startup problems:
  `<title> was not restored because WallpaperMachine quit unexpectedly twice while
  loading it. Apply it again to retry.` The sentence is English only for now; it is
  not in the string catalogs.
- **Apply** in the inspector opens the wallpaper again, even when nothing in its draft
  changed, and clears the hold and the notice.
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
(`Shutdown` calls `clean_shutdown`), so quitting during a load is not a crash.

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
are no longer installed (`prune`, only after a successful scan), keeps the set in
`BridgeActorState::held_wallpapers` and reports each held wallpaper that is assigned to a
display. `ApplyWallpaperOptions` calls `forgive` first; when that releases a hold it also
forces the reconcile that an unchanged draft would otherwise skip.

## Limits

- A force quit, a `kill -9`, a power loss or a logout kill during a load or its settle
  window looks like a crash and counts one strike. Two in a row hold the wallpaper,
  which is why one is not enough. Releasing is one Apply.
- A launch that opens several displays at once makes every wallpaper still opening a
  suspect; the journal cannot tell which one killed the process.
- A crash later than the settle window is not attributed to a load.
- Isolated support roots (`WALLPAPER_MACHINE_HOME`, tests) have their own journal,
  because it lives beside `config.toml`.
- The journal is not in the Settings backup package and is not part of the diagnostics
  report yet.
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

## Logging

The session log (see [diagnostics.md](diagnostics.md)) carries:

- `WARN load journal: previous session died while opening <id> (display N); strike k/2`
- `WARN load journal: holding <id>` at every launch while it is held
- `INFO load journal: released <id> (apply)` and `released N held wallpaper(s) after update`
- `WARN load journal: set aside an unusable journal ...` and `could not write ...`
- `DEBUG` lines when a load is recorded and when it settles

## Verification

Device-free, against the fake engine and a temporary support root:

- `engine::load_journal::tests` in the bridge crate: one strike per dead session and per
  wallpaper, the hold at two and its persistence, the settle window (long and short),
  dropped and succeeded tickets, clean shutdown (also from another thread, and nothing
  recorded after it), a new build, forgive, a corrupt file,
  an empty load never touching the disk, and pruning.
- `tests::crash_loop_guard`: bootstrap leaves a held wallpaper out and names it, Apply
  brings it back and releases the hold, later reconciles keep skipping it, the record is
  on disk while a load runs and through its settle window, only scenes that really open are
  recorded, quitting and failing loads leave no strike.
- `tests::activation_plan`: a held wallpaper gets no scene, web or native-video
  descriptor; `build_owned` names the owner of every scene, mirrors included.

Not verifiable headlessly: a real engine crash while a scene loads. The fake engine
cannot take the process down, so the crash is played by a record that never ends. The
check on a desktop is to kill the app with `SIGSEGV` during a restore twice, relaunch
and confirm the wallpaper is held, then apply it from the panel and confirm it loads;
that needs an explicitly authorized run.
