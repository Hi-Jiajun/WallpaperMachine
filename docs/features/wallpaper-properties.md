# Wallpaper properties

What the inspector offers for one installed wallpaper beyond applying it: the live
preview window, the authored properties with their presets, image placement, the
compatibility check and the black-bar check. Selecting and applying a wallpaper, and the inspector's overall
layout, are in [control panel](control-panel.md#selection-versus-apply).

## Live preview

An installed scene, video or Web wallpaper has **Preview wallpaper** in its
details. It opens one ordinary, resizable **Wallpaper Preview** window; choosing
another preview replaces that window's content. A preview never applies to a
display, changes the panel's selection, consumes a playback-history entry or saves
options. It reads the current property draft, including text still being edited,
and the target display's scaling options; **Reload preview** reads them again.

The wallpaper is shown on a stage with the proportions of the target display, so a
portrait, ultrawide or 4:3 display previews with the layout and crop it will get
instead of a 16:9 frame. The stage is the largest box of that shape inside the
black area above the controls; a window dragged to another shape keeps the
proportions and shows bars. A scene's drawable and a page's `innerWidth` and
`innerHeight` are the stage's, so a scene's crop and a page's layout follow the
display's proportions. A new window opens at a size that fits the stage on the main screen's
visible area (at most 1000 points wide and never narrower than the control row
needs, with a portrait stage getting bars beside it); a window that is already open
keeps its size when another preview replaces its content, and only the stage
changes. A display that is not attached, or whose shape cannot be read, previews at
16:9. Shapes are limited to between 1:4 and 4:1. The stage reproduces the
display's proportions, not its resolution: a page sees the stage's size in points.

The window has its own **Play/Pause**, sound toggle and reload control, and every
new preview, including reload, starts muted. Scene and video rendering is capped
at 30 FPS or the effective lower limit when its inputs are read. Web pages receive
that FPS through the standard wallpaper host protocol, and below 60 the host holds
the page's `requestAnimationFrame` callbacks to it
([frame-rate limit](web-wallpapers.md#frame-rate-limit)); timers, video and CSS
animation are not limited. Hiding, covering or minimizing
the window, locking the session or sleeping the displays suspends it, and resuming
visibility preserves an explicit user pause. Closing the window cancels pending
preparation, removes file watchers and releases its renderer or WebKit page. A
superseded load cannot replace the newer preview. Load failures stay in the window
with their reason and a reload action; first-frame or page readiness has a
30-second budget while visible.

Scene and video previews use a private Compatibility renderer attached to the
window, independently of the desktop's renderer preference, and scene hover,
buttons and dragging are scoped to that view. Web previews reuse the wallpaper
host protocol in a separate, nonpersistent website data store and support ordinary
in-window interaction; preview storage is discarded on close and is not the
desktop page's localStorage or signed-in session. File and directory properties
use the existing managed asset authorization and staging path
([user files](user-files.md)). Audio response and
system media information are unavailable in preview and the window says so;
page-initiated capture, dialogs, new windows and file pickers are declined; a Web
preview is refused if WebKit cannot establish whole-page mute; scene previews need
the shared scene resources, just as desktop scenes do. Per-wallpaper energy
ratings exclude the interval while a preview is open.

`WallpaperPreviewSession` owns the loading and playback lifecycle,
`WallpaperPreviewLoader` validates the installed paths, manifest and inputs, and
`WallpaperPreviewWindowController` exists only for an explicit preview action. The
bridge's read-only `wallpaper_preview` export keeps Web property scalar types and
never reconciles the desktop.

## Properties

The inspector's compact **General configuration** section holds mute, volume,
[Audio response](audio-response.md), and media integration. **Audio and media
status** expands to show their explanations and delivery status. **Displays**
follows with per-display playback configuration, open when the wallpaper is on a
display and collapsed otherwise, then **Collections**.
**Wallpaper properties** comes last, with the wallpaper's authored controls in their
original order, so a long property list never pushes the shorter sections out of
reach. General, display and property disclosures retain their state across
snapshot updates.

Property rows place the label on the left and the checkbox, slider/value, combo
menu or color swatch on the right; text and file editors use the full width below
the label. A reset icon appears on hover, keyboard focus, or a modified row and
restores that property's default. Checkboxes use the author's name directly.
Recognized Wallpaper Engine label tokens (brightness, position, default, and
similar built-in vocabulary) are localized rather than displayed as `ui_editor_…`
identifiers. A built-in token without such a phrase is shown as sentence-cased
English words, never as the identifier: the `ui_` prefix, the editor-area words
that begin it (`editor`, `properties`, `effect`, `context`, `menu` and similar) and
a trailing `title`, `label` or `text` are dropped, so `ui_editor_effect_opacity_title`
reads **Opacity**. The same applies to a combo choice. Only a label or choice that
is exactly such a token (surrounding space ignored, at most 96 characters) is
rewritten; author prose that merely mentions one is left alone, and the stored
label and the choice's value are unchanged. The words are English, and the panel
translates them whenever the same phrase is already a catalog entry.

A wallpaper may carry its own translations in `general.localization`: a table per
Wallpaper Engine language code (`en-us`, `zh-chs`, `zh-cht`, `ja-jp`) that maps
the `ui_…` tokens its labels and combo options use to text. A label or combo
option that is exactly one of those tokens (surrounding spaces ignored) shows the
text from the app's language, then from `en-us`, and otherwise stays as the author
wrote it, so a token missing from every table is left to the built-in vocabulary
above. Text that only mentions a token is never rewritten, and a translated value
passes through the same label sanitiser as any other label. Titles and
descriptions are not translated. The tables come from downloaded projects and are
bounded (64 languages, 4,096 tokens each, 2 KiB per text, 1 MiB overall); anything
beyond the bounds or not text is ignored without failing the wallpaper. The app
sends its language to the bridge at launch and whenever the language changes, and
the open inspector relabels at once without reloading the wallpaper or touching
pending edits.

Authors use HTML labels as a layout surface. `WebUI/property-label.js` parses them
inertly and reconstructs a small presentation allowlist: headings, paragraphs, line
breaks, emphasis, font colors, centered content, dividers, links and images. Author
scripts, styles, embedded documents, form controls, event handlers and panel action
attributes are discarded. Plain labels remain available for accessibility and
native file pickers. An empty text property is omitted; a control without a
readable name uses **Unnamed option**, never the editor's markup-derived id.

A `group` record is a section heading for the controls after it, so it is shown
as a bold, ruled heading (exposed to assistive technology as a level-3 heading)
rather than as muted description text. It takes the same sanitised label as any
other, is omitted when it has no words, and is not collapsible: Wallpaper Engine
groups only label what follows and own no rows of their own.

Author artwork is loaded only through registered `mwe-ui://property-image/`
routes. `PropertyImageCache` fetches HTTPS raster images natively from the
allowlisted image CDNs (`i.ibb.co`, `i.imgur.com`, the supported Steam image hosts
and QQ's photo-store hosts), rechecks redirects, and rejects credentials, custom
ports, unregistered routes, oversized images and non-raster content. PNG
transparency and GIF animation are preserved, and repeated dividers share a
bounded in-memory cache. At most four author-image transfers run across all hosts;
a URL's load is shared by its consumers and cancelled when the last one goes away.
Other image hosts are omitted (alt text is retained). Images remain author-hosted,
need network access on a cache miss and are not copied into the app bundle.
Supported author links use the native external-link policy, including Bilibili
profile/article pages, and open only when clicked; unsupported links keep their
text without a clickable action.

An authored visibility rule decides whether a property is listed, and the
bridge re-evaluates it after every draft edit. A rule may combine property
checks (`a.value`, `a.value == 3`, with `==`, `===`, `!=`, `!==`, `>`, `>=`, `<`
and `<=`) with `&&`, `||`, `!` and parentheses; use the constants `true` and
`false`; compare against numbers, booleans or text in either kind of quotes; and
test a list such as `[3, 4, 5].includes(a.value)`. A rule using anything else, or
longer, more deeply nested or more heavily listed than the parser's fixed bounds,
is unreadable and leaves its property visible rather than hiding a control the
author may have meant to show. Each library refresh writes one app-log line per
wallpaper naming how many of its rules could not be read. A property hidden by a
rule is only left out of the panel's list. The bridge still reports it, not
enabled and with its current value, so the value (or its authored default) still
feeds other rules and the renderer and a preset can still name it. These rules
only choose which rows the panel lists: a scene layer or effect whose visibility is
bound to a property follows its value whether or not a rule hides the row, and the
scene file alone says what a value switches on or off ([scene
rendering](scene-rendering.md)). The rules are evaluated when the panel's property
list is built, never per frame, and the scene resolves its bindings when it loads
and on a property change. A rule that is always false, such as a bare `false`,
hides its property for good, as Wallpaper Engine does.

Audio, scaling mode and frame rate take effect immediately. Everything else is
pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages. A dirty
or unsubmitted control shows a localized **Modified** flag outside its
author-provided label; Reset clears the flag once the property is clean.

**Restore all defaults**, a link above the controls beside the presets, stages
the authored default of every property at once instead of one reset icon at a
time. It is pending like any other edit: **Apply changes** keeps it and **Revert**
brings back every value and **Modified** flag. It also drops text not yet sent and
values behind a rule that currently hides their property, but not display
settings, audio or presets. A chosen file or folder is left alone, because it is
saved the moment it is picked; each keeps its own **Clear**. The link is disabled
while nothing but such files and folders differs from the defaults and no text is
waiting, and while the wallpaper cannot be rendered. A modified value behind a
rule that currently hides its property counts as a difference, since it still
reaches the wallpaper, so the link is enabled for it even though no row shows it.

A `scenetexture` property's image picker fills the material slot that names it, so
a wallpaper built around "choose your own picture" shows the picture. The choice
takes effect on **Apply changes**, which reloads the scene; the picker stores the
path, not a copy, so moving or deleting the file leaves that slot on the artwork
the author shipped. A picture outside the app's own storage is not readable from
the sandboxed lock-screen extension, which keeps the authored texture there.

### Property presets

**Wallpaper properties → Save current…** stores a named preset of the currently
applied authored properties; pending edits must first be applied or reverted.
Choose a preset and **Apply**, rename or delete it, or export/import its versioned
JSON document. Import saves a new preset and never applies it automatically. These
are wallpaper-specific property presets, not the Performance quality tiers.

Application validates every saved property against current types, limits and
choices before staging edits. Default markers follow the author's current default.
File and directory edits join the same draft transaction, and a failed application
restores draft and selection-permission state. Managed attachments are retained
independently of the current property under `UserAssets/PresetAssets`; deleting a
saved preset does not delete a directory still used by an applied wallpaper, and
ordinary cache cleaning leaves these retained originals alone.

Presets can switch a mode and set fields that mode enables. All values and
resources are validated first; enabled mode controls are edited before dependent
fields, and the bridge reevaluates authored conditions after each draft edit. If a
target field remains disabled, the draft is reverted without applying it.

A preset holds the properties the panel listed when it was saved; one a rule hid
then is left out, and applying the preset leaves it as it is. A preset may still
name a property that a rule hides when it is applied, because the wallpaper's
settings changed since or the preset came from an import: the property is set once
the preset's own edits to the properties that control it show it. A property the
wallpaper no longer defines, or whose type changed, is reported as unknown and
nothing is applied.

Portable documents embed up to 32 MB of managed attachments, within a 48 MB
document limit. Hidden files in retained directories (such as Finder metadata) are
excluded from portable exports. Preset names accept 1–120 characters. Arbitrary
external paths do not grant access on import: select external originals through
the property editor. Missing resources, incompatible author changes, malformed
documents and filesystem-aliasing filenames are errors, not partially applied
presets.

### Image placement

App-generated imported pictures and saved pixiv pages show **Position on screen**.
Drag the preview or use its keyboard/position controls and 100–300% zoom; each
target display keeps its own placement. **Reset to Image fit** restores the
Fit/Fill/top-aligned behavior. Original image bytes are unchanged, and changes
reach the running page through properties without resetting its document. An
app-generated page from an earlier template is upgraded once, and only if its
provenance, resources and exact unmodified template match; authored or modified
HTML is never rewritten.

### Compatibility check

An installed wallpaper's **Compatibility check** reads entry/shared resources and,
for video, asynchronously checks native admission for the selected display and
frame-rate constraints. Checks are explicit and version/configuration-bound.
Unknown scene shader/graph or Web runtime behavior remains **unknown**; readable
files and video metadata are not proof of a displayed frame. The same card shows
the actual running backend and fallback reason when the runtime reports them.
When the installed project or its entry file is unavailable and the wallpaper is
a Workshop item, the card also offers [Reinstall from Workshop…](workshop-downloads.md#reinstall-from-workshop).

### Black bars

An installed video's **Black bars** card looks for bars baked into the picture
itself, such as a 2.39:1 film inside a 16:9 file or a 4:3 clip inside 16:9.
**Look for black bars** is an explicit click: it decodes five frames at 10, 30, 50,
70 and 90% of the clip (frames that land on the same moment count once), measures
the bars in each and reports what most of them agree on. The check is read-only:
nothing is applied, rewritten or saved. Results are held in memory for the last
16 wallpapers checked and read as not checked again after a library refresh or a
restart; selecting another wallpaper cancels a check that is still running.

- **No black bars found**, or **Black bars found** with their size as a share of the
  picture on each side. Bars on both ends of one axis, or all four sides, are
  reported only when they are about the same size.
- With the target display in **Fill**, the card names the scale factor that crops
  the bars off that display. The factor depends on the display's proportions under
  the engine's Fill layout (a 21:9 display already crops the top and bottom of a
  16:9 video, so the card may say Fill already does it), is rounded up to two
  decimals and carries half a percent of overscan. In any other scaling mode the
  bars are reported and no factor is named. Setting the factor is the display's
  **Scale factor** field; the card changes nothing.
- **Uneven** bars (one side only, or lopsided) get no factor, because a centred
  zoom would also cut picture. Bars that add up to more than 45% of an axis are
  treated as unreliable and nothing is suggested.
- The card says it cannot tell when the sampled frames are too dark, disagree about
  where the bars are, or are too few after repeats are dropped. It says it cannot
  check when AVFoundation cannot read the file (WebM, Matroska and AVI are not
  readable there), the file has no video track, reading takes longer than 20
  seconds, or the file changed while it was being read.

Sampled evidence is not proof: a scene that keeps a black border through all five
samples looks like bars, burnt-in subtitles shorten a bar in the frames that carry
them, and the thresholds are this app's own, exercised on generated H.264 clips
and not on a corpus of real wallpapers. Anamorphic (non-square pixel) clips can be
a percent or two off, which the overscan covers. Mirror displays hold their own
scale factor and are not covered. Both video backends apply the scale factor with
the same Fill layout, so the named factor crops the same bars on either
([Video backend](performance.md#video-backend)).
