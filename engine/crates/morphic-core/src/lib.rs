//! # morphic-core
//!
//! The engine facade (docs/architecture/01). It composes the subsystem crates and owns
//! sessions, commands, undo/redo, and events.
//!
//! **M1.1 (task 1.1.4):** real sessions. An import retains the typed `Table` + profile +
//! generated document in memory, so `queryPage` and `metricData` execute against canonical
//! Rust state instead of re-parsing. Reopening a workspace rehydrates the session from the
//! content-addressed source. Undo/redo and the additive layout/field-override commands arrived
//! in M1.5.1; their full UI surfaces are later M1.5 tasks.
//!
//! **M1.1 (task 1.1.6):** datasets are content-addressed, opens replay the write-ahead
//! journal (so a crash mid-save restores the pre-crash revision), pre-1.1.6 workspaces are
//! migrated transparently, and a missing source opens in degraded mode instead of failing.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

pub mod commands;
mod plans;

pub use commands::Command;

use morphic_model::{DatasetProfile, ImportReport, Table};
use morphic_schema::WorkspaceDoc;
use morphic_workspace::{
    state_hash, FileStore, HistoryFrame, HistoryState, RecoveryReport, StoreError, WorkspaceStore,
};

/// Re-exported so the FFI bridge can create and trip a cancellation token without taking a
/// direct dependency on the ingest crate. Core stays the bridge's only engine surface.
pub use morphic_ingest::CancelToken;
use serde::Serialize;
use thiserror::Error;

/// Bridge contract version. Bumped on breaking FFI changes (docs/architecture/02 §5).
/// v2 adds sessions, queryPage, metricData, and snapshot (M1.1 task 1.1.4).
/// v5 adds applyCommands and componentPage (M1.3 task 1.3.3). Additive: every v4 entry point
/// still exists with the same shape, so an older client keeps working.
/// v7 adds `ChangeComponentType` to the command vocabulary and `typeOptions` to the
/// snapshot/import/apply payloads (M1.4 task 1.4.7). v8 adds `MoveComponent`,
/// `OverrideFieldType`, `OverrideFieldRole`, undo/redo entry points and history metadata on
/// snapshot/import/apply (M1.5 task 1.5.1). v9 adds `ResizeComponent` and its persisted
/// `layout.hints` record (M1.5 task 1.5.2). v10 adds the library lifecycle and source re-link
/// entry points (M1.5 task 1.5.3). v11 adds `ClearFieldOverride` and targeted recompilation of
/// the bindings affected by a field correction (M1.5 task 1.5.5). v12 adds the startup
/// recovery report and the explicit autosave checkpoint entry points (M1.5 task 1.5.4). New
/// entry points and commands are additive contract changes and are versioned with the bridge
/// (doc 02 §4).
pub const API_VERSION: u32 = 12;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("ingest: {0}")]
    Ingest(#[from] morphic_ingest::IngestError),
    #[error("store: {0}")]
    Store(#[from] StoreError),
    #[error("query: {0}")]
    Query(#[from] morphic_query::QueryError),
    #[error("generated workspace failed validation: {0}")]
    Validation(String),
    #[error("no open session for workspace '{0}'")]
    SessionNotFound(String),
    #[error("unknown component '{0}'")]
    UnknownComponent(String),
    #[error("component '{0}' is a {1}, which has no metric value")]
    NotAMetric(String, String),
    #[error("component '{0}' is a {1}, not a chart")]
    NotAChart(String, String),
    #[error("unsupported binding: {0}")]
    UnsupportedBinding(String),
    #[error("session state was poisoned by an earlier panic")]
    SessionPoisoned,
    #[error("source data for workspace '{0}' is unavailable")]
    SourceUnavailable(String),
    #[error("unknown format '{0}'; expected csv, json, jsonl, log or txt")]
    UnknownFormat(String),
    #[error("import cancelled")]
    Cancelled,
    #[error("command rejected: {0}")]
    Command(String),
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

/// A real progress event emitted during import.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportProgress {
    /// `sniffing` | `parsing` | `typing` | `done`
    pub phase: String,
    pub rows_read: u64,
    pub bytes_read: u64,
}

/// One import call. Bundled into a struct so the format hint and extension do not push
/// `import` past a readable argument count.
#[derive(Debug, Clone, Copy)]
pub struct ImportRequest<'a> {
    pub bytes: &'a [u8],
    pub title: &'a str,
    pub workspace_id: &'a str,
    pub now_iso: &'a str,
    /// `csv` | `json` | `jsonl` | `log` | `txt` (aliases accepted). `None` means auto-detect.
    pub format_hint: Option<&'a str>,
    /// The source file's extension, used only when no content probe was decisive.
    pub extension: Option<&'a str>,
    /// Cooperative cancellation. Checked during parsing and again immediately before the
    /// first byte is written, so a cancelled import leaves no dataset and no workspace.
    pub cancel: Option<&'a morphic_ingest::CancelToken>,
}

/// Everything an import produced. The document is already validated and persisted.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub doc: WorkspaceDoc,
    pub profile: DatasetProfile,
    pub report: ImportReport,
    /// The engine's compatibility matrix, per component id. The UI must not offer a switch
    /// the engine would refuse (docs/architecture/04 §4).
    pub type_options: std::collections::BTreeMap<String, Vec<String>>,
    pub state_hash: String,
    pub undo_depth: usize,
    pub redo_depth: usize,
    pub undo_label: String,
    pub redo_label: String,
}

/// A revisioned view of canonical state, as rendered by Flutter.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub doc: WorkspaceDoc,
    /// `None` in degraded mode: the layout is available but the data is not.
    pub profile: Option<DatasetProfile>,
    pub revision: u64,
    /// True when the source is missing or unparseable. The document still renders so the
    /// user can see what the workspace was, instead of getting a hard failure.
    pub degraded: bool,
    pub notice: Option<String>,
    /// Empty in degraded mode, where no profile exists to validate a converted binding.
    pub type_options: std::collections::BTreeMap<String, Vec<String>>,
    pub state_hash: String,
    pub undo_depth: usize,
    pub redo_depth: usize,
    pub undo_label: String,
    pub redo_label: String,
}

/// The computed value behind one `metric_card`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricResult {
    pub component_id: String,
    pub value: serde_json::Value,
    pub revision: u64,
}

/// A chart's pre-aggregated scene, at the revision that produced it.
///
/// The revision travels with the scene for the same reason it travels with a metric: the reader
/// must be able to tell which selection it is looking at (M1.3 task 1.3.5).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChartResult {
    pub component_id: String,
    pub scene: morphic_query::ChartScene,
    pub revision: u64,
}

/// What one committed command batch changed.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyOutcome {
    pub revision: u64,
    /// Components whose data may have changed, in layout order. Empty for a no-op batch.
    pub affected: Vec<String>,
    /// False when every command set a value that was already set: no revision, no save.
    pub changed: bool,
    pub doc: WorkspaceDoc,
    /// Recomputed after the batch, so a converted component immediately offers the switches
    /// that are valid for its *new* type.
    pub type_options: std::collections::BTreeMap<String, Vec<String>>,
    pub state_hash: String,
    pub undo_depth: usize,
    pub redo_depth: usize,
    pub undo_label: String,
    pub redo_label: String,
    /// Short description of what this result did, shown by the app bar's snackbar.
    pub label: String,
}

/// The acknowledgement behind an explicit autosave checkpoint.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveOutcome {
    pub revision: u64,
    pub state_hash: String,
    /// Always false: the checkpoint has folded the journal. Dart uses this to clear its own
    /// "unflushed checkpoint" flag; it never means "data was unsaved".
    pub dirty: bool,
    pub compacted: bool,
}

/// An open workspace: canonical Rust state that Flutter only renders.
struct Session {
    doc: WorkspaceDoc,
    table: Option<Table>,
    profile: Option<DatasetProfile>,
    notice: Option<String>,
    /// Engine-owned undo/redo stacks. Dart never reconstructs state itself (doc 06 §3).
    history: HistoryState,
    /// Revision of the *data*, not the document. Editing a filter bumps the document revision
    /// but not this one, which is what lets an untouched component keep its cached result.
    /// Bumped when the table is replaced (re-import or a field override, M1.5).
    data_revision: u64,
    pages: morphic_query::cache::ResultCache<morphic_query::Page>,
    metrics: morphic_query::cache::ResultCache<serde_json::Value>,
    charts: morphic_query::cache::ResultCache<morphic_query::ChartScene>,
    /// Actual engine executions per component. The evidence that a command recomputed only
    /// what it affected, rather than a claim that it did.
    computes: HashMap<String, u64>,
}

impl Session {
    fn new(
        doc: WorkspaceDoc,
        table: Option<Table>,
        profile: Option<DatasetProfile>,
        notice: Option<String>,
        history: HistoryState,
    ) -> Session {
        Session {
            doc,
            table,
            profile,
            notice,
            history,
            data_revision: 1,
            pages: morphic_query::cache::ResultCache::default(),
            metrics: morphic_query::cache::ResultCache::default(),
            charts: morphic_query::cache::ResultCache::default(),
            computes: HashMap::new(),
        }
    }

    fn bump_compute(&mut self, component_id: &str) {
        *self.computes.entry(component_id.to_string()).or_insert(0) += 1;
    }
}

/// The history fields carried by every bridge response. Computed from the engine's own
/// stacks and the authoritative document, never from a Dart-side guess.
#[derive(Debug, Clone)]
struct HistoryFacts {
    state_hash: String,
    undo_depth: usize,
    redo_depth: usize,
    undo_label: String,
    redo_label: String,
}

impl HistoryFacts {
    fn new(history: &HistoryState, doc: &WorkspaceDoc) -> Self {
        HistoryFacts {
            state_hash: state_hash(doc),
            undo_depth: history.undo_depth(),
            redo_depth: history.redo_depth(),
            undo_label: history.undo_label(),
            redo_label: history.redo_label(),
        }
    }
}

fn command_label(commands: &[Command]) -> String {
    if commands.len() != 1 {
        return format!("Applied {} changes", commands.len());
    }
    match &commands[0] {
        Command::SetGlobalFilter { .. } => "Changed global filters".into(),
        Command::SetComponentFilter { .. } => "Changed component filter".into(),
        Command::SetComponentSort { .. } => "Changed component sort".into(),
        Command::SetSearch { .. } => "Changed search".into(),
        Command::ChangeComponentType { .. } => "Changed component type".into(),
        Command::MoveComponent { .. } => "Moved component".into(),
        Command::ResizeComponent { .. } => "Resized component".into(),
        Command::OverrideFieldType { .. } => "Overrode field type".into(),
        Command::OverrideFieldRole { .. } => "Overrode field role".into(),
        Command::ClearFieldOverride { .. } => "Cleared field correction".into(),
    }
}

fn frame_for(
    doc: &WorkspaceDoc,
    commands: serde_json::Value,
    label: &str,
    inverse_summary: &str,
) -> HistoryFrame {
    HistoryFrame {
        revision: doc.workspace.revision,
        doc: doc.clone(),
        commands,
        label: label.to_string(),
        inverse_summary: inverse_summary.to_string(),
        state_hash: state_hash(doc),
    }
}

/// The engine handle. Owns the workspace store and the open sessions.
pub struct Engine {
    store: FileStore,
    sessions: Mutex<HashMap<String, Session>>,
    /// What startup recovery actually did. Captured once at construction, not recomputed on
    /// every call, so the app can show the user exactly one honest report per process start.
    recovery: RecoveryReport,
}

/// The UI's menu is engine-authoritative: it is exactly the set of switches whose converted
/// binding the engine can validate against the live profile. Degraded mode has no profile,
/// so it gets no switches rather than a menu that would fail on every tap.
fn type_options(
    doc: &WorkspaceDoc,
    profile: Option<&morphic_model::DatasetProfile>,
) -> std::collections::BTreeMap<String, Vec<String>> {
    let Some(p) = profile else {
        return std::collections::BTreeMap::new();
    };
    doc.workspace
        .components
        .iter()
        .map(|c| {
            (
                c.id.clone(),
                morphic_schema::component_type_options(c, p)
                    .into_iter()
                    .map(str::to_string)
                    .collect(),
            )
        })
        .collect()
}

impl Engine {
    pub fn new(storage_root: impl AsRef<Path>) -> Result<Self, CoreError> {
        let store = FileStore::new(storage_root)?;
        // Full startup recovery before anything is opened (docs/architecture/06 §2). The
        // report is retained so the UI can tell the user what was repaired rather than
        // silently fixing it (M1.5 task 1.5.4).
        let recovery = store.recover_startup()?;
        Ok(Self {
            store,
            sessions: Mutex::new(HashMap::new()),
            recovery,
        })
    }

    /// What startup recovery did on this engine instance. Clean means nothing needed repair.
    pub fn recovery_report(&self) -> RecoveryReport {
        self.recovery.clone()
    }

