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
| Scene renderer | Compatibility / Native Metal preferred | Native Metal preferred |
| Scene render optimisation | Off / On | **On** |
| Update only when the scene changes | Off / On | Off |

### Scene renderer

Which renderer scene wallpapers prefer. **Native Metal preferred**, the default,
asks for the native Metal backend; a scene it cannot draw runs on Compatibility as a
whole (an effect is never dropped to keep a scene native) and the status line says
why. **Compatibility** is the Vulkan-through-MoltenVK path for every scene.
Lock-screen playback always uses Compatibility.

Native Metal became the default once it drew every scene of the local test library
the way Compatibility does (drawn by both renderers in one harness, the pictures
were the same) and cost less to run. Over 12 of those scenes at 3840×2160 and 60
FPS it took about 21% less process CPU time and 14% less GPU time in its own command
buffers (one per frame instead of three), about 3% less memory footprint, and held
60 FPS where Compatibility dropped frames; the commands are in the
[verification log](../testing/verification-log.md). A configuration saved before
then holds `compatibility` whether or not anyone chose it, so it moves to Native
Metal preferred once, when this version first loads it, and records that it did
(`native_metal_default_applied`); choosing Compatibility afterwards is kept.

No GPU backend is created until the scene has been parsed and a backend chosen, so
the row reports one of three states per scene: **preparing** (no backend yet), the
backend actually in use, or Compatibility with the reason native was not used. It
never shows the preference in place of the outcome.

