# Lock screen and screen saver (experimental)

The app can animate the macOS lock screen and use applied wallpapers as the
screen saver. Both choices are off by default and require macOS 26 or later.

## Enabling it

Apply a video or live scene to a display, then enable **Settings -> General ->
Animate lock screen**, or the same switch on the welcome guide's Preferences
page (it applies at once there too; the guide's **Skip** turns it back to what it
was when the guide opened). A status row next to the Settings switch reports the
current state, and a **Retry** action appears when activation failed.

This uses a sandboxed native wallpaper extension — the
[`Extension/`](../../Extension) ExtensionKit target — rather than drawing an
ordinary app window over the login UI. While it is active the native desktop
remains a still frame, while the existing desktop renderer keeps playing.
That still frame is what Mission Control shows, so an unlocked lock-screen
surface keeps animating for 15 seconds after its first frame
(`WallpaperPresentationAuthority.desktopSettleBudget`) rather than holding an
intro's opening (often black) or a setting before it has faded in. A new
wallpaper or changed setting replaces the renderer and settles again; the
periodic Mission Control update in Settings does not apply in this mode.
Once it has settled it pauses its
renderer while retaining scene state, textures and device allocations, and
reads the held frame back for snapshots and the backing below. A
readback frame is committed beneath the nonopaque Metal layer before readiness
is acknowledged, with implicit animations disabled. It supplies real wallpaper
pixels when a drawable is not yet available or is reclaimed across sleep;
later drawables cover it without a timed fade or a wait for scanout. The image
retains the snapshot IOSurface without copying its bitmap. Scene replacement
keeps this backing until a new frame arrives; clearing the configuration or
failing to start the replacement drops it. Display sleep and host suspension
pause rather than unload it. Locking or waking resumes that same renderer only once the display
is awake, the host is active and user/power policy permits playback.

This avoids replacing the live surface with an old static poster and loading
the scene again after the display lights up. It uses more resident memory than
the former poster-only idle state, but does not continuously render while
paused. Resolution, frame rate and effects are unchanged. A newly acquired
surface or a changed wallpaper still needs an initial load; macOS can display
its own cached snapshot before it presents the extension. Real lock/wake timing
is OS-controlled and is not established by the offscreen regression checks.

Display-topology refreshes stage the next complete configuration before replacing
the previous one; they do not publish an empty manifest between a one-display
and two-display mapping. Staging does not clear the committed enabled state.
That flag stays until the new mapping's first frame is acknowledged, or until
deactivation rolls a real failure back to disabled. A lock-screen acknowledgement
timeout can retain an independently selected screen saver, as described below.
If Core Graphics temporarily cannot resolve a display
still named by the bridge during wake or a lid change, the committed manifest
and native selection stay untouched. That gap is not an error. While no earlier
error is pending, the existing status monitor retries the same scene set once
the topology settles; an unchanged mapping is reconciled and not republished.
A real earlier compatibility or restoration error is left in place, and the
monitor stays stopped until an explicit retry succeeds — the gap must not
clear that error just to resume polling. Removing the last wallpaper, disabling
both modes, and shared publication/renderer failure recovery still clear the
manifest. If macOS reacquires the same
WallpaperID on the same physical display at a different size or scale, the
extension keeps its remote context and backing frame while rebuilding the
renderer at the new pixel dimensions. Geometry stays local to that display;
the other display's context is not reused or resized.
The retained image fills the resized root layer, so a changed aspect ratio can
briefly stretch the old frame. Invalid dimensions are rejected before releasing
the existing renderer or changing its geometry. The extension leaves that context
intact locally; whether macOS retains it after an acquire error is unverified.

Lock-screen audio, audio input and media integration are disabled; see
[Audio response](audio-response.md) and
[Media integration](media-integration.md). The extension turns media off again
after `apply_config`, so a desktop Scene that uses now-playing does not keep
that feed on the lock screen.

