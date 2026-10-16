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

## 2026-10-16 — Release banners and highlights in the changelog

Feature releases can carry a bundled 3:1 banner (Resources/ReleaseBanners/x.y.z.jpg) shown in CHANGELOG.md, the GitHub release page and the What's New window; the release-notes model writes Highlights for x.y.0 and groups many commits per area. Banner for 1.5.0 added.

- `python3 scripts/test.py` — exit 0; 3872 tests: 3827 passed, 45 skipped; test_release_notes.py 61 tests OK
- `python3 scripts/test.py --only WhatsNewTests` / `--only AppUpdateTests` — passed while iterating
- Visual: temporary offscreen XCTest snapshot of the What's New window with the bundled 1.5.0 banner (dark), banner above the header at 712 pt, notes below; probe deleted
- Skipped: live --ai model run (no RELEASE_NOTES_API_KEY locally), so the 1.5.0 wording is written by CI at release; the raw.githubusercontent banner URL is checked only by unit test until v1.5.0 is tagged

## 2026-10-16 — Tabs in the title bar, Now Playing bar and one-colour title bar on top of the Filters sidebar

- Rebased onto main's Filters sidebar (69955b77, cf9f5ebe): my own filters panel was dropped; the sidebar now slides from the window's leading edge, and Installed's has the Collections group at its top.
- Window: no window sidebar; Library, Steam Workshop, pixiv and Settings are tabs centred in the title bar (symbols only under 960 points) with the mark, name and version leading; Library has All wallpapers and Favorites chips; Now Playing is a bottom bar whose wallpaper part opens a details popover; Settings searches above its own section list.
- Title bar: macOS 26 draws a band per window column (opaque grey over a page without a top scroll view, its own dark band over the system inspector). The inspector is now an in-page InspectorColumn (260-420, drag to resize) and the Filters sidebar, page and inspector sit in one full-width scroll host, so the bar is one colour.
- Real window (desktop control allowed by the user): Library with Filters sidebar and inspector open, and Settings, sampled 29,29,31 across the whole bar in dark; inspector edge drag resized it.
- Gate: python3 scripts/test.py passed, 3826 passed, 0 failed, 45 skipped. Targeted shell, root, welcome, installed, inspector, pixiv and workshop classes: 160 passed.
- Not run: desktop UI tests (Tests/UI updated, not executed); light appearance not checked on the real window.

## 2026-10-16 — Filters sidebar replaces the Filters popover

- Change: Installed, Workshop and pixiv filters moved from a popover into one shell-level Filters sidebar (FilterSidebar in PanelDetail) that slides out from under the window sidebar; Filter buttons and the sidebar's own top-right button toggle it.
- python3 scripts/test.py: passed, 3829 passed, 0 failed, 45 skipped (Python suites OK).
- New tests: ShellModelTests (one sidebar across library pages, waits out Settings; takes turns with the inspector under 960 pt), ShellRenderTests (sidebar + inspector fit the split view from 1240 down to 760 pt).
- Migrated tests: InstalledBrowserModelTests, InstalledPageRenderTests (sidebar width 268 pt in every language and appearance), WorkshopBrowserModelTests, ShellModelTests support-prompt/popover cases.
- Visual: offscreen snapshot (temporary probe, deleted) confirmed placement beside the page and search bar; offscreen rendering draws no glass, so the glass look and the slide animation were not seen on a real desktop.
- Gap: InspectorRenderTests smallest-window test timed out twice earlier today on the untouched base and passed in this run: flaky, unrelated.

## 2026-10-16 — origin/main's telemetry and sharing carried into the native panel

Main's 103 unpushed commits were rebased onto origin/main, whose 1.4.1 telemetry and sharing commits were written for the web panel the native SwiftUI panel had replaced; their services kept, their web UI rebuilt natively (Storage switch and report, guide draft, three-prompt sheet, Share…, About links).

