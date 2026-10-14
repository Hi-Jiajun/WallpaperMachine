# Appearance

**Settings → Appearance** styles the app's own interface. Wallpaper colors,
playback and display settings are untouched.

## Options

| Setting | Values | Notes |
| --- | --- | --- |
| Appearance | **System (Auto)**, **Light**, **Dark**, each shown as a picture of a window | System follows the macOS light/dark setting without reloading the panel; a manual choice also sets the native app appearance |
| Accent color | A row of macOS-style swatches and a color well, with the chosen hex value beside them | The well takes any color the swatches lack. Colors buttons, links and focus rings |
| Surface tone | **Neutral**, **Warm**, **Cool**, each shown as a picture of a window | Warms or cools the window background |
| App icon | **Minimal**, **Day**, **Night** | Changes the running Dock icon immediately and restores the choice at launch; Finder and the menu bar stay unchanged |

Accent shades adapt so text, buttons and focus rings stay readable against the
resolved background. The theme runtime (`WebUI/theme.js`) resolves appearance, tone
and accent tokens before first paint, so the panel does not flash an unstyled or
wrong-appearance frame.

## Window material

The sidebar shows the system's translucent sidebar material. The web view draws no
background, and `PanelContentController` (`ControlPanelWindow.swift`) places an
`NSVisualEffectView` (`.sidebar` material, behind the window, following the window's
active state) behind the whole page. The page's sidebar paints nothing, so the material
shows through it; every other region paints its own surface token. macOS decides how the
material looks: it is opaque under **Reduce Transparency** and dims in an inactive
window. Native injects `window.__appVibrancy`, `theme.js` marks `<html data-vibrancy>`,
and a page without that flag (the offscreen test page) paints a plain sidebar surface
instead.

## Persistence and reset

Choices are stored natively (`AppThemeStore`, the `WallpaperMachine.appTheme` default),
so they survive the panel's ephemeral WebKit data store and web-content recovery and
stay usable even when renderer settings are unavailable. Changes apply immediately and
are remembered for the next launch. An invalid accent (anything but `#rrggbb`) is
rejected without overwriting the saved value. **Reset appearance** restores System, the
default accent, the Neutral tone and the Day icon; it does not touch wallpapers,
playback or display configuration.

## App icon

The Dock picker is independent of the panel's light/dark theme. **Day** and **Night**
are the white-background and black-background variants of the bundled icon, which
macOS also selects for Finder through its *Appearance → Icon & widget style* setting;
neither the panel theme nor the Dock icon preference overrides that. **Minimal** uses
the same frame-and-gear mark in blue on white, without the gradient wallpaper fill. The
selection is applied with `NSApplication.applicationIconImage` from
`WebUI/app-icons/{minimal,day,night}.png`, without changing the app bundle or resetting
system icon caches. Day is the default. The selected icon applies while the app is
running; a pinned Dock entry can show the bundled icon after the app quits. The menu
bar uses a monochrome template (`TrayIcon`), and the panel shows the chosen icon's image
on the first welcome page and at the top of Settings → About.

## Brand assets

`scripts/brand.py` owns the mark's geometry and colours and documents its outputs in
its module docstring; the Manrope wordmark is stored as outlines in
`scripts/lib/wordmark.py`, so rendering needs no font installation. Regenerate the app
assets on macOS (it uses Quick Look, `sips`, and Xcode's Icon Composer and Swift) with:

```sh
python3 scripts/brand.py                           # app icon, Dock choices, tray icon, DMG background
python3 scripts/brand.py --website <site-checkout> # plus logo, favicons and manifest there
```

- The app icon is generated as `App/Resources/AppIcon.icon`, an Icon Composer document
  of vector foreground layers plus solid light and dark backgrounds that Xcode compiles
  into the app's assets and fallback ICNS. macOS owns the outer mask, so no inset tile
  or opaque canvas is baked into the artwork. The mark is a filled outline (macOS 26
  recoloring fills an open stroked path despite `fill="none"`), and the panel meets the
  frame through an explicit curved cutout rather than an SVG mask so Icon Composer
  preserves the separation.
- The Dock exports `WebUI/app-icons/{minimal,day,night}.png` are fixed-appearance
  1024 px renders through Icon Composer with `--design-generation 26` (the deployment
  target's generation, not the newer preview default), keep a 100 px transparent outer
  margin and load as 512-point Retina images. The root README displays `day.png`;
  update its path there if the export is renamed.
- The small-size mark is heavier and stays reserved for the menu bar; the panel shows the
  Dock icon images instead.
- Website export writes `brand/logo.svg` (light backgrounds), `brand/logo-dark.svg`,
  `brand/mark.svg`, `brand/app-icon-{minimal,day,night}.{svg,png}` (the unqualified
  `app-icon.*` is Day) and favicons, touch and manifest icons. Its PNGs are copied from
  `WebUI/app-icons/` to keep the native rendering; SVGs share the geometry and colors
  without Icon Composer's lighting. To refresh only the website from the current Dock
  PNGs, add `--skip-app`; after changing native icon geometry, run the regular
  `--website` command so both sets regenerate together.

## Verification

Appearance preferences, invalid-change rejection, reset isolation and the offscreen
panel regression (real Appearance controls committed through the native bridge, live
native appearance changes, explicit Light winning over Dark, recovery through the
WebContent reload path) are inventoried under *Appearance* in
[coverage](../testing/coverage.md). The rendering of the icon variants in Finder and the
Dock needs a manual look.
