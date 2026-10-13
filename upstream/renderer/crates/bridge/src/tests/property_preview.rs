//! A wallpaper's pending property edits, shown on the scenes that draw it
//! without being applied.
//!
//! The renderer is the fake engine, so what these tests establish is what the
//! bridge asks of the engine and what it keeps; how a scene looks when the
//! document arrives is the renderer's business and is covered there.

use std::{sync::Arc, time::Duration};

use wallpaper_core::project::SceneHandle;

use super::display_position::{identified_display, new_engine, running};
use crate::{
    BridgeDisplayMode, BridgeErrorKind, BridgePropertyValue, WallpaperBridge,
    api::BridgeBuilder,
    config::ConfigStore,
    engine::{EngineFacade as _, FakeEngineFacade},
};

/// One property of every kind a panel offers, and a shortcut whose default the
/// host supplies, so that the saved document is never empty.
const SCENE: &str = r#"{
    "type":"scene",
    "title":"Scene",
    "file":"scene.pkg",
    "general":{"properties":{
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1,"order":1},
        "glow":{"type":"bool","text":"Glow","value":false,"order":2},
        "tint":{"type":"color","text":"Tint","value":"1 1 1","order":3},
        "mode":{"type":"combo","text":"Mode","value":"a",
                "options":[{"label":"A","value":"a"},{"label":"B","value":"b"}],"order":4},
        "label":{"type":"textinput","text":"Label","value":"","order":5},
        "picture":{"type":"scenetexture","text":"Picture","value":"","order":6},
        "clip":{"type":"file","text":"Clip","value":"","order":7},
        "folder":{"type":"directory","text":"Folder","value":"","order":8},
        "playpausebutton":{"type":"usershortcut","text":"Play","value":"","order":9}
    }}
}"#;

const VIDEO: &str = r#"{
    "type":"video",
    "title":"Clip",
    "file":"clip.mp4",
    "general":{"properties":{
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1,"order":1}
    }}
}"#;

const WEB: &str = r#"{
    "type":"web",
    "title":"Web",
    "file":"index.html",
    "general":{"properties":{
        "alpha":{"type":"slider","text":"Alpha","value":1,"min":0,"max":1,"order":1}
    }}
}"#;

/// What the saved configuration loads the scene with: the host's own default
/// and nothing the user chose.
const SAVED: &str = r#"{"playpausebutton":"media:playpause"}"#;

fn bridge_over(engine: &FakeEngineFacade, root: &tempfile::TempDir) -> WallpaperBridge {
    BridgeBuilder::new(engine.clone())
        .with_config_store(ConfigStore::open(root.path().to_path_buf()))
        .with_mouse_polling_enabled(false)
        .with_power_watching_enabled(false)
        .build()
        .expect("tokio runtime and config load for wallpaper bridge")
}

/// `project` as wallpaper `id`, applied to each of `display_ids` through the
/// calls the panel makes, and running: the fake hands out handles by position.
async fn show_wallpaper(
    bridge: &WallpaperBridge,
    engine: &FakeEngineFacade,
    id: &str,
    project: &str,
    display_ids: &[u32],
) {
    bridge
        .inject_scene_project_for_test(id, "Wallpaper", project)
        .await;
    for display in display_ids {
        bridge
            .set_display_config_enabled(id.into(), display.to_string(), true)
            .await
            .unwrap();
    }
    bridge
        .apply_wallpaper_options(id.into(), true)
        .await
        .unwrap();
    // Every display stays, and the ones that run a scene hold its handle.
    let mut snapshot = running(&engine.rendered_scenes());
    for entry in engine.display_snapshot() {
        if !snapshot
            .iter()
            .any(|running| running.desc.display_id == entry.desc.display_id)
        {
            snapshot.push(identified_display(entry.desc.display_id));
        }
    }
    engine.set_snapshot(snapshot);
}

