# Web wallpapers

Wallpaper Engine projects with `"type": "web"` are HTML pages (`"file"` names the
entry page, usually `index.html`) that talk to their host through
`window.wallpaperPropertyListener`. WallpaperMachine renders them in a
`WKWebView` hosted by the app; the vendored scene renderer never opens a window
for them.

## What the user sees

- [Live preview](control-panel.md#live-preview) runs an installed project in its
  own window and temporary website data store, with independent playback and
  default mute. It never replaces the desktop page or its stored state.
- Web wallpapers import, download and apply like scene and video wallpapers, and
  their user properties (combos, sliders, colors, text, booleans) are edited in the
  same inspector. Apply pushes the committed values into the running page.
- Play/Pause, the presentation policy (occluded desktop, display sleep, session
  lock), display assignment, mirroring, and Space posters apply to web wallpapers
  the same way they apply to renderer wallpapers. Occlusion is per display: a
  window covering the wallpaper on one screen suspends that page and leaves the
  page on another screen running.
- The Workshop badge reads *Web · built-in web view*; the inspector notes that
  mouse input and audio response reach the page while keyboard input does not.
- Mouse input reaches the page: hover, clicks, drags, right clicks and scrolling
  over the desktop are mirrored into the wallpaper. Finder keeps its icons and
  the desktop keeps every system behavior, so a click on an icon also reaches
  the page. Settings → General → *Keep windows in place when clicking the
  wallpaper* turns off macOS's "Click wallpaper to reveal desktop" option (the
  same value System Settings → Desktop & Dock writes) so a click no longer
  slides every window aside.
