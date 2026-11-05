//! # morphic-schema
//!
//! The MORPHIC UI Schema v1.0 — a declarative, versioned, validated description of a
//! workspace (docs/architecture/03). This is the product's core IP: **data, never code.**
//!
//! Rust types here are the single source of truth. A JSON Schema artifact and the
//! component-registry manifest are exported from them (see `src/bin/export.rs`) and
//! drift-checked in CI.
//!
//! Phase 0 implements the full document types, structural/registry/referential/resource
//! validation, and export. Binding validation against a live dataset profile (pass 3) is
//! wired in M1.1 once the compiler produces real bindings.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub const SCHEMA_VERSION: &str = "1.0";
pub const MAX_COMPONENTS: usize = 64;

// ---------------------------------------------------------------------------
// Document
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct WorkspaceDoc {
    pub schema_version: String,
    pub workspace: Workspace,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Workspace {
    pub id: String,
    pub title: String,
    pub created_at: String,
    pub modified_at: String,
    pub revision: u64,
    pub generator: Generator,
    pub data_sources: Vec<DataSourceRef>,
    pub layout: Layout,
    #[serde(default)]
    pub global_filters: Vec<FilterExpr>,
    #[serde(default)]
    pub components: Vec<ComponentSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Generator {
    pub kind: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DataSourceRef {
    pub alias: String,
    pub dataset_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Layout {
    /// `adaptive` | `grid` in v1; `freeform` is reserved (P2/P3).
    pub mode: String,
    pub order: Vec<String>,
    #[serde(default)]
    pub hints: Vec<LayoutHint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutHint {
    pub component_id: String,
    #[serde(default = "default_span")]
    pub span: u8,
    #[serde(default)]
    pub height: String,
}

fn default_span() -> u8 {
    1
}

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComponentSpec {
    pub id: String,
    /// Registry key, e.g. `metric_card`.
    #[serde(rename = "type")]
    pub component_type: String,
    pub type_version: String,
    #[serde(default)]
    pub title: Option<String>,
    pub data_source: String,
    pub binding: Binding,
    #[serde(default)]
    pub interactions: Interactions,
    #[serde(default)]
    pub explanation: Option<Explanation>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Interactions {
    #[serde(default)]
    pub filter: bool,
    #[serde(default)]
    pub search: bool,
    #[serde(default)]
    pub sort: bool,
    #[serde(default)]
    pub select: bool,
}

/// Type-specific data binding. Tagged by `kind`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Binding {
    MetricCard {
        aggregation: Aggregation,
    },
    DataTable {
        #[serde(default)]
        columns: Vec<String>,
        #[serde(default = "default_page_size")]
        page_size: u32,
    },
    BarChart {
        dimension: String,
        measure: Aggregation,
        #[serde(default = "default_limit")]
        limit: u32,
    },
    LineChart {
        x: String,
        y: Vec<Aggregation>,
        #[serde(default)]
        group_by: Option<String>,
    },
    Timeline {
        time_field: String,
        #[serde(default)]
        group_by: Option<String>,
        #[serde(default)]
        severity_field: Option<String>,
    },
}

fn default_page_size() -> u32 {
    256
}
fn default_limit() -> u32 {
    12
}

impl Binding {
    pub fn kind(&self) -> &'static str {
        match self {
            Binding::MetricCard { .. } => "metric_card",
            Binding::DataTable { .. } => "data_table",
            Binding::BarChart { .. } => "bar_chart",
            Binding::LineChart { .. } => "line_chart",
            Binding::Timeline { .. } => "timeline",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Aggregation {
    /// count | sum | avg | min | max | distinct_count
    pub op: String,
    #[serde(default)]
    pub field: Option<String>,
    #[serde(default)]
    pub filter: Option<FilterExpr>,
}

/// A safe filter expression. Phase 0 uses a flat node representation; the typed-tree
/// grammar with the full operator set is finalized in M1.3 (docs/architecture/03 §2.3).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FilterExpr {
    /// and | or | not | eq | neq | gt | gte | lt | lte | in | contains | is_null | not_null
    pub op: String,
    #[serde(default)]
    pub field: Option<String>,
    #[serde(default)]
    pub value: Option<serde_json::Value>,
    #[serde(default)]
    pub args: Vec<FilterExpr>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Explanation {
    pub reason: String,
    pub detail: String,
    #[serde(default)]
    pub evidence: Vec<String>,
    #[serde(default)]
    pub confidence: f64,
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ValidationIssue {
    pub pointer: String,
    pub rule: String,
}

/// The set of component types the Phase 1 runtime implements.
pub const ACTIVE_COMPONENTS: &[&str] = &[
    "metric_card",
    "data_table",
    "bar_chart",
    "line_chart",
    "timeline",
];

/// Component ids reserved for later phases (validator rejects them in v1).
pub const RESERVED_COMPONENTS: &[&str] = &[
    "scatter_plot",
    "pie_chart",
    "relationship_graph",
    "search_panel",
    "filter_panel",
    "text_inspector",
    "detail_panel",
    "data_summary",
    "hierarchical_explorer",
];

/// Structural + registry + referential + resource validation (passes 1, 2, 4, 5).
/// Binding validation against a dataset profile (pass 3) is a separate step added in M1.1.
pub fn validate(doc: &WorkspaceDoc) -> Vec<ValidationIssue> {
    let mut issues = Vec::new();
    let ws = &doc.workspace;

    if doc.schema_version != SCHEMA_VERSION {
        issues.push(ValidationIssue {
            pointer: "/schemaVersion".into(),
            rule: format!("unsupported schemaVersion '{}'", doc.schema_version),
        });
    }

    if ws.components.len() > MAX_COMPONENTS {
        issues.push(ValidationIssue {
            pointer: "/workspace/components".into(),
            rule: format!(
                "too many components ({} > {})",
                ws.components.len(),
                MAX_COMPONENTS
            ),
        });
    }

    if !matches!(ws.layout.mode.as_str(), "adaptive" | "grid") {
        issues.push(ValidationIssue {
            pointer: "/workspace/layout/mode".into(),
            rule: format!("unsupported layout mode '{}' in v1", ws.layout.mode),
        });
    }

    // Unique component ids + registry membership + binding/type agreement.
    let mut seen = std::collections::HashSet::new();
    for (i, c) in ws.components.iter().enumerate() {
        let ptr = format!("/workspace/components/{}", i);
        if !seen.insert(c.id.clone()) {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!("duplicate component id '{}'", c.id),
            });
        }
        if RESERVED_COMPONENTS.contains(&c.component_type.as_str()) {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!(
                    "component type '{}' is reserved, not implemented in v1",
                    c.component_type
                ),
            });
        } else if !ACTIVE_COMPONENTS.contains(&c.component_type.as_str()) {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!("unknown component type '{}'", c.component_type),
            });
        }
        if c.binding.kind() != c.component_type {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!(
                    "binding kind '{}' does not match component type '{}'",
                    c.binding.kind(),
                    c.component_type
                ),
            });
        }
        // data source alias must exist
        if !ws.data_sources.iter().any(|d| d.alias == c.data_source) {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!("dataSource '{}' is not a declared alias", c.data_source),
            });
        }
    }

    // Layout order must reference exactly the component ids (no orphans, no missing).
    let comp_ids: std::collections::HashSet<&str> =
        ws.components.iter().map(|c| c.id.as_str()).collect();
    for id in &ws.layout.order {
        if !comp_ids.contains(id.as_str()) {
            issues.push(ValidationIssue {
                pointer: "/workspace/layout/order".into(),
                rule: format!("layout references unknown component '{}'", id),
            });
        }
    }
    for c in &ws.components {
        if !ws.layout.order.iter().any(|o| o == &c.id) {
            issues.push(ValidationIssue {
                pointer: "/workspace/layout/order".into(),
                rule: format!("component '{}' missing from layout order", c.id),
            });
        }
    }

    issues
}

