# Switching wallpapers without a black gap

Choosing another wallpaper tears the old renderer down before the new one has drawn a
frame, and the window between the two is black. The **switch hold** covers that gap: it
takes a still of what the display shows just before the switch, carries it over the window
that shows the new wallpaper, and fades it out once the new wallpaper has drawn. There is no
setting; it applies whenever the conditions below hold and costs one picture in memory per
display while a switch loads.

The pieces are `WallpaperSwitchHold` (the per-display state and its timers) and
`SwitchHoldVeil` (the layer that carries the still), both in `App/Services/Desktop/`, and
three hooks on `BridgeStore` that tell the hold when a switch starts, settles or fails.

## What the user sees

- The previous wallpaper stays on screen while the new one loads, then fades out over 0.2
  seconds. A scene that takes seconds to load, or a cold shader compile, no longer shows a
  black screen first.
- **Reduce Motion** (System Settings › Accessibility › Display) removes the fade: the
  previous picture is replaced at once when the new wallpaper has drawn.
- The held picture is a still taken up to a quarter of a second before the switch. An
  animated wallpaper may therefore jump a little at the moment the new one appears.
- When no still can be taken, the switch behaves as it always did.

## Which switches are held

Held: any activation that goes through `BridgeStore.activateWallpaperAsync` (a tile or
menu choice, a hotkey, a link, a Shortcuts action, a playlist or rule, a rotation on unlock,
**Back**, **Random Wallpaper**, a wallpaper applied to every display, a saved display layout,
**Copy or swap**) on a display that is showing a wallpaper, when the new
wallpaper is drawn by the scene engine: a scene, or a video on the Compatibility backend.
A display mirroring the switched display is held with it.

Not held, because the old picture is not available or the successor is not a scene:

- A display with no wallpaper window yet (the first wallpaper, or one just ejected), a
  display that is suspended (display sleep, a covered desktop, a pause rule, a lock), and
  any display whose surface does not answer within 250 ms (a paused or stalled renderer
  may not).
- **Reapply wallpaper**, Retry for a scene that stopped, and the reload after an update:
  all three take the wallpaper off the display first, so there is no picture left to hold.
- A web page or a video on the native backend as the successor: their windows are
  owned by `WebWallpaperHost` and `NativeVideoWallpaperHost`, which do not take the veil
  yet (`WallpaperSwitchHold.adopt` and `contentReady` are the entry points they will
  use). A held still that no host picks up is released 8 seconds after the engine has
  finished.
- First launch, quit, display reconfigures and wake rebuilds, and the rebuild a host does
  when an admission or a setting changes.

## Limits

| Limit | Value | Why |
|---|---|---|
| Waiting for the still | 250 ms | Every switch waits this long at most before it applies |
| Holding a display | 30 s | A cold compile can outlast it, which only restores the black gap |
| Waiting for a host window | 8 s | After the engine finished with no scene to carry the still |
| Fade | 0.2 s | None under Reduce Motion |

The still is the renderer's final pixels at the display's pixel size, four bytes per
pixel: about 60 MB on a 5K display, held for at most the ceiling. A second switch while a
host successor (a web page or a clip) is still loading keeps the still it has and restarts
the ceiling; it never takes another. A scene is different: its switch finishes when it has
drawn, so the next switch finds the veil fading or gone and takes a fresh still of the new
scene.

## How it works

1. **Before the apply.** `BridgeStore.performActivation` calls `willSwitchWallpaper` with
   the live display ids the switch changes (`switchHoldDisplays(for:)`: the display and every
   display mirroring it) after every check that could refuse the activation, and before the
   display config is enabled. An activation that finds its wallpaper already active and
   clean returns earlier and announces nothing.
2. **The still.** For each display the hold asks the frontmost wallpaper window for a frame
   with `DesktopPosterNotification.request` on its content layer, the same request the
   [desktop picture](desktop-picture.md) sync uses, so scene, web and native surfaces all
   answer it. The request carries the context `switch-hold:<uuid>`. The hold takes the first
   frame the layer reports, whatever it was asked for. `DesktopWallpaperSync` ignores a
   frame whose context is not the one it asked for, so a held still can never become the
   desktop poster. Several displays are asked at once.
