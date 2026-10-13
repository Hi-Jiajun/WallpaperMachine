//! A wallpaper's position on one display: moved live, saved at once, never a
//! draft.
//!
//! The renderer is the fake engine, so what these tests establish is what the
//! bridge asks of the engine and what it keeps; how a position looks on a real
//! display is not covered.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use wallpaper_core::{
    DisplayDesc, DisplayIdentity, DisplaySnapshotEntry, WallpaperAssignment,
    project::{SceneDesc, SceneFraming, SceneHandle, SceneTemplate},
};

use crate::{
    BridgeErrorKind, WallpaperBridge,
    api::BridgeBuilder,
    config::ConfigStore,
    engine::{EngineFacade as _, FakeEngineFacade},
};

/// A fake engine, and what lets go of it when the test ends.
///
/// The bridge registers a callback with its engine that holds the bridge's actor
/// and its runtime, and the engine is held by that actor in turn, so a test
/// bridge that is merely dropped keeps its twenty or so threads until the whole
/// test process exits. The bridge tests are already a few hundred threads short
/// of the limit a process has, so a test that builds bridges has to break that
/// loop itself.
fn new_engine() -> (FakeEngineFacade, EngineRelease) {
    let engine = FakeEngineFacade::default();
    let release = EngineRelease(engine.clone());
    (engine, release)
}

struct EngineRelease(FakeEngineFacade);

impl Drop for EngineRelease {
    fn drop(&mut self) {
        self.0.set_first_frame_callback(Arc::new(|_| {}));
    }
}

fn identified_display(display_id: u32) -> DisplaySnapshotEntry {
    let identity = DisplayIdentity {
        uuid: Some(format!("display-{display_id}")),
        vendor_id: Some(10),
        model_id: Some(display_id),
        serial_number: Some(100 + display_id),
        unit_number: Some(display_id),
        name: Some(format!("Display {display_id}")),
    };
    DisplaySnapshotEntry {
        identity: identity.clone(),
        desc: DisplayDesc::with_identity(display_id, identity, 0, 0, 1920, 1080, 2.0)
            .with_refresh_rate(60),
        handle: None,
        accepts_pointer_input: false,
        paused: false,
        window_active: true,
        assignment: None,
    }
}

/// What the engine reports once it runs `scenes`: the fake hands out handles by
/// position, and every running scene carries the descriptor it was opened with.
fn running(scenes: &[SceneDesc]) -> Vec<DisplaySnapshotEntry> {
    scenes
        .iter()
        .enumerate()
        .map(|(index, scene)| DisplaySnapshotEntry {
            identity: scene.display.identity.clone(),
            desc: scene.display.clone(),
            handle: Some(SceneHandle::new(index as u64 + 1)),
            accepts_pointer_input: true,
            paused: false,
            window_active: true,
            assignment: Some(WallpaperAssignment::Direct(SceneTemplate::from_scene_desc(
                scene,
            ))),
        })
        .collect()
}

/// Wallpaper `100` applied to each of `display_ids` through the same calls the
/// panel makes, and running: the first display holds handle 1, the next 2.
async fn shown_on(
    engine: &FakeEngineFacade,
    display_ids: &[u32],
) -> (WallpaperBridge, tempfile::TempDir) {
    let root = tempfile::tempdir().unwrap();
    engine.set_snapshot(
        display_ids
            .iter()
            .map(|&id| identified_display(id))
            .collect(),
    );
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    for id in display_ids {
        bridge
            .set_display_config_enabled("100".into(), id.to_string(), true)
            .await
            .unwrap();
    }
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.rendered_scenes().len(), display_ids.len());
    engine.set_snapshot(running(&engine.rendered_scenes()));
    (bridge, root)
}

/// The scenes a second launch opens from what the first one saved.
async fn scenes_after_restart(root: &Path, display_ids: &[u32]) -> Vec<SceneDesc> {
    let (engine, _release) = new_engine();
    engine.set_snapshot(
        display_ids
            .iter()
            .map(|&id| identified_display(id))
            .collect(),
    );
    let store = ConfigStore::open(root.to_path_buf());
    let saved = store.load_wallpaper("100").unwrap();
    let bridge = BridgeBuilder::new(engine.clone())
        .with_config_store(store)
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge");
    bridge
        .inject_scene_wallpaper_config_for_test("100", "Scene")
        .await;
    bridge.replace_wallpaper_config_for_test("100", saved).await;
    bridge.refresh_displays().await.unwrap();
    engine
        .calls()
        .first()
        .cloned()
        .expect("the restart opens the wallpaper")
}

fn framing(pan_x: f64, pan_y: f64) -> SceneFraming {
    SceneFraming { pan_x, pan_y }
}