    /// Explicit autosave checkpoint (docs/architecture/06 §2). Every command already writes
    /// the authoritative document, so this does **not** introduce a debounced write window
    /// that could lose data: it rewrites the document, refreshes the index, folds the journal
    /// and acknowledges the flush. Dart calls it after its debounce and immediately on
    /// `AppLifecycleState.paused`.
    pub fn save(&self, workspace_id: &str) -> Result<SaveOutcome, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        self.store.checkpoint(&s.doc)?;
        Ok(SaveOutcome {
            revision: s.doc.workspace.revision,
            state_hash: state_hash(&s.doc),
            dirty: false,
            compacted: true,
        })
    }

    /// Import CSV, forcing the CSV parser. Retained for the PoC screen and older callers.
    pub fn import_csv(
        &self,
        bytes: &[u8],
        title: &str,
        workspace_id: &str,
        now_iso: &str,
        on_progress: &mut dyn FnMut(ImportProgress),
    ) -> Result<ImportOutcome, CoreError> {
        self.import(
            ImportRequest {
                bytes,
                title,
                workspace_id,
                now_iso,
                format_hint: Some("csv"),
                extension: None,
                cancel: None,
            },
            on_progress,
        )
    }

    /// Import any supported format: detect → parse → analyze → compile → validate → persist
    /// → retain an open session (M1.2 task 1.2.3).
    ///
    /// `on_progress` receives real events from the streaming parser. Pass a no-op closure
    /// when the caller does not need them.
    pub fn import(
        &self,
        req: ImportRequest<'_>,
        on_progress: &mut dyn FnMut(ImportProgress),
    ) -> Result<ImportOutcome, CoreError> {
        let ImportRequest {
            bytes,
            title,
            workspace_id,
            now_iso,
            format_hint,
            extension,
            cancel,
        } = req;
        let mut opts = morphic_ingest::IngestOptions::default();
        if let Some(hint) = format_hint {
            // An unrecognised hint is a caller error, not a silent fall back to sniffing.
            opts.format_hint = Some(
                morphic_ingest::detect::Format::parse(hint)
                    .ok_or_else(|| CoreError::UnknownFormat(hint.to_string()))?,
            );
        }
        opts.extension = extension.map(|s| s.to_string());
        let (table, report) = morphic_ingest::ingest_with(bytes, &opts, cancel, &mut |p| {
            on_progress(ImportProgress {
                phase: format!("{:?}", p.phase).to_lowercase(),
                rows_read: p.rows_read as u64,
                bytes_read: p.bytes_read,
            });
        })
        .map_err(|e| match e {
            // Normalise: a caller matching on CoreError must have exactly one cancellation
            // variant, whether the parser noticed first or the pre-write checkpoint did.
            morphic_ingest::IngestError::Cancelled => CoreError::Cancelled,
            other => CoreError::Ingest(other),
        })?;
        let profile = morphic_semantic::profile(&table);
        // Content-addressed: the dataset's identity is its hash, so importing the same file
        // twice stores one copy and two workspaces can share it. The hash is computed
        // *without writing* so the document can be compiled and validated before anything
        // touches disk.
        let dataset_id = morphic_workspace::content_hash(bytes);
        let doc = morphic_compiler::compile(&profile, &dataset_id, workspace_id, title, now_iso);
        // All five passes, including bindings checked against the real profile.
        let issues = morphic_schema::validate_with_profile(&doc, &profile);
        if !issues.is_empty() {
            let msg = issues
                .iter()
                .map(|i| format!("{}: {}", i.pointer, i.rule))
                .collect::<Vec<_>>()
                .join("; ");
            return Err(CoreError::Validation(msg));
        }
        // Last checkpoint before any I/O. Everything above is pure computation, so bailing
        // out here leaves the store exactly as it was — which is what AT-05 requires of a
        // cancelled import. It also means a validation failure no longer orphans a dataset.
        if cancel.is_some_and(|c| c.is_cancelled()) {
            return Err(CoreError::Cancelled);
        }
        self.store.put_dataset(bytes)?;
        self.store
            .save_history(&doc, serde_json::json!([]), "Imported workspace", "")?;
        let history = HistoryState::seed(&doc);
        // For an import the document must exist before the history file: a crash in between
        // is repaired by read_history seeding from the authoritative document on reopen.
        self.store.write_history(workspace_id, &history)?;
        let facts = HistoryFacts::new(&history, &doc);

        self.sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?
            .insert(
                workspace_id.to_string(),
                Session::new(
                    doc.clone(),
                    Some(table),
                    Some(profile.clone()),
                    None,
                    history,
                ),
            );

        Ok(ImportOutcome {
            type_options: type_options(&doc, Some(&profile)),
            doc,
            profile,
            report,
            state_hash: facts.state_hash,
            undo_depth: facts.undo_depth,
            redo_depth: facts.redo_depth,
            undo_label: facts.undo_label,
            redo_label: facts.redo_label,
        })
    }

    /// The Phase 0 entry point, kept so existing callers and the PoC screen still work.
    pub fn create_workspace_from_csv(
        &self,
        bytes: &[u8],
        title: &str,
        workspace_id: &str,
        now_iso: &str,
    ) -> Result<WorkspaceDoc, CoreError> {
        Ok(self
            .import_csv(bytes, title, workspace_id, now_iso, &mut |_| {})?
            .doc)
    }

    /// Reopen a persisted workspace and rehydrate its session from the content-addressed
    /// source. `load_workspace` replays the journal, so a crash before the last rename
    /// restores the pre-crash revision rather than losing the save.
    ///
    /// Re-ingesting on open remains a deliberate trade-off: one source of truth at the cost
    /// of a parse. A columnar `snapshot.bin` is deferred until the reopen cost is measured on
    /// real hardware (see the crate docs).
    ///
    /// A missing or unparseable source opens in **degraded mode**: the document and layout
    /// are returned with `degraded = true` and a notice, and data operations return a typed
    /// [`CoreError::SourceUnavailable`] instead of crashing.
    pub fn open_session(&self, workspace_id: &str) -> Result<Snapshot, CoreError> {
        // Workspaces saved before 1.1.6 kept the source in the workspace folder.
        self.store.migrate_legacy_source(workspace_id)?;
        let doc = self.store.load_workspace(workspace_id)?;

        // The stored source may be any supported format, so reopen runs the same detection
        // the import did. Forcing CSV here would corrupt every non-CSV workspace on reopen.
        let (table, profile, notice) = match self.store.load_source(workspace_id) {
            Ok(bytes) => match morphic_ingest::ingest(&bytes) {
                Ok((table, _report)) => {
                    let profile = morphic_semantic::profile(&table);
                    (Some(table), Some(profile), None)
                }
                Err(e) => (
                    None,
                    None,
                    Some(format!("the stored source could not be parsed: {e}")),
                ),
            },
            Err(StoreError::SourceUnavailable(_)) => (
                None,
                None,
                Some(
                    "the imported source file is no longer available; re-import the same \
                     file to restore the data"
                        .to_string(),
                ),
            ),
            Err(e) => return Err(e.into()),
        };

        // M1.5: the journal-bounded history file is reconciled against the authoritative
        // document, so a crash mid-save cannot make a future state current again.
        let history = self.store.read_history(workspace_id, &doc)?;
        self.store.write_history(workspace_id, &history)?;
        let facts = HistoryFacts::new(&history, &doc);
        let snapshot = Snapshot {
            revision: doc.workspace.revision,
            doc: doc.clone(),
            profile: profile.clone(),
            degraded: table.is_none(),
            notice: notice.clone(),
            type_options: type_options(&doc, profile.as_ref()),
            state_hash: facts.state_hash,
            undo_depth: facts.undo_depth,
            redo_depth: facts.redo_depth,
            undo_label: facts.undo_label,
            redo_label: facts.redo_label,
        };
        self.sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?
            .insert(
                workspace_id.to_string(),
                Session::new(doc, table, profile, notice, history),
            );
        Ok(snapshot)
    }

    pub fn close_session(&self, workspace_id: &str) -> Result<(), CoreError> {
        self.sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?
            .remove(workspace_id);
        Ok(())
    }

    pub fn has_session(&self, workspace_id: &str) -> bool {
        match self.sessions.lock() {
            Ok(s) => s.contains_key(workspace_id),
            Err(_) => false,
        }
    }

    /// A revisioned snapshot of canonical state. Opens the session if needed.
    pub fn snapshot(&self, workspace_id: &str) -> Result<Snapshot, CoreError> {
        if !self.has_session(workspace_id) {
            return self.open_session(workspace_id);
        }
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let facts = HistoryFacts::new(&s.history, &s.doc);
        Ok(Snapshot {
            revision: s.doc.workspace.revision,
            doc: s.doc.clone(),
            profile: s.profile.clone(),
            degraded: s.table.is_none(),
            notice: s.notice.clone(),
            type_options: type_options(&s.doc, s.profile.as_ref()),
            state_hash: facts.state_hash,
            undo_depth: facts.undo_depth,
            redo_depth: facts.redo_depth,
            undo_label: facts.undo_label,
            redo_label: facts.redo_label,
        })
    }

    /// Execute a bounded page against the session's canonical table.
    pub fn query_page(
        &self,
        workspace_id: &str,
        plan: &morphic_query::Plan,
    ) -> Result<morphic_query::Page, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let table = s
            .table
            .as_ref()
            .ok_or_else(|| CoreError::SourceUnavailable(workspace_id.into()))?;
        Ok(morphic_query::query_page(table, plan)?)
    }

    /// Apply a batch of interaction commands atomically.
    ///
    /// Either every command lands and the document is saved once at one new revision, or
    /// nothing changes. The history file is written first, then the command-sourced journal
    /// and the document; reconciliation on reopen repairs any crash window between them.
    /// The in-memory session is swapped only after both writes succeed.
    ///
    /// The session lock is held across the save. That serializes edits against reads, which is
    /// the correct trade for a single-user local app: a torn read would be worse than a brief
    /// wait. Debouncing and autosave belong to the UI layer, not here.
    pub fn apply(
        &self,
        workspace_id: &str,
        commands: &[Command],
        now_iso: &str,
    ) -> Result<ApplyOutcome, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get_mut(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;

        let fields: Option<Vec<String>> = s
            .table
            .as_ref()
            .map(|t| t.columns.iter().map(|c| c.name.clone()).collect());
        let applied = commands::apply(
            &s.doc,
            commands,
            fields.as_deref(),
            s.profile.as_ref(),
            now_iso,
        )?;
        if !applied.changed {
            let facts = HistoryFacts::new(&s.history, &s.doc);
            return Ok(ApplyOutcome {
                revision: s.doc.workspace.revision,
                affected: Vec::new(),
                changed: false,
                doc: s.doc.clone(),
                type_options: type_options(&s.doc, s.profile.as_ref()),
                state_hash: facts.state_hash,
                undo_depth: facts.undo_depth,
                redo_depth: facts.redo_depth,
                undo_label: facts.undo_label,
                redo_label: facts.redo_label,
                label: String::new(),
            });
        }
        let commands_json = serde_json::to_value(commands).unwrap_or(serde_json::json!([]));
        let label = command_label(commands);
        let inverse = format!("Undo {label}");
        let frame = frame_for(&applied.doc, commands_json.clone(), &label, &inverse);
        let mut next_history = s.history.clone();
        next_history.push_frame(frame);
        // The history file is the undo stack; the journal is its durable, bounded provenance.
        // Writing it first means a crash before the document rename is repaired by
        // read_history matching the authoritative document's hash on reopen.
        self.store.write_history(workspace_id, &next_history)?;
        self.store
            .save_history(&applied.doc, commands_json, &label, &inverse)?;
        s.history = next_history;
        s.doc = applied.doc;
        // Old-revision entries can never be asked for again; reclaim them rather than waiting
        // for eviction pressure. The current data revision's entries stay: an unaffected
        // component's plan hash has not changed and must still hit.
        let data_revision = s.data_revision;
        s.pages.retain_revision(data_revision);
        s.metrics.retain_revision(data_revision);
        let facts = HistoryFacts::new(&s.history, &s.doc);
        Ok(ApplyOutcome {
            revision: s.doc.workspace.revision,
            affected: applied.affected,
            changed: true,
            doc: s.doc.clone(),
            type_options: type_options(&s.doc, s.profile.as_ref()),
            state_hash: facts.state_hash,
            undo_depth: facts.undo_depth,
            redo_depth: facts.redo_depth,
            undo_label: facts.undo_label,
            redo_label: facts.redo_label,
            label,
        })
    }

    /// Undo one revision. Rust restores the document from its own bounded stack; the caller
    /// receives a full `ApplyResult`-shaped response and never reconstructs state.
    pub fn undo(&self, workspace_id: &str, now_iso: &str) -> Result<ApplyOutcome, CoreError> {
        self.step_history(workspace_id, now_iso, false)
    }

    /// Redo one revision. The redo stack is truncated by any new command batch.
    pub fn redo(&self, workspace_id: &str, now_iso: &str) -> Result<ApplyOutcome, CoreError> {
        self.step_history(workspace_id, now_iso, true)
    }

    fn step_history(
        &self,
        workspace_id: &str,
        now_iso: &str,
        forward: bool,
    ) -> Result<ApplyOutcome, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get_mut(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let cursor = s.history.cursor;
        let next = if forward {
            if cursor + 1 >= s.history.frames.len() {
                None
            } else {
                Some(cursor + 1)
            }
        } else {
            cursor.checked_sub(1)
        };
        let Some(next) = next else {
            let facts = HistoryFacts::new(&s.history, &s.doc);
            let label = if forward {
                "Nothing to redo"
            } else {
                "Nothing to undo"
            };
            return Ok(ApplyOutcome {
                revision: s.doc.workspace.revision,
                affected: Vec::new(),
                changed: false,
                doc: s.doc.clone(),
                type_options: type_options(&s.doc, s.profile.as_ref()),
                state_hash: facts.state_hash,
                undo_depth: facts.undo_depth,
                redo_depth: facts.redo_depth,
                undo_label: facts.undo_label,
                redo_label: facts.redo_label,
                label: label.to_string(),
            });
        };

        let mut target = s.history.frames[next].doc.clone();
        let max_revision = s
            .history
            .frames
            .iter()
            .map(|f| f.revision)
            .max()
            .unwrap_or(0)
            .max(s.doc.workspace.revision);
        // Undo/redo still bump the revision: caches must not serve a stale result, and the
        // write-ahead journal needs a record strictly newer than the document it replaces.
        // state_hash deliberately ignores this bookkeeping (AT-13).
        target.workspace.revision = max_revision.saturating_add(1);
        target.workspace.modified_at = now_iso.to_string();
        let label = if forward {
            format!("Redid {}", s.history.frames[next].label)
        } else {
            format!("Undid {}", s.history.frames[cursor].label)
        };
        let inverse = if forward {
            format!("Undo {}", s.history.frames[next].label)
        } else {
            format!("Redo {}", s.history.frames[cursor].label)
        };
        let kind = if forward { "redo" } else { "undo" };
        let commands_json = serde_json::json!([{ "kind": kind }]);
        let mut next_history = s.history.clone();
        next_history.frames[next].doc = target.clone();
        next_history.frames[next].revision = target.workspace.revision;
        next_history.frames[next].state_hash = state_hash(&target);
        next_history.cursor = next;
        self.store.write_history(workspace_id, &next_history)?;
        self.store
            .save_history(&target, commands_json, &label, &inverse)?;
        s.history = next_history;
        s.doc = target;
        // An undo can restore any filter, binding or layout, so no cached page, metric or
        // scene may be trusted across it.
        s.pages.clear();
        s.metrics.clear();
        s.charts.clear();
        let facts = HistoryFacts::new(&s.history, &s.doc);
        Ok(ApplyOutcome {
            revision: s.doc.workspace.revision,
            affected: s.doc.workspace.layout.order.clone(),
            changed: true,
            doc: s.doc.clone(),
            type_options: type_options(&s.doc, s.profile.as_ref()),
            state_hash: facts.state_hash,
            undo_depth: facts.undo_depth,
            redo_depth: facts.redo_depth,
            undo_label: facts.undo_label,
            redo_label: facts.redo_label,
            label,
        })
    }

    /// One page of a component's rows, with global filters, its own filter, sort and search
    /// already applied. This is the path the table UI uses; `query_page` remains the raw
    /// escape hatch for a caller that supplies its own plan.
    pub fn component_page(
        &self,
        workspace_id: &str,
        component_id: &str,
        offset: usize,
        limit: usize,
    ) -> Result<morphic_query::Page, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get_mut(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let component = s
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == component_id)
            .ok_or_else(|| CoreError::UnknownComponent(component_id.into()))?;
        // limit 0 means "the page size this table declares".
        let effective = if limit == 0 {
            plans::page_size(component)
        } else {
            limit
        };
        let plan = plans::for_component(&s.doc, component, offset, effective)?;
        let table = s
            .table
            .as_ref()
            .ok_or_else(|| CoreError::SourceUnavailable(workspace_id.into()))?;
        let key = morphic_query::cache::CacheKey::new(s.data_revision, plan.hash());
        if let Some(page) = s.pages.get(key) {
            return Ok(page.clone());
        }
        let page = morphic_query::query_page(table, &plan)?;
        s.bump_compute(component_id);
        s.pages.insert(key, page.clone());
        Ok(page)
    }

    /// How many times this component's data has actually been executed this session. A cache
    /// hit does not count. This is what the incremental-recomputation test asserts against.
    pub fn compute_count(&self, workspace_id: &str, component_id: &str) -> Result<u64, CoreError> {
        let sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        Ok(s.computes.get(component_id).copied().unwrap_or(0))
    }

    /// Compute the value behind a `metric_card`. Rust resolves the binding from the
    /// document; Flutter never re-implements aggregation.
    ///
    /// Global filters, the component's own filter and the binding's filter all apply. Before
    /// M1.3 the binding filter was parsed and then ignored, so a card declared as
    /// `count where level = ERROR` counted every row.
    pub fn metric_data(
        &self,
        workspace_id: &str,
        component_id: &str,
    ) -> Result<MetricResult, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get_mut(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let component = s
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == component_id)
            .ok_or_else(|| CoreError::UnknownComponent(component_id.into()))?;
        let aggregation = match &component.binding {
            morphic_schema::Binding::MetricCard { aggregation } => aggregation,
            other => {
                return Err(CoreError::NotAMetric(
                    component_id.into(),
                    other.kind().to_string(),
                ))
            }
        };
        let plan = plans::for_metric(&s.doc, component)?;
        let revision = s.doc.workspace.revision;
        let table = s
            .table
            .as_ref()
            .ok_or_else(|| CoreError::SourceUnavailable(workspace_id.into()))?;
        // The plan alone is NOT the metric's identity: two cards over the same selection with
        // different aggregations produce identical plans. Keying on the plan alone handed the
        // second card the first card's cached number. The aggregation is part of the key.
        let fingerprint = serde_json::json!({
            "plan": plan,
            "op": aggregation.op,
            "field": aggregation.field,
        });
        let key = morphic_query::cache::CacheKey::new(
            s.data_revision,
            morphic_query::cache::hash_json(&fingerprint),
        );
        if let Some(value) = s.metrics.get(key) {
            return Ok(MetricResult {
                component_id: component_id.into(),
                value: value.clone(),
                revision,
            });
        }
        let agg = morphic_query::Aggregate {
            op: &aggregation.op,
            field: aggregation.field.as_deref(),
        };
        // Only pay for a selection when there is something to select: an unfiltered card
        // aggregates the table directly.
        let value = if plan.filter.is_none() && plan.search.is_none() {
            morphic_query::aggregate(table, &agg)?
        } else {
            let rows = morphic_query::select_rows(table, &plan)?;
            morphic_query::aggregate_over(table, Some(&rows), &agg)?
        };
        s.bump_compute(component_id);
        s.metrics.insert(key, value.clone());
        Ok(MetricResult {
            component_id: component_id.into(),
            value,
            revision,
        })
    }

    /// The pre-aggregated scene for a chart component.
    ///
    /// Rust does the grouping and bucketing; Dart receives buckets and totals and never rows
    /// (docs/architecture/02 §2.5). The same composed filter a table would use applies here, so a
    /// workspace filter moves the charts and the table together.
    pub fn chart_data(
        &self,
        workspace_id: &str,
        component_id: &str,
    ) -> Result<ChartResult, CoreError> {
        if !self.has_session(workspace_id) {
            self.open_session(workspace_id)?;
        }
        let mut sessions = self
            .sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?;
        let s = sessions
            .get_mut(workspace_id)
            .ok_or_else(|| CoreError::SessionNotFound(workspace_id.into()))?;
        let component = s
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == component_id)
            .ok_or_else(|| CoreError::UnknownComponent(component_id.into()))?;
        if !matches!(
            component.binding,
            morphic_schema::Binding::BarChart { .. }
                | morphic_schema::Binding::LineChart { .. }
                | morphic_schema::Binding::Timeline { .. }
        ) {
            return Err(CoreError::NotAChart(
                component_id.into(),
                component.binding.kind().to_string(),
            ));
        }

        let plan = plans::for_metric(&s.doc, component)?;
        let revision = s.doc.workspace.revision;
        let table = s
            .table
            .as_ref()
            .ok_or_else(|| CoreError::SourceUnavailable(workspace_id.into()))?;
        // The binding is the scene's identity: two charts over one selection with different
        // dimensions or measures produce different scenes from an identical plan.
        // The order is part of the scene's identity. `for_metric` carries no sort (a chart
        // groups rather than orders rows), so without this a sort toggle would hash to the
        // same key and be served the previous scene from cache.
        let order = plans::category_order(component);
        let fingerprint = serde_json::json!({
            "plan": plan,
            "binding": component.binding,
            "order": order,
        });
        let key = morphic_query::cache::CacheKey::new(
            s.data_revision,
            morphic_query::cache::hash_json(&fingerprint),
        );
        if let Some(scene) = s.charts.get(key) {
            return Ok(ChartResult {
                component_id: component_id.into(),
                scene: scene.clone(),
                revision,
            });
        }

        let rows = morphic_query::select_rows(table, &plan)?;
        let scene = match &component.binding {
            morphic_schema::Binding::BarChart {
                dimension,
                measure,
                limit,
            } => {
                let agg = morphic_query::Aggregate {
                    op: &measure.op,
                    field: measure.field.as_deref(),
                };
                morphic_query::ChartScene::Category(morphic_query::category_scene_ordered(
                    table,
                    &rows,
                    dimension,
                    &agg,
                    *limit as usize,
                    order,
                )?)
            }
            morphic_schema::Binding::LineChart { x, y, group_by } => {
                // The compiler emits exactly one measure. A hand-authored document asking for
                // several is rejected rather than silently charting the first: dropping a
                // requested series without saying so is the failure mode this project avoids.
                let measure = match y.as_slice() {
                    [one] => one,
                    [] => {
                        return Err(CoreError::UnsupportedBinding(
                            "line chart has no y aggregation".into(),
                        ))
                    }
                    _ => {
                        return Err(CoreError::UnsupportedBinding(format!(
                            "line chart has {} y aggregations; MVP charts one measure per chart",
                            y.len()
                        )))
                    }
                };
                morphic_query::ChartScene::Series(morphic_query::series_scene(
                    table,
                    &rows,
                    &morphic_query::SeriesSpec {
                        x,
                        agg: morphic_query::Aggregate {
                            op: &measure.op,
                            field: measure.field.as_deref(),
                        },
                        group_by: group_by.as_deref(),
                    },
                )?)
            }
            morphic_schema::Binding::Timeline {
                time_field,
                group_by,
                severity_field,
            } => {
                // Severity lanes when a severity field is named; otherwise the group field is
                // the lane, which is what a timeline grouped by service should show.
                let lane = severity_field.as_deref().or(group_by.as_deref());
                morphic_query::ChartScene::Timeline(morphic_query::timeline_scene(
                    table,
                    &rows,
                    &morphic_query::TimelineSpec {
                        time_field,
                        severity_field: lane,
                    },
                )?)
            }
            _ => unreachable!("binding kind was checked above"),
        };
        s.bump_compute(component_id);
        s.charts.insert(key, scene.clone());
        Ok(ChartResult {
            component_id: component_id.into(),
            scene,
            revision,
        })
    }

    pub fn list_workspaces(&self) -> Result<Vec<morphic_workspace::WorkspaceMeta>, CoreError> {
        Ok(self.store.list_workspaces()?)
    }

    /// Rename a workspace. This is a real persisted edit: the document, library index and
    /// undo seed all move together, and any open session is dropped so the next snapshot reads
    /// the new title from disk rather than serving stale in-memory state.
    pub fn rename_workspace(
        &self,
        id: &str,
        title: &str,
        now_iso: &str,
    ) -> Result<WorkspaceDoc, CoreError> {
        let title = title.trim();
        if title.is_empty() {
            return Err(CoreError::Validation("workspace title is empty".into()));
        }
        let mut doc = self.store.load_workspace(id)?;
        doc.workspace.title = title.to_string();
        doc.workspace.revision = doc.workspace.revision.saturating_add(1);
        doc.workspace.modified_at = now_iso.to_string();
        self.store.save_workspace(&doc)?;
        self.store.write_history(id, &HistoryState::seed(&doc))?;
        self.close_session(id)?;
        Ok(doc)
    }

    /// Duplicate a workspace document under a new id. The content-addressed dataset is shared,
    /// not copied: `save_workspace` writes only the new document/journal/history. A fresh
    /// revision and undo seed make the copy an independent workspace from here on.
    pub fn duplicate_workspace(
        &self,
        source_id: &str,
        new_id: &str,
        title: &str,
        now_iso: &str,
    ) -> Result<WorkspaceDoc, CoreError> {
        let title = title.trim();
        if title.is_empty() || new_id.trim().is_empty() {
            let msg = "duplicate needs a title and a new id".to_string();
            return Err(CoreError::Validation(msg));
        }
        if self.store.exists(new_id) {
            let msg = format!("workspace '{new_id}' already exists");
            return Err(CoreError::Validation(msg));
        }
        let mut doc = self.store.load_workspace(source_id)?;
        doc.workspace.id = new_id.to_string();
        doc.workspace.title = title.to_string();
        doc.workspace.created_at = now_iso.to_string();
        doc.workspace.modified_at = now_iso.to_string();
        doc.workspace.revision = 1;
        self.store.save_workspace(&doc)?;
        self.store
            .write_history(new_id, &HistoryState::seed(&doc))?;
        Ok(doc)
    }

    /// Delete a workspace and drop its session. The content-addressed dataset is kept:
    /// another workspace may reference the same bytes (docs/architecture/06 §1).
    pub fn delete_workspace(&self, id: &str) -> Result<(), CoreError> {
        self.close_session(id)?;
        self.store.delete_workspace(id)?;
        Ok(())
    }

    /// Restore a degraded workspace by re-adding its source bytes. The bytes must hash to the
    /// dataset id the document already references; a different file is refused rather than
    /// silently changing what the workspace means. The session is dropped so the next open
    /// rehydrates the table, profile and metrics from the restored source.
    pub fn relink_workspace(&self, id: &str, bytes: &[u8]) -> Result<(), CoreError> {
        let doc = self.store.load_workspace(id)?;
        let expected = doc
            .workspace
            .data_sources
            .first()
            .map(|d| d.dataset_id.as_str())
            .unwrap_or("");
        let actual = morphic_workspace::content_hash(bytes);
        if expected.is_empty() || actual != expected {
            let msg = format!(
                "source does not match workspace '{id}': expected {expected}, got {actual}"
            );
            return Err(CoreError::Validation(msg));
        }
        self.store.put_dataset(bytes)?;
        self.close_session(id)?;
        Ok(())
    }

    pub fn load_workspace(&self, id: &str) -> Result<WorkspaceDoc, CoreError> {
        Ok(self.store.load_workspace(id)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let mut root = std::env::temp_dir();
        root.push(format!(
            "morphic-core-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

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
        let root = temp_root("slice");
        let engine = Engine::new(&root).unwrap();
        let csv =
            b"time,level,value\n2026-11-05T10:00:00Z,ERROR,1.5\n2026-11-05T10:01:00Z,INFO,2.5\n";
        let doc = engine
            .create_workspace_from_csv(csv, "Logs", "w_poc", "2026-11-05T00:00:00Z")
            .unwrap();
        let profile = morphic_semantic::profile(&morphic_ingest::parse_csv(csv).unwrap().0);
        assert!(morphic_schema::validate_with_profile(&doc, &profile).is_empty());
        // M1.1 1.1.3: temporal AND a measure ⇒ R1 + R2 + R3 (line chart) + R6.
        let kinds: Vec<&str> = doc
            .workspace
            .components
            .iter()
            .map(|c| c.component_type.as_str())
            .collect();
        assert!(kinds.contains(&"metric_card"));
        assert!(kinds.contains(&"line_chart"));
        assert!(kinds.contains(&"data_table"));
        assert!(!kinds.contains(&"timeline"));
        let loaded = engine.load_workspace("w_poc").unwrap();
        assert_eq!(loaded.workspace.id, "w_poc");
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.1 task 1.1.4: sessions, paging, metrics, reopen ---

    // Amounts deliberately repeat: a perfectly unique integer column is classified as an
    // identifier by morphic-semantic's >=99%-unique rule, so it would earn no measure metric.
    const SALES: &[u8] = b"region,amount\n\
                           eu,10\n\
                           us,20\n\
                           eu,10\n\
                           us,40\n\
                           eu,50\n";

    fn imported(tag: &str) -> (Engine, std::path::PathBuf) {
        let root = temp_root(tag);
        let engine = Engine::new(&root).unwrap();
        engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        (engine, root)
    }

    #[test]
    fn import_retains_an_open_session_and_reports_facts() {
        let (engine, root) = imported("retain");
        assert!(engine.has_session("w1"));
        let out = engine
            .import_csv(SALES, "Sales", "w2", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        assert_eq!(out.report.rows_imported, 5);
        assert_eq!(out.profile.row_count, 5);
        assert_eq!(out.doc.workspace.revision, 1);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn import_emits_real_progress_phases_in_order() {
        let root = temp_root("progress");
        let engine = Engine::new(&root).unwrap();
        let mut phases: Vec<String> = Vec::new();
        engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |p| {
                phases.push(p.phase);
            })
            .unwrap();
        assert_eq!(phases.first().map(String::as_str), Some("sniffing"));
        assert_eq!(phases.last().map(String::as_str), Some("done"));
        assert!(phases.contains(&"parsing".to_string()));
        assert!(phases.contains(&"typing".to_string()));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn snapshot_carries_the_revision_and_profile() {
        let (engine, root) = imported("snapshot");
        let snap = engine.snapshot("w1").unwrap();
        assert_eq!(snap.revision, 1);
        assert_eq!(snap.profile.as_ref().unwrap().row_count, 5);
        assert_eq!(snap.doc.workspace.id, "w1");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn query_page_returns_typed_rows_and_paging_metadata() {
        let (engine, root) = imported("page");
        let plan = morphic_query::Plan {
            offset: 1,
            limit: 2,
            ..Default::default()
        };
        let page = engine.query_page("w1", &plan).unwrap();
        assert_eq!(page.total_rows, 5);
        assert_eq!(page.rows.len(), 2);
        assert_eq!(page.rows[0][0], serde_json::json!("us"));
        assert_eq!(page.rows[0][1], serde_json::json!(20));
        assert!(page.has_more);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn query_page_search_narrows_the_total() {
        let (engine, root) = imported("search");
        let plan = morphic_query::Plan {
            search: Some("eu".into()),
            ..Default::default()
        };
        let page = engine.query_page("w1", &plan).unwrap();
        assert_eq!(page.total_rows, 3);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn metric_data_resolves_the_binding_in_rust() {
        let (engine, root) = imported("metric");
        let count = engine.metric_data("w1", "total_records").unwrap();
        assert_eq!(count.value, serde_json::json!(5));
        assert_eq!(count.revision, 1);
        let avg = engine.metric_data("w1", "metric_amount").unwrap();
        assert_eq!(avg.value, serde_json::json!(26.0));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn metric_data_on_a_non_metric_component_is_a_typed_error() {
        let (engine, root) = imported("notmetric");
        let e = engine.metric_data("w1", "data_table").unwrap_err();
        assert!(matches!(e, CoreError::NotAMetric(_, _)), "{e}");
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.4 task 1.4.1: chart scenes -------------------------------------------------

    /// The compiler's bar chart over SALES: region is the dimension, amount the measure.
    fn breakdown_id(doc: &morphic_schema::WorkspaceDoc) -> String {
        doc.workspace
            .components
            .iter()
            .find(|c| matches!(c.binding, morphic_schema::Binding::BarChart { .. }))
            .expect("the sales fixture has a low-cardinality dimension")
            .id
            .clone()
    }

    #[test]
    fn chart_data_groups_in_rust_and_reports_its_revision() {
        let (engine, root) = imported("chart_group");
        let id = breakdown_id(&engine.snapshot("w1").unwrap().doc);
        let got = engine.chart_data("w1", &id).unwrap();
        assert_eq!(got.revision, 1);
        assert_eq!(got.component_id, id);
        let morphic_query::ChartScene::Category(scene) = got.scene else {
            panic!("a bar chart must produce a category scene");
        };
        assert_eq!(scene.dimension, "region");
        assert_eq!(scene.measure, "avg_amount");
        assert_eq!(scene.total_categories, 2);
        // us: 20,40 -> 30.0 sorts above eu: 10,10,50 -> 23.33. Descending by measure.
        assert_eq!(scene.points.len(), 2);
        assert_eq!(scene.points[0].label.as_deref(), Some("us"));
        assert_eq!(scene.points[0].value, Some(30.0));
        assert_eq!(scene.points[0].row_count, 2);
        assert_eq!(scene.points[1].label.as_deref(), Some("eu"));
        assert_eq!(scene.points[1].row_count, 3);
        assert!(scene.other.is_none(), "two categories fit the limit of two");
        assert!(!scene.truncated);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_global_filter_moves_the_chart_and_the_cache_does_not_serve_the_old_scene() {
        let (engine, root) = imported("chart_filter");
        let id = breakdown_id(&engine.snapshot("w1").unwrap().doc);
        let before = engine.chart_data("w1", &id).unwrap();
        let revision = engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("eu"))],
                }],
                "2026-11-05T00:00:00Z",
            )
            .unwrap()
            .revision;
        let after = engine.chart_data("w1", &id).unwrap();
        assert_eq!(after.revision, revision);
        assert_ne!(after.revision, before.revision);
        let morphic_query::ChartScene::Category(scene) = after.scene else {
            panic!("category scene");
        };
        assert_eq!(scene.total_categories, 1, "us must be gone, not cached");
        assert_eq!(scene.points.len(), 1);
        assert_eq!(scene.points[0].label.as_deref(), Some("eu"));
        assert_eq!(scene.points[0].row_count, 3);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_repeated_chart_read_is_served_from_cache() {
        let (engine, root) = imported("chart_cache");
        let id = breakdown_id(&engine.snapshot("w1").unwrap().doc);
        let first = engine.chart_data("w1", &id).unwrap();
        let once = engine.compute_count("w1", &id).unwrap();
        let second = engine.chart_data("w1", &id).unwrap();
        assert_eq!(engine.compute_count("w1", &id).unwrap(), once);
        assert_eq!(first.scene, second.scene);
        assert_eq!(once, 1, "the scene must be computed exactly once");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_bar_ceiling_is_the_same_on_both_sides_of_the_contract() {
        // Neither crate may depend on the other, so the constant is declared twice. This is
        // the only thing stopping the validator and the scene builder from drifting apart.
        assert_eq!(
            morphic_schema::MAX_BAR_LIMIT as usize,
            morphic_query::MAX_BAR_POINTS,
            "the validator and the scene builder must agree on the documented top-N cap"
        );
    }

    #[test]
    fn a_sort_on_the_dimension_orders_bars_by_label_and_busts_the_cache() {
        let (engine, root) = imported("chart_sort_label");
        let id = breakdown_id(&engine.snapshot("w1").unwrap().doc);
        let before = engine.chart_data("w1", &id).unwrap();
        let morphic_query::ChartScene::Category(c) = &before.scene else {
            panic!("category scene");
        };
        // SALES: us avg 30 above eu avg 23.33.
        assert_eq!(c.points[0].label.as_deref(), Some("us"));

        engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: id.clone(),
                    sort: vec![morphic_schema::SortRule {
                        field: "region".into(),
                        dir: morphic_schema::SortDir::Asc,
                        nulls: morphic_schema::NullsOrder::Last,
                    }],
                }],
                "2026-11-05T00:00:00Z",
            )
            .unwrap();
        let after = engine.chart_data("w1", &id).unwrap();
        let morphic_query::ChartScene::Category(c) = &after.scene else {
            panic!("category scene");
        };
        assert_eq!(
            c.points[0].label.as_deref(),
            Some("eu"),
            "a label sort must reach the scene, not be served from cache"
        );
        assert_eq!(c.points[1].label.as_deref(), Some("us"));
        assert_ne!(after.revision, before.revision);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_sort_on_the_measure_orders_bars_by_value() {
        let (engine, root) = imported("chart_sort_measure");
        let id = breakdown_id(&engine.snapshot("w1").unwrap().doc);
        engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: id.clone(),
                    sort: vec![morphic_schema::SortRule {
                        field: "amount".into(),
                        dir: morphic_schema::SortDir::Asc,
                        nulls: morphic_schema::NullsOrder::Last,
                    }],
                }],
                "2026-11-05T00:00:00Z",
            )
            .unwrap();
        let morphic_query::ChartScene::Category(c) = engine.chart_data("w1", &id).unwrap().scene
        else {
            panic!("category scene");
        };
        assert_eq!(c.points[0].label.as_deref(), Some("eu"), "smallest first");
        assert_eq!(c.points[1].label.as_deref(), Some("us"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn chart_data_on_a_non_chart_is_a_typed_error() {
        let (engine, root) = imported("chart_notchart");
        let e = engine.chart_data("w1", "data_table").unwrap_err();
        assert!(matches!(e, CoreError::NotAChart(_, _)), "{e}");
        let e = engine.chart_data("w1", "total_records").unwrap_err();
        assert!(matches!(e, CoreError::NotAChart(_, _)), "{e}");
        assert!(matches!(
            engine.chart_data("w1", "ghost"),
            Err(CoreError::UnknownComponent(_))
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_line_chart_with_two_measures_is_rejected_not_silently_truncated() {
        // The compiler emits one measure. A hand-authored document asking for two must hear
        // about it: charting the first and dropping the second is the silent-loss failure this
        // project keeps refusing.
        let (engine, root) = imported("chart_two_measures");
        let mut doc = engine.snapshot("w1").unwrap().doc;
        let id = breakdown_id(&doc);
        {
            let c = doc
                .workspace
                .components
                .iter_mut()
                .find(|c| c.id == id)
                .unwrap();
            c.binding = morphic_schema::Binding::LineChart {
                x: "region".into(),
                y: vec![
                    morphic_schema::Aggregation {
                        op: "avg".into(),
                        field: Some("amount".into()),
                        filter: None,
                    },
                    morphic_schema::Aggregation {
                        op: "sum".into(),
                        field: Some("amount".into()),
                        filter: None,
                    },
                ],
                group_by: None,
            };
        }
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc).unwrap();
        drop(engine);
        let engine = Engine::new(&root).unwrap();
        let e = engine.chart_data("w1", &id).unwrap_err();
        assert!(matches!(e, CoreError::UnsupportedBinding(_)), "{e}");
        assert!(e.to_string().contains("2 y aggregations"), "{e}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_chart_measure_filter_composes_with_the_workspace_filter() {
        // A chart's measure carries the same optional binding filter a card's does. Global and
        // binding must intersect, not replace one another.
        let (engine, root) = imported("chart_binding_filter");
        let mut doc = engine.snapshot("w1").unwrap().doc;
        let id = breakdown_id(&doc);
        {
            let c = doc
                .workspace
                .components
                .iter_mut()
                .find(|c| c.id == id)
                .unwrap();
            if let morphic_schema::Binding::BarChart { measure, .. } = &mut c.binding {
                measure.filter = Some(morphic_schema::FilterExpr {
                    op: "gt".into(),
                    field: Some("amount".into()),
                    value: Some(serde_json::json!(10)),
                    args: vec![],
                });
            }
        }
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc).unwrap();
        drop(engine);
        let engine = Engine::new(&root).unwrap();
        // amount > 10 leaves us 20, us 40, eu 50 -> eu avg 50 (1 row), us avg 30 (2 rows).
        let morphic_query::ChartScene::Category(scene) =
            engine.chart_data("w1", &id).unwrap().scene
        else {
            panic!("category scene");
        };
        assert_eq!(scene.points[0].label.as_deref(), Some("eu"));
        assert_eq!(scene.points[0].value, Some(50.0));
        assert_eq!(scene.points[0].row_count, 1);
        assert_eq!(scene.points[1].label.as_deref(), Some("us"));
        assert_eq!(scene.points[1].row_count, 2);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn unknown_component_is_a_typed_error() {
        let (engine, root) = imported("unknown");
        assert!(matches!(
            engine.metric_data("w1", "ghost"),
            Err(CoreError::UnknownComponent(_))
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn unknown_workspace_is_a_typed_error() {
        let root = temp_root("noworkspace");
        let engine = Engine::new(&root).unwrap();
        assert!(matches!(
            engine.snapshot("ghost"),
            Err(CoreError::Store(StoreError::NotFound(_)))
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn reopen_rehydrates_a_queryable_session_from_disk() {
        let root = temp_root("reopen");
        let doc_id = "w_reopen";
        {
            let engine = Engine::new(&root).unwrap();
            engine
                .import_csv(SALES, "Sales", doc_id, "2026-11-05T00:00:00Z", &mut |_| {})
                .unwrap();
        }
        // A brand-new Engine has no in-memory session: it must rebuild from the source.
        let engine = Engine::new(&root).unwrap();
        assert!(!engine.has_session(doc_id));
        let page = engine
            .query_page(doc_id, &morphic_query::Plan::default())
            .unwrap();
        assert_eq!(page.total_rows, 5);
        assert!(engine.has_session(doc_id));
        assert_eq!(
            engine.metric_data(doc_id, "metric_amount").unwrap().value,
            serde_json::json!(26.0)
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn close_session_drops_state_but_not_the_persisted_workspace() {
        let (engine, root) = imported("close");
        engine.close_session("w1").unwrap();
        assert!(!engine.has_session("w1"));
        // Still reopenable, because the document and source are on disk.
        assert_eq!(
            engine
                .snapshot("w1")
                .unwrap()
                .profile
                .as_ref()
                .unwrap()
                .row_count,
            5
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn engine_is_send_and_sync_for_the_bridge() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<Engine>();
    }

    // --- M1.1 task 1.1.2 paths retained ---

    #[test]
    fn temporal_csv_flows_through_ingest_into_facts() {
        let csv = b"when,region,latency_ms\n\
                    2024-01-01T12:00:00Z,eu,10\n\
                    2024-01-01T14:00:00+02:00,us,20\n\
                    2024-01-02T00:00:00Z,eu,30\n";
        let (table, report) = morphic_ingest::parse_csv(csv).unwrap();
        assert_eq!(table.row_count, 3);
        assert_eq!(table.columns[0].dtype, morphic_model::DataType::Timestamp);
        assert_eq!(table.columns[2].dtype, morphic_model::DataType::Int64);
        assert!(report
            .warnings
            .iter()
            .any(|w| w.contains("UTC milliseconds")));

        let profile = morphic_semantic::profile(&table);
        let when = &profile.fields[0];
        assert_eq!(when.inference.role, morphic_model::FieldRole::Temporal);
        assert_eq!(when.min.as_deref(), Some("2024-01-01T12:00:00.000Z"));
        assert_eq!(when.max.as_deref(), Some("2024-01-02T00:00:00.000Z"));
        assert!(when.stats.is_some());

        let latency = &profile.fields[2];
        assert_eq!(latency.inference.role, morphic_model::FieldRole::Measure);
        let s = latency.stats.as_ref().unwrap();
        assert_eq!(s.count, 3);
        assert!((s.mean - 20.0).abs() < 1e-9);
        assert!(!s.sampled);
        assert!(profile.fields[1].stats.is_none());
    }

    #[test]
    fn ambiguous_dates_do_not_silently_become_timestamps_end_to_end() {
        let csv = b"booked_on,amount\n01/02/2024,10\n03/04/2024,20\n05/06/2024,30\n";
        let (table, report) = morphic_ingest::parse_csv(csv).unwrap();
        assert_eq!(table.columns[0].dtype, morphic_model::DataType::Utf8);
        assert!(report.warnings.iter().any(|w| w.contains("ambiguous")));
        let profile = morphic_semantic::profile(&table);
        // The dtype is the fact and it stays text. The role is an interpretation, and this
        // field IS a time axis — AT-02's scorer showed that calling it a dimension was the
        // wrong answer. Refusing to guess the instant must not mean refusing to know what the
        // column means.
        assert_eq!(table.columns[0].dtype, morphic_model::DataType::Utf8);
        assert_eq!(
            profile.fields[0].inference.role,
            morphic_model::FieldRole::Temporal
        );
        assert!(
            profile.fields[0]
                .inference
                .evidence
                .iter()
                .any(|e| e.contains("stayed text")),
            "the evidence must disclose that it was not typed: {:?}",
            profile.fields[0].inference.evidence
        );
    }

    /// `amount` is a measure even when every row differs. This used to assert the opposite and
    /// documented it as a known limit; AT-02's scorecard showed the limit was costing real
    /// workspaces their metrics, so a measure vocabulary now outranks uniqueness.
    #[test]
    fn a_measure_named_column_earns_a_metric_even_when_every_value_is_distinct() {
        let root = temp_root("idlike");
        let engine = Engine::new(&root).unwrap();
        let csv = b"region,amount\neu,10\nus,20\neu,30\nus,40\neu,50\n";
        let out = engine
            .import_csv(csv, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        let ids: Vec<&str> = out
            .doc
            .workspace
            .components
            .iter()
            .map(|c| c.id.as_str())
            .collect();
        assert!(ids.contains(&"total_records"));
        assert!(
            ids.contains(&"metric_amount"),
            "a column named amount is a measure; uniqueness in five rows is a sample artefact"
        );
        // The count metric still works, so the workspace remains useful.
        assert_eq!(
            engine.metric_data("w1", "total_records").unwrap().value,
            serde_json::json!(5)
        );
        std::fs::remove_dir_all(&root).ok();
    }

    /// The limit that remains, stated rather than hidden: an all-distinct integer with a name
    /// that says nothing is still read as an identifier, so it earns no measure metric. Telling
    /// a key from a quantity with no name evidence is genuinely ambiguous; M1.4's scored
    /// planner is where that gets better.
    #[test]
    fn an_unnamed_all_distinct_integer_is_still_read_as_an_identifier() {
        let root = temp_root("idlike2");
        let engine = Engine::new(&root).unwrap();
        let csv = b"region,n\neu,10\nus,20\neu,30\nus,40\neu,50\n";
        let out = engine
            .import_csv(csv, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        let ids: Vec<&str> = out
            .doc
            .workspace
            .components
            .iter()
            .map(|c| c.id.as_str())
            .collect();
        assert!(ids.contains(&"total_records"));
        assert!(
            !ids.contains(&"metric_n"),
            "with no name evidence, a perfectly unique integer is still treated as a key"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.5 task 1.5.3: library lifecycle + source re-link ----------------------------

    #[test]
    fn rename_duplicate_and_delete_update_the_library_and_share_the_dataset() {
        let (engine, root) = imported("library_lifecycle");
        let renamed = engine
            .rename_workspace("w1", "  Quarterly sales  ", "2026-11-10T10:00:00Z")
            .unwrap();
        assert_eq!(renamed.workspace.title, "Quarterly sales");
        assert_eq!(renamed.workspace.revision, 2);
        let reopened = engine.snapshot("w1").unwrap();
        assert_eq!(reopened.doc.workspace.title, "Quarterly sales");
        assert_eq!(
            engine
                .list_workspaces()
                .unwrap()
                .iter()
                .find(|w| w.id == "w1")
                .unwrap()
                .title,
            "Quarterly sales"
        );

        let duplicate = engine
            .duplicate_workspace("w1", "w2", "Quarterly sales copy", "2026-11-10T10:01:00Z")
            .unwrap();
        assert_eq!(duplicate.workspace.id, "w2");
        assert_eq!(duplicate.workspace.revision, 1);
        assert_eq!(
            duplicate.workspace.data_sources[0].dataset_id,
            renamed.workspace.data_sources[0].dataset_id
        );
        // AT-15: three library entries, one dataset. A third copy exercises the "immediately
        // reflects changes" part with more than one surviving sibling.
        engine
            .duplicate_workspace("w1", "w3", "Third copy", "2026-11-10T10:02:00Z")
            .unwrap();
        let datasets: Vec<_> = std::fs::read_dir(root.join("datasets")).unwrap().collect();
        assert_eq!(datasets.len(), 1, "duplication must not copy source bytes");
        assert_eq!(engine.list_workspaces().unwrap().len(), 3);

        engine.delete_workspace("w1").unwrap();
        assert_eq!(engine.list_workspaces().unwrap().len(), 2);
        // Deleting one workspace must not break either surviving copy's shared dataset.
        assert!(!engine.snapshot("w2").unwrap().degraded);
        assert!(!engine.snapshot("w3").unwrap().degraded);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn relinking_requires_the_exact_original_bytes() {
        let (engine, root) = imported("relink_exact");
        let original = SALES;
        let doc = engine.load_workspace("w1").unwrap();
        let dataset = doc.workspace.data_sources[0].dataset_id.clone();
        let path = root.join("datasets").join(&dataset).join("source.csv");
        std::fs::remove_file(&path).unwrap();
        assert!(engine.open_session("w1").unwrap().degraded);
        assert!(engine
            .relink_workspace("w1", b"region,amount\neu,999\n")
            .is_err());
        assert!(engine.open_session("w1").unwrap().degraded);
        engine.relink_workspace("w1", original).unwrap();
        let snap = engine.open_session("w1").unwrap();
        assert!(!snap.degraded);
        // "Restores full function" (AT-16): the table and metrics work again, not just the
        // document. A degraded session would return a typed SourceUnavailable error here.
        assert_eq!(
            engine.metric_data("w1", "total_records").unwrap().value,
            serde_json::json!(5)
        );
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.5 task 1.5.4: startup recovery, explicit checkpoint, kill-mid-save -----------

    #[test]
    fn startup_recovery_is_reported_once_and_a_checkpoint_acknowledges_the_flush() {
        let root = temp_root("startup-report");
        // An interrupted atomic rename left a temp file behind before this process started.
        std::fs::create_dir_all(root.join("datasets")).unwrap();
        std::fs::write(root.join("datasets").join("interrupted.tmp"), b"partial").unwrap();

        let engine = Engine::new(&root).unwrap();
        let report = engine.recovery_report();
        assert_eq!(report.swept_tmp, 1);
        assert!(!report.is_clean());
        // The report is a snapshot of startup, not a live query: repeating the call does not
        // re-sweep or silently claim a second repair.
        assert_eq!(engine.recovery_report(), report);

        engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        let saved = engine.save("w1").unwrap();
        assert!(!saved.dirty);
        assert!(saved.compacted);
        assert_eq!(
            saved.state_hash,
            state_hash(&engine.load_workspace("w1").unwrap())
        );

        drop(engine);
        assert!(Engine::new(&root).unwrap().recovery_report().is_clean());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_kill_between_journal_and_rename_is_repaired_at_startup() {
        let root = temp_root("kill-mid-save");
        let engine = Engine::new(&root).unwrap();
        let out = engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        drop(engine);

        // Fault injection: the write-ahead journal reached disk, but the process died before
        // the authoritative document rename. A second store handle writes only the journal.
        let store = FileStore::new(&root).unwrap();
        let mut newer = out.doc.clone();
        newer.workspace.revision = 6;
        newer.workspace.modified_at = "2026-11-05T06:00:00Z".into();
        store.journal_revision(&newer).unwrap();

        let reopened = Engine::new(&root).unwrap();
        assert!(
            reopened.recovery_report().restored_from_journal,
            "startup must report the promoted revision"
        );
        let snap = reopened.open_session("w1").unwrap();
        assert_eq!(snap.revision, 6, "the interrupted save was not lost");
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.5 task 1.5.5: targeted recompilation after a field correction ---------------

    #[test]
    fn an_override_recompiles_only_the_bindings_that_read_that_field() {
        let (engine, root) = imported("targeted_recompile");
        let before = engine.load_workspace("w1").unwrap();
        let binding = |doc: &morphic_schema::WorkspaceDoc, id: &str| {
            serde_json::to_value(
                &doc.workspace
                    .components
                    .iter()
                    .find(|c| c.id == id)
                    .unwrap()
                    .binding,
            )
            .unwrap()
        };
        let average = binding(&before, "metric_amount");
        let records = binding(&before, "total_records");
        assert_eq!(average["aggregation"]["op"], "avg");

        let outcome = engine
            .apply(
                "w1",
                &[Command::OverrideFieldType {
                    field: "amount".into(),
                    dtype: "utf8".into(),
                }],
                "2026-11-10T11:00:00Z",
            )
            .unwrap();
        assert!(outcome.changed);
        // AT-17: the engine reports only the rebuilt bindings, not every component.
        assert!(outcome.affected.iter().any(|id| id == "metric_amount"));
        assert!(!outcome.affected.iter().any(|id| id == "total_records"));
        let after = outcome.doc;
        assert_eq!(
            binding(&after, "metric_amount")["aggregation"]["op"],
            "count",
            "an average over a now-text field must be recompiled into a row count"
        );
        assert_eq!(
            binding(&after, "total_records"),
            records,
            "the untouched record count must stay byte-identical"
        );
        assert_eq!(
            after.workspace.field_overrides[0].dtype.as_deref(),
            Some("utf8")
        );
        // The correction is persisted, not just applied to the in-memory session.
        engine.close_session("w1").unwrap();
        let reopened = engine.load_workspace("w1").unwrap();
        assert_eq!(
            binding(&reopened, "metric_amount")["aggregation"]["op"],
            "count"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn undo_restores_the_original_inference_and_bindings() {
        let (engine, root) = imported("override_undo");
        let before = engine.load_workspace("w1").unwrap();
        engine
            .apply(
                "w1",
                &[Command::OverrideFieldRole {
                    field: "region".into(),
                    role: "identifier".into(),
                }],
                "2026-11-10T11:01:00Z",
            )
            .unwrap();
        let undone = engine.undo("w1", "2026-11-10T11:02:00Z").unwrap();
        // History frames hold the full authoritative document, so undo restores both the
        // inferred role and every binding the correction recompiled. Revision and modifiedAt
        // are bookkeeping that undo deliberately bumps, so compare the semantic state hash.
        assert_eq!(state_hash(&undone.doc), state_hash(&before));
        assert!(undone.doc.workspace.field_overrides.is_empty());
        assert!(before.workspace.field_overrides.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn clearing_an_override_restores_the_inferred_binding() {
        let (engine, root) = imported("override_clear");
        let before = engine.load_workspace("w1").unwrap();
        engine
            .apply(
                "w1",
                &[Command::OverrideFieldType {
                    field: "amount".into(),
                    dtype: "utf8".into(),
                }],
                "2026-11-10T11:03:00Z",
            )
            .unwrap();
        let cleared = engine
            .apply(
                "w1",
                &[Command::ClearFieldOverride {
                    field: "amount".into(),
                }],
                "2026-11-10T11:04:00Z",
            )
            .unwrap();
        assert!(cleared.doc.workspace.field_overrides.is_empty());
        let amount = cleared
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == "metric_amount")
            .unwrap();
        assert_eq!(
            serde_json::to_value(&amount.binding).unwrap()["aggregation"]["op"],
            "avg"
        );
        assert_eq!(
            serde_json::to_value(&before.workspace.layout).unwrap(),
            serde_json::to_value(&cleared.doc.workspace.layout).unwrap()
        );
        std::fs::remove_dir_all(&root).ok();
    }

    // --- task 1.1.6: content addressing, journal recovery, degraded mode ------------------

    #[test]
    fn the_dataset_id_is_the_content_hash_of_the_source() {
        let root = temp_root("hashid");
        let engine = Engine::new(&root).unwrap();
        let out = engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        // Guards the exact confusion that content addressing exposed: `compile` takes
        // (profile, dataset_id, workspace_id, ...), and passing the workspace id for both had
        // hidden the argument order until the two values stopped being equal.
        assert_eq!(
            out.doc.workspace.id, "w1",
            "the workspace must keep the id the caller asked for"
        );
        assert_eq!(
            out.doc.workspace.data_sources[0].dataset_id,
            morphic_workspace::content_hash(SALES),
            "a workspace must reference its dataset by content, not by workspace id"
        );
        assert_ne!(
            out.doc.workspace.id, out.doc.workspace.data_sources[0].dataset_id,
            "workspace identity and dataset identity are different things"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn two_workspaces_over_one_file_share_a_single_dataset() {
        let root = temp_root("dedupe");
        let engine = Engine::new(&root).unwrap();
        for id in ["w1", "w2"] {
            engine
                .import_csv(SALES, "Sales", id, "2026-11-05T00:00:00Z", &mut |_| {})
                .unwrap();
        }
        let datasets: Vec<_> = std::fs::read_dir(root.join("datasets")).unwrap().collect();
        assert_eq!(datasets.len(), 1, "identical content must be stored once");
        // Both are independently queryable.
        for id in ["w1", "w2"] {
            engine.close_session(id).unwrap();
            let snap = engine.open_session(id).unwrap();
            assert!(!snap.degraded);
            assert_eq!(snap.profile.as_ref().unwrap().row_count, 5);
        }
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn deleting_one_workspace_does_not_break_the_other() {
        let root = temp_root("shared-delete");
        let engine = Engine::new(&root).unwrap();
        for id in ["w1", "w2"] {
            engine
                .import_csv(SALES, "Sales", id, "2026-11-05T00:00:00Z", &mut |_| {})
                .unwrap();
        }
        engine.delete_workspace("w1").unwrap();
        engine.close_session("w2").unwrap();
        let snap = engine.open_session("w2").unwrap();
        assert!(!snap.degraded, "w2 still has its data");
        assert_eq!(
            engine.metric_data("w2", "total_records").unwrap().value,
            serde_json::json!(5)
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn reopen_restores_the_pre_crash_revision_from_the_journal() {
        let root = temp_root("crash-rev");
        let engine = Engine::new(&root).unwrap();
        let out = engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        assert_eq!(out.doc.workspace.revision, 1);
        drop(engine);

        // Simulate a crash: revision 2 reached the journal but the workspace.json rename
        // never happened. A second store handle on the same root writes only the journal.
        let store = FileStore::new(&root).unwrap();
        let mut newer = out.doc.clone();
        newer.workspace.revision = 2;
        newer.workspace.modified_at = "2026-11-05T01:00:00Z".into();
        store.journal_revision(&newer).unwrap();

        let reopened = Engine::new(&root).unwrap();
        let snap = reopened.open_session("w1").unwrap();
        assert_eq!(snap.revision, 2, "the save was not lost");
        assert_eq!(snap.doc.workspace.revision, 2);
        assert!(!snap.degraded);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_missing_source_opens_degraded_instead_of_failing() {
        let root = temp_root("degraded");
        let engine = Engine::new(&root).unwrap();
        engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        engine.close_session("w1").unwrap();
        // The dataset disappears (user cleared app data, partial restore, etc.).
        std::fs::remove_dir_all(root.join("datasets")).unwrap();

        let snap = engine.open_session("w1").unwrap();
        assert!(snap.degraded);
        assert!(snap.profile.is_none());
        assert!(snap.notice.is_some());
        assert!(!snap.doc.workspace.components.is_empty(), "layout survives");

        // Data operations are a typed error, not a panic and not an empty result.
        assert!(matches!(
            engine.query_page("w1", &morphic_query::Plan::default()),
            Err(CoreError::SourceUnavailable(_))
        ));
        assert!(matches!(
            engine.metric_data("w1", "total_records"),
            Err(CoreError::SourceUnavailable(_))
        ));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn reimporting_the_same_content_restores_a_degraded_workspace() {
        let root = temp_root("relink");
        let engine = Engine::new(&root).unwrap();
        engine
            .import_csv(SALES, "Sales", "w1", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        engine.close_session("w1").unwrap();
        std::fs::remove_dir_all(root.join("datasets")).unwrap();
        assert!(engine.open_session("w1").unwrap().degraded);
        engine.close_session("w1").unwrap();

        // Re-importing the same bytes restores the dataset by hash, so the old workspace
        // resolves again without any manual relinking.
        let store = FileStore::new(&root).unwrap();
        store.put_dataset(SALES).unwrap();
        let snap = engine.open_session("w1").unwrap();
        assert!(!snap.degraded);
        assert_eq!(snap.profile.as_ref().unwrap().row_count, 5);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_pre_116_workspace_opens_and_is_migrated_transparently() {
        let root = temp_root("legacy-open");
        let engine = Engine::new(&root).unwrap();
        let out = engine
            .import_csv(SALES, "Sales", "w_old", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        engine.close_session("w_old").unwrap();
        drop(engine);

        // Rewind to the pre-1.1.6 layout: source inside the workspace folder, datasetId set
        // to the workspace id, and no content-addressed copy.
        let store = FileStore::new(&root).unwrap();
        let mut old = out.doc.clone();
        old.workspace.data_sources[0].dataset_id = "w_old".into();
        let dir = root.join("workspaces").join("w_old");
        std::fs::write(
            dir.join("workspace.json"),
            serde_json::to_vec_pretty(&old).unwrap(),
        )
        .unwrap();
        std::fs::write(dir.join("source.csv"), SALES).unwrap();
        std::fs::remove_dir_all(root.join("datasets")).unwrap();
        drop(store);

        let reopened = Engine::new(&root).unwrap();
        let snap = reopened.open_session("w_old").unwrap();
        assert!(
            !snap.degraded,
            "a legacy workspace must still open with its data"
        );
        assert_eq!(snap.profile.as_ref().unwrap().row_count, 5);
        assert_eq!(
            snap.doc.workspace.data_sources[0].dataset_id,
            morphic_workspace::content_hash(SALES),
            "and be repointed at the content-addressed dataset"
        );
        assert!(!dir.join("source.csv").exists(), "legacy copy removed");
        assert_eq!(snap.revision, 1, "migration does not bump the revision");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn recents_are_newest_first_through_the_engine() {
        let root = temp_root("recents");
        let engine = Engine::new(&root).unwrap();
        engine
            .import_csv(SALES, "Older", "w_old", "2026-11-01T00:00:00Z", &mut |_| {})
            .unwrap();
        engine
            .import_csv(SALES, "Newer", "w_new", "2026-11-05T00:00:00Z", &mut |_| {})
            .unwrap();
        let ids: Vec<String> = engine
            .list_workspaces()
            .unwrap()
            .into_iter()
            .map(|w| w.id)
            .collect();
        assert_eq!(ids, vec!["w_new", "w_old"]);
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.2 task 1.2.4: cancellation must leave the store untouched (AT-05) -----------

    fn dataset_written(root: &std::path::Path, bytes: &[u8]) -> bool {
        root.join("datasets")
            .join(morphic_workspace::content_hash(bytes))
            .exists()
    }

    fn req<'a>(bytes: &'a [u8], id: &'a str) -> ImportRequest<'a> {
        ImportRequest {
            bytes,
            title: "Sales",
            workspace_id: id,
            now_iso: "2026-11-06T00:00:00Z",
            format_hint: None,
            extension: None,
            cancel: None,
        }
    }

    #[test]
    fn a_cancelled_import_writes_neither_dataset_nor_workspace() {
        let root = temp_root("cancel-pre");
        let engine = Engine::new(&root).unwrap();
        let token = morphic_ingest::CancelToken::new();
        token.cancel();
        let r = ImportRequest {
            cancel: Some(&token),
            ..req(SALES, "w1")
        };
        let err = engine.import(r, &mut |_| {}).unwrap_err();
        assert!(matches!(err, CoreError::Cancelled), "{err}");
        assert!(engine.list_workspaces().unwrap().is_empty());
        assert!(
            !dataset_written(&root, SALES),
            "a cancelled import must not leave a dataset behind"
        );
        assert!(!engine.has_session("w1"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn cancelling_during_parsing_still_writes_nothing() {
        let root = temp_root("cancel-mid");
        let engine = Engine::new(&root).unwrap();
        let token = morphic_ingest::CancelToken::new();
        let trip = token.clone();
        let r = ImportRequest {
            cancel: Some(&token),
            ..req(SALES, "w1")
        };
        // Cancel from inside the real progress callback, i.e. genuinely mid-import. Even if
        // the parser finishes before it notices, the pre-write checkpoint must catch it.
        let err = engine
            .import(r, &mut |_| {
                trip.cancel();
            })
            .unwrap_err();
        assert!(matches!(err, CoreError::Cancelled), "{err}");
        assert!(engine.list_workspaces().unwrap().is_empty());
        assert!(!dataset_written(&root, SALES));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_cancelled_reimport_leaves_the_existing_workspace_intact() {
        let root = temp_root("cancel-existing");
        let engine = Engine::new(&root).unwrap();
        engine
            .import(req(SALES, "w1"), &mut |_| {})
            .expect("first import succeeds");
        let token = morphic_ingest::CancelToken::new();
        token.cancel();
        let r = ImportRequest {
            cancel: Some(&token),
            ..req(b"region,other\neu,1\nus,2\n", "w1")
        };
        assert!(matches!(
            engine.import(r, &mut |_| {}),
            Err(CoreError::Cancelled)
        ));
        engine.close_session("w1").unwrap();
        let snap = engine.open_session("w1").unwrap();
        assert!(!snap.degraded);
        assert_eq!(
            snap.profile.as_ref().unwrap().row_count,
            5,
            "the cancelled attempt must not have touched the stored workspace"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_uncancelled_token_does_not_interfere() {
        let root = temp_root("cancel-noop");
        let engine = Engine::new(&root).unwrap();
        let token = morphic_ingest::CancelToken::new();
        let r = ImportRequest {
            cancel: Some(&token),
            ..req(SALES, "w1")
        };
        let out = engine.import(r, &mut |_| {}).expect("not cancelled");
        assert_eq!(out.report.rows_imported, 5);
        assert!(dataset_written(&root, SALES));
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.3 task 1.3.2: interaction commands, atomic batches, incremental recomputation ---

    const NOW: &str = "2026-11-07T09:00:00Z";

    fn table_id(doc: &WorkspaceDoc) -> String {
        doc.workspace
            .components
            .iter()
            .find(|c| matches!(c.binding, morphic_schema::Binding::DataTable { .. }))
            .expect("the compiler always emits a raw table")
            .id
            .clone()
    }

    fn metric_id(doc: &WorkspaceDoc) -> String {
        doc.workspace
            .components
            .iter()
            .find(|c| matches!(c.binding, morphic_schema::Binding::MetricCard { .. }))
            .expect("the compiler always emits a record count")
            .id
            .clone()
    }

    fn eq_filter(field: &str, value: serde_json::Value) -> morphic_schema::FilterExpr {
        morphic_schema::FilterExpr {
            op: "eq".into(),
            field: Some(field.into()),
            value: Some(value),
            args: vec![],
        }
    }

    fn sort_desc(field: &str) -> morphic_schema::SortRule {
        morphic_schema::SortRule {
            field: field.into(),
            dir: morphic_schema::SortDir::Desc,
            nulls: morphic_schema::NullsOrder::Last,
        }
    }

    #[test]
    fn a_component_command_affects_only_that_component() {
        let (engine, root) = imported("cmd_affected");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let out = engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: table.clone(),
                    sort: vec![sort_desc("amount")],
                }],
                NOW,
            )
            .unwrap();
        assert!(out.changed);
        assert_eq!(out.affected, vec![table]);
        assert_eq!(out.revision, 2);
        assert_eq!(out.doc.workspace.modified_at, NOW);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_global_filter_affects_every_component_in_layout_order() {
        let (engine, root) = imported("cmd_global");
        let doc = engine.snapshot("w1").unwrap().doc;
        let out = engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("eu"))],
                }],
                NOW,
            )
            .unwrap();
        assert_eq!(out.affected, doc.workspace.layout.order);
        assert!(out.affected.len() >= 2);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_rejected_command_leaves_the_document_and_the_disk_untouched() {
        let (engine, root) = imported("cmd_atomic");
        let before = engine.snapshot("w1").unwrap();
        let table = table_id(&before.doc);
        // The first command is valid, the second is not. Neither may land.
        let err = engine
            .apply(
                "w1",
                &[
                    Command::SetComponentSort {
                        component_id: table.clone(),
                        sort: vec![sort_desc("amount")],
                    },
                    Command::SetSearch {
                        component_id: "no_such_component".into(),
                        text: Some("eu".into()),
                    },
                ],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("command 1"), "{err}");
        let after = engine.snapshot("w1").unwrap();
        assert_eq!(after.revision, before.revision);
        assert_eq!(
            serde_json::to_value(&after.doc).unwrap(),
            serde_json::to_value(&before.doc).unwrap(),
            "the valid first command must not have landed either"
        );
        // And nothing reached the store: a fresh engine sees the original document.
        drop(engine);
        let reopened = Engine::new(&root).unwrap();
        let stored = reopened.snapshot("w1").unwrap();
        assert_eq!(stored.revision, before.revision);
        assert!(stored
            .doc
            .workspace
            .components
            .iter()
            .all(|c| c.state.is_empty()));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_batch_lands_as_one_revision() {
        let (engine, root) = imported("cmd_batch");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let metric = metric_id(&doc);
        let out = engine
            .apply(
                "w1",
                &[
                    Command::SetComponentSort {
                        component_id: table.clone(),
                        sort: vec![sort_desc("amount")],
                    },
                    Command::SetSearch {
                        component_id: table.clone(),
                        text: Some("eu".into()),
                    },
                    Command::SetComponentFilter {
                        component_id: metric.clone(),
                        filter: Some(eq_filter("region", serde_json::json!("us"))),
                    },
                ],
                NOW,
            )
            .unwrap();
        assert_eq!(out.revision, 2, "three commands, one revision");
        assert_eq!(out.affected.len(), 2);
        assert!(out.affected.contains(&table) && out.affected.contains(&metric));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn setting_what_is_already_set_changes_nothing() {
        let (engine, root) = imported("cmd_idempotent");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let cmd = Command::SetComponentSort {
            component_id: table.clone(),
            sort: vec![sort_desc("amount")],
        };
        let first = engine.apply("w1", std::slice::from_ref(&cmd), NOW).unwrap();
        assert!(first.changed);
        let second = engine.apply("w1", &[cmd], "2026-11-07T10:00:00Z").unwrap();
        assert!(!second.changed);
        assert!(second.affected.is_empty());
        assert_eq!(second.revision, first.revision);
        assert_eq!(
            second.doc.workspace.modified_at, first.doc.workspace.modified_at,
            "a no-op must not touch modified_at either"
        );
        assert!(engine.apply("w1", &[], NOW).unwrap().affected.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn commands_cannot_exceed_a_components_capabilities() {
        let (engine, root) = imported("cmd_capability");
        let doc = engine.snapshot("w1").unwrap().doc;
        let metric = metric_id(&doc);
        // The compiler gives metric cards filter but not sort or search.
        let err = engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: metric.clone(),
                    sort: vec![sort_desc("amount")],
                }],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("does not allow sorting"), "{err}");
        let err = engine
            .apply(
                "w1",
                &[Command::SetSearch {
                    component_id: metric,
                    text: Some("eu".into()),
                }],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("does not allow search"), "{err}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn unknown_fields_are_rejected_at_the_command_not_at_query_time() {
        let (engine, root) = imported("cmd_fields");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let err = engine
            .apply(
                "w1",
                &[Command::SetComponentFilter {
                    component_id: table.clone(),
                    filter: Some(eq_filter("regn", serde_json::json!("eu"))),
                }],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("unknown field 'regn'"), "{err}");
        let err = engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: table,
                    sort: vec![sort_desc("amout")],
                }],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("unknown sort field"), "{err}");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn only_affected_components_recompute() {
        // The plan's stated verification for 1.3.2. Two components are computed, one is
        // changed, both are asked for again: the untouched one must be served from cache.
        let (engine, root) = imported("cmd_incremental");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let metric = metric_id(&doc);

        engine.component_page("w1", &table, 0, 0).unwrap();
        engine.metric_data("w1", &metric).unwrap();
        assert_eq!(engine.compute_count("w1", &table).unwrap(), 1);
        assert_eq!(engine.compute_count("w1", &metric).unwrap(), 1);

        // Asking again with nothing changed is already free.
        engine.component_page("w1", &table, 0, 0).unwrap();
        engine.metric_data("w1", &metric).unwrap();
        assert_eq!(engine.compute_count("w1", &table).unwrap(), 1, "cache hit");
        assert_eq!(engine.compute_count("w1", &metric).unwrap(), 1, "cache hit");

        let out = engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: table.clone(),
                    sort: vec![sort_desc("amount")],
                }],
                NOW,
            )
            .unwrap();
        assert_eq!(out.affected, vec![table.clone()]);

        engine.component_page("w1", &table, 0, 0).unwrap();
        engine.metric_data("w1", &metric).unwrap();
        assert_eq!(
            engine.compute_count("w1", &table).unwrap(),
            2,
            "the sorted table must recompute"
        );
        assert_eq!(
            engine.compute_count("w1", &metric).unwrap(),
            1,
            "the metric's plan did not change, so it must still hit the cache"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_global_filter_recomputes_everything_because_everything_changed() {
        let (engine, root) = imported("cmd_global_recompute");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        let metric = metric_id(&doc);
        engine.component_page("w1", &table, 0, 0).unwrap();
        engine.metric_data("w1", &metric).unwrap();
        engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("eu"))],
                }],
                NOW,
            )
            .unwrap();
        engine.component_page("w1", &table, 0, 0).unwrap();
        engine.metric_data("w1", &metric).unwrap();
        assert_eq!(engine.compute_count("w1", &table).unwrap(), 2);
        assert_eq!(engine.compute_count("w1", &metric).unwrap(), 2);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn global_and_component_filters_intersect() {
        let (engine, root) = imported("cmd_intersect");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        // SALES: eu 10, us 20, eu 10, us 40, eu 50.
        engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("eu"))],
                }],
                NOW,
            )
            .unwrap();
        let page = engine.component_page("w1", &table, 0, 0).unwrap();
        assert_eq!(page.total_rows, 3);

        engine
            .apply(
                "w1",
                &[Command::SetComponentFilter {
                    component_id: table.clone(),
                    filter: Some(morphic_schema::FilterExpr {
                        op: "gte".into(),
                        field: Some("amount".into()),
                        value: Some(serde_json::json!(50)),
                        args: vec![],
                    }),
                }],
                NOW,
            )
            .unwrap();
        let page = engine.component_page("w1", &table, 0, 0).unwrap();
        assert_eq!(page.total_rows, 1, "eu AND amount >= 50");
        assert_eq!(page.rows[0][0], serde_json::json!("eu"));

        // Clearing the component filter restores the global-only answer exactly.
        engine
            .apply(
                "w1",
                &[Command::SetComponentFilter {
                    component_id: table.clone(),
                    filter: None,
                }],
                NOW,
            )
            .unwrap();
        assert_eq!(
            engine
                .component_page("w1", &table, 0, 0)
                .unwrap()
                .total_rows,
            3
        );
        // Clearing the global filter restores the original five.
        engine
            .apply("w1", &[Command::SetGlobalFilter { filters: vec![] }], NOW)
            .unwrap();
        assert_eq!(
            engine
                .component_page("w1", &table, 0, 0)
                .unwrap()
                .total_rows,
            5
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_component_sort_reorders_the_page_and_search_narrows_it() {
        let (engine, root) = imported("cmd_sort_search");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: table.clone(),
                    sort: vec![sort_desc("amount")],
                }],
                NOW,
            )
            .unwrap();
        let page = engine.component_page("w1", &table, 0, 0).unwrap();
        let amounts: Vec<i64> = page.rows.iter().map(|r| r[1].as_i64().unwrap()).collect();
        assert_eq!(amounts, vec![50, 40, 20, 10, 10]);

        engine
            .apply(
                "w1",
                &[Command::SetSearch {
                    component_id: table.clone(),
                    text: Some("  eu  ".into()),
                }],
                NOW,
            )
            .unwrap();
        let page = engine.component_page("w1", &table, 0, 0).unwrap();
        assert_eq!(page.total_rows, 3, "search is trimmed, not taken literally");
        let amounts: Vec<i64> = page.rows.iter().map(|r| r[1].as_i64().unwrap()).collect();
        assert_eq!(amounts, vec![50, 10, 10], "search and sort compose");

        // Whitespace-only clears the search rather than searching for spaces.
        engine
            .apply(
                "w1",
                &[Command::SetSearch {
                    component_id: table.clone(),
                    text: Some("   ".into()),
                }],
                NOW,
            )
            .unwrap();
        assert_eq!(
            engine
                .component_page("w1", &table, 0, 0)
                .unwrap()
                .total_rows,
            5
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_metric_cards_own_filter_narrows_its_value() {
        let (engine, root) = imported("cmd_metric_filter");
        let doc = engine.snapshot("w1").unwrap().doc;
        let metric = metric_id(&doc);
        let before = engine.metric_data("w1", &metric).unwrap().value;
        assert_eq!(before, serde_json::json!(5), "record count over all rows");
        engine
            .apply(
                "w1",
                &[Command::SetComponentFilter {
                    component_id: metric.clone(),
                    filter: Some(eq_filter("region", serde_json::json!("us"))),
                }],
                NOW,
            )
            .unwrap();
        let after = engine.metric_data("w1", &metric).unwrap();
        assert_eq!(after.value, serde_json::json!(2));
        assert_eq!(after.revision, 2);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_binding_filter_is_applied_not_ignored() {
        // Regression: before M1.3 the aggregation's filter was parsed and then dropped, so a
        // card declared as "count where region = us" counted every row.
        let (engine, root) = imported("cmd_binding_filter");
        let mut doc = engine.snapshot("w1").unwrap().doc;
        let metric = metric_id(&doc);
        {
            let c = doc
                .workspace
                .components
                .iter_mut()
                .find(|c| c.id == metric)
                .unwrap();
            if let morphic_schema::Binding::MetricCard { aggregation } = &mut c.binding {
                aggregation.filter = Some(eq_filter("region", serde_json::json!("us")));
            }
        }
        // Persist the edited binding through the store, then reopen so the engine reads it.
        let store = FileStore::new(&root).unwrap();
        store.save_workspace(&doc).unwrap();
        drop(engine);
        let engine = Engine::new(&root).unwrap();
        let got = engine.metric_data("w1", &metric).unwrap();
        assert_eq!(
            got.value,
            serde_json::json!(2),
            "the binding filter must count"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn interaction_state_survives_save_and_reopen() {
        let (engine, root) = imported("cmd_persist");
        let doc = engine.snapshot("w1").unwrap().doc;
        let table = table_id(&doc);
        engine
            .apply(
                "w1",
                &[
                    Command::SetComponentSort {
                        component_id: table.clone(),
                        sort: vec![sort_desc("amount")],
                    },
                    Command::SetSearch {
                        component_id: table.clone(),
                        text: Some("eu".into()),
                    },
                    Command::SetGlobalFilter {
                        filters: vec![eq_filter("region", serde_json::json!("eu"))],
                    },
                ],
                NOW,
            )
            .unwrap();
        drop(engine);
        let reopened = Engine::new(&root).unwrap();
        let snap = reopened.snapshot("w1").unwrap();
        assert_eq!(snap.revision, 2);
        assert_eq!(snap.doc.workspace.global_filters.len(), 1);
        let c = snap
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == table)
            .unwrap();
        assert_eq!(c.state.sort, vec![sort_desc("amount")]);
        assert_eq!(c.state.search.as_deref(), Some("eu"));
        // And the reopened engine produces the same filtered, sorted answer.
        let page = reopened.component_page("w1", &table, 0, 0).unwrap();
        assert_eq!(page.total_rows, 3);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn commands_have_a_stable_wire_shape() {
        let cmd = Command::SetComponentSort {
            component_id: "t1".into(),
            sort: vec![sort_desc("amount")],
        };
        let wire = serde_json::to_value(&cmd).unwrap();
        assert_eq!(wire["kind"], "setComponentSort");
        assert_eq!(wire["componentId"], "t1");
        let back: Command = serde_json::from_value(wire).unwrap();
        assert_eq!(back, cmd);
        let clear = Command::SetGlobalFilter { filters: vec![] };
        assert_eq!(
            serde_json::to_value(&clear).unwrap()["kind"],
            "setGlobalFilter"
        );
    }

    #[test]
    fn the_duplicated_sort_and_filter_ceilings_agree() {
        // schema may not depend on query, so the constants are declared twice. This is the
        // guard that stops them drifting apart.
        assert_eq!(
            morphic_schema::MAX_SORT_KEYS,
            morphic_query::sort::MAX_SORT_KEYS
        );
        assert_eq!(
            morphic_schema::MAX_FILTER_DEPTH,
            morphic_query::filter::MAX_FILTER_DEPTH
        );
        assert_eq!(
            morphic_schema::MAX_FILTER_NODES,
            morphic_query::filter::MAX_FILTER_NODES
        );
        // And every operator the schema allows, the executor parses.
        for op in morphic_schema::FILTER_OPS {
            let node = match *op {
                "and" | "or" => serde_json::json!({"op": op, "args": [
                    {"op": "eq", "field": "region", "value": "eu"}
                ]}),
                "not" => serde_json::json!({"op": op, "args": [
                    {"op": "eq", "field": "region", "value": "eu"}
                ]}),
                "is_null" | "not_null" => serde_json::json!({"op": op, "field": "region"}),
                "in" => serde_json::json!({"op": op, "field": "region", "value": ["eu"]}),
                "contains" => serde_json::json!({"op": op, "field": "region", "value": "e"}),
                _ => serde_json::json!({"op": op, "field": "amount", "value": 1}),
            };
            assert!(
                morphic_query::Filter::from_json(&node).is_ok(),
                "schema allows '{op}' but the executor rejects it"
            );
        }
    }

    #[test]
    fn two_cards_over_the_same_selection_do_not_share_a_cache_entry() {
        // Regression: the metric cache was keyed on the plan alone. Two unfiltered cards have
        // identical plans, so the average card was served the record count from cache.
        let (engine, root) = imported("cmd_metric_key");
        let doc = engine.snapshot("w1").unwrap().doc;
        let cards: Vec<String> = doc
            .workspace
            .components
            .iter()
            .filter(|c| matches!(c.binding, morphic_schema::Binding::MetricCard { .. }))
            .map(|c| c.id.clone())
            .collect();
        assert!(cards.len() >= 2, "the fixture must produce two cards");
        let values: Vec<serde_json::Value> = cards
            .iter()
            .map(|id| engine.metric_data("w1", id).unwrap().value)
            .collect();
        assert_ne!(
            values[0], values[1],
            "a count and an average are not the same number"
        );
        // And asking again is still a cache hit for each, not a recompute.
        for id in &cards {
            engine.metric_data("w1", id).unwrap();
            assert_eq!(engine.compute_count("w1", id).unwrap(), 1);
        }
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.4 task 1.4.7: ChangeComponentType -------------------------------------------

    fn component_id_of(doc: &WorkspaceDoc, kind: &str) -> String {
        doc.workspace
            .components
            .iter()
            .find(|c| c.component_type == kind)
            .unwrap_or_else(|| panic!("no {kind} component in the generated document"))
            .id
            .clone()
    }

    #[test]
    fn a_type_change_is_converted_persisted_and_explained() {
        let (engine, root) = imported("type_change_ok");
        let before = engine.snapshot("w1").unwrap().doc;
        let table = component_id_of(&before, "data_table");
        let out = engine
            .apply(
                "w1",
                &[Command::ChangeComponentType {
                    component_id: table.clone(),
                    target_type: "metric_card".into(),
                }],
                NOW,
            )
            .unwrap();
        assert!(out.changed);
        assert_eq!(out.affected, vec![table.clone()]);
        assert_eq!(out.revision, 2);
        let c = out
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == table)
            .unwrap();
        assert_eq!(c.component_type, "metric_card");
        assert_eq!(c.binding.kind(), "metric_card");
        let e = c.explanation.as_ref().unwrap();
        assert_eq!(e.reason, morphic_schema::TYPE_CHANGE_REASON);
        assert!(e.detail.contains("data_table"));
        assert!(e.detail.contains("metric_card"));
        assert!(morphic_schema::validate(&out.doc).is_empty());

        // Persistence: a fresh engine reads the converted document back from disk.
        let reopened = Engine::new(&root).unwrap();
        let loaded = reopened.snapshot("w1").unwrap().doc;
        let c2 = loaded
            .workspace
            .components
            .iter()
            .find(|c| c.id == table)
            .unwrap();
        assert_eq!(c2.component_type, "metric_card");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_rejected_type_change_leaves_the_whole_batch_untouched() {
        let (engine, root) = imported("type_change_reject");
        let before = engine.snapshot("w1").unwrap().doc;
        let table = component_id_of(&before, "data_table");
        // SALES has no Timestamp column, so the matrix refuses a timeline. The first command
        // in the batch is valid; atomicity means it must not land either.
        let err = engine
            .apply(
                "w1",
                &[
                    Command::SetGlobalFilter {
                        filters: vec![eq_filter("region", serde_json::json!("eu"))],
                    },
                    Command::ChangeComponentType {
                        component_id: table.clone(),
                        target_type: "timeline".into(),
                    },
                ],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("timestamp"), "{err}");
        let after = engine.snapshot("w1").unwrap().doc;
        assert_eq!(after.workspace.revision, before.workspace.revision);
        assert!(after.workspace.global_filters.is_empty());
        let c = after
            .workspace
            .components
            .iter()
            .find(|c| c.id == table)
            .unwrap();
        assert_eq!(c.component_type, "data_table");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_no_op_type_change_does_not_bump_the_revision() {
        let (engine, root) = imported("type_change_noop");
        let before = engine.snapshot("w1").unwrap().doc;
        let table = component_id_of(&before, "data_table");
        let out = engine
            .apply(
                "w1",
                &[Command::ChangeComponentType {
                    component_id: table,
                    target_type: "data_table".into(),
                }],
                NOW,
            )
            .unwrap();
        assert!(!out.changed);
        assert_eq!(out.revision, before.workspace.revision);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn snapshot_type_options_are_engine_authoritative() {
        let (engine, root) = imported("type_options");
        let snap = engine.snapshot("w1").unwrap();
        let table = component_id_of(&snap.doc, "data_table");
        let opts = snap
            .type_options
            .get(&table)
            .expect("every component must have a matrix entry");
        assert!(
            opts.iter().any(|t| t == "metric_card"),
            "any -> data_table is always allowed: {opts:?}"
        );
        assert!(
            !opts.iter().any(|t| t == "timeline"),
            "SALES has no Timestamp column, so a timeline must not be offered: {opts:?}"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    // --- M1.5 task 1.5.1: undo/redo, bounded journal, restart-surviving depth --------------

    fn ten_mixed_commands(doc: &WorkspaceDoc) -> Vec<Vec<Command>> {
        let table = component_id_of(doc, "data_table");
        let order = &doc.workspace.layout.order;
        assert!(order.len() > 1, "a move needs at least two components");
        let from = order.iter().position(|id| id == &table).unwrap();
        let to_index = if from == 0 { 1 } else { 0 };
        vec![
            vec![Command::SetGlobalFilter {
                filters: vec![eq_filter("region", serde_json::json!("eu"))],
            }],
            vec![Command::SetComponentFilter {
                component_id: table.clone(),
                filter: Some(eq_filter("amount", serde_json::json!(10))),
            }],
            vec![Command::SetComponentSort {
                component_id: table.clone(),
                sort: vec![sort_desc("amount")],
            }],
            vec![Command::SetSearch {
                component_id: table.clone(),
                text: Some("eu".to_string()),
            }],
            vec![Command::MoveComponent {
                component_id: table.clone(),
                to_index,
            }],
            vec![Command::ChangeComponentType {
                component_id: table.clone(),
                target_type: "metric_card".to_string(),
            }],
            vec![Command::OverrideFieldRole {
                field: "region".to_string(),
                role: "dimension".to_string(),
            }],
            vec![Command::OverrideFieldType {
                field: "amount".to_string(),
                dtype: "int64".to_string(),
            }],
            vec![Command::ChangeComponentType {
                component_id: table.clone(),
                target_type: "data_table".to_string(),
            }],
            vec![Command::SetGlobalFilter { filters: vec![] }],
        ]
    }

    #[test]
    fn at13_ten_mixed_commands_undo_and_redo_match_every_state_hash() {
        let (engine, root) = imported("at13_mixed");
        let initial = engine.snapshot("w1").unwrap();
        let batches = ten_mixed_commands(&initial.doc);
        assert_eq!(batches.len(), 10, "AT-13 asks for exactly ten commands");
        let mut hashes = vec![initial.state_hash];
        for (i, batch) in batches.iter().enumerate() {
            let out = engine.apply("w1", batch, NOW).unwrap();
            assert!(out.changed, "command {i} was a no-op: {out:?}");
            hashes.push(out.state_hash);
        }
        assert_eq!(hashes.len(), 11);
        let final_snap = engine.snapshot("w1").unwrap();
        assert_eq!(final_snap.undo_depth, 10);
        assert_eq!(final_snap.redo_depth, 0);

        // Undo all ten, then redo all ten: every intermediate state must match the hash
        // recorded when the mixed run first produced it (AT-13).
        for (i, expected) in hashes.iter().enumerate().take(10).rev() {
            let out = engine.undo("w1", NOW).unwrap();
            assert_eq!(out.state_hash, expected.as_str(), "undo to state {i}");
            assert!(out.changed);
        }
        let bottom = engine.snapshot("w1").unwrap();
        assert_eq!(bottom.undo_depth, 0);
        assert_eq!(bottom.redo_depth, 10);
        for (i, expected) in hashes.iter().enumerate().skip(1) {
            let out = engine.redo("w1", NOW).unwrap();
            assert_eq!(out.state_hash, expected.as_str(), "redo to state {i}");
            assert!(out.changed);
        }
        let top = engine.snapshot("w1").unwrap();
        assert_eq!(top.undo_depth, 10);
        assert_eq!(top.redo_depth, 0);
        assert_eq!(top.state_hash, hashes[10]);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn layout_resize_persists_a_hint_and_is_undoable_after_restart() {
        let (engine, root) = imported("layout_resize");
        let before = engine.snapshot("w1").unwrap().doc;
        let table = component_id_of(&before, "data_table");
        let out = engine
            .apply(
                "w1",
                &[Command::ResizeComponent {
                    component_id: table.clone(),
                    span: Some(2),
                    height: Some("large".into()),
                }],
                NOW,
            )
            .unwrap();
        assert!(out.changed);
        let hint = out
            .doc
            .workspace
            .layout
            .hints
            .iter()
            .find(|h| h.component_id == table)
            .expect("the resize wrote one hint");
        assert_eq!(hint.span, 2);
        assert_eq!(hint.height, "large");
        assert!(morphic_schema::validate(&out.doc).is_empty());

        // A fresh engine is a reopen: the hint and the undo frame must both come from disk.
        let reopened = Engine::new(&root).unwrap();
        let snap = reopened.open_session("w1").unwrap();
        assert_eq!(snap.undo_depth, 1);
        let loaded = snap.doc.workspace.layout.hints;
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].component_id, table);
        assert_eq!(loaded[0].span, 2);
        assert_eq!(loaded[0].height, "large");
        let undone = reopened.undo("w1", NOW).unwrap();
        assert!(undone.doc.workspace.layout.hints.is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn an_invalid_resize_rejects_the_whole_batch() {
        let (engine, root) = imported("layout_resize_reject");
        let before = engine.snapshot("w1").unwrap().doc;
        let table = component_id_of(&before, "data_table");
        let err = engine
            .apply(
                "w1",
                &[
                    Command::MoveComponent {
                        component_id: table.clone(),
                        to_index: 0,
                    },
                    Command::ResizeComponent {
                        component_id: table,
                        span: Some(4),
                        height: None,
                    },
                ],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("invalid layout span"));
        let after = engine.snapshot("w1").unwrap().doc;
        assert_eq!(after.workspace.revision, before.workspace.revision);
        assert_eq!(
            serde_json::to_value(&after.workspace.layout).unwrap(),
            serde_json::to_value(&before.workspace.layout).unwrap()
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn undo_depth_survives_restart_from_the_bounded_journal() {
        let (engine, root) = imported("history_restart");
        let mut hashes = vec![engine.snapshot("w1").unwrap().state_hash];
        for value in ["eu", "us", "eu", "us", "eu", "us"] {
            let out = engine
                .apply(
                    "w1",
                    &[Command::SetGlobalFilter {
                        filters: vec![eq_filter("region", serde_json::json!(value))],
                    }],
                    NOW,
                )
                .unwrap();
            hashes.push(out.state_hash);
        }
        drop(engine);

        // A fresh engine is an app restart: no in-memory session, only the files on disk.
        let reopened = Engine::new(&root).unwrap();
        let snap = reopened.open_session("w1").unwrap();
        assert_eq!(snap.undo_depth, 6, "undo depth must survive restart");
        assert_eq!(snap.state_hash, hashes[6]);
        for i in (0..6).rev() {
            let out = reopened.undo("w1", NOW).unwrap();
            assert_eq!(out.state_hash, hashes[i], "restart undo to state {i}");
        }
        let store = FileStore::new(&root).unwrap();
        let (entries, torn) = store.read_journal("w1").unwrap();
        assert_eq!(torn, 0);
        assert!(entries.len() >= 7, "history was not journaled: {entries:?}");
        assert!(
            entries
                .iter()
                .any(|e| e.commands.as_array().is_some_and(|a| !a.is_empty())),
            "the journal is command-sourced (doc 06 §3)"
        );
        assert!(
            entries.iter().any(|e| !e.inverse_summary.is_empty()),
            "the journal carries inverseSummary"
        );
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_new_command_after_undo_truncates_the_redo_stack() {
        let (engine, root) = imported("truncate_redo");
        let initial = engine.snapshot("w1").unwrap().state_hash;
        let first = engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("eu"))],
                }],
                NOW,
            )
            .unwrap();
        let second = engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("us"))],
                }],
                NOW,
            )
            .unwrap();
        let undone = engine.undo("w1", NOW).unwrap();
        assert_eq!(undone.state_hash, first.state_hash);
        assert_eq!(undone.redo_depth, 1);
        let branched = engine
            .apply(
                "w1",
                &[Command::SetGlobalFilter {
                    filters: vec![eq_filter("region", serde_json::json!("latam"))],
                }],
                NOW,
            )
            .unwrap();
        assert_eq!(branched.redo_depth, 0, "the old future must be dropped");
        assert_eq!(branched.undo_depth, 2);
        let no_redo = engine.redo("w1", NOW).unwrap();
        assert!(!no_redo.changed);
        assert_eq!(no_redo.label, "Nothing to redo");
        assert_ne!(initial, second.state_hash);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_rejected_batch_does_not_push_history() {
        let (engine, root) = imported("rejected_history");
        let snap = engine.snapshot("w1").unwrap();
        let table = component_id_of(&snap.doc, "data_table");
        let good = engine
            .apply(
                "w1",
                &[Command::SetComponentSort {
                    component_id: table.clone(),
                    sort: vec![sort_desc("amount")],
                }],
                NOW,
            )
            .unwrap();
        let err = engine
            .apply(
                "w1",
                &[
                    Command::SetComponentSort {
                        component_id: table.clone(),
                        sort: vec![sort_desc("region")],
                    },
                    Command::SetGlobalFilter {
                        filters: vec![eq_filter("nope", serde_json::json!("x"))],
                    },
                ],
                NOW,
            )
            .unwrap_err();
        assert!(err.to_string().contains("unknown field"), "{err}");
        let after = engine.snapshot("w1").unwrap();
        assert_eq!(after.state_hash, good.state_hash);
        assert_eq!(after.undo_depth, 1, "a failed batch is not undoable work");
        assert_eq!(after.redo_depth, 0);
        std::fs::remove_dir_all(&root).ok();
    }
}
