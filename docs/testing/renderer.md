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
| `WE_TEST_METAL_WARMUP_TICKS` | `metal_scene_draw_smoke` | Runtime ticks of 1/60 s before the graph is built, as `offscreen_scene_probe` takes 40; `0..3600`. Unset, none. The scene clock is not advanced by them, here or there |
| `WE_TEST_COMPARE_PROJECTS` | `metal_scene_draw_smoke --gtest_filter='*DrawTheSamePictureOnBothRenderers*'` | Colon-separated `project.json` paths drawn by both renderers in one harness (see below). Unset, the test skips |
| `WE_TEST_COMPARE_SURFACE` | the same test | `<width>x<height>` of the layer both renderers draw into; default `960x540` |
| `WE_TEST_COMPARE_NATIVE_ONLY` | the same test | Set (any value) to draw only the Native Metal picture of each project and compare nothing: only `<scene>-native.ppm` is written, for a comparison with a reference from outside the harness such as Wallpaper Engine's own frames |
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
draws layers a script creates during `init` but not ones created later, nor a
layer its properties hide that a script shows later;
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

The fair renderer comparison is `MetalSceneDraw.LocalProjectsDrawTheSamePictureOnBothRenderers`
with `WE_TEST_COMPARE_PROJECTS`: each project is parsed twice exactly as a
wallpaper loads it, seeded and clocked identically (`WE_TEST_METAL_FRAMES`,
`WE_TEST_METAL_FRAME_STEP`, `WE_TEST_METAL_WARMUP_TICKS`, `WE_TEST_RANDOM_SEED`),
given the scaling the host pushes to every renderer, and drawn through
`SceneRendererHandle` on a layer no window owns, once per renderer. The last
frame's final composition returns through the poster path both renderers share,
so the two pictures differ only by what the renderers did; it prints the mean
absolute difference and writes both under `WE_TEST_OUTPUT`. A difference found by
comparing `offscreen_scene_probe` with the local-project run is not yet a renderer
difference: the two harnesses differ in the ways below, and the probe also never
rebuilds its graph for a layer a script shows after the warm-up.

