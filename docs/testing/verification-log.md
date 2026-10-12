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

## 2026-10-12 — Control panel stays closed at login (issue #41)

- Change: ControlPanelLaunch reads the open-application Apple event's keyAELaunchedAsLogInItem; a login launch skips the startup panel unless the welcome guide is unfinished or BridgeStore failed to start.
- python3 scripts/test.py --only ControlPanelLaunchTests: 3 passed.
- python3 scripts/test.py on origin/main 1607a15 + this change: 1339 passed, 0 failed, 14 skipped of 1353.
- Gap: not verified with a real logout/login; whether SMAppService.mainApp launches still carry keyAELaunchedAsLogInItem on macOS 27 is unconfirmed. Look for 'startup: launched at login; control panel stays closed' in the app log after the next login.

## 2026-10-11 — macOS 27 per-Space poster writes: absolute paths and late acknowledgement

- Diagnosis (read-only, M5 Pro, macOS 27.0.1): DesktopPictureSetDisplayForSpace forwards to WallpaperServices, whose result HIServices discards; every poster write logged 'Failed to set legacy configuration: … no such file' because the sandboxed WallpaperAgent resolves the root-relative path inside its container.
- Live, with the user's permission, on one inactive Space: an absolute home-path poster was accepted with no WallpaperServices error, changed only that Space's two store nodes, and read back after ~0.3 s (not immediately); the original was restored and the probe image deleted.
- The WallpaperServices BOOL is returned before the agent applies the write (failures are logged later off-thread), so it is not used as acknowledgement.
- Store evidence: writes to a display's visible Space are copied into SystemDefault and Displays/<uuid>; the on-disk Index.plist can lag the agent's memory until a scheduled store write.
- Unit: python3 scripts/test.py --only DesktopWallpaperTests (51 passed), including late-acknowledgement, never-acknowledged pause, absolute-path configuration and the poster-pruning race the new test exposed.
- Gate: python3 scripts/test.py — 1339 passed, 0 failed, 14 skipped.
- Not checked: a full app session on macOS 27 with the rebuilt app, Mission Control thumbnails, or macOS 15/26 (root-relative path path unchanged there).

## 2026-10-11 — Aligned layers turn about their anchor

SceneRuntimeContext rotated a non-centre layer about its centre and slid its anchor offset along the scene's axes. Every gate below ran in a detached worktree at HEAD plus this change only, because another session's uncommitted audio edits in the shared tree stop audio_tests from compiling (SmoothAudioResponseBinsForTesting undeclared).

- `script_runtime_compat_test`: 97 passed; the new `RotatedAnchoredLayerTurnsAboutItsAnchor` and `ScriptedRingBarsHangOutwardFromTheirCircle` fail on HEAD's runtime (rotation assertions only). `scene_schema_tests` 110, `scenescript_media_event_smoke` 20, `text_object_runtime_test` 64 passed, 2 skipped (local assets).
- `metal_scene_draw_smoke` LocalProjects, 2850003448 at 2560x1440, 60 Hz noise (amplitude 0.5 for legible bars): before, the ring slid down over the planet; after, bars hang outward from a dark ring, as in the Workshop preview.
- Local corpus A/B, 57 scenes, `offscreen_scene_probe` `nodes.txt`, both arms built from HEAD: placement moves only on rotated non-centre layers in 6 scenes. 3276911872's audio strip now rests on the date line, flush with its left edge; 3665954520's hidden visualizer bar now spans its sibling bars' 150 units from their shared corner; three text layers tilted 0.6-2.2 degrees move up to 4.4 units. 3589454154's node diffs, and every pixel/state diff, also appear between two baseline runs.
- `python3 scripts/check_renderer.py`: exit 0; 12/12 generated scenes pixel-equal pooled vs isolated; reload cycles 0. Skipped: 2 local-asset text tests, local video import, local-project Metal (run by hand above).
- `python3 scripts/test.py`: Python suites OK; native 1334 passed, 0 failed, 14 skipped of 1348.
- Gap: Wallpaper Engine's offset for a script-set alignment (full size*scale vs this renderer's scale delta) is unconfirmed; 8-unit bars differ by 4 units, too little for a preview. Not rebuilt as a Release app.
