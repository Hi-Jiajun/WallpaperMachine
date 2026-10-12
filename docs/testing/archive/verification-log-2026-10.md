# Verification log archive — 2026-10 and earlier

Retired entries from [../verification-log.md](../verification-log.md), moved
here when that log was capped at its ten newest entries. No recorded result was
rewritten: each entry is reproduced verbatim, and the only edit is that
relative Markdown links gained one `../` for this file's extra directory
level.

These are historical results about the trees they were taken on. They are not
evidence about the current tree and must never be cited as such.

## 2026-10-10 — Energy readout: native video left out, macOS 27 ABI rechecked

- Change: readings while a video is on the native player carry nativeVideo (no grade, battery share or comparison); the per-wallpaper recorder skips intervals with a presenting native-video display; ratings carry version 2 and a video's unversioned rating is hidden and replaced, not averaged.
- Evidence for the fix: a stored rating of 0.18 mW over 4.4 h for a video wallpaper; GPU billed_to_me fields are 0 in all 818 coalitions; decoding 720p H.264 at ~1,700 fps charged ~2 W CPU and 0 GPU.
- ABI on M5 Pro, macOS 27.0.1: struct coalition_resource_usage is 50 fields (5 appended); indices 8/11/41 unchanged. Saturating Metal load: coalition 16.85 W, all coalitions 17.56 W, IOReport GPU Energy 17.94 W.
- Unchanged: the 0.25 contention threshold. A 60 fps probe read 91 mW alone and 162 mW at 21 % other GPU time (below the flag); documented, not retuned.
- Tests: python3 scripts/test.py --only EnergyUsageMonitorTests --only WallpaperEnergyRatingsTests --only WebPanelEnergyUsageTests (23 passed); new GPU-counter guard failed once on a cold test host (0 mW after 0.8 s) and now waits up to 5 s for a post, then passed 4 runs.
- Full gate: python3 scripts/test.py — 1319 passed, 0 failed, 14 skipped (opt-in media and network layers).
- Page: node --check WebUI/settings.js; energyControl rendered in Node for native, native+contended, contended and normal readings. The panel itself was not opened (no desktop authorization).
- Not verified: a native-video wallpaper end to end in the running app, and the hardware decoder's own energy (needs powermetrics/root).

## 2026-10-09 — Keep web wallpapers animating through Show Desktop pointer moves

- Symptom: a web wallpaper (3747222633) froze briefly on every hot-corner Show Desktop; scene wallpapers did not. Unified logs showed no host suspension, WebKit activity-state change or poster capture at those moments.
- Before evidence (installed v1.3.2, three Show Desktops, 3 s sample of app/WebContent/GPU each): app main thread spent 122/234/210 ms in NSWindow.windowNumber(at:) via SLSCopyWindowRoutingRecordsForScreenLocation from WebWallpaperMouseForwarder, 0 ms in the idle baseline; WebContent updateRendering samples fell 20–45% in the same windows.
- Fix: routing reads the window the window server recorded in the event (kCGMouseEventWindowUnderMousePointer); only a press or scroll without it still queries, a move without it is dropped.
- Hand probe on real global-monitor events: field 91 matched windowNumber(at:) in 1536 of 1540 events (4 were transient screenshot-tool windows), never 0. Field 92 skipped the menu bar for moves, so it was not used. No scroll events were captured.
- python3 scripts/test.py --only WebWallpaperMouseRoutingTests: 6 passed (2 new); synthesized scroll events do not keep the field, so scrolls are covered by the fallback test.
- python3 scripts/test.py: 267 Python tests passed; native 1315 passed, 0 failed, 14 skipped of 1329. Full gate run once.
- Gap: smoothness after the fix on the real desktop is not yet measured; the same capture script must be re-run against a build that contains it.
- Separate, unfixed: a web page assigned while its display is suspended loads detached, so its first reveal is a cold start (327 ms hidden content plus shader compiles on 2026-10-09 18:03:57).

## 2026-10-09 — v1.3.2 published release and import-helper recovery

