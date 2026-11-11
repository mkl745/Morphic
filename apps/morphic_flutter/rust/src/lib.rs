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

/// In-flight imports, keyed by workspace id, so the UI thread can cancel one.
///
/// Deliberately a **separate lock** from `engines()`: `with_engine` holds the engine lock for
/// the whole import, so a cancel call that needed it would block until the import it is
/// trying to stop had already finished.
fn cancellations() -> &'static Mutex<HashMap<String, morphic_core::CancelToken>> {
    static CANCELS: OnceLock<Mutex<HashMap<String, morphic_core::CancelToken>>> = OnceLock::new();
    CANCELS.get_or_init(|| Mutex::new(HashMap::new()))
}

/// RAII registration. Removes the entry on *every* exit path — normal return, early `?`,
/// and a panic unwinding through `guarded`'s firewall — so the registry cannot leak ids.
struct CancelRegistration(String);

impl CancelRegistration {
    fn new(id: &str) -> (Self, morphic_core::CancelToken) {
        let token = morphic_core::CancelToken::new();
        if let Ok(mut m) = cancellations().lock() {
            m.insert(id.to_string(), token.clone());
        }
        (Self(id.to_string()), token)
    }
}

impl Drop for CancelRegistration {
    fn drop(&mut self) {
        if let Ok(mut m) = cancellations().lock() {
            m.remove(&self.0);
        }
    }
}

/// Ask an in-flight import to stop. Returns `{"cancelled": bool}` — false when no import
/// with that id is running, which is a normal answer, not an error (the import may have
/// finished between the user tapping and this call landing).
///
/// Cancellation is cooperative: the import returns an `import cancelled` error and, because
/// core writes nothing until parsing and validation have both succeeded, leaves no dataset
/// and no workspace behind.
///
/// # Safety
/// `workspace_id` must be null or a valid C string.
#[no_mangle]
pub unsafe extern "C" fn morphic_cancel_import(workspace_id: *const c_char) -> *mut c_char {
    guarded(|| {
        let Some(id) = (unsafe { cstr(workspace_id) }) else {
            return err("workspace_id is required");
        };
        let Ok(registry) = cancellations().lock() else {
            return err("cancel registry poisoned");
        };
        let cancelled = match registry.get(&id) {
            Some(token) => {
                token.cancel();
                true
            }
            None => false,
        };
        serde_json::json!({ "cancelled": cancelled }).to_string()
    })
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
        // Registered before the engine lock is taken, so a cancel arriving at any point
        // during the import finds the token. Dropped when this closure exits.
        let (_registration, cancel) = CancelRegistration::new(&id);

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
                        cancel: Some(&cancel),
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

/// The pre-aggregated scene behind a chart. Rust groups, buckets and downsamples; Dart
/// receives buckets and totals and never rows (docs/architecture/02 §2.5).
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_chart_data(
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
                    .chart_data(&id, &component)
                    .map_err(|e| e.to_string())?,
            )
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

/// Apply a batch of interaction commands atomically (M1.3 task 1.3.3).
///
/// `commands_json` is a JSON array of tagged commands, e.g.
/// `[{"kind":"setComponentSort","componentId":"t1","sort":[{"field":"amount","dir":"desc"}]}]`.
/// Returns `{revision, affected, changed, doc}`. A rejected command changes nothing.
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_apply_commands(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    commands_json: *const c_char,
    now_iso: *const c_char,
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
        let raw = match unsafe { cstr(commands_json) } {
            Some(s) => s,
            None => return err("invalid commands_json"),
        };
        let now = match unsafe { cstr(now_iso) } {
            Some(s) => s,
            None => return err("invalid now_iso"),
        };
        let commands: Vec<morphic_core::Command> = match serde_json::from_str(&raw) {
            Ok(c) => c,
            Err(e) => return err(&format!("invalid commands: {e}")),
        };
        with_engine(&root, |engine| {
            to_json(
                &engine
                    .apply(&id, &commands, &now)
                    .map_err(|e| e.to_string())?,
            )
        })
    })
}

/// Undo one engine-owned revision. Returns the same `ApplyResult` shape as
/// `morphic_apply_commands`, including the new `stateHash`, depths and snackbar label.
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_undo(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    now_iso: *const c_char,
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
        let now = match unsafe { cstr(now_iso) } {
            Some(s) => s,
            None => return err("invalid now_iso"),
        };
        with_engine(&root, |engine| {
            to_json(&engine.undo(&id, &now).map_err(|e| e.to_string())?)
        })
    })
}