// ---------------------------------------------------------------------------
// Export (single source of truth -> artifacts)
// ---------------------------------------------------------------------------

/// Generate the JSON Schema (draft-07 via schemars 0.8) for `WorkspaceDoc`.
pub fn export_json_schema() -> serde_json::Value {
    let schema = schemars::schema_for!(WorkspaceDoc);
    serde_json::to_value(schema).expect("schema serializes")
}

/// The component-registry manifest (Rust half; Dart contract tests assert coverage).
pub fn registry_manifest() -> serde_json::Value {
    let active: Vec<serde_json::Value> = ACTIVE_COMPONENTS
        .iter()
        .map(|t| serde_json::json!({ "type": t, "typeVersion": "1.0", "status": "active" }))
        .collect();
    let reserved: Vec<serde_json::Value> = RESERVED_COMPONENTS
        .iter()
        .map(|t| serde_json::json!({ "type": t, "status": "reserved" }))
        .collect();
    serde_json::json!({
        "registryVersion": "1.0",
        "components": active,
        "reserved": reserved,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_doc() -> WorkspaceDoc {
        WorkspaceDoc {
            schema_version: SCHEMA_VERSION.into(),
            workspace: Workspace {
                id: "w1".into(),
                title: "Test".into(),
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

    #[test]
    fn minimal_doc_validates() {
        assert!(validate(&minimal_doc()).is_empty());
    }

    #[test]
    fn rejects_unknown_component_type() {
        let mut doc = minimal_doc();
        doc.workspace.components[0].component_type = "web_view".into();
        let issues = validate(&doc);
        assert!(issues
            .iter()
            .any(|i| i.rule.contains("unknown component type")));
    }

    #[test]
    fn rejects_reserved_component_type() {
        let mut doc = minimal_doc();
        doc.workspace.components[0].component_type = "relationship_graph".into();
        let issues = validate(&doc);
        assert!(issues.iter().any(|i| i.rule.contains("reserved")));
    }

    #[test]
    fn rejects_duplicate_ids() {
        let mut doc = minimal_doc();
        let dup = doc.workspace.components[0].clone();
        doc.workspace.components.push(dup);
        doc.workspace.layout.order.push("m1".into());
        let issues = validate(&doc);
        assert!(issues.iter().any(|i| i.rule.contains("duplicate")));
    }

    #[test]
    fn json_schema_export_has_title() {
        let schema = export_json_schema();
        assert!(schema.get("title").is_some() || schema.get("$schema").is_some());
    }

    #[test]
    fn registry_lists_five_active() {
        let m = registry_manifest();
        assert_eq!(m["components"].as_array().unwrap().len(), 5);
    }
}
