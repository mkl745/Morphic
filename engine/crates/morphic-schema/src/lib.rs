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

mod type_change;
pub use type_change::{component_type_options, convert_component_type, TYPE_CHANGE_REASON};

pub const SCHEMA_VERSION: &str = "1.0";
pub const MAX_COMPONENTS: usize = 64;

/// Resource ceilings (docs/architecture/03 §4, quality-and-performance budgets).
/// A document that exceeds these is rejected rather than allowed to stall the runtime.
pub const MAX_PAGE_SIZE: u32 = 1024;
/// Bars a `bar_chart` may keep. `04-component-registry.md` §2 specifies top-N <= 50; the old
/// 2000 let a document ask for a chart 96,000 dp tall. Mirrors `morphic_query::MAX_BAR_POINTS`;
/// the two are pinned equal by a test in morphic-core, because this crate may not depend on the
/// query crate.
pub const MAX_BAR_LIMIT: u32 = 50;
pub const MAX_LINE_SERIES: usize = 8;
/// Sort keys per component. Mirrors `morphic_query::sort::MAX_SORT_KEYS`; the two are pinned
/// equal by a test in morphic-core, because this crate may not depend on the query crate.
pub const MAX_SORT_KEYS: usize = 8;
/// Filter tree ceilings (docs/architecture/03 §3 pass 4). Same values as the executor's, for
/// the same reason: a plan the schema accepts must be a plan the engine will run.
pub const MAX_FILTER_DEPTH: usize = 32;
pub const MAX_FILTER_NODES: usize = 512;

/// The closed aggregation vocabulary. Anything else is a schema error, not a silent no-op.
pub const AGGREGATION_OPS: &[&str] = &["count", "sum", "avg", "min", "max", "distinct_count"];

/// The closed filter vocabulary. Kept in step with `morphic_query::Filter::from_json`.
pub const FILTER_OPS: &[&str] = &[
    "and", "or", "not", "eq", "neq", "gt", "gte", "lt", "lte", "in", "contains", "is_null",
    "not_null",
];

/// Closed vocabularies for M1.5's persisted field overrides (docs/architecture/05 §3.2).
pub const FIELD_ROLES: &[&str] = &[
    "unknown",
    "temporal",
    "measure",
    "dimension",
    "severity",
    "identifier",
    "text",
];
pub const DATA_TYPES: &[&str] = &["null", "bool", "int64", "float64", "utf8", "timestamp"];

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
    // User corrections to inferred field type/role (M1.5). Additive and optional: v1.0
    // documents written before the field existed still load unchanged.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub field_overrides: Vec<FieldOverride>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FieldOverride {
    pub field: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dtype: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
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
    /// Persisted interaction state (docs/architecture/03 §2.1). Omitted from JSON when empty so
    /// a generated document is byte-identical to one written before M1.3.
    #[serde(default, skip_serializing_if = "ComponentState::is_empty")]
    pub state: ComponentState,
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

/// What the user has done to one component: the filter they applied, the sort they chose, the
/// search they typed. `interactions` says what a component *allows*; this says what is
/// *currently set*. Persisted so a sort indicator survives save and reopen (AT-07, AT-09).
///
/// A flat struct rather than a per-type enum, with pass 5 checking the keys against the
/// component's capabilities — the contract's "state keys valid for type" rule.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ComponentState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub filter: Option<FilterExpr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub sort: Vec<SortRule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub search: Option<String>,
}

impl ComponentState {
    pub fn is_empty(&self) -> bool {
        self.filter.is_none() && self.sort.is_empty() && self.search.is_none()
    }
}

/// One sort key. This crate cannot depend on `morphic-query` (DAG rule), so it declares its own
/// vocabulary and morphic-core converts; a test pins the two against each other.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SortRule {
    pub field: String,
    #[serde(default)]
    pub dir: SortDir,
    #[serde(default)]
    pub nulls: NullsOrder,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SortDir {
    #[default]
    Asc,
    Desc,
}

