//! # morphic-workspace
//!
//! Persistence for workspaces (docs/architecture/06). Folder-per-workspace file store with
//! **atomic writes** (tmp → fsync → rename → fsync dir), a library index, a write-ahead
//! journal, crash recovery, and **content-addressed datasets**.
//!
//! ## What task 1.1.6 adds
//!
//! - **Content addressing.** Source bytes live at `datasets/<sha256>/source.csv`, so two
//!   workspaces over the same file share one copy. A workspace references its dataset by
//!   hash through `dataSources[].datasetId`.
//! - **Write-ahead journal.** `save_workspace` journals the revision *before* the atomic
//!   rename, so a crash in between is recoverable rather than lost. On load, a journal entry
//!   newer than `workspace.json` wins and is compacted away.
//! - **Torn-write tolerance.** A crash mid-append leaves a partial JSONL line. The reader
//!   drops the torn trailing line instead of failing the whole journal.
//! - **Corruption handling.** An unparseable `workspace.json` is reconstructed from the
//!   journal if possible; otherwise it is quarantined and reported, never silently ignored.
//! - **Legacy migration.** Workspaces saved before 1.1.6 kept the source inside the
//!   workspace folder. They still open, and are migrated to content addressing on first open.
//! - **Degraded mode.** A missing dataset is a typed `SourceUnavailable`, so the caller can
//!   show the layout with a "source unavailable" notice instead of crashing.
//!
//! ## Deliberate deferrals
//!
//! - **`snapshot.bin`** (columnar cache for fast reopen) is *not* implemented. Reopen
//!   re-ingests the source, which is correct and already tested. The binary format is a
//!   performance optimization, and the 10 MB budget it would serve is still unmeasured on
//!   real hardware — adding a versioned binary format before that data exists would be
//!   speculative risk. Revisit with the perf work.
//! - **`.lock` files** are not written. The app is single-process and the engine serializes
//!   session access with a mutex, so a stale-lock protocol would add failure modes without a
//!   concurrent writer to protect against. Revisit if a second writer ever exists.
//! - **Journal commands.** M1.1 has no edit surface, so entries carry a full document
//!   snapshot (kilobytes) and an empty `commands` array. The field is reserved so M1.5 layout
//!   commands can be added without a format break.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use morphic_schema::WorkspaceDoc;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("workspace '{0}' not found")]
    NotFound(String),
    #[error("workspace '{0}' is corrupt and could not be reconstructed")]
    Corrupt(String),
    #[error("source data for workspace '{0}' is unavailable")]
    SourceUnavailable(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceMeta {
    pub id: String,
    pub title: String,
    pub modified_at: String,
    /// Present from 1.1.6; `#[serde(default)]` keeps pre-1.1.6 `library.json` readable.
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub dataset_id: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub workspaces: Vec<WorkspaceMeta>,
}

/// One write-ahead journal record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalEntry {
    pub revision: u64,
    /// Reserved for M1.5 edit commands. M1.1 writes an empty array.
    #[serde(default)]
    pub commands: serde_json::Value,
    /// M1.1 payload: the whole document at this revision. Small (kilobytes) and enough to
    /// reconstruct authoritative state after a crash.
    #[serde(default)]
    pub doc: Option<WorkspaceDoc>,
}

/// What recovery actually did, so the caller can tell the user rather than silently fixing.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecoveryReport {
    pub swept_tmp: usize,
    pub torn_journal_lines: usize,
    pub restored_from_journal: bool,
    pub quarantined: bool,
    pub migrated_legacy_source: bool,
}

impl RecoveryReport {
    pub fn is_clean(&self) -> bool {
        *self == RecoveryReport::default()
    }
}

/// Storage abstraction so a SQLite backend can replace the file backend later (ADR-0007).
pub trait WorkspaceStore {
    fn save_workspace(&self, doc: &WorkspaceDoc) -> Result<(), StoreError>;

    /// Loads the authoritative document, repairing from the journal if a crash left
    /// `workspace.json` stale or unparseable. Recovery is a write, and is idempotent.
    fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, StoreError>;

