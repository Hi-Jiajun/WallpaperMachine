# Logs and diagnostics reports

How the app records what happened, and how a user hands that record to us with a
bug report. The runtime diagnostics counters used for power claims are separate;
see [power-benchmark.md](../testing/power-benchmark.md#runtime-counters).

## The application log

One log for the whole process. Swift (`App/Logging/AppLog.swift`), the Rust bridge
and core, and the C++ renderer all write into the bridge's `ApplicationLogger`
(`upstream/renderer/crates/bridge/src/logging.rs`). Files live under
`<app support>/Logs/<session>/<N>.log`. Each launch is one session, named by its
start time (`20260927-150211`, `-1`, `-2`… for same-second launches).

Every line has the same shape:

```
2026-09-27T15:02:11.482+08:00 ERROR [load#7] WPSceneParser.cpp:1061 unknown tex "x"
```

- **Time**: local time with its UTC offset and milliseconds. Users report what
  their clock said, and crash reports carry their own offset. Swift lines keep
  the time they were logged, even when they were held until the bridge opened
  the log.
- **Level**, then **`[load#N]`** when the line belongs to a wallpaper load, then
  the source file and line.

### Wallpaper loads

Every wallpaper load gets a process-unique number. The load's first line is a
header:

```
… INFO [load#7] backend.rs:93 scene load: display 1 3456x2234 @2x 120Hz, fps 60, scaling fit x1, render native, paused false; project title="Rain" type="scene" version=3 workshop=123456 file="scene.json" at …/123456/project.json
… INFO [load#7] SceneWallpaper.cpp:1540 scene backend: legacy_vulkan; fell back: …
```

- **Scene and video wallpapers on the scene engine**: the header is written by
  `OweBackend::open_scene`, the single place every open or rebuild passes
  through. The renderer's `main` and `render` threads for that scene adopt the
  number when they start (`owe_scene_wallpaper_set_log_scope`). So a parser
  error, the backend choice and the first frame all carry it, even while
  another display is loading at the same time.
- **Web wallpapers and native video**: the Swift hosts start their own loads
  through `AppLog.beginLoad`, and their later lines pass `load:`.
- **Not tagged**: the renderer's frame timer thread and its shared
  decoder/audio threads carry no load number. Match those lines by time.

The `project.json` summary is read leniently: a field of an unexpected type is
left out, and an unreadable manifest is logged as such rather than failing
the load.

### What each session starts with

- The logger's own line: process id and level in force.
- The saved preferences that decide how wallpapers render: scene renderer, video
  backend, render scale, battery mode, frame-rate limit, scene optimisation,
  on-demand updating and the experimental switches.
- `environment:` lines from Swift (`DiagnosticEnvironment`): app version and
  build, macOS, hardware model, CPU, core count, memory, GPU, low-power and
  thermal state, languages, locale, time zone, and each display's pixel size,
  scale, refresh rate and name.
- Startup milestones (`startup: …`).

Each time the quality settings are applied (a battery-mode, frame-rate-limit or
battery-profile change, or a power-source change in reduced-quality mode), the
frame-rate ceiling and render scale in force are logged.

### Levels and detailed logging

The default level is `info`. **Settings → Storage → Troubleshooting → Detailed
logging** adds `debug` lines. It takes effect immediately, is saved as
`diagnostics.verbose_logging` in `config.toml`, and stays on across relaunches
until turned off, so a problem that appears at launch is still captured. Every
change of level is logged. `WALLPAPER_ENGINE_LOG_LEVEL` (`error`, `warn`, `info`,
`debug`, `trace`, `off`) overrides both the default and the setting for the
process. The level applies to Swift lines too. The workshop download lines that
[Show download logs](workshop-downloads.md) depends on are therefore `info`.

### Retention

- A file rotates at 5 MB. A session keeps its newest 10 files.
- At launch, the newest 9 earlier sessions are kept as long as together they
  fit in 100 MB; every older session is removed.
- **Clear…** on the Logs row in Settings → Storage removes every session except a fresh one.

### Before the log opens

`AppLog` is callable from any thread and never hops to the main actor, so a
stalled main thread does not also silence the lines that would explain it.
Lines logged before the bridge exists are held, up to 1000, and written when it
attaches, together with a count of any that were dropped. If the bridge fails to
start, the held lines and every later one go to stderr.

The lock-screen extension is a separate sandboxed process. It keeps its own
bounded `extension.log`; see [lock-screen.md](lock-screen.md).

## Diagnostics report

**Settings → Storage → Troubleshooting → Diagnostics report → Export…** writes one
`WallpaperMachine-diagnostics-<date>-<time>.zip`, by default to the Desktop, and
reveals it in Finder. It is built off the main actor by `DiagnosticsBundle`
(`App/Services/Diagnostics/`):

| Entry | Contents |
|---|---|
| `logs/<session>/<N>.log` | Newest 5 sessions, newest files first, at most 64 MB in total. A file that would exceed the budget contributes its tail, marked `[truncated: …]` |
| `lock-screen/extension.log` | The extension's log, if present |
| `load-journal.json` | The crash-loop guard's journal, [crash-recovery.md](crash-recovery.md): the strikes per wallpaper and the scenes that were opening when the app last stopped. Wallpaper ids, display numbers, times, the build and an opaque session id; no paths. The file exists once a scene has been opened; without it the report notes that it was not present |
| `crash-reports/*.ips` | Up to 5 macOS crash reports from the last 14 days whose name starts with `WallpaperMachine` (app and extension) |
| `diagnostic-reports/*.diag`, `*.spin`, `*.hang` | Up to 5 macOS resource, spin and hang reports from the last 14 days whose name starts with `WallpaperMachine`, newest first across both report folders. See [below](#macos-resource-spin-and-hang-reports) |
| `environment.txt` | The environment lines above, read at export time, plus the saved renderer preferences and the backend each running scene actually uses |
| `README.txt` | What is included, what was missing or skipped, and what was redacted |

Everything except `README.txt` passes through `DiagnosticsRedactor` first:

| Replaced | With |
|---|---|
| The home folder path, including its `/private` and `/System/Volumes/Data` forms | `~` |
| The macOS short and full user name | `<user>` |
| The saved Steam account name, and the name in SteamCMD's `Logging in user '…'` | `<account>` |
| Values of authorization, cookie, password, secret, session id, Steam Guard, token and similar keys, in `key=value`, `key: value` and JSON forms | `<redacted>` |
| The value of the `Beta Identifier:` line of a macOS resource report, a GUID that is the same in every report from this install | `<redacted>` |
| The Mac's host name in the file name of a macOS resource report | Dropped from the name stored in the zip |

Names are replaced only as whole tokens. Wallpaper titles, Workshop IDs and file
names inside the library are kept: those are what reproduce the problem.

### macOS resource, spin and hang reports

A crash report exists only for a process that crashed. macOS also writes a report
when the app writes too much to disk, burns too much CPU, or stops responding, and
those name the code that was running. On macOS 27 they are not in the user's
`~/Library/Logs/DiagnosticReports` but in `/Library/Logs/DiagnosticReports`, as
`<process>_<date>_<host name>.diag` (`.cpu_resource.diag` for CPU). Spin and hang
reports use `.spin` and `.hang`. That folder is `root:_analyticsusers`, mode
`rw-rw----`, so it is listable only by an account in the `_analyticsusers` group.
Older macOS releases wrote them to the user folder, so the export looks in both.

- **Which files**: regular files directly in either folder (so `Retired/` is
  skipped) whose name starts with `WallpaperMachine`, which also matches
  `WallpaperMachineExtension`, with one of those three extensions, modified inside
  the last 14 days and not in the future. The same window as crash reports. `.ips`
  files stay under `crash-reports/` and are read from the user folder only.
- **How many**: the 5 newest across both folders. A report over 4 MiB contributes
  its tail, marked `[truncated: …]`. Real ones are 20 to 30 KB.
- **Classified by name, never by content.** The body differs between macOS releases,
  so it is redacted and copied, not parsed.
- **Stored name**: the host name is dropped (`WallpaperMachine_2026-10-10-193707.diag`),
  because a Mac's host name is usually its owner's name and the redactor only knows
  the account's names. Two reports that end up with the same name get a `-2`.
- **Not readable**: if the system folder cannot be listed, the export still succeeds
  and README.txt says `macOS resource reports were not readable (the account may not
  be in the _analyticsusers group)`. Reports from the user folder are still included.
  If both folders are readable and empty, it says there were none in the last 14 days.
- **Left out on purpose**: jetsam (memory-pressure) events. They list the other
  processes that were running, which a bug report should not carry.

Bug reports on GitHub use the issue form in
`.github/ISSUE_TEMPLATE/bug_report.yml`. It asks for the Workshop ID and the
exported report, and points to Detailed logging for problems that are hard to
reproduce.

## Verification

- Rust:
  - `logging::tests` (`upstream/renderer/crates/bridge/src/logging.rs`): line format, load tag, session and
    file retention.
  - `log_context::tests` (`upstream/renderer/crates/core/src/log_context.rs`): scope nesting, project summary.
  - `settings_intents::verbose_logging_persists_across_relaunch_and_can_be_turned_off`.
- Swift: `AppLogRouterTests`, `DiagnosticsRedactorTests`, `DiagnosticsBundleTests`.
- Not established by tests:
  - that a real scene's renderer lines carry its number on the desktop;
  - the unreadable-folder note on a Mac whose account is not in `_analyticsusers`
    (the test uses a path that cannot be listed);
  - spin and hang reports from a real hang: the fixtures are named after the
    `.diag` reports macOS wrote on this machine, and no `.spin` or `.hang` file was
    available to check the naming against;
  - the Save panel;
  - Finder reveal.
