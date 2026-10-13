# Verification log

Append-only history of what was actually verified, when, and with what result.
The newest entry goes on top; never rewrite an older entry to match today's
tree. Every entry is evidence about the tree it was taken on, not about the
current one — re-run the relevant checks after integration and add a new entry
instead of reusing an old result. Durable guidance belongs in the sibling docs:
test layers and policy in [README.md](README.md), renderer commands and
regression areas in [renderer.md](renderer.md), manual checks in
[manual-smoke.md](manual-smoke.md). Result bundles and probe output are local
and disposable, so entries state counts and commands rather than artifact
paths.

Entry format, so the log stays skimmable: a one-line summary heading, one short
paragraph of context only when the result needs it, then a bullet per command
with its exit status, counts and any skip. Keep an entry around ten lines. A
fact that will still matter next week is not an entry — promote it to the doc
that owns it (renderer behaviour and known-failing tests to
[renderer.md](renderer.md), build and signing traps to
[../build.md](../build.md)) and cite it from there.

Retention: this file keeps the ten newest entries. Add an entry with
`python3 scripts/log_verification.py --title "…" --line "…"`, which prepends it
and moves whatever falls past ten verbatim into a monthly file under
[archive/](archive/); promote anything durable before it goes. Editing an
entry's recorded result is not allowed.

## 2026-10-13 — Native video host takes the switch hold

A replacement clip's window opens with the picture it replaces over it and drops it on the clip's first frame; a replacement's admission is decided before the old surface stops. Targeted run only: the lane runs the full gate once, at its end.