/// Where nulls go, independent of direction. `last` means last ascending *and* descending.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum NullsOrder {
    First,
    #[default]
    Last,
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
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

        // Pass 5: resource ceilings + closed aggregation vocabulary.
        validate_binding_resources(c, &ptr, &mut issues);
        validate_state(c, &ptr, &mut issues);
    }

    // Pass 4: global filters obey the same ceilings as component filters.
    for (i, f) in ws.global_filters.iter().enumerate() {
        let mut nodes = 0usize;
        validate_filter(
            f,
            &format!("/workspace/globalFilters/{i}"),
            0,
            &mut nodes,
            &mut issues,
        );
    }

    // Persisted field corrections are closed-vocabulary and unique per field.
    let mut overridden = std::collections::HashSet::new();
    for (i, o) in ws.field_overrides.iter().enumerate() {
        let ptr = format!("/workspace/fieldOverrides/{i}");
        if o.field.trim().is_empty() {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: "field override names no field".into(),
            });
        }
        if !overridden.insert(o.field.as_str()) {
            issues.push(ValidationIssue {
                pointer: ptr.clone(),
                rule: format!("duplicate field override '{}'", o.field),
            });
        }
        if let Some(d) = &o.dtype {
            if !DATA_TYPES.contains(&d.as_str()) {
                issues.push(ValidationIssue {
                    pointer: ptr.clone(),
                    rule: format!("unknown dtype override '{d}'"),
                });
            }
        }
        if let Some(r) = &o.role {
            if !FIELD_ROLES.contains(&r.as_str()) {
                issues.push(ValidationIssue {
                    pointer: ptr.clone(),
                    rule: format!("unknown role override '{r}'"),
                });
            }
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

/// Pass 5: "state keys valid for type". `interactions` declares what a component allows; state
/// that exceeds it is a document error, not something the UI is trusted to avoid sending.
fn validate_state(c: &ComponentSpec, ptr: &str, issues: &mut Vec<ValidationIssue>) {
    let st = &c.state;
    if st.filter.is_some() && !c.interactions.filter {
        issues.push(ValidationIssue {
            pointer: format!("{ptr}/state/filter"),
            rule: format!("'{}' does not allow filtering", c.component_type),
        });
    }
    if !st.sort.is_empty() && !c.interactions.sort {
        issues.push(ValidationIssue {
            pointer: format!("{ptr}/state/sort"),
            rule: format!("'{}' does not allow sorting", c.component_type),
        });
    }
    if st.search.is_some() && !c.interactions.search {
        issues.push(ValidationIssue {
            pointer: format!("{ptr}/state/search"),
            rule: format!("'{}' does not allow search", c.component_type),
        });
    }
    if let Some(f) = &st.filter {
        let mut nodes = 0usize;
        validate_filter(f, &format!("{ptr}/state/filter"), 0, &mut nodes, issues);
    }
    if st.sort.len() > MAX_SORT_KEYS {
        issues.push(ValidationIssue {
            pointer: format!("{ptr}/state/sort"),
            rule: format!("too many sort keys ({} > {})", st.sort.len(), MAX_SORT_KEYS),
        });
    }
    // A repeated field makes the second key unreachable, which is a mistake rather than a
    // preference; silently ignoring it would hide the mistake.
    for (i, rule) in st.sort.iter().enumerate() {
        if rule.field.is_empty() {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/state/sort/{i}/field"),
                rule: "sort field must not be empty".into(),
            });
        }
        if st.sort[..i].iter().any(|prev| prev.field == rule.field) {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/state/sort/{i}/field"),
                rule: format!("duplicate sort field '{}'", rule.field),
            });
        }
    }
}

/// Pass 4: the filter grammar is closed and its shape is bounded. Depth and node ceilings match
/// the executor's so a document the schema accepts is a plan the engine will run.
fn validate_filter(
    f: &FilterExpr,
    ptr: &str,
    depth: usize,
    nodes: &mut usize,
    issues: &mut Vec<ValidationIssue>,
) {
    if depth > MAX_FILTER_DEPTH {
        issues.push(ValidationIssue {
            pointer: ptr.into(),
            rule: format!("filter nesting exceeds {MAX_FILTER_DEPTH} levels"),
        });
        return;
    }
    *nodes += 1;
    if *nodes > MAX_FILTER_NODES {
        // One issue for the whole tree, not one per remaining node.
        if *nodes == MAX_FILTER_NODES + 1 {
            issues.push(ValidationIssue {
                pointer: ptr.into(),
                rule: format!("filter exceeds {MAX_FILTER_NODES} nodes"),
            });
        }
        return;
    }
    if !FILTER_OPS.contains(&f.op.as_str()) {
        issues.push(ValidationIssue {
            pointer: format!("{ptr}/op"),
            rule: format!("unknown filter operator '{}'", f.op),
        });
        return;
    }
    let connective = matches!(f.op.as_str(), "and" | "or" | "not");
    if connective {
        if f.op == "not" && f.args.len() != 1 {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/args"),
                rule: "'not' takes exactly one arg".into(),
            });
        }
        if f.op != "not" && f.args.is_empty() {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/args"),
                rule: format!("'{}' needs at least one arg", f.op),
            });
        }
    } else {
        if !f.args.is_empty() {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/args"),
                rule: format!("'{}' is a leaf and takes no args", f.op),
            });
        }
        if f.field.as_deref().unwrap_or("").is_empty() {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/field"),
                rule: format!("'{}' requires a field", f.op),
            });
        }
        let needs_value = !matches!(f.op.as_str(), "is_null" | "not_null");
        if needs_value && f.value.is_none() {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/value"),
                rule: format!("'{}' requires a value", f.op),
            });
        }
        if f.op == "in" && !matches!(f.value, Some(serde_json::Value::Array(_))) {
            issues.push(ValidationIssue {
                pointer: format!("{ptr}/value"),
                rule: "'in' requires an array value".into(),
            });
        }
    }
    for (i, arg) in f.args.iter().enumerate() {
        validate_filter(arg, &format!("{ptr}/args/{i}"), depth + 1, nodes, issues);
    }
}

