# Renderer verification

Non-desktop verification of the vendored renderer in `upstream/renderer`: the
Rust crates, the C++ scene engine and its GPU probes. Nothing here creates a
window, swapchain, audio device, or screenshot, and nothing here inspects or
changes the desktop. What "verified" means and which checks a change needs are
in [README.md](README.md); dated results live in
[verification-log.md](verification-log.md); this file is the working reference.

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
   `RUST_SHADER_STATICLIB` pointing at `upstream/renderer/target/release/libshader.a`,
3. builds `offscreen_scene_probe`, `scene_reload_cycle_probe` and every target
   in the script's `REGRESSION_BINARIES` registry, the one list that drives
   build, run and verdict,
4. runs the registered binaries, recording failures, timeouts and explicit skips,
5. renders every generated case and every `--project` twice through
   `offscreen_scene_probe` — once pooled, once isolated (`WE_TEST_NO_REUSE=1`) —
   and compares `frame-2` byte for byte,
6. scans both logs for `ERROR` diagnostics (ignoring shader-cache misses),
7. checks independent known-pixel assertions for the generated cases, so two
   equally blank or corrupt outputs cannot both pass,
8. runs `scene_reload_cycle_probe` over the selected projects (the `--project`
   inputs, or the generated cases without any) twice each.

| Flag | Effect |
| --- | --- |
| `--skip-build` | Reuse the existing binaries instead of rebuilding |
| `--project PATH` | Add a local scene `project.json`; repeatable |
| `--assets PATH` | Shared assets directory for `--project` inputs (default `~/Library/Application Support/WallpaperMachine/SceneAssets`) |
| `--allow-missing-gpu` | CI fallback only: compile a Metal-device probe; its exact exit 77 skips the GPU targets flagged in `REGRESSION_BINARIES` plus the image and reload probes. Compile errors, abnormal exits and timeouts still fail. Default local runs require GPU checks. |
| `--allow-imprecise-timers` | CI fallback only: compile a timer probe that takes the median of 31 condition-variable waits of 10 ms; its exact exit 77 (median above 20 ms) filters the cadence tests named in `REALTIME_TESTS` out of their binaries. Compile errors, abnormal exits and timeouts still fail. Default local runs require every cadence test. |

Reports, SHA-256 hashes, logs, the generated synthetic fixtures and private GPU
output go under a fresh `artifacts/renderer/adaptive-<timestamp>/` directory,
with `report.json` as the summary; check binaries live in
`artifacts/renderer/bin/`. Imported wallpapers are read only. A nonzero exit
means a test binary or the reload probe failed, a pooled/isolated pair diverged,
a generated case emitted diagnostics, or a generated pixel assertion failed.
`report.json` records `full_compatibility_verified: false` on every case: there
is no authored-reference comparison, so rendering without a crash does not prove
all authored effects loaded.

The twelve generated cases are original synthetic scenes with no workshop
identifiers; they use private synthetic compose-layer assets plus the probes'
virtual assets, so they run on a clean checkout without an installed wallpaper
library:

| Case | What it reads back |
| --- | --- |
| `generated-0` … `generated-7` | Nested compose layers: background copy on and off, visibility, sizes, transforms and declaration order; known pixels prove a first effect draws, empty or hidden nested layers leak no earlier pixels, and visible children survive their clears |
| `generated-alpha`, `generated-alpha-single-sample` | Composed coverage as RGB: expected 128/191/255 over transparent, half-covered and opaque destinations; the second runs alpha-to-coverage on single-sample targets |
| `generated-perspective-animation` | A four-corner homography whose third corner follows a paused parent timeline: the page covers the centre and the margin stays the clear color |
| `generated-origin-animation` | A relative `origin` curve: both halves of the canvas are revealed once the curtain finishes |

Hosted CI may lack a Metal device. With `--allow-missing-gpu`, the report sets
`gpu_checks_executed: false`, lists each skipped target, and emits a CI warning.
CPU/capability tests still execute; VideoToolbox-dependent tests report their
own codec skips. A started test's failure is never converted into a
missing-device skip. A default local renderer run remains necessary evidence for
the GPU checks CI skips.

Hosted macOS arm64 runners are virtual machines that deliver a 10 ms wait
50–100 ms late regardless of process policy, so the frame-clock,
unchanged-present and audio-expiry tests that count ticks against short waits
cannot pass there. With `--allow-imprecise-timers` only the probe's exit 77
filters exactly the tests in `REALTIME_TESTS` out of their binaries with
`--gtest_filter`; every other test in those binaries still runs. The report sets
`realtime_checks_executed: false` and lists each filtered test with the measured
median under `skips`, each with a CI warning. A cadence test that fails only on
hosted runners belongs in `REALTIME_TESTS`; the harness tests check that every
name still exists. A default local renderer run remains necessary evidence for
them.

Test binaries and probes run through macOS `taskpolicy` with application
scheduling and latency/throughput tiers of zero. Before exec, the
single-threaded Python driver clears inherited Darwin background policy on both
the child process and its main thread using `os.setpriority`; `taskpolicy` alone
leaves that policy in place. Only test children change priority, leaving the
invoking agent and build tools untouched. This keeps inherited background
scheduling from governing real-time assertions; it does not relax their
thresholds or remove any tests. Contention can still affect wall-clock
performance checks, so run the gate without concurrent builds or benchmarks.

## Probes

All probes are explicitly invoked executables, not ctest cases or UI tests.
`offscreen_scene_probe` creates a surface-free Vulkan device and private render
targets, uses the production shader passes and batching plan, and writes PPM
images under `WE_TEST_OUTPUT`. Use a disposable output/cache directory. The
device requests the same extension set as the wallpaper renderer, including
`VK_EXT_metal_objects` on Apple, so a scene whose textures are video streams
imports its frames instead of rendering empty texture slots.

```sh
WE_TEST_PROJECT="$HOME/Library/Application Support/WallpaperMachine/Library/<id>/project.json" \
WE_TEST_ASSETS="$HOME/Library/Application Support/WallpaperMachine/SceneAssets" \
WE_TEST_OUTPUT="$PWD/artifacts/renderer/scratch" \
artifacts/renderer/bin/tests/offscreen_scene_probe
```

`metal_scene_draw_smoke` is the equivalent harness for the native Metal backend;
"both scene probes" below means these two.

### Probe environment variables

Inputs and outputs:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_PROJECT` | `offscreen_scene_probe`, `text_object_runtime_test` | Path to a scene `project.json` |
| `WE_TEST_PROJECTS` | `scene_reload_cycle_probe` | `;`-separated project list |
| `WE_TEST_METAL_PROJECTS` | `metal_scene_draw_smoke` | Colon-separated `project.json` paths run through the production parser into the native backend offscreen. A fallback is printed with its reason and is not a failure; an accepted scene must prepare and draw every requested frame. Frames after initialization are summarised as render passes per frame (how many rendered into the scene's own image), blits per frame and thread CPU milliseconds per `drawFrame`. With `WE_TEST_OUTPUT` set, the last frame is written there. Unset, the test skips. Read any `metal translation of '…' failed` line as a failed effect, not a clean native run |
| `WE_TEST_ASSETS` | probes | Shared `SceneAssets` directory |
| `WE_TEST_OUTPUT` | probes | Output/cache directory (disposable) |
| `WE_TEST_CACHE` | `text_object_runtime_test` | Disposable shader cache directory |
| `WE_TEST_CYCLES` | `scene_reload_cycle_probe` | Reload cycles per project |
| `WE_TEST_PROPERTIES` | `offscreen_scene_probe`, `metal_scene_draw_smoke` | Flat JSON property overrides, in memory only. A layer gated on a saved property draws nothing without this, so both backends have to be driven with the same overrides to compare one |
| `WE_TEST_RANDOM_SEED` | both scene probes | Seeds the particle random source before the scene is parsed, so the same project simulates the same particles on both renderers. The Vulkan probe only steps the particle simulation when `WE_TEST_AUDIO_HZ` is set, and only advances time when `WE_TEST_FRAME_STEP` is |

Frames, time and surfaces:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_FRAMES` | `offscreen_scene_probe` | Number of sampled frames |
| `WE_TEST_FRAME_STEP` | `offscreen_scene_probe` | Sampling interval, to look past an intro |
| `WE_TEST_CAPTURE_LAST=1` | `offscreen_scene_probe` | Draw every requested frame but save only the last, for long intro and text-update checks without thousands of images |
| `WE_TEST_SAMPLE_FRAMES` | both scene probes | JSON array of frame indices. Saves each frame and `state-N.json` with live transforms, material values, text and script-error count |
| `WE_TEST_METAL_FRAMES` | `metal_scene_draw_smoke` | Frames the local-project Metal test draws, 1/60 s apart: 120 by default, 2–3600 accepted. Its own knob, so the probe's `WE_TEST_FRAMES` in the same environment cannot move the Metal frame's scene time. The last frame is the output; the test also prints the bytes of this scene's render targets and, separately, the device-wide Metal allocation, which includes the layer's drawables and varies between runs |
| `WE_TEST_METAL_FRAME_STEP` | `metal_scene_draw_smoke` | Simulation delta in seconds; default `1/60`. Use `1/120` and twice as many frames for a matched-duration 120 FPS scenario |
| `WE_TEST_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` physical output extent; defaults to `1920x1080`. Perspective scenes use it as their full-scale raster; authored 2D canvases keep their size |
| `WE_TEST_TEXTURE_SURFACE` | `offscreen_scene_probe` | `<width>x<height>` opts into the production display-sized texture mip policy without changing raster extent; unset retains all source levels for before/after image and allocation comparisons. Native Metal uses its surface size automatically |
| `WE_TEST_METAL_SURFACE` | `metal_scene_draw_smoke` | `<width>x<height>` for the surface the native backend rasterizes; defaults to `960x540`. Screen-space shader inputs follow it, so comparing this backend's output with another's is only meaningful when both rasterize the same extent |

