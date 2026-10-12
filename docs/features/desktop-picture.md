# System desktop picture and Mission Control

The wallpaper on screen is an app window, but macOS keeps its own static desktop
picture for every desktop (Space) of every display. That picture is what Mission
Control and the Spaces bar show, what appears for a moment beneath a renderer that is
still loading, and what stays on screen when the app is not running. WallpaperMachine
installs a **poster**, a still frame of the animated wallpaper, as that picture so it
matches what the user sees, and puts the user's own wallpaper back when the app quits.
The windows that draw the live wallpaper are described in
[architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling).

The pieces are `DesktopWallpaperSync` (when to take, encode and apply posters),
`DesktopWallpaperLedger` (which desktops to write, the journal of originals and the
restoration) and `DesktopSpaceWallpaperAPI` (the private per-Space calls), all in
`App/Services/Desktop/`.

## What the user sees

Mission Control thumbnails are sampled still frames, not live animation. A poster is
the renderer's real final pixels, not a screen capture and not a Workshop cover, so
scaling and cropping match the live wallpaper. Rendering, JPEG encoding and the
system's thumbnail compositor still take time, so an update is not instant.

**Settings › General › Startup & desktop › Update the Mission Control picture every 5
minutes** (`PlaybackPreferences.refreshesDesktopPicturePeriodically`, off by default)
retakes the poster every five minutes while the wallpaper plays, for wallpapers that
change over time. Without it the poster is taken only at the moments listed
[below](#when-a-poster-is-taken), so it shows the wallpaper as it looked once it
settled. The setting applies to the running sync at once and has no effect while the
lock screen is animated, because poster sync is then suspended
([below](#the-native-lock-screen-provider-and-space-selection)).

With no live wallpaper on a display, nothing is written there: its desktops show the
user's own wallpaper again.

## When a poster is taken

A poster is requested from the surface that draws the wallpaper, which answers with
its final pixels: a Metal readback for scene and Compatibility-backend video, a
`WKWebView` snapshot for a web wallpaper, and the player surface's image for a
native-backend video. The request and the answer carry the same context string (empty
outside Space selection mode), so a reply can be matched to the request that asked for
it. The first ready frame goes to every native desktop of the display at once, without
visiting them.

- **A wallpaper starts or changes.** It is captured at once and again after
  `DesktopWallpaperSync.settleCaptureDelays` (3 s and 15 s), because intros, fades and
  settings that fade in are missed by the first frame. A wallpaper that resumes after
  a pause, a cover or display sleep settles the same way (`presentationResumed`).
- **A Space change or wake.** The existing poster is applied at once and a fresh frame
  is requested, since an animated wallpaper has moved on since its poster was taken.
  Desktops that kept refusing posters are tried again, and the Space monitor re-reads
  the topology first.
- **Periodically**, every `periodicRefreshInterval` (300 s), while the setting is on.
- Settling and periodic captures ask only displays whose wallpaper is presenting
  (`canCapture`: the presentation policy has not suspended playback globally or for
  that display); a new wallpaper, a Space change and a wake capture every surface.
- A frame identical to the current poster costs a readback and a hash, and is neither
  encoded again nor rewritten. Bursts of refresh requests collapse so that at most one
  runs every 500 ms.
- Only the newest frame of a surface that is still on screen may become its poster.
  While one wallpaper window replaces another on a display, the poster whose frame
  arrived last wins, counted on receipt and not when encoding ends, so a slow encode
  cannot put the old picture back; a window without a poster yet never removes its
  sibling's.

Posters are JPEG (`DesktopPosterEncoder`, quality 0.9, sRGB) under
`<support>/DesktopPosters/` (`<support>` is `ClientPaths.supportURL`). The file name
hashes the display, the original it replaced and the pixels, so a filename is never
reused for different pixels (WallpaperAgent can cache inactive-Space thumbnails by
URL) and identical frames share one immutable file. A poster has the display's exact
aspect ratio and is written with fill-screen placement, so the renderer's crop or bars
are kept without scaling the content a second time. A failed synchronization is
retried up to three times, 100 ms longer each time, for the system's asynchronous
acknowledgement and Space-creation races; the initial update is never delayed for
them.

## Reaching the per-Space picture

`DesktopSpaceWallpaperAPI` `dlopen`s CoreGraphics and HIServices and resolves
`_CGSDefaultConnection`, `CGSCopyManagedDisplaySpaces`,
`DesktopPictureCopyDisplayForSpace` and `DesktopPictureSetDisplayForSpace`. Every
symbol is optional: if one is missing the initializer fails and the caller falls back
to the public `NSWorkspace` API, which is scoped to the visible Space. That fallback
is logged once, has no Space identity and so cannot accept a Space-scoped write.
Switching Spaces, patching the wallpaper plist and restarting system processes are
deliberately not used.

A target is a display and the UUID of one of its regular desktops; fullscreen-app
Spaces are not desktop thumbnails and are skipped.

`SystemDesktopPictureWorkspace.referencedPictureURLs` reads the system wallpaper store
(`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`) read-only, to
see what WallpaperAgent will load. A selection waiting for the agent to reload may not be
visible through the picture API yet, and the picture API can still report the old
selection after the store has the new one. Screen-saver-only (idle) choices are
excluded because they do not own the desktop and posters never write them.

## The journal of originals

Before anything is replaced, `DesktopWallpaperLedger` records the user's original
per-Space picture in `<support>/DesktopPosters/originals.json`, keyed by poster file
name. It keeps the complete native configuration, including the opaque options blob of
a dynamic wallpaper or slideshow, and writes it back as it was rather than rebuilding
it. The entry is saved before the native call, so a crash or relaunch can still find
it; after a crash the poster stays installed until the next launch, which recognizes
it by its folder and journal entry and keeps the original.

A pathless (inherited) selection or a poster cannot bring the user's wallpaper back, so
before any write the ledger resolves each display's original in this order: its first
real per-Space original, then its effective image through `NSWorkspace`, then its saved
journal, and finally another display's original. With no recoverable original it leaves
that desktop untouched and reports the failure through `AppLog`; live playback
continues without new posters there.

A desktop showing anything but a poster was changed outside the app and keeps that
choice on restoration. When a display stops showing a live wallpaper, its desktops are
restored while the others keep their posters.

Posters no readable desktop shows are deleted. A display is complete when every desktop
on it is a native Space whose picture was read; elsewhere an unseen desktop may still
show a poster, so only the newest `retainedPostersPerIncompleteDisplay` (4) are kept
there and older ones go. A poster a readable desktop shows is never deleted, and
neither is one whose write is still settling.

## Writes macOS delays or refuses

The per-Space setter returns before the write is applied, so its return is not an
acknowledgement. `DesktopSpaceWallpaperAPI.set` reads the picture back right after the
write: one that does not read back yet is **unconfirmed**
(`DesktopPictureUnconfirmed`), not refused. WallpaperAgent copies the poster file some time after
the write, so the file stays on disk for `DesktopWallpaperLedger.confirmationWindow`
(1 s) even if a newer frame replaces it or its desktop stops receiving posters, and
`DesktopWallpaperSync` synchronizes again once that window has passed. A pending
write that reads back is confirmed without counting a refusal; one that still has not
after the window counts as refused. The same poster that is still on its way is not
rewritten, and a poster that lands on a desktop which no longer receives them is put
back to the original wallpaper by that follow-up pass.

A desktop macOS keeps refusing (`DesktopWallpaperLedger.refusalsBeforePause`, 4 writes
in a row) is logged once and left alone, rather than rewritten on every snapshot, until
the next Space change or wake. One desktop failing never stops the others: the pass
continues and reports the first error afterwards.

## macOS 27

The per-Space setter forwards to WallpaperAgent, which applies the write
asynchronously, about 0.3 s later. Because WallpaperAgent runs sandboxed, it resolves a
relative image path inside its own container, where the poster does not exist, and
rejects the write. Paths are therefore sent absolute from macOS 27
(`DesktopSpaceWallpaperAPI.takesAbsolutePaths`); through macOS 26 the setter
mis-expanded absolute home paths into `/~`, so they are sent root-relative there.

macOS 27 can also copy a Space write into the display-wide and system-default
selections. No per-Space write reaches those, so the poster remains named there after
every desktop that can be written has been restored; see
[Quitting](#quitting). When diagnosing, read back through the picture API, because the
agent's on-disk `Index.plist` can lag its in-memory store until a scheduled write.

## Quitting

`applicationShouldTerminate` first suspends poster sync, so no new poster is written
during the quit. The native lock-screen service then restores its own selections
(without a lock-screen service, on macOS earlier than 26, restoration starts
directly), and the poster service restores the originals: it puts each desktop's
journaled original back, checks image references in the native store read-only, and
retries asynchronous restoration for about five seconds (25 attempts, 200 ms apart)
while WallpaperAgent reloads. Quit waits for every restored desktop to read back and for any poster write
still in flight; one that lands late is restored again.

A poster the store still names after every writable desktop is restored and read back
is logged and does not block quit, since macOS 27 can keep a reference no per-Space
write can remove. Any other failure cancels the quit, and so does restoration that
takes longer than 20 seconds (`QuitSupervisor`). Nothing after restoration starts for a
cancelled quit. Because the app is hidden while it quits, a cancelled quit puts things back
and says so:

- poster synchronization restarts unless the native lock-screen provider has the desktop;
- the control panel (and What's New) comes back if it was open, on the section it was on;
- an alert gives the reason: the restoration error's own text (macOS is still restoring the
  desktop wallpaper, or the original could not be recovered and the user should select
  their wallpaper again in System Settings), or that restoring took too long, and that
  quitting again retries;
- an update installer that was waiting for the app to quit is called off, so it cannot
  replace the app at some later quit; the update stays downloaded and About offers it again;
- the error also stays as a line in the menu bar menu, and the user can quit again.

The restoration stage is cancelled when its time is up. `restoreForTermination` checks for
cancellation before every one of its 25 attempts and its wait between them is cancellable, so it
stops promptly and leaves the originals journal as it was. A step that never returns and
ignores cancellation (a hung call into WallpaperAgent) cannot be stopped; the quit is still
refused on time, but that step may finish later.

While a quit is running the menu shows a disabled **Quitting…** in place of **Exit**, and a
second request to quit is refused. The stages after restoration (services, imports,
SteamCMD, Workshop, pixiv, the renderer) share 10 seconds. See
[architecture](../architecture.md#appkit-shell) for the budgets and the exit fuse and
[diagnostics](diagnostics.md#why-the-app-quit) for the log lines.

## The native lock-screen provider and Space selection

With **Animate lock screen**, the sandboxed extension owns the system Desktop provider,
so the still frame Mission Control shows comes from the extension, which keeps
animating for 15 seconds after its first frame before holding it
([lock-screen.md](lock-screen.md#how-the-surface-behaves)), and poster sync has nothing
to do. `suspendForNativeProvider` stops every poster write, cancels the timers and
drops the per-layer state, but keeps the poster file and the journal because the
native provider journals the current poster as the original it will restore. Poster
sync restarts when the provider releases the desktop, and is not started while one is
active or an animated lock screen is on its way to taking it. A screen saver chosen on
its own leaves poster sync running. For restoration order at quit with the provider active, see
[lock-screen.md](lock-screen.md#turning-it-off).

A display using the experimental Follow desktop Space mode scopes its posters to the
visited desktop and holds writes while it has no current target. The context
bookkeeping that rejects late frames is in
[spaces.md](spaces.md#poster-ownership-and-late-frames), and the mode's conflict with
the animated lock screen in
[spaces.md](spaces.md#focus-mirroring-and-native-lock-screen-ownership).

## Verification

`DesktopWallpaperTests` cover posters, timing, refusals, originals and quit with
synthetic pixels and an in-memory workspace that never touches the user's wallpaper;
the inventory is under [Posters](../testing/coverage.md#posters-mission-control). What
Mission Control actually shows, its refresh latency, and macOS accepting and restoring
the native selections are not covered and need an authorized desktop run
([manual smoke](../testing/manual-smoke.md#native-desktop-posters-and-mission-control)).