/// Closed-vocabulary check for one aggregation. A free function rather than a closure so
/// callers can keep pushing to the same `issues` vector without a unique-borrow conflict.
fn check_agg_op(agg: &Aggregation, location: &str, issues: &mut Vec<ValidationIssue>) {
    if !AGGREGATION_OPS.contains(&agg.op.as_str()) {
        issues.push(ValidationIssue {
            pointer: location.into(),
            rule: format!("unknown aggregation op '{}'", agg.op),
        });
    }
    if let Some(f) = &agg.filter {
        let mut nodes = 0usize;
        validate_filter(f, &format!("{location}/filter"), 0, &mut nodes, issues);
    }
}

/// Pass 5: aggregation vocabulary and resource ceilings. Profile-independent.
fn validate_binding_resources(c: &ComponentSpec, ptr: &str, issues: &mut Vec<ValidationIssue>) {
    match &c.binding {
        Binding::MetricCard { aggregation } => {
            check_agg_op(aggregation, &format!("{ptr}/binding/aggregation"), issues);
        }
        Binding::DataTable { page_size, .. } => {
            if *page_size == 0 || *page_size > MAX_PAGE_SIZE {
                issues.push(ValidationIssue {
                    pointer: format!("{ptr}/binding/page_size"),
                    rule: format!("page_size {} out of range 1..={}", page_size, MAX_PAGE_SIZE),
                });
            }
        }
        Binding::BarChart { limit, measure, .. } => {
            if *limit == 0 || *limit > MAX_BAR_LIMIT {
                issues.push(ValidationIssue {
                    pointer: format!("{ptr}/binding/limit"),
                    rule: format!("limit {} out of range 1..={}", limit, MAX_BAR_LIMIT),
                });
            }
            check_agg_op(measure, &format!("{ptr}/binding/measure"), issues);
        }
        Binding::LineChart { y, .. } => {
            if y.is_empty() {
                issues.push(ValidationIssue {
                    pointer: format!("{ptr}/binding/y"),
                    rule: "lineChart requires at least one series".into(),
                });
            }
            if y.len() > MAX_LINE_SERIES {
                issues.push(ValidationIssue {
                    pointer: format!("{ptr}/binding/y"),
                    rule: format!("too many series ({} > {})", y.len(), MAX_LINE_SERIES),
                });
            }
            for (i, agg) in y.iter().enumerate() {
                check_agg_op(agg, &format!("{ptr}/binding/y/{i}"), issues);
            }
        }
        Binding::Timeline { .. } => {}
    }
}

/// Look up a field by name in the profile.
fn find_field<'a>(
    profile: &'a morphic_model::DatasetProfile,
    name: &str,
) -> Option<&'a morphic_model::FieldProfile> {
    profile.fields.iter().find(|f| f.name == name)
}

/// Require that a referenced field exists; records an issue and returns false if not.
fn require_field(
    profile: &morphic_model::DatasetProfile,
    name: &str,
    ptr: &str,
    issues: &mut Vec<ValidationIssue>,
) -> bool {
    if find_field(profile, name).is_some() {
        return true;
    }
    issues.push(ValidationIssue {
        pointer: ptr.into(),
        rule: format!("field '{name}' does not exist in the dataset"),
    });
    false
}