/// Redo one engine-owned revision. The redo stack is truncated by a new command batch.
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_redo(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    now_iso: *const c_char,
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
        let now = match unsafe { cstr(now_iso) } {
            Some(s) => s,
            None => return err("invalid now_iso"),
        };
        with_engine(&root, |engine| {
            to_json(&engine.redo(&id, &now).map_err(|e| e.to_string())?)
        })
    })
}

/// One page of a component's rows with its persisted filter, sort and search applied, plus
/// any global filters. The UI never assembles this plan itself.
///
/// `limit` of 0 means the page size the component's binding declares.
///
/// # Safety
/// All pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_component_page(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    component_id: *const c_char,
    offset: usize,
    limit: usize,
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
                    .component_page(&id, &component, offset, limit)
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

/// What startup recovery actually repaired when this engine instance was created. The report
/// is captured once, so the app shows exactly one honest summary per process start.
///
/// # Safety
/// `storage_root` must be a valid C string.
#[no_mangle]
pub unsafe extern "C" fn morphic_recovery_report(
    storage_root: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        with_engine(&root, |engine| to_json(&engine.recovery_report()))
    })
}

/// Explicit autosave checkpoint. Every command is already persisted, so this folds the journal
/// and acknowledges the flush rather than introducing a window that could lose data.
///
/// # Safety
/// Both pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_save_workspace(
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
            to_json(&engine.save(&id).map_err(|e| e.to_string())?)
        })
    })
}

/// Rename a persisted workspace. Returns the new `WorkspaceDoc`.
///
/// # Safety
/// All four pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_rename_workspace(
    storage_root: *const c_char,
    workspace_id: *const c_char,
    title: *const c_char,
    now_iso: *const c_char,
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
        let title = match unsafe { cstr(title) } {
            Some(t) => t,
            None => return err("invalid title"),
        };
        let now = unsafe { cstr(now_iso) }.unwrap_or_else(|| "1970-01-01T00:00:00Z".into());
        with_engine(&root, |engine| {
            let doc = engine
                .rename_workspace(&id, &title, &now)
                .map_err(|e| e.to_string())?;
            to_json(&doc)
        })
    })
}

/// Duplicate a workspace document under a new id, sharing the content-addressed dataset.
///
/// # Safety
/// All five pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_duplicate_workspace(
    storage_root: *const c_char,
    source_id: *const c_char,
    new_id: *const c_char,
    title: *const c_char,
    now_iso: *const c_char,
) -> *mut c_char {
    guarded(|| {
        let root = match unsafe { cstr(storage_root) } {
            Some(r) => r,
            None => return err("invalid storage_root"),
        };
        let source = match unsafe { cstr(source_id) } {
            Some(i) => i,
            None => return err("invalid source workspace_id"),
        };
        let new = match unsafe { cstr(new_id) } {
            Some(i) => i,
            None => return err("invalid new workspace_id"),
        };
        let title = match unsafe { cstr(title) } {
            Some(t) => t,
            None => return err("invalid title"),
        };
        let now = unsafe { cstr(now_iso) }.unwrap_or_else(|| "1970-01-01T00:00:00Z".into());
        with_engine(&root, |engine| {
            let doc = engine
                .duplicate_workspace(&source, &new, &title, &now)
                .map_err(|e| e.to_string())?;
            to_json(&doc)
        })
    })
}

/// Delete a workspace. Datasets are kept because another workspace may share them.
///
/// # Safety
/// Both pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_delete_workspace(
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
            engine.delete_workspace(&id).map_err(|e| e.to_string())?;
            Ok(r#"{"deleted":true}"#.to_string())
        })
    })
}

