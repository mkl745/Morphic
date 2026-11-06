//! # morphic-bridge
//!
//! Thin FFI facade over `morphic-core`. A hand-written C ABI over `dart:ffi` carries a JSON
//! control plane (docs/architecture/02). Only this crate knows about FFI; the engine crates
//! never see it.
//!
//! **M1.1 (task 1.1.4):** the bridge is now *stateful*. Engines are cached per storage root
//! so imported sessions survive between calls, which is what makes `queryPage` and
//! `metricData` execute against canonical Rust state instead of re-parsing the file.
//!
//! Contract: coarse-grained calls, JSON responses, errors as `{"error": "..."}`, and a
//! panic firewall (`catch_unwind`) so a Rust panic becomes a typed error, never a crash.
//! Every returned string MUST be freed by the caller with `morphic_free_string`.
//!
//! See ADR-0014 for why the flutter_rust_bridge migration was deferred rather than silently
//! dropped.

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::{Mutex, OnceLock};

use morphic_core::Engine;

/// Wrap a bridge entry point in the panic firewall and return a heap C string.
fn guarded<F>(f: F) -> *mut c_char
where
    F: FnOnce() -> String + std::panic::UnwindSafe,
{
    let s =
        std::panic::catch_unwind(f).unwrap_or_else(|_| r#"{"error":"internal panic"}"#.to_string());
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => CString::new(r#"{"error":"nul byte in output"}"#)
            .expect("static string has no nul")
            .into_raw(),
    }
}

fn err(msg: &str) -> String {
    serde_json::json!({ "error": msg }).to_string()
}

/// Read a nullable C string into an owned String.
///
/// # Safety
/// `ptr` must be null or a valid, NUL-terminated C string.
unsafe fn cstr(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

/// One cached engine per storage root, so sessions persist across FFI calls.
fn engines() -> &'static Mutex<HashMap<String, Engine>> {
    static ENGINES: OnceLock<Mutex<HashMap<String, Engine>>> = OnceLock::new();
    ENGINES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Run `f` with the engine for `root`, creating it on first use.
fn with_engine<F>(root: &str, f: F) -> String
where
    F: FnOnce(&Engine) -> Result<String, String>,
{
    let mut map = match engines().lock() {
        Ok(m) => m,
        Err(_) => return err("engine registry poisoned"),
    };
    if !map.contains_key(root) {
        match Engine::new(root) {
            Ok(e) => {
                map.insert(root.to_string(), e);
            }
            Err(e) => return err(&e.to_string()),
        }
    }
    match map.get(root) {
        Some(engine) => f(engine).unwrap_or_else(|m| err(&m)),
        None => err("engine disappeared"),
    }
}

fn to_json<T: serde::Serialize>(value: &T) -> Result<String, String> {
    serde_json::to_string(value).map_err(|e| e.to_string())
}

/// Optional progress sink. The pointer is valid only for the duration of the call; the
/// callee must copy anything it wants to keep. May be null.
pub type MorphicProgressFn = extern "C" fn(*const c_char);

/// Engine identity + bridge API version.
#[no_mangle]
pub extern "C" fn morphic_engine_info() -> *mut c_char {
    guarded(|| {
        let info = morphic_core::engine_info();
        serde_json::to_string(&info).unwrap_or_else(|_| err("serialize"))
    })
}

/// Profile CSV bytes entirely in Rust, without creating a session.
///
/// # Safety
/// `data` must point to `len` readable bytes (or be null).
#[no_mangle]
pub unsafe extern "C" fn morphic_profile_csv(data: *const u8, len: usize) -> *mut c_char {
    guarded(|| {
        if data.is_null() {
            return err("null input");
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        match morphic_core::profile_csv_bytes(bytes) {
            Ok(profile) => serde_json::to_string(&profile).unwrap_or_else(|_| err("serialize")),
            Err(e) => err(&e.to_string()),
        }
    })
}

/// Import a file: analyze → compile → validate → persist → open a session.
///
/// Returns `{doc, profile, report}`. `on_progress` may be null.
///
/// # Safety
/// `data` must point to `len` readable bytes; the string pointers must be valid C strings.
/// `on_progress`, if non-null, must be a valid `extern "C"` function that does not unwind.
#[no_mangle]
pub unsafe extern "C" fn morphic_import_csv(
    data: *const u8,
    len: usize,
    storage_root: *const c_char,
    title: *const c_char,
    workspace_id: *const c_char,
    now_iso: *const c_char,
    on_progress: Option<MorphicProgressFn>,
) -> *mut c_char {
    // Retained for the PoC screen and any older caller: force CSV, no extension evidence.
    unsafe {
        morphic_import(
            data,
            len,
            storage_root,
            title,
            workspace_id,
            now_iso,
            c"csv".as_ptr(),
            std::ptr::null(),
            on_progress,
        )
    }
}

/// Import any supported format, detecting it from the content (M1.2 task 1.2.3).
///
/// `format_hint` is a C string (`csv`, `json`, `jsonl`, `log`, `txt`) or null to auto-detect;
/// an unrecognised value is an error, never a silent fall back. `extension` is the source
/// file's extension or null, and is used only when no content probe was decisive.
///
/// Returns `{doc, profile, report}`. `on_progress` may be null.
///
/// # Safety
/// `data` must point to `len` readable bytes; every non-null string pointer must be a valid
/// C string. `on_progress`, if non-null, must be a valid `extern "C"` fn that does not unwind.
#[no_mangle]
// A C ABI boundary: nine scalar parameters is the honest shape here. Collapsing them into a
// repr(C) struct would move the marshalling burden to Dart without removing any of it.
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn morphic_import(
    data: *const u8,
    len: usize,
    storage_root: *const c_char,
    title: *const c_char,
    workspace_id: *const c_char,
    now_iso: *const c_char,
    format_hint: *const c_char,
    extension: *const c_char,
    on_progress: Option<MorphicProgressFn>,
) -> *mut c_char {
    guarded(|| {
        if data.is_null() {
            return err("null input");
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        let title = unsafe { cstr(title) }.unwrap_or_else(|| "Untitled".into());
        let now = unsafe { cstr(now_iso) }.unwrap_or_else(|| "1970-01-01T00:00:00Z".into());
        let hint = unsafe { cstr(format_hint) };
        let ext = unsafe { cstr(extension) };

        with_engine(&root, |engine| {
            let mut sink = |p: morphic_core::ImportProgress| {
                if let Some(cb) = on_progress {
                    if let Ok(json) = serde_json::to_string(&p) {
                        if let Ok(cs) = CString::new(json) {
                            cb(cs.as_ptr());
                        }
                    }
                }
            };
            let outcome = engine
                .import(
                    morphic_core::ImportRequest {
                        bytes,
                        title: &title,
                        workspace_id: &id,
                        now_iso: &now,
                        format_hint: hint.as_deref(),
                        extension: ext.as_deref(),
                    },
                    &mut sink,
                )
                .map_err(|e| e.to_string())?;
            to_json(&outcome)
        })
    })
}

/// The Phase 0 vertical slice, retained for the PoC screen and existing callers.
///
/// # Safety
/// `data` must point to `len` readable bytes; the string pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_create_workspace(
    data: *const u8,
    len: usize,
    storage_root: *const c_char,
    title: *const c_char,
    workspace_id: *const c_char,
    now_iso: *const c_char,
) -> *mut c_char {
    guarded(|| {
        if data.is_null() {
            return err("null input");
        }
        let bytes = unsafe { std::slice::from_raw_parts(data, len) };
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let title = unsafe { cstr(title) }.unwrap_or_else(|| "Untitled".into());
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        let now = unsafe { cstr(now_iso) }.unwrap_or_else(|| "1970-01-01T00:00:00Z".into());
        with_engine(&root, |engine| {
            let doc = engine
                .create_workspace_from_csv(bytes, &title, &id, &now)
                .map_err(|e| e.to_string())?;
            to_json(&doc)
        })
    })
}

/// A revisioned snapshot of canonical state, opening the session if necessary.
///
/// # Safety
/// Both pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_snapshot(
    storage_root: *const c_char,
    workspace_id: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        with_engine(&root, |engine| {
            to_json(&engine.snapshot(&id).map_err(|e| e.to_string())?)
        })
    })
}

