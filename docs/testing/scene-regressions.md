# Scene regressions

Regression areas for what a scene looks like and does: cameras and cursor
mapping, scripts and bindings, layers and compositing, text, animation and the
shader pipeline. Each bullet names the test that guards a behavior and the
invariant or trap it protects; keep them covered when touching that area.
The commands, probes and by-hand test binaries are in
[renderer.md](renderer.md), which also holds the rules that apply to every
entry ([Regression areas that must stay covered](renderer.md#regression-areas-that-must-stay-covered)).
Playback, backend, host and startup areas are in
[runtime-regressions.md](runtime-regressions.md).

## Cameras, parallax and cursor mapping

- **LDR bloom** — `SceneSchema.ParserBuildsLdrBloomPostProcessWhenBloomEnabledWithoutHdr`:
  the horizontal blur writes an eighth-size image of its own, as Wallpaper
  Engine's does, and the combine reads it.
- **Scene settings bound to user properties** — `SceneSchema.SceneSettingsBoundToUserPropertiesFollowThem`:
  a scene loads with its bound bloom switch, parallax switch and amount at the
  properties' current values and reports those properties as load-only; bloom
  strength and tint, parallax delay and zoom follow a property change while it
  runs. `SceneSchema.SceneSettingsLeftOutTakeWallpaperEnginesDefaults`: a scene
  that leaves them out gets parallax amount 0.5, delay 0.1 and influence 0.5,
  black ambient and sky light, and Wallpaper Engine's HDR bloom defaults.
- **Camera shake** — `SceneSchema.TheSceneCameraShakesAsWallpaperEngineWhileItsPropertyIsOn`
  checks Wallpaper Engine's offset for a 2D scene, that it moves the view, that the
  scene asks for frames while it shakes, and that its user property stops it.
- **Camera zoom** — `scene_schema_tests --gtest_filter='SceneSchema.*CameraZoom*'`.
  Scene `general.zoom` may hold an authored scalar animation, not only a fixed
  camera scale.
- **Camera layers in 2D scenes** — in `scene_schema_tests`:
  `SceneSchema.CameraObjectKeepsAnOrthographicSceneOnItsCanvas` next to
  `.DefaultCameraObjectBecomesActivePerspective`,
  `.CameraObjectTimelineGlidesFromItsFirstShotToWhereItRests`,
  `.TheLastVisibleCameraObjectFramesTheCanvas`,
  `.AScriptedShotOriginFramesTheViewOnceATickHasAppliedIt` and
  `.PerspectiveShotsInheritSceneFovUnlessExplicitlyOverridden`.
  - `orthogonalprojection` decides what a scene is. When present, the canvas
    projects the scene (`ParseCamera` makes `cameras["global"]` the active
    orthographic camera) and every 2D layer's size, `origin` and `alignment` is
    authored in canvas space; a `camera` layer there is parsed, bound and
    scriptable like any node but never touches `scene.activeCamera`. When it is
    null, a camera projects the scene and a `camera` layer is the shot it plays.
  - The shot still frames the canvas it does not own: at the end of each tick,
    after every script and visibility/origin writer, `ApplyCameraShots` passes
    the last visible shot (authored order) to `Scene::FrameCanvas`. Its `zoom`
    narrows the orthographic view about the view centre, and its origin `x`/`y` is
    that centre's offset from the canvas centre, not a canvas coordinate. The
    perspective camera keeps its distance but takes the same centre and a field of
    view spanning the same visible height. With no visible shot the whole canvas
    shows, and nothing is reframed while zoom and offset stay the same.
  - A script-bound origin is pending until the first tick has applied it (the
    view stays on the canvas centre until then); the editor's static `value`
    beside such a script is never drawn. A relative origin curve offsets the
    authored origin; zoom and origin keyed together share the zoom's clock. A
    single-play timeline that has ended stops counting as animation demand, so
    an otherwise still scene can go idle after its intro.
  - Perspective shots with an omitted or nonpositive `fov` inherit the scene's
    resolved FOV (`perspectiveoverridefov`, then `fov`, then 50); a positive shot
    FOV overrides. Resolve it from authored scene settings, never from a shared
    camera an earlier visible shot may have changed.
  - Framing moves no node and rebuilds no graph, so a fullscreen layer's last
    pass uses the `fullscreen` camera (always the canvas), a layer sampled as
    `_rt_imageLayerComposite_<id>` is drawn through a layer-local camera
    (`LayerCompositeCameraKey`) that ignores placement, view and parallax, compose
    cameras are not layer-local (children draw through them at their place inside
    the layer), and the static-result cache folds each pass's camera and the
    active camera into its sample (`vulkan::FoldPassCameras`, shared by both
    backends).
- **Camera-object zoom in 2D scenes** — `SceneSchema.CameraObjectZoomTightensTheOrthographicFrustum`
  and `.CameraObjectZoomThatIsNotPositiveFramesTheWholeCanvas` in
  `scene_schema_tests`, `MouseInput.HitTestingFollowsACameraObjectZoomAcrossAResize`
  in `mouse_input_test`. `zoom` is applied when the ortho projection is built,
  not by writing camera width and height, because `ApplyCameraFillMode` rewrites
  those from the authored canvas whenever a fill mode is applied. Pointer mapping
  must read `SceneCamera::VisibleWidth/VisibleHeight` (the extent the projection
  uses), not `Width()`/`Height()`, or clicks and mouse-linked particles stay on
  the unzoomed image. The authored extent the render targets are sized from must
  not move with zoom.
- **Perspective camera shots and paths** — in `scene_schema_tests`:
  `SceneSchema.PerspectiveCameraSelectionFollowsVisibilityWithoutHiddenOverrides`,
  `.PerspectiveCameraPathsSampleAndQueueAuthoredCurves`,
  `.RandomCameraPathsStayWithinAuthoredShotsAndBoundCatchup`,
  `.CameraPathsPreserveSteepAndRolledLookAtOrientation` (near-vertical and Euler
  singularities), `.CameraPathsAndLayerTimelinesShareScaledAndZeroDeltas` and
  `.PerspectiveFallbackCapturesTheCameraAtFirstRegistrationOnly`. The last
  effectively visible shot for a camera owns its pose and FOV; hidden presets
  cannot reattach that shared camera; with no visible shot the editor pose
  returns. Packaged eye/center/up/FOV curves share the path clock, with
  sequential or random queuing and bounded catch-up; only selected paths advance,
  hidden paths add no animation demand, and curves are parsed once. Camera-path
  zoom, path events and camera-cut fades are not implemented.
- **Camera parallax** — `ShaderValueUpdaterCompat.CameraParallaxMovesEachLayerTreeByItsRootsDistanceFromTheCursor`,
  `.ZeroParallaxDelayFollowsTheCursorAtOnce` and
  `.ParallaxLayersAreReportedAsFollowingTheCursor` in `script_runtime_compat_test`;
  `SceneSchema.ParserCopiesImageParallaxDepthToPuppetMaterialSlots` in
  `scene_schema_tests`.
  - In a 2D scene, as in Wallpaper Engine, parallax moves each layer tree by its
    outermost layer's distance from the eased cursor point, times that layer's
    `parallaxDepth` and `cameraparallaxamount`. The point rests at the view centre
    and moves with the cursor by `cameraparallaxmouseinfluence`, so with the cursor
    centred a layer off the centre already sits further out, by
    `(origin - centre) x amount x depth`. Every layer of a tree, and every effect
    pass of a layer, takes the outermost layer's current origin; a layer that
    leaves `parallaxDepth` out has depth (1, 1). A layer under a depth-0 group does
    not move. 3D scenes use each layer's own distance from the camera.
  - A pass parallax moves is reported as following the cursor (`kParallax`),
    judged for the camera the pass draws through: static reuse redraws its
    target, and an on-demand scene wakes for the pointer. A layer drawn into a
    composite through its layer-local camera is not moved, so that composite stays
    reusable (`LayerTextureReference.AReferencedLayerIsItsCardWhereverTheSceneShowsIt`
    in `layer_texture_reference_test`). What this costs is under
    [Known limitations](renderer.md#known-limitations).
  - `cameraparallaxdelay` of zero means no easing. Dividing by it makes the eased
    cursor NaN, which reaches every parallax layer's model matrix and leaves only
    the clear color on both backends.
  - `ShaderValueUpdaterCompat.ParallaxEasesAsWallpaperEngineWhileShadersSeeTheCursor`:
    parallax closes `(1 - delay / 3) * 10 * frametime` of the way to the cursor
    (clamped to the window) each frame, while `g_PointerPosition` is the cursor
    itself, not the eased one.
- **Parallax inheritance** — in `scene_schema_tests`:
  `SceneSchema.ParallaxInheritanceResolvesRootsWithoutDependingOnDeclarationOrder`
  (nesting, zero/default depth, missing/duplicate parents, cycles),
  `.ParallaxInheritanceRejectsOutOfRangeIdsWithoutAliasingValidLayers`,
  `.ParallaxInheritanceAcceptsSignedBoundariesAndUnsignedInRangeIds` and
  `.ParentedPuppetSlotsFollowTheRootDepthAndKeepTheirLocalTransforms`; and
  `MetalSceneDraw.ParentedCardsStayJoinedWhileParallaxMovesAndReverses` in
  `metal_scene_draw_smoke`. Parented layers take the outermost parent's
  `parallaxDepth`, including a zero one or an omitted one, which is (1, 1) (Wallpaper Engine's
  [release notes](https://steamcommunity.com/app/431960/allnews/) confirm that
  the parent controls parallax on child layers). `ResolveLayerParallax`
  resolves it once at parse time, independent of declaration order and before
  materials are built, with no per-frame ancestor walk. Missing or ambiguous
  parents supply no depth, cycles stay unresolved, and IDs and parent references
  must be integers in the signed 32-bit range (wider JSON numbers are ignored,
  never truncated into another layer's identity).
- **Fullscreen layers** — `CameraFraming.AFullscreenLayerCoversTheScreenWhateverTheShot`,
  `.AFullscreenEffectCoversAPerspectiveScene` (independent of the perspective
  FOV) and `.MovingTheCameraChangesTheStaticSampleOfAPassItDraws` in
  `layer_texture_reference_test`. Fullscreen effects use the screen-space
  `fullscreen` camera in 2D and 3D scenes.
- **One cursor mapping, owned by the presentation** —
  `SceneRuntimeContext::SetCursorInput` maps window-normalized input through the
  cursor viewport the renderer publishes (`origin + (x, 1 - y) * size`) and writes
  it to `Scene::pointerScenePosition`, so consumers outside the script runtime
  read the same point instead of deriving their own. A particle control point that
  maps the pointer over the canvas (`pointerPosition * ortho`) agrees with the
  cursor only at the window centre once a wallpaper is cropped (`fill`) or
  letterboxed (`fit`). `ParticleMouseControlpoint.MouseControlpointFollowsTheCroppedPresentation`
  in `particle_mouse_controlpoint_test` (run by `check_renderer.py`) guards it.
  `offscreen_scene_probe` with `WE_TEST_CLICK_VIEWPORT=4112x2658@2.0:fill` prints
  the mapping a running wallpaper would use. Nothing exercises `SceneWallpaper`'s
  own message loop offscreen, so the host's half (polling the pointer and
  publishing the viewport) is covered only by `mouse_input_test` at the unit
  level.
- **Cursor hit testing under scaling** — `MouseInput.CursorViewportMapsWindowOntoTheCroppedSceneRectangle`,
  `.LayerHitTestingFollowsWhereTheWallpaperIsPresented` and
  `.LetterboxBarsDoNotTriggerLayersThatCrossTheCanvasEdge` in `mouse_input_test`;
  `ScriptRuntimeCompat.HoverScaleFollowsNormalizedDisplayInputOnACroppedWallpaper`
  in `script_runtime_compat_test`. Scene coordinates reach the window through two
  transforms: the global camera rectangle fills the default render target, and
  `ComputeWallpaperScalingLayout` places that target in the window (`FILL`
  deliberately pushes it outside to crop). Cursor input arrives as a window
  fraction and is mapped back through both (`ComputeWallpaperCursorMapping` →
  `SceneRuntimeContext::SetCursorViewport`); mapping onto the raw canvas matches
  only when scene and display share an aspect ratio and otherwise squeezes every
  `cursorEnter`/`cursorLeave` box toward the screen centre. The mapping also
  reports the drawn content rectangle: coordinates extrapolate past it (scripts
  read positions outside the canvas), but named layers take cursor events only
  while the cursor is inside it, so letterbox bars never trigger a layer whose box
  crosses the canvas edge.
  The picture can also be positioned inside its slack (`WallpaperFraming`, the
  trailing `pan_x`/`pan_y` of `ComputeWallpaperScalingLayout`); the mapping derives
  from `layout.viewport_px` alone, so the pointer follows the position with no mapping
  of its own. `WallpaperScaling.CursorMappingFollowsThePannedPresentation` in
  `wallpaper_scaling_test` (CPU only, run by `check_renderer.py`) requires the window's
  left edge to map to the camera's left edge at a pan of 0 and the right edges to meet
  at 1, with the drawn content rectangle and the clip unchanged.
  `.DefaultPanIsBitExactWithTheCentredLayout` compares every mode against an in-test
  copy of the old centring arithmetic, so the default can never move a wallpaper by a
  pixel; a change to the layout function's arithmetic order has to keep it green.
- **`engine.screenResolution`** has its own setter:
  `SceneWallpaper::publishScreenResolution` reports the display's pixels on scene
  attach and whenever the surface is replaced. `RenderInitInfo::width`/`height`
  already are those pixels (both backends divide by `display_scale_factor` for
  logical points), so scaling them again doubles the resolution on Retina panels.
  It is neither the world region the cursor mapping publishes nor the
  rasterization size: a quality setting must not move a script's layout.
- **Cursor coverage masks** — `ScriptRuntimeCompat.CursorHitTestRespectsCoverageMask`
  in `script_runtime_compat_test`. Hit tests run in the layer's local plane
  (rotated and flipped buttons keep their rectangle) and, for image layers whose
  scripts handle cursor events, consult a coverage mask sampled from the albedo
  at parse time (RGBA8/BC2/BC3, at most 256 texels per side, alpha ≥ 16 counts as
  covered): transparent texels do not hit, so overlapping triangle buttons do not
  fire together. Puppets, videos, sprite sheets and opaque formats keep the
  rectangle test. `offscreen_scene_probe` with `WE_TEST_CLICK_OFFSET` exercises
  real assets.

## Scene scripts and property bindings

All in `script_runtime_compat_test` and `scene_schema_tests` unless noted.

- **Callback-only property scripts** — `*CallbackOnly*` in both binaries.
  Callback-only scripts keep their no-writeback behavior.
- **Script property load order** — `ScriptRuntimeCompat.ModuleCodeSeesDeclaredDefaultsAndInitSeesTheBoundValue`.
  As in Wallpaper Engine, a layer's saved and user-bound `scriptproperties` reach
  the script after its module has run: top-level code reads the defaults the
  script declares, `init` and `update` read the values. A switch that moves its
  layers by the difference from a top-level reading stays where it was authored
  if the module already sees the user's position.
- **Module syntax** — `ScriptRuntimeCompat.ExportFollowedByUnicodeWhitespaceStillCompiles`,
  `.AnUpdateSeparatedByUnicodeWhitespaceStillDrivesItsProperty` and
  `ScriptModuleSyntax.*`. `Scripting/ScriptModuleSyntax` is the one matcher for
  `export` and `export function update`, shared by the module rewrite and both
  update detections (`HasUpdateScript` in the parser, `wrap_script_if_needed` in
  the resolver). ECMAScript whitespace between the tokens counts, including the
  U+00A0 that text pasted from a rich-text editor carries and U+FEFF (not Unicode
  White_Space), and only where a statement can start, so `reexport` and
  `module.export` are not the keyword. Only the pure `ScriptModuleSyntax` test
  uses the rarer separators; the two that compile JavaScript through the linked
  QuickJS use U+00A0. The rewrite erases only the keyword, so a comment ending in
  the word keeps its line break.
- **Property-script feedback and hover easing** — `ScriptRuntimeCompat.HoverScaleInterpolatesAcrossFramesAndReversesWithoutSnapping`
  and `.PropertyFeedbackResumesFromExplicitUserValueChanges`. `update(value)`
  receives the current value, including the previous frame's result and explicit
  property writes, not the authored value on every tick; that preserves iterative
  hover easing, full authored enlargement and continuous reversal on cursor leave
  and re-entry. JavaScript input conversion serializes only the value payload,
  without copying the live property's listener/subscription ownership.
- **Native writes survive `update()`** — `ScriptRuntimeCompat.UpdateSideEffectWritesSurviveWhenUpdateReturnsUndefined`.
  "Keep the current value when `update()` returns `undefined`" only works if the
  current value includes what the script wrote, so evaluation continues from the
  live dynamic value, not a private copy of the authored base. Native writes
  (`thisLayer.visible = …`, `origin`, `scale`, `angles`) arrive through the typed
  `DynamicValue::update` overloads and must reach the next `update(value)`. The
  canonical case hides its layer in `init()` and sets
  `thisLayer.visible = alpha != 0` in `update()` without returning a value.
- **Script-driven layer visibility** — `SceneSchema.HiddenByDefaultVisibilityScriptDrivesVisibilityAndOrigin`.
  A layer setting may carry `value`, `user` and `script` at once. `value` is the
  script's initial value, never a permission to run it: a layer authored hidden at
  rest (day/night or weather switchers) still runs its script, and dropping the
  binding leaves a scene drawing only `general.clearcolor`.
  `PropertyScriptProgram::Evaluate` keeps the current value when a script throws,
  returns `undefined`, or returns an object for a boolean, so a hidden helper
  layer cannot be revealed by accident.
- **User-bound image colour** — `SceneSchema.UserBoundImageColourTintsEveryLayerMaterialAndFollowsTheProperty`
  and `.InstanceColourSurvivesUnlessARuntimeImageTakesTheSlot`. An image layer's
  `color` of `{"user": …, "value": …}` is the property's value; `value` is only
  its default, so a Workshop preset or a saved colour must replace it (issue #43:
  a preset's black drew in the base's red). `ParseImageObj` resolves it once
  before building `g_Color`/`g_Color4`, then `BindMaterialColor` feeds the layer's
  own material, every effect pass and a compose layer's passthrough from one
  value, keeping each `g_Color4` alpha. It is a listener, so it costs nothing per
  frame and runs only when the property changes. A scripted `color` is
  deliberately not bound: `DynamicValue` notifies on every update, so a binding
  would overwrite what a script that writes `thisLayer.color` and returns nothing
  just set. A layer whose placeholder a runtime image replaces drops a bound
  colour as it drops an authored one.
- **User properties and interactive scenes** — `applyUserProperties` runs once
  initially, then only for changed properties, after the whole property set has
  been refreshed. Exercise clock clicks and hidden-helper enter/leave through
  projected input (`WE_TEST_INPUT_JSON`, `WE_TEST_CLICK_*`), not by forcing
  overlay alpha. A closed author menu and an audio-driven wave with no audio are
  not evidence that a rendered frame has exercised either feature.
- **User-switched effects** — `RenderGraph.parsedEffectVisibilityFollowsTheBoundUserProperty`
  (`rendergraph_smoke`, image layers) and
  `TextObjectRuntime.TextEffectVisibilityFollowsTheBoundUserProperty`. An
  effect's `visible` bound to a user property (`{"user": "toggle", "value":
  false}`, or a combo `condition`) holds the editor's value only as a default: the parser builds the effect when the
  property's current value says so, by the layer-visibility rule
  (`ResolveBoolSetting`), and keeps the authored value for a property the project
  does not declare. It is decided at parse time with no per-frame cost: a live
  property preview holds the property at the loaded value (see *Load-only
  properties* below) and Apply changes reloads. A scripted effect `visible`
  keeps its authored value. Reading only the default left colour modes and
  effect toggles in customizable wallpapers doing nothing.
- **Alignment anchors under dynamic transforms** — `SceneSchema.ImageAlignmentAnchorSurvivesScriptedOriginAndScale`,
  `ScriptRuntimeCompat.RotatedAnchoredLayerTurnsAboutItsAnchor` and
  `.ScriptedRingBarsHangOutwardFromTheirCircle`, plus `nodes.txt` translate diffs
  from `offscreen_scene_probe`.
  - Alignment is an anchor, not a one-off offset. `SceneRuntimeContext` owns it
    for image and text layers and re-derives `origin + size * scale * 0.5` for the
    named edges whenever origin, scale, size or rotation changes; baking the
    offset into the node translate loses it as soon as a scripted or user-bound
    origin writes the translate, and ignores scale. Centre-aligned image layers
    carry no offset. An alignment a script sets on a layer that had none
    (`bar.alignment = 'top'`) offsets by the scale delta,
    `size * (scale - 1) * 0.5`, so the unscaled layer stays where it was authored
    and grows away from that edge; this is the renderer's own convention, since
    Wallpaper Engine's SceneScript reference omits `alignment`.
  - The offset is turned by the node's rotation (x, y, z order of
    `SceneNode::GetLocalTrans`), so a turned layer keeps its named edge on the
    origin. Every rotation write re-derives the anchor: `SetNodeRotation`
    (`layer.angles`), `RegisterNodeRotation` and the bound-angles pass of `Tick`.
    Unrotated layers keep the same arithmetic bit for bit.
  - Re-registering a node (`RegisterNodeVisibility`, `RegisterNodeTranslate`,
    `RegisterNodeScale` and `RegisterNodeRotation` all call `RegisterNode` again)
    must not re-seed an existing anchor from `node->Translate()`, which already
    contains the offset; `SetNodeAlignment` keeps the existing anchor mode. The
    double offset shows only on layers whose scale or origin is dynamic, which is
    why a static-origin/scripted-scale case is in the test.
- **Host queries on `engine`** — `ScriptRuntimeCompat.UpstreamConsoleInputAndEngineCompatibilityStubsAreCallable`.
  The `IEngine` queries Wallpaper Engine documents are functions a script can
  call: `isRunningInEditor()` and `isScreensaver()` return `false`,
  `isDesktopDevice()` `true`, `isMobileDevice()` `false`, and `isWallpaper()`
  returns `!engine.isScreensaver()` (the test swaps `isScreensaver` to check that
  it follows). A missing one throws "not a function" and aborts the script's
  `init` or `update`. All but `isRunningInEditor` (a native function) are defined
  in `AppendCommonHostBootstrap`, which runs once per shared script context,
  never per frame.
- **Layer parents and scripted alpha** — `ScriptRuntimeCompat.LayerGetParent*`
  and `.LayerAlpha*`. `getParent()` is how an icon script reads its group;
  without it the whole `update` throws every frame. `layer.alpha` must reach
  `g_UserAlpha`, and only for layers whose authored alpha is not already owned by
  a timeline, an update script or a user property (two writers per frame fight).
- **Property and name bindings** — `ScriptRuntimeCompat.AuthoredColorPropertiesStayVectorsAcrossTicksAndPropertyChanges`:
  `createScriptProperties().addColor(...)` exposes a `Vec3` even when the saved
  `scriptproperties` stores RGB as a space-separated string, and again after
  native property updates replace the value; `addText` values stay strings.
  `SceneSchema.DuplicateNamesResolveInAuthoredOrderWithoutSharingThisLayerBindings`
  and `.DuplicateLayerAliasesIgnoreMalformedEntriesAndKeepValidLookup`: duplicate
  non-text layer names keep separate internal binding keys; SceneScript name
  lookup selects the first declaration in authored order (including lookups made
  while a script module initializes) while each layer's `thisLayer` addresses its
  own key; the alias pass skips non-object entries, non-string names and
  nonnumeric IDs. A text label that repeats another layer's name keeps its own
  runtime key (`__we_text_<id>`, asserted in `text_object_runtime_test`), so
  `getLayer("s")` addresses the layer that owns the name.
- **Video-controlled visibility and music scripts** — `scenescript_media_event_smoke`:
  `getVideoTexture().isPlaying()` reflects shared runtime pause/play state, so
  scripts that hide a layer during init can reveal it during update; `Vec*.mix`
  and `MediaPlaybackEvent` constants are available.
- **Who hears a button's release** — `SceneSchema.APressedTransportButtonComesBackWhenItIsReleased`
  and `.AButtonThatShrinksWhileHeldStillGetsItsRelease`;
  `SceneScriptSoundLayerSmoke.LayerScriptReceivesCursorUpForItsPressAfterLeavingWindow`
  and `.LayerScriptDoesNotReceiveCursorUpForAnotherPressAfterLeavingWindow` in
  `scenescript_sound_layer_smoke`. A release goes to whatever took the press,
  wherever the cursor has gone, the window included; re-testing the layer on the
  way up leaves a button that shrinks while held, or a press dragged off the
  desktop, latched for good. A layer that did not take the press hears a release
  only under the cursor, and a scene-wide script hears one from anywhere.
- **Creating layers from scripts** — SceneScript creation tests cover independent
  cloned layers, owner-local cached factories, bounded authored pools and lazy
  template loading. A script imported from the Workshop declares
  `export let __workshopId = '<id>'` and names its assets as in its own project
  (`models/bar.json`) while the editor stored them under `models/workshop/<id>/`;
  `thisScene.createLayer` passes the id on, and the runtime tries the workshop
  folder only after the path as written, the owner's own workshop folder and the
  lazy loader have found nothing. `ScriptRuntimeCompat.CreateLayerFindsTheAssetsOfTheWorkshopItemItsScriptDeclares`,
  `.CreateLayerPrefersThePathAsWrittenOverTheDeclaredWorkshopItem` and
  `.CreateLayerLooksInAWorkshopFolderOnlyForANumericDeclaredItem` cover the
  lookup. Template source layers are usually hidden and never parsed, so the lazy
  loader builds the template from the bare model: visible (copies start as copies
  of it) and as large as the model's picture when the model states no size
  (`SceneSchema.ALayerCreatedFromAWorkshopModelIsSizedByItsPictureAndShows`); a
  zero-sized hidden template makes every lazily created layer invisible. A
  scene layer using the model registers as its template, but one with an effect
  chain (its own camera) or child layers cannot be copied, which is common for
  the script's own layer: the lazy loader then builds the model's own layer once
  and it replaces that registration
  (`ScriptRuntimeCompat.CreateLayerBuildsTheModelsOwnLayerWhenTheLayerUsingItCannotBeCopied`;
  a model that loads into such a shape fails once and is not reloaded,
  `.CreateLayerDoesNotReloadAModelThatLoadsIntoALayerItCannotCopy`).
  Refusing it threw `Unable to create layer` from `init` and logged
  `createLayer unsupported template shape`.
  `thisScene.destroyLayer` (a layer or its name) removes a layer a script
  created: it leaves the scene graph and the runtime's registries at once, so the
  layer object the script still holds reaches nothing and a second call answers
  false, while the node is freed only once the graph has been rebuilt without it
  (`ScriptRuntimeCompat.DestroyLayerRemovesALayerTheScriptCreated`,
  `.ADestroyedLayerIsFreedOnlyOnceTheGraphNoLongerDrawsIt`). A layer from the
  scene file, or one named by index, stays and the call answers false. Without
  it, a script that rebuilds its layers when a setting changes threw
  `not a function` before building the new set.
- **Timeline events** — `ScriptRuntimeCompat.*Timeline*Event*`, `*Marker*`,
  `GlobalAnimationListenersRunOncePerMarkerWhateverIsBound`,
  `GlobalOnlyAnimationListenerSeesTheCurrentTickTime` and
  `SceneGetAnimationFindsATimelineOnAnotherLayer`: crossing, `event.frame`,
  reverse travel and exact loop wraps, delivery after `init`, one global listener
  run per marker with zero and two bound scene scripts, a fresh host context for a
  global-only listener, and scene-wide `getAnimation`.
  - `ScalarAnimationPlayback::Advance` queues every `options.events` marker the
    playhead crosses as a whole `ScalarAnimationEvent` (`frame` beside `name`);
    departure is exclusive and arrival inclusive, in both directions. A loop runs
    on a circle, so a wrap, an exact landing on the seam and a marker authored at
    the period are the same point, reverse travel is symmetric, travelling a whole
    period or more reports each marker once, and markers arrive in the order the
    playhead met them. `SetFrame` is a jump and reports nothing.
  - `SceneRuntimeContext::Tick` drains the queue after advancing the clocks *and*
    re-evaluating scripted values (a property script initializes lazily, so a
    marker crossed by the first tick must still reach an initialized handler) and
    calls `animationEvent` on the property and scene scripts bound to the
    timeline's layer. The global `engine.on`/`scene.on` list runs once per marker,
    not once per matching program, and refreshes `engine.runtime`/`engine.frametime`
    itself. Every crossed marker is collected before any handler runs, because
    handlers create, hide or destroy layers.
  - `thisScene.getAnimation(name)` exists beside the layer's `getAnimation`: a null
    layer argument to `__animationControl` matches the name across every
    registered timeline (`SceneRuntimeContext::FindAnimationByName`).
- **Puppet animation layer control** — `ScriptRuntimeCompat.PuppetAnimationLayer*`:
  `getAnimationLayer(name).play()` restarts a finished single-shot layer on every
  copy of the shared state; a `visible` bound to a user property toggles the
  layer. Puppet animation layers are one shared playback state per image object
  (`WPPuppetLayer` copies share it), registered under the layer name and backed by
  `SceneRuntimeContext::PuppetAnimationControl`. Authored layers start playing; a
  single-shot layer holds its last frame and reports stopped.
  `animationlayers[].visible/rate/blend` bound to user properties follow the
  property like any other setting.
- **Vector material constant timelines** — `SceneSchema.*VectorTimeline*` and
  `SceneSchema.SharedVectorTimelineWrapsOnlyOnTheParentClock`,
  `ScriptRuntimeCompat.VectorMaterialTimelineDrivesEveryComponentSeparately` and
  `.ClonedTemplateLayersShareOneTimelineAndKeepEveryBinding`, and the
  `generated-perspective-animation` case in `check_renderer.py`. Each component of
  a material constant resolves its own curve (`c0`–`c3`) and its own entry of the
  initial value; unanimated components keep that value. The constants of one
  material pass are collected first, `options.parent.key` is walked to its root
  with memoized results, and the whole group shares the root's single
  `ScalarAnimationPlayback`, so `thisLayer.getAnimation(name)` drives it and
  looping and restarting happen once, on the root. Sampled component copies are
  single-shot, so a short child curve holds its last key instead of wrapping on
  its own length. A missing parent, a parent without a usable animation, or a
  cycle logs once and freezes that group on frame 0; relations never cross
  material passes. Without the curves a perspective quad's homogeneous `w` terms
  go negative and the quad inverts into a spike; the generated case asserts the
  page covers the centre and the margin stays clear (a blank or all-white frame
  fails too).
- **Scripted vector material constants** — `SceneSchema.ScriptedMaterialConstantsKeepTheComponentsTheShaderDeclares`:
  a script that swaps a `vec2`'s components only produces the authored numbers
  when it is handed a vector, not the text `[x,y]`. Constants resolve at the
  authored component count: one component as a float, two and four through
  `ResolveVectorSetting`, three through `ResolveVec3Setting`; a constant with no
  authored value has no count to preserve and still resolves as a string.
- **Compiled exports and caches** — compiled script exports suppress only absent
  handlers; initialization, scheduled callbacks, shared scene callbacks,
  live-value fallback and live alpha/geometry hit order stay covered by
  `script_runtime_compat_test` and `mouse_input_test`. Transform/material caches
  avoid recomputing sources but still repair changed destinations in the
  original phases; a failed registration releases only its new
  subscriptions/values and restores existing mask/puppet identity.
- **Authored defaults versus loaded values** — `project_property_preview_test`
  (CPU only, in the `check_renderer.py` gate). A scene loads with the project's
  defaults under the user's saved choices, and `SceneParseRequest::authored_project_properties`
  (set by `MainHandler::loadScene`; null means the loaded table is also the
  authored one) keeps the defaults apart, as `SceneRuntimeBootstrap` does for the
  runtime. `ApplyProjectPropertyOverride(document)` takes a whole document: the
  declared defaults with exactly these values over them, so a property the
  document leaves out is at its default again whatever the scene loaded with, and
  `ResetProjectPropertyOverride()` is the empty document. Both return the sorted
  names whose value in effect changed (a change of kind counts). The test pins
  the table arithmetic and, through the real `WPSceneParser`, every way a
  property reaches a scene: a flag and a choice with a user condition (layer
  visibility), a slider (`g_UserAlpha`) and a colour (`g_Color4`) on an image
  layer, a bound text, and a bound material constant. For each, loading with a
  saved choice, applying a document and returning leaves visibility, every
  material constant and the text bit for bit equal to a fresh parse of the
  authored table, and applying a document equals loading with it. The fixture
  makes the authored and the saved value differ on every layer, so a return that
  stops at the loaded values fails. A document adds no time-advancing work
  (`DescribeTimeAdvancingWork` stays 0 for a still scene), so the on-demand idle
  analysis is unchanged. A name the scene loaded with but the project does not
  declare keeps its last value until the next load; callers send only declared ids.
- **Load-only properties** — `project_property_preview_test`
  (`LoadOnlyProperties.*`, CPU only). Almost every property is a live binding, so
  a document reaches the scene on its next tick. Two readers decide once, while
  the scene loads, and a built effect or a filled material slot is not redone:
  a `usertextures` slot that names a `scenetexture` property
  (`UserTexturePropertyName`, noted by `LoadMaterial`) and an effect whose
  `visible` is bound to a property, plain or with a combo `condition`
  (`UserPropertyName`, noted by `ResolveUserEffectVisibility`, image and text
  objects). Building every hidden effect would cost passes and memory, so these
  stay load-only. The parser calls `NoteLoadOnlyProperty(name)`, which records
  the value the name was read with (absent when the table did not name it);
  `LoadOnlyProperties()` lists the names. `PreviewProjectPropertyOverride(document)`
  is `ApplyProjectPropertyOverride` with every noted name forced back to that
  value for every consumer of it, live ones included (`glow` here also shows a
  layer, and the layer stays put), and lists the names the document asked
  something else for as `deferred`: a document that leaves out a name the scene
  loaded with a saved choice defers it too, and asking for the loaded value again
  defers nothing. A scripted effect `visible`, an effect with a plain value, a
  property nothing reads and a live slider note nothing. One test builds the
  scene again with the new values to show the effect set and the slot texture
  differ, which is why a running scene cannot take them.
- **Sound layer volume follows its slider** — `project_property_preview_test`
  (`SoundLayerVolume.*`, CPU only, a fake sound stream and a null-backend sound
  manager, so no audio device is opened). `WPSoundParser::Parse` read a
  slider-bound volume once, so a sound layer could not follow a property change.
  `WPSoundParser::BindVolumeProperty` resolves the bound property like any other
  slider setting (the authored volume while the project declares no such
  property) and sets `WPSoundStream::SetVolume`, an atomic store the audio thread
  already reads, so a sound layer is not load-only and costs nothing per frame.
  The volume follows a property, clamps above full, and returns to the project's
  own volume on the empty document, on a reset and after a saved choice, never to
  the saved choice or to the volume the layer carries in the scene. An undeclared,
  unnamed or non-numeric property leaves it alone. A document refreshes every
  property, so only a change of the bound property moves the volume: an unrelated
  edit does not undo a volume a script set with `SetSoundLayerVolume`. A released
  stream is not touched, and the real `Parse` binds a user-bound volume and leaves
  a plain number alone. Audible output on real hardware is not checked.
- **A property document on a running scene** — `project_property_preview_test`
  (`ScenePropertyPreview.*`, CPU only, no surface or window),
  `HiddenLayers.APropertyPreviewRevealsALayerWithOneGraphRebuildAndAGraphBuiltLaterLeavesTheHiddenOneOutAgain`
  in `layer_texture_reference_test` (CPU) and
  `MetalSceneDraw.APropertyPreviewChangesThePixelsAndAnEmptyDocumentRestoresThemByteForByte`
  in `metal_scene_draw_smoke` (private textures, skips without a Metal device).
  The wallpaper property `project_property_preview_json` carries a flat JSON
  object; `MainHandler` parses it, never touches the saved override JSON and stages
  it in `RenderHandler`'s latest-wins slot, and `CMD_APPLY_PROJECT_PROPERTIES`
  (posted only when the slot was empty, and dispatched in `onMessageReceived`, where
  a missing case silently drops a command) shows it on the render thread with
  `PreviewProjectPropertyOverride`. The tests send documents through
  `SceneWallpaper::setPropertyString` to scenes that have a runtime and nothing to
  draw: a document reaches the runtime, a load-only property stays put and a name
  left out is the project's own value; a burst of 500 documents queued while the
  render thread is held inside the first (a listener that waits) runs the runtime
  twice and handles two commands, the first and the last (the test-only
  `PropertyPreviewCommandsHandled` counts them, so a command per document fails); a
  document that is not a JSON object, or one that arrives before any scene exists,
  changes nothing and is not kept for the scene that arrives next; a second scene
  with the same property names shows its own loaded values and the first is not
  touched again; a preview adds no time-advancing work. On the graph, a preview that
  reveals a layer the graph left out makes one tick raise the mutation flag once, a
  held property reveals nothing, hiding the layer again and showing it again on the
  same graph raise nothing, a graph built while it is hidden leaves it out again and
  showing it then raises the flag once more. On Metal, a slider-bound alpha changes
  the picture with no new graph, a switch that shows a layer rebuilds the graph
  exactly once and draws the picture a fresh load with the same values draws, and
  the empty document brings the first frame back byte for byte, twice over, without
  another graph. On a live surface (`unchanged_present_test`, the Compatibility
  backend on a layer no window owns, timing-shaped and named in `REALTIME_TESTS`),
  `UnchangedPresent.APropertyPreviewShowsOnAStillSceneAndWakesAnIdleOneForOneFrame`
  sends a slider through the property: a still scene whose passes are all reused
  submits exactly one frame, presents a different picture and goes back to
  repeating, and with the on-demand clock the stopped scene draws exactly one frame
  and goes back to sleep. A paused scene showing the change on resume comes from the
  same per-command frame request and is not exercised; a preview on a real display,
  and the hitch of a revealed layer compiling new pipelines, are not checked.
- **Scene commits in headless tests** — `scene_schema_tests` helpers wait for
  posted work with a render-looper round trip (`beginSurfaceReconfigure`) and a
  main-looper one (installing a pointer callback replays from the main looper)
  before `shutdown()`, which stops the loopers without draining them. A test that
  posts a scene and shuts down at once measures a race. A graph that never
  reached a backend is simply dropped by the next scene.

## Layers, textures and compositing

- **Effect buffers and swaps** — `SceneSchema.EffectBuffersTakeWallpaperEnginesSizesFormatsAndSwaps`
  pins `fit`/`width`/`height` sizing, the float and 8-bit formats and how a `swap`
  lowers to one copy or a three-copy exchange;
  `MetalSceneDraw.AnEffectsSwappedBuffersAccumulateAndItsFloatBuffersKeepTheirSignOnBothRenderers`
  draws an accumulating, signed effect through both renderers. Wallpaper Engine's
  fluid simulation (`effects/fluidsimulation`) needs both: without the swap its
  history buffers were never written, and the two renderers then disagreed on a
  local scene that runs it (mean difference 16 before, 0 after).
- **3D model materials and skinning** — `SceneSchema.ModelMaterialDefaultsAreOpaqueDepthTestedAndExplicitStateWins`
  and `.ModelBonesReachEveryMaterialIncludingTheBindPose` in `scene_schema_tests`.
  Model materials default to normal blending, back-face culling and enabled
  depth test/write; explicit pass settings win, and image defaults are
  unchanged. Skeletal models share one `WPPuppetLayer` playback across material
  slots, attachments and runtime animation controls, including bind-pose uploads
  when no clip matches, with no extra render passes or texture allocations.
  `MdlSchema.Mdls3SkinningPreservesAuthoredHierarchyAndPivotsAcrossMeshVersions`
  in `mdl_schema_tests`: mesh format versions do not justify flattening an
  authored skeleton. Versioned model fixtures cover MDLV13–23 attribute layouts.
- **Pass depth and cull words** — `SceneSchema.PassStateValuesOutsideWallpaperEnginesListsReadAsTheirFirstEntry`:
  `depthtest` and `depthwrite` are on only for `enabled` and `cullmode` is off only for
  `nocull`; any other word (`less`, `greater`, `always`, `inverted`) reads as the list's
  first entry: no depth test, no depth write, back faces culled. A write without a
  test is not drawn (`ResolveSceneDepthState`). The native capability check no longer
  refuses a material for its depth word, so such scenes stay on Native Metal;
  `MetalCapability.AnUnsupportedDepthCompareIsRefusedWithItsOwnReason` went with the
  rule it pinned.
- **Perspective model contracts** — the parser selects the index width from the
  vertex count (32-bit indices above 65535 vertices; reading that blob as uint16
  triples rejects the mesh or draws scrambled triangles), and the vertex cap is
  4 million. `g_NormalModelMatrix` is a std140 `mat3` (48 bytes) and uniform
  writes are clamped to the reflected member size, so an oversized write cannot
  spill into `g_ViewProjectionMatrix`. Culled model passes keep Vulkan's
  counter-clockwise front face (clockwise culls skyboxes on MoltenVK even though
  `recordDraw` uses a negative viewport height). A perspective far plane is
  padded by a tenth of a percent so a skybox scaled to exactly `far` is not
  clipped off-centre. An image layer's `alpha` `update` script or user property
  is applied to `g_Alpha`, not only an animation timeline. Perspective particle
  billboards keep object scale while authored 2D canvases keep their pixel-size
  compensation; quantity remains the documented emission-rate factor, not a
  replacement for the authored maximum count.
- **Layer textures tiled across models** — `LayerTextureReference.CompositeAddressingFollowsTheSourceLayersClampUvs`
  in `layer_texture_reference_test`. `_rt_imageLayerComposite_<id>` repeats when
  the source layer says `"clampuvs": false` and clamps when it is true or absent;
  otherwise a model whose UVs run far outside 0..1 smears the composite's edge
  texels into solid bands.
- **Layer targets: point sampling and wrap** — `LayerTextureReference.LayerTargetsFollowNointerpolationClampuvsAndTheTextureHeader`
  and `.ACompositeFollowsItsLayersTextureHeaderWhateverIsParsedFirst` in
  `layer_texture_reference_test` and
  `MetalSceneDraw.AnImageLayersTargetsArePointSampledWhenItAsksOnBothRenderers`.
  The ping-pong pair an image layer's effects run through, and the composite
  another layer reads, are point-sampled when the layer sets `nointerpolation` or
  its primary texture's header does, wrapped when `clampuvs` is off, clamped and
  linear otherwise; per-effect buffers stay clamped and linear. The header is read
  from the texture file (`LayerRenderTargetFilter`), because the composite of a layer
  another layer reads is registered before the layer's own material is loaded: the
  second test makes the point-sampled texture's only user the layer in question, in
  three layer orders, with and without an effect chain (whose ping-pong pair has to
  agree with the composite), and a texture with no flag or one that cannot be read
  stays linear. The Metal test shows a 16 by 12 target 16 times larger on both
  renderers: a smooth gradient by default and flat squares with `nointerpolation`.
- **Mip level of point-sampled file textures** — `MetalSceneDraw.ATexturePointSampledByItsHeaderPicksItsMipLevelByPointOnBothRenderers`.
  The reference builds the sampler of a file texture from a flags word that is the
  texture's own (its two low bits are the `.tex` header's `noInterpolation` and
  `clampUVs`): with `noInterpolation` the min, mag and mip filters are all point. `TextureSample::mipFilter` carries that, set by the `.tex`
  parser from the flag and read by the Metal sampler and the Vulkan sampler (and the
  Vulkan sampler cache's hash); every other sample, render targets and the
  default-constructed `TextureSample {}` fallbacks among them, keeps the linear mip
  filter. The test draws a seven-level chain, white then black, at 1.68 texels to the
  pixel on both renderers: a header with the flag gives the black second level, one
  without it the blend of the two. A render target has a single level, so its filter
  has no mip to choose. No local scene shows the difference: its point-sampled
  textures have one mip level or are magnified.
- **Shape objects** — `LayerTextureReference.AShapeDrawsItsLastEffectAdditivelyOntoTheScene`
  (CPU, in the gate) and `MetalSceneDraw.AShapeIsAddedOntoTheSceneOnBothRenderers`. A
  `shape` is the group node `ParseLayerNodes` makes for it with a mesh and a material
  added by `ParseShapeObj`: the quad of `point0` to `point3` (corner `(p.x, 1 - p.y)`
  of a canvas-high square about the layer, texture coordinate `p`) or the whole
  square, the last visible effect's material with `DIRECTDRAW` forced on, drawn
  additively onto the scene. The effect shader of both tests only compiles when
  `DIRECTDRAW` is on, so the test fails if the parser stops forcing it. The Metal
  test draws half-transparent red over green on both renderers and requires
  identical pictures, red-added inside the quad and untouched outside it. The
  shipped light-shaft effect, parsed with the editor's own assets, compiles through
  the shape path in both its linear and its radial modes; drawn once offscreen on
  Native Metal it was a beam narrowing upward and fading downward, as the editor
  shows it (checked by hand, not kept as a test, as it needs the editor's assets).
- **Model flags of the layer utilities** — `LayerTextureReference.TheDepthTestedComposeModelComposesLikeTheOthers`
  and `.AProjectLayerTakesTheCanvasSizeAndKeepsItsOrigin`. A layer composes when its
  model is the composition layer or its depth-testing variant; a model with both
  `autosize` and `projectlayer` is as large as the scene's canvas, whatever size
  the scene saved. `solidlayer` is read and unused, and `autosize` alone still takes
  the saved size.
- **Layers a wallpaper's properties hide** — `HiddenLayers.ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt`
  in `layer_texture_reference_test` (CPU, in the gate) and
  `MetalSceneDraw.ALayerItsPropertiesHideHoldsNoImagesUntilAScriptShowsIt` in
  `metal_scene_draw_smoke`. A layer hidden by a visibility only a reload changes
  (authored, or bound to one of the wallpaper's properties, on the layer or an
  ancestor) has no passes in the graph: on both backends it holds no effect
  images, loads no textures and costs what a dropped layer costs. A
  script-driven visibility stays in the graph, and so does a hidden layer another
  layer samples, with its ancestors; a layer named only in its own
  `dependencies` is not one. A script writing `visible` takes the layer
  over: showing a left-out layer, or a property applied or previewed in place
  showing one, marks the graph mutated, the rebuilt graph draws it exactly as the
  property would, and a layer a script has written is never left out again, so
  blinking it rebuilds nothing. A layer only a preview showed has no such owner: a
  graph built while it is hidden leaves it out again. A left-out layer that was
  the scene output's first writer leaves its load and clear to the first layer
  drawn: with clearing off that layer still loads instead of discarding
  (`RenderGraph.aHiddenFirstWriterLeftOutKeepsTheSceneOutputsLoadAndClear` in
  `rendergraph_smoke`). Customizable wallpapers ship every theme, language and
  format as a layer; keeping their hidden effect chains cost gigabytes of
  targets and a render pass per hidden first-use clear every frame.
- **Layer as texture** — `layer_texture_reference_test` (CPU, in the gate):
  `_rt_imageLayerComposite_<id>[_a|_b]` forward refs, duplicate names, missing
  targets, cycles, history `_b`, file names vs layer names, invisible sources
  kept, producer-before-consumer graph order, and an effect-chain source linking
  from its composite rather than `_rt_default`.
  - A composite is the source layer's card in its own texture space, whatever
    its placement, the scene camera or parallax do
    (`AReferencedLayerIsItsCardWhereverTheSceneShowsIt`). A compose layer's
    camera is not layer-local: its children keep their place inside it
    (`ComposeChildrenKeepTheirPlaceInsideTheLayer`), and a `composelayer` drawn
    into its own composite still samples the screen behind it
    (`ScriptRuntimeCompat.ComposeBackgroundUsesScreenCameraAndParentTransform`
    in `script_runtime_compat_test`).
  - A compose layer that only copies the background is skipped unless another
    layer samples it; then it is drawn into its composite and nowhere else, since
    its card covers its whole target (`ABareComposeLayerAnotherSamplesIsDrawnOnlyIntoItsComposite`).
    A mask that paints that background back over later layers otherwise has
    nothing to sample, and native Metal falls back.
  - A sampled layer inside a compose layer is drawn into its own composite as
    well as into the compose layer's picture, so the compose layer's own effect
    can sample its child (`AComposeLayersEffectCanSampleItsOwnChild`; pixels on
    the native backend in `MetalSceneDraw.AComposeLayersEffectSamplesItsOwnChild`).
    Drawn only into the compose target, the child had no composite: the graph
    logged `link tex <id> not found` and native Metal fell back at prepare.
    Hidden for good (authored or by a property) it is only its composite; hidden
    by a script it keeps its draw into the picture, since nothing rebuilds the
    graph when the script shows it again. The same rule decides whether a
    sampled top-level layer keeps its on-screen draw.
  - A sampled text layer is its card in its own composite, as an image is
    (`ASampledTextLayerIsItsCardInItsOwnComposite`; pixels on the native backend
    in `MetalSceneDraw.AHiddenTextLayerAnotherSamplesIsItsCardInItsComposite`).
    With effects the card is the chain's final card, not the larger capacity
    the chain renders at, and a card aligned to one side of an overflowed box is
    framed off the layer's origin. A relayout moves the composite camera with
    the card and resizes the target to keep one texel per unit, since a consumer
    may place the image by its size (`g_Texture1Resolution`); only a size change
    in texels costs a new graph. A hidden sampled text is still laid out when
    its text changes. Before, a text layer had no composite of its own: drawn
    through the scene camera into a screen-sized fallback it sat wherever it is
    on screen, and hidden it was never drawn, so a marquee of a hidden song
    title showed nothing.
  - A layer's own effect binding the layer's `_a` composite (or the bare name)
    reads the chain's buffer A, the image `previous` names at that point (the
    layer before any effect, for the first), and does not make the layer a
    sampled one; other layers binding the name still get the final composite
    (`ALayersOwnEffectReadsItsBufferANotItsComposite`, image and text layers,
    with and without another consumer; pixels on the native backend in
    `MetalSceneDraw.ALayersOwnEffectReadsItsBufferANotItsComposite`). Read as the
    composite, the effect sampled a link the frame filled only after it: the
    compatibility renderer logged `slot 0 (_rt_link_<id>) has no image` and the
    layer drew nothing (a clock whose outline effect names its own text), and
    native Metal refused the scene as history feedback. Built-in blur, shine and
    godrays carry the same names, `_a` and `_b` alternating along the chain, in
    the slot their effect binds to `previous`; that binding wins.
  - A self `_b` in the layer's own effects is that same input, not last-frame
    history (`ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn`, the editor's
    `_a`-then-`_b` alternation and `_b` in both effects;
    `SelfBInItsOwnEffectsIsNotAReference`; pixels on the native backend in
    `MetalSceneDraw.ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn`). The
    editor names the buffer `previous` was in when the effect was set up: the
    layer is drawn into `_a` and each effect pass without a target of its own
    moves to the other buffer, so a name can be stale after effects are
    reordered. Wallpaper Engine keeps last-frame images in an effect's own
    `unique` buffers filled by a `copy` command (motion blur), not in these.
    Taken as history, the name made native Metal refuse the scene, and an
    effect naming `_b` in its first slot without a `bind` (a wave after an
    audio-bar effect) logged `slot 0 (_rt_link_<id>) has no image` on the
    compatibility renderer. A self `_b` outside the layer's effects still
    refuses the scene.
  - Older editors also list the layer in its own `dependencies`, once for each
    self name its effects bind. A dependency names no slot, so it cannot ask
    for the last frame, and a layer waits on nothing of its own; whatever it
    does sample of itself is a texture name. The self entry is skipped: it
    gives the layer no composite and keeps no hidden layer in the graph
    (`ALayersOwnEffectReadsItsBufferANotItsComposite` and
    `ALayersOwnEffectReadsItsBufferBAsTheImageItWorksOn` with and without it;
    `HiddenLayers.ALayerItsPropertiesHideStaysOutOfTheGraphUntilSomethingShowsIt`).
    Recorded, it drew the layer's last effect pass a second time every frame,
    into a composite nobody sampled.
  - A linked composite's size is never folded into the material as a zero at
    parse time (the card padding divides by it and every texture coordinate of
    the consumer's card becomes `NaN`), and nothing stale is folded in its place:
    the shader reads the target's real size whichever the backend uploads last,
    constants or live values (`AReferencedCompositeIsSampledAtItsRealSize` checks
    both orders).
  - `ExternalMaterialsKeepHiddenTransitiveProducers` covers texture references
    absent from the scene JSON.
- **User-chosen scene textures** — `MediaThumbnailTextureSmoke.TextureProperty*`,
  `.UnsetTexturePropertyKeepsTheAuthoredTexture` and
  `.AnUnreadableUserFileKeepsTheAuthoredTexture` in `media_thumbnail_texture_smoke`;
  `TexSchema.AbsolutePath*`, `.PackagedLooseImageStillLoadsFromTheMount` and
  `.OnlyAReadableHostPictureCountsAsOne` plus
  `SceneSourceMount.APresetFileBesideThePackageLoadsAndThePackageStillWins` in
  `tex_schema_tests`. A `usertextures` entry is either a cover slot the runtime
  supplies or the name of a `scenetexture` property. The property stores a path,
  not a copy, so a slot is only replaced when that file opens at load; unset,
  moved and unreadable all keep the authored texture. Origin travels on
  `LooseAssetCandidate`, never re-derived from the path: a mounted
  `/assets/materials/foo.png` is absolute too, and deciding by `is_absolute()`
  sends every packaged loose picture and video to the host filesystem, where none
  exist. A Workshop preset names its own pictures and videos relatively
  (`files/clip.mp4`) and ships them beside its base's `scene.pkg`, so
  `MountSceneSource` mounts the project folder under the package: packaged files
  still win, and the probes mount the same way. With only the package mounted
  those layers draw black and native Metal falls back.
- **JPEG/EXIF orientation** — `tex_schema_tests`: all eight EXIF display
  transforms on asymmetric RGBA pixels, both TIFF byte orders, truncated
  JPEG/EXIF data, invalid IFD offsets.
- **Render scale** — `RenderScale.*` in `render_scale_test`: physical surface
  sizing and scale/resize transitions (full scale keeps every target at the
  authored size, half scale halves the raster but not the authored canvas,
  three-quarter scale rounds rather than truncates, returning to full scale
  restores the exact size) without changing 2D canvas behavior; a perspective
  raster follows the surface without changing the canvas fallback.
- **Random sprite-sheet frames** — `ParticleMouseControlpoint.SpawnedParticlesCarryAStableFrameValueSpreadOverTheSheet`
  in `particle_mouse_controlpoint_test`. A `randomframe` particle keeps one frame
  for its life, derived from its spawn state rather than drawn from the random
  source, so seeded particle layouts do not shift (an integral value would
  always select frame 0).
- **Rope and rope-trail geometry** — `particle_rope_geometry_test` (CPU, in the
  gate): pieces per instance and never across instances, dead particles skipped
  and neighbours joined, subdivision through the particles, coincident points
  without `NaN`, the rope-trail head, tail shrink and per-slot separation, and the
  simulation's history — birth point, growth to capacity, zero time step, respawn
  reset. Index width: packed 16-bit up to 16 384 quads, 32-bit past that,
  overflow-safe capacity math, and draw order across instances on a 32-bit mesh.
- **Hidden particle geometry** — `ParticleSystem::RebuildVisibleMeshes` runs after
  `Tick` and rebuilds a hidden subsystem on the frame it becomes visible or must
  produce; the simulation still runs while it is hidden.
  `ParticleHiddenGeometry.LayerShownByTickAfterEmittDrawsWhatAlwaysGeneratingDraws`
  shows a layer (or its parent) in the Tick after Emitt and compares the first
  visible frame's mesh bytes with an always-visible run; `particle_rope_geometry_test`
  and `particle_mouse_controlpoint_test` cover the geometry; a fixed-seed
  `offscreen_scene_probe` dump of a hidden-then-shown particle scene must stay
  byte-identical to a build that generated every frame.
- **Matrix packing and live uniform updates** — `ShaderValuePacking.*` and
  `ShaderValueUpdaterCompat.*` in `script_runtime_compat_test` cover column-major
  values, row-major/strided inputs, inline/dynamic/empty ownership and current
  camera/effect/material-slot values. `PlaybackGPU.FrameUpdatesAreVisibleBeforeUpload`
  checks updated color/geometry and hidden output on the real GPU.
  `PlaybackGPU.LiveTexelSizeOverridesParseDefaultsWhileMaterialValuesStayLive`
  checks actual output pixels and changing user material constants: Compatibility
  and Native Metal write live engine uniforms after parser defaults.
- **Lighting projection** — `MetalSceneDraw.LightingViewDirectionFollowsTheAuthoredSceneThroughEffects`
  checks lit and unlit pixels for both projections, directly and through
  effects. Material compilation sets `SCENE_ORTHO` from the authored scene
  projection on both backends, effect passes included, so a 2D layer uses the
  shader's fixed view direction rather than a perspective eye on the layer's
  plane (which reduces its lighting to ambient-only). Material overrides cannot
  change this scene-owned switch, and the shader request/cache key includes it.
  `PerformLighting_V1` itself is generated as Wallpaper Engine writes it, below.
- **Scene lights (LightingV1)** — `cargo test -p shader --lib preprocess::lighting`
  pins the generated block (arrays sized by the `LIGHTS_*` combos, nothing for an
  unlit pass); `pipeline.rs`
  `a_lit_pass_gets_wallpaper_engines_light_arrays_sized_by_the_scene_on_both_backends`
  compiles it for SPIR-V and Metal, and
  `every_asset_shader_that_requires_lighting_compiles_lit_and_fogged_on_both_backends`
  does so, with both fogs, for Wallpaper Engine's own lit shaders when
  `WALLPAPER_MACHINE_ASSETS_ROOT` names them (`fur4` is excluded: its instanced shells read the
  dialect's `CASTF` cast macro, which the compiler does not supply, lit or unlit).
  `SceneSchema.LightsOfEachKindFillWallpaperEnginesLightingArrays` checks every
  kind's uniform layout, parenting and the legacy-only packing;
  `SceneSchema.LightsFollowTheirUserPropertyScriptAndIntensityTimeline` the
  bindings and the light-state hash the static cache folds in;
  `SceneSchema.TheNormalMatrixIsTheDrawsRotationWithoutItsScale` the per-draw
  normal matrix; `MetalSceneDraw.ALayerLitByScenePointAndDirectionalLightsIsTheSameOnBothRenderers`
  the lit pixels on both renderers.
  `SceneSchema.FogIsCompiledIntoPassesWhoseFogComboIsOnWithWallpaperEnginesParameters`
  checks that scene fog reaches a pass whose `FOG` combo is on (and only such a
  pass) with Wallpaper Engine's parameter layout, and
  `SceneSchema.ATextureSlotsTexelIsTheStepOfTheTextureItSamples` that
  `g_Texture<N>Texel` is (1 / width, 1 / height, width, height) of the sampled
  texture. After a shader-crate change, rebuild
  `target/release/libshader.a` (`cargo build -p shader --features ffi --release`)
  before the CMake test binaries, or they link the old compiler.
- **HDR, bloom and emissive masks** — an authored `hdr` scene with bloom on uses
  RGBA16F color intermediates on both backends
  (`SceneSchema.AnHdrSceneWithoutBloomRendersAsAnOrdinaryOne`: with bloom off it is
  8-bit, as in Wallpaper Engine); masks and source media keep their formats and
  SDR scenes keep RGBA8. HDR shader combos are enabled before compilation, not
  approximated by raising final display brightness, and the fourth
  texture-component flag (TEX bit23) travels through the C++/Rust compiler
  interface so an alpha-channel emissive mask can enable its shader branch.
  Missing HDR materials fail rather than silently substituting LDR. HDR bloom
  follows Wallpaper Engine 2.8: as many half-size levels as the frame's shorter
  side allows, at most eight and at most `bloomhdriterations`; extraction and
  downsampling read one source texel either side and upsampling half of one
  (`ScenePostProcessPass::source_texel_radius`, refreshed at prepare/resize); the
  two coarsest levels upsample through `hdr_upsample_cubic` (the linear upsample
  stands in when an asset set lacks it); every upsample adds its level times
  `bloomhdrscatter` as it is, and the extraction strength is
  `bloomhdrstrength / (scatter^max(levels - 2, 0) + 1)`. A scene that leaves the
  keys out gets strength 2, threshold 1, feather 0.1, scatter 1.619 and eight
  iterations. `SceneSchema.HdrBloomBuildsWallpaperEnginesLevelsAndWeights` checks
  the levels, radii, cubic passes and weights the parser builds, and
  `MetalSceneDraw.HdrBloomWeighsItsLevelsAsWallpaperEngine` GPU pixels across
  live strength and scatter changes (zero strength included);
  `.ParsedHdrRadianceSurvivesEffectsLayerLinksAndBloom` uses an
  original bit23 emissive texture through the real parser, effect chain and layer
  references. `MetalSceneDraw.OverbrightRadianceReachesBloomWithoutChangingLdrColor`
  and `PlaybackGPU.OverbrightTargetsFeedBloomAndPreserveSdrColor` read pixels and
  unclamped radiance on the native and Compatibility backends, and
  `SceneSchema.HdrBloomRejectsMissingHdrMaterialsRatherThanFallingBackToLdr`
  guards the parser.
- **Render targets and texture allocation**
  - Texture residency comparisons must cover the scene's full visibility and
    crossfade cycle, including the moments when each affected image is actually
    visible; matching startup frames can miss large animated layers whose
    opacity is still zero.
  - Native Metal allocates only targets the compiled passes name.
    `metal_scene_draw_smoke` checks that a declared but unused target stays
    unallocated through optimisation off/on, and that a copy the plan drops as
    dead is not made while the optimisation is on and gets its image back,
    filled, when it is turned off without a recompile. Compare target residency
    with the harness's render-target bytes, not the device-wide allocation.
  - `render_target_lifetime_test` checks 32 generated multi-version graphs
    against a last-access oracle, plus nested composites with aliases, three
    sizes, visible and hidden parents, and background-copy enabled/disabled.
    Alias clears and readers must refer to the same canonical resource. Pooled
    targets are retained until every logical version has finished, and effect
    inputs are cleared explicitly when `copybackground=false`; the test asserts
    version lifetimes and a real transparent writer before an effect samples its
    empty input.
  - The check's eight generated nested-compose scenes compare pooled and isolated
    allocation byte for byte and add known-pixel assertions that empty inputs do
    not leak old pixels and that children actually render.
  - A target the frame reads before anything writes it, and writes later, carries
    the previous frame's pixels (a motion-blur history buffer). The render graph
    flags it (`carriesPreviousFrame`), and the Vulkan renderer and the offscreen
    probe reserve it an image of its own before preparing passes, so it is never
    pooled; pooled, it would take an image another target redraws every frame and
    a trail would blend in a faint copy of some other layer. The scene output is
    exempt (the frame's prepass clears it first). `RenderTargetLifetime.OnlyTargetsReadBeforeTheFrameWritesThemKeepTheirOwnImage`
    and `.CarriedOverKeysAreTheOnesReadBeforeTheirFirstWrite` cover the graph,
    `PlaybackGPU.CarriedTargetsShareTheirImageWithNoOtherTarget` the reservation.
    It costs exactly those buffers' memory. Native Metal keeps every carried-over
    target in an image of its own for the life of the graph, so it draws these too
    (`MetalSceneDraw.ALayerReadingThePreviousFrameSeesExactlyThePreviousFrame`:
    the first frame reads the cleared buffer, each later one the frame before,
    byte-identical with scene optimisation off and on), and reports the loop as
    a reason to keep the clock running.
- **Render-target reuse correctness** — `static_subgraph_cache_test` (reuse
  verdicts, copy elision, alias resolution, and `OnlyWritersOfCacheableTargetsAreSampled`:
  both backends sample only the passes `Plan` reads, and an unsampled pass cannot
  change a verdict) and, on the native backend,
  `MetalSceneDraw.AnUnchangedTargetIsReusedAndProducesTheSamePixels` and
  `.TurningTheOptimisationOffDrawsEveryPassAgain` in `metal_scene_draw_smoke`.
  Reuse must be provable by readback, not by a counter alone: a skipped pass has
  to leave byte-identical pixels, and a changed input has to redraw. On
  Compatibility, `PlaybackGPU.APooledImageAnotherTargetStillDrawsIntoIsNeverPinned`
  in `playback_gpu_test`: a target whose pooled image it took from a key that
  released it is never pinned, because that key's prepared passes still draw into
  the image every frame; pinning it lets a skipped layer read another layer's
  picture from the second frame on, which the pooled/isolated comparison in
  `check_renderer.py` shows as a divergence.
- **Direct presentation and reuse** — a frame that drew straight into the
  drawable leaves the scene's output target unwritten, so the reuse record for it
  is dropped (`VulkanRender::drawFrameSwapchain`); reusing it through the final
  blit would compose an image nobody drew.
- **Sprite-sheet stepping and reuse** — `MetalSceneDraw.ASpriteSheetAdvancesOnItsOwnClockAndRedrawsOnlyWhenTheFrameChanges`.
  A sheet between frame changes may be reused, but its clock must keep running or
  the animation never reaches the next frame. `sprite_animation_test` checks
  elapsed time across cadences and long loops.

## Alpha compositing

- **Source-over coverage** — the `generated-alpha` case in `check_renderer.py`.
  `SetBlend` (and the native `MetalBlend` state) writes source-over's
  `As + Ad*(1-As)` for `BlendMode::Translucent`: the color source factor is
  `SRC_ALPHA` but the alpha source factor is `ONE`. With `SRC_ALPHA` for both,
  every translucent draw loses coverage on partially covered texels, nested
  compose layers multiply the loss, and soft anti-aliased seams show a thin
  saturated line. Opaque and fully transparent texels are unaffected. The case
  composites a half-covered source over transparent, half-covered and opaque
  destinations inside a compose layer and samples the composed alpha back as RGB
  (expected 128/191/255). It uses synthetic shaders only.
- **Alpha-to-coverage passes** — `MetalBlend.*` in `metal_backend_test`; the
  Compatibility backend sets the same state in `SetBlend`. On multisampled
  attachments coverage decides what an `alphatocoverage` pass keeps and kept
  samples are written unblended, as in Direct3D (blending as well multiplies
  partially covered texels by alpha a second time and dims thin lines). On
  single-sample targets both backends disable coverage and use source-over
  blending, otherwise transparent or partially covered pixels become opaque.
  Scenes stay single-sampled, so edges are thresholded rather than antialiased.
  `generated-alpha-single-sample` verifies composed coverage on Compatibility
  (128/191/255), `MetalSceneDraw.SingleSampleAlphaCoveragePreservesTransparentAndPartialPixels`
  checks zero, half and full coverage as RGB on Native Metal across repeated
  frames, and the CPU blend-state tests keep the unblended multisample
  contract. None of this adds MSAA targets, render passes or allocations.

## Text, fonts and clocks

- **Fonts and limits** — `text_object_runtime_test`. Font decoding prefers valid
  authored bytes, then a usable installed family, then a platform fallback;
  missing paths and malformed embedded fonts use the same fallback for both
  measurement and rasterization. Coverage spans seven font choices and three
  text samples including Chinese, plus missing/corrupt sources and valid assets,
  and checks actual glyph coverage rather than just nonempty strings. Authored
  `maxwidth`, `maxrows`, `limitwidth`, `limitrows` and `limituseellipsis`
  constrain both measurement and rasterization, including dynamic text updates:
  `TextObjectRuntime.WidthAndRowLimitsProduceTheSamePixelsAsExplicitLineBreaks`
  and `.EllipsisFitsTheLastVisibleRowAndLimitFlagsRemainIndependent` compare the
  rendered pixels and layout bounds, and FreeType and fallback fonts share the
  same wrapping and truncation rules.
- **Text as Wallpaper Engine sets it** — `text_object_runtime_test`.
  `TextObjectRuntime.PointSizeIsRequestedFromTheFontAt300Dpi` asks FreeType for the
  face the way Wallpaper Engine does (`FT_Set_Char_Size` at 300 dpi, whose line
  height is one row's card height) and requires the layout to agree;
  `.PointSizeIsClampedToTheRangeWallpaperEngineAccepts` pins the 1 through 256 clamp
  for measurement and estimate alike. `.EmptyTextIsATwoByTwoCardPlusPadding`,
  `.CardPaddingSizesTheCardAndNeverNarrowsTheWrap` (a limit that just fits keeps the
  text on one row whatever the padding) and `.CardPaddingInsetsAlignedTextOnEachAxis`
  cover the card; `.ANegativePaddingTakesTheCardInAndOnlyTheTopIsCapped` pins that
  a lane is capped at 512 and not floored (a card never goes below a pixel);
  `.PaddingAndSpacingReadTheFormsWallpaperEngineReads` (number, `"x y"`, a lone
  `"x"`, a bound `value`, the 32-pixel default, the 512 cap, a negative lane, and a
  JSON array, which the reference does not read and so leaves the default) and
  `.CardPaddingAppliesOnlyToLayersWallpaperEnginePads` (effects, a visible effect
  only, colour blend other than none and add, LED source, opaque background) cover
  the parse and the gate, and `.ASceneWithFogPadsEveryTextLayerWhateverItsEffects`
  the scene-wide fog flags (`fogdistance`, `fogheight`: the renderer composites every
  text layer in such a scene, which is what pads it; the same two flags also add the
  `FOG_COMPUTED` combo to its shader, which a text layer's own shader has no use for).
  `.SpacingAddsToEveryAdvanceAndToTheLinePitch` requires a
  row to be the pen at the glyph starts and the last glyph's ink, so `n` glyphs
  widen by `n - 1` gaps, and rows to step by the line height plus `spacing` y;
  `.SpacingMovesTheRowsOfRasterisedText` checks the pixels.
  `.BlockAlignJustifiesOnlyRowsThatEndedAtAWordWrap` justifies the wrapped rows of
  a paragraph to exactly `maxwidth` and leaves the paragraph's last row and the
  next paragraph's rows pixel-identical to the unjustified layout;
  `.BlockAlignNeedsAWidthLimitAndALineThatWraps` leaves unlimited and single-row
  text alone. Where a row ends is pinned against the rule read from the reference:
  `.TheLastRowTheLimitAllowsIsCutAtTheGlyphThatDidNotFit` (on the last row
  `maxrows` allows nothing wraps; the row keeps every glyph before the one that did
  not fit, inside a word if that is where it falls, and with two rows allowed the
  first still wraps at its last space and only the second is cut),
  `.AnEllipsisReplacesTheEndOfTheLastRowAtTheGlyphThatDidNotFit` (the marker
  replaces the end of that row, glyphs dropped one at a time until it fits, never the
  whole word before it),
  `.ALineBreakWithNothingAfterItAddsNoRowAndNoEllipsis` (a break with nothing after
  it ends the text; one with anything after it, a second break included, is cut)
  and `.ARowThatWrapsAtADoubleSpaceKeepsAllButOneOfTheSpaces` (the break is at the
  last space before the glyph, and the space before it stays in the row, where
  `blockalign` has it to widen). Each fails against the rule it replaced (a
  word-boundary cut on the last row, a row after a trailing break, every trailing
  space dropped). `.TextMeasuresToTheCardsWallpaperEngineSaved` is ground truth: the
  size of a text layer in a scene file is the card Wallpaper Engine laid the text out
  in, and the five cards it saved for Arial text that the tests keep (with and
  without a padding of 32, a lone full stop, a run of dashes, a long run of
  underscores) are reproduced to the pixel with exact comparison, which is as far as
  the claim goes: other fonts and scripts, and any other text, are not compared. They
  are the metrics of the Arial of the machine that ran Wallpaper Engine, and a build
  of the font with other metrics shows as a difference, not a skip.
  `.PenAdvancesAreUnhintedWholePixelsKernedWithTheNextGlyph` states the kerning rule
  against FreeType's own numbers. Two cards that were reproduced while the rule was
  developed, one of wrapped text of 729 characters and one with a padding of 128, are
  not kept: their text is private, so nothing re-checks them. The other fixtures use
  a system font, so the tests state relations to the font's own metrics, not pixel
  counts, and the ground-truth tests skip where Arial is not installed.
- **Text colour blend and screen anchor** —
  `TextObjectRuntime.ColorBlendModeMixesTextWithTheScreenThroughThePassthroughPass`
  and `.AddColorBlendTextIsDrawnAdditivelyOntoTheScene` (CPU, in the gate) and
  `MetalSceneDraw.ATextLayersColourBlendModeAppliesItsColourAndAlphaOnceOnBothRenderers`,
  which draws white text at half alpha over green on both renderers: mode 2 mixes
  half of white once (128, 159, 128), mode 31 adds half of it (128, 191, 128), and
  the pictures are identical. `.ScreenAnchorOffsetsPinTheLayerToTheEdgeItNames`
  tabulates the nine anchors against the presented margins, and
  `.ScreenAnchoredTextFollowsThePresentedAreaAndNothingElseDoes` moves anchored
  layers with `SetCursorViewport` (a pan, a display that shows more than the canvas,
  and back) while layers with `none`, no key, or only the key keep their place: the
  `anchor` key is never a pivot.
- **Outline, blur and drop shadow** — `TextObjectRuntime.OutlineGrowsTheGlyphByItsThicknessInPixels`,
  `.OutlineThicknessIsCappedWithTheGlyphAtlasAndNeverBelowOnePixel`,
  `.BlurSoftensEdgesOverItsSizeAndKeepsTheGlyphWhereItIs`,
  `.DropShadowFollowsItsOffsetAndOpacityAndOutlineWidth`,
  `.StyledTextCardGrowsOutwardAndKeepsTheLayoutBoxWhereItWas`,
  `.ParserReadsTheFontShaderStyleAndPicksTheStyledShader`,
  `.StyledTextCardCoversTheStyleWhenTheLayerIsParsed` and
  `.StyleColoursFollowTheirPropertiesAndTheBakedKeysAreReadOnceAndHeld`, and
  `MetalSceneDraw.StyledTextIsDrawnWithItsOutlineAndShadowByTheNativeBackend` and
  `.StyledTextWithoutAnOutlineKeepsTheLayersColourAtItsEdgesOnBothRenderers`.
  The raster of a styled layer holds three coverage masks (red the glyph, green the
  glyph and its outline, blue the shadow with its opacity), so the glyph takes the
  layer's colour and the outline and shadow keep theirs; the first Metal test requires
  green outline and magenta shadow pixels around white glyphs (Native Metal only), and
  the second, on both renderers, draws red text blurred, and shadowed in red, over
  white: every pixel is red mixed with white, so its red channel must stay full,
  which it does not when an outline colour the layer never asked for is mixed in at
  the partly covered pixels (the shader takes the outline colour into the glyph only
  for a layer with an outline, as the reference's path without `OUTLINE_ENABLED`
  does). The property test binds the outline and shadow colours, which follow their
  property live, and the switches, sizes and opacity, which are read once at load with
  the user's value, noted load-only and held by a preview. Sizes are pixels of the
  finished text, capped in the shader's atlas units (outline 5.1, blur and shadow 6),
  and the tests state them as distances from the unstyled glyph box.
- **Cache metadata and corruption** — `render_target_lifetime_test`,
  `text_object_runtime_test` and `shader_cache_metadata_test` cover clock/text
  corruption, persistent shader-cache metadata, cache invalidation after include
  edits, corrupt-cache recovery, parent-aware compose-background sampling, and
  SceneScript AM/PM sprite-frame selection. They create no window and no Vulkan
  device.
- **Clocks** — `ShaderValueUpdaterCompat.DayTimeUniformFollowsLocalClockAndWrapsAtMidnight`
  injects a wall clock and checks `g_Daytime` and the compatible `g_DayTime`
  spelling as the local fraction of a day.
  `ScriptRuntimeCompat.EngineTimeOfDayFollowsTheLocalClock` checks that
  SceneScript's `engine.timeOfDay` is the same fraction (`Utils/TimeOfDay.hpp`
  serves both). It is a getter that reads the clock only when a script asks.
  While it was missing, scripts that blend day and night layers by the hour
  computed `NaN` and drew the layer black.
- **Raster caches and revisions** — text raster caches hold neutral glyph
  coverage. Color, brightness and alpha bindings reach uniforms, including text
  under effects, without relayout or uploads
  (`MetalSceneDraw.TextStylingChangesPixelsWithoutRerasterizingGlyphs`). Text
  scripts first run on the normal ordered tick, not while objects are still being
  parsed. The layout queue is FIFO and coalesces updates in place;
  `TextObjectRuntime.AWaitingClockIsNotStarvedByNewerReadoutUpdates` blocks the
  worker deterministically to verify that newer readouts cannot overtake a
  waiting clock. Completed glyph images publish in revision order even when a
  newer value is pending, so continuously changing labels never stay blank
  waiting for an exact-current revision; the test compares the published glyph
  pixels before and after catching up. An effect target grows geometrically, up
  to 4096 per dimension, only when its caption outgrows the current capacity, and
  that size change requests a graph rebuild.
- **Text layers on the native backend** — `MetalSceneDraw.ATextLayerIsParsedTranslatedAndDrawnByTheNativeBackend`:
  a parsed text object, the text program translated to Metal, the rasterised
  glyphs imported and the card drawn into the scene's own target. A text layer
  must reach the backend through the ordinary parser, not through a hand-built
  mesh.
- **Unchanged text costs nothing** — `MetalSceneDraw.TextThatHasNotChangedIsNeitherLaidOutNorUploadedAgain`:
  twelve frames of an unchanged string measure nothing and upload nothing, a new
  string costs at most one upload per in-flight frame and reaches the drawn
  picture, and it then goes quiet again. The script keeps running throughout;
  "quiet" must never be achieved by stopping it.
- **Text layers under an effect chain** — `MetalSceneDraw.ATextLayerWithAnEffectChainKeepsBothOfItsCards`:
  a text layer with effects has three meshes the relayout rewrites — its own
  card, the chain's final card and the node the chain resolves its last pass onto
  — and all of them have to be accepted and updated, or the scene falls back as a
  whole or freezes at its first layout. Use text whose glyphs differ, not more of
  the same word: the chain clips the card to its buffer, so a longer repetition
  can leave identical pixels.
- **Opt-in local-asset diagnostic** — `TextObjectRuntime.LonelyCatHeadlessRegression`
  in `text_object_runtime_test`: set `WE_TEST_PROJECT`, `WE_TEST_ASSETS` and a
  disposable `WE_TEST_CACHE`, then run with
  `--gtest_filter=TextObjectRuntime.LonelyCatHeadlessRegression`; add
  `WE_TEST_EXPECT_WARM=1` for a second run. It parses the package, ticks scripts
  and constructs the render graph; it does not initialize playback, capture the
  desktop, or modify the imported wallpaper.

## Animation and puppets

- **Non-additive layer weights** — `MdlSchema.NonAdditiveLayersShareTheWholePoseWeight`
  (normalized and partial weights, rotation, scale, loop wrap, repeated samples)
  and `.NonAdditivePoseMixRetainsDistinctMotionAndAdditiveOffsets` (distinct
  animations, additive overlays, live blend/visibility changes) in
  `mdl_schema_tests`. Non-additive puppet animation layers use their effective
  blend weights for the entire pose (translation, scale and rotation), including
  offsets from the reference pose; otherwise overlapping layers double
  character-sheet assembly offsets and separate attached pieces. Additive layers
  keep their authored weights. The prepared weights are reused: no per-frame work
  or GPU resources are added.
- **Puppet lighting** — `MetalSceneDraw.PuppetEffectsApplyLightingOnceAfterAssembly`
  covers all eight combinations of puppet/card, effects/direct and lit/unlit over
  repeated draws. Puppet layers with effects light their assembled geometry only
  in the final skinned pass; the input texture-sheet pass is unlit, so lighting
  is neither multiplied twice nor baked into the separate cut-out pieces.
  Unskinned layers, effect-free puppets and unlit materials keep their lighting
  paths.
- **Colour blend modes** — `MetalSceneDraw.AColorBlendLayersColourAndAlphaApplyOnceOnBothRenderers`
  draws a tinted, half-transparent layer through a stand-in passthrough over a
  coloured background: the tint and alpha are taken once, by the layer's own
  pass. `MetalSceneDraw.AnAddColorBlendLayerIsAddedOntoTheSceneOnBothRenderers`
  requires mode 31 to add the layer at its alpha, and
  `RenderGraph.addColorBlendLayersAddOntoTheSceneWithoutSamplingIt` that a mode 31
  layer, with and without an effect, draws additively onto the scene with no
  passthrough, no screen copy and no pass sampling the screen.
- **`colorBlendMode` on puppets** — `RenderGraph.puppetColorBlendModeSamplesTheScreenOnlyWhereItDrawsOnScreen`
  in `rendergraph_smoke`. A layer's `colorBlendMode` mixes it with the screen
  behind it, so only the pass that draws onto the screen may sample it. On a
  puppet with bones that is the final skinned pass, which takes `BLENDMODE`
  itself; the separate passthrough that cards and mesh-only puppets end with
  would otherwise run before it, over the texture sheet, and paint a shrunken
  copy of the whole wallpaper inside the layer. The passthrough is dropped, not
  added to. The test parses a one-bone puppet and requires the only
  screen-sampling pass to be the one writing the scene.
- **Four-light shaders** — `ShaderValueUpdaterCompat.FourLightColorsRoundTripThroughPackedUniforms`
  in `script_runtime_compat_test`: legacy four-light shaders pack the fourth
  light's RGB into the `w` lanes of three color uniforms; zero through five
  lights, channel order, radius/intensity premultiplication, the four-light limit
  and clearing after lights are removed.
- **`origin.animation`** — `SceneSchema.OriginTimeline*` (aligned images,
  text/groups, absolute/relative keys, loop duration, paused playback,
  seek/replay, completed timelines releasing animation demand),
  `MetalSceneDraw.AnAnimatedCurtainRevealsTheWholeCanvasAndStaysOpen` (pixels
  before, during and after a reveal on direct and effect-chain layers) and the
  `generated-origin-animation` case in `check_renderer.py`, which verifies both
  halves after the intro under pooled and isolated allocation. Authored layer
  `origin.animation` uses one playback clock for its three curves. Relative keys
  offset the authored origin, not the previous tick; unkeyed axes keep their
  values. Scripts and user properties keep precedence, anchors and effect-final
  cards follow the existing transform path, and orthographic shots keep their
  shared origin/zoom clock. Static origins add no tick binding, and held
  animation frames do not re-evaluate curves.
- **Puppet attachments and poses** — puppet attachments use the animated bone
  affine each frame while preserving the child layer's authored/script
  transform. Character-sheet reference poses are decoded separately from cut-up
  bind geometry so additive and non-additive animations reassemble correctly, and
  puppet animation deltas use the skeleton reference pose, not the first
  animation sample, preserving initially collapsed eyelids and authored
  rotations. Synthetic regressions cover declaration order, animated
  translation/rotation/scale, repeated same-time samples and local edits.
- **Scalar material timelines** preserve paused first keys and authored Bezier
  handles; SceneScript named animation controls drive play, replay, pause, stop,
  seek and rate.

## Shader pipeline

Rust regressions in `crates/shader/tests` (`legalize`, `preprocess`,
`video_planes`, `pipeline`) cover these paths with synthetic shader sources;
`pipeline` skips asset-dependent cases with a printed reason.

- **Built-in simulation uniforms** —
  `ShaderValueUpdaterCompat.SimulationEffectsSeeFrameTimeCursorTravelAndButtons`
  checks that a shader declaring `g_Frametime`, `g_PointerPositionLast`,
  `g_PointerState` or `g_TextureReductionScale` receives the frame's step, the
  previous frame's cursor, the primary button (held in x and y, z only on the
  frame it went down, as Wallpaper Engine pushes a ripple once per click) and 1,
  and that such a pass counts as following the clock or the cursor. Left at zero,
  Wallpaper Engine's cursor ripple and fluid simulation effects never moved and
  `blend` with `TRANSFORMUV` divided by zero.
  `.EffectModelMatrixAndInverseProjectionMatchTheEffectProjection` checks
  `g_EffectModelMatrix` and `g_EffectModelViewProjectionMatrixInverse` against
  the effect projection, and `.EffectTextureProjectionMapsTheLayerCardOntoTheScreen`
  that `g_EffectTextureProjectionMatrix(Inverse)` maps the layer card onto the
  screen wherever the card is moved, turned or flipped, so a cursor effect lands
  under the cursor on a layer that does not fill the canvas.
- **Trailing commas** — `SceneSchema.EffectFilesWithTrailingCommasLoadTheirPasses`
  loads an effect and material whose arrays and objects end with a comma, as
  Wallpaper Engine's own `effects/fluidsimulation/effect.json` does; strict
  parsing had dropped every fluid simulation effect.
- **Pipeline revision** — `ShaderPipelineRevision::CURRENT`
  (`crates/shader/src/pipeline/revision.rs`) is part of the cache key. Bump it
  whenever codegen can produce different output for source that already
  compiled; each bump invalidates previously compiled programs.
- **`HLSL` is true, as in Wallpaper Engine** — a stage sees `GLSL`, `HLSL` and
  `HLSL_SM40` defined as 1 (`crates/shader/src/preprocess/macros.rs`).
  Wallpaper Engine compiles its shaders as HLSL: it prepends `#define HLSL 1` and
  `#define HLSL_SM40 1` and never defines `GLSL`, which stays defined here so the
  `#if GLSL` paths shaders pick for the backend language stay picked. `HLSL`
  used to be 0, which `#ifdef HLSL` cannot tell from 1 but `#if HLSL` can: every
  such block was skipped. The first pass of each compositing effect
  (`effectcomposebackground`, and the `COPYBG` and `TEX` paths of the god rays,
  shine and clipping mask effects) turns `v_ScreenCoord.y` over only there, so a
  layer composed over the screen sampled it mirrored vertically on both renderers
  (`MetalSceneDraw.ACompositingEffectSeesTheScreenUprightOnBothRenderers` reads
  a red-over-blue screen back through such an effect). Taking those blocks put
  the others in play, each handled by a rule that is not tied to a shader:
  - A stage-qualified declaration of a builtin variable the backend provides
    (`in uint gl_VertexID;` and `in uint gl_InstanceID;`, which Wallpaper
    Engine's morph, instancing and shadow stages write) is dropped
    (`PlannedDeclaration::BuiltinRedeclaration`). It had become a vertex
    attribute of that name, which compiles and reads whatever sits at its
    location. The `builtin_variables` strategy spells the uses `gl_VertexIndex`
    and `gl_InstanceIndex`, which Naga types `uint` as the declaration did, so
    `gl_VertexID + g_MorphOffsets[1]` and `CASTF(gl_InstanceID)` need no
    conversion, and the compiled program lists neither as a vertex input. A
    `gl_` builtin the backend lacks (`gl_ViewportIndex`) keeps its former
    handling, so the shadow caster stages (their shadow maps are not drawn) still
    compile.
  - The `mat3 inverse(mat3)` of `common_perspective.h` is an ordinary user
    function: Naga calls it in place of its builtin on both targets, and a stage
    that declares any `inverse` gets no generated Metal helper, as before. It is
    the exact adjugate-over-determinant inverse.
  - The `pow(falloff + FLT_MIN, exponent)` light falloff of `common_pbr_2.h` has
    a positive base even where the falloff is 0, so it is defined and finite. It
    differs from the earlier `mix`/`step` form, which offset the base by 6.1e-5,
    by at most 0.1 for exponents of 0.25 and above and by under 0.001 from 1 to
    16; with a zero exponent it lights beyond the radius, as it does there.
  - A brace-list array initializer (the kernel of `bokeh`) is read by Naga as it
    stands, on both targets.
  Pipeline revision 15 recompiles programs built while the macro was 0. Across
  the 1,269 (scene, shader, combos) programs of the local scene library, compiled
  for SPIR-V and MSL (2,538 compilations), every program that compiled still
  compiles and none that failed was fixed; 2,126 outputs are unchanged and the
  other 412 differ only in those blocks (author `inverse` 224, light falloff 164,
  bokeh kernel 20, screen coordinate 8, four of them in two). With the dialect's
  cast macros defined, the shipped `generic3`, `generic4` and `shadowcaster`
  vertex stages with `MORPHING`, and `fur4` with its instancing, compile where
  they stopped at `gl_VertexID` and `gl_InstanceID`. Known and not handled: the compiler does
  not supply the dialect's own prelude macros `CASTI`, `CASTU`, `CASTF`,
  `CAST4U`, `DECLARE_SAMPLER2D_PARAMETER` and `MAKE_SAMPLER2D_ARGUMENT`, so those
  stages, and the morph-target stages that pass a sampler to a function
  (`foliage4`, `chroma4`), do not compile on their own; and Naga has no
  `gl_ViewportIndex`. Tests: `preprocess`
  (`default_macros_are_wallpaper_engines_direct3d_dialect_plus_glsl`,
  `every_spelling_of_the_hlsl_test_takes_the_direct3d_branch`), `legalize`
  (`a_redeclared_vertex_builtin_makes_no_attribute_and_its_uses_reach_the_builtin`
  and the macro, qualifier and brace-list cases beside it), `naga_metal` (the
  vertex and instance index as `[[vertex_id]]`/`[[instance_id]]` and SPIR-V
  builtins; the author's `inverse` on both targets) and `pipeline` (the screen
  coordinate, the kernel, the falloff, the vertex inputs, and the shipped
  `effectcomposebackground` and `generic4` stages when the assets are present).
- **Repairs for permissive-path shaders** — the pipeline handles undersized
  cross-stage varying declarations, conditional helper headers, source-defined
  `log10`, legacy scalar/vector argument conversion, compound assignment
  narrowing and scalar initializer conversion. Floating remainder uses a
  generated typed helper accepted by Naga, preserving truncating remainder and
  single evaluation of its operands. Active `#undef` directives remove macros
  across includes; inactive branches leave them intact. A directive keyword ends
  at its first non-identifier character, so `#if(A == B)` and `#endif// note`
  are conditionals, and only an `#include <path>` body opens angle brackets, so
  a `<` comparison keeps a trailing `//` comment out of its `#if` expression.
  Generated NV12 members
  create and bind a uniform block even when a material has no authored scalar
  uniforms. It also absorbs idioms author shaders inherit from the permissive
  path they were written against, each of which otherwise drops a whole effect
  rather than one expression: a texture annotation's `"default":""` means the
  slot has no default; `CAST2`/`CAST3`/`CAST4` are vector constructors before
  `legacy_builtins` renames them; mixed-width vector operands inside a call
  argument truncate to that expression's narrowest operand, while sampler
  coordinate arguments stay with the texture strategy that narrows them to the
  sampler's dimensionality; a declaration or assignment truncates its wider
  operands whether they sit next to a call, a constructor or a parenthesized
  group (`round(v2) * v4`, `(CAST2(500) / res4) * s`); a scalar operand of `pow`,
  `mix` and the other broadcasting builtins broadcasts when it is a
  component-wise builtin of known scalars or a one-component read
  (`pow(abs(c), color)`, legacy `saturate`/`lerp`/`fmod` spellings included);
  a whole call of a builtin that always returns a scalar (`dot`, `length`,
  `distance`) is a scalar unless a user overload of that name says otherwise,
  so `vec2 proj = dot(a, b);` broadcasts;
  a scalar stored into a vector by plain `=` broadcasts, and a returned value
  converts to the declared return type the same way (`vec3 f() { vec4 c; return
  c; }` keeps `.xyz`); a comparison stored into a float lvalue (`x += a < b;`,
  `x = a < b;`) becomes `1.0`/`0.0`, while a conditional whose condition
  compares (`a < b ? 1.0 : 2.0`) stays the number it selects; and a parenthesized
  comparison used as an arithmetic operand is converted with `float(...)`.
  A global initializer that reads a runtime value (a uniform, a texture, a stage
  input, a mutable global or a user function) runs at the start of `main`:
  strict GLSL rejects it on a `const` global and silently drops it on a mutable
  one, which then reads zero. Constant initializers stay constant expressions.
  A statement that follows a JSON annotation or a `#define` is analyzed like any
  other; before, it took that token for its type and every repair skipped it.
  Known and not handled: logical-not applied to a float (`!someFloat`), which
  still rejects Wallpaper Engine's own `clipping_mask` effect.
- **Legacy effect shader interfaces** — `pipeline` tests: array varyings reserve
  all element locations; unambiguous user function parameters narrow wider vector
  arguments; a whole vector variable assigned to a narrower one keeps its leading
  components (`pipeline_narrows_whole_vector_identifier_assigned_to_narrower_target`,
  the shipped `cloudmotion` effect's `v_NoiseCoord = v_TexCoord`); custom
  scalar/vector uniforms across stages share a vector block with stage-local
  prefix views. Engine `g_*` uniform type conflicts remain errors.
- **Varying arrays sized by a numeric combo** resolve the macro before generated
  interface declarations are emitted and reserve one location per element, like
  literal-sized arrays. Location planning and emission use the same
  `interface_array_size` resolver at each declaration's source position: all
  earlier active directives count (including macros changed between ordinary
  items or inside earlier function bodies), later changes do not resize an
  earlier array, and bounds must be positive integer literals or visible
  object-like macros with positive integer values. Expressions, missing
  definitions (including those defined only after the declaration), zero and
  negative sizes produce an explicit diagnostic rather than silently reserving one
  location. `pipeline_resolves_macro_array_bounds_at_each_declaration` and
  `pipeline_rejects_unresolved_interface_array_bounds_before_layout` cover both
  backends; `pipeline_compiles_macro_sized_varyings_without_overlapping_locations`
  and `pipeline_legalizes_nested_legacy_calls_in_macro_replacements` compile both
  SPIR-V and MSL and cover annotation defaults, explicit counts, consecutive
  arrays and nested object/function macros. Legacy builtin calls in `#define`
  replacements are rewritten inside function bodies too. These are compile-time
  repairs for rejected shaders, not brightness adjustments: restoring a dropped
  effect restores its authored GPU work and target allocation, with no new
  per-frame CPU path or compensating render pass.
- **Uniform array layout is a contract** — a scalar or narrow-vector array in the
  generated uniform block is declared `vec4 name[N]` and every subscripted read is
  swizzled back. std140 pads each element to 16 bytes, which is what the host
  packs and the reflection reports, while the MSL backend emits the natural tight
  stride; without the repair every member after such an array is read from a
  different address on Metal than the host wrote it to. The swizzle follows reads
  reached through `#define` aliases (written inside `main` by the audio-bars
  shader family) and through array-parameter specialization, not just direct
  ones. A `float` element is one component, so a further subscript
  (`g_AudioSpectrum64Left[i / 4][i % 4]`) selects the element itself.
- **Matrix `inverse` reaches Metal through a generated helper** — Naga's MSL
  writer has no `inverse()`, so a stage that inverted a matrix failed native
  translation (`metal translation of '<shader>' failed`), which dropped the
  effect or sent the whole wallpaper to the compatibility renderer: the stock
  `perspective` and `lightshafts` effects with any combos, and `reflection`,
  `clouds` and `waterwaves` with `PERSPECTIVE=1`, which undo `squareToQuad` in
  the vertex stage. The `compatibility_functions` strategy renames builtin
  `inverse` calls to `_we_Inverse` and emits mat2/mat3/mat4
  adjugate-over-determinant overloads behind `#ifdef _WE_POLYFILL_INVERSE`,
  else `#define _we_Inverse inverse`.
  `NagaCompiler` defines the macro only for MSL, so SPIR-V keeps `GLSL.std.450`
  `MatrixInverse` and stays byte-identical, and no pipeline revision bump was
  needed. A shader that declares its own `inverse` keeps it.
  `matrix_inverse_of_every_square_size_compiles_to_metal_and_stays_native_in_spirv`
  (`naga_metal`) covers translation and the unchanged SPIR-V;
  `MetalSceneDraw.MatrixInversesOfEverySizeAreTranslatedAndDrawnExactly` draws
  each size's round-trip residual on the native backend, where one wrong
  cofactor sign turns its channel black.
- **A sampler slot's `combo` answers whether the material bound a texture there**,
  which is not the same as whether the slot is bound. An annotation's `default`
  exists so an unused sampler still reads something sane; `WPSceneParser` binds
  it, then reports the slot as unbound to the compiler so the combo stays 0.
  Feeding the defaulted list back turns every `{"combo":…,"default":…}` sampler
  permanently on (a `rounded_mask` then reads its corner radius from a white
  default instead of `u_Radius`). A slot the combo leaves unsampled is cleared
  afterwards, so nothing holds a texture it never reads.
- **Texture-driven switches are discovered before stripping conditional
  branches**: `#if USE_MASK` can contain the sampler annotation that defines
  `USE_MASK`, and discovering it only after preprocessing drops authored masks
  and lets localized brightness pulses affect the whole image. Only
  texture-derived switches are seeded this way; ordinary combo defaults still
  follow evaluated branches, and explicit material overrides still win. This is
  compile-time work with no added passes, temporal filtering or quality
  reduction; an active mask keeps its texture and sampling cost.
  `conditional_texture_annotations_enable_the_sampled_mask_on_both_backends`
  covers includes, cross-stage switches, absent/default-only textures and explicit
  overrides for SPIR-V and MSL, and `PlaybackGPU.AConditionalMaskKeepsPulsesOutOfTheMaskedRegion`
  reads six alternating-brightness frames: masked pixels stay fixed while the
  unmasked region continues to pulse.
