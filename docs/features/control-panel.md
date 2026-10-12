# Control panel

The app window is a bundled HTML/CSS/JS interface rendered by `WKWebView` from
[`WebUI/`](../../WebUI), served over the app-private `mwe-ui:` scheme and driven
by [`App/Views/ControlPanel/`](../../App/Views/ControlPanel). Menus, windows,
file pickers and security confirmations stay native — the web layer never draws
a system dialog and renderer content is never loaded into the web view.

## Language

The app ships in English, Simplified Chinese (简体中文), Traditional Chinese
(繁體中文) and Japanese (日本語), including navigation,
filters, wallpaper options, download/sign-in guidance, settings, accessibility
labels, menus and dialogs. **Settings → General → Language** offers **System
(Auto)** and every shipped language, each listed under its own name:

- **System (Auto)** (default) follows the macOS language list as macOS matches
  it to the app: `zh-CN`, `zh` and `zh-Hans-TW` reach Simplified Chinese;
  `zh-TW`, `zh-HK` and `zh-Hant` reach Traditional Chinese; `ja` reaches
  Japanese; any other language falls back to English. A per-app
  choice made in **System Settings → General → Language & Region →
  Applications** is honoured the same way.
- Choosing a language switches the panel immediately, without a reload, and is
  remembered. The **Import → Choose files** picker also follows immediately,
  including a language chosen in the welcome guide. When its language differs
  from the app's launch language, it opens as a separate native picker window;
  otherwise it stays an attached sheet. Native menus and other dialogs use the
  new language after fully quitting and reopening the app, because macOS fixes
  a process's localization at launch. Returning to **System (Auto)** hands the
  choice back to macOS.

