//! # morphic-workspace
//!
//! Persistence for workspaces (docs/architecture/06). Phase 0 implements the
//! folder-per-workspace file store with **atomic writes** (tmp → rename), a library
//! index, an append-only command journal, and a crash-recovery sweep.
//!
//! Dataset content-addressing, snapshot binaries, undo/redo replay, and migrations land
//! in M1.1 / M1.5. The `WorkspaceStore` trait keeps a future SQLite backend swappable.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use morphic_schema::WorkspaceDoc;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("workspace '{0}' not found")]
    NotFound(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceMeta {
    pub id: String,
    pub title: String,
    pub modified_at: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub workspaces: Vec<WorkspaceMeta>,
}

/// Storage abstraction so a SQLite backend can replace the file backend later (ADR-0007).
pub trait WorkspaceStore {
    fn save_workspace(&self, doc: &WorkspaceDoc) -> Result<(), StoreError>;
    fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, StoreError>;
    fn list_workspaces(&self) -> Result<Vec<WorkspaceMeta>, StoreError>;
    fn delete_workspace(&self, id: &str) -> Result<(), StoreError>;
}

/// Folder-per-workspace file backend rooted at an app-private directory.
pub struct FileStore {
    root: PathBuf,
}

impl FileStore {
    pub fn new(root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("workspaces"))?;
        Ok(Self { root })
    }

    fn workspace_dir(&self, id: &str) -> PathBuf {
        self.root.join("workspaces").join(id)
    }

    fn library_path(&self) -> PathBuf {
        self.root.join("library.json")
    }

    fn read_library(&self) -> Result<Library, StoreError> {
        let path = self.library_path();
        if !path.exists() {
            return Ok(Library::default());
        }
        let bytes = fs::read(&path)?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    fn write_library(&self, library: &Library) -> Result<(), StoreError> {
        let bytes = serde_json::to_vec_pretty(library)?;
        atomic_write(&self.library_path(), &bytes)
    }

    /// Append a command batch to the workspace journal (crash-safe append).
    pub fn append_journal(
        &self,
        id: &str,
        revision: u64,
        commands_json: &str,
    ) -> Result<(), StoreError> {
        let dir = self.workspace_dir(id).join("journal");
        fs::create_dir_all(&dir)?;
        let path = dir.join("commands.jsonl");
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        writeln!(
            file,
            "{{\"revision\":{},\"commands\":{}}}",
            revision, commands_json
        )?;
        Ok(())
    }

    /// Remove orphaned `*.tmp` files left by interrupted writes. Returns the count swept.
    /// Called on startup before any workspace is opened.
    pub fn recover(&self) -> Result<usize, StoreError> {
        let mut swept = 0;
        sweep_tmp(&self.root, &mut swept)?;
        Ok(swept)
    }
}

fn sweep_tmp(dir: &Path, swept: &mut usize) -> Result<(), StoreError> {
    if !dir.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let meta = entry.metadata()?;
        if meta.is_dir() {
            sweep_tmp(&path, swept)?;
        } else if path.extension().map(|e| e == "tmp").unwrap_or(false) {
            fs::remove_file(&path)?;
            *swept += 1;
        }
    }
    Ok(())
}

impl WorkspaceStore for FileStore {
    fn save_workspace(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        let id = &doc.workspace.id;
        let dir = self.workspace_dir(id);
        fs::create_dir_all(&dir)?;
        let bytes = serde_json::to_vec_pretty(doc)?;
        atomic_write(&dir.join("workspace.json"), &bytes)?;

        let mut library = self.read_library()?;
        let meta = WorkspaceMeta {
            id: id.clone(),
            title: doc.workspace.title.clone(),
            modified_at: doc.workspace.modified_at.clone(),
        };
        if let Some(existing) = library.workspaces.iter_mut().find(|w| &w.id == id) {
            *existing = meta;
        } else {
            library.workspaces.push(meta);
        }
        self.write_library(&library)?;
        Ok(())
    }

    fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, StoreError> {
        let path = self.workspace_dir(id).join("workspace.json");
        if !path.exists() {
            return Err(StoreError::NotFound(id.to_string()));
        }
        let bytes = fs::read(&path)?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    fn list_workspaces(&self) -> Result<Vec<WorkspaceMeta>, StoreError> {
        Ok(self.read_library()?.workspaces)
    }

    fn delete_workspace(&self, id: &str) -> Result<(), StoreError> {
        let dir = self.workspace_dir(id);
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        let mut library = self.read_library()?;
        library.workspaces.retain(|w| w.id != id);
        self.write_library(&library)?;
        Ok(())
    }
}

/// Atomic write: write to a sibling `.tmp`, flush, then rename over the target.
/// A crash mid-write leaves only a `.tmp`, which `recover()` sweeps; the previous
/// authoritative file is never corrupted.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), StoreError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("tmp");
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_schema::{
        Aggregation, Binding, ComponentSpec, DataSourceRef, Generator, Interactions, Layout,
        Workspace, WorkspaceDoc, SCHEMA_VERSION,
    };

    fn doc(id: &str) -> WorkspaceDoc {
        WorkspaceDoc {
            schema_version: SCHEMA_VERSION.into(),
            workspace: Workspace {
                id: id.into(),
                title: format!("Workspace {}", id),
                created_at: "2026-11-05T00:00:00Z".into(),
                modified_at: "2026-11-05T00:00:00Z".into(),
                revision: 1,
                generator: Generator {
                    kind: "deterministic".into(),
                    version: "0.1.0".into(),
                },
                data_sources: vec![DataSourceRef {
                    alias: "data".into(),
                    dataset_id: "d1".into(),
                }],
                layout: Layout {
                    mode: "adaptive".into(),
                    order: vec!["m1".into()],
                    hints: vec![],
                },
                global_filters: vec![],
                components: vec![ComponentSpec {
                    id: "m1".into(),
                    component_type: "metric_card".into(),
                    type_version: "1.0".into(),
                    title: None,
                    data_source: "data".into(),
                    binding: Binding::MetricCard {
                        aggregation: Aggregation {
                            op: "count".into(),
                            field: None,
                            filter: None,
                        },
                    },
                    interactions: Interactions::default(),
                    explanation: None,
                }],
            },
        }
    }

    fn temp_root() -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let mut p = std::env::temp_dir();
        p.push(format!("morphic-test-{}-{}", std::process::id(), n));
        p
    }

    #[test]
    fn save_load_roundtrip() {
        let root = temp_root();
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc("w1")).unwrap();
        let loaded = store.load_workspace("w1").unwrap();
        assert_eq!(loaded.workspace.id, "w1");
        assert_eq!(store.list_workspaces().unwrap().len(), 1);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn delete_removes_from_library() {
        let root = temp_root();
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc("w1")).unwrap();
        store.delete_workspace("w1").unwrap();
        assert!(store.list_workspaces().unwrap().is_empty());
        assert!(matches!(
            store.load_workspace("w1"),
            Err(StoreError::NotFound(_))
        ));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn recover_sweeps_orphaned_tmp() {
        let root = temp_root();
        let store = FileStore::new(&root).unwrap();
        // Simulate a crash mid-write: an orphaned .tmp with no authoritative file.
        let orphan = root.join("workspaces").join("w1").join("workspace.tmp");
        fs::create_dir_all(orphan.parent().unwrap()).unwrap();
        fs::write(&orphan, b"partial").unwrap();
        let swept = store.recover().unwrap();
        assert_eq!(swept, 1);
        assert!(!orphan.exists());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn journal_appends() {
        let root = temp_root();
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc("w1")).unwrap();
        store.append_journal("w1", 2, "[]").unwrap();
        store.append_journal("w1", 3, "[]").unwrap();
        let journal = root
            .join("workspaces")
            .join("w1")
            .join("journal")
            .join("commands.jsonl");
        let content = fs::read_to_string(journal).unwrap();
        assert_eq!(content.lines().count(), 2);
        fs::remove_dir_all(&root).ok();
    }
}