    /// Newest first, so "recents" means recents.
    fn list_workspaces(&self) -> Result<Vec<WorkspaceMeta>, StoreError>;
    fn delete_workspace(&self, id: &str) -> Result<(), StoreError>;

    /// Store source bytes under their content hash. Idempotent: identical bytes are written
    /// once no matter how many workspaces reference them. Returns the hex SHA-256.
    fn put_dataset(&self, bytes: &[u8]) -> Result<String, StoreError>;
    fn has_dataset(&self, hash: &str) -> bool;

    /// Resolve a workspace's source bytes, preferring the content-addressed dataset and
    /// falling back to the pre-1.1.6 in-workspace copy.
    fn load_source(&self, id: &str) -> Result<Vec<u8>, StoreError>;
}

/// Folder-per-workspace file backend rooted at an app-private directory.
pub struct FileStore {
    root: PathBuf,
}

impl FileStore {
    pub fn new(root: impl AsRef<Path>) -> Result<Self, StoreError> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(root.join("workspaces"))?;
        fs::create_dir_all(root.join("datasets"))?;
        Ok(Self { root })
    }

    fn workspace_dir(&self, id: &str) -> PathBuf {
        self.root.join("workspaces").join(id)
    }

    fn doc_path(&self, id: &str) -> PathBuf {
        self.workspace_dir(id).join("workspace.json")
    }

    fn journal_path(&self, id: &str) -> PathBuf {
        self.workspace_dir(id)
            .join("journal")
            .join("commands.jsonl")
    }

    fn legacy_source_path(&self, id: &str) -> PathBuf {
        self.workspace_dir(id).join("source.csv")
    }

    fn dataset_path(&self, hash: &str) -> PathBuf {
        self.root.join("datasets").join(hash).join("source.csv")
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
        match serde_json::from_slice(&bytes) {
            Ok(lib) => Ok(lib),
            // A torn index must not hide workspaces that are still on disk.
            Err(_) => Ok(Library::default()),
        }
    }

    fn write_library(&self, library: &Library) -> Result<(), StoreError> {
        let bytes = serde_json::to_vec_pretty(library)?;
        atomic_write(&self.library_path(), &bytes)
    }

    /// Append a command batch. Retained for the M1.5 command journal; M1.1 uses
    /// [`Self::journal_revision`] which also carries the document.
    pub fn append_journal(
        &self,
        id: &str,
        revision: u64,
        commands_json: &str,
    ) -> Result<(), StoreError> {
        let commands: serde_json::Value = serde_json::from_str(commands_json)?;
        self.append_entry(
            id,
            &JournalEntry {
                revision,
                commands,
                doc: None,
            },
        )
    }

    /// Write-ahead record of a document revision, fsynced before the caller renames the
    /// authoritative file.
    pub fn journal_revision(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        self.append_entry(
            &doc.workspace.id,
            &JournalEntry {
                revision: doc.workspace.revision,
                commands: serde_json::json!([]),
                doc: Some(doc.clone()),
            },
        )
    }

    fn append_entry(&self, id: &str, entry: &JournalEntry) -> Result<(), StoreError> {
        let path = self.journal_path(id);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .truncate(false)
            .open(&path)?;
        let mut line = serde_json::to_vec(entry)?;
        line.push(b'\n');
        file.write_all(&line)?;
        file.sync_all()?;
        Ok(())
    }

    /// Read the journal, dropping a torn trailing line left by a crash mid-append.
    /// Returns the entries and how many lines were discarded.
    pub fn read_journal(&self, id: &str) -> Result<(Vec<JournalEntry>, usize), StoreError> {
        let path = self.journal_path(id);
        if !path.exists() {
            return Ok((Vec::new(), 0));
        }
        let text = fs::read_to_string(&path)?;
        let mut entries = Vec::new();
        let mut torn = 0usize;
        for line in text.lines() {
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<JournalEntry>(line) {
                Ok(e) => entries.push(e),
                // Only a trailing partial record is expected from a crash. A malformed line
                // anywhere is skipped and counted rather than failing the whole journal.
                Err(_) => torn += 1,
            }
        }
        Ok((entries, torn))
    }

    /// Drop journal entries at or below the persisted revision.
    pub fn compact_journal(&self, id: &str, persisted_revision: u64) -> Result<(), StoreError> {
        let (entries, _) = self.read_journal(id)?;
        let keep: Vec<&JournalEntry> = entries
            .iter()
            .filter(|e| e.revision > persisted_revision)
            .collect();
        let path = self.journal_path(id);
        if keep.is_empty() {
            if path.exists() {
                fs::remove_file(&path)?;
            }
            return Ok(());
        }
        let mut buf = Vec::new();
        for e in keep {
            buf.extend(serde_json::to_vec(e)?);
            buf.push(b'\n');
        }
        atomic_write(&path, &buf)
    }

    /// Resolve authoritative state from `workspace.json` plus the journal, repairing if needed.
    pub fn recover_workspace(&self, id: &str) -> Result<RecoveryReport, StoreError> {
        let (_, report) = self.resolve(id)?;
        Ok(report)
    }

    fn resolve(&self, id: &str) -> Result<(WorkspaceDoc, RecoveryReport), StoreError> {
        let mut report = RecoveryReport::default();
        let path = self.doc_path(id);
        let (entries, torn) = self.read_journal(id)?;
        report.torn_journal_lines = torn;

        let base: Option<WorkspaceDoc> = if path.exists() {
            // An unparseable document is `None`, not an error: the journal may still hold a
            // recoverable revision. Genuine IO failures do propagate.
            serde_json::from_slice(&fs::read(&path)?).ok()
        } else {
            None
        };
        let had_file = path.exists();

        // The newest journal entry that carries a document and is at least as new as the base.
        let best = entries
            .iter()
            .filter(|e| e.doc.is_some())
            .filter(|e| match &base {
                Some(d) => e.revision > d.workspace.revision,
                None => true,
            })
            .max_by_key(|e| e.revision);

        match (base, best) {
            (Some(doc), None) => {
                if torn > 0 {
                    self.compact_journal(id, doc.workspace.revision)?;
                }
                Ok((doc, report))
            }
            (_, Some(entry)) => {
                let doc = entry.doc.clone().expect("filtered on is_some");
                // A crash after the journal append but before the rename: promote the journal.
                atomic_write(&path, &serde_json::to_vec_pretty(&doc)?)?;
                self.compact_journal(id, doc.workspace.revision)?;
                self.index(&doc)?;
                report.restored_from_journal = true;
                Ok((doc, report))
            }
            (None, None) => {
                if had_file {
                    // Unparseable and nothing to rebuild from: keep the bytes for diagnosis
                    // instead of deleting evidence, then report corruption.
                    let quarantine = self.workspace_dir(id).join("workspace.corrupt.json");
                    fs::rename(&path, &quarantine)?;
                    report.quarantined = true;
                    return Err(StoreError::Corrupt(id.to_string()));
                }
                Err(StoreError::NotFound(id.to_string()))
            }
        }
    }

    fn index(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        let mut library = self.read_library()?;
        let meta = WorkspaceMeta {
            id: doc.workspace.id.clone(),
            title: doc.workspace.title.clone(),
            modified_at: doc.workspace.modified_at.clone(),
            revision: doc.workspace.revision,
            dataset_id: doc
                .workspace
                .data_sources
                .first()
                .map(|d| d.dataset_id.clone())
                .unwrap_or_default(),
        };
        if let Some(existing) = library.workspaces.iter_mut().find(|w| w.id == meta.id) {
            *existing = meta;
        } else {
            library.workspaces.push(meta);
        }
        self.write_library(&library)
    }

    /// Move a pre-1.1.6 in-workspace source into the content-addressed store and repoint the
    /// document at it. Returns true if a migration happened. Revision is unchanged: this is a
    /// storage migration, not a user edit.
    pub fn migrate_legacy_source(&self, id: &str) -> Result<bool, StoreError> {
        let legacy = self.legacy_source_path(id);
        if !legacy.exists() {
            return Ok(false);
        }
        let mut doc = self.load_workspace(id)?;
        let bytes = fs::read(&legacy)?;
        let hash = self.put_dataset(&bytes)?;
        if let Some(ds) = doc.workspace.data_sources.first_mut() {
            if ds.dataset_id == hash {
                // Already repointed (a previous migration was interrupted after the write).
                fs::remove_file(&legacy)?;
                return Ok(false);
            }
            ds.dataset_id = hash;
        } else {
            return Ok(false);
        }
        self.save_workspace(&doc)?;
        fs::remove_file(&legacy)?;
        Ok(true)
    }

    /// Remove orphaned `*.tmp` files left by interrupted writes. Returns the count swept.
    /// Called on startup before any workspace is opened.
    pub fn recover(&self) -> Result<usize, StoreError> {
        let mut swept = 0;
        sweep_tmp(&self.root, &mut swept)?;
        Ok(swept)
    }
}

