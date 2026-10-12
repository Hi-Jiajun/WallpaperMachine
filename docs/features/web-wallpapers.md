# Web wallpapers

Wallpaper Engine projects with `"type": "web"` are HTML pages (`"file"` names the
entry page, usually `index.html`) that talk to their host through
`window.wallpaperPropertyListener`. WallpaperMachine renders them in a
`WKWebView` hosted by the app; the vendored scene renderer never opens a window
for them.

## What the user sees

- [Live preview](wallpaper-properties.md#live-preview) runs an installed project in its
  own window and temporary website data store, with independent playback and
  default mute. It never replaces the desktop page or its stored state.
- Web wallpapers import, download and apply like scene and video wallpapers, and
  their user properties (combos, sliders, colors, text, booleans) are edited in the
  same inspector. Apply pushes the committed values into the running page.
- Play/Pause, the presentation policy (occluded desktop, display sleep, session
  lock), display assignment, mirroring, and Space posters
  ([desktop picture](desktop-picture.md)) apply to web wallpapers
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
| `wallpaperPropertyListener.setPaused(bool)` | Play/Pause, battery Pause, presentation suspension; the page's cooperative half, the host suspends it as well ([Suspension](#runtime-shape)) |
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
suspended (covered, or paused once it has drawn) and resume when it comes back:
media state is re-derived on resume, and directory additions and removals are held
across the suspension and replayed in order.

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
  document is never reloaded to suspend it, so its JavaScript state survives.
  Two reasons suspend a page and they compose, so clearing one leaves the other in
  force. The presentation policy (no pixel can reach the display) suspends at once.
  A paused wallpaper suspends once its first frame has had time to draw:
  `BridgeWebWallpaper.paused` is the bridge's composed flag (Play/Pause, battery
  Pause, and the bridge's own presentation and per-display suspension), and
  `WebWallpaperPage.Timing.firstFrameGrace` (3 s, the first settle capture of the
  poster sync) starts when the document has finished loading and its view is in the
  window; time spent covered does not count, and it starts over each time the view
  is put back. The grace exists because
  `didFinish` fires before the first meaningful paint, the bridge defers a battery
  pause until the host reports startup, and a wallpaper can be applied while
  paused; detaching at once would snapshot a blank view and WebKit may not finish
  loading a detached one. A reload or a crash restart puts a paused page back in
  the window tree for its load and suspends it again after its next first frame. The
  grace expiring has no host call behind it, so the page reports it
  (`onHostSuspensionChanged`) and the host drops the global pointer monitor and
  re-elects audio owners; each transition is logged at debug level
  (`host suspension on|off`) so resume latency can be read from the log. Because
  `paused` includes the presentation, a presentation resume also waits for the
  descriptors to be read again, and a presentation change returns no snapshot to
  carry them: `AppDelegate` reconciles the web and native video hosts once the bridge has
  committed the change (or failed to), and the pause that came from the covered
  desktop ends with it. Values applied while a page is suspended reach it when it
  resumes, not before, with one exception: a changed property payload (the
  inspector's Apply, an image's fit or placement) reaching a page that only its
  pause holds still puts the page back in the window for another first-frame
  grace, so the edit draws, and detaches it again with the frame it drew; the
  host then reads the Space posters again (`onSuspensionPosterRefreshed`). A page
  that is also covered waits for the cover to end. The frame limit and the render
  scale do not wake a paused page: they change how it draws, not what it shows,
  and apply when it plays.
  The frame taken at detach is kept (`suspensionPoster`) and answers the desktop
  poster sync's requests, because WebKit does not promise a snapshot of a detached
  view ([desktop picture](desktop-picture.md#when-a-poster-is-taken)). With its view
  detached, a page that implements no pause listener runs no animation frames, no
  timer callbacks and no CSS animation iterations
  (`WebWallpaperSuspensionTests.testUserPauseStopsFramesTimersAndCSSOfAPageWithoutAListener`
  counts them by wall-clock time inside the detached interval). The energy effect
  on a real desktop is the power benchmark's T4 and has not been measured.
- **Occlusion** is left to `WallpaperPresentationPolicy`. A guarded per-view WebKit
  selector (`_setWindowOcclusionDetectionEnabled:`) disables WebKit's independent
  window-occlusion check; otherwise even a brief Space or Show Desktop transition
  can stop animation frames before the host's settling delay expires. If the
  selector is unavailable, the page keeps WebKit's default scheduling and the
  limitation is logged. This does not change the control panel or native
  screen-saver web surfaces.
- **Frame rate.** The page is told the display's effective frame rate through
  `applyGeneralProperties({ fps })`, and many pages pace their own loop by it.
  WebKit draws a page near 60 fps even on a faster display, and it hands the page
  one pointer move per drawn frame, so hover is held to that rate too. When the
  effective rate reaches the refresh of a display above 60 Hz (the user chose, for
  example, 120 on a 120 Hz display), `WebWallpaperHost` creates the page with
  WebKit's `PreferPageRenderingUpdatesNear60FPSEnabled` feature off, and the page
  then draws, and receives the pointer, at the full refresh. WebKit reads that
  feature only when a web view is created, so a rate change that crosses the
  refresh (the slider, or the battery frame rate taking over) rebuilds the page;
  a change that stays on one side keeps the document. At the default rate nothing
  changes. If the running WebKit no longer offers the feature, the page keeps the
  default cadence and the limitation is logged once.
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

`file` and `directory` properties let the user give a page a picture, a clip or a folder of
them from anywhere on disk. The app keeps its own copy and stages it where WebKit lets the
page read it; the storage, the value the page receives, folder watching and the inspector
control are in [user-files.md](user-files.md).

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
- A page sees at most one pointer move per frame it draws. Below a fast display's
  full refresh, WebKit's own cadence near 60 fps applies (60 on a 120 Hz display,
  whatever rate between 60 and 120 is chosen). A page that cannot keep up, such as
  a heavy WebGL scene on a slower GPU, slows its pointer with its frames.
- Nonzero WebAudio gain is not controlled by the native media-volume interface;
  whole-page Mute still applies where WebKit exposes it.
- A paused wallpaper's WebAudio is muted (`WebWallpaperAudioOwnership` gives a paused
  page no audible output) but not suspended: the host has no `AudioContext`
  handling, and what WebKit's own throttling does to a detached page's audio graph
  is unmeasured.

## Verification

The page host is tested against a real offscreen `WKWebView` with no desktop window
(`Tests/Unit/WebWallpaper/`: module loading, late-listener replay, local request
metadata, pause composition, suspension by presentation and by pause with its
first-frame grace and edits shown while paused, navigation lockdown, forwarded
pointer events, mouse routing policy) and the bridge contract in
`upstream/renderer/crates/bridge/src/tests/` (`apply_options.rs`,
`web_audio_media.rs`); file and directory properties are covered under
[user files](user-files.md#verification), and the domain inventory is in
[coverage](../testing/coverage.md). Show Desktop and Space transition smoothness,
real hover and window-server routing on a desktop, audible output and mirror audio
handoff need an authorized manual run.