Allocation, optimisation and dumps:

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_NO_REUSE=1` | `offscreen_scene_probe` | Isolated texture allocation (no pooling) |
| `WE_TEST_NO_SCENE_OPTIMIZATION` | `offscreen_scene_probe` | Any value forces the unoptimised path (no static-result reuse) for a direct A/B; the probe otherwise prints how many passes were reused |
| `WE_TEST_SCENE_OPTIMIZATION=0` | `metal_scene_draw_smoke` | Turns static-result reuse off around the local-project loop, to compare a scene that looks wrong under it with the same scene drawn every frame. Process-global, restored afterwards |
| `WE_TEST_DUMP_SOURCE=1` | `offscreen_scene_probe` | Write the packaged scene JSON beneath `WE_TEST_OUTPUT`; `nodes.txt` also records per-node visibility, translate and scale, which diffs layer placement between builds without comparing pixels |
| `WE_TEST_ASSET_PATH` | `offscreen_scene_probe` | Copy one asset from the mounted package to `asset.txt` under `WE_TEST_OUTPUT` for shader diagnosis; keep private asset output uncommitted |
| `WE_TEST_DUMP_PASSES` | `offscreen_scene_probe` | Dump per-pass detail for the last sampled frame only: one image per custom pass (the image is the whole pooled allocation, which can be larger than the target), plus that pass's material slot, live visibility and full `constValues` appended to `passes.txt`. The prepare-time listing at the top of that file is a snapshot; only the `frame N` lines show what a sampled frame actually drew |
| `WE_TEST_DUMP_TARGETS` | `offscreen_scene_probe` | Colon-separated render target names, or `*` for every target the scene declares; the last frame of each is written as `target-<name>.ppm` |
| `WE_TEST_METAL_DUMP_TARGETS` | `metal_scene_draw_smoke` | Same selection as above. Each target is reported with its size and mean luma and, with `WE_TEST_OUTPUT` set, written as a PPM. Target names carry a per-run suffix, so `*` is the only way to name one across two processes |
| `WE_TEST_DUMP_ALPHA=1` | both scene probes | Writes each dumped target's alpha channel separately as grey. Effects that weight by coverage (the bokeh downsample divides by the sum of its taps' alpha) make different color from the same RGB when alpha differs |
| `WE_TEST_DUMP_POSES=1` | `wpdump` | Dump sampled bone transforms |
| `WE_TEST_EXPECT_WARM=1` | `text_object_runtime_test` | Assert zero shader compilations on a second run |
| `WE_TEST_VIDEO` | `playback_gpu_test --gtest_filter=AppleVideoFrame.LocalVideoImportsVisiblePixels` | Absolute local video path, opened read-only. Imports the first decoded frame into a private Metal texture and checks for visible pixels after releasing the decoder; select a clip with a non-black first frame. Unset skips this corpus diagnostic. No audio, window or desktop capture |

Synthetic input, media and audio (none reads the desktop, a media player or an
audio device):

| Variable | Used by | Meaning |
| --- | --- | --- |
| `WE_TEST_CLICK_LAYER` | `offscreen_scene_probe` | Image-layer ID to click |
| `WE_TEST_CLICK_COUNT` | `offscreen_scene_probe` | `1..10` synthetic clicks |
| `WE_TEST_CLICK_OFFSET` | `offscreen_scene_probe` | World-space `"dx dy"` added to the click layer's origin, to hit a covered or transparent texel instead of the centre |
| `WE_TEST_CLICK_VIEWPORT` | `offscreen_scene_probe` | `"<px_w>x<px_h>@<scale>:<fill\|fit\|stretch\|none>"`; maps the click the way a desktop does — the presented viewport is published and the cursor arrives window-normalized — instead of handing the runtime a world position, so hit testing is exercised against a real display's geometry |
| `WE_TEST_INPUT_JSON` | both scene probes | Ordered synthetic pointer events: `[{"frame":600,"layer":42,"inside":true,"buttons":1},{"frame":601,"buttons":0}]`. `layer` follows that parsed node's projected centre; `x`/`y` supply normalized coordinates instead. An exit uses `inside:false` |
| `WE_TEST_MEDIA_EVENTS` | both scene probes | JSON array of SceneScript media event objects, dispatched in order after the warm-up ticks. Enables media integration for the run, so a wallpaper that only draws its player while something is playing can be rendered without a system media source or Automation permission |
| `WE_TEST_MEDIA_ARTWORK` | both scene probes | `<width>x<height>:<rrggbb>`; publishes one opaque cover through the same path the app uses, so `$mediaThumbnail` and `$mediaPreviousThumbnail` carry a color that is legible in the rendered frame. Without it a background drawn from the current cover renders flat grey on both backends and a comparison says nothing |
| `WE_TEST_MEDIA_JSON` | `offscreen_scene_probe` | A JSON array of media events dispatched right after the parse, before the warm-up ticks |
| `WE_TEST_AUDIO_HZ` | both scene probes | Synthetic PCM at `0..24000` Hz; `0` means silence. Each frame submits one analysis window (1,600 frames at 48 kHz) through the same service the desktop tap feeds, and the Metal gate enables audio response for the run. The 64 bands follow Wallpaper Engine's layout: one ~23 Hz bin each up to about 400 Hz (band 0 ≈ 23 Hz, band 3 ≈ 95 Hz), then widening to ~15 kHz, so a shader reading only the lowest bands needs a bass tone, not 440 Hz |
| `WE_TEST_AUDIO_FILE` | both scene probes | Raw float32 mono PCM at 48 kHz played instead of the synthetic tone, continuing across frames and looping; `WE_TEST_AUDIO_HZ` must still be set to enable audio. A music-like signal is the only way to judge a visualizer's look: a tone lights one band and white noise lights all of them |
| `WE_TEST_AUDIO_AMPLITUDE`, `WE_TEST_AUDIO_NOISE=1` | both scene probes | Amplitude `0..1` (default `.025`) and optional deterministic broadband PCM instead of a sine, with `WE_TEST_AUDIO_HZ` set. A single tone cannot exercise scripts averaging several frequency bands |
| `WE_TEST_AUDIO_ENABLED=0` | `offscreen_scene_probe` | Exercise the disabled audio gate |

Audio is submitted after GPU setup so shader compilation cannot expire its
live-input timeout. These options never initialize audio hardware. Keep all
probe output outside Git. If IDE ignore rules block reads under the repository's
ignored directories, write to a system temporary directory instead. Per-pass
Vulkan dumps split submissions and are not proof of depth-preserving batched
output: compare the ordinary unsplit final frame for perspective scenes.

### Probe behavior

`offscreen_scene_probe` reports `startup parsed`, `prepared` and `first-frame`
timings. Use a fresh `WE_TEST_OUTPUT` for a cold shader-cache run and repeat the
same directory for a warm run. It resolves each project's entry/package version
and render dimensions and discovers text nodes instead of using fixed layer IDs.
It tests scene rendering only — not video or web projects, and not AppKit
presentation. It builds its render graph once, after its warm-up ticks, so it
draws layers a script creates during `init` but not ones created later;
`metal_scene_draw_smoke` rebuilds on every graph mutation, as production does.
Local-asset probe sound managers use the null backend: not calling `Play()` alone
does not prevent `MountStream()` from initializing a system audio device.

The probe keeps two clocks, and a frame's time is not `N * WE_TEST_FRAME_STEP`.
The runtime clock (timelines, camera shots, scripts) takes 40 warm-up ticks of
1/60 s before frame 0, then one `Tick(step)` before each frame, so frame N is at
about `0.667 + (N + 1) * step` seconds. The scene clock (`elapsingTime`: puppet
poses, shader `g_Time`, effects such as a spinning planet) skips the warm-up and
advances `step` after each frame, so frame N draws at `N * step`.
`metal_scene_draw_smoke` ticks and advances both clocks by 1/60 s for
`WE_TEST_METAL_FRAMES` frames (120 by default) and writes the last one at
(frames − 1)/60 s on both, 119/60 s by default. Comparing the two harnesses, or
one render with a crop of another, therefore needs matched scene time: the Vulkan
run with `WE_TEST_FRAMES=4` and `WE_TEST_FRAME_STEP=0.6611111` (119/180) draws
frame 3 at the default Metal frame's scene time. A puppet posed at a different
scene time reads as a camera or backend fault. Seed both with the same
`WE_TEST_RANDOM_SEED`.

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

`offscreen_scene_probe` is Vulkan-only. With the Native Metal preference
(`scene_renderer = "native_metal_preferred"`), a scene the capability gate
accepts runs on the native backend with nothing behind it, so a probe result
describes a renderer that wallpaper may never use. Check the backend first —
`metal_scene_draw_smoke` with `WE_TEST_METAL_PROJECTS` prints the decision per
project — and repeat any comparison there before calling a difference
backend-independent.

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

What a later launch compiles again:

| Condition | Compiled again |
| --- | --- |
| First load, every cache cold | Metal source and pipelines |
| Next process, same location | Nothing |
| Same location, new `LC_UUID`, new `CFBundleVersion` or bundle replaced | Nothing |
| Same bundle id, another location | Metal source (the larger share); pipelines are shared |
| Compiled source missing only | Metal source |
| Compiled pipelines missing only | Pipelines (the smaller share) |

MoltenVK's pipeline cache stores the Metal source it generated, not compiled
code, and no `MVK_CONFIG_*` setting adds a binary archive. A binary archive, on
either backend, would hold only the pipeline row's share. Measured energy for
these conditions is in [performance](../features/performance.md).

## Regression areas that must stay covered

Each entry names the test that guards a behavior and the invariant or trap it
protects. Binaries in the `REGRESSION_BINARIES` registry run in
`scripts/check_renderer.py`. These do not, and must be built and run by hand
when their area changes (see [C++/CMake test binaries](#ccmake-test-binaries)):
`scene_schema_tests`, `script_runtime_compat_test`, `mouse_input_test`,
`mdl_schema_tests`, `tex_schema_tests`, `media_thumbnail_texture_smoke`,
`scenescript_media_event_smoke` and `scenescript_sound_layer_smoke`. Rust tests
(`module::test_name`) run through `python3 scripts/check_rust.py`; Swift tests
(`TestClass.testName`) run through `python3 scripts/test.py`. Tests that need
shipped Wallpaper Engine shaders or assets skip with a printed reason.

### Cameras, parallax and cursor mapping

- **Camera zoom** — `scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'`.
  Scene `general.zoom` may hold an authored scalar animation, not only a fixed
  camera scale.
- **Camera layers in 2D scenes** — in `scene_schema_tests`:
  `SceneSchema.CameraObjectKeepsAnOrthographicSceneOnItsCanvas` next to
  `.DefaultCameraObjectBecomesActivePerspective`,
  `.CameraObjectTimelineGlidesFromItsFirstShotToWhereItRests`,
  `.TheLastVisibleCameraObjectFramesTheCanvas`,
  `.AScriptedShotOriginFramesTheViewOnceATickHasAppliedIt` and
  `.PerspectiveShotsInheritSceneFovUnlessExplicitlyOverridden`.
  - `orthogonalprojection` decides what a scene is. When present, the canvas
    projects the scene (`ParseCamera` makes `cameras["global"]` the active
    orthographic camera) and every 2D layer's size, `origin` and `alignment` is
    authored in canvas space; a `camera` layer there is parsed, bound and
    scriptable like any node but never touches `scene.activeCamera`. When it is
    null, a camera projects the scene and a `camera` layer is the shot it plays.
  - The shot still frames the canvas it does not own: at the end of each tick,
    after every script and visibility/origin writer, `ApplyCameraShots` passes
    the last visible shot (authored order) to `Scene::FrameCanvas`. Its `zoom`
    narrows the orthographic view about the view centre, and its origin `x`/`y` is
    that centre's offset from the canvas centre, not a canvas coordinate. The
    perspective camera keeps its distance but takes the same centre and a field of
    view spanning the same visible height. With no visible shot the whole canvas
    shows, and nothing is reframed while zoom and offset stay the same.
  - A script-bound origin is pending until the first tick has applied it (the
    view stays on the canvas centre until then); the editor's static `value`
    beside such a script is never drawn. A relative origin curve offsets the
    authored origin; zoom and origin keyed together share the zoom's clock. A
    single-play timeline that has ended stops counting as animation demand, so
    an otherwise still scene can go idle after its intro.
  - Perspective shots with an omitted or nonpositive `fov` inherit the scene's
    resolved FOV (`perspectiveoverridefov`, then `fov`, then 50); a positive shot
    FOV overrides. Resolve it from authored scene settings, never from a shared
    camera an earlier visible shot may have changed.
  - Framing moves no node and rebuilds no graph, so a fullscreen layer's last
    pass uses the `fullscreen` camera (always the canvas), a layer sampled as
    `_rt_imageLayerComposite_<id>` is drawn through a layer-local camera
    (`LayerCompositeCameraKey`) that ignores placement, view and parallax, compose
    cameras are not layer-local (children draw through them at their place inside
    the layer), and the static-result cache folds each pass's camera and the
    active camera into its sample (`vulkan::FoldPassCameras`, shared by both
    backends).
- **Camera-object zoom in 2D scenes** — `SceneSchema.CameraObjectZoomTightensTheOrthographicFrustum`
  and `.CameraObjectZoomThatIsNotPositiveFramesTheWholeCanvas` in
  `scene_schema_tests`, `MouseInput.HitTestingFollowsACameraObjectZoomAcrossAResize`
  in `mouse_input_test`. `zoom` is applied when the ortho projection is built,
  not by writing camera width and height, because `ApplyCameraFillMode` rewrites
  those from the authored canvas whenever a fill mode is applied. Pointer mapping
  must read `SceneCamera::VisibleWidth/VisibleHeight` (the extent the projection
  uses), not `Width()`/`Height()`, or clicks and mouse-linked particles stay on
  the unzoomed image. The authored extent the render targets are sized from must
  not move with zoom.
- **Perspective camera shots and paths** — in `scene_schema_tests`:
  `SceneSchema.PerspectiveCameraSelectionFollowsVisibilityWithoutHiddenOverrides`,
  `.PerspectiveCameraPathsSampleAndQueueAuthoredCurves`,
  `.RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup`,
  `.CameraPathsPreserveSteepAndRolledLookAtOrientation` (near-vertical and Euler
  singularities), `.CameraPathsAndLayerTimelinesShareScaledAndZeroDeltas` and
  `.PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly`. The last
  effectively visible shot for a camera owns its pose and FOV; hidden presets
  cannot reattach that shared camera; with no visible shot the editor pose
  returns. Packaged eye/center/up/FOV curves share the path clock, with
  sequential or random queuing and bounded catch-up; only selected paths advance,
  hidden paths add no animation demand, and curves are parsed once. Camera-path
  zoom, path events and camera-cut fades are not implemented.