- `python3 scripts/test.py --only` the ten touched classes (PanelPerformanceDataTests, PanelSharingTests, PanelSupportPromptTests, SupportPromptPresenterTests, SupportPromptStoreTests, FirstRunModelTests, FirstRunDraftTests, Telemetry{Service,Sampler,Client}Tests) — 97 passed
- `python3 scripts/test.py` — exit 65; 3864 tests: 3815 passed, 4 failed, 45 skipped. The 4 are SettingsBRenderTests.testTheEditorsAndOpenDisclosuresStillFitTheNarrowestWindowIn{English,Japanese,SimplifiedChinese,TraditionalChinese}: they hang laying out Keyboard shortcuts with its links disclosure open, and the English one fails the same way on 820c436a, before the rebase and this port
- `python3 scripts/build.py --swift-only --configuration Release` — built; the binary carries the new Storage rows
- Not checked: the share menu and the sheets on screen (no desktop run authorised), the live website endpoint

## 2026-10-16 — Settings name what overrides a quality or frame-rate choice

Reported as On battery: Keep running still capping wallpapers at 30 fps. The app's log showed the low-battery rule (saved as Reduced quality, level 20%) engaging at 20% charge; nothing in Quick Settings said so, and the Displays and inspector notes blamed Performance settings and linked to a Frame rate limit reading No limit. Quick Settings' Quality and On battery modules, Performance › Effective now and the Displays and inspector frame-rate notes now name the cause and open the page it is set on.

- `python3 scripts/test.py --only QualityReportTests --only QualityPresetTests --only DisplaysSettingsModelTests --only PanelPropertyRowsTests --only PanelLibraryActionsTests --only SettingsSectionsRenderTests --only SettingsSearchTests --only PanelSettingsValuesTests --only SettingsControlsRenderTests --only PanelPerformanceSettingsTests` — 157 passed
- `python3 scripts/test.py` — exit 0; 3819 tests: 3774 passed, 45 skipped (opt-in media and network layers)
- `python3 scripts/build.py --renderer-only` — run first in the worktree to replace a stale bridge library; regenerated bindings unchanged
- Skipped: no desktop run; the new lines were not looked at on screen (render tests lay out the Quick Settings and Performance pages with a throttle in force in every language). Manual check added to docs/testing/manual-smoke.md.
- Gap: a condition's Pause or Stop overriding On battery: Keep running is still not shown in Quick Settings.

## 2026-10-16 — Native Metal matched to Wallpaper Engine 2.8 scenes: gate, comparison with its frames and Release build

The 70 Wallpaper Engine parity commits on main (5f3e5d58..98be08fa: scene, text, particle, shader, script, video and harness changes), checked in an isolated worktree of the landing chain and then built from main.

- `python3 scripts/check_rust.py` — exit 0
- `python3 scripts/check_renderer.py` — exit 0; no FAILED line in the evidence logs and every report.json count 0; skipped: the shader asset tests (no WALLPAPER_MACHINE_ASSETS_ROOT) and the local-project gtests
- `python3 scripts/test.py` — 3767 to 3769 of 3815 passed, 45 skipped; `PixivBrowserRenderTests.testAtTheSmallestWindowThePillGivesWayToTheDownloadsButtonAndTheInspectorToggle` times out, as it does on main 5f3e5d58 without this work; `PowerSourceResamplerTests.testStartingTwiceDoesNotObserveTwice` and another Pixiv grid test failed once under load and passed in the other runs
- every one of the 70 commits built alone and passed the 30 renderer test binaries (and the Swift classes and Rust crates it touches)
- Native Metal renders of 40 Workshop scene wallpapers compared with Wallpaper Engine 2.8.42's own frames (display resolution, pointer at the centre, real-time pacing, clock at the capture time): of 324 differences found before, 142 fixed, 13 improved, 18 unchanged, 0 worse; no wallpaper left with a major difference
- gaps: web wallpapers were not recaptured (no change to the web host); volumetric lights, model MSAA and the other listed known limitations remain; one reference capture showed another wallpaper; the app was not run on the desktop
- `python3 scripts/build.py --configuration Release` — OK; the app's bridge checksums match its bindings

## 2026-10-16 — Text layout, placement, effect buffers and fonts: review follow-ups of the text steps

Follow-ups to the reviews of the ported text steps (face cache, alignment words and brightness, card layout, placement, effect buffers, composite, fonts), checked in an isolated worktree with the renderer test binaries; the app gate (`scripts/test.py`), `scripts/check_renderer.py` and the Swift unit target were not run, and there was no desktop, app launch or audio.

