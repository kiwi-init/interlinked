//! Exercises the engine against downloaded lists. Skipped unless
//! IL_LISTS_DIR points at a folder holding the lists and resources.json.
use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;

#[test]
fn real_lists() {
    let Ok(dir) = std::env::var("IL_LISTS_DIR") else { return };
    let mut set = FilterSet::new(false);
    for (name, trusted) in [("filters.min.txt", true), ("quick-fixes.min.txt", true), ("privacy.min.txt", true),
                            ("unbreak.min.txt", true), ("badware.min.txt", true), ("easylist.txt", false), ("easyprivacy.txt", false)] {
        let text = std::fs::read_to_string(format!("{dir}/{name}")).unwrap();
        let options = ParseOptions { permissions: if trusted { PermissionMask::from_bits(1) } else { PermissionMask::default() }, ..Default::default() };
        set.add_filter_list(text, options);
    }
    let start = std::time::Instant::now();
    let mut engine = Engine::new_with_filter_set(set);
    println!("engine built in {:?}", start.elapsed());
    let resources: Vec<Resource> = serde_json::from_str(&std::fs::read_to_string(format!("{dir}/resources.json")).unwrap()).unwrap();
    println!("resources: {}", resources.len());
    engine.use_resources(resources);
    let bytes = engine.serialize();
    println!("serialized: {} bytes", bytes.len());

    for (url, source, kind) in [
        ("https://securepubads.g.doubleclick.net/tag/js/gpt.js", "https://news.example/", "script"),
        ("https://www.googletagmanager.com/gtm.js?id=GTM-1", "https://news.example/", "script"),
        ("https://www.google-analytics.com/analytics.js", "https://news.example/", "script"),
        ("https://www.youtube.com/pagead/adview?x=1", "https://www.youtube.com/watch?v=1", "xmlhttprequest"),
        ("https://www.youtube.com/youtubei/v1/player/ad_break?x", "https://www.youtube.com/watch?v=1", "xmlhttprequest"),
        ("https://example.org/style.css", "https://news.example/", "stylesheet"),
    ] {
        let r = engine.check_network_request(&Request::new(url, source, kind, "GET").unwrap());
        println!("{:<62} block={} redirect={} rewritten={:?}", url, r.should_block(), r.redirect.as_ref().map(|d| d.len()).unwrap_or(0), r.rewritten_url);
    }
    // uBlock filters – Privacy strips click identifiers such as gclid and
    // fbclid on every site. It leaves utm_* alone, so those URLs stay unchanged.
    for (url, expected) in [
        ("https://shop.example/item?gclid=x&id=5&fbclid=y", Some("https://shop.example/item?id=5")),
        ("https://shop.example/item?utm_source=x&id=5", None),
    ] {
        let r = engine.check_network_request(&Request::new(url, url, "document", "GET").unwrap());
        assert_eq!(r.rewritten_url.as_deref(), expected, "{url}");
    }
    let yt = engine.url_cosmetic_resources("https://www.youtube.com/watch?v=abc");
    println!("youtube: hide={} procedural={} script_len={} generichide={}", yt.hide_selectors.len(), yt.procedural_actions.len(), yt.injected_script.len(), yt.generichide);
    for needle in ["adPlacements", "playerAds", "json-prune", "adSlots"] { println!("  script mentions {needle}: {}", yt.injected_script.contains(needle)); }
    let verge = engine.url_cosmetic_resources("https://www.theverge.com/");
    println!("verge: hide={} script_len={}", verge.hide_selectors.len(), verge.injected_script.len());
    let generic = engine.hidden_class_id_selectors(["ad-banner", "adsbygoogle", "content"], ["google_ads_top"], &verge.exceptions);
    println!("generic selectors for sample classes: {:?}", generic);
}
