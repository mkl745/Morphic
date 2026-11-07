//! # morphic-core
//!
//! The engine facade (docs/architecture/01). It composes the subsystem crates and owns
//! sessions, commands, undo/redo, and events.
//!
//! **M1.1 (task 1.1.4):** real sessions. An import retains the typed `Table` + profile +
//! generated document in memory, so `queryPage` and `metricData` execute against canonical
//! Rust state instead of re-parsing. Reopening a workspace rehydrates the session from the
//! content-addressed source. Typed commands, undo/redo, and layout mutation arrive in M1.5.
//!
//! **M1.1 (task 1.1.6):** datasets are content-addressed, opens replay the write-ahead
//! journal (so a crash mid-save restores the pre-crash revision), pre-1.1.6 workspaces are
//! migrated transparently, and a missing source opens in degraded mode instead of failing.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use morphic_model::{DatasetProfile, ImportReport, Table};
use morphic_schema::WorkspaceDoc;
use morphic_workspace::{FileStore, StoreError, WorkspaceStore};

/// Re-exported so the FFI bridge can create and trip a cancellation token without taking a
/// direct dependency on the ingest crate. Core stays the bridge's only engine surface.
pub use morphic_ingest::CancelToken;
use serde::Serialize;
use thiserror::Error;

/// Bridge contract version. Bumped on breaking FFI changes (docs/architecture/02 §5).
/// v2 adds sessions, queryPage, metricData, and snapshot (M1.1 task 1.1.4).
pub const API_VERSION: u32 = 4;

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
    #[error("session state was poisoned by an earlier panic")]
    SessionPoisoned,
    #[error("source data for workspace '{0}' is unavailable")]
    SourceUnavailable(String),
    #[error("unknown format '{0}'; expected csv, json, jsonl, log or txt")]
    UnknownFormat(String),
    #[error("import cancelled")]
    Cancelled,
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
}

/// The computed value behind one `metric_card`.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetricResult {
    pub component_id: String,
    pub value: serde_json::Value,
    pub revision: u64,
}

/// An open workspace: canonical Rust state that Flutter only renders.
struct Session {
    doc: WorkspaceDoc,
    table: Option<Table>,
    profile: Option<DatasetProfile>,
    notice: Option<String>,
}

/// The engine handle. Owns the workspace store and the open sessions.
pub struct Engine {
    store: FileStore,
    sessions: Mutex<HashMap<String, Session>>,
}

impl Engine {
    pub fn new(storage_root: impl AsRef<Path>) -> Result<Self, CoreError> {
        let store = FileStore::new(storage_root)?;
        // Crash-recovery sweep before anything is opened (docs/architecture/06 §2).
        store.recover()?;
        Ok(Self {
            store,
            sessions: Mutex::new(HashMap::new()),
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
        self.store.save_workspace(&doc)?;

        self.sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?
            .insert(
                workspace_id.to_string(),
                Session {
                    doc: doc.clone(),
                    table: Some(table),
                    profile: Some(profile.clone()),
                    notice: None,
                },
            );

        Ok(ImportOutcome {
            doc,
            profile,
            report,
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

        let snapshot = Snapshot {
            revision: doc.workspace.revision,
            doc: doc.clone(),
            profile: profile.clone(),
            degraded: table.is_none(),
            notice: notice.clone(),
        };
        self.sessions
            .lock()
            .map_err(|_| CoreError::SessionPoisoned)?
            .insert(
                workspace_id.to_string(),
                Session {
                    doc,
                    table,
                    profile,
                    notice,
                },
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
        Ok(Snapshot {
            revision: s.doc.workspace.revision,
            doc: s.doc.clone(),
            profile: s.profile.clone(),
            degraded: s.table.is_none(),
            notice: s.notice.clone(),
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

    /// Compute the value behind a `metric_card`. Rust resolves the binding from the
    /// document; Flutter never re-implements aggregation.
    pub fn metric_data(
        &self,
        workspace_id: &str,
        component_id: &str,
    ) -> Result<MetricResult, CoreError> {
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
        let table = s
            .table
            .as_ref()
            .ok_or_else(|| CoreError::SourceUnavailable(workspace_id.into()))?;
        let value = morphic_query::aggregate(
            table,
            &morphic_query::Aggregate {
                op: &aggregation.op,
                field: aggregation.field.as_deref(),
            },
        )?;
        Ok(MetricResult {
            component_id: component_id.into(),
            value,
            revision: s.doc.workspace.revision,
        })
    }

    pub fn list_workspaces(&self) -> Result<Vec<morphic_workspace::WorkspaceMeta>, CoreError> {
        Ok(self.store.list_workspaces()?)
    }

    /// Delete a workspace and drop its session. The content-addressed dataset is kept:
    /// another workspace may reference the same bytes (docs/architecture/06 §1).
    pub fn delete_workspace(&self, id: &str) -> Result<(), CoreError> {
        self.close_session(id)?;
        self.store.delete_workspace(id)?;
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
}
