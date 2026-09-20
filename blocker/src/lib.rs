//! C interface to Brave's adblock engine for Interlinked's built-in blocker.
//! Every function is safe to call from any thread; an engine is immutable once
//! built, so Chromium's network thread and the main thread share it freely.

use adblock::lists::{FilterSet, ParseOptions};
use adblock::request::Request;
use adblock::resources::{PermissionMask, Resource};
use adblock::Engine;
use std::collections::HashSet;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

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
    let result = (*blocker).engine.check_network_request(&request);
    let block = result.should_block();
    if let Some(redirect) = result.redirect {
        *detail = give(redirect);
        return IL_REDIRECT;
    }
    if block {
        return IL_BLOCK;
    }
    if let Some(rewritten) = result.rewritten_url {
        *detail = give(rewritten);
        return IL_REWRITE;
    }
    IL_ALLOW
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