fn on_display(scenes: &[SceneDesc], display_id: u32) -> &SceneDesc {
    scenes
        .iter()
        .find(|scene| scene.display.display_id == display_id)
        .unwrap_or_else(|| panic!("no scene for display {display_id}"))
}

fn wallpaper_file(root: &Path) -> PathBuf {
    root.join("wallpapers").join("100.json")
}

async fn move_to(
    bridge: &WallpaperBridge,
    pan_x: Option<f64>,
    pan_y: Option<f64>,
) -> Result<(), crate::BridgeError> {
    bridge
        .set_display_position("100".into(), "1".into(), pan_x, pan_y)
        .await
        .map(|_| ())
}

#[tokio::test]
async fn a_position_moves_the_live_scene_without_reopening_it_and_survives_a_restart() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();

    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(1), framing(0.2, 0.8))],
        "the scene on that display is told once"
    );
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "the running scene already is where the config says, so nothing reopens it"
    );

    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn saying_the_same_position_again_neither_writes_nor_asks_the_engine() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    move_to(&bridge, Some(0.2), None).await.unwrap();
    move_to(&bridge, None, Some(0.8)).await.unwrap();

    assert_eq!(engine.framing_calls().len(), 1);
    assert!(
        !file.exists(),
        "a position already held is not written again"
    );

    // The same holds for a display nobody ever positioned being told to stay
    // in the middle.
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, Some(0.5), Some(0.5)).await.unwrap();

    assert!(engine.framing_calls().is_empty());
    assert!(!file.exists());
}

#[tokio::test]
async fn an_axis_left_out_keeps_its_saved_value() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;

    move_to(&bridge, Some(0.1), Some(0.9)).await.unwrap();
    move_to(&bridge, Some(0.4), None).await.unwrap();
    move_to(&bridge, None, Some(0.0)).await.unwrap();

    let handle = SceneHandle::new(1);
    assert_eq!(
        engine.framing_calls(),
        vec![
            (handle, framing(0.1, 0.9)),
            (handle, framing(0.4, 0.9)),
            (handle, framing(0.4, 0.0)),
        ]
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.4, 0.0));
}

#[tokio::test]
async fn naming_neither_axis_changes_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.3), Some(0.6)).await.unwrap();
    let file = wallpaper_file(root.path());
    std::fs::remove_file(&file).unwrap();

    move_to(&bridge, None, None).await.unwrap();

    assert_eq!(engine.framing_calls().len(), 1);
    assert!(!file.exists());
}

#[tokio::test]
async fn a_position_outside_the_display_is_refused_whole() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    move_to(&bridge, Some(0.25), Some(0.75)).await.unwrap();
    let file = wallpaper_file(root.path());
    let saved = std::fs::read(&file).unwrap();

    for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -0.01, 1.01] {
        for (pan_x, pan_y) in [(Some(bad), None), (None, Some(bad)), (Some(0.9), Some(bad))] {
            let error = move_to(&bridge, pan_x, pan_y).await.unwrap_err();
            assert_eq!(
                error.kind(),
                BridgeErrorKind::InvalidInput,
                "{pan_x:?},{pan_y:?}"
            );
        }
    }

    assert_eq!(engine.framing_calls().len(), 1, "the engine heard nothing");
    assert_eq!(
        std::fs::read(&file).unwrap(),
        saved,
        "a refused position leaves the file alone, the good axis of a pair included"
    );
    // The edges themselves are positions.
    move_to(&bridge, Some(0.0), Some(1.0)).await.unwrap();
    assert_eq!(
        engine.framing_calls().last().map(|call| call.1),
        Some(framing(0.0, 1.0))
    );
}

#[tokio::test]
async fn an_unknown_display_or_wallpaper_is_an_error_and_saves_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let file = wallpaper_file(root.path());
    let saved = std::fs::read(&file).unwrap();

    let display = bridge
        .set_display_position("100".into(), "99".into(), Some(0.1), Some(0.1))
        .await
        .unwrap_err();
    let wallpaper = bridge
        .set_display_position("404".into(), "1".into(), Some(0.1), Some(0.1))
        .await
        .unwrap_err();

    assert_eq!(display.kind(), BridgeErrorKind::InvalidInput);
    assert_eq!(wallpaper.kind(), BridgeErrorKind::InvalidInput);
    assert!(engine.framing_calls().is_empty());
    assert_eq!(std::fs::read(&file).unwrap(), saved);
    assert!(!root.path().join("wallpapers").join("404.json").exists());
}

