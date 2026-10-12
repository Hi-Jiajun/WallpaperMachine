# Manual release smoke checklist

**This checklist is manual and is not automated.** Every item below controls the
desktop, opens application windows, changes the user's wallpapers, signs in to
Steam, or grants system permissions, so each run requires an explicit user
decision. It is neither routine verification nor a required release gate (see
[README.md](README.md#authorization-boundary)), and no agent may perform it
without an explicit request.

Perform the checks yourself when preparing a release, using disposable imports
where needed. Note any check skipped for unavailable hardware or assets. Restore
your original wallpaper configuration afterwards. Native tests do not establish
these visual and OS-integration behaviors; report them unverified when no check
was run.

## Launch and window

- [ ] One library window opens, the starter wallpaper is visible, and there are
      no blank floating panels.
- [ ] Switch between the Discover, pixiv, Installed and Settings tabs and through the
      seven Settings categories: Performance, General, Appearance, Displays,
      Library & Steam, Storage, About.
- [ ] Command-comma reuses the existing window.
- [ ] Close the window with its close button and with Command-W, and reopen it
      each time, without quitting or crashing.

## Appearance

- [ ] Choose Light and Dark, then System, and change the macOS appearance.
- [ ] Check the titlebar, menus, controls, dialogs, inspector and download
      popover in each mode.
- [ ] Set an accent and a surface tone; relaunch and confirm both persist.
- [ ] Try white and black accents, then Reset appearance. Wallpapers and
      playback must not change.

## Library and import

- [ ] Open and cancel Import.
- [ ] Search for a nonexistent local title, clear the search, and confirm the
      collection returns.
- [ ] Select a wallpaper and refresh: the selection survives.
- [ ] Selecting must not activate a wallpaper. Apply/Reapply and double-click
      activate it, and double-click must not close the window. The window stays
      open after applying unless Settings → General → Hide window after applying
      a wallpaper is on.
- [ ] Try invalid media and missing scene assets: actionable failures appear
      without blocking videos or losing an already downloaded scene, and a valid
      wallpaper remains usable.

## Layout and accessibility

- [ ] Check Discover, pixiv and Installed at 1240×800, 960×640 and 760×560 in light and
      dark mode. The inspector stays present; panes resize without losing the
      target or the primary actions.
- [ ] Command-F, grid arrows, Return/Space, text editing and VoiceOver names
      stay correctly scoped.

## Discover, search and filters

- [ ] Search Discover, edit an unsubmitted query, then advance a page:
      pagination must still use the displayed query. Submit to switch queries.
- [ ] Navigate away and back: query, page and selection stay.
- [ ] A failed request's Retry repeats that request.
- [ ] Open and dismiss the Downloads/Import pane.
- [ ] Select tags in the filter sidebar across the resolution,
      ultrawide/portrait, genre, age-rating and category groups: results contain
      only items matching every selected tag, and Clear filters restores the
      unfiltered query.
- [ ] Filter changes never activate wallpapers.

## pixiv

- [ ] The pixiv tab opens on the daily ranking; paging, a tag search and each
      filter group work, and Clear restores the defaults.
- [ ] Select a work with several pages, step to another page and download it:
      it appears in Installed as a still wallpaper, applies, and Image fit and
      Background color change it.
- [ ] **Sign in to pixiv…** opens pixiv's own sign-in page in its own window;
      signing in with a pixiv ID or email closes it and the sidebar names the
      account. Closing the window instead changes nothing.
- [ ] Quit and reopen: the sign-in is still there, with no keychain prompt on a
      release build.
- [ ] With an account whose viewing restrictions allow R-18 works, tick Mature
      (R-18): search includes works with the R-18 badge and the R-18 rankings
      join the menu. With an account that hides them, the sidebar says so.
- [ ] **Log out**: the Mature box unticks and disables, an R-18 ranking returns
      to its all-ages one, and Keychain Access no longer lists
      `app.wallpapermachine.pixiv`.

## SteamCMD setup

- [ ] Install or locate SteamCMD in Settings → Library & Steam or the download
      setup dialog, and use the same runtime without restarting.
- [ ] Installation itself must not log in; a retained wallpaper request
      continues once its prerequisites are met.
- [ ] Official signed command-line SteamCMD finishes from Install without an
      extra Allow step.
- [ ] A blocked download remains present across relaunch and retry.
- [ ] Only confirm Allow this SteamCMD after checking the shown path and
      understanding the risk, and only when Gatekeeper actually rejects a copy. Global Gatekeeper and signature checks stay enabled;
      updated bytes require another approval.
- [ ] An official no-login installation smoke uses a disposable support root and
      the production providers, stops on any Gatekeeper, architecture or signature
      block, and never approves a prompt or re-signs downloaded code. The
      installation candidate stays quarantined; only the validated disposable
      execution copy has its download marks cleared, just as for downloads.

## Download queue

- [ ] Double-click a Discover tile with SteamCMD installed and a saved sign-in:
      no dialog opens, the tile's ring fills with a percentage that matches the
      inspector's received/total bytes, and clicking the ring cancels.
- [ ] With a saved sign-in, queue at least four Workshop items: three transfer
      at once (the activity bar reads "3 downloading" with a combined speed),
      the fourth waits for a free slot, and the app log records each start.
- [ ] With no saved sign-in, queue several items: only the first prompts, the
      rest wait for the sign-in, then start silently as soon as Steam accepts
      it and before the first transfer finishes.
- [ ] Cancel an active item and check that the oldest queued item starts after
      cleanup.
- [ ] If Steam ends a session with "logged in elsewhere", the ended item goes
      back in line, the footer reads "Downloads run one at a time", and it
      retries after the running item without a click.
- [ ] Remove queued work and confirm it never starts.
- [ ] Complete one sign-in and check that the next job attempts saved-session
      reuse. Steam may still ask again.
- [ ] With no saved sign-in, the password / Steam Guard dialog opens by itself;
      Not now keeps it closed until Steam asks for something else, and the
      tile's shield reopens it. Close the Downloads popover, change search or
      page, and reopen the active transfer's sign-in dialog.
- [ ] Verify independent retry, completion and scene-resource consent.
- [ ] Saved sign-in settings stay locked until pending transfers finish;
      quitting stops all transfers.
- [ ] With setup missing, click Download, dismiss with Not now, and navigate
      elsewhere: the request remains in Downloads and Continue setup resumes it.
      Removing it prevents later automatic continuation.
- [ ] Completing setup, account and resource consent continues without another
      Start download button. Downloads do not auto-apply.
- [ ] Show in library reveals an item excluded by filters and returns to the
      original results; deleting it removes Discover's installed badge.

Synthetic-process tests do not prove Steam CDN throughput, live-account session
reuse, or visual behavior, which is why these items are manual.

## Displays and properties

- [ ] Select a target display and apply: other displays keep their assignments.
- [ ] Disconnected, disabled or mirrored targets are not silently redirected to
      primary.
- [ ] Pause/resume and relaunch: the expected wallpaper and playback state
      return.
- [ ] Leave invalid scaling text, refresh or change routes, then return: the
      text is preserved and Apply changes is disabled. Return stages only that
      field, not unrelated properties.
- [ ] Check immediate audio/FPS/scaling-mode semantics versus pending
      Apply/Revert.
- [ ] Check the Language, Clock Location and Bar Style property menus, and that
      language-row changes survive reopening the app.
- [ ] When relevant, check each connected display and sleep/wake behavior.

## Native desktop posters and Mission Control

- [ ] Create multiple Desktops, apply a video, and immediately open Mission
      Control **without** switching Desktops.
- [ ] Apply a different scene and repeat, including rapid A→B→C changes. All
      desktop thumbnails update from the new renderer's first frame without
      waiting on a timer.
- [ ] Check the actual rendered image, not its Workshop cover, including
      Fill/Match/Stretch, scaling and flipping.
- [ ] Check different and mirrored wallpapers on connected displays,
      pause/resume, and a newly created Desktop.
- [ ] Apply a wallpaper with an intro, wait about 20 seconds and open Mission
      Control: the thumbnails show the wallpaper after its intro. Change a
      property that fades in and check again.
- [ ] Turn on **Update the Mission Control picture every 5 minutes**, wait past
      five minutes with the wallpaper visible and check that the thumbnails
      moved on; with it off they keep the last settled frame.
- [ ] Eject a wallpaper: all Desktops recover their previous native image and
      scaling.
- [ ] Quit and reopen to check restoration journaling.
- [ ] Start with an inherited/system wallpaper on each display, apply a live
      wallpaper, then quit. Each display restores its own original. If macOS
      cannot expose an original image, live playback works but the system
      wallpaper and Mission Control thumbnails remain unchanged.
- [ ] Change a native wallpaper outside the app and verify that quitting does
      not overwrite it.

Mission Control posters are sampled still frames, not live animation. Updates
begin as soon as a rendered frame is available, but rendering, JPEG encoding and
the system's thumbnail compositor still take time; zero-millisecond visual
latency cannot be guaranteed. How the poster service targets Spaces, resolves
originals and restores them, and which non-public APIs it uses, is in
[architecture.md](../architecture.md) and, for Space mode,
[spaces.md](../features/spaces.md#poster-ownership-and-late-frames). Two
consequences matter while testing: without a recoverable original the poster
writes are skipped and a failure is logged while live playback continues, and a
journal from an older build that holds only empty originals cannot restore the
earlier wallpaper (select it again in System Settings once).

## Animated lock screen (experimental, opt-in)

- [ ] Enable Animate lock screen, then apply wallpaper A and wallpaper B without
      visiting other Spaces, and inspect every desktop thumbnail.
- [ ] Disable the feature: journaled Desktop/Idle entries are restored and
      poster synchronization resumes.
- [ ] Quit with the feature enabled: the native provider is restored before
      poster restoration is attempted. Repeat with lock-screen only, screen-saver
      only, and both enabled after a poster has already been installed.
      Every desktop returns to its original; quit waits through the native
      service reload. A restoration failure keeps the app running and reports
      the error so Exit can be retried.
- [ ] Lock and unlock the screen and confirm the provider becomes active with
      playback unpaused.
- [ ] Do not run this alongside a competing global wallpaper manager; a conflict
      is reported and ownership-aware restoration runs instead.

macOS refuses screenshots while locked, so the final lock-screen appearance and
smoothness cannot be captured and have to be judged by eye.

## Audio responsiveness

- [ ] Use an authored audio-reactive scene, leave Audio response enabled, and
      grant system audio recording access.
- [ ] Play and pause music in another app and check shader, script and particle
      response.
- [ ] Verify that mute affects wallpaper playback only.
- [ ] Verify that the final disabled or removed scene stops capture.
- [ ] Verify that denied permission surfaces an error.

## App update

- [ ] Settings → About shows **Check for Updates**. The application menu item
      **Check for Updates…** opens that same section.
- [ ] A live GitHub release check, the published disk image mounting and the
      replacement of the app in Applications. Update tests use fixture JSON, a
      fake client and locally made images, so this path is manual only.
- [ ] Opening the disk image shows one window without toolbar or sidebar: the
      app and Applications at their places over the background, labels readable,
      the volume icon. Dragging installs; the first launch is refused and opens
      from System Settings → Privacy & Security → **Open Anyway**.

## Cross-cutting

- [ ] Multiple displays, multiple Spaces and Mission Control posters,
      sleep/wake, quit and relaunch restoration, external wallpaper changes, and
      invalid→valid recovery.

Record each authorized desktop run as described in
[wallpaper-corpus.md](wallpaper-corpus.md#record-of-an-authorized-desktop-run),
and add the outcome to [verification-log.md](verification-log.md).
