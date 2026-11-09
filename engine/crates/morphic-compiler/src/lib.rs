//! # morphic-compiler
//!
//! Transforms a semantic profile + user intent into a validated `WorkspaceDoc`
//! (docs/architecture/05 §5). This is where the interface *emerges from the data*.
//!
//! **M1.1 (task 1.1.3):** an explicit, ordered [`RULE_TABLE`] replaces the Phase 0 ad-hoc
//! branches. Every emitted component carries an [`Explanation`] naming the rule that fired
//! and the evidence behind it, so the generated interface is always auditable. Selection is
//! fully deterministic: the same profile always produces byte-identical output, which is
//! what makes the golden tests meaningful.
//!
//! The `IntelligenceProvider` seam for Phase 2 AI is declared here; the deterministic
//! planner remains the permanent offline fallback.

use morphic_model::{DataType, DatasetProfile, FieldProfile, FieldRole};
use morphic_schema::{
    Aggregation, Binding, ComponentSpec, DataSourceRef, Explanation, FilterExpr, Generator,
    Interactions, Layout, Workspace, WorkspaceDoc, SCHEMA_VERSION,
};
use serde_json::Value;

/// Version stamped into `workspace.generator.version`. Bump when rules change so saved
/// workspaces record which planner produced them.
pub const GENERATOR_VERSION: &str = "0.2.0";

/// Upper bound on categories shown in a breakdown; keeps the chart legible and bounded.
pub const MAX_BAR_CATEGORIES: u32 = 12;

/// Phone-first ceiling (docs/architecture/05 §5 rule 6). A generated workspace must fit a phone
/// screen's attention, not just its scroll view.
pub const MAX_COMPONENTS: usize = 6;

/// Table projection ceiling (docs/architecture/05 §5 rule 4). The rest stays reachable by
/// horizontal scroll and in row detail; the binding names the columns worth showing first.
pub const MAX_TABLE_COLUMNS: usize = 8;

/// Cardinality above which a column is not a breakdown at all. Mirrors the ceiling
/// `morphic-semantic` uses to call a column a Dimension in the first place.
///
/// This is deliberately NOT `MAX_BAR_CATEGORIES`. The bar renderer keeps the top N and folds
/// the rest into an "Other" bucket, so a 20-value dimension is chartable — showing 12 bars and
/// one Other is the whole point of that bucket. Capping selection at 12 made Other unreachable
/// from every generated workspace, however well the painter implemented it.
pub const MAX_DIMENSION_CARDINALITY: usize = 50;

/// Row count at which "every value is unique" starts to mean "this is a key".
///
/// Below it, uniqueness is an artefact of the sample: two rows have two distinct cities and
/// that says nothing. Matches the floor `morphic-semantic` uses for its identifier heuristic.
const KEY_LIKE_MIN_ROWS: usize = 5;

/// Levels that mean "something went wrong", for the error metric AT-12 requires whenever a
/// severity field exists. Matching is exact on the lower-cased value, never a substring: a level
/// literally named `error_handler` is not an error count.
const ERROR_LEVELS: &[&str] = &[
    "error", "err", "fatal", "critical", "crit", "alert", "emerg", "panic",
];

/// True when a severity value should be counted as an error.
fn is_error_level(value: &str) -> bool {
    ERROR_LEVELS.contains(&value.trim().to_ascii_lowercase().as_str())
}

/// User intent. M1.1 only supports `explore`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intent {
    Explore,
}

/// The seam through which Phase 2 AI providers will offer suggestions.
pub trait IntelligenceProvider {
    fn name(&self) -> &str;
}

/// The deterministic provider (rule-based, explainable, offline).
pub struct DeterministicProvider;

impl IntelligenceProvider for DeterministicProvider {
    fn name(&self) -> &str {
        "deterministic"
    }
}

/// One planner rule. `id` is written into the component's explanation so a user can always
/// ask "why is this here?" and get a stable answer.
#[derive(Debug, Clone, Copy)]
pub struct Rule {
    pub id: &'static str,
    pub when: &'static str,
    pub emits: &'static str,
}

/// The v0 rule table, in application order. Order is part of the contract: it determines
/// layout order and is asserted by the golden tests.
pub const RULE_TABLE: &[Rule] = &[
    Rule {
        id: "R1_records",
        when: "always",
        emits: "metric_card",
    },
    Rule {
        id: "R2_primary_measure",
        when: "a numeric measure field exists",
        emits: "metric_card",
    },
    Rule {
        id: "R2b_error_metric",
        when: "a severity field exists",
        emits: "metric_card",
    },
    Rule {
        id: "R3_time_series",
        when: "a temporal field AND a numeric measure exist",
        emits: "line_chart",
    },
    Rule {
        id: "R4_event_timeline",
        when: "a temporal field exists but no numeric measure does",
        emits: "timeline",
    },
    Rule {
        id: "R5_category_breakdown",
        when: "a low-cardinality dimension exists",
        emits: "bar_chart",
    },
    Rule {
        id: "R6_raw_table",
        when: "always",
        emits: "data_table",
    },
];

/// Applies the phone cap, keeping the table.
///
/// A free function rather than an inline branch so it can be tested with more components than the
/// current rules can emit. Today R1–R6 produce at most six, which would leave an inline
/// truncation permanently unexercised — and an untested branch is not a guarantee.
fn cap_components(mut components: Vec<ComponentSpec>) -> Vec<ComponentSpec> {
    if components.len() <= MAX_COMPONENTS {
        return components;
    }
    // R6 pushes the table last, and AT-12 requires it in every workspace, so the cap yields to
    // that invariant rather than the other way round.
    let table = components.pop().expect("R6 always pushes a table last");
    components.truncate(MAX_COMPONENTS - 1);
    components.push(table);
    components
}