- Published [v1.3.2](https://github.com/WallpaperMachine/WallpaperMachine/releases/tag/v1.3.2), build 31, from `e278ae8f205e324835facd6f84c70e27f3d31cc7`; [Version run 37825423704](https://github.com/WallpaperMachine/WallpaperMachine/actions/runs/37825423704) passed every required job. Failed, unpublished v1.3.0/v1.3.1 tags were preserved; notes cover v1.2.6 through v1.3.2.
- Import-helper repair `8fb411a`: six targeted child-process tests passed normally and with `TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. Local `python3 scripts/test.py` passed 268 Python and 1,313 native tests, with 14 skips; no desktop picker was opened.
- CI `python3 scripts/test.py --serial` passed 268 Python and 1,312 native tests, with 15 skips and no failures. Rust core, bridge, core-integration and shader checks passed; six explicit desktop/corpus exclusions and three missing-asset shader skips remain unverified.
- CI renderer checks passed 12 generated pixel comparisons and eight projects through two reloads. Seven asset-dependent cases were skipped. The compiled timer probe exited 77 (35.20 ms median for a 10 ms wait), so ten named wall-clock cadence cases were skipped under `--allow-imprecise-timers`; these skips are not passing runtime coverage.
- CI verified the Release bundle and mounted disk image. Independently downloaded the public DMG: 36,496,549 bytes, SHA-256 `abaa683f21d1c24e97f8eb6f8c08839e9ba1bc0a4b573b893ea1d4258af47e32`; it matches the CI artifact, public sidecar, release asset metadata and public latest update manifest.
- Release body matches the tagged English notes and `Built from` commit; bundled changelog contains English and Simplified Chinese. Latest resolves to v1.3.2 and equals the highest public stable version. Public DMG and manifest requests succeeded.
- `gh attestation verify` passed for the public DMG, restricted to this repository and `.github/workflows/build.yml`, rejecting self-hosted runners and enforcing source digest `8fb411a34d05dc1a3f4218afaa1d647bc9d94089`. As documented, this event digest precedes the version-bump commit; `Built from` records the built revision.
- No install, launch/restart, desktop/Spaces/Mission Control/VoiceOver, real Siri/Focus, or manual disk-image smoke was performed. CI packaging and headless checks do not verify those surfaces. The release remains self-signed, not Developer ID signed or notarized.

## 2026-10-09 — Release recovery after hosted test timing failures

- v1.3.0 was tagged but not published: attempt 1 failed an onboarding test that counted incoming snapshots as requests; attempt 2 failed ThreadTimerTest.RequestsAfterALongWaitStillRespectTheCeiling on a host whose timer probe returned 77.
- Test-only welcome replay fix `5ff25f1` now checks outgoing actions and injects an unrelated snapshot. Application code remains unchanged.
- Added the omitted 50 ms cadence test to the existing exact-name CI fallback, only after the compiled timer probe reports imprecise timers. Default local runs still execute it; other failures remain failures.
- Version workflow accepts optional notes_from, passed as release_notes.py --previous, so a new patch after an unpublished failed tag can include all changes since the last public release. Tags and live releases are not rewritten.
- Python renderer/version/release-notes suites: 106 passed. Workflow shell arguments verified for default and explicit previous tag; developer preview includes the unpublished feature commits from v1.2.6.
- Full local gate: 268 Python and 1,312 native passed, 0 failed, 14 skipped; artifacts/tests/Tests-20261009-012014-576231.xcresult (disposable).
- First local renderer pass hit the time-sensitive UnchangedPresent frame-order assertion. Separate rerun python3 scripts/check_renderer.py --skip-build passed, with realtime_checks_executed=true, 12 equal pixel comparisons and 8 x 2 reloads; four asset checks skipped. Evidence artifacts/renderer/adaptive-20261009-012147 (disposable).
- No runtime implementation, desktop interaction, installation, first-launch or manual-smoke changes. Recovery publication is tracked separately and must still pass the CI gate.

## 2026-10-09 — Integrate Mission Control refreshes with Space-scoped posters

- Integrated upstream `dc6b764` (Mission Control refresh/settling, injected-clock downloader tests and Supporter list) with feature commit `81eb112`; preserved both histories without rebase or force.
- Kept JPEG encoding, changed-frame deduplication, immediate/3 s/15 s/optional 5-minute captures and lock-screen settling while retaining per-Space request contexts and scoped poster ownership.
- Added regressions proving settling/periodic requests use the current Space context and respect hold, and identical pixels are reused on another Space only after a fresh context is confirmed.
- Targeted desktop/native-video/Space/scheduler/lock-screen-authority/downloader tests — 129 passed, 0 failed, 0 skipped.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,312 passed, 0 failed, 14 skipped of 1,326. Full gate ran once for this integration.
- Native evidence: `artifacts/tests/Tests-20261009-001715-304824.xcresult` and same-name `.log` (disposable local evidence).
- Renderer/bridge source is unchanged from the feature commit; the prior renderer-only build and 12 pixel comparisons plus 8 x 2 reloads remain applicable. Four asset checks were skipped, not passing asset coverage.
- All 64 pre-existing verification entries from both merge parents were retained using the verification-log script; the active log remains bounded to ten entries. Diff and agent-path checks passed.
- No real desktop/Mission Control/Space transitions, visible UI, VoiceOver, Release app rebuild or install/restart was performed. User authorized commit and push; remote delivery is checked separately after this commit.

## 2026-10-08 — Lock-screen desktop settles before holding a frame

- Report: AbyssGaming【琉璃】 left Mission Control Space thumbnails black with Animate lock screen on; DesktopPosters was empty (poster sync suspended, extension owns Desktop).
- Root cause: offscreen_scene_probe, 21 frames at 1 s steps: frame 0 mean brightness 0.0, 67.8 at 1 s, ~122-135 from 2 s on. The extension held its readiness frame.
- Fix: WallpaperPresentationAuthority.desktopSettleBudget (15 s) keeps an unlocked lock-screen surface animating after its first frame; on pausing it reads the held frame back for snapshots/backing.
- python3 scripts/test.py --only WallpaperPresentationAuthorityTests: 16 passed. python3 scripts/test.py: 1215 passed, 0 failed, 14 skipped.
- Not checked: real Mission Control thumbnails with the extension; whether WallpaperAgent re-reads the extension snapshot after it pauses.

## 2026-10-08 — Mission Control poster refresh

- Change: desktop poster retaken 3 s and 15 s after a new/changed/resumed wallpaper, fresh capture on Space change and wake, unchanged frames skipped by pixel digest, JPEG (q0.9) instead of PNG, optional 5-minute refresh in Settings › General.
- Encode cost measured on M5 Pro at 3456x2234: PNG ~215 ms / 8.9 MB, JPEG ~32 ms / 2.8 MB, HEIC ~40 ms / 2.3 MB (synthetic graded frame).
- python3 scripts/test.py --only DesktopWallpaperTests --only PlaybackPreferencesTests: 49 passed.
- python3 scripts/test.py: 1214 passed, 0 failed, 14 skipped (opt-in layers).
- Not checked: real Mission Control thumbnails, WallpaperAgent caching of replaced pictures, the lock-screen-provider mode (unchanged; still a frozen frame). Needs the manual-smoke Mission Control steps.

## 2026-10-08 — Desktop Space choices and scoped poster ownership

- Added experimental Follow desktop Space automation: per-display UUID choices for wallpapers/playlists, persistent visit identities, manual overrides until the next regular desktop visit, fullscreen exclusion, Focus priority and animated-lock-screen conflict checks.
- `python3 scripts/build.py --renderer-only` — exit 0; rebuilt the renderer static library and regenerated bindings for the Objective-C++ poster context change. No Release app bundle was rebuilt or delivered.
- `python3 scripts/test.py` — exit 0; 268 Python passed; native 1,305 passed, 0 failed, 14 skipped of 1,319. Full gate ran once in this batch. Native evidence: `artifacts/tests/Tests-20261008-235505-811159.xcresult` and same-name `.log` (disposable).
- Targeted monitor/scheduler/store/poster/native-video/panel/backup run — 129 passed; poster scheduling/integration follow-up — 51 passed; final orphan-focus panel run — 2 passed.
- `python3 scripts/check_renderer.py` — exit 0; 12 generated pooled/isolated pixel comparisons matched, diagnostics 0; 8 projects x 2 reloads passed. Four local-asset checks skipped. Evidence: `artifacts/renderer/adaptive-20261008-234144` (disposable).
- Regression coverage includes independent/shared display groups, malformed/ambiguous topology, desktop reorder, fullscreen entries without UUIDs, visit persistence, paused catch-up, rapid queued switches, Focus exit with unknown topology, old-schema migration and backup transient-state exclusion/rollback.
- Scoped poster tests cover current-Space-only writes, public-fallback exclusion, late request/encode rejection, mode changes, replacement gaps, current-only eject and all-Space restore. Native-video poster context is exercised through the real coordinator with a fake surface; Scene bindings carry context beside captured request generations.
- Offscreen WKWebView tests cover choice save, UUID-preserving reorder, current-desktop accessible name, unavailable mode/native validation, orphan removal and final-orphan focus. One Impeccable detector invocation returned `[]`; source-only reviewer disposition `ship` for its single corrected focus finding.
- Localization and JS syntax checks passed; 192 local documentation links resolved; diff check passed excluding generator-owned bindings. Upstream provenance updated, notices retained, CLAUDE.md remains a relative AGENTS.md symlink; no agent state staged.
- No desktop/window/screenshot, actual Mission Control/Space/Focus transitions, visible layout, VoiceOver, installed-app test, install/restart, commit or push. Inactive Spaces retain posters, not resident renderer instances; brief reload transitions and animated-lock-screen incompatibility are documented.

## 2026-10-08 — Multi-display wallpaper layouts, copy and swap

- Added saved per-display wallpaper arrangements, independent-display copy/swap, a searchable Shortcuts layout action, URL routing and backup merge support. Separate live per-Space assignments remain unimplemented.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,290 passed, 0 failed, 14 skipped of 1,304. Full gate ran once for this batch.
- Native evidence: `artifacts/tests/Tests-20261008-230934-164642.xcresult`, log `Tests-20261008-230934-164642.log` (disposable local evidence). Existing live Workshop/SteamCMD and native-media skips remain skipped.
- Targeted core/store/BridgeStore integration tests — 15 passed; panel/backup/integration/command/catalog run — 44 passed; final focus-boundary panel/store run — 7 passed. A test fixture return type was corrected before these successful runs.
- Checked complete preflight, copy/swap from original assignments, failure after mutation, restoring empty destinations, preserving unexpected external choices, cancellation cleanup, clean-editor admission, net history and newer queued user commands.
- Offscreen WKWebView tests cover save/rename/apply/delete, copy/swap and recovery errors, escaped names, missing-screen eligibility, Escape/focus return, English/Chinese/Japanese at 760 points and saving the 64th layout.
- Panel/native localization coverage and JavaScript syntax checks passed; 160 local documentation links resolved. Impeccable detector returned `[]` once on this batch's changed JS/CSS.
- Static review disposition `ship` for its single focus finding after correction and regression coverage. Rendered appearance and VoiceOver remain unverified; no additional visual inspection was authorized.
- `git diff --check -- . ':!App/Bridge/Generated'` passed; existing generator-owned output from the preview batch is excluded. CLAUDE.md remains a relative symlink to AGENTS.md; no agent state was staged.
- No renderer/bridge ABI changes in this batch, so prior renderer checks were not rerun. No desktop/windows/screenshots, real multi-monitor compositor/Spaces or Siri/Shortcuts run, Release rebuild, install, commit or push.

## 2026-10-08 — Advanced wallpaper automation and Focus restoration

- Added per-display weekday/time/sunrise/sunset and system-appearance choices, temporary Focus wallpaper/playlist overrides, and saved playlist/property preset Shortcuts and URLs.
- `python3 scripts/test.py` — exit 0; 268 Python tests passed; native 1,270 passed, 0 failed, 14 skipped of 1,284. Full gate ran once for this batch; no renderer code changed in this batch.
- Full native evidence: `artifacts/tests/Tests-20261008-194956-595159.xcresult`; log `Tests-20261008-194956-595159.log` (disposable local evidence).
- Targeted automation/planner/store/Focus/panel/command/catalog tests — 35 passed. Offscreen automation editor and backup tests — 33 passed after correcting a test-fixture initializer argument order.
- Covered DST and solar boundaries, persisted/manual precedence, Focus restoration and interrupted state, deleted saved plans, queued multi-field playlist edits, backup merge and rollback.
- Offscreen WKWebView flows cover save/edit/cancel/delete, hidden invalid timing fields, local weekday errors/focus, appearance clearing, solar location save/clear and compact overflow.
- Panel localization checks passed for English source plus Simplified Chinese, Traditional Chinese and Japanese; JavaScript syntax checks passed; 168 local documentation links resolved.
- Impeccable detector returned `[]` on the three changed automation/settings UI sources. Static reviewer disposition `ship` for the three listed fixes, all resolved; rendered appearance and VoiceOver remain unchecked.
- `git diff --check -- . ':!App/Bridge/Generated'` passed; generator-owned bindings from the preceding preview batch retain generator whitespace. `CLAUDE.md` remains a relative symlink to `AGENTS.md`.
- No live Focus/appearance transitions, Siri/Shortcuts, desktop interaction, screenshots, permission prompts, Release rebuild, installation, commit or push. Existing corpus/runtime skips remain skipped, not passing asset evidence.

## 2026-10-08 — Independent live wallpaper preview

- Added an explicit preview window for installed Scene, Video and Web wallpapers. Read-only draft export, independent playback, mute by default, reload, scoped pointer input and close/replacement cleanup leave desktop assignments and history unchanged.
- python3 scripts/build.py --renderer-only: exit 0; regenerated UniFFI bindings for wallpaper_preview. project.yml and XcodeGen include the existing renderer C header for the app and hosted tests; no vendored C++ behavior changed.
- python3 scripts/test.py: final exit 0; all 268 Python tests passed; native tests 1242 passed, 0 failed, 14 skipped of 1256. An earlier gate stopped at CodeSign because com.apple.FinderInfo returned on disposable Debug output; only that attribute was removed before rerunning.
- The 14 native skips remain opt-in real-media, live Steam installation and live Workshop network cases. Preview regressions use isolated fixtures/offscreen views and cover drafts, path bounds, storage isolation, mute, cancellation, generation fences, readiness timeout, pointer mapping and the inspector action.
- WallpaperPreviewLayoutTests checks the 480-point NSView content in English, Chinese and Japanese without an NSWindow; controls fit and errors retain a full-width selectable row and complete tooltip. Scoped static UI review findings were resolved; the WebUI mechanical detector returned no findings.
- python3 scripts/check_rust.py: exit 0 for core, bridge, core-integration and shader groups. Six desktop/corpus cases were explicitly excluded and three asset-dependent shader checks reported skips; those surfaces remain unverified.
- python3 scripts/check_renderer.py: exit 0 with GPU and realtime checks enabled. All 12 generated pooled/isolated pixel pairs matched with no diagnostics; 8 projects completed two reload cycles. Four local-asset cases were skipped (2 text, 1 video, 1 native-Metal local-project case).
- Localization checks and local documentation link checks passed. git diff --check passed excluding raw generator-owned UniFFI output, whose existing generator emits trailing whitespace; bindings were not edited manually.
- Actual preview-window presentation, Scene/Video swapchain first frames in that window, OS visibility transitions and VoiceOver were not exercised. Web FPS is a cooperative host-property request; preview audio response and media integration are unavailable. No Release app, installation or desktop run was requested or delivered.

## 2026-10-08 — Wallpaper history, playlist ordering and failure recovery

- python3 scripts/test.py: exit 0; all 268 Python tests passed; native tests 1227 passed, 0 failed, 14 skipped of 1241. The full gate ran once after integration.
- The 14 native skips were 11 opt-in NativeVideoPlayerMediaTests and 3 live Steam/Workshop network or installation tests; no real media or live-account coverage is claimed.
- Targeted final run of ControlPanelPlaybackToolsTests and WallpaperActivationRecoveryTests: 21 passed, 0 failed, 0 skipped. Offscreen WebKit covered repeated keyboard moves, boundary focus fallback, drag sorting, stale-drag rejection, history order, escaped titles, current-state accessibility and target-only clearing.
- History and playlist regressions cover persistence, bounded recent lists, repeated Previous, failed-apply preservation, exact reorder membership, cooldown expiry, cancellation, bounded fallback attempts and a newer manual command taking precedence.
- python3 -m unittest scripts.tests.test_panel_localization: 5 passed. node --check succeeded for panel.js, settings.js and playlist-order.js. The Impeccable mechanical detector returned no findings for the changed WebUI targets; the scoped source review findings were resolved.
- XcodeGen regenerated the project for WallpaperHistoryStore and its new test files. Local documentation link targets and git diff --check passed.
- The first targeted build was blocked by com.apple.FinderInfo on disposable Debug products. Only that attribute was removed from build/Build/Products/Debug before the successful test runs.
- Desktop playback, OS shortcut invocation, actual dragging in an on-screen window and VoiceOver were not exercised. Failure skipping handles errors returned by Apply; it does not diagnose a visual defect after a successful assignment.
- No Release build, installation, app launch/restart, commit or push was requested or performed.

## 2026-10-07 — Keep web wallpaper animation running through transient occlusion

- Desktop web pages now leave window occlusion to WallpaperPresentationPolicy through a guarded per-view WebKit selector; host detach and inactive suspension remain in place.
- Before the fix, the new offscreen transient-occlusion regression failed because animation frames stopped while the host still allowed playback.
- python3 scripts/test.py --only WebWallpaperSuspensionTests: 5 passed, 0 failed, 0 skipped after the fix.
- python3 scripts/test.py: 268 Python tests passed; 1211 native tests passed, 0 failed, 14 skipped of 1225. Full gate run once.
- Skipped: 11 native media/device cases, 2 live Workshop searches, and 1 live SteamCMD install; opt-in layers were not enabled.
- The first targeted build hit the documented Finder metadata signing failure; clearing xattrs from Debug products let the unchanged command run.
- The regression uses an unshown window with simulated occlusion. Real Show Desktop/Space animations and the original wallpaper were not exercised on the desktop.
- No renderer changes, Release build, app installation/restart, settings mutation, commit, or push.

## 2026-10-07 — Automatic recovery from duplicate wallpaper extensions

- Activation now validates and reconciles native extension registrations to the running app, preserving other app bundles and verifying the resulting registry.
- A wrong extension copy triggers one fresh activation; snapshot refreshes share registration work and preserve the recovery limit, while disabling or shutdown cancels preparation.
- Read-only pluginkit discovery confirmed installed and worktree Debug registrations before implementation; no live registration-repair command was executed.
- Targeted iteration: python3 scripts/test.py --only LockScreenExtensionRegistrationTests --only LockScreenWallpaperServiceTests --only LockScreenExtensionDiagnosticsTests passed 60 tests; the final gate also covers parent-unregistration removing its extension first (61 related tests passed).
- Full gate, run once: python3 scripts/test.py exited 0; 268 Python script tests passed; native tests: 1209 passed, 0 failed, 14 skipped of 1223.
- Skipped opt-in coverage: 11 NativeVideoPlayerMediaTests and 3 live Steam network/install tests; no private asset corpus or desktop checks were run.
- Initial targeted compilation hit the documented Finder/File Provider xattr signing issue; cleared disposable Debug product xattrs with xattr -cr build/Build/Products/Debug, then verified through the passing gate.
- git diff --check passed; owning documentation links resolve; all shipped native language catalogs contain the new messages.
- Unverified: real LaunchServices/PlugInKit repair convergence, macOS choosing the intended extension, and visible lock-screen/screen-saver transitions. No Release build, app installation/restart, or desktop automation.

## 2026-10-05 — Code audit fixes: downloads, playlists, Discover, lock screen, updater, panel

- Scope: 16 fixes and Open on Steam from a read-only audit of aa47389 (Swift app, WebUI, bridge to panel); no renderer change.
- python3 scripts/test.py: Python suites OK; native 1186 passed, 0 failed, 14 skipped of 1200 (opt-in media and network tests).
- New tests that failed before their fix: silent Workshop transfer outliving the timeouts (mutation-checked), lock-screen refresh during readiness wait, failed resume across display reconnect.
- Also covered: failed source switch clears Discover and pixiv, requested playlist skip while paused, allowlisted panel links, queued panel request after a failure, screened subscriptions empty state, collections read-limit count, update digest required, newest poster per display, Steam cookie redirect stripping, paused web audio demand.
- Web navigation: refused top-frame navigation, replaced loads and hash routing never fail the page even without filtering; the suspected -999 report was not reproducible, so no code change.
- Not unit-testable, not run on a desktop: per-display uncover re-evaluating playlists, error alerts from the main run loop, poster sync in screen-saver-only mode, Open after a failed start.
- Not done: update code-signature pinning (self-signed release certificate, planned Developer ID move); setenv race in BridgeStore not reproducible.
- No Release build, no desktop, Steam sign-in or lock-screen run.

## 2026-10-05 — Discover Collections fill screened pages to 30

- Cause: under the default Everyone-only rating, WorkshopService.collections drops collections whose sampled wallpapers are Questionable/Mature; live Steam page 1 (trend, 365 days) kept 9 of 30.
- Fix: WorkshopStore.filledPage fills each panel page from consecutive screened Steam pages (cursor per page, cap 10, next page fetched alongside); page/result counts are estimates; jumps start at an estimated Steam page.
- python3 scripts/test.py --only WorkshopSourceTests: 18 passed (new testScreenedCollectionsFillEachPageFromTheSteamPagesAfterIt).
- python3 scripts/test.py --only WorkshopStoreTests: 10 passed.
- python3 scripts/test.py: 1171 passed, 0 failed, 14 skipped.
- Not checked: the live panel against Steam (no desktop run); Release build follows.

## 2026-10-05 — Discover source tabs (Your subscriptions findable)

- Change: Discover's source <select> replaced by a tab row (Wallpapers / Collections / Your subscriptions) heading the toolbar; signed-in subscriptions summary leads with a primary Download-missing button, count and Sign out; empty subscriptions offer Browse Workshop.
- python3 scripts/test.py --only ControlPanelDiscoverTests --only WebPanelWorkshopSourceTests: 10 passed (new testDiscoverListsAreTabsAndSubscriptionsLeadWithTheirDownload, incl. one-row tabs at the 760px minimum with filters open).
- python3 scripts/test.py: 1170 passed, 0 failed, 14 skipped; Python localization catalog tests OK.
- impeccable detect on WebUI/panel.css, panel.js: no findings.
- Gap: no visual/desktop check (no screenshot authorization); layout verified only through offscreen WKWebView DOM geometry.

## 2026-10-05 — Local XHR startup compatibility for web wallpapers (landed on main)

Commit 41e88a2 (2026-10-03) existed only on a local main worktree; applied onto current main on 2026-10-05. Its original 2026-10-03 entry is carried over below, and the gate was re-run on the new base.

- 2026-10-03: private offscreen WKWebView probe with the original host script reproduced a local settings-loader JSON parse failure and retained splash. With the fix, the same read-only assets initialized a 1920×1080 canvas, removed the splash and reported no script errors across six samples. Audio/capture disabled, nonpersistent storage, no window or screenshot; desktop animation remains unverified.
- 2026-10-03: `python3 scripts/test.py --only WebWallpaperLocalRequestTests` — exit 0; 4 passed, covering synchronous startup, empty responses, async callbacks, JSON/binary bodies, missing files, abort, reuse and non-file metadata.
- 2026-10-03: full `python3 scripts/test.py` — exit 0 on retry after one picker-cancellation timeout that passed alone without code changes; 229 Python and 1075 native tests passed, 12 opt-in skips.
- 2026-10-05, on current main: `python3 scripts/test.py` — exit 0; 1169 passed, 0 failed, 14 skipped (media/network opt-ins). Conflicts were only the verification logs and the generated project; the project was regenerated with xcodegen.
- No renderer source changes; renderer gate not required. No desktop control, wallpaper changes, live audio, installation or app restart.

## 2026-10-05 — Native video keeps playing when its audio output cannot start (issue 31)

Workshop 3582362359 (H.264 Main@5.2, 2880x2160, 60 fps, AAC) was handed to Compatibility with AVErrorUnknown. Reproduced in a scratch AVPlayerLooper probe: while this Mac's audio output could not start, any clip with audio, including a generated control clip and a muted player, failed with -11800 over OSStatus -66681 (kAudioQueueErr_CannotStart); a missing output device fails with -11800 over -12746. The same clip with only its video track played at 60 fps in both cases.

- `WALLPAPER_MACHINE_MEDIA_TESTS=1 python3 scripts/test.py --only NativeVideoPlaybackFailureTests --only NativeVideoWallpaperHostTests --only NativeVideoPlayerMediaTests --only NativeVideoAdmissionTests --only SyntheticVideoFixtureTests` — 62 passed, 0 skipped
- With the fallback disabled, `NativeVideoPlayerMediaTests/testAClipWhoseAudioCannotStartKeepsPlayingItsPicture` fails (the clip is handed off); restored afterwards
- `python3 scripts/test.py` — 1165 passed, 0 failed, 14 skipped (media/network opt-ins)
- Compatibility path with the Workshop clip (temporary `unchanged_present_test` case, reverted): ~380–400 MB footprint, 400–580 MB Metal, flat over 40 s at 2560x1440; no VRAM growth reproduced
- Gap: the Compatibility black desktop in the report was not reproduced; one Compatibility run during the audio fault took 229 s instead of ~4 s with the stall unlocated, and a rerun after audio recovered did not repeat it
- Not run: `check_renderer.py` (no renderer change), desktop playback of the Workshop item

## 2026-10-05 — Issue #30: frozen panel, false first-frame timeout, poster refusal loop

Three fixes from one multi-display report: panel.js send() no longer strands a pending key when its busy render throws (the next tab click spun an endless microtask loop); the bridge facade waits for a first frame only where the engine opens or replaces a scene, judged against its live display snapshot instead of its own stale cache; the poster ledger leaves a desktop that keeps refusing posters alone until a Space change or wake.

- `python3 scripts/test.py --only ControlPanelShellTests/testTabsStayUsableAfterARenderThrowsWhileSending` against the unfixed panel.js — failed (page hung, execution time allowance); passes with the fix
- `python3 scripts/test.py --only DesktopWallpaperTests/testDesktopThatKeepsRefusingPostersWaitsForTheNextSpaceChange` against the unfixed ledger — failed (refusals rose 4 → 9; XCTest then stalled recording the assertion until the allowance); passes with the fix
- `cargo test -p wallpaper-bridge --lib first_frame_tests` — 3 passed
- `python3 scripts/check_renderer.py` — exit 0; skipped: 4 local-corpus tests (TextObjectRuntime ×2, AppleVideoFrame.LocalVideoImportsVisiblePixels, MetalSceneDraw.LocalProjects…)
- `python3 scripts/check_rust.py` — exit 0; core 222, bridge 381 passed; shader skipped 3 corpus cases
- `python3 scripts/test.py` — exit 0; 1173 tests: 1161 passed, 12 skipped
- Not verified: the reporter's 4-display Mac, real WallpaperAgent refusals, and that their freeze was this exact page loop (no panel console log was available); the SIGABRT in SharedVideoSourceHandle::prime and the raw BridgeError banner text are not addressed

## 2026-10-04 — Workshop preset media, background-copy masks and script property order (#28)

Issue #28: preset 3610485014 (base 2983846453, a day/night switch template) drew a black background and an unclipped switch at the canvas centre. Diagnostics showed native Metal falling back on files/*.mp4. Both items were fetched with the user-approved saved Steam session into a disposable scratch directory and assembled the way the importer does; nothing from them is committed.

- Before: `metal_scene_draw_smoke` (local project) fell back on the missing `files/*.mp4`, then on `link tex 89 not found`; layer 32's script moved the switch by 0 instead of the preset's (+1346, +830).
- After: native Metal accepts the scene (120 frames, no fallback), and `offscreen_scene_probe` (Vulkan) shows the same picture: video background, switch top right, clipped to its pill. This matches the reporter's Windows screenshot by eye; no pixel reference.
- New regressions, each confirmed failing without its fix: `SceneSourceMount.APresetFileBesideThePackageLoadsAndThePackageStillWins`, `LayerTextureReference.ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`, `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue`.
- `python3 scripts/check_renderer.py --project <assembled preset>`: exit 0. All generated cases are pooled/isolated equal with 0 diagnostics; the preset is pooled/isolated equal with 4 known diagnostics (`.mp4.tex` probes before the loose fallback, and the clock script's `createLayer({text})` drop shadow, which is unsupported and hidden). Skipped: corpus-dependent text_object_runtime, playback_gpu local video and metal local-project tests (env unset).
- `python3 scripts/test.py`: exit 0; 1157 passed, 12 skipped of 1169.
- `python3 scripts/build.py --configuration Release`: the first run failed configuring wallpaper-core, because a compiler-path change reset its stale CMake cache without the build script's `-D` flags; the unchanged retry built the app. Bindings were regenerated unchanged.
- Not verified: desktop or app run, clicking the day/night switch, audio bars. Text-layer `padding` given as an "x y" string still parses to 0 (pre-existing; no visible effect here).

## 2026-10-04 — v1.2.4 hosted-runner timer precision gate

- Cause: v1.2.4 Release runs 37185728032, 37188243177 and 37190006244 failed 'Renderer regressions without a desktop' (new in v1.2.4) on wall-clock cadence tests: 11 ticks of a 10 ms cadence in 600 ms, ~10 fps at a 60 fps ceiling; the background-priority reset (265339e) did not change it.
- Fix: check_renderer.py --allow-imprecise-timers compiles a probe (median of 31 condition-variable 10 ms waits); only its exit 77 (median > 20 ms) filters the nine REALTIME_TESTS by --gtest_filter and records each as a warned skip; build.yml passes the flag.
- Probe locally: 11.0 ms median (exit 0); under taskpolicy -b: 47.95 ms (exit 77), matching the CI signature.
- Filtered timer_tests (29), audio_tests (51) and unchanged_present_test (1) all passed on the local binaries; no filtered name ran.
- python3 scripts/check_renderer.py --skip-build --allow-missing-gpu --allow-imprecise-timers: exit 0, every cadence test executed, 12 generated scenes matched, reload 8x2 passed.
- A first full-build run failed FrameTimerTest.AnIdleBurstOfWakeOnceProducesOneCallback once under load average ~6; 0/40 on repeat, unrelated to this change, passed on all three CI runs.
- python3 scripts/test.py: Python suites passed (test_check_renderer 26 tests); native 1156 passed, 0 failed, 12 skipped.
- Gap: the hosted-runner skip path is proven only through mocked gate tests until the v1.2.4 Release run; no desktop, app launch or Release rebuild.

## 2026-10-04 — v1.2.4 background runner regression

- Reproduced the CI timer failure with taskpolicy -b; application scheduling alone did not clear inherited Darwin background policy.
- Child-only process and main-thread priority reset preserves real-time assertions; 20 renderer harness Python tests passed, including background inheritance and exit-status propagation.
- /usr/sbin/taskpolicy -b python3 scripts/check_renderer.py --skip-build: passed all required binaries, all 12 generated scene pixel comparisons and expected pixels with zero diagnostics, and eight reload projects twice.
- python3 scripts/test.py: Python checks passed; native suite 1156 passed, 0 failed, 12 optional media/network tests skipped.
- User commit 9a63ed3 and its bilingual release note remain included. Optional local wallpaper/video corpus tests were skipped; no desktop launch, install, audio hardware, or visual smoke test was performed.

## 2026-10-04 — Normalize complete puppet poses across animation layers

- Original synthetic regressions: both NonAdditive tests fail against the original WPPuppet.cpp and pass with the correction.
- CMake mdl_schema_tests and scene_schema_tests: exit 0; 57 model and 109 scene tests passed.
- python3 scripts/test.py: exit 0; Python checks passed, native gate 1156 passed, 0 failed, 12 opt-in media/network skips.
- python3 scripts/check_renderer.py --project <local-project>: exit 0; all 30 registered binaries succeeded; 12 generated scenes and one local scene had pooled/isolated pixel equality and zero diagnostics; local reload x2 passed.
- Renderer gate skipped two optional private text scenes, a private video import and its unconfigured local Metal case; the affected local scene was separately rendered successfully by metal_scene_draw_smoke.
- Private offline renders of Into The Abyss inspected at scene time 15 seconds on Compatibility and native Metal: hair and arm reassembled. Compatibility before/after both used 1024 passes across 16 samples and 276121600 allocated GPU bytes.
- python3 scripts/build.py --configuration Release: exit 0; rebuilt renderer and Release app. No installation or launch.
- git diff --check passed. Desktop presentation, live smoothness and energy use unverified; no desktop control, screen capture or audio hardware used.

## 2026-10-04 — PR 25 declaration-scoped arrays and camera FOV

- Resolve stage-interface macro bounds at each declaration, including intervening and function-body directives; freeze literal bounds before hoisting/input-copy emission. Shader pipeline revision 10 -> 11 invalidates previously cached stale-sized programs.
- Omitted/nonpositive camera FOV inherits immutable authored scene settings; named camera creation, runtime shots and non-runtime playback share the resolved value. Positive object overrides remain authoritative.
- `cargo test -p shader -- --nocapture` with the project Cargo environment — exit 0; 515 reported passed, including three unavailable asset-dependent early-return skips. SPIR-V/MSL per-declaration and undefined-macro regressions passed.
- Camera-targeted scene-schema run — 20 passed. Rebuilt full scene_schema_tests with the current shader library — 109 passed, including named/default cameras, scene/shot overrides and visibility fallback in both playback paths.
- `python3 scripts/build.py --renderer-only` — passed; generated bridge bindings unchanged. No Release app build.
- `python3 scripts/check_renderer.py` — every recorded binary exited zero; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- `python3 scripts/test.py` — all Python suites passed; 1,156 native passed, zero failed, 12 skipped.
- Corpus gaps: three shader cases, two renderer text scenes, the optional local video import case and environment-selected Metal projects skipped; these are not verified asset coverage.
- `git diff --check`, provenance JSON and generated-binding consistency passed. No desktop visual/live keyboard validation, authored-reference parity claim or app launch.

## 2026-10-03 — Software-decoded video GPU import

- Reproduced the initial GPU-import failure in the installed reported video, read-only, using playback_gpu_test --gtest_filter='DecodedFormats/*:AppleVideoFrame.LocalVideoImportsVisiblePixels' with WE_TEST_VIDEO. All five cases failed before the allocation fix and passed afterward.
- Generated BGRA, NV12, YUV420P and YUVJ420P cases verify exact strided color/alpha pixels after decoder-buffer release, with no conversion destination or CPU GPU-wait added by import.
- The local clip's first decoded frame imported successfully afterward: 667163 of 921600 pixels exceeded the visible-pixel threshold. This checks GPU texture import, not desktop presentation or authored-reference equivalence.
- python3 scripts/test.py: exit 0; Python modules passed; native tests 1156 passed, 0 failed, 12 opt-in skips.
- python3 scripts/check_renderer.py: exit 0; all 30 registered binaries passed; 12 generated pooled/isolated cases matched with expected pixels and no diagnostics; eight projects reloaded twice.
- Renderer skips: two asset-dependent text cases, one local-project Metal case, and WE_TEST_VIDEO unset in the routine gate. The video diagnostic was run separately with the reported clip; skipped asset cases are not claimed as passing.
- python3 scripts/build.py --configuration Release: exit 0; Release app built, not launched or installed.
- No wallpaper assets, settings, hardware-decoder selection or frame scheduling changed. No desktop control, screenshots or audio hardware; desktop appearance, sustained playback and energy impact remain unverified.

## 2026-10-03 — PR 25 merge with audited main

- Merged `origin/main` at `d895d74` without rebasing; preserve the audit registry/GPU prerequisites, all 12 synthetic scenes, both regression sets, and all 42 distinct historical verification entries.
- Reconciled stage-interface bounds with the audit leading-macro undefinition/redefinition behavior; the new unit regression passed.
- `python3 scripts/build.py --renderer-only` — passed; renderer rebuilt and bridge bindings regenerated, matching the incoming generated files. No Release app build.
- `python3 scripts/check_rust.py` — all four suites exited zero: core 223, bridge 378, core integration summaries 15, shader 533 reported passed; shader reports three unavailable corpus early-return skips.
- Rust exclusions remain explicit: two desktop window tests and four external-corpus tests; desktop/media/network opt-ins disabled.
- `python3 scripts/check_renderer.py` — all registered binaries passed; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- Additional C++ suites rebuilt and passed in isolated state: scene_schema_tests 108, script_runtime_compat_test 91, mouse_input_test 13.
- `python3 scripts/test.py` — all Python suites passed; 1,156 native passed, zero failed, 12 skipped. Renderer-tooling targeted suite: 17 passed.
- Renderer corpus skips: two local text scenes and the environment-selected Metal project case. No desktop visual/live keyboard validation, authored-reference parity claim or app launch.
- `git diff origin/main --check`, regenerated-binding consistency, historical-entry preservation/order and conflict-marker checks passed; incoming generator whitespace was not hand-edited.

## 2026-10-03 — PR 24: retry eligibility and durable pixiv cancellation

- Web host state now explicitly grants retry only to failures from the current live page; panel rendering, action dispatch and host retry all honor that capability.
- Project validation and fingerprint failures remain visible without an ineffective retry action, including failures while an older surface still exists.
- Pixiv cancellation is excluded from the durable queue immediately while the task retains its slot until cleanup finishes; pause/shutdown cannot revive cancellation, and a fresh request discards orphaned partial data.
- python3 scripts/test.py --only WebWallpaperHostLifecycleTests --only ControlPanelHostStateTests: 9 passed, 0 failed/skipped. Initial test compile error in an error-pattern catch was corrected before this successful run.
- python3 scripts/test.py --only PixivDownloadQueueTests: 9 passed, 0 failed/skipped; held cancellation cleanup covers queue restore, slot ownership, shutdown, paused checkpoints and fresh enqueue.
- python3 scripts/test.py: 256 Python tests and 1148 native tests passed; 0 failures and 12 media/network opt-in skips. Full gate ran once after both changes were final.
- git diff --check passed. No renderer/bridge changes, so renderer checks and binding generation were not repeated.
- No Release app build, desktop automation, live pixiv/Steam access or real media-hardware validation. Panel assertions use offscreen fixtures.

## 2026-10-03 — PR 24 review follow-up

- Addressed all 12 inline review threads: per-wallpaper purge isolation, resume consent, benchmark schema lookup, effective-cap reporting, artwork validation, dangling symlinks, BGRA admission, encoder skips, allocator scope, termination order, checkpoint recovery and empty playback notifications.
- python3 scripts/test.py --only UserAssetStoreTests --only WorkshopStoreTests --only WorkshopDownloadPersistenceTests: 55 passed, 0 failed, 0 skipped.
- python3 -m unittest scripts.tests.test_power_benchmark scripts.tests.test_mediaremote_stream: 38 passed, including synthetic startup/track callbacks; no real player access.
- Targeted cargo test --release --locked --lib checks: wallpaper-bridge tests::quality_settings (10), tests::web_audio_media (21), wallpaper-core tests::general::shader_cache (5); all 36 passed with isolated WALLPAPER_MACHINE_HOME.
- python3 scripts/build.py --renderer-only: passed and regenerated bindings, with no generated API changes; no Release app build.
- python3 scripts/test.py: 256 Python tests and 1143 native tests passed; 0 failures, 12 native media/network opt-in skips. The new WorkshopDownloadIntentTests resume-consent case passed in this full gate.
- python3 scripts/check_renderer.py: passed with GPU checks executed; all 10 generated pooled/isolated pairs matched with zero diagnostics, expected pixels passed, and 8 projects completed two reload cycles each.
- Renderer gaps: three local-asset cases skipped; the existing disabled JPEG timing benchmark was not run. Desktop, visual presentation, live Steam, real media hardware and battery/power behavior were not exercised.
- git diff --check and all auditRemediation provenance SHA-256 checks passed; CLAUDE.md remains a relative AGENTS.md symlink. Changes remain local, uncommitted and unpushed.

## 2026-10-03 — Audit remediation across app, renderer and tooling

- Completed all 79 formal audit findings; the excluded/withdrawn audit candidates were not promoted into the repair scope. Owning feature/testing docs and 106 changed upstream file hashes are recorded.
- python3 scripts/build.py --renderer-only: exit 0; Rust/C++ renderer dependencies rebuilt and UniFFI bindings regenerated. No Release application build or delivery.
- python3 scripts/test.py: 254 Python tests passed; native 1140 passed, 0 failed, 12 skipped of 1152. First attempt stopped at catalog quote-format validation; fixed and full gate passed on retry.
- python3 scripts/check_renderer.py: exit 0; 662 gtests passed, 3 external-corpus tests skipped; 10 generated scene pixel comparisons and 16 reload cycles passed. Fixed one missed probe API migration and an obsolete prepared-state fixture before final success.
- python3 scripts/check_rust.py --output artifacts/remediation-20261003/rust-final: all four groups exit 0; core 223, bridge 377, integration 15 plus layer pixel executable, shader 529 reported including 3 corpus early-return skips. Two desktop and four corpus cases explicitly excluded.
- Focused regressions cover asset commit/cancel/rollback interleavings, same-path content refresh, host readiness/audio delivery, durable download pause/resume, updater cancellation/ownership, media withdrawals and failed extension-surface reuse. Security boundary candidate received independent source review; no new confirmed regression.
- Synthetic Debug measurements: 10000-row snapshot construction 35.70 ms initially versus 1.94 ms mean progress update; actual payload JSON UTF-8 2303731 to 5935 bytes. Asset cold preparation for 8/128/1024 files kept measured main-actor maximum delay below 7 ms; timings are observations, not whole-app energy claims.
- arm64 JPEG scalar/NEON output was byte-identical; decoder-only warm medians improved about 33%. Runtime GPU checks used private images. Desktop/UI opt-ins, live account/network/player tests and missing external corpus checks were not run; UI source typecheck passed.
- git diff --check passed for handwritten sources; generated UniFFI formatting retains generator whitespace. CLAUDE.md remains the relative AGENTS.md symlink. No commit, push, app install/restart or desktop interaction.

## 2026-10-03 — PR 25 CodeRabbit input-validation follow-ups

- Range-check parallax IDs and parent references before narrowing, handling unsigned JSON values before signed conversion; preserve valid int32 boundaries and declaration-order independence.
- Skip non-object entries, non-string names and nonnumeric IDs during layer-alias registration; retain missing-field defaults and valid alias-driven script updates.
- Hosted keyboard-loop test now waits for both fields to attach to its window and reports a setup failure immediately on timeout.
- Rebuilt `scene_schema_tests`; `--gtest_filter="SceneSchema.*Parallax*:SceneSchema.*Parented*:SceneSchema.*Duplicate*"` — 11 passed, including three new boundary/type regressions.
- `python3 scripts/test.py --only ControlPanelWindowSizingTests` — four passed; targeted iteration only.
- `python3 scripts/check_renderer.py` — every recorded binary exited zero; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- `python3 scripts/test.py` — all Python suites passed; 1,072 native passed, zero failed, 12 skipped.
- Renderer skips: two local text scenes and the environment-selected Metal project case. No desktop visuals/live keyboard check, authored-reference parity, app launch or Release rebuild.
- Confirmed no configured/gated SwiftLint required_deinit rule; kept the controller unchanged. Current verification entries already satisfy newest-first ordering; no historical results rewritten.

## 2026-10-03 — PR 25 Claude review follow-ups

- Unified stage-interface array bounds for location allocation and emission; unsupported expressions, late/missing definitions and nonpositive sizes now fail explicitly.
- Single-sample alpha-to-coverage uses source-over blending on Metal/Vulkan; multisampled state retains unblended coverage without adding targets or passes.
- `cargo test -p shader -- --nocapture` using the project Cargo environment — exit 0; 507 reported passed, including three unavailable asset-dependent early-return skips.
- `python3 scripts/check_renderer.py` — exit 0; all 12 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles. All recorded test binaries exited zero.
- Negative control: the preceding renderer binary fails the new single-sample composed-coverage pixel assertion; the rebuilt renderer passes. Native Metal transparent/half/opaque pixel regression also passed.
- `scene_schema_tests --gtest_filter="SceneSchema.*Camera*:SceneSchema.PerspectiveFallback*"` after rebuilding — 19 passed, including steep/rolled look-at, scaled/zero deltas and fallback registration.
- `python3 scripts/test.py` — all Python suites passed; 1,072 native passed, zero failed, 12 skipped. Existing cancellation/preview-error tests and new offscreen Tab/Shift-Tab wrapping passed.
- Stable-sorted verification entries by date through the log helper functions, preserving every historical body and relative archive link; new evidence appended only via `scripts/log_verification.py`.
- Asset gaps: three shader corpus cases, two local text scenes, and the environment-selected Metal project case skipped. No desktop visual/live WebKit keyboard check, authored-reference parity, app launch or Release rebuild.

## 2026-10-03 — PR 25 merge conflict resolution

- Merged `origin/main` into `fix/scene-playback-panel-shaders` without rebasing; retained both sides of renderer provenance and all 36 distinct historical verification entries.
- `python3 scripts/test.py` — all Python suites passed; native results: 1,071 passed, zero failed, 12 skipped.
- `python3 scripts/check_renderer.py` — exit 0; all 11 synthetic pooled/isolated comparisons matched with zero diagnostics; eight projects completed two reload cycles.
- Built `scene_schema_tests` and `script_runtime_compat_test` with the project build environment; 26 targeted duplicate-name/parallax/camera/model tests and two color/composition tests passed.
- Targeted coverage includes both incoming regressions: duplicate names retain independent bindings, and authored color properties remain vectors across updates.
- Renderer asset gaps remain: two local text-scene tests and the environment-selected local-project Metal test skipped; no authored-reference parity claim.
- Provenance JSON, historical-entry preservation, conflict-marker checks, and `git diff --check` validated before commit.
- No desktop automation, visual validation, app launch, or Release app rebuild performed.

## 2026-10-03 — Shader macro fixes and pending scene/playback/panel PR

- `python3 scripts/test.py` — passed: 1,071 native tests passed, 12 skipped; all Python script suites passed.
- `cargo test -p shader -- --nocapture` from `upstream/renderer`, using `scripts/build.py` cargo environment — exit 0; 506 reported passed, including three asset-dependent early-return skips.
- Shader corpus gaps: two auto-sway/depth-parallax fixtures and the genericimage4 asset case were unavailable; those cases are skipped, not verified.
- New macro-sized varying and nested legacy macro regressions passed for SPIR-V and MSL.
- `python3 scripts/check_renderer.py` — exit 0; all 11 synthetic pooled/isolated pairs matched with zero diagnostics; eight projects completed two reload cycles.
- Renderer gaps: two local text-scene cases and the environment-selected local-project Metal case skipped; no authored-reference parity claim.
- `git diff --check` — passed before commit.
- No desktop automation, visual validation, app launch, or Release app rebuild performed.

## 2026-10-03 — Tile layer textures, unblended alpha-to-coverage, random sprite frames

- Composite render targets follow the source layer clampuvs; alphatocoverage writes kept samples unblended on both backends; randomframe particles get a fixed hashed per-particle frame. No wallpaper-specific rules, MSAA, extra passes or allocations.
- Targeted: layer_texture_reference_test 20, particle_mouse_controlpoint_test 42, metal_backend_test 35, scene_schema_tests 100 passed.
- python3 scripts/check_renderer.py: passed; 509 renderer tests, 3 optional local-asset skips, 0 failures; 11 generated scenes pass pixel and pooled/isolated checks; 8 reload projects x2.
- python3 scripts/test.py: passed; 1,071 native passed, 12 skipped.
- Local packaged 3D scene, Compatibility offscreen, disposable package copies forcing single camera paths: the solid blue planes came from a 497x-tiled maze composite sampled with clamp; after the fix the maze tiles and sprite particles show varied frames.
- Remaining against the supplied Windows screenshot: maze lines are thinner/dimmer (single-sample coverage threshold vs likely MSAA) and distant lines alias; not changed, to avoid MSAA memory/perf cost.
- python3 scripts/build.py --configuration Release: passed. No desktop capture, Parallels inspection, wallpaper change or app launch.

## 2026-10-03 — Parent-controlled parallax keeps child layers aligned

- Resolved outermost-parent parallax once at parse time; no wallpaper identifiers, asset edits, new render passes, texture allocation or per-frame hierarchy traversal.
- scene_schema_tests: 100 passed, including declaration-order/cycle/default-depth resolution and parsed multi-slot puppet displacement with unchanged local transforms.
- MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses: passed for direct/effect cards and repeated/reversed cursor motion; removing only the inheritance call in a private build makes its pixel assertion fail.
- check_renderer.py with an isolated artifact root: 507 passed, 3 asset-dependent skips; 11 generated pixel cases and the selected local wallpaper match pooled/isolated allocation, no diagnostics; two reload cycles passed.
- The first additional private-scene comparison failed only in 769 live-clock pixels. Retry used WE_TEST_PROPERTIES to hide its clock in memory; no imported files or saved user settings changed.
- Matched eight-frame Vulkan probes with synthetic pointer input reproduce detached head/flowers without inheritance and aligned pieces with it; both execute 1095 passes, reuse 49 and allocate 114272640 VMA bytes. This is not a battery/performance benchmark.
- python3 scripts/test.py: 1071 passed, 0 failed, 12 skipped; all Python script modules passed. No desktop/UI, live network or media-device opt-ins.
- python3 scripts/build.py --configuration Release: passed; delivered build/Build/Products/Release/WallpaperMachine.app, not launched or installed.
- Shared workspace contained concurrent shader/camera/model/UI work. A transient unrelated ParseCameraPaths test declaration blocker cleared before verification; unrelated edits remain separate.
- Desktop presentation, real cursor interaction and animation smoothness remain unverified; all image inspection was surface-free offscreen output.

## 2026-10-03 — Restore perspective shots and skeletal model playback

- Implemented runtime perspective-shot selection, packaged eye/center/up/FOV camera paths, shared skeletal-model playback and model-specific opaque depth/cull defaults; no wallpaper-specific rules or asset edits.
- scene_schema_tests: 100 passed, including five new camera/model regressions; orthographic camera coverage remains green.
- python3 scripts/test.py: passed; 229 Python tests, 1,071 native tests passed, 12 native skips.
- python3 scripts/check_renderer.py: passed; 507 renderer tests passed, three optional local-asset tests skipped; 11 generated scenes passed known-pixel and pooled/isolated equality checks, eight reload projects exercised twice.
- Local packaged scene, Compatibility offscreen: reproduced the missing model, wrong camera and rear-triangle artifacts before the fixes; after, fixed and dynamic camera views show the model and solid ghosts. Four animation samples confirm the jaw opens/closes; a 720-frame path run changes the camera pose with zero script errors.
- Native local-project probe reports Compatibility fallback for dynamic lighting; not a native rendering pass. Two optional text corpus cases remain skipped.
- 1920x1080 offscreen probes retain 176 executed passes/frame and 256,163,584 allocated Vulkan bytes before/after. Shared skeletal playback and parse-once camera curves add authored animation work, not extra passes/targets; sustained desktop performance not measured.
- python3 scripts/build.py --configuration Release: passed; built build/Build/Products/Release/WallpaperMachine.app. No installation, launch, restart, desktop capture, wallpaper change or Parallels control.
- Exact Parallels parity remains unverified without a supplied reference; camera-path zoom/events and camera-cut fades remain unsupported. Existing concurrent shader/parallax edits were preserved and included in shared-tree verification.

## 2026-10-03 — Wallpaper apply and background presentation ordering

- Reproduced the reported interruption with held fake-bridge operations: disabling the serialization fix makes both arrival-order regressions fail with the original interruption error; restored the fix afterwards.
- `python3 scripts/test.py --only WallpaperActivationRecoveryTests` — exit 0; 18 passed, covering Apply/Apply changes versus display refresh, global/per-display suspension, unload/reload and audio suppression, both arrival orders, failure release, cancellation and explicit Pause.
- `python3 scripts/test.py` — exit 0; Python suites passed; native 1070 passed, 12 skipped, 0 failed. Skips: nine real-player media tests, one live SteamCMD install and two live Workshop searches.
- `python3 scripts/build.py --swift-only --configuration Release` — exit 0; built the Release app with existing renderer/bindings, per local build opt-in.
- No desktop control, wallpaper changes, app launch/restart or UI run; visual behavior and private Workshop assets were not verified.
- Existing concurrent renderer/provenance edits were left untouched and were not rebuilt or verified by this Swift-only task.
- `git diff --check` — exit 0; existing documentation paths and commands retained.

## 2026-10-02 — Live Solar System scripted colors and duplicate layer lookup

- python3 scripts/test.py: exit 0; 227 Python tests and 1064 native tests passed, 12 native opt-in tests skipped.
- CMake targeted build: offscreen_scene_probe, scene_schema_tests and script_runtime_compat_test succeeded.
- scene_schema_tests --gtest_filter=SceneSchema.*Duplicate*: 5 passed, including mixed image/group order, module-initialization lookup, independent thisLayer writes and parsing without a runtime.
- script_runtime_compat_test --gtest_filter=ScriptRuntimeCompat.AuthoredColor*:ScriptRuntimeCompat.MaterialConstantUserBindingUpdatesThroughRuntimeProperties: 2 passed; saved color strings stay vectors over repeated ticks and property changes, while text stays a string.
- python3 scripts/check_renderer.py --project <local Live Solar System project.json>: exit 0; 503 C++ tests passed, 3 asset-dependent cases skipped; all 10 generated scenes and the local scene matched pooled/isolated pixels, with 2 successful reload cycles.
- Surface-free Vulkan probes with intro disabled: sun tint changed from black to the authored RGB value, the oversized foreground dwarf planet now receives the simulation scale, and sampled startup and 5.5-second frames had zero script errors.
- The local project retained the same 92 non-cache shader-value diagnostics as the baseline; no new diagnostics. These checks do not establish complete wallpaper compatibility.
- Skipped renderer asset cases: LonelyCatHeadlessRegression, Workshop3409533530FullSceneKeepsClockRenderPassAndTexture and the optional native-Metal local-project test. Live Solar System uses the dynamic-lighting Compatibility path.
- No Release build, app installation/restart, desktop control, screen capture, live audio or Steam sign-in. Desktop interaction and presentation remain unverified.
- python3 scripts/clean.py --dry-run: shared artifacts and other worktree caches were listed, so no shared cleanup was performed. Private probe outputs remain Git-ignored.

## 2026-10-02 — v1.2.3 pre-release gate

- `python3 scripts/build.py --renderer-only` — exit 0; renderer rebuilt and Swift bindings regenerated.
- `python3 scripts/test.py` — exit 0; 227 Python tests passed; native 1064 passed, 0 failed, 12 skipped (9 opt-in media, 3 live network/install).
- `cargo test --release -p wallpaper-bridge --lib` with the build helper environment — exit 0; 367 passed, 0 failed.
- `python3 scripts/check_renderer.py` — exit 0; 24 test binaries and reload cycles passed; all 10 generated pooled/isolated pairs matched with no diagnostics and expected pixels.
- Three asset-dependent renderer cases skipped: two local text-project regressions and the native local-project matrix. No authored-reference compatibility claim.
- `git diff --check` passed; origin/main is an ancestor of the reviewed main, with no unmerged paths. Version dry run: 1.2.2 (24) -> 1.2.3 (25).
- Compiler warnings remain, including Swift concurrency diagnostics and Rust unused-code warnings; zero warnings/issues is not claimed.
- No desktop run, wallpaper change, audio capture, live Steam login, or local Release app build. Release publication will use the Version workflow after the source push.

## 2026-10-02 — Web-only audio capture ownership

- Read-only inspection found the reported web wallpaper registers the standard audio listener; its saved Audio response switch is off. No user settings or private wallpaper assets changed.
- Regression: restoring the old scene-handle-only capture predicate makes capture_tap_follows_web_subscribers_with_no_scene_handle fail; restored the fix before the passing checks.
- cargo test --release -p wallpaper-core --lib: exit 0, 225 passed; cargo test --release -p wallpaper-bridge --lib: exit 0, 367 passed. Controller tests cover one shared tap, external ownership, permission, suspension and rollback; bridge tests exercise the production demand handler, web-only startup and shutdown.
- python3 scripts/build.py --renderer-only: exit 0; generated bindings refreshed without a UniFFI signature change.
- python3 scripts/test.py: exit 0; all 17 Python modules passed; native 1064 passed, 0 failed, 12 opt-in media/network cases skipped.
- python3 scripts/check_renderer.py: exit 0; all ten generated pooled/isolated cases pixel-identical with zero diagnostics, eight reload projects twice; three environment-selected private-asset checks skipped.
- python3 scripts/build.py --configuration Release: exit 0. Local Release app built, not installed or launched.
- Live system capture, actual music reaction, desktop visuals and battery effects remain unverified. No desktop control, windows, screenshots, audio devices or permission prompts used. Existing shared-workspace edits preserved.

## 2026-10-02 — Conditional texture masks contain brightness pulses

- `cargo test -p shader -- --nocapture` (renderer workspace, build environment): exit 0; 504 nominal successes, including 3 asset-dependent early-return skips, not 504 exercised cases. The new SPIR-V/MSL conditional-mask regression failed before the fix and passed after it; existing inactive-default and disabled-texture tests remain green.
- `python3 scripts/check_renderer.py --project <local-scene-project>`: exit 0; 502 native renderer checks passed, 3 optional corpus checks skipped; all ten generated scenes and the affected local scene matched pooled/isolated pixels with no diagnostics; two reload cycles passed. The GPU regression holds masked pixels constant across six alternating brightness frames while unmasked pixels continue changing.
- Surface-free before/after probes: same 30 frames at 1/60 s, fixed seed, untouched local package. Both pulse passes now retain their authored mask slot. Maximum consecutive-frame change in sampled mean red fell from 9.844 to 0.066 code values; both runs executed 540 passes. Masks add their intended texture residency/sampling, not extra passes or lower quality.
- `python3 scripts/test.py`: exit 0; Python modules passed; native gate 1064 passed, 0 failed, 12 skipped.
- `python3 scripts/build.py --configuration Release`: exit 0; local Release app rebuilt under the developer's build opt-in, not installed or launched.
- No desktop control, wallpaper changes, screenshots, audio devices or permissions. Desktop appearance, long-duration visual comfort and live power/frame-time performance remain unverified. Concurrent library/web/bridge/parallax edits were preserved; the gates and build used the shared working tree.

## 2026-10-02 — Workshop presets download and import as self-contained wallpapers

- Cause: Workshop presets (e.g. Purple Ink 1809081988, Ink 3356611918) have no project.json type, only dependency + preset values; validation rejected them.
- Fix: downloader fetches the base in a second SteamCMD pass of the same job; importer assembles base + preset files + merged manifest under the preset id; manual import uses a sibling or installed base.
- python3 scripts/test.py --only ImportTests --only DownloaderLifecycleTests: passed 53, failed 0.
- python3 scripts/test.py: passed 1064, failed 0, skipped 12 (opt-in layers).
- Not verified: a live SteamCMD download of the two real presets (needs Steam sign-in); no Release build.

## 2026-10-02 — Web wallpapers: Chromium-like file:// fetch responses (Unity/WASM)

- Cause: WebKit file:// fetch → status 0/ok false/no Content-Type; Unity 2022.3 wasm streaming + fallback both rejected, canvas stayed dark (Workshop 3756621387).
- Fix: host script serves found file:// GET/HEAD as 200 + extension MIME; served .wasm compiled from bytes (WebKit streaming compiler ~190 ms slower boot).
- Offscreen headless WKWebView repro (no desktop window): before abort('both async and sync fetching of the wasm failed'); after Unity boots, Live2D renders, music loads.
- Perf: 30 MB fetch+arrayBuffer native vs normalized ~68 ms both; Unity boot to first engine log 180 ms (vs 364 ms with native streaming).
- python3 scripts/test.py --only WebWallpaperPageTests/ScreenSaverWebSurfaceTests/WebWallpaperAuthorAPITests: 25 passed.
- python3 scripts/test.py: 1058 passed, 0 failed, 12 skipped.
- Not run: Release build, desktop/visual check of the live wallpaper.

## 2026-10-02 — Video preflight preserves Compatibility fallback (issue #23)

- Reproduction before the fix: python3 scripts/test.py --only WallpaperActivationRecoveryTests/testMatroskaVideoCanBeActivatedWithEitherBackendPreference --only WallpaperActivationRecoveryTests/testMatroskaVideoOptionsCanBeAppliedWithEitherBackendPreference — exit 65; both tests failed with the reported video-decode error on an original silent H.264 Matroska fixture.
- python3 scripts/test.py --only WallpaperActivationRecoveryTests — exit 0; 12 passed, 0 failed or skipped. Covers both apply paths and backend preferences, missing/empty/non-file entries, decoder-error propagation and retry.
- python3 scripts/test.py — exit 0; 227 Python tests passed; native suite 1,057 passed, 0 failed, 12 skipped. Full gate run once after the fix.
- Skipped: nine opt-in native player/media tests, two live Workshop searches and one live SteamCMD install. No media-device or network-test opt-ins enabled.
- Fixture metadata checked with ffprobe: Matroska, H.264, 16 x 16, two video packets, no audio stream; embedded bytes match the generated original. No FFmpeg CLI is required by the regression tests.
- git diff --check — exit 0. No renderer or generated-bridge changes.
- Workshop item 3351864056 is absent locally; its original file and desktop playback remain unverified. No Release build, app launch, install or desktop control performed.

## 2026-10-02 — Single-pass puppet lighting and complete four-light packing

- python3 scripts/test.py: 1064 passed, 0 failed, 12 skipped; 229 Python tests passed. First native attempt was blocked by another build holding the shared Xcode database; retry after it finished passed.
- python3 scripts/check_renderer.py --project <local-scene>: exit 0; 506 renderer tests passed, 3 asset-dependent cases skipped; all 11 generated pixel cases and the private scene matched pooled/isolated output; two reload cycles passed.
- script_runtime_compat_test --gtest_filter=ShaderValueUpdaterCompat.*: 10 passed, including zero-to-five-light color packing and clearing.
- MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly: all eight original puppet/card, effect/direct, lit/unlit combinations passed across three draws each.
- Negative controls: disabling each fix made its respective new regression fail; restored fixes passed.
- Offscreen private scene: duplicate dimming and eye-patch boundaries removed at startup and a six-second sample. Same three-frame workload retained 197 executed / 40 reused passes and 266389504 allocated GPU bytes; lighting shader work is removed, not replaced with additional passes.
- Existing private scene init TypeError remains, unchanged from baseline. Native local-project probe reports Compatibility because of dynamic lighting; it did not render this scene natively.
- No desktop control, windows, screenshots, wallpaper changes, audio hardware or live services. Desktop appearance/smoothness and power use remain unverified. Concurrent work preserved.

## 2026-10-02 — Macro-sized shader interfaces and nested macro builtins

- Original synthetic shader regressions reproduced unknown COUNT and CAST3 failures before their respective repairs; both now compile SPIR-V and MSL. Numeric combo defaults/overrides and consecutive arrays are covered.
- WALLPAPER_MACHINE_ASSETS_ROOT=<local SceneAssets> cargo test -p shader -- --nocapture: exit 0; 506 reported successful tests, including two unavailable private-asset checks that returned early (504 exercised).
- python3 scripts/test.py: exit 0; Python script suites passed; native verdict 1064 passed, 0 failed, 12 skipped of 1076.
- python3 scripts/check_renderer.py --project <local project>: exit 1 in the shared working tree. All 11 synthetic pixel cases passed; local project pooled/isolated pixels matched and both reload cycles succeeded. The concurrently added MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly failed; its source and the concurrent parser/updater changes were not modified by this task.
- Surface-free local scene renders restore the sky, mountain and bridge gradients; four formerly rejected gradient effects now compile. Existing dock script errors and a missing layer-texture link remain. Native Metal still refuses the same missing effects/blend image as before, so this scene was verified through Compatibility, not native presentation.
- Changes are shader-compilation-only, with no wallpaper IDs, asset edits or brightness compensation. Restored effects increase the sampled two-frame executed-pass total from 289 to 297 and allocated Vulkan target/image bytes from 244133504 to 278081152; this is authored work previously dropped, not a new correction pass. Desktop performance and exact reference parity are unverified.
- No desktop control, live settings changes, app restart or installation. Eye-square report could not be identified in the bridge scene; screenshot requested. No commit or Release build while the shared renderer gate is failing.

## 2026-10-02 — Layer origin timelines reveal animated intros

- python3 scripts/test.py: passed (1064 native tests, 12 opt-in skips; 17 Python modules).
- python3 scripts/check_renderer.py: passed; 23 test executables, eleven synthetic pooled/isolated pixel comparisons and eight scenes reloaded twice. Two private text cases and the environment-driven local-project case skipped in the default gate.
- scene_schema_tests: 93 passed; script_runtime_compat_test: 85 passed. Origin regressions cover absolute/relative offsets, anchors, missing axes, one loop clock, pause/seek/replay, text/groups, property precedence and relinquishing animation demand.
- MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen: passed for direct and effect-chain layers at initial, intermediate, final and held positions. Compatibility generated-origin-animation independently checks both halves after the curtain exits.
- Installed Into The Abyss [4K]: reproduced the stuck right-side curtain on both backends; after the fix Compatibility at six seconds and Native Metal across 420 frames reveal the full canvas. Native run: 43 render passes/frame, zero blits, 217284608 render-target bytes. These are observations, not a before/after performance benchmark.
- No desktop control, screenshots, wallpaper changes, app restart or audio-device access. Desktop presentation, continuous-playback smoothness and full authored visual parity remain unverified. Concurrent shader/material edits were left intact.

## 2026-10-02 — Correct 2D shader projection and dark lit layers

- Shared LoadMaterial compilation now supplies the authored SCENE_ORTHO value, including effect passes; no brightness multiplier or wallpaper-specific code.
- Original Metal pixel regression covers both projections, direct/effect rendering and unlit colours; passes with the fix and fails with it removed.
- python3 scripts/check_renderer.py with the affected local project: exit 0; all ten generated cases and the local scene have identical pooled/isolated pixels, no diagnostics, and reload cycles pass.
- Renderer asset-dependent cases: two text fixtures and the environment-selected native-project test skipped. The separate native probe reports the affected scene's existing dynamic-lighting fallback to Compatibility.
- Before/after Compatibility probe: 366 executed passes and 845691008 allocated GPU bytes in both runs; restored brightness inspected only in private offscreen frames.
- python3 scripts/test.py: exit 0; Python modules pass, native gate reports 1064 passed, 0 failed, 12 skipped.
- Desktop presentation and exact authored-light parity unverified. Existing PerformLighting_V1 approximation unchanged; no desktop, audio hardware, live library changes or app restart.
- Unrelated concurrent renderer edits appeared during verification; leave them unstaged and defer the Release build rather than package unfinished shared-workspace changes.

## 2026-10-02 — Keep Discover responsive without canvas preview readback

- Live diagnostics: the native main thread remained in its event loop while WebKit logged RemoteImageBuffer_FlushContextSync failure and repeated 15-second FillRect/DrawNativeImage waits. No desktop control or restart was performed.
- Regression red check: python3 scripts/test.py --only ControlPanelDiscoverTests/testDiscoverPreviewsPlayWithoutCanvasReadbackAndReleaseOffscreenImages — failed on the old implementation; 33 canvas requests and neither loaded animation revealed with canvas unavailable.
- python3 scripts/test.py --only ControlPanelDiscoverTests — exit 0; 6 passed, 0 failed, 0 skipped. Covers loaded dark/bright previews without canvas, error fallback, still-first loading, hidden/offscreen release and cached resume.
- python3 scripts/test.py — exit 0; all 17 Python modules passed; native 1064 passed, 0 failed, 12 skipped (3 live-network and 9 opt-in media tests).
- python3 scripts/build.py --swift-only --configuration Release — exit 0; bundled panel.js matches source and codesign --verify --deep --strict passes.
- No renderer changes in this fix; concurrent renderer edits were left untouched. No live GPU-hang reproduction or desktop visual check; installed app not replaced or restarted.

## 2026-10-01 — Sync main download fixes with remote SteamCMD and lock-screen fixes

- Merged origin/main without rewriting existing commits; regenerated the Xcode project with xcodegen generate and preserved both sides of verification history.
- python3 scripts/test.py — passed; 1053 native tests passed, 0 failed, 12 skipped of 1065; all Python test suites passed.
- Uncommitted frame-rate slider changes were stashed and excluded from this gate and merge.
- No desktop run, live Steam sign-in/install, renderer corpus check, or Release build; this was a repository synchronization.

## 2026-10-01 — Steam and pixiv failure diagnosis

- Fixed unknown SteamCMD failures being attributed to credentials; classify compact network/rate-limit result names and log only a safe category.
- pixiv HTTP 403 now explains access denial rather than promising a one-minute wait; HTTP failures log status only, without URLs, cookies or bodies. Updated all four native locales.
- python3 scripts/test.py --only SteamCMDReportedFailureTests --only DownloaderLifecycleTests --only PixivServiceTests: passed 55, failed 0, skipped 0.
- First python3 scripts/test.py: Python passed; native 1036 passed, 1 failed, 11 skipped. WallpaperImportPickerTests/testCancellationReapsThePickerWaitingForASelection exceeded 120 seconds; no picker code changed.
- python3 scripts/test.py --only WallpaperImportPickerTests: passed 5, failed 0, skipped 0; timeout did not reproduce.
- Final python3 scripts/test.py: all 244 Python tests passed; native 1037 passed, 0 failed, 11 skipped (9 opt-in media tests, 2 live Steam tests).
- python3 scripts/build.py --swift-only --configuration Release: succeeded; app not launched or installed.
- The reported user's root cause remains unconfirmed without their diagnostics/network details. No live Steam login, live pixiv access or visual/desktop checks; unrelated workspace edits preserved.

## 2026-10-01 — PR 22 integration with current main

- Merged origin/main at e1fc9e1 into the native SteamCMD PR without rewriting history. The only conflict was the verification log; replayed the two PR-only entries through log_verification.py and asserted that both branches’ historical entries were preserved exactly, with ten active entries.
- `python3 scripts/test.py --only SteamCMDSetupTests --only SteamCMDApprovalTests --only LockScreenWallpaperServiceTests` — exit 0, 91 passed, none skipped.
- Full `python3 scripts/test.py` in the logged-in Aqua session — exit 0; 226 Python tests and 1,047 native tests passed, 12 opt-in skips. Ran the full gate once on the integrated tree.
- Skipped: nine opt-in media tests, two live Workshop-page cases and the live SteamCMD installer. No renderer/corpus, live account/CDN or desktop checks; no Release rebuild or production app restart.
- Resolved in the isolated PR worktree, leaving unrelated original-checkout edits untouched. git diff --check and staged conflict-marker checks passed.

## 2026-10-01 — PR 22 redirect-failure review fixes

- Addressed CodeRabbit and Claude: preserve a rejected redirect’s original failure if URLSession delivers its final response before cancellation; retain the isolated Foundation configuration copy with a narrowly documented SwiftLint force_cast suppression.
- Regression-first check: `python3 scripts/test.py --only SteamCMDSetupTests/testRejectedRedirectRetainsItsFailureWhenFinalResponseArrivesBeforeCancellation` failed before the fix by comparing original versus overwritten error values. It pins no localized wording and uses only URLProtocol fixtures.
- `python3 scripts/test.py --only SteamCMDSetupTests` — exit 0, 41 passed. Full `python3 scripts/test.py` in Aqua — exit 0, 226 Python tests and 1,042 native tests passed, 12 skipped; full gate ran once.
- Skipped: nine opt-in media tests, two live Workshop-page tests and the live SteamCMD install. No live account/CDN, renderer/corpus or desktop checks were run for this small download-delegate fix. SwiftLint is unavailable locally; its suppression was not verified with the lint executable.
- Verification ran on PR 22’s branch in an isolated worktree, leaving concurrent edits in the original checkout untouched. Coverage docs updated; git diff --check clean. No Release rebuild, production app launch/restart, security-setting changes or history rewrite.

## 2026-10-01 — Native Apple silicon SteamCMD package installation

- Full gate: `python3 scripts/test.py` in the logged-in Aqua session — exit 0; 226 Python tests and 1,041 native tests passed, 12 native tests skipped. Ran the full gate once.
- Gate skips: nine opt-in media cases, two live Workshop-page cases, and the opt-in SteamCMD install. Renderer/corpus and desktop/visual checks were not run; no renderer code changed.
- Targeted approval/runtime/downloader/queue/telemetry/WorkshopStore/ControlPanelShell runs with `python3 scripts/test.py --only …` — exit 0, 112 passed; remaining six ControlPanel classes — exit 0, 30 passed.
- `WALLPAPER_MACHINE_NETWORK_TESTS=1 python3 scripts/test.py --only SteamCMDSetupTests --only SteamCMDLiveInstallTests` — exit 0; 41 passed (40 offline setup regressions plus the live native installation), none skipped.
- Live install used temporary support/preferences/approval directories, real CDN packages, per-slice codesign and spctl, and the real native runner. Ready, arm64 resolution and Loading Steam API...OK were asserted; nothing installed into the user’s SteamCMD directory.
- Live checks exposed and fixed HTTP gzip Content-Length versus decoded-byte accounting and quarantined smoke exec being killed. Smoke now uses the downloader’s existing validated disposable-copy path; the installation candidate remains quarantined and policy failures are not bypassed.
- `spctl --assess --type execute --verbose=2` on the quarantined temporary native runtime returned 3 with valid-but-not-an-app, not the earlier sandbox’s internal error. All Mach-O slices verified and steamcmd satisfied Valve’s signing requirement; no system security settings changed.
- Authorized cached-session checks, using copied files and `arch -arm64`: sign-in without secret input, an active license listing app 431960, Workshop item 3773084716 downloaded successfully, and Windows app_update reached downloading then its owned process group was stopped. Temporary session copies were deleted, never written back.
- Localization: all ten changed native keys cover en/ja/zh-Hans/zh-Hant; panel localization passed in the gate. WebUI mechanical detector reported no findings; reinstall confirmation flow was inspected without desktop interaction.
- Owning feature/testing docs updated; Xcode project regenerated by test.py; git diff --check clean. Remaining risks: Valve changing/removing the package manifest and Intel-only copies needing reinstall. No Release rebuild, app launch/install/restart, wallpaper changes, or commit.

## 2026-10-01 — Preserve committed display mapping across lock-screen retry

- The reported timeout → missing display UUID → lock Retry → saver Off transition now invalidates only the lock request cache key, retaining the committed mapping needed for immediate Idle restoration.
- python3 scripts/test.py --only LockScreenWallpaperServiceTests --only LockScreenWallpaperTests — exit 0; 80 passed, 0 failed, 0 skipped. Includes pending lock recovery after the UUID returns without re-enabling the saver.
- python3 scripts/test.py — exit 0; 226 Python cases across 17 modules; native: 1036 passed, 0 failed, 11 skipped of 1047.
- Runtime smoke — temporary CLI linked current production Debug objects without the app entrypoint. With a software-generated silent video and isolated defaults/store, the missing-UUID transition restored original Idle immediately and removed the journal; exit 0. Temporary scaffolding removed.
- Owning feature and coverage documentation updated; relative links checked. No real WallpaperAgent reload, desktop changes, app launch, visual or power verification, or Release rebuild.

## 2026-10-01 — Keep screen saver selected when restored lock-screen activation times out

- Before fix: the restored-preferences regression failed (0 passed, 1 failed); after fix: all 33 LockScreenWallpaperServiceTests passed. The extra LockScreenWallpaperSelectionTests selector matched no class; the full gate below covered LockScreenWallpaperTests.
- python3 scripts/test.py — exit 0; all 17 Python test modules passed; native: 1035 passed, 0 failed, 11 skipped of 1046. Skips: 9 opt-in native-player media cases and 2 live Steam searches.
- Runtime smoke — temporary CLI linked the production Debug service/selection objects without the app entrypoint. A software-generated silent video, isolated defaults and wallpaper-store files exercised timeout retention, saver pause updates, lock disable and exact shutdown restoration; exit 0.
- Shared extension incompatibility, failed Idle-only publication, stale readiness and a later saver renderer failure remain covered by regression tests.
- No real WallpaperAgent reload, desktop changes, app launch, visual lock/idle transitions, or power measurements. The OS cause of the reported post-update missing lock-screen acknowledgement remains unverified; no Release rebuild requested.

## 2026-10-01 — PR 21 recovery journal review fix

- CodeRabbit: cancelled-quit synchronization and verification status findings were already addressed in 69fad27; fixed the remaining linked/inherited journal decoding finding.
- New linked and inherited baseline regressions reproduced both silent failures before the fix (targeted run exit 65); malformed arrays and invalid plist bytes now preserve the store and journal, skip reload, and recover after repair.
- python3 scripts/test.py --only LockScreenWallpaperTests: exit 0; 46 passed, 0 failed, 0 skipped.
- python3 scripts/test.py: exit 0; 226 Python tests and 1,031 native tests passed; 11 skipped (9 optional media and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: exit 0; built the Release app containing the fix.
- Initial verification needed a test-fixture type annotation; sandboxed Xcode test-runner and compiler-plugin failures were resolved by rerunning with approved access outside the sandbox.
- git diff --check: exit 0. No renderer or generated-binding changes; desktop and visual behavior remain unverified. No app launch, install, restart, wallpaper change or live account access.

## 2026-10-01 — PR 21 cancelled-quit poster recovery

- Fixed the Codex review finding: a cancelled quit restarts desktop poster synchronization immediately when native desktop ownership has been released; an owned provider remains protected.
- python3 scripts/test.py --only DesktopWallpaperTests --only LockScreenWallpaperServiceTests: exit 0; 65 passed, 0 failed, 0 skipped. The initial sandboxed attempt failed before tests because Xcode could not launch its Swift macro compiler; the permitted unsandboxed rerun passed.
- python3 scripts/test.py: exit 0; 226 Python tests and 1029 native tests passed, 0 failed; 11 optional cases skipped (9 media, 2 live Workshop).
- python3 scripts/build.py --swift-only --configuration Release: exit 0; built the Release app after the gate.
- git diff --check: exit 0. No renderer or generated-binding changes.
- The real AppKit cancelled-quit flow and visual desktop behavior were not exercised; no desktop control, app launch, install, or restart.

## 2026-10-01 — Integrate wallpaper recovery and Steam ownership fixes with main

- Merged the latest remote main without rewriting the five local feature/fix commits; preserved both branches of verification history while resolving log conflicts.
- python3 scripts/build.py --renderer-only --configuration Release: passed; regenerated the renderer bindings required by the incoming main branch.
- python3 scripts/test.py: passed; 226 Python and 1,029 native tests passed, 0 failed, 11 skipped (9 opt-in media and 2 live Workshop tests).
- python3 scripts/check_renderer.py: passed; all renderer binaries exited 0, all 10 synthetic scenes matched between pooled and isolated runs with no diagnostics, and 8 projects passed two reload cycles.
- Renderer asset-dependent checks skipped: the two private text-scene regressions and the environment-selected native Metal project corpus. Authored visual compatibility was not established.
- python3 scripts/build.py --configuration Release: passed; strict deep codesign verification passed.
- Under prior authorization, removed the test-generated Debug extension registration and registered the rebuilt Release copy; pluginkit listed only Release.
- The user confirmed the preceding wallpaper fix works. Live desktop, lock-screen, saver, and quit behavior of the merged build were not retested; no automatic app restart was performed.

## 2026-10-01 — Keep inherited native display choices complete

- Read-only WallpaperAgent logs identified DecodingError.keyNotFound for Idle in a synthesized Space display override; macOS rejected the entire Index before launching the extension. Enabling both modes filled the missing field and succeeded.
- Synthesized individual display nodes now resolve and journal both inherited choices, preserve the inactive mode, and return to inheritance on disable/recovery unless an external edit must survive.
- python3 scripts/test.py --only LockScreenWallpaperTests --only LockScreenWallpaperServiceTests: 73 passed, 0 failed.
- python3 scripts/test.py: passed; 226 Python and 921 native tests passed, 0 failed, 11 skipped (9 opt-in media and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: passed; codesign --verify --deep --strict also passed.
- Under existing user authorization, unregistered the test-produced Debug extension and registered Release; pluginkit confirmed only Release remained.
- Regression fixtures cover linked/individual inheritance, missing top-level and per-Space nodes, either mode alone, mode transitions, exact crash recovery, external edits, and failed reloads.
- Live standalone lock-screen playback and quit restoration on the rebuilt app remain unverified; no app restart, desktop control, or wallpaper change was performed.

## 2026-10-01 — Support the macOS linked default wallpaper

- Updated native selection to accept the built-in linked default, suppress only requested global Desktop/Idle overrides, and restore linked or inherited originals while preserving external edits.
- Focused LockScreenWallpaperTests and LockScreenWallpaperServiceTests: 69 passed after fixing metadata restoration; the added legacy-journal case also passed in the full gate.
- python3 scripts/test.py: passed; 226 Python tests and 918 native tests passed, 0 failed, 11 skipped (9 opt-in native-media tests and 2 live Workshop tests).
- python3 scripts/build.py --swift-only --configuration Release: passed; delivered the updated Release app.
- codesign --verify --deep --strict on the Release app: passed.
- Under existing user approval, unregistered the Debug extension produced by testing and registered Release; pluginkit listed only the Release extension afterward.
- Regression fixtures cover both activation orders, partial disable, crash/reload recovery, copied fallbacks, external choices and metadata, and legacy global journals.
- Live lock-screen/screen-saver rendering, idle transitions, sleep/wake, and quit restoration remain unverified; no desktop control or wallpaper changes were performed.

## 2026-10-01 — Wait for native-provider and desktop-poster restoration on quit

- python3 scripts/test.py --only DesktopWallpaperTests --only LockScreenWallpaperServiceTests — exit 0; 64 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — exit 0; 226 Python tests passed; 910 native tests passed, 0 failed, 11 skipped of 921.
- Skipped: nine opt-in NativeVideoPlayerMediaTests and two live WorkshopTests. Renderer code unchanged; no renderer corpus checks.
- Fixtures cover persisted posters temporarily invisible during native reload, delayed original persistence, retained journals, failed quit with retry, external choices during the wait, and ordered Desktop/Idle plus poster restoration.
- python3 scripts/build.py --swift-only --configuration Release — exit 0; Release app built. codesign --verify --deep --strict — exit 0.
- git diff --check — exit 0. Read-only logs showed rejected desktop writes and extension copies loaded from installed and Debug apps. No live wallpaper changes, application restarts, or extension registration changes were performed.
- Visual desktop restoration with an active native provider remains unverified; the separate extension-copy conflict remains unresolved.

## 2026-10-01 — Preserve recoverable originals before desktop poster writes

- python3 scripts/test.py --only DesktopWallpaperTests — exit 0; 32 passed, 0 failed, 0 skipped.
- python3 scripts/test.py — exit 0; 226 Python tests passed; 904 native tests passed, 0 failed, 11 skipped of 915.
- Skipped: nine opt-in NativeVideoPlayerMediaTests and two live WorkshopTests; no renderer changes or renderer corpus checks.
- Regression fixtures cover effective wallpaper capture before any write, independent display and Space originals, refusal to replace unresolved originals, and repair/relaunch recovery of legacy empty journals even with unchanged frames.
- Read-only inspection confirmed empty inherited originals in the existing desktop journal; no wallpaper settings were modified. Such journals need a fresh user selection when no original survives.
- git diff --check — exit 0. Desktop appearance and actual macOS restoration remain unverified; no desktop control or Release rebuild.

## 2026-10-01 — Welcome guide Wallpaper Engine ownership check

- python3 scripts/test.py --only DownloaderLifecycleTests — exit 0; 24 passed, 0 failed, 0 skipped. Covers owned, missing and unknown license responses, complete app IDs, session reset and no downloads during sign-in.
- python3 scripts/test.py --only ControlPanelShellTests/testWelcomeOwnershipNoticeAllowsContinuingAndRecheckingAfterPurchase — exit 0; 1 passed. Offscreen guide covers purchase links, unconfirmed results, continuing setup and rechecking after purchase.
- python3 scripts/test.py — exit 0; 226 Python tests passed; native gate 901 passed, 0 failed, 11 skipped of 912. Skips: 9 opt-in media tests and 2 live Workshop tests.
- Impeccable detector on WebUI/welcome.js — exit 0; no findings. git diff --check — exit 0. Added strings cover all shipped languages.
- Live Steam authentication and license responses, desktop presentation and visual appearance remain unverified; synthetic PTY fixtures and offscreen WebKit only. Release app not rebuilt.
- python3 scripts/clean.py --dry-run — exit 0; existing shared artifacts retained to avoid removing unrelated evidence.

## 2026-10-01 — Bounded HDR and interactive scene compatibility

- User selected a general bounded bloom model rather than claiming exact proprietary Wallpaper Engine HDR parameter parity. No wallpaper-specific rendering branches or private asset edits.
- cargo test --release -p shader --features ffi with the build cargo environment: exit 0; 522 passed. Fourth-channel metadata and disabled-slot behavior covered.
- Targeted CMake build and text/script/mouse/scene/texture suites: exit 0; 60, 84, 13, 89 and 22 passed respectively; two opt-in local text cases skipped. Particle suite: 41 passed. Diagnostic dumper library compiled.
- GPU HDR filters: four passed, including real TEX bit23 emissive radiance through effects/linked layers, SDR preservation, missing-source rejection, bounded spread, live strength changes and zero halo strength.
- Installed perspective scene: both Metal and Compatibility completed 1200/2400 frames at 1/60 and 1/120 simulation steps, 1680x1050, synthetic clock click/hover entry/exit and broadband audio. Sampled script errors zero; menu and overlay transitions, moving bars/waves and numeric readouts verified.
- Full-resolution scenarios: Native Metal 1200 frames and Compatibility 2400 frames at 3840x2160 completed; sampled input transitions and script errors passed. Offscreen frames visually inspected; no desktop capture or audio hardware used.
- Native drawFrame CPU means: 0.60 ms at 1680x1050, 0.59 ms at 3840x2160. These exclude script tick/GPU/display cadence and are not FPS or power claims; HDR half-float target cost is documented, with no forced supersampling.
- python3 scripts/test.py --serial: exit 0; all 17 Python modules passed; native 883 passed, zero failed, 11 opt-in skips of 894.
- python3 scripts/check_renderer.py: isolated final run exit 0; all renderer executables passed, ten generated pooled/isolated comparisons equal with zero diagnostics, eight projects reloaded twice. Three default opt-in asset checks skipped; target scene exercised separately. Earlier concurrent run failed one baseline video-frame timing assertion; retained assertion passed on the isolated full rerun.
- Documentation links and provenance JSON checked. No Release app rebuild, launch/restart, live settings changes or desktop input. Exact Windows visual equivalence, physical presentation cadence and power effects remain unverified.

## 2026-10-01 — Lock-screen extension mismatch diagnostics

- Added revision-scoped extension identity, schema-version and configuration-load diagnostics; legacy extension copies are identified by running bundle path after readiness timeout.
- python3 scripts/test.py --only LockScreenExtensionDiagnosticsTests --only LockScreenWallpaperServiceTests: exit 0; 31 passed before the final screen-saver monitor regression was added.
- python3 scripts/test.py: exit 0; all 226 Python tests passed; native gate 898 passed, 0 failed, 11 skipped of 909. Includes all 10 new diagnostic regressions.
- Native skips: nine opt-in media/device tests and two live Workshop network tests. No asset-dependent renderer checks were run; renderer and bridge were unchanged by this task.
- Covered incompatible schema before scene decoding, missing/malformed configuration, stale revisions, same-bundle symlinks, configuration success without frame readiness, failed diagnostic writes, legacy timeout restoration and later screen-saver configuration failure.
- git diff --check: exit 0. XcodeGen regenerated the project through test.py; native localization checks passed in the gate.
- python3 scripts/clean.py --dry-run: exit 0; broad cleanup deferred to preserve the shared workspace renderer evidence under artifacts.
- No Release rebuild, app restart, registration changes or desktop tests. Live extension selection and lock-screen visuals remain unverified.

## 2026-10-01 — PR 19 backup and preset review fixes

- `python3 scripts/build.py --renderer-only` — passed; rebuilt the isolated worktree’s missing current bridge library and regenerated unchanged bindings after the first targeted run could not link.
- `python3 scripts/test.py --only WallpaperBackupTests --only WallpaperPresetStoreTests --only ControlPanelBackupFlowTests` — passed, 50 tests; an earlier run exposed volatile-default cleanup in the new fixture, corrected before this run.
- `python3 scripts/test.py` — passed once as the final gate: all Python checks passed; 1006 native tests passed, 0 failed, 11 opt-in media/network cases skipped.
- Regressions cover persistent-only preference export/conflicts/rollback, a 48 MiB preset archive, manifest rejection before payload reads while preserving an existing destination, and preset directory roundtrips with hidden Finder metadata.
- The WebUI mechanical detector reported no findings; `git diff --check` passed. No renderer source or generated-binding changes.
- No Release app build, desktop/window-driving, visual presentation, audio hardware or live-account verification. The shared main checkout’s existing commit and uncommitted edits were not changed.

## 2026-10-01 — Reusable wallpaper workflows rebased onto 1.2.1

- Implementation: local collections and named playlist plans, wallpaper property presets, staged local backup/restore, per-display still-image placement, compatibility cards, Shortcuts display selection, and Web page mute/native HTML-media gain; all four UI languages updated.
- Fetched origin and rebased feat/library-workflows-and-web-audio onto main a5200fe; preserved remote import-picker startup, screen-saver/renderer updates, localization and historical verification records. Regenerated Xcode project and UniFFI outputs rather than editing generated conflicts.
- Scene restore security: scene/scenetexture overrides and texture defaults now resolve to validated retained image files instead of unapproved original paths. A keep-existing tree without matching bytes is rejected before publication. WallpaperBackupTests: 24 passed before rebase; included again in the rebased full gate.
- python3 scripts/build.py --renderer-only — exit 0 after rebase; renderer library and Swift bindings regenerated. No Release app build.
- cargo test -p wallpaper-bridge with scripts/build.py cargo_environment — exit 0 after rebase; 363 passed, 0 failed.
- python3 scripts/check_renderer.py — rebuilt current renderer probes, exit 0; 10 generated scene pixel comparisons and 8 projects x2 reload cycles passed. Three local-asset-dependent cases skipped; no full authored-wallpaper compatibility claim.
- python3 scripts/test.py — exit 0 after rebase; all Python checks passed, 1002 native tests passed, 0 failed, 11 opt-in media/network tests skipped of 1013.
- Before rebase: six temporary real offscreen WKWebView feature flows passed and were removed after retaining focused regressions; renderer draft/metadata and synthetic pointer-capture boundaries were injected. Native WebKit output probe invoked media gain and read back mute false→true→false without audio hardware.
- Desktop/visual presentation, actual speaker output, live account services, Siri/Shortcuts UI and power remain unverified. No app launch, permission prompt, wallpaper change, install or restart.