/// The scene wallpaper `100` on each of `display_ids`.
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
    let bridge = bridge_over(engine, &root);
    show_wallpaper(&bridge, engine, "100", SCENE, display_ids).await;
    assert_eq!(engine.rendered_scenes().len(), display_ids.len());
    (bridge, root)
}

/// The scene of display `display_id`, which the fake has handed a handle.
fn handle_of(engine: &FakeEngineFacade, display_id: u32) -> SceneHandle {
    engine
        .display_snapshot()
        .iter()
        .find(|entry| entry.desc.display_id == display_id)
        .and_then(|entry| entry.handle)
        .unwrap_or_else(|| panic!("no scene on display {display_id}"))
}

fn number(value: f64) -> BridgePropertyValue {
    BridgePropertyValue::Number { value }
}

fn text(value: &str) -> BridgePropertyValue {
    BridgePropertyValue::String {
        value: value.into(),
    }
}

async fn edit(bridge: &WallpaperBridge, property: &str, value: BridgePropertyValue) {
    bridge
        .edit_property("100".into(), property.into(), value)
        .await
        .unwrap();
}

async fn show(bridge: &WallpaperBridge) -> Result<(), crate::BridgeError> {
    bridge.preview_wallpaper_properties("100".into(), true).await
}

async fn show_saved(bridge: &WallpaperBridge) -> Result<(), crate::BridgeError> {
    bridge
        .preview_wallpaper_properties("100".into(), false)
        .await
}

async fn is_dirty(bridge: &WallpaperBridge) -> bool {
    bridge
        .wallpaper_options_snapshot("100".into())
        .await
        .unwrap()
        .dirty
}

/// The documents the engine was asked to show, as text, in order.
fn documents(engine: &FakeEngineFacade) -> Vec<String> {
    engine
        .preview_property_calls()
        .into_iter()
        .map(|(_, document)| document)
        .collect()
}

fn json(document: &str) -> serde_json::Value {
    serde_json::from_str(document).expect("the engine is only ever handed JSON")
}

#[tokio::test]
async fn a_pending_edit_reaches_every_scene_that_draws_the_wallpaper_and_saves_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1, 2, 3]).await;
    // Display 3 shows what display 1 shows, with a scene of its own.
    bridge
        .set_display_mode("3".into(), BridgeDisplayMode::Mirror)
        .await
        .unwrap();
    bridge
        .set_mirror_target("3".into(), "1".into())
        .await
        .unwrap();
    engine.set_snapshot(running(&engine.rendered_scenes()));
    assert_eq!(engine.rendered_scenes().len(), 3);
    let reconciles = engine.calls().len();
    let exported = bridge.lock_screen_scenes().await.unwrap();
    let file = root.path().join("wallpapers").join("100.json");
    std::fs::remove_file(&file).ok();

    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();

    let calls = engine.preview_property_calls();
    assert_eq!(calls.len(), 3, "one document for each scene that draws it");
    for display in [1, 2, 3] {
        assert!(
            calls.contains(&(
                handle_of(&engine, display),
                r#"{"alpha":0.5,"playpausebutton":"media:playpause"}"#.to_string()
            )),
            "display {display} is told the whole document: {calls:?}"
        );
    }
    assert!(!file.exists(), "nothing is written");
    assert_eq!(
        bridge.lock_screen_scenes().await.unwrap(),
        exported,
        "the lock screen follows what is saved"
    );
    assert!(is_dirty(&bridge).await, "the edit is still pending");
    bridge.refresh_displays().await.unwrap();
    assert_eq!(
        engine.calls().len(),
        reconciles,
        "an edit that was never applied leaves nothing for a reconcile to rebuild"
    );
}

