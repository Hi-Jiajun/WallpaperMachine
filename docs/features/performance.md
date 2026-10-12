# Performance

**Settings → Performance** is the first settings section and the one Settings
opens on. It is a playback and quality page. Every engine control is applied
through the bridge and the page re-renders from the snapshot the engine returns,
so the page never shows a setting the engine did not accept. Playback choices
that the app owns (other-app audio, display sleep, app rules) are stored in
`PlaybackPreferences` and published on the same snapshot.

Nothing on this page promises a measured power saving. A lower frame rate or
render scale is a quality tradeoff the user chooses. The **Energy use** readout
shows what the app draws now and, after a change, what it drew before; it is a
measurement, not a promise about any setting.

## Energy use

The first group, placed directly above **Quality** so a change and its effect sit
together, leads with the total power, a named energy grade, and separate **CPU**
and **GPU** readings. The breakdown sits beside the total when space allows and
below it in a narrow settings container. Battery share and any before/after
comparison follow the readings.

**How it’s measured** opens the accounting scope, GPU attribution, grade
thresholds and comparison guidance. It starts collapsed and keeps its open state
and keyboard focus across energy pushes and snapshot updates. Periodic readings
are not live announcements.

Readings cover this app, averaged over the last few seconds (four samples two
seconds apart, so up to six seconds). They are read without privileges from the
kernel's resource-coalition accounting (`CoalitionEnergySource`,
`EnergyUsageMonitor` in `App/Services/Diagnostics/`):

- **What is counted.** The app's own coalition, which macOS also charges for the
  XPC services the app starts: the panel's WebKit processes, the video decoder
  service's CPU work and the audio helper. The lock-screen extension runs in a
  coalition of its own and is added when a process from this bundle's
  `Contents/Extensions` is running.
