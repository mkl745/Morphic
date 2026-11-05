//! # morphic-compiler
//!
//! Transforms a semantic profile + user intent into a validated `WorkspaceDoc`
//! (docs/architecture/05 §5). This is where the interface *emerges from the data*.
//!
//! **Phase 0 status:** a minimal deterministic rule set produces a metric card + data
//! table (and a timeline when a temporal field exists), each with an explanation. The full
//! planner rule table, severity/temporal/dimension logic, and selection-accuracy scoring
//! land in M1.4. The `IntelligenceProvider` seam for Phase 2 AI is declared here.

use morphic_model::{DatasetProfile, FieldRole};
use morphic_schema::{
    Aggregation, Binding, ComponentSpec, DataSourceRef, Explanation, Generator, Interactions,
    Layout, Workspace, WorkspaceDoc, SCHEMA_VERSION,
};

/// User intent. Phase 0 only supports `explore`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Intent {
    Explore,
}

/// The seam through which Phase 2 AI providers will offer suggestions. In Phase 1 the
/// deterministic planner is the only implementation and the permanent offline fallback.
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

/// Compile a profile into an initial workspace document.
pub fn compile(
    profile: &DatasetProfile,
    dataset_id: &str,
    workspace_id: &str,
    title: &str,
    now_iso: &str,
) -> WorkspaceDoc {
    let mut components: Vec<ComponentSpec> = Vec::new();

    // Rule: always a total-records metric card.
    components.push(ComponentSpec {
        id: "total_records".into(),
        component_type: "metric_card".into(),
        type_version: "1.0".into(),
        title: Some("Records".into()),
        data_source: "data".into(),
        binding: Binding::MetricCard {
            aggregation: Aggregation {
                op: "count".into(),
                field: None,
                filter: None,
            },
        },
        interactions: Interactions::default(),
        explanation: Some(Explanation {
            reason: "dataset_overview".into(),
            detail: "A record count is the fastest orientation signal for any dataset.".into(),
            evidence: vec![format!("{} rows detected", profile.row_count)],
            confidence: 1.0,
        }),
    });

    // Rule: a temporal field yields a timeline.
    if let Some(temporal) = profile
        .fields
        .iter()
        .find(|f| f.inference.role == FieldRole::Temporal)
    {
        components.push(ComponentSpec {
            id: "event_timeline".into(),
            component_type: "timeline".into(),
            type_version: "1.0".into(),
            title: Some("Timeline".into()),
            data_source: "data".into(),
            binding: Binding::Timeline {
                time_field: temporal.name.clone(),
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
            explanation: Some(Explanation {
                reason: "temporal_field_detected".into(),
                detail: format!(
                    "Field '{}' was identified as temporal, so events are laid out over time.",
                    temporal.name
                ),
                evidence: temporal.inference.evidence.clone(),
                confidence: temporal.inference.confidence,
            }),
        });
    }

    // Rule: always a data table over the dataset.
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
        explanation: Some(Explanation {
            reason: "raw_explorer".into(),
            detail: "A searchable, sortable table keeps every record reachable.".into(),
            evidence: vec![format!("{} fields", profile.field_count)],
            confidence: 1.0,
        }),
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
                kind: "deterministic".into(),
                version: "0.1.0".into(),
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
    use morphic_model::{DataType, DatasetProfile, FieldProfile, FieldRole, Inference};

    fn profile_with_temporal() -> DatasetProfile {
        DatasetProfile {
            row_count: 10,
            field_count: 2,
            fields: vec![
                FieldProfile {
                    name: "time".into(),
                    dtype: DataType::Utf8,
                    null_count: 0,
                    distinct_count: 10,
                    min: None,
                    max: None,
                    top_values: vec![],
                    inference: Inference {
                        role: FieldRole::Temporal,
                        confidence: 0.9,
                        evidence: vec!["ISO-8601".into()],
                    },
                },
                FieldProfile {
                    name: "value".into(),
                    dtype: DataType::Float64,
                    null_count: 0,
                    distinct_count: 8,
                    min: None,
                    max: None,
                    top_values: vec![],
                    inference: Inference {
                        role: FieldRole::Measure,
                        confidence: 0.85,
                        evidence: vec![],
                    },
                },
            ],
        }
    }

    #[test]
    fn compile_produces_valid_doc() {
        let doc = compile(
            &profile_with_temporal(),
            "d1",
            "w1",
            "Test",
            "2026-11-05T00:00:00Z",
        );
        assert!(morphic_schema::validate(&doc).is_empty());
        // metric + timeline + table
        assert_eq!(doc.workspace.components.len(), 3);
    }

    #[test]
    fn compile_without_temporal_has_no_timeline() {
        let mut p = profile_with_temporal();
        p.fields[0].inference.role = FieldRole::Dimension;
        let doc = compile(&p, "d1", "w1", "Test", "2026-11-05T00:00:00Z");
        assert_eq!(doc.workspace.components.len(), 2);
        assert!(morphic_schema::validate(&doc).is_empty());
    }
}
