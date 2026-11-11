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
//!   rename, so a crash in between is recoverable rather than lost. Since M1.5 the journal is
//!   also the **bounded undo history**: compaction keeps the last `HISTORY_LIMIT` states
//!   instead of deleting them, so undo depth survives a restart.
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

pub mod bundle;
pub use bundle::{
    decode_bundle, encode_bundle, hex_decode, hex_encode, BundleDataset, BundleEnvelope,
    BundleExport, BundleImportOutcome, BundleManifest, BUNDLE_FORMAT,
};

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
    #[error("invalid .morphic bundle: {0}")]
    Bundle(String),
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

/// Maximum number of document states kept on disk for undo (doc 06 §3).
pub const HISTORY_LIMIT: usize = 100;

/// One write-ahead journal record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JournalEntry {
    pub revision: u64,
    /// The command batch that produced this state. Stored as JSON because this crate cannot
    /// depend on `morphic-core` (DAG rule); the engine only uses it for provenance.
    #[serde(default)]
    pub commands: serde_json::Value,
    /// The whole document at this revision. Small (kilobytes) and enough to reconstruct
    /// authoritative state after a crash or to undo one step.
    #[serde(default)]
    pub doc: Option<WorkspaceDoc>,
    /// Short description of the batch, shown in the app bar's snackbar.
    #[serde(default)]
    pub label: String,
    /// What a future `undo()` of this state would do (doc 06 §3).
    #[serde(default, rename = "inverseSummary")]
    pub inverse_summary: String,
    /// Hash of the semantic state, with volatile bookkeeping excluded.
    #[serde(default, rename = "stateHash")]
    pub state_hash: String,
}

/// A stable hash of the *semantic* workspace state.
///
/// `revision` and `modifiedAt` are volatile bookkeeping: undoing and redoing must not change
/// the hash of the state a person is looking at (AT-13). Everything else — components,
/// bindings, filters, sort, search, layout, field overrides — is part of the state.
pub fn state_hash(doc: &WorkspaceDoc) -> String {
    let mut value = serde_json::to_value(doc).unwrap_or(serde_json::Value::Null);
    if let Some(ws) = value.get_mut("workspace").and_then(|v| v.as_object_mut()) {
        ws.remove("revision");
        ws.remove("modifiedAt");
    }
    let bytes = serde_json::to_vec(&value).unwrap_or_default();
    format!("{:x}", Sha256::digest(bytes))
}

/// One undoable state in the engine's bounded history.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryFrame {
    pub revision: u64,
    pub doc: WorkspaceDoc,
    #[serde(default)]
    pub commands: serde_json::Value,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub inverse_summary: String,
    #[serde(default)]
    pub state_hash: String,
}

/// The persisted undo/redo stacks. `frames[cursor]` is the current state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryState {
    #[serde(default)]
    pub cursor: usize,
    #[serde(default)]
    pub frames: Vec<HistoryFrame>,
}

impl HistoryState {
    /// A fresh workspace has exactly one state and nothing to undo.
    pub fn seed(doc: &WorkspaceDoc) -> Self {
        let frame = HistoryFrame {
            revision: doc.workspace.revision,
            doc: doc.clone(),
            commands: serde_json::json!([]),
            label: "Imported workspace".to_string(),
            inverse_summary: String::new(),
            state_hash: state_hash(doc),
        };
        HistoryState {
            cursor: 0,
            frames: vec![frame],
        }
    }