/// Execute a bounded page. `plan_json` is a `morphic_query::Plan`; null means defaults.
///
/// # Safety
/// The string pointers must be valid C strings (plan may be null).
#[no_mangle]
pub unsafe extern "C" fn morphic_query_page(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    plan_json: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        let plan: morphic_query::Plan = match unsafe { cstr(plan_json) } {
            None => morphic_query::Plan::default(),
            Some(s) => match serde_json::from_str(&s) {
                Ok(p) => p,
                Err(e) => return err(&format!("invalid plan: {e}")),
            },
        };
        with_engine(&root, |engine| {
            to_json(&engine.query_page(&id, &plan).map_err(|e| e.to_string())?)
        })
    })
}

/// Compute the value behind a `metric_card`. Rust resolves the binding.
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_metric_data(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    component_id: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        let component = match unsafe { cstr(component_id) } {
            Some(c) => c,
            None => return err("invalid component_id"),
        };
        with_engine(&root, |engine| {
            to_json(
                &engine
                    .metric_data(&id, &component)
                    .map_err(|e| e.to_string())?,
            )
        })
    })
}

/// Drop an open session's in-memory state. The persisted workspace is untouched.
///
/// # Safety
/// Both pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_close_workspace(
    storage_root: *const c_char,
    workspace_id: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        with_engine(&root, |engine| {
            engine.close_session(&id).map_err(|e| e.to_string())?;
            Ok(r#"{"closed":true}"#.to_string())
        })
    })
}