- `python3 scripts/test.py --only NativeVideoWallpaperHostTests` — exit 0; 98 passed (11 new)
- `python3 scripts/test.py --only NativeVideoWallpaperHostTests --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests` — exit 0; 225 passed
- Mutation check — seven one-line breakages of `NativeVideoWallpaperHost` (no adopt, close before admission, no cancel on failure, no settle after hand-off, no release on first frame, no overtaken-pass guard, no release for a layer ready at birth) each failed between 1 and 5 of the host tests
- Skipped: the full gate and `check_rust.py`/`check_renderer.py` (no Rust or renderer change in this commit), `NativeVideoPlayerMediaTests` (opt-in), any desktop run
- Not established: that `isReadyForDisplay` alone is late enough that the veil does not come off a frame early on a real clip; the fade and the clip-to-clip, scene-to-clip and refusal switches on a real display ([manual smoke](manual-smoke.md#wallpaper-switching))

## 2026-10-13 — Wallpaper switch hold for scene successors

Commit 3 of the seamless-switch lane, built and tested in an isolated worktree on top of the layer-swap revert and layer announcement commits. Web pages and native-backend clips take the veil in the lane's next commits; this one carries it for scenes.

- `python3 scripts/test.py --only WallpaperSwitchHoldTests --only WallpaperActivationRecoveryTests --only DesktopWallpaperTests --only WallpaperPresentationPolicyTests --only WallpaperReapplyTests --only WallpaperDisplayTransferIntegrationTests --only WallpaperDisplayTransferTests --only UserCommandQueueTests --only ActivationLogTests --only WallpaperWindowAuditorTests` — exit 0; 234 passed, 0 failed, 0 skipped
- Mutation check on `WallpaperSwitchHold` (a reconfigure takes the veil, the engine settling no longer fades a scene's veil, the host grace is never applied): 7 of the 26 `WallpaperSwitchHoldTests` failed; the file was restored
- Not run: the full gate, `scripts/check_rust.py` and the renderer checks (no Rust, bridge or C++ change in this commit), and the gated window cases of the lane's first two commits (`case_wallpaper_window_layer_swap_revert`, `case_wallpaper_window_layer_swap_finish`, `case_wallpaper_window_announces_layers`)
- Unverified, desktop only: a sublayer above the `CAMetalLayer` composites over its drawables and hides the black placeholder, scene surfaces answer the still request within 250 ms (a paused renderer included), the held still looks like the live frame it replaces, the 0.2 s fade, Reduce Motion, multi-display and mirror switches (checklist in manual-smoke.md)

## 2026-10-13 — Workshop downloads in the menu bar

StatusMenuModel.DownloadActivity and WorkshopDownloadManager.inProgressTransfers: while Workshop downloads run, a line under Control Panel reads Downloads: N in progress with a byte-weighted percent that is left out when any counted job cannot report a size and stops at 99, and opens Discover. Built when the menu opens (no timer). Commit 10 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only StatusMenuModelTests --only DownloadQueueTests --only WorkshopDownloadPersistenceTests --only WorkshopStoreTests --only AppAutomationTests --only AutomationCommandTests --only ControlPanelAutomationTests --only DownloaderLifecycleTests` — exit 0; 116 passed, 0 failed, 0 skipped
- Mutation check: counting a paused job, counting the sign-in job and letting the percent reach 100 each failed the test written for it (3 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the native catalog key `Downloads: %lld in progress, %lld%%` was confirmed against what the Swift compiler extracts for the literal)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py`, `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the line draws and reads in the real menu, that it appears while a real SteamCMD transfer reports bytes, and that choosing it brings Discover forward; see manual-smoke "Download queue"

## 2026-10-13 — Mute every wallpaper (menu bar, links, Shortcuts, shortcut key)

PlaybackPreferences.wallpapersMuted, OR-ed into WallpaperPresentationPolicy's audio suppression (the bridge's audio_suppressed, which the engine ORs with each wallpaper's saved mute), reached from a ticked Mute Wallpapers menu item, wallpapermachine://mute, unmute and togglemute, three Shortcuts actions, a shortcut key and a Settings → Performance → Playback switch. Commit 9 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate. No Rust, bridge or renderer change.

- `python3 scripts/test.py --only PlaybackPolicyCompositionTests --only PlaybackPreferencesTests --only AutomationCommandTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WebPanelGeneralSettingsTests --only WallpaperBackupTests --only WallpaperPresentationPolicyTests` plus AppAutomationTests, GlobalHotKeysTests, WebPanelPerformanceSettingsTests, ControlPanelShellTests, WebPanelExternalLinkTests, WebPanelAssetsTests, ControlPanelAutomationTests, WallpaperActivationRecoveryTests, OtherAudioMonitorTests, AppRuleMonitorTests and SystemConditionMonitorTests — exit 0; 247 passed, 0 failed, 0 skipped
- Mutation check: dropping the user mute from the policy, the muted arm of the menu item's condition, the unchanged-value guard in the preference and the Settings row each failed the tests written for them (5 failures); all were reverted
- Every scripts/tests/test_*.py module run directly — 316 passed (the WebUI key check includes the new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: that scene, video (Native and Compatibility) and Web wallpapers really go silent and come back through an audio output (audio hardware needs an authorized desktop run; only the suppression delivered to the bridge is tested), how the ticked menu item draws and reads, Siri or Shortcuts listing the three actions, and a real shortcut key press; see manual-smoke "Audio responsiveness"

## 2026-10-13 — Random Wallpaper command

A new AutomationCommand.random(display:pool:) with pools all and favorites, reached from the menu bar, wallpapermachine://random, a Shortcuts action and a shortcut key. Its pick comes from PlaylistStore.randomPick with a round of its own per display and pool (kept beside the shuffle rounds in WallpaperMachine.playlistRounds), and BridgeStore.activateRandomWallpaperAsync makes it in the display's turn of the command queue. Commit 8 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1; targeted runs only, not the full gate.

- `python3 scripts/test.py --only AutomationCommandTests --only PlaylistStoreTests --only PlaylistPlannerTests --only HotKeyPreferencesTests --only StatusMenuModelTests --only WallpaperDisplayTransferIntegrationTests --only WebPanelGeneralSettingsTests` — exit 0; 105 passed, 0 failed, 0 skipped
- `python3 scripts/test.py --only AppAutomationTests --only GlobalHotKeysTests --only PlaylistSchedulerTests --only WebPanelPlaylistTests --only WallpaperBackupTests --only ControlPanelPlaybackToolsTests --only ControlPanelShellTests --only WebPanelAssetsTests --only ActivationLogTests --only WallpaperActivationRecoveryTests` — exit 0; 172 passed, 0 failed, 0 skipped
- Mutation check: dropping the held-wallpaper exclusion and recording a pick before it was applied each failed the integration test written for it; both were reverted
- Every scripts/tests/test_*.py module run directly — all passed (the WebUI key check includes the two new keys in ja, zh-Hans and zh-Hant)
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_rust.py` and `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the menu item draws and reads, a real shortcut key press, Siri or Shortcuts listing the action and its Choose from option, and how a random pick looks on real displays; see manual-smoke "The menu bar with two displays"

## 2026-10-13 — Menu bar: control each display

The menu bar menu gets a submenu per display when two or more displays can show their own wallpaper (StatusMenuModel), with Remove from Display, Start Again and Open in Control Panel; one display keeps the flat menu. Lane worktree, targeted run only, not the full gate.

- `python3 scripts/test.py --only StatusMenuModelTests --only AutomationCommandTests --only WallpaperDisplayTransferIntegrationTests --only AppAutomationTests --only UserCommandQueueTests --only WallpaperActivationRecoveryTests --only WallpaperDisplayTransferTests --only HotKeyPreferencesTests --only GlobalHotKeysTests --only DisplayTitleResolverTests` — exit 0; 107 passed, 0 failed, 0 skipped
- `python3 -m unittest discover -s scripts/tests -p test_panel_localization.py` — OK (6 tests); the three new native strings are in all four languages
- Not run: the full `python3 scripts/test.py` gate, `python3 scripts/check_renderer.py` (no Rust, bridge or renderer change), Release build, any desktop run
- Not covered: how the NSMenu draws, orders and reads (VoiceOver) with two or more real displays, and Remove then Start Again on real displays; see manual-smoke "The menu bar with two displays"

## 2026-10-13 — Apply a wallpaper to every display

A new transfer request, WallpaperDisplayTransfer.Request.everywhere, expands over the eligible displays when it is planned (main display first), so it keeps copy and swap's preflight, re-plan after preparing and verified rollback. Entry points: the inspector's Apply to all displays, apply?id=…&display=all and Apply Wallpaper's On all displays. Commit 6 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only WallpaperDisplayTransferTests --only WallpaperDisplayTransferIntegrationTests --only AutomationCommandTests --only ControlPanelDisplayLayoutTests --only WallpaperReapplyPanelTests --only AppAutomationTests --only ControlPanelLibraryTests --only WebPanelGeneralSettingsTests --only ControlPanelAutomationTests --only WallpaperActivationRecoveryTests --only ActivationLogTests --only WorkshopApplyOnArrivalTests --only ControlPanelShellTests --only WallpaperBackupTests` — 191 passed, 0 failed, 0 skipped
- Every module under `scripts/tests/` passes, including the new WebUI catalog key in zh-Hans, zh-Hant and ja.
- Mutation checks: with the main display no longer planned first, or the choice counted for no display when asked for, the matching transfer and integration tests fail and the rest pass. The first inspector test run failed because putting the displays back selects the wallpaper they showed, so the failure notice sat on a wallpaper the panel no longer showed; the panel now returns to the wallpaper it applied.
- Not run: the full gate, a Release build, any desktop run. Unverified: a real two-monitor apply and rollback, the button in the narrow inspector, and Shortcuts showing the On all displays switch; the display set is a two-display test bridge. See the new row in manual-smoke.md.

## 2026-10-13 — Rotate on unlock

A third How often choice for rotating playlists, Each time the Mac is unlocked (DisplayPlaylist.trigger). The presentation policy reports the locked-to-unlocked edge of its corrected lock state; PlaylistScheduler answers it for every display that waits for it, once, within a 30 second window. Commit 5 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only WallpaperPresentationPolicyTests --only PlaylistSchedulerTests --only PlaylistStoreTests --only PlaylistPlannerTests --only WebPanelPlaylistTests --only ControlPanelPlaybackToolsTests --only WallpaperBackupTests --only WallpaperAutomationSchedulerTests --only PlaybackPolicyCompositionTests --only ControlPanelAutomationTests --only ControlPanelHeldWallpaperTests` — 200 passed, 0 failed, 0 skipped
- Every module under `scripts/tests/` passes, including the new WebUI catalog keys in zh-Hans, zh-Hant and ja.
- Mutation checks: with Change now no longer answering a waiting unlock, or with the 30 second window never expiring, the matching scheduler test fails and the rest pass.
- Not run: the full gate, a Release build, any desktop run. Unverified: the order of the operating system's unlock events against a display waking, an unlock with a second display re-enumerating, and the visible change after unlock; the scheduler logic runs under fakes. See the new row in manual-smoke.md.

## 2026-10-13 — Switch to stop writing the macOS desktop picture

Settings › General › Use the wallpaper as the macOS desktop picture, on by default. Off, poster writes stop, the user's own picture is put back with the quit's verified restore, and a poster left behind is repaired at launch. Commit 1 of the desktop-menubar lane, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only PlaybackPreferencesTests --only DesktopWallpaperTests --only WebPanelGeneralSettingsTests --only LockScreenWallpaperServiceTests` — 133 passed, 0 failed, 0 skipped
- All Desktop, LockScreen, Panel and Lifecycle test classes — 839 passed, 0 failed, 0 skipped; `scripts/tests/test_panel_localization.py` passes with the new catalog keys
- Mutation check: with the settings.js row removed, the offscreen row test fails and the rest pass.
- Not run: the full gate, a Release build, any desktop run. Unverified: what Mission Control and the Spaces bar show after the switch goes off and on, the macOS 27 read-back during the 25-attempt restore, enabling Animate lock screen with the switch off, and the relaunch repair; `AppDelegate`'s decision of when to restore is wiring that no unit test reaches. See the new rows in manual-smoke.md.

## 2026-10-13 — Native video wake and resume repair

A stalled native video pipeline is now kicked, rebuilt once and then handed to Compatibility, after a resume, a wake or an unlock. Commit `fix(native-video): repair a stalled pipeline after a resume, wake or unlock`, checked in an isolated worktree on macOS 27.0.1.

- `python3 scripts/test.py --only NativeVideoHealthLadderTests --only NativeVideoHealthSupervisorTests --only NativeVideoWallpaperHostTests --only NativeVideoRecoveryBudgetTests --only NativeVideoLivenessTests` — 142 passed, 0 failed, 0 skipped
- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlayerMediaTests` — 37 passed, 0 skipped, twice (the hev1 clip is frame-less on this OS, so the kick, rebuild and give-up cases ran); all NativeVideo classes plus RuntimeCountersTests and WallpaperPresentationPolicyTests with media on: 256 passed, 0 failed, 0 skipped
- Mutation checks, each failing exactly the tests that defend it and then reverted: no absorb rule while repairing, no supersession of a wake settle, a rebuild that cancels its own check.
- The lock-screen extension target compiled the two new `RuntimeCounter` cases in the same builds.
- Not run: the full gate, a Release build, any desktop run. Unverified: that the system really reclaims a decoder across sleep, lock or a covered desktop, and that a kick or a rebuild brings one back; the `hev1` pipeline cannot be repaired, so only the failing ladder is shown. The 1 s wake settle and the cost of the check output on a 4K clip are untuned. See the sleep, lock and unlock rows in manual-smoke.md.