- **What is not.** WindowServer compositing the wallpaper, the hardware video
  decoder, DRAM and the display panel: macOS charges none of them to any app.
  WindowServer's share follows the wallpaper's present rate; see
  [power benchmarking](../testing/power-benchmark.md#windowservers-share).
- **Native video.** A video on the native player (**Native video preferred**) is
  decoded by the media engine and drawn by WindowServer, so almost none of its cost
  reaches the app. While the engine's **In use now** report lists a `native` video,
  readings carry `nativeVideo`, the row reads **Native video not counted** with a
  note, and there is no grade, battery share or comparison; a comparison in
  progress is dropped, since switching a video to the native player would
  otherwise read as a near-total saving. A window that held a native-video sample
  stays flagged until it has aged out.
- **Loading.** The row's note says that right after a wallpaper is applied the
  figures include loading it (shader compilation can dominate for a few seconds;
  see [Metal compile across processes](../testing/renderer.md#metal-compile-across-processes)),
  so for a moment the figures and grade describe the load, not the wallpaper. The
  readout does not detect switches: it samples only while Settings is open, so a
  switch made from another page has already started when it begins.
- **How GPU energy is shared out.** The kernel splits the whole GPU's energy
  between coalitions by GPU time. When other apps keep the GPU busy, this app's
  frames run at their clock and share the GPU for longer, so the figure charged to
  it rises without the app doing more work. When other coalitions together occupy
  25 % or more of the window (`EnergyUsageReading.contentionThreshold`), the
  readout says the GPU figure reads high and gives no grade, battery share or
  comparison until the GPU is free (`EnergyUsageReading.isComparable`). Below the
  threshold a figure can still read high.
- **Grade.** `EnergyLevel` in Swift owns the thresholds: **Low** under 0.5 W,
  **Medium** under 2 W, **High** at 2 W or more, of CPU plus GPU. A MacBook Air
  doing light work draws roughly 3–5 W in total, so these read as about a tenth
  and about half again on its battery drain. The page only names the grade it was
  sent.
- **Battery share.** On a Mac with a battery, the row adds **About N% of a full
  battery charge per hour** (or less than 1%). `BatteryCapacity` reads today's full
  charge (`AppleRawMaxCapacity`, mAh) from the `AppleSmartBattery` registry entry,
  once per activation, and multiplies it by 3.85 V per cell; a desktop Mac has no
  such entry and shows no line.
- **Before and after.** A Performance setting that changes rendering work
  (`WebPanelController.renderingSettings`: presets, frame-rate limit, render scale,
  battery mode and quality, video backend, scene renderer and the scene and
  experimental switches) calls `EnergyUsageMonitor.settingChanged()` once the
  engine has accepted it. The window restarts, the row reads **Measuring…** with
  the last settled figure as **Before it**, and once four uncontended samples under
  the new setting exist it reads **Before your change: … Now: … (−N%)**. A second
  change before the first settled keeps the original "before". Without a settled,
  uncontended figure at the moment of the change there is no comparison. Leaving
  Settings drops it.
- **Cost.** One sample is about 3 ms of kernel calls (every coalition on the Mac
  is read for the contention check), taken off the main thread. Sampling runs only
  while the panel window is visible with Settings open; otherwise no timer exists.
  Settings tabs switch inside the page without telling native, so the other
  Settings tabs sample too. Readings reach the page through
  `window.wallpaperUI.energy(reading)`, not the snapshot, so a two-second update
  patches one row instead of re-rendering the panel. The object carries `level`,
  `batteryPercentPerHour` and `comparison` (`beforeMilliwatts`, `afterMilliwatts`)
  when they apply.
- **Unavailable.** The interfaces are private libsystem exports resolved with
  `dlsym`. If a macOS release removes one, the row reads **Unavailable on this
  Mac**.

How the accounting was validated against `powermetrics` and IOReport, and what it
cannot see, is in
[power benchmarking](../testing/power-benchmark.md#per-app-energy-without-root),
which also remains the way to compare builds; this readout is for users.

## Per-wallpaper energy rating

The inspector of an installed wallpaper shows, once measured, a line such as
**Medium energy use, about 1.2 W. Measured while it played alone on 1 display at
60 fps, 75% render scale, with this window closed.** It is measured in the
background by `WallpaperEnergyRecorder` and kept by `WallpaperEnergyRatings` (both
in `App/Services/Diagnostics/WallpaperEnergyRatings.swift`), owned by the app
delegate and reachable from the panel as `BridgeStore.wallpaperEnergyRatings`:

- **When a sample is credited.** Every 30 seconds the recorder asks the app
  delegate for a `WallpaperEnergyContext`. There is none, and no sample is taken,
  unless presentation is running and playback is playing (no display sleep, lock,
  app rule, other-audio, Low Power Mode, heat, Focus-filter or battery pause), the
  control panel is not on screen, no live preview window is open, no download is
  running SteamCMD or fetching a pixiv original, exactly one wallpaper is assigned
  across the displays that are not suspended by occlusion, and none of those
  displays plays a video on the native player
  (`NativeVideoWallpaperHost.activeDisplayIDs`), whose cost macOS does not charge
  to the app. Stable `primary` and `identity:` selectors are resolved to connected
  physical display IDs first; an unknown mapping prevents attribution for that
  interval. Energy is charged to the whole app, so two different wallpapers cannot
  be told apart. An interval is credited only when both ends saw the same context
  and the GPU was not contended; any engine snapshot or presentation change in
  between invalidates it, so a pause and resume inside one interval is not
  counted. A sample taken within 8 s of such a change does not start an interval
  either, so a switch's shader compiling and texture decoding are not rated as
  playback.
- **Conditions.** The context records the displays showing it, the frame-rate
  ceiling in force (the battery one included) and the effective render scale. A
  measurement under other conditions replaces the rating rather than being averaged
  in, so the line always names the settings it describes.
- **Averaging.** Intervals combine as a time-weighted mean. History is weighted as
  at most 30 minutes, so a rating follows a wallpaper whose cost changed. A rating
  is shown after two minutes of credited time.
- **Storage.** `<support>/EnergyRatings.json`, keyed by wallpaper id. It is saved
  when a rating first appears or changes grade, at most every ten minutes
  otherwise, and on quit. An unreadable file is logged and starts empty. Each
  rating carries `version` (`WallpaperEnergyRating.currentVersion`); one from
  another version is replaced by the next measurement, not averaged with it.
  Ratings saved without a version may have credited native video playback, so a
  video wallpaper's is not shown.
- **Cost.** One coalition sample (about 3 ms of kernel calls) every 30 seconds while
  a single wallpaper plays; only a state check otherwise.
- **What it is not.** The figure includes everything in the app's coalition at the
  time, as the readout above does. Discover items have no rating.

## Quality

Presets set the frame-rate limit and the internal render scale together.

| Preset | Frame-rate limit | Render scale |
| --- | --- | --- |
| Low | 30 fps | 50% |
| Medium | 60 fps | 75% |
| High | No limit | 100% (native) |

High is the default. **Custom** is shown, and is not clickable, when the current
frame-rate cap and preferred render scale match none of those pairs. The welcome
guide's Performance page offers the same presets and slider before its
Preferences page; see [First run](control-panel.md#first-run).

**Frame rate limit** is a slider from 10 to the highest display refresh the
snapshot reports (`frameRateCapMax`, or 60 when no display publishes one), plus one
extra top position. Every value up to the refresh (for example 119 and 120 on a
120 Hz display) is a cap. The extra top position reads **No limit** and sends null
(no cap): each display then runs at its own rate, 60 fps by default (below). The
effective rate on a display is the minimum of the saved per-wallpaper rate, that
display's refresh, the global cap, and the battery frame rate when reduced quality
is in force. Saved per-wallpaper frame rates are never rewritten. When a
Performance cap is below the saved rate, the inspector and **Settings → Displays**
say so and offer **Open Performance**.

**Internal render scale** (100% / 75% / 50%) is the internal rasterization size
only. Output size, placement and composition are unchanged; a lower scale
rasterizes fewer pixels and draws the result into the same area, so detail softens
as the scale drops. It is a quality tier and is not part of any same-quality
backend comparison. For 2D scenes the authored canvas defines 100%; perspective
scenes with no authored canvas use the physical output size instead of a fixed
1920×1080 fallback, and the camera aspect follows the surface. This is native
resolution, not supersampling. When no running wallpaper can honour a scale the
control is disabled and reads `Not applicable to the wallpapers currently running`.

The engine clamps a render scale to `0.25...1.0` (values from a stale page are
clamped the same way) but does not quantize it to these tiers, so a hand-edited
`config.toml` can hold a value between them. The control then carries that value as
an extra leading option labelled `60% (from configuration)` and keeps it selected,
rather than displaying a neighbouring tier the user never chose. Picking a tier
replaces it. Whenever the effective `renderScale` differs from the saved
`preferredRenderScale`, **Effective now** shows the scale the engine published; it
names battery as the cause only while reduced quality is actually in force.

### Default per-display frame rate

A display with no saved rate runs at its refresh rate up to 60 fps
(`DEFAULT_FRAME_RATE_CEILING` in the bridge's `config` module): 60 on a ProMotion
MacBook Pro, a MacBook Air or a 60 Hz external display, 48 on a 48 Hz one. A
scene's cost follows its frame rate, and so does WindowServer's compositing share
([power benchmarking](../testing/power-benchmark.md#windowservers-share)). A higher
rate is one choice away: the per-display slider still goes up to the display's
refresh.

The wallpaper config stores the rate as `frame_rate` in each `monitors` entry, and
a mirror display stores it as `frame_rate` in its `[[monitor_settings]]` table. The
key is omitted for the default, so the rate keeps following the display if its
refresh changes; any other rate, the full refresh of a display above 60 Hz
included, is saved as chosen. The legacy keys `fps` (wallpapers) and `target_fps`
(mirror displays) are read once on load — a legacy `60` is indistinguishable from
the old default and becomes the default; any other legacy value is kept — and are
never written again.

## Playback

A wallpaper nobody can see — behind a full-screen app, on a hidden Space or under
windows that leave no pixel of it — pauses automatically, per display. There is no
control for that part.

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
"visible" and a scene keeps drawing at the full frame rate for that strip. With
**Pause** the display counts as covered once other windows hide its working area —
the screen minus the menu bar and a shown Dock, inset by 32 pt — and that display
pauses after the usual one-second settle; the strip and the edges keep the last
frame, and exposing any of the working area resumes it at once. A translucent
window does not cover, because macOS decides what covers what. **Keep running**
leaves the wallpaper animating in the gaps. `WallpaperCoverageProbes` measures this
with one fully transparent, mouse-transparent window per display just above the
wallpaper; see [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling).

**Mute** affects scene and video wallpapers and, where WebKit exposes its native
output channel, Web wallpapers. Availability is shown in the wallpaper's details;
see [Page sound](web-wallpapers.md#page-sound). **Pause** applies to every
wallpaper and does not change the user's own Play/Pause.

Another app counts as playing sound while Core Audio reports it running audio
output (`kAudioProcessPropertyIsRunningOutput`). This app and the processes it is
responsible for, such as the WebKit processes playing a web wallpaper, are
excluded. Sound must last 0.5 s before it counts and silence 2 s before it clears,
so a gap between tracks does not restart the wallpaper. Nothing is observed while
the choice is **Keep running**.

**Stop** on display sleep frees renderer memory. The wallpaper is reloaded when the
display wakes. **Pause** keeps it loaded.

**On battery** is one choice. **Keep running** leaves quality alone. **Pause**
stops wallpapers until the Mac is plugged in. **Reduced quality** shows the battery
render scale (100% / 75% / 50%, default 75%) and battery frame rate (1–240 fps,
default 30) underneath, plus whether the Mac is on battery. Those two fields are
sent together: changing one resends the other as the engine currently reports it.
Reduced quality is in force only while that mode is selected and the Mac is on
battery. A configuration saved with the former pause-on-battery switch maps to
**Pause**, otherwise the former battery profile switch maps to **Reduced quality**.

### Low Power Mode, heat and Focus

**In Low Power Mode** applies while macOS reports Low Power Mode
(`ProcessInfo.isLowPowerModeEnabled`), and **When the Mac is hot** while it reports
the thermal state as serious or critical, the states in which macOS starts
throttling itself. Both are off until chosen. Each row's note says whether the
condition holds right now.

A Focus can act on wallpapers through a Focus filter (`WallpaperFocusFilter`, an
App Intents `SetFocusFilterIntent`): in System Settings → Focus → a Focus → Focus
Filters, add WallpaperMachine and choose **Keep running**, **Mute**, **Pause**,
**Stop (free memory)**, **Use wallpaper** or **Use saved playlist**. The latter two
temporarily select content on an optional display; restoration and manual-choice
behavior are described in
[Automation](automation.md#focus-selection-and-restoration). macOS performs the
filter with that value when the Focus turns on and with the default, Keep running,
when it turns off; `FocusFilterState` keeps the last value across launches, and the
app reads the filter in force again at launch. **Open Focus Settings…** on the Focus
row opens that pane; the app cannot add a filter itself. Adding the filter needs no
permission.

`SystemConditionMonitor` turns the playback conditions into rule actions that join
the app rules' in `WallpaperPresentationPolicy`, so they pause, mute or stop
wallpapers exactly as an app rule does and never change the user's own Play/Pause.
It only observes notifications (`NSProcessInfoPowerStateDidChange`,
`ProcessInfo.thermalStateDidChangeNotification`, the preferences and the Focus
filter); nothing is polled. Web mute uses the same availability boundary as above.
Wallpaper and playlist selections instead reach `WallpaperAutomationScheduler`;
they never become pause/mute/stop actions or change the user's own Play/Pause. The
experimental [desktop Space mode](spaces.md) uses the same eligibility gate,
retains manual overrides for the current visit, and defers Focus exit while the
current desktop cannot be identified. Animated lock-screen ownership
conflicts with that mode; screen-saver-only ownership does not.

### App rules

**Edit…** opens an inline list. Each row is an app name, a condition (**Running**
or **In front**), an action (**Pause**, **Mute** or **Stop**) and **Remove**. **Add
app…** opens a native panel for one `.app` bundle. An app with no bundle identifier
is refused. The same bundle is not added twice. Rules pause, mute or stop
wallpapers while the chosen app matches. They do not change the user's own
Play/Pause. Web mute uses the same output channel and availability boundary as
above, without disabling its system-audio response.

## Advanced

Collapsed by default, with a **Renderers & experimental options** preview. Inside,
three flat sections separate **Video backend**, **Scene wallpapers** and
**Experimental**; scene renderer selection comes before the optimisation and
update-only-on-change switches. Each renderer section has a collapsed **Live
diagnostics** disclosure: video shows the backend in use; scenes show the renderer
and video path, whether optimisation is in force, and what is keeping the scene
updating. These reports continue to update from snapshots, and their open state
survives setting changes. **Renderer compatibility** remains beside the scene
diagnostics, and **What these settings change** stays last, outside Advanced.

## Video backend

| Setting | Values | Default |
| --- | --- | --- |
| Video playback | **Compatibility**, **Native video preferred** | Compatibility |

Native is a preference, not a guarantee: the engine selects a backend per running
wallpaper and keeps anything that does not qualify on Compatibility. **In use now**
lists the backend each running video wallpaper actually got, and names the
fallback reason when the user asked for native and did not get it. It reads `No
video wallpaper is running.` when nothing is playing video. An unrecognised backend
name is refused rather than silently mapped to Compatibility, so a stale page cannot
report a choice that was never applied.

Applying a video checks that its entry is a readable, nonempty file. Container and
codec support are decided by the playback backend: AVFoundation's native admission
check must not block a file the Compatibility backend can decode, including H.264
in Matroska. This applies both to **Apply** and **Apply changes**, with either
backend preference. Missing or empty files fail before display settings change;
decoder failures still go through the engine's apply recovery.

When the clip's audio output cannot start (no output device, or one that will not
start), AVFoundation fails the whole clip, muted or not, and reports only
`AVErrorUnknown`. Native playback then rebuilds the clip from its video track alone
and keeps playing it natively without sound, logging the original failure against
the wallpaper's load. A clip without audio, or one whose picture fails too, falls
back to Compatibility for the session. Native fallback reasons include each error's
domain and code, so a report shows which part of playback failed.

## Scene wallpapers

| Setting | Values | Default |
| --- | --- | --- |
| Scene renderer | Compatibility / Native Metal preferred | Compatibility |
| Scene render optimisation | Off / On | **On** |
| Update only when the scene changes | Off / On | Off |

### Scene renderer

Which renderer scene wallpapers prefer. **Compatibility** is the
Vulkan-through-MoltenVK path and the default. **Native Metal preferred** asks for
the native Metal backend; a scene it cannot draw runs on Compatibility as a whole
(an effect is never dropped to keep a scene native) and the status line says why.
Lock-screen playback always uses Compatibility. No GPU backend is created until
the scene has been parsed and a backend chosen, so the row reports one of three
states per scene: **preparing** (no backend yet), the backend actually in use, or
Compatibility with the reason native was not used. It never shows the preference in
place of the outcome.

Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and rope-trail
particles, perspective cameras for those layer types, ordinary effect chains and
scene post-processing, layers that read an image another layer produced earlier in
the same frame, images the runtime replaces while the scene plays, and BGRA or
8-bit NV12 video textures — the latter either converted once per frame or, with
**Direct video plane sampling** on, sampled by the layer's own shader. Lit
particles, 3D models, dynamic lighting, history-feedback effects, HDR or 10-bit
video, plain video wallpapers and shaders that do not translate fall back as a
whole scene. Compatibility additionally instantiates leaf `.mdl` model objects,
activates the scene's perspective camera, honours material `depthtest` /
`depthwrite` / `cullmode` on a depth attachment for the default target and keeps
authored `scene.lights`; Native Metal refuses those scenes as a whole until it grows
the same depth, perspective and lighting path. `input.cursorWorldPosition` stays 2D
(`z = 0`), so a scripted orbit drag may not match Wallpaper Engine.

Puppets and rope geometry behave the same on both renderers. A puppet is deformed
by its author's own skinning shader, and its pose comes from the one animation
system the scene already has (animation layers, their play, pause, stop, rate,
blend and visibility, and any script or user property driving them); the renderer
only uploads the resulting bone matrices. Rope and rope-trail geometry is generated
once by the shared particle simulation. The rope renderers' *UV scale* is not
implemented on either renderer, and a puppet model whose animation block the model
parser cannot read is drawn in its bind pose on both, with a log line when it
loads. A text layer is an ordinary layer: it takes its place in the layer order and
carries its transform, opacity, blend, effect chain, camera and the final
composition, appears in desktop posters, and uses the engine's one text system on
both renderers. Text whose content has not changed is not laid out, rasterised or
uploaded again; a script that produces it still runs on its own schedule every
frame. Effect and video output of Native Metal has not been compared against real
wallpapers.

Desktop posters work on both backends and need no setting: each re-draws its final
composition — fit, zoom and flip included — into an image of its own only when a
poster is requested, including while the scene is idle or paused. The
Compatibility drawable is therefore only ever rendered to, never read back.

Compiled work is reused across launches where it can be. A scene's translated Metal
shaders, their reflection and their binding plans are stored in that scene's shader
cache, including the optional direct-plane program, which is prepared in the
background. Alongside them, the render pipelines Metal built are kept in a binary
archive in the same directory and handed back to Metal the next time the same
pipeline is created, so each wallpaper has its own store even when two displays
show different ones. Each of these is a separate saving and none removes the
others: a stored shader means no translation ran, a stored pipeline means Metal did
not have to produce that pipeline's compiled form again, and the first use of a
program in a process still costs some compilation whatever is cached. An archive
that cannot be read, is from another machine, or is missing is not a failure — the
pipeline is compiled as before and the wallpaper loads. All of it is regenerable and
is removed by **Clear shader cache** in Storage; nothing you imported is stored
there.

Compatibility keeps no compiled Metal code of its own. MoltenVK's pipeline cache
(`vk-pipeline-cache.bin`, beside the same scene's shaders) stores the Metal source
MoltenVK generated, which saves translating it again but not compiling it; the
compiled forms come from macOS's own Metal shader cache. That cache survives
relaunching the app, rebuilding it, a new version number and a bundle replaced at
the same path, but it keeps compiled Metal source per app location: a second copy of
the app at another path — an installed copy beside a development build, say —
compiles each wallpaper's shaders again the first time that copy loads it, once.
Compiled pipelines are shared between copies. The native backend's binary archive
stores pipelines, so it covers the smaller part. Method and what recompiles:
[renderer testing](../testing/renderer.md#metal-compile-across-processes).

### Scene render optimisation

The only scene control that ships on. It reuses the result of scene subgraphs whose
inputs have not changed and removes render passes proven redundant, inside the scene
renderer's own render graph. It is not a quality tier: the same pixels are
produced, and resolution, frame rate and animation speed are untouched. It reaches
wallpapers the scene engine draws — scenes on either renderer, and video wallpapers
on Compatibility, which the engine draws as a one-texture scene; native video and
web wallpapers do not go through it. It is on the Performance page so it can be
turned off and on for an A/B comparison without an environment variable.

Unlike content pacing and shared video decode, which are read back from the
renderer, its row reports the saved preference: the renderer publishes no query for
it. The engine applies a change to a running scene in place, on that scene's next
frame in either direction — the copy plan, the targets it governs and the reuse
table are rebuilt over the graph that is already compiled, without reparsing the
project, reopening a video or resetting a timeline — so nothing restarts and no
wallpaper reloads. The **In force now** row beneath the switch reports what each
running scene is actually under, so a preference that has not reached a scene yet is
visible as such.

Reuse needs a target that is both cacheable and holding a pinned allocation,
because the render-target pool may otherwise hand that image to another key.
Pinning is bounded by a memory budget; when a graph's targets do not fit at the
current output size nothing is pinned, and the per-frame sampling and signature walk
that decide what to reuse are skipped outright, since their only reachable answer is
"draw everything". The budget itself is unchanged; a target that cannot be pinned
still redraws.

### Frames that would repeat the picture

With scene render optimisation on, a frame that would put back exactly the picture
already on screen is not drawn, submitted or presented, and the surface keeps
showing the last frame. Two cases qualify:

- a Compatibility video wallpaper whose playback clock selected the same decoded
  frame as the last present, which is most ticks of a 24 or 30 fps clip under a 60
  or 120 fps limit;
- a scene, on either renderer, whose every pass was reused from the previous frame,
  leaving only the final composition to redo.

The frame clock still ticks at the configured rate, and the scene still runs its
scripts, timeline, sound and events on every tick; only drawing an identical
picture is left out. A newly decoded video frame is presented on the tick that
selects it, so this is neither content pacing nor updating only when the scene
changes, and no drawable is held to keep the picture. A resize, fill, scaling or
flip change, a render-scale or scene-optimisation change, a rebuilt graph or
surface, a resumed wallpaper, a failed frame or a poster request makes the next
frame present. The renderer counters report these frames as
`presents_skipped_unchanged`, apart from dropped draws and present requests. Native
Metal takes a drawable only after the scene's passes are encoded, so a frame that
repeats the picture takes none.

### Update only when the scene changes

Off by default, because stopping a wallpaper's clock changes what the user sees
happen. When a scene can be shown to have nothing that advances on its own, its
frame clock stops entirely instead of ticking at the configured rate: the last
frame stays on screen and events restart it. This is not a frame-rate setting and it
lowers no quality. It is also not the same question as scene render optimisation,
which asks whether a render target's pixels can be reused; this asks whether the
whole runtime can sleep. A scene whose image happens to be still may still be
running scripts, sound and timelines, so both analyses must agree before anything
stops.

A scene keeps its clock if any of these is present: a script or scripted property,
an animation, a particle emitter, a playing video texture, an audio-reactive
shader, a time uniform, an animated sprite, geometry rebuilt every frame, a puppet,
a feedback pass, a text layer whose content is computed every tick, a sound layer,
a node transform or material constant driven by a script or an animation, text
whose new layout has not reached a frame yet, or any input the renderer could not
account for. That last one is reported as **an input the renderer could not account
for**, and it is the answer when a wallpaper does not go idle. The list turns on
what *is* changing rather than what *can* change: a text layer's card is rewritten
when the text is re-laid out, and a layer's visibility is a binding whether or not
anything ever moves it, neither of which means the scene has work to do. A static
caption, a caption the user's own property supplies, an image replaced only when a
resource arrives, and any of those under a supported effect chain all stop their
clocks; the same layer driven by a script does not.

Pointer-reactive scenes do sleep, and pointer movement wakes them. Property
changes, resizes, display reconfiguration, resource updates, poster requests and
visibility changes all wake the scene, as does a text layout finishing on its own
thread; a wallpaper the user paused is never woken by any of them. Writing a
caption the layer already has is not a change and wakes nothing, which keeps a
script that returns the same string from defeating the feature.

Waking is not a licence to draw. The configured frame rate is a ceiling on every
path into a frame, not only on the periodic one: a request, a one-shot appointment
and an appointment already past all wait until one frame period after the last
frame, so a burst of pointer samples coalesces into one frame per period. After a
quiet stretch longer than that period the first event draws immediately. Content
pacing can make the *cadence* longer than the ceiling and an event may cut that wait
short, but only as far as the ceiling. A request is never discarded to enforce any
of that: it stays outstanding until a draw consumes it, so a tick dropped because a
draw was still in flight loses the tick and not the update, and the end of that draw
re-arms the clock — one wake at that edge, not a retry per frame period.

Both renderers implement this. The status line reports what each running scene is
doing right now — updating continuously and why, waiting for events, paused by you,
suspended by the system, or that the state could not be read. A scene that is
running but cannot be read says so; it is never shown as updating normally.

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

The renderer does not rewrite anything at run time to achieve this. While the scene
is parsed, a material with exactly one video texture records everything a second
translation of the same author source would need; nothing is compiled then, and the
wallpaper loads and draws with its ordinary program first. Only if the switch is on
is the second program produced, on a background worker, and its Metal pipeline
built off the frame thread; the scene adopts it between frames when it is ready.
With the switch off nothing is prepared at all, and no shader is ever compiled
inside a frame either way.

**Drawn by** reports per scene what each running scene actually did: sampled
directly, converted once per frame, both for a scene whose materials differ, or
converted while the direct program is still being prepared (the wallpaper is playing
normally and a second program is on its way). A material whose shader the
translation cannot reproduce — an explicit level-of-detail sample, a size query, a
texel fetch, two video slots in one material — keeps converting and says nothing; so
does any frame that is not 8-bit NV12, which is what a software decoder produces for
the same file. Nothing here changes which renderer draws a scene.

**Where the two differ.** At a one-to-one mapping between video texels and output
pixels the two paths produce the same picture, to within the single code value the
converted intermediate's own 8-bit quantisation can introduce. Where the layer is
resampled they are not identical, for a structural reason: the converting path
clamps each texel to the range the stream declares and quantises it before the
layer's sampler filters, while the direct path filters first and clamps the result.
The transform between those two clamps is affine, so the two orders agree exactly
wherever the clamp does nothing — every sample a conforming stream carries. Where a
stream carries codes outside the range it declares they can differ by up to the
excursion that clamp removes, at most 24 code values for 8-bit limited range. This is
a real difference, not floating-point noise, and it is why the setting is opt-in.
No power measurement has been taken: what is claimed is only that a conversion is not
encoded and its destination is not allocated when nothing asks for one.

## Renderer memory

On Apple platforms, the Compatibility renderer grows its Vulkan allocator in 8 MiB
preferred blocks rather than the library's 256 MiB default. This reduces unused
reservations in unified memory; it is not a cap on wallpaper size, and larger
resources still allocate normally. The offscreen probe prints allocator reserved and
used bytes separately from process memory.

For scenes with an authored 2D canvas, both backends load packaged mip chains to
match the physical display: the longest texture edge is limited to the next power of
two at or above the display's longest edge, so a 3024×1964 display uses the authored
4K mip instead of an 8K source level. Larger levels are skipped before decoding and
GPU upload. Layout metadata, render-target resolution, frame rate and effects stay
unchanged, but source detail can differ, especially when zooming into an image.
Display-surface replacement rebuilds the textures for the new display size.
Perspective scenes without an authored canvas retain the source mip chain: a model
or skybox can magnify a small UV region, so display dimensions alone cannot
establish which source detail is safe to discard. The policy uses available
authored mips; a single-level image or an incomplete chain may remain above the
limit, and loose images, videos, sprite atlases, multi-slot images and unknown
encoded containers keep their original loading behavior. It is a texture-residency
reduction, not a fixed ceiling on total process memory.

An authored `hdr` scene selects the HDR path on either scene backend: overbright
color is preserved in half-float targets and bloom is HDR, while non-HDR scenes keep
the 8-bit path. Half-float targets cost eight rather than four bytes per pixel, and
the cache accounts for that actual size; a six-level bloom pyramid starting at
half-resolution holds under a third of a full-size target's pixels. This is real
post-processing work, not a free brightness adjustment or supersampling, and
increasing FPS alone cannot substitute for it: the High preset controls only frame
rate and render scale. Bloom spread is this renderer's own energy-conserving model;
exact Wallpaper Engine parameter parity is not established.

Native Metal allocates render targets only when the compiled graph writes or samples
them, plus the final output. Parser-provided shadow, mipmapped-frame and bloom
buffers are metadata until a pass needs them. References from hidden passes and
elided copies still count, so animation and live optimization toggles retain the
targets they can use, and the same filter applies when a toggle reallocates targets.
This applies to scenes drawn with **Native Metal preferred**; the Compatibility
backend already requests its targets from the cache as passes prepare them.

The lock-screen extension keeps its renderer paused while unlocked or asleep to
avoid a cold reload on wake; see [lock-screen memory tradeoff](lock-screen.md#how-the-surface-behaves).
The desktop renderer still needs the textures and render targets of the active
wallpaper. An idle control-panel benchmark cannot establish its playback memory
usage, and the extension must be measured separately from the app coalition. Its
Metal layer remains nonopaque so a missing drawable reveals the retained frame
below it; that gives up the layer's opaque-compositing guarantee, and the
WindowServer blending and energy cost has not been measured.

Closing the control panel releases its web view and allows its WebKit helpers to
exit, rather than keeping the whole page hidden. Reopening reloads the page; see
[panel lifecycle](control-panel.md#tabs).

## Repeated-work reduction

These renderer-internal optimizations do not change any setting, target frame rate,
render scale, animation speed or audio-response subscription:

- Per-frame uniform writes borrow their writer only for the synchronous update and
  match shader values to their uniform slots through a per-pass table built once;
  every value is still written every frame and no camera, bone, script or effect
  result is cached by this path.
- On Compatibility, a hidden layer's first-use clear is left out when nothing can
  see its target, the first draw into a composite just cleared to transparent opens
  with that clear, and a plain video wallpaper whose decoded frame is exactly the
  scene's size draws straight through the final composition instead of copying into
  a video-sized image. Each new video frame's colour conversion is queued ahead of
  the frame on the renderer's own GPU queue: one submission per new frame.
- A hidden particle layer keeps its simulation and rebuilds its mesh on the first
  frame it is shown again, or while something samples it.
- The audio-analysis queue advances a logical read position instead of moving its
  tail after every 1,600-frame window; every window is still processed, 30 a
  second. A video demuxer discards packets of streams it does not decode.
- Repeated system-media artwork skips redundant input conversion while still
  consuming every media-state message ([media integration](media-integration.md)).
- Bridge snapshot bursts reuse one shader-cache size measurement for up to two
  seconds instead of walking its directory for every property or playback update;
  explicit settings-snapshot requests and cache clearing force a fresh
  measurement. This affects storage statistics only.

The contracts and tests behind each item are in
[renderer verification](../testing/renderer.md#continuous-playback-work-contracts).
Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not displayed
FPS; a power claim still requires the matched conditions in
[power benchmarking](../testing/power-benchmark.md).

## Background work only while it has a consumer

These change no setting, frame rate, render scale or sound; they stop work that
nothing could see or hear.

- **Wallpaper sound output.** The Core Audio output a scene's sound layers or a
  video's own audio track play through starts only while something is mounted, the
  wallpaper is playing and it is not muted. A paused, muted or silent wallpaper, a
  wallpaper that arrives paused, and the lock-screen extension (always muted) start
  no output, so Core Audio runs no output cycle for them and holds no idle-sleep
  assertion on their behalf. Resuming or unmuting costs one device start.
- **System audio capture.** Runs only for a presenting wallpaper that actually reads
  the sound; see [audio response](audio-response.md). A wallpaper that reads audio
  still runs the tap, and no drop in coreaudiod cost is claimed for it.
- **Pointer sampling.** Scenes receive the cursor from a sampler that runs when
  macOS reports pointer motion or a button, when an interactive scene appears or
  resumes, or when its pointer delivery is reset, at most once per 16 ms, with a
  move after a quiet stretch delivered at once. A still pointer causes no wakes, and
  a scene that is paused or covered is not a consumer. While this app is frontmost,
  where macOS routes pointer events past the monitors, the sampler checks the cursor
  every 16 ms and does engine work only when it moved. No new permission is needed.
- **Frame clock.** A wallpaper's frame clock starts when its scene is loaded, not
  when the renderer is created, so a surface still parsing or whose load failed has
  no clock thread. A global resume applies each display's own pause in one step, so
  a display that is still covered is never briefly resumed. A pointer sample that
  cannot move the next tick does not wake the clock, and a burst of samples while it
  is idle coalesces into one frame; the configured frame rate stays the ceiling.
- **Video decode.** The decode thread is woken when a frame is actually ready, not
  on every tick that has nothing new, and per-tick counter bookkeeping runs only
  while renderer counters are on.
- **Discover previews.** Animation sources exist only for visible tiles in a visible
  document ([tile thumbnails](workshop-downloads.md#tile-thumbnails)).

The regression coverage for these is in
[renderer verification](../testing/renderer.md#regression-areas-that-must-stay-covered).
Those tests prove the work stopped; they are not power measurements, which still
need the matched conditions in [power benchmarking](../testing/power-benchmark.md).
