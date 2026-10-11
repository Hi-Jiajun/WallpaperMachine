# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. When it grows past that,
move the oldest entries verbatim into
[archive/verification-log-2026-09.md](archive/verification-log-2026-09.md)
(or a new dated archive file) first, and promote anything durable before it
goes. Trimming is allowed; editing an entry's recorded result is not.

## 2026-10-11 — Aligned layers turn about their anchor

SceneRuntimeContext rotated a non-centre layer about its centre and slid its anchor offset along the scene's axes. Every gate below ran in a detached worktree at HEAD plus this change only, because another session's uncommitted audio edits in the shared tree stop audio_tests from compiling (SmoothAudioResponseBinsForTesting undeclared).

- `script_runtime_compat_test`: 97 passed; the new `RotatedAnchoredLayerTurnsAboutItsAnchor` and `ScriptedRingBarsHangOutwardFromTheirCircle` fail on HEAD's runtime (rotation assertions only). `scene_schema_tests` 110, `scenescript_media_event_smoke` 20, `text_object_runtime_test` 64 passed, 2 skipped (local assets).
- `metal_scene_draw_smoke` LocalProjects, 2850003448 at 2560x1440, 60 Hz noise (amplitude 0.5 for legible bars): before, the ring slid down over the planet; after, bars hang outward from a dark ring, as in the Workshop preview.
- Local corpus A/B, 57 scenes, `offscreen_scene_probe` `nodes.txt`, both arms built from HEAD: placement moves only on rotated non-centre layers in 6 scenes. 3276911872's audio strip now rests on the date line, flush with its left edge; 3665954520's hidden visualizer bar now spans its sibling bars' 150 units from their shared corner; three text layers tilted 0.6-2.2 degrees move up to 4.4 units. 3589454154's node diffs, and every pixel/state diff, also appear between two baseline runs.
- `python3 scripts/check_renderer.py`: exit 0; 12/12 generated scenes pixel-equal pooled vs isolated; reload cycles 0. Skipped: 2 local-asset text tests, local video import, local-project Metal (run by hand above).
- `python3 scripts/test.py`: Python suites OK; native 1334 passed, 0 failed, 14 skipped of 1348.
- Gap: Wallpaper Engine's offset for a script-set alignment (full size*scale vs this renderer's scale delta) is unconfirmed; 8-unit bars differ by 4 units, too little for a preview. Not rebuilt as a Release app.

## 2026-10-10 — Lock state and scene-assets folder no longer probed per update

Cached the session lock state in WallpaperPresentationPolicy (asked at start, lock/unlock, display wake, user switch and while locked) and resolved the scene-assets folder with its readiness in WorkshopStore instead of in every page snapshot.

- `python3 scripts/test.py --only WallpaperPresentationPolicyTests --only WorkshopDownloadIntentTests --only ControlPanelSnapshotDeliveryTests --only ControlPanelShellTests` — 71 passed, including 6 new tests
- `python3 scripts/test.py` on the shared tree with the lock-screen re-sync change (artifacts/tests/Tests-20261010-134554-494250) — 1334 passed, 0 failed, 14 skipped
- `python3 scripts/build.py --swift-only --configuration Release` at 51e1d39 — OK; relaunched by the user
- Standalone loop: `CGSessionCopyCurrentDictionary` 52 µs median (84 µs p95), `ClientPaths.assetsURL` 124 µs, cached URL 0.3 µs
- Live, 30 vs 18 user-approved Bar Count drags in 40 s windows: page-snapshot samples in `assetsURL` 50 of 141 → 0 of 71; policy lock read 1 → 0; coalition energy within noise
- Driving the drags in the background activated the app per drag, so the on-key assets refresh took 15 samples; not representative of drags in the focused panel
- Not exercised live: a real screen lock, display wake with a lock, or fast user switching (unit tests only)
- `scripts/check_renderer.py` — not run: no renderer or bridge change

## 2026-10-10 — Lock-screen check skips unchanged store re-syncs

Release 1.3.2 (31) at HEAD bd55717, M5 Pro, macOS 27.0.1, AC power; animated lock screen and screen saver on one display with 45 Spaces (93 journal entries). Every two-second check and every snapshot apply re-synced the native selection.