"Enabled" is not claimed optimistically: it requires the system extension to
acknowledge a rendered frame. Every snapshot refreshes the service, so refreshes
arrive while that frame is awaited; one that interrupts the wait neither claims
Enabled nor publishes the activation again, but waits on for the same revision
until the original deadline, and only a confirmed activation saves the setting
for the next launch. The extension answers macOS only once that frame
exists, and WallpaperAgent abandons an extension that has not answered after
about 31 seconds (observed on macOS 27.2), so a scene must reach its first frame
well inside that; see
[startup costs](../testing/renderer.md#startup-and-staging-buffers).

## Use wallpaper as screen saver

Enable **Settings → General → Screen saver → Use wallpaper as screen saver**.
Each display follows its applied wallpaper and committed properties, including
scene, video, web and still-image/pixiv projects. Choosing the native desktop
video backend does not exclude a video from native presentation.

This control owns only the system's **Idle** selection. **Animate lock screen**
owns **Desktop**; either can be enabled or disabled without changing the other's
selection. The screen saver does not require the lock-screen switch. macOS still
controls idle timing, password requirements and dismissal; the app changes none
of those settings.

macOS can also keep all-displays overrides, including its default screen saver,
which take precedence over individual display choices. Enabling either mode
journals and removes only that mode's global override. A combined global choice
becomes Desktop-only for the screen saver or Idle-only for lock-screen animation;
enabling both removes the global override until restoration.

The built-in `default` provider can link desktop and screen saver into one
choice, globally or for a display. The app separates that choice while either
mode is active and preserves the other mode. Disabling, quitting, or recovering
after a crash restores the original linked configuration, including inherited
display settings. Later changes made in System Settings are preserved instead
of relinking over them. Other linked providers remain unsupported.

New display overrides, including those inside Spaces, contain both required
Desktop and Idle choices even when only one mode is enabled. The unselected
choice comes from the inherited system selection or its restoration journal.
macOS rejects the entire wallpaper store if an `individual` override omits
either field; a lock-screen-only override with no Idle field prevents the
renderer from starting. Temporary overrides return to inheritance on disable
or recovery, unless a later external choice needs to be kept.

“Selected” means the native choice was committed, not that a screen saver has
already started rendering. macOS may acquire an Idle-only surface only when it
starts the screen saver. A later renderer failure is shown beside the setting,
and restoration preserves choices changed elsewhere. If both modes are requested
and the lock-screen frame acknowledgement times out, only Desktop is restored;
the app publishes a new Idle-only revision and keeps the screen saver selected.
This also applies when restoring saved preferences after an update or relaunch:
the user need not turn off the lock-screen switch to retain the screen saver.
The lock-screen error remains visible without turning off a previously saved
lock-screen preference. Automatic updates keep the screen saver's wallpapers and
pause state current, but do not retry the failed lock screen. Its **Retry** action
or explicitly enabling its switch starts a new lock-screen attempt. Late reports
for the abandoned revision cannot overwrite the screen saver's current state.
Retry preserves the last committed display mapping. If a display UUID is temporarily
unavailable during wake, turning the screen saver off still restores its Idle choice
immediately rather than waiting for that display lookup to recover.

Both modes still share the publisher and extension. Configuration-loading errors,
unresolved extension conflicts, reported renderer failures, and failed publication
or restoration can roll back both selections. Retaining the Idle selection after
a lock-screen timeout does not establish that macOS has started rendering it.

Web and still wallpapers use a live WebKit layer tree, not a recorded video or a
periodic screenshot. Only their staged project and referenced imports are granted
file access. Audio, media integration, camera/microphone/display capture,
interaction and author dialogs are disabled. Pause freezes page execution and
retains the compositor tree; it does not resume playback the user paused.
Web projects remain unsupported for **Animate lock screen**.

## Caveats

- **Follow desktop Space** and animated lock-screen wallpaper currently require
  different Desktop ownership. Settings prevents enabling both for an active
  independent display; choose another automatic mode or turn animated lock-screen
  wallpaper off. Screen-saver-only mode can still use the currently applied content.
  See [Space-based wallpaper choices](spaces.md).

- It requires macOS 26 or later. On earlier releases the app does not start the
  service, Settings reports "Requires macOS 26 or later", and the extension
  refuses the system's connection: the private protocol it speaks has only been
  verified on macOS 26 and 27.

- Lock-screen animation uses private macOS wallpaper APIs and wallpaper-store
  formats that may change; it may stop working after an OS update, and rendering
  is not guaranteed on every macOS release.
- Lock-screen animation replaces Desktop; screen-saver playback replaces Idle.
  Selection changes reload the wallpaper service. Unsupported per-display
  configurations are rejected rather than converted destructively.
- Linked providers other than the built-in `default` provider can prevent
  activation. The app reports the conflict instead of overwriting those choices.
- Playback respects the pause and battery settings. The lock screen covering the
  desktop does not pause it.

## When activation fails

If the renderer fails, or misses the extension's own 30-second first-frame
deadline, the extension writes the reason to its readiness file and the status
row shows it. Configuration-loading failures and incompatible extension copies
also produce a specific error, without waiting for the first-frame timeout.
The app publishes `activation-request.json` alongside the manifest; the extension
answers in `extension-status.json` with the activation revision, its bundle path,
supported configuration version and any loading error. Reports for an earlier
revision are ignored. A successful configuration report is not frame readiness.
For older extensions that cannot send this report, a timed-out activation checks
the current user's running extension paths and identifies a different app copy
when one is found. Otherwise the generic "macOS did not load the lock-screen
renderer" message means no matching frame acknowledgement arrived.
The extension keeps a bounded log at
`~/Library/Application Support/WallpaperMachine/LockScreenExchange/extension.log`.
The app and extension exchange files only there, never through the extension's
sandbox container, so macOS does not ask the app for access to another app's
data. Files earlier releases left in that container are removed by the extension.
Startup and first-frame failures stop the surface and invalidate its context;
they do not leave the last backing frame hosted as a successful replacement.
The controller removes failed acquisitions from its reusable surfaces. A retry
with the same wallpaper identity creates a new generation, while a healthy
same-identity update keeps its context. Completion and readiness callbacks from
an older generation cannot remove or acknowledge its replacement.

Every copy of the app on disk can register the same extension identifier,
including Debug builds and worktrees. Before activating either native mode,
WallpaperMachine now reconciles registrations to the **currently running app**.
It validates its bundled renderer, lists all versions and physical copies with
`pluginkit -m -A -D -v -i app.wallpapermachine.wallpaper-extension`, registers its
own app and extension, and unregisters other copies of the same app from
LaunchServices and PlugInKit. It then reads the registry again to confirm that
only its own extension remains. An already correct registration is left alone.
The process preserves app bundles, worktrees and build output; developers can
keep Release and Debug copies on disk. A missing or invalid current renderer
stops activation; an unrelated bundle occupying an old registration's path is
never unregistered. Failed discovery never authorizes registration cleanup.

Registration commands run off the UI thread with cancellation and a ten-second
deadline per command. They do not change extension enable/disable elections,
reset the system registry, install apps or restart app copies. The ordinary
native-selection flow still reloads the wallpaper service after publication.
Snapshot refreshes share an in-progress registration attempt; they neither
restart it nor reset the automatic recovery limit. Changing a native-mode
switch or shutting down cancels the pending preparation before it can publish.
Registration alone does not establish playback: lock-screen activation still
waits for the matching first-frame acknowledgement.

macOS can rediscover a copy after a build or launch; unregistering it is not a
permanent exclusion. If a current diagnostic (or a legacy timeout's process-path
check) identifies another copy, the app restores its owned selections and makes
one fresh activation attempt, repeating registration repair with a new revision.
If that also fails, it restores the selections and shows **Retry**. Close other
running copies before retrying in that case. Ordinary two-second refreshes do
not continually rewrite registration. Startup logs include the extension bundle
path and configuration version; checking only its identifier does not prove
which copy macOS actually loaded.

The extension exits 30 seconds after its last wallpaper-service connection
closes, provided no lock-screen, screen-saver or preview surface is alive; a new
connection or surface in that window keeps it. RunningBoard otherwise hands an
already-running extension process to WallpaperAgent even after macOS has
registered another copy (an update or another build). That process never
receives the new connection, and WallpaperAgent processes requests one at a
time, so each System Settings query then stalls for about 30 seconds while
wallpaper choices, the lock screen and the screen saver wait behind it: the lock
screen and screen saver stayed black and new wallpapers applied only minutes
later. A process from a build before 2026-10-12 can still linger after another
copy is registered; quitting it (`pkill -x WallpaperMachineExtension`) or logging
out clears it, since macOS starts the registered copy on the next request.

## Turning it off

Disabling either control restores only its still-owned selections. Quitting
restores both. Wallpaper and screen-saver changes made elsewhere are preserved.

If the native provider replaced a desktop poster, quit restores the native
selection first, then waits for WallpaperAgent's asynchronous reload and restores
the poster's saved original. The poster journal and image stay available while the
native store still references them. Quit retries for up to about five seconds;
if restoration still fails, it cancels termination and exposes the error in the
menu bar (and native-feature status) so the user can retry. A failed activation
also restores native selections, but resumes live desktop playback afterward.

## Background checks and recovery

The service keeps one two-second monitor while a mode can still refresh safely,
recovery is complete, and shutdown has not begun. Busy refreshes keep that timer
but skip its work. An active request with no wallpapers still checks for a later
wallpaper; disabling both modes or shutting down cancels the timer immediately.
A shared error stops automatic monitoring until an explicit retry or another
existing refresh path succeeds. A lock-screen-only acknowledgement timeout does
not stop monitoring the retained screen saver, and those checks never restart
the failed lock-screen attempt. Disabling the screen saver in that state stops
the monitor until either mode is explicitly reactivated. A pending display-identity
lookup does not clear an error and does not by itself start the monitor. With no
error, the same timer retries an unchanged scene set when the identity resolves.

A library refresh, explicit wallpaper reload or managed-asset change invalidates
the content check even when project paths and options stayed identical. The
publisher recalculates its asset fingerprints; changed bytes produce a new
immutable publication, while identical scene records keep the current revision
and do not reload the extension. No intermediate empty assignment is required.

Recovery entries represent the last successful journal commit. Repeated checks
do not rewrite an unchanged journal: saved baselines keep their journaled bytes,
because encoding an equal property list again can order its keys differently.
A check that changed nothing is not repeated until its displays or revision
change or the system store is written again. New Spaces, choices made in System
Settings and wallpaper-service reloads all rewrite the store, so the check
compares only the store file's inode, size, and modification and change times;
it rereads the store only after one of them moves. Before 2026-10-10 every
two-second check reread the store and rewrote the journal: 8–12 ms of
main-thread CPU with 45 Spaces. Unchanged inputs skip the compatibility check.
A revision-only store update may still require a wallpaper-service reload
without rewriting the journal. The recovery union is persisted before changing
the store, and pruned only after a successful reload; failed writes, reloads or
journal removal retain recovery information for retry. A malformed saved linked
or inherited baseline fails recovery before changing the store or removing the
journal.

macOS copies the extension's selection into the fallbacks it reloads
(`SystemDefault` and each Space's `Default`), and a Space created while the
feature is on, a new desktop or a full-screen app's, starts from those copies,
so the live store has no native choice left to restore it to. Such a Space is
taken over like any other, with originals taken from the journaled originals
of those fallbacks, and restored to them when the feature turns off. A Space
created after the last check, just before the feature turns off, was never
journaled; turning off still restores its Default and the journaled displays'
nodes the same way, and keeps the journal for a retry if nothing native is left
to restore them to. Before 2026-09-28 the first check after a new Space failed
with "no restoration journal or surviving system fallback", turned the feature
off and left that Space pointing at the extension.

## Storage

Native wallpaper assets are isolated copies, using APFS clones where available.
They still require additional disk space. Web projects receive a separate
read-grant root containing only that project's referenced managed files.

## Verification

See [Testing](../testing/README.md) for the exact tested behavior and visual
limitations, and the [verification log](../testing/verification-log.md) for
recorded runs.

The screen-saver implementation has offscreen native-context/WebKit and isolated
selection coverage. Real idle transitions, password UI, multi-monitor compositor
delivery, and sleep/wake visuals still require an authorized desktop check.

Back to the [project README](../../README.md).