- **Camera parallax** — `ShaderValueUpdaterCompat.CameraParallaxFollowsTheCursorAndDepthNotThePosition`,
  `.ZeroParallaxDelayFollowsTheCursorAtOnce` and
  `.ParallaxLayersAreReportedAsFollowingTheCursor` in `script_runtime_compat_test`;
  `SceneSchema.ParserCopiesImageParallaxDepthToPuppetMaterialSlots` in
  `scene_schema_tests`.
  - In a 2D scene parallax moves a layer by the cursor's offset from the view
    centre times its `parallaxDepth`, scaled by `cameraparallaxamount` and
    `cameraparallaxmouseinfluence`. Where the layer sits, nested or not, plays no
    part, so with the cursor centred every layer rests where it was authored;
    adding the layer's distance from the camera pushes far layers out of frame.
    3D scenes keep that distance term.
  - A pass parallax moves is reported as following the cursor (`kParallax`),
    judged for the camera the pass draws through: static reuse redraws its
    target, and an on-demand scene wakes for the pointer. A layer drawn into a
    composite through its layer-local camera is not moved, so that composite stays
    reusable (`LayerTextureReference.AReferencedLayerIsItsCardWhereverTheSceneShowsIt`
    in `layer_texture_reference_test`). What this costs is under
    [Known limitations](#known-limitations).
  - `cameraparallaxdelay` of zero means no easing. Dividing by it makes the eased
    cursor NaN, which reaches every parallax layer's model matrix and leaves only
    the clear color on both backends.
- **Parallax inheritance** — in `scene_schema_tests`:
  `SceneSchema.ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder`
  (nesting, zero/default depth, missing/duplicate parents, cycles),
  `.ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers`,
  `.ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds` and
  `.ParentedPuppetSlotsFollowTheRootDepthAndKeepTheirLocalTransforms`; and
  `MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses` in
  `metal_scene_draw_smoke`. Parented layers take the outermost parent's
  `parallaxDepth`, including a zero or omitted one (Wallpaper Engine's
  [release notes](https://steamcommunity.com/app/431960/allnews/) confirm that
  the parent controls parallax on child layers). `ResolveLayerParallax`
  resolves it once at parse time, independent of declaration order and before
  materials are built, with no per-frame ancestor walk. Missing or ambiguous
  parents supply no depth, cycles stay unresolved, and IDs and parent references
  must be integers in the signed 32-bit range (wider JSON numbers are ignored,
  never truncated into another layer's identity).
- **Fullscreen layers** — `CameraFraming.AFullscreenLayerCoversTheScreenWhateverTheShot`,
  `.AFullscreenEffectCoversAPerspectiveScene` (independent of the perspective
  FOV) and `.MovingTheCameraChangesTheStaticSampleOfAPassItDraws` in
  `layer_texture_reference_test`. Fullscreen effects use the screen-space
  `fullscreen` camera in 2D and 3D scenes.
- **One cursor mapping, owned by the presentation** —
  `SceneRuntimeContext::SetCursorInput` maps window-normalized input through the
  cursor viewport the renderer publishes (`origin + (x, 1 - y) * size`) and writes
  it to `Scene::pointerScenePosition`, so consumers outside the script runtime
  read the same point instead of deriving their own. A particle control point that
  maps the pointer over the canvas (`pointerPosition * ortho`) agrees with the
  cursor only at the window centre once a wallpaper is cropped (`fill`) or
  letterboxed (`fit`). `ParticleMouseControlpoint.MouseControlpointFollowsTheCroppedPresentation`
  in `particle_mouse_controlpoint_test` (run by `check_renderer.py`) guards it.
  `offscreen_scene_probe` with `WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill` prints
  the mapping a running wallpaper would use. Nothing exercises `SceneWallpaper`'s
  own message loop offscreen, so the host's half (polling the pointer and
  publishing the viewport) is covered only by `mouse_input_test` at the unit
  level.
- **Cursor hit testing under scaling** — `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`,
  `.LayerHitTestingFollowsWhereTheWallpaperIsPresented` and
  `.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`;
  `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper`
  in `script_runtime_compat_test`. Scene coordinates reach the window through two
  transforms: the global camera rectangle fills the default render target, and
  `ComputeWallpaperScalingLayout` places that target in the window (`FILL`
  deliberately pushes it outside to crop). Cursor input arrives as a window
  fraction and is mapped back through both (`ComputeWallpaperCursorMapping` →
  `SceneRuntimeContext::SetCursorViewport`); mapping onto the raw canvas matches
  only when scene and display share an aspect ratio and otherwise squeezes every
  `cursorEnter`/`cursorLeave` box toward the screen centre. The mapping also
  reports the drawn content rectangle: coordinates extrapolate past it (scripts
  read positions outside the canvas), but named layers take cursor events only
  while the cursor is inside it, so letterbox bars never trigger a layer whose box
  crosses the canvas edge.
- **`engine.screenResolution`** has its own setter:
  `SceneWallpaper::publishScreenResolution` reports the display's pixels on scene
  attach and whenever the surface is replaced. `RenderInitInfo::width`/`height`
  already are those pixels (both backends divide by `display_scale_factor` for
  logical points), so scaling them again doubles the resolution on Retina panels.
  It is neither the world region the cursor mapping publishes nor the
  rasterization size: a quality setting must not move a script's layout.
- **Cursor coverage masks** — `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask`
  in `script_runtime_compat_test`. Hit tests run in the layer's local plane
  (rotated and flipped buttons keep their rectangle) and, for image layers whose
  scripts handle cursor events, consult a coverage mask sampled from the albedo
  at parse time (RGBA8/BC2/BC3, at most 256 texels per side, alpha ≥ 16 counts as
  covered): transparent texels do not hit, so overlapping triangle buttons do not
  fire together. Puppets, videos, sprite sheets and opaque formats keep the
  rectangle test. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises
  real assets.

### Scene scripts and property bindings

All in `script_runtime_compat_test` and `scene_schema_tests` unless noted.

- **Callback-only property scripts** — `*CallbackOnly*` in both binaries.
  Callback-only scripts keep their no-writeback behavior.
- **Script property load order** — `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue`.
  As in Wallpaper Engine, a layer's saved and user-bound `scriptproperties` reach
  the script after its module has run: top-level code reads the defaults the
  script declares, `init` and `update` read the values. A switch that moves its
  layers by the difference from a top-level reading stays where it was authored
  if the module already sees the user's position.
- **Module syntax** — `ScriptRuntimeCompat.ExportFollowedByUnicodeWhitespaceStillCompiles`,
  `.AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty` and
  `ScriptModuleSyntax.*`. `Scripting/ScriptModuleSyntax` is the one matcher for
  `export` and `export function update`, shared by the module rewrite and both
  update detections (`HasUpdateScript` in the parser, `wrap_script_if_needed` in
  the resolver). ECMAScript whitespace between the tokens counts, including the
  U+00A0 that text pasted from a rich-text editor carries and U+FEFF (not Unicode
  White_Space), and only where a statement can start, so `reexport` and
  `module.export` are not the keyword. Only the pure `ScriptModuleSyntax` test
  uses the rarer separators; the two that compile JavaScript through the linked
  QuickJS use U+00A0. The rewrite erases only the keyword, so a comment ending in
  the word keeps its line break.
- **Property-script feedback and hover easing** — `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping`
  and `.PropertyFeedbackResumesFromExplicitUserValueChanges`. `update(value)`
  receives the current value, including the previous frame's result and explicit
  property writes, not the authored value on every tick; that preserves iterative
  hover easing, full authored enlargement and continuous reversal on cursor leave
  and re-entry. JavaScript input conversion serializes only the value payload,
  without copying the live property's listener/subscription ownership.
- **Native writes survive `update()`** — `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined`.
  "Keep the current value when `update()` returns `undefined`" only works if the
  current value includes what the script wrote, so evaluation continues from the
  live dynamic value, not a private copy of the authored base. Native writes
  (`thisLayer.visible = …`, `origin`, `scale`, `angles`) arrive through the typed
  `DynamicValue::update` overloads and must reach the next `update(value)`. The
  canonical case hides its layer in `init()` and sets
  `thisLayer.visible = alpha != 0` in `update()` without returning a value.
- **Script-driven layer visibility** — `SceneSchema.HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin`.
  A layer setting may carry `value`, `user` and `script` at once. `value` is the
  script's initial value, never a permission to run it: a layer authored hidden at
  rest (day/night or weather switchers) still runs its script, and dropping the
  binding leaves a scene drawing only `general.clearcolor`.
  `PropertyScriptProgram::Evaluate` keeps the current value when a script throws,
  returns `undefined`, or returns an object for a boolean, so a hidden helper
  layer cannot be revealed by accident.
- **User properties and interactive scenes** — `applyUserProperties` runs once
  initially, then only for changed properties, after the whole property set has
  been refreshed. Exercise clock clicks and hidden-helper enter/leave through
  projected input (`WE_TEST_INPUT_JSON`, `WE_TEST_CLICK_*`), not by forcing
  overlay alpha. A closed author menu and an audio-driven wave with no audio are
  not evidence that a rendered frame has exercised either feature.
- **Alignment anchors under dynamic transforms** — `SceneSchema.ImageAlignmentAnchorSurvivesScriptedOriginAndScale`,
  `ScriptRuntimeCompat.RotatedAnchoredLayerTurnsAboutItsAnchor` and
  `.ScriptedRingBarsHangOutwardFromTheirCircle`, plus `nodes.txt` translate diffs
  from `offscreen_scene_probe`.
  - Alignment is an anchor, not a one-off offset. `SceneRuntimeContext` owns it
    for image and text layers and re-derives `origin + size * scale * 0.5` for the
    named edges whenever origin, scale, size or rotation changes; baking the
    offset into the node translate loses it as soon as a scripted or user-bound
    origin writes the translate, and ignores scale. Centre-aligned image layers
    carry no offset. An alignment a script sets on a layer that had none
    (`bar.alignment = 'top'`) offsets by the scale delta,
    `size * (scale - 1) * 0.5`, so the unscaled layer stays where it was authored
    and grows away from that edge; this is the renderer's own convention, since
    Wallpaper Engine's SceneScript reference omits `alignment`.
  - The offset is turned by the node's rotation (x, y, z order of
    `SceneNode::GetLocalTrans`), so a turned layer keeps its named edge on the
    origin. Every rotation write re-derives the anchor: `SetNodeRotation`
    (`layer.angles`), `RegisterNodeRotation` and the bound-angles pass of `Tick`.
    Unrotated layers keep the same arithmetic bit for bit.
  - Re-registering a node (`RegisterNodeVisibility`, `RegisterNodeTranslate`,
    `RegisterNodeScale` and `RegisterNodeRotation` all call `RegisterNode` again)
    must not re-seed an existing anchor from `node->Translate()`, which already
    contains the offset; `SetNodeAlignment` keeps the existing anchor mode. The
    double offset shows only on layers whose scale or origin is dynamic, which is
    why a static-origin/scripted-scale case is in the test.
- **Layer parents and scripted alpha** — `ScriptRuntimeCompat.LayerGetParent*`
  and `.LayerAlpha*`. `getParent()` is how an icon script reads its group;
  without it the whole `update` throws every frame. `layer.alpha` must reach
  `g_UserAlpha`, and only for layers whose authored alpha is not already owned by
  a timeline, an update script or a user property (two writers per frame fight).
- **Property and name bindings** — `ScriptRuntimeCompat.AuthoredColorPropertiesStayVectorsAcrossTicksAndPropertyChanges`:
  `createScriptProperties().addColor(...)` exposes a `Vec3` even when the saved
  `scriptproperties` stores RGB as a space-separated string, and again after
  native property updates replace the value; `addText` values stay strings.
  `SceneSchema.DuplicateNamesResolveInAuthoredOrderWithoutSharingThisLayerBindings`
  and `.DuplicateLayerAliasesIgnoreMalformedEntriesAndKeepValidLookup`: duplicate
  non-text layer names keep separate internal binding keys; SceneScript name
  lookup selects the first declaration in authored order (including lookups made
  while a script module initializes) while each layer's `thisLayer` addresses its
  own key; the alias pass skips non-object entries, non-string names and
  nonnumeric IDs. A text label that repeats another layer's name keeps its own
  runtime key (`__we_text_<id>`, asserted in `text_object_runtime_test`), so
  `getLayer("s")` addresses the layer that owns the name.
- **Video-controlled visibility and music scripts** — `scenescript_media_event_smoke`:
  `getVideoTexture().isPlaying()` reflects shared runtime pause/play state, so
  scripts that hide a layer during init can reveal it during update; `Vec*.mix`
  and `MediaPlaybackEvent` constants are available.
- **Creating layers from scripts** — SceneScript creation tests cover independent
  cloned layers, owner-local cached factories, bounded authored pools and lazy
  template loading. A script imported from the Workshop declares
  `export let __workshopId = '<id>'` and names its assets as in its own project
  (`models/bar.json`) while the editor stored them under `models/workshop/<id>/`;
  `thisScene.createLayer` passes the id on, and the runtime tries the workshop
  folder only after the path as written, the owner's own workshop folder and the
  lazy loader have found nothing. `ScriptRuntimeCompat.CreateLayerFindsTheAssetsOfTheWorkshopItemItsScriptDeclares`,
  `.CreateLayerPrefersThePathAsWrittenOverTheDeclaredWorkshopItem` and
  `.CreateLayerLooksInAWorkshopFolderOnlyForANumericDeclaredItem` cover the
  lookup. Template source layers are usually hidden and never parsed, so the lazy
  loader builds the template from the bare model: visible (copies start as copies
  of it) and as large as the model's picture when the model states no size
  (`SceneSchema.ALayerCreatedFromAWorkshopModelIsSizedByItsPictureAndShows`); a
  zero-sized hidden template makes every lazily created layer invisible.
- **Timeline events** — `ScriptRuntimeCompat.*Timeline*Event*`, `*Marker*`,
  `GlobalAnimationListenersRunOncePerMarkerWhateverIsBound`,
  `GlobalOnlyAnimationListenerSeesTheCurrentTickTime` and
  `SceneGetAnimationFindsATimelineOnAnotherLayer`: crossing, `event.frame`,
  reverse travel and exact loop wraps, delivery after `init`, one global listener
  run per marker with zero and two bound scene scripts, a fresh host context for a
  global-only listener, and scene-wide `getAnimation`.
  - `ScalarAnimationPlayback::Advance` queues every `options.events` marker the
    playhead crosses as a whole `ScalarAnimationEvent` (`frame` beside `name`);
    departure is exclusive and arrival inclusive, in both directions. A loop runs
    on a circle, so a wrap, an exact landing on the seam and a marker authored at
    the period are the same point, reverse travel is symmetric, travelling a whole
    period or more reports each marker once, and markers arrive in the order the
    playhead met them. `SetFrame` is a jump and reports nothing.
  - `SceneRuntimeContext::Tick` drains the queue after advancing the clocks *and*
    re-evaluating scripted values (a property script initializes lazily, so a
    marker crossed by the first tick must still reach an initialized handler) and
    calls `animationEvent` on the property and scene scripts bound to the
    timeline's layer. The global `engine.on`/`scene.on` list runs once per marker,
    not once per matching program, and refreshes `engine.runtime`/`engine.frametime`
    itself. Every crossed marker is collected before any handler runs, because
    handlers create, hide or destroy layers.
  - `thisScene.getAnimation(name)` exists beside the layer's `getAnimation`: a null
    layer argument to `__animationControl` matches the name across every
    registered timeline (`SceneRuntimeContext::FindAnimationByName`).
- **Puppet animation layer control** — `ScriptRuntimeCompat.PuppetAnimationLayer*`:
  `getAnimationLayer(name).play()` restarts a finished single-shot layer on every
  copy of the shared state; a `visible` bound to a user property toggles the
  layer. Puppet animation layers are one shared playback state per image object
  (`WPPuppetLayer` copies share it), registered under the layer name and backed by
  `SceneRuntimeContext::PuppetAnimationControl`. Authored layers start playing; a
  single-shot layer holds its last frame and reports stopped.
  `animationlayers[].visible/rate/blend` bound to user properties follow the
  property like any other setting.
- **Vector material constant timelines** — `SceneSchema.*VectorTimeline*` and
  `SceneSchema.SharedVectorTimelineWrapsOnlyOnTheParentClock`,
  `ScriptRuntimeCompat.VectorMaterialTimelineDrivesEveryComponentSeparately` and
  `.ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding`, and the
  `generated-perspective-animation` case in `check_renderer.py`. Each component of
  a material constant resolves its own curve (`c0`–`c3`) and its own entry of the
  initial value; unanimated components keep that value. The constants of one
  material pass are collected first, `options.parent.key` is walked to its root
  with memoized results, and the whole group shares the root's single
  `ScalarAnimationPlayback`, so `thisLayer.getAnimation(name)` drives it and
  looping and restarting happen once, on the root. Sampled component copies are
  single-shot, so a short child curve holds its last key instead of wrapping on
  its own length. A missing parent, a parent without a usable animation, or a
  cycle logs once and freezes that group on frame 0; relations never cross
  material passes. Without the curves a perspective quad's homogeneous `w` terms
  go negative and the quad inverts into a spike; the generated case asserts the
  page covers the centre and the margin stays clear (a blank or all-white frame
  fails too).
- **Scripted vector material constants** — `SceneSchema.ScriptedMaterialConstantsKeepTheComponentsTheShaderDeclares`:
  a script that swaps a `vec2`'s components only produces the authored numbers
  when it is handed a vector, not the text `[x,y]`. Constants resolve at the
  authored component count: one component as a float, two and four through
  `ResolveVectorSetting`, three through `ResolveVec3Setting`; a constant with no
  authored value has no count to preserve and still resolves as a string.
- **Compiled exports and caches** — compiled script exports suppress only absent
  handlers; initialization, scheduled callbacks, shared scene callbacks,
  live-value fallback and live alpha/geometry hit order stay covered by
  `script_runtime_compat_test` and `mouse_input_test`. Transform/material caches
  avoid recomputing sources but still repair changed destinations in the
  original phases; a failed registration releases only its new
  subscriptions/values and restores existing mask/puppet identity.
- **Scene commits in headless tests** — `scene_schema_tests` helpers wait for
  posted work with a render-looper round trip (`beginSurfaceReconfigure`) and a
  main-looper one (installing a pointer callback replays from the main looper)
  before `shutdown()`, which stops the loopers without draining them. A test that
  posts a scene and shuts down at once measures a race. A graph that never
  reached a backend is simply dropped by the next scene.

### Layers, textures and compositing

- **3D model materials and skinning** — `SceneSchema.ModelMaterialDefaultsAreOpaqueDepthTestedAndExplicitStateWins`
  and `.ModelBonesReachEveryMaterialIncludingTheBindPose` in `scene_schema_tests`.
  Model materials default to normal blending, back-face culling and enabled
  depth test/write; explicit pass settings win, and image defaults are
  unchanged. Skeletal models share one `WPPuppetLayer` playback across material
  slots, attachments and runtime animation controls, including bind-pose uploads
  when no clip matches, with no extra render passes or texture allocations.
  `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions`
  in `mdl_schema_tests`: mesh format versions do not justify flattening an
  authored skeleton. Versioned model fixtures cover MDLV13–23 attribute layouts.
- **Perspective model contracts** — the parser selects the index width from the
  vertex count (32-bit indices above 65535 vertices; reading that blob as uint16
  triples rejects the mesh or draws scrambled triangles), and the vertex cap is
  4 million. `g_NormalModelMatrix` is a std140 `mat3` (48 bytes) and uniform
  writes are clamped to the reflected member size, so an oversized write cannot
  spill into `g_ViewProjectionMatrix`. Culled model passes keep Vulkan's
  counter-clockwise front face (clockwise culls skyboxes on MoltenVK even though
  `recordDraw` uses a negative viewport height). A perspective far plane is
  padded by a tenth of a percent so a skybox scaled to exactly `far` is not
  clipped off-centre. An image layer's `alpha` `update` script or user property
  is applied to `g_Alpha`, not only an animation timeline. Perspective particle
  billboards keep object scale while authored 2D canvases keep their pixel-size
  compensation; quantity remains the documented emission-rate factor, not a
  replacement for the authored maximum count.
- **Layer textures tiled across models** — `LayerTextureReference.CompositeAddressingFollowsTheSourceLayersClampUvs`
  in `layer_texture_reference_test`. `_rt_imageLayerComposite_<id>` repeats when
  the source layer says `"clampuvs": false` and clamps when it is true or absent;
  otherwise a model whose UVs run far outside 0..1 smears the composite's edge
  texels into solid bands.
- **Layer as texture** — `layer_texture_reference_test` (CPU, in the gate):
  `_rt_imageLayerComposite_<id>[_a|_b]` forward refs, duplicate names, missing
  targets, cycles, history `_b`, file names vs layer names, invisible sources
  kept, producer-before-consumer graph order, and an effect-chain source linking
  from its composite rather than `_rt_default`.
  - A composite is the source layer's card in its own texture space, whatever
    its placement, the scene camera or parallax do
    (`AReferencedLayerIsItsCardWhereverTheSceneShowsIt`). A compose layer's
    camera is not layer-local: its children keep their place inside it
    (`ComposeChildrenKeepTheirPlaceInsideTheLayer`), and a `composelayer` drawn
    into its own composite still samples the screen behind it
    (`ScriptRuntimeCompat.ComposeBackgroundUsesScreenCameraAndParentTransform`
    in `script_runtime_compat_test`).
  - A compose layer that only copies the background is skipped unless another
    layer samples it; then it is drawn into its composite and nowhere else, since
    its card covers its whole target (`ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`).
    A mask that paints that background back over later layers otherwise has
    nothing to sample, and native Metal falls back.
  - A linked composite's size is never folded into the material as a zero at
    parse time (the card padding divides by it and every texture coordinate of
    the consumer's card becomes `NaN`), and nothing stale is folded in its place:
    the shader reads the target's real size whichever the backend uploads last,
    constants or live values (`AReferencedCompositeIsSampledAtItsRealSize` checks
    both orders).
  - `ExternalMaterialsKeepHiddenTransitiveProducers` covers texture references
    absent from the scene JSON.
- **User-chosen scene textures** — `MediaThumbnailTextureSmoke.TextureProperty*`,
  `.UnsetTexturePropertyKeepsTheAuthoredTexture` and
  `.AnUnreadableUserFileKeepsTheAuthoredTexture` in `media_thumbnail_texture_smoke`;
  `TexSchema.AbsolutePath*`, `.PackagedLooseImageStillLoadsFromTheMount` and
  `.OnlyAReadableHostPictureCountsAsOne` plus
  `SceneSourceMount.APresetFileBesideThePackageLoadsAndThePackageStillWins` in
  `tex_schema_tests`. A `usertextures` entry is either a cover slot the runtime
  supplies or the name of a `scenetexture` property. The property stores a path,
  not a copy, so a slot is only replaced when that file opens at load; unset,
  moved and unreadable all keep the authored texture. Origin travels on
  `LooseAssetCandidate`, never re-derived from the path: a mounted
  `/assets/materials/foo.png` is absolute too, and deciding by `is_absolute()`
  sends every packaged loose picture and video to the host filesystem, where none
  exist. A Workshop preset names its own pictures and videos relatively
  (`files/clip.mp4`) and ships them beside its base's `scene.pkg`, so
  `MountSceneSource` mounts the project folder under the package: packaged files
  still win, and the probes mount the same way. With only the package mounted
  those layers draw black and native Metal falls back.
- **JPEG/EXIF orientation** — `tex_schema_tests`: all eight EXIF display
  transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated
  JPEG/EXIF data, invalid IFD offsets.
- **Render scale** — `RenderScale.*` in `render_scale_test`: physical surface
  sizing and scale/resize transitions (full scale keeps every target at the
  authored size, half scale halves the raster but not the authored canvas,
  three-quarter scale rounds rather than truncates, returning to full scale
  restores the exact size) without changing 2D canvas behavior; a perspective
  raster follows the surface without changing the canvas fallback.
- **Random sprite-sheet frames** — `ParticleMouseControlpoint.SpawnedParticlesCarryAStableFrameValueSpreadOverTheSheet`
  in `particle_mouse_controlpoint_test`. A `randomframe` particle keeps one frame
  for its life, derived from its spawn state rather than drawn from the random
  source, so seeded particle layouts do not shift (an integral value would
  always select frame 0).
- **Rope and rope-trail geometry** — `particle_rope_geometry_test` (CPU, in the
  gate): pieces per instance and never across instances, dead particles skipped
  and neighbours joined, subdivision through the particles, coincident points
  without `NaN`, the rope-trail head, tail shrink and per-slot separation, and the
  simulation's history — birth point, growth to capacity, zero time step, respawn
  reset. Index width: packed 16-bit up to 16 384 quads, 32-bit past that,
  overflow-safe capacity math, and draw order across instances on a 32-bit mesh.
- **Hidden particle geometry** — `ParticleSystem::RebuildVisibleMeshes` runs after
  `Tick` and rebuilds a hidden subsystem on the frame it becomes visible or must
  produce; the simulation still runs while it is hidden.
  `ParticleHiddenGeometry.LayerShownByTickAfterEmittDrawsWhatAlwaysGeneratingDraws`
  shows a layer (or its parent) in the Tick after Emitt and compares the first
  visible frame's mesh bytes with an always-visible run; `particle_rope_geometry_test`
  and `particle_mouse_controlpoint_test` cover the geometry; a fixed-seed
  `offscreen_scene_probe` dump of a hidden-then-shown particle scene must stay
  byte-identical to a build that generated every frame.
- **Matrix packing and live uniform updates** — `ShaderValuePacking.*` and
  `ShaderValueUpdaterCompat.*` in `script_runtime_compat_test` cover column-major
  values, row-major/strided inputs, inline/dynamic/empty ownership and current
  camera/effect/material-slot values. `PlaybackGPU.FrameUpdatesAreVisibleBeforeUpload`
  checks updated color/geometry and hidden output on the real GPU.
  `PlaybackGPU.LiveTexelSizeOverridesParseDefaultsWhileMaterialValuesStayLive`
  checks actual output pixels and changing user material constants: Compatibility
  and Native Metal write live engine uniforms after parser defaults.
- **Lighting projection** — `MetalSceneDraw.LightingViewDirectionFollowsTheAuthoredSceneThroughEffects`
  checks lit and unlit pixels for both projections, directly and through
  effects. Material compilation sets `SCENE_ORTHO` from the authored scene
  projection on both backends, effect passes included, so a 2D layer uses the
  shader's fixed view direction rather than a perspective eye on the layer's
  plane (which reduces its lighting to ambient-only). Material overrides cannot
  change this scene-owned switch, and the shader request/cache key includes it.
  This fixes projection selection, not the approximate `PerformLighting_V1`
  compatibility helper; full authored-light parity is unverified.
- **HDR, bloom and emissive masks** — an authored `hdr` scene uses RGBA16F color
  intermediates on both backends; masks and source media keep their formats and
  SDR scenes keep RGBA8. HDR shader combos are enabled before compilation, not
  approximated by raising final display brightness, and the fourth
  texture-component flag (TEX bit23) travels through the C++/Rust compiler
  interface so an alpha-channel emissive mask can enable its shader branch.
  Missing HDR materials fail rather than silently substituting LDR. HDR bloom
  uses the supplied downsample, additive upsample and SDR-combine materials;
  the pyramid is bounded to 12 levels with source-sized sample offsets refreshed
  at prepare/resize. The bounded model maps positive spread `s` to a coarse-level
  weight `s / (1 + s)` and divides extraction strength by the sum of the pyramid
  weights, so spread redistributes energy rather than amplifying a constant
  field; zero strength disables the halo and negative spread has the same narrow
  kernel as zero. These are this renderer's defined semantics, not a verified
  reproduction of Wallpaper Engine's proprietary parameter mapping.
  `MetalSceneDraw.HdrSpreadPreservesEnergyAndStrengthScalesTheHalo` checks GPU
  pixels across live strength/spread changes (large spread and zero strength
  included); `.ParsedHdrRadianceSurvivesEffectsLayerLinksAndBloom` uses an
  original bit23 emissive texture through the real parser, effect chain and layer
  references. `MetalSceneDraw.OverbrightRadianceReachesBloomWithoutChangingLdrColor`
  and `PlaybackGPU.OverbrightTargetsFeedBloomAndPreserveSdrColor` read pixels and
  unclamped radiance on the native and Compatibility backends, and
  `SceneSchema.HdrBloomRejectsMissingHdrMaterialsRatherThanFallingBackToLdr`
  guards the parser.
- **Render targets and texture allocation**
  - Texture residency comparisons must cover the scene's full visibility and
    crossfade cycle, including the moments when each affected image is actually
    visible; matching startup frames can miss large animated layers whose
    opacity is still zero.
  - Native Metal allocates only targets the compiled passes name.
    `metal_scene_draw_smoke` checks that a declared but unused target stays
    unallocated through optimisation off/on, and that a copy the plan drops as
    dead is not made while the optimisation is on and gets its image back,
    filled, when it is turned off without a recompile. Compare target residency
    with the harness's render-target bytes, not the device-wide allocation.
  - `render_target_lifetime_test` checks 32 generated multi-version graphs
    against a last-access oracle, plus nested composites with aliases, three
    sizes, visible and hidden parents, and background-copy enabled/disabled.
    Alias clears and readers must refer to the same canonical resource. Pooled
    targets are retained until every logical version has finished, and effect
    inputs are cleared explicitly when `copybackground=false`; the test asserts
    version lifetimes and a real transparent writer before an effect samples its
    empty input.
  - The check's eight generated nested-compose scenes compare pooled and isolated
    allocation byte for byte and add known-pixel assertions that empty inputs do
    not leak old pixels and that children actually render.
  - A target the frame reads before anything writes it, and writes later, carries
    the previous frame's pixels (a motion-blur history buffer). The render graph
    flags it (`carriesPreviousFrame`), and the Vulkan renderer and the offscreen
    probe reserve it an image of its own before preparing passes, so it is never
    pooled; pooled, it would take an image another target redraws every frame and
    a trail would blend in a faint copy of some other layer. The scene output is
    exempt (the frame's prepass clears it first). `RenderTargetLifetime.OnlyTargetsReadBeforeTheFrameWritesThemKeepTheirOwnImage`
    and `.CarriedOverKeysAreTheOnesReadBeforeTheirFirstWrite` cover the graph,
    `PlaybackGPU.CarriedTargetsShareTheirImageWithNoOtherTarget` the reservation.
    It costs exactly those buffers' memory.
- **Render-target reuse correctness** — `static_subgraph_cache_test` (reuse
  verdicts, copy elision, alias resolution, and `OnlyWritersOfCacheableTargetsAreSampled`:
  both backends sample only the passes `Plan` reads, and an unsampled pass cannot
  change a verdict) and, on the native backend,
  `MetalSceneDraw.AnUnchangedTargetIsReusedAndProducesTheSamePixels` and
  `.TurningTheOptimisationOffDrawsEveryPassAgain` in `metal_scene_draw_smoke`.
  Reuse must be provable by readback, not by a counter alone: a skipped pass has
  to leave byte-identical pixels, and a changed input has to redraw. On
  Compatibility, `PlaybackGPU.APooledImageAnotherTargetStillDrawsIntoIsNeverPinned`
  in `playback_gpu_test`: a target whose pooled image it took from a key that
  released it is never pinned, because that key's prepared passes still draw into
  the image every frame; pinning it lets a skipped layer read another layer's
  picture from the second frame on, which the pooled/isolated comparison in
  `check_renderer.py` shows as a divergence.
- **Direct presentation and reuse** — a frame that drew straight into the
  drawable leaves the scene's output target unwritten, so the reuse record for it
  is dropped (`VulkanRender::drawFrameSwapchain`); reusing it through the final
  blit would compose an image nobody drew.
- **Sprite-sheet stepping and reuse** — `MetalSceneDraw.ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges`.
  A sheet between frame changes may be reused, but its clock must keep running or
  the animation never reaches the next frame. `sprite_animation_test` checks
  elapsed time across cadences and long loops.

### Alpha compositing

- **Source-over coverage** — the `generated-alpha` case in `check_renderer.py`.
  `SetBlend` (and the native `MetalBlend` state) writes source-over's
  `As + Ad*(1-As)` for `BlendMode::Translucent`: the color source factor is
  `SRC_ALPHA` but the alpha source factor is `ONE`. With `SRC_ALPHA` for both,
  every translucent draw loses coverage on partially covered texels, nested
  compose layers multiply the loss, and soft anti-aliased seams show a thin
  saturated line. Opaque and fully transparent texels are unaffected. The case
  composites a half-covered source over transparent, half-covered and opaque
  destinations inside a compose layer and samples the composed alpha back as RGB
  (expected 128/191/255). It uses synthetic shaders only.
- **Alpha-to-coverage passes** — `MetalBlend.*` in `metal_backend_test`; the
  Compatibility backend sets the same state in `SetBlend`. On multisampled
  attachments coverage decides what an `alphatocoverage` pass keeps and kept
  samples are written unblended, as in Direct3D (blending as well multiplies
  partially covered texels by alpha a second time and dims thin lines). On
  single-sample targets both backends disable coverage and use source-over
  blending, otherwise transparent or partially covered pixels become opaque.
  Scenes stay single-sampled, so edges are thresholded rather than antialiased.
  `generated-alpha-single-sample` verifies composed coverage on Compatibility
  (128/191/255), `MetalSceneDraw.SingleSampleAlphaCoveragePreservesTransparentAndPartialPixels`
  checks zero, half and full coverage as RGB on Native Metal across repeated
  frames, and the CPU blend-state tests keep the unblended multisample
  contract. None of this adds MSAA targets, render passes or allocations.

### Text, fonts and clocks

- **Fonts and limits** — `text_object_runtime_test`. Font decoding prefers valid
  authored bytes, then a usable installed family, then a platform fallback;
  missing paths and malformed embedded fonts use the same fallback for both
  measurement and rasterization. Coverage spans seven font choices and three
  text samples including Chinese, plus missing/corrupt sources and valid assets,
  and checks actual glyph coverage rather than just nonempty strings. Authored
  `maxwidth`, `maxrows`, `limitwidth`, `limitrows` and `limituseellipsis`
  constrain both measurement and rasterization, including dynamic text updates:
  `TextObjectRuntime.WidthAndRowLimitsProduceTheSamePixelsAsExplicitLineBreaks`
  and `.EllipsisFitsTheLastVisibleRowAndLimitFlagsRemainIndependent` compare the
  rendered pixels and layout bounds, and FreeType and fallback fonts share the
  same wrapping and truncation rules.
- **Cache metadata and corruption** — `render_target_lifetime_test`,
  `text_object_runtime_test` and `shader_cache_metadata_test` cover clock/text
  corruption, persistent shader-cache metadata, cache invalidation after include
  edits, corrupt-cache recovery, parent-aware compose-background sampling, and
  SceneScript AM/PM sprite-frame selection. They create no window and no Vulkan
  device.
- **Clocks** — `ShaderValueUpdaterCompat.DayTimeUniformFollowsLocalClockAndWrapsAtMidnight`
  injects a wall clock and checks `g_Daytime` and the compatible `g_DayTime`
  spelling as the local fraction of a day.
- **Raster caches and revisions** — text raster caches hold neutral glyph
  coverage. Color, brightness and alpha bindings reach uniforms, including text
  under effects, without relayout or uploads
  (`MetalSceneDraw.TextStylingChangesPixelsWithoutRerasterizingGlyphs`). Text
  scripts first run on the normal ordered tick, not while objects are still being
  parsed. The layout queue is FIFO and coalesces updates in place;
  `TextObjectRuntime.AWaitingClockIsNotStarvedByNewerReadoutUpdates` blocks the
  worker deterministically to verify that newer readouts cannot overtake a
  waiting clock. Completed glyph images publish in revision order even when a
  newer value is pending, so continuously changing labels never stay blank
  waiting for an exact-current revision; the test compares the published glyph
  pixels before and after catching up. An effect target grows geometrically, up
  to 4096 per dimension, only when its caption outgrows the current capacity, and
  that size change requests a graph rebuild.
- **Text layers on the native backend** — `MetalSceneDraw.ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend`:
  a parsed text object, the text program translated to Metal, the rasterised
  glyphs imported and the card drawn into the scene's own target. A text layer
  must reach the backend through the ordinary parser, not through a hand-built
  mesh.
- **Unchanged text costs nothing** — `MetalSceneDraw.TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`:
  twelve frames of an unchanged string measure nothing and upload nothing, a new
  string costs at most one upload per in-flight frame and reaches the drawn
  picture, and it then goes quiet again. The script keeps running throughout;
  "quiet" must never be achieved by stopping it.
- **Text layers under an effect chain** — `MetalSceneDraw.ATextLayerWithAnEffectChainKeepsBothOfItsCards`:
  a text layer with effects has three meshes the relayout rewrites — its own
  card, the chain's final card and the node the chain resolves its last pass onto
  — and all of them have to be accepted and updated, or the scene falls back as a
  whole or freezes at its first layout. Use text whose glyphs differ, not more of
  the same word: the chain clips the card to its buffer, so a longer repetition
  can leave identical pixels.
- **Opt-in local-asset diagnostic** — `TextObjectRuntime.LonelyCatHeadlessRegression`
  in `text_object_runtime_test`: set `WE_TEST_PROJECT`, `WE_TEST_ASSETS` and a
  disposable `WE_TEST_CACHE`, then run with
  `--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`; add
  `WE_TEST_EXPECT_WARM=1` for a second run. It parses the package, ticks scripts
  and constructs the render graph; it does not initialize playback, capture the
  desktop, or modify the imported wallpaper.

### Animation and puppets

- **Non-additive layer weights** — `MdlSchema.NonAdditiveLayersShareTheWholePoseWeight`
  (normalized and partial weights, rotation, scale, loop wrap, repeated samples)
  and `.NonAdditivePoseMixRetainsDistinctMotionAndAdditiveOffsets` (distinct
  animations, additive overlays, live blend/visibility changes) in
  `mdl_schema_tests`. Non-additive puppet animation layers use their effective
  blend weights for the entire pose (translation, scale and rotation), including
  offsets from the reference pose; otherwise overlapping layers double
  character-sheet assembly offsets and separate attached pieces. Additive layers
  keep their authored weights. The prepared weights are reused: no per-frame work
  or GPU resources are added.
- **Puppet lighting** — `MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly`
  covers all eight combinations of puppet/card, effects/direct and lit/unlit over
  repeated draws. Puppet layers with effects light their assembled geometry only
  in the final skinned pass; the input texture-sheet pass is unlit, so lighting
  is neither multiplied twice nor baked into the separate cut-out pieces.
  Unskinned layers, effect-free puppets and unlit materials keep their lighting
  paths.
- **`colorBlendMode` on puppets** — `RenderGraph.puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen`
  in `rendergraph_smoke`. A layer's `colorBlendMode` mixes it with the screen
  behind it, so only the pass that draws onto the screen may sample it. On a
  puppet with bones that is the final skinned pass, which takes `BLENDMODE`
  itself; the separate passthrough that cards and mesh-only puppets end with
  would otherwise run before it, over the texture sheet, and paint a shrunken
  copy of the whole wallpaper inside the layer. The passthrough is dropped, not
  added to. The test parses a one-bone puppet and requires the only
  screen-sampling pass to be the one writing the scene.
- **Four-light shaders** — `ShaderValueUpdaterCompat.FourLightColorsRoundTripThroughPackedUniforms`
  in `script_runtime_compat_test`: legacy four-light shaders pack the fourth
  light's RGB into the `w` lanes of three color uniforms; zero through five
  lights, channel order, radius/intensity premultiplication, the four-light limit
  and clearing after lights are removed.
- **`origin.animation`** — `SceneSchema.OriginTimeline*` (aligned images,
  text/groups, absolute/relative keys, loop duration, paused playback,
  seek/replay, completed timelines releasing animation demand),
  `MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen` (pixels
  before, during and after a reveal on direct and effect-chain layers) and the
  `generated-origin-animation` case in `check_renderer.py`, which verifies both
  halves after the intro under pooled and isolated allocation. Authored layer
  `origin.animation` uses one playback clock for its three curves. Relative keys
  offset the authored origin, not the previous tick; unkeyed axes keep their
  values. Scripts and user properties keep precedence, anchors and effect-final
  cards follow the existing transform path, and orthographic shots keep their
  shared origin/zoom clock. Static origins add no tick binding, and held
  animation frames do not re-evaluate curves.
- **Puppet attachments and poses** — puppet attachments use the animated bone
  affine each frame while preserving the child layer's authored/script
  transform. Character-sheet reference poses are decoded separately from cut-up
  bind geometry so additive and non-additive animations reassemble correctly, and
  puppet animation deltas use the skeleton reference pose, not the first
  animation sample, preserving initially collapsed eyelids and authored
  rotations. Synthetic regressions cover declaration order, animated
  translation/rotation/scale, repeated same-time samples and local edits.
- **Scalar material timelines** preserve paused first keys and authored Bezier
  handles; SceneScript named animation controls drive play, replay, pause, stop,
  seek and rate.

### Shader pipeline

Rust regressions in `crates/shader/tests` (`legalize`, `preprocess`,
`video_planes`, `pipeline`) cover these paths with synthetic shader sources;
`pipeline` skips asset-dependent cases with a printed reason.

- **Pipeline revision** — `ShaderPipelineRevision::CURRENT`
  (`crates/shader/src/pipeline/revision.rs`) is part of the cache key. Bump it
  whenever codegen can produce different output for source that already
  compiled; each bump invalidates previously compiled programs.
- **Repairs for permissive-path shaders** — the pipeline handles undersized
  cross-stage varying declarations, conditional helper headers, source-defined
  `log10`, legacy scalar/vector argument conversion, compound assignment
  narrowing and scalar initializer conversion. Floating remainder uses a
  generated typed helper accepted by Naga, preserving truncating remainder and
  single evaluation of its operands. Active `#undef` directives remove macros
  across includes; inactive branches leave them intact. Generated NV12 members
  create and bind a uniform block even when a material has no authored scalar
  uniforms. It also absorbs idioms author shaders inherit from the permissive
  path they were written against, each of which otherwise drops a whole effect
  rather than one expression: a texture annotation's `"default":""` means the
  slot has no default; `CAST2`/`CAST3`/`CAST4` are vector constructors before
  `legacy_builtins` renames them; mixed-width vector operands inside a call
  argument truncate to that expression's narrowest operand, while sampler
  coordinate arguments stay with the texture strategy that narrows them to the
  sampler's dimensionality; and a parenthesized comparison used as an arithmetic
  operand is converted with `float(...)`. Known and not handled: logical-not
  applied to a float (`!someFloat`), which still rejects Wallpaper Engine's own
  `clipping_mask` effect.
- **Legacy effect shader interfaces** — `pipeline` tests: array varyings reserve
  all element locations; unambiguous user function parameters narrow wider vector
  arguments; a whole vector variable assigned to a narrower one keeps its leading
  components (`pipeline_narrows_whole_vector_identifier_assigned_to_narrower_target`,
  the shipped `cloudmotion` effect's `v_NoiseCoord = v_TexCoord`); custom
  scalar/vector uniforms across stages share a vector block with stage-local
  prefix views. Engine `g_*` uniform type conflicts remain errors.
- **Varying arrays sized by a numeric combo** resolve the macro before generated
  interface declarations are emitted and reserve one location per element, like
  literal-sized arrays. Location planning and emission use the same
  `interface_array_size` resolver at each declaration's source position: all
  earlier active directives count (including macros changed between ordinary
  items or inside earlier function bodies), later changes do not resize an
  earlier array, and bounds must be positive integer literals or visible
  object-like macros with positive integer values. Expressions, missing
  definitions (including those defined only after the declaration), zero and
  negative sizes produce an explicit diagnostic rather than silently reserving one
  location. `pipeline_resolves_macro_array_bounds_at_each_declaration` and
  `pipeline_rejects_unresolved_interface_array_bounds_before_layout` cover both
  backends; `pipeline_compiles_macro_sized_varyings_without_overlapping_locations`
  and `pipeline_legalizes_nested_legacy_calls_in_macro_replacements` compile both
  SPIR-V and MSL and cover annotation defaults, explicit counts, consecutive
  arrays and nested object/function macros. Legacy builtin calls in `#define`
  replacements are rewritten inside function bodies too. These are compile-time
  repairs for rejected shaders, not brightness adjustments: restoring a dropped
  effect restores its authored GPU work and target allocation, with no new
  per-frame CPU path or compensating render pass.
- **Uniform array layout is a contract** — a scalar or narrow-vector array in the
  generated uniform block is declared `vec4 name[N]` and every subscripted read is
  swizzled back. std140 pads each element to 16 bytes, which is what the host
  packs and the reflection reports, while the MSL backend emits the natural tight
  stride; without the repair every member after such an array is read from a
  different address on Metal than the host wrote it to. The swizzle follows reads
  reached through `#define` aliases (written inside `main` by the audio-bars
  shader family) and through array-parameter specialization, not just direct
  ones.
- **A sampler slot's `combo` answers whether the material bound a texture there**,
  which is not the same as whether the slot is bound. An annotation's `default`
  exists so an unused sampler still reads something sane; `WPSceneParser` binds
  it, then reports the slot as unbound to the compiler so the combo stays 0.
  Feeding the defaulted list back turns every `{"combo":…,"default":…}` sampler
  permanently on (a `rounded_mask` then reads its corner radius from a white
  default instead of `u_Radius`). A slot the combo leaves unsampled is cleared
  afterwards, so nothing holds a texture it never reads.
- **Texture-driven switches are discovered before stripping conditional
  branches**: `#if USE_MASK` can contain the sampler annotation that defines
  `USE_MASK`, and discovering it only after preprocessing drops authored masks
  and lets localized brightness pulses affect the whole image. Only
  texture-derived switches are seeded this way; ordinary combo defaults still
  follow evaluated branches, and explicit material overrides still win. This is
  compile-time work with no added passes, temporal filtering or quality
  reduction; an active mask keeps its texture and sampling cost.
  `conditional_texture_annotations_enable_the_sampled_mask_on_both_backends`
  covers includes, cross-stage switches, absent/default-only textures and explicit
  overrides for SPIR-V and MSL, and `PlaybackGPU.AConditionalMaskKeepsPulsesOutOfTheMaskedRegion`
  reads six alternating-brightness frames: masked pixels stay fixed while the
  unmasked region continues to pulse.

### Native Metal backend

All in `metal_scene_draw_smoke` unless noted; `metal_backend_test` needs no
device.

- **Native backend admission** — `metal_backend_test`: every refused construct
  keeps its own distinct reason; plain sheets, sprite particles, sprite trails,
  thin and thick ropes, rope trails and a skinned mesh under a `g_Bones` shader
  are accepted by their actual layout; a sprite trail without velocity, a
  rope-marked sprite layout, a thin rope trail, a skinning shader on a mesh
  without bone weights and a bone stride that cannot hold a 4x4 matrix are
  refused; a puppet under an effect chain is judged by the chain's final mesh,
  and only on the chain's last node. An unused perspective camera does not
  reject; a supported layer that names a perspective camera, or an active
  perspective camera with supported layers, is accepted.
- **Perspective cameras** — `MetalProjection.PerspectiveUsesFovAspectNearFarAndAHomogeneousDivide`,
  `.UnprojectingNdcHitsTheLayerPlane` and `.CameraAxesFollowTheAttachedNode` in
  `metal_backend_test`; `MetalSceneDraw.APerspectiveCameraDrawsThroughTheAuthoredShader`.
  Projection is the scene camera's own FOV/aspect/near/far, not an orthographic
  scale; a rotated card must foreshorten.
- **Render passes** — `MetalSceneDraw.LayersSharingATargetShareOneRenderPassAndHiddenLayersCostNone`:
  consecutive passes into one image share one render pass, a hidden layer starts
  none, a hidden card draws exactly what a dropped one does, and showing it
  changes the picture. A pass starts a new render pass only for another image,
  another depth attachment, a read of its own image, or a clear, unless the open
  render pass began with that same clear and has drawn nothing yet. A draw
  sharing a render pass sets every binding the previous draw may have left, nil
  included. On a real scene, `WE_TEST_METAL_PROJECTS` prints render passes and
  blits per frame and CPU per `drawFrame`, and its PPM must stay byte-identical to
  a build without the change.
- **Feedback copies** — `MetalSceneDraw.AFeedbackCopyTradesTexturesAndDrawsTheSamePicture`:
  two lenses that each sample `_rt_FullFrameBuffer` over a card, drawn with scene
  optimisation off (the graph's copies are made) and on (the image and its copy
  trade textures, and the reader's render pass opens with a texel-exact copy of
  the image as it stood). Every frame must be byte-identical across three frames
  (the trades carry over) with no blits when on; removing the opening copy fails
  all three. The trade is planned only for a copy whose reader is the next pass
  to touch the image, draws into it without reading it, and loads it (or clears
  it, which needs no opening copy), with both textures private to one name, one
  size, `RGBA8Unorm`, one mip level, no depth and neither image reused; an
  abandoned frame undoes its trades. On a real scene,
  `WALLPAPER_MACHINE_FEEDBACK_COPIES=1` makes the copies again, and the harness
  PPM must match either way.
  `.InterleavedFeedbackCopiesPreserveEachReadersImage`: `copy A→Ac`, unrelated B
  work, `copy B→Bc`, then B's reader before A's reader; both target images match
  the blit path over four frames with both blits removed. Opening copies are
  retained separately by destination texture, not in one overwritable pending
  slot, and graph release and abandoned frames clear that state.
- **Per-frame geometry upload** — `MetalSceneDraw.GeometryRebuiltEveryFrameIsUploadedAndDrawnFromItsOwnSlot`,
  across more frames than there are in-flight slots. Zero live particles must
  draw nothing rather than fail.
- **Skinning** — `MetalSceneDraw.APuppetIsSkinnedByItsOwnShaderFromThePoseTheRuntimeProduces`:
  a 64-byte reflected bone stride, the skinned quad translating by the distance
  its bone did with its width unchanged (what rules out a transposed matrix), the
  unskinned quad still, no reuse while the pose moves, `pause()` freezing and
  `play()` resuming. `.TheShippedImageShaderSkinsAPuppetThroughTheNativeBackend`
  repeats the translation and draw with the author's `genericimage2` and skips
  without the shipped shaders.
- **Trail and rope layouts** — `MetalSceneDraw.ARopeLayoutMeshReachesTheTarget`,
  `.ASpriteTrailMeshReachesTheTarget` and
  `.TheShippedRopeAndTrailPreviewScenesAreParsedTranslatedAndDrawnNatively`,
  which runs the editor's own preview projects through the real parser and
  shaders and skips without the shipped assets.
- **Scene optimisation applied at runtime** — `MetalSceneDraw.TurningTheOptimisationBackOnDoesNotReuseAFrameDrawnWhileItWasOff`
  and `.AGraphCompiledWithTheOptimisationOffStartsReusingWhenItIsTurnedOn`:
  turning the setting on must reach a graph that was compiled while it was off,
  on that graph's next frame, without reusing pixels no plan recorded.
- **Program reuse** — `MetalSceneDraw.TheSameProgramIsCompiledOnceAndReusedByTheNextSurface`:
  a second renderer on the same device must not hand an identical translated
  program to the Metal compiler again. The pipeline key identifies the program by
  content, never by the address of the object holding it.
- **Optional programs** — `.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader`
  asserts the parse compiled nothing optional before asking for it, and
  `.AVideoLayerKeepsConvertingWhileTheSettingIsOff` asserts the program was never
  even claimed while the switch was off: preparing an optional variant during a
  parse is a first-frame cost, not a free one.
  `.AnOptionalProgramTranslatedOnceIsRestoredFromDiskOnTheNextLaunch`: after the
  in-memory caches are cleared, the stored entry must reproduce the Metal source,
  the reflection *and* the per-stage binding plan without the compiler running;
  truncated entries fall back to a normal compile. Restoring MSL alone is not a
  restored program.
- **Pipeline archive on the production path** — `MetalSceneDraw.PipelinesThisProcessBuildsAreArchivedAndServeTheProductionPath`:
  pipelines are offered to the archive, published, reopened from disk and
  satisfied strictly, and a scene with no archive path still draws. A written
  archive that is never attached to a production descriptor proves nothing.
- **Who owns the first frame** — `MetalSceneDraw.ADrawnFrameIsReportedAsPresentedAndLeavesTheFirstFrameFlagAlone`:
  a backend reports presentation through `drawFrame`'s `presented` out-parameter
  and leaves `Scene::first_frame_ok` to the frame handler. A backend that sets the
  flag satisfies the handler's own check before the handler runs, the host is
  never told the wallpaper started, and the startup deadline tears down a
  wallpaper that is drawing correctly.
- **Posters** — `metal_poster_capture_test` covers on-request poster readback,
  busy coalescing and invalidation.

### Video decode, color and import

- **Decode state machine** — `video_decode_pump_test` pins the libavcodec
  send/receive contract and includes reproductions of the two orders to avoid:
  feeding input before draining output loses a packet the decoder rejected with
  `EAGAIN`, and seeking at end of input instead of draining loses the reordered
  tail of every loop. It also covers cancellation during a drain, a bounded
  no-progress budget, and releasing a held packet exactly once on seek, stop or
  failure.
- **Color range** — `video_color_conversion_test` pins known pixels for
  BT.601/709/2020 in both ranges, studio black and white with clamping, 75%
  color bars round-tripped from their RGB primaries, matrix separation,
  resolution-based inference for unspecified metadata, and bit-depth scaling.
  Limited-range chroma has its own 224 code-value excursion; reading it as
  `sample - 0.5` desaturates every studio-swing frame, and that has a case of its
  own. `PlaybackGPU.MetalConversionMatchesTheCpuColorReference` compares the
  Metal `nv12_to_bgra` kernel against the same CPU reference so the two paths
  cannot drift apart.
- **Display matrices** survive metadata probing and frame extraction: the decoded
  buffer keeps its coded dimensions, while output dimensions and sampling use the
  affine display transform. `VideoDisplayTransform.*` in
  `video_color_conversion_test` checks all eight orthogonal orientations plus
  scale and shear, and `VideoSourceInput.DisplayMatrixSurvivesMetadataProbeAndFrameExtraction`
  reads ordinary synthetic MP4 metadata. Private-texture Vulkan and Metal checks
  draw four distinct corner colors through BGRA, converted NV12 and direct NV12
  sampling and compare orientation, logical size and transparent uncovered
  corners for shear; converted and direct output may differ by at most two
  channel levels.
- **Software-decoded frames** allocate the BGRA output buffer with IOSurface
  backing and Metal compatibility: a CPU-only Core Video buffer decodes correctly
  but cannot be imported as a GPU texture, leaving the video black. Import adds
  no second pixel copy, conversion destination or GPU wait.
  `DecodedFormats/SoftwareVideoFrame.*` in `playback_gpu_test` covers BGRA, NV12,
  YUV420P and YUVJ420P with generated strided color/alpha patterns, checks exact
  imported pixels after releasing the decoder buffers, and asserts direct-import
  work. `WE_TEST_VIDEO` optionally exercises an installed clip without editing it.
- **Import leases** — video frame imports are owned by a lease that retains the
  Core Video texture wrapper and the pixel buffer for as long as the frame can be
  sampled, not just the vended `MTLTexture`. `playback_gpu_test` exercises pool
  reuse, generation dedup, cache eviction and recording-discard recovery.
- **Decoded frames carry real timestamps** — `video_source_input_test` and
  `shared_video_session_test` against media the tests encode. A frame whose
  timestamp is always zero looks like playback for as long as frames keep
  arriving and then freezes, so a video regression here reads as "the picture
  stopped" rather than as a decode failure; the FFmpeg header/library check in
  `src/Video/FfmpegAbi.hpp` exists because the layout mismatch that produces it
  compiles cleanly. `video_source_input_test` owns a private `TMPDIR` and only
  removes its own media cache; never clear the app's decode cache to make a test
  pass.
- **One clock per shared decoder** — `SharedVideoSessionTest.AFrameStaysValidAfterTheDecoderMovesOn`
  and `.PausingOneSurfaceLeavesTheOtherPlaying`: exactly one elected consumer
  moves a shared session's clock, so a test that advances the non-driving
  consumer observes nothing. Make the advancing consumer the driver rather than
  loosening the election.
- **Consumption decided before import** — `MetalVideoTexture.PlanesOnlyDemandEncodesNoConversion`,
  `.MixedDemandConvertsOnceAndStillPublishesThePlanes` and
  `.ADemandChangeReImportsTheSameGenerationInsteadOfWaiting`: a frame every
  consumer samples as planes encodes no conversion and allocates no destination;
  a mixed scene converts exactly once.
- **Pixel format decided per frame** — `MetalVideoTexture.ABgraFrameIgnoresAPlaneDemand`
  and `.AFormatChangeSwitchesPathWithoutLosingTheTexture`. Software decode hands
  back BGRA and VideoToolbox hands back NV12 for the same file, either can take
  over mid-playback, and neither may reparse the scene or lose the picture.
- **Direct plane sampling, end to end** — `MetalSceneDraw.AVideoLayerSamplesTheDecoderPlanesThroughItsOwnShader`
  and `.AVideoLayerKeepsConvertingWhileTheSettingIsOff`: an ordinary parsed author
  material, a real decoded video, the variant compiled by the parser, bound
  through its own reflection and drawn. A test-only shader does not cover this.
- **Direct-versus-converted picture** — `MetalSceneDraw.OneToOneSamplingProducesTheSamePictureOnBothPaths`
  (must agree to one code value) and `.ScaledSamplingStaysInsideTheClampExcursionTheStreamImplies`
  (see [performance](../features/performance.md)). The paths are exactly
  equivalent at a one-to-one mapping; under resampling they differ only where the
  stream carries codes outside the range it declares, bounded by that clamp's own
  excursion.
- **Plane variant refusals** — `video_planes.rs` in `crates/shader`: an
  explicit-LOD sample, a size query, and any other use of the video slot refuse
  the variant instead of mistranslating it, and the ordinary program is unchanged
  by the option existing.

### Continuous-playback work contracts

- **Playback GPU harness** — `playback_gpu_test` uses real private images for
  producer/consumer and overwrite synchronization, every generated mip, and
  recording/pipeline/framebuffer failures. The executor returns the first
  `VkResult` failure; failed recordings are reset and abandoned rather than
  submitted or waited on. Shader-read barriers are outside render passes and
  include vertex consumers.
- **Pass teardown** — destroying a pass leaves it unprepared with no image
  handles. Render-scale and copy-elision rebuilds destroy every pass, drop the
  render targets and prepare only unprepared passes, so a pass that stays
  prepared records against freed images (a `CopyPass` that did crashed MoltenVK
  at launch with render scale below 1).
  `PlaybackGPU.CopyPreparesAgainAfterRenderTargetsAreDroppedAndResized` covers it.
- **Clears** — a prepared `PrePass` is skipped only when a same-image, same-view,
  single-mip, single-sample clear with bit-identical color is reached before any
  reader or non-custom pass; visibility and actual active descriptors are
  reconsidered each frame, and the standalone pass loop remains the reference
  path. `PlaybackGPU.FirstDrawAfterATransparentClearOpensWithItByteForByte`: the
  first draw into a target cleared to transparent opens with that clear, leaves
  the bytes the clear plus a loading draw left, and the transfer clear is
  dropped; `RenderTargetLifetime.NestedCompositesClearBeforeChildrenWithoutErasingThem`
  keeps every later draw loading and single-sample. A hidden layer's batched
  first-use clear (`ClearImage`) is recorded only when something can observe its
  target (`HiddenClearIsObservable`, over the whole graph, including passes left
  out of the frame by reuse): a later drawing reader, sampler, copy, final
  composition or loading draw, any earlier reader (it samples the previous
  frame's clear), or the scene output.
  `PlaybackGPU.HiddenClearsAreRecordedOnlyWhereSomethingReadsThem` covers each
  reader and the transition of a hidden reader to drawing; the executor and the
  unchanged-present check apply the same rule.
- **Direct presentation** requires exactly one graph shader pass writing the
  default target, a first clear, no depth/mip/MSAA or feedback, UNORM RGBA/BGRA,
  and identical graphics/present queue families. Each frame also requires the
  exact full-target viewport/scissor, matching extent, ready descriptors and no
  flip — except for the plain-video scene, whose one pass is by construction the
  final composition's own quad copying one texture: it presents through the final
  composition's viewport, scissor and sampler whenever its bound frame is exactly
  the scene's size and the picture is not mirrored. Other frames render the
  normal intermediate plus `FinPass`. Both pipelines are prepared once, and all
  paths retain frame/presentation waits. Private-target tests compare complete
  same-format bytes over poisoned target rotation, graph resize, transparency,
  fallback and error recovery; they never transition private images to
  `PRESENT_SRC_KHR`. `PlaybackGPU.PlainVideoPresentsThroughTheFinalViewportByteForByte`
  drives the production video layer (`SceneWallpaperInputTestAccess::CreateVideoProjectNode`)
  over fit, fill, stretch, none, user scale, 2x displays, exact halving and
  uneven reduction, RGBA and BGRA sources sampled linearly or nearest, and
  requires the copy path's bytes; mirrored, smaller frames and other passes fall
  back.
- **Posters** — the Compatibility swapchain is `COLOR_ATTACHMENT` only, so
  MoltenVK makes the layer framebuffer-only. A requested poster is composed a
  second time by the pass that composed the drawable (`FinPass::recordComposition`
  or `CustomShaderPass::recordPresentation`) into a one-frame image of its own,
  refused above the poster limit by its real allocation, and copied from there.
  The same test requires every poster to equal the bytes the target received.
- **NV12 on Compatibility** makes one submission per new frame: the conversion is
  committed, without a CPU wait, on MoltenVK's own graphics `MTLCommandQueue`
  (exported with `vkExportMetalObjectsEXT`) and is ordered ahead of the frame by
  commit order and hazard tracking. That relies on MoltenVK's defaults
  (`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=1`, no prefill) and on the conversion
  running in the update op before `rr.command.Begin`. A first-use layout
  transition is recorded into the frame (`TextureCache::RecordVideoFirstUseTransitions`,
  right after `Begin`; harnesses that record frames call it too).
  `PlaybackGPU.NewVideoFramesNeitherWaitOnTheCpuNorSubmitOutsideTheFrame` guards
  one submit per frame, no CPU wait and image creations bounded by pooled
  destinations; `.ADroppedFrameDestinationIsNotReusedBeforeItsConversionRuns`
  guards the parking of a destination whose conversion is still in flight.
- **Per-frame uniform writes** resolve reflected members through a per-pass memo
  instead of string-keyed maps; every value is still written every frame and the
  upload stays memcmp-gated. The memo relies on two invariants: after parsing, a
  material's `customShader.constValues` only gains keys or is updated in place (a
  runtime erase would have to invalidate the memo), and `RuntimeImageSource`
  never removes a name (`NamesGeneration()` moves when one is added).
  `PlaybackGPU.RuntimeImagePublishedAfterPrepareReachesTheNextFrame` and
  `.RuntimeImageNamePublishedAfterPrepareReachesTheNextFrame` cover them.
- **Puppet copies** reuse a result buffer in their existing shared playback state
  for the exact same finite time until a control mutation; fresh layers sharing an
  asset have independent results and attachments still apply each frame. Audio
  uniforms borrow an owning packing buffer synchronously and read a fresh spectrum
  on every call; particle mouse inverses are skipped only when all current
  controlpoint link flags are off.
- **Core and bridge tests** additionally cover bounded capability relay delivery,
  renderer-instance replacement, serialized observer replay/publication, retained
  held-button levels and discarded inactive taps, level-only native
  reconciliation, single-turn samples and exact-success input deduplication.
  Native capability and button tests initialize loopers only, not Vulkan,
  playback or audio hardware.
- **Performance probes** stay disposable, with fixed simulation time, full output
  checks outside timing, raw samples and per-block median/p95. C++ `new` counters
  do not measure QuickJS `malloc`, worker-thread allocations or whole-process
  memory. Pixel equality and Vulkan command traces are not synchronization-layer
  validation, desktop equivalence, GPU residency or power measurements; GPU
  elapsed times vary run to run, so treat them as samples, never as proof of a
  GPU-time change and never as power or battery measurements.
- **Frames that would repeat the picture** — `unchanged_present_test`
  (Compatibility, driven through `SceneWallpaper` on a `CAMetalLayer` no window
  owns, against media it encodes) and
  `MetalSceneDraw.AFrameThatWouldRepeatThePictureTakesNoDrawableAndPresentsNothing`.
  A plain video presents exactly its newly selected frames: submissions track
  `video_frames_selected`, every other tick is `presents_skipped_unchanged`, and
  `video_frames_skipped` and the selected rate match the run with scene
  optimisation off. The distinct video generations presented, with their PTS, form
  the same sequence with the skip on and off
  (`TheSkipPresentsTheSameVideoFramesInTheSameOrder`, observed through
  `RenderInitInfo::video_frame_presented`), and with the skip on no generation is
  presented twice after the start. A held frame submits nothing until a flip, a
  poster request, a resume, a scaling-factor (crop), render-scale, surface-resize
  or fill-mode change, each of which presents the held generation exactly once and
  then repeats again; a static scene submits nothing once every pass is reused,
  and the poster it then exports is byte-identical to the baseline's. Counters
  are compared within one draw at the window edges, never exactly. A change the
  comparison cannot see must invalidate the gate; do not widen the skip by
  comparing fewer inputs. `unchanged_present_test` measures real-time frame
  cadence, including zero skipped baseline video frames, so run it without
  concurrent builds or benchmarks and keep a failing baseline visible rather than
  excluding the test.

### Frame timing, pacing and idle

- **Frame timing** — frame timing keeps render cost separate from animation time.
  Dropped busy ticks remain included in the elapsed delivered-frame delta;
  restarting excludes paused time. `timer_tests` covers dropped ticks, restart,
  FPS changes and long gaps without desktop surfaces or audio devices.
- **Pacing follows the content, bounded on both sides** — `timer_tests` pins the
  frame clock's content-rate pacing. A pushed `FrameDemand.content_period` may
  only lengthen the tick interval: the configured FPS stays the ceiling, so a
  60 fps video cannot make a 30 fps wallpaper render at 60, and an unknown, zero,
  negative or absurdly long period cannot stall a scene (one hour is clamped to
  the five-second gap the frame clock still treats as continuous playback).
  Dropping the demand restores the fixed cadence rather than inheriting the
  previous scene's, and pacing never changes how many draws may be in flight.
  The suspension threshold scales with the interval the clock is actually using
  and never drops below the five-second floor, so an ordinary frame boundary at
  the pacing clamp reports its real elapsed time instead of one ideal frame,
  while an eight-hour gap is still treated as a resume.
  - Only the engine's own plain-video scene reports a period, and only because
    `CreateVideoProjectScene` builds it with a single video texture, a copy
    shader, a no-op shader value updater and no script, particle, audio or
    pointer input. Authored scenes report nothing. A change that lets any other
    scene answer needs a positive account of every dynamic render-graph input
    first; guessing freezes a live wallpaper.
  - The period a source reports is evidence, not metadata. `avg_frame_rate` is
    an average and `r_frame_rate` an estimate, so neither describes a particular
    gap in a variable-frame-rate clip. `video_frame_pacing_test` pins the rules:
    declared rates are an upper bound on the period and never unlock pacing on
    their own; the shortest gap actually decoded does, after enough samples; the
    result is monotonically non-increasing, so a burst that appears once keeps
    the clock fast afterwards; deltas across a loop seam or a seek are discarded;
    and repeated, rewound or non-finite timestamps are not counted as evidence at
    all, which leaves the fixed cadence in place. Rational rates keep their exact
    period (`24000/1001`, not `1/24`), and playback speed maps the content's own
    timeline onto the wall clock, so a 2x wallpaper needs twice the tick rate for
    the same clip.
  - `WALLPAPER_MACHINE_CONTENT_PACING=1` switches content pacing on in the same
    binary so a comparison measures one strategy rather than two builds. The
    default is the fixed cadence; an unset or empty value (or `0`/`false`) never
    enables pacing.
- **Pointer-driven clock wakes** — `FrameTimerTest.ABurstOfWakeOnceAtTheCeilingDoesNotAddCallbacks`
  and `.AnIdleBurstOfWakeOnceProducesOneCallback` in `timer_tests`. Two hundred
  `WakeOnce` calls in one second at 30 fps stay inside about one callback per
  period (20–40), and an idle burst produces one callback. The configured ceiling
  still produces frames.
- **Renderer work counters** — `OWE_RC_*` counters are incremented by the
  production paths that perform the work: the frame clock's tick, the draw
  handler, the Vulkan submit, the present request, the frame fence and the
  texture cache's video update. They are off by default and read by pulling
  `owe_scene_wallpaper_counters`; nothing is pushed or logged per frame.
  `timer_tests` asserts that a tick which found a draw still in flight is counted
  as a suppressed tick rather than a request, that nothing is counted while the
  switch is off, and — running the real thread timer against the real callback —
  that a content period genuinely lowers how many draws the scheduler posts.
  `video_frame_pacing_test` pins the generation accounting behind
  `video_frames_selected`, `video_frames_reused` and `video_frames_skipped`: a gap
  between two displayed generations is exactly the number of decoded frames that
  never reached the screen, which is how a pacing regression is falsified while
  the picture still moves. `present_requests` counts requests; this backend has
  no presentation-feedback source, so the frames a compositor actually displayed
  are reported as unavailable and never approximated by the request count.
- **Counter baseline** — `PlaybackGPU.TurningCountersOnDoesNotReportWorkAlreadyDone`.
  A Compatibility video update that runs while counting is off does not read the
  decoder at all; the next counted update only records the decoder's totals and
  the frame on screen. Decode outputs, seeks, selected and skipped frames are then
  only what later counted updates observed, including after counting was turned
  off and on again.
- **A scene with nothing left to do** — `MetalSceneDraw.AStaticTextSceneRunsOutOfWorkToDo`,
  `.AStaticTextLayerUnderAnEffectChainAlsoRunsOutOfWork` and
  `.TextBoundToAUserPropertyIsEventDrivenRatherThanContinuous`: a static caption
  reaches zero demand reasons, having actually drawn, while the renderer still
  reports `EventMesh` and `RuntimeImage` (the reuse cache depends on both, and
  neither is a reason to keep the frame clock). Assert the reasons, not the frame
  rate.
- **Waking from idle, and not waking** — `MetalSceneDraw.AChangedCaptionWakesTheSceneAndThenLetsItGoQuietAgain`
  and `TextObjectRuntime.PreparedTextWakesWhoeverOwnsTheFrameClock`: a changed
  caption brings the demand back, reaches the output and goes quiet again; the
  text worker asks for the frame that shows its result, because a scene that has
  already idled has no clock to notice; and rewriting the same string wakes
  nothing. A wallpaper that idles and then misses an update is worse than one that
  never idles.
- **Content that must never be called still** — `MetalSceneDraw.TextProducedByAScriptIsNeverCalledStill`:
  a caption computed every tick keeps the clock on every frame, whatever the
  script returns. No script source is read, no repeated result is counted and no
  schedule is inferred.
- **Geometry rewritten on an event** — `SceneDemandMapping.GeometryRewrittenOnAnEventIsNotAReasonToKeepDrawing`
  in `static_subgraph_cache_test`: `EventMesh` and `DynamicMesh` must both cost a
  target its cacheability and must differ at the scene level. Collapsing them
  into one bit either stops static text idling or idles a particle system.

### Audio

- **FIFO continuity and overflow** — `audio_tests --gtest_filter='AudioResponseMonoTest.*'`
  includes `CompactedFifoPreservesEveryStereoWindow` (21 back-to-back stereo
  windows from 49 chunks of 700 frames, so windows straddle submissions; 34,300
  accepted frames, 700 retained) and `OversizedStereoSubmitAnalyzesOnlyRetainedFrames`
  (waits for all 60 windows from each latest-96,000-frame input).
- **Spectrum matches Wallpaper Engine** — `AudioResponseMonoTest.TonesLandInTheBandsWallpaperEngineMeasures`
  (octave tones from 42 Hz to 12 kHz peak inside the bands measured on Wallpaper
  Engine), `.LevelsSpanFortyEightDecibelsBelowAFullScaleTone`,
  `.CoarserResolutionsCoverTheSameFrequencies` and `.EachSpectrumStandsAlone` in
  `audio_tests`. The 48 kHz tap must be filtered before it is reduced (frequencies
  above 6 kHz must not fold into the bands), and the bands are not peak-held,
  log-compressed, spread into their neighbours or release-smoothed: a normally
  mastered track reading 1.0 in every band turns an audio visualizer into a solid
  uniform ring. See [audio response](../features/audio-response.md#what-wallpapers-receive).
- **Frequency mapping** — `audio_tests`, `particle_mouse_controlpoint_test` and
  `script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'` cover
  physical FFT frequency mapping including DC and Nyquist, silent and stale
  input, box/sphere emission transitions, and typed SceneScript views.
- **Sound output lifecycle** — `audio_tests --gtest_filter='SoundOutputLifecycle*'`
  on miniaudio's null backend: the output device starts only with channels
  mounted, playing and unmuted; muted hosts (the lock-screen extension) never
  start it; positions stay frozen while paused or muted.
  `FfmpegSoundStreamTest.ResampledTailPreservesTheAuthoredDuration` and
  `.LoopIncludesTheCompleteResampledTail` pin the resampled PCM: the tail keeps
  the authored duration and a looping stream repeats one cycle sample for sample.
  `SoundLayerControlTest` checks authored random playback delays between clips
  against emitted sample counts, including different callback sizes,
  pause/resume, stop/restart and seeded bounds, on the null backend, which never
  opens an audio device. All sound fixtures use the null backend.
- **Audio capture follows what the scene reads** — `SceneSchema.AudioRequirementComesOnlyFromContentThatReadsAudio`
  and `.AudioRequirementIsReportedOncePerSceneAndResetByReplacement` in
  `scene_schema_tests`, `VideoSourceInput.PlainVideoProjectNeverReportsAnAudioRequirement`
  in `video_source_input_test`, and the bridge tests
  `display_presentation::audio_response_alone_does_not_open_the_tap_for_a_scene_that_reads_no_audio`,
  `::replacing_an_audio_scene_with_one_that_reads_nothing_closes_the_tap` and
  `web_audio_media::a_web_listener_counts_beside_a_scene_that_reads_no_audio`.

### Host, bridge and display behavior

Rust tests in `wallpaper-bridge` and `wallpaper-core`, and Swift tests under
`Tests/Unit/`. They guard the host's half of rendering: what the app asks the
engine to redo, and when.

- **Download-speed sampling** — `DownloadTelemetryTests` in `Tests/Unit/Workshop/`:
  real `nettop` streaming over a private PTY with local-socket traffic; CRLF and
  split line endings. LF-only fixtures do not verify live delivery.
- **Pointer sampling is event-armed** — `api_smoke::mouse_polling_samples_only_when_input_arrives`,
  `::mouse_polling_stops_while_the_only_interactive_scene_is_suspended_on_its_display`,
  `::mouse_polling_in_a_monitor_gap_checks_the_cursor_without_engine_work` and
  `engine::snapshot::tests::a_paused_scene_is_not_a_pointer_consumer_and_its_resume_drops_paused_clicks`.
  A consumer with no input is never sampled; a paused scene is not a consumer.
- **A global resume keeps covered displays paused** — `display_presentation::a_global_resume_never_restarts_a_display_that_is_still_covered`:
  the scene pause log must never show `paused=false` for a display that is still
  suspended.
- **A display refresh keeps an unchanged scene** — `settings_intents::a_display_refresh_does_not_reload_a_scene_whose_audio_response_has_nothing_to_read`,
  `::a_display_refresh_does_not_reload_a_scene_held_to_the_battery_frame_rate`,
  `::a_display_refresh_does_not_reload_a_scene_muted_for_other_audio`,
  `::a_display_refresh_does_not_reload_a_scene_paused_by_a_lock_or_a_covered_display`,
  and `DisplayRefreshCoalescerTests` in `Tests/Unit/Desktop/`. A value applied
  live on top of the saved configuration must never read as a different
  wallpaper: every display change refreshes displays, and a mismatch reopens the
  scene behind a white placeholder layer and restarts its animation.
- **A screen change that moves nothing does no work** — `DisplayRefreshCoalescerTests`
  (`testScreenChangesThatLeaveTheDisplaysAsTheyWereDoNotRefresh`,
  `testAnUnchangedBurstDuringARefreshEndsWithIt`,
  `testTwoReadingsOfTheSameDisplaysAreEqual`), `WallpaperSpaceMonitorTests.testOnlyAScreenChangeThatMovesADisplayRereadsTheSpaces`
  and `WallpaperPresentationPolicyTests.testOnlyAScreenChangeThatMovesAWorkingAreaIsEvaluated`.
  An XDR display posts a screen change for every frame of an EDR headroom ramp;
  each one would run a bridge refresh, republish every snapshot, re-sync the lock
  screen, push the whole control panel and ask the window server for the
  session's lock state twice. A failed refresh is still retried on the next
  change.
- **The lock state is not asked per evaluation** — `WallpaperPresentationPolicyTests.testTheLockStateIsAskedOnlyWhenItCanHaveChanged`,
  `.testASessionLockedBeforeStartIsSuspendedFromTheStart`,
  `.testWakingDisplaysAskForTheLockStateAgain`,
  `.testSwitchingUsersAsksForTheLockStateAgain` and
  `.testAMissedUnlockClearsAtTheNextEvaluation`. Every snapshot the engine applies
  runs the presentation policy, and `CGSessionCopyCurrentDictionary` is a
  synchronous window-server round trip. It is asked again only at start, on a lock
  or unlock, on display wake, on a user switch and while the session counts as
  locked, so a missed unlock still clears at the next evaluation.
- **No folder probe per panel snapshot** — `WorkshopDownloadIntentTests.testSceneAssetsAreFoundAgainOnlyOnRefresh`.
  Resolving `ClientPaths.assetsURL` probes up to four folders, which is a large
  share of building the page snapshot while a property slider is dragged. The
  folder is found with its readiness: at launch, after locating or installing
  assets, and when the panel becomes key; a refresh that finds nothing new wakes
  no observer.
- **Identical monitors keep their own wallpapers** — `display_identity::*` in the
  bridge (`a_stale_block_for_one_identical_monitor_never_lands_on_the_other`,
  `display_sync_keeps_one_block_per_display_under_its_current_selector`,
  `a_disconnected_display_keeps_only_its_first_block`,
  `identical_monitors_keep_their_own_wallpapers_across_renumbering`) and
  `display::tests::identical_models_sharing_a_unit_number_do_not_match` in core.
  They replay a four-display layout with two displays of one vendor and model,
  without the hardware. macOS renumbers displays and renames identical models
  across reboots and reconnects: a unit number must never pair two displays whose
  UUIDs or serials differ, display sync must keep one `[[monitors]]` block per
  display under its current selector, and a panel display id from before a
  renumbering must still edit that display.
- **A reconcile keeps an unchanged scene** — `settings_intents::a_reconcile_does_not_reload_a_scene_held_to_the_frame_rate_cap`,
  `::a_reconcile_does_not_reload_a_scene_muted_for_other_audio` and
  `performance_settings::wallpapers_applied_under_a_frame_rate_cap_start_at_the_capped_rate`.
  A reconcile hands the engine every configured scene and the engine reopens any
  whose descriptor differs from the one it runs, so the descriptor carries the
  live frame-rate ceiling and mute. It is also what holds a scene opened under a
  cap to that cap: nothing lowers the rate after the reconcile.
- **Snapshots do not wait on the service manager** — `login::tests::a_burst_of_snapshots_asks_the_service_manager_once`,
  `::a_change_made_in_system_settings_shows_once_the_last_read_has_aged` and
  `::a_change_made_in_the_app_shows_at_once`. Every snapshot carries the
  launch-at-login status; reading it from `SMAppService` for each one would hold a
  burst of queued bridge requests (Apply and Quit among them) behind service-manager
  round trips.
- **The lock screen ignores the covered desktop** — `apply_options::lock_screen_export_ignores_the_desktop_display_being_covered`:
  locking covers the desktop and suspends its display, and the exported
  lock-screen scene must stay unpaused unless the user or power policy paused
  playback.

### Startup and staging buffers

- **Deferred backend selection** — `SceneSurface.DeferredBackendRetainsTheLayerUntilTheSceneIsDeleted`
  in `playback_gpu_test` checks that deferred backend selection keeps its
  `CAMetalLayer` alive after the host releases it, then releases it with the
  scene. It uses no window or GPU backend and flushes Core Animation's implicit
  transaction so that transaction cannot mask missing scene ownership.
- **Staging buffers grow geometrically.** Extending by a fixed size zeroes a
  temporary CPU vector and copies the entire previous allocation twice per
  extension, which is quadratic for a large scene and caused an Apply timeout.
  Geometric blocks plus direct replacement-buffer copying preserve existing
  offsets and data without that work. The check is the cold/warm startup timings
  of `offscreen_scene_probe` on a large scene.
- **First-frame wait.** A cold MoltenVK pipeline compile for a large scene can
  take longer than 20 seconds, and a warm shader cache or driver pipeline cache
  does not remove the wait. The apply wait is 90 seconds, with rollback after
  it. It waits only on displays where the engine opens or replaces a scene,
  judged against the engine's live display snapshot: a display refresh moves and
  resizes scenes in place without the facade, and such a scene keeps its
  renderer, which announces its first frame once. Comparing against the
  descriptors the facade last handed over would make the next Apply wait out the
  90 seconds and roll back a playing wallpaper
  (`engine::facade::first_frame_tests`).
- **Texture decode at preparation** — `texture_prefetch_test` (CPU, in the gate):
  images handed over once under their own name, decoding plus untaken images held
  within the byte budget (an image larger than the budget alone), preparation
  never waiting on an image not yet admitted, a prefetch whose threads failed to
  start answering at once, a failed decode reported rather than retried, a
  throwing decoder left to the caller, and teardown joining running decodes and
  freeing every image. `CustomShaderPass::prepare` asks `TextureCache::FindTex`
  before decoding, so an image bound by several passes is decoded once.
  `TexturePrefetch` decodes the images unprepared passes will parse on up to six
  threads, ahead of the pass that binds them, with decoding and untaken images
  held under a 256 MiB budget estimated from each header and admitted in request
  order. Startup timing and byte-identical output on a real scene come from
  `offscreen_scene_probe`, which prepares through the same prefetch. Startup cost
  feeds lock-screen admission latency: the extension answers WallpaperAgent only
  after a first frame (see [lock screen](../features/lock-screen.md)).

## Rust crates

`python3 scripts/check_rust.py` is the release-CI entry point. It supplies the
Homebrew Cargo environment, uses a temporary `WALLPAPER_MACHINE_HOME`, disables
the desktop, media and network opt-ins, and runs, all with `--release --locked`:
the `wallpaper-core` and `wallpaper-bridge` library tests, four device-free
`wallpaper-core` integration targets (`audio_response_controller`,
`core_audio_api`, `project_override_json`, `wallpaper_background`) and the
`shader` crate with `ffi`. It prints and records the six explicit
desktop/external-corpus exclusions (`CORE_EXCLUSIONS` in the script) and any
emitted skip reasons. A nonzero command or missing tool fails the check. Full
logs and the JSON verdict go under `artifacts/rust/` (`--output` redirects them);
CI uploads them on failure. This does not certify skipped corpus inputs or
authorize a desktop run.

Generated bindgen output can differ in formatting between machines; tests must
exercise the FFI behavior instead of parsing a formatted declaration. Mouse
monitor-gap tests wait for the fake engine's sample barrier and observed probe
progress before comparing counts, so a busy CI worker is not mistaken for a
dropped cursor update. Close the gap while the sample is blocked before checking
that probes stop; otherwise an in-flight probe can race the final count.

Run individual commands from `upstream/renderer` with the Homebrew environment
from `scripts/build.py`. The first `cargo test` after that environment changes
fails in its CMake configure step and succeeds on an unchanged retry, so a single
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
  scenes, cleanup, suspension, permission and failed-transition rollback. The
  bridge's `tests::web_audio_media` replays web capture decisions through the
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
- `shader`'s `pipeline` test skips asset-dependent cases (for example
  `genericimage4` and a Workshop package) with a printed `skipping …` reason; read
  those lines before claiming shader coverage. See
  [wallpaper-corpus.md](wallpaper-corpus.md) for the asset roots.

## C++/CMake test binaries

CMake test binaries are built under `artifacts/renderer/bin/` (executables in
its `tests/` folder). The authoritative routine build/run list is
`REGRESSION_BINARIES` in `scripts/check_renderer.py`, covering the
texture/cache/lifetime, audio, video, graph, particle, timer and Metal checks; a
non-zero exit from any registered binary fails the check. Binaries outside the
registry are built and run by hand, in the Homebrew environment from
`scripts/build.py`, once `check_renderer.py` has configured the build directory:

```sh
cmake --build artifacts/renderer/bin --target scene_schema_tests
artifacts/renderer/bin/tests/scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'
```

`scene_schema_tests`, `mdl_schema_tests`, `tex_schema_tests`,
`script_runtime_compat_test`, `mouse_input_test`, `media_thumbnail_texture_smoke`,
`scenescript_media_event_smoke` and `scenescript_sound_layer_smoke` are such
binaries: they provide the parser, SceneScript, input and media-protocol coverage
when those paths change. `tex_schema_tests` links `PkgConfig::TEST_LZ4` itself
(`tests/CMakeLists.txt`), the way the video suites re-resolve FFmpeg: the
renderer links LZ4 `PRIVATE`, so the include directory does not propagate to a
test that builds its own compressed `.tex` fixtures. Run it when touching
`WPTexImageParser`. Other useful filters:

```sh
audio_tests --gtest_filter='AudioResponseMonoTest.*'
script_runtime_compat_test --gtest_filter='AudioResponseCompat.*'
```

`rendergraph_smoke` and `vulkan_sample_count_smoke` use always-active GTest
checks in Release builds. `sprite_animation_test` checks elapsed time across
cadences and long loops. `stb_image_regression_test` decodes ordinary generated
JPEG/PNG/BMP images, checks cleanup under controlled allocator refusal, and
compares scalar versus arm64 NEON JPEG pixels (arm64 production decoding enables
NEON). The disabled `Arm64NeonJpegDecodeBenchmark` is explicitly opt-in; its
first-decode and warm in-memory decoder timings are not disk-cold startup,
whole-app performance or energy measurements. `miniaudio_failure_paths_test`
covers allocation failures without opening audio hardware.

`unchanged_present_test` exercises Compatibility frames that would repeat the
picture through a real swapchain on a `CAMetalLayer` no window owns. The native
Metal backend adds `metal_backend_test` (capability and graph gate, no device
needed), `metal_scene_draw_smoke` (author shaders and same-frame intermediates
drawn and read back, plus target reuse, dynamic-geometry upload, sprite-sheet
stepping, text layers and their update dedup, direct video plane sampling end to
end and Metal program reuse across renderers), `metal_poster_capture_test`
(on-request poster readback, busy coalescing, invalidation) and
`metal_video_texture_test` (BGRA import and NV12 conversion against the CPU
color reference, from synthetic frames). All four run in the check and draw only
into private textures; the three that draw skip visibly without a Metal device.

## Known limitations

- Local scenes can emit MDLA, Rust `light_map` compile and shader-value alias
  errors that are independent of a given change; compare against a baseline run
  and verify only that no *new* diagnostics appear. A
  `ShaderValue: … not found in glsl` line is authored leftovers, not a binding
  failure. Wallpaper Engine's own `clipping_mask` effect fails to translate (see
  [Shader pipeline](#shader-pipeline)).
- The `perspective` flag of an image layer is read by no parser (`WPTextObject`
  and `WPModelObject` read theirs); image layers always draw through the
  orthographic camera.
- **A lone `pixels_equal=false` on a large scene is not by itself a regression.**
  On an unmodified build a 4K scene's `frame-2` has been seen once to differ from
  its isolated twin by a few levels everywhere (no clock, label or single layer),
  in a pooled run only, so allocation reuse is not ruled out. Re-run it, and
  investigate if it repeats.
- **A target a parallax layer draws into is never reused.** Neither backend's
  static pass sample (`CustomShaderPass::frameSample`,
  `MetalRender::Impl::frameSample`) includes the parallax offset
  `WPShaderValueUpdater::UpdateUniforms` adds to a layer's model matrix, so
  `FrameVaryingUniforms` reports such a pass as `kParallax`, which becomes
  `PointerUniform` and keeps the whole target out of the cache
  (`StaticSubgraphCache::Compile`), whether or not the cursor moves. With
  on-demand rendering off, a scene whose only motion is parallax redraws its whole
  frame at the frame cap, as it would with scene optimisation off. Without the
  report the cache would reuse those targets while the cursor moved and parallax
  would stop following it. Folding the offset itself into the sample would allow
  reuse while the cursor is still.
- **On-demand rendering stops parallax partway.** A scene that sleeps wakes for
  one frame per pointer event (`wakeForPointer`), but nothing asks for frames
  while the layers are still easing toward the cursor, so after the pointer stops
  they rest partway and catch up at its next movement. `m_mouseDelayedTime` is no
  end condition: `SceneWallpaper` calls `MouseInput` every frame, and that
  subtracts the real frame interval `FrameBegin` has just added as the ideal one,
  so `cameraparallaxdelay` acts as an exponential time constant and the eased
  cursor approaches the pointer without reaching it. A demand of
  `m_mouseDelayedTime < delay` would never clear and would keep the scene awake
  for good; a correct one needs a threshold on the offset still to travel.
- **An animated material constant keeps a scene awake after its timeline ends.**
  `DescribeTimeAdvancingWork` reports `NodeBinding` for every material-constant
  binding that has an animation, playing or not. The timeline's clock is a
  registered playback (`RegisterScalarAnimation` in the parser), which the
  `Animation` reason already counts while it plays, so with on-demand rendering
  on, a scene whose only motion was such a single-play timeline keeps ticking
  after it ends.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