/// Check that an aggregation names an existing field and is meaningful for its type.
fn check_aggregation(
    profile: &morphic_model::DatasetProfile,
    agg: &Aggregation,
    ptr: &str,
    issues: &mut Vec<ValidationIssue>,
) {
    let needs_field = matches!(
        agg.op.as_str(),
        "sum" | "avg" | "min" | "max" | "distinct_count"
    );
    let Some(name) = &agg.field else {
        if needs_field {
            issues.push(ValidationIssue {
                pointer: ptr.into(),
                rule: format!("aggregation '{}' requires a field", agg.op),
            });
        }
        return;
    };
    let Some(f) = find_field(profile, name) else {
        issues.push(ValidationIssue {
            pointer: ptr.into(),
            rule: format!("field '{name}' does not exist in the dataset"),
        });
        return;
    };
    let numeric = f.dtype.is_numeric();
    let ordered = numeric || f.dtype == morphic_model::DataType::Timestamp;
    let ok = match agg.op.as_str() {
        // Summing or averaging a timestamp is meaningless.
        "sum" | "avg" => numeric,
        "min" | "max" => ordered,
        _ => true,
    };
    if !ok {
        issues.push(ValidationIssue {
            pointer: ptr.into(),
            rule: format!(
                "aggregation '{}' is not valid for field '{}' of type {}",
                agg.op,
                name,
                f.dtype.as_str()
            ),
        });
    }
}

/// **Pass 3 — binding validation against a live dataset profile.**
///
/// Structural validity does not imply a binding can actually be computed. This checks that
/// every referenced field exists and that each aggregation is meaningful for the field's
/// physical type, so the runtime never receives a document it cannot execute.
pub fn validate_bindings(
    doc: &WorkspaceDoc,
    profile: &morphic_model::DatasetProfile,
) -> Vec<ValidationIssue> {
    use morphic_model::{DataType, FieldRole};

    let mut issues = Vec::new();
    for (i, c) in doc.workspace.components.iter().enumerate() {
        let ptr = format!("/workspace/components/{}", i);
        match &c.binding {
            Binding::MetricCard { aggregation } => {
                check_aggregation(
                    profile,
                    aggregation,
                    &format!("{ptr}/binding/aggregation"),
                    &mut issues,
                );
            }
            Binding::DataTable { columns, .. } => {
                for (j, col) in columns.iter().enumerate() {
                    require_field(
                        profile,
                        col,
                        &format!("{ptr}/binding/columns/{j}"),
                        &mut issues,
                    );
                }
            }
            Binding::BarChart {
                dimension, measure, ..
            } => {
                require_field(
                    profile,
                    dimension,
                    &format!("{ptr}/binding/dimension"),
                    &mut issues,
                );
                check_aggregation(
                    profile,
                    measure,
                    &format!("{ptr}/binding/measure"),
                    &mut issues,
                );
            }
            Binding::LineChart { x, y, group_by } => {
                if require_field(profile, x, &format!("{ptr}/binding/x"), &mut issues) {
                    let f = find_field(profile, x).expect("checked by require_field");
                    if !(f.dtype == DataType::Timestamp
                        || f.dtype.is_numeric()
                        || f.inference.role == FieldRole::Temporal)
                    {
                        issues.push(ValidationIssue {
                            pointer: format!("{ptr}/binding/x"),
                            rule: format!(
                                "lineChart x field '{x}' must be temporal or numeric, got {}",
                                f.dtype.as_str()
                            ),
                        });
                    }
                }
                for (j, agg) in y.iter().enumerate() {
                    check_aggregation(profile, agg, &format!("{ptr}/binding/y/{j}"), &mut issues);
                }
                if let Some(g) = group_by {
                    require_field(profile, g, &format!("{ptr}/binding/group_by"), &mut issues);
                }
            }
            Binding::Timeline {
                time_field,
                group_by,
                severity_field,
            } => {
                if require_field(
                    profile,
                    time_field,
                    &format!("{ptr}/binding/time_field"),
                    &mut issues,
                ) {
                    let f = find_field(profile, time_field).expect("checked by require_field");
                    if !(f.dtype == DataType::Timestamp || f.inference.role == FieldRole::Temporal)
                    {
                        issues.push(ValidationIssue {
                            pointer: format!("{ptr}/binding/time_field"),
                            rule: format!("timeline time_field '{time_field}' is not temporal"),
                        });
                    }
                }
                if let Some(g) = group_by {
                    require_field(profile, g, &format!("{ptr}/binding/group_by"), &mut issues);
                }
                if let Some(s) = severity_field {
                    require_field(
                        profile,
                        s,
                        &format!("{ptr}/binding/severity_field"),
                        &mut issues,
                    );
                }
            }
        }
    }
    issues
}

