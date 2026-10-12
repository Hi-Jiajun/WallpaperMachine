# Automation

WallpaperMachine can choose wallpapers by weekday, time, sunrise/sunset, system
appearance or Focus. Global keyboard shortcuts, actions in the Shortcuts app
(and so Siri and Spotlight), and `wallpapermachine://` links run explicit
commands (`AutomationCommand`)
through `AppAutomation` into `AppDelegate.performAutomation`, which the menu bar's
**Previous Wallpaper** and **Next Wallpaper** use too. They only do what the menu
bar and the panel already offer: play, pause, the previous or next wallpaper,
apply an installed wallpaper, copy a saved playlist to a display, apply a saved
property preset, or open the window. Automatic selection uses the same serialized
wallpaper commands and keeps manual choices until the next event.

[Display layouts](display-layouts.md) add one command for restoring saved wallpaper
choices across multiple independent displays.

## Automatic selection

**Settings → Displays → a display → Automatic wallpaper selection** offers:

| Mode | Behavior |
| --- | --- |
| Off | Leaves the wallpaper and any existing playlist under their usual controls. |
| Time schedule | Up to 64 rules, each with weekdays, a clock time or sunrise/sunset plus a −180…180 minute offset, and a wallpaper or saved playlist. |
| Follow system appearance | Separate choices for the system's light and dark appearance; an empty choice leaves the display as it is. The panel's own theme is independent. |
| Follow desktop Space | Experimental choices by desktop UUID, reloaded after entering that desktop; an empty choice keeps the current wallpaper. See [Space-based choices](spaces.md) for pause/Focus behavior and native lock-screen limits. |

A wallpaper target turns that display's playlist off after successful activation.
A saved playlist copies its current settings, then the existing playlist scheduler
takes over. Editing a saved plan does not update an already applied copy. Mirrored
and disabled displays do not accept rules. Disconnected displays keep their settings
and catch up when eligible again.

Time rules use the Mac's time zone. The latest due rule wins; equal timestamps
choose the later rule in the list. A daylight-saving gap moves a nonexistent time
to the next valid clock time; a repeated time fires at its first occurrence only.
After sleep, lock, pause or a covered display, only the latest due choice is applied
when playback can run again. Manual wallpaper and playlist choices mark the current
event handled, including across relaunch. A rule that comes due while your own
Apply is waiting on that display, or running there, gives way to it and is not
applied afterwards; it counts as handled, like a manual choice. Saving changed rules creates a new event
and may apply it immediately. A failed event is reported in the display's section
and waits for **Retry automatic change** or a later event.