- Before, live: `stat` of `native-selection.plist` 2 s apart showed a new inode each check; per-second coalition sampler (`ri_energy_nj`) idle ticks 12–16 ms app CPU and 4–6 mJ every 2 s; `sample <pid> 2` ×3: 8–12 of 10–14 on-CPU main-thread samples in `LockScreenWallpaperSelection.synchronize`, 2–3 in `persistEntries`
- Cause: re-encoding journaled baselines (global override, inherited and linked originals) reorders dictionary keys, so equal entries compared unequal and the journal was rewritten; the store was reread and every entry decoded each time
- `Index.plist` unchanged for over 15 min while idle (`stat` every 5 s), so an unchanged check now costs one `stat`
- Scratch `swiftc -O` benchmark, HEAD vs change, on copies of the real store and journal, 200 syncs ×2: unchanged store 2.9–3.6 ms → 1.6–2.6 µs per sync, journal writes 139–200 → 0; store rewritten with only an unrelated key 2.6–3.1 ms → 2.3–2.5 ms, writes 101–200 → 0
- New journal test's fixture replayed in scratch: HEAD rewrote the journal in 30/30 runs, change in 0/30
- `python3 scripts/test.py --only LockScreenWallpaperTests --only LockScreenWallpaperServiceTests` — 91 passed
- `python3 scripts/test.py` — 1334 passed, 0 failed, 14 skipped (shared tree with the concurrent session-lock and asset-path change)
- Not run: live after-measurement, which needs the rebuilt app relaunched; no desktop, wallpaper or lock-screen change was made

## 2026-10-10 — Screen changes that move nothing no longer refresh displays