/// Restore a degraded workspace's source bytes. The bytes must hash to the dataset id already
/// referenced by the document; a different file is refused.
///
/// # Safety
/// `data` must point to `len` readable bytes; the string pointers must be valid C strings.
#[no_mangle]
pub unsafe extern "C" fn morphic_relink_workspace(
    data: *const u8,
    len: usize,
    storage_root: *const c_char,
    workspace_id: *const c_char,
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
        with_engine(&root, |engine| {
            engine
                .relink_workspace(&id, bytes)
                .map_err(|e| e.to_string())?;
            Ok(r#"{"relinked":true}"#.to_string())
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
        assert_eq!(v["apiVersion"], 12);
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

    #[test]
    fn library_lifecycle_and_relink_cross_the_json_boundary() {
        let (p, rp) = root("library_lifecycle");
        let w1 = c("w1");
        let w2 = c("w2");
        unsafe { import(&rp, &w1, None) };

        let renamed = unsafe {
            json(morphic_rename_workspace(
                rp.as_ptr(),
                w1.as_ptr(),
                c("Renamed").as_ptr(),
                c("2026-11-10T10:00:00Z").as_ptr(),
            ))
        };
        assert_eq!(renamed["workspace"]["title"], "Renamed");

        let duplicate = unsafe {
            json(morphic_duplicate_workspace(
                rp.as_ptr(),
                w1.as_ptr(),
                w2.as_ptr(),
                c("Renamed copy").as_ptr(),
                c("2026-11-10T10:01:00Z").as_ptr(),
            ))
        };
        assert_eq!(duplicate["workspace"]["id"], "w2");
        let list = unsafe { json(morphic_list_workspaces(rp.as_ptr())) };
        assert_eq!(list.as_array().unwrap().len(), 2);

        let dataset = duplicate["workspace"]["dataSources"][0]["datasetId"]
            .as_str()
            .unwrap()
            .to_string();
        std::fs::remove_file(p.join("datasets").join(dataset).join("source.csv")).unwrap();
        let degraded = unsafe { json(morphic_snapshot(rp.as_ptr(), w2.as_ptr())) };
        assert_eq!(degraded["degraded"], true);
        let relinked = unsafe {
            json(morphic_relink_workspace(
                CSV.as_ptr(),
                CSV.len(),
                rp.as_ptr(),
                w2.as_ptr(),
            ))
        };
        assert_eq!(relinked["relinked"], true);
        let healthy = unsafe { json(morphic_snapshot(rp.as_ptr(), w2.as_ptr())) };
        assert_eq!(healthy["degraded"], false);

        let deleted = unsafe { json(morphic_delete_workspace(rp.as_ptr(), w2.as_ptr())) };
        assert_eq!(deleted["deleted"], true);
        let list = unsafe { json(morphic_list_workspaces(rp.as_ptr())) };
        assert_eq!(list.as_array().unwrap().len(), 1);
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
        let v = unsafe {
            import_as(
                b"[{\"id\":1,\"v\":2.5},{\"id\":2,\"v\":3.5}]",
                &rp,
                &c("w-j"),
                None,
                None,
            )
        };
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

    // ------------------------------------------- M1.2 1.2.4 cancellation over the C ABI

    #[test]
    fn cancelling_an_unknown_import_is_false_not_an_error() {
        let v = unsafe { json(morphic_cancel_import(c("nobody").as_ptr())) };
        assert_eq!(v["cancelled"], false, "{v}");
        assert!(v.get("error").is_none(), "{v}");
    }

    #[test]
    fn cancelling_with_a_null_id_is_a_typed_error() {
        let v = unsafe { json(morphic_cancel_import(std::ptr::null())) };
        assert!(
            v["error"].as_str().unwrap_or("").contains("required"),
            "{v}"
        );
    }

    #[test]
    fn the_cancel_registry_is_cleaned_up_after_success() {
        let (p, rp) = root("cancel-cleanup-ok");
        let id = c("w-done");
        let v = unsafe { import(&rp, &id, None) };
        assert!(v.get("error").is_none(), "{v}");
        // The id must not linger: a later cancel is a no-op, not a stale hit.
        let after = unsafe { json(morphic_cancel_import(id.as_ptr())) };
        assert_eq!(after["cancelled"], false, "{after}");
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn the_cancel_registry_is_cleaned_up_after_failure() {
        let (_p, rp) = root("cancel-cleanup-err");
        let id = c("w-bad");
        // An unknown hint fails inside core, after registration.
        let v = unsafe { import_as(CSV, &rp, &id, Some(&c("parquet")), None) };
        assert!(v.get("error").is_some(), "{v}");
        let after = unsafe { json(morphic_cancel_import(id.as_ptr())) };
        assert_eq!(after["cancelled"], false, "{after}");
    }

    /// Trips the cancel from inside a real progress event, i.e. genuinely mid-import.
    extern "C" fn cancel_during_import(_json: *const c_char) {
        unsafe {
            let reply = morphic_cancel_import(c"w-cancel-cb".as_ptr());
            morphic_free_string(reply);
        }
    }

    #[test]
    fn cancelling_mid_import_errors_and_persists_nothing() {
        let (p, rp) = root("cancel-mid");
        let id = c("w-cancel-cb");
        let v = unsafe {
            json(morphic_import(
                CSV.as_ptr(),
                CSV.len(),
                rp.as_ptr(),
                c("Sales").as_ptr(),
                id.as_ptr(),
                c("2026-11-06T00:00:00Z").as_ptr(),
                c"csv".as_ptr(),
                std::ptr::null(),
                Some(cancel_during_import),
            ))
        };
        let msg = v["error"].as_str().unwrap_or("");
        assert!(msg.contains("cancelled"), "{v}");
        // AT-05: no workspace and no dataset may survive a cancelled import.
        let list = unsafe { json(morphic_list_workspaces(rp.as_ptr())) };
        assert_eq!(list.as_array().unwrap().len(), 0, "{list}");
        let stored = std::fs::read_dir(p.join("datasets"))
            .map(|entries| entries.count())
            .unwrap_or(0);
        assert_eq!(stored, 0, "a cancelled import left a dataset behind");
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.3 task 1.3.3: interaction commands and component pages ------------------------

    /// Apply one batch and return the parsed outcome.
    unsafe fn apply(rp: &CString, id: &CString, commands: &str) -> serde_json::Value {
        json(morphic_apply_commands(
            rp.as_ptr(),
            id.as_ptr(),
            c(commands).as_ptr(),
            c("2026-11-07T00:00:00Z").as_ptr(),
        ))
    }

    unsafe fn undo(rp: &CString, id: &CString, now: &str) -> serde_json::Value {
        json(morphic_undo(rp.as_ptr(), id.as_ptr(), c(now).as_ptr()))
    }

    unsafe fn redo(rp: &CString, id: &CString, now: &str) -> serde_json::Value {
        json(morphic_redo(rp.as_ptr(), id.as_ptr(), c(now).as_ptr()))
    }

    unsafe fn page(
        rp: &CString,
        id: &CString,
        component: &str,
        offset: usize,
        limit: usize,
    ) -> serde_json::Value {
        json(morphic_component_page(
            rp.as_ptr(),
            id.as_ptr(),
            c(component).as_ptr(),
            offset,
            limit,
        ))
    }

    const SORT_AMOUNT_DESC: &str = r#"[{"kind":"setComponentSort","componentId":"data_table",
        "sort":[{"field":"amount","dir":"desc","nulls":"last"}]}]"#;

    #[test]
    fn apply_commands_persists_state_and_returns_the_document() {
        let (p, rp) = root("apply");
        let id = c("w1");
        let before = unsafe { import(&rp, &id, None) };
        let revision = before["doc"]["workspace"]["revision"].as_u64().unwrap();
        let v = unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        assert_eq!(v["changed"], true);
        assert_eq!(v["revision"], revision + 1);
        assert_eq!(v["affected"][0], "data_table");
        let comps = v["doc"]["workspace"]["components"].as_array().unwrap();
        let table = comps
            .iter()
            .find(|c| c["id"] == "data_table")
            .expect("the compiler emits a table");
        assert_eq!(table["state"]["sort"][0]["field"], "amount");
        assert_eq!(table["state"]["sort"][0]["dir"], "desc");
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn undo_redo_return_apply_results_with_matching_state_hashes() {
        let (p, rp) = root("undo_redo_ffi");
        let id = c("w1");
        let imported = unsafe { import(&rp, &id, None) };
        let h0 = imported["stateHash"].as_str().unwrap().to_string();
        let applied = unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        let h1 = applied["stateHash"].as_str().unwrap().to_string();
        assert_ne!(h0, h1);
        assert_eq!(applied["undoDepth"], 1);
        assert_eq!(applied["redoDepth"], 0);

        let undone = unsafe { undo(&rp, &id, "2026-11-07T00:01:00Z") };
        assert_eq!(undone["stateHash"], h0);
        assert_eq!(undone["undoDepth"], 0);
        assert_eq!(undone["redoDepth"], 1);
        assert!(undone["label"].as_str().unwrap().contains("Undid"));

        let redone = unsafe { redo(&rp, &id, "2026-11-07T00:02:00Z") };
        assert_eq!(redone["stateHash"], h1);
        assert_eq!(redone["undoDepth"], 1);
        assert_eq!(redone["redoDepth"], 0);
        assert!(redone["label"].as_str().unwrap().contains("Redid"));
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn component_page_applies_the_persisted_sort() {
        let (p, rp) = root("comppage");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        // The UI sends no plan: Rust composes it from the state the command persisted.
        let v = unsafe { page(&rp, &id, "data_table", 0, 2) };
        assert_eq!(v["totalRows"], 4);
        assert_eq!(v["rows"][0][1], 30);
        assert_eq!(v["rows"][1][1], 20);
        assert_eq!(v["hasMore"], true);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_zero_limit_uses_the_page_size_the_binding_declares() {
        let (p, rp) = root("pagesize");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(v["limit"], 256, "the compiler emits page_size 256");
        assert_eq!(v["totalRows"], 4);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_component_filter_narrows_the_page_and_a_global_filter_still_applies() {
        let (p, rp) = root("compfilter");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setComponentFilter","componentId":"data_table",
                    "filter":{"op":"eq","field":"region","value":"eu"}}]"#,
            )
        };
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            2
        );
        // A global filter is composed *with* the component's own, never instead of it.
        unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                    {"op":"gt","field":"amount","value":10}]}]"#,
            )
        };
        let v = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(v["totalRows"], 1);
        assert_eq!(v["rows"][0][1], 30);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn search_is_per_component_state_and_narrows_the_page() {
        let (p, rp) = root("compsearch");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setSearch","componentId":"data_table","text":"eu"}]"#,
            )
        };
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            2
        );
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn repeating_a_command_is_a_no_op_with_no_revision_bump() {
        let (p, rp) = root("noop");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let first = unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        let again = unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        assert_eq!(again["changed"], false);
        assert_eq!(again["revision"], first["revision"]);
        assert!(again["affected"].as_array().unwrap().is_empty());
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_rejected_batch_leaves_the_persisted_state_untouched() {
        let (p, rp) = root("reject");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let first = unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        // The second command in the batch is invalid, so the first must not survive either.
        let bad = unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setSearch","componentId":"data_table","text":"zzz"},
                    {"kind":"setComponentFilter","componentId":"data_table",
                     "filter":{"op":"eq","field":"nope","value":1}}]"#,
            )
        };
        assert!(
            bad["error"].is_string(),
            "expected a typed error, got {bad}"
        );
        let v = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(
            v["totalRows"], 4,
            "the rejected search must not have applied"
        );
        assert_eq!(v["rows"][0][1], 30, "the earlier sort is still in force");
        let snap = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(snap["doc"]["workspace"]["revision"], first["revision"]);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn malformed_commands_are_a_typed_error_not_a_crash() {
        let (p, rp) = root("badcmds");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = unsafe { apply(&rp, &id, "{not json") };
        assert!(v["error"].as_str().unwrap().contains("invalid commands"));
        let unknown = unsafe { apply(&rp, &id, r#"[{"kind":"dropTable"}]"#) };
        assert!(unknown["error"].is_string());
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn an_unknown_component_is_an_error_not_an_empty_page() {
        let (p, rp) = root("unknowncomp");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = unsafe { page(&rp, &id, "no_such_component", 0, 10) };
        assert!(v["error"].is_string(), "expected a typed error, got {v}");
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn null_pointers_on_the_new_endpoints_are_errors_not_crashes() {
        let id = c("w1");
        let cmds = c("[]");
        let now = c("2026-11-07T00:00:00Z");
        let v = json(unsafe {
            morphic_apply_commands(std::ptr::null(), id.as_ptr(), cmds.as_ptr(), now.as_ptr())
        });
        assert!(v["error"]
            .as_str()
            .unwrap()
            .contains("invalid storage_root"));
        let v = json(unsafe {
            morphic_apply_commands(id.as_ptr(), id.as_ptr(), std::ptr::null(), now.as_ptr())
        });
        assert!(v["error"]
            .as_str()
            .unwrap()
            .contains("invalid commands_json"));
        let v = json(unsafe {
            morphic_component_page(id.as_ptr(), id.as_ptr(), std::ptr::null(), 0, 0)
        });
        assert!(v["error"]
            .as_str()
            .unwrap()
            .contains("invalid component_id"));
    }

    #[test]
    fn persisted_sort_survives_close_and_reopen() {
        let (p, rp) = root("reopenstate");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe { apply(&rp, &id, SORT_AMOUNT_DESC) };
        unsafe { morphic_close_workspace(rp.as_ptr(), id.as_ptr()) };
        // A fresh session reads the document from disk, so the indicator and the order return.
        let v = unsafe { page(&rp, &id, "data_table", 0, 2) };
        assert_eq!(
            v["rows"][0][1], 30,
            "AT-07: the sort is document state, not UI state"
        );
        let snap = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        let comps = snap["doc"]["workspace"]["components"].as_array().unwrap();
        let table = comps.iter().find(|c| c["id"] == "data_table").unwrap();
        assert_eq!(table["state"]["sort"][0]["dir"], "desc");
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.3 task 1.3.4: one global filter, every component (AT-06) ----------------------

    unsafe fn metric(rp: &CString, id: &CString, component: &str) -> serde_json::Value {
        json(morphic_metric_data(
            rp.as_ptr(),
            id.as_ptr(),
            c(component).as_ptr(),
        ))["value"]
            .clone()
    }

    #[test]
    fn one_global_filter_moves_every_component_and_clearing_restores_the_aggregate() {
        let (p, rp) = root("globalfilter");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };

        let count_before = unsafe { metric(&rp, &id, "total_records") };
        let avg_before = unsafe { metric(&rp, &id, "metric_amount") };
        let rows_before = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(count_before, 4);
        assert_eq!(avg_before, 17.5);
        assert_eq!(rows_before["totalRows"], 4);

        // One command, one revision — the card and the table must agree afterwards.
        let applied = unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                    {"op":"eq","field":"region","value":"eu"}]}]"#,
            )
        };
        let affected = applied["affected"].as_array().unwrap();
        for expected in ["total_records", "metric_amount", "data_table"] {
            assert!(
                affected.iter().any(|a| a == expected),
                "{expected} is bound to the data and must be named affected"
            );
        }
        assert_eq!(unsafe { metric(&rp, &id, "total_records") }, 2);
        assert_eq!(unsafe { metric(&rp, &id, "metric_amount") }, 20.0);
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            2
        );

        // AT-06: clearing restores the *exact* prior aggregates, not merely a plausible count.
        unsafe { apply(&rp, &id, r#"[{"kind":"setGlobalFilter","filters":[]}]"#) };
        assert_eq!(unsafe { metric(&rp, &id, "total_records") }, count_before);
        assert_eq!(unsafe { metric(&rp, &id, "metric_amount") }, avg_before);
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            rows_before["totalRows"]
        );
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_global_filter_intersects_a_component_filter_instead_of_replacing_it() {
        let (p, rp) = root("intersect");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setComponentFilter","componentId":"data_table",
                    "filter":{"op":"gt","field":"amount","value":10}}]"#,
            )
        };
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            2
        );
        unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                    {"op":"eq","field":"region","value":"eu"}]}]"#,
            )
        };
        // eu rows are 10 and 30; only 30 is also greater than 10.
        let v = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(v["totalRows"], 1);
        assert_eq!(v["rows"][0][1], 30);
        // The card has no component filter, so it sees both eu rows — different selections
        // from the same global set, which is the point of composing per component.
        assert_eq!(unsafe { metric(&rp, &id, "total_records") }, 2);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn setting_the_same_global_set_again_is_a_no_op() {
        let (p, rp) = root("globalnoop");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let cmds = r#"[{"kind":"setGlobalFilter","filters":[
            {"op":"eq","field":"region","value":"eu"}]}]"#;
        let first = unsafe { apply(&rp, &id, cmds) };
        let again = unsafe { apply(&rp, &id, cmds) };
        assert_eq!(first["changed"], true);
        assert_eq!(again["changed"], false);
        assert_eq!(again["revision"], first["revision"]);
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.3 task 1.3.5: one revision, every component ------------------------------------

    #[test]
    fn a_batch_spanning_two_components_is_observed_whole() {
        let (p, rp) = root("batchwhole");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        // One batch, two scopes: a global filter and a component filter on the table.
        let outcome = unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                        {"op":"eq","field":"region","value":"eu"}]},
                    {"kind":"setComponentFilter","componentId":"data_table",
                        "filter":{"op":"gt","field":"amount","value":10}}]"#,
            )
        };
        assert_eq!(outcome["changed"], true);
        let revision = outcome["revision"].as_u64().unwrap();

        // The table sees both commands; the card sees the global one. Neither sees half.
        let table = unsafe { page(&rp, &id, "data_table", 0, 0) };
        assert_eq!(table["totalRows"], 1);
        assert_eq!(table["rows"][0][1], 30);
        let card = json(unsafe {
            morphic_metric_data(rp.as_ptr(), id.as_ptr(), c("total_records").as_ptr())
        });
        assert_eq!(card["value"], 2);
        assert_eq!(
            card["revision"], revision,
            "the read reports the batch's revision"
        );

        let snap = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(snap["doc"]["workspace"]["revision"], revision);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_rejected_batch_leaves_every_component_on_the_previous_revision() {
        let (p, rp) = root("batchreject");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let before = unsafe { metric(&rp, &id, "total_records") };
        let rows_before = unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"].clone();
        let snap_before = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        let rev_before = snap_before["doc"]["workspace"]["revision"]
            .as_u64()
            .unwrap();

        // The first command is valid and global; the second names a field that does not exist.
        // Neither may survive: a workspace where the cards moved and the table did not is the
        // torn state this task rules out, expressed at the engine boundary.
        let bad = unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                        {"op":"eq","field":"region","value":"eu"}]},
                    {"kind":"setComponentFilter","componentId":"data_table",
                        "filter":{"op":"eq","field":"nope","value":1}}]"#,
            )
        };
        assert!(
            bad["error"].is_string(),
            "expected a typed error, got {bad}"
        );
        assert_eq!(unsafe { metric(&rp, &id, "total_records") }, before);
        assert_eq!(
            unsafe { page(&rp, &id, "data_table", 0, 0) }["totalRows"],
            rows_before
        );
        let snap = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(snap["doc"]["workspace"]["revision"], rev_before);
        assert!(snap["doc"]["workspace"]["globalFilters"]
            .as_array()
            .unwrap()
            .is_empty());
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.4 task 1.4.1: chart scenes over FFI --------------------------------------------

    unsafe fn chart(rp: &CString, id: &CString, component: &str) -> serde_json::Value {
        json(morphic_chart_data(
            rp.as_ptr(),
            id.as_ptr(),
            c(component).as_ptr(),
        ))
    }

    /// The compiler's bar chart id for the two-column CSV fixture.
    unsafe fn bar_id(rp: &CString, id: &CString) -> String {
        let snap = json(morphic_snapshot(rp.as_ptr(), id.as_ptr()));
        snap["doc"]["workspace"]["components"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["type"] == "bar_chart")
            .expect("region is a low-cardinality dimension")["id"]
            .as_str()
            .unwrap()
            .to_string()
    }

    #[test]
    fn chart_data_returns_a_scene_not_rows() {
        let (p, rp) = root("chartscene");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let bar = unsafe { bar_id(&rp, &id) };
        let got = unsafe { chart(&rp, &id, &bar) };
        assert_eq!(got["componentId"], bar);
        assert_eq!(got["revision"], 1);
        let scene = &got["scene"];
        assert_eq!(scene["kind"], "category");
        assert_eq!(scene["dimension"], "region");
        assert_eq!(scene["measure"], "avg_amount");
        // eu: 10,30 -> 20.0 (2 rows); us: 20,10 -> 15.0 (2 rows). Descending by measure.
        assert_eq!(scene["points"][0]["label"], "eu");
        assert_eq!(scene["points"][0]["value"], 20.0);
        assert_eq!(scene["points"][0]["rowCount"], 2);
        assert_eq!(scene["points"][1]["label"], "us");
        assert_eq!(scene["points"][1]["value"], 15.0);
        // The contract that matters: no raw rows cross the boundary.
        assert!(scene.get("rows").is_none(), "a chart must not receive rows");
        assert!(got.get("rows").is_none());
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn a_workspace_filter_moves_the_chart_over_ffi() {
        let (p, rp) = root("chartffifilter");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let bar = unsafe { bar_id(&rp, &id) };
        let outcome = unsafe {
            apply(
                &rp,
                &id,
                r#"[{"kind":"setGlobalFilter","filters":[
                    {"op":"eq","field":"region","value":"eu"}]}]"#,
            )
        };
        let revision = outcome["revision"].as_u64().unwrap();
        let got = unsafe { chart(&rp, &id, &bar) };
        assert_eq!(got["revision"], revision, "the scene reports its revision");
        let scene = &got["scene"];
        assert_eq!(scene["totalCategories"], 1);
        assert_eq!(scene["points"].as_array().unwrap().len(), 1);
        assert_eq!(scene["points"][0]["label"], "eu");
        assert_eq!(scene["points"][0]["value"], 20.0);
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn chart_data_on_a_table_is_a_typed_error_over_ffi() {
        let (p, rp) = root("chartffibad");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let got = unsafe { chart(&rp, &id, "data_table") };
        assert!(
            got["error"].as_str().unwrap().contains("not a chart"),
            "{got}"
        );
        let ghost = unsafe { chart(&rp, &id, "ghost") };
        assert!(ghost["error"].is_string());
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.4 task 1.4.7: the command name must cross the JSON boundary ------------------
    #[test]
    fn change_component_type_command_is_accepted_over_ffi() {
        let (p, rp) = root("changetype");
        let id = c("w1");
        let before = unsafe { import(&rp, &id, None) };
        let comps = before["doc"]["workspace"]["components"].as_array().unwrap();
        let table = comps.iter().find(|c| c["type"] == "data_table").unwrap()["id"]
            .as_str()
            .unwrap()
            .to_string();
        let cmd = serde_json::json!([{
            "kind": "changeComponentType",
            "componentId": table.clone(),
            "targetType": "metric_card",
        }])
        .to_string();
        let v = unsafe { apply(&rp, &id, &cmd) };
        assert_eq!(v["changed"], serde_json::json!(true), "{v}");
        let after = v["doc"]["workspace"]["components"].as_array().unwrap();
        let changed = after.iter().find(|c| c["id"] == table.as_str()).unwrap();
        assert_eq!(changed["type"], "metric_card");
        assert_eq!(changed["binding"]["kind"], "metric_card");
        assert_eq!(changed["explanation"]["reason"], "user_type_change");

        // The apply result carries the *new* matrix, and a fresh snapshot agrees with it.
        // Both travel through the same FFI JSON shape the Dart controller parses.
        let apply_opts = v["typeOptions"]
            .as_object()
            .unwrap_or_else(|| panic!("typeOptions missing: {v}"));
        let targets = apply_opts[table.as_str()].as_array().unwrap();
        assert!(
            targets.iter().any(|x| x.as_str() == Some("data_table")),
            "the converted metric card must be able to switch back: {v}"
        );
        let snap = json(unsafe { morphic_snapshot(rp.as_ptr(), id.as_ptr()) });
        let snap_opts = snap["typeOptions"]
            .as_object()
            .unwrap_or_else(|| panic!("typeOptions missing: {snap}"));
        assert_eq!(
            snap_opts[table.as_str()].as_array().unwrap(),
            targets,
            "snapshot and apply disagree about the available switches"
        );
        std::fs::remove_dir_all(&p).ok();
    }

    // --- M1.5 task 1.5.4: recovery report and explicit checkpoint over FFI ---------------

    #[test]
    fn recovery_report_crosses_the_ffi_boundary() {
        let (p, rp) = root("recoveryreport");
        // Plant an interrupted write *before* the engine is created, so startup recovery has
        // something real to report. with_engine caches per root, and this root is unique.
        std::fs::create_dir_all(p.join("datasets")).unwrap();
        std::fs::write(p.join("datasets").join("interrupted.tmp"), b"partial").unwrap();
        let v = json(unsafe { morphic_recovery_report(rp.as_ptr()) });
        assert_eq!(v["sweptTmp"], 1, "{v}");
        assert_eq!(v["restoredFromJournal"], false, "{v}");
        assert_eq!(v["quarantined"], false, "{v}");
        assert_eq!(v["rebuiltLibraryIndex"], false, "{v}");
        // A second call must not sweep the same file twice.
        let again = json(unsafe { morphic_recovery_report(rp.as_ptr()) });
        assert_eq!(again["sweptTmp"], 1, "the report is captured once: {again}");
        std::fs::remove_dir_all(&p).ok();
    }

    #[test]
    fn explicit_save_checkpoint_returns_a_clean_flush() {
        let (p, rp) = root("checkpoint");
        let id = c("w1");
        unsafe { import(&rp, &id, None) };
        let v = json(unsafe { morphic_save_workspace(rp.as_ptr(), id.as_ptr()) });
        assert_eq!(v["dirty"], false, "{v}");
        assert_eq!(v["compacted"], true, "{v}");
        assert!(v["revision"].as_u64().unwrap() >= 1, "{v}");
        assert!(v["stateHash"].as_str().unwrap().len() >= 32, "{v}");
        std::fs::remove_dir_all(&p).ok();
    }
}
