//! # morphic-core
//!
//! The engine facade (docs/architecture/01). It composes the subsystem crates and owns
//! sessions, commands, undo/redo, and events.
//!
//! **Phase 0 status:** the vertical-slice proof of concept is real — CSV bytes in, a
//! validated + persisted `WorkspaceDoc` out. Session/command/event machinery arrives in
//! M1.1–M1.3. This crate contains no business logic that belongs in a subsystem.

use std::path::Path;

use morphic_model::DatasetProfile;
use morphic_schema::WorkspaceDoc;
use morphic_workspace::{FileStore, StoreError, WorkspaceStore};
use serde::Serialize;
use thiserror::Error;

/// Bridge contract version. Bumped on breaking FFI changes (docs/architecture/02 §5).
pub const API_VERSION: u32 = 1;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("ingest: {0}")]
    Ingest(#[from] morphic_ingest::IngestError),
    #[error("store: {0}")]
    Store(#[from] StoreError),
    #[error("generated workspace failed validation: {0}")]
    Validation(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EngineInfo {
    pub api_version: u32,
    pub core_version: String,
    pub engine: String,
}

pub fn engine_info() -> EngineInfo {
    EngineInfo {
        api_version: API_VERSION,
        core_version: env!("CARGO_PKG_VERSION").to_string(),
        engine: "morphic".to_string(),
    }
}

/// Parse + profile CSV bytes without touching storage (the data-processing PoC).
pub fn profile_csv_bytes(bytes: &[u8]) -> Result<DatasetProfile, CoreError> {
    let (table, _report) = morphic_ingest::parse_csv(bytes)?;
    Ok(morphic_semantic::profile(&table))
}

/// The engine handle. Holds the workspace store rooted at an app-private directory.
pub struct Engine {
    store: FileStore,
}

impl Engine {
    pub fn new(storage_root: impl AsRef<Path>) -> Result<Self, CoreError> {
        let store = FileStore::new(storage_root)?;
        // Crash-recovery sweep before anything is opened (docs/architecture/06 §2).
        store.recover()?;
        Ok(Self { store })
    }

    /// The Phase 0 vertical slice: CSV → analyze → compile → validate → persist.
    pub fn create_workspace_from_csv(
        &self,
        bytes: &[u8],
        title: &str,
        workspace_id: &str,
        now_iso: &str,
    ) -> Result<WorkspaceDoc, CoreError> {
        let (table, _report) = morphic_ingest::parse_csv(bytes)?;
        let profile = morphic_semantic::profile(&table);
        let doc = morphic_compiler::compile(
            &profile,
            "dataset_poc", // Phase 0: datasets are not yet content-addressed (M1.1)
            workspace_id,
            title,
            now_iso,
        );
        let issues = morphic_schema::validate(&doc);
        if !issues.is_empty() {
            let msg = issues
                .iter()
                .map(|i| format!("{}: {}", i.pointer, i.rule))
                .collect::<Vec<_>>()
                .join("; ");
            return Err(CoreError::Validation(msg));
        }
        self.store.save_workspace(&doc)?;
        Ok(doc)
    }

    pub fn list_workspaces(&self) -> Result<Vec<morphic_workspace::WorkspaceMeta>, CoreError> {
        Ok(self.store.list_workspaces()?)
    }

    pub fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, CoreError> {
        Ok(self.store.load_workspace(id)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_info_has_version() {
        let info = engine_info();
        assert_eq!(info.api_version, API_VERSION);
        assert_eq!(info.engine, "morphic");
    }

    #[test]
    fn profile_csv_poc() {
        let csv = b"a,b\n1,x\n2,y\n";
        let profile = profile_csv_bytes(csv).unwrap();
        assert_eq!(profile.row_count, 2);
        assert_eq!(profile.field_count, 2);
    }

    #[test]
    fn vertical_slice_creates_valid_workspace() {
        let mut root = std::env::temp_dir();
        root.push(format!("morphic-core-test-{}", std::process::id()));
        let engine = Engine::new(&root).unwrap();
        let csv =
            b"time,level,value\n2026-11-05T10:00:00Z,ERROR,1.5\n2026-11-05T10:01:00Z,INFO,2.5\n";
        let doc = engine
            .create_workspace_from_csv(csv, "Logs", "w_poc", "2026-11-05T00:00:00Z")
            .unwrap();
        assert!(morphic_schema::validate(&doc).is_empty());
        // metric + timeline + table
        assert_eq!(doc.workspace.components.len(), 3);
        // reopen
        let loaded = engine.load_workspace("w_poc").unwrap();
        assert_eq!(loaded.workspace.id, "w_poc");
        std::fs::remove_dir_all(&root).ok();
    }
}
