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

## 2026-10-13 — Live property preview in the preview window

The Wallpaper Preview window follows the property draft (debounced, hidden-aware) for scenes and Web pages; pictures and files stay as the preview loaded them and the window offers a reload. Swift only; the renderer's hot path was verified in the earlier renderer commits of this package.

- `python3 scripts/test.py --only` the touched preview, draft-hook, preset and panel-property classes (WallpaperPreviewLivePropertiesTests, LivePropertyPayloadTests, PropertyPreviewSchedulerTests, PropertyDraftHookTests, WallpaperPreviewSessionTests, WallpaperPreviewRequestTests, WebWallpaperPreviewSurfaceTests, WallpaperPreviewLayoutTests, WallpaperPresetStoreTests, ControlPanelPreviewTests, WebPanelAssetPropertiesTests, WebPanelHiddenPropertyTests, WebPanelPropertyLabelTests) — exit 0; 93 passed
- `python3 -m unittest scripts/tests/test_panel_localization.py` — 6 passed (the new string is in all four native languages)
- Not run: the full gate, `scripts/check_renderer.py` and `scripts/check_rust.py` (no Rust or C++ change in this commit), a Release build
- Unverified without a desktop run: the visible follow of sliders, colours, combos and booleans in an open preview of a scene and of a Web wallpaper, hidden and paused behaviour, the status line, a real renderer taking the document inside the window (listed in manual-smoke.md)

## 2026-10-13 — Reduced quality for Low Power Mode, heat and a low battery

The panel offers Reduced quality for the three system conditions and names the cause; the bridge, monitor and policy it drives were verified by the three commits before it. Targeted runs only: the full gate and a Release build were not part of this commit's verification.

- `python3 scripts/test.py --only` the 44 classes in `Tests/Unit/Panel` — 283 passed, 0 failed, 0 skipped; includes the new `testReducedQualityShowsItsProfileAndNamesItsCause`, `testDisplayFrameRateNoteCountsTheThrottle` and two `WebPanelPerformanceSettingsTests` cases
- The two new shell tests were re-run against the previous `WebUI/settings.js` — both failed, so they do not pass vacuously
- Each `scripts/tests/test_*.py` module (20, including `test_panel_localization.py`: every `t()` literal translated, identical keys in all three catalogs) — all exit 0
- Skipped: the full `python3 scripts/test.py` gate, `check_rust.py` and `check_renderer.py` (no Rust or C++ change in this commit), `--ui`, any desktop run
- Not covered: the live layout of the Playback rows and how the new sentences read in each language, a real Low Power Mode, thermal change or discharge reaching a running wallpaper, a change while the Mac is locked
- The power saving of Reduced quality has not been measured; no claim is made in the app or the docs. Planned comparison: a power benchmark with the profile on and off (the condition matrix has no row for it yet) in an authorized session

## 2026-10-13 — Native Metal compatibility, cost and default

Native Metal draws scene lights, previous-frame effects and steps with an unproduced input, culls and steps the host frame like Compatibility, shares target images, survives a pipeline-archive folder deleted mid-write, and becomes the default renderer with Compatibility as the per-scene fallback.

- Admission, `metal_scene_draw_smoke` once per scene over the 60 local scene wallpapers: main 95dfb6bc 48/60 on Native Metal (8 history feedback, 4 dynamic lighting); this branch 60/60.
- Same-harness parity, `MetalSceneDraw.LocalProjectsDrawTheSamePictureOnBothRenderers` with `WE_TEST_METAL_FRAMES=180 WE_TEST_RANDOM_SEED=1 WE_TEST_METAL_WARMUP_TICKS=40`: 57/60 identical (mean abs < 0.05/255), 3616389236 0.06 and 3675966045 0.26 (at most 0.1% of pixels), 3610485014 8.6 but differs from itself run to run.
- Cost, `UnchangedPresent.LocalProjectEnergyIsMeasuredHeadlessly` (`WE_TEST_ENERGY_*`), 12 scenes at 3840x2160 and 60 FPS, C N N C, 2 x 15 s per renderer: process CPU time 21.6 -> 17.1 s (-21%, every scene lower), own command-buffer GPU time 59.5 -> 51.0 s (-14%), command buffers 3 -> 1 per frame, CPU energy -12%; Compatibility 50.1 and 57.8 FPS on 3226487183 and 3620484312, Native 60. Measured before the last rebase; whole-GPU energy unusable while other sessions drew.
- Footprint, same test with 2 x 5 s windows on the rebased build: 18954 -> 18318 MB in total (-3.4%), 9 of 12 lower, none more than +6% (within run-to-run spread).
- Target sharing: 3620484312 Native render targets 926 -> 247 MB with no blit added; `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` restores one image per target.
- Archive crash: `MetalSceneDraw.AStoreFolderDeletedWhileItsArchiveIsWrittenCostsOnlyThatWrite` crashed 4 of 4 runs serialising beside the store and passes 4 of 4 with the fix; found as a SIGSEGV of `unchanged_present_test` in `check_renderer.py`.
- Every commit's tree built and passed `metal_scene_draw_smoke`, `metal_backend_test`, `unchanged_present_test` and `layer_texture_reference_test`; after the rebase onto 18ddfbd8 the same four and `script_runtime_compat_test` pass.
- `python3 scripts/check_rust.py` exit 0 (3 corpus/asset skips); `python3 scripts/check_renderer.py` exit 0 (env-gated local-project, energy, text-workshop and local-video skips); `python3 scripts/test.py` exit 0, 2564 passed, 45 skipped; all on 95dfb6bc plus this branch.
- Not checked: a real display or the desktop, wallpapers outside the local library, the lock screen (still Compatibility). Seen only under parallel load and passing alone: `TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`, `TheSkipPresentsTheSameVideoFramesInTheSameOrder`.

## 2026-10-13 — One depth rule for both scene renderers

Native Metal dropped depth writes for translucent and additive materials and depth-tested into targets with no depth attachment; both renderers now take a draw's depth state from ResolveSceneDepthState. Wallpaper Engine's own translucent depth-tested font materials write depth, as Compatibility already did.

- `MetalSceneDraw.ADepthWritingDrawHidesLaterDrawsAsOnCompatibility` (seven authored blend/depth cases through both renderers): **failed** without the source change (translucent, additive and no-attachment opaque cases differ), **passed** with it
- `python3 scripts/check_renderer.py`: **exit 0**; `metal_scene_draw_smoke` **57 passed**, `metal_backend_test` **35 passed**, generated cases pixel-equal with no diagnostics, reload probe 8 projects x2 clean; local-project tests skipped (no `WE_TEST_*` projects)
- `python3 scripts/build.py --renderer-only` then `python3 scripts/test.py`: **2564 passed, 0 failed, 45 skipped**
- After rebasing onto `b0f1a177`: `metal_scene_draw_smoke` **58 passed**, `metal_backend_test` **35 passed**
- Renderer comparison (`LocalProjectsDrawTheSamePictureOnBothRenderers`, on the uncommitted Native Metal compatibility work, which draws model scenes natively) over 28 local model/perspective scenes plus Leon, baseline/fix/baseline: no change beyond run-to-run noise; 3675966045 differs by 0.417 mean in every run, unrelated
- Not checked: the app on the desktop; the Release build follows the commit

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