    /// Repair a history file that is missing, corrupt or out of step with the authoritative
    /// document. A crash between the journal and this file must never resurrect a future
    /// state: the document's own hash decides which frame is current.
    pub fn reconcile(mut self, doc: &WorkspaceDoc) -> Self {
        if self.frames.is_empty() || self.cursor >= self.frames.len() {
            return HistoryState::seed(doc);
        }
        let hash = state_hash(doc);
        if self.frames[self.cursor].state_hash == hash
            && self.frames[self.cursor].revision == doc.workspace.revision
        {
            self.trim_to_limit();
            return self;
        }
        // Prefer an exact (hash, revision) match. A crash between the history file and the
        // document may leave the revision stale, in which case the semantic hash still finds
        // the right frame without resurrecting a different state that merely looks alike.
        let exact = self
            .frames
            .iter()
            .position(|f| f.state_hash == hash && f.revision == doc.workspace.revision);
        let found = exact.or_else(|| self.frames.iter().position(|f| f.state_hash == hash));
        if let Some(i) = found {
            let frame = &mut self.frames[i];
            frame.doc = doc.clone();
            frame.revision = doc.workspace.revision;
            frame.state_hash = hash;
            self.cursor = i;
            self.trim_to_limit();
            return self;
        }
        HistoryState::seed(doc)
    }

    /// Drop redo states, append one new frame and keep at most `HISTORY_LIMIT` states.
    pub fn push_frame(&mut self, frame: HistoryFrame) {
        self.frames.truncate(self.cursor + 1);
        self.frames.push(frame);
        self.cursor = self.frames.len() - 1;
        self.trim_to_limit();
    }

    fn trim_to_limit(&mut self) {
        let excess = self.frames.len().saturating_sub(HISTORY_LIMIT);
        if excess > 0 {
            self.frames.drain(..excess);
            self.cursor = self.cursor.saturating_sub(excess);
        }
    }

    pub fn undo_depth(&self) -> usize {
        self.cursor
    }

    pub fn redo_depth(&self) -> usize {
        self.frames.len().saturating_sub(self.cursor + 1)
    }

    pub fn undo_label(&self) -> String {
        self.frames
            .get(self.cursor)
            .map(|f| f.label.clone())
            .unwrap_or_default()
    }

    pub fn redo_label(&self) -> String {
        self.cursor
            .checked_add(1)
            .and_then(|i| self.frames.get(i))
            .map(|f| f.label.clone())
            .unwrap_or_default()
    }
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
    /// A missing or unreadable `library.json` was rebuilt from the workspace folders.
    pub rebuilt_library_index: bool,
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