/// List persisted workspaces (library index).
///
/// # Safety
/// `storage_root` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn morphic_list_workspaces(storage_root: *const c_char) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        with_engine(&root, |engine| {
            to_json(&engine.list_workspaces().map_err(|e| e.to_string())?)
        })
    })
}

/// Load a persisted workspace document by id.
///
/// # Safety
/// Both pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_load_workspace(
    storage_root: *const c_char,
    workspace_id: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let id = match unsafe { cstr(workspace_id) } {
            Some(i) => i,
            None => return err("invalid workspace_id"),
        };
        with_engine(&root, |engine| {
            to_json(&engine.load_workspace(&id).map_err(|e| e.to_string())?)
        })
    })
}

/// Free a string returned by any `morphic_*` function.
///
/// # Safety
/// `s` must be a pointer previously returned by this library, or null. Must be called
/// exactly once per returned pointer.
#[no_mangle]
pub unsafe extern "C" fn morphic_free_string(s: *mut c_char) {
    if !s.is_null() {
        unsafe {
            drop(CString::from_raw(s));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    unsafe fn take(ptr: *mut c_char) -> String {
        let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
        morphic_free_string(ptr);
        s
    }

    fn json(ptr: *mut c_char) -> serde_json::Value {
        let s = unsafe { take(ptr) };
        serde_json::from_str(&s).unwrap_or_else(|e| panic!("not JSON: {s} ({e})"))
    }

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    fn root(tag: &str) -> (std::path::PathBuf, CString) {
        let mut p = std::env::temp_dir();
        p.push(format!("morphic-bridge-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        let cs = c(p.to_str().unwrap());
        (p, cs)
    }

    const CSV: &[u8] = b"region,amount\neu,10\nus,20\neu,30\nus,10\n";

    unsafe fn import(
        rp: &CString,
        id: &CString,
        cb: Option<MorphicProgressFn>,
    ) -> serde_json::Value {
        json(morphic_import_csv(
            CSV.as_ptr(),
            CSV.len(),
            rp.as_ptr(),
            c("Sales").as_ptr(),
            id.as_ptr(),
            c("2026-11-05T00:00:00Z").as_ptr(),
            cb,
        ))
    }

    #[test]
    fn engine_info_returns_json() {
        let v = json(morphic_engine_info());
        assert_eq!(v["engine"], "morphic");
        assert_eq!(v["apiVersion"], 2);
    }

    #[test]
    fn profile_csv_returns_profile() {
        let csv = b"a,b\n1,x\n2,y\n";
        let v = json(unsafe { morphic_profile_csv(csv.as_ptr(), csv.len()) });
        assert_eq!(v["rowCount"], 2);
        assert_eq!(v["fieldCount"], 2);
    }

    #[test]
    fn null_input_is_error_not_crash() {
        let s = unsafe { take(morphic_profile_csv(std::ptr::null(), 0)) };
        assert!(s.contains("error"));
    }

    #[test]
    fn free_null_is_safe() {
        unsafe { morphic_free_string(std::ptr::null_mut()) };
    }

    #[test]
    fn invalid_utf8_pointer_is_an_error_not_a_crash() {
        let bad = [0xff, 0xfe, 0x00];
        let v = json(unsafe {
            morphic_snapshot(bad.as_ptr() as *const c_char, bad.as_ptr() as *const c_char)
        });
        assert!(v.get("error").is_some());
    }

    // --- M1.1 task 1.1.4 contract tests ---

    #[test]
    fn import_returns_doc_profile_and_report() {
        let (p, rp) = root("import");
        let v = unsafe { import(&rp, &c("w1"), None) };
        assert!(v.get("error").is_none(), "{v}");
        assert_eq!(v["report"]["rowsImported"], 4);
        assert_eq!(v["profile"]["rowCount"], 4);
        assert_eq!(v["doc"]["workspace"]["id"], "w1");
        std::fs::remove_dir_all(&p).ok();
    }

    static CALLS: AtomicUsize = AtomicUsize::new(0);
    extern "C" fn count_progress(s: *const c_char) {
        // The pointer is only valid for the duration of the call; parse it immediately.
        let text = unsafe { CStr::from_ptr(s) }.to_str().unwrap();
        let v: serde_json::Value = serde_json::from_str(text).unwrap();
        assert!(v.get("phase").is_some());
        CALLS.fetch_add(1, Ordering::SeqCst);
    }

    #[test]
    fn progress_callback_receives_real_events() {
        let (p, rp) = root("progress");
        CALLS.store(0, Ordering::SeqCst);
        let v = unsafe { import(&rp, &c("w1"), Some(count_progress)) };
        assert!(v.get("error").is_none(), "{v}");
        assert!(
            CALLS.load(Ordering::SeqCst) >= 3,
            "expected sniffing/parsing/typing/done"
        );
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn null_progress_callback_is_accepted() {
        let (p, rp) = root("nullcb");
        let v = unsafe { import(&rp, &c("w1"), None) };
        assert!(v.get("error").is_none());
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn session_survives_between_calls_so_query_page_works() {
        let (p, rp) = root("session");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        // A separate FFI call must see the session created by the import.
        let plan = c(r#"{"offset":1,"limit":1}"#);
        let v = json(unsafe { morphic_query_page(rp.as_ptr(), id.as_ptr(), plan.as_ptr()) });
        assert_eq!(v["totalRows"], 4);
        assert_eq!(v["rows"][0][0], "us");
        assert_eq!(v["rows"][0][1], 20);
        assert_eq!(v["limit"], 1);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn query_page_accepts_a_null_plan() {
        let (p, rp) = root("nullplan");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = json(unsafe { morphic_query_page(rp.as_ptr(), id.as_ptr(), std::ptr::null()) });
        assert_eq!(v["totalRows"], 4);
        assert_eq!(v["limit"], 256);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn malformed_plan_is_a_typed_error() {
        let (p, rp) = root("badplan");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v =
            json(unsafe { morphic_query_page(rp.as_ptr(), id.as_ptr(), c("{not json").as_ptr()) });
        assert!(v["error"].as_str().unwrap().contains("invalid plan"));
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn metric_data_computes_in_rust() {
        let (p, rp) = root("metric");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = json(unsafe {
            morphic_metric_data(rp.as_ptr(), id.as_ptr(), c("total_records").as_ptr())
        });
        assert_eq!(v["value"], 4);
        assert_eq!(v["componentId"], "total_records");
        assert_eq!(v["revision"], 1);
        let avg = json(unsafe {
            morphic_metric_data(rp.as_ptr(), id.as_ptr(), c("metric_amount").as_ptr())
        });
        assert_eq!(avg["value"], 17.5);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn metric_data_on_unknown_component_is_an_error() {
        let (p, rp) = root("ghostcomponent");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = json(unsafe { morphic_metric_data(rp.as_ptr(), id.as_ptr(), c("nope").as_ptr()) });
        assert!(v["error"].as_str().unwrap().contains("unknown component"));
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn snapshot_reopens_from_disk_after_close() {
        let (p, rp) = root("reopen");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let closed = json(unsafe { morphic_close_workspace(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(closed["closed"], true);
        // Snapshot must rehydrate from the persisted source, not fail.
        let v = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(v["profile"]["rowCount"], 4);
        assert_eq!(v["revision"], 1);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn snapshot_of_unknown_workspace_is_an_error() {
        let (p, rp) = root("unknownws");
        let v = json(unsafe { morphic_snapshot(rp.as_ptr(), c("ghost").as_ptr()) });
        assert!(v.get("error").is_some());
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn list_and_load_still_work() {
        let (p, rp) = root("library");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let list = json(unsafe { morphic_list_workspaces(rp.as_ptr()) });
        assert_eq!(list.as_array().unwrap().len(), 1);
        let doc = json(unsafe { morphic_load_workspace(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(doc["workspace"]["id"], "w1");
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn legacy_create_workspace_still_returns_a_doc() {
        let (p, rp) = root("legacy");
        let v = json(unsafe {
            morphic_create_workspace(
                CSV.as_ptr(),
                CSV.len(),
                rp.as_ptr(),
                c("Legacy").as_ptr(),
                c("w_legacy").as_ptr(),
                c("2026-11-05T00:00:00Z").as_ptr(),
            )
        });
        assert_eq!(v["workspace"]["id"], "w_legacy");
        std::fs::remove_dir_all(&p).ok();
    }

    // --- task 1.1.6: degraded mode is part of the JSON contract --------------------------

    #[test]
    fn snapshot_reports_degraded_when_the_dataset_is_gone() {
        let (p, rp) = root("degraded");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe { morphic_close_workspace(rp.as_ptr(), id.as_ptr()) };
        std::fs::remove_dir_all(p.join("datasets")).unwrap();

        let v = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(
            v["degraded"], true,
            "the UI must be told, not left guessing"
        );
        assert!(v["notice"]
            .as_str()
            .unwrap()
            .contains("no longer available"));
        assert!(v["profile"].is_null());
        let components = v["doc"]["workspace"]["components"].as_array().unwrap();
        assert!(!components.is_empty(), "the layout survives");
        // Data operations are a typed error string, never a panic or a silent empty page.
        let q = json(unsafe { morphic_query_page(rp.as_ptr(), id.as_ptr(), std::ptr::null()) });
        assert!(q["error"].as_str().unwrap().contains("unavailable"));
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_healthy_snapshot_is_explicitly_not_degraded() {
        let (p, rp) = root("notdegraded");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(v["degraded"], false);
        assert!(v["notice"].is_null());
        std::fs::remove_dir_all(&p).ok();
    }

    // ------------------------------------------ M1.2 1.2.3 format-aware import

    unsafe fn import_as(
        bytes: &[u8],
        rp: &CString,
        id: &CString,
        hint: Option<&CString>,
        ext: Option<&CString>,
    ) -> serde_json::Value {
        json(morphic_import(
            bytes.as_ptr(),
            bytes.len(),
            rp.as_ptr(),
            c("Imported").as_ptr(),
            id.as_ptr(),
            c("2026-11-06T00:00:00Z").as_ptr(),
            hint.map_or(std::ptr::null(), |h| h.as_ptr()),
            ext.map_or(std::ptr::null(), |e| e.as_ptr()),
            None,
        ))
    }

    #[test]
    fn import_auto_detects_json() {
        let (_p, rp) = root("auto-json");
        let v = unsafe { import_as(b"[{\"id\":1,\"v\":2.5},{\"id\":2,\"v\":3.5}]", &rp, &c("w-j"), None, None) };
        assert_eq!(v["report"]["format"], "json", "{v}");
        assert_eq!(v["report"]["rowsImported"], 2, "{v}");
    }

    #[test]
    fn import_auto_detects_jsonl() {
        let (_p, rp) = root("auto-jsonl");
        let v = unsafe { import_as(b"{\"id\":1}\n{\"id\":2}\n", &rp, &c("w-jl"), None, None) };
        assert_eq!(v["report"]["format"], "jsonl", "{v}");
    }

    #[test]
    fn import_auto_detects_logs() {
        let (_p, rp) = root("auto-log");
        let src = b"2026-11-05T14:00:01Z INFO api hello\n2026-11-05T14:00:02Z WARN api slow\n";
        let v = unsafe { import_as(src, &rp, &c("w-log"), None, None) };
        assert_eq!(v["report"]["format"], "log", "{v}");
    }

    #[test]
    fn import_auto_detects_plain_text() {
        let (_p, rp) = root("auto-txt");
        let v = unsafe { import_as(b"some prose\nmore prose\n", &rp, &c("w-txt"), None, None) };
        assert_eq!(v["report"]["format"], "txt", "{v}");
    }

    #[test]
    fn an_explicit_hint_overrides_detection() {
        let (_p, rp) = root("hint-txt");
        // Valid CSV, but the caller asked for text.
        let v = unsafe { import_as(CSV, &rp, &c("w-hint"), Some(&c("txt")), None) };
        assert_eq!(v["report"]["format"], "txt", "{v}");
    }

    #[test]
    fn an_unknown_hint_is_a_typed_error_not_a_crash() {
        let (_p, rp) = root("hint-bad");
        let v = unsafe { import_as(CSV, &rp, &c("w-bad"), Some(&c("parquet")), None) };
        let msg = v["error"].as_str().unwrap_or("");
        assert!(msg.contains("unknown format"), "{v}");
    }

    #[test]
    fn the_extension_decides_only_when_content_could_not() {
        let (_p, rp) = root("ext-csv");
        let v = unsafe { import_as(b"alpha\nbeta\n", &rp, &c("w-ext"), None, Some(&c("csv"))) };
        assert_eq!(v["report"]["format"], "csv", "{v}");
    }

    #[test]
    fn a_json_workspace_reopens_with_its_data() {
        // Regression guard: open_session used to force CSV, which would have corrupted
        // every non-CSV workspace on reopen.
        let (_p, rp) = root("reopen-json");
        let id = c("w-reopen");
        let v = unsafe {
            import_as(
                b"[{\"region\":\"eu\",\"amount\":10},{\"region\":\"us\",\"amount\":20}]",
                &rp,
                &id,
                None,
                None,
            )
        };
        assert_eq!(v["report"]["format"], "json", "{v}");
        unsafe {
            morphic_close_workspace(rp.as_ptr(), id.as_ptr());
        }
        let snap = unsafe { json(morphic_snapshot(rp.as_ptr(), id.as_ptr())) };
        assert_eq!(snap["degraded"], false, "{snap}");
        assert!(snap["profile"].is_object(), "{snap}");
    }

}
