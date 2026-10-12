# Runtime regressions

Regression areas for how the renderer runs: the native Metal backend, video,
continuous-playback work, frame timing and idle, audio, the host's half of
rendering, and startup. Each bullet names the test that guards a behavior and
the invariant or trap it protects; keep them covered when touching that area.
The commands, probes and by-hand test binaries are in
[renderer.md](renderer.md), which also holds the rules that apply to every
entry ([Regression areas that must stay covered](renderer.md#regression-areas-that-must-stay-covered)).
Scene-content areas are in [scene-regressions.md](scene-regressions.md).

## Native Metal backend

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

## Video decode, color and import

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

## Continuous-playback work contracts

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

## Frame timing, pacing and idle

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

## Audio

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

## Host, bridge and display behavior

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
- **A display that reports no pixels is left out of the refresh** — `display::state::tests::a_running_display_that_reports_no_pixels_keeps_its_descriptor_and_runtime`,
  `::a_new_display_that_reports_no_pixels_gets_no_record_until_it_has_a_size` and
  `::transitional_matching_uses_identity_when_the_display_id_changed`, with
  `display::tests::plan_refresh_*` and `engine::tests::a_secondary_display_without_pixels_is_left_out_until_it_reports_a_size`.
  A display that is still connecting can be listed as active with a 0x0 mode, and
  opening a window for it fails the whole reconcile. It must stay out of the
  refresh, yet a display that already runs a scene must keep its descriptor:
  reading it as absent would close the scene and reload it after the glitch. All
  descriptors are synthetic; a real display that reports 0x0 while connecting was
  not reproduced.
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

## Startup and staging buffers

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
- **A wallpaper that kills the app while it loads is held back.** The saved
  configuration is replayed at every launch, so a scene that crashes the
  process on load would crash every launch. The bridge's load journal records
  the scenes about to open (`engine/load_journal.rs`) and keeps them through a
  20 s settle window after the first frame and over the render-scale, audio and
  mute calls that follow the scene (the changelog records a launch crash after
  applying a render scale). Two launches in a row that
  die mid-load hold the wallpaper out of every plan; Apply, the panel's
  Try again, an app update, or its removal from the library releases it, and
  nothing is deleted.
  `engine::load_journal::tests` and `tests::crash_loop_guard` (fake engine, a
  record that never ends playing the crash) must keep covering: a quit while startup holds the actor, one strike per
  dead session and wallpaper, the hold persisting across launches, a failed
  load and a quit during a load leaving no strike, only scenes that really open
  being recorded, Apply reaching the engine for an unchanged draft, a rotation leaving a hold alone, and a Try
  again that fails leaving the wallpaper held (`ControlPanelHeldWallpaperTests`
  covers the banner and the action). A real
  engine crash is not reproducible headlessly; see
  [crash recovery](../features/crash-recovery.md#verification).
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