/// The columns a phone table should show first (docs/architecture/05 §5 rule 4).
///
/// Ordered by how much a column tells you at a glance: when it happened, how bad it was, what
/// quantity, which category, then the prose payload. Identifiers sort last — an order number is
/// rarely what someone scans a table for — and unrecognised fields after that.
///
/// Ties break by name, like every other selector here. Source order looks like the natural
/// tie-break and is not one: JSON object keys and logfmt keys have no stable order, and the
/// planner promises that reordering the columns of a file does not change the interface.
///
/// Nothing is lost: the binding names a projection, and every field remains in row detail.
fn informative_columns(profile: &DatasetProfile) -> Vec<String> {
    fn rank(role: FieldRole) -> u8 {
        match role {
            FieldRole::Temporal => 0,
            FieldRole::Severity => 1,
            FieldRole::Measure => 2,
            FieldRole::Dimension => 3,
            FieldRole::Text => 4,
            FieldRole::Identifier => 5,
            FieldRole::Unknown => 6,
        }
    }
    let mut ranked: Vec<(u8, &str)> = profile
        .fields
        .iter()
        .map(|f| (rank(f.inference.role), f.name.as_str()))
        .collect();
    ranked.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(b.1)));
    ranked
        .into_iter()
        .take(MAX_TABLE_COLUMNS)
        .map(|(_, name)| name.to_string())
        .collect()
}

/// Component ids must be safe to use as keys/routes regardless of the source column name.
fn safe_id(s: &str) -> String {
    let out: String = s
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if out.is_empty() {
        "field".to_string()
    } else {
        out
    }
}

/// Highest-confidence numeric measure; ties broken by name so output is deterministic.
fn primary_measure(profile: &DatasetProfile) -> Option<&FieldProfile> {
    let mut candidates: Vec<&FieldProfile> = profile
        .fields
        .iter()
        .filter(|f| f.inference.role == FieldRole::Measure && f.dtype.is_numeric())
        .collect();
    // A perfectly unique integer is an identifier, not a measure. This matters in small
    // files where morphic-semantic's >=5-row identifier heuristic cannot fire, so a row id
    // would otherwise be averaged into a headline metric. Deprioritized, not dropped: if
    // every measure looks like an id we still show one.
    let id_like =
        |f: &FieldProfile| f.dtype == DataType::Int64 && f.distinct_count == profile.row_count;
    candidates.sort_by(|a, b| {
        id_like(a)
            .cmp(&id_like(b))
            .then(b.inference.confidence.total_cmp(&a.inference.confidence))
            .then(a.name.cmp(&b.name))
    });
    candidates.into_iter().next()
}

/// The best time axis the query layer can actually bucket.
///
/// A `Temporal` *role* is not enough. CLF and RFC3164 timestamps stay `utf8` (month names, no
/// year), and an unresolved day/month order stays `utf8` on purpose — guessing it would invent
/// data. `series_scene` refuses a text x and `timeline_scene` refuses a non-timestamp time
/// field, so proposing one produced a component that validated and then failed at the first
/// draw. Found by rendering every generated chart against its own fixture in the AT-12 scorer.
///
/// The cost is stated, not hidden: those files get no time view. Making them chartable means
/// teaching ingest to parse those formats, not loosening this check.
fn temporal_field(profile: &DatasetProfile) -> Option<&FieldProfile> {
    let mut candidates: Vec<&FieldProfile> = profile
        .fields
        .iter()
        .filter(|f| {
            f.dtype == DataType::Timestamp
                || (f.inference.role == FieldRole::Temporal && f.dtype.is_numeric())
        })
        .collect();
    candidates.sort_by(|a, b| {
        (b.dtype == DataType::Timestamp)
            .cmp(&(a.dtype == DataType::Timestamp))
            .then(b.inference.confidence.total_cmp(&a.inference.confidence))
            .then(a.name.cmp(&b.name))
    });
    candidates.into_iter().next()
}

/// A dimension with enough variety to be interesting but few enough values to chart.
fn best_dimension(profile: &DatasetProfile) -> Option<&FieldProfile> {
    let mut candidates: Vec<&FieldProfile> = profile
        .fields
        .iter()
        .filter(|f| {
            f.inference.role == FieldRole::Dimension
                && f.distinct_count >= 2
                && f.distinct_count <= MAX_DIMENSION_CARDINALITY
                // Every value unique is a key, not a category — but only once the sample is
                // big enough for that to mean anything.
                && !(profile.row_count >= KEY_LIKE_MIN_ROWS
                    && f.distinct_count == profile.row_count)
        })
        .collect();
    candidates.sort_by(|a, b| {
        b.inference
            .confidence
            .total_cmp(&a.inference.confidence)
            .then(a.distinct_count.cmp(&b.distinct_count))
            .then(a.name.cmp(&b.name))
    });
    candidates.into_iter().next()
}

/// Average rather than sum: a mean is meaningful for both totals and rates, whereas summing
/// a rate or a temperature is nonsense. The choice is stated in the explanation.
fn average_of(field: &str) -> Aggregation {
    Aggregation {
        op: "avg".into(),
        field: Some(field.into()),
        filter: None,
    }
}

fn count_all() -> Aggregation {
    Aggregation {
        op: "count".into(),
        field: None,
        filter: None,
    }
}