#[tokio::test]
async fn the_document_is_the_one_apply_loads_down_to_the_byte() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    edit(&bridge, "alpha", number(0.25)).await;
    edit(&bridge, "glow", BridgePropertyValue::Bool { value: true }).await;
    edit(
        &bridge,
        "tint",
        BridgePropertyValue::ColorRgb {
            red: 0.5,
            green: 0.25,
            blue: 0.75,
        },
    )
    .await;
    edit(&bridge, "mode", text("b")).await;
    edit(&bridge, "label", text("hello \"there\"")).await;

    show(&bridge).await.unwrap();
    let shown = documents(&engine).pop().expect("a document was shown");
    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();

    let loaded = engine
        .rendered_scenes()
        .last()
        .and_then(|scene| scene.property_override_json.clone())
        .expect("Apply loads the edits");
    assert_eq!(shown, loaded);
    let parsed = json(&shown);
    assert_eq!(parsed["alpha"], 0.25);
    assert_eq!(parsed["glow"], true);
    assert_eq!(parsed["mode"], "b");
    assert_eq!(parsed["label"], "hello \"there\"");
}

#[tokio::test]
async fn the_payload_is_the_whole_draft_so_reset_and_restore_all_defaults_send_the_saved_payload()
{
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    assert_eq!(
        engine.rendered_scenes()[0].property_override_json.as_deref(),
        Some(SAVED),
        "the saved document is what the scene was opened with"
    );

    edit(&bridge, "alpha", number(0.5)).await;
    edit(&bridge, "glow", BridgePropertyValue::Bool { value: true }).await;
    show(&bridge).await.unwrap();
    bridge
        .restore_property_default("100".into(), "alpha".into())
        .await
        .unwrap();
    show(&bridge).await.unwrap();
    assert_eq!(
        documents(&engine),
        vec![
            r#"{"alpha":0.5,"glow":true,"playpausebutton":"media:playpause"}"#.to_string(),
            r#"{"glow":true,"playpausebutton":"media:playpause"}"#.to_string(),
        ],
        "a property the draft no longer holds is back at its authored default, \
         not left at the last value shown"
    );

    edit(&bridge, "mode", text("b")).await;
    bridge
        .restore_all_property_defaults("100".into())
        .await
        .unwrap();
    show(&bridge).await.unwrap();
    assert_eq!(
        documents(&engine).last().map(String::as_str),
        Some(SAVED),
        "everything restored is exactly what a scene is opened with"
    );
    let sent = engine.preview_property_calls().len();
    show(&bridge).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        sent,
        "the scenes show their saved look again, so asking for it sends nothing"
    );
    assert!(!is_dirty(&bridge).await);
}

#[tokio::test]
async fn pictures_and_files_wait_for_apply() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;

    edit(&bridge, "picture", text("pending.png")).await;
    show(&bridge).await.unwrap();
    assert!(
        engine.preview_property_calls().is_empty(),
        "a texture is read only while a scene loads, so there is nothing to show"
    );

    // A file is saved the moment it is picked, so it is part of what is saved
    // and of any document shown after it, but picking it shows nothing by
    // itself.
    bridge
        .set_property_path("100".into(), "clip".into(), Some("/picked/clip.mp4".into()))
        .await
        .unwrap();
    show(&bridge).await.unwrap();
    assert!(engine.preview_property_calls().is_empty());

    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    assert_eq!(
        documents(&engine),
        vec![
            r#"{"alpha":0.5,"clip":"/picked/clip.mp4","playpausebutton":"media:playpause"}"#
                .to_string()
        ],
        "the pending texture stays out, the saved file stays in"
    );
    assert!(
        is_dirty(&bridge).await,
        "the texture and the slider are still pending"
    );
}

#[tokio::test]
async fn revert_restores_the_saved_look_on_the_scenes_it_was_shown_on_and_a_second_revert_sends_nothing()
{
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1, 2]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 2);

    bridge.cancel_wallpaper_options("100".into()).await.unwrap();

    let calls = engine.preview_property_calls();
    assert_eq!(calls.len(), 4, "every scene that was shown the edit");
    for display in [1, 2] {
        assert_eq!(
            calls.iter().rfind(|call| call.0 == handle_of(&engine, display)),
            Some(&(handle_of(&engine, display), SAVED.to_string())),
            "display {display} is back to what is saved"
        );
    }
    assert!(!is_dirty(&bridge).await);

    bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        4,
        "a scene that shows its saved look is not told again"
    );

    edit(&bridge, "glow", BridgePropertyValue::Bool { value: true }).await;
    bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        4,
        "an edit that was never shown has nothing to take back"
    );
}