Native Metal draws image layers, text layers, sprite-sheet animation,
two-dimensional puppets, two-dimensional sprite, sprite-trail, rope and rope-trail
particles, 3D models and skyboxes, perspective cameras, scene lights, ordinary
effect chains and scene post-processing, layers that read an image another layer
produced in the same frame, effects that read the previous frame (a motion-blur
trail, a fluid or ripple simulation), images the runtime replaces while the scene
plays, and BGRA or 8-bit NV12 video textures — the latter either converted once per
frame or, with
[**Direct video plane sampling**](performance.md#direct-video-plane-sampling) on,
sampled by the layer's own shader. A scene falls back as a whole for HDR or 10-bit
video, a plain video wallpaper, a shader that does not translate, particle geometry
in a layout it does not recognise (lit particles among them), a multisampled target,
an effect that samples a depth buffer, or a layer that reads its own previous frame (its `_b` composite, bound anywhere but its
own effects).
A scene with `camerashake` on shakes its camera as Wallpaper Engine does: the eye and
what it looks at move together by `(cos t, sin 1.333t, sin t)` at
`t = camerashakespeed² × time`, its length raised to `camerashakeroughness³`, scaled
by a tenth of `camerashakeamplitude` (and in a 2D scene by a tenth of the canvas
height, in the canvas plane only). The switch and every setting follow their user
properties, and a shaking scene keeps drawing while it shakes.
`input.cursorWorldPosition` stays 2D (`z = 0`), so a scripted orbit drag may not
match Wallpaper Engine.

A scene follows the cursor anywhere on its display, but, as in Wallpaper Engine, a
mouse press counts only where it lands on the desktop: the wallpaper, Finder's icons or
a desktop widget. A click in another app's window, in the menu bar or the Dock, or in
this app's own windows is not a click on the wallpaper, so neither scripts
(`cursorDown`, `cursorClick`, `cursorUp`) nor effects that react to a held button
(cursor ripples, fluid simulations) see it, or its release, even when the pointer is
dragged onto the desktop before the button is let go. A press the wallpaper did get is
always released, wherever the pointer ends up.

An effect that composes its layer over the screen (refraction among them) reads
that screen the right way up on both renderers. The shader compiler defines `HLSL`
and `HLSL_SM40` as Wallpaper Engine does, so the Direct3D branches of an effect's own
shaders are the ones compiled: the flipped screen coordinate of the compositing
pass, a brace-listed sample kernel, and a light falloff that stays defined beyond a
light's radius.

Scene lighting works as in Wallpaper Engine, on both renderers. A lit shader
(`genericimage4`, `generic4`, the particle, rope, foliage and fluid shaders) asks for
`#require LightingV1`; the shader compiler writes in a `PerformLighting_V1` with one
uniform array per light kind, sized by the scene's `general.lightconfig`, and calls
the author's own `ComputePBRLightShadow` for every light. Point (`lpoint`), spot
(`lspot`), tube (`ltube`) and directional (`ldirectional`) lights fill those arrays
every frame: colour times intensity with the radius, the world position with the
exponent, a spot's cone cosines and the light's own x axis as the way a spot or
directional light points, a tube's far end its control point carried by the light's
transform. The older `point` light still fills the four packed legacy lights
(`g_LightsPosition`, `g_LightsColorPremultiplied`). A light is a node like any layer:
it follows its parent, and its visibility, transform, colour, intensity, radius and
exponent follow user properties, scripts and timelines; a hidden light, or one under
a hidden layer, lights nothing. Each kind lights at most as many lights as the config
names, the first ones in scene order. A lit pass reuses its last image only while
the lights it reads are unchanged. `g_NormalModelMatrix` is each draw's own rotation
and `g_LightSkylightColor` the scene's skylight; `g_Texture<N>Texel` is the step of
the texture a slot samples, as for Wallpaper Engine's morph-target and downsample
shaders. Distance and height fog
(`fogdistance`, `fogheight` with their start, end, densities and colours, Wallpaper
Engine's defaults where they are left out) are compiled into every pass whose `FOG`
combo is on, the material's own or its shader's default, and applied by the
author's `common_fog.h`. Shadow maps, spot cookies and
volumetric light shafts are not drawn: a light that casts a shadow lights as if
nothing did, which is also what Wallpaper Engine shows when nothing in the scene
casts one. Both renderers apply a material's depth state and cull mode the same way: a
pass into a depth-attached target (a model, a skybox, a scene with a perspective
camera) takes its material's depth test, depth write and cull mode, against the same
front faces, and every other pass draws in painter's order and culls nothing. A pass
reads these words as Wallpaper Engine does: only `enabled` turns on a depth test or a
depth write and only `nocull` turns culling off, so any other value (`less`,
`inverted`) means no depth test, no depth write or back faces culled; there is no
depth compare to choose. A material writes depth as authored whatever its blending,
as Wallpaper Engine's own translucent depth-tested font materials expect, so a
translucent or additive layer that asks to write depth hides what is drawn behind it
afterwards, its transparent texels included; a pass that does not depth-test writes
none. A target the frame
reads before it writes it keeps its own image from one frame to the next on both
renderers, so the reader sees exactly the previous frame; a scene with such a loop
is never called still while it runs. An effect's own buffers are made the way
Wallpaper Engine makes them: a float format (`r16f`, `rg1616f`) is a float target,
so a fluid simulation's velocity and pressure keep their sign; an explicit 8-bit
format stays 8-bit and the back-buffer formats follow the scene; a buffer with its
own `width`/`height` or a `fit` has that size, its longer side shrunk to the `fit`
with its aspect kept, before `scale`. An effect's `swap` command exchanges two
buffers where it stands among the effect's passes, so a simulation carries its state from one frame to the
next; when the effect draws into the second buffer before reading it again, one copy
into the first is the whole exchange, otherwise it goes through a temporary buffer.
A buffer's `clear` colour and `conditions` are not read: buffers start cleared to
zero and are made whether or not the effect's combos use them. A layer's colour blend
mode mixes it with the screen behind it through Wallpaper Engine's passthrough
material, the layer's last step; the passthrough takes the layer as its first pass
drew it, colour and alpha included, and does not apply them again. Mode 31 ("add")
has no passthrough: the layer, or its last effect, is drawn with additive blending
straight onto the scene, so it costs neither the extra pass nor a copy of the screen. Translating to the
Metal shading language
turns GLSL's `inverse`, which Metal has no built-in for, into helper functions, so
the stock perspective, reflection, water, light-shaft and cursor-ripple effects
translate. A step that samples an image nothing in the scene produces (a layer
texture whose layer draws no composite) is skipped on Native Metal exactly as
Compatibility skips it, instead of sending the scene to Compatibility; an image that
exists and does not load still does.

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

Text is set the way Wallpaper Engine 2.8.42 sets it. `pointsize` is a size in
points at 300 dpi, 4.17 pixels to the point, clamped to 1 through 256 and handed to
FreeType as it is, which rounds the em to whole pixels only for the fonts that ask;
a glyph's advance is its unhinted advance, kerned against the next glyph of the
same face from the font's `kern` table and cut to whole pixels (Wallpaper Engine's
shaper also reads OpenType kerning, ligatures and complex scripts, which this does
not); the line pitch is the font's line height plus the layer's `spacing` y, its x
adds to every glyph's advance, and a row is as wide as its ink and the pen at each
glyph start (the advance after the last glyph is not part of it). Five cards that
Wallpaper Engine saved for text in Arial in the local scenes (with and without
padding, a lone full stop, a run of dashes, a long run of underscores) come out to
the pixel; other fonts, scripts and the OpenType-only kerning of many fonts have not
been compared. The card is the text plus `padding` on each axis, and the margin is
there only for a layer that draws through effect passes, a colour blend, an LED
source or an opaque background, or in a scene that enables distance fog or height
fog (`fogdistance`, `fogheight`): a plain text layer has none, whatever its `padding`
says. `padding` and `spacing` are two numbers, and `padding` is 32 on both axes where
the scene leaves it out, each lane capped at 512 and not floored (a negative padding
takes the card in around the text). A scene's authored `size` is not what sets the
card as it is in Wallpaper Engine, which ignores it and sizes the card from the
layout; here it stays the layout box and the smallest the card is (see the known
limitations). `maxwidth` is the width a row may fill, as authored: padding is never
taken from it, so a padded card can be wider than `maxwidth`. A row wraps before a
glyph whose ink would end past that width, once it holds a glyph: at the last space
or tab before it, where everything before that space stays in the row (a second space
too) and the next row starts at the glyph, or at the glyph itself when the row has
none to break at. A space never starts a wrap. The last row the row limit allows does
not wrap: it is cut before the glyph that did not fit, inside a word if that is where
it falls, and an ellipsis, where asked for, replaces its end by dropping glyphs one at
a time until the marker fits. A line break with nothing after it ends the text
without a row of its own and without an ellipsis. With
`blockalign` on, a row that ended at a wrap, with another row after it, is stretched
to exactly the width by spreading the slack over its spaces and tabs; the last row of
a paragraph, a row a line break ended, a row the row limit cut and a row with no
space are left alone. A text layer's colour blend mode works as an image layer's
does, through the passthrough pass or, for mode 31, additively onto the scene.
A text object that leaves keys out has Wallpaper Engine's defaults: 32 points,
`maxwidth` 500 and `maxrows` 1.

An image layer's own render targets, the pair its effects run through and the
composite another layer reads, are point-sampled when the layer says
`nointerpolation` or its primary texture's header does (read from the texture's
file, not from what an earlier layer happened to load), wrapped when the layer says
`clampuvs` is off, and clamped and linear otherwise. A texture file whose header asks
for point sampling is also sampled with its mip level picked by point, as the
reference's sampler for that flag does; a texture without the flag, and a render
target, keep the blend of mip levels they always had. A project layer
(`models/util/projectlayer.json`) is as large as the scene's canvas, and the
depth-testing composition layer composes like the plain one. A `shape` object, the
quad the editor's light-shaft effect is drawn on, is a quad as tall as the canvas on
both axes, or the one `point0` to `point3` of its first effect make; it has no
texture, and its last effect, with `DIRECTDRAW` forced on, is drawn additively
straight onto the scene as the layer's own geometry, so it keeps a layer's transform,
parents, visibility and scripts. An effect of more than one pass is left out.

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