#[tokio::test]
async fn a_position_is_not_a_draft_so_cancel_keeps_it_and_apply_does_not_reopen() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();

    // An unapplied scale factor is still a draft, and Cancel still undoes it.
    bridge
        .edit_scaling_factor("100".into(), "1".into(), 1.5)
        .await
        .unwrap();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();
    bridge.cancel_wallpaper_options("100".into()).await.unwrap();

    assert_eq!(
        engine.scaling_factor_calls().last().map(|call| call.1),
        Some(1.0),
        "Cancel put the live scale factor back"
    );
    assert_eq!(
        engine.framing_calls().len(),
        1,
        "and left the position alone"
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
    assert!((on_display(&scenes, 1).scaling_factor - 1.0).abs() <= f64::EPSILON);

    // With nothing else pending, Apply has no scene to reopen.
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.calls().len(), reconciles);
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn applying_another_change_opens_the_scene_at_the_position() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let mut snapshot = running(&engine.rendered_scenes());
    snapshot.push(identified_display(2));
    engine.set_snapshot(snapshot);
    let reconciles = engine.calls().len();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    // Showing the wallpaper on a second display is a change Apply must carry
    // out, and it rebuilds the scenes from the saved config.
    bridge
        .set_display_config_enabled("100".into(), "2".into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();

    assert_eq!(engine.calls().len(), reconciles + 1);
    let reopened = engine.calls().pop().unwrap();
    assert_eq!(on_display(&reopened, 1).framing, framing(0.2, 0.8));
    assert_eq!(on_display(&reopened, 2).framing, SceneFraming::default());
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn a_renderer_that_refuses_the_move_still_leaves_it_saved_for_the_next_reconcile() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let reconciles = engine.calls().len();
    engine.fail_next_framing();

    let error = move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap_err();

    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(
        on_display(&scenes, 1).framing,
        framing(0.2, 0.8),
        "the choice was kept"
    );
    // The running scene is still where it was, so the next reconcile does not
    // find it matching and builds it at the saved position.
    bridge.refresh_displays().await.unwrap();
    assert_eq!(engine.calls().len(), reconciles + 1);
    let reopened = engine.calls().pop().unwrap();
    assert_eq!(on_display(&reopened, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn a_position_that_could_not_be_saved_is_saved_when_asked_for_again() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    // A file where the wallpapers folder should be: nothing can be written.
    let folder = root.path().join("wallpapers");
    std::fs::remove_dir_all(&folder).unwrap();
    std::fs::write(&folder, b"not a folder").unwrap();

    let error = move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap_err();

    assert_ne!(error.kind(), BridgeErrorKind::InvalidInput);
    assert!(
        engine.framing_calls().is_empty(),
        "nothing was kept, so nothing moved"
    );

    std::fs::remove_file(&folder).unwrap();
    move_to(&bridge, Some(0.2), Some(0.8)).await.unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(1), framing(0.2, 0.8))]
    );
    let scenes = scenes_after_restart(root.path(), &[1]).await;
    assert_eq!(on_display(&scenes, 1).framing, framing(0.2, 0.8));
}

#[tokio::test]
async fn each_display_keeps_its_own_position() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1, 2]).await;

    bridge
        .set_display_position("100".into(), "2".into(), Some(0.0), Some(1.0))
        .await
        .unwrap();

    assert_eq!(
        engine.framing_calls(),
        vec![(SceneHandle::new(2), framing(0.0, 1.0))],
        "only the scene on that display moves"
    );
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 2).framing, framing(0.0, 1.0));
    assert_eq!(
        on_display(&scenes, 1).framing,
        SceneFraming::default(),
        "the other display stays centred"
    );
}

#[tokio::test]
async fn a_wallpaper_nobody_shows_can_still_be_positioned_for_later() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1, 2]).await;
    bridge
        .set_display_config_enabled("100".into(), "2".into(), false)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    assert_eq!(engine.rendered_scenes().len(), 1);
    let mut snapshot = running(&engine.rendered_scenes());
    snapshot.push(identified_display(2));
    engine.set_snapshot(snapshot);

    bridge
        .set_display_position("100".into(), "2".into(), Some(0.9), None)
        .await
        .unwrap();

    assert!(
        engine.framing_calls().is_empty(),
        "no scene runs there, so there is nobody to tell"
    );
    bridge
        .set_display_config_enabled("100".into(), "2".into(), true)
        .await
        .unwrap();
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();
    let reopened = engine.rendered_scenes();
    assert_eq!(on_display(&reopened, 2).framing, framing(0.9, 0.5));
    let scenes = scenes_after_restart(root.path(), &[1, 2]).await;
    assert_eq!(on_display(&scenes, 2).framing, framing(0.9, 0.5));
}
