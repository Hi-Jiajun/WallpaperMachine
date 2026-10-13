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

## 2026-10-13 — Workshop effect shaders the legalizer rejected

Shader legalizer repairs for permissive-path expressions that dropped whole Workshop effects on both renderers (scalar builtin broadcasts, mixed-width operands, scalar and bool stores, return conversion, widened float-array component subscripts, runtime global initializers, statements after annotations or directives). ShaderPipelineRevision 11 -> 12.

- `cargo test -p shader` — 528 passed; the 12 new regressions in legalize_type_coercion, legalize, naga_compile and tokenizer each failed before its fix
- Local-library A/B, 1,269 (scene, shader, combos) programs from 60 scenes, SPIR-V and MSL: failures 64 -> 28, none that compiled stops compiling; changed output for programs that already compiled is semantically neutral
- The 28 left are outside this change: Naga MSL lacks inverse() (stock lightshafts, perspective, reflection, clouds, waterwaves variants), two preprocessor #if forms, and a builtin scalar call initializing a vector
- `offscreen_scene_probe` and `metal_scene_draw_smoke` on the 11 affected scenes: 77 Vulkan load/compile failures before, 0 after; on Metal only the stock reflection inverse() failure remains; no native-Metal fallback
- `python3 scripts/check_rust.py` — exit 0 (core, bridge, core-integration, shader)
- `python3 scripts/check_renderer.py` — exit 0; generated cases pixel-equal pooled/isolated, no diagnostics; reload cycles clean
- `python3 scripts/test.py` — first run 1 failure in EnergyUsageMonitorTests.testKernelCountersForThisProcessAdvanceWithGPUWork (8.05 mW < 10 mW, own compute kernel, while another session ran GPU probes); class alone 13/13; rerun exit 0: 2,564 passed, 45 skipped
- Not checked: whether each restored effect looks as it does in Wallpaper Engine; no desktop run

## 2026-10-13 — Robustness, web, video, lock-screen and panel port: integrated gate