- every renderer test binary of the worktree (`run_suites.sh`, 30 binaries) — all passed, among them `text_object_runtime_test` 158, `metal_scene_draw_smoke` 130, `scene_schema_tests` 156, `script_runtime_compat_test` 171, `mouse_input_test` 30, `layer_texture_reference_test` 38
- new tests fail without their change: a font file rewritten or deleted under a cached face, the rows set within the widest row's width (not the block's), the effect matrices of a screen-anchored text, CJK punctuation drawn by the symbol face
- rebuild cost of a text card that changes in texels, six forced rebuilds on a real clock scene (72 passes, 1920 by 1080, native Metal) — 0.5 to 0.8 ms to lower and 39 to 45 ms to compile; 0.6 to 0.9 ms on a one-layer scene
- gaps: no Wallpaper Engine frame was compared for the changes of this pass; the brightness probes (`probetextb1`, `probetextb2`) and the exponent probe for a chain other than opacity are uncaptured, so the HDR half of the text brightness rule and the composite exponent of non-opacity chains stay inferred; that Segoe UI Symbol lacks the CJK punctuation is inferred; the sandboxed lock-screen extension was not run with a face opened by path

## 2026-10-15 — Scene font keys, Windows-font stand-ins, the glyph fallback list, opaque backgrounds and Windows font names in web wallpapers

Worktree steps T11, T12 and T10 of the text parity work, checked in an isolated worktree with the renderer test binaries and, for the Swift part, a standalone XCTest bundle built from the repository's own source files; the app gate (`scripts/test.py`), `scripts/check_renderer.py` and the Swift unit target were not run, and there was no desktop, app launch or audio.

- `ctest` over every renderer test binary built from the worktree — 1484 of 1485 passed; 10 not run (2 disabled, 8 skipped for lack of local corpus, video or project inputs); the one failure, `FrameTimerTest.ADrawSlightlyLongerThanTheIntervalDoesNotHalveTheRate`, is a wall-clock timing test in code this change does not touch and passed on 3 of 4 reruns alone
- `text_object_runtime_test` 154 (152 passed, 2 skipped: the local-project tests), `metal_scene_draw_smoke` 110 (108 passed, 2 skipped), `scene_schema_tests` 137, `script_runtime_compat_test` 163, `layer_texture_reference_test` 37, `project_property_preview_test` 23, `mouse_input_test` 22, `static_subgraph_cache_test` 26, `metal_backend_test` 36 — all passed, on both renderers where a test draws
- `WebWallpaperFontAliasTests` (10 cases, real offscreen `WKWebView`s, no window) compiled with `swiftc` against `Shared/` and run with `xcrun xctest` — all passed; with the script emptied the Han, Segoe UI and subframe cases fail
- the two opaque-background draw cases fail with the fill switched off (196 failed checks) and pass with it, on both renderers
- the Consolas clock of workshop 3299228616 rendered with `render_ours.py` against Wallpaper Engine's frame: digit rows 87 tall in both (101 with the first stand-in tried) and rows 362-448 here against 361-447, the date's 471-491 against 470-491; before the ascender was set to 0.743 em the clock stood 12 pixels low
- probetext1 against Wallpaper Engine's frame: cap tops and baselines unchanged and equal (793.0/651.0 and 602.5/320.1)
- gaps: the probe of the eight font keys at three alignments (`probefont1`) was queued and the capture loader was not running, so the ascender and descender of Cambria, Segoe UI and Calibri stay the fonts' remembered tables with only their sum checked; no Wallpaper Engine frame of Cambria, Segoe UI, Calibri or an opaque background was compared; the web stand-ins' glyphs and line metrics were not compared with a Wallpaper Engine frame; the lock-screen extension was not run

## 2026-10-15 — Text through effects is composed over the scene behind it, and padded only while an effect is visible

Worktree step T9 and T5 of the text parity work, checked in an isolated worktree with the renderer test binaries; the app gate (`scripts/test.py`) and `scripts/check_renderer.py` were not run, and the spec's generated-picture case for the composite is covered by drawn `metal_scene_draw_smoke` cases instead.

