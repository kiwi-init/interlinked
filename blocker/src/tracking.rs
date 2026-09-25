//! Tracking parameters removed from every page address before it is requested,
//! whether or not content blocking is on. Names compare without case.

use url::{form_urlencoded, Url};

/// Parameters that only identify a click, campaign, or recipient.
const NAMES: &[&str] = &[
    // Google
    "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "gad_source", "gad_campaignid", "srsltid", "_ga", "_gl",
    // Meta
    "fbclid", "igshid", "igsh",
    // Microsoft
    "msclkid",
    // X
    "twclid",
    // TikTok
    "ttclid",
    // LinkedIn
    "li_fat_id",
    // Pinterest
    "epik",
    // Snapchat
    "sccid",
    // Reddit
    "rdt_cid",
    // Yandex
    "yclid", "ysclid", "_openstat",
    // Taboola
    "tblci",
    // Impact
    "irclickid",
    // Adobe
    "s_cid", "s_kwcid", "ef_id",
    // AT Internet
    "xtor",
    // Mailchimp
    "mc_cid", "mc_eid",
    // HubSpot
    "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
    // Marketo
    "mkt_tok",
    // Klaviyo
    "_kx",
    // Drip
    "__s",
    // MailerLite
    "ml_subscriber", "ml_subscriber_hash",
    // ActiveCampaign
    "vgo_ee",
    // Bronto
    "_bta_tid", "_bta_c",
    // Omeda
    "oly_anon_id", "oly_enc_id",
    // Vero
    "vero_id", "vero_conv",
    // Wicked Reports
    "wickedid",
    // Rockerbox
    "rb_clickid",
    // Branch
    "_branch_match_id", "_branch_referrer",
    // Matomo
    "pk_campaign", "pk_kwd", "pk_keyword", "pk_source", "pk_medium", "pk_content", "pk_cid",
    "mtm_campaign", "mtm_keyword", "mtm_source", "mtm_medium", "mtm_content", "mtm_cid", "mtm_group", "mtm_placement",
];

/// utm_source, utm_medium, utm_campaign, and the rest; HubSpot ad parameters.
const PREFIXES: &[&str] = &["utm_", "hsa_"];

/// Share identifiers that are ordinary words elsewhere, so only these sites lose them.
const SITE_NAMES: &[(&str, &[&str])] = &[
    ("youtube.com", &["si"]),
    ("youtu.be", &["si"]),
    ("spotify.com", &["si"]),
    ("x.com", &["s", "t", "ref_src", "ref_url"]),
    ("twitter.com", &["s", "t", "ref_src", "ref_url"]),
];

fn on_site(host: &str, site: &str) -> bool {
    host == site || host.strip_suffix(site).is_some_and(|rest| rest.ends_with('.'))
}

fn is_tracking(name: &str, host: &str) -> bool {
    let name = name.to_ascii_lowercase();
    NAMES.contains(&name.as_str())
        || PREFIXES.iter().any(|prefix| name.starts_with(prefix))
        || SITE_NAMES.iter().any(|(site, names)| on_site(host, site) && names.contains(&name.as_str()))
}

/// The address without tracking parameters, or None when it has none.
/// Every other parameter keeps its exact spelling, encoding, and order.
pub fn strip(address: &str) -> Option<String> {
    let mut url = Url::parse(address).ok()?;
    if !matches!(url.scheme(), "http" | "https") {
        return None;
    }
    let host = url.host_str()?.to_ascii_lowercase();
    let query = url.query()?.to_owned();
    let pairs: Vec<&str> = query.split('&').collect();
    let kept: Vec<&str> = pairs
        .iter()
        .copied()
        .filter(|pair| {
            let (name, _) = form_urlencoded::parse(pair.as_bytes()).next().unwrap_or_default();
            !is_tracking(&name, &host)
        })
        .collect();
    if kept.len() == pairs.len() {
        return None;
    }
    let kept = kept.into_iter().filter(|pair| !pair.is_empty()).collect::<Vec<_>>().join("&");
    url.set_query(if kept.is_empty() { None } else { Some(&kept) });
    Some(url.into())
}

#[cfg(test)]
mod tests {
    use super::strip;

    #[test]
    fn removes_campaign_and_click_parameters() {
        assert_eq!(
            strip("https://shop.example/item?utm_source=news&id=5&gclid=abc&UTM_Campaign=x&fbclid=1#reviews").as_deref(),
            Some("https://shop.example/item?id=5#reviews")
        );
    }

    #[test]
    fn drops_the_question_mark_when_nothing_is_left() {
        assert_eq!(
            strip("https://news.example/story?utm_medium=email&mc_eid=9").as_deref(),
            Some("https://news.example/story")
        );
    }

    #[test]
    fn keeps_other_parameters_exactly() {
        assert_eq!(
            strip("https://search.example/?q=a%20b+c&utm_term=x&empty&dup=1&dup=2").as_deref(),
            Some("https://search.example/?q=a%20b+c&empty&dup=1&dup=2")
        );
    }

    #[test]
    fn leaves_clean_and_non_web_addresses_alone() {
        assert_eq!(strip("https://example.com/?id=1&ref=main"), None);
        assert_eq!(strip("https://example.com/#utm_source=x"), None);
        assert_eq!(strip("about:blank"), None);
        assert_eq!(strip("file:///tmp/a.html?utm_source=x"), None);
    }

    #[test]
    fn site_specific_names_apply_only_on_that_site() {
        assert_eq!(
            strip("https://www.youtube.com/watch?v=abc&si=share&t=42").as_deref(),
            Some("https://www.youtube.com/watch?v=abc&t=42")
        );
        assert_eq!(strip("https://x.com/user/status/1?s=20&t=xyz").as_deref(), Some("https://x.com/user/status/1"));
        assert_eq!(strip("https://example.com/?si=1&s=2&t=3"), None);
        assert_eq!(strip("https://notx.com/?s=1"), None);
    }

    #[test]
    fn recognizes_encoded_names() {
        assert_eq!(strip("https://example.com/?utm%5Fsource=x&a=1").as_deref(), Some("https://example.com/?a=1"));
    }
}
