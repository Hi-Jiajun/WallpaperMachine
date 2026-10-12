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

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-10-13 — Switch to stop writing the macOS desktop picture

Settings › General › Use the wallpaper as the macOS desktop picture, on by default. Off, poster writes stop, the user's own picture is put back with the quit's verified restore, and a poster left behind is repaired at launch. Commit 1 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only PlaybackPreferencesTests --only DesktopWallpaperTests --only WebPanelGeneralSettingsTests --only LockScreenWallpaperServiceTests` — 133 passed, 0 failed, 0 skipped
- All Desktop, LockScreen, Panel and Lifecycle test classes — 839 passed, 0 failed, 0 skipped; `scripts/tests/test_panel_localization.py` passes with the new catalog keys
- Mutation check: with the settings.js row removed, the offscreen row test fails and the rest pass.
- Not run: the full gate, a Release build, any desktop run. Unverified: what Mission Control and the Spaces bar show after the switch goes off and on, the macOS 27 read-back during the 25-attempt restore, enabling Animate lock screen with the switch off, and the relaunch repair; `AppDelegate`'s decision of when to restore is wiring that no unit test reaches. See the new rows in manual-smoke.md.

## 2026-10-13 — Native video wake and resume repair

A stalled native video pipeline is now kicked, rebuilt once and then handed to Compatibility, after a resume, a wake or an unlock. Commit `fix(native-video): repair a stalled pipeline after a resume, wake or unlock`, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only NativeVideoHealthLadderTests --only NativeVideoHealthSupervisorTests --only NativeVideoWallpaperHostTests --only NativeVideoRecoveryBudgetTests --only NativeVideoLivenessTests` — 142 passed, 0 failed, 0 skipped
- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlayerMediaTests` — 37 passed, 0 skipped, twice (the hev1 clip is frame-less on this OS, so the kick, rebuild and give-up cases ran); all NativeVideo classes plus RuntimeCountersTests and WallpaperPresentationPolicyTests with media on: 256 passed, 0 failed, 0 skipped
- Mutation checks, each failing exactly the tests that defend it and then reverted: no absorb rule while repairing, no supersession of a wake settle, a rebuild that cancels its own check.
- The lock-screen extension target compiled the two new `RuntimeCounter` cases in the same builds.
- Not run: the full gate, a Release build, any desktop run. Unverified: that the system really reclaims a decoder across sleep, lock or a covered desktop, and that a kick or a rebuild brings one back; the `hev1` pipeline cannot be repaired, so only the failing ladder is shown. The 1 s wake settle and the cost of the check output on a 4K clip are untuned. See the sleep, lock and unlock rows in manual-smoke.md.

## 2026-10-13 — Native video liveness detection after a long pause

Observation only: the check logs and counts a stalled pipeline and acts on nothing. Commit `feat(native-video): detect a pipeline that stops delivering frames`, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only NativeVideoLivenessTests --only NativeVideoHealthSupervisorTests --only NativeVideoWallpaperHostTests` — 100 passed, 0 failed, 0 skipped
- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlayerMediaTests` — 31 passed, 0 skipped (the hev1 clip is frame-less on this OS, so its two cases ran); the other NativeVideo classes with media on: 182 passed, 0 failed, 0 skipped
- The lock-screen extension target compiled the new `RuntimeCounter` case in the same builds.
- Not run: the full gate, a Release build, any desktop run. Unverified: whether a real long suspension (covered desktop for hours, display sleep, Low Power Mode) ever costs a clip its decoder; no test reclaims one, so only the `nativeVideoPlaybackStalled` counter on a real Mac answers it. Cost of the check's video output on a 4K clip not measured.

## 2026-10-13 — Play only on the display in use

Commit `feat(playback): optionally play only on the display you are using`: opt-in Playback toggle `Only play on the display I’m using`. ActiveDisplayTracker follows the pointer through event monitors that exist only while the option is on and two displays are connected; WallpaperPresentationPolicy treats every other display as hidden after a 3 s dwell and resumes at once, never darkening every display. No bridge or Rust change. Taken in a worktree; the full gate was not run here.

- `python3 scripts/test.py --only ActiveDisplayTrackerTests --only WallpaperPresentationPolicyTests --only PlaybackPolicyCompositionTests --only PlaybackPreferencesTests --only WebPanelPerformanceSettingsTests --only PowerSourceResamplerTests --only WallpaperBackupTests` plus SystemConditionMonitorTests, LowBatteryTests, WebPanelGeneralSettingsTests, ControlPanelPlaybackToolsTests, ControlPanelSnapshotDeliveryTests, WebPanelAssetsTests, AppRuleMonitorTests, OtherAudioMonitorTests — 152 passed of 152 (19 new).
- Deliberate breaks (a wait that ignores cancellation, a pointer entry that leaves the old wait running, no never-darken-every-display guard) each failed the new tests; all were reverted.
- `python3 -m unittest scripts.tests.test_panel_localization` — 5 passed (three new WebUI strings in ja, zh-Hans, zh-Hant).
- Not run: the full gate; real global and local pointer events across two physical displays, whether the global monitor sees the pointer while this app is in front, the display-ID mapping with mixed scaling, how the 3 s dwell feels, and the live row layout. All need an authorized two-display desktop run.

## 2026-10-13 — Low-battery playback rule

New Playback rule `When the battery is low` (Keep running, Pause or Stop at 10, 20 or 30 percent; internal battery only). It joins SystemConditionMonitor's actions, reads IOKit's power-source notification only while an action is chosen, and is hidden on Macs without a battery. No bridge or Rust change.

- `python3 scripts/test.py --only LowBatteryTests --only SystemConditionMonitorTests --only PlaybackPreferencesTests --only WebPanelPerformanceSettingsTests --only WallpaperBackupTests` plus WebPanelGeneralSettingsTests, ControlPanelSnapshotDeliveryTests, WebPanelAssetsTests, WebPanelCompatibilityTests, ControlPanelPlaybackToolsTests, WallpaperPresentationPolicyTests, PlaybackPolicyCompositionTests — 122 passed of 122 (18 new).
- Seven deliberate breaks (no release margin, parse accepting a UPS, observing while Keep running, a wake refresh that reads nothing, unchecked level in preferences, panel action and backup restore) each failed at least one new test; all were reverted.
- `python3 -m unittest scripts.tests.test_panel_localization` — 5 passed (four new WebUI strings in ja, zh-Hans, zh-Hant).
- Not run: the full gate, a real discharge crossing the level, IOKit's notification cadence on this Mac, the live panel row layout. The live battery read is never asserted.

## 2026-10-13 — Mission Control poster kept while fresh

Commit `perf(desktop): stop retaking the Mission Control picture while the current one is fresh`: DesktopWallpaperSync retakes a surface's poster on a Space change, wake or resume only when it is older than 120 s or was taken before the wallpaper settled. Taken in a worktree; the full gate was not run here.

- `python3 scripts/test.py --only DesktopWallpaperTests` — 62 passed of 62 (8 new tests for the freshness floor, one existing test now builds the sync with a zero floor). Three mutations each fail the expected tests: a poster never kept (4 failures), the settle rule ignored (1), Space scope ignored plus a failed encode left counting as fresh (2).
- The same class plus WallpaperPresentationPolicyTests, PlaybackPolicyCompositionTests, WallpaperSpaceMonitorTests and WallpaperActivationRecoveryTests — 121 passed of 121.
- Gap: what Mission Control shows after rapid Space swipes with an animated wallpaper, and whether WallpaperAgent's container stops growing, were not observed; headless tests use synthetic pixels, an in-memory workspace and an injected clock.

## 2026-10-13 — Power source read again on wake (resample)

Commit `fix(power): read the power source again when the Mac wakes`: WallpaperBridge.resample_power_source() and PowerSourceResampler (wake plus a follow-up two seconds later). Taken in a worktree on top of the power watcher change (`perf(bridge): let the power watcher sleep until something happens`); the full gate was not run here.

- `cargo test -p wallpaper-bridge --lib power` — exit 0; 32 passed (7 new resample tests). Two mutations (resample never processed; unreadable source delivered) each fail the expected tests.
- `python3 scripts/build.py --renderer-only` — exit 0; App/Bridge/Generated diff limited to resamplePowerSource and its checksum.
- `python3 scripts/test.py --only PowerSourceResamplerTests` plus SystemConditionMonitorTests, PlaybackPolicyCompositionTests, WallpaperSpaceMonitorTests, WallpaperActivationRecoveryTests, WebPanelPerformanceSettingsTests — 56 passed of 56 (7 new). Removing the cancellation guard and stop()'s cancel together fails 2 tests; removing the start() guard fails 1.
- `python3 scripts/check_rust.py` — exit 0; bridge 401 passed, core 224 passed; local-corpus shader cases skipped.
- `python3 scripts/check_renderer.py` — exit 0; skipped: 4 asset-dependent cases (text_object_runtime_test x2, playback_gpu_test, metal_scene_draw_smoke).
- Gap: a real plug or unplug during sleep, and whether IOKit answers correctly at the instant of wake, were not exercised; headless tests prove the repair logic and idempotence only.

## 2026-10-13 — Battery share of Energy use and the per-wallpaper rating

Energy use's battery line was missing on macOS 27 (capacity keys moved into BatteryData, no CellVoltage); the per-wallpaper rating now carries the same share. M5 Pro MacBook Pro, macOS 27.0.1, on battery.

- Coalition fields rechecked under a Metal load: field 41 summed over all coalitions 28.3 W against IOReport `GPU Energy` 29.5 W (4 %); field 11 tracks CPU energy
- `BatteryCapacity.fullChargeWattHours()` on the live registry: nil before the fix, 98.5 Wh after (FullChargeCapacity 8,530 mAh × 3 × 3.85 V; rated 99.6 Wh)
- `python3 scripts/test.py --only EnergyUsageMonitorTests` — failed on the new macOS 27 fixture before the fix, 13 passed after
- `python3 scripts/test.py --only WallpaperEnergyRatingsTests` — 11 passed
- Inspector sentence rendered with Node from `panel.js`'s `energyRating` and the real catalogs in en, zh-Hans, zh-Hant and ja, with and without a battery share
- `python3 scripts/test.py` — 1342 passed, 0 failed, 14 skipped
- Not checked: the rendered panel on screen (no desktop run requested); the rating line on a real rated wallpaper

## 2026-10-13 — Layers a wallpaper's properties hide leave the render graph

Settled-hidden layers (authored or property-bound visibility, no script) are left out of sceneToRenderGraph; a script showing one rebuilds the graph once. Run in a detached worktree at 24aa0834 plus this change.

- `layer_texture_reference_test` HiddenLayers, `rendergraph_smoke` aHiddenFirstWriter…, `metal_scene_draw_smoke` ALayerItsPropertiesHide… — new; the first and last fail without the change
- `python3 scripts/check_renderer.py` — exit 0; 4 asset-dependent tests skipped (no local corpus assets)
- `python3 scripts/test.py` — exit 0; 1341 passed, 0 failed, 14 skipped
- By hand: `script_runtime_compat_test` 98, `scene_schema_tests` 111, `mdl_schema_tests` 57 — all passed
- Workshop 2531810451 defaults: native Metal targets 11.42 → 0.39 GB, peak footprint 12.66 → 1.64 GB, 240 → 19 passes/frame; Vulkan VMA 8.26 → 0.54 GB; frames byte-identical on both
- 60 local scenes, both probes, base ×2 vs fix: 29 use less memory, none more; same backend choices; no difference beyond base-vs-base noise (one Vulkan video-decode timing case converges by frame 89)
- Not checked: desktop/app run, a real SceneScript revealing a property-hidden layer (covered by the runtime call it makes), scenes with clearenabled false (none local; guarded by rendergraph_smoke)

## 2026-10-13 — Web wallpaper pointer and frame cadence (#45)

Issue #45 reported the Colorful Fluid Animation web wallpaper (1748506393) sampling the cursor at 10–20 Hz on a 120 Hz screen. Measured on a 120 Hz MacBook Pro, macOS 27.0.1. Web wallpapers now draw at a display's full refresh when its effective frame rate reaches a refresh above 60 Hz.

- Authorized live run, real hand movement over the bare desktop, temporary in-page probe (removed): cursor ~120/s → global monitor ~118/s (every move carried the window under the pointer) → page `mousemove` 60/s → the page's own loop 50/s. 10–20 Hz not reproduced.
- Scratch WKWebView harness hosted like `WebWallpaperWindow`: WebKit coalesces hover to one move per rendering update (60/s on 120 Hz). With `PreferPageRenderingUpdatesNear60FPSEnabled` off at creation: 120 moves/s and 120 rAF/s. Flipping it on a live page (re-attach, hide/show, reload) had no effect.
- Harness: a GPU-bound page drops pointer, rAF and its own loop together (13/s); a starved JS loop does not slow WebKit's pointer delivery; emulated audio splats had no effect.
- `python3 scripts/test.py --only` WebWallpaper host/page/routing/recovery/suspension classes — 39 passed; mutation without the new reuse check fails `testFrameRateCrossingTheDisplayRefreshRebuildsThePage` as expected.
- `python3 scripts/test.py` (isolated worktree) — Python script tests OK; 1355 native: 1341 passed, 14 skipped.
- Not measured: the rebuilt page's 120 Hz cadence inside the real app (needs a 120 fps setting and a live run); the reporter's own machine.