To put both clocks on the same second, give the Metal run
`WE_TEST_METAL_WARMUP_TICKS=40` and both runs the same frame count and step
(`WE_TEST_FRAMES` with `WE_TEST_FRAME_STEP`, `WE_TEST_METAL_FRAMES` with
`WE_TEST_METAL_FRAME_STEP`). Three more things differ between the harnesses
unless set: the Vulkan probe steps particles only with `WE_TEST_AUDIO_HZ` (use
`0` on both); it keeps every source mip unless `WE_TEST_TEXTURE_SURFACE` names
the surface the Metal run rasterises (`WE_TEST_METAL_SURFACE`), which otherwise
reads as Metal being blurrier; and a canvas that is not 16:9 is cropped by the
Metal harness's fill mode on its default 960x540 surface, which reads as a
zoom, so give both a surface of the canvas's own aspect. A scene still inside
its camera fade at the sampled time is black on both and compares equal.

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
protects. Every C++ test binary these pages name is in the `REGRESSION_BINARIES`
registry and runs in `scripts/check_renderer.py` (see
[C++/CMake test binaries](#ccmake-test-binaries)). Rust tests
(`module::test_name`) run through `python3 scripts/check_rust.py`; Swift tests
(`TestClass.testName`) run through `python3 scripts/test.py`. Tests that need
shipped Wallpaper Engine shaders or assets skip with a printed reason.

- [Scene regressions](scene-regressions.md) — cameras, parallax and cursor
  mapping, scene scripts and property bindings, layers, textures and
  compositing, alpha, text and clocks, animation and puppets, and the shader
  pipeline.
- [Runtime regressions](runtime-regressions.md) — the native Metal backend,
  video decode and import, continuous-playback work, frame timing and idle,
  audio, host, bridge and display behavior, and startup and staging buffers.

## Rust crates

`python3 scripts/check_rust.py` is the release-CI entry point. It supplies the
Homebrew Cargo environment, uses a temporary `WALLPAPER_MACHINE_HOME`, disables
the desktop, media and network opt-ins, and runs, all with `--release --locked`:
the `wallpaper-core` and `wallpaper-bridge` library tests, four device-free
`wallpaper-core` integration targets (`audio_response_controller`,
`core_audio_api`, `project_override_json`, `wallpaper_background`) and the
`shader` crate with `ffi`. It prints and records the nine explicit
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

A `wallpaper-bridge` test bridge keeps its actor runtime's threads (about one per
CPU core, and the actor's own) until the test process exits, unless the test lets go
of its engine: the bridge registers a callback with the engine that holds the actor
and its runtime, and the actor holds the engine. A test that builds a bridge over a
`FakeEngineFacade` keeps an `EngineRelease` for it (`tests/engine_release.rs`), which
drops that callback when the test ends and leaves about one thread behind instead of
twenty. Only a few tests do so far, so on an 18-core Mac the library suite peaks near
5,800 threads against the 6,144 a process may hold (`sysctl kern.num_taskthreads`).
A new test that builds a bridge keeps an `EngineRelease`, and shares one bridge
between the phases of a property instead of building one per assertion. A failure of
an unrelated test with `Resource temporarily unavailable (os error 35)` from `kameo`
or a tokio worker is that cap, not the change under test; it also turns up when other
builds on the same Mac hold the per-user process limit.

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
  scenes, cleanup, suspension, permission and failed-transition rollback, and the
  rebuild after an output device change (`restart_*`); `device_watch::tests`
  covers its debounce and subscriber table with real timers of a few tens of
  milliseconds, never the CoreAudio listener. The
  bridge's `tests::web_audio_media` replays web capture decisions through the
  production demand handler and real controller with a device-free backend:
  checking only the fake engine's suspension flag cannot prove capture starts.
- `wallpaper-core` framing coverage (`cargo test --release -p wallpaper-core --lib
  framing`): a scene's position (`SceneFraming`, two fractions from 0 to 1, centred
  at 0.5 by default) is refused when an axis is NaN, infinite or outside 0..1 by
  the descriptor and template builders, both `validate()` methods and
  `WallpaperEngine::set_framing` (which refuses before it asks the actor, so
  nothing reaches the renderer); it counts toward `SceneDesc::same_wallpaper`, so
  only a different position forces a renderer rebuild and `paused` or `display`
  alone do not; it survives the descriptor-template round trip and the stored direct
  assignment the bridge compares; and it moves between wallpapers like the scaling
  factor (the live position stays for the same wallpaper, the next descriptor's is
  taken for a different one). These are pure state tests: none opens a renderer or a
  window, so `SceneRuntime::set_framing` against a live renderer is covered only by
  a desktop run.
- `wallpaper-bridge` framing coverage (`cargo test --release -p wallpaper-bridge
  --lib -- config::wallpaper tests::activation_plan`): a display's saved position
  (`FramingCfg` in the wallpaper config's `monitors` entry) is written only when it
  is not centred and round-trips; a hand-edited value is clamped or read as centred
  without losing the file's other settings, because a file that fails to parse is set
  aside whole; the scene built for a display carries that display's position and no
  other display's, whichever selector (Primary or identity) addresses it; a mirror is
  centred even when its source is positioned; and a position changes neither the
  native video descriptor nor its admission key, so moving a clip never restarts the
  native player.
- `wallpaper-bridge` position setter (`cargo test --release -p wallpaper-bridge --lib
  -- display_position wallpaper_options_draft drafts::`): `set_display_position`
  tells the fake engine once with the display's live handle and never reopens the
  scene; the position survives a restart; repeating it, naming neither axis or
  centring a display nobody positioned neither writes the file nor calls the engine;
  an axis left out keeps its value; NaN, infinite and out-of-range axes are refused
  whole with nothing saved or sent; Cancel keeps the position and Apply reopens no
  scene for it, yet a reopening Apply carries it; a refused engine update leaves the
  position saved for the next reconcile, and a failed save leaves nothing saved so
  asking again saves it; two displays keep their own positions.
  The engine here is the fake one, so the move on a live renderer is a desktop check.
- `wallpaper-bridge` position reports (same filter): the options snapshot carries each
  display's position, only a moved display offers Restore defaults, the reply to a move
  already carries it and a restart loads it; the lock-screen export carries a scene's
  and a natively played video's saved position, centres a web page and a mirror, and
  follows a position at once while an unapplied scale factor stays out of it.
- `wallpaper-bridge` reduced-quality request (`cargo test --release -p wallpaper-bridge
  --lib -- tests::quality_throttle tests::quality_settings tests::performance_settings
  tests::settings_intents`): `set_quality_throttle` lowers every open scene live through
  the same `set_render_scale` and `set_fps` calls the battery profile uses, never rebuilds
  the scene list, and an empty list hands the saved scale and the display's own rate back.
  It only ever lowers: a scale or cap already below the profile stays, and a table over
  saved scale, saved cap, battery profile and request pins the stricter-of rule, including
  that the battery profile alone still returns the profile's scale as is. The request is
  deduplicated and reported sorted, one cause ending keeps the others in force, it is
  never written to `config.toml` and a new bridge starts without one, a wallpaper applied
  under it opens at the lowered rate and scale, web, lock-screen and native-video
  descriptors follow it (a refusal recorded for the old rate is dropped, as for a cap),
  playback is never touched, and asking again after a refused renderer update re-applies it.
  A clip the native player refused at the old rate goes back to it the moment the ceiling
  moves, whichever change moved it (a throttle, the cap, the rate or mode of the battery
  profile, the power source), and a request that failed halfway or whose scene rebuild failed
  still hands the clip back when it is repeated or the host asks what to play next, because
  the rebuild stays owed until one succeeds. The engine is the fake one, so a live Metal or
  Vulkan scene following the change and any power effect are desktop checks.
- `wallpaper-core` and `wallpaper-bridge` drag previews (`cargo test --release -p
  wallpaper-core --lib framing`; `cargo test --release -p wallpaper-bridge --lib
  display_position`): `WallpaperEngine::preview_framing` refuses an invalid position
  before it asks the actor and forwards a valid one. `preview_display_position` tells
  the fake engine's preview call once per step with the display's live handle, and
  writes no file, changes neither the lock-screen export nor the options, leaves nothing
  for a display refresh to rebuild, and a restart still opens the scene centred; an axis
  left out follows the saved position, not the last step; a position outside 0 to 1, NaN,
  an infinity and an unknown wallpaper are refused with nothing shown, while a display
  no engine scene draws (a native video, a disabled display, a web page, a mirror or an
  unknown display) is not an error. The release is an ordinary `set_display_position`
  that saves and clears the preview mark; a drag that ends at the saved position puts the
  scene back once without writing, a scene on another display is not told, and a
  refused release keeps the mark for the next try. These are fake-engine tests:
  `SceneRuntime::preview_framing` leaving the runtime's descriptor and stored template
  alone (so an abandoned drag leaves nothing to rebuild) is by construction and is
  covered, with the picture itself, only by a desktop run.
- `wallpaper-core` property previews (`cargo test --release -p wallpaper-core --lib
  property`; `--test core_audio_api`): `WallpaperEngine::preview_property_override`
  refuses a document that is not a JSON object (an array, a number, a string, `null`,
  text that is not JSON, nothing at all) or has an array leaf before it asks the actor,
  with the message `set_property_override` gives for the same document, and forwards
  an empty, a flat and a nested one to the actor; the document the renderer receives is
  one flat object (nested keys joined with underscores, `null` as the empty string, key
  order and spacing normalised). `OweScene` sets a property of its own, not the
  override's, the reset's or the shader refresh's, and refuses a document with a NUL
  byte and a closed scene (also one it was last shown the document) without reaching
  the renderer. Through an allocated, never initialised renderer object, which takes
  property updates like a running one: it remembers the document it was shown until the
  scene is loaded again by `set_property_override` or `reset_property_override`, a
  refused document leaves what it shows alone, and `preview_on_scene_of` hands a
  document made for another wallpaper to nothing (`OtherWallpaper`, the renderer's record
  unchanged) and one made for the scene's own to the renderer. `SceneRuntime` itself
  has no test, because it needs a window: it leaving the runtime's saved override,
  descriptor and stored template alone (so an abandoned edit leaves nothing to rebuild)
  is by construction, like `preview_framing`, as is passing its own `scene_path` to
  `preview_on_scene_of`, and the picture is covered only by the renderer tests above and
  a desktop run.
- `wallpaper-bridge` property previews (`cargo test --release -p wallpaper-bridge --lib
  property_preview`, and `--lib state::drafts` for the document builder):
  `preview_wallpaper_properties` tells the fake engine's
  preview call once per scene that draws the wallpaper, on two displays and a mirror,
  with the whole document, and writes no file, changes neither the lock-screen export
  nor the draft and leaves nothing for a display refresh to rebuild. The document equals
  the one Apply loads byte for byte, a restored property or restore all defaults sends
  the saved document (host-supplied defaults included), and a texture waits for Apply
  while a picked file, which is saved at once, stays in every later document. An untouched
  wallpaper sends nothing, and a document a scene already shows is not sent to it again;
  Revert and `show` false put the saved look back once and keep the draft; a refused update
  or a refused restore is repeated, the restore leaving the draft dirty; Apply drops the
  mark. The fake engine follows the real engine's rules, which the bridge relies on: it
  remembers per display what it was shown, forgets it when a reconcile gives the display a
  scene that is not the same wallpaper (the shader cache clear is one), and
  `rebuild_renderer_of` forgets it as an engine-internal recovery does, so a scene the
  engine kept is not told again, one it opened afresh or rebuilt is, and the bridge keeps no
  copy of its own. A document made for a wallpaper that a reconcile has just moved off a
  display (the apply held after the engine switched it, before the bridge committed) is
  declined for that display only, never recorded as sent to the scene that now draws another
  wallpaper, and a display still showing the wallpaper follows the edit and is the only one
  Revert puts back afterwards. A preview that lands while an Apply is loading does not make
  the Apply stale. A video, a web page and a wallpaper no display shows are a silent no-op, and an
  unknown wallpaper is refused. A value still being dragged (`pending`) goes on top of the
  draft for the document of that call alone, in order and the last for a property winning,
  without making a clean wallpaper dirty or writing a file; the next call that does not name
  it shows the draft, committing the value last shown sends nothing more and another value
  does, dragging back to the authored value puts the saved look back, a texture among the
  steps changes nothing, a drag with one refused step (unknown id, out of range, `NaN`, wrong
  kind, a colour channel, an option that is not offered, in the same words as the edit's
  refusal) sends nothing, and a video is not asked about its steps. `tests::wallpaper_preview`
  holds the same list for the preview export: the step wins over the draft, the draft and its
  dirty marks do not move, a Web page follows too and a refused step exports nothing. These
  are fake-engine tests: what a real scene does with the document is covered by the renderer
  tests above.
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
  edits/default restoration/discard, a rule-hidden row staying in the snapshot
  (not enabled, with its value and modified state), hidden-value preservation, the visibility
  grammar (groups, constants, quoted text, `===`, list membership) deciding row
  visibility with synthetic ids, and fail-open behavior for unreadable rules,
  and a wallpaper's own `general.localization` tables following the language the
  host sets (whole-label matches only, English fallback, no change to the draft,
  no effect on a project without a table), and the staged Restore all defaults
  (every default shown but not committed, a chosen file kept, a value behind a
  hidden row reported as modified and then cleared, Revert bringing every value back, Apply persisting the
  defaults, an unknown wallpaper refused);
  `project::condition` also pins the input bounds (length, nesting, list size) and
  that hostile input returns an error instead of recursing, and
  `project::localization` pins the table bounds (languages, tokens, text size,
  overall bytes) and the language-list cleaning in the same way; `power::tests`
  for the power-source watcher: a sleeping or just-started watcher stops promptly
  when dropped (the old five-second wake would fail it), a wake signalled before
  the run loop starts is not lost, a delivery the actor rejected is offered again,
  and a resample requested by the host delivers a changed source once, leaves an
  unreadable one alone and does not delay shutdown (`tests::power_settings` applies
  the battery policy from such a change through the bridge). They use the real run
  loop and `IOKit` source but fake the read and the actor, and prove the
  sleep-until-signalled structure, not a measured saving.
- `shader`'s `pipeline` test skips asset-dependent cases (for example
  `genericimage4` and a Workshop package) with a printed `skipping …` reason; read
  those lines before claiming shader coverage. See
  [wallpaper-corpus.md](wallpaper-corpus.md) for the asset roots.

## C++/CMake test binaries

CMake test binaries are built under `artifacts/renderer/bin/` (executables in
its `tests/` folder). The authoritative routine build/run list is
`REGRESSION_BINARIES` in `scripts/check_renderer.py`, covering the parsers
(`scene_schema_tests`, `mdl_schema_tests`, `tex_schema_tests`, `version_tests`),
SceneScript, input and the media protocol (`script_runtime_compat_test`,
`mouse_input_test`, `scenescript_sound_layer_smoke`,
`scenescript_media_event_smoke`, `media_thumbnail_texture_smoke`), the shader
preprocessor (`shader_preprocessor_compat_test`, `unpack_shader_compile_smoke`),
Compatibility pass batching (`vulkan_render_batch_planner_smoke`, plain asserts
kept live in Release with `-UNDEBUG`), video playback-state merging
(`video_texture_submission_smoke`), and the texture/cache/lifetime, audio, video,
graph, particle, timer and Metal checks; a non-zero exit from any registered
binary fails the check. A test binary that is not registered fails unnoticed, so a
new one joins the registry in the change that adds it. The few executables in
`tests/CMakeLists.txt` that are neither registered nor one of the two probes are
listed in `MANUAL_BINARIES` beside the registry with the reason, and
`tests.test_check_renderer` fails on any other. Every registered binary
runs on each check, in CI too, so it has to stay fast and headless: no Metal
device unless its registry flag says so, no window, and no audio device. A test
that mounts a sound layer passes `SoundManager::OutputBackend::Null`, because a
mount opens the system output device even when nothing plays. Temporary files
carry the process id, because other checkouts run the same binaries at the same
time and share the temporary directory, and are removed when the test ends.

Two registered binaries also read a local corpus when there is one; the roots
and their defaults are in
[wallpaper-corpus.md](wallpaper-corpus.md#pointing-the-tests-at-your-local-corpus).
`version_tests` parses every `<id>/scene.pkg` under
`WALLPAPER_MACHINE_WORKSHOP_ROOT` and checks each package, texture and model
version it finds (a parsed model needs geometry; it may have no bones, which the
renderer draws as a static mesh). Without a corpus it generates no cases and
`CorpusSmoke.NonEmpty` skips, naming the folder it looked in; pointed at the app's
`Library` folder (60 items) it takes about 3 seconds. `unpack_shader_compile_smoke`
checks its compile-job building and path guards on every run. Its corpus sweep
compiles every shader-bearing material of every scene under
`WALLPAPER_MACHINE_UNPACK_ROOT`, with `WALLPAPER_MACHINE_ASSETS_ROOT` mounted, and
took 5 to 6 minutes for 60 scenes, so it is disabled and runs only on request:

```sh
WALLPAPER_MACHINE_UNPACK_ROOT=<folder of id/scene.json> \
  artifacts/renderer/bin/tests/unpack_shader_compile_smoke \
  --gtest_also_run_disabled_tests --gtest_filter='*ParsesCorpus*'
```

Run by hand only (`MANUAL_BINARIES`): `wpdump <workshop folder> [out.json]` writes
the snapshot `version_tests` checks for one item (package, scene, texture and
model versions and fields) as JSON, to inspect what the parsers make of it.

To iterate on one test, build and run its binary in the Homebrew environment from
`scripts/build.py`, once `check_renderer.py` has configured the build directory:

```sh
cmake --build artifacts/renderer/bin --target scene_schema_tests
artifacts/renderer/bin/tests/scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'
```

`tex_schema_tests` links `PkgConfig::TEST_LZ4` itself
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

`surface_health_test` (CPU only, in the check) pins the always-on surface health
reading with an injected clock: completed and presented frames advance
independently, a graph failure and a frame failure latch different reasons,
clearing the stop never clears the failure count, and the present age is unknown
before the first present.

`wallpaper_scaling_test` (CPU only, in the check) pins the presentation layout
function: the default position reproduces an in-test copy of the old centring
arithmetic bit for bit in every scaling mode, a position of 0 and 1 puts the picture
against the leading and trailing edges for an overflowing and a letterboxed picture
alike, non-finite values fall back to the centre and out-of-range ones clamp, and the
pointer mapping follows the position.

`project_property_preview_test` (CPU only, in the check) pins what a property
document means to a running scene: the project's declared defaults with exactly the
given values over them, whatever the scene loaded with, which properties a
scene reads only while it loads (a preview holds those at the loaded value), and
that a sound layer's volume follows its slider. It also sends documents through the
engine's `project_property_preview_json` command to a scene running on its render
thread: the newest document of a burst wins at the cost of one queued command, a
bad document or one with no scene yet changes nothing, and nothing is replayed to
the next scene. `layer_texture_reference_test` pins the one graph rebuild a preview
that reveals a hidden layer asks for, and `metal_scene_draw_smoke` the pixels: a
preview draws what a fresh load with the same values draws and the empty document
restores the first frame byte for byte; `unchanged_present_test` shows on a live
surface that a previewed slider presents once and that an on-demand scene wakes for
exactly one frame. See
[scene regressions](scene-regressions.md#scene-scripts-and-property-bindings).

`unchanged_present_test` exercises Compatibility frames that would repeat the
picture through a real swapchain on a `CAMetalLayer` no window owns. In
`AStaticSceneStopsPresentingOnceEveryPassIsReused` it also reads
`surfaceHealth()` across the 1000 ms window: with the skip on, frames completed
tracks the draws that ran while frames presented stays flat and no stop is
latched. That is the semantic a liveness check relies on: skipped frames are
completed, not presented. `ADrawFailureAfterTheFirstFrameIsReportedOnceAndASurfaceRebuildHealsIt`
runs the renderer's own failure routine through a test-only seam
(`SceneWallpaperInputTestAccess::InjectFrameFailure`, compiled only with
`WESCENE_BUILD_TESTS`) on a scene that has drawn: the render-failure callback
fires once, the stop latches as `FrameFailed`, the clock stops, a surface
reconfigure like the host's clears the stop and frames resume with the failure
count kept, and the next failure reports again.
`ADrawFailureBeforeTheFirstFrameIsCountedButNotReported` pins that a scene that
has not presented yet counts the failure and does not call back. The seam
replaces only the failure, not its consequences; a real swapchain failure is not
produced.

`LocalProjectEnergyIsMeasuredHeadlessly`, in the same binary, is the headless
renderer A/B: it skips unless `WE_TEST_ENERGY_PROJECT` names a local
`project.json` (with `WE_TEST_ASSETS`), then runs the production
`SceneWallpaper` on the renderer `WE_TEST_ENERGY_RENDERER` asks for
(`compatibility` or `native`) with its own 60 FPS clock into an unattached layer
of `WE_TEST_ENERGY_WIDTH` x `WE_TEST_ENERGY_HEIGHT` (default 1920x1080), waits
`WE_TEST_ENERGY_WARMUP` seconds (default 5) after the first frame and samples a
`WE_TEST_ENERGY_SECONDS` window (default 20). It prints one `ENERGY {...}` line:
the backend actually used, this process's CPU seconds and CPU energy
(`ri_energy_nj`), the GPU time of this process's own Metal command buffers and
how many there were (`gpu_own_s`, `command_buffers`: the test wraps the device's
command-buffer `commit` to read each buffer's GPU start and end, which counts
MoltenVK's buffers and the native backend's alike), the whole GPU's energy and
busy time over all resource coalitions (other processes included), frames
completed and presented, and the physical footprint. Counting is off and scene
optimisation on, as shipped; `WE_TEST_ENERGY_CACHE` keeps the shader and pipeline
caches between runs. Run one renderer per process, warm both caches with an
unmeasured run first and alternate the renderers. The whole-GPU figures are only
usable against an idle window of the same length on an otherwise quiet machine:
a process launched from a terminal shares a coalition with that terminal, and
any other process drawing at the time is in them. GPU time is workload, not
energy. It changes nothing on
the desktop and needs no privileges; it is not a power measurement in the
sense of [power benchmarking](power-benchmark.md), which observes the app and
WindowServer. The native
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
  [Shader pipeline](scene-regressions.md#shader-pipeline)).
- **Shadows, spot cookies and volumetric lights are not drawn.** A light with
  `castshadow` lights as if nothing cast a shadow (`_rt_shadowAtlas` is never
  written), a spot cookie lights through its cone instead of its cookie image, and
  `castvolumetrics` adds no light shafts. When a kind has more lights than its
  `lightconfig` count, the first ones in scene order are lit, where Wallpaper Engine
  sorts them first.
- Wallpaper Engine's `fur4` shader does not compile on its own: its instanced shells read
  the dialect's cast macros (`CASTF` among them), which the compiler does not supply with
  `CASTI`, `CASTU`, `CAST4U`, `DECLARE_SAMPLER2D_PARAMETER` and `MAKE_SAMPLER2D_ARGUMENT`.
  Its redeclared `gl_InstanceID` is no longer the obstacle.
- **Fog keys bound to user properties are not followed.** The `general` fog keys
  bound to user properties keep the value the scene loaded with.
- The `perspective` flag of an image layer is read by no parser (`WPTextObject`
  and `WPModelObject` read theirs); image layers always draw through the
  orthographic camera.
- **Object kinds not drawn or not modelled.** A `shape` object draws only an effect of
  a single pass: its last effect is drawn onto the scene as a mesh, so a multi-pass
  last effect, which would draw into buffers first, is left out (the editor's
  light-shaft effect has one pass).
- **File textures are sampled trilinearly.** Wallpaper Engine's sampler for a file
  texture is anisotropic (8x), which only shows on a surface seen at an angle (the
  local scene with 3D models), and it samples a shadow atlas through a comparison
  sampler for the shadow pass that does not exist here; neither backend does either.
  The anisotropy would cost fetches on every tilted surface, so it wants a
  measurement before it lands. The exception is a texture whose header asks for
  point sampling: both backends sample it with the mip level picked by point, as the
  reference's sampler for that flag does.
- **Text details not matched.** Wallpaper Engine shapes text with HarfBuzz (OpenType
  kerning, ligatures, complex scripts) and draws colour glyphs from an RGBA atlas; the
  layout kerns only from a font's legacy `kern` table (Arial has one, many OpenType
  fonts have only GPOS kerning and so go unkerned), forms no ligatures, and colour
  glyphs are monochrome or missing. It draws one quad per glyph from a distance-field atlas, so the outline of
  a glyph that overlaps its neighbour's fill is drawn over it there, and the outline,
  blur and shadow are made here from the union of the glyphs, at their reach but not
  clipped to the atlas margin. `msdf` alone, `opaquebackground`, `backgroundcolor` and
  `backgroundbrightness` are read and draw nothing. The screen `anchor` of a text layer
  moves the layer in its parent's space, so its children move with it; whether
  Wallpaper Engine's children inherit the shift is not established. **The authored
  `size` of a text object is kept**: Wallpaper Engine ignores it and sets the card from
  the layout every time the text is laid out (the text object's size function writes
  the layout box plus twice the padding, and its guard byte only keeps it from
  running while the object is still being built), so a scripted text that gets
  shorter has a smaller card there. Here the authored size stays the layout box a
  layer is aligned in and answers the cursor with, and the smallest the raster is, so
  such text keeps the stale card and the card is `bounds + 2 * padding` only where the
  authored size is not larger. The saved sizes of Arial text come out the same either
  way, since Wallpaper Engine wrote them from the same layout; the difference is text
  that changes. Changing it moves the placement of every text layer that has an
  authored size and needs a picture comparison. The distance fog and height fog flags
  of a scene, which make Wallpaper Engine pad and composite every text layer, are
  modelled for the padding only: the composite itself and the `FOG_COMPUTED` combo
  change nothing a text layer draws here. A style key (`outline`, `blur`,
  `dropshadow`, their sizes and opacity) driven by a script or a timeline keeps the
  scene file's value; one bound to a property is read once at load, with the user's
  value, and held there (a load-only property). The text object's other layout keys
  (`pointsize`, `padding`, `spacing`, `maxwidth`, `maxrows`, the limit flags) read the
  scene file's value whatever property or script is bound to them.
- **Cursor walk details.** Layers are walked in the scene's layer order, and the quad
  test keeps a coverage mask for layers whose scripts handle the cursor, which
  Wallpaper Engine's does not have. Wallpaper Engine lets no blocker stop the walk while
  a button is held with a captured set, and fires a click on release over the layer
  that took the press, where a script here gets enter, down and click together on
  press.
- **Model utility flags.** A project layer is sized by the canvas but still takes the
  passthrough path, not the compose one: it does not draw its children into a target of
  its own and has no composite-only mode (the 11 local scenes that use it hold layers of
  the canvas's size, where the two paths were not compared). `autosize` alone, which sizes a layer by its texture, and
  `solidlayer` are read and not applied.
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
  they rest partway and catch up at its next movement. Parallax eases as Wallpaper
  Engine eases it, closing `(1 - cameraparallaxdelay / 3) * 10 * frametime` of the
  remaining way each frame (`WPShaderValueUpdater::FrameBegin`), which approaches
  the cursor without reaching it; a correct demand needs a threshold on the offset
  still to travel.
- **An animated material constant keeps a scene awake after its timeline ends.**
  `DescribeTimeAdvancingWork` reports `NodeBinding` for every material-constant
  binding that has an animation, playing or not. The timeline's clock is a
  registered playback (`RegisterScalarAnimation` in the parser), which the
  `Animation` reason already counts while it plays, so with on-demand rendering
  on, a scene whose only motion was such a single-play timeline keeps ticking
  after it ends.
- **Particle differences from Wallpaper Engine 2.8.42 that remain.** Not
  implemented: the operators `vortex_v2`, `boids`, `remapvalue`, `inheritvaluefromevent` and
  the collision shapes `collisionbounds`, `collisionquad` and `collisionmodel`
  (their kernels or input/output tables are not decoded), the `remapinitialvalue`
  initializer, the `layerimage` emitter, the renderer `orientation`, `axis` and `flags`
  keys (the orientation uniforms stay the screen-facing constants), the rope trail's
  `fadealpha`/`fadesize` and the `uvscrolling` fade, a rope trail's thin vertex layout
  (it stays in the thick layout), and the geometry-shader path: ribbons use the
  vertex-shader fallback, which draws them with a fixed eye direction instead of
  one per segment and, because the shipped shader applies its width factor to
  the side offset before subtracting a constant (an operator-precedence slip in
  the shader's source), a half ribbon width off centre. Child control point chaining (`parentcontrolpoint`,
  flags 4 and 8), restarting flagged children at a periodic window, the audio
  emitters' burst and silence rules (a burst waits for sound and is scaled by it), the
  `turbulentvelocityrandom` initializer's different algorithm, the per-step time scale
  the drag uses, the half step at low frame rates, and an `eventspawn` child's emitters
  outliving its particle are unchanged. Turbulence uses Perlin noise where the
  engine's own noise function is not identified. `maxcount` is still capped at 20 000
  particles per file. A `worldspace` file keeps live particles in place when its layer moves;
  its spawn-time matrix rules (emitter origin added unscaled, velocity not scaled by
  the layer) are not reproduced. A sprite or rope keeps its authored pixel size when
  its layer is scaled in a pixel scene: Wallpaper Engine's shader builds the billboard in
  model space, which would scale it with the layer, but that policy is the authored
  canvas's established one and changing it needs a reference render first. Emitter
  defaults for a scene without a pixel canvas (sphere `distancemax`, box `directions`)
  are still the pixel set. A scene that names no `orthogonalprojection` is still
  drawn here as the default orthogonal canvas, while Wallpaper Engine's scene
  starts without an orthogonal projection; its particle defaults follow what is
  drawn (the pixel set), not the engine's scene-unit set. An event child's instance
  is prewarmed at the moment it spawns, inside the frame, as Wallpaper Engine does:
  a start time of 15 s costs about 300 steps of that child file's own system per
  spawned instance (about a millisecond on the local library), so a burst of
  many spawns with a long start time in one frame costs that many times as much;
  spreading the work over frames is not done, because it would change what the
  instance looks like when it first appears.
- Unimplemented non-audio scene features, including some script outputs, can
  still affect wallpaper compatibility even when every renderer check passes.
- No renderer check proves desktop presentation, AppKit behavior, live audio
  capture, real input capture, or visual equivalence. Those need the authorized
  manual checks in [manual-smoke.md](manual-smoke.md).