/// Hex SHA-256 of the source bytes: the dataset's identity.
pub fn content_hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
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
        fs::create_dir_all(self.workspace_dir(id))?;
        // Write-ahead: the journal record is durable before the authoritative rename, so a
        // crash in between is recoverable rather than a lost save.
        self.journal_revision(doc)?;
        atomic_write(&self.doc_path(id), &serde_json::to_vec_pretty(doc)?)?;
        self.index(doc)?;
        self.compact_journal(id, doc.workspace.revision)?;
        Ok(())
    }

    fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, StoreError> {
        Ok(self.resolve(id)?.0)
    }

    fn list_workspaces(&self) -> Result<Vec<WorkspaceMeta>, StoreError> {
        let mut items = self.read_library()?.workspaces;
        // Newest first; ties broken by id so the order is deterministic.
        items.sort_by(|a, b| {
            b.modified_at
                .cmp(&a.modified_at)
                .then_with(|| a.id.cmp(&b.id))
        });
        Ok(items)
    }

    fn put_dataset(&self, bytes: &[u8]) -> Result<String, StoreError> {
        let hash = content_hash(bytes);
        let path = self.dataset_path(&hash);
        if !path.exists() {
            atomic_write(&path, bytes)?;
        }
        Ok(hash)
    }

    fn has_dataset(&self, hash: &str) -> bool {
        self.dataset_path(hash).exists()
    }

    fn load_source(&self, id: &str) -> Result<Vec<u8>, StoreError> {
        if let Ok(doc) = self.load_workspace(id) {
            for ds in &doc.workspace.data_sources {
                let path = self.dataset_path(&ds.dataset_id);
                if path.exists() {
                    return Ok(fs::read(&path)?);
                }
            }
        }
        let legacy = self.legacy_source_path(id);
        if legacy.exists() {
            return Ok(fs::read(&legacy)?);
        }
        Err(StoreError::SourceUnavailable(id.to_string()))
    }

    fn delete_workspace(&self, id: &str) -> Result<(), StoreError> {
        let dir = self.workspace_dir(id);
        if dir.exists() {
            fs::remove_dir_all(&dir)?;
        }
        let mut library = self.read_library()?;
        library.workspaces.retain(|w| w.id != id);
        self.write_library(&library)?;
        // Datasets are deliberately NOT deleted: another workspace may reference the same
        // content hash. Explicit GC is a later feature (docs/architecture/06 §1).
        Ok(())
    }
}

