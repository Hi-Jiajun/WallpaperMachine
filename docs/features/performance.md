# Performance

**Settings → Performance** is the first settings section and the one Settings
opens on. It is a playback and quality page. Every engine control is applied
through the bridge and the page re-renders from the snapshot the engine
returns, so the page never shows a setting the engine did not accept. Playback
choices that the app owns (other-app audio, display sleep, app rules) are
stored in `PlaybackPreferences` and published on the same snapshot.

Nothing on this page promises a measured power saving. A lower frame rate or
render scale is a quality tradeoff the user chooses. The **Energy use** readout
shows what the app draws now and, after a change, what it drew before; it is a
measurement, not a promise about any setting.

## Energy use

The first group, placed directly above **Quality** so a change and its effect
sit together, leads with the total power, a named energy grade, and separate
**CPU** and **GPU** readings. The breakdown sits beside the total when space
allows and below it in a narrow settings container. Battery share and any
before/after comparison follow the readings.

**How it’s measured** opens the accounting scope, GPU attribution, grade
thresholds and comparison guidance. It starts collapsed and keeps its open
state and keyboard focus across energy pushes and snapshot updates. Periodic
readings are not live announcements.

Readings cover this app, averaged over the last few seconds (four samples two
seconds apart, so up to six seconds). They are read without privileges from
the kernel's resource-coalition accounting (`CoalitionEnergySource`,
`EnergyUsageMonitor` in `App/Services/Diagnostics/`):

- **What is counted.** The app's own coalition, which macOS also charges for
  the XPC services the app starts: the panel's WebKit processes, the video
  decoder service's CPU work and the audio helper. The lock-screen extension
  runs in a coalition of its own and is added when a process from this bundle's
  `Contents/Extensions` is running.
- **What is not.** WindowServer compositing the wallpaper (measured at about
  0.2 W of GPU beside a 0.59 W scene), the hardware video decoder, DRAM and the
  display panel. macOS charges none of them to any app: decoding 720p H.264 at
  1,700 frames a second added about 2 W of CPU to the decoding coalition and
  nothing to its GPU energy or to the whole GPU's.
- **Native video.** A video on the native player (**Native video preferred**)
  is decoded by the media engine and drawn by WindowServer, so almost none of
  its cost reaches the app: a video wallpaper rated that way read 0.18 mW. While
  the engine's **In use now** report lists a `native` video, readings carry
  `nativeVideo`, the row reads **Native video not counted** with a note, and
  there is no grade, battery share or comparison; a comparison in progress is
  dropped, since switching a video to the native player would otherwise read
  as a near-total saving. A window that held a native-video sample stays
  flagged until it has aged out.
- **Loading.** The row's note says that right after a wallpaper is applied the
  figures include loading it. On an M5 Pro a scene's first load drew 6–7 W for
  2–4 s while its shaders compiled (10–22 J, most of it in `MTLCompilerService`)
  and a load with every cache warm about 1.5 J, so for a few seconds the
  figures and grade describe the load, not the wallpaper. The readout does not
  detect switches: it samples only while Settings is open, so a switch made
  from another page has already started when it begins.
- **How GPU energy is shared out.** The kernel splits the whole GPU's energy
  between coalitions by GPU time. When other apps keep the GPU busy, this app's
  frames run at their clock and share the GPU for longer, so the figure charged
  to it rises without the app doing more work: 0.59 W alone, 4.6 W beside a
  25 % GPU load and 15 W beside a saturating one on an M5 Pro. When other
  coalitions together occupy 25 % or more of the window
  (`EnergyUsageReading.contentionThreshold`), the readout says the GPU figure
  reads high and gives no grade, battery share or comparison until the GPU is
  free (`EnergyUsageReading.isComparable`). Below the threshold a figure can
  still read high: a 60 fps probe drawing 91 mW alone read 162 mW while other
  coalitions kept the GPU busy for 21 % of the window.
- **Grade.** `EnergyLevel` in Swift owns the thresholds: **Low** under 0.5 W,
  **Medium** under 2 W, **High** at 2 W or more, of CPU plus GPU. A MacBook Air
  doing light work draws roughly 3–5 W in total, so these read as about a tenth
  and about half again on its battery drain. The page only names the grade it
  was sent.
- **Battery share.** On a Mac with a battery, the row adds **About N% of a full
  battery charge per hour** (or less than 1%). `BatteryCapacity` reads today's
  full charge (`AppleRawMaxCapacity`, mAh) from the `AppleSmartBattery`
  registry entry, once per activation, and multiplies it by 3.85 V per cell;
  a desktop Mac has no such entry and shows no line.
- **Before and after.** A Performance setting that changes rendering work
  (`WebPanelController.renderingSettings`: presets, frame-rate limit, render
  scale, battery mode and quality, video backend, scene renderer and the scene
  and experimental switches) calls `EnergyUsageMonitor.settingChanged()` once
  the engine has accepted it. The window restarts, the row reads **Measuring…**
  with the last settled figure as **Before it**, and once four uncontended
  samples under the new setting exist it reads **Before your change: … Now: …
  (−N%)**. A second change before the first settled keeps the original
  "before". Without a settled, uncontended figure at the moment of the change
  there is no comparison. Leaving Settings drops it.
- **Cost.** One sample is about 3 ms of kernel calls (every coalition on the
  Mac is read for the contention check), taken off the main thread. Sampling
  runs only while the panel window is visible with Settings open; otherwise no
  timer exists. Settings tabs switch inside the page without telling native,
  so the other Settings tabs sample too. Readings reach the page through
  `window.wallpaperUI.energy(reading)`, not the snapshot, so a two-second
  update patches one row instead of re-rendering the panel. The object carries
  `level`, `batteryPercentPerHour` and `comparison` (`beforeMilliwatts`,
  `afterMilliwatts`) when they apply.