/// All five passes: structural, registry, **binding**, referential, resource.
pub fn validate_with_profile(
    doc: &WorkspaceDoc,
    profile: &morphic_model::DatasetProfile,
) -> Vec<ValidationIssue> {
    let mut issues = validate(doc);
    let names: Vec<&str> = profile.fields.iter().map(|f| f.name.as_str()).collect();
    for (i, o) in doc.workspace.field_overrides.iter().enumerate() {
        if !names.contains(&o.field.as_str()) {
            issues.push(ValidationIssue {
                pointer: format!("/workspace/fieldOverrides/{i}"),
                rule: format!("override names unknown field '{}'", o.field),
            });
        }
    }
    issues.extend(validate_bindings(doc, profile));
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

    pub(crate) fn minimal_doc() -> WorkspaceDoc {
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

    // --- M1.1 task 1.1.3: pass 3 (bindings) + pass 5 (resources) ---

    use morphic_model::{DataType, DatasetProfile, FieldProfile, FieldRole, Inference};

    fn fp(name: &str, dtype: DataType, role: FieldRole) -> FieldProfile {
        FieldProfile {
            name: name.into(),
            dtype,
            null_count: 0,
            distinct_count: 5,
            min: None,
            max: None,
            top_values: vec![],
            stats: None,
            inference: Inference {
                role,
                confidence: 0.9,
                evidence: vec![],
            },
        }
    }

    fn sample_profile() -> DatasetProfile {
        let fields = vec![
            fp("amount", DataType::Float64, FieldRole::Measure),
            fp("count", DataType::Int64, FieldRole::Measure),
            fp("when", DataType::Timestamp, FieldRole::Temporal),
            fp("region", DataType::Utf8, FieldRole::Dimension),
            fp("note", DataType::Utf8, FieldRole::Text),
        ];
        DatasetProfile {
            row_count: 10,
            field_count: fields.len(),
            fields,
        }
    }

    /// Replace the single component's binding, keeping the document structurally valid.
    fn with_binding(binding: Binding) -> WorkspaceDoc {
        let mut doc = minimal_doc();
        let kind = binding.kind().to_string();
        doc.workspace.components[0].component_type = kind;
        doc.workspace.components[0].binding = binding;
        doc
    }

    fn agg(op: &str, field: Option<&str>) -> Aggregation {
        Aggregation {
            op: op.into(),
            field: field.map(|s| s.into()),
            filter: None,
        }
    }

    #[test]
    fn resource_pass_rejects_oversized_page() {
        let doc = with_binding(Binding::DataTable {
            columns: vec![],
            page_size: MAX_PAGE_SIZE + 1,
        });
        assert!(validate(&doc).iter().any(|i| i.rule.contains("page_size")));
    }

    #[test]
    fn resource_pass_rejects_zero_page() {
        let doc = with_binding(Binding::DataTable {
            columns: vec![],
            page_size: 0,
        });
        assert!(validate(&doc).iter().any(|i| i.rule.contains("page_size")));
    }

    #[test]
    fn resource_pass_accepts_boundary_page() {
        let doc = with_binding(Binding::DataTable {
            columns: vec![],
            page_size: MAX_PAGE_SIZE,
        });
        assert!(validate(&doc).is_empty());
    }

    #[test]
    fn resource_pass_rejects_oversized_bar_limit() {
        let doc = with_binding(Binding::BarChart {
            dimension: "region".into(),
            measure: agg("count", None),
            limit: MAX_BAR_LIMIT + 1,
        });
        assert!(validate(&doc).iter().any(|i| i.rule.contains("limit")));
    }

    #[test]
    fn resource_pass_rejects_empty_line_series() {
        let doc = with_binding(Binding::LineChart {
            x: "when".into(),
            y: vec![],
            group_by: None,
        });
        assert!(validate(&doc)
            .iter()
            .any(|i| i.rule.contains("at least one series")));
    }

    #[test]
    fn resource_pass_rejects_unknown_aggregation_op() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("median", Some("amount")),
        });
        assert!(validate(&doc)
            .iter()
            .any(|i| i.rule.contains("unknown aggregation op")));
    }

    #[test]
    fn binding_pass_accepts_a_well_formed_document() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("avg", Some("amount")),
        });
        assert!(validate_with_profile(&doc, &sample_profile()).is_empty());
    }

    #[test]
    fn binding_pass_rejects_a_missing_field() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("avg", Some("ghost")),
        });
        let issues = validate_bindings(&doc, &sample_profile());
        assert!(issues.iter().any(|i| i.rule.contains("does not exist")));
    }

    #[test]
    fn binding_pass_requires_a_field_for_sum() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("sum", None),
        });
        assert!(validate_bindings(&doc, &sample_profile())
            .iter()
            .any(|i| i.rule.contains("requires a field")));
    }

    #[test]
    fn binding_pass_allows_count_without_a_field() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("count", None),
        });
        assert!(validate_bindings(&doc, &sample_profile()).is_empty());
    }

    #[test]
    fn binding_pass_rejects_summing_text() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("sum", Some("note")),
        });
        assert!(validate_bindings(&doc, &sample_profile())
            .iter()
            .any(|i| i.rule.contains("not valid for field")));
    }

    #[test]
    fn binding_pass_rejects_averaging_a_timestamp() {
        let doc = with_binding(Binding::MetricCard {
            aggregation: agg("avg", Some("when")),
        });
        assert!(validate_bindings(&doc, &sample_profile())
            .iter()
            .any(|i| i.rule.contains("not valid for field")));
    }

    #[test]
    fn binding_pass_allows_min_max_on_timestamps() {
        for op in ["min", "max"] {
            let doc = with_binding(Binding::MetricCard {
                aggregation: agg(op, Some("when")),
            });
            assert!(
                validate_bindings(&doc, &sample_profile()).is_empty(),
                "{op} on a timestamp is meaningful"
            );
        }
    }

    #[test]
    fn binding_pass_checks_table_columns() {
        let doc = with_binding(Binding::DataTable {
            columns: vec!["amount".into(), "ghost".into()],
            page_size: 256,
        });
        let issues = validate_bindings(&doc, &sample_profile());
        assert!(issues
            .iter()
            .any(|i| i.pointer.contains("/binding/columns/1")));
    }

    #[test]
    fn binding_pass_requires_temporal_or_numeric_line_x() {
        let bad = with_binding(Binding::LineChart {
            x: "note".into(),
            y: vec![agg("avg", Some("amount"))],
            group_by: None,
        });
        assert!(validate_bindings(&bad, &sample_profile())
            .iter()
            .any(|i| i.rule.contains("must be temporal or numeric")));
        let good = with_binding(Binding::LineChart {
            x: "when".into(),
            y: vec![agg("avg", Some("amount"))],
            group_by: None,
        });
        assert!(validate_bindings(&good, &sample_profile()).is_empty());
    }

    #[test]
    fn binding_pass_requires_temporal_timeline_field() {
        let bad = with_binding(Binding::Timeline {
            time_field: "region".into(),
            group_by: None,
            severity_field: None,
        });
        assert!(validate_bindings(&bad, &sample_profile())
            .iter()
            .any(|i| i.rule.contains("is not temporal")));
    }

    #[test]
    fn binding_pass_checks_optional_group_and_severity_fields() {
        let doc = with_binding(Binding::Timeline {
            time_field: "when".into(),
            group_by: Some("ghost".into()),
            severity_field: Some("phantom".into()),
        });
        let issues = validate_bindings(&doc, &sample_profile());
        assert!(issues.iter().any(|i| i.pointer.contains("group_by")));
        assert!(issues.iter().any(|i| i.pointer.contains("severity_field")));
    }

    /// Resolve an RFC-6901 JSON Pointer against a serialized value.
    fn resolve<'a>(v: &'a serde_json::Value, pointer: &str) -> Option<&'a serde_json::Value> {
        let mut cur = v;
        for raw in pointer.split('/').skip(1) {
            let key = raw.replace("~1", "/").replace("~0", "~");
            cur = match cur {
                serde_json::Value::Object(m) => m.get(&key)?,
                serde_json::Value::Array(a) => a.get(key.parse::<usize>().ok()?)?,
                _ => return None,
            };
        }
        Some(cur)
    }

    /// Every issue must point at a real location in the document. This caught a genuine
    /// defect: binding variant fields serialize snake_case (`time_field`), so pointers
    /// written as `timeField` addressed keys that do not exist.
    #[test]
    fn every_issue_pointer_resolves_in_the_serialized_document() {
        let cases = vec![
            with_binding(Binding::MetricCard {
                aggregation: agg("avg", Some("ghost")),
            }),
            with_binding(Binding::MetricCard {
                aggregation: agg("sum", None),
            }),
            with_binding(Binding::MetricCard {
                aggregation: agg("avg", Some("when")),
            }),
            with_binding(Binding::DataTable {
                columns: vec!["ghost".into()],
                page_size: 0,
            }),
            with_binding(Binding::BarChart {
                dimension: "ghost".into(),
                measure: agg("median", None),
                limit: 0,
            }),
            with_binding(Binding::LineChart {
                x: "note".into(),
                y: vec![agg("avg", Some("ghost"))],
                group_by: Some("ghost".into()),
            }),
            with_binding(Binding::Timeline {
                time_field: "region".into(),
                group_by: Some("ghost".into()),
                severity_field: Some("ghost".into()),
            }),
        ];
        let profile = sample_profile();
        let mut checked = 0;
        for doc in cases {
            let value = serde_json::to_value(&doc).unwrap();
            let issues = validate_with_profile(&doc, &profile);
            assert!(!issues.is_empty(), "case should produce issues");
            for issue in issues {
                assert!(
                    resolve(&value, &issue.pointer).is_some(),
                    "pointer '{}' does not resolve (rule: {})",
                    issue.pointer,
                    issue.rule
                );
                checked += 1;
            }
        }
        assert!(
            checked > 10,
            "expected a meaningful number of pointers, got {checked}"
        );
    }
}

