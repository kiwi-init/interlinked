//! C interface to Brave's adblock engine for Interlinked's built-in blocker.
//! Every function is safe to call from any thread; an engine is immutable once
//! built, so Chromium's network thread and the main thread share it freely.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use adblock::blocker::BlockerResult;
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

mod tracking;

pub struct Blocker {
    engine: Engine,
}

const _: fn() = || {
    fn shared<T: Send + Sync>() {}
    shared::<Blocker>();
};

/// Trusted lists may use scriptlets that rewrite network responses.
const TRUSTED: PermissionMask = PermissionMask::from_bits(1);

unsafe fn text<'a>(pointer: *const c_char) -> &'a str {
    if pointer.is_null() {
        return "";
    }
    CStr::from_ptr(pointer).to_str().unwrap_or("")
}

fn give(value: String) -> *mut c_char {
    CString::new(value).map(CString::into_raw).unwrap_or(ptr::null_mut())
}

fn resources(json: &str) -> Vec<Resource> {
    serde_json::from_str(json).unwrap_or_default()
}

#[no_mangle]
pub extern "C" fn il_filters_new() -> *mut FilterSet {
    Box::into_raw(Box::new(FilterSet::new(false)))
}

/// # Safety
/// `filters` comes from `il_filters_new`; `list` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn il_filters_add(filters: *mut FilterSet, list: *const c_char, trusted: bool) {
    let options = ParseOptions {
        permissions: if trusted { TRUSTED } else { PermissionMask::default() },
        ..ParseOptions::default()
    };
    (*filters).add_filter_list(text(list).to_owned(), options);
}

/// Consumes `filters`.
/// # Safety
/// `filters` comes from `il_filters_new` and is not used again.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_new(filters: *mut FilterSet, resources_json: *const c_char) -> *mut Blocker {
    let mut engine = Engine::new_with_filter_set(*Box::from_raw(filters));
    engine.use_resources(resources(text(resources_json)));
    Box::into_raw(Box::new(Blocker { engine }))
}

/// # Safety
/// `data` points to `length` bytes written by `il_blocker_serialize`.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_restore(data: *const u8, length: usize, resources_json: *const c_char) -> *mut Blocker {
    let mut engine = Engine::default();
    if data.is_null() || engine.deserialize(std::slice::from_raw_parts(data, length)).is_err() {
        return ptr::null_mut();
    }
    engine.use_resources(resources(text(resources_json)));
    Box::into_raw(Box::new(Blocker { engine }))
}

/// Writes the engine to a buffer released with `il_bytes_free`.
/// # Safety
/// `blocker` is live; `length` is writable.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_serialize(blocker: *const Blocker, length: *mut usize) -> *mut u8 {
    let mut bytes = (*blocker).engine.serialize().into_boxed_slice();
    *length = bytes.len();
    let pointer = bytes.as_mut_ptr();
    std::mem::forget(bytes);
    pointer
}

/// # Safety
/// `data` and `length` come from `il_blocker_serialize`.
#[no_mangle]
pub unsafe extern "C" fn il_bytes_free(data: *mut u8, length: usize) {
    if !data.is_null() {
        drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(data, length)));
    }
}

/// # Safety
/// `blocker` comes from this library and no thread still uses it.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_free(blocker: *mut Blocker) {
    if !blocker.is_null() {
        drop(Box::from_raw(blocker));
    }
}

/// # Safety
/// `value` comes from this library.
#[no_mangle]
pub unsafe extern "C" fn il_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

pub const IL_ALLOW: i32 = 0;
pub const IL_BLOCK: i32 = 1;
/// `detail` is a data: URL to answer the request with.
pub const IL_REDIRECT: i32 = 2;
/// `detail` is the URL to load instead, with tracking parameters removed.
pub const IL_REWRITE: i32 = 3;

/// # Safety
/// Strings are NUL-terminated UTF-8; `detail` is writable and its value is
/// released with `il_string_free`.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_check(
    blocker: *const Blocker,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
    method: *const c_char,
    detail: *mut *mut c_char,
) -> i32 {
    *detail = ptr::null_mut();
    let Ok(request) = Request::new(text(url), text(source_url), text(request_type), text(method)) else {
        return IL_ALLOW;
    };
    let (code, value) = verdict((*blocker).engine.check_network_request(&request));
    if let Some(value) = value {
        *detail = give(value);
    }
    code
}