- **Unavailable.** The interfaces are private libsystem exports resolved with
  `dlsym`. If a macOS release removes one, the row reads **Unavailable on this
  Mac**. `EnergyUsageMonitorTests` checks that CPU work and Metal compute work
  in the test host move the CPU and GPU counters, which catches a moved struct
  field.

The accounting was checked against `powermetrics` and IOReport: the sum over
all coalitions matched the whole GPU within 5 % at idle and 6–9 % under load.
[Power benchmarking](../testing/power-benchmark.md) remains the way to compare
builds; this readout is for users.

## Per-wallpaper energy rating

The inspector of an installed wallpaper shows, once measured, a line such as
**Medium energy use, about 1.2 W. Measured while it played alone on 1 display
at 60 fps, 75% render scale, with this window closed.** It is measured in the
background by `WallpaperEnergyRecorder` and kept by `WallpaperEnergyRatings`
(both in `App/Services/Diagnostics/WallpaperEnergyRatings.swift`), owned by the
app delegate and reachable from the panel as `BridgeStore.wallpaperEnergyRatings`:

- **When a sample is credited.** Every 30 seconds the recorder asks the app
  delegate for a `WallpaperEnergyContext`. There is none, and no sample is taken,
  unless playback is playing, presentation is running (not display sleep, lock,
  app rule or other-audio pause), no download is running SteamCMD, the panel
  window is not on screen, exactly one wallpaper is assigned across the
  displays that are not suspended by occlusion, and none of those displays
  plays a video on the native player (`NativeVideoWallpaperHost.activeDisplayIDs`),
  whose cost macOS does not charge to the app. Stable `primary` and `identity:`
  selectors are resolved to connected physical display IDs first; an unknown
  mapping prevents attribution for that interval. Energy is charged to the whole
  app, so two different wallpapers cannot be told apart. An interval is
  credited only when both ends saw the same context and the GPU was not
  contended; any engine snapshot or presentation change in between invalidates
  it, so a pause and resume inside one interval is not counted. A sample
  taken within 8 s of such a change does not start an interval either, so a
  switch's shader compiling and texture decoding are not rated as playback.
- **Conditions.** The context records the displays showing it, the frame-rate
  ceiling in force (the battery one included) and the effective render scale.
  A measurement under other conditions replaces the rating rather than being
  averaged in, so the line always names the settings it describes.
- **Averaging.** Intervals combine as a time-weighted mean. History is weighted
  as at most 30 minutes, so a rating follows a wallpaper whose cost changed. A
  rating is shown after two minutes of credited time.
- **Storage.** `<support>/EnergyRatings.json`, keyed by wallpaper id. It is
  saved when a rating first appears or changes grade, at most every ten minutes
  otherwise, and on quit. An unreadable file is logged and starts empty. Each
  rating carries `version` (`WallpaperEnergyRating.currentVersion`); one from
  another version is replaced by the next measurement, not averaged with it.
  Ratings saved without a version may have credited native video playback, so
  a video wallpaper's is not shown.
- **Cost.** One coalition sample (about 3 ms of kernel calls) every 30 seconds
  while a single wallpaper plays; only a state check otherwise.
- **What it is not.** The figure includes everything in the app's coalition at
  the time, as the readout above does. Discover items have no rating.

## Playback

A wallpaper nobody can see — behind a full-screen app, on a hidden Space or
under windows that leave no pixel of it — pauses automatically, per display.
There is no control for that part.

| Setting | Values | Default |
| --- | --- | --- |
| When windows cover the desktop | **Pause**, **Keep running** | Pause |
| When another app plays sound | **Keep running**, **Mute**, **Pause** | Keep running |
| When displays sleep | **Pause**, **Stop (free memory)** | Pause |
| On battery | **Keep running**, **Reduced quality**, **Pause** | Keep running |
| In Low Power Mode | **Keep running**, **Pause**, **Stop (free memory)** | Keep running |
| When the Mac is hot | **Keep running**, **Pause**, **Stop (free memory)** | Keep running |

**When windows cover the desktop** handles the case AppKit never reports as
hidden. A zoomed (not full-screen) window leaves the strip under the translucent
menu bar and its own rounded corners showing, so the wallpaper window stays
"visible" and a scene kept drawing at the full frame rate for that strip: on
the 4112x2658 built-in display of an M3 Max, Lucy (3521337568) at about 100
frames/s cost about 5.5 W of app GPU. With **Pause** the display counts as
covered once other windows hide its working area — the screen minus the menu
bar and a shown Dock, inset by 32 pt — and that display pauses after the usual
one-second settle; the strip and the edges keep the last frame, and exposing
any of the working area resumes it at once. A translucent window does not
cover, because macOS decides what covers what. **Keep running** leaves the
wallpaper animating in the gaps. `WallpaperCoverageProbes` measures this with
one fully transparent, mouse-transparent window per display just above the
wallpaper; see [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling).