105 commits of independently implemented reliability, web-host, native-video, lock-screen, power, Workshop, playlist, menu-bar, switch-hold and per-display position work, verified together on one tree on top of 20f44470 (the per-commit entries record each area's targeted runs).

- `python3 scripts/test.py` — exit 0 on the second run; Python 316 tests OK; Swift 2564 passed, 0 failed, 45 skipped of 2609. The first run had one failure, ControlPanelLibraryTests.testHoldAndDragSelectsARunOfTilesWithoutWindow, under load from another build; the class passed alone (17/17) and the sweep code is unchanged by this work
- `python3 scripts/check_rust.py` — exit 0; core 293, bridge 542, core-integration 15, shader 534 passed; desktop window tests and corpus smoke cases skipped
- `python3 scripts/check_renderer.py` — exit 0; 708 gtest cases passed, 4 skipped (local-asset cases), 0 failed; no --project corpus, so authored-reference compatibility is not verified
- `python3 scripts/build.py --configuration Release` — exit 0; regenerated bindings identical to the committed ones
- Commits that change the bridge API or move test helpers were each compiled on their own with `scripts/test.py --only` at that commit
- Not verified: no desktop run. The switch-hold picture during a wallpaper change, wake and stall repair, the lock screen, menu-bar submenus, the position controls on real displays, native-video layout on real displays and live Steam downloads still need an authorized desktop check

## 2026-10-13 — Position sliders follow a drag

Commit 8 of the framing lane: while a Position slider is dragged the running wallpaper follows through a non-saving preview call; the release is the ordinary move. Targeted runs in the lane's worktree; the bare full gate was not run, no desktop was opened and the app was not rebuilt there.

- `cargo test --release -p wallpaper-core --lib framing` and `-p wallpaper-bridge --lib display_position` — pass (core 17 framing tests, bridge 24 position tests); each bridge mutation of the preview mark, the saved-axis base and the commit clearing was caught
- `python3 scripts/check_rust.py` — exit 0; core 287, bridge 540, core integration and shader passed; six core tests excluded (desktop run, local wallpaper corpus)
- `python3 scripts/build.py --renderer-only` — exit 0; `App/Bridge/Generated` regenerated (one method, `preview_display_position`)
- `python3 scripts/check_renderer.py` — exit 0; skipped: local-asset cases in `text_object_runtime_test`, `playback_gpu_test` and `metal_scene_draw_smoke` (no corpus)
- `python3 scripts/test.py --only WebPanelDisplayPositionTests` and 13 neighbouring panel classes — 133 passed; the drag tests were broken one at a time (no interval, release not waiting for the step on its way, no settle on pointer-up, key presses previewing, a queued or saving preview) and each was caught
- Not checked: the wallpaper following a real drag on a display, the 100 ms interval and the feel under load, the lock screen and Mission Control picture staying put during a drag, and `SceneRuntime::preview_framing` against a live renderer (see manual-smoke.md)

## 2026-10-13 — Per-display wallpaper position

Commit 7 of the framing lane: the inspector's Position sliders and Center for scene and video wallpapers. Commits 1-6 had already carried the position through the engine, the bridge and the lock-screen export; commit 8 follows the sliders live.

- `python3 scripts/test.py --only WebPanelDisplayPositionTests` — exit 0; 10 passed
- `python3 scripts/test.py` with 23 `--only` classes (the panel suites, UserCommandQueueTests, WallpaperActivationRecoveryTests, ActivationLogTests) — exit 0; 198 passed, 0 failed
- Script tests (the 20 modules the gate runs first, run directly) — exit 0, including test_panel_localization: the ja, zh-Hans and zh-Hant catalogs carry the four new strings
- Mutation checks — eleven deliberate breakages (dead change handler, sliders hidden for scenes, request naming no axis accepted, clamping instead of refusing, no scene/video and display check, no change notice, native flag for any backend, reset sending one axis, move not queued, both axes sent, native note dropped) each failed the new class, which passed again once they were undone
- Not run: the bare `python3 scripts/test.py` gate, `check_rust.py` and `check_renderer.py` (no Rust or C++ change), a Release build
- Unverified (desktop only): the wallpaper visibly moving under the sliders on a real display on both scene renderers, slider feel and layout at the narrowest panel width, VoiceOver reading, the Mission Control picture being retaken after a move

## 2026-10-13 — Web host takes the switch hold

A replacement web page's window opens with the picture it replaces over it and drops it 500 ms after the page has loaded, or at once when it fails. A window closed with no web successor ends only the veil it carries. Targeted run only: the lane runs the full gate once, at its end.

- `python3 scripts/test.py --only WebWallpaperHostLifecycleTests --only WallpaperSwitchHoldTests` — exit 0; 51 passed (10 new: 8 web host, 2 hold)
- `python3 scripts/test.py` with the web test classes, `NativeVideoWallpaperHostTests`, `WallpaperActivationRecoveryTests` and `DesktopWallpaperTests` — exit 0; 336 passed
- Mutation check — five one-line breakages of `WebWallpaperHost` (no adopt, no release on load, no release on failure, the plan's unconditional `cancel` where a window closes, no release of a veil on the closed window) each failed between 1 and 4 of the host tests
- Skipped: the full gate and `check_rust.py`/`check_renderer.py` (no Rust or renderer change in this commit), any desktop run
- Not established: that 500 ms after `didFinish` is enough for a real project's first paint; how long the system picture shows while a page's window is replaced, and after a scene closes; the fade and the page-to-page, scene-to-page and page-to-scene switches on a real display ([manual smoke](manual-smoke.md#wallpaper-switching))

## 2026-10-13 — Native video host takes the switch hold

A replacement clip's window opens with the picture it replaces over it and drops it on the clip's first frame; a replacement's admission is decided before the old surface stops. Targeted run only: the lane runs the full gate once, at its end.

- `python3 scripts/test.py --only NativeVideoWallpaperHostTests` — exit 0; 98 passed (11 new)
- `python3 scripts/test.py --only NativeVideoWallpaperHostTests --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests` — exit 0; 225 passed
- Mutation check — seven one-line breakages of `NativeVideoWallpaperHost` (no adopt, close before admission, no cancel on failure, no settle after hand-off, no release on first frame, no overtaken-pass guard, no release for a layer ready at birth) each failed between 1 and 5 of the host tests
- Skipped: the full gate and `check_rust.py`/`check_renderer.py` (no Rust or renderer change in this commit), `NativeVideoPlayerMediaTests` (opt-in), any desktop run
- Not established: that `isReadyForDisplay` alone is late enough that the veil does not come off a frame early on a real clip; the fade and the clip-to-clip, scene-to-clip and refusal switches on a real display ([manual smoke](manual-smoke.md#wallpaper-switching))

## 2026-10-13 — Wallpaper switch hold for scene successors

Commit 3 of the seamless-switch lane, built and tested in an isolated worktree on top of the layer-swap revert and layer announcement commits. Web pages and native-backend clips take the veil in the lane's next commits; this one carries it for scenes.

- `python3 scripts/test.py --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests --only WallpaperPresentationPolicyTests --only WallpaperReapplyTests --only WallpaperDisplayTransferIntegrationTests --only WallpaperDisplayTransferTests --only UserCommandQueueTests --only ActivationLogTests --only WallpaperWindowAuditorTests` — exit 0; 234 passed, 0 failed, 0 skipped
- Mutation check on `WallpaperSwitchHold` (a reconfigure takes the veil, the engine settling no longer fades a scene's veil, the host grace is never applied): 7 of the 26 `WallpaperSwitchHoldTests` failed; the file was restored
- Not run: the full gate, `scripts/check_rust.py` and the renderer checks (no Rust, bridge or C++ change in this commit), and the gated window cases of the lane's first two commits (`case_wallpaper_window_layer_swap_revert`, `case_wallpaper_window_layer_swap_finish`, `case_wallpaper_window_announces_layers`)
- Unverified, desktop only: a sublayer above the `CAMetalLayer` composites over its drawables and hides the black placeholder, scene surfaces answer the still request within 250 ms (a paused renderer included), the held still looks like the live frame it replaces, the 0.2 s fade, Reduce Motion, multi-display and mirror switches (checklist in manual-smoke.md)

## 2026-10-13 — Workshop downloads in the menu bar

StatusMenuModel.DownloadActivity and WorkshopDownloadManager.inProgressTransfers: while Workshop downloads run, a line under Control Panel reads Downloads: N in progress with a byte-weighted percent that is left out when any counted job cannot report a size and stops at 99, and opens Discover. Built when the menu opens (no timer). Commit 10 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only StatusMenuModelTests --only DownloadQueueTests --only WorkshopDownloadPersistenceTests --only WorkshopStoreTests --only AppAutomationTests --only AutomationCommandTests --only ControlPanelAutomationTests --only DownloaderLifecycleTests` — exit 0; 116 passed, 0 failed, 0 skipped
- Mutation check: counting a paused job, counting the sign-in job and letting the percent reach 100 each failed the test written for it (3 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the native catalog key `Downloads: %lld in progress, %lld%%` was confirmed against what the Swift compiler extracts for the literal)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py`, `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the line draws and reads in the real menu, that it appears while a real SteamCMD transfer reports bytes, and that choosing it brings Discover forward; see manual-smoke "Download queue"

## 2026-10-13 — Mute every wallpaper (menu bar, links, Shortcuts, shortcut key)

PlaybackPreferences.wallpapersMuted, OR-ed into WallpaperPresentationPolicy's audio suppression (the bridge's audio_suppressed, which the engine ORs with each wallpaper's saved mute), reached from a ticked Mute Wallpapers menu item, wallpapermachine://mute, unmute and togglemute, three Shortcuts actions, a shortcut key and a Settings → Performance → Playback switch. Commit 9 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only PlaybackPolicyCompositionTests --only PlaybackPreferencesTests --only AutomationCommandTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WebPanelGeneralSettingsTests --only WallpaperBackupTests --only WallpaperPresentationPolicyTests` plus AppAutomationTests, GlobalHotKeysTests, WebPanelPerformanceSettingsTests, ControlPanelShellTests, WebPanelExternalLinkTests, WebPanelAssetsTests, ControlPanelAutomationTests, WallpaperActivationRecoveryTests, OtherAudioMonitorTests, AppRuleMonitorTests and SystemConditionMonitorTests — exit 0; 247 passed, 0 failed, 0 skipped
- Mutation check: dropping the user mute from the policy, the muted arm of the menu item's condition, the unchanged-value guard in the preference and the Settings row each failed the tests written for them (5 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the WebUI key check includes the new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: that scene, video (Native and Compatibility) and Web wallpapers really go silent and come back through an audio output (audio hardware needs an authorized desktop run; only the suppression delivered to the bridge is tested), how the ticked menu item draws and reads, Siri or Shortcuts listing the three actions, and a real shortcut key press; see manual-smoke "Audio responsiveness"

## 2026-10-13 — Random Wallpaper command

A new AutomationCommand.random(display:pool:) with pools all and favorites, reached from the menu bar, wallpapermachine://random, a Shortcuts action and a shortcut key. Its pick comes from PlaylistStore.randomPick with a round of its own per display and pool (kept beside the shuffle rounds in WallpaperMachine.playlistRounds), and BridgeStore.activateRandomWallpaperAsync makes it in the display's turn of the command queue. Commit 8 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate.

- `python3 scripts/test.py --only AutomationCommandTests --only PlaylistStoreTests --only PlaylistPlannerTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WallpaperDisplayTransferIntegrationTests --only WebPanelGeneralSettingsTests` — exit 0; 105 passed, 0 failed, 0 skipped
- `python3 scripts/test.py --only AppAutomationTests --only GlobalHotKeysTests --only PlaylistSchedulerTests --only WebPanelPlaylistTests --only WallpaperBackupTests --only ControlPanelPlaybackToolsTests --only ControlPanelShellTests --only WebPanelAssetsTests --only ActivationLogTests --only WallpaperActivationRecoveryTests` — exit 0; 172 passed, 0 failed, 0 skipped
- Mutation check: dropping the held-wallpaper exclusion and recording a pick before it was applied each failed the integration test written for it; both were reverted
- Every scripts/tests/test_*.py module run directly — all passed (the WebUI key check includes the two new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the menu item draws and reads, a real shortcut key press, Siri or Shortcuts listing the action and its Choose from option, and how a random pick looks on real displays; see manual-smoke "The menu bar with two displays"
