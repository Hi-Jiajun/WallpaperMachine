# Renderer verification

Non-desktop verification of the vendored renderer in `upstream/renderer`: the
Rust crates, the C++ scene engine and its GPU probes. Nothing here creates a
window, swapchain, audio device, or screenshot, and nothing here inspects or
changes the desktop. Dated results live in
[verification-log.md](verification-log.md); this file is the working reference.

This file is long. Read the section you need rather than the whole file
(`rg -n '^##' docs/testing/renderer.md` gives the line numbers):

| Section | Read it when |
|---|---|
| [`scripts/check_renderer.py`](#scriptscheck_rendererpy) | Running or changing the renderer check itself |
| [Probes](#probes) | Driving `offscreen_scene_probe` and friends by hand; `WE_TEST_*` variables |
|  [Metal compile across processes](#metal-compile-across-processes) | Measuring what a later launch compiles again; why a copied probe recompiles |
| [Regression areas that must stay covered](#regression-areas-that-must-stay-covered) | Before changing renderer behaviour: the table names the test that guards each area |
|  [Property bindings and alignment anchors](#property-bindings-and-alignment-anchors) | Property scripts, `origin`/`scale`/anchor maths |
|  [Native writes from scripts, puppet layers and cursor coverage](#native-writes-from-scripts-puppet-layers-and-cursor-coverage) | SceneScript side effects, puppets, cursor hit tests |
|  [Startup and staging buffers](#startup-and-staging-buffers), [Alpha compositing](#alpha-compositing) | First-frame, staging, blend modes |
|  [Vector material constant timelines](#vector-material-constant-timelines), [Scripted material constants](#scripted-material-constants-keep-their-component-count) | Material constants and their animation |
|  [Timeline events](#timeline-events), [Animation and puppets](#animation-and-puppets) | Event timelines, puppet animation layers |
|  [Cursor coordinates and presentation](#cursor-coordinates-and-presentation) | Pointer mapping across displays and scales |
|  [Text, fonts and clocks](#text-fonts-and-clocks) | Text layers, font fallback, clock formats |
|  [Textures, allocation and composition](#textures-allocation-and-composition) | Texture keys, allocation, composition layers |
|  [Frame timing](#frame-timing), [Frame pacing](#frame-pacing-follows-the-content-bounded-on-both-sides) | Pacing, throttling, battery behaviour |
|  [Continuous-playback work contracts](#continuous-playback-work-contracts), [Renderer work counters](#renderer-work-counters) | Work-per-frame contracts, `RuntimeCounters` |
|  [Video decode state machine and colour range](#video-decode-state-machine-and-colour-range) | Video playback in scenes |
|  [Shader pipeline](#shader-pipeline) | GLSL translation, uniform blocks, varyings |
| [Rust crates](#rust-crates) | `cargo test` commands and the configure-retry trap |
| [C++/CMake test binaries](#ccmake-test-binaries) | Building and filtering the gtest executables |
| [Known limitations](#known-limitations) | Before reporting a failure as a regression: the pre-existing ones are listed |

## `scripts/check_renderer.py`

```sh
python3 scripts/check_renderer.py
```

It assembles the Homebrew environment from `scripts/build.py`, then:

1. builds `cargo build -p shader --features ffi --release` **from
   `upstream/renderer`**, because rustup resolves that tree's
   `rust-toolchain.toml` (nightly) from the working directory, not from
   `--manifest-path`; running it from the repository root picks the default
   stable toolchain instead,
2. configures CMake over `upstream/renderer/external/open-wallpaper-engine` with
   `CMAKE_BUILD_TYPE=Release`, `BUILD_TESTS=ON`, `RUST_SHADER_FFI=ON`, and
   `RUST_SHADER_STATICLIB`
   pointing at `upstream/renderer/target/release/libshader.a`,
3. builds the two image/reload probes and every target in the script's
   `REGRESSION_BINARIES` registry,
4. runs the registered binaries, recording failures, timeouts and explicit skips,
5. renders every case twice through `offscreen_scene_probe` — once pooled, once
   isolated (`WE_TEST_NO_REUSE=1`) — and compares `frame-2` byte for byte,
6. scans both logs for `ERROR` diagnostics (ignoring shader-cache misses),
7. checks independent known-pixel assertions for the generated cases, so two
   equally blank or corrupt outputs cannot both pass,
8. runs `scene_reload_cycle_probe` over the selected projects twice each.

| Flag | Effect |
| --- | --- |
| `--skip-build` | Reuse the existing binaries instead of rebuilding |
| `--project PATH` | Add a local scene `project.json`; repeatable |
| `--assets PATH` | Shared assets directory (default `~/Library/Application Support/WallpaperMachine/SceneAssets`) |
| `--allow-missing-gpu` | CI fallback only: compile a Metal-device probe; its exact exit 77 skips the named GPU targets. Compile errors, abnormal exits and timeouts still fail. Default local runs require GPU checks. |
| `--allow-imprecise-timers` | CI fallback only: compile a timer probe that takes the median of 31 condition-variable waits of 10 ms; its exact exit 77 (median above 20 ms) skips the cadence tests named in `REALTIME_TESTS`. Compile errors, abnormal exits and timeouts still fail. Default local runs require every cadence test. |

Reports, SHA-256 hashes, logs, the generated synthetic fixtures and private GPU
output go under a fresh `artifacts/renderer/<run>/` directory, with
`report.json` as the summary; check binaries live in `artifacts/renderer/bin/`.
Imported wallpapers are read only. A nonzero exit means a test binary failed, a
pooled/isolated pair diverged, a generated case emitted diagnostics, or a
generated pixel assertion failed. `report.json` records
`full_compatibility_verified: false` on every case: there is no
authored-reference comparison, so rendering without a crash does not prove all
authored effects loaded.

Hosted CI may lack a Metal device. With the explicit fallback flag, the report
sets `gpu_checks_executed: false`, lists each skipped target (including the image
and reload probes), and emits a CI warning. CPU/capability tests still execute;
VideoToolbox-dependent tests report their own codec skips. A started test's
failure is never converted into a missing-device skip. A default local renderer
run remains necessary evidence for the GPU checks skipped by CI.

The generated matrix is twelve original synthetic scenes; it contains no workshop
identifiers and no workshop-specific rendering rules. Those scenes and their reload
checks use private synthetic compose-layer assets plus the probes' virtual assets, so
they run on a clean checkout without an installed wallpaper library. `--assets`
applies to additional `--project` inputs.

Test binaries run through macOS `taskpolicy` with application scheduling and
latency/throughput tiers of zero. Before exec, the single-threaded Python driver
clears inherited Darwin background policy on both the child process and its main
thread using `os.setpriority`; `taskpolicy` alone leaves that policy in place.
Only test children change priority, leaving the invoking agent and build tools
untouched. This keeps inherited background scheduling from governing real-time
assertions; it does not relax their thresholds or remove any tests. Contention
can still affect wall-clock performance checks.

Hosted macOS arm64 runners are virtual machines that deliver a 10 ms wait
50-100 ms late regardless of process policy: v1.2.4's release builds measured 11
ticks of a 10 ms cadence in 600 ms and about 10 frames a second at a 60 fps
ceiling, while a 600 ms sleep stayed accurate. The frame-clock, unchanged-present
and audio-expiry tests that count ticks against short waits cannot pass there.
With `--allow-imprecise-timers` the probe runs under the same test-child policy,
and only its exit 77 filters exactly those named tests out of their binaries with
`--gtest_filter`; every other test in those binaries still runs. The report sets
`realtime_checks_executed: false` and lists each filtered test with the measured
median under `skips`, each with a CI warning. A default local renderer run remains
necessary evidence for them. A new cadence test that fails only on hosted runners
belongs in `REALTIME_TESTS`; the harness tests check every name still exists.
`ThreadTimerTest.RequestsAfterALongWaitStillRespectTheCeiling` is included:
its 50 ms observation loop can overrun on a VM and count seven 10 ms ticks
against an assumed six-tick bound. The conditional skip requires the same
imprecise-timer probe result; ordinary local runs still execute the test.

## Probes

All probes are explicitly invoked executables, not ctest cases or UI tests.
`offscreen_scene_probe` creates a surface-free Vulkan device and private render
targets, uses the production shader passes and batching plan, and writes PPM
images under `WE_TEST_OUTPUT`. Use a disposable output/cache directory. The
device requests the same extension set as the wallpaper renderer, including
`VK_EXT_metal_objects` on Apple, so a scene whose textures are video streams
imports its frames here instead of rendering empty texture slots.

```sh
WE_TEST_PROJECT="$HOME/Library/Application Support/WallpaperMachine/Library/<id>/project.json" \
WE_TEST_ASSETS="$HOME/Library/Application Support/WallpaperMachine/SceneAssets" \
WE_TEST_OUTPUT="$PWD/artifacts/renderer/scratch" \
artifacts/renderer/bin/tests/offscreen_scene_probe
```

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_PROJECT` | `offscreen_scene_probe`, `text_object_runtime_test` | Path to a scene `project.json` |
| `WE_TEST_PROJECTS` | `scene_reload_cycle_probe` | `;`-separated project list |
| `WE_TEST_ASSETS` | probes | Shared `SceneAssets` directory |
| `WE_TEST_OUTPUT` | probes | Output/cache directory (disposable) |
| `WE_TEST_CACHE` | `text_object_runtime_test` | Disposable shader cache directory |
| `WE_TEST_CYCLES` | `scene_reload_cycle_probe` | Reload cycles per project |
| `WE_TEST_NO_REUSE=1` | `offscreen_scene_probe` | Isolated texture allocation (no pooling) |
| `WE_TEST_FRAMES` | `offscreen_scene_probe` | Number of sampled frames |
| `WE_TEST_METAL_FRAMES` | `metal_scene_draw_smoke` | Frames the local-project Metal test draws, 1/60 s apart: 120 by default, 2–3600 accepted. Its own knob, so the probe's `WE_TEST_FRAMES` in the same environment cannot move the Metal frame's scene time. The last frame is the output; the test also prints the bytes of this scene's render targets and, separately, the device-wide Metal allocation, which includes the layer's drawables and varies between runs |
| `WE_TEST_FRAME_STEP` | `offscreen_scene_probe` | Sampling interval, to look past an intro |
| `WE_TEST_DUMP_SOURCE=1` | `offscreen_scene_probe` | Write the packaged scene JSON beneath `WE_TEST_OUTPUT`; `nodes.txt` also records per-node visibility, translate and scale, which diffs layer placement between builds without comparing pixels |
| `WE_TEST_ASSET_PATH` | `offscreen_scene_probe` | Copy one asset from the mounted package to `asset.txt` under `WE_TEST_OUTPUT` for shader diagnosis; keep private asset output uncommitted |
| `WE_TEST_MEDIA_JSON` | `offscreen_scene_probe` | JSON array of synthetic media events dispatched to scene scripts; does not read system media |
| `WE_TEST_MEDIA_ARTWORK=1` | `offscreen_scene_probe` | Synthetic four-color 2x2 `$mediaThumbnail` texture; no player or audio device |
| `WE_TEST_DUMP_PASSES` | `offscreen_scene_probe` | Dump per-pass detail for the last sampled frame only: one image per custom pass, plus that pass's material slot, its live visibility and its full `constValues` appended to `passes.txt`. The prepare-time listing at the top of that file is a snapshot; only these `frame N` lines show what a sampled frame actually drew |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Flat JSON property overrides, in memory only. A layer gated on a saved property draws nothing without this, which is how both backends have to be driven to compare one |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks, no desktop input |
| `WE_TEST_CLICK_OFFSET` | `offscreen_scene_probe` | World-space `"dx dy"` added to the click layer's origin, to hit a covered or transparent texel instead of the centre |
| `WE_TEST_CLICK_VIEWPORT` | `offscreen_scene_probe` | `"<px_w>x<px_h>@<scale>:<fill\|fit\|stretch\|none>"`; maps the click the way a desktop does — the presented viewport is published and the cursor arrives window-normalized — instead of handing the runtime a world position, so hit testing is exercised against a real display's geometry |
| `WE_TEST_AUDIO_HZ` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Synthetic PCM at `0..6000` Hz; `0` means silence. The Metal gate submits one block per frame through the same analysis service the desktop tap feeds and enables audio response for the run. Band 0 of the 64-band spectrum covers roughly 0–94 Hz, so a shader reading only the lowest bands needs a bass tone, not 440 Hz |
| `WE_TEST_AUDIO_ENABLED=0` | `offscreen_scene_probe` | Exercise the disabled audio gate |
| `WE_TEST_MEDIA_EVENTS` | `offscreen_scene_probe` | JSON array of SceneScript media event objects, dispatched in order after the warm-up ticks. Enables media integration for the run, so a wallpaper that only draws its player while something is playing can be rendered without a system media source or Automation permission |
| `WE_TEST_MEDIA_ARTWORK` | `offscreen_scene_probe` | `<width>x<height>:<rrggbb>`; publishes one opaque cover through the same path the app uses, so `$mediaThumbnail` and `$mediaPreviousThumbnail` carry a colour that is legible in the rendered frame |
| `WE_TEST_RANDOM_SEED` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Seeds the particle random source before the scene is parsed, so the same project simulates the same particles on both renderers and their frames can be compared. The probe only steps the particle simulation when `WE_TEST_AUDIO_HZ` is set, and only advances time when `WE_TEST_FRAME_STEP` is |
| `WE_TEST_METAL_PROJECTS` | `metal_scene_draw_smoke` | Colon-separated `project.json` paths run through the production parser into the native backend offscreen. A fallback is printed with its reason and is not a failure; an accepted scene must prepare and draw every requested frame (120 by default). Frames after initialization are also summarised as render passes per frame (how many rendered into the scene's own image), blits per frame and thread CPU milliseconds per `drawFrame`. With `WE_TEST_OUTPUT` set, the last frame is written there. Unset, the test skips |
| `WE_TEST_DUMP_TARGETS` | `offscreen_scene_probe` | Colon-separated render target names, or `*` for every target the scene declares; the last frame of each is written as `target-<name>.ppm`. Same meaning as the Metal harness's own knob, so a target can be held against its counterpart on the other backend |
| `WE_TEST_DUMP_PASSES=1` | `offscreen_scene_probe` | Writes every pass's output on the last frame plus a `passes.txt` naming each pass's material, bound textures and folded constants. Note the image is the whole pooled allocation, which can be larger than the target, and the constants listed are the parse-time ones |
| `WE_TEST_MEDIA_ARTWORK`, `WE_TEST_MEDIA_EVENTS` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | The now-playing state the app would deliver. Both harnesses take them with the same meaning, so a wallpaper whose background is drawn from the current cover can be held against the other backend -- without one it renders flat grey on both and the comparison says nothing |
| `WE_TEST_DUMP_ALPHA=1` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Writes each dumped target's alpha channel separately as grey. Effects that weight by coverage -- the bokeh downsample divides by the sum of its taps' alpha -- make different colour from the same RGB when alpha differs |
| `WE_TEST_METAL_SURFACE` | `metal_scene_draw_smoke` | `<width>x<height>` for the surface the native backend rasterizes; defaults to `960x540`. Screen-space shader inputs follow it, so comparing this backend's output with another's is only meaningful when both rasterize the same extent |
| `WE_TEST_TEXTURE_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` opts into the production display-sized texture mip policy without changing raster extent; unset retains all source levels for before/after image and allocation comparisons. Native Metal uses its surface size automatically |
| `WE_TEST_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` physical output extent; defaults to `1920x1080`. Perspective scenes use it as their full-scale raster; authored 2D canvases keep their size |
| `WE_TEST_CAPTURE_LAST=1` | `offscreen_scene_probe` | Draw every requested frame but save only the last, for long intro and text-update checks without thousands of images |
| `WE_TEST_METAL_FRAME_STEP` | `metal_scene_draw_smoke` | Simulation delta in seconds; default `1/60`. Use `1/120` and twice as many frames for a matched-duration 120 FPS scenario |
| `WE_TEST_INPUT_JSON` | both scene probes | Ordered synthetic pointer events: `[{"frame":600,"layer":42,"inside":true,"buttons":1},{"frame":601,"buttons":0}]`. `layer` follows that parsed node's projected centre; `x`/`y` supply normalized coordinates instead. An exit uses `inside:false`. No desktop input |
| `WE_TEST_SAMPLE_FRAMES` | both scene probes | JSON array of frame indices. Saves each frame and `state-N.json` with live transforms, material values, text and script-error count |
| `WE_TEST_AUDIO_AMPLITUDE` / `WE_TEST_AUDIO_NOISE=1` | both scene probes | Amplitude `0..1` (default `.025`) and optional deterministic broadband PCM instead of a sine, with `WE_TEST_AUDIO_HZ` set. A single tone cannot exercise scripts averaging several frequency bands |
| `WE_TEST_SCENE_OPTIMIZATION=0` | `metal_scene_draw_smoke` | Turns static-result reuse off around the local-project loop, which is how a scene that looks wrong under it is compared with the same scene drawn every frame. Process-global, so it is restored afterwards |
| `WE_TEST_METAL_DUMP_TARGETS` | `metal_scene_draw_smoke` | Colon-separated render target names, or `*` for every target the scene declares. Each is reported with its size and mean luma and, with `WE_TEST_OUTPUT` set, written as a PPM. Target names carry a per-run suffix, so `*` is the only way to name one across two processes |
| `WE_TEST_EXPECT_WARM=1` | `text_object_runtime_test` | Assert zero shader compilations on a second run |
| `WE_TEST_VIDEO` | `playback_gpu_test --gtest_filter=AppleVideoFrame.LocalVideoImportsVisiblePixels` | Absolute local video path, opened read-only. Imports the first decoded frame into a private Metal texture and checks for visible pixels after releasing the decoder; select a clip with a non-black first frame. Unset skips this corpus diagnostic. No audio, window or desktop capture |
| `WE_TEST_DUMP_POSES=1` | `wpdump` | Dump sampled bone transforms |

Audio is submitted after GPU setup so shader compilation cannot expire its
live-input timeout. These options never initialize audio hardware. Keep all
probe output outside Git. If IDE ignore rules block reads under the repository's
ignored directories, write to a system temporary directory instead.

`offscreen_scene_probe` reports `startup parsed`, `prepared` and `first-frame`
timings. Use a fresh `WE_TEST_OUTPUT` for a cold shader-cache run and repeat the
same directory for a warm run. It resolves each project's entry/package version
and render dimensions and discovers text nodes instead of using fixed layer IDs.
It tests scene rendering only — not video or web projects, and not AppKit
presentation.

The probe keeps two clocks, and a frame's time is not `N * WE_TEST_FRAME_STEP`.
The runtime clock (timelines, camera shots, scripts) takes 40 warm-up ticks of
1/60 s before frame 0, then one `Tick(step)` before each frame, so frame N is at
about `0.667 + (N + 1) * step` seconds. The scene clock (`elapsingTime`: puppet
poses, shader `g_Time`, effects such as Earth's spin) skips the warm-up and
advances `step` after each frame, so frame N draws at `N * step`.
`metal_scene_draw_smoke` ticks and advances both clocks by 1/60 s for
`WE_TEST_METAL_FRAMES` frames (120 by default) and writes the last one at
(frames − 1)/60 s on both, 119/60 s by default. Comparing the two harnesses, or
one render with a crop of another, therefore needs matched scene time: the Vulkan
run with `WE_TEST_FRAMES=4` and `WE_TEST_FRAME_STEP=0.6611111` (119/180) draws
frame 3 at the default Metal frame's scene time. A puppet posed at a different scene time
reads as a camera or backend fault, and more than once did so here. Seed both
with the same `WE_TEST_RANDOM_SEED`.

`scene_reload_cycle_probe` parses every selected project twice in one process,
each parse on a fresh thread with fresh VFS mounts, the way a wallpaper switch
builds a new `SceneWallpaper`. It catches per-process state that survives a
scene teardown and stalls the next load; a stall is reported as a probe timeout.
It covers scene parsing and script compilation only, not presentation.

`playback_gpu_test` is Apple-only and requires real Metal/MoltenVK
capabilities. It uses private images and synthetic IOSurface-backed inputs and
creates no window, surface, swapchain, audio device, or screenshot. Missing
required GPU capabilities fail explicitly rather than skipping. Run the built
executable directly from the renderer check build directory.

### Metal compile across processes

macOS keeps compiled Metal code under
`$(getconf DARWIN_USER_CACHE_DIR)/<bundle id>/com.apple.metal/`, in a
`libraries*` pair (compiled Metal source) and a `functions*` pair (compiled
pipelines); the folder names above them differ by machine and macOS version. A
bare executable has no bundle id and uses `com.apple.metal/` directly under that
directory. Library entries are scoped by location — the bundle's path, or a bare
executable's folder — while pipeline entries are keyed by content and shared.
For measurements this means:

- A probe run twice from the same folder compiles once. A byte-identical copy
  in another folder compiles the Metal source again; renaming, re-signing,
  touching or replacing the binary in the same folder does not.
- To behave like the app, put the probe in a minimal bundle
  (`Contents/MacOS/<name>` plus an `Info.plist` with a scratch
  `CFBundleIdentifier`) so it gets a cache of its own. Never use
  `app.wallpapermachine`, and delete only a scratch identifier's folder.
- Measure per process, not per coalition: a probe started from a terminal
  shares the terminal's coalition. `proc_pid_rusage` with `RUSAGE_INFO_V6`
  (`ri_energy_nj`, CPU only) needs no privileges; read the probe's from its
  zombie before reaping it, and poll each `MTLCompilerService`, of which macOS
  starts one per client process.

Lucy (3521337568), `WE_TEST_FRAMES=1`, bundled probe, CPU energy of the probe
plus its `MTLCompilerService` (2026-10-10, M5 Pro, macOS 27.0.1, MoltenVK 1.4.2):

| Condition | Energy | Wall |
| --- | --- | --- |
| First load, every cache cold | 35.4 J (21.6 J compiler) | 5.6 s |
| Next process, same location | 2.0–2.2 J (none) | 0.7 s |
| Same location, new `LC_UUID`, new `CFBundleVersion` or bundle replaced | 2.0–2.1 J (none) | 0.8 s |
| Same bundle id, another location | 21.7 J (19.5 J compiler) | 4.1 s |
| Compiled source missing only | 21.8–22.1 J (19.5–19.8 J compiler) | 3.5–3.8 s |
| Compiled pipelines missing only | 4.1 J (1.9 J compiler) | 0.8–0.9 s |

Lucy's entries survived 16 other wallpapers compiled after it and a second
process holding the cache files while Lucy compiled; synthetic kernels survived
a holder killed with SIGKILL and 3,400 entries (about 45 MB) written by one
process. MoltenVK's
pipeline cache stores the Metal source it generated, not compiled code, and no
`MVK_CONFIG_*` setting adds a binary archive. A binary archive, on either
backend, would hold only the pipeline row's share.

## Regression areas that must stay covered

| Area | Coverage |
| --- | --- |
| Camera zoom | `scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'`. Scene `general.zoom` may contain an authored scalar animation, not just a fixed camera scale. |
| Camera layers in 2D scenes | `SceneSchema.CameraObjectKeepsAnOrthographicSceneOnItsCanvas` next to `SceneSchema.DefaultCameraObjectBecomesActivePerspective`, plus `SceneSchema.CameraObjectTimelineGlidesFromItsFirstShotToWhereItRests`, `.TheLastVisibleCameraObjectFramesTheCanvas` and `.AScriptedShotOriginFramesTheViewOnceATickHasAppliedIt`, in `scene_schema_tests`. A scene with `orthogonalprojection` is projected by that canvas; a `camera` layer in one must not become the active perspective camera, but it does frame the canvas. Its zoom narrows the view, its origin moves the view centre away from the canvas centre, a timeline plays both on one clock, and the last visible shot wins. The perspective camera follows it. A single-play timeline that has ended no longer asks for frames, and a script-bound origin frames the view only once a tick has applied it (see below). |
| Perspective camera shots and paths | `SceneSchema.PerspectiveCameraSelectionFollowsVisibilityWithoutHiddenOverrides`, `.PerspectiveCameraPathsSampleAndQueueAuthoredCurves` and `.RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup`. The last effectively visible shot for a camera owns its pose and FOV; hidden presets cannot reattach that shared camera. Selection follows runtime visibility, and no visible shot restores the editor pose. Packaged eye/center/up/FOV curves share the path clock, with sequential or random queuing and bounded catch-up. Only selected paths advance; hidden paths add no animation demand. Curves are parsed once, not per frame. Camera-path zoom, path events and camera-cut fades are not implemented. `.CameraPathsPreserveSteepAndRolledLookAtOrientation` checks reconstructed look-at vectors near vertical and Euler singularities; `.CameraPathsAndLayerTimelinesShareScaledAndZeroDeltas` checks the shared scaled Tick delta, and `.PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly` protects the editor-camera fallback against later shot registrations. |
| 3D model materials and skinning | `SceneSchema.ModelMaterialDefaultsAreOpaqueDepthTestedAndExplicitStateWins` and `.ModelBonesReachEveryMaterialIncludingTheBindPose`. Model materials default to normal blending, back-face culling and enabled depth test/write; explicit pass settings win, and image defaults are unchanged. Skeletal models share one existing `WPPuppetLayer` playback across material slots, attachments and runtime animation controls, including bind-pose uploads when no clip matches. No new render passes or texture allocations are introduced. |
| Layer textures tiled across models | `LayerTextureReference.CompositeAddressingFollowsTheSourceLayersClampUvs` in `layer_texture_reference_test`. `_rt_imageLayerComposite_<id>` repeats when the source layer says `"clampuvs": false` and clamps when it is true or absent. A model whose UVs run far outside 0..1 otherwise smeared the composite's edge texels into solid bands. |
| Alpha-to-coverage passes | `MetalBlend.*` in `metal_backend_test`; the compatibility backend sets the same state in `SetBlend`. Coverage decides what an `alphatocoverage` pass keeps and kept samples are written unblended, as in Direct3D. Blending as well multiplied partially covered texels by alpha a second time, which dimmed thin lines. Scenes stay single-sampled, so edges are thresholded rather than antialiased. |
| Random sprite-sheet frames | `ParticleMouseControlpoint.SpawnedParticlesCarryAStableFrameValueSpreadOverTheSheet` in `particle_mouse_controlpoint_test`. A `randomframe` particle keeps one frame for its life, derived from its spawn state rather than drawn from the random source, so seeded particle layouts do not shift. The previous integral value always selected frame 0. |
| Camera-object zoom in 2D scenes | `SceneSchema.CameraObjectZoomTightensTheOrthographicFrustum` and `.CameraObjectZoomThatIsNotPositiveFramesTheWholeCanvas` in `scene_schema_tests`, plus `MouseInput.HitTestingFollowsACameraObjectZoomAcrossAResize` in `mouse_input_test`. A shot that does not own the projection still frames it: `zoom` is applied when the ortho projection is built, not by writing camera width and height, because `ApplyCameraFillMode` rewrites those from the authored canvas whenever a fill mode is applied. Production applies one only after a `PROPERTY_FILLMODE` message, and the app sends none today; `metal_scene_draw_smoke` is the only caller. Pointer mapping reads `SceneCamera::VisibleWidth/VisibleHeight`, the same extent the projection uses — passing `Width()`/`Height()` leaves clicks and mouse-linked particles on the unzoomed image, right at the centre and wrong everywhere else. The authored extent the render targets are sized from must not move with it. |
| Camera parallax | `ShaderValueUpdaterCompat.CameraParallaxFollowsTheCursorAndDepthNotThePosition`, `.ZeroParallaxDelayFollowsTheCursorAtOnce` and `.ParallaxLayersAreReportedAsFollowingTheCursor` in `script_runtime_compat_test`, and `SceneSchema.ParserCopiesImageParallaxDepthToPuppetMaterialSlots` in `scene_schema_tests`. In a 2D scene parallax moves a layer by the cursor's offset from the view centre times the layer's `parallaxDepth`, scaled by `cameraparallaxamount` and `cameraparallaxmouseinfluence`. Where the layer sits, nested in a group or not, plays no part, so with the cursor centred every layer rests where it was authored. Adding the layer's distance from the camera, as an earlier revision did, pushed a depth-0.5 planet near the top of a 4K canvas out of the frame (Workshop 3521337568). 3D scenes keep that distance term, since no 3D parallax scene has been checked. A pass parallax moves is reported as following the cursor (`kParallax`), judged for the camera the pass draws through: static reuse redraws its target, and an on-demand scene wakes for the pointer. A layer drawn into a composite through its layer-local camera is not moved, so that composite stays reusable (`LayerTextureReference.AReferencedLayerIsItsCardWhereverTheSceneShowsIt`). What that costs, and the easing on-demand rendering misses, are under Known limitations. A `cameraparallaxdelay` of zero means no easing: the cursor is followed at once. Dividing by it made the eased cursor NaN, which reached every parallax layer's model matrix, and the scene drew only its clear colour on both backends. |
| User-chosen scene textures | `MediaThumbnailTextureSmoke.TextureProperty*`, `.UnsetTexturePropertyKeepsTheAuthoredTexture` and `.AnUnreadableUserFileKeepsTheAuthoredTexture` in `media_thumbnail_texture_smoke`; `TexSchema.AbsolutePath*`, `.PackagedLooseImageStillLoadsFromTheMount` and `.OnlyAReadableHostPictureCountsAsOne` plus `SceneSourceMount.APresetFileBesideThePackageLoadsAndThePackageStillWins` in `tex_schema_tests`. A `usertextures` entry is either a cover slot the runtime supplies or the name of a `scenetexture` property. The property stores a path, not a copy, so a slot is only replaced when that file opens now; unset, moved and unreadable all keep the authored texture. Origin travels on `LooseAssetCandidate`, never re-derived from the path: a mounted `/assets/materials/foo.png` is absolute too, and deciding by `is_absolute()` sends every packaged loose picture and video to the host filesystem, where none of them exist. A Workshop preset names its own pictures and videos relatively (`files/clip.mp4`) and ships them beside its base's `scene.pkg`, so `MountSceneSource` mounts the project folder under the package: packaged files still win, and the probes mount the same way. With only the package mounted those layers drew black and native Metal fell back. |
| Layer parents and scripted alpha | `ScriptRuntimeCompat.LayerGetParent*` and `.LayerAlpha*` in `script_runtime_compat_test`. `getParent()` is how an icon script reads its group; without it the whole `update` throws once a frame. `layer.alpha` has to reach `g_UserAlpha`, and only for layers whose authored alpha is not already owned by a timeline, an update script or a user property — two writers per frame fight. |
| Callback-only property scripts | `*CallbackOnly*` in `scene_schema_tests` and `script_runtime_compat_test` |
| Script property load order | `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue` in `script_runtime_compat_test`. As in Wallpaper Engine, a layer's saved and user-bound `scriptproperties` reach the script after its module has run: top-level code reads the defaults the script declares, `init` and `update` read the values. A switch that moves its layers by the difference from a top-level reading stayed where it was authored when the module already saw the user's position. |
| Module syntax in scene scripts | `ScriptRuntimeCompat.ExportFollowedByUnicodeWhitespaceStillCompiles`, `.AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty` and `ScriptModuleSyntax.*` in `script_runtime_compat_test`. `Scripting/ScriptModuleSyntax` is the one matcher for `export` and `export function update`: ECMAScript whitespace between the tokens counts, including the U+00A0 that text pasted from a rich-text editor carries and U+FEFF, which is not Unicode White_Space, and only where a statement can start, so `reexport` and `module.export` are not the keyword. Only the pure `ScriptModuleSyntax` test uses the rarer separators; the two that compile JavaScript through the linked QuickJS use U+00A0. The module rewrite and both update detections (`HasUpdateScript` in the parser, `wrap_script_if_needed` in the resolver) use it. The rewrite erases only the keyword, so a comment ending in the word keeps its line break. |
| Property-script feedback / hover easing | `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping` and `ScriptRuntimeCompat.PropertyFeedbackResumesFromExplicitUserValueChanges` in `script_runtime_compat_test` |
| Script-driven layer visibility | `SceneSchema.HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin` in `scene_schema_tests`. The authored `visible.value` is the script's initial value, never a permission to run it (see below). |
| Alignment anchors under dynamic transforms | `SceneSchema.ImageAlignmentAnchorSurvivesScriptedOriginAndScale` in `scene_schema_tests`, `ScriptRuntimeCompat.RotatedAnchoredLayerTurnsAboutItsAnchor` and `.ScriptedRingBarsHangOutwardFromTheirCircle` in `script_runtime_compat_test` (the anchor turns with the layer), plus `nodes.txt` translate diffs from `offscreen_scene_probe` |
| SceneScript writes from `update()` | `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined` in `script_runtime_compat_test`: a `thisLayer.visible = …` written during `update()` survives the next reevaluation even when `update()` returns nothing (see below). |
| Video-controlled visibility and music scripts | `scenescript_media_event_smoke`: `getVideoTexture().isPlaying()` reflects shared runtime pause/play state, so scripts that hide a layer during init can reveal it during update; `Vec*.mix` and `MediaPlaybackEvent` constants are available. |
| Legacy effect shader interfaces | Shader `pipeline` tests: array varyings reserve all element locations; unambiguous user function parameters narrow wider vector arguments; a whole vector variable assigned to a narrower one keeps its leading components (`pipeline_narrows_whole_vector_identifier_assigned_to_narrower_target`, the shipped `cloudmotion` effect's `v_NoiseCoord = v_TexCoord`); custom scalar/vector uniforms across stages share a vector block with stage-local prefix views. Engine `g_*` uniform type conflicts remain errors. |
| Matrix packing and live uniform updates | `ShaderValuePacking.*` and `ShaderValueUpdaterCompat.*` in `script_runtime_compat_test` cover column-major values, row-major/strided inputs, inline/dynamic/empty ownership and current camera/effect/material-slot values. `PlaybackGPU.FrameUpdatesAreVisibleBeforeUpload` checks updated color/geometry and hidden output on the real GPU. |
| Audio FIFO continuity and overflow | `audio_tests --gtest_filter='AudioResponseMonoTest.*'` includes `CompactedFifoPreservesEveryStereoWindow` (41 successive stereo windows, 9,024 accepted frames, 824 retained) and `OversizedStereoSubmitAnalyzesOnlyRetainedFrames` (waits for all 115 windows from each latest-24,000-frame input). The analysis cadence and spectrum tolerance stay unchanged. Run this target explicitly; it is not in `scripts/check_renderer.py`'s default target list. |
| Puppet animation layer control | `ScriptRuntimeCompat.PuppetAnimationLayer*` in `script_runtime_compat_test`: `getAnimationLayer(name).play()` restarts a finished single-shot layer on every copy of the shared state; a `visible` bound to a user property toggles the layer. |
| Cursor coverage masks | `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask` in `script_runtime_compat_test`: transparent texels of a cursor-scripted image layer do not hit. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises real assets. |
| Cursor hit testing under scaling | `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`, `MouseInput.LayerHitTestingFollowsWhereTheWallpaperIsPresented`, `MouseInput.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`, and `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper` (see below) |
| Mouse-linked particle control points | `ParticleMouseControlpoint.MouseControlpointFollowsTheCroppedPresentation` in `particle_mouse_controlpoint_test`, which `scripts/check_renderer.py` runs. A mouse trail reads the same scene coordinate the scripts do, through `Scene::pointerScenePosition`; `pointerPosition * ortho` is right only at the centre of the window (see below). |
| MDLS3 hierarchy/pivots | `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions` in `mdl_schema_tests`. Mesh format versions do not justify flattening an authored skeleton. |
| Large-scene first-frame startup | `offscreen_scene_probe` cold/warm startup timings; staging-buffer growth must stay geometric (see below) |
| JPEG/EXIF orientation | `tex_schema_tests`: all eight EXIF display transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated JPEG/EXIF data, invalid IFD offsets |
| Translucent coverage / alpha compositing | the `generated-alpha` case in `scripts/check_renderer.py` |
| Vector material constant timelines | `SceneSchema.*VectorTimeline*` and `SceneSchema.SharedVectorTimelineWrapsOnlyOnTheParentClock` in `scene_schema_tests`, `ScriptRuntimeCompat.VectorMaterialTimelineDrivesEveryComponentSeparately` and `ScriptRuntimeCompat.ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding` in `script_runtime_compat_test`, and the `generated-perspective-animation` case in `scripts/check_renderer.py` (see below) |
| Scripted vector material constants | `SceneSchema.ScriptedMaterialConstantsKeepTheComponentsTheShaderDeclares` in `scene_schema_tests`: a script that swaps a `vec2`'s components only produces the authored numbers when it is handed a vector (see below) |
| Timeline events | `ScriptRuntimeCompat.*Timeline*Event*`, `*Marker*`, `GlobalAnimationListenersRunOncePerMarkerWhateverIsBound`, `GlobalOnlyAnimationListenerSeesTheCurrentTickTime` and `SceneGetAnimationFindsATimelineOnAnotherLayer` in `script_runtime_compat_test`: crossing, `event.frame`, reverse travel and exact loop wraps, delivery after `init`, one global listener run per marker with zero and two bound scene scripts, a fresh host context for a global-only listener, and scene-wide `getAnimation` (see below) |
| Clock/text corruption | `render_target_lifetime_test`, `text_object_runtime_test`, `shader_cache_metadata_test` |
| Continuous-playback resource reuse | `playback_gpu_test` |
| Texture decode at preparation | `texture_prefetch_test` (CPU, in the gate): images handed over once under their own name, decoding plus untaken images held within the byte budget (an image larger than the budget alone), preparation never waiting on an image not yet admitted, a prefetch whose threads failed to start answering at once, a failed decode reported rather than retried, a throwing decoder left to the caller, and teardown joining running decodes and freeing every image. Startup timing and byte-identical output on a real scene come from `offscreen_scene_probe`, which prepares through the same prefetch (see [Startup and staging buffers](#startup-and-staging-buffers)). |
| Render-target reuse correctness | `static_subgraph_cache_test` (reuse verdicts, copy elision, alias resolution, and `OnlyWritersOfCacheableTargetsAreSampled`: both backends sample only the passes `Plan` reads, and an unsampled pass cannot change a verdict) and, on the native backend, `MetalSceneDraw.AnUnchangedTargetIsReusedAndProducesTheSamePixels` / `.TurningTheOptimisationOffDrawsEveryPassAgain` in `metal_scene_draw_smoke`. Reuse must be provable by readback, not by a counter alone: a skipped pass has to leave byte-identical pixels, and a changed input has to redraw. On Compatibility, `PlaybackGPU.APooledImageAnotherTargetStillDrawsIntoIsNeverPinned` in `playback_gpu_test`: a target whose pooled image it took from a key that released it is never pinned, because that key's prepared passes still draw into the image every frame; pinning it let a skipped layer read another layer's picture from the second frame on, which the pooled/isolated comparison in `check_renderer.py` shows as a divergence. |
| Render passes on the native backend | `MetalSceneDraw.LayersSharingATargetShareOneRenderPassAndHiddenLayersCostNone`: consecutive passes into one image share one render pass, a hidden layer starts none, a hidden card draws exactly what a dropped one does, and showing it changes the picture. A pass starts a new render pass only for another image, another depth attachment, a read of its own image, or a clear — unless the open render pass began with that same clear and has drawn nothing yet. A draw sharing a render pass sets every binding the previous draw may have left, nil included. On a real scene, `WE_TEST_METAL_PROJECTS` prints render passes and blits per frame and CPU per `drawFrame`, and its PPM must stay byte-identical to the pre-change build's. |
| Feedback copies on the native backend | `MetalSceneDraw.AFeedbackCopyTradesTexturesAndDrawsTheSamePicture`: two lenses that each sample `_rt_FullFrameBuffer` over a card, drawn with scene optimisation off (the graph's copies are made) and on (the image and its copy trade textures, and the reader's render pass opens with a texel-exact copy of the image as it stood). Every frame must be byte-identical across three frames — the trades carry over from frame to frame — with no blits when on. Removing the opening copy fails all three frames. The trade is planned only for a copy whose reader is the next pass to touch the image, draws into it without reading it, and loads it (or clears it, which needs no opening copy), with both textures private to one name, one size, `RGBA8Unorm`, one mip level, no depth and neither image reused; an abandoned frame undoes its trades. On a real scene, `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` makes the copies again, and the harness PPM must match either way. |
| Interleaved feedback-copy readers | `MetalSceneDraw.InterleavedFeedbackCopiesPreserveEachReadersImage`: `copy A→Ac`, unrelated B work, `copy B→Bc`, then B's reader before A's reader. Both target images must match the blit path over four frames, with both blits removed. Opening copies are retained separately by destination texture, not in one overwritable pending slot; graph release and abandoned frames clear that state. Reinstating single-slot overwrite semantics makes A's pixel comparison fail. |
| Sprite-sheet stepping and reuse | `MetalSceneDraw.ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges`. A sheet between frame changes may be reused, but its clock must keep running or the animation never reaches the next frame. |
| Per-frame geometry upload | `MetalSceneDraw.GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot`, across more frames than there are in-flight slots. Zero live particles must draw nothing rather than fail. |
| Native backend admission | `metal_backend_test`: every refused construct keeps its own distinct reason; plain sheets, sprite particles, sprite trails, thin and thick ropes, rope trails and a skinned mesh under a `g_Bones` shader are accepted by their actual layout; a sprite trail without velocity, a rope-marked sprite layout, a thin rope trail, a skinning shader on a mesh without bone weights and a bone stride that cannot hold a 4x4 matrix are refused; a puppet under an effect chain is judged by the chain's final mesh, and only on the chain's last node. An unused perspective camera does not reject; a supported layer that names a perspective camera, or an active perspective camera with supported layers, is accepted. |
| Perspective cameras on Metal | `MetalProjection.PerspectiveUsesFovAspectNearFarAndAHomogeneousDivide`, `.UnprojectingNdcHitsTheLayerPlane`, `.CameraAxesFollowTheAttachedNode` in `metal_backend_test`; `MetalSceneDraw.APerspectiveCameraDrawsThroughTheAuthoredShader` in `metal_scene_draw_smoke`. Projection is the scene camera's own FOV/aspect/near/far, not an orthographic scale; a rotated card must foreshorten. |
| Layer as texture | `layer_texture_reference_test` (CPU, in the gate): `_rt_imageLayerComposite_<id>[_a|_b]` forward refs, duplicate names, missing targets, cycles, history `_b`, file names vs layer names, invisible sources kept, producer-before-consumer graph order, and an effect-chain source linking from its composite rather than `_rt_default`. A composite is the source layer's card in its own texture space, whatever its placement, the scene camera or parallax do (`AReferencedLayerIsItsCardWhereverTheSceneShowsIt`). A compose layer's camera is not layer-local: its children keep their place inside it (`ComposeChildrenKeepTheirPlaceInsideTheLayer`), and a `composelayer` drawn into its own composite still samples the screen behind it (`ScriptRuntimeCompat.ComposeBackgroundUsesScreenCameraAndParentTransform`). A compose layer that only copies the background is skipped unless another layer samples it; then it is drawn into its composite and nowhere else, since its card covers its whole target (`ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`). A mask that paints that background back over later layers otherwise had nothing to sample, and native Metal fell back. A linked composite's size is never folded into the material as a zero at parse time: the card padding divided by it and every texture coordinate of the consumer's card became `NaN`. Nothing stale is folded in its place either, so the shader reads the target's real size whichever the backend uploads last, constants or live values (`AReferencedCompositeIsSampledAtItsRealSize` checks both orders). |
| Camera framing of fullscreen layers and reuse | `CameraFraming.AFullscreenLayerCoversTheScreenWhateverTheShot`, `.AFullscreenEffectCoversAPerspectiveScene` and `.MovingTheCameraChangesTheStaticSampleOfAPassItDraws` in `layer_texture_reference_test`. Fullscreen effects use the screen-space `fullscreen` camera in both 2D and 3D scenes. Every static pass sample folds in the pass camera and active camera through `vulkan::FoldPassCameras`, shared by both backends. |
| Rope and rope-trail geometry | `particle_rope_geometry_test` (CPU, in the gate): pieces per instance and never across instances, dead particles skipped and neighbours joined, subdivision through the particles, coincident points without `NaN`, the rope-trail head, tail shrink and per-slot separation, and the simulation's history — birth point, growth to capacity, zero time step, respawn reset. Index width: packed 16-bit up to 16 384 quads, 32-bit past that, overflow-safe capacity math, and draw order across instances on a 32-bit mesh. |
| Skinning on the native backend | `MetalSceneDraw.APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces`: a 64-byte reflected bone stride, the skinned quad translating by the distance its bone did with its width unchanged (what rules out a transposed matrix), the unskinned quad still, no reuse while the pose moves, `pause()` freezing and `play()` resuming. `.TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend` repeats the translation and draw with the author's `genericimage2`, and skips without the shipped shaders. |
| Trail and rope layouts on the native backend | `MetalSceneDraw.ARopeLayoutMeshReachesTheTarget`, `.ASpriteTrailMeshReachesTheTarget`, and `.TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively`, which runs the editor's own preview projects through the real parser and shaders and skips without the shipped assets. |
| Scene optimisation applied at runtime | `MetalSceneDraw.TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff` and `.AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn`. Turning the setting on must reach a graph that was compiled while it was off, on that graph's next frame, without reusing pixels no plan recorded. |
| Video consumption decided before import | `MetalVideoTexture.PlanesOnlyDemandEncodesNoConversion`, `.MixedDemandConvertsOnceAndStillPublishesThePlanes`, `.ADemandChangeReImportsTheSameGenerationInsteadOfWaiting`. A frame every consumer samples as planes must encode no conversion and allocate no destination; a mixed scene must convert exactly once. |
| Video pixel format decided per frame | `MetalVideoTexture.ABgraFrameIgnoresAPlaneDemand` and `.AFormatChangeSwitchesPathWithoutLosingTheTexture`. Software decode hands back BGRA and VideoToolbox hands back NV12 for the same file, either can take over mid-playback, and neither may reparse the scene or lose the picture. |
| Direct plane sampling, end to end | `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader` and `.AVideoLayerKeepsConvertingWhileTheSettingIsOff`: an ordinary parsed author material, a real decoded video, the variant compiled by the parser, bound through its own reflection and drawn. A test-only shader does not cover this. |
| Direct-versus-converted picture | `MetalSceneDraw.OneToOneSamplingProducesTheSamePictureOnBothPaths` (must agree to one code value) and `.ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies` (see [performance](../features/performance.md)). The paths are exactly equivalent at a one-to-one mapping; under resampling they differ only where the stream carries codes outside the range it declares, bounded by that clamp's own excursion. |
| Plane variant refusals | `video_planes.rs` in `crates/shader`: an explicit-LOD sample, a size query, and any other use of the video slot refuses the variant instead of mistranslating it, and the ordinary program is unchanged by the option existing. |
| Text layers on the native backend | `MetalSceneDraw.ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend`: a parsed text object, the text program translated to Metal, the rasterised glyphs imported and the card drawn into the scene's own target. A text layer must reach the backend through the ordinary parser, not through a hand-built mesh. |
| Unchanged text costs nothing | `MetalSceneDraw.TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`: twelve frames of an unchanged string measure nothing and upload nothing, a new string costs at most one upload per in-flight frame and reaches the drawn picture, and it then goes quiet again. The script keeps running throughout; "quiet" must never be achieved by stopping it. |
| Text layers under an effect chain | `MetalSceneDraw.ATextLayerWithAnEffectChainKeepsBothOfItsCards`: a text layer with effects has three meshes the relayout rewrites — its own card, the chain's final card and the node the chain resolves its last pass onto — and all of them have to be accepted and updated, or the scene falls back as a whole or freezes at its first layout. Use text whose glyphs differ, not more of the same word: the chain clips the card to its buffer, so a longer repetition can leave identical pixels. |
| Optional programs stay off the load path | `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader` asserts the parse compiled nothing optional before asking for it; `.AVideoLayerKeepsConvertingWhileTheSettingIsOff` asserts the program was never even claimed while the switch was off. Preparing an optional variant during a parse is a first-frame cost, not a free one. |
| Metal program reuse | `MetalSceneDraw.TheSameProgramIsCompiledOnceAndReusedByTheNextSurface`: a second renderer on the same device must not hand an identical translated program to the Metal compiler again. The pipeline key must identify the program by content, never by the address of the object holding it. |
| A scene with nothing left to do | `MetalSceneDraw.AStaticTextSceneRunsOutOfWorkToDo`, `.AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork` and `.TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous`: a static caption must reach zero demand reasons, having actually drawn, while the renderer still reports `EventMesh` and `RuntimeImage` — the reuse cache depends on both, and neither is a reason to keep the frame clock. Assert the reasons, not the frame rate. |
| Waking from idle, and not waking | `MetalSceneDraw.AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain` and `TextObjectRuntime.PreparedTextWakesWhoeverOwnsTheFrameClock`: a changed caption brings the demand back, reaches the output and goes quiet again; the text worker asks for the frame that shows its result, because a scene that has already idled has no clock to notice; and rewriting the same string wakes nothing. A wallpaper that idles and then misses an update is worse than one that never idles. |
| Content that must never be called still | `MetalSceneDraw.TextProducedByAScriptIsNeverCalledStill`: a caption computed every tick keeps the clock on every frame, whatever the script returns. No script source is read, no repeated result is counted and no schedule is inferred. |
| Geometry rewritten on an event | `SceneDemandMapping.GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing` in `static_subgraph_cache_test`: `EventMesh` and `DynamicMesh` must both cost a target its cacheability and must differ at the scene level. Collapsing them back into one bit either stops static text idling or idles a particle system. |
| Optional programs across launches | `MetalSceneDraw.AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch`: after the in-memory caches are cleared, the stored entry must reproduce the Metal source, the reflection *and* the per-stage binding plan without the compiler running; truncated entries must fall back to a normal compile. Restoring MSL alone is not a restored program. |
| Pipeline archive on the production path | `MetalSceneDraw.PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath`: pipelines are offered to the archive, published, reopened from disk and satisfied strictly, and a scene with no archive path still draws. A written archive that is never attached to a production descriptor proves nothing. |
| Download-speed sampling | `DownloadTelemetryTests` in `Tests/Unit/Workshop/`: real `nettop` streaming over a private PTY with local-socket traffic; CRLF and split line endings. LF-only fixtures do not verify live delivery. |
| Who owns the first frame | `MetalSceneDraw.ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone`: a backend must report presentation through `drawFrame`'s `presented` out-parameter and leave `Scene::first_frame_ok` to the frame handler. A backend that sets the flag satisfies the handler's own check before the handler runs, the host is never told the wallpaper started, and the startup deadline tears down a wallpaper that is drawing correctly. |
| Decoded frames carry real timestamps | `video_source_input_test` and `shared_video_session_test` against media the tests encode. A frame whose timestamp is always zero looks like playback for as long as frames keep arriving and then freezes, so a video regression here reads as "the picture stopped" rather than as a decode failure; the FFmpeg header/library check in `src/Video/FfmpegAbi.hpp` exists because the layout mismatch that produced it compiles cleanly. |
| One clock per shared decoder | `SharedVideoSessionTest.AFrameStaysValidAfterTheDecoderMovesOn` and `.PausingOneSurfaceLeavesTheOtherPlaying`: exactly one elected consumer moves a shared session's clock, so a test that advances the non-driving consumer observes nothing. Make the advancing consumer the driver rather than loosening the election. |
| Frames that would repeat the picture | `unchanged_present_test` (Compatibility, driven through `SceneWallpaper` on a `CAMetalLayer` no window owns, against media it encodes) and `MetalSceneDraw.AFrameThatWouldRepeatThePictureTakesNoDrawableAndPresentsNothing`. A plain video presents exactly its newly selected frames: submissions track `video_frames_selected`, every other tick is `presents_skipped_unchanged`, and `video_frames_skipped` and the selected rate match the run with scene optimisation off. The distinct video generations presented, with their PTS, form the same sequence with the skip on and off (`TheSkipPresentsTheSameVideoFramesInTheSameOrder`, observed through `RenderInitInfo::video_frame_presented`), and with the skip on no generation is presented twice after the start. A held frame submits nothing until a flip, a poster request, a resume, a scaling-factor (crop), render-scale, surface-resize or fill-mode change, each of which presents the held generation exactly once and then repeats again; a static scene submits nothing once every pass is reused, and the poster it then exports is byte-identical to the baseline's. Counters are compared within one draw at the window edges, never exactly. A change the comparison cannot see must invalidate the gate; do not widen the skip by comparing fewer inputs. |
| Direct presentation and reuse | A frame that drew straight into the drawable left the scene's output target unwritten, so the reuse record for it is dropped (`VulkanRender::drawFrameSwapchain`). Reusing it through the final blit would compose an image nobody drew. |
| Wallpaper sound output lifecycle | `audio_tests --gtest_filter='SoundOutputLifecycle*'` on miniaudio's null backend: the output device starts only with channels mounted, playing and unmuted; muted hosts (the lock-screen extension) never start it; positions stay frozen while paused or muted. `FfmpegSoundStreamTest.ResampledLoopingPcmMatchesBaseline` pins the resampled PCM bit for bit. Not in `scripts/check_renderer.py`'s default target list. |
| Audio capture follows what the scene reads | `SceneSchema.AudioRequirementComesOnlyFromContentThatReadsAudio` and `.AudioRequirementIsReportedOncePerSceneAndResetByReplacement` in `scene_schema_tests`, `VideoSourceInput.PlainVideoProjectNeverReportsAnAudioRequirement`, and the bridge tests `display_presentation::audio_response_alone_does_not_open_the_tap_for_a_scene_that_reads_no_audio`, `::replacing_an_audio_scene_with_one_that_reads_nothing_closes_the_tap` and `web_audio_media::a_web_listener_counts_beside_a_scene_that_reads_no_audio`. |
| Pointer-driven clock wakes | `FrameTimerTest.ABurstOfWakeOnceAtTheCeilingDoesNotAddCallbacks` and `.AnIdleBurstOfWakeOnceProducesOneCallback` in `timer_tests`. Two hundred `WakeOnce` calls in one second at 30 fps stay inside about one callback per period (20–40), and an idle burst produces one callback. The configured ceiling still produces frames. |
| Counter baseline | `PlaybackGPU.TurningCountersOnDoesNotReportWorkAlreadyDone`. A Compatibility video update that runs while counting is off does not read the decoder at all; the next counted update only records the decoder's totals and the frame on screen. Decode outputs, seeks, selected and skipped frames are then only what later counted updates observed, including after counting was turned off and on again. |
| Hidden particle geometry | `ParticleSystem::RebuildVisibleMeshes` runs after `Tick` and rebuilds a hidden subsystem on the frame it becomes visible or must produce. The simulation still runs while it is hidden. `ParticleHiddenGeometry.LayerShownByTickAfterEmittDrawsWhatAlwaysGeneratingDraws` shows a layer (or its parent) in the Tick after Emitt and compares the first visible frame's mesh bytes with an always-visible run; `particle_rope_geometry_test` and `particle_mouse_controlpoint_test` cover the geometry; a fixed-seed `offscreen_scene_probe` dump of a hidden-then-shown particle scene must stay byte-identical to the build that generated every frame. |
| Pointer sampling is event-armed | `api_smoke::mouse_polling_samples_only_when_input_arrives`, `::mouse_polling_stops_while_the_only_interactive_scene_is_suspended_on_its_display`, `::mouse_polling_in_a_monitor_gap_checks_the_cursor_without_engine_work` and `engine::snapshot::tests::a_paused_scene_is_not_a_pointer_consumer_and_its_resume_drops_paused_clicks`. A consumer with no input is never sampled; a paused scene is not a consumer. |
| A global resume keeps covered displays paused | `display_presentation::a_global_resume_never_restarts_a_display_that_is_still_covered`: the scene pause log must never show `paused=false` for a display that is still suspended. |
| A display refresh keeps an unchanged scene | `settings_intents::a_display_refresh_does_not_reload_a_scene_whose_audio_response_has_nothing_to_read`, `::a_display_refresh_does_not_reload_a_scene_held_to_the_battery_frame_rate`, `::a_display_refresh_does_not_reload_a_scene_muted_for_other_audio`, `::a_display_refresh_does_not_reload_a_scene_paused_by_a_lock_or_a_covered_display`, and `DisplayRefreshCoalescerTests` in `Tests/Unit/Desktop/`. A value applied live on top of the saved configuration must never read as a different wallpaper: every display change refreshes displays, and each mismatch reopened the scene behind a white placeholder layer and restarted its animation. |
| A screen change that moves nothing does no work | `DisplayRefreshCoalescerTests` (`testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotRefresh`, `testAnUnchangedBurstDuringARefreshEndsWithIt`, `testTwoReadingsOfTheSameDisplaysAreEqual`), `WallpaperSpaceMonitorTests.testOnlyAScreenChangeThatMovesADisplayRereadsTheSpaces` and `WallpaperPresentationPolicyTests.testOnlyAScreenChangeThatMovesAWorkingAreaIsEvaluated`. An XDR display posts a screen change for each frame of an EDR headroom ramp, 241 in two seconds. Each one ran a bridge refresh, republished every snapshot, re-synced the lock screen, pushed the whole control panel and asked the window server for the session's lock state twice: about 12 J per ramp with the panel open. A failed refresh is still retried on the next change. |
| The lock state is not asked per evaluation | `WallpaperPresentationPolicyTests.testTheLockStateIsAskedOnlyWhenItCanHaveChanged`, `.testASessionLockedBeforeStartIsSuspendedFromTheStart`, `.testWakingDisplaysAskForTheLockStateAgain`, `.testSwitchingUsersAsksForTheLockStateAgain` and `.testAMissedUnlockClearsAtTheNextEvaluation`. Every snapshot the engine applies runs the presentation policy, and `CGSessionCopyCurrentDictionary` is a synchronous window-server round trip (about 50 µs, blocked in `mach_msg`). It is asked again only at start, on a lock or unlock, on display wake, on a user switch and while the session counts as locked, so a missed unlock still clears at the next evaluation. |
| No folder probe per panel snapshot | `WorkshopDownloadIntentTests.testSceneAssetsAreFoundAgainOnlyOnRefresh`. Resolving `ClientPaths.assetsURL` probes up to four folders (about 120 µs) and was a third of building the page snapshot while a property slider was dragged. The folder is found with its readiness: at launch, after locating or installing assets, and when the panel becomes key; a refresh that finds nothing new wakes no observer. |
| Identical monitors keep their own wallpapers | `display_identity::*` in the bridge (`a_stale_block_for_one_identical_monitor_never_lands_on_the_other`, `display_sync_keeps_one_block_per_display_under_its_current_selector`, `a_disconnected_display_keeps_only_its_first_block`, `identical_monitors_keep_their_own_wallpapers_across_renumbering`) and `display::tests::identical_models_sharing_a_unit_number_do_not_match` in core. They replay issue #33's four displays, two of one vendor and model, without the hardware. macOS renumbers displays and renames identical models across reboots and reconnects; a unit number must never pair two displays whose UUIDs or serials differ, display sync must keep one `[[monitors]]` block per display under its current selector, and a panel display id from before a renumbering must still edit that display. |
| A reconcile keeps an unchanged scene | `settings_intents::a_reconcile_does_not_reload_a_scene_held_to_the_frame_rate_cap`, `::a_reconcile_does_not_reload_a_scene_muted_for_other_audio` and `performance_settings::wallpapers_applied_under_a_frame_rate_cap_start_at_the_capped_rate`. A reconcile hands the engine every configured scene and the engine reopens any whose descriptor differs from the one it runs, so the descriptor carries the live frame-rate ceiling and mute. It is also what holds a scene opened under a cap to that cap: nothing lowers the rate after the reconcile. |
| Snapshots do not wait on the service manager | `login::tests::a_burst_of_snapshots_asks_the_service_manager_once`, `::a_change_made_in_system_settings_shows_once_the_last_read_has_aged` and `::a_change_made_in_the_app_shows_at_once`. Every snapshot carries the launch-at-login status; reading it from `SMAppService` for each one held a burst of queued bridge requests, Apply and Quit among them, behind hundreds of service-manager round trips. |
| The lock screen ignores the covered desktop | `apply_options::lock_screen_export_ignores_the_desktop_display_being_covered`: locking covers the desktop and suspends its display, and the exported lock-screen scene must stay unpaused unless the user or power policy paused playback. |
| Scene commits in headless tests | `scene_schema_tests` helpers wait for posted work with a render-looper round trip (`beginSurfaceReconfigure`) and a main-looper one (installing a pointer callback replays from the main looper) before `shutdown()`, which stops the loopers without draining them. A test that posts a scene and shuts down at once measures a race. A graph that never reached a backend is simply dropped by the next scene. |

### Where the cursor is, in scene coordinates

There is one answer and it belongs to the presentation.
`SceneRuntimeContext::SetCursorInput` maps window-normalized input through the
cursor viewport the renderer publishes — `origin + (x, 1 - y) * size` — and now
also writes it to `Scene::pointerScenePosition` so consumers outside the script
runtime read the same point instead of deriving their own.

A particle system's mouse-linked control point derived its own, as
`pointerPosition * ortho`. That is the canvas, not the window. A 2560x1440
wallpaper filling a 4112x2658 display is cropped to the canvas range
[166.3, 2394.2]; stretching the pointer over [0, 2560] instead agrees with the
cursor exactly at the centre of the window and is wrong by 165.8 scene units —
about 306 physical pixels, 7.4% of the width — at either edge. Reported as a
mouse trail that tracks in the middle of the screen and slides away toward the
sides, on every wallpaper with a trail, not one. Under `fit` the same error is
vertical instead: that display letterboxes to [-107.1, 1547.7].

The numbers above come from `offscreen_scene_probe` with
`WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill`, which prints the mapping the
running wallpaper would use. Nothing exercises `SceneWallpaper`'s own message
loop offscreen, so the host's half of the chain — polling the pointer and
publishing the viewport — is still only covered by `mouse_input_test` at the
unit level.

### Parallax inheritance

Parented layers take the outermost parent's `parallaxDepth`, including a zero or
omitted depth, rather than adding or retaining their own stale child values.
`ResolveLayerParallax` resolves this once during scene parsing, independent of
declaration order, before image, puppet-slot, text and particle materials are
built. The existing layer-local/effect-camera exclusions and cursor-driven reuse
classification remain in force; there is no per-frame ancestor traversal, extra
pass or texture. Missing/ambiguous parents do not supply a depth, and cycles are
left unresolved. IDs and parent references must be integers within the signed
32-bit range; wider signed/unsigned JSON numbers are ignored rather than
truncated into another layer's identity. Wallpaper Engine's [release notes](https://steamcommunity.com/app/431960/allnews/)
confirm that the parent controls parallax on child layers.

`SceneSchema.ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder`
covers nesting, zero/default depth, missing/duplicate parents and cycles;
`SceneSchema.ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers`
and `.ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds` cover
range checks for both fields and preserve valid boundary values;
`SceneSchema.ParentedPuppetSlotsFollowTheRootDepthAndKeepTheirLocalTransforms`
checks both material slots and cursor reversal through the parsed scene.
`MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses` checks
known pixels for direct and effect-chain cards across moving and repeated frames.
The shared probe's `WE_TEST_INPUT_JSON` feeds both runtime cursor events and
shader/particle pointer inputs, without reading or moving the desktop pointer.

### Camera layers in 2D scenes

`orthogonalprojection` decides what a scene is. When it is present the scene is
projected by that canvas: `ParseCamera` makes `cameras["global"]` the active
orthographic camera at the canvas centre, and every 2D layer's card size,
`origin` and `alignment` is authored in that space. When it is null the scene is
projected by a camera, and a `camera` layer is the shot that camera plays.

`ParseCameraObj` used to apply the second reading to both. A visible layer with
`"camera": "default"` attached its node to `global_perspective`, forced that
camera's FOV to the layer's own and made it active — so a 2D wallpaper was
suddenly viewed through a perspective camera standing wherever the shot was
authored. The usual authored pose is a few hundred units off the canvas plane at
fov 50, which frames a few hundred units of a canvas thousands of units wide:
one magnified sliver of a corner, `general.clearcolor` everywhere else. Layers
with an effect chain render through their own effect camera and were unaffected,
which is why the symptom reads as "most of the wallpaper is missing" rather than
as a camera bug. Workshop 3605722997 and 3292361861 are both scenes of that
shape.

So in an orthographic scene the shot layer is parsed, registered and bound like
any other node — scripts can still read and move it — but it does not touch
`scene.activeCamera`. Scenes with `orthogonalprojection: null` keep the old
behaviour exactly, which is what `SceneSchema.DefaultCameraObjectBecomesActivePerspective`
holds down.

Perspective shots with an omitted or nonpositive `fov` inherit the scene's
resolved FOV (`perspectiveoverridefov`, then `fov`, then 50). A positive shot
FOV still overrides it. Resolve this from authored scene settings, not a shared
camera whose FOV an earlier visible shot may already have changed. Newly named
cameras, runtime shot selection and non-runtime playback use the same resolved
value, including the named camera's saved fallback.
`SceneSchema.PerspectiveShotsInheritSceneFovUnlessExplicitlyOverridden` covers
named/default cameras, both playback paths, scene overrides and visibility
fallback after an earlier shot used a different FOV.

The shot still frames the canvas it does not own. `ParseCameraObj` registers
every shot with `SceneRuntimeContext::RegisterCameraShot`. At the end of each
tick, after scripts and every visibility and origin writer,
`ApplyCameraShots` passes the last visible shot, in authored order, to
`Scene::FrameCanvas`. Its `zoom` narrows the orthographic view about the view
centre, and its origin `x`/`y` is that centre's offset from the canvas centre.
The perspective camera keeps its distance but takes the same centre, and a
field of view that spans the same visible height, so perspective layers and
particles are framed the same way. With no visible shot, the whole canvas is
shown. Nothing is reframed while the zoom and offset stay the same.

The offset reading comes from the wallpapers. In 3605722997 the default shot is
`0 0 5` at zoom 1 and shows the whole canvas, and the close-up `5.5 344.2` at
zoom 2.87 frames the character's face; read as a canvas coordinate, both would
be centred on the bottom-left corner. The custom lens in 3605722997 and the only
shot in 3292361861 set the origin by script to `slider * engine.canvasSize`, with
sliders from -1 to 1 that default to 0 (the `scriptproperties` bind `user`
properties, so 3292361861's in-script default of 0.5 is never read). The default
is therefore the whole canvas, and a slider pans it. The editor's static `value` next to such
a script (3292361861's `2434 725`) is never drawn. The shot registers its origin
as pending until the first tick, and the view stays on the canvas centre until
then. The app ticks before every draw, and a tick applies scripted origins before
it frames the view. At defaults 3292361861 frames the same view as before this
change; 3605722997's preview is a zoomed crop taken with non-default settings,
so it cannot be matched without guessing the author's property values.
3521337568's intro keys `zoom` from 3 to 1 and a relative origin from
`+159.2/+1.6` to `+244.7/−1468.7` on one 12 fps playhead (`options.parent`),
which ends at offset zero: the whole canvas the wallpaper's preview shows. A
relative origin curve offsets the authored origin, and zoom and origin keyed
together share the zoom's clock. The intro's opening framing has no reference;
only where it ends is checked against the preview. Once a single-play timeline
has ended it no longer counts as animation demand, so an otherwise still scene
can go idle after its intro.

Framing the view moves no node and rebuilds no graph, so three things that
used to depend on the view being the whole canvas no longer do. In a 2D scene a
fullscreen layer's last pass is drawn through the `fullscreen` camera, which
always frames the canvas. A layer another layer samples as
`_rt_imageLayerComposite_<id>` is drawn into that target through a layer-local
camera (`LayerCompositeCameraKey`) that spans the card and ignores the layer's
placement, the view and parallax. Compose cameras are not layer-local, because
a compose layer's children draw through them at their place inside it. The
static-result cache folds each pass's camera and the active camera into its
sample (`vulkan::FoldPassCameras`, shared by both backends).

### Property bindings and alignment anchors

`createScriptProperties().addColor(...)` exposes a `Vec3` even when the
author's saved `scriptproperties` stores RGB as a space-separated string.
Conversion applies again when native property updates replace that value;
`addText` values remain strings. The regression is
`ScriptRuntimeCompat.AuthoredColorPropertiesStayVectorsAcrossTicksAndPropertyChanges`
in `script_runtime_compat_test`. A missing conversion silently turned Live
Solar System's sun tint black despite its nonzero brightness.

Duplicate non-text layer names retain separate internal binding keys. SceneScript
name lookup selects the first declaration in authored order, including
lookups made while a script module initializes; each layer's `thisLayer` still
addresses its own key. `SceneSchema.DuplicateNamesResolveInAuthoredOrderWithoutSharingThisLayerBindings`
in `scene_schema_tests` covers mixed image/group order and independent writes.
The alias-registration pass skips non-object entries, non-string names and
nonnumeric IDs while retaining defaults for missing fields;
`SceneSchema.DuplicateLayerAliasesIgnoreMalformedEntriesAndKeepValidLookup`
keeps valid aliases and their script updates working beside such entries.
Dropping the public lookup altogether left a dwarf planet at its authored
scale instead of the simulation's tiny scale, producing a large foreground
surface. These two regressions require the named CMake test binaries in
addition to `scripts/check_renderer.py`.

A layer setting may carry `value`, `user` and `script` at once. `value` is the
initial value the property script receives; it does not decide whether the
script runs. The parser used to drop every dynamic binding of a layer whose
`visible` setting combined a script with a falsy `value`, which froze
day/night/weather switchers and any other layer authored hidden at rest — the
scene then rendered nothing but `general.clearcolor`. Scripts are now always
bound; `PropertyScriptProgram::Evaluate` already keeps the current value when a
script throws, returns `undefined`, or returns an object for a boolean, so a
hidden helper layer cannot be revealed by accident.

Alignment is an anchor, not a one-off offset. `SceneRuntimeContext` owns the
anchor for image and text layers and re-derives `origin + size * scale * 0.5`
for the named edges whenever the origin, scale, size or rotation changes. Baking
the offset into the node translate loses it as soon as a scripted or user-bound
origin writes the translate, and ignores scale. Center-aligned image layers
carry no offset and keep the direct path. An alignment a script sets on a layer
that had none (`bar.alignment = 'top'` on a centre-aligned bar) offsets by the
scale delta, `size * (scale - 1) * 0.5`, so the unscaled layer stays where it
was authored and grows away from that edge. Wallpaper Engine's SceneScript
reference does not document `alignment`, so this rule is the renderer's own
convention; on the 8-unit bars seen so far it differs from a full offset by
4 units, too little to settle against a Workshop preview.

The anchor is the layer's pivot in its own axes. The offset is turned by the
node's rotation, in the x, y, z order `SceneNode::GetLocalTrans` applies, so a
turned layer keeps its named edge on the origin; perspective layers turned
about x or y keep it there in 3D. Every rotation write re-derives the anchor:
`SetNodeRotation` (`layer.angles`), `RegisterNodeRotation`, and the bound-angles
pass of `Tick`, which runs after the translate pass and so would otherwise leave
a frame placed for the previous angle. Unrotated layers go through the same
arithmetic as before, bit for bit. `ScriptRuntimeCompat.RotatedAnchoredLayerTurnsAboutItsAnchor`
and `.ScriptedRingBarsHangOutwardFromTheirCircle` in `script_runtime_compat_test`
cover z and x/y/z turns, a bound rotation within one tick, an exact return to
the unrotated placement, and the scripted ring. With the offset left on the
scene's axes, every bar of Workshop 2850003448's ring visualizer slid the same
way down the screen, over the planet it should surround, instead of hanging
outward from the circle; 'bottom'-aligned clock hands turned about their centre.

The anchor origin must survive re-registration. `RegisterNodeVisibility`,
`RegisterNodeTranslate`, `RegisterNodeScale` and `RegisterNodeRotation` each
call `RegisterNode` again for the same node, and `RegisterNode` seeds the anchor
from `node->Translate()`. Once an anchor is registered that translate already
contains the offset, so re-seeding it makes the next `ApplyNodeTransform` add a
second offset — visible only on layers whose scale or origin is dynamic, which
is why a static-origin/scripted-scale case is part of the regression test.
`RegisterNode` therefore re-seeds only when the bound node changes or no anchor
is registered yet, and `SetNodeAlignment` keeps the existing anchor mode instead
of forcing `size_anchor = false` on an already-anchored node.

### Native writes from scripts, puppet layers and cursor coverage

"Keep the current value when `update()` returns `undefined`" only works if the
current value includes what the script wrote. `ScriptedDynamicValue` used to
feed a private copy of the authored base value into `update(value)`; native
writes such as `thisLayer.visible = …`, `origin`, `scale` and `angles` arrive
through the typed `DynamicValue::update` overloads and never reached that
copy, so the authored `false` reverted the write on the next tick. Evaluation
now continues from the live dynamic value itself (see the property-feedback
entry above). The workshop "video texture controls" script (hide in `init()`,
`thisLayer.visible = alpha != 0` in `update()`, no return) is the canonical
victim: a layer authored `visible: false` never appeared.

Puppet animation layers are one shared playback state per image object
(`WPPuppetLayer` copies share it), registered with the runtime under the layer
name. `thisLayer.getAnimationLayer(name)` is backed by
`SceneRuntimeContext::PuppetAnimationControl`; it used to be a no-op stub, so
click-triggered puppet gestures never played. Authored layers start playing; a
single-shot layer holds its last frame and reports stopped, and `play()`
restarts it. `animationlayers[].visible/rate/blend` bound to user properties
follow the property like any other setting.

Cursor hit tests run in the layer's local plane (rotated and flipped buttons
keep their rectangle) and, for image layers whose scripts handle cursor events,
consult a coverage mask sampled from the albedo texture at parse time
(RGBA8/BC2/BC3, ≤256 texels per side, alpha ≥ 16 counts as covered). Two
interlocking triangle buttons whose rectangles overlap no longer fire together.
Puppets, videos, sprite sheets and opaque formats keep the rectangle test.

### Startup and staging buffers

`SceneSurface.DeferredBackendRetainsTheLayerUntilTheSceneIsDeleted` in
`playback_gpu_test` checks that deferred backend selection keeps its
`CAMetalLayer` alive after the host releases it, then releases it with the scene.
It uses no window or GPU backend and flushes Core Animation's implicit
transaction so that the transaction cannot mask missing scene ownership.

Quadratic staging-buffer growth caused the original Sparkle apply timeout: each
fixed-size extension zeroed a temporary CPU vector and copied the entire
previous allocation twice. Geometric blocks plus direct replacement-buffer
copying preserve existing offsets and data without that repeated work. A cold
MoltenVK pipeline compile for a large scene still takes longer than 20 seconds.
Workshop `3588579284` reached its first frame in 25.1 seconds with a warm
shader cache, and 24.4 seconds on the next launch after the driver pipeline
cache had been written beside that scene's shader cache, so the cache does
not remove the wait. The apply wait is 90 seconds. Rollback after the wait is
unchanged. It waits only on displays where the engine opens or replaces a
scene, judged against the engine's live display snapshot: a display refresh
moves and resizes scenes in place without the facade, and such a scene keeps
its renderer, which announces its first frame once. Comparing against the
descriptors the facade last handed over made the next Apply wait out the 90
seconds and roll back a playing wallpaper (issue #30;
`engine::facade::first_frame_tests`).

Texture decode was the other serial startup cost. `CustomShaderPass::prepare`
decoded an image again for every pass that bound it, only for `CreateTex` to
return the cached upload; it now asks `TextureCache::FindTex` first.
`TexturePrefetch` decodes the images unprepared passes will parse on up to six
threads, ahead of the pass that binds them, with decoding and untaken images
held under a 256 MiB budget estimated from each header and admitted in request
order. Preparation decodes an image itself rather than wait on one not yet
admitted. A private 943 MB puppet scene with 122 embedded PNGs (1264 Mpx) went
from 15.6 to 3.6 seconds to its first `offscreen_scene_probe` frame with a warm
shader cache, with a byte-identical frame and about 0.3 GB higher peak RSS.
It contributes to lock-screen admission latency: the extension answers
WallpaperAgent only after a first frame (see [lock screen](../features/lock-screen.md)).

### Alpha compositing

`SetBlend` used `VK_BLEND_FACTOR_SRC_ALPHA` for both the color and the alpha
factor of `BlendMode::Translucent`, so every translucent draw wrote
`As*As + Ad*(1-As)` instead of source-over's `As + Ad*(1-As)`. Partially covered
texels lost coverage on each composite and nested compose layers multiplied the
loss, which showed up as a thin saturated line along soft anti-aliased seams.
Color factors are unchanged, so opaque and fully transparent texels render
exactly as before. The `generated-alpha` case composites a half-covered source
over transparent, half-covered and opaque destinations inside a compose layer
and samples the composed alpha back as RGB: expected readback is 128/191/255,
and the pre-fix binary produces 64/96/191. It uses synthetic shaders only.

Alpha-to-coverage writes surviving samples unblended **only on multisampled
attachments**. On single-sample targets both backends disable coverage and use
source-over blending instead; otherwise transparent or partially covered pixels
can become opaque. `generated-alpha-single-sample` verifies composed coverage
on Compatibility (128/191/255), and
`MetalSceneDraw.SingleSampleAlphaCoveragePreservesTransparentAndPartialPixels`
checks zero, half, and full coverage as RGB on Native Metal across repeated
frames. The new Compatibility fixture fails against the prior renderer binary.
CPU blend-state tests also retain the unblended multisample contract. This adds
no MSAA targets, render passes, or allocations.

### Vector material constant timelines

`RegisterMaterialConstants` only resolved an animation when a constant had
exactly one component, and `ResolveScalarAnimation` only read `c0`. A `vec2`
book-page corner therefore lost its authored `c0`/`c1` curves, the group of
corners an author drives from one timeline through `options.parent.key` lost
that relation, and no `ScalarAnimationPlayback` was registered at all — so the
layer's own `thisObject.getAnimation(name).play()` found nothing to play.

On the local "猫猫的耳朵可以摸吗？" package that is the whole page-turn
interaction. Clicking `page首` runs the `cursorClick` export on its perspective
`point1` constant, which sets `thisLayer.visible = true` and plays the `900`
timeline. Without a registered timeline the page appeared with its corners
frozen, and the four homogeneous `w` terms of the authored `squareToQuad` were
`[1, 0.333, -0.819, -0.152]`: two corners behind the projection plane invert
the quad into a white spike that shoots off the top of the screen. With the
curves resolved the same corners measure `[1, 1.025, 1.069, 1.044]` on the
paused first key, `[1, 0.977, 0.965, 0.988]` mid-fold and `[1, 0.825, 0.469,
0.644]` on the authored last key — a valid quad for the whole fold.

Each component now resolves its own curve (`c0`–`c3`) and its own entry of the
initial value, and unanimated components keep that value. The constants of one
material pass are collected first, `options.parent.key` is walked to its root
with memoized results, and the whole group shares the root's single
`ScalarAnimationPlayback` — so `thisLayer.getAnimation(name)` still drives it,
and looping and restarting happen once, on the root. The sampled component
copies are single-shot, so a short child curve holds its last key instead of
wrapping on its own length. A missing parent, a parent without a usable
animation, or a cycle logs once and freezes that group on frame 0; relations
never cross material passes, so a corner of the same name elsewhere is a
different parameter.

The `generated-perspective-animation` case draws an original four-corner
homography mask whose third corner is animated from a paused parent timeline.
With the authored first key the page covers the centre and the margin stays
clear; with the static corner the page disappears and a wedge covers the
top-left margin instead. Both readings are asserted, so a blank frame and an
all-white frame fail too.

### Scripted material constants keep their component count

`MakeMaterialConstantDynamicValue` only treated a constant as a vector at three
or more components; everything else reached its property script through
`ResolveStringSetting`. A `vec2` corner was therefore handed to the script as
the text `[0.79139,0.44186]`, so `value.x` was `undefined` and the handler
returned `NaN`. On the local package that produced `g_Point2=[nan,nan,0]` on the
visible `workshop/2872021376/effects/perspective` pass of layer 503
`中-菜单-浮动`, and `g_Point1=[0]` — one component, parsed off a string that
starts with `[` — on the page-fold pass. Constants now resolve at the authored
component count: one component as a float, two and four through
`ResolveVectorSetting`, three unchanged through `ResolveVec3Setting`. A constant
with no authored value has no count to preserve and still resolves as a string.

### Timeline events

`options.events` is parsed into `ScalarAnimation::events`, and
`ScalarAnimationPlayback::Advance` queues every marker the playhead crosses as a
whole `ScalarAnimationEvent` — the authored `AnimationEvent` carries `frame`
beside `name`. Departure is exclusive and arrival inclusive, in both directions.
A loop runs on a circle, so the distance to each marker is measured along the
direction of travel: that makes a wrap, an exact landing on the seam and a
marker authored at the period the same point, and it keeps reverse travel
symmetric. Travelling at least a whole period reports each marker once rather
than once per lap, so a stalled frame cannot flood the queue. Markers arrive in
the order the playhead met them. Seeking is an explicit jump, not playback, so
`SetFrame` reports nothing.

`SceneRuntimeContext::Tick` drains the queue after advancing the clocks *and*
re-evaluating the scripted values, because a property script initializes lazily
on its first evaluation and a marker crossed by the very first tick must still
reach an initialized handler. Each queued marker calls the `animationEvent`
export on the property scripts and scene scripts bound to that timeline's layer.
The `engine.on`/`scene.on` list is global to the shared context, so the runtime
runs it once per marker instead of once per matching program — otherwise two
bound scene scripts would repeat every listener and none would silence them.
That runner also refreshes the `engine` object itself, because a global listener
can be a marker's only consumer and nothing else would have updated
`engine.runtime`/`engine.frametime` before it runs.
Handlers routinely create, hide or destroy layers, so every crossed marker is
collected before any handler runs and the script lists are re-checked while
dispatching.

`scene.getAnimation(name)` was missing: `getAnimation` existed only on the layer
object, so the authored `thisScene.getAnimation('111').play()` threw
`TypeError: not a function`. A null layer argument to `__animationControl` now
means "match this name across every registered timeline"
(`SceneRuntimeContext::FindAnimationByName`).

Together these complete the local package's two-phase page turn. Clicking
`page首` plays `900`; at frame 30 `houye` swaps the layers — `page首` goes
`visible=0`, `page` goes `visible=1` — and starts `111` on `page`; at frame 45
that second fold is mid-flight with its own corners moving; at frame 60 `yeshu`
hides `page` and the book is back at rest. The probe logs no `animationEvent`
errors, and the thin white sliver that used to be left at the page edge is gone.

### Cursor coordinates and presentation

Scene coordinates reach the window through two transforms: the global camera
rectangle fills the default render target, and `ComputeWallpaperScalingLayout`
places that target in the window, which `FILL` deliberately pushes outside the
window to crop. Cursor input arrives as a window fraction, so it has to be
mapped back through both (`ComputeWallpaperCursorMapping` →
`SceneRuntimeContext::SetCursorViewport`). Mapping it onto the raw canvas
instead only matches when the scene and the display share an aspect ratio;
otherwise every `cursorEnter`/`cursorLeave` box is squeezed toward the screen
centre. On the 7680×2160 local scene at the recorded 4112×2658 output, a
275-unit text layer answered the cursor across only about 4% of the window
width while it was drawn across about 9%, so hovering the ends of the text did
nothing.

The mapping also reports the drawn content rectangle. Coordinates keep
extrapolating past it — scripts read positions outside the canvas — but named
layers only take cursor events while the cursor is inside it. Without that,
`FIT` and scaled-down wallpapers would let letterbox bars trigger any layer
whose box crosses the canvas edge.

`engine.screenResolution` is a different quantity and has its own setter.
`SceneWallpaper::publishScreenResolution` reports the display's pixels on scene
attach and again whenever the surface is replaced. `RenderInitInfo::width`/
`height` already are those pixels — the host fills them from `DisplayDesc`, and
both backends divide by `display_scale_factor` when they want logical points —
so scaling them again would publish twice the resolution on every Retina panel. It used to be whatever the cursor mapping
published, which is the region of the scene's own world the window shows, so a
script sizing itself against the screen read the author's canvas back instead.
The rasterization size is not it either: internal quality may halve that, and a
quality setting must not move a script's layout.

### Text, fonts and clocks

Font decoding prefers valid authored bytes, then a usable installed family, then
a platform fallback; missing paths and malformed embedded fonts use the same
fallback for both measurement and rasterization. Coverage spans seven font
choices and three text samples including Chinese, plus missing/corrupt sources
and valid assets. The text regression checks actual glyph coverage rather than
just nonempty strings. C++ tests also cover persistent shader-cache metadata,
cache invalidation after include edits, corrupt-cache recovery, parent-aware
compose-background sampling, and SceneScript AM/PM sprite-frame selection;
these create no window and no Vulkan device.

Authored `maxwidth`, `maxrows`, `limitwidth`, `limitrows` and `limituseellipsis`
constrain both measurement and rasterization, including dynamic text updates.
`WidthAndRowLimitsProduceTheSamePixelsAsExplicitLineBreaks` and
`EllipsisFitsTheLastVisibleRowAndLimitFlagsRemainIndependent` compare the
actual rendered pixels and layout bounds. FreeType and fallback fonts use the
same wrapping and truncation rules.

`ShaderValueUpdaterCompat.DayTimeUniformFollowsLocalClockAndWrapsAtMidnight`
injects a wall clock and checks `g_Daytime` and the compatible `g_DayTime`
spelling as the local fraction of a day. `SoundLayerControlTest` checks authored
random playback delays between clips against emitted sample counts, including
different callback sizes, pause/resume, stop/restart and seeded bounds. Its
null audio backend never opens an audio device.

Text raster caches hold neutral glyph coverage. Color, brightness and alpha
bindings reach uniforms, including text under effects, without relayout or
uploads (`MetalSceneDraw.TextStylingChangesPixelsWithoutRerasterizingGlyphs`).
Text scripts first run on the normal ordered tick, not while objects are still
being parsed. The layout queue is FIFO and coalesces updates in place;
`AWaitingClockIsNotStarvedByNewerReadoutUpdates` blocks the worker deterministically
to verify that newer readouts cannot overtake a waiting clock. Completed glyph
images publish in revision order even when a newer value is pending; continuously
changing labels must not remain blank waiting for an exact-current revision.
The test compares the published glyph pixels before and after catching up.
An effect target grows geometrically, up to 4096 per dimension, only when its
caption outgrows the current capacity; that size change requests a graph rebuild.

`CameraFraming.AFullscreenEffectCoversAPerspectiveScene` checks full-screen
coverage independently of the perspective FOV. `RenderScale` covers physical
surface sizing and scale/resize transitions without changing 2D canvas behavior.
`ExternalMaterialsKeepHiddenTransitiveProducers` covers texture references absent
from the scene JSON. Versioned model fixtures cover MDLV13–23 attribute layouts.
SceneScript creation regressions cover independent cloned layers, owner-local
cached factories, bounded authored pools and lazy template loading.

A script imported from the Workshop declares `export let __workshopId = '<id>'`
and keeps naming its assets as in its own project (`models/bar.json`), while the
editor stored them under `models/workshop/<id>/`. Its `thisScene.createLayer`
passes that id on, and the runtime tries the workshop folder only after the
path as written, the owner's own workshop folder and the lazy loader have all
found nothing, so a path that resolves without it keeps its template. Those
source layers are usually hidden and never parsed, so the lazy loader builds
the template from the bare model: visible, because the copies start as copies
of it, and as large as the model's picture when the model states no size. A
zero-sized hidden template had made every lazily created layer invisible, which
silenced audio visualizers built from imported bar assets.
`ScriptRuntimeCompat.CreateLayerFindsTheAssetsOfTheWorkshopItemItsScriptDeclares`,
`.CreateLayerPrefersThePathAsWrittenOverTheDeclaredWorkshopItem` and
`.CreateLayerLooksInAWorkshopFolderOnlyForANumericDeclaredItem` cover the
lookup; `SceneSchema.ALayerCreatedFromAWorkshopModelIsSizedByItsPictureAndShows`
covers the parsed template. `offscreen_scene_probe` builds its render graph once,
after its warm-up ticks, so it draws layers a script creates during `init` but
not ones created later; `metal_scene_draw_smoke` rebuilds on every graph
mutation, as production does.

The local-project Metal probe consumes runtime graph mutations like production.
Local-asset probe sound managers use the null backend: not calling `Play()` alone
does not prevent `MountStream()` from initializing a system audio device.

`TextObjectRuntime.LonelyCatHeadlessRegression` in `text_object_runtime_test` is
an opt-in local-asset diagnostic. Set `WE_TEST_PROJECT`, `WE_TEST_ASSETS` and a
disposable `WE_TEST_CACHE`, then run with
`--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`; add
`WE_TEST_EXPECT_WARM=1` for a second run. It parses the package, ticks scripts
and constructs the render graph; it does not initialize playback, capture the
desktop, or modify the imported wallpaper.

### HDR bloom, emissive masks and interactive scenes

Material compilation sets `SCENE_ORTHO` from the authored scene projection on
both backends, including effect passes. A 2D layer must use the shader's fixed
view direction rather than a perspective eye on the layer's plane, which can
reduce its lighting to ambient-only. Material overrides cannot change this
scene-owned switch; the shader request/cache key includes it. This adds no
passes, textures or per-frame CPU work. The original GPU regression
`MetalSceneDraw.LightingViewDirectionFollowsTheAuthoredSceneThroughEffects`
checks lit and unlit pixels for both projections, directly and through effects.
This fixes projection selection, not the existing approximate
`PerformLighting_V1` compatibility helper; full authored-light parity remains
unverified.

An authored `hdr` scene uses RGBA16F color intermediates on both backends.
Masks and source media remain in their original formats; SDR scenes retain
RGBA8. HDR shader combos are enabled before compilation, not approximated by
raising final display brightness. The fourth texture-component flag (TEX bit23)
travels through the C++/Rust compiler interface, so an alpha-channel emissive
mask can enable its shader branch.

HDR bloom uses the supplied downsample, additive upsample and SDR-combine
materials. The pyramid is bounded to 12 levels, with source-sized sample
offsets refreshed at prepare/resize. The general bounded model maps positive
spread `s` to a coarse-level weight `s / (1 + s)` and divides extraction strength
by the sum of the pyramid weights. Spread redistributes energy rather than
amplifying a constant field. Zero strength disables the halo; negative spread
has the same narrow kernel as zero. These are this renderer's defined semantics,
not a verified reproduction of Wallpaper Engine's proprietary parameter mapping.
`HdrSpreadPreservesEnergyAndStrengthScalesTheHalo` checks GPU pixels across live
strength/spread changes, including large spread and zero strength.

`ParsedHdrRadianceSurvivesEffectsLayerLinksAndBloom` uses an original bit23
emissive texture through the real parser, effect chain and layer references.
The native and Compatibility overbright regressions read pixels and unclamped
radiance. Missing HDR materials fail rather than silently substituting LDR.

`applyUserProperties` runs once initially, then only for changed properties,
after the whole property set has been refreshed. Test clock clicks and hidden
helper enter/leave through projected input, not by forcing overlay alpha.
Likewise, a closed author menu and an audio-driven wave with no audio are not
evidence that a rendered frame has exercised either feature.

Perspective particle billboards keep object scale; authored 2D canvases retain
their pixel-size compensation. Quantity remains the documented emission-rate
factor, not a replacement for the authored maximum count. Tests cover both
projection policies, hierarchy, depth and reflection.

### Textures, allocation and composition

- Texture residency comparisons must cover the scene's full visibility/crossfade
  cycle, including the moments when each affected image is actually visible.
  Matching startup frames can miss large animated layers whose opacity is still zero.
- Native Metal allocates only targets the compiled passes name.
  `metal_scene_draw_smoke` checks that a declared but unused target stays
  unallocated through optimisation off/on, and that a copy the plan drops as
  dead is not made while the optimisation is on and gets its image back,
  filled, when it is turned off without a recompile. Compare target residency with the harness's render-target bytes,
  not the device-wide allocation.
- Texture lifetime tests check 32 generated multi-version graphs against a
  last-access oracle, plus nested composites with aliases, three sizes, visible
  and hidden parents, and background-copy enabled/disabled. Alias clears and
  readers must refer to the same canonical resource.
- Eight generated GPU scenes vary nested children, background-copy settings,
  visibility, dimensions, transforms and declaration order. Besides exact
  pooled/isolated pixel equality, known pixel assertions verify that empty
  inputs do not leak old pixels and that children actually render.
- Pooled targets are retained until every logical version has finished, and
  effect inputs are cleared explicitly when `copybackground=false`.
  `render_target_lifetime_test` asserts version lifetimes and a real transparent
  writer before an effect samples its empty input.

### Animation and puppets

- Non-additive puppet animation layers use their effective blend weights for
  the entire pose (translation, scale and rotation), including offsets from the
  reference pose. Otherwise overlapping layers double character-sheet assembly
  offsets and separate attached pieces. Additive layers keep their authored
  weights. `MdlSchema.NonAdditiveLayersShareTheWholePoseWeight` covers normalized
  and partial weights, rotation, scale, loop wrap and repeated samples;
  `NonAdditivePoseMixRetainsDistinctMotionAndAdditiveOffsets` covers distinct
  animations, additive overlays and live blend/visibility changes. The correction
  uses the existing prepared weights without adding per-frame work or GPU resources.

- Puppet layers with effects light their assembled geometry only in the final
  skinned pass. The input texture-sheet pass is unlit, so lighting is not
  multiplied twice or baked into the separate cut-out pieces. Unskinned layers,
  effect-free puppets and unlit materials retain their lighting paths. This
  removes shader work without adding passes or targets. The original pixel test
  `PuppetEffectsApplyLightingOnceAfterAssembly` covers all eight combinations
  of puppet/card, effects/direct and lit/unlit over repeated draws.
- A layer's `colorBlendMode` mixes it with the screen behind it, so only the
  pass that draws onto the screen may sample it. On a puppet with bones that is
  the final skinned pass, which takes `BLENDMODE` itself; the separate
  passthrough that cards and mesh-only puppets end with would otherwise run
  before it, over the texture sheet, and paint a shrunken copy of the whole
  wallpaper inside the layer (with opaque mesh-shaped blocks where a multiply
  shadow belongs). The passthrough is dropped, not added to.
  `RenderGraph.puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen`
  parses a one-bone puppet and requires the only screen-sampling pass to be
  the one writing the scene.
- Legacy four-light shaders pack the fourth light's RGB into the `w` lanes of
  three color uniforms. `FourLightColorsRoundTripThroughPackedUniforms` checks
  zero through five lights, channel order, radius/intensity premultiplication,
  the four-light limit and clearing after lights are removed.

- Authored layer `origin.animation` uses one playback clock for its three curves.
  Relative keys offset the authored origin, not the previous tick; unkeyed axes
  retain their values. Scripts/user properties keep precedence, anchors and
  effect-final cards follow the existing transform path, and orthographic shots
  retain their shared origin/zoom clock. `SceneSchema.OriginTimeline*` covers
  aligned images, text/groups, absolute/relative keys, loop duration, paused
  playback, seek/replay and completed timelines releasing animation demand.
  `MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen` reads pixels
  before, during and after a reveal on direct and effect-chain layers; the
  `generated-origin-animation` Compatibility case verifies both halves after
  the intro, under pooled and isolated allocation. Static origins add no tick
  binding; held animation frames do not re-evaluate curves.

- Puppet attachments use the animated bone affine each frame while preserving
  the child layer's authored/script transform. Character-sheet reference poses
  are decoded separately from cut-up bind geometry so additive and non-additive
  animations reassemble correctly. Synthetic regressions cover declaration
  order, animated translation/rotation/scale, repeated same-time samples and
  local edits.
- Scalar material timelines preserve paused first keys and authored Bezier
  handles; SceneScript named animation controls drive play, replay, pause, stop,
  seek and rate. Puppet animation deltas use the skeleton reference pose, not
  the first animation sample, preserving initially collapsed eyelids and
  authored rotations.
- Property-script `update(value)` receives the current value, including the
  previous frame's result and explicit property writes, rather than the
  original authored value on every tick. This preserves iterative hover easing,
  full authored enlargement, and continuous reversal on cursor leave/re-entry.
  JavaScript input conversion serializes only the value payload, without copying
  the live property's listener/subscription ownership. Callback-only scripts
  keep their existing no-writeback behavior.

### Frame timing

Frame timing keeps render cost separate from animation time. Dropped busy ticks
remain included in the elapsed delivered-frame delta; restarting excludes paused
time. `timer_tests` covers dropped ticks, restart, FPS changes and long gaps
without desktop surfaces or audio devices.

### Continuous-playback work contracts

- `playback_gpu_test` uses real private images for producer/consumer and
  overwrite synchronization, every generated mip, and recording/pipeline/
  framebuffer failures. The executor returns the first `VkResult` failure;
  failed recordings are reset and abandoned rather than submitted or waited on.
  Shader-read barriers are outside render passes and include vertex consumers.
- Destroying a pass leaves it unprepared with no image handles. Render-scale and
  copy-elision rebuilds destroy every pass, drop the render targets and prepare
  only unprepared passes, so a pass that stays prepared records against freed
  images (a `CopyPass` that did crashed MoltenVK at launch with render scale
  below 1). `CopyPreparesAgainAfterRenderTargetsAreDroppedAndResized` covers it.
- A prepared `PrePass` is skipped only when a same-image, same-view, single-mip,
  single-sample clear with bit-identical color is reached before any reader or
  non-custom pass. Visibility and actual active descriptors are reconsidered
  each frame. The standalone pass loop remains the reference path.
  `FirstDrawAfterATransparentClearOpensWithItByteForByte`: the first draw into a
  target cleared to transparent opens with that clear, leaves the bytes the
  clear plus a loading draw left, and the transfer clear is dropped;
  `RenderTargetLifetime.NestedCompositesClearBeforeChildrenWithoutErasingThem`
  keeps every later draw loading and single-sample.
- A hidden layer's batched first-use clear (`ClearImage`) is recorded only when
  something can observe its target (`HiddenClearIsObservable`, over the whole
  graph, including passes left out of the frame by reuse): a later drawing
  reader, sampler, copy, final composition or loading draw, any earlier reader
  (it samples the previous frame's clear), or the scene output.
  `HiddenClearsAreRecordedOnlyWhereSomethingReadsThem` covers each reader and
  the transition of a hidden reader to drawing; the executor and the
  unchanged-present check apply the same rule.
- Direct presentation requires exactly one graph shader pass writing the
  default target, a first clear, no depth/mip/MSAA or feedback, UNORM RGBA/BGRA,
  and identical graphics/present queue families. Each frame also requires the
  exact full-target viewport/scissor, matching extent, ready descriptors and no
  flip -- except for the plain-video scene, whose one pass is by construction
  the final composition's own quad copying one texture: it presents through the
  final composition's viewport, scissor and sampler whenever its bound frame is
  exactly the scene's size and the picture is not mirrored. Other frames render
  the normal intermediate plus `FinPass`. Both pipelines are prepared once; all
  paths retain frame/presentation waits. Private-target tests compare complete
  same-format bytes over poisoned target rotation, graph resize, transparency,
  fallback and error recovery; they never transition private images to
  `PRESENT_SRC_KHR`. `PlainVideoPresentsThroughTheFinalViewportByteForByte`
  drives the production video layer (`SceneWallpaperInputTestAccess::
  CreateVideoProjectNode`) over fit, fill, stretch, none, user scale, 2x
  displays, exact halving and uneven reduction, RGBA and BGRA sources sampled
  linearly or nearest, and requires the copy path's bytes; mirrored, smaller
  frames and other passes fall back.
- The Compatibility swapchain is `COLOR_ATTACHMENT` only, so MoltenVK makes the
  layer framebuffer-only. A requested poster is composed a second time by the
  pass that composed the drawable (`FinPass::recordComposition` or
  `CustomShaderPass::recordPresentation`) into a one-frame image of its own,
  refused above the poster limit by its real allocation, and copied from there.
  The same test requires every poster to equal the bytes the target received.
- The Compatibility NV12 path makes one submission per new frame: the
  conversion is committed, without a CPU wait, on MoltenVK's own graphics
  `MTLCommandQueue` (exported with `vkExportMetalObjectsEXT`) and is ordered
  ahead of the frame by commit order and hazard tracking. That relies on
  MoltenVK's defaults (`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1`, no prefill)
  and on the conversion running in the update op before `rr.command.Begin`. A
  first-use layout transition is recorded into the frame
  (`TextureCache::RecordVideoFirstUseTransitions`, right after `Begin`; harnesses
  that record frames call it too). `NewVideoFramesNeitherWaitOnTheCpuNorSubmitOutsideTheFrame`
  guards one submit per frame, no CPU wait and image creations bounded by
  pooled destinations; `ADroppedFrameDestinationIsNotReusedBeforeItsConversionRuns`
  guards the parking of a destination whose conversion is still in flight.
- Per-frame uniform writes resolve reflected members through a per-pass memo
  instead of string-keyed maps; every value is still written every frame and the
  upload stays memcmp-gated. The memo relies on two invariants: after parsing, a
  material's `customShader.constValues` only gains keys or is updated in place
  (a runtime erase would have to invalidate the memo), and `RuntimeImageSource`
  never removes a name (`NamesGeneration()` moves when one is added).
  `LiveTexelSizeOverridesParseDefaultsWhileMaterialValuesStayLive`,
  `RuntimeImagePublishedAfterPrepareReachesTheNextFrame` and
  `RuntimeImageNamePublishedAfterPrepareReachesTheNextFrame` cover them.
- Compiled script exports suppress only absent handlers. Initialization,
  scheduled callbacks, shared scene callbacks, live-value fallback and live
  alpha/geometry hit order remain covered by `script_runtime_compat_test` and
  `mouse_input_test`. Transform/material caches avoid recomputing sources but
  still repair changed destinations in the original phases; failed registration
  releases only its new subscriptions/values and restores existing mask/puppet
  identity.
- Puppet copies reuse a result buffer in their existing shared playback State
  for the exact same finite time until a control mutation. Fresh layers sharing
  an asset have independent results. Attachments still apply each frame. Audio
  uniforms borrow an owning packing buffer synchronously and read a fresh
  spectrum on every call; particle mouse inverses are skipped only when all
  current controlpoint link flags are off.

Core/bridge tests additionally cover bounded capability relay delivery,
renderer-instance replacement, serialized observer replay/publication, retained
held-button levels and discarded inactive taps, level-only native reconciliation,
single-turn samples and exact-success input deduplication. Native capability and
button tests initialize loopers only, not Vulkan, playback or audio hardware.

Performance probes remain disposable, with fixed simulation time, full output
checks outside timing, raw samples and per-block median/p95. C++ `new` counters
do not measure QuickJS `malloc`, worker-thread allocations or whole-process
memory. Pixel equality and Vulkan command traces are not synchronization-layer
validation, desktop equivalence, GPU residency or power measurements.

### Video decode state machine and colour range

`video_decode_pump_test` pins the libavcodec send/receive contract, and includes
reproductions of the order this project used before: feeding input before
draining output loses a packet the decoder rejected with `EAGAIN`, and seeking at
end of input instead of draining loses the reordered tail of every loop. A
change that reintroduces either order fails those two cases. The same file
covers cancellation during a drain, a bounded no-progress budget, and releasing
a held packet exactly once on seek, stop or failure.

`video_color_conversion_test` pins known pixels for BT.601/709/2020 in both
ranges, studio black and white with clamping, 75% colour bars round-tripped from
their RGB primaries, matrix separation, resolution-based inference for
unspecified metadata, and bit-depth scaling. Limited-range chroma has its own
224 code-value excursion; reading it as `sample - 0.5` desaturates every
studio-swing frame, and that specific regression has a case of its own.
`PlaybackGPU.MetalConversionMatchesTheCpuColorReference` compares the Metal
`nv12_to_bgra` kernel against the same CPU reference, so the two paths cannot
drift apart.

Stream display matrices survive metadata probing and frame extraction. The
decoded buffer keeps its coded dimensions; output dimensions and sampling use
the affine display transform. `VideoDisplayTransform` checks all eight
orthogonal orientations plus scale and shear, and
`VideoSourceInput.DisplayMatrixSurvivesMetadataProbeAndFrameExtraction` reads
ordinary synthetic MP4 metadata. Private-texture Vulkan and Metal checks draw
four distinct corner colors through BGRA, converted NV12 and direct NV12
sampling. They compare orientation, logical size and transparent uncovered
corners for shear; converted and direct output may differ by at most two
channel levels. No desktop surface is used.

Software-decoded frames allocate the existing BGRA output buffer with IOSurface
backing and Metal compatibility. A CPU-only Core Video buffer decodes correctly
but cannot be imported as a GPU texture, leaving the video black. This changes
the backing allocation, not hardware-decoder selection, color conversion or
scheduling; import adds no second pixel copy, conversion destination or GPU wait.
`DecodedFormats/SoftwareVideoFrame.*` in `playback_gpu_test` covers BGRA, NV12,
YUV420P and YUVJ420P using generated strided color/alpha patterns, checks exact
imported pixels after releasing the decoder buffers, and asserts direct-import
work. `WE_TEST_VIDEO` optionally exercises an installed clip without editing it.

Video frame imports are owned by a lease that retains the Core Video texture
wrapper and the pixel buffer for as long as the frame can be sampled, not just
the vended `MTLTexture`. `playback_gpu_test` exercises pool reuse, generation
dedup, cache eviction and recording-discard recovery against it.

### Frame pacing follows the content, bounded on both sides

`timer_tests` pins the frame clock's content-rate pacing. A pushed
`FrameDemand.content_period` may only lengthen the tick interval: the configured
FPS stays the ceiling, so a 60 fps video cannot make a 30 fps wallpaper render at
60, and an unknown, zero, negative or absurdly long period cannot stall a
scene — one hour is clamped to the five-second gap the frame clock still treats
as continuous playback. Dropping the demand restores the fixed cadence rather
than inheriting the previous scene's, and pacing never changes how many draws may
be in flight.

Only the engine's own plain-video scene reports a period, and only because
`CreateVideoProjectScene` builds it with a single video texture, a copy shader, a
no-op shader value updater and no script, particle, audio or pointer input.
Authored scenes report nothing. A change that lets any other scene answer needs a
positive account of every dynamic render-graph input first; guessing freezes a
live wallpaper.

The period a source reports is evidence, not metadata. `avg_frame_rate` is an
average and `r_frame_rate` is an estimate, so neither describes a particular gap
in a variable-frame-rate clip. `video_frame_pacing_test` pins the rules that
replaced the metadata-only version: declared rates are an upper bound on the
period and never unlock pacing on their own; the shortest gap actually decoded
does, after enough samples; the result is monotonically non-increasing, so a
burst that appears once keeps the clock fast afterwards; deltas across a loop
seam or a seek are discarded because they describe the seam; and repeated,
rewound or non-finite timestamps are not counted as evidence at all, which
leaves the fixed cadence in place rather than pacing on a guess. Rational rates
keep their exact period (`24000/1001`, not `1/24`), and playback speed maps the
content's own timeline onto the wall clock, so a 2x wallpaper needs twice the
tick rate for the same clip.

A frame clock paced to its content also has to be told apart from a suspended
process. `timer_tests` covers the boundary: the suspension threshold scales with
the interval the clock is actually using and never drops below the five-second
floor, so an ordinary frame boundary at the pacing clamp reports its real
elapsed time instead of one ideal frame, while an eight-hour gap is still
treated as a resume. Before that change a scene paced at the clamp lost the
difference on every frame and fell steadily behind.

`WALLPAPER_MACHINE_CONTENT_PACING=1` switches content pacing on in the same
binary so a comparison measures one strategy rather than two builds. The
default is the fixed cadence; an unset or empty value never enables pacing.

### Renderer work counters

`OWE_RC_*` counters are incremented by the production paths that perform the
work: the frame clock's tick, the draw handler, the Vulkan submit, the present
request, the frame fence and the texture cache's video update. They are off by
default and read by pulling `owe_scene_wallpaper_counters`; nothing is pushed or
logged per frame. `timer_tests` asserts that a tick which found a draw still in
flight is counted as a suppressed tick rather than a request, that nothing is
counted while the switch is off, and — running the real thread timer against the
real callback — that a content period genuinely lowers how many draws the
scheduler posts. `video_frame_pacing_test` pins the generation accounting behind
`video_frames_selected`, `video_frames_reused` and `video_frames_skipped`: a gap
between two displayed generations is exactly the number of decoded frames that
never reached the screen, which is how a pacing regression is falsified while
the picture still moves.

`present_requests` counts requests. This backend has no presentation-feedback
source, so the frames a compositor actually displayed are reported as
unavailable and never approximated by the request count.

### Shader pipeline

The shader repair handles undersized cross-stage varying declarations,
conditional helper headers, source-defined `log10`, legacy scalar/vector
argument conversion, compound assignment narrowing, and scalar initializer
conversion. The pipeline revision is part of the cache key and is bumped
whenever codegen can produce different output for source that already
compiled; it is 11 now, and each bump invalidates previously compiled programs.
Revision 11 invalidates arrays previously emitted with a stale leading macro size.

Floating remainder uses a generated typed helper accepted by Naga, preserving
truncating remainder and single evaluation of its operands. Active `#undef`
directives remove macros across includes; inactive branches leave them intact.
Generated NV12 members create and bind a uniform block even when a material has
no authored scalar uniforms. The `legalize`, `preprocess` and `video_planes`
Rust regressions cover these paths with synthetic shader sources.

It also absorbs idioms author shaders inherit from the permissive path they
were written against, each of which otherwise drops a whole effect rather than
one expression: a texture annotation's `"default":""` means the slot has no
default; `CAST2`/`CAST3`/`CAST4` are vector constructors before
`legacy_builtins` renames them; mixed-width vector operands inside a call
argument truncate to that expression's narrowest operand, while sampler
coordinate arguments stay with the texture strategy that narrows them to the
sampler's dimensionality; and a parenthesized comparison used as an arithmetic
operand is converted with `float(...)`. Known and not handled: logical-not
applied to a float (`!someFloat`), which still rejects
`workshop/2800594362/effects/clipping_mask`.

Varying arrays sized by a numeric combo resolve the macro before generated
interface declarations are emitted and reserve one location per element, just
like literal-sized arrays. Location planning and emission use the same
`interface_array_size` resolver at each original declaration's source position.
All earlier active directives count, including macros changed between ordinary
items or inside earlier function bodies; later changes do not resize an earlier
array. Codegen stores literal bounds before hoisting declarations or generating
local input copies. Bounds must be positive integer literals or visible
object-like macros with positive integer values. Expressions, missing definitions
(including those defined only after the declaration), zero and negative sizes
produce an explicit diagnostic rather than silently reserving one location.
`pipeline_resolves_macro_array_bounds_at_each_declaration` and
`pipeline_rejects_unresolved_interface_array_bounds_before_layout` cover both
backends. Legacy builtin calls in `#define` replacements are
rewritten inside function bodies too, not only in top-level directives. The
original regressions `pipeline_compiles_macro_sized_varyings_without_overlapping_locations`
and `pipeline_legalizes_nested_legacy_calls_in_macro_replacements` compile both
SPIR-V and MSL; they cover annotation defaults, explicit counts, consecutive
arrays and nested object/function macros. These are compile-time repairs for
previously rejected shaders, not brightness adjustments. Restoring a dropped
effect restores its authored GPU work and target allocation; no new per-frame
CPU path or compensating render pass is introduced.

One repair is a layout contract rather than a spelling: a scalar or
narrow-vector array in the generated uniform block is declared `vec4 name[N]`
and every subscripted read is swizzled back. std140 pads each element to 16
bytes, which is what the host packs and the reflection reports, while the MSL
backend emits the natural tight stride — so without it every member after such
an array is read from a different address on Metal than the host wrote it to.
The swizzle has to follow reads reached through `#define` aliases (written
inside `main` by the audio-bars shader family) and through array-parameter
specialization, not just direct ones.

A sampler slot's `combo` answers whether the **material** bound a texture
there, and that is not the same question as whether the slot is bound. An
annotation's `default` exists so an unused sampler still reads something sane;
`WPSceneParser` binds it, then reports the slot as unbound to the compiler so
the combo stays 0. Feeding the defaulted list back turned every
`{"combo":…,"default":…}` sampler permanently on — `rounded_mask` read its
corner radius from a white default instead of `u_Radius` and masked the layer
it was applied to into a circle. A slot the combo leaves unsampled is cleared
afterwards, so nothing holds a texture it never reads.

Texture-driven switches are discovered before stripping conditional branches:
`#if USE_MASK` can contain the sampler annotation that defines `USE_MASK`.
Discovering it only after preprocessing dropped authored masks and let localized
brightness pulses affect the whole image. Only texture-derived switches are
seeded this way; ordinary combo defaults still follow evaluated branches, and
explicit material overrides still win. This is compile-time work, with no added
render passes, temporal filtering or quality reduction. An active mask retains
its texture and sampling cost, as the authored shader requires.
`conditional_texture_annotations_enable_the_sampled_mask_on_both_backends`
covers includes, cross-stage switches, absent/default-only textures and explicit
overrides for SPIR-V and MSL. `PlaybackGPU.AConditionalMaskKeepsPulsesOutOfTheMaskedRegion`
reads six alternating-brightness frames: masked pixels stay fixed while the
unmasked region continues to pulse.

## Rust crates

`python3 scripts/check_rust.py` is the release-CI entry point. It supplies the
Homebrew Cargo environment, uses a temporary `WALLPAPER_MACHINE_HOME`, and runs
the core/bridge library tests, four device-free core integration targets, and
the shader crate with `ffi`, all with `--release --locked`. It prints and records
the six explicit desktop/external-corpus exclusions and any emitted skip
reasons. A nonzero command or missing tool fails the check. Full logs and the
JSON verdict are under `artifacts/rust/`; CI uploads them on failure. This does
not certify skipped corpus inputs or authorize a desktop run.

Generated bindgen output can differ in formatting between machines; tests must
exercise the FFI behavior instead of parsing a formatted declaration. Mouse
monitor-gap tests wait for the fake engine's sample barrier and observed probe
progress before comparing counts, so a busy CI worker is not mistaken for a
dropped cursor update. Close the gap while the sample is blocked before checking
that probes stop; otherwise an in-flight probe can race the final count.

Run from `upstream/renderer` with the Homebrew environment from
`scripts/build.py`. The first `cargo test` after that environment changes fails
in its CMake configure step and succeeds on an unchanged retry, so a single
configure failure is not a result:

```sh
cargo test --release -p wallpaper-core --lib
cargo test --release -p wallpaper-core --test wallpaper_background
cargo test --release -p wallpaper-bridge --lib
cargo test --release -p wallpaper-core --lib audio
cargo test -p shader --test pipeline -- --nocapture
```

- `wallpaper-core` audio coverage: capture ownership and failures,
  mono/multichannel conversion, resampling including sample-rate changes.
  `capture_controller_tests` includes non-scene consumers sharing one tap with
  scenes, cleanup, suspension, permission and failed-transition rollback.
  The bridge's `tests::web_audio_media` replays web capture decisions through the
  production demand handler and real controller with a device-free backend:
  checking only the fake engine's suspension flag cannot prove capture starts.
- `wallpaper_background`: renders unattached production Metal layers over a white
  bitmap with no drawable, before and after a resize and after recreation. Every
  pixel must be opaque black. Its harness runs on the process's main thread; no
  window, GPU drawable, or desktop access is needed. It does not establish
  physical sleep/wake compositor timing.
- `wallpaper-bridge`: live audio toggle errors, rollback/persistence,
  nonblocking selection and mirror behavior; scene lifetime,
  presentation/manual pause precedence, failure rollback, disabled destruction,
  stalled single-flight mouse scenarios, and live handles remaining after
  reconciliation/audio errors; the lock-screen export regression for
  committed-versus-draft scaling, pause/resume and ejection; and
  `tests::property_snapshot` for combo selection, conditional rows after
  edits/default restoration/discard, hidden-value preservation, and
  malformed-condition fail-open behavior.
- `shader`'s `pipeline` test skips asset-dependent cases with a printed
  `skipping …` reason; read those lines before claiming shader coverage. See
  [wallpaper-corpus.md](wallpaper-corpus.md) for the asset roots.

## C++/CMake test binaries

CMake test binaries are built under `artifacts/renderer/bin/`. The authoritative
routine build/run list is `REGRESSION_BINARIES` in `scripts/check_renderer.py`;
a non-zero exit from any registered binary fails the check. It includes the
texture/cache/lifetime, audio, video, graph, script-derived rendering and Metal
checks. `scene_schema_tests`, `mdl_schema_tests`, `tex_schema_tests`,
`script_runtime_compat_test` and `media_thumbnail_texture_smoke` also provide
targeted parser, SceneScript and media protocol coverage when those paths change.

`rendergraph_smoke` and `vulkan_sample_count_smoke` use always-active GTest
checks in Release builds. `sprite_animation_test` checks elapsed time across
cadences and long loops. `video_source_input_test` owns a private `TMPDIR` and
only removes its own media cache; never clear the app's decode cache to make a
test pass. All sound fixtures use the null backend.

`stb_image_regression_test` decodes ordinary generated JPEG/PNG/BMP images,
checks cleanup under controlled allocator refusal, and compares scalar versus
arm64 NEON JPEG pixels. Arm64 production decoding enables NEON. The disabled
`Arm64NeonJpegDecodeBenchmark` is explicitly opt-in; its first-decode and warm
in-memory decoder timings are not disk-cold startup, whole-app performance or
energy measurements. `miniaudio_failure_paths_test` covers allocation failures
without opening audio hardware.

`unchanged_present_test` exercises Compatibility frames that would repeat the
picture through a real swapchain on a `CAMetalLayer` no window owns. The
native Metal backend adds `metal_backend_test` (capability and graph gate, no
device needed), `metal_scene_draw_smoke` (author shaders and same-frame
intermediates drawn and read back, plus target reuse, dynamic-geometry upload,
sprite-sheet stepping, text layers and their update dedup, direct video plane
sampling end to end and Metal program reuse across renderers), `metal_poster_capture_test` (on-request poster
readback, busy coalescing, invalidation) and `metal_video_texture_test` (BGRA
import and NV12 conversion against the CPU colour reference, from synthetic
frames); all four run in the check, draw only into private textures and skip
visibly without a Metal device.

`unchanged_present_test` measures real-time frame cadence, including zero skipped
baseline video frames. Run the renderer gate without concurrent builds or other
benchmark jobs; a scheduling stall can fail that baseline even when generated
pixel comparisons pass. Keep such failures visible rather than excluding the test.

Useful filters:

```sh
audio_tests --gtest_filter='AudioResponseMonoTest.*'
script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'
scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'
```

`audio_tests`, `particle_mouse_controlpoint_test` and
`script_runtime_compat_test` cover physical FFT frequency mapping including DC
and Nyquist, silent and stale input, box/sphere emission transitions, and typed
SceneScript views.

## Known limitations

- `tex_schema_tests` links `PkgConfig::TEST_LZ4` itself (`tests/CMakeLists.txt`),
  the same way the video suites re-resolve FFmpeg: the renderer links LZ4
  `PRIVATE`, so the include directory does not propagate to a test that builds
  its own compressed `.tex` fixtures. It stays outside
  `scripts/check_renderer.py`'s target list, so run it by hand when touching
  `WPTexImageParser`.
- Asset-dependent `shader` pipeline cases (for example `genericimage4` and a
  Workshop package) are excluded when their referenced files are absent.
- Some locally installed scenes emit pre-existing MDLA, Rust `light_map` compile
  and shader-value alias errors. Those predate current work; verify only that
  no *new* diagnostics appear. Named case seen so far: Wallpaper Engine's own
  `clipping_mask` fails to translate (`!float` in the translated vertex
  shader). A `ShaderValue: … not found in glsl` line is authored leftovers,
  not a binding failure. Music Visualizer | iOS Style's `gaussian`,
  `cutout_vignette` and `effects/refract` were listed here until the shader
  pipeline absorbed the three idioms they relied on; they compile now, and the
  Shader pipeline section above owns that list.
- **Native admission accepts a scene with a failed effect.** Before
  `cloudmotion` compiled, `metal_scene_draw_smoke` reported Workshop 3521337568
  as `Native Metal, 120 frames drawn` while the same run logged `metal
  translation of 'effects/cloudmotion' failed`: `SelectSceneBackend` does not
  reject a scene one of whose author effects failed to translate, and the
  layer is drawn without it. The project rule is that Native Metal must not
  report success while an effect is skipped. Not fixed here; when reading a
  local-project Metal run, require zero `metal translation … failed` lines.
- The `perspective` flag of an image layer is read by no parser
  (`WPTextObject` and `WPModelObject` read theirs); image layers always draw
  through the orthographic camera.
- **Intermittent frame in 3632513108, predating the 2026-09-25 work.** Run with
  `scripts/check_renderer.py`'s environment (default frames and step), this
  scene's `frame-2` occasionally comes out as a second image that differs
  everywhere by at most 12 levels (3,737,738 px at 3840x2160, mean 0.8): no
  clock, label or single layer. An unmodified HEAD build produced it in one of
  two pooled runs and in neither isolated run; ten later renders, five per
  mode, produced none. It has only been confirmed in a pooled run, so
  allocation reuse is not ruled out. A lone `pixels_equal=false` for this scene
  is not by itself a new regression: re-run it, and investigate if it repeats.
- **A target a parallax layer draws into is never reused.** Neither backend's
  static pass sample (`CustomShaderPass::frameSample`,
  `MetalRender::Impl::frameSample`) includes the parallax offset
  `WPShaderValueUpdater::UpdateUniforms` adds to a layer's model matrix, so
  `FrameVaryingUniforms` reports such a pass as `kParallax`, which becomes
  `PointerUniform` and keeps the whole target out of the cache
  (`StaticSubgraphCache::Compile`), whether or not the cursor moves. With
  on-demand rendering off, a scene whose only motion is parallax redraws its
  whole frame at the frame cap, as it would with scene optimisation off.
  Without the report the cache reused those targets while the cursor moved,
  and parallax stopped following it. Folding the offset itself into the sample
  would allow reuse while the cursor is still.
- **On-demand rendering stops parallax partway.** A scene that sleeps wakes
  for one frame per pointer event (`wakeForPointer`), but nothing asks for
  frames while the layers are still easing toward the cursor, so after the
  pointer stops they rest partway and catch up at its next movement.
  `m_mouseDelayedTime` is no end condition: `SceneWallpaper` calls `MouseInput`
  every frame, and that subtracts the real frame interval `FrameBegin` has just
  added as the ideal one, so `cameraparallaxdelay` acts as an exponential time
  constant and the eased cursor approaches the pointer without reaching it. A
  demand of `m_mouseDelayedTime < delay` would never clear and would keep the
  scene awake for good; a correct one needs a threshold on the offset still to
  travel.
- Compatibility and Native Metal write live engine uniforms after parser
  defaults. `PlaybackGPU.LiveTexelSizeOverridesParseDefaultsWhileMaterialValuesStayLive`
  checks actual output pixels and changing user material constants.
- Per-pass Vulkan dumps split submissions and are not proof of depth-preserving
  batched output. Compare the ordinary unsplit final frame for perspective scenes.
- **An animated material constant keeps a scene awake after its timeline
  ends.** `DescribeTimeAdvancingWork` reports `NodeBinding` for every
  material-constant binding that has an animation, playing or not. The
  timeline's clock is a registered playback (`RegisterScalarAnimation` in the
  parser), which the `Animation` reason already counts while it plays, so with
  on-demand rendering on, a scene whose only motion was such a single-play
  timeline keeps ticking after it ends.
- **Perspective models with more than 65535 vertices** are stored with 32-bit
  indices. Reading that blob as uint16 triples rejects the mesh (Saturn's body,
  `3589454154`) or draws scrambled triangles (Live Solar System bodies over
  the same limit). The parser selects the index width from the vertex count,
  and the vertex cap is 4 million so the asteroid mesh in that scene is kept.
  `g_NormalModelMatrix` is a std140 `mat3` (48 bytes). Writing the old mat4
  identity into that slot spilled 16 bytes into `g_ViewProjectionMatrix` and
  collapsed every perspective vertex onto one screen column, so the 3D pass
  drew nothing over the HUD. Uniform writes are clamped to the reflected
  member size. Culled model passes keep Vulkan's counter-clockwise front
  face; clockwise culls the Saturn skybox and rings on MoltenVK even though
  `recordDraw` uses a negative viewport height. A perspective far plane is
  padded by a tenth of a percent so a skybox scaled to exactly `far` is not
  clipped when the camera is not on its center. An image layer's `alpha`
  `update` script or user property is applied to `g_Alpha`; previously only an
  animation timeline was. Workshop `3662790108` uses that script on its opaque
  black intro card: with intro animation enabled the card covers the scene
  until its own timeline ends, and with the property off the star shell is
  visible on the first frame. A text label that repeats another layer's name
  keeps its own runtime key (`__we_text_<id>`). Workshop `3662790108` has both
  a sun group and a hidden readout named `s`; the readout used to take the
  name, so the simulation's `getLayer("s").scale` stretched that label into
  full-height white bars and never resized the sun. The planets are still
  placed by the scene's simulation script, so several stay hidden or smaller
  than a pixel at the start.
- GPU elapsed measurements vary substantially between repeated runs on this
  hardware. Treat them as samples, not as proof of a GPU-time improvement or
  regression, and never as power or battery measurements.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- **`offscreen_scene_probe` is Vulkan-only.** With
  `scene_renderer = "native_metal_preferred"` a scene the capability gate
  accepts runs on the native backend with nothing behind it, so a probe result
  describes a renderer that wallpaper may never use. Check the backend first —
  `metal_scene_draw_smoke` with `WE_TEST_METAL_PROJECTS` prints the decision
  per project — and repeat any comparison there before calling a difference
  backend-independent. The divergence that made this rule worth writing —
  `3799253558` rendering 70% black on Native Metal with a ring that ignored
  audio — was the uniform array layout above, and is fixed; the lesson is that
  a Vulkan-only measurement could not have found it.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
