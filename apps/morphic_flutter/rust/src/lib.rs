//! # morphic-bridge (Phase 0 C-ABI proof of concept)
//!
//! Thin FFI facade over `morphic-core`. **Phase 0 uses a hand-written C ABI over
//! `dart:ffi`** so the Dart↔Rust proof of concept is fully authorable and testable without
//! a local codegen toolchain. The production bridge migrates to flutter_rust_bridge +
//! cargokit in M1.1 (see ADR-0002 addendum). Only this crate knows about FFI; the engine
//! crates never see it, so the migration is contained.
//!
//! Contract (docs/architecture/02): coarse-grained calls, JSON control-plane responses,
//! a panic firewall (`catch_unwind`) so a Rust panic becomes a typed error, never a crash.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

/// Wrap a bridge entry point in the panic firewall and return a heap C string.
/// The caller (Dart) MUST free the result with `morphic_free_string`.
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

/// Engine identity + bridge API version.
#[no_mangle]
pub extern "C" fn morphic_engine_info() -> *mut c_char {
    guarded(|| {
        let info = morphic_core::engine_info();
        serde_json::to_string(&info).unwrap_or_else(|_| err("serialize"))
    })
}

/// The data-processing PoC: profile CSV bytes entirely in Rust.
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

/// The Phase 0 vertical slice: CSV bytes → validated + persisted workspace doc.
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

        let engine = match morphic_core::Engine::new(&root) {
            Ok(e) => e,
            Err(e) => return err(&e.to_string()),
        };
        match engine.create_workspace_from_csv(bytes, &title, &id, &now) {
            Ok(doc) => serde_json::to_string(&doc).unwrap_or_else(|_| err("serialize")),
            Err(e) => err(&e.to_string()),
        }
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
        let engine = match morphic_core::Engine::new(&root) {
            Ok(e) => e,
            Err(e) => return err(&e.to_string()),
        };
        match engine.list_workspaces() {
            Ok(list) => serde_json::to_string(&list).unwrap_or_else(|_| err("serialize")),
            Err(e) => err(&e.to_string()),
        }
    })
}

/// Load a persisted workspace document by id (the "reopen" half of the PoC).
///
/// # Safety
/// `storage_root` and `workspace_id` must be valid C strings.
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
        let engine = match morphic_core::Engine::new(&root) {
            Ok(e) => e,
            Err(e) => return err(&e.to_string()),
        };
        match engine.load_workspace(&id) {
            Ok(doc) => serde_json::to_string(&doc).unwrap_or_else(|_| err("serialize")),
            Err(e) => err(&e.to_string()),
        }
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

    /// Read a returned C string and free it.
    unsafe fn take(ptr: *mut c_char) -> String {
        let s = CStr::from_ptr(ptr).to_str().unwrap().to_string();
        morphic_free_string(ptr);
        s
    }

    #[test]
    fn engine_info_returns_json() {
        let ptr = morphic_engine_info();
        assert!(!ptr.is_null());
        let s = unsafe { take(ptr) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["engine"], "morphic");
        assert_eq!(v["apiVersion"], 1);
    }

    #[test]
    fn profile_csv_returns_profile() {
        let csv = b"a,b\n1,x\n2,y\n";
        let ptr = unsafe { morphic_profile_csv(csv.as_ptr(), csv.len()) };
        let s = unsafe { take(ptr) };
        let v: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(v["rowCount"], 2);
        assert_eq!(v["fieldCount"], 2);
    }

    #[test]
    fn null_input_is_error_not_crash() {
        let ptr = unsafe { morphic_profile_csv(std::ptr::null(), 0) };
        let s = unsafe { take(ptr) };
        assert!(s.contains("error"));
    }

    #[test]
    fn free_null_is_safe() {
        unsafe { morphic_free_string(std::ptr::null_mut()) };
    }
}