#[cfg(test)]
mod state_tests {
    use super::*;

    fn doc_with_state(state: ComponentState, interactions: Interactions) -> WorkspaceDoc {
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.components[0].state = state;
        doc.workspace.components[0].interactions = interactions;
        doc
    }

    fn table_interactions() -> Interactions {
        Interactions {
            filter: true,
            search: true,
            sort: true,
            select: true,
        }
    }

    fn rule(field: &str) -> SortRule {
        SortRule {
            field: field.into(),
            dir: SortDir::Asc,
            nulls: NullsOrder::Last,
        }
    }

    #[test]
    fn empty_state_is_omitted_from_json() {
        // A generated document must stay byte-identical to a pre-M1.3 one.
        let doc = doc_with_state(ComponentState::default(), table_interactions());
        let json = serde_json::to_value(&doc).unwrap();
        assert!(json["workspace"]["components"][0].get("state").is_none());
    }

    #[test]
    fn state_round_trips_and_defaults_are_direction_and_nulls() {
        // Deserialized without dir/nulls, so this genuinely tests the defaults.
        let bare: SortRule = serde_json::from_value(serde_json::json!({"field":"amount"})).unwrap();
        assert_eq!(bare.dir, SortDir::Asc);
        assert_eq!(bare.nulls, NullsOrder::Last);
        let state = ComponentState {
            filter: None,
            sort: vec![bare],
            search: Some("eu".into()),
        };
        let doc = doc_with_state(state.clone(), table_interactions());
        let wire = serde_json::to_value(&doc).unwrap();
        assert_eq!(
            wire["workspace"]["components"][0]["state"]["sort"][0]["dir"],
            "asc"
        );
        assert_eq!(
            wire["workspace"]["components"][0]["state"]["sort"][0]["nulls"],
            "last"
        );
        let back: WorkspaceDoc = serde_json::from_value(wire).unwrap();
        assert_eq!(back.workspace.components[0].state, state);
        assert!(validate(&back).is_empty());
    }