- On macOS 26+, **Use wallpaper as screen saver** can present web and still-image
  projects through the native extension. It uses committed properties and isolated
  file copies, without audio, capture or interaction. See
  [Screen saver](lock-screen.md#use-wallpaper-as-screen-saver) for activation,
  independent selection and verification limits. **Animate lock screen** does not
  support web projects; that combination is reported as not applicable, never as a
  failure.

## Host protocol

The page is loaded from `file://` with read access to its project folder, matching
Wallpaper Engine's CEF host: ES modules, `fetch()` and media inside the project
folder work, and `location.protocol` is `file:`. The top frame cannot navigate away
from the entry page; subframes and network requests are unrestricted (macOS ATS
applies, so plain `http://` requests fail).

The host script (`Shared/WebWallpaperProtocol.swift`, installed at document start and
shared with the screen-saver web surface) also closes one gap between WebKit and
Chromium. WebKit answers a `fetch()` or `XMLHttpRequest` of a project file with
status 0 and no headers, where Chromium answers 200 with a `Content-Type` taken from
the extension. The script gives a found `file://` GET/HEAD response that status and
type, so loaders that check `ok`, and WebGL exports (Unity, Emscripten) that call
`WebAssembly.instantiateStreaming`, start. Served `.wasm` responses are compiled from
their bytes rather than by WebKit's streaming compiler, which was slower to boot a
large module. Missing, failed and aborted requests, non-file responses and all
bodies stay native: nothing is copied, retried or run per frame.

| Call into the page | When |
|---|---|
| `wallpaperPropertyListener.applyUserProperties({ id: { value } })` | After load and after every Apply; colors are `"r g b"` floats in 0–1 as in `project.json` |
| `wallpaperPropertyListener.applyGeneralProperties({ fps })` | After load and when the display's target FPS changes |
| `wallpaperPropertyListener.setPaused(bool)` | Play/Pause, presentation suspension |
| `wallpaperPropertyListener.userDirectoryFilesAddedOrChanged(property, files)` / `userDirectoryFilesRemoved(property, files)` | A watched `fetchall` folder gained or lost files |

Combo values reach the page with the selected option's authored JSON type: a
numeric option stays a number, a boolean a boolean, and `"3"` a string. The
inspector and saved overrides still use string selection keys; conversion happens
only when the Web payload is exported, so strict comparisons and `switch`
statements in the page keep working. Property `order`/`index` values are ordering
hints, not identity: fractional values are preserved and properties that share one
all stay, in declaration order.

Values are replayed to a listener that registers after the first push, so pages
that install the listener from a deferred module still start.

The page may call `wallpaperRegisterAudioListener`, the five
`wallpaperRegisterMedia*Listener` functions (status, properties, thumbnail,
playback, timeline) and `wallpaperRequestRandomFileForProperty`.
`window.wallpaperMediaIntegration` exposes the playback constants under both
documented spellings, `PLAYBACK_PLAYING` / `PLAYBACK_PAUSED` / `PLAYBACK_STOPPED`
and `playback.PLAYING` / `.PAUSED` / `.STOPPED`, with values 0, 1 and 2.
Registering a listener replaces the previous one, and each listener fires only when
its own part of the state changed. A page that registers after load is given the
current state. Audio, media and directory delivery all stop while a page is
suspended and resume when it comes back: media state is re-derived on resume, and
directory additions and removals are held across the suspension and replayed in
order.

The wallpaper web view has exactly one `WKScriptMessageHandler`, named
`mweWallpaper`, carrying listener registration and random-file requests; it is
removed when the page stops. It is not the control panel's channel, which is a
separate web view with its own handler (see [architecture](../architecture.md#control-panel-wkwebview-and-the-javascript-bridge)).

## Runtime shape

- Rust (`upstream/renderer/crates/bridge`): `WallpaperProjectType::Web` entries are
  `supported`. `ActivationInputs::build()` routes web projects away from the scene
  engine and `build_web()` yields one `WebWallpaperDesc` per assigned display
  (mirrors included). The uniffi call `web_wallpapers()` exposes them as
  `BridgeWebWallpaper` (display id, project path, entry file, fps, paused, volume,
  mute, audio and media consent, and the effective property values as the
  `applyUserProperties` payload). The same web descriptors are exported to the
  native screen saver as lock-screen scenes with a web entry file.
- Swift (`App/Services/WebWallpaper/`): `WebWallpaperHost` re-reads
  `webWallpapers()` on every snapshot and diffs it against one `WebWallpaperWindow`
  (`MWEWebWallpaperDesktopWindow`, desktop level, all Spaces, mouse-transparent) per
  display. `WebWallpaperPage` owns the `WKWebView`, the host script,
  property/pause delivery, host-side suspension and content-process recovery.
- **Suspension** does not rely on the page cooperating. `setPaused` is an optional
  listener callback, so a page can ignore it; alongside it the host suspends all
  media playback (suspend and unsuspend, so media the user had paused is not
  started by a resume) and removes the web view from the window tree, which is the
  documented condition for `WKPreferences.inactiveSchedulingPolicy` (`.suspend`).
  A snapshot taken before detaching stays on screen as a placeholder inside the
  window's container view, so the Space poster sync keeps identifying the surface
  by the same content layer, and a suspended page receives no pointer events. The
  document is never reloaded to suspend it, so its JavaScript state survives. How
  much WebKit then throttles the page is its own decision and has not been
  measured here.
- **Occlusion** is left to `WallpaperPresentationPolicy`. A guarded per-view WebKit
  selector (`_setWindowOcclusionDetectionEnabled:`) disables WebKit's independent
  window-occlusion check; otherwise even a brief Space or Show Desktop transition
  can stop animation frames before the host's settling delay expires. If the
  selector is unavailable, the page keeps WebKit's default scheduling and the
  limitation is logged. This does not change the control panel or native
  screen-saver web surfaces.
- **Recovery.** A content process that keeps terminating is restarted on a windowed
  budget with exponential backoff rather than forever; the budget returns only
  after a document has run without interruption for the stable-run threshold.
  Committed host state (properties, fps, pause) is replayed in full on every new
  document, so a reload after a crash restores the page.
- **Host state in the inspector.** Each display reports loading, ready or failed. A
  failed live Web page offers **Retry wallpaper**; project validation and file-scan
  failures show their error without a retry that cannot reload a page, so fix the
  project and refresh or reapply it. Late callbacks from a replaced surface are
  ignored, and the host echoes the bridge's startup revision only after loading
  finishes or fails, so accepting an assignment does not imply ready content.
- **Library refresh** checks active project file identities on a background actor.
  Replacing HTML or resources at the same path reloads the page even when an
  intermediate empty assignment was coalesced away; an unchanged revision keeps the
  existing document.
- **Mouse input** (`WebWallpaperMouseForwarder`): the windows stay mouse-transparent
  and nothing is consumed, so no Accessibility or Input Monitoring grant is needed.
  The global `NSEvent` monitor exists only while at least one page is loaded and not
  host-suspended (`WebWallpaperHost.refreshPointerMonitor`).
  `WebWallpaperMouseRouting` forwards events only while the window the system would
  hit is below layer 0 (Finder's desktop, the system wallpaper, widgets), keeps a
  forwarded press's drags and release, and sends one exit when the pointer leaves
  the desktop. The hit window is the one the window server recorded in the event
  (`mouseEventWindowUnderMousePointer`), so routing makes no window-server call per
  move: a synchronous per-move query stalled the main thread during Show Desktop
  and froze the page. Only a press or scroll without the field still asks; a move
  without it is dropped. Events are rebuilt in wallpaper-window coordinates and
  replayed through the responder methods. Hover has no public entry point on
  `WKWebView`, so it uses `_simulateMouseMove:`/`_simulateMouseExit:` when the
  running WebKit responds to them, and `WebWallpaperWindow` reports `isKeyWindow` as
  true because WebKit hit-tests hover only for active windows (it still cannot
  become key, so keyboard focus is never taken). The host script cancels
  `contextmenu` defaults so WebKit's own menu never opens.
- `DesktopClickRevealPreference` (`App/Services/Desktop/`) reads and writes
  `com.apple.WindowManager EnableStandardClickToShowDesktop` for the Settings toggle.
- `WallpaperPresentationPolicy` counts both window classes when deciding whether a
  wallpaper pixel is visible; `DesktopWallpaperSync` asks a web surface for a
  `WKWebView` snapshot through the same poster request it sends to Metal layers.

## Audio response

Per wallpaper, off unless the user turns it on in the inspector's *General
configuration* (consent and capture are described in
[audio-response.md](audio-response.md)). The switch is consent to capture, not a
promise of delivery: the page receives nothing until it calls
`wallpaperRegisterAudioListener`, and a wallpaper that never asks stays silent
however the switch is left.

The panel reports this wallpaper's state from the running host: requesting a
connection, confirmed subscription, or successful delivery of a valid frame to its
JavaScript listener. A frame older than two seconds no longer counts as current
delivery. A failed subscription tells the user to toggle and retry; another
wallpaper's subscription never changes this one's status. With no running surface,
delivery stays unknown, and a page that has not registered a listener is reported
separately.

The listener receives a 128-float array: indices 0–63 the left channel, 64–127 the
right, low index first within a channel. Delivery is capped at 30 Hz, skips
generations the analyser did not recompute, and happens only while the page has a
registered listener, the user has audio response enabled for that wallpaper, and the
page is not suspended. One shared poller (`WebWallpaperAudioPump`) serves every
display and does not exist while nothing is subscribed; the system capture tap is
opened and closed from that same demand, and a page counts as a consumer only once
it has subscribed. Mute and volume do not affect it: a silenced wallpaper still
analyses what the system is playing. Values are clamped to 0.0–1.0 by the renderer's
spectrum entry point (`owe_audio_current_spectrum_128`); the official protocol says
values may occasionally exceed 1.0 and tells pages to clamp themselves, so this is a
documented deviation. How the spectrum is computed is in
[audio-response.md](audio-response.md#what-wallpapers-receive).

## Media integration

Off by default, per wallpaper. Web pages register `wallpaperRegisterMedia*`
listeners as above. The now-playing source is shared through `DesktopMediaSession`
and also feeds Scene wallpapers that have the same toggle on; sources, lifetime and
lock-screen policy are in [media-integration.md](media-integration.md).

The status listener describes the user's setting, independently of provider
availability. With integration enabled but no data, properties are empty, playback
is stopped and there is no timeline. An empty thumbnail string clears the previous
cover. Pages must tolerate absent metadata and timelines.

## User-selected files and folders

`file` and `directory` wallpaper properties let the page read a file the user chose
from anywhere on disk. A `WKWebView` only grants `file://` reads below the root passed
to `loadFileURL(_:allowingReadAccessTo:)`, and that root has to be an ancestor of the
entry page, so a page can never read outside its own project folder; widening the
root to a common ancestor would hand every wallpaper the whole application-support
tree. A symlink placed inside the root is resolved by WebKit and refused, a hard link
is not. Those two measured facts fix the design:

- **Managed store.** `App/Services/UserAssets/ManagedUserAssetStore.swift` holds the
  app's own copy of each chosen file under
  `~/Library/Application Support/WallpaperMachine/UserAssets/` (`WALLPAPER_MACHINE_HOME`
  relocates it), laid out as `<stableWallpaperId>/<propertyId>/<assetId>/<fileName>`
  with a `manifest.json` per wallpaper. The manifest, not the wallpaper package, is
  the system of record: asset id, the user's original path, size, modification time,
  a SHA-256 content digest, and whether the import was a file or a folder. Keying on
  the stable wallpaper id rather than the display name or entry file name lets an
  import survive a Workshop update or a delete-and-re-download. Import clones the
  file with `clonefile` where the filesystem supports it and copies otherwise; the
  user's original is never moved, renamed or written to. The modification time is
  kept in full precision (`modifiedReferenceTime`) so an unchanged selection can skip
  hashing after relaunch.
- **Derived bridge.** `App/Services/UserAssets/UserAssetStore.swift` keeps a bridge at
  `<project>/.mwe-user-assets/<propertyId>/`, a hard link onto the store's copy when
  the project shares its volume and a byte copy when it does not. It exists only
  because of the WebKit read-access rule and holds nothing of its own: deleting all of
  it loses nothing, because the next import rebuilds it from the manifest. Data flows
  store → bridge only, and the dot directory is the only thing created inside the
  project. A bridge written by this app carries a hidden `.managed-by` marker naming
  its wallpaper. A bridge without one, left by an older build, is absorbed into the
  store once and only when the property's original no longer resolves; nothing in the
  old location is deleted, the manifest records the migration, and a failed copy
  leaves the old entry loading as before.
- **Missing originals.** An asset whose original path no longer resolves but which is
  still in the store stays usable, served from the store. One that is in neither place
  is reported as missing (`assetMissing` on the property descriptor), never silently
  cleared.
- **Value handed to the page.** The staged absolute path with its leading `/`
  removed and `%`, `#` and `?` percent-escaped, so the page's `'file:///' + value`
  resolves. Spaces, non-ASCII, `+`, `&` and `'` stay literal, because a page that
  treats the value as a plain path must still see them.
- **Accepted files.** Only image (`jpeg jpg png pnga bmp gif svg webp`) and video
  (`webm ogg ogv`) extensions are staged, case-insensitively; a property that
  declares no file type accepts the union of the two, never an arbitrary file. A
  folder is read one level deep and capped at
  `UserAssetStore.defaultDirectoryFileLimit` (4096) entries; hitting the cap is
  reported rather than silently dropping files.
- **Watching.** A `fetchall` folder is watched with FSEvents, never polled. A burst
  of changes is debounced into one added/removed diff, which re-stages added or
  rewritten files, drops the links for removed ones, and reaches the page as
  `userDirectoryFilesAddedOrChanged` / `userDirectoryFilesRemoved`. An unavailable
  directory, an unreadable matching file or a failed manifest write preserves the
  last committed list and bytes; pruning happens only after the new manifest is
  durable.
- **Concurrency.** `UserAssetWorker` enumerates, hashes, copies and publishes bridges
  off the main actor. A newer selection cancels the previous preparation, and one
  asynchronous turn per managed root and wallpaper serializes preparation,
  publication, permission changes and purge across store instances, so a stale
  preparation cannot overwrite a newer selection. Copies publish from private
  temporary files, so cancellation never deletes another import's copy.
- **Lifetime.** The store outlives the project, the bridge outlives the process, the
  in-memory index does not. `WebWallpaperHost` re-imports on next use (which rebuilds
  a missing bridge) and discards the store handle for a project nothing displays any
  more. Changing the pick replaces that property's assets in both places; clearing a
  property removes them from both.
  `python3 scripts/clean.py --user-assets` removes every `.mwe-user-assets` bridge in
  the imported library and the Steam workshop folder, which the app rebuilds on next
  load. `--managed-user-assets` is the destructive one: it deletes the app's own
  copies, which nothing regenerates. Neither the default pass nor `--all` nor
  `--derived` reaches either of them.
- **Storage settings.** Settings → Storage → *Wallpaper files you chose* shows the
  managed directory, reveals it in Finder, and **Clear unused caches…** reclaims only
  stored bytes no manifest still lists: an orphaned `assetId` folder, a property the
  manifest no longer mentions, a wallpaper folder with no manifest. A referenced asset
  is never a purge candidate, which matters most for the property whose original has
  gone and whose stored copy is now the only one. A missing manifest is distinct from
  an unreadable, damaged, foreign or unsupported manifest; the latter blocks purging
  or replacing that wallpaper's files, is logged and skipped, and the purge continues
  with the others.
- **Lock screen and screen saver.** The sandboxed extension
  (`Extension/WallpaperExtension.entitlements`) cannot read the store or the bridge.
  For a committed **video or scene** wallpaper, the assets it actually references are
  republished into the lock-screen exchange directory as their own
  `revisions/<fingerprint>/` tree and the property values are rewritten to point at
  that copy; the fingerprint covers the recorded content digests, so an unchanged
  selection is not copied again, and revisions the published configuration no longer
  names are collected after each successful publish. Web projects get a separate
  read-grant root holding only their referenced managed files; see
  [lock-screen.md](lock-screen.md#storage).

### In the inspector

A `file` property shows a read-only field with the chosen file's own name (never the
staged path the page reads), a *Choose…* button, a *Clear* button, and the extensions
the property accepts, taken from its `fileFilter`. An absent filter means the author
declared no file-type option, which the protocol defines as both kinds it knows, so
both lists are offered.

A `directory` property adds how many files in the chosen folder the importer would
take, whether the folder holds more than the import limit, and what the wallpaper does
with them: a `fetchall` folder is handed to the page whole, an `ondemand` folder is
one the page picks from itself. The count is the panel's own measurement of the
chosen folder, applying the importer's screens (first level, accepted extensions, no
hidden entries, regular files only, readable only), and is kept until the chosen path
changes. It describes the folder, never the outcome of an import the panel cannot
observe: a single entry whose link and copy both fail is skipped and logged by the
importer. A folder that cannot be read is reported as unreadable rather than empty.

Both persist through `setPropertyPath`; *Clear* sends `nil` and the engine writes the
property's own default back. A choice the app cannot honour (a wallpaper folder that
is missing or read-only, so nothing can be staged inside it) is reported beside that
control rather than in the window-wide banner, and the path is not sent. `texture` and
`scenetexture` properties are a separate kind: they keep the scene texture picker and
are refused by the path editor.

## Page sound

Mute and Volume reach the page's output, independently of Audio response.
`WebWallpaperAudioOutput` resolves WebKit's native interfaces at runtime:
`WKPageSetMediaVolume` controls HTML audio/video media elements, while
`_setPageMuted:` with only the audio bit controls whole-page output, including
WebAudio. Nonzero Volume is **not** a WebAudio gain control. Zero volume also mutes
the page; neither control pauses media timelines or disables system-audio analysis.
The official general-property payload remains `fps`, not an invented `volume`
protocol.

User mute and temporary app/Focus/other-audio mute compose in the existing bridge
configuration; ending a rule does not clear user mute. Mirrored pages elect one
presenting audible owner per actual source assignment (`WebWallpaperAudioOwnership`);
independent assignments of the same project stay independent, and a hidden owner
hands off to a visible mirror without duplicate sound.

These are private WebKit interfaces and may be unavailable on another macOS version.
**Audio and media status** in the inspector reports the observed availability and
never substitutes Pause for an unavailable mute.

## Limits

- Keyboard input is not forwarded; the wallpaper window never becomes key.
- Pointer events are mirrored, not captured: Finder still selects icons and
  rubber-bands, and a click on an icon reaches the page too. The middle button
  arrives without its button number.
- Nonzero WebAudio gain is not controlled by the native media-volume interface;
  whole-page Mute still applies where WebKit exposes it.

## Verification

The page host is tested against a real offscreen `WKWebView` with no desktop window
(`Tests/Unit/WebWallpaper/`: module loading, late-listener replay, local request
metadata, pause composition, suspension, navigation lockdown, forwarded pointer
events, mouse routing policy), the inspector side in
`Tests/Unit/Panel/WebPanelAssetPropertiesTests.swift`, and the bridge contract in
`upstream/renderer/crates/bridge/src/tests/` (`apply_options.rs`,
`file_properties.rs`, `web_audio_media.rs`); the domain inventory is in
[coverage](../testing/coverage.md). Show Desktop and Space transition smoothness,
real hover and window-server routing on a desktop, audible output and mirror audio
handoff need an authorized manual run.