Cause of the ~12 J bursts: on the built-in XDR display (M5 Pro, macOS 27.0.1) every EDR headroom ramp (1.0↔1.2 over 2 s, raised by a menu-bar banner or HDR content) posts 241 didChangeScreenParameters notifications with only maximumExtendedDynamicRangeColorComponentValue changed. A passive watcher saw 5,995 such notifications in 30 min and no frame, visibleFrame, scale or Space-driven change. Fix b3d3921 compares DisplayConfiguration (AppKit's copy of what DisplayDesc::all() reads, 11 µs per read) before refreshing; the Space monitor and presentation policy filter the same notification.

- `python3 scripts/test.py` — exit 0; 1340 tests: 1326 passed, 14 skipped (targeted: DisplayRefreshCoalescerTests, WallpaperSpaceMonitorTests, WallpaperPresentationPolicyTests, ControlPanelSpaceWallpaperTests — 38 passed)
- `python3 scripts/build.py --swift-only --configuration Release` — built; relaunched with the user's permission
- Before, per-second coalition energy (ri_energy_nj): one ramp with Settings open 0.6 + 6.5 + 5.2 J (app 3.3 W, WebContent 3.2 W); ten ramps with the panel closed 0.2–2.6 W and 300–650 ms CPU/s for 2–4 s
- Before, `sample` during a ramp: main thread 580 on-CPU samples (lock-screen re-sync 379, page snapshot 90, refresh 33) plus 233 blocked in CGSessionCopyCurrentDictionary; WebKit logged 252 snapshot pushes per ramp
- After, three ramps with the panel open: app 56–74 ms CPU/s against a 71 ms/s quiet median, panel WebContent no rise; one display refresh, the first after launch
- Not measured: WindowServer energy (proc_pid_rusage is denied without root); no external display, display wake or resolution change exercised live (covered by unit tests only)

## 2026-10-10 — Metal shader compile across launches (investigation, docs only)

Why MTLCompilerService recompiled Lucy (3521337568) after a launch despite warm shader and Vulkan pipeline caches. No app, renderer or upstream change; app not rebuilt; no desktop control or wallpaper change.

- Built `offscreen_scene_probe` and `metal_scene_draw_smoke` with `scripts/build.py`'s environment; per-process CPU energy from `proc_pid_rusage` (`ri_energy_nj`) of the probe and each `MTLCompilerService` it started.
- Same location, separate processes: first load 35.4–41.5 J, every later process 2.0–2.2 J with no compiler activity. New `LC_UUID`, new `CFBundleVersion`, bundle replaced in place: 2.0–2.1 J.
- Same bundle id at another path: 21.7 J (19.5 J compiler). Cold compiled source only: 21.8–22.1 J; cold pipelines only: 4.1 J. Two rounds each.
- No eviction or loss: 16 other wallpapers, a concurrent holder, a SIGKILLed holder, 3,400 entries (~45 MB) in one process.
- App logs: every warm-cache compile gap (Winter 10:57, Lucy 11:17, Lofi Girl 12:14) was the Release build's first load of a wallpaper last loaded by `/Applications/WallpaperMachine.app`; same-copy repeats hit.
- Native Metal admits Lucy and Lofi Girl, not Yae Miko (lighting) or Winter Nothingness (translation failure); MoltenVK 1.4.2 has no binary-archive option. Findings in features/performance.md, renderer.md and power-benchmark.md; links checked.

## 2026-10-10 — Energy readout: static loading notice replaces switch detection

- Change: the loading flag (switch detection, hidden grade and comparison) is removed; the Energy use row now always notes that right after a wallpaper is applied the figures include loading it. Per-wallpaper ratings still start no interval within 8 s of a presentation change.
- Why: the user saw the flag miss a second apply. The readout samples only while Settings is open, so a switch made from another page, or a re-apply of the same wallpaper, was never seen.
- Tests: targeted EnergyUsageMonitorTests, WallpaperEnergyRatingsTests, WebPanelEnergyUsageTests (24 passed); test_panel_localization OK; node --check WebUI/settings.js.
- Full gate: python3 scripts/test.py — 1320 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Not verified: the note in the running panel (no screenshot taken).

## 2026-10-10 — Energy readout: wallpaper loading flagged, measured switch cost

- Change: readings whose window holds a sample within 8 s of a display's wallpaper changing (or of a rendering setting change) carry loading: shown with a note, no grade, battery share or comparison; a switch drops a comparison in progress. The rating recorder starts no interval within 8 s of a presentation change.
- Measured with the user's permission: 5 switches via wallpapermachine://apply on the covered primary display, per-second per-process coalition energy. First loads 10–22 J at 6–7 W for 2–4 s (app shader compile + MTLCompilerService); warm repeat 1.4 J; video 3 J; restore 5.8 J; WallpaperAgent ~0.5 J per desktop picture update. Wallpaper restored to 3796026374.
- Separate finding (flagged as a follow-up task): display-refresh bursts cost the app + panel WebContent ~12 J over 3 s each; MTLCompilerService recompiles despite a warm Vulkan pipeline cache (follow-up task).
- Tests: python3 scripts/test.py --only EnergyUsageMonitorTests --only WallpaperEnergyRatingsTests --only WebPanelEnergyUsageTests (26 passed); python3 -m unittest scripts.tests.test_panel_localization (OK); node --check and a Node render of loading, loading+contended, native+loading and normal readings.
- Full gate: python3 scripts/test.py — 1322 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Not verified: the new note in the running panel (no screenshot taken).

## 2026-10-10 — Energy readout: native video left out, macOS 27 ABI rechecked

- Change: readings while a video is on the native player carry nativeVideo (no grade, battery share or comparison); the per-wallpaper recorder skips intervals with a presenting native-video display; ratings carry version 2 and a video's unversioned rating is hidden and replaced, not averaged.
- Evidence for the fix: a stored rating of 0.18 mW over 4.4 h for a video wallpaper; GPU billed_to_me fields are 0 in all 818 coalitions; decoding 720p H.264 at ~1,700 fps charged ~2 W CPU and 0 GPU.
- ABI on M5 Pro, macOS 27.0.1: struct coalition_resource_usage is 50 fields (5 appended); indices 8/11/41 unchanged. Saturating Metal load: coalition 16.85 W, all coalitions 17.56 W, IOReport GPU Energy 17.94 W.
- Unchanged: the 0.25 contention threshold. A 60 fps probe read 91 mW alone and 162 mW at 21 % other GPU time (below the flag); documented, not retuned.
- Tests: python3 scripts/test.py --only EnergyUsageMonitorTests --only WallpaperEnergyRatingsTests --only WebPanelEnergyUsageTests (23 passed); new GPU-counter guard failed once on a cold test host (0 mW after 0.8 s) and now waits up to 5 s for a post, then passed 4 runs.
- Full gate: python3 scripts/test.py — 1319 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Page: node --check WebUI/settings.js; energyControl rendered in Node for native, native+contended, contended and normal readings. The panel itself was not opened (no desktop authorization).
- Not verified: a native-video wallpaper end to end in the running app, and the hardware decoder's own energy (needs powermetrics/root).

## 2026-10-09 — Keep web wallpapers animating through Show Desktop pointer moves

- Symptom: a web wallpaper (3747222633) froze briefly on every hot-corner Show Desktop; scene wallpapers did not. Unified logs showed no host suspension, WebKit activity-state change or poster capture at those moments.
- Before evidence (installed v1.3.2, three Show Desktops, 3 s sample of app/WebContent/GPU each): app main thread spent 122/234/210 ms in NSWindow.windowNumber(at:) via SLSCopyWindowRoutingRecordsForScreenLocation from WebWallpaperMouseForwarder, 0 ms in the idle baseline; WebContent updateRendering samples fell 20–45% in the same windows.
- Fix: routing reads the window the window server recorded in the event (kCGMouseEventWindowUnderMousePointer); only a press or scroll without it still queries, a move without it is dropped.
- Hand probe on real global-monitor events: field 91 matched windowNumber(at:) in 1536 of 1540 events (4 were transient screenshot-tool windows), never 0. Field 92 skipped the menu bar for moves, so it was not used. No scroll events were captured.
- python3 scripts/test.py --only WebWallpaperMouseRoutingTests: 6 passed (2 new); synthesized scroll events do not keep the field, so scrolls are covered by the fallback test.
- python3 scripts/test.py: 267 Python tests passed; native 1315 passed, 0 failed, 14 skipped of 1329. Full gate run once.
- Gap: smoothness after the fix on the real desktop is not yet measured; the same capture script must be re-run against a build that contains it.
- Separate, unfixed: a web page assigned while its display is suspended loads detached, so its first reveal is a cold start (327 ms hidden content plus shader compiles on 2026-10-09 18:03:57).

## 2026-10-09 — v1.3.2 published release and import-helper recovery

- Published [v1.3.2](https://github.com/WallpaperMachine/WallpaperMachine/releases/tag/v1.3.2), build 31, from `e278ae8f205e324835facd6f84c70e27f3d31cc7`; [Version run 37825423704](https://github.com/WallpaperMachine/WallpaperMachine/actions/runs/37825423704) passed every required job. Failed, unpublished v1.3.0/v1.3.1 tags were preserved; notes cover v1.2.6 through v1.3.2.
- Import-helper repair `8fb411a`: six targeted child-process tests passed normally and with `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Local `python3 scripts/test.py` passed 268 Python and 1,313 native tests, with 14 skips; no desktop picker was opened.
- CI `python3 scripts/test.py --serial` passed 268 Python and 1,312 native tests, with 15 skips and no failures. Rust core, bridge, core-integration and shader checks passed; six explicit desktop/corpus exclusions and three missing-asset shader skips remain unverified.
- CI renderer checks passed 12 generated pixel comparisons and eight projects through two reloads. Seven asset-dependent cases were skipped. The compiled timer probe exited 77 (35.20 ms median for a 10 ms wait), so ten named wall-clock cadence cases were skipped under `--allow-imprecise-timers`; these skips are not passing runtime coverage.
- CI verified the Release bundle and mounted disk image. Independently downloaded the public DMG: 36,496,549 bytes, SHA-256 `abaa683f21d1c24e97f8eb6f8c08839e9ba1bc0a4b573b893ea1d4258af47e32`; it matches the CI artifact, public sidecar, release asset metadata and public latest update manifest.
- Release body matches the tagged English notes and `Built from` commit; bundled changelog contains English and Simplified Chinese. Latest resolves to v1.3.2 and equals the highest public stable version. Public DMG and manifest requests succeeded.
- `gh attestation verify` passed for the public DMG, restricted to this repository and `.github/workflows/build.yml`, rejecting self-hosted runners and enforcing source digest `8fb411a34d05dc1a3f4218afaa1d647bc9d94089`. As documented, this event digest precedes the version-bump commit; `Built from` records the built revision.
- No install, launch/restart, desktop/Spaces/Mission Control/VoiceOver, real Siri/Focus, or manual disk-image smoke was performed. CI packaging and headless checks do not verify those surfaces. The release remains self-signed, not Developer ID signed or notarized.