**Mute** affects scene and video wallpapers and, where WebKit exposes its native
output channel, Web wallpapers. Availability is shown in the wallpaper's details;
see [Page sound](web-wallpapers.md#page-sound). **Pause** applies to every wallpaper
and does not change the user's own Play/Pause.

Another app counts as playing sound while Core Audio reports it running audio
output (`kAudioProcessPropertyIsRunningOutput`). This app and the processes it
is responsible for, such as the WebKit processes playing a web wallpaper, are
excluded. Sound must last 0.5 s before it counts and silence 2 s before it
clears, so a gap between tracks does not restart the wallpaper. Nothing is
observed while the choice is **Keep running**.

**Stop** on display sleep frees renderer memory. The wallpaper is reloaded when
the display wakes. **Pause** keeps it loaded.

**On battery** is one choice. **Keep running** leaves quality alone. **Pause**
stops wallpapers until the Mac is plugged in. **Reduced quality** shows the
battery render scale (100% / 75% / 50%) and battery frame rate (1–240 fps,
default 30) underneath, plus whether the Mac is on battery. Those two fields
are sent together: changing one resends the other as the engine currently
reports it. Reduced quality is in force only while that mode is selected and
the Mac is on battery. A configuration saved before this choice existed keeps
its behavior: the old pause-on-battery switch becomes **Pause**, otherwise the
old battery profile switch becomes **Reduced quality**.

### Low Power Mode, heat and Focus

**In Low Power Mode** applies while macOS reports Low Power Mode
(`ProcessInfo.isLowPowerModeEnabled`), and **When the Mac is hot** while it
reports the thermal state as serious or critical, the states in which macOS
starts throttling itself. Both are off until chosen. Each row's note says whether
the condition holds right now.

A Focus can act on wallpapers through a Focus filter (`WallpaperFocusFilter`, an
App Intents `SetFocusFilterIntent`): in System Settings → Focus → a Focus →
Focus Filters, add WallpaperMachine and choose **Keep running**, **Mute**,
**Pause**, **Stop (free memory)**, **Use wallpaper** or **Use saved playlist**.
The latter two temporarily select content on an optional display; restoration and
manual-choice behavior are described in [Automation](automation.md#focus-selection-and-restoration).
macOS performs the filter with that value
when the Focus turns on and with the default, Keep running, when it turns off;
`FocusFilterState` keeps the last value across launches, and the app reads the
filter in force again at launch. **Open Focus Settings…** on the Focus row opens
that pane; the app cannot add a filter itself. Adding the filter needs no
permission.

`SystemConditionMonitor` turns the playback conditions into rule actions that join the app
rules' in `WallpaperPresentationPolicy`, so they pause, mute or stop wallpapers
exactly as an app rule does and never change the user's own Play/Pause. It only
observes notifications (`NSProcessInfoPowerStateDidChange`,
`ProcessInfo.thermalStateDidChangeNotification`, the preferences and the Focus
filter); nothing is polled. Web mute uses the same availability boundary as above.
Wallpaper and playlist selections instead reach `WallpaperAutomationScheduler`;
they never become pause/mute/stop actions or change the user's own Play/Pause.
The experimental [desktop Space mode](spaces.md) uses the same eligibility gate,
retains manual overrides for the current visit, and defers Focus exit while the
current desktop cannot be identified. Animated lock-screen ownership currently
conflicts with that mode; screen-saver-only ownership does not.

### App rules

**Edit…** opens an inline list. Each row is an app name, a condition
(**Running** or **In front**), an action (**Pause**, **Mute** or **Stop**) and
**Remove**. **Add app…** opens a native panel for one `.app` bundle. An app
with no bundle identifier is refused. The same bundle is not added twice.
Rules pause, mute or stop wallpapers while the chosen app matches. They do not
change the user's own Play/Pause. Web mute uses the same output channel and
availability boundary as above, without disabling its system-audio response.

## Quality

Presets set the frame-rate limit and the internal render scale together.

| Preset | Frame-rate limit | Render scale |
| --- | --- | --- |
| Low | 30 fps | 50% |
| Medium | 60 fps | 75% |
| High | No limit | 100% (native) |

High is the default. **Custom** is shown, and is not clickable, when the
current frame-rate cap and preferred render scale match none of those pairs.
The welcome guide's Performance page offers the same presets and slider
before its Preferences page; see [First run](control-panel.md#first-run).

**Frame rate limit** is a slider from 10 to the highest display refresh the
snapshot reports (`frameRateCapMax`, or 60 when no display publishes one), plus
one extra top position. Every value up to the refresh (for example 119 and 120
on a 120 Hz display) is a cap. The extra top position reads **No limit** and
sends null (no cap): each display then runs at its own rate, 60 fps by default
(below).
The effective rate on a display is the minimum of the saved per-wallpaper rate,
that display's refresh, the global cap, and the battery frame rate when
reduced quality is in force. Saved per-wallpaper frame rates are never
rewritten. When a Performance cap is below the saved rate, the inspector and
**Settings → Displays** say so and offer **Open Performance**.

**Internal render scale** is unchanged: 100% / 75% / 50%, with a hand-edited
value carried as its own option. It is the internal rasterization size only.
Output size and placement do not change. When no running wallpaper can honour
a scale the control is disabled. Values from a stale page are clamped to
`0.25...1.0`.

Whenever the effective `renderScale` differs from the saved
`preferredRenderScale`, **Effective now** shows the scale the engine published.
It names battery as the cause only while reduced quality is actually in force.

### Default per-display frame rate

A display with no saved rate runs at its refresh rate up to 60 fps: 60 on a
ProMotion MacBook Pro, a MacBook Air or a 60 Hz external display, 48 on a 48 Hz
one (`DEFAULT_FRAME_RATE_CEILING` in the bridge's `config` module). A scene's
cost follows its frame rate. On the 120 Hz built-in display of an M3 Max, with
the desktop exposed, Lucy (3521337568) drawn about 89 times a second took
5.0–5.2 W of app power and 0.51 W of WindowServer compositing; at this default,
60 frames a second, 3.0–3.3 W and 0.22–0.33 W. A higher rate is one choice
away: the per-display slider still goes up to the display's refresh.

The wallpaper config stores the rate as `frame_rate` in each `monitors` entry,
and a mirror display stores it as `frame_rate` in its `[[monitor_settings]]`
table; the key is omitted for the default, so the rate keeps following the
display if its refresh changes. Any other rate, the full refresh of a display
above 60 Hz included, is saved as chosen. Before this default a missing key
meant the display's full refresh, so a display left at "follow the display" in
an earlier build runs at 60 now; choosing the top of its slider again saves
that choice.

Earlier builds defaulted to 60 fps and wrote it as `fps` (wallpapers) or
`target_fps` (mirror displays). Those keys are read once on load: a legacy `60`
is indistinguishable from that old default and becomes the default;
any other legacy value is kept. The legacy keys are never written again, and an
older build reading a new file falls back to its own 60 fps default.

## Advanced

Collapsed by default, with a **Renderers & experimental options** preview.
Inside, three flat sections separate **Video backend**, **Scene wallpapers**
and **Experimental** rather than nesting settings cards. Scene renderer
selection comes before the optimisation and update-only-on-change switches.

Each renderer section has a collapsed **Live diagnostics** disclosure: video
shows the backend in use; scenes show the renderer and video path, whether
optimisation is in force, and what is keeping the scene updating. These reports
continue to update from snapshots, and their open state survives setting
changes. **Renderer compatibility** remains beside the scene diagnostics.

The experimental section groups content pacing, shared video decode and direct
video plane sampling. Shared-decode usage appears immediately below its switch
when sessions or consumers are reported. All switch labels retain their
descriptions and aligned controls. **What these settings change** stays last,
outside Advanced. Renderer behavior and saved preferences are unchanged.

## Renderer memory

On Apple platforms, the Compatibility renderer grows its Vulkan allocator in
8 MiB preferred blocks rather than the library's 256 MiB default. This reduces
unused reservations in unified memory; it is not a cap on wallpaper size, and
larger resources still allocate normally. The offscreen probe prints allocator reserved
and used bytes separately from process memory.

For scenes with an authored 2D canvas, both backends load packaged mip chains to
match the physical display: the longest texture edge is limited to the next
power of two at or above the display's longest edge. A 3024×1964 display therefore uses the authored 4K mip
instead of an 8K source level. Larger levels are skipped before decoding and GPU
upload. Layout metadata, render-target resolution, frame rate and effects stay
unchanged, but source detail can differ, especially when zooming into an image.
Display-surface replacement rebuilds the textures for the new display size.

Perspective scenes without an authored canvas retain the source mip chain:
a model or skybox can magnify a small UV region, so display dimensions alone
cannot establish which source detail is safe to discard. This can use more
texture memory, but adds no per-frame decoding or supersampling.

This policy uses available authored mips; a single-level image or an incomplete
chain may remain above the limit. Loose images, videos, sprite atlases, multi-slot
images and unknown encoded containers retain their original loading behavior.
This is a texture-residency reduction, not a fixed ceiling on total process memory.

Authored HDR scenes preserve overbright color in half-float targets and use
HDR bloom; non-HDR scenes keep the existing 8-bit path. Half-float targets cost
eight rather than four bytes per pixel, and the cache accounts for that actual
size. A six-level bloom pyramid starting at half-resolution contains less than
one third of a full-size target's pixels. This is real post-processing work,
not a free brightness adjustment or supersampling.
Spread uses bounded, normalized pyramid weights so widening a halo does not
multiply overall brightness. This is a general energy-conserving model; exact
Wallpaper Engine HDR parameter parity is not established.

Wallpaper Engine's [Ultra post-processing](https://docs.wallpaperengine.io/en/scene/effects/bloom.html)
enables HDR bloom. This app's High preset controls frame rate and render scale;
increasing FPS alone cannot substitute for HDR rendering. Authored HDR data
now selects the HDR path on either scene backend.

Native Metal allocates render targets only when the compiled graph writes or
samples them, plus the final output. Parser-provided shadow, mipmapped-frame and
bloom buffers are metadata until a pass needs them. References from hidden passes
and elided copies still count, so animation and live optimization toggles retain
the targets they can use. The same filter applies when a toggle reallocates targets.
This applies to scenes drawn with **Prefer Native Metal**; the Compatibility
backend already requests its targets from the cache as passes prepare them.

The lock-screen extension keeps its renderer paused while unlocked or asleep
to avoid a cold reload on wake; see [lock-screen memory tradeoff](lock-screen.md#enabling-it).
The desktop renderer still needs the textures and render targets of the active
wallpaper. An idle control-panel benchmark cannot establish its playback memory
usage, and the extension must be measured separately from the app coalition.
Its Metal layer remains nonopaque so a missing drawable reveals the retained
frame below it. That gives up the layer's opaque-compositing guarantee; the
WindowServer blending and energy cost has not been measured. Offscreen backing
pixel checks establish fallback correctness, not a compositor-performance result.

Closing the control panel releases its web view and allows its WebKit helpers
to exit, rather than keeping the whole page hidden. Reopening reloads the page;
see [panel lifecycle and import exception](control-panel.md#tabs).

## Repeated-work reduction

These internal optimizations do not change any setting, target frame rate,
render scale, animation speed or audio-response subscription:

- Metal and Compatibility passes borrow their uniform writer only for the
  synchronous update call. Matrices still update every frame, pack column-major
  into owned storage, and preserve the input scalar type until conversion to
  float. Fixed 4×4 values use the existing inline storage; larger values own a
  vector. No camera, bone, script or effect result is cached by this path.
- The audio-analysis FIFO advances a logical read position instead of moving
  its tail after every 1,600-frame window. Appends compact only when the
  consumed prefix is at least the retained suffix or the physical queue would
  exceed 96,000 frames (two seconds at 48 kHz). Stereo channels advance
  together, capacity grows geometrically within that bound, and every window is
  still copied and processed, 30 a second.
- Repeated system-media artwork skips redundant input conversion while still
  consuming every media-state message; see [media integration](media-integration.md).
- On Compatibility, a hidden layer's first-use clear is left out when nothing
  can see its target: no pass samples, copies, composes or draws over it later
  in the frame, and no pass before it could read the previous frame's clear.
  Anything that reads the target keeps the clear, and the frame in which a
  reader starts drawing clears it first.
- On Compatibility, the first draw into a composite that was just cleared to
  transparent (a group layer without copy-background) opens with that same
  clear, so the separate clear is dropped as redundant and the target is not
  cleared and then loaded. Later draws still load; the pass keeps the
  single-sample path it had.
- On Compatibility, a plain video wallpaper draws its decoded frame straight
  onto the display through the final composition's own viewport, scissor and
  sampler whenever the decoded frame is exactly the scene's size and the
  picture is not mirrored, instead of copying it into a video-sized image and
  resampling that. The bytes on the display are the same; a mirrored picture, a
  frame decoded at another size or any other scene keeps the copy.
- On Compatibility, each new video frame's colour conversion is queued ahead of
  the frame on the renderer's own GPU queue instead of being waited for on the
  CPU and submitted separately: one submission per new frame, and the images
  that wrap pooled conversion targets are made once and reused.
- Per-frame shader values are matched to their uniform slots through a per-pass
  table built once, instead of string-keyed lookups on every write. Every value
  is still written every frame.
- The Compatibility drawable is only ever rendered to, so macOS can treat it as
  framebuffer-only; a requested poster is drawn again into an image of its own
  (see [Scene renderer](#scene-renderer)).
- A hidden particle layer keeps its simulation and rebuilds its mesh on the
  first frame it is shown again, or while something samples it. The geometry is
  not generated for a frame that cannot read it.
- A video demuxer discards packets of streams it does not decode, and the
  wallpaper audio demuxer discards the video bitstream. The decoded picture,
  the PCM and the loop seam are unchanged.

- Discover retains animation sources only for visible tiles in a visible document.
  Scrolling a tile out of view, hiding the panel document or leaving Discover
  releases its animation source; returning loads from the existing disk cache.
  Stills and brightness-based fade handling are preserved. Failed or single-frame
  previews are not retried just because the user scrolls.
- Bridge snapshot bursts reuse one shader-cache size measurement for up to two
  seconds instead of walking its directory for every property or playback update.
  Explicit settings-snapshot requests and cache clearing force a fresh measurement.
  This affects storage statistics only, not shader loading or rendering.

Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not
displayed FPS; a power claim still requires the matched conditions described in
[power benchmarking](../testing/power-benchmark.md).

## Background work only while it has a consumer

These change no setting, frame rate, render scale or sound; they stop work that
nothing could see or hear.

- **Wallpaper sound output.** The Core Audio output a scene's sound layers or a
  video's own audio track play through starts only while something is mounted,
  the wallpaper is playing and it is not muted. A paused, muted or silent
  wallpaper, a wallpaper that arrives paused, and the lock-screen extension
  (always muted) start no output, so Core Audio runs no output cycle for them
  and holds no idle-sleep assertion on their behalf. The output was silence in
  every one of those states already, with sound positions frozen. Resuming or
  unmuting costs one device start.
- **System audio capture.** Runs only for a presenting wallpaper that actually
  reads the sound; see [audio response](audio-response.md). This only changes
  scenes that read no audio; a wallpaper that reads audio still runs the tap,
  and no drop in coreaudiod cost is claimed for it.
- **Pointer sampling.** Scenes receive the cursor from a sampler that runs when
  macOS reports pointer motion or a button, when an interactive scene appears or
  resumes, or when its pointer delivery is reset, at most once per 16 ms, with
  a move after a quiet stretch delivered at once. It no longer wakes 62.5 times
  a second with the pointer still, and a scene that is paused or covered is not
  a consumer, so a covered interactive scene does not keep it running. While
  this app is frontmost, where macOS routes pointer events past the monitors,
  the sampler checks the cursor every 16 ms and does engine work only when it
  moved. No new permission is needed.
- **Frame clock.** A wallpaper's frame clock starts when its scene is loaded,
  not when the renderer is created, so a surface still parsing or whose load
  failed has no clock thread. A global resume applies each display's own pause
  in one step, so a display that is still covered is never briefly resumed.
- A pointer sample that cannot move the next tick does not wake the frame
  clock, and a burst of samples while the clock is idle coalesces into one
  frame. The configured frame rate stays the ceiling.
- The video decode thread is woken when a frame is actually ready, not on every
  tick that has nothing new.
- Per-tick video counter bookkeeping runs only while renderer counters are on.
  With them off the counters stay zero and that bookkeeping does not run.

## Video backend

This control and its **In use now** report live in the **Advanced** disclosure.

| Setting | Values | Default |
| --- | --- | --- |
| Video playback | **Compatibility**, **Native video preferred** | Compatibility |

Native is a preference, not a guarantee: the engine selects a backend per
running wallpaper and keeps anything that does not qualify on Compatibility.
**In use now** lists the backend each running video wallpaper actually got, and
names the fallback reason when the user asked for native and did not get it. It
reads `No video wallpaper is running.` when nothing is playing video.

Applying a video checks that its entry is a readable, nonempty file. Container
and codec support are decided by the playback backend: AVFoundation's native
admission check must not block a file the Compatibility backend can decode,
including H.264 in Matroska. This applies both to **Apply** and **Apply changes**,
with either backend preference. Missing or empty files fail before display
settings change; decoder failures still go through the engine's apply recovery.

When the clip's audio output cannot start (no output device, or one that will
not start), AVFoundation fails the whole clip, muted or not, and reports only
`AVErrorUnknown` ("The operation could not be completed"). Native playback then
rebuilds the clip from its video track alone and keeps playing it natively
without sound, logging the original failure against the wallpaper's load. A
clip without audio, or one whose picture fails too, falls back to Compatibility
for the session as before. Native fallback reasons include each error's domain
and code, for example `AVFoundationErrorDomain -11800 < NSOSStatusErrorDomain
-66681`, so a report shows which part of playback failed.

An unrecognised backend name is refused rather than silently mapped to
Compatibility, so a stale page cannot report a choice that was never applied.

## Render scale details

The select lives in **Quality**, beside the presets and the frame-rate limit.

| Setting | Values | Default |
| --- | --- | --- |
| Internal render scale | **100% (native)**, **75%**, **50%** | 100% |

This is the internal rasterization size only. Output size, placement and
composition are unchanged; a lower scale rasterizes fewer pixels and draws the
result into the same area, so detail softens as the scale drops. It is a quality
tier and is not part of any same-quality backend comparison.

For 2D scenes, the authored canvas defines 100%. Perspective scenes with no
authored canvas use the physical output size instead of a fixed 1920×1080
fallback. The selected scale still applies, and the camera aspect follows the
surface. Higher-resolution output requires more raster work; this is native
resolution, not supersampling.

When no running wallpaper can honour a render scale the control is disabled and
reads `Not applicable to the wallpapers currently running`. Values arriving from
a stale page are clamped to `0.25...1.0`.

The engine clamps a render scale to `0.25...1.0` but does not quantize it to
these tiers, so a hand-edited `config.toml` can hold a value between them. The
control then carries that value as an extra leading option labelled
`60% (from configuration)` and keeps it selected, rather than displaying a
neighbouring tier the user never chose. Picking a tier replaces it.

## Scene wallpapers

| Setting | Values | Default |
| --- | --- | --- |
| Scene render optimisation | Off / On | **On** |
| Update only when the scene changes | Off / On | Off |
| Scene renderer | Compatibility / Native Metal preferred | Compatibility |

The only control here that ships on. It reuses the result of scene subgraphs
whose inputs have not changed and removes render passes proven redundant, inside
the scene renderer's own render graph. It is not a quality tier: the same pixels
are produced, and resolution, frame rate and animation speed are untouched. It
reaches wallpapers the scene engine draws: scenes on either renderer, and video
wallpapers on Compatibility, which the engine draws as a one-texture scene.
Native video and web wallpapers do not go through it.

It is on the **Settings -> Performance** page so it can be turned off and on
for an A/B comparison without an environment variable.

Unlike content pacing and shared video decode, which are read back from the
renderer, this row reports the saved preference: the renderer publishes no query
for it. The engine applies a change to running scenes in place, so nothing
restarts and no wallpaper reloads.

Reuse needs a target that is both cacheable and holding a pinned allocation,
because the render-target pool may otherwise hand that image to another key.
Pinning is bounded by a memory budget, so a graph whose targets do not fit at
the current output size ends up with nothing pinned. In that case the per-frame
sampling and signature walk that decide what to reuse are skipped outright:
their only reachable answer is "draw everything", and paying to reach it every
frame was pure overhead. The budget itself is unchanged; a target that cannot
be pinned still redraws.

### Frames that would repeat the picture

With scene render optimisation on, a frame that would put back exactly the
picture already on screen is not drawn, submitted or presented, and the surface
keeps showing the last frame. Two cases qualify:

- a Compatibility video wallpaper whose playback clock selected the same
  decoded frame as the last present, which is most ticks of a 24 or 30 fps clip
  under a 60 or 120 fps limit;
- a scene, on either renderer, whose every pass was reused from the previous
  frame, leaving only the final composition to redo.

The frame clock still ticks at the configured rate, and the scene still runs its
scripts, timeline, sound and events on every tick; only drawing an identical
picture is left out. A newly decoded video frame is presented on the tick that
selects it, exactly as before, so this is neither content pacing nor updating
only when the scene changes, and no drawable is held to keep the picture. A
resize, fill, scaling or flip change, a render-scale or scene-optimisation
change, a rebuilt graph or surface, a resumed wallpaper, a failed frame or a
poster request makes the next frame present. The renderer counters report these
frames as `presents_skipped_unchanged`, apart from dropped draws and present
requests.

Native Metal takes a drawable only after the scene's passes are encoded, so a
frame that repeats the picture takes none.

### Update only when the scene changes

Off by default, because stopping a wallpaper's clock changes what the user sees
happen. When a scene can be shown to have nothing that advances on its own, its
frame clock stops entirely instead of ticking at the configured rate: the last
frame stays on screen and events restart it.

This is not a frame-rate setting and it lowers no quality. It is also not the
same question as scene render optimisation. That one asks whether a render
target's pixels can be reused; this one asks whether the whole runtime can
sleep. A scene whose image happens to be still may still be running scripts,
sound and timelines, so both analyses must agree before anything stops.

A scene keeps its clock if any of these is present: a script or scripted
property, an animation, a particle emitter, a playing video texture, an
audio-reactive shader, a time uniform, an animated sprite, geometry rebuilt
every frame, a puppet, a feedback pass, a text layer whose content is computed
every tick, a sound layer, a node transform or material constant driven by a
script or an animation, text whose new layout has not reached a frame yet, or
any input the renderer could not account for. That last one is reported as **an
input the renderer could not account for**, and it is the answer when a
wallpaper does not go idle.

The distinction the list turns on is between something that *can* change and
something that *is* changing. A text layer's card is rewritten when the text is
re-laid out and its texture is replaced when the glyphs change, and a layer's
visibility is a binding whether or not anything ever moves it — none of which
means the scene has work to do. A static caption, a static caption over a static
background, a caption the user's own property supplies, an image replaced only
when a resource arrives, and any of those under a supported effect chain all
stop their clocks; the same layer driven by a script does not.

Pointer-reactive scenes do sleep, and pointer movement wakes them. Property
changes, resizes, display reconfiguration, resource updates, poster requests and
visibility changes all wake the scene, as does a text layout finishing on its
own thread; a wallpaper the user paused is never woken by any of them. Writing
a caption the layer already has is not a change and wakes nothing, which is what
keeps a script that returns the same string from defeating the whole feature.

Waking is not a licence to draw. The configured frame rate is a ceiling on
every path into a frame, not only on the periodic one: a request, a one-shot
appointment and an appointment already past all wait until one frame period
after the last frame, so a burst of pointer samples coalesces into one frame
per period instead of one frame each. After a quiet stretch longer than that
period the first event draws immediately, which is the case that matters for
responsiveness. Content pacing can make the *cadence* longer than the ceiling
and an event may cut that wait short — but only as far as the ceiling.

A request is never discarded to enforce any of that. It stays outstanding until
a draw actually consumes it, so a tick dropped because a draw was still in
flight loses the tick and not the update. The end of that draw re-arms the
clock, which is the only moment that can see both facts: the scene decides
whether it still needs the clock *after* the draw ends, so a request the
running clock left outstanding would otherwise have no later tick to notice it.
Nothing polls to find out — there is one wake at that edge, not a retry per
frame period.

Both renderers implement this. The status line below reports what each scene is
actually doing, so a backend that could not idle a particular scene is visible
as such rather than described in general.

The status line reports what each running scene is doing right now — updating
continuously and why, waiting for events, paused by you, suspended by the
system, or that the state could not be read. A scene that is running but cannot
be read says so; it is never shown as updating normally.

### Scene renderer

Which renderer scene wallpapers prefer. **Compatibility** is the existing
Vulkan-through-MoltenVK path and the default. **Native Metal preferred** asks
for the native Metal backend; the menu states that unsupported scenes use
Compatibility, while **Renderer compatibility** holds the full feature list.
A scene the native backend cannot draw runs on Compatibility and the status
line says why. Lock-screen playback always uses Compatibility.
Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and
rope-trail particles, perspective cameras for those layer types, ordinary
effect chains and scene post-processing, layers that read an image another
layer produced earlier in the same frame, images the runtime replaces while
the scene plays, and BGRA or 8-bit NV12 video textures — the latter either
converted once per frame or, with **Direct video plane sampling** on, sampled
by the layer's own shader. Lit particles, 3D models, dynamic lighting,
history-feedback effects, HDR or 10-bit video, plain video wallpapers and
shaders that do not translate fall back as a whole scene; an effect is never
dropped to keep a scene native.

Compatibility (Vulkan) instantiates leaf `.mdl` model objects, activates the
scene's perspective camera when `orthogonalprojection` is null or `isOrtho` is
false, and a visible camera object named `default` replaces the editor preview
pose as `activeCamera`. It writes live `g_EyePosition` / view-basis uniforms, honours material
`depthtest` / `depthwrite` / `cullmode` on a depth attachment for `_rt_default`,
keeps authored `scene.lights`, and still builds the LDR bloom chain when the
author set `hdr: true` so a sun glow is not skipped entirely. Native Metal
continues to refuse those scenes as a whole until that backend grows the same
depth, perspective and lighting path. `input.cursorWorldPosition` remains 2D
(`z = 0`), so scripted orbit drag may not match Wallpaper Engine.

A puppet is deformed by its author's own skinning shader on both renderers. The
pose comes from the one animation system the scene already has — animation
layers, their play, pause, stop, rate, blend and visibility, and any script or
user property driving them — and the renderer only uploads the resulting bone
matrices, so choosing a renderer does not change how a puppet moves. Rope and
rope-trail geometry is generated once by the shared particle simulation and
consumed by whichever renderer is active. Not implemented on either renderer:
the rope renderers' *UV scale*. A puppet model whose animation block the model
parser cannot read — seen locally with one format-version-23 model — is drawn
in its bind pose on both renderers, and the log says so when it loads.

A text layer is an ordinary layer here: it takes its place in the layer order
and carries its transform, opacity, blend, effect chain, camera and the final
composition, and it appears in desktop posters. Its typography is the engine's
existing text system's — the same fonts, layout and rasterisation the
compatibility backend uses — and choosing a renderer neither adds nor removes a
typographic feature. Text whose content has not changed is not laid out,
rasterised or uploaded again; a script that produces it still runs on its own
schedule every frame.
Effect and video output has not yet been compared against real wallpapers.

No GPU backend is created until the scene has been parsed and a backend chosen,
so the row reports one of three states per scene: **preparing** (no backend
yet), the backend actually in use, or Compatibility with the reason native was
not used. It never shows the preference in place of the outcome. The
lock-screen extension always uses the compatibility backend.

Desktop posters work on both backends and need no setting: each re-draws its
final composition — fit, zoom and flip included — into an image of its own only
when a poster is requested, including while the scene is idle or paused. The
Compatibility drawable is therefore only ever rendered to, never read back.
**Scene optimisation** applies to both renderers, and a change to it
now reaches a running scene on that scene's next frame in either direction: the
copy plan, the targets it governs and the reuse table are rebuilt over the graph
that is already compiled, without reparsing the project, reopening a video or
resetting a timeline. The row beneath the switch reports what each running scene
is actually under, so a preference that has not reached a scene yet is visible
as such rather than looking applied.

Compiled work is reused across launches where it can be. A scene's translated
Metal shaders, their reflection and their binding plans are stored in that
scene's shader cache and read back instead of being translated again — including
the optional direct-plane program, which is prepared in the background and now
survives a restart the same way. Alongside them, the render pipelines Metal
built are kept in a binary archive in that same directory and handed back to
Metal the next time the same pipeline is created, so each wallpaper has its own
store even when two displays are showing different ones.

Every one of those is a separate saving and none of them removes the others: a
stored shader means no translation ran, a stored pipeline means Metal did not
have to produce that pipeline's compiled form again, and the first use of a
program in a process still costs some compilation whatever is cached. An archive
that cannot be read, is from another machine, or is simply missing is not a
failure — the pipeline is compiled exactly as it was before, and the wallpaper
loads. All of it is regenerable and all of it is removed by **Clear shader
cache** in Storage; nothing you imported is stored there.

Compatibility keeps no compiled Metal code of its own. MoltenVK's pipeline cache
(`vk-pipeline-cache.bin`, beside the same scene's shaders) stores the Metal
source MoltenVK generated, which saves translating it again but not compiling
it; the compiled forms come from macOS's own Metal shader cache. That cache
survives relaunching the app, rebuilding it, a new version number and a bundle
replaced at the same path, but it keeps compiled Metal source per app location:
a second copy of the app at another path — an installed copy beside a
development build, say — compiles each wallpaper's shaders again the first time
that copy loads it, once. Compiled pipelines are shared between copies. On Lucy
(3521337568), with the offscreen probe on an M5 Pro under macOS 27.0.1, a load
with every cache warm cost 2.0–2.2 J of CPU energy; with only the compiled
source missing, 21.7–22.1 J, 19.5–19.8 J of it in `MTLCompilerService`; with
only the pipelines missing, 4.1 J. The native backend's binary archive stores
pipelines, so it covers the smaller part: both backends compile Metal source
through the same per-location cache. Method and the full table are in
[renderer testing](../testing/renderer.md#metal-compile-across-processes).

Measured so far on one scene only — Workshop 3620484312, a 3840×2160 canvas on
the built-in 3456×2234 display, with other applications running (numbers in the
verification log). Native Metal used to start a render pass for every pass of
the frame, about 180 here, most of them for hidden layers. Consecutive passes
into one image now share a render pass and a hidden layer starts none (47 here),
and a copy a layer makes only to read the image it draws into — 21 full-frame
copies a frame here, one per clipping-mask layer — is replaced by trading the two
images' textures. The picture is byte-identical, and offscreen CPU per frame
fell from 1.8 ms to about 1 ms. In one desktop pair, the two diagnostics windows
reported approximately 51.3 draws/s; app GPU busy time was 38.6 % versus 33.0 %,
and CPU + GPU + ANE combined power was 2.5 W versus 2.3 W. The power and counter
windows started independently, so this is not proof of matched throughput over
the power window. Neither these numbers nor the earlier render-pass comparison
establish a same-quality whole-machine power saving.

Battery runs on the built-in display recorded 10–25 W of system load with the
app quit, and 21–29 W with this wallpaper at a configured 60 fps ceiling.
Diagnostics observed 45–52 draws/s; the cause of that shortfall was not
established. A 30 fps ceiling recorded 17.5–18.9 W, and a 1 fps run recorded
17.6 W. Those ceilings are quality tradeoffs, not same-quality optimizations.
Background load and independently timed windows prevent subtracting these
ranges into a reliable wallpaper-only watt figure or attributing the difference
to memory or display hardware. CPU + GPU + ANE combined power is not whole-Mac
power. The audio-reactive runs also recorded coreaudiod at 13–17 % CPU, including
at 1 fps. No isolated energy saving has been established for the caches above.

## Experimental switches

All three switches are experimental and off by default.

| Setting | Notes |
| --- | --- |
| Content pacing | Drives presentation from the content's own frame cadence instead of the display refresh |
| Shared video decode | Lets equivalent display surfaces showing the same video share one decode session |
| Direct video plane sampling | Lets a Native Metal scene's own shader read the decoder's two video planes instead of a colour image converted for it each frame |

When shared decode is actually merging work, **Shared decode in use** reports the
live session and surface counts the engine publishes. Sharing is reported only
where it genuinely happens: surfaces still submit and present separately.

### Direct video plane sampling

An 8-bit NV12 frame is two planes — full-resolution luma and half-resolution
chroma — and turning it into one colour image is a full-frame pass the GPU runs
before any layer samples it. Where a layer's own shader can do that conversion
while it samples, the pass is not needed at all.

The renderer does not rewrite anything at run time to achieve this. While the
scene is parsed, a material with exactly one video texture records everything a
second translation of the same author source would need. Nothing is compiled
then: the wallpaper loads and draws with its ordinary program first. Only if the
switch is on is the second program produced, on a background worker, and its
Metal pipeline built off the frame thread; the scene adopts it between frames
when it is ready. With the switch off nothing is prepared at all, and no shader
is ever compiled inside a frame either way.

What each running scene actually did is reported per scene in **Drawn by**:
sampled directly, converted once per frame, both for a scene whose materials
differ, or converted while the direct program is still being prepared — which
means the wallpaper is playing normally and a second program is still on its
way. A material whose shader the translation cannot reproduce — an explicit
level-of-detail sample, a size query, a texel fetch, two video slots in one
material — keeps converting and says nothing; so does any frame that is not
8-bit NV12, which is what a software decoder produces for the same file. Nothing
here changes which renderer draws a scene.

**Where the two differ.** At a one-to-one mapping between video texels and
output pixels the two paths produce the same picture, to within the single code
value the converted intermediate's own 8-bit quantisation can introduce. Where
the layer is resampled they are not identical, and the reason is structural: the
converting path clamps each texel to the range the stream declares and quantises
it before the layer's sampler filters, while the direct path filters first and
clamps the result. The transform between those two clamps is affine, so the two
orders agree exactly wherever the clamp does nothing — which is every sample a
conforming stream carries. Where a stream carries codes outside the range it
declares, they can differ by up to the excursion that clamp removes, which for
8-bit limited range is at most 24 code values; a deliberately out-of-range
synthetic probe measured 19. This is a real difference, not floating-point
noise, and it is why the setting is opt-in.

No power measurement of any kind has been taken. What is claimed is that a
conversion is not encoded and its destination is not allocated when nothing asks
for one — not that this saves a measurable amount of anything.

## Verification

See [Testing](../testing/README.md) and
`Tests/Unit/Panel/WebPanelPerformanceSettingsTests.swift`, which covers
clamping, refusal of an unknown backend or battery mode, the frame-rate cap
(including null as no limit), quality presets, app-rule add/update/remove, and
the snapshot keys the page reads.
`Tests/Unit/Diagnostics/EnergyUsageMonitorTests.swift` covers the milliwatt
arithmetic, coalitions missing from one sample, the contention threshold, the
averaging window, the live counters, the before/after comparison (settled
baseline, repeated changes, contended windows), the grade boundaries, the
battery share and `BatteryCapacity` parsing; `WallpaperEnergyRatingsTests`
covers when an interval is credited to a wallpaper, how measurements combine
or replace one another, and persistence; `WebPanelEnergyUsageTests` covers
that the readout samples only while Settings is visible.
The renderer-side behaviour above (frames that repeat the picture, sound output
and audio capture only while needed, event-armed pointer sampling, the frame
clock starting with a scene) is covered by the regression areas in
[renderer verification](../testing/renderer.md#regression-areas-that-must-stay-covered).
Those tests prove the work stopped; they are not power measurements, which
still need the matched conditions in [power benchmarking](../testing/power-benchmark.md).