/// A redirect only answers a request the engine blocks. `redirect-rule`
/// names a stand-in without blocking anything, and an exception still wins.
fn verdict(result: BlockerResult) -> (i32, Option<String>) {
    if result.should_block() {
        return match result.redirect {
            Some(redirect) => (IL_REDIRECT, Some(redirect)),
            None => (IL_BLOCK, None),
        };
    }
    match result.rewritten_url {
        Some(rewritten) => (IL_REWRITE, Some(rewritten)),
        None => (IL_ALLOW, None),
    }
}

/// The page address without tracking parameters, or null when it has none.
/// Independent of any engine. Release the result with `il_string_free`.
/// # Safety
/// `url` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn il_strip_tracking(url: *const c_char) -> *mut c_char {
    tracking::strip(text(url)).map(give).unwrap_or(ptr::null_mut())
}

/// Returns JSON: hide, exceptions, procedural, script, generichide.
/// # Safety
/// `blocker` is live; `url` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_cosmetics(blocker: *const Blocker, url: *const c_char) -> *mut c_char {
    let found = (*blocker).engine.url_cosmetic_resources(text(url));
    give(
        serde_json::json!({
            "hide": found.hide_selectors,
            "exceptions": found.exceptions,
            "procedural": found.procedural_actions,
            "script": found.injected_script,
            "generichide": found.generichide,
        })
        .to_string(),
    )
}

/// Takes JSON with classes, ids, exceptions; returns a JSON array of selectors.
/// # Safety
/// `blocker` is live; `query_json` is NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn il_blocker_generic_selectors(blocker: *const Blocker, query_json: *const c_char) -> *mut c_char {
    let query: serde_json::Value = serde_json::from_str(text(query_json)).unwrap_or_default();
    let strings = |key: &str| -> Vec<String> {
        query[key]
            .as_array()
            .map(|values| values.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
            .unwrap_or_default()
    };
    let exceptions: HashSet<String> = strings("exceptions").into_iter().collect();
    let selectors = (*blocker)
        .engine
        .hidden_class_id_selectors(strings("classes"), strings("ids"), &exceptions);
    give(serde_json::to_string(&selectors).unwrap_or_else(|_| "[]".into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_answers_a_tracking_parameter_with_the_cleaned_url() {
        unsafe {
            let filters = il_filters_new();
            il_filters_add(filters, c"$removeparam=gclid".as_ptr(), false);
            let blocker = il_blocker_new(filters, c"[]".as_ptr());
            let url = c"https://shop.example/item?gclid=x&id=5";
            let mut detail = ptr::null_mut();
            let verdict = il_blocker_check(blocker, url.as_ptr(), url.as_ptr(), c"document".as_ptr(), c"GET".as_ptr(), &mut detail);
            assert_eq!(verdict, IL_REWRITE);
            assert_eq!(CStr::from_ptr(detail).to_str(), Ok("https://shop.example/item?id=5"));
            il_string_free(detail);
            il_blocker_free(blocker);
        }
    }

    /// The verdict for a script request under `rules`, with a noop.js stand-in.
    fn check(rules: &str, url: &str, source: &str) -> i32 {
        let resources = c"[{\"name\":\"noop.js\",\"aliases\":[],\"kind\":{\"mime\":\"application/javascript\"},\"content\":\"KGZ1bmN0aW9uKCl7fSkoKQ==\"}]";
        let rules = CString::new(rules).unwrap();
        let url = CString::new(url).unwrap();
        let source = CString::new(source).unwrap();
        unsafe {
            let filters = il_filters_new();
            il_filters_add(filters, rules.as_ptr(), false);
            let blocker = il_blocker_new(filters, resources.as_ptr());
            let mut detail = ptr::null_mut();
            let verdict = il_blocker_check(blocker, url.as_ptr(), source.as_ptr(), c"script".as_ptr(), c"GET".as_ptr(), &mut detail);
            il_string_free(detail);
            il_blocker_free(blocker);
            verdict
        }
    }

    #[test]
    fn redirect_rule_alone_leaves_the_request_alone() {
        assert_eq!(check("||ads.example/lib.js$redirect-rule=noop.js", "https://ads.example/lib.js", "https://news.example/"), IL_ALLOW);
    }

    #[test]
    fn exception_beats_a_redirecting_block() {
        let rules = "||ads.example/lib.js$redirect=noop.js\n@@||ads.example/lib.js$domain=news.example";
        assert_eq!(check(rules, "https://ads.example/lib.js", "https://news.example/"), IL_ALLOW);
        assert_eq!(check(rules, "https://ads.example/lib.js", "https://other.example/"), IL_REDIRECT);
    }

    #[test]
    fn blocked_request_without_a_stand_in_is_blocked() {
        assert_eq!(check("||ads.example^", "https://ads.example/lib.js", "https://news.example/"), IL_BLOCK);
    }
}