### Live property edits

The renderer can take a whole property document on a running scene instead of
loading the scene again. The document is the project's declared defaults with
exactly the given values over them, so a property it leaves out is back at the
declared default whatever the scene loaded with. It adds no per-frame work.

Nearly every property is a live binding and follows on the next tick: layer
visibility, alpha, colour, origin, scale and angles, camera, clear colour, bloom
strength, threshold and tint, parallax delay, the scene zoom, camera shake,
shader constants, rope and particle values, text, puppets, and the values a
script reads and reacts to. A few readers decide once, while the scene loads, and
are **load-only**: a material slot that a `scenetexture` property picks, an
effect an on/off or combo property builds or leaves out (every hidden effect
would otherwise cost passes and memory), and the scene's bloom switch and its
parallax switch, amount and cursor influence, which decide whether the bloom
passes exist and which passes follow the cursor. A scene setting bound to a
property loads with the property's current value, saved choices included. A preview of a document holds a
load-only property at the value the scene read, for every layer that uses it, and
reports it as deferred; only loading the scene applies it. A sound layer's volume
is live too: a slider bound to it sets the stream's volume when the slider moves,
and nothing else does, so a volume a script set stays until its own slider moves.

A running scene takes the document through the wallpaper property
`project_property_preview_json`, one flat JSON object holding the whole state. The
main looper parses it (anything that is not a JSON object is logged and changes
nothing) and stages it in a latest-wins slot; the render thread, the only thread that
ticks the runtime, shows it with `PreviewProjectPropertyOverride`. A burst of
documents therefore costs one update: while the render thread is busy only the
newest is kept, and one command is queued behind the one it waits for. Like every
command except the draw, it asks for a frame, so an idle scene draws one and a
paused one shows the change when it resumes; it registers no time-advancing work, so
the idle analysis is unchanged. A layer the document reveals that the render graph
left out is shown by that frame's tick, which asks for one new graph before the frame
is drawn, as a script showing the layer does (new pipelines may compile, so that
frame can take longer); a layer it hides again keeps its passes until the next graph
is built, which leaves it out once more.

