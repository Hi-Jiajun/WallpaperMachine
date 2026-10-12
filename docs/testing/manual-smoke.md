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
- [ ] Move the panel to another Space (or a desktop with another app full screen) and
      choose Control Panel from the status menu: it appears on the Space you are on,
      and the green button still offers full screen. Minimize the panel, then choose
      Control Panel from the status menu, click the Dock icon, and Command-Tab to the
      app: each brings it back from the Dock. Repeat the Space check with What's New,
      a wallpaper preview and a Steam or pixiv sign-in window.
- [ ] Close the window with its close button and with Command-W, and reopen it
      each time, without quitting or crashing.
- [ ] On Installed, type a search, change the sort and direction, untick a type box
      and scroll down a long library, then close the panel and reopen it from the status
      menu: the search, sort, boxes and scroll position are as left. Quit and relaunch:
      Installed starts unfiltered at the top.
- [ ] With the app running, `open -n` the same app: no second copy appears and the
      first shows its panel. Run a copy from another folder: an alert says another
      copy is using the library, and the running copy is untouched. After an in-app
      update the new version starts normally.
- [ ] Switch WallpaperMachine off in System Settings → General → Login Items, then
      turn **Launch at login** on in Settings → General: the switch returns to off, a
      note says to allow it in Login Items, and **Open Login Items…** opens that pane.
      Allow it there and come back to the panel: the switch is on and the note goes
      away without any other action.

## Appearance

- [ ] Choose Light and Dark, then System, and change the macOS appearance.
- [ ] Check the titlebar, menus, controls, dialogs, inspector and download
      popover in each mode.
- [ ] Set an accent and a surface tone; relaunch and confirm both persist.
- [ ] Try white and black accents, then Reset appearance. Wallpapers and
      playback must not change.

## Library and import

- [ ] Open and cancel Import.
- [ ] In Import's picker, a project's `scene.pkg` and `project.json` and a
      Wallpaper Engine folder are all selectable, and each imports its project(s).
- [ ] Import a large project (several GB, ideally from an external drive) twice
      with **Keep both copies**: the second import ends as skipped without a second
      copy in the library, in about the time it takes to read the project once.
- [ ] Apply an installed project to a display, change a file of its source folder
      (a different video, say) and import that folder with **Replace if changed**:
      the display shows the new file without being reapplied, the library holds
      one folder for it, and a second import of the same folder ends as skipped.
- [ ] With animated GIF previews in the library, Installed shows every tile as a
      still, with nothing moving at rest. Resting the pointer on a tile plays only
      that tile, Tab or arrow keys play only the focused one, and leaving it, a
      selection drag, another tab or another window stops it with no flicker when
      the grid re-renders. When a Workshop download finishes or the library is
      rescanned, the covers stay as they are with no flicker; after a preview
      file is replaced (import it again with Replace if changed), only that
      tile's cover refreshes.
- [ ] With a saved Steam sign-in, select an installed Workshop wallpaper and
      choose **Reinstall from Workshop…** (the circular arrows beside Trash):
      a sheet asks first and Cancel changes nothing. Confirming shows the
      download in the queue and, when it completes, the wallpaper keeps its
      options and a display showing it loads the new files. Delete the entry file
      from its folder beforehand to see the Compatibility check offer the same
      button, and Reinstall repair it. Imported pictures and folders with a
      non-numeric name show no button.
- [ ] Search for a nonexistent local title, clear the search, and confirm the
      collection returns.
- [ ] Select a wallpaper and refresh: the selection survives.
- [ ] Selecting must not activate a wallpaper. Apply/Reapply and double-click
      activate it, and double-click must not close the window. The window stays
      open after applying unless Settings → General → Hide window after applying
      a wallpaper is on.
- [ ] With a wallpaper playing, press **Reapply wallpaper** in its inspector: the
      wallpaper restarts from its first frame on that display only (watch a
      video or scene; note whether a scene flashes to the bare desktop while it
      reloads). Double-clicking the same tile, or choosing it in Recently used,
      must leave it playing without a restart.
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
      Start download button. Downloads do not auto-apply unless Download and
      apply was chosen.
- [ ] With a saved sign-in, choose Download and apply on a Discover video that
      is not installed: the inspector reads "Will apply when the download
      finishes.", and when it arrives the target display shows it. Repeat and
      apply a different wallpaper to that display while the download runs, or
      swap it with another display or apply a saved layout that names it: the
      display keeps your choice, the new wallpaper stays in the library, and the
      inspector says it was not applied because you chose another wallpaper.
      Click Download and apply on two wallpapers for one display: whichever
      arrives first, the one you clicked last is applied.
      Quit and reopen mid-download: the download comes back paused and applies
      nothing when resumed.
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
- [ ] Preview a wallpaper for a portrait or ultrawide display (rotate one, or
      use a 21:9 or 9:16 display): the window opens with a stage of that shape
      and black bars, a scene or page lays out as it does on the display, and
      dragging the window to other shapes keeps the proportions without
      stretching. Previewing again for a 16:9 display reshapes the stage without
      resizing the window.

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
- [ ] With a live wallpaper applied, log out, then restart and shut down (separate
      runs, authorized only). macOS must show no "cancelled" or "preventing logout"
      dialog. The log says `quit: reason=logout mode=powerOff` (or restart or
      shutdown) and every stage duration; if a line says `desktop restoration
      unfinished`, the next login shows the last poster until the app runs again and
      the next launch logs `previous session: quit normally (logout; desktop
      restoration unfinished)`. Also start a quit from the menu with a restoration that
      cannot finish and log out while it runs: the logout must not be cancelled.

Mission Control posters are sampled still frames, not live animation. Updates
begin as soon as a rendered frame is available, but rendering, JPEG encoding and
the system's thumbnail compositor still take time; zero-millisecond visual
latency cannot be guaranteed. How posters are taken, how originals are resolved
and restored, and which non-public APIs are involved is in
[desktop-picture.md](../features/desktop-picture.md) and, for Space mode,
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
- [ ] With an update available (a build older than the latest release) and
      another app full-screen, no update alert appears and the log has
      `update prompt deferred`; leaving full screen shows the alert once, and
      opening the control panel while a display is covered shows it too.
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
