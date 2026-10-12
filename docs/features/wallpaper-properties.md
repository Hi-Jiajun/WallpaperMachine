# Wallpaper properties

What the inspector offers for one installed wallpaper beyond applying it: the live
preview window, the authored properties with their presets, image placement and the
compatibility check. Selecting and applying a wallpaper, and the inspector's overall
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
identifiers.

Authors use HTML labels as a layout surface. `WebUI/property-label.js` parses them
inertly and reconstructs a small presentation allowlist: headings, paragraphs, line
breaks, emphasis, font colors, centered content, dividers, links and images. Author
scripts, styles, embedded documents, form controls, event handlers and panel action
attributes are discarded. Plain labels remain available for accessibility and
native file pickers. An empty text property is omitted; a control without a
readable name uses **Unnamed option**, never the editor's markup-derived id.

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

Audio, scaling mode and frame rate take effect immediately. Everything else is
pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages. A dirty
or unsubmitted control shows a localized **Modified** flag outside its
author-provided label; Reset clears the flag once the property is clean.

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
When a check is unavailable and the wallpaper is a Workshop item, the card also
offers [Reinstall from Workshop…](workshop-downloads.md#reinstall-from-workshop).