A preview is transient. It never reaches the saved override, so a scene that is
loaded again for any reason (Apply, a display change, waking, a wallpaper switch)
shows the saved look, and nothing is replayed to the scene that replaces it: a
document is for the scene running when it is shown, and a document that arrives
before the first scene exists is dropped. The lock-screen and Mission Control
pictures are not involved. Properties held at their loaded value are logged once,
as a set, when it changes.

The Rust engine sends the document with `WallpaperEngine::preview_property_override`,
the property counterpart of the framing drag preview. It parses and flattens the
document with the code `set_property_override` uses, so a document that is not a JSON
object, has an array leaf or is not JSON is refused before the actor is asked and never
reaches the renderer, and it then sets the preview property through
`SceneRuntime::preview_property_override_json`. Unlike `set_property_override` it asks
for no shader refresh and loads nothing, and it records nothing in the runtime: the
runtime's saved override, its descriptor, the stored scene template and the published
snapshot stay as they were, so the next reconcile still compares the saved configuration,
an edit that is abandoned leaves nothing to rebuild, and a rebuilt renderer shows the saved
look. `set_property_override` and `reset_property_override` keep their meaning, a reload that
remembers (or forgets) the override.

The call names the project file of the wallpaper the document was made for, and returns
`PropertyPreview::Shown` or `PropertyPreview::OtherWallpaper`. A handle names a display's
scene, not a wallpaper: a reconcile that is still under way (an Apply, a playlist or schedule
switch, a mirror change) replaces the renderer inside the same `SceneRuntime`, keeps the
handle, and commits the bridge's configuration only after it finishes, so for that long the
bridge can still find the first wallpaper's handle on a display that already runs the second.
The engine handles the call after that reconcile, not before, so it compares the scene's
`scene_path` then (`preview_on_scene_of`) and leaves a scene that draws another wallpaper
alone. This is what keeps the invariant above: the document of one wallpaper cannot reach
another by sharing property names, however the bridge's picture of the displays lags.