    #[test]
    fn a_pre_13_document_without_state_still_decodes() {
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.components[0].interactions = table_interactions();
        let mut wire = serde_json::to_value(&doc).unwrap();
        wire["workspace"]["components"][0]
            .as_object_mut()
            .unwrap()
            .remove("state");
        let back: WorkspaceDoc = serde_json::from_value(wire).unwrap();
        assert!(back.workspace.components[0].state.is_empty());
    }

    #[test]
    fn state_beyond_the_components_capabilities_is_rejected() {
        // A metric card allows filtering but not sorting or search.
        let metric = Interactions {
            filter: true,
            ..Default::default()
        };
        let doc = doc_with_state(
            ComponentState {
                sort: vec![rule("amount")],
                ..Default::default()
            },
            metric.clone(),
        );
        let issues = validate(&doc);
        assert!(
            issues.iter().any(|i| i.pointer.ends_with("/state/sort")),
            "{issues:?}"
        );

        let doc = doc_with_state(
            ComponentState {
                search: Some("x".into()),
                ..Default::default()
            },
            metric,
        );
        assert!(validate(&doc)
            .iter()
            .any(|i| i.pointer.ends_with("/state/search")));
    }

    #[test]
    fn sort_keys_are_bounded_and_unique() {
        let many: Vec<SortRule> = (0..MAX_SORT_KEYS + 1)
            .map(|i| rule(&format!("f{i}")))
            .collect();
        let doc = doc_with_state(
            ComponentState {
                sort: many,
                ..Default::default()
            },
            table_interactions(),
        );
        assert!(validate(&doc)
            .iter()
            .any(|i| i.rule.contains("too many sort keys")));

        let doc = doc_with_state(
            ComponentState {
                sort: vec![rule("a"), rule("a")],
                ..Default::default()
            },
            table_interactions(),
        );
        assert!(validate(&doc)
            .iter()
            .any(|i| i.rule.contains("duplicate sort field")));
    }

