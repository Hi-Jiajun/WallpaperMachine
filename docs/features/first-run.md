# First-run guide and support prompt

Two one-time offers on a Mac that has not seen them: the welcome guide that covers
the first window, and a single request to star or support the project after the
first downloaded wallpaper is applied. Each is shown once and remembered natively.
The panel they appear in is described in [control panel](control-panel.md).

## First run

The first time the panel opens, a guide covers the whole window, top bar included
(`WebUI/welcome.js` + `welcome.css`; `#welcome` is fixed-position over the app and
inherits its light/dark surfaces). It is a page, not a modal dialog; the download
dialog can still open over it for an unrelated job. Background app regions are
inert while the guide is open, and the body scrolls independently of the footer so
it stays reachable at the 760×560 minimum. Steps can be jumped to freely except
while language, appearance, the lock screen, performance or preferences are being
committed; later pages have **Back**, and decision pages have **Skip**:

1. **Language & appearance.** Radio tiles for the language (**System (Auto)** plus
   every shipped language under its own name) and the appearance mode (**System
   (Auto)**, **Light**, **Dark**, each with a drawn miniature). A choice applies at
   once through the `languageSetting` / `themeSetting` actions, so the page
   repaints in the chosen language and theme. **Skip** puts back whatever was in
   force when the guide opened and moves on.
2. **Steam.** Explains that browsing is free and that downloading needs a Steam
   account that owns Wallpaper Engine, with **Create a Steam account**
   (`store.steampowered.com/join/`) and **Buy Wallpaper Engine** beside that
   explanation. The form takes the account name (login name, not profile name),
   the password (with a show/hide toggle) and **Keep me signed in on this Mac** (on
   by default). **Sign in** sends only the account name and the remember choice
   (`steamSignIn`); the password is held in the page until Steam's own password
   prompt arrives on the sign-in job and is then submitted through `downloadInput`
   exactly once. It is never part of a snapshot, the login-start payload or DOM
   markup. Without SteamCMD the button reads **Install SteamCMD and sign in** and
   the page installs it first (`setupInstall`, with the Gatekeeper approval and
   locate-a-copy paths when they apply). Steam Guard is shown with the same guides
   as the download dialog; **Cancel** stops the session. After sign-in the guide
   checks Wallpaper Engine ownership and shows **Signed in as …** with the result
   and **Use a different account** (`logOutSteam`). Non-owners see **Buy Wallpaper
   Engine** and an explanation that pixiv downloads, Workshop browsing and viewing
   existing wallpapers remain available; an inconclusive result is labeled
   unconfirmed. Both offer **Check ownership again** and allow **Continue**, and
   saved accounts from an earlier run can also be checked. **Skip for now** (or
   **Skip and cancel sign-in** while a job or setup request is pending) leaves
   Steam for the first download to ask about. A Steam Guard request arriving on
   another page marks the Steam step with a shield without changing pages. See
   [Steam sign-in](workshop-downloads.md#steam-sign-in) for the session itself.
3. **Performance.** Radio tiles for the **Low**, **Medium** and **High** quality
   presets (the same pairs as [Settings → Performance](performance.md#quality),
   shared through `settings.js`), then the **Frame rate limit** slider, whose top
   reads **No limit** (see
   [Default per-display frame rate](performance.md#default-per-display-frame-rate)).
   High, no limit at full render scale, is selected on a fresh install. A preset
   fills both drafts; moving the slider changes only the limit, and a pair matching
   no preset leaves every tile unchecked with a **Custom** note. They are drafts:
   **Continue** sends only what changed as `setting` / `renderScale` and `setting`
   / `frameRateCap`, **Skip** discards them.
4. **Preferences.** Launch at login and Keep windows in place when clicking the
   wallpaper are switches. **On battery** is a menu: Keep running, Reduced quality
   or Pause. They are drafts: **Continue** commits only the ones that changed
   (`setting` actions, including `batteryMode`), **Skip** discards them. Launch at
   login is disabled with its reason while the app is outside Applications.
   Started at login, the app stays in the menu bar without opening the panel,
   unless this guide is unfinished or the renderer failed to start
   (`ControlPanelLaunch`). When renderer settings are unavailable the page says so
   and disables the controls.
   The last row, **Animate lock screen** (off by default, marked experimental), is
   not a draft: like Settings it sends `setting` / `lockScreenEnabled` at once,
   shows the native status while busy, is disabled when the integration is
   unavailable, and a refusal leaves the switch off with the reason on the page.
   **Skip** puts it back to the value it had when the guide opened. During a
   preference or lock-screen commit, Back, step navigation, Skip and Continue are
   all disabled so the guide cannot leave a partially submitted operation.
5. **Tips.** Three one-line tips (Discover, download then double-click to apply,
   one wallpaper per display), then a compatibility card: not every wallpaper works
   (videos usually play, scenes are experimental, Application wallpapers cannot
   run), failures are reported with the inspector's report button, and pull
   requests are welcome, with **Report an issue** and **Contribute on GitHub**
   links.
6. **Start.** A recap of language, appearance and the actual Steam sign-in state.
   Pending jobs or setup requests offer **Finish sign-in**. Unsaved performance or
   preference drafts each add a cell with their count and **Review**, which returns
   to that page without discarding them; closing does not auto-save the drafts.
   **Browse the Workshop** opens Discover, **Import wallpapers** opens the import
   popover on Installed, and **Start using the app** simply closes it.

Leaving the guide by any of the closing actions is stored natively
(`WebPanelController.welcomeSeenKey`, sent as the `welcomeSeen` action and reported
in every snapshot), so the guide is shown on its own exactly once per Mac.
**Settings → Library & Steam → Welcome guide → Show again** brings it back from the
first page; closing it then does not touch the stored flag. Every link passes the
same external-URL allowlist as every other link in the panel. While the guide is
open the panel's document-level handlers stay out of `#welcome`, and the download
dialog does not surface the sign-in job's prompts (the guide answers them). A
finished sign-in-only job is not listed as a download.

## First wallpaper support prompt

After a wallpaper downloaded through Discover or pixiv is successfully applied by
the user, the panel offers **Feeling good?** once. **Star on GitHub** opens the
project repository; **Become a Supporter** opens the website's pricing page (the
Chinese page for either Chinese app language). Both require a click. **Not now**,
the close button and Escape dismiss the offer.

The download must have finished installing, and applying must have succeeded and
reported a new active display assignment. Downloads alone, local imports, failed
applies, startup restoration, playlist changes, automatic update reloads and
reapplying an already active wallpaper do not qualify. **Apply changes** also
qualifies when it first enables the downloaded wallpaper on a display.

Eligibility survives quitting between download and apply. If the panel is hidden,
the [welcome guide](#first-run) or sign-in is open, another dialog is active, or a
wallpaper switch is in progress, the offer waits; **Hide window after applying a
wallpaper** (see [Selection versus apply](control-panel.md#selection-versus-apply))
defers hiding for this first offer. Only a displayed offer consumes the one-time
flag; after that it never returns automatically, including after quitting or
updating. Opening a link neither stars the repository nor makes a payment; the user
finishes that action in their browser. See [Supporter details](../../SPONSORS.md).