3. **The veil.** The still becomes `SwitchHoldVeil`, a plain sublayer named `MWEHandoffVeil`
   with a high `zPosition`, never a window: occlusion tracking, hit testing, the poster sync
   and web snapshots see the window as before.
4. **A scene successor.** The Rust window code posts `WallpaperMachine.wallpaperLayerInstalled`
   for every content layer it gives a window, synchronously on the main thread before the
   layer is first composited (see [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling)).
   The hold moves the veil onto the new layer for the reasons `open` and `replace`. A
   `reconfigure` (a display change that gives the window a fresh layer) moves it only while
   the veil sits on a scene successor that has not presented yet: that renderer has no
   picture to keep, and the veil would go with the layer it replaced. Before a successor has
   a layer, or on a host's window, a `reconfigure` is ignored: the renderer that shows a
   picture keeps it. It never restarts the 30 second ceiling, because the load did not
   start over. A second announcement moves the veil again, so a switch that opens a
   window and then replaces its layer still ends with the veil on the layer that is shown.
5. **Release.** `didSettleWallpaperSwitch` fires when the engine's apply returns, which
   waits for the first presented frame of every replaced display: a veil on a scene layer
   fades out then. `didAbandonWallpaperSwitch` fires when the apply throws or is
   cancelled and releases the veil (with the fade when it sits on a window); a scene whose
   replacement failed shows its previous renderer again (see the layer swap in the
   architecture document).
6. **Backstops.** A veil nothing releases is removed after 30 seconds. The fade ends from a
   timer and not from the animation's completion, which does not run for a layer that is
   off screen. `stop()` removes every veil at once and runs before the hosts shut down.

A host window (web page, native clip) takes the veil with `adopt(into:displayID:)`, which
refuses a veil that still covers a live window, and releases it with `contentReady`, with an
optional wait for a page's first paint. `cancel` ends a hold the host abandoned.

## Diagnostics

The hold logs through `AppLog`, one line per step and always the display's CoreGraphics
id:

- `switch hold: display N frame captured in X ms (WxH)`
- `switch hold: display N veil on scene layer`
- `switch hold: display N veil followed a display reconfigure`
- `switch hold: display N adopted by host`
- `switch hold: display N released after S s (scene first frame | host ready | cancelled | no window took it | ceiling)`
- warnings: `poster not delivered within 250 ms; not holding`, `poster frame WxH could not be
  used; not holding` and `ceiling reached after 30 s; releasing`

A switch with no `frame captured` line was not held. The activation line
([diagnostics](diagnostics.md)) is unchanged and still says who asked and how it ended.

## Verification

`WallpaperSwitchHoldTests` drive the hold with an injected notification center, plain
`CALayer`s, a manual clock and timers: the request goes to the frontmost layer, an unanswered
or unusable request leaves no ticket, announcements move the veil, `reconfigure` moves it only
off a scene that has not presented yet and does not restart the ceiling, the veil fades and is
removed by the timer, Reduce Motion skips the fade, the ceiling and the
host grace release a veil nothing ends, `cancel` and `stop` remove everything including a
still still on its way, and displays are held independently.
`WallpaperActivationRecoveryTests` pin the hook order around a real
`BridgeStore.activateWallpaperAsync` (announce, apply, settle; abandon when the apply throws;
nothing for a no-op) and which displays a switch holds. `DesktopWallpaperTests` pin the shared
poster frame conversion and that a held frame never becomes the poster.

Not established by any test: that a sublayer above a `CAMetalLayer` composites over its
drawables and hides the black placeholder; that scene, web and native surfaces answer the
request quickly, including a paused renderer; how the still compares with the live frame it
replaces; the fade, Reduce Motion, multi-display and mirror behavior on a real desktop. The
checklist is in [manual smoke](../testing/manual-smoke.md#wallpaper-switching).