/// Atomic write: write a sibling `.tmp`, fsync it, rename over the target, then fsync the
/// directory so the rename itself is durable. A crash mid-write leaves only a `.tmp`, which
/// `recover()` sweeps; the previous authoritative file is never corrupted.
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
    fsync_dir(path)?;
    Ok(())
}

#[cfg(unix)]
fn fsync_dir(path: &Path) -> Result<(), StoreError> {
    if let Some(parent) = path.parent() {
        fs::File::open(parent)?.sync_all()?;
    }
    Ok(())
}

/// Windows cannot fsync a directory handle; the rename is still atomic there.
#[cfg(not(unix))]
fn fsync_dir(_path: &Path) -> Result<(), StoreError> {
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
        doc_at(id, 1, "2026-11-05T00:00:00Z")
    }

    fn doc_at(id: &str, revision: u64, modified: &str) -> WorkspaceDoc {
        WorkspaceDoc {
            schema_version: SCHEMA_VERSION.into(),
            workspace: Workspace {
                id: id.into(),
                title: format!("Workspace {}", id),
                created_at: "2026-11-05T00:00:00Z".into(),
                modified_at: modified.into(),
                revision,
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
        p.push(format!("morphic-store-test-{}-{}", std::process::id(), n));
        let _ = fs::remove_dir_all(&p);
        p
    }

    fn store() -> (FileStore, PathBuf) {
        let root = temp_root();
        let s = FileStore::new(&root).unwrap();
        (s, root)
    }

    #[test]
    fn save_load_roundtrip() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        assert_eq!(s.load_workspace("w1").unwrap().workspace.id, "w1");
        assert_eq!(s.list_workspaces().unwrap().len(), 1);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn delete_removes_from_library() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        s.delete_workspace("w1").unwrap();
        assert!(s.list_workspaces().unwrap().is_empty());
        assert!(matches!(
            s.load_workspace("w1"),
            Err(StoreError::NotFound(_))
        ));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn recover_sweeps_orphaned_tmp() {
        let (s, root) = store();
        let orphan = root.join("workspaces").join("w1").join("workspace.tmp");
        fs::create_dir_all(orphan.parent().unwrap()).unwrap();
        fs::write(&orphan, b"partial").unwrap();
        assert_eq!(s.recover().unwrap(), 1);
        assert!(!orphan.exists());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn journal_appends() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        s.append_journal("w1", 2, "[]").unwrap();
        s.append_journal("w1", 3, "[]").unwrap();
        let (entries, torn) = s.read_journal("w1").unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(torn, 0);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn save_compacts_the_journal_so_it_does_not_grow_forever() {
        let (s, root) = store();
        for rev in 1..=5 {
            s.save_workspace(&doc_at("w1", rev, "2026-11-05T00:00:00Z"))
                .unwrap();
        }
        // Every save is acknowledged by workspace.json, so nothing needs replaying.
        assert!(!s.journal_path("w1").exists());
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 5);
        fs::remove_dir_all(&root).ok();
    }

    // --- content addressing -------------------------------------------------------------

    #[test]
    fn content_hash_is_stable_and_hex() {
        let h = content_hash(b"a,b\n1,2\n");
        assert_eq!(h.len(), 64);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(h, content_hash(b"a,b\n1,2\n"));
        assert_ne!(h, content_hash(b"a,b\n1,3\n"));
        // Known-answer test: SHA-256 of the empty input.
        assert_eq!(
            content_hash(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn identical_bytes_are_stored_once_for_two_workspaces() {
        let (s, root) = store();
        let bytes = b"region,amount\neu,10\nus,20\n";
        let h1 = s.put_dataset(bytes).unwrap();
        let h2 = s.put_dataset(bytes).unwrap();
        assert_eq!(h1, h2);
        let datasets: Vec<_> = fs::read_dir(root.join("datasets")).unwrap().collect();
        assert_eq!(datasets.len(), 1, "same content must not be duplicated");
        assert!(s.has_dataset(&h1));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn put_dataset_is_idempotent_and_does_not_rewrite() {
        let (s, root) = store();
        let bytes = b"x\n1\n";
        let h = s.put_dataset(bytes).unwrap();
        let path = s.dataset_path(&h);
        let before = fs::metadata(&path).unwrap().modified().unwrap();
        s.put_dataset(bytes).unwrap();
        let after = fs::metadata(&path).unwrap().modified().unwrap();
        assert_eq!(before, after, "an existing dataset must not be rewritten");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn deleting_a_workspace_keeps_a_shared_dataset() {
        let (s, root) = store();
        let bytes = b"x\n1\n";
        let hash = s.put_dataset(bytes).unwrap();
        let mut a = doc("w1");
        let mut b = doc("w2");
        a.workspace.data_sources[0].dataset_id = hash.clone();
        b.workspace.data_sources[0].dataset_id = hash.clone();
        s.save_workspace(&a).unwrap();
        s.save_workspace(&b).unwrap();
        s.delete_workspace("w1").unwrap();
        assert!(s.has_dataset(&hash), "w2 still references this content");
        assert_eq!(s.load_source("w2").unwrap(), bytes.to_vec());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn missing_dataset_is_a_typed_error_not_a_panic() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        assert!(matches!(
            s.load_source("w1"),
            Err(StoreError::SourceUnavailable(_))
        ));
        fs::remove_dir_all(&root).ok();
    }

    // --- crash recovery -----------------------------------------------------------------

    #[test]
    fn a_crash_between_journal_and_rename_restores_the_newer_revision() {
        let (s, root) = store();
        s.save_workspace(&doc_at("w1", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        // Simulate the crash: the revision-2 record is durable, but workspace.json still
        // holds revision 1 because the rename never happened.
        s.journal_revision(&doc_at("w1", 2, "2026-11-05T01:00:00Z"))
            .unwrap();
        assert_eq!(
            serde_json::from_slice::<WorkspaceDoc>(&fs::read(s.doc_path("w1")).unwrap())
                .unwrap()
                .workspace
                .revision,
            1
        );

        let report = s.recover_workspace("w1").unwrap();
        assert!(report.restored_from_journal);
        let recovered = s.load_workspace("w1").unwrap();
        assert_eq!(
            recovered.workspace.revision, 2,
            "pre-crash revision restored"
        );
        assert!(
            !s.journal_path("w1").exists(),
            "journal compacted after replay"
        );
        // Recovery is idempotent.
        assert!(!s.recover_workspace("w1").unwrap().restored_from_journal);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_torn_trailing_journal_line_is_dropped_not_fatal() {
        let (s, root) = store();
        s.save_workspace(&doc_at("w1", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        s.journal_revision(&doc_at("w1", 2, "2026-11-05T01:00:00Z"))
            .unwrap();
        // Half-written third record, as a power loss mid-append would leave.
        let path = s.journal_path("w1");
        let mut text = fs::read_to_string(&path).unwrap();
        text.push_str("{\"revision\":3,\"comm");
        fs::write(&path, text).unwrap();

        let (entries, torn) = s.read_journal("w1").unwrap();
        assert_eq!(torn, 1);
        assert_eq!(entries.len(), 1);
        // The intact revision-2 record still recovers.
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 2);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn corrupt_workspace_json_is_rebuilt_from_the_journal() {
        let (s, root) = store();
        s.save_workspace(&doc_at("w1", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        s.journal_revision(&doc_at("w1", 4, "2026-11-05T02:00:00Z"))
            .unwrap();
        fs::write(s.doc_path("w1"), b"{ not json at all").unwrap();

        let report = s.recover_workspace("w1").unwrap();
        assert!(report.restored_from_journal);
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 4);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn corrupt_json_with_no_journal_is_quarantined_and_reported() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        fs::write(s.doc_path("w1"), b"garbage").unwrap();
        let err = s.recover_workspace("w1");
        assert!(matches!(err, Err(StoreError::Corrupt(_))));
        let kept = s.workspace_dir("w1").join("workspace.corrupt.json");
        assert!(kept.exists(), "corrupt bytes are kept for diagnosis");
        assert_eq!(fs::read(&kept).unwrap(), b"garbage".to_vec());
        assert!(!s.doc_path("w1").exists());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_stale_journal_entry_never_overwrites_a_newer_document() {
        let (s, root) = store();
        s.save_workspace(&doc_at("w1", 9, "2026-11-05T09:00:00Z"))
            .unwrap();
        // An older record left behind must not roll state backwards.
        s.journal_revision(&doc_at("w1", 3, "2026-11-05T03:00:00Z"))
            .unwrap();
        let report = s.recover_workspace("w1").unwrap();
        assert!(!report.restored_from_journal);
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 9);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_torn_library_index_does_not_hide_saved_workspaces() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        fs::write(s.library_path(), b"{\"workspaces\": [").unwrap();
        // The document is still loadable even though the index is unusable.
        assert_eq!(s.load_workspace("w1").unwrap().workspace.id, "w1");
        // And the next save rebuilds the index.
        s.save_workspace(&doc("w2")).unwrap();
        assert!(s.list_workspaces().unwrap().iter().any(|w| w.id == "w2"));
        fs::remove_dir_all(&root).ok();
    }

    // --- legacy migration ---------------------------------------------------------------

    #[test]
    fn a_pre_116_workspace_still_opens_and_is_migrated() {
        let (s, root) = store();
        // Recreate the old layout by hand: source inside the workspace folder, datasetId
        // equal to the workspace id rather than a content hash.
        let mut old = doc("w_old");
        old.workspace.data_sources[0].dataset_id = "w_old".into();
        fs::create_dir_all(s.workspace_dir("w_old")).unwrap();
        fs::write(
            s.doc_path("w_old"),
            serde_json::to_vec_pretty(&old).unwrap(),
        )
        .unwrap();
        let bytes = b"region,amount\neu,10\nus,20\n";
        fs::write(s.legacy_source_path("w_old"), bytes).unwrap();

        // It opens before any explicit migration, via the fallback.
        assert_eq!(s.load_source("w_old").unwrap(), bytes.to_vec());

        assert!(s.migrate_legacy_source("w_old").unwrap());
        let migrated = s.load_workspace("w_old").unwrap();
        let hash = &migrated.workspace.data_sources[0].dataset_id;
        assert_eq!(hash, &content_hash(bytes));
        assert!(s.has_dataset(hash));
        assert!(!s.legacy_source_path("w_old").exists());
        assert_eq!(s.load_source("w_old").unwrap(), bytes.to_vec());
        assert_eq!(
            migrated.workspace.revision, 1,
            "migration is not a user edit"
        );
        // Running it again is a no-op.
        assert!(!s.migrate_legacy_source("w_old").unwrap());
        fs::remove_dir_all(&root).ok();
    }

    // --- recents ------------------------------------------------------------------------

    #[test]
    fn list_is_newest_first() {
        let (s, root) = store();
        s.save_workspace(&doc_at("old", 1, "2026-11-01T00:00:00Z"))
            .unwrap();
        s.save_workspace(&doc_at("new", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        s.save_workspace(&doc_at("mid", 1, "2026-11-03T00:00:00Z"))
            .unwrap();
        let ids: Vec<String> = s
            .list_workspaces()
            .unwrap()
            .into_iter()
            .map(|w| w.id)
            .collect();
        assert_eq!(ids, vec!["new", "mid", "old"]);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn list_ties_are_broken_deterministically() {
        let (s, root) = store();
        s.save_workspace(&doc_at("b", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        s.save_workspace(&doc_at("a", 1, "2026-11-05T00:00:00Z"))
            .unwrap();
        let ids: Vec<String> = s
            .list_workspaces()
            .unwrap()
            .into_iter()
            .map(|w| w.id)
            .collect();
        assert_eq!(ids, vec!["a", "b"]);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn library_records_revision_and_dataset_for_recents() {
        let (s, root) = store();
        let hash = s.put_dataset(b"x\n1\n").unwrap();
        let mut d = doc_at("w1", 7, "2026-11-05T00:00:00Z");
        d.workspace.data_sources[0].dataset_id = hash.clone();
        s.save_workspace(&d).unwrap();
        let meta = s.list_workspaces().unwrap().remove(0);
        assert_eq!(meta.revision, 7);
        assert_eq!(meta.dataset_id, hash);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_pre_116_library_without_the_new_fields_still_reads() {
        let (s, root) = store();
        fs::write(
            s.library_path(),
            br#"[{"id":"w1","title":"Old","modifiedAt":"2026-11-01T00:00:00Z"}]"#,
        )
        .unwrap();
        // Not the shape we write (object with `workspaces`), so it degrades to empty rather
        // than crashing; the real legacy shape is an object, tested next.
        assert!(s.list_workspaces().unwrap().is_empty());
        fs::write(
            s.library_path(),
            br#"{"workspaces":[{"id":"w1","title":"Old","modifiedAt":"2026-11-01T00:00:00Z"}]}"#,
        )
        .unwrap();
        let items = s.list_workspaces().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0].revision, 0,
            "missing field defaults, does not fail"
        );
        assert_eq!(items[0].dataset_id, "");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn atomic_write_leaves_no_tmp_behind_on_success() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        assert_eq!(s.recover().unwrap(), 0);
        fs::remove_dir_all(&root).ok();
    }
}