fn explanation(
    reason: &str,
    detail: String,
    evidence: Vec<String>,
    confidence: f64,
) -> Explanation {
    Explanation {
        reason: reason.into(),
        detail,
        evidence,
        confidence,
    }
}

/// Compile a profile into an initial workspace document by applying [`RULE_TABLE`].
pub fn compile(
    profile: &DatasetProfile,
    dataset_id: &str,
    workspace_id: &str,
    title: &str,
    now_iso: &str,
) -> WorkspaceDoc {
    let mut components: Vec<ComponentSpec> = Vec::new();
    let measure = primary_measure(profile);
    let temporal = temporal_field(profile);
    let dimension = best_dimension(profile);
    let severity = profile
        .fields
        .iter()
        .find(|f| f.inference.role == FieldRole::Severity);

    // R1 — always: a record count is the fastest orientation signal.
    components.push(ComponentSpec {
        id: "total_records".into(),
        component_type: "metric_card".into(),
        type_version: "1.0".into(),
        title: Some("Records".into()),
        data_source: "data".into(),
        binding: Binding::MetricCard {
            aggregation: count_all(),
        },
        // A metric card is filterable (docs/architecture/03 §2.1, AT-06's tap-to-filter).
        // It has no ordering and no text search, so those stay off.
        interactions: Interactions {
            filter: true,
            ..Default::default()
        },
        state: Default::default(),
        explanation: Some(explanation(
            "R1_records",
            "A record count is the fastest orientation signal for any dataset.".into(),
            vec![format!("{} rows detected", profile.row_count)],
            1.0,
        )),
    });

    // R2 — a numeric measure earns a headline metric.
    if let Some(m) = measure {
        components.push(ComponentSpec {
            id: format!("metric_{}", safe_id(&m.name)),
            component_type: "metric_card".into(),
            type_version: "1.0".into(),
            title: Some(format!("Avg {}", m.name)),
            data_source: "data".into(),
            binding: Binding::MetricCard {
                aggregation: average_of(&m.name),
            },
            interactions: Interactions {
                filter: true,
                ..Default::default()
            },
            state: Default::default(),
            explanation: Some(explanation(
                "R2_primary_measure",
                format!(
                    "'{}' is the strongest numeric measure, so its average is surfaced. \
                     An average is used rather than a sum because it stays meaningful for \
                     rates as well as totals.",
                    m.name
                ),
                m.inference.evidence.clone(),
                m.inference.confidence,
            )),
        });
    }

    // R2b — a severity field always earns an error count (AT-12). The restriction lives in the
    // aggregation's own filter, not in component state: state is what the *user* set and can be
    // cleared, which would silently turn an "Errors" card into a second "Records" card.
    if let Some(sev) = severity {
        // Exact values as they appear in the data, because `in` is case-sensitive and logs write
        // ERROR, error and Error interchangeably. The profiler keeps the top 20 values, which
        // covers every level a severity field realistically has.
        let mut levels: Vec<Value> = sev
            .top_values
            .iter()
            .filter(|vc| is_error_level(&vc.value))
            .map(|vc| Value::String(vc.value.clone()))
            .collect();
        if levels.is_empty() {
            // No error-shaped level was observed. The card still ships and reads zero, which is
            // the honest answer; AT-12 asks for the metric whenever severity exists, not only
            // when something has already gone wrong.
            levels.push(Value::String("error".into()));
        }
        let observed = levels.len();
        components.push(ComponentSpec {
            id: "error_records".into(),
            component_type: "metric_card".into(),
            type_version: "1.0".into(),
            title: Some("Errors".into()),
            data_source: "data".into(),
            binding: Binding::MetricCard {
                aggregation: Aggregation {
                    op: "count".into(),
                    field: None,
                    filter: Some(FilterExpr {
                        op: "in".into(),
                        field: Some(sev.name.clone()),
                        value: Some(Value::Array(levels)),
                        args: vec![],
                    }),
                },
            },
            interactions: Interactions {
                filter: true,
                ..Default::default()
            },
            state: Default::default(),
            explanation: Some(explanation(
                "R2b_error_metric",
                format!(
                    "'{}' carries severity levels, so the count of error-level records is a \
                     headline number.",
                    sev.name
                ),
                vec![format!("{observed} error-shaped level(s) observed")],
                sev.inference.confidence,
            )),
        });
    }

    // R3 / R4 — time is shown as a trend when there is something to measure, otherwise as
    // an event timeline. Never both: that would duplicate the same axis.
    if let Some(t) = temporal {
        match measure {
            Some(m) => components.push(ComponentSpec {
                id: "trend_over_time".into(),
                component_type: "line_chart".into(),
                type_version: "1.0".into(),
                title: Some(format!("{} over time", m.name)),
                data_source: "data".into(),
                binding: Binding::LineChart {
                    x: t.name.clone(),
                    y: vec![average_of(&m.name)],
                    // Split by severity when the data has it (docs/architecture/05 §5 rule 2).
                    // Without this the renderer's multi-series legend was unreachable from any
                    // generated document, however well the painter handled eight series.
                    group_by: severity.map(|f| f.name.clone()),
                },
                interactions: Interactions {
                    filter: true,
                    select: true,
                    ..Default::default()
                },
                state: Default::default(),
                explanation: Some(explanation(
                    "R3_time_series",
                    format!(
                        "'{}' is temporal and '{}' is a measure, so the measure is plotted \
                         over time.",
                        t.name, m.name
                    ),
                    t.inference
                        .evidence
                        .iter()
                        .chain(m.inference.evidence.iter())
                        .cloned()
                        .collect(),
                    t.inference.confidence.min(m.inference.confidence),
                )),
            }),
            // `timeline_scene` buckets epoch milliseconds and nothing else. A numeric temporal
            // column can carry a line but not event density, so it does not reach this branch.
            None if t.dtype == DataType::Timestamp => components.push(ComponentSpec {
                id: "event_timeline".into(),
                component_type: "timeline".into(),
                type_version: "1.0".into(),
                title: Some("Timeline".into()),
                data_source: "data".into(),
                binding: Binding::Timeline {
                    time_field: t.name.clone(),
                    group_by: None,
                    severity_field: profile
                        .fields
                        .iter()
                        .find(|f| f.inference.role == FieldRole::Severity)
                        .map(|f| f.name.clone()),
                },
                interactions: Interactions {
                    filter: true,
                    // The renderer offers a lane legend whose chips hide and show a severity.
                    // Without `select` those chips render disabled, so a documented interaction
                    // (docs/architecture/04 §2: "lane toggle") is unreachable in a generated
                    // workspace even though the painter implements it. Found by a tester tapping
                    // the chips on a device and getting no response.
                    select: true,
                    ..Default::default()
                },
                state: Default::default(),
                explanation: Some(explanation(
                    "R4_event_timeline",
                    format!(
                        "'{}' is temporal but no numeric measure was found, so records are \
                         laid out as events over time.",
                        t.name
                    ),
                    t.inference.evidence.clone(),
                    t.inference.confidence,
                )),
            }),
            None => {}
        }
    }

    // R5 — a low-cardinality dimension earns a breakdown.
    if let Some(d) = dimension {
        let limit = (d.distinct_count as u32).clamp(1, MAX_BAR_CATEGORIES);
        let (agg, what) = match measure {
            Some(m) => (average_of(&m.name), format!("average {}", m.name)),
            None => (count_all(), "record count".to_string()),
        };
        components.push(ComponentSpec {
            id: format!("breakdown_by_{}", safe_id(&d.name)),
            component_type: "bar_chart".into(),
            type_version: "1.0".into(),
            title: Some(format!("{} by {}", what, d.name)),
            data_source: "data".into(),
            binding: Binding::BarChart {
                dimension: d.name.clone(),
                measure: agg,
                limit,
            },
            // `sort` is part of the bar chart's contract (04-component-registry §2): the
            // renderer's toggle persists a SetComponentSort, and pass 5 rejects state that
            // exceeds the declared interactions — without this the toggle would be refused.
            interactions: Interactions {
                filter: true,
                sort: true,
                select: true,
                ..Default::default()
            },
            state: Default::default(),
            explanation: Some(explanation(
                "R5_category_breakdown",
                format!(
                    "'{}' has {} distinct values, few enough to compare as categories.",
                    d.name, d.distinct_count
                ),
                d.inference.evidence.clone(),
                d.inference.confidence,
            )),
        });
    }

    // R6 — always: every record stays reachable.
    components.push(ComponentSpec {
        id: "data_table".into(),
        component_type: "data_table".into(),
        type_version: "1.0".into(),
        title: Some("Data".into()),
        data_source: "data".into(),
        binding: Binding::DataTable {
            columns: informative_columns(profile),
            page_size: 256,
        },
        interactions: Interactions {
            search: true,
            sort: true,
            filter: true,
            select: true,
        },
        state: Default::default(),
        explanation: Some(explanation(
            "R6_raw_table",
            "A searchable, sortable table keeps every record reachable.".into(),
            vec![format!("{} fields", profile.field_count)],
            1.0,
        )),
    });

    // Rule 6: cap for a phone. The table is dropped from the truncation, never from the
    // workspace — AT-12 requires every workspace to keep every record reachable, so the cap
    // yields to that invariant rather than the other way round.
    let components = cap_components(components);

    let order: Vec<String> = components.iter().map(|c| c.id.clone()).collect();

    WorkspaceDoc {
        schema_version: SCHEMA_VERSION.into(),
        workspace: Workspace {
            id: workspace_id.into(),
            title: title.into(),
            created_at: now_iso.into(),
            modified_at: now_iso.into(),
            revision: 1,
            generator: Generator {
                kind: DeterministicProvider.name().into(),
                version: GENERATOR_VERSION.into(),
            },
            data_sources: vec![DataSourceRef {
                alias: "data".into(),
                dataset_id: dataset_id.into(),
            }],
            layout: Layout {
                mode: "adaptive".into(),
                order,
                hints: vec![],
            },
            global_filters: vec![],
            components,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{FieldProfile, Inference};

    fn field(name: &str, dtype: DataType, role: FieldRole, distinct: usize) -> FieldProfile {
        FieldProfile {
            name: name.into(),
            dtype,
            null_count: 0,
            distinct_count: distinct,
            min: None,
            max: None,
            top_values: vec![],
            stats: None,
            inference: Inference {
                role,
                confidence: 0.9,
                evidence: vec![format!("{name} evidence")],
            },
        }
    }

    fn profile(fields: Vec<FieldProfile>) -> DatasetProfile {
        DatasetProfile {
            row_count: 100,
            field_count: fields.len(),
            fields,
        }
    }

    fn build(p: &DatasetProfile) -> WorkspaceDoc {
        compile(p, "d1", "w1", "Test", "2026-11-05T00:00:00Z")
    }

    fn ids(doc: &WorkspaceDoc) -> Vec<&str> {
        doc.workspace
            .components
            .iter()
            .map(|c| c.component_type.as_str())
            .collect()
    }

    #[test]
    fn temporal_plus_measure_yields_line_chart_not_timeline() {
        let p = profile(vec![
            field("when", DataType::Timestamp, FieldRole::Temporal, 100),
            field("value", DataType::Float64, FieldRole::Measure, 80),
        ]);
        let doc = build(&p);
        assert_eq!(
            ids(&doc),
            vec!["metric_card", "metric_card", "line_chart", "data_table"]
        );
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn temporal_without_measure_yields_timeline() {
        let p = profile(vec![
            field("when", DataType::Timestamp, FieldRole::Temporal, 100),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
        ]);
        let doc = build(&p);
        assert!(ids(&doc).contains(&"timeline"));
        assert!(!ids(&doc).contains(&"line_chart"));
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn dimension_plus_measure_yields_bar_chart() {
        let p = profile(vec![
            field("region", DataType::Utf8, FieldRole::Dimension, 4),
            field("sales", DataType::Float64, FieldRole::Measure, 90),
        ]);
        let doc = build(&p);
        assert!(ids(&doc).contains(&"bar_chart"));
        let bar = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "bar_chart")
            .unwrap();
        match &bar.binding {
            Binding::BarChart { limit, measure, .. } => {
                assert_eq!(*limit, 4);
                assert_eq!(measure.op, "avg");
            }
            other => panic!("wrong binding: {other:?}"),
        }
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn severity_always_earns_an_error_metric() {
        // AT-12: "severity data always gets an error metric".
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
        ]);
        let doc = build(&p);
        let errors = doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == "error_records")
            .expect("a severity field must produce an error metric");
        assert_eq!(errors.component_type, "metric_card");
        assert_eq!(errors.title.as_deref(), Some("Errors"));
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn the_error_restriction_lives_in_the_binding_not_user_state() {
        // If it lived in `state.filter`, clearing filters would silently turn "Errors" into a
        // second "Records" card.
        let p = profile(vec![field("level", DataType::Utf8, FieldRole::Severity, 3)]);
        let doc = build(&p);
        let errors = doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == "error_records")
            .unwrap();
        assert!(errors.state.filter.is_none());
        match &errors.binding {
            Binding::MetricCard { aggregation } => {
                assert_eq!(aggregation.op, "count");
                let f = aggregation
                    .filter
                    .as_ref()
                    .expect("restricted in the binding");
                assert_eq!(f.op, "in");
                assert_eq!(f.field.as_deref(), Some("level"));
            }
            other => panic!("expected a metric binding, got {other:?}"),
        }
    }

    #[test]
    fn a_severity_field_without_errors_still_gets_the_metric() {
        // Zero is the honest answer, and AT-12 asks for the card whenever severity exists.
        let p = profile(vec![field("level", DataType::Utf8, FieldRole::Severity, 2)]);
        let doc = build(&p);
        assert!(doc
            .workspace
            .components
            .iter()
            .any(|c| c.id == "error_records"));
    }

    #[test]
    fn error_levels_are_matched_exactly_not_by_substring() {
        assert!(is_error_level("ERROR"));
        assert!(is_error_level(" Fatal "));
        assert!(is_error_level("crit"));
        assert!(!is_error_level("error_handler"));
        assert!(!is_error_level("warning"));
        assert!(!is_error_level("info"));
    }

    #[test]
    fn temporal_data_always_gets_a_time_based_view() {
        // AT-12, both branches: with a measure it is a trend, without one it is event density.
        for with_measure in [true, false] {
            let mut fields = vec![field("ts", DataType::Timestamp, FieldRole::Temporal, 90)];
            if with_measure {
                fields.push(field("latency", DataType::Float64, FieldRole::Measure, 40));
            }
            let doc = build(&profile(fields));
            let kinds = ids(&doc);
            assert!(
                kinds.contains(&"line_chart") || kinds.contains(&"timeline"),
                "temporal data must get a time view (measure={with_measure}): {kinds:?}"
            );
        }
    }

    #[test]
    fn a_line_chart_splits_by_severity_when_the_data_has_it() {
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("latency", DataType::Float64, FieldRole::Measure, 40),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
        ]);
        let doc = build(&p);
        let line = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "line_chart")
            .unwrap();
        match &line.binding {
            Binding::LineChart { group_by, .. } => {
                assert_eq!(group_by.as_deref(), Some("level"));
            }
            other => panic!("expected a line binding, got {other:?}"),
        }
    }

    #[test]
    fn a_line_chart_has_no_split_when_there_is_no_severity() {
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("latency", DataType::Float64, FieldRole::Measure, 40),
        ]);
        let doc = build(&p);
        let line = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "line_chart")
            .unwrap();
        match &line.binding {
            Binding::LineChart { group_by, .. } => assert!(group_by.is_none()),
            other => panic!("expected a line binding, got {other:?}"),
        }
    }

    #[test]
    fn the_cap_keeps_the_table_and_drops_from_the_middle() {
        let p = profile(vec![field("x", DataType::Utf8, FieldRole::Dimension, 3)]);
        let template = build(&p).workspace.components.remove(0);
        let mut many: Vec<ComponentSpec> = (0..9)
            .map(|i| {
                let mut c = template.clone();
                c.id = format!("c{i}");
                c
            })
            .collect();
        let mut table = template;
        table.id = "data_table".into();
        table.component_type = "data_table".into();
        many.push(table);

        let capped = cap_components(many);
        assert_eq!(capped.len(), MAX_COMPONENTS);
        assert_eq!(capped.last().unwrap().component_type, "data_table");
        assert_eq!(
            capped.first().unwrap().id,
            "c0",
            "priority order is preserved"
        );
    }

    #[test]
    fn a_cap_that_does_not_bind_leaves_the_plan_alone() {
        let p = profile(vec![field("x", DataType::Utf8, FieldRole::Dimension, 3)]);
        let components = build(&p).workspace.components;
        let n = components.len();
        assert_eq!(cap_components(components).len(), n);
    }

    #[test]
    fn every_generated_workspace_keeps_a_table_within_the_cap() {
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("latency", DataType::Float64, FieldRole::Measure, 40),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
            field("service", DataType::Utf8, FieldRole::Dimension, 6),
        ]);
        let doc = build(&p);
        let kinds = ids(&doc);
        assert!(kinds.contains(&"data_table"));
        assert!(doc.workspace.components.len() <= MAX_COMPONENTS);
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn the_table_projection_is_ranked_and_capped() {
        let p = profile(vec![
            field("row_id", DataType::Int64, FieldRole::Identifier, 100),
            field("note", DataType::Utf8, FieldRole::Text, 100),
            field("region", DataType::Utf8, FieldRole::Dimension, 4),
            field("amount", DataType::Float64, FieldRole::Measure, 90),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
        ]);
        let cols = informative_columns(&p);
        assert_eq!(cols, ["ts", "level", "amount", "region", "note", "row_id"]);

        let wide: Vec<FieldProfile> = (0..20)
            .map(|i| field(&format!("c{i}"), DataType::Utf8, FieldRole::Dimension, 4))
            .collect();
        assert_eq!(informative_columns(&profile(wide)).len(), MAX_TABLE_COLUMNS);
    }

    #[test]
    fn the_plan_is_composed_for_a_phone() {
        // Phone-aware composition is the part the renderer actually honours today:
        // at most six components, metric cards consecutive at the front so the adaptive
        // Wrap flows them into one row, the table last, and its projection capped.
        //
        // `layout.hints` stays empty on purpose. Nothing reads it, and doc 03 §1 defines it
        // as where *manual* adjustments persist (M1.5). Emitting spans no renderer consumes
        // would be one more feature that exists only in the document.
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("latency", DataType::Float64, FieldRole::Measure, 40),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
            field("service", DataType::Utf8, FieldRole::Dimension, 6),
            field("message", DataType::Utf8, FieldRole::Text, 90),
        ]);
        let doc = build(&p);
        let kinds: Vec<&str> = doc
            .workspace
            .components
            .iter()
            .map(|c| c.component_type.as_str())
            .collect();
        assert!(kinds.len() <= MAX_COMPONENTS);
        assert_eq!(
            kinds.last(),
            Some(&"data_table"),
            "the table anchors the page"
        );

        // Every metric card precedes every chart: a metric buried between two charts breaks
        // the renderer's consecutive-metric row and wastes a screen on a one-card row.
        let last_metric = kinds.iter().rposition(|k| *k == "metric_card").unwrap();
        let first_chart = kinds
            .iter()
            .position(|k| *k != "metric_card")
            .expect("a table at minimum");
        assert!(
            last_metric < first_chart,
            "metric cards must be consecutive at the front: {kinds:?}"
        );
        assert!(doc.workspace.layout.hints.is_empty());

        match &doc.workspace.components.last().unwrap().binding {
            Binding::DataTable { columns, page_size } => {
                assert!(columns.len() <= MAX_TABLE_COLUMNS);
                assert_eq!(*page_size, 256);
            }
            other => panic!("wrong binding: {other:?}"),
        }
    }

    #[test]
    fn a_text_time_axis_is_not_offered_as_a_chart() {
        // CLF and RFC3164 times stay utf8, and an unresolved day/month order stays utf8 on
        // purpose. `series_scene` and `timeline_scene` both refuse a text axis, so proposing one
        // produced a card that validated and then failed at the first draw. Caught by rendering
        // every generated chart against its own fixture, not by any selection assertion.
        for role_dtype in [DataType::Utf8, DataType::Bool] {
            let p = profile(vec![
                field("time", role_dtype, FieldRole::Temporal, 90),
                field("latency", DataType::Float64, FieldRole::Measure, 40),
            ]);
            let doc = build(&p);
            assert!(
                !ids(&doc).contains(&"line_chart"),
                "a {role_dtype:?} axis cannot be bucketed"
            );
            assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
        }
    }

    #[test]
    fn a_text_time_axis_without_a_measure_is_not_a_timeline() {
        let p = profile(vec![field("time", DataType::Utf8, FieldRole::Temporal, 90)]);
        let doc = build(&p);
        assert!(!ids(&doc).contains(&"timeline"));
        assert!(
            ids(&doc).contains(&"data_table"),
            "the records stay reachable"
        );
    }

    #[test]
    fn a_normalized_time_axis_still_charts() {
        // The guard above must not cost the cases that do work.
        let p = profile(vec![
            field("time", DataType::Timestamp, FieldRole::Temporal, 90),
            field("latency", DataType::Float64, FieldRole::Measure, 40),
        ]);
        assert!(ids(&build(&p)).contains(&"line_chart"));
    }

    #[test]
    fn a_dimension_wider_than_the_bar_limit_is_still_charted_via_other() {
        // The renderer keeps the top 12 and folds the rest into an "Other" bucket. Capping
        // *selection* at 12 made that bucket unreachable from every generated workspace.
        let p = profile(vec![
            field("service", DataType::Utf8, FieldRole::Dimension, 20),
            field("latency", DataType::Float64, FieldRole::Measure, 90),
        ]);
        let doc = build(&p);
        let bar = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "bar_chart")
            .expect("20 categories is chartable as top-12 plus Other");
        match &bar.binding {
            Binding::BarChart { limit, .. } => {
                assert_eq!(
                    *limit, MAX_BAR_CATEGORIES,
                    "the chart still shows at most 12"
                );
            }
            other => panic!("wrong binding: {other:?}"),
        }
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn an_all_unique_column_is_a_key_not_a_breakdown() {
        // 20 distinct values in 20 rows is an index, whatever the role says. Charting it would
        // draw twenty bars of one record each.
        let mut p = profile(vec![field(
            "name",
            DataType::Utf8,
            FieldRole::Dimension,
            20,
        )]);
        p.row_count = 20;
        assert!(!ids(&build(&p)).contains(&"bar_chart"));
    }

    #[test]
    fn uniqueness_in_a_tiny_sample_is_not_evidence_of_a_key() {
        // Two rows have two distinct cities. That is the sample size talking, not the data.
        let mut p = profile(vec![field("city", DataType::Utf8, FieldRole::Dimension, 2)]);
        p.row_count = 2;
        assert!(ids(&build(&p)).contains(&"bar_chart"));
    }

    #[test]
    fn the_table_projection_breaks_ties_by_name_not_source_order() {
        // Caught by `measure_ties_break_by_name_not_input_order` when the projection first
        // shipped: ranking kept the profile's own order inside a rank, so reversing the columns
        // of a file changed the generated table. JSON and logfmt keys have no stable order.
        let forward = profile(vec![
            field("zulu", DataType::Utf8, FieldRole::Dimension, 4),
            field("alpha", DataType::Utf8, FieldRole::Dimension, 4),
            field("middle", DataType::Utf8, FieldRole::Dimension, 4),
        ]);
        let mut reversed = forward.clone();
        reversed.fields.reverse();
        assert_eq!(
            informative_columns(&forward),
            ["alpha", "middle", "zulu"],
            "same rank, so the tie breaks by name"
        );
        assert_eq!(
            informative_columns(&forward),
            informative_columns(&reversed),
            "column order in the file must not change the generated table"
        );
    }

    #[test]
    fn a_timeline_allows_the_lane_toggle_its_renderer_offers() {
        let p = profile(vec![
            field("ts", DataType::Timestamp, FieldRole::Temporal, 90),
            field("level", DataType::Utf8, FieldRole::Severity, 4),
        ]);
        let doc = build(&p);
        let timeline = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "timeline")
            .expect("temporal without a measure yields a timeline");
        assert!(
            timeline.interactions.filter,
            "tap-bucket-to-range is part of the contract"
        );
        assert!(
            timeline.interactions.select,
            "the lane legend's chips are gated on select; without it the toggle is dead UI"
        );
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn a_bar_chart_allows_the_sort_its_renderer_offers() {
        let p = profile(vec![
            field("region", DataType::Utf8, FieldRole::Dimension, 4),
            field("sales", DataType::Float64, FieldRole::Measure, 90),
        ]);
        let mut doc = build(&p);
        let bar = doc
            .workspace
            .components
            .iter_mut()
            .find(|c| c.component_type == "bar_chart")
            .unwrap();
        assert!(
            bar.interactions.filter,
            "tap-to-filter is part of the contract"
        );
        assert!(
            bar.interactions.sort,
            "the renderer's sort toggle needs this"
        );
        // Pass 5 rejects state that exceeds the declared interactions, so the line above is
        // not cosmetic: without it, tapping the toggle is a rejected command and the feature
        // is unreachable in the app even though the painter works.
        bar.state.sort = vec![morphic_schema::SortRule {
            field: "region".into(),
            dir: morphic_schema::SortDir::Asc,
            nulls: morphic_schema::NullsOrder::Last,
        }];
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn dimension_without_measure_counts_records() {
        let p = profile(vec![field(
            "region",
            DataType::Utf8,
            FieldRole::Dimension,
            3,
        )]);
        let doc = build(&p);
        let bar = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "bar_chart")
            .unwrap();
        match &bar.binding {
            Binding::BarChart { measure, .. } => {
                assert_eq!(measure.op, "count");
                assert!(measure.field.is_none());
            }
            other => panic!("wrong binding: {other:?}"),
        }
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn empty_profile_still_produces_a_usable_workspace() {
        let p = profile(vec![]);
        let doc = build(&p);
        assert_eq!(ids(&doc), vec!["metric_card", "data_table"]);
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn every_component_explains_itself_with_a_known_rule() {
        let p = profile(vec![
            field("when", DataType::Timestamp, FieldRole::Temporal, 100),
            field("value", DataType::Float64, FieldRole::Measure, 80),
            field("region", DataType::Utf8, FieldRole::Dimension, 4),
        ]);
        let doc = build(&p);
        for c in &doc.workspace.components {
            let e = c
                .explanation
                .as_ref()
                .expect("every component is explained");
            assert!(
                RULE_TABLE.iter().any(|r| r.id == e.reason),
                "unknown rule id {}",
                e.reason
            );
            assert!(!e.detail.is_empty());
            assert!((0.0..=1.0).contains(&e.confidence));
        }
    }

    #[test]
    fn compilation_is_deterministic() {
        let p = profile(vec![
            field("b", DataType::Float64, FieldRole::Measure, 80),
            field("a", DataType::Float64, FieldRole::Measure, 80),
            field("when", DataType::Timestamp, FieldRole::Temporal, 100),
        ]);
        let first = serde_json::to_string(&build(&p)).unwrap();
        let second = serde_json::to_string(&build(&p)).unwrap();
        assert_eq!(
            first, second,
            "same profile must give byte-identical output"
        );
    }

    #[test]
    fn measure_ties_break_by_name_not_input_order() {
        let forward = profile(vec![
            field("alpha", DataType::Float64, FieldRole::Measure, 80),
            field("beta", DataType::Float64, FieldRole::Measure, 80),
        ]);
        let mut reversed = forward.clone();
        reversed.fields.reverse();
        assert_eq!(
            serde_json::to_string(&build(&forward)).unwrap(),
            serde_json::to_string(&build(&reversed)).unwrap(),
            "field order in the file must not change the generated interface"
        );
    }

    #[test]
    fn normalized_timestamp_beats_a_string_shape_inference() {
        let p = profile(vec![
            field("aaa_text_time", DataType::Utf8, FieldRole::Temporal, 100),
            field(
                "zzz_real_time",
                DataType::Timestamp,
                FieldRole::Temporal,
                100,
            ),
            field("value", DataType::Float64, FieldRole::Measure, 80),
        ]);
        let doc = build(&p);
        let line = doc
            .workspace
            .components
            .iter()
            .find(|c| c.component_type == "line_chart")
            .unwrap();
        match &line.binding {
            Binding::LineChart { x, .. } => assert_eq!(x, "zzz_real_time"),
            other => panic!("wrong binding: {other:?}"),
        }
    }

    #[test]
    fn high_cardinality_dimension_is_not_charted() {
        let p = profile(vec![field(
            "id",
            DataType::Utf8,
            FieldRole::Dimension,
            5000,
        )]);
        let doc = build(&p);
        assert!(!ids(&doc).contains(&"bar_chart"));
    }

    #[test]
    fn single_value_dimension_is_not_charted() {
        let p = profile(vec![field(
            "constant",
            DataType::Utf8,
            FieldRole::Dimension,
            1,
        )]);
        assert!(!ids(&build(&p)).contains(&"bar_chart"));
    }

    #[test]
    fn timestamps_are_never_averaged_into_a_metric() {
        let p = profile(vec![field(
            "when",
            DataType::Timestamp,
            FieldRole::Temporal,
            100,
        )]);
        let doc = build(&p);
        // Only the record count metric; averaging a timestamp would be meaningless.
        assert_eq!(ids(&doc).iter().filter(|t| **t == "metric_card").count(), 1);
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn unsafe_column_names_produce_safe_component_ids() {
        let p = profile(vec![field(
            "total sales (USD)/2024",
            DataType::Float64,
            FieldRole::Measure,
            80,
        )]);
        let doc = build(&p);
        for c in &doc.workspace.components {
            assert!(
                c.id.chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || ch == '_'),
                "unsafe id {}",
                c.id
            );
        }
        assert!(morphic_schema::validate_with_profile(&doc, &p).is_empty());
    }

    #[test]
    fn layout_order_matches_components_exactly() {
        let p = profile(vec![
            field("when", DataType::Timestamp, FieldRole::Temporal, 100),
            field("value", DataType::Float64, FieldRole::Measure, 80),
            field("region", DataType::Utf8, FieldRole::Dimension, 4),
        ]);
        let doc = build(&p);
        let comp_ids: Vec<&str> = doc
            .workspace
            .components
            .iter()
            .map(|c| c.id.as_str())
            .collect();
        let order: Vec<&str> = doc
            .workspace
            .layout
            .order
            .iter()
            .map(|s| s.as_str())
            .collect();
        assert_eq!(comp_ids, order);
    }

    #[test]
    fn generator_version_is_stamped() {
        let doc = build(&profile(vec![]));
        assert_eq!(doc.workspace.generator.version, GENERATOR_VERSION);
        assert_eq!(doc.workspace.generator.kind, "deterministic");
    }

    #[test]
    fn perfectly_unique_integer_is_not_chosen_as_the_headline_measure() {
        // 4 rows: morphic-semantic's >=5-row identifier heuristic cannot fire, so `row_id`
        // arrives labelled Measure. The compiler must still prefer the real measure.
        let p = DatasetProfile {
            row_count: 4,
            field_count: 2,
            fields: vec![
                field("row_id", DataType::Int64, FieldRole::Measure, 4),
                field("value", DataType::Float64, FieldRole::Measure, 4),
            ],
        };
        let doc = build(&p);
        let metric = doc
            .workspace
            .components
            .iter()
            .find(|c| c.id.starts_with("metric_"))
            .expect("a measure metric");
        assert_eq!(metric.id, "metric_value");
    }

    #[test]
    fn an_all_id_like_dataset_still_gets_a_measure_metric() {
        // Deprioritized, never dropped: something is still better than nothing.
        let p = DatasetProfile {
            row_count: 3,
            field_count: 1,
            fields: vec![field("row_id", DataType::Int64, FieldRole::Measure, 3)],
        };
        let doc = build(&p);
        assert!(doc
            .workspace
            .components
            .iter()
            .any(|c| c.id == "metric_row_id"));
    }

    #[test]
    fn rule_table_ids_are_unique() {
        let mut seen = std::collections::HashSet::new();
        for r in RULE_TABLE {
            assert!(seen.insert(r.id), "duplicate rule id {}", r.id);
            assert!(
                morphic_schema::ACTIVE_COMPONENTS.contains(&r.emits),
                "rule {} emits an inactive component {}",
                r.id,
                r.emits
            );
        }
    }
}