#[tokio::test]
async fn an_identical_payload_is_not_sent_twice_and_an_untouched_wallpaper_sends_nothing() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;

    show(&bridge).await.unwrap();
    show_saved(&bridge).await.unwrap();
    assert!(
        engine.preview_property_calls().is_empty(),
        "an untouched wallpaper shows its saved look already"
    );

    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 1);

    // A texture changes the draft and not the document.
    edit(&bridge, "picture", text("pending.png")).await;
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 1);

    edit(&bridge, "alpha", number(0.25)).await;
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 2);

    // Dragging back to the authored value is the saved look again, which the
    // scene is still showing the last step of.
    edit(&bridge, "alpha", number(1.0)).await;
    show(&bridge).await.unwrap();
    assert_eq!(
        documents(&engine).last().map(String::as_str),
        Some(SAVED),
        "the saved look is put back"
    );
    assert_eq!(engine.preview_property_calls().len(), 3);
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 3);
}

#[tokio::test]
async fn show_false_restores_without_touching_the_draft() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();

    show_saved(&bridge).await.unwrap();

    assert_eq!(documents(&engine).last().map(String::as_str), Some(SAVED));
    assert!(is_dirty(&bridge).await, "the edit is still pending");
    let options = bridge
        .wallpaper_options_snapshot("100".into())
        .await
        .unwrap();
    let alpha = options
        .properties
        .iter()
        .find(|property| property.id == "alpha")
        .unwrap();
    assert_eq!(alpha.value, number(0.5));

    show_saved(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 2);

    show(&bridge).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        3,
        "the edit can be shown again"
    );
}

#[tokio::test]
async fn apply_clears_the_mark_and_a_later_revert_does_not_touch_the_rebuilt_scene() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    let reconciles = engine.calls().len();

    bridge
        .apply_wallpaper_options("100".into(), true)
        .await
        .unwrap();

    assert!(engine.calls().len() > reconciles, "Apply loads the scene again");
    assert_eq!(
        engine
            .rendered_scenes()
            .last()
            .and_then(|scene| scene.property_override_json.clone())
            .as_deref(),
        documents(&engine).last().map(String::as_str),
    );
    bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        1,
        "the rebuilt scene never showed a preview, so there is nothing to take back"
    );
}

#[tokio::test]
async fn a_reconcile_makes_the_last_document_untrustworthy_so_it_is_sent_again() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1, 2]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    assert_eq!(engine.preview_property_calls().len(), 2);

    // Whether the engine kept the scenes or opened them again is not known to
    // the bridge.
    bridge.set_display_enabled("2".into(), false).await.unwrap();
    show(&bridge).await.unwrap();
    let after = engine.preview_property_calls().len();
    assert!(
        after > 2,
        "the document is sent again to the scene that still draws the wallpaper"
    );

    // And a scene that may be showing an edit is put back when that is asked,
    // even if the bridge no longer knows what it showed.
    bridge.set_display_enabled("1".into(), true).await.unwrap();
    show_saved(&bridge).await.unwrap();
    assert_eq!(documents(&engine).last().map(String::as_str), Some(SAVED));
}

#[tokio::test]
async fn a_refused_update_surfaces_and_leaves_the_call_to_be_repeated() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    engine.fail_next_property_preview();

    let error = show(&bridge).await.unwrap_err();
    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    show(&bridge).await.unwrap();

    assert_eq!(
        engine.preview_property_calls().len(),
        2,
        "the first update never took, so the same document is sent again"
    );
}