- `ctest` over every renderer test binary built from the worktree — all 1476 that ran passed; 2 are disabled and 8 skipped for lack of local corpus, video or project inputs
- `text_object_runtime_test` 145, `metal_scene_draw_smoke` 106 (2 skipped: the local-project tests), `scene_schema_tests` 137, `script_runtime_compat_test` 163, `layer_texture_reference_test` 37, `project_property_preview_test` 23, `mouse_input_test` 22, `static_subgraph_cache_test` 26, `metal_backend_test` 36 — all passed, on both renderers where a test draws
- probetext4 rendered with `render_ours.py` against Wallpaper Engine's frames: stems at alpha 1, 0.65 and 0.5 are 1.000, 0.651, 0.498 plain and 1.000, 0.275, 0.125 through `opacity`, equal to Wallpaper Engine's
- a scene of three text layers whose shipped `opacity` effect a script switches on from 0.5 s to 1 s, drawn natively at 1920x1080 with the shipped assets (`LocalProjectsDrawTheSamePictureOnBothRenderers`, native only): ink at frames 10, 45 and 90 with the same box, where frames 10 and 90 had none before the passthrough took a white `g_Color4`
- the new draw cases fail without their fix: the scripted, add and shipped-effects cases without the white `g_Color4`, the add case without `SetIdleFinalBlend`; the no-pass case fails without `EffectCountsForText` and the skip of effects with no pass
- gaps: whether an effect that leaves alpha alone composes at the alpha cubed is open (the VHS frame of 3465215190 reads the alpha squared) and the capture that settles it was not taken; no Wallpaper Engine frame of HDR text through an effect, nor of mode 31 text with an effect, was compared

## 2026-10-15 — 2D scene resolution: Display resolution by default

Headless only: no desktop, no audio, no app launch, no Release build.

- Renderer binaries rebuilt from the final tree and run whole: `render_scale_test` 23 passed (13 new `RasterResolution.*`), `wallpaper_scaling_test` 8, `metal_backend_test` 35, `unchanged_present_test` 11 (1 new, a running scene on both renderers), `metal_scene_draw_smoke` 86 (2 new). The picture test fails when the compatibility backend is made to ignore the choice.
- `python3 scripts/check_rust.py` — exit 0: core 315, bridge 602 (5 new), core-integration, shader; the asset-dependent shader cases skipped as printed (no Wallpaper Engine assets directory, no unpacked corpus).
- `python3 scripts/test.py --only` on the settings classes (PanelPerformanceSettingsTests, PanelEnergyRestartTests, SettingsSectionsLocalizationTests, SettingsSectionsRenderTests, SettingsControlsRenderTests, SettingsSearchOfferTests, PanelSettingsValuesTests, SettingsEditingModelTests) — 62 passed. All 113 panel classes at once: 994 passed, 27 failed, every failure a test that does not pin the language reading this Mac's saved app language (zh-Hans), and failing the same alone; not caused by this change.
- The 21 Python script test modules (catalog and panel localization included) — passed.
- Both renderers draw two local 1920x1080-canvas scenes byte for byte alike at 3456x2234 backed at 2x in both modes (`DrawTheSamePictureOnBothRenderers` with `WE_TEST_COMPARE_RESOLUTION`, 60 frames). Display mode crops show crisper edges and grain than Canvas at the same size; viewed offscreen, never on the desktop.
- Cost, `LocalProjectEnergyIsMeasuredHeadlessly` (`WE_TEST_ENERGY_RESOLUTION`), 3456x2234 at 2x, 60 fps, 2 x 20 s per mode, canvas/display/display/canvas: a bloom and effect-chain scene on Native Metal 1.62 -> 3.42 ms own GPU time per frame, render targets 35 -> 94 MB, peak footprint 380 -> 455 MB; on Compatibility 1.91 -> 3.27 ms and 399 -> 480 MB; a 26-layer scene of mostly author-sized buffers 1.76 -> 2.33 ms, 132 -> 160 MB, 515 -> 555 MB. CPU time per frame unchanged; energy not measured; footprint carries about 30 MB of run-to-run noise.
- Not run: the full `python3 scripts/test.py` and `python3 scripts/check_renderer.py` gates, a desktop run, the lock screen (it never sets the choice and keeps the canvas), a Release build.
