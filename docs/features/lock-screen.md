# Lock screen and screen saver (experimental)

The app can animate the macOS lock screen and use applied wallpapers as the
screen saver. Both choices are off by default and require macOS 26 or later. The
file exchange between the app and the sandboxed extension is specified in
[architecture](../architecture.md#lock-screen-extension); this document describes
what the user gets and the rules that keep the two native modes consistent.

## Enabling it

Apply a video or live scene to a display, then enable **Settings → General →
Animate lock screen**, or the same switch on the welcome guide's Preferences page
(it applies at once there too; the guide's **Skip** turns it back to what it was
when the guide opened). A status row next to the Settings switch reports the
current state, and a **Retry** action appears when activation failed.

### How the surface behaves

This uses a sandboxed native wallpaper extension (the [`Extension/`](../../Extension)
ExtensionKit target) rather than drawing an ordinary app window over the login UI.
While it is active the native desktop remains a still frame, while the existing
desktop renderer keeps playing. That still frame is what Mission Control shows, so
an unlocked lock-screen surface keeps animating for 15 seconds after its first
frame (`WallpaperPresentationAuthority.desktopSettleBudget`) rather than holding an
intro's opening (often black) or a setting before it has faded in. A new wallpaper
or changed setting replaces the renderer and settles again; the periodic Mission
Control update in Settings does not apply in this mode.

Once settled, the surface pauses its renderer while retaining scene state, textures
and device allocations, and reads the held frame back. That frame is committed
beneath the nonopaque Metal layer (no implicit animation) before readiness is
acknowledged, so there are real wallpaper pixels when a drawable is not yet
available or is reclaimed across sleep; later drawables cover it without a timed
fade. Scene replacement keeps this backing until a new frame arrives; clearing the
configuration or failing to start the replacement drops it. Display sleep and host
suspension pause rather than unload; locking or waking resumes the same renderer
once the display is awake, the host is active and user/power policy permits
playback. This costs more resident memory than showing a static poster, but nothing
renders continuously while paused, and resolution, frame rate and effects are
unchanged. A newly acquired surface or a changed wallpaper still needs an initial
load, macOS can show its own cached snapshot before it presents the extension, and
real lock/wake timing is OS-controlled.

### Display changes

Topology refreshes stage the next complete configuration before
replacing the previous one, so no empty manifest is published between a one-display
and a two-display mapping, and the committed enabled state stays until the new
mapping's first frame is acknowledged (or deactivation rolls a real failure back to
disabled). If Core Graphics temporarily cannot resolve a display the bridge still
names, during wake or a lid change, the committed manifest and native selection stay
untouched and that gap is not an error: while no earlier error is pending, the
status monitor retries the same scene set once the topology settles. A real earlier
compatibility or restoration error is left in place and the monitor stays stopped
until an explicit retry succeeds. Removing the last wallpaper, disabling both modes,
and shared publication or renderer failure recovery clear the manifest. If macOS
reacquires the same `WallpaperID` on the same display at a different size or scale,
the extension keeps its remote context and backing frame and rebuilds the renderer at
the new pixel size; geometry stays local to that display, a changed aspect ratio can
briefly stretch the old frame, and invalid dimensions are rejected before the
existing renderer is touched. Whether macOS keeps a context after an acquire error is
unverified.

### Audio, media and the Enabled state

Lock-screen audio, audio input and media integration are disabled (see
[Audio response](audio-response.md) and [Media integration](media-integration.md));
the bridge exports lock-screen scenes with media off and the extension turns audio
and media off again after applying the configuration, so a desktop Scene that uses
now-playing does not keep that feed on the lock screen.

