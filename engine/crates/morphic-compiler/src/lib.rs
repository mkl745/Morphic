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
    Aggregation, Binding, ComponentSpec, DataSourceRef, Explanation, Generator, Interactions,
    Layout, Workspace, WorkspaceDoc, SCHEMA_VERSION,
};

/// Version stamped into `workspace.generator.version`. Bump when rules change so saved
/// workspaces record which planner produced them.
pub const GENERATOR_VERSION: &str = "0.2.0";

/// Upper bound on categories shown in a breakdown; keeps the chart legible and bounded.
pub const MAX_BAR_CATEGORIES: u32 = 12;

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
            .then(
                b.inference
                    .confidence
                    .total_cmp(&a.inference.confidence),
            )
            .then(a.name.cmp(&b.name))
    });
    candidates.into_iter().next()
}

/// Prefer a normalized `Timestamp` (a measured fact) over a string-shape inference.
fn temporal_field(profile: &DatasetProfile) -> Option<&FieldProfile> {
    let mut candidates: Vec<&FieldProfile> = profile
        .fields
        .iter()
        .filter(|f| f.dtype == DataType::Timestamp || f.inference.role == FieldRole::Temporal)
        .collect();
    candidates.sort_by(|a, b| {
        (b.dtype == DataType::Timestamp)
            .cmp(&(a.dtype == DataType::Timestamp))
            .then(
                b.inference
                    .confidence
                    .total_cmp(&a.inference.confidence),
            )
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
                && f.distinct_count <= MAX_BAR_CATEGORIES as usize
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

fn explanation(reason: &str, detail: String, evidence: Vec<String>, confidence: f64) -> Explanation {
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
        interactions: Interactions::default(),
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
            interactions: Interactions::default(),
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
                    group_by: None,
                },
                interactions: Interactions {
                    filter: true,
                    select: true,
                    ..Default::default()
                },
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
            None => components.push(ComponentSpec {
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
                    ..Default::default()
                },
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
            interactions: Interactions {
                filter: true,
                select: true,
                ..Default::default()
            },
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
            columns: vec![],
            page_size: 256,
        },
        interactions: Interactions {
            search: true,
            sort: true,
            filter: true,
            select: true,
        },
        explanation: Some(explanation(
            "R6_raw_table",
            "A searchable, sortable table keeps every record reachable.".into(),
            vec![format!("{} fields", profile.field_count)],
            1.0,
        )),
    });

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
        assert_eq!(ids(&doc), vec!["metric_card", "metric_card", "line_chart", "data_table"]);
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
    fn dimension_without_measure_counts_records() {
        let p = profile(vec![field("region", DataType::Utf8, FieldRole::Dimension, 3)]);
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
            let e = c.explanation.as_ref().expect("every component is explained");
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
        assert_eq!(first, second, "same profile must give byte-identical output");
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
            field("zzz_real_time", DataType::Timestamp, FieldRole::Temporal, 100),
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
        let p = profile(vec![field("id", DataType::Utf8, FieldRole::Dimension, 5000)]);
        let doc = build(&p);
        assert!(!ids(&doc).contains(&"bar_chart"));
    }

    #[test]
    fn single_value_dimension_is_not_charted() {
        let p = profile(vec![field("constant", DataType::Utf8, FieldRole::Dimension, 1)]);
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
                c.id.chars().all(|ch| ch.is_ascii_alphanumeric() || ch == '_'),
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
        let comp_ids: Vec<&str> = doc.workspace.components.iter().map(|c| c.id.as_str()).collect();
        let order: Vec<&str> = doc.workspace.layout.order.iter().map(|s| s.as_str()).collect();
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
        assert!(doc.workspace.components.iter().any(|c| c.id == "metric_row_id"));
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