The engine also keeps what each scene was last shown. `OweScene` records the document it
took from a preview and drops the record when the scene is loaded again through
`set_property_override` or `reset_property_override`; a replaced renderer is a new object and
starts without one. Nothing else needs to remember to forget it, so every path that rebuilds a
scene is covered (a descriptor change, a shader cache clear, the wake check's repair, the
engine's own recovery of a failed frame), including the ones the bridge never sees. A scene
that already shows the document is not sent it again, and a refused update leaves no record,
so asking again sends it.

The bridge sends it with `preview_wallpaper_properties(wallpaper_id, show, pending)`. The
document is built from the whole draft, so a property the draft restored is back at its authored
default, by the function that builds a scene descriptor's document: it is byte for byte
what Apply would load, except that a texture, a file and a folder stay at their saved
value (a texture is read only while a scene loads, and a file or folder is saved the
moment it is picked). It goes to every scene that draws the wallpaper, mirrors included
(they run a scene of their own), and to nothing for a video, a web page or a wallpaper
no display shows. It saves nothing and leaves the draft alone, and it advances no
generation and builds no snapshot, so a reconcile that is already under way is not made
stale; the lock-screen export follows the saved configuration, and the app keeps the
Mission Control picture at the saved look by not taking it from a display that may be showing
an edit and by taking it again when the edit ends
([desktop picture](desktop-picture.md#when-a-poster-is-taken)). A wallpaper that is not being
previewed and whose saved look is asked for sends the engine nothing, and a scene that already
shows the document is not told again, which the engine decides, not the bridge: the bridge
keeps no copy of what a scene shows, because anything that loads a scene again would leave the
copy wrong, and most of those never pass through the bridge. It keeps only which wallpapers it
showed an edit on (`previewed_properties`) so that **Revert** (`cancel_wallpaper_options`) puts
the saved look back on those scenes before the draft is cancelled, and asks again if the engine
refused: a refusal leaves the draft dirty. `show` false does the same restore without
cancelling anything. **Apply** forgets the mark, because it loads the scene again from the
saved configuration. A scene the engine declines because it now draws another wallpaper is
skipped, not an error: there is nothing of this wallpaper on it to show or to put back, and
when no scene is left the mark goes too. Anything that loads a scene again (a display change,
waking, a shader cache clear, a recovery) shows the saved look, and the next edit shows the
draft again, even one that leaves the document as it was.

`pending` holds the values of sliders and colours the person is still dragging. Each is
checked by the function `edit_property` uses and made to a copy of the draft, in order,
for the document of that call alone (`WallpaperOptionsDraft::with_edits`), so the scenes
follow the drag while the draft, the dirty state and the saved options never hear of it,
and a call that does not name the value shows the draft again. One the property does not
accept refuses the whole call before any scene is told anything. `wallpaper_preview`
takes the same list for the preview window's export.

The app asks for it from `BridgeStore` after each property edit while [the Settings
switch](wallpaper-properties.md#showing-edits-on-the-desktop) is on; the preview window
has its own scene and follows the draft whatever that switch says.

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

An authored `hdr` scene with its bloom on selects the HDR path on either scene
backend, as in Wallpaper Engine: overbright color is preserved in half-float targets
and bloom is HDR, while other scenes, an `hdr` scene with bloom off included, keep the
8-bit path. A scene that leaves `bloom` out has it on, at strength 2 above 0.65, as
Wallpaper Engine has it. Half-float targets cost eight rather than four bytes per
pixel, and the cache accounts for that actual size; an eight-level bloom pyramid
starting at half-resolution holds under a third of a full-size target's pixels. This
is real post-processing work, not a free brightness adjustment or supersampling, and
increasing FPS alone cannot substitute for it: the High preset controls only frame
rate and render scale ([Quality](performance.md#quality)). The HDR bloom's levels,
sampling and weights are Wallpaper Engine's ([scene
regressions](../testing/scene-regressions.md)).

On both backends, a layer hidden by its authored visibility or by one of the
wallpaper's own properties, itself or through a parent, is left out of the render
graph. Applying a property change reloads the scene, so until then only a script,
or a property edit shown on the running scene ([live property
edits](#live-property-edits)), can show it. Customizable wallpapers ship every
theme, language and date format as a layer, and those hidden layers no longer hold
effect images, load textures or clear targets every frame. When a script shows one,
a graph that draws it is built before that frame is drawn; this happens once per
layer, because a layer whose visibility a script has written stays in the graph from
then on. A previewed property shows it the same way, but a preview owns nothing: a
layer it hides again keeps its passes only until the next graph is built, and
showing it afterwards asks for one more graph. The graph can therefore hold the
layers a preview showed since it was last built, never more than the wallpaper
ships, and is back to what a fresh load with the current values holds the next
time one is built. A hidden layer another layer samples keeps drawing into its
composite.

Native Metal allocates render targets only when the compiled graph writes or samples
them, plus the final output. Parser-provided shadow, mipmapped-frame and bloom
buffers are metadata until a pass needs them. References from hidden passes left in
the graph (a script decides their visibility) and elided copies still count, so
animation and live optimization toggles retain the targets they can use, and the
same filter applies when a toggle reallocates targets.
This applies to scenes drawn with **Native Metal preferred**; the Compatibility
backend already requests its targets from the cache as passes prepare them.

Native Metal also lets targets that are never alive at the same time share one
image, as Compatibility's cache pools them. A target qualifies when its first touch
in every frame is a clear that really happens, nothing copies into or out of it,
and it is not carried into the next frame, pinned for reuse, mip-mapped,
depth-attached or the scene output; targets of one shape whose spans of passes do
not overlap then take turns on an image. Copies of the picture so far that a layer
reads (a lens, a blend mode over the screen) are traded rather than blitted, and the
traded copies of one source share a small set of images: each copy takes one when it
runs and gives it back once its last reader has drawn, so a scene with forty such
copies keeps two or three images instead of forty-one, with no extra blit. A scene
that draws over the whole screen many times holds about a quarter of the target
memory it did. `WALLPAPER_MACHINE_METAL_TARGET_SHARING=0` gives every target its own
image again, for comparison or to read each target's own pixels after a frame.

The lock-screen extension keeps its renderer paused while unlocked or asleep to
avoid a cold reload on wake; see [lock-screen memory tradeoff](lock-screen.md#how-the-surface-behaves).
The desktop renderer still needs the textures and render targets of the active
wallpaper. An idle control-panel benchmark cannot establish its playback memory
usage, and the extension must be measured separately from the app coalition. Its
Metal layer remains nonopaque so a missing drawable reveals the retained frame
below it; that gives up the layer's opaque-compositing guarantee, and the
WindowServer blending and energy cost has not been measured.

Closing the control panel releases its window's controller and everything the panel
held, rather than keeping a hidden panel alive, and a hidden or minimized panel does no
work of its own. Reopening builds a fresh panel over the same stores; see
[panel lifecycle](control-panel.md#pages-and-settings).

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