"Enabled" is not claimed optimistically: it requires the system extension to
acknowledge a rendered frame. Every snapshot refreshes the service, so refreshes
arrive while that frame is awaited; one that interrupts the wait neither claims
Enabled nor publishes the activation again, but waits on for the same revision until
the original deadline (35 seconds), and only a confirmed activation saves the setting
for the next launch. The extension answers macOS only once that frame exists, and
WallpaperAgent abandons an extension that has not answered after about 31 seconds
(observed on macOS 27.2), so a scene must reach its first frame well inside that; see
[startup costs](../testing/runtime-regressions.md#startup-and-staging-buffers).

## Use wallpaper as screen saver

Enable **Settings → General → Screen saver → Use wallpaper as screen saver**. Each
display follows its applied wallpaper and committed properties, including scene,
video, web and still-image/pixiv projects. Choosing the native desktop video backend
does not exclude a video from native presentation.

This control owns only the system's **Idle** selection. **Animate lock screen** owns
**Desktop**; either can be enabled or disabled without changing the other's
selection, and the screen saver does not require the lock-screen switch. macOS still
controls idle timing, password requirements and dismissal; the app changes none of
those settings.

### Global overrides

macOS can keep all-displays overrides, including its default
screen saver, which take precedence over individual display choices. Enabling either
mode journals and removes only that mode's global override. A combined global choice
becomes Desktop-only for the screen saver or Idle-only for lock-screen animation;
enabling both removes the global override until restoration.

### Linked default provider

The built-in `default` provider can link desktop and
screen saver into one choice, globally or for a display. The app separates that
choice while either mode is active and preserves the other mode. Disabling, quitting,
or recovering after a crash restores the original linked configuration, including
inherited display settings; later changes made in System Settings are preserved
instead of relinked over. Other linked providers are unsupported and prevent
activation: the app reports the conflict instead of overwriting those choices.

### Complete display overrides

New display overrides, including those inside
Spaces, contain both the Desktop and Idle choices even when only one mode is enabled;
the unselected one comes from the inherited system selection or its restoration
journal. macOS rejects the entire wallpaper store if an `individual` override omits
either field, and a lock-screen-only override with no Idle field prevents the renderer
from starting. Temporary overrides return to inheritance on disable or recovery,
unless a later external choice needs to be kept.

### Selected is not rendering

"Selected" means the native choice was committed, not
that a screen saver has started: macOS may acquire an Idle-only surface only when it
starts the screen saver. A later renderer failure is shown beside the setting, and
restoration preserves choices changed elsewhere. If both modes are requested and the
lock-screen frame acknowledgement times out, only Desktop is restored; the app
publishes a new Idle-only revision and keeps the screen saver selected, also when
restoring saved preferences after an update or relaunch. The lock-screen error stays
visible without turning off a previously saved lock-screen preference. Automatic
updates keep the screen saver's wallpapers and pause state current but do not retry
the failed lock screen; its **Retry** action, or explicitly enabling its switch,
starts a new attempt, and late reports for the abandoned revision cannot overwrite
the screen saver's state. Retry preserves the last committed display mapping, and
turning the screen saver off restores its Idle choice immediately even if a display
UUID is temporarily unavailable during wake.

Both modes share the publisher and extension. Configuration-loading errors,
unresolved extension conflicts, reported renderer failures, and failed publication or
restoration can roll back both selections.

### Web and still wallpapers

Web and still wallpapers use a live WebKit layer tree, not a recorded video or a
periodic screenshot. Only their staged project and referenced imports are granted file
access. Audio, media integration, camera/microphone/display capture, interaction and
author dialogs are disabled. Pause freezes page execution and retains the compositor
tree; it does not resume playback the user paused. Web projects remain unsupported for
**Animate lock screen**; that combination is reported as not applicable.

## Caveats

- **Follow desktop Space** and animated lock-screen wallpaper require different
  Desktop ownership. Settings prevents enabling both for an active independent
  display; choose another automatic mode or turn animated lock-screen wallpaper off.
  Screen-saver-only mode can still use the currently applied content. See
  [Space-based wallpaper choices](spaces.md).
- It requires macOS 26 or later. On earlier releases the app does not start the
  service, Settings reports "Requires macOS 26 or later", and the extension refuses
  the system's connection: the private protocol it speaks has only been verified on
  macOS 26 and 27.
- It uses private macOS wallpaper APIs and wallpaper-store formats that may change;
  it may stop working after an OS update, and rendering is not guaranteed on every
  macOS release.
- Lock-screen animation replaces Desktop; screen-saver playback replaces Idle.
  Selection changes reload the wallpaper service, and unsupported per-display
  configurations are rejected rather than converted destructively.
- Playback respects the pause and battery settings. The lock screen covering the
  desktop does not pause it.

## When activation fails

If the renderer fails, or misses the extension's own 30-second first-frame deadline,
the extension writes the reason to its readiness file and the status row shows it.
Configuration-loading failures and incompatible extension copies produce a specific
error without waiting for the timeout: the app publishes `activation-request.json`
alongside the manifest and the extension answers in `extension-status.json` with the
activation revision, its bundle path, supported configuration version and any loading
error. Reports for an earlier revision are ignored, and a successful configuration
report is not frame readiness. For older extensions that cannot send this report, a
timed-out activation checks the current user's running extension paths and identifies
a different app copy when one is found; otherwise the generic "macOS did not load the
lock-screen renderer" message means no matching frame acknowledgement arrived.

The extension keeps a bounded log at
`~/Library/Application Support/WallpaperMachine/LockScreenExchange/extension.log`
(included in the [diagnostics report](diagnostics.md#diagnostics-report)). The app and
extension exchange files only in that directory, never through the extension's
sandbox container, so macOS does not ask the app for access to another app's data;
the extension removes files earlier releases left in that container. Startup and
first-frame failures stop the surface and invalidate its context rather than leaving
the last backing frame hosted as a successful replacement. A retry with the same
wallpaper identity creates a new generation, a healthy same-identity update keeps its
context, and completion or readiness callbacks from an older generation cannot remove
or acknowledge its replacement.

### App copies and registration

Every copy of the app on disk can register the same
extension identifier, including Debug builds and worktrees. Before activating either
native mode, WallpaperMachine reconciles registrations to the **currently running
app**: it validates its bundled renderer, lists all versions and physical copies with
`pluginkit -m -A -D -v -i app.wallpapermachine.wallpaper-extension`, registers its own
app and extension, unregisters other copies of the same app from LaunchServices and
PlugInKit, then reads the registry again to confirm only its own extension remains.
An already correct registration is left alone. App bundles, worktrees and build
output are preserved, so Release and Debug copies can stay on disk. A missing or
invalid current renderer stops activation, an unrelated bundle occupying an old
registration's path is never unregistered, and failed discovery never authorizes
cleanup.

Registration commands run off the UI thread with cancellation and a ten-second
deadline each. They do not change extension enable/disable elections, reset the
system registry, install apps or restart app copies. Snapshot refreshes share an
in-progress attempt (neither restarting it nor resetting the automatic recovery
limit), and changing a native-mode switch or shutting down cancels pending
preparation before it can publish. Registration alone does not establish playback:
activation still waits for the matching first-frame acknowledgement.

macOS can rediscover a copy after a build or launch, so unregistering it is not a
permanent exclusion. If a current diagnostic (or a legacy timeout's process-path check)
identifies another copy, the app restores its owned selections and makes one fresh
activation attempt with a new revision, repeating registration repair. If that also
fails, it restores the selections and shows **Retry**; close other running copies
before retrying. Ordinary two-second refreshes do not rewrite registration. Startup
logs include the extension bundle path and configuration version, because checking
only the identifier does not prove which copy macOS loaded.

### Idle exit

The extension exits 30 seconds after its last wallpaper-service
connection closes, provided no lock-screen, screen-saver or preview surface is alive;
a new connection or surface in that window keeps it. Without this, RunningBoard hands
an already-running extension process to WallpaperAgent even after macOS has
registered another copy (an update or another build). That process never receives the
new connection, and WallpaperAgent processes requests one at a time, so each System
Settings query stalls for about 30 seconds while wallpaper choices, the lock screen
and the screen saver wait behind it. A process from an older build that lingers can be
cleared by quitting it (`pkill -x WallpaperMachineExtension`) or logging out; macOS
starts the registered copy on the next request.

## Turning it off

Disabling either control restores only its still-owned selections. Quitting restores
both. Wallpaper and screen-saver changes made elsewhere are preserved.

If the native provider replaced a desktop poster, quit restores the native selection
first, then waits for WallpaperAgent's asynchronous reload and restores the poster's
saved original (poster ownership and the quit wait are described in
[desktop picture](desktop-picture.md#quitting)).
If restoration still fails after the wait, quit is cancelled and the error is exposed
in the menu bar (and native-feature status) so the user can retry. A failed activation
also restores native selections, but resumes live desktop playback afterward.

## Background checks and recovery

The service keeps one two-second monitor while a mode can still refresh safely,
recovery is complete, and shutdown has not begun. Busy refreshes keep the timer but
skip its work; an active request with no wallpapers still checks for a later
wallpaper; disabling both modes or shutting down cancels the timer immediately. A
shared error stops automatic monitoring until an explicit retry or another existing
refresh path succeeds. A lock-screen-only acknowledgement timeout does not stop
monitoring the retained screen saver, and those checks never restart the failed
lock-screen attempt; disabling the screen saver in that state stops the monitor until
either mode is explicitly reactivated. A pending display-identity lookup does not
clear an error and does not by itself start the monitor; with no error, the same timer
retries an unchanged scene set when the identity resolves.

A library refresh, explicit wallpaper reload or managed-asset change invalidates the
content check even when project paths and options stayed identical. The publisher
recalculates its asset fingerprints: changed bytes produce a new immutable
publication, while identical scene records keep the current revision and do not
reload the extension.

Repeated checks do not rewrite an unchanged recovery journal. New Spaces, choices made
in System Settings and wallpaper-service reloads all rewrite the system wallpaper
store, so each check compares only the store file's identity (device, inode, size,
modification and change times) and rereads the store only after one of them moves;
unchanged inputs also skip the compatibility check. A revision-only store update may
still need a service reload. The recovery union is persisted before the store changes
and pruned only after a successful reload; failed writes, reloads or journal removal
keep it for retry, and a malformed saved linked or inherited baseline fails recovery
before the store changes or the journal is removed.

macOS copies the extension's selection into the fallbacks it reloads (`SystemDefault`
and each Space's `Default`), and a Space created while the feature is on, a new
desktop or a full-screen app's, starts from those copies, so the live store has no
native choice left to restore it to. Such a Space is taken over like any other, with
originals taken from the journaled originals of those fallbacks, and restored to them
when the feature turns off. A Space created after the last check, just before the
feature turns off, was never journaled; turning off still restores its Default and the
journaled displays' nodes the same way, and keeps the journal for a retry if nothing
native is left to restore them to.

## Storage

Native wallpaper assets are isolated copies, using APFS clones where available, and
still require additional disk space. Scene and video wallpapers publish the assets
they reference as immutable `revisions/<fingerprint>/` trees in the exchange
directory (see [User-selected files](user-files.md)
for chosen files); web projects receive a separate read-grant root containing only
that project's referenced managed files.

## Verification

The offscreen suites (service, selection journal, extension registration, frame
backing, presentation authority, and the screen saver's native-context/WebKit
surface) are inventoried under *Lock screen* in [coverage](../testing/coverage.md).
They never mutate LaunchServices or PlugInKit and select no real wallpaper. Real idle
transitions, password UI, multi-monitor compositor delivery, sleep/wake visuals, live
registration repair and macOS choosing the intended extension still require an
authorized desktop check.