    #[test]
    fn filter_grammar_is_closed_and_bounded_wherever_it_appears() {
        let bad = FilterExpr {
            op: "regex".into(),
            field: Some("level".into()),
            value: Some(serde_json::json!("x")),
            args: vec![],
        };
        // component state
        let doc = doc_with_state(
            ComponentState {
                filter: Some(bad.clone()),
                ..Default::default()
            },
            table_interactions(),
        );
        assert!(validate(&doc)
            .iter()
            .any(|i| i.rule.contains("unknown filter operator")));
        // global filters
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.global_filters = vec![bad];
        assert!(validate(&doc)
            .iter()
            .any(|i| i.pointer.starts_with("/workspace/globalFilters")));
    }

    #[test]
    fn filter_depth_and_node_ceilings_are_enforced() {
        let mut f = FilterExpr {
            op: "eq".into(),
            field: Some("level".into()),
            value: Some(serde_json::json!("ERROR")),
            args: vec![],
        };
        for _ in 0..MAX_FILTER_DEPTH + 2 {
            f = FilterExpr {
                op: "not".into(),
                field: None,
                value: None,
                args: vec![f],
            };
        }
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.global_filters = vec![f];
        assert!(validate(&doc).iter().any(|i| i.rule.contains("nesting")));

        let leaf = FilterExpr {
            op: "eq".into(),
            field: Some("level".into()),
            value: Some(serde_json::json!("ERROR")),
            args: vec![],
        };
        let wide = FilterExpr {
            op: "or".into(),
            field: None,
            value: None,
            args: vec![leaf; MAX_FILTER_NODES + 5],
        };
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.global_filters = vec![wide];
        let issues = validate(&doc);
        assert_eq!(
            issues.iter().filter(|i| i.rule.contains("nodes")).count(),
            1,
            "one issue for the tree, not one per node"
        );
    }

    #[test]
    fn leaf_and_connective_shapes_are_checked() {
        let cases = [
            (
                FilterExpr {
                    op: "and".into(),
                    field: None,
                    value: None,
                    args: vec![],
                },
                "at least one",
            ),
            (
                FilterExpr {
                    op: "not".into(),
                    field: None,
                    value: None,
                    args: vec![],
                },
                "exactly one",
            ),
            (
                FilterExpr {
                    op: "eq".into(),
                    field: None,
                    value: Some(serde_json::json!(1)),
                    args: vec![],
                },
                "requires a field",
            ),
            (
                FilterExpr {
                    op: "eq".into(),
                    field: Some("x".into()),
                    value: None,
                    args: vec![],
                },
                "requires a value",
            ),
            (
                FilterExpr {
                    op: "in".into(),
                    field: Some("x".into()),
                    value: Some(serde_json::json!(3)),
                    args: vec![],
                },
                "array",
            ),
        ];
        for (f, want) in cases {
            let mut doc = crate::tests::minimal_doc();
            doc.workspace.global_filters = vec![f];
            let issues = validate(&doc);
            assert!(
                issues.iter().any(|i| i.rule.contains(want)),
                "{want}: {issues:?}"
            );
        }
    }

    #[test]
    fn is_null_needs_no_value() {
        let mut doc = crate::tests::minimal_doc();
        doc.workspace.global_filters = vec![FilterExpr {
            op: "is_null".into(),
            field: Some("level".into()),
            value: None,
            args: vec![],
        }];
        assert!(validate(&doc).is_empty());
    }
}