**Sunrise and sunset**, at the bottom of Displays, accepts manual latitude and
longitude: north/east positive, south/west negative. Calculation is local, requires
no location permission or network request, and follows the approximate
[NOAA solar equations](https://www.gml.noaa.gov/grad/solcalc/solareqns.PDF).
It uses the Mac's time zone even when coordinates describe another region. Weekdays
refer to the solar event's civil day before applying the offset; offsets may cross
midnight. Days without a sunrise/sunset near the poles are skipped. A solar rule
without saved coordinates has no event until a location is supplied.

## Focus selection and restoration

In **System Settings → Focus → Focus Filters**, WallpaperMachine also offers
**Use wallpaper** and **Use saved playlist**, with an optional display. Omitting the
display pins the panel's current target when that Focus choice takes effect. The
selection temporarily overrides time and appearance rules; existing pause/mute/stop
Focus actions are documented under [Performance](performance.md#low-power-mode-heat-and-focus).

When the filter ends, a currently due automatic rule takes over; otherwise the
previous wallpaper and playlist return. A manual wallpaper chosen during Focus is
preserved unless a new automatic event became due. Editing or applying a different
playlist during Focus keeps that new playlist instead of restoring the old one.
Restored rotations start a fresh interval; restored day/night playlists wait until
their next boundary. Deleted wallpaper, plan and collection references are checked
again on restoration. Focus recovery is journaled before applying a choice so an
interrupted launch can recover it. Actual macOS Focus delivery still requires a
separate desktop test.

Rules and coordinates are stored in `WallpaperMachine.automaticWallpapers` and
`WallpaperMachine.solarLocation` and included in local backups. Keep-existing restore
merges by display. The handled-event and Focus recovery records are local runtime
state, excluded from exports, cleared when restored settings replace their baseline,
and retained if restore rolls back.

## Commands

| Command | What it does |
| --- | --- |
| Play, Pause, Play or pause | Resumes or pauses every wallpaper, as the menu bar's Play/Pause does. |
| Previous wallpaper | Returns to an earlier successful switch on the chosen display; repeated requests keep walking back, skipping deleted or unsupported wallpapers. History is consumed only after Apply succeeds. |
| Next wallpaper | Changes a display to its playlist's next when it rotates (see [playlists](playlists.md)), otherwise to the next playable wallpaper in library order. |
| Apply a wallpaper | Applies an installed wallpaper, named by its id (its folder name in the library). |
| Apply saved playlist | Copies a saved plan to the chosen display and starts it when playback can run. |
| Apply wallpaper property preset | Applies a saved preset to its owning wallpaper on every display using it; rejects unapplied editor drafts. |
| Apply display layout | Restores the saved wallpaper arrangement across its named displays, with full preflight and verified failure recovery. |
| Open | Brings up the control panel, on Installed, Discover, pixiv or Settings when named. |

Previous, Next, Apply Wallpaper and Apply Saved Playlist act on the panel's target display unless a display is named, and
only an enabled display showing its own wallpaper can be switched. Switches share
the display's command slot with the panel, so the latest request for a display
wins; an automatic change (a playlist, a rule, an update reload) never replaces
a request that is waiting or running there. A command that arrives while the app is still
starting (the system may launch it to run one) waits up to 15 seconds for the
library to load, then fails with a message saying so. If the renderer could not start at all, opening the
panel still works, since Settings is where a failed start is put right; every
other command fails at once instead of waiting. A failure from a link or a keyboard shortcut shows at
the foot of the menu bar menu; the Shortcuts app shows its own.

## Keyboard shortcuts

**Settings → General → Keyboard shortcuts** records one shortcut each for
**Play or pause wallpapers**, **Previous wallpaper**, **Next wallpaper** and **Open the control panel**.
None is set until recorded, so the app never takes a combination another app
expects. **Record…** takes the next key pressed in that row (Escape alone, or
moving focus away, gives up); the key must be held with ⌘, ⌥ or ⌃, except F13
to F20, which type nothing and may stand alone. The page sends the key's position
(`KeyboardEvent.code`), which `GlobalHotKeys` maps to Carbon's virtual key code,
so a shortcut stays on the same key whatever the keyboard layout. One combination
serves one action.

`GlobalHotKeys` registers them with `RegisterEventHotKey`, which works whichever
app is in front, needs no Accessibility permission and delivers only those
combinations. A combination another app already holds is refused by macOS; the
row says so, and says it again after a relaunch until it is changed. Shortcuts
are kept in the `WallpaperMachine.hotKeys` default.

## Shortcuts app, Siri and Spotlight

App Intents in `App/Services/Automation/WallpaperIntents.swift` add **Pause
Wallpapers**, **Resume Wallpapers**, **Play or Pause Wallpapers**, **Previous Wallpaper**, **Next
Wallpaper**, **Apply Wallpaper** (with the wallpaper chosen from, or searched in,
the installed ones that can play), **Apply Saved Playlist**, **Apply Wallpaper
Property Preset**, and **Open WallpaperMachine**. The latter two configuration
actions and their searchable entities live in `WallpaperConfigurationIntents.swift`.
That file also supplies **Apply Display Layout** with a saved-layout picker and
no display parameter; the layout itself identifies its target screens.
`WallpaperMachineShortcuts` offers play/pause, previous, next and the wallpaper,
playlist, property preset and display layout actions to Siri and Spotlight without
building a shortcut ("Next wallpaper in WallpaperMachine", "Apply a wallpaper with
WallpaperMachine"). The actions run in the app's own process; if it is not running,
macOS starts it first.

**Previous Wallpaper**, **Next Wallpaper**, **Apply Wallpaper** and **Apply Saved
Playlist** have an optional **Display** picker.
It lists connected, enabled independent displays using the same stable identities
as the panel; leaving it empty keeps the panel-target behavior. Execution checks
eligibility again, including when a queued command gets its turn. A disconnected
or mirrored target is rejected rather than silently redirected to another screen.
Property presets do not offer a display picker because wallpaper properties are
shared across displays. Presets whose wallpapers are no longer installed are not
offered; deletion between selection and execution is checked again.

## Links

`Info.plist` claims the `wallpapermachine` scheme (`CFBundleURLTypes`). The
command is the host, and `display`, `id` and `page` are query values:

```
wallpapermachine://play
wallpapermachine://pause
wallpapermachine://toggle
wallpapermachine://previous
wallpapermachine://next
wallpapermachine://next?display=primary
wallpapermachine://apply?id=3632513108
wallpapermachine://playlist?id=PLAN_ID&display=primary
wallpapermachine://preset?id=PRESET_ID
wallpapermachine://layout?id=LAYOUT_ID
wallpapermachine://open?page=settings
```

A link with an unknown command, a query value the command does not take, a value
given twice, or a path is ignored and logged rather than guessed at. A browser
asks before it opens the app. **Settings → General → Shortcuts app and links**
lists the links. Plan and preset IDs are the IDs in their saved records, not their
display names; Shortcuts supplies name-based pickers without requiring these IDs.

## Verification

Link parsing and refusals (`AutomationCommandTests`), waiting for the app and failures
reaching the caller (`AppAutomationTests`), hotkey preferences and the key-code and
modifier mapping (`HotKeyPreferencesTests`, `GlobalHotKeysTests`), the planner, store and
scheduler (`WallpaperAutomationPlannerTests`, `WallpaperAutomationStoreTests`,
`WallpaperAutomationSchedulerTests`: weekday rules, simultaneous events, appearance
choices, DST, solar offsets crossing midnight, absent polar events, catch-up and retry
against a fake clock and the real command queue, manual precedence including a rule
giving way to a waiting or running manual command, Focus exit and
interrupted recovery), native validation and queued manual playlist edits
(`WebPanelPlaylistTests`), the offscreen rule editor (`ControlPanelAutomationTests`) and
rule merging and rollback in backups (`WallpaperBackupTests`) each have their own suite;
the Space tests are listed in [Spaces verification](spaces.md#storage-and-verification).
The domain inventory is in [coverage](../testing/coverage.md).

These tests do not verify a real press of a registered shortcut, the Shortcuts app, a
link opened from a browser, actual Focus transitions, system appearance notifications,
Siri/Spotlight registration, visible panel layout or desktop playback.