Steam's own language is not involved. Unsupported languages and missing keys
fall back to English. Wallpaper titles, descriptions, creator names, custom
property labels and upstream diagnostic details remain as supplied. The panel
translates its own labels and recognized Wallpaper Engine UI tokens, not authored
prose (see [Properties](#properties)). Steam filter values and bridge
action identifiers remain unchanged when labels are translated. How the layers
fit together and how to add a language: [Localization](../localization.md).

## Layout

| Region | Contents |
| --- | --- |
| Top tabs | **Discover**, **pixiv**, **Installed**, **Settings** |
| Top bar | Sits in the window's title-bar strip beside the traffic lights: tabs on the left, the product mark and name centered, target-display picker and a downloads button (only while there is download activity) on the right. The side groups never shrink below their content, so a long display name nudges the brand off-center rather than under the controls; in windows up to 840px wide the name hides and only the mark stays. The renderer's own repository is linked from Settings → About. Its background drags the window and follows the system double-click action |
| Browser column | Filter button, search field, sort menu, tile grid, result summary, Workshop pagination with an editable page number. On Discover a page is one Steam page of 30 square tiles (at most 1,000 pages); the grid shows as many columns as fit, never fewer than three, and scrolls the rest |
| Left sidebar | Filters on every library page, mirroring Wallpaper Engine's sidebar: Show only, Type, Age rating, Resolution and Tags tick boxes on Discover; the same boxes minus Resolution (plus Favorites and Active in Show only) on Installed, applied to the library in the page; the pixiv account and pixiv's own filters on pixiv. Compact width; the toolbar's Filter button opens and closes it, and that choice is remembered per page across launches |
| Inspector | Preview, title, kind, creator, actions, tags, and the selected wallpaper's options and properties. Its width is a function of the window width alone and cannot be dragged: 260px at the 760px minimum, `15vw + 146px` in between (290px at 960px, 386px at 1600px) and 420px from about 1830px on, the same on Discover and Installed. Nothing is stored, so a given window size always yields the same layout. Inside, the panel adapts to its own width: past 360px the insets widen and a display's scale factor and frame rate share a row |
| Activity bar | Global pause/resume, import activity and unseen results, download progress (not a playback timeline). Playback remains available when any display has an assignment, even if the target display is empty; with no assignments it is disabled and reports **No wallpaper playing**. Long summaries truncate visually but keep their full accessible names |

In full-screen mode and either Split View tile, the top bar stays in the content
area below macOS's native chrome, and the empty toolbar used to align the
windowed traffic lights is hidden. Exiting restores the unified title-bar layout
without changing the restored window bounds. The layout switches only after a
successful transition, so a canceled entry or exit leaves the current layout intact.

The visual direction combines Wallpaper Engine's image-first gallery, filtering
and right-hand property workflow with macOS-oriented window chrome and controls;
it does not reproduce Windows window decorations or the Windows button skin.
The [official Windows walkthrough](https://help.wallpaperengine.io/en/mobile/pairing.html)
is the composition reference; the [macOS design guidance](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
informs the restrained system typography, comfortable density and familiar
keyboard/pointer behavior. Navigation uses quiet, rounded selected controls in
the unified title bar. Filled accent color is reserved for primary actions,
selection and status, rather than making Filter compete with Apply or Download.
Light/dark mode, surface tone and custom accent preferences continue to apply.
The inspector preview is capped at 220px, or 180px in windows up to 640px tall,
leaving more room for the title, actions and properties without changing the
inspector's own width.
Selection uses an outer accent ring with a surface-coloured gap so blue artwork
does not hide it. At the narrowest browser width captions remain 12px on one
line and hide the type sublabel; narrow filter sidebars omit decorative glyphs
rather than shrinking the checkbox labels. Installed's sidebar grows as needed
to keep **Active on target display** on one line, including its translations,
without shrinking or truncating the label.

Wallpapers appear as square, image-first tiles with a transparent title overlay.
Discover tiles show cached still thumbnails first and then, for tiles on
screen, play Steam's animated preview once it loads, retaining the still as a
loading/error fallback (see
[Workshop downloads](workshop-downloads.md#tile-thumbnails)). Authored black or
transparent animation frames are shown unchanged, even at the start; the panel
never samples their pixels to substitute the still, because synchronous canvas
readback can freeze WebKit. Failed animated images are removed, revealing the
cached still. Animations stop
when the grid leaves Discover, so an installed copy of the same wallpaper shows
its library preview on Installed.
Tiles keep their size on hover or visible keyboard focus; they rise above their
neighbours with a shadow instead of enlarging.
Both tabs fill the grid with as many columns as the browser column can hold at a
preferred tile size that shrinks with the column, and never fewer than three,
so a narrower window shows smaller tiles and more of them rather than fewer,
larger ones; the grid scrolls vertically for whatever rows that takes. The window
itself never shrinks below a 760×560 content area (capped by the visible screen
on small displays): `ControlPanelWindow` owns that floor and `AppDelegate`
enforces it in `windowWillResize`, because the SwiftUI hosting controller
resets `contentMinSize` once it attaches.
Arrow keys, `Home` and `End` move focus across the grid; `Escape` closes an open
popover or leaves selection mode.

The sort menu and its actions wrap as one group after Filter and search. At a
narrow browser width Installed's Import becomes a named icon button; Select/Done
keeps its text. Routine controls use a 32px minimum, compact actions 28px, while
the welcome guide's primary buttons remain 36px. Errors keep their original
details and Dismiss; Reconnect is offered only before the first snapshot or
when the native bridge is unavailable, not for an ordinary operation failure.

## First run

The first time the panel opens, a guide covers the whole window, top bar
included (`WebUI/welcome.js` + `welcome.css`; `#welcome` is fixed-position
over the app and inherits its light/dark surfaces; its top strip stands in for
the title bar, draggable and clear of the traffic lights). It is
a page, not a modal dialog; the download dialog can still open over it for an
unrelated job. Background app regions are inert while the guide is open; closing
it restores their prior availability. The body scrolls independently of the
footer, which stays reachable at the 760×560 minimum. All six step buttons keep
accessible names even when their visible labels are hidden. They allow free
jumping except while language, appearance, the lock screen, performance or
preferences are being committed; later pages have **Back**, and decision pages
have **Skip**:

1. **Language & appearance.** Radio tiles for the language (**System (Auto)**
   plus every shipped language under its own name) and the appearance mode
   (**System (Auto)**, **Light**, **Dark**, each with a drawn miniature). A
   choice applies at once through the `languageSetting` / `themeSetting`
   actions, so the page repaints in the chosen language and theme. **Skip**
   puts back whatever was in force when the guide opened and moves on.
   The automatic language option spans the full row above four equal language
   tiles; at 640px or narrower, those tiles form two complete rows of two.
   Each radio group has one Tab stop; arrow keys, Home and End choose an enabled
   option. A completed language/theme write restores lost radio focus without
   taking focus back from another control.
2. **Steam.** Explains in plain words that browsing is free and that downloading
   needs a Steam account that owns Wallpaper Engine, with **Create a Steam
   account** (`store.steampowered.com/join/`) and **Buy Wallpaper Engine** (the
   store page) beside that explanation. The form takes the account name (login
   name, not profile name), the password (with a show/hide toggle) and **Keep me
   signed in on this Mac** (on by default). **Sign in** sends only the account
   name and the remember choice (`steamSignIn`); the password is held in the
   page until Steam's own password prompt arrives on the sign-in job and is then
   submitted through `downloadInput` exactly once. It is never part of a snapshot,
   the login-start payload or DOM markup. Showing the password does not make a
   subsequent snapshot erase it. Without SteamCMD the button
   reads **Install SteamCMD and sign in** and the page installs it first
   (`setupInstall`, with the Gatekeeper approval and locate-a-copy paths when
   they apply). Steam Guard (mobile approval, authenticator or emailed code)
   is shown with the same guides as the download dialog; **Cancel** stops the
   session. After sign-in, the guide checks Wallpaper Engine ownership and shows
   **Signed in as …** with the result and **Use a different account** (`logOutSteam`).
   Non-owners see **Buy Wallpaper Engine** and an explanation that Pixiv downloads,
   Workshop browsing, and viewing existing wallpapers remain available. An
   inconclusive result is labeled unconfirmed. Both offer **Check ownership again**
   and allow **Continue**; saved accounts from an earlier run can also be checked.
   **Skip for now** (or **Skip and cancel sign-in** while a job or
   setup request is pending) leaves Steam for the first download to ask about.
   New prompts hand focus to their input when the previous control disappears;
   ordinary progress does not interrupt typing. A Steam Guard request arriving
   on another page marks the Steam step with a shield without changing pages.
   See [Steam sign-in](workshop-downloads.md#steam-sign-in) for the session itself.
3. **Performance.** Radio tiles for the **Low**, **Medium** and **High** quality
   presets (the same pairs as [Settings → Performance](performance.md#quality),
   shared through `settings.js`), then the **Frame rate limit** slider, whose
   top reads **No limit**: each display then runs at its own rate, up to 60 fps
   unless a higher rate was chosen for it (see
   [Default per-display frame rate](performance.md#default-per-display-frame-rate)).
   High, no limit at full render scale, is selected on a fresh install. A preset fills
   both drafts; moving the slider changes only the limit, and a pair matching
   no preset leaves every tile unchecked with a **Custom** note. They are
   drafts: **Continue** sends only what changed as `setting` / `renderScale`
   and `setting` / `frameRateCap`, **Skip** discards them.
4. **Preferences.** Launch at login and Keep windows in place when clicking the
   wallpaper are switches. **On battery** is a menu: Keep running, Reduced
   quality, or Pause. They are drafts: **Continue** commits only the ones that
   changed (`setting` actions, including `batteryMode`), **Skip** discards them.
   Launch at login is disabled with its reason while the app is outside
   Applications. Started at login, the app stays in the menu bar without
   opening the panel, unless this guide is unfinished or the renderer failed to
   start (`ControlPanelLaunch`). When renderer settings are unavailable the
   page says so and disables the controls.
   The last row, **Animate lock screen** (off by default, marked experimental),
   is not a draft: like Settings it sends `setting` / `lockScreenEnabled` at
   once, shows the native status while busy, is disabled when the integration
   is unavailable, and a refusal leaves the switch off with the reason on the
   page. **Skip** puts it back to the value it had when the guide opened.
   During a preference or lock-screen commit, Back, step navigation, Skip and
   Continue are all disabled so the guide cannot leave a partially submitted operation.
5. **Tips.** Three one-line tips (Discover, download then double-click to
   apply, one wallpaper per display) on one card, then a compatibility card:
   not every wallpaper works (videos usually play, scenes are experimental,
   Application wallpapers cannot run), failures are reported with the
   inspector's report button (shown inline by its glyph), and pull requests are
   welcome, with **Report an issue** (`state.repositoryURL` + `/issues`) and
   **Contribute on GitHub** (the repository) links.
6. **Start.** A recap of language, appearance and the actual Steam sign-in state.
   Pending jobs/setup requests offer **Finish sign-in**. Unsaved performance or
   preference drafts each add a cell with their count and **Review**, which
   returns to that page without discarding them. Closing does not auto-save the
   drafts.
   **Browse the Workshop** opens Discover, **Import wallpapers** opens the
   import popover on Installed, and **Start using the app** simply closes it.

Leaving the guide by any of the closing actions is stored natively
(`WebPanelController.welcomeSeenKey`, sent as the `welcomeSeen` action and
reported in every snapshot), so the guide is shown on its own exactly once per
Mac. **Settings → Library & Steam → Welcome guide → Show again** brings it
back from the first page; closing it then does not touch the stored flag. Every
link passes the same external-URL allowlist as every other link in the panel,
and the whole guide is translated with the rest of the UI. While the guide is
open the panel's document-level handlers stay out of `#welcome`; the guide owns
its own events, and the download dialog does not surface the sign-in job's
prompts (the guide answers them). A finished sign-in-only job is not listed as
a download.

## Tabs

- **Discover** browses the Steam Workshop. See
  [Workshop downloads](workshop-downloads.md).
- **pixiv** browses pixiv's illustration rankings and tag search in the same
  grid, sidebar and inspector, and saves a page of a work as a still wallpaper.
  See [pixiv](pixiv.md).
- **Installed** shows the local library.
- **Settings** replaces the browser with a sectioned native-feeling settings
  view. **Performance** is first and is the section Settings opens on, then
  General, Appearance, Displays, Library & Steam, Storage and About. Everyday
  categories lead the navigation; library, storage and product information are
  visually separated. **General** starts with the
  [Language](#language) picker, then startup/desktop (including the optional
  five-minute Mission Control picture update; see
  [architecture](../architecture.md#desktop-wallpaper-windows-and-private-api-handling)),
  keyboard shortcuts (see
  [automation](automation.md)) and lock-screen groups.
  It no longer has a pause-on-battery toggle; battery is one choice on
  Performance. **Performance** opens with a live energy readout for the app
  (grade, total, CPU and GPU, battery share, and the figure before and after
  the last quality change), then quality (presets, frame-rate limit, render
  scale) directly beneath it, then playback (occlusion, other-app audio,
  display sleep, battery, app rules). Video backend, scene controls and the
  experimental switches stay under **Advanced**. See
  [Performance settings](performance.md). The inspector of an installed
  wallpaper adds its measured energy grade once it has one; see
  [Per-wallpaper energy rating](performance.md#per-wallpaper-energy-rating).
  **About** leads with the app version, read from the bundle (`MARKETING_VERSION` in
  `project.yml`, the same value GitHub reports carry), and the Git revision.
  **Check for Updates** reads the latest
  GitHub Release, and download / restart-install happen only after confirmation.
  The application menu item **Check for Updates…** opens this section.
  **Storage** ends with **Troubleshooting**: Detailed logging and the diagnostics
  report export. See [Logs and diagnostics reports](diagnostics.md).

Settings use lightly bounded, keyed groups on the window's secondary surface,
with dividers between related rows rather than a separate card for every control.
Rows wrap within their available content width. Live backend, quality, power and
installation readouts use foreground text beneath muted captions, separate from
the saved preference controls. Unknown, preparing
and fallback results remain distinct. Explicit lock-screen unavailability
disables its switch; language and appearance remain usable if renderer settings
are unavailable. Snapshot updates preserve active drafts, selection, disclosures
and scrolling. About's update actions precede expanded release notes.

All Settings pages share 20px group insets, 16px row padding and 8px control
gaps. Notes have a relaxed line height, and action footers sit below one divider.
A footer directly following a row reuses that row's divider without an extra
blank band.
The shared scene resources card adds bottom padding after its download
explanation so the final line does not crowd the card edge.
When a page's content area is 480px wide or narrower, controls stack beneath
their labels rather than squeezing text beside buttons; switches remain inline
and diagnostic readouts retain their caption/value layout.

Storage's wallpaper-file folder, the wallpaper library and a downloaded SteamCMD
installation give paths the full available width, with Finder and other folder
actions below a divider. Performance's nested Advanced groups remain unboxed,
while display playlists and playback disclosures use the same row spacing as
the main pages.

Settings text is non-selectable throughout the navigation and content, including
version readouts, paths, color values, release notes and status/error messages.
Form controls retain their normal editing and keyboard behavior.

Settings disclosures use a heavier chevron in a 24px rounded, bordered indicator.
Closed sections use foreground ink; open sections use the theme's accent surface
and a downward chevron. Hover strengthens the indicator's surface and border.
The summary remains the native pointer/keyboard toggle, with visible focus;
reduced-motion preferences disable the indicator transition.

The panel's web view sets WebKit's inactive scheduling policy
(`WKPreferences.inactiveSchedulingPolicy = .suspend`). WebKit applies it when
it considers the view inactive. Minimized or app-hidden windows keep their page;
a snapshot skipped while hidden is delivered when revealed. Closing the window
(close button or Command-W) releases its hosting controller and web view instead
of retaining a hidden page. Reopening rebuilds the page on the last native
navigation section, using the existing library, playback and download stores.
Page-local scrolling, filters, disclosures and uncommitted input start fresh.
An active local import keeps the window hidden until its next close, so releasing
the page cannot cancel the import. Workshop downloads live in the retained store.
Discover releases animated preview sources when their tiles scroll offscreen,
the document hides, or the grid leaves Discover. Returning to a visible tile
loads its cached animation again. Preview readiness follows image load/error
events, not a polling timer or synchronous canvas pixel reads; an unresponsive
WebKit graphics backend must not trap the panel in repeated readback waits.

### After an update

On the first launch of a newer version, a separate, nonmodal **What’s New**
window shows the installed version and every release since the last announced
version, newest first. The window opens with a 760 × 720-point content area and
can resize down to 600 × 480 points without collapsing the notes viewport.
**English / 简体中文** tabs display one translation at a time for every release.
The initial tab follows the app’s effective language in Settings → General →
Language, including **System** matching. Simplified or Traditional Chinese uses
Simplified Chinese notes; English or Japanese uses English notes. This reads the
current app preference, not the bundle’s launch-time language. Switching tabs returns to the top of the
notes and does not change the app’s interface language. Notes come from the bundled
`CHANGELOG.md`, so they work offline and cannot accidentally describe a newer
remote release. Release generation and translation are owned by
[the release pipeline](../release.md#release-notes-and-the-changelog).

**Don’t show this window after updates** saves immediately and suppresses all
future automatic post-update windows. It does not disable update checks or hide
the release notes in Settings → About. Closing the window, including Command-W,
leaves WallpaperMachine running. Ordinary relaunches, fresh installs, downgrades
and returning to an already announced version do not show the window.

`WhatsNewStore` persists the highest announced/launched version and the opt-out
in the app’s preferences. Older builds did not record a version: on migration,
users who already completed or skipped the welcome guide see only the installed
release’s notes, without a fabricated previous-version number. The next update
has an exact baseline; a fresh installation records one without another window.
A missing installed-version entry is not marked as announced. `announcement`
returns nil without writing `WallpaperMachine.whatsNew.lastVersion`, and the
next launch runs the same check. That retry is intentional: recording the
version on a miss would consume the announcement, so a later bundle that
contains the notes would never show them. A fresh installation and the
permanent opt-out still record the version, because those launches are not
waiting for notes. The bundled history is strict: every `##` heading must be a
semantic version, so `## Unreleased` or a `##` line inside notes fails the
whole file and the window does not appear. Publishing rejects that file first.
`WhatsNewTests` covers skipped releases, migration, first launch, interrupted
presentation, downgrade/relaunch suppression, a missing current section that
must not consume a later announcement, bilingual history validation, rejection
of `## Unreleased` and headings inside notes, switching all release translations
and back, saved app-language precedence over system language and System matching,
and the checkbox’s persisted effect across subsequent versions.

## Thumbnail corner marks

Installed and Discover show status marks at the thumbnail's upper-left corner:

- A pink heart identifies a local favorite, including the same item when it
  appears in Discover. Use the heart button on an Installed tile (visible on
  hover or keyboard focus), or the inspector's favorite action, to toggle it.
  This is the app's saved favorite list, not Steam-account favorites.
- A green trophy identifies **Approved** wallpapers. Discover uses Steam's
  `Approved` tag. Installed reads `approved: true` or an `Approved` tag from the
  local `project.json`, off the snapshot thread; wallpapers without that local
  metadata have no trophy. The app does not fetch missing approval metadata for
  imported wallpapers.
- Discover also retains a check for items already in the library.

Multiple marks stack vertically. On Installed they move aside when the
multi-select check appears, and the Active badge sits alongside rather than
covering them. Tile accessibility labels announce the marks; overlay colors stay
readable against artwork in both light and dark appearance.

## Selection versus apply

Selecting a tile only selects it: the inspector updates and nothing changes on
screen. Activation is explicit.

- **Apply wallpaper** activates the selected wallpaper on the current target
  display; for the wallpaper already active there it reads **Reapply wallpaper**.
- Double-clicking a tile on the Installed tab activates it as well. Double-click
  does not close the window. On Discover, double-click downloads the tile (or
  applies it once it is in the library); see
  [Workshop downloads](workshop-downloads.md#one-decision-per-download).
- Apply is unavailable when the target display is disabled, is mirroring another
  display, or when the wallpaper kind cannot be rendered (Application or Unknown).
- Background display refreshes and automatic presentation/audio-policy updates
  wait for an in-flight Apply (and Apply waits for an update already running).
  Switching wallpapers therefore does not invalidate itself when its windows
  trigger a policy update. Explicit Play/Pause can still interrupt an Apply.
- A successful apply leaves the window open; it stays until the user closes it
  (close button or Command-W). **Settings -> General -> Hide window after
  applying a wallpaper** (off by default) hides the app after each successful
  apply instead, so the new wallpaper is visible; the choice is stored in the
  app's defaults, not the engine.

The inspector follows Wallpaper Engine's centered hierarchy: square preview,
title, creator (Discover), facts (type, size, subscribers), utility actions and tags. For
installed wallpapers, the circular play button overlapping the preview is
**Apply wallpaper** (or **Reapply wallpaper**); its accessible name and tooltip
identify the action. **Download** remains a full-width action on Discover.
The utility row holds **Show in Finder**, favorites and Trash on Installed,
or **View on Steam Workshop** on Discover. The inspector scrolls independently;
**Apply changes** and **Revert** stay visible in a fixed footer while editing.

Below the compatibility note, an installed wallpaper that can run (not
Application) shows **Not working? Report on GitHub**. It opens the repository's
new-issue form in the browser with the wallpaper's title, Workshop link or id,
type, app version and, while it is on screen, the backend drawing it (with the
renderer's fallback reason) pre-filled. When the panel saw this wallpaper fail
(its download, or the last attempt to apply it), an error notice takes the
link's place with **Report this problem on GitHub**, whose issue also carries
the error; an apply failure stays until an apply succeeds. Nothing is submitted
by the app; the user edits and sends the issue on GitHub. Neither is shown when
the snapshot carries no `https` repository URL.

### Live preview

An installed scene, video or Web wallpaper has **Preview wallpaper** in its
details. It opens one ordinary, resizable **Wallpaper Preview** window. Choosing
another preview replaces that window's content; it does not apply to a display,
change the panel's selection, consume a playback-history entry or save options.
The preview reads the current property draft, including text still being edited,
and the target display's scaling options. **Reload preview** reads them again.

The window has its own **Play/Pause**, sound toggle and reload control. Every
new preview, including reload, starts muted. Scene/video rendering is capped at
30 FPS and the effective lower limit when its inputs are read. Web pages receive
that FPS through the standard wallpaper host protocol; honoring it depends on
the page, so this is not a WebKit frame-rate guarantee. Hiding, covering or minimizing the
window, locking the session or sleeping the displays suspends it. Resuming
visibility preserves an explicit user pause. Closing the window cancels pending
preparation, removes file watchers and releases its renderer or WebKit page.
A superseded load cannot replace the newer preview. Load failures remain in the
window with their reason and a reload action; first-frame/page readiness has a
30-second budget while visible.

Scene and video previews use a private Compatibility renderer attached to the
window, independently of the desktop's renderer preference. Scene hover, buttons
and dragging are scoped to that view. Web previews reuse the wallpaper host
protocol in a separate, nonpersistent website data store and support ordinary
in-window interaction. File and directory properties use the existing managed
asset authorization and staging path. Preview storage is discarded when closed;
it is not the desktop page's localStorage or signed-in session.

Audio response and system media information are unavailable in preview and the
window says so. Page-initiated capture, dialogs, new windows and file pickers are
declined. A Web preview is refused if WebKit cannot establish whole-page mute.
Scene previews need the shared scene resources, just as desktop scenes do.
Per-wallpaper energy ratings exclude the interval while a preview is open.

`WallpaperPreviewSession` owns the loading and playback lifecycle;
`WallpaperPreviewLoader` validates the installed paths, manifest and inputs.
The bridge's read-only `wallpaper_preview` export keeps Web property scalar types
and never reconciles the desktop. `WallpaperPreviewWindowController` is created
only for an explicit preview action. Offscreen and fixture-level tests cover
these contracts; real window presentation remains a separate authorized check.

### Previous and recently used

The activity bar's **Previous wallpaper** returns the target display to its last
successfully applied wallpaper. Repeated presses continue backward instead of
alternating between two wallpapers. Missing or unsupported library entries are
skipped; a failed application leaves history intact. The menu bar, global
keyboard shortcuts and [automation](automation.md) offer the same command.

**Recently used** in the activity bar lists up to 50 distinct wallpapers used on
that display, newest use first, and applies one when chosen. The menu bar shows
the latest ten. **Clear history** clears only the target display's recent list
and back history. Neither action deletes wallpaper files. Successful automatic
playlist changes are included; reapplying an unchanged assignment adds nothing.

`WallpaperHistoryStore` saves per-display history in the
`WallpaperMachine.wallpaperHistory` preference. It survives relaunch, is pruned
when wallpapers are deleted in the app, and remains local to this Mac (it is not
included in backup packages). History records successful assignment and saving;
it does not certify every frame a wallpaper subsequently displays.

## First wallpaper support prompt

After a wallpaper downloaded through Discover or pixiv is successfully applied by
the user, the panel offers **Feeling good?** once. **Star on GitHub** opens the
project repository; **Become a Supporter** opens the website's pricing page
(the Chinese page for either Chinese app language). Both require a click.
**Not now**, the close button and Escape dismiss the offer.

The download must have finished installing, and applying must have succeeded and
reported a new active display assignment. Downloads alone, local imports, failed
applies, startup restoration, playlist changes, automatic update reloads and
reapplying an already active wallpaper do not qualify. **Apply changes** also
qualifies when it first enables the downloaded wallpaper on a display. Downloads
completed before this feature was installed are not inferred from library IDs.

Eligibility survives quitting between download and apply. If the panel is hidden,
onboarding or sign-in is open, another dialog is active, or a wallpaper switch is
in progress, the offer waits. **Hide window after applying a wallpaper** defers
hiding for this first offer. Only a displayed offer consumes the one-time flag;
after that it never returns automatically, including after quitting or updating.
Opening a link neither stars the repository nor makes a payment; the user finishes
that action in their browser. See [Supporter details](../../SPONSORS.md).

## Deleting wallpapers

Deletion always moves the managed library copy to the Mac's Trash after a
confirmation sheet; imported source folders are never touched, and a wallpaper
playing on a display is ejected first. A disconnected display, or a wallpaper
folder removed outside the app, can keep its assignment: once the library has
been scanned the renderer leaves that display empty rather than failing every
apply, and reinstalling the wallpaper brings the assignment back.

- Single: the trash button in the inspector's action row (next to **Apply
  wallpaper**), or `Delete`/`Backspace` on a focused tile.
- Batch: **Select** in the Installed toolbar switches the grid into selection
  mode, where every tile shows a check box and clicking a tile toggles it;
  `Shift`-click extends across the visible range and **Select all** in the
  summary row selects every tile matching the current filters. Outside
  selection mode the check box appears on hover and `Cmd`-click toggles it. The
  summary row shows the count with **Clear** and **Move N to Trash**; `Delete`
  acts on the selection from the grid, `Escape` or **Done** leaves selection
  mode. One confirmation covers the whole batch, every wallpaper is trashed
  independently, the library refreshes once, and any wallpaper that could not
  be removed is reported in the error banner while the rest are gone.
- Drag-select: holding a tile still for 350ms checks it (the tile sinks and its
  check fills in during the hold) and sweeping on checks every tile from the
  pressed one to the one under the pointer, in grid order; sweeping back
  unchecks the overshoot, and resting near the grid's top or bottom edge
  scrolls it. Starting on a checked tile clears instead. Once a selection is
  under way, in selection mode, or when the press starts on a check box, moving
  onto another tile starts the sweep without the hold; otherwise a drag that
  moves before the hold completes does nothing. The click ending a sweep is
  ignored, so it never toggles the last tile or changes the inspector.
- Teaching it: the summary row shows a tip (**Hold a tile, then drag across
  others…** with **Got it**) whenever a selection or selection mode is active,
  until the user sweeps across two or more tiles or presses **Got it**; that is
  stored natively (`dragSelectLearned` action and snapshot field, like
  `welcomeSeen`), because the panel's web storage is not persistent. Afterwards
  selection mode keeps a one-line reminder, **Click or drag across tiles to
  select them.** The toolbar's **Select** tooltip and each check box's tooltip
  mention the gesture too.

## Target display

The top bar picker chooses which display Apply acts on. Disabled and mirrored
displays are listed but not selectable, annotated `(disabled)` or `(mirrored)`.
Per-display enablement, independent/mirror mode, mirror source, scaling, scale
factor, frame rate, mute and volume live in **Settings -> Displays**, beside
each independent display's **Playlist** (see [playlists](playlists.md)). When a
Performance cap, or the battery frame rate while reduced quality is in force,
is below the saved frame rate, the field notes `Limited to {fps} fps by
Performance settings` and can open Settings → Performance. The inspector's
per-display frame-rate field shows the same note. Saved frame rates are not
rewritten.

**Copy or swap wallpapers** under an independent display transfers its current
wallpaper to another eligible screen or exchanges their assignments. **Display
layouts** below the display sections saves and reapplies named arrangements.
Unavailable layouts stay visible with their missing resource; all targets are
validated before changes. These operations preserve existing playback rules and
use the normal command queue. See [Multi-display wallpaper layouts](display-layouts.md)
for recovery, history, saved settings and the per-Space boundary.

**Automatic wallpaper selection → Follow desktop Space** adds an experimental
wallpaper/playlist picker for each regular desktop on the display. The current
desktop is marked, reordered desktops keep their UUID-based choice, and unavailable
desktops can be forgotten. Fullscreen app Spaces keep the previous selection.
See [Space-based wallpaper choices](spaces.md) for transition, pause and lock-screen
ownership limits; this mode does not create or switch Spaces.

A display the app has never configured starts enabled with the primary
display's wallpaper, so a newly connected monitor shows a wallpaper without a
trip to Settings. Turning **Enable wallpaper** off saves that choice under the
display's identity, and it stays off when the display reconnects. A display
switched to mirroring shows its source even if it kept an earlier wallpaper;
applying that wallpaper again does not make it independent. Configuration
written before this default (0.5.0 and earlier saved new displays as disabled)
is not rewritten.

Display titles come from the renderer as `Vendor 1552 - Model 41055 (1 - Primary)`
because the vendored renderer only reads CoreGraphics vendor/model numbers.
`DisplayTitleResolver` (App/Services/Desktop) replaces that label with
`NSScreen.localizedName` — the name System Settings shows, such as
**Built-in Retina Display** — keeping the renderer's `(id - Primary)` suffix.
Renderer display ids are `primary`, a live CoreGraphics id or
`identity:{json}` (never the screen number for configured displays), so the
resolver matches the live id inside the title suffix and the identity UUID
against `NSScreenNumber` / `CGDisplayCreateUUIDFromDisplayID`. It applies to the
target picker, Settings -> Displays, mirror-source menus and the inspector's
per-display sections; a display without a matching screen (or an empty system
name) keeps the renderer label. The renderer's own titles and ids
are unchanged, so nothing persisted or sent over the bridge moves.

## Filtering

Both library pages share one filter sidebar on the left of the grid (the
inspector keeps the right). Its only switch is the toolbar's **Filter** button:
the first control in the toolbar, with a funnel glyph, the label "Filter" and,
when filters are active, their count in a pill. Open, it uses a soft accent
surface and reads as pressed (`aria-expanded`) beside the sidebar; closed,
the sidebar leaves the layout and the grid takes its column. The sidebar itself
has no collapse control and no rail. Each page remembers its own choice natively
(`filters` action, `filtersCollapsed` in the snapshot; the panel's web storage is
not persistent) and restores it on the next launch. Closing never changes the
search or the filters.
Collapsed groups retain their state and show their own active count: Show only
counts selected tags, and exclude groups count visible boxes that differ from
that page's defaults. Clear restores those defaults; hidden/unknown tags are not
claimed to be represented by the sum of visible group counts.

- Installed: the sidebar carries Discover's boxes and rules (see below), applied
  in the page to each wallpaper: **Show only** starts with Favorites and Active
  on target display, then Approved, Audio responsive and Customizable; **Type**
  (Scene, Video, Web) reads the wallpaper's kind; **Age rating** and **Tags**
  read its `project.json`, which `LibraryMetricsService` turns into Steam's tags
  (`tags` in the snapshot: the manifest's genre tags, `contentrating`, `Approved`,
  `Audio responsive` for `general.supportsaudioprocessing` and `Customizable` for
  user properties beyond `schemecolor`); a wallpaper without a genre counts as
  Unspecified. A manifest carries no resolution or Workshop category, so those
  boxes are Discover-only. Every box starts ticked (a library hides nothing by
  default), a ticked Show only box requires its tag and an unticked box hides
  every wallpaper carrying that tag, case-insensitively; **Clear** resets the
  sidebar. Search matches titles and tags. Filtering never activates a
  wallpaper. The toolbar's sort menu offers Name, Type, Favorites, File size and
  Date added, with a direction button beside it. Choosing a key starts in the
  direction people ask for it (names A→Z; favorites, largest and newest first)
  and the button flips it; names break ties. File size is the wallpaper folder's
  total and Date added is when the folder entered the library (download or
  import), both measured off the main thread by `LibraryMetricsService` and
  re-checked only after a library reload; wallpapers not yet measured sort last.
- Discover: the sidebar is Wallpaper Engine's own filter list — Show only
  (required tags), then Type, Age rating, Resolution and Tags as tick boxes
  whose unticked entries are excluded (see
  [workshop-downloads](workshop-downloads.md)); sort opens on Most popular this
  year and offers Highest rated, Most popular today, Trending this week, Most
  popular this month, Most popular this year, Most subscribed, Newest or Relevance.
- pixiv: the sidebar starts with the pixiv account (sign in, or who is signed in
  and **Log out**), then Orientation, Minimum size, Age rating and AI-generated;
  its Mature (R-18) box waits for a sign-in. The toolbar menu lists rankings
  while the search field is empty and search orders once it is not. See
  [pixiv](pixiv.md#browsing).

An empty result offers recovery for the actual restriction: **Clear search**,
**Clear filters** (plus **Show filters** when hidden), or **Clear search and
filters**. A Workshop response with no restrictions offers Refresh instead of
an ineffective Clear. First loading, Workshop failure/Retry and an empty local
library keep their own states; a refresh can leave existing results visible.

### Local collections

Installed's sidebar also has named local **Collections**, separate from Steam's
Workshop collections and the author's tags. Create, rename or delete a group;
add selected wallpapers through **Add to collection…**, remove selected members,
or toggle membership in the inspector. A collection filter composes with search
and the existing filters. Deleting a collection leaves its wallpapers installed.
Collections can feed [playlists](playlists.md#collections-and-saved-playlists).

## Properties

The inspector's compact **General configuration** section holds mute, volume,
[Audio response](audio-response.md), and media integration. **Audio and media
status** expands to show their explanations and delivery status. **Wallpaper
properties** follows, with the wallpaper's authored controls in their original
order. **Displays** is collapsed below them and holds per-display playback
configuration. General, property and display disclosures retain their state
across snapshot updates.

Property rows place the label on the left and the checkbox, slider/value,
combo menu or color swatch on the right. Text and file editors use the full
width below the label. A reset icon appears on hover, keyboard focus, or a
modified row; it restores that property's default. Checkboxes use the author's
name directly, without a second “Enabled” row. Recognized Wallpaper Engine
label tokens (brightness, position, default, and similar built-in vocabulary)
are localized rather than displayed as `ui_editor_…` identifiers.

Authors use HTML labels as a layout surface. `WebUI/property-label.js` parses
them inertly and reconstructs a small presentation allowlist: headings,
paragraphs, line breaks, emphasis, font colors, centered content, dividers,
links and images. Author scripts, styles, embedded documents, form controls,
event handlers and panel action attributes are discarded. Plain labels remain
available for accessibility and native file pickers. An empty text property
is omitted; a control without a readable name uses **Unnamed option**, never
the editor's markup-derived id.

Author artwork is loaded only through registered `mwe-ui://property-image/`
routes. `PropertyImageCache` fetches HTTPS raster images natively from the
allowlisted image CDNs (`i.ibb.co`, `i.imgur.com`, the supported Steam image
hosts, and QQ's photo-store hosts), rechecks redirects, and rejects credentials,
custom ports, unregistered routes, oversized images and non-raster content.
PNG transparency and GIF animation are preserved; repeated dividers share a
bounded in-memory cache. At most four author-image transfers run across all
hosts; queued consumers do not start a transfer. Each URL's load is shared by
its current consumers. Stopping the last consumer cancels queued or active
work, and an active transfer holds its slot until it exits. A retired load
cannot deliver to a new request for the same URL or populate the cache.
Other image hosts are omitted (alt text is retained).
Images remain author-hosted and require network access on a cache miss; they
are not copied into the app bundle. Supported author links use the native
external-link policy, including Bilibili profile/article pages, and open only
when clicked. Unsupported links retain their text without a clickable action.

Audio, scaling mode and frame rate take effect immediately. Everything else is
pending until committed:

- **Apply changes** saves pending properties and scaling factors.
- **Revert** discards pending changes.

Unsubmitted text stays with its wallpaper when navigating between pages.
A dirty or unsubmitted control shows a localized **Modified** flag outside its
author-provided label. Reset clears the flag once the property is clean; the
fixed Apply changes / Revert footer retains its existing meaning.

A `scenetexture` property's image picker fills the material slot that names it,
so a wallpaper built around "choose your own picture" shows the picture. The
choice takes effect on **Apply changes**, which reloads the scene; the picker
stores the path, not a copy, so moving or deleting the file leaves that slot on
the artwork the author shipped. A picture outside the app's own storage is not
readable from the sandboxed lock-screen extension, which keeps the authored
texture there.

### Property presets

**Wallpaper properties → Save current…** stores a named preset of the currently
applied authored properties. Pending edits must first be applied or reverted.
Choose a preset and **Apply**, rename/delete it, or export/import its versioned
JSON document. Import saves a new preset; it never applies it automatically.
These are wallpaper-specific property presets, not the Performance quality tiers.

Application validates every saved property against current types, limits and
choices before staging edits. Default markers follow the author's current
default. File/directory edits join the same draft transaction, and a failed
application restores draft and selection-permission state. Managed attachments
are retained independently of the current property under `UserAssets/PresetAssets`;
deleting a saved preset does not delete a directory still used by an applied
wallpaper. Ordinary cache cleaning leaves these retained originals alone.

Presets can switch a mode and set fields that mode enables. All values and
resources are validated first; enabled mode controls are edited before dependent
fields, and the bridge reevaluates authored conditions after each draft edit.
If a target field remains disabled, the draft is reverted without applying it.

Portable documents embed up to 32 MB of managed attachments, within a 48 MB
document limit. Hidden files in retained directories (such as Finder metadata)
are excluded from portable exports. Preset names accept 1–120 characters.
Arbitrary external paths do not grant access on import: select
external originals through the property editor. Missing resources, incompatible
author changes, malformed documents and filesystem-aliasing filenames are errors,
not partially applied presets.

### Image placement

App-generated imported pictures and saved pixiv pages show **Position on screen**.
Drag the preview or use its keyboard/position controls and 100–300% zoom; each
target display keeps its own placement. **Reset to Image fit** restores the
existing Fit/Fill/top-aligned behavior. Original image bytes are unchanged.
Changes reach the running page through properties without resetting its document.
An older app-generated page is upgraded once only if its provenance, resources
and exact unmodified template match; authored or modified HTML is not rewritten.

### Compatibility check

An installed wallpaper's **Compatibility check** reads entry/shared resources and,
for video, asynchronously checks native admission for the selected display and
frame-rate constraints. Checks are explicit and version/configuration-bound.
Unknown scene shader/graph or Web runtime behavior remains **unknown**; readable
files and video metadata are not proof of a displayed frame. The same card shows
the actual running backend and fallback reason when the runtime reports them.

### Local backup and restore

**Settings → Storage → Backup** exports a versioned `.wmbackup` directory package
containing renderer/wallpaper settings, allowlisted preferences (collections,
plans, presets, favorites, image placements, display layouts, automatic-selection rules and solar
coordinates included), and retained UserAssets. Handled automatic events and
temporary Focus recovery state remain local and are cleared on successful restore;
rollback restores their original values.
**Include the wallpaper library** also copies installed projects. Login sessions,
passwords, keychain entries, logs, caches and shared scene resources are excluded.
The local scene-assets selection stays local and may need to be selected again.
Only preferences saved in the app’s persistent domain are included; inherited
system languages and registered defaults are excluded, including during conflict
checks and rollback. Export checks the complete manifest size before copying
payload bytes and supports the full 48 MB preset archive limit.

Choose a backup to preview its contents, conflicts and missing-resource warnings.
**Keep what is on this Mac** preserves conflicting per-display playlists, their
deadlines and automatic-selection configurations as whole records; independent
records can be imported. **Replace with
the backup** replaces conflicts. Confirmed restoration is staged for the next
launch, before stores or the renderer read settings; nothing changes in the
running session, and the app does not quit or restart automatically.

Packages reject traversal, links, special files, ambiguous filenames, changed
bytes and unsupported configuration schemas. Publication is journaled and rolls
back on failure. A failed pending restore is shown in Storage and is not retried
every launch without explicit reconfirmation; **Cancel restore** removes staging.
Managed resource paths relocate, while ordinary property text stays unchanged.
Backed-up copies are portable; original external files are read or watched only
after a matching local authorization or an explicit reselection. Restoring metadata
alone cannot authorize a wallpaper to read another folder on this Mac.
Scene texture overrides and authored defaults that had only retained copies are
rewritten to the exact validated retained file, because the scene renderer opens
paths directly rather than going through the Web asset host. Original paths stay
as provenance only. A retained directory without a directly usable scene resource,
or a keep-existing asset tree missing the matching bytes, cannot authorize a
scene reference and is rejected before publication.

## Downloads and import

Discover tiles show their own download ring (progress, cancel, sign-in needed,
retry). Before any bytes move, the ring sweeps and names the current SteamCMD
step inside it (Preparing, Connecting, Updating, Signing in, Requesting) from
the job's `phase`; a transfer without a percentage yet shows its speed instead,
and after the last byte the full ring reads Finishing while the files are
validated and imported. The full status sentence stays in the tooltip, the
inspector and the downloads list. Several tiles download at once; the activity
bar sums them. The
downloads popover opens from the activity bar, from the top-bar
downloads button while downloads exist, and from **Show in downloads** in the
inspector. The import
popover opens from **Import** in the Installed toolbar; imports copy source
files into the library and leave the originals untouched, with a duplicate
policy of **Skip duplicates** or **Keep both copies**. Closing a popover, or the
window, never cancels work: `LibraryImportStore` runs the import for the app, not
for the page.

Quitting cancels and awaits an active local import. Its temporary directory holds
an ownership marker and a live file lock. Startup reclaims abandoned marked
directories; an unmarked legacy directory must have a valid task name and an
entire inspected tree older than 24 hours. Active or uncertain directories are kept.

An import takes Wallpaper Engine project folders, a Steam library, videos
(`mp4`, `m4v`, `mov`, `webm`, `mkv`, `avi`), HTML files and pictures (`jpg`,
`jpeg`, `png`, `gif`, `webp`, `heic`, `heif`, `tif`, `tiff`, `bmp`, `avif`, at
most 512 MB). A picture becomes a still `web` wallpaper with the id
`image-<file name>`, packaged the way pixiv pages are (`StillImageWallpaper`; see
[pixiv](pixiv.md#saving-a-page)): the original kept as `image.<ext>`, a 512 px
`preview.jpg`, and a `display.jpg` shown instead when the format is not one a
web view shows as it is (`jpg`, `png`, `gif`, `webp`) or the long side exceeds
8,192 px. Its **Image fit** and **Background color** labels are translated like
pixiv's. A picture ImageIO cannot measure or scale is reported and not imported.
A Workshop preset folder is imported as one self-contained wallpaper built on
its base, found next to it (a Steam library) or already in the library; see
[Workshop presets](workshop-downloads.md#workshop-presets).
Files dropped on the Dock icon, or opened with WallpaperMachine from Finder
(`CFBundleDocumentTypes` in `Info.plist`, rank Alternate, so the app never
becomes a default), are imported the same way with **Skip duplicates**, and the
window opens on Installed with the import in the activity bar. The Steam sign-in dialog uses a guide card (glyph plus numbered
steps) for Steam Guard stages; account and password prompts are just the
labelled field. Once Steam accepts the sign-in, it confirms that the download
is running before it closes; see
[workshop downloads](workshop-downloads.md#the-download-queue).

Busy imports show indeterminate progress. If an import finishes while its
popover is closed, a result button stays in the activity bar until viewed and
closed (or another popover is opened). Counts and each failure stay available
inside Import. A popover opened from the activity bar keeps that anchor while
open, and retains the displayed report across snapshots that omit it. This
unread indicator lasts only for the page session; an old report in the first
snapshot is not announced as a new result.

Popovers use the actual space above or below their trigger, up to 560px, instead
of a fixed fraction of the window height. Sign-in dialogs leave a 20px vertical
window margin and keep the 640px height ceiling, with scrolling for longer
content. Their default action follows the alternatives at the trailing edge in
both the visible layout and DOM/Tab order. Already-installed shared resources
offer re-download as a secondary action rather than another recommended primary.

## Verification

Panel behavior is covered by the unit and UI suites and by the manual desktop
checklist; see [Testing](../testing/README.md) and the
[verification log](../testing/verification-log.md) for current evidence.

Back to the [project README](../../README.md).
