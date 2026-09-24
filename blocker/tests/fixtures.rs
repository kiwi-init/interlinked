//! Checks what the engine makes of test-fixtures/blocker-filters.txt, the list
//! the UI tests load in place of the standard lists. Needs no network.
//! IL_UPDATE_FIXTURES=1 rewrites test-fixtures/blocker-procedural.json.
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::Resource;
use adblock::Engine;
use std::path::PathBuf;

fn repository(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join(path)
}

fn engine() -> Engine {
    let mut set = FilterSet::new(false);
    let list = std::fs::read_to_string(repository("test-fixtures/blocker-filters.txt")).unwrap();
    set.add_filter_list(list, ParseOptions::default());
    let mut engine = Engine::new_with_filter_set(set);
    let resources = std::fs::read_to_string(repository("Interlinked/Resources/blocker-resources.json")).unwrap();
    engine.use_resources(serde_json::from_str::<Vec<Resource>>(&resources).unwrap());
    engine
}

fn procedural(engine: &Engine, url: &str) -> Vec<String> {
    let mut actions: Vec<String> = engine.url_cosmetic_resources(url).procedural_actions.into_iter().collect();
    actions.sort();
    actions
}

/// The cosmetics script test (InterlinkedTests/BlockerCosmeticsTests.swift)
/// replays this JSON, so the engine and the script are tested end to end.
#[test]
fn procedural_filters_match_the_script_fixture() {
    let actions = procedural(&engine(), "http://127.0.0.1:8765/blocker/procedural");
    let path = repository("test-fixtures/blocker-procedural.json");
    if std::env::var_os("IL_UPDATE_FIXTURES").is_some() {
        std::fs::write(&path, serde_json::to_string_pretty(&actions).unwrap() + "\n").unwrap();
    }
    let expected: Vec<String> = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(actions, expected);
}

#[test]
fn procedural_exceptions_remove_the_rule() {
    let actions = procedural(&engine(), "http://127.0.0.1:8765/blocker/procedural");
    assert!(actions.iter().any(|action| action.contains("Sponsored")));
    assert!(!actions.iter().any(|action| action.contains("Excepted")), "{actions:?}");
}

#[test]
fn procedural_filters_stay_on_their_site() {
    assert!(procedural(&engine(), "http://localhost:8765/blocker/procedural").is_empty());
}

#[test]
fn redirect_destination_has_its_own_rules() {
    let engine = engine();
    let destination = engine.url_cosmetic_resources("http://localhost:8765/blocker/redirected");
    assert!(destination.hide_selectors.contains(".redirect-ad"));
    assert!(destination.injected_script.contains("interlinkedFixtureScriptlet"));
    let origin = engine.url_cosmetic_resources("http://127.0.0.1:8765/blocker/redirect");
    assert!(!origin.hide_selectors.contains(".redirect-ad"));
    assert!(!origin.injected_script.contains("interlinkedFixtureScriptlet"));
}

#[test]
fn removeparam_strips_the_tracking_parameter() {
    let url = "http://127.0.0.1:8765/blocker/removeparam?gclid=fixture&keep=1";
    let result = engine().check_network_request(&Request::new(url, url, "document", "GET").unwrap());
    assert!(!result.should_block());
    assert_eq!(result.rewritten_url.as_deref(), Some("http://127.0.0.1:8765/blocker/removeparam?keep=1"));
}