#[tokio::test]
async fn a_failed_restore_keeps_the_draft_and_the_mark() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    engine.fail_next_property_preview();

    let error = bridge
        .cancel_wallpaper_options("100".into())
        .await
        .unwrap_err();

    assert_eq!(error.kind(), BridgeErrorKind::Engine);
    assert!(
        is_dirty(&bridge).await,
        "the draft is kept so that Revert can be asked again"
    );

    bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    assert!(!is_dirty(&bridge).await);
    assert_eq!(
        engine.preview_property_calls().len(),
        3,
        "shown, refused, then put back"
    );
    assert_eq!(documents(&engine).last().map(String::as_str), Some(SAVED));
}

#[tokio::test]
async fn a_wallpaper_no_display_shows_a_video_and_a_web_wallpaper_are_silent() {
    let (engine, _release) = new_engine();
    let root = tempfile::tempdir().unwrap();
    engine.set_snapshot(vec![identified_display(1), identified_display(2)]);
    let bridge = bridge_over(&engine, &root);
    // The scene is known but shown nowhere.
    bridge
        .inject_scene_project_for_test("100", "Scene", SCENE)
        .await;
    edit(&bridge, "alpha", number(0.5)).await;
    show(&bridge).await.unwrap();
    show_saved(&bridge).await.unwrap();

    // A video the scene engine plays has a scene, and a property document does
    // not reach a plain video.
    show_wallpaper(&bridge, &engine, "400", VIDEO, &[1]).await;
    assert_eq!(engine.rendered_scenes().len(), 1);
    bridge
        .edit_property("400".into(), "alpha".into(), number(0.5))
        .await
        .unwrap();
    bridge
        .preview_wallpaper_properties("400".into(), true)
        .await
        .unwrap();

    // A web page is drawn by the host, never by the engine.
    show_wallpaper(&bridge, &engine, "300", WEB, &[2]).await;
    bridge
        .edit_property("300".into(), "alpha".into(), number(0.5))
        .await
        .unwrap();
    bridge
        .preview_wallpaper_properties("300".into(), true)
        .await
        .unwrap();

    assert!(
        engine.preview_property_calls().is_empty(),
        "there was nothing to show: {:?}",
        engine.preview_property_calls()
    );
}

#[tokio::test]
async fn unknown_wallpaper_is_refused() {
    let (engine, _release) = new_engine();
    let (bridge, _root) = shown_on(&engine, &[1]).await;

    for show in [true, false] {
        let error = bridge
            .preview_wallpaper_properties("404".into(), show)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), BridgeErrorKind::InvalidInput);
    }
    assert!(engine.preview_property_calls().is_empty());
}

#[tokio::test]
async fn a_preview_while_an_apply_is_loading_does_not_make_the_apply_stale() {
    let (engine, _release) = new_engine();
    let (bridge, root) = shown_on(&engine, &[1]).await;
    let bridge = Arc::new(bridge);
    edit(&bridge, "alpha", number(0.5)).await;

    let gate = engine.block_next_reconcile();
    let applying = bridge.clone();
    let job = std::thread::spawn(move || {
        tokio::runtime::Runtime::new()
            .unwrap()
            .block_on(applying.apply_wallpaper_options("100".into(), true))
    });
    assert!(gate.wait_until_blocked(Duration::from_secs(2)));

    // A step that lands while the scene is being opened again.
    show(&bridge).await.unwrap();
    gate.release();
    job.join().unwrap().unwrap();

    assert!(
        !is_dirty(&bridge).await,
        "the apply committed: a preview does not advance the generation"
    );
    assert!(
        std::fs::read_to_string(root.path().join("wallpapers").join("100.json"))
            .unwrap()
            .contains("0.5"),
        "and what it applied is saved"
    );
    let sent = engine.preview_property_calls().len();
    bridge.cancel_wallpaper_options("100".into()).await.unwrap();
    assert_eq!(
        engine.preview_property_calls().len(),
        sent,
        "the scene was opened again from the saved configuration"
    );
}