    fn history_path(&self, id: &str) -> PathBuf {
        self.workspace_dir(id).join("history.json")
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

    /// Whether an authoritative document exists for this id. Used by library duplication to
    /// refuse an id collision before any file is written.
    pub fn exists(&self, id: &str) -> bool {
        self.doc_path(id).exists()
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
                label: String::new(),
                inverse_summary: String::new(),
                state_hash: String::new(),
            },
        )
    }

    /// Write-ahead record of a document revision, fsynced before the caller renames the
    /// authoritative file. Kept for the crash-recovery tests and older callers.
    pub fn journal_revision(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        self.append_history(doc, serde_json::json!([]), "", "")
    }

    /// Append one durable document state with the batch that produced it.
    pub fn append_history(
        &self,
        doc: &WorkspaceDoc,
        commands: serde_json::Value,
        label: &str,
        inverse_summary: &str,
    ) -> Result<(), StoreError> {
        self.append_entry(
            &doc.workspace.id,
            &JournalEntry {
                revision: doc.workspace.revision,
                commands,
                doc: Some(doc.clone()),
                label: label.to_string(),
                inverse_summary: inverse_summary.to_string(),
                state_hash: state_hash(doc),
            },
        )
    }

    /// Read the undo/redo stacks, repairing them against [current] if a crash left them stale.
    pub fn read_history(
        &self,
        id: &str,
        current: &WorkspaceDoc,
    ) -> Result<HistoryState, StoreError> {
        let path = self.history_path(id);
        if !path.exists() {
            return Ok(HistoryState::seed(current));
        }
        let bytes = fs::read(&path)?;
        let parsed: HistoryState =
            serde_json::from_slice(&bytes).unwrap_or_else(|_| HistoryState::seed(current));
        Ok(parsed.reconcile(current))
    }

    pub fn write_history(&self, id: &str, state: &HistoryState) -> Result<(), StoreError> {
        let bytes = serde_json::to_vec_pretty(state)?;
        atomic_write(&self.history_path(id), &bytes)
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

    /// Keep only the newest `keep_last` states. A torn trailing line is dropped here too:
    /// `read_journal` never returns it, so the rewrite is clean.
    pub fn compact_journal(&self, id: &str, keep_last: usize) -> Result<(), StoreError> {
        let (entries, _) = self.read_journal(id)?;
        let start = entries.len().saturating_sub(keep_last);
        let keep = &entries[start..];
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
                    self.compact_journal(id, HISTORY_LIMIT)?;
                }
                Ok((doc, report))
            }
            (base, Some(entry)) => {
                let doc = entry.doc.clone().expect("filtered on is_some");
                if had_file && base.is_none() {
                    // The base was unparseable but the journal can rebuild it. Keep the bad
                    // bytes for diagnosis instead of overwriting the only evidence.
                    let quarantine = self.workspace_dir(id).join("workspace.corrupt.json");
                    fs::rename(&path, &quarantine)?;
                    report.quarantined = true;
                }
                // A crash after the journal append but before the rename: promote the journal.
                atomic_write(&path, &serde_json::to_vec_pretty(&doc)?)?;
                self.compact_journal(id, HISTORY_LIMIT)?;
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
                    // The error is the signal here; there is no report to return.
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
        {
            let Some(ds) = doc.workspace.data_sources.first() else {
                return Ok(false);
            };
            if ds.dataset_id == hash {
                // Already repointed (a previous migration was interrupted after the write).
                fs::remove_file(&legacy)?;
                return Ok(false);
            }
        }
        // One-version rollback copy (docs/architecture/06 §5). Write it *before* the
        // datasetId is repointed: if the process dies between these two atomic writes the
        // original document is still recoverable by hand, rather than being overwritten.
        let backup = self.workspace_dir(id).join("workspace.pre-v1.json.bak");
        if !backup.exists() {
            atomic_write(&backup, &serde_json::to_vec_pretty(&doc)?)?;
        }
        doc.workspace.data_sources[0].dataset_id = hash;
        self.checkpoint(&doc)?;
        fs::remove_file(&legacy)?;
        Ok(true)
    }

    /// Export one workspace plus every source it references as a self-contained `.morphic`
    /// JSON envelope (M1.5 task 1.5.6). Dataset bytes are hex-encoded and hash-verified on
    /// import; no ZIP dependency is added to the supply chain.
    pub fn export_bundle(&self, id: &str, exported_at: &str) -> Result<BundleExport, StoreError> {
        let doc = self.load_workspace(id)?;
        let mut datasets = Vec::new();
        for ds in &doc.workspace.data_sources {
            let path = self.dataset_path(&ds.dataset_id);
            let bytes =
                fs::read(&path).map_err(|_| StoreError::SourceUnavailable(id.to_string()))?;
            datasets.push((ds.dataset_id.clone(), bytes));
        }
        encode_bundle(&doc, &datasets, exported_at)
    }

    /// Import a `.morphic` envelope under a fresh workspace id. The bundle's manifest is
    /// checked, every dataset hash is verified, and the document is re-seeded at revision 1.
    pub fn import_bundle(
        &self,
        bytes: &[u8],
        new_id: &str,
        title: &str,
        now_iso: &str,
    ) -> Result<BundleImportOutcome, StoreError> {
        let decoded = decode_bundle(bytes)?;
        if new_id.trim().is_empty() || title.trim().is_empty() {
            return Err(StoreError::Bundle(
                "import needs a workspace id and title".into(),
            ));
        }
        if self.exists(new_id) {
            return Err(StoreError::Bundle(format!(
                "workspace '{new_id}' already exists"
            )));
        }
        for source in &decoded.datasets {
            let stored = self.put_dataset(&source.bytes)?;
            if stored != source.hash {
                return Err(StoreError::Bundle(format!(
                    "dataset '{}' was stored under a different hash",
                    source.hash
                )));
            }
        }
        let mut doc = decoded.workspace;
        doc.workspace.id = new_id.to_string();
        doc.workspace.title = title.trim().to_string();
        doc.workspace.created_at = now_iso.to_string();
        doc.workspace.modified_at = now_iso.to_string();
        doc.workspace.revision = 1;
        self.save_workspace(&doc)?;
        self.write_history(new_id, &HistoryState::seed(&doc))?;
        Ok(BundleImportOutcome {
            doc,
            source_title: decoded.manifest.title,
            dataset_count: decoded.manifest.dataset_count,
        })
    }

    /// An explicit autosave checkpoint (M1.5 task 1.5.4). The engine already writes the
    /// authoritative document on every command, so this does not introduce a debounced write
    /// window that could lose data; it rewrites the document, refreshes the index and folds
    /// the journal, then acknowledges the flush to the UI.
    pub fn checkpoint(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        let id = &doc.workspace.id;
        fs::create_dir_all(self.workspace_dir(id))?;
        atomic_write(&self.doc_path(id), &serde_json::to_vec_pretty(doc)?)?;
        self.index(doc)?;
        self.compact_journal(id, HISTORY_LIMIT)?;
        Ok(())
    }

    /// Ids of every workspace folder on disk, sorted. Reading the folders rather than
    /// `library.json` means a torn index cannot hide a workspace from startup recovery.
    pub fn workspace_ids(&self) -> Result<Vec<String>, StoreError> {
        let dir = self.root.join("workspaces");
        if !dir.exists() {
            return Ok(Vec::new());
        }
        let mut ids = Vec::new();
        for entry in fs::read_dir(&dir)? {
            let entry = entry?;
            if entry.path().is_dir() {
                ids.push(entry.file_name().to_string_lossy().into_owned());
            }
        }
        ids.sort();
        Ok(ids)
    }

    /// Remove orphaned `*.tmp` files left by interrupted writes. Returns the count swept.
    /// Called on startup before any workspace is opened.
    pub fn recover(&self) -> Result<usize, StoreError> {
        let mut swept = 0;
        sweep_tmp(&self.root, &mut swept)?;
        Ok(swept)
    }

    /// Full startup recovery across the whole store (M1.5 task 1.5.4). Sweeps interrupted
    /// writes, replays newer journal revisions, quarantines unreadable documents, migrates
    /// pre-1.1.6 sources and rebuilds a torn index from the folders on disk — then returns
    /// *what it did* so the app can show it instead of silently repairing. Idempotent: a
    /// second call on a healthy store reports clean.
    pub fn recover_startup(&self) -> Result<RecoveryReport, StoreError> {
        let mut report = RecoveryReport::default();
        sweep_tmp(&self.root, &mut report.swept_tmp)?;
        let ids = self.workspace_ids()?;
        let torn_index = self.library_is_torn() && !ids.is_empty();
        for id in ids {
            match self.recover_workspace(&id) {
                Ok(found) => {
                    report.torn_journal_lines += found.torn_journal_lines;
                    report.restored_from_journal |= found.restored_from_journal;
                    report.quarantined |= found.quarantined;
                }
                // `resolve` quarantines the bad bytes *before* returning Corrupt, so the
                // startup sweep still has to tell the user it happened.
                Err(StoreError::Corrupt(_)) => report.quarantined = true,
                Err(_) => {}
            }
            if let Ok(true) = self.migrate_legacy_source(&id) {
                report.migrated_legacy_source = true;
            }
            // Rebuild the index from authoritative docs. `read_library` tolerates a torn
            // index by returning an empty one, which would otherwise hide every workspace
            // until its next save. Doing this here makes startup repair complete.
            if let Ok(doc) = self.load_workspace(&id) {
                self.index(&doc)?;
            }
        }
        report.rebuilt_library_index = torn_index;
        Ok(report)
    }

    /// Whether `library.json` is missing or unparseable. A missing index on an empty store is
    /// not damage; the caller only reports a rebuild when workspace folders exist.
    fn library_is_torn(&self) -> bool {
        match fs::read(self.library_path()) {
            Ok(bytes) => serde_json::from_slice::<Library>(&bytes).is_err(),
            Err(e) => e.kind() == std::io::ErrorKind::NotFound,
        }
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

impl FileStore {
    /// Persist a state and its producing batch in one write-ahead transaction.
    pub fn save_history(
        &self,
        doc: &WorkspaceDoc,
        commands: serde_json::Value,
        label: &str,
        inverse_summary: &str,
    ) -> Result<(), StoreError> {
        let id = &doc.workspace.id;
        fs::create_dir_all(self.workspace_dir(id))?;
        // Write-ahead: the journal record is durable before the authoritative rename, so a
        // crash in between is recoverable rather than a lost save.
        self.append_history(doc, commands, label, inverse_summary)?;
        atomic_write(&self.doc_path(id), &serde_json::to_vec_pretty(doc)?)?;
        self.index(doc)?;
        self.compact_journal(id, HISTORY_LIMIT)?;
        Ok(())
    }
}

impl WorkspaceStore for FileStore {
    fn save_workspace(&self, doc: &WorkspaceDoc) -> Result<(), StoreError> {
        self.save_history(doc, serde_json::json!([]), "", "")
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
                field_overrides: vec![],
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
                    state: Default::default(),
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
        // save_workspace now writes one history state before the two explicit appends.
        assert_eq!(entries.len(), 3);
        assert_eq!(torn, 0);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn save_keeps_a_bounded_journal_instead_of_deleting_it() {
        let (s, root) = store();
        for rev in 1..=5 {
            s.save_workspace(&doc_at("w1", rev, "2026-11-05T00:00:00Z"))
                .unwrap();
        }
        // M1.5: the journal is the undo history, not just a crash-recovery scratch pad.
        let (entries, torn) = s.read_journal("w1").unwrap();
        assert_eq!(torn, 0);
        assert_eq!(entries.len(), 5);
        assert_eq!(entries.last().unwrap().revision, 5);
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 5);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn compaction_caps_the_journal_at_the_history_limit() {
        let (s, root) = store();
        for rev in 1..=(HISTORY_LIMIT as u64 + 5) {
            s.save_workspace(&doc_at("w1", rev, "2026-11-05T00:00:00Z"))
                .unwrap();
        }
        let (entries, _) = s.read_journal("w1").unwrap();
        assert_eq!(entries.len(), HISTORY_LIMIT);
        assert_eq!(entries.first().unwrap().revision, 6);
        assert_eq!(entries.last().unwrap().revision, HISTORY_LIMIT as u64 + 5);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn state_hash_ignores_revision_and_modified_at() {
        let (s, root) = store();
        let mut a = doc_at("w1", 1, "2026-11-05T00:00:00Z");
        let b = doc_at("w1", 2, "2026-11-06T00:00:00Z");
        assert_eq!(state_hash(&a), state_hash(&b));
        a.workspace.title = "Changed".into();
        assert_ne!(state_hash(&a), state_hash(&b));
        // Keep `s` used so the store helper stays honest.
        s.save_workspace(&a).unwrap();
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
        let (entries, _) = s.read_journal("w1").unwrap();
        assert_eq!(entries.len(), 2, "bounded history retained after replay");
        assert_eq!(entries.last().unwrap().revision, 2);
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
        // One entry from save_workspace, one from journal_revision, one torn line.
        assert_eq!(entries.len(), 2);
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
        assert!(
            report.quarantined,
            "recovering must not destroy the corrupt bytes"
        );
        let kept = s.workspace_dir("w1").join("workspace.corrupt.json");
        assert_eq!(fs::read(&kept).unwrap(), b"{ not json at all".to_vec());
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 4);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn corrupt_json_with_no_journal_is_quarantined_and_reported() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        fs::write(s.doc_path("w1"), b"garbage").unwrap();
        // save_workspace now retains a bounded history journal. Delete it so this test still
        // exercises the "unparseable document with nothing to rebuild from" branch.
        fs::remove_file(s.journal_path("w1")).unwrap();
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

    // --- M1.5 task 1.5.4: kill-mid-save chaos suite -------------------------------------

    /// Fault injection, not a literal process kill: each case reproduces the exact on-disk
    /// state a crash at that point would leave, then asks startup recovery to repair it.
    /// Running this in CI is stronger than a nightly cron that has never fired.
    #[test]
    fn startup_recovery_reports_every_crash_window() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        // A kill after the journal append but before the document rename.
        s.journal_revision(&doc_at("w1", 7, "2026-11-05T07:00:00Z"))
            .unwrap();
        // A torn trailing line from a write interrupted halfway.
        let journal = s.journal_path("w1");
        let mut bytes = fs::read(&journal).unwrap();
        bytes.extend(b"{\"revision\":8,\"doc\":");
        fs::write(&journal, bytes).unwrap();
        // An orphaned tmp file from an interrupted atomic rename.
        let orphan = root.join("datasets").join("partial.tmp");
        fs::write(&orphan, b"partial").unwrap();
        // A pre-1.1.6 workspace whose source still lives beside the document.
        let mut old = doc("w_legacy");
        old.workspace.data_sources[0].dataset_id = "w_legacy".into();
        fs::create_dir_all(s.workspace_dir("w_legacy")).unwrap();
        fs::write(
            s.doc_path("w_legacy"),
            serde_json::to_vec_pretty(&old).unwrap(),
        )
        .unwrap();
        fs::write(s.legacy_source_path("w_legacy"), b"a,b\n1,2\n").unwrap();

        let report = s.recover_startup().unwrap();
        assert_eq!(report.swept_tmp, 1, "the interrupted write is discarded");
        assert_eq!(report.torn_journal_lines, 1, "the torn record is counted");
        assert!(
            report.restored_from_journal,
            "the lost revision is promoted"
        );
        assert!(
            report.migrated_legacy_source,
            "the legacy source is migrated"
        );
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 7);
        assert!(
            s.workspace_dir("w_legacy")
                .join("workspace.pre-v1.json.bak")
                .exists(),
            "a one-version rollback copy is kept"
        );
        // Recovery is idempotent: a second startup on a healthy store reports nothing.
        assert!(s.recover_startup().unwrap().is_clean());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn startup_recovery_rebuilds_a_torn_library_index() {
        let (s, root) = store();
        s.save_workspace(&doc("w1")).unwrap();
        s.save_workspace(&doc("w2")).unwrap();
        fs::write(s.root.join("library.json"), b"{ torn").unwrap();

        let report = s.recover_startup().unwrap();
        assert!(
            report.rebuilt_library_index,
            "a torn index must be reported as repaired"
        );
        assert_eq!(
            s.list_workspaces().unwrap().len(),
            2,
            "every folder must be visible again"
        );
        assert!(s.recover_startup().unwrap().is_clean());
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn startup_recovery_quarantines_an_unreadable_document() {
        let (s, root) = store();
        s.save_workspace(&doc("w_bad")).unwrap();
        fs::write(s.doc_path("w_bad"), b"{ not json").unwrap();
        fs::remove_file(s.journal_path("w_bad")).unwrap();

        let report = s.recover_startup().unwrap();
        assert!(report.quarantined, "startup must report the quarantine");
        assert!(
            s.workspace_dir("w_bad")
                .join("workspace.corrupt.json")
                .exists(),
            "the bad bytes are kept for diagnosis"
        );
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_explicit_checkpoint_leaves_no_torn_journal() {
        let (s, root) = store();
        let mut d = doc("w1");
        s.save_workspace(&d).unwrap();
        d.workspace.revision = 5;
        s.checkpoint(&d).unwrap();
        let (entries, torn) = s.read_journal("w1").unwrap();
        assert_eq!(torn, 0);
        assert_eq!(entries.len(), 1, "the journal stays bounded");
        assert_eq!(s.load_workspace("w1").unwrap().workspace.revision, 5);
        fs::remove_dir_all(&root).ok();
    }

    // --- M1.5 task 1.5.6: .morphic bundle export/import ----------------------------------

    #[test]
    fn hex_roundtrip_is_exact_and_rejects_bad_input() {
        let bytes = b"\x00\x0f\x10\xff,eu\n";
        assert_eq!(hex_decode(&hex_encode(bytes)).unwrap(), bytes.to_vec());
        assert!(hex_decode("abc").is_err(), "odd length is rejected");
        assert!(hex_decode("zz").is_err(), "non-hex is rejected");
    }

    #[test]
    fn a_bundle_roundtrip_restores_the_document_and_source_bytes() {
        let (s, root) = store();
        let source = b"region,amount\neu,10\nus,20\n";
        let hash = s.put_dataset(source).unwrap();
        let mut d = doc("w1");
        d.workspace.data_sources[0].dataset_id = hash.clone();
        s.save_workspace(&d).unwrap();

        let export = s.export_bundle("w1", "2026-11-05T08:00:00Z").unwrap();
        assert_eq!(export.manifest.format, BUNDLE_FORMAT);
        assert_eq!(export.manifest.dataset_count, 1);
        assert_eq!(export.manifest.workspace_id, "w1");
        assert!(export.json.contains(BUNDLE_FORMAT));

        let imported = s
            .import_bundle(
                export.json.as_bytes(),
                "w2",
                "Imported workspace",
                "2026-11-05T09:00:00Z",
            )
            .unwrap();
        assert_eq!(imported.doc.workspace.id, "w2");
        assert_eq!(imported.doc.workspace.title, "Imported workspace");
        assert_eq!(imported.doc.workspace.revision, 1);
        assert_eq!(imported.source_title, "Workspace w1");
        assert_eq!(imported.dataset_count, 1);
        assert_eq!(s.load_source("w2").unwrap(), source.to_vec());
        assert!(s.exists("w2"));
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_tampered_bundle_is_refused_before_any_workspace_is_written() {
        let (s, root) = store();
        let source = b"region,amount\neu,10\n";
        let hash = s.put_dataset(source).unwrap();
        let mut d = doc("w1");
        d.workspace.data_sources[0].dataset_id = hash;
        s.save_workspace(&d).unwrap();
        let export = s.export_bundle("w1", "2026-11-05T08:00:00Z").unwrap();

        let mut envelope: BundleEnvelope = serde_json::from_str(&export.json).unwrap();
        envelope.datasets[0].content_hex = hex_encode(b"tampered,source\n1,2\n");
        let bad = serde_json::to_string(&envelope).unwrap();
        let err = s
            .import_bundle(bad.as_bytes(), "w2", "Bad", "2026-11-05T09:00:00Z")
            .unwrap_err();
        assert!(
            matches!(err, StoreError::Bundle(_)),
            "expected a typed bundle error, got {err}"
        );
        assert!(!s.exists("w2"), "a bad bundle must write nothing");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_wrong_manifest_dataset_count_is_refused_before_any_write() {
        let (s, root) = store();
        let hash = s.put_dataset(b"region,amount\neu,10\n").unwrap();
        let mut d = doc("w1");
        d.workspace.data_sources[0].dataset_id = hash;
        s.save_workspace(&d).unwrap();
        let export = s.export_bundle("w1", "2026-11-05T08:00:00Z").unwrap();

        let mut envelope: BundleEnvelope = serde_json::from_str(&export.json).unwrap();
        envelope.manifest.dataset_count = 2;
        let bad = serde_json::to_string(&envelope).unwrap();
        let err = s
            .import_bundle(bad.as_bytes(), "w2", "Bad", "2026-11-05T09:00:00Z")
            .unwrap_err();
        assert!(
            matches!(err, StoreError::Bundle(_)),
            "expected a typed bundle error, got {err}"
        );
        assert!(!s.exists("w2"), "a bad manifest must write nothing");
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
