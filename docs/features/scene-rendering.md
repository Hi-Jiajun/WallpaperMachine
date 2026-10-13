# Scene rendering

How scene wallpapers are drawn and kept cheap: which renderer draws them, the
optimisation and update-only-on-change behaviour, and the renderer-internal memory
and repeated-work reductions. The settings that choose between them are on
**Settings → Performance → Advanced**, described in
[Performance](performance.md#advanced).

## Scene wallpapers

The three scene controls in **Advanced**:

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
[**Direct video plane sampling**](performance.md#direct-video-plane-sampling) on,
sampled by the layer's own shader. Lit particles, 3D models, dynamic lighting, history-feedback effects, HDR or 10-bit
video, plain video wallpapers and shaders that do not translate fall back as a
whole scene. Compatibility additionally instantiates leaf `.mdl` model objects,
activates the scene's perspective camera, honours material `depthtest` /
`depthwrite` / `cullmode` on a depth attachment for the default target and keeps
authored `scene.lights`; Native Metal refuses those scenes as a whole until it grows
the same depth, perspective and lighting path. Both renderers apply a material's
depth state the same way: a pass depth-tests only into a target with a depth
attachment (a scene with a perspective camera or models), and every other pass
draws in painter's order. A material writes depth as authored whatever its
blending, as Wallpaper Engine's own translucent depth-tested font materials expect,
so a translucent or additive layer that asks to write depth hides what is drawn
behind it afterwards, its transparent texels included; a pass that does not
depth-test writes none. `input.cursorWorldPosition` stays 2D
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
composition — fit, zoom, flip and position included — into an image of its own only
when a poster is requested, including while the scene is idle or paused. The
Compatibility drawable is therefore only ever rendered to, never read back.

Where the picture sits is one layout shared by both backends, the pointer mapping and
the posters. The scaling mode and the scale factor decide how large the picture is;
whatever room that leaves around it (bars for Fit, Original size or a factor below 1)
or whatever it overflows by (Fill, or a factor above 1) is split by a position, a
fraction per axis: 0 puts the picture's left or top edge on the display's, 1 its right
or bottom edge, and 0.5, the default, centres it as every wallpaper was before the
position existed. An axis with no room, such as Stretch at a factor of 1, does not
move. The engine takes the position as a live setting
(`owe_scene_wallpaper_set_framing`): nothing is rebuilt, a held video keeps its frame,
the next frame is presented once, and the position survives a surface rebuild and a
change of renderer. The Rust engine carries it with a scene's other settings
(`SceneFraming`, refused unless both fractions are between 0 and 1): it stays with the
same wallpaper across a rebuild, and a different wallpaper takes the position of its
own descriptor. The wallpaper config keeps it per display as `framing` (`pan_x` and
`pan_y`) in that display's `monitors` entry, beside the scaling mode and factor, and the
bridge hands it to the scene it builds for that display. The key is left out while the
display is centred, so an older build ignores it and a file nobody positioned is
unchanged. A hand-edited value never costs the file its other settings: a fraction
outside 0 to 1 is clamped, and anything that is not a number reads as the centre. A
mirror display is always centred, because it has its own display settings and a live
change to its source's position never reaches it. The native video player ignores the
position. The bridge moves a wallpaper on one display (`set_display_position`, an axis
passed as nothing keeps its saved value): it refuses a fraction outside 0 to 1 or not a
number instead of clamping it, saves the position at once and moves the scene that runs
on that display without rebuilding it. Like the scaling mode, and unlike the scale factor,
a position is not part of the options draft, so Apply does not wait for it, Cancel does
not undo it and Apply reopens no scene because of it. Saying the position it already has
writes nothing and tells the renderer nothing (unless a drag showed that scene at another
position first, see below), and a renderer that refuses the move leaves the position saved
for the next time the scene is built. While a slider is dragged the app calls
`preview_display_position` for the newest value: the running scene follows through
`SceneRuntime::preview_framing`, which moves the renderer but leaves the runtime, its
descriptor and the stored template as they were, so nothing is saved, no snapshot or
generation changes, the lock-screen export stays at the saved position and a drag that is
abandoned halfway leaves nothing for the next reconcile to rebuild. The bridge remembers
the scenes it previewed, so a release at the saved position still tells the scene that
position once; a display that is gone or that no engine scene draws is not an error. The bridge reports the
position to the app in each display's row of the wallpaper options (a moved display also
offers Restore defaults) and in the lock-screen and screen-saver export, which comes from
the saved configuration and so never holds a draft. The export carries it for a scene and
for a video the desktop plays natively; a web page and a mirror display are exported
centred. The inspector's Displays section offers it for scenes and videos
([display position](wallpaper-properties.md#display-position)). The lock-screen and
screen-saver extension draws a scene or video at the exported position
([lock screen](lock-screen.md#where-the-picture-sits)).

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
there. The archive is written in the app's temporary folder and moved into the cache
only once it is complete, so clearing the cache while a write is due costs that
write and nothing else.

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
web wallpapers do not go through it. It is on the
[Performance page](performance.md#advanced) so it can be turned off and on for an
A/B comparison without an environment variable.

Unlike [content pacing and shared video decode](performance.md#experimental-switches),
which are read back from the renderer, its row reports the saved preference: the renderer publishes no query for
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
selects it, so this is neither content pacing (an
[experimental switch](performance.md#experimental-switches)) nor updating only when
the scene changes, and no drawable is held to keep the picture. A resize, fill, scaling,
position or flip change, a render-scale or scene-optimisation change, a rebuilt graph or
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
suspended by the system, stopped after a rendering failure, or that the state could
not be read. A scene that is running but cannot be read says so; it is never shown as
updating normally.

### A scene that stops drawing

When a frame fails after the graph was built (an acquire or present that the
swapchain refuses, a submit that errors), or the render graph or its backend cannot be
built or released, the scene stops drawing and stays on its last picture. That used to
look like a pause from the outside, because the renderer's failure counter only
counts while a diagnostic session has counting switched on.

Each scene surface now carries a small health reading that is always on. It is a few
atomics written once per frame and read when asked; it starts no thread, timer or log
output, and it does not depend on renderer counting.

| Field | Meaning |
|---|---|
| `frames_completed` | Frames the render loop ran to the end, whether or not they reached the display |
| `frames_presented` | Frames that reached the surface |
| `failed_frames` | Frames lost to a failure in the draw itself; never reset |
| `last_present_age` | Time since the last present, or none before the first |
| stop | Not stopped, `FrameFailed` (the draw failed) or `GraphFailed` (the graph or backend could not be built or released) |

Liveness is `frames_completed` moving, never a present: with
[scene render optimisation](#frames-that-would-repeat-the-picture) a frame that would
repeat the picture completes without presenting, so a healthy, still scene stands
at the same `frames_presented` and a growing `last_present_age`. A reading built on
presents would call it stalled. Host-initiated stops, such as a surface being rebuilt
for a display change, are not failures and never set the stop. It clears when a
wallpaper is applied, a surface is installed or the graph rebuilds.

The reading is shown in two places, both as the mode `stopped_after_failure`:
**Settings → Performance → Live diagnostics → Updating now** says "stopped after a
rendering failure", and the `running scene:` lines of the
[diagnostics report](diagnostics.md#diagnostics-report) end with `mode …`. A pause the
user chose, or a display the app suspended, outranks it, and it shows again the moment
that is lifted; a reading the renderer could not take stays `unknown` and is never
reported as stopped or as running.

#### Recovery

A scene that had already shown a frame and then fails one calls the app back once (the
renderer's render-failure callback: no payload, never replayed on install). The app
then heals it with a small ladder inside a rolling minute. It is event-driven, and a
healthy scene costs nothing. The one exception is the look at a renderer that recovery
just rebuilt, described below, which lasts until that renderer has drawn.

| Attempt | Waits | Does |
|---|---|---|
| 1 | 0.5 s | Rebuilds the surface and swapchain in place; the compiled scene stays |
| 2 | 2 s | Opens a new renderer for the same wallpaper and closes the old one |
| 3 | 8 s | The same rebuild again |

An in-place rebuild that fails goes straight to the renderer rebuild instead of
waiting for the next rung. Attempts older than a minute stop counting, so a failure
after a quiet minute starts again at the first rung; a fourth failure inside one
minute gives up with one line in the log, "display N stopped drawing; recovery gave up
after 3 attempts in 60 s", and the scene stays stopped, shown as above, until
[Retry](#retry) or a different wallpaper loads on that display. A pause (the user's, or
a covered display's) is kept across every attempt, so recovery never plays what was
paused. The internal [render scale](performance.md#quality) is kept the same way: a
renderer the engine opens itself starts at full size, so the rebuild hands it the scale in force
before it draws, and a wallpaper turned down to 50% does not come back at four times the pixels.
An attempt that finds the surface drawing again, because a display change
rebuilt it in the meantime, does nothing. The wallpaper window shows its placeholder
for a moment while the surface is rebuilt, and the engine waits for the render thread
meanwhile, up to the 10 s swapchain acquire timeout in the worst case, as it does for a
display change.

A failure before the first frame is not retried: the app is still inside its first-frame
wait, which has its own timeout and rollback, and a retry of its own would race it. The
failure is still counted in the health reading.

A renderer that recovery itself rebuilt is a new renderer with no first frame yet, so
it too would call nobody back if its first frame failed, and the ladder would end there
with the scene stopped and no further rung tried. The engine therefore looks at a
rebuilt renderer itself, once a second, until it has presented a frame. The attempt stays
under way meanwhile, so a stall check or a second failure starts nothing beside it. A
renderer that stopped before it drew counts as the failure it is: the next rung is
scheduled, or, after the third, the scene gives up with the usual line. A renderer that
neither draws nor stops within 30 seconds is reported in the log and left as it is,
because a scene with a great deal to load is not a failure and rebuilding it again would
only interrupt the load.

A caller that knows something the renderer does not can ask the engine for the next
rung directly with `WallpaperEngine::recover_surface`. It spends the same budget the
failures do, so a liveness check cannot buy back a spent one within the minute;
[Retry](#retry) gets a fresh budget by loading the wallpaper afresh, which opens a new
renderer. The
[check after the Mac wakes](performance.md#playback) is such a caller: it finds a scene
that stopped itself, or one still counted as running whose `frames_completed` stood
still for three seconds, and asks for a repair as `Stalled`. That covers a scene the
failure callback never reported (one that failed before its first frame) and a surface
that stopped drawing without any failed frame. A scene whose minute of attempts is already spent
stays stopped, the check says so in the log, and **Retry** is still the way back.

Each step is logged under the load it belongs to: "display N stopped drawing after a
failed frame; trying a surface reconfigure in 500ms (attempt 1/3)", then "display N
renderer recovered by a surface reconfigure (attempt 1/3)" or the error. A rebuild gives
the scene a new load number and the budget carries over to it; it is logged as "renderer
rebuilt (attempt 2/3); waiting for it to draw", and then either "renderer recovered by a
renderer rebuild (attempt 2/3)" once it has presented a frame, or "renderer rebuilt
(attempt 2/3) stopped before it drew" followed by the next rung.

A real MoltenVK or Metal presentation failure has not been reproduced on a desktop. The
tests inject the failure into the renderer's own failure routine and exercise everything
after it there, the ladder with injected instants, and the relay that carries the report
to the engine. The engine's reaction to a report on a live scene needs a real window and
is not covered by an automated test, so whether a genuine failure is healed by the first
rung or needs a rebuild is unverified.

#### Retry

A scene that reads stopped has a **Retry** button on its row in **Settings → Performance
→ Live diagnostics → Updating now**. That covers a scene recovery gave up on and one
that failed before its first frame, which recovery leaves alone. Retry takes the
wallpaper off that display and applies it again, so a new renderer opens with a fresh
recovery budget. Applying the wallpaper again from the Library (double-clicking its tile
or choosing it in Recently used) cannot do this: a wallpaper a display already shows is
left as it is, and so is its stopped scene. The inspector's **Reapply wallpaper** takes
the wallpaper off the display and loads it afresh, so it restarts a stopped scene too
([control panel](control-panel.md#selection-versus-apply)); Retry does the same from the
row that reports the fault, and unlike Reapply it does not count as the user choosing the
wallpaper.

- Only the display on the row reloads. Another display showing the same wallpaper is
  not touched, and the wallpaper's files are not counted as changed, which only a
  Workshop update does. The exception is a display that mirrors another: it presents a
  scene of its own but has no wallpaper of its own to take off, so its Retry reloads the
  display it mirrors, which opens a new scene on that display and on the mirror.
- It is queued in that display's slot, like a switch. It waits for the command that is
  running, a newer choice on the display replaces a retry that is still waiting, and a
  retry that waited behind a switch finds another wallpaper on the display and does
  nothing. While it runs the button is disabled, like every control that waits on that
  queue.
- Nothing retries by itself. A scene that stops again reads stopped again, with the
  recovery ladder above starting afresh, until Retry is pressed once more.
- If the reload fails, the error shows as for any apply and the display has no
  wallpaper, because it was taken off first, rather than a frozen picture.

The button appears for the stopped reading only: a pause, a suspension and a scene
still starting are not faults to retry. The tests drive the page, the dispatcher and
the store against a stand-in engine; the button's placement, a reload of a genuinely
stopped scene on a real display, and whether reloading a display's source opens a new
scene on its mirror have not been checked on a desktop.

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
rate and render scale ([Quality](performance.md#quality)). Bloom spread is this
renderer's own energy-conserving model; exact Wallpaper Engine parameter parity is
not established.

On both backends, a layer hidden by its authored visibility or by one of the
wallpaper's own properties, itself or through a parent, is left out of the render
graph. Changing a property reloads the scene, so until then only a script can show
it. Customizable wallpapers ship every theme, language and date format as a layer,
and those hidden layers no longer hold effect images, load textures or clear
targets every frame. When a script shows one, a graph that draws it is built
before that frame is drawn; this happens once per layer, because a layer whose
visibility a script has written stays in the graph from then on. A hidden layer
another layer samples keeps drawing into its composite.

Native Metal allocates render targets only when the compiled graph writes or samples
them, plus the final output. Parser-provided shadow, mipmapped-frame and bloom
buffers are metadata until a pass needs them. References from hidden passes left in
the graph (a script decides their visibility) and elided copies still count, so
animation and live optimization toggles retain the targets they can use, and the
same filter applies when a toggle reallocates targets.
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

The app records macOS memory-pressure events together with its process footprint and
the scenes it is presenting ([diagnostics](diagnostics.md#memory-pressure)). It does
not unload, pause or stop a wallpaper on them: the footprint is for the whole process,
so a scene cannot be singled out, and no threshold has been measured.

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
[renderer verification](../testing/runtime-regressions.md#continuous-playback-work-contracts).
Fewer allocations, queue moves or conversions are workload evidence, not a
measurement of watts. Draw-call CPU timing excludes simulation and is not displayed
FPS; a power claim still requires the matched conditions in
[power benchmarking](../testing/power-benchmark.md).
