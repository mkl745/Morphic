//! Targeted recompilation after a user field correction (M1.5 task 1.5.5).
//!
//! A `fieldOverrides` record corrects **the semantic profile the planner sees**, not the bytes
//! the query layer ingested. The table keeps the column dtypes it parsed; the planner and the
//! binding validator use the corrected view. That is the honest boundary: a user saying "this
//! numeric-looking id is really text" changes which components make sense, without silently
//! re-parsing 100k rows or invalidating the page cache.
//!
//! Only components whose [`Binding::fields`] reads a corrected field are rebuilt. Everything
//! the user changed by hand — component state, type, title, layout order and hints — is left
//! byte-for-byte intact. Where the corrected profile still generates that component, its fresh
//! binding and explanation are copied from a real [`compile`] run. Where it no longer does, the
//! binding is repaired in place to a valid form (e.g. an average over a now-text field becomes a
//! row count) rather than dropping the component or inventing a new layout.
//!
//! This module never calls [`compile`] on the unmodified profile, so the compiler goldens and
//! the AT-12 planner scorer are untouched.

use morphic_model::{DataType, DatasetProfile, FieldRole};
use morphic_schema::{Aggregation, Binding, FieldOverride, WorkspaceDoc};

use crate::compile;

/// Closed vocabulary from `morphic_schema::DATA_TYPES`, mapped to the model's typed enum.
fn parse_dtype(name: &str) -> Option<DataType> {
    Some(match name {
        "null" => DataType::Null,
        "bool" => DataType::Bool,
        "int64" => DataType::Int64,
        "float64" => DataType::Float64,
        "utf8" => DataType::Utf8,
        "timestamp" => DataType::Timestamp,
        _ => return None,
    })
}

/// Closed vocabulary from `morphic_schema::FIELD_ROLES`.
fn parse_role(name: &str) -> Option<FieldRole> {
    Some(match name {
        "unknown" => FieldRole::Unknown,
        "temporal" => FieldRole::Temporal,
        "measure" => FieldRole::Measure,
        "dimension" => FieldRole::Dimension,
        "severity" => FieldRole::Severity,
        "identifier" => FieldRole::Identifier,
        "text" => FieldRole::Text,
        _ => return None,
    })
}

/// The profile the planner sees after user corrections. Overrides are additive and keyed by
/// field name; unknown names and unknown vocabulary are ignored here because schema pass 1 has
/// already rejected them before any command is committed.
///
/// A corrected role carries confidence 1.0 and a single piece of evidence naming the user's
/// choice, so freshly generated explanations do not claim the inference came from the data.
pub fn effective_profile(profile: &DatasetProfile, overrides: &[FieldOverride]) -> DatasetProfile {
    let mut out = profile.clone();
    for o in overrides {
        let Some(field) = out.fields.iter_mut().find(|f| f.name == o.field) else {
            continue;
        };
        if let Some(dtype) = o.dtype.as_deref().and_then(parse_dtype) {
            field.dtype = dtype;
        }
        if let Some(name) = o.role.as_deref() {
            if let Some(role) = parse_role(name) {
                field.inference.role = role;
                field.inference.confidence = 1.0;
                field.inference.evidence = vec![format!("user override: {name}")];
            }
        }
    }
    out
}

/// Result of one targeted recompile.
pub struct Recompiled {
    pub doc: WorkspaceDoc,
    /// Component ids whose binding actually changed, in document order.
    pub affected: Vec<String>,
    /// The corrected profile that produced the new bindings; the caller validates against it.
    pub effective: DatasetProfile,
}

/// Recompile only the components that read one of `fields`.
///
/// `fields` are the names whose override changed in this batch. Passing an empty list is a
/// no-op, so a batch with no corrections cannot perturb the document.
pub fn recompile_for_fields(
    doc: &WorkspaceDoc,
    profile: &DatasetProfile,
    fields: &[String],
) -> Recompiled {
    let effective = effective_profile(profile, &doc.workspace.field_overrides);
    if fields.is_empty() {
        return Recompiled {
            doc: doc.clone(),
            affected: Vec::new(),
            effective,
        };
    }
    let dataset_id = doc
        .workspace
        .data_sources
        .first()
        .map(|d| d.dataset_id.as_str())
        .unwrap_or("");
    let fresh = compile(
        &effective,
        dataset_id,
        &doc.workspace.id,
        &doc.workspace.title,
        &doc.workspace.created_at,
    );

    let mut next = doc.clone();
    let mut affected = Vec::new();
    for component in next.workspace.components.iter_mut() {
        let replacement = fresh
            .workspace
            .components
            .iter()
            .find(|f| f.id == component.id && f.component_type == component.component_type);
        // A previous correction may have removed the field from this binding (an average
        // became a row count). Clearing that correction has to find the component again, so
        // the freshly compiled binding is considered too, not just the current one.
        let fresh_reads = replacement.is_some_and(|f| reads_corrected(&f.binding, fields));
        if !reads_corrected(&component.binding, fields) && !fresh_reads {
            continue;
        }
        let before = serde_json::to_value(&component.binding).unwrap_or_default();
        match replacement {
            Some(fresh_component) => {
                component.binding = fresh_component.binding.clone();
                component.explanation = fresh_component.explanation.clone();
            }
            None => {
                component.binding = repair_binding(&component.binding, &effective);
                if let Some(explanation) = component.explanation.as_mut() {
                    explanation
                        .evidence
                        .push("recompiled after a user field correction".into());
                }
            }
        }
        let after = serde_json::to_value(&component.binding).unwrap_or_default();
        if after != before {
            affected.push(component.id.clone());
        }
    }
    Recompiled {
        doc: next,
        affected,
        effective,
    }
}

/// True when a binding reads at least one of the fields whose correction just changed.
fn reads_corrected(binding: &Binding, fields: &[String]) -> bool {
    binding
        .fields()
        .iter()
        .any(|name| fields.iter().any(|changed| changed.as_str() == *name))
}

fn count_all() -> Aggregation {
    Aggregation {
        op: "count".into(),
        field: None,
        filter: None,
    }
}

/// Mirrors `morphic_schema::check_aggregation` so a repaired binding is one the validator
/// will actually accept.
fn aggregation_ok(agg: &Aggregation, profile: &DatasetProfile) -> bool {
    let Some(name) = agg.field.as_deref() else {
        return true;
    };
    let Some(field) = profile.fields.iter().find(|f| f.name == name) else {
        return false;
    };
    match agg.op.as_str() {
        "sum" | "avg" => field.dtype.is_numeric(),
        "min" | "max" => field.dtype.is_numeric() || field.dtype == DataType::Timestamp,
        _ => true,
    }
}

fn temporal_ok(name: &str, profile: &DatasetProfile) -> bool {
    profile.fields.iter().any(|f| {
        f.name == name
            && (f.dtype == DataType::Timestamp || f.inference.role == FieldRole::Temporal)
    })
}

fn first_temporal(profile: &DatasetProfile) -> Option<String> {
    profile
        .fields
        .iter()
        .find(|f| f.dtype == DataType::Timestamp || f.inference.role == FieldRole::Temporal)
        .map(|f| f.name.clone())
}

/// Repair a binding whose component the corrected profile no longer generates. Field *names*
/// never change under an override, so table columns and chart dimensions stay; only the
/// aggregations and time axes whose dtype/role no longer supports them are rewritten.
fn repair_binding(binding: &Binding, profile: &DatasetProfile) -> Binding {
    match binding {
        Binding::MetricCard { aggregation } => Binding::MetricCard {
            aggregation: if aggregation_ok(aggregation, profile) {
                aggregation.clone()
            } else {
                count_all()
            },
        },
        Binding::BarChart {
            dimension,
            measure,
            limit,
        } => Binding::BarChart {
            dimension: dimension.clone(),
            measure: if aggregation_ok(measure, profile) {
                measure.clone()
            } else {
                count_all()
            },
            limit: *limit,
        },
        Binding::LineChart { x, y, group_by } => {
            let kept: Vec<Aggregation> = y
                .iter()
                .filter(|agg| aggregation_ok(agg, profile))
                .cloned()
                .collect();
            let x_ok = profile
                .fields
                .iter()
                .find(|f| f.name == *x)
                .is_some_and(|f| {
                    f.dtype == DataType::Timestamp
                        || f.dtype.is_numeric()
                        || f.inference.role == FieldRole::Temporal
                });
            Binding::LineChart {
                x: if x_ok {
                    x.clone()
                } else {
                    first_temporal(profile).unwrap_or_else(|| x.clone())
                },
                y: if kept.is_empty() {
                    vec![count_all()]
                } else {
                    kept
                },
                group_by: group_by.clone(),
            }
        }
        Binding::Timeline {
            time_field,
            group_by,
            severity_field,
        } => Binding::Timeline {
            time_field: if temporal_ok(time_field, profile) {
                time_field.clone()
            } else {
                first_temporal(profile).unwrap_or_else(|| time_field.clone())
            },
            group_by: group_by.clone(),
            severity_field: severity_field.clone(),
        },
        Binding::DataTable { .. } => binding.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{FieldProfile, Inference, NumericStats, ValueCount};

    fn field(name: &str, dtype: DataType, role: FieldRole) -> FieldProfile {
        FieldProfile {
            name: name.into(),
            dtype,
            null_count: 0,
            distinct_count: 3,
            min: None,
            max: None,
            top_values: Vec::<ValueCount>::new(),
            stats: if dtype.is_numeric() {
                Some(NumericStats {
                    count: 5,
                    mean: 10.0,
                    std_dev: 1.0,
                    p50: 10.0,
                    p95: 11.0,
                    p99: 12.0,
                    sampled: false,
                    sample_size: 5,
                })
            } else {
                None
            },
            inference: Inference {
                role,
                confidence: 0.9,
                evidence: vec!["inferred from the sample".into()],
            },
        }
    }

    fn profile() -> DatasetProfile {
        DatasetProfile {
            row_count: 5,
            field_count: 3,
            fields: vec![
                field("region", DataType::Utf8, FieldRole::Dimension),
                field("amount", DataType::Int64, FieldRole::Measure),
                field("note", DataType::Utf8, FieldRole::Text),
            ],
        }
    }

    #[test]
    fn effective_profile_applies_both_kinds_of_correction() {
        let overrides = vec![
            FieldOverride {
                field: "amount".into(),
                dtype: Some("utf8".into()),
                role: Some("identifier".into()),
            },
            FieldOverride {
                field: "missing".into(),
                dtype: Some("bool".into()),
                role: None,
            },
        ];
        let effective = effective_profile(&profile(), &overrides);
        let amount = effective
            .fields
            .iter()
            .find(|f| f.name == "amount")
            .unwrap();
        assert_eq!(amount.dtype, DataType::Utf8);
        assert_eq!(amount.inference.role, FieldRole::Identifier);
        assert_eq!(amount.inference.confidence, 1.0);
        assert_eq!(amount.inference.evidence, vec!["user override: identifier"]);
        assert_eq!(effective.fields.len(), 3, "unknown names change nothing");
    }

    #[test]
    fn recompiler_only_changes_components_that_read_the_corrected_field() {
        let base = profile();
        let doc = compile(&base, "d1", "w1", "Sales", "2026-11-10T00:00:00Z");
        assert!(
            doc.workspace
                .components
                .iter()
                .any(|c| c.id == "metric_amount"),
            "the fixture must generate an average over amount"
        );
        let mut corrected = doc.clone();
        corrected.workspace.field_overrides.push(FieldOverride {
            field: "amount".into(),
            dtype: Some("utf8".into()),
            role: None,
        });
        let result = recompile_for_fields(&corrected, &base, &["amount".to_string()]);
        assert!(result.affected.contains(&"metric_amount".to_string()));
        // The record-count card has no field reference and must be byte-identical.
        let before = doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == "total_records")
            .unwrap();
        let after = result
            .doc
            .workspace
            .components
            .iter()
            .find(|c| c.id == "total_records")
            .unwrap();
        assert_eq!(
            serde_json::to_value(&before.binding).unwrap(),
            serde_json::to_value(&after.binding).unwrap()
        );
        assert_eq!(
            result.doc.workspace.layout.order,
            doc.workspace.layout.order
        );
        assert_eq!(
            result.doc.workspace.field_overrides,
            corrected.workspace.field_overrides
        );
    }

    #[test]
    fn an_empty_change_set_is_a_no_op() {
        let base = profile();
        let doc = compile(&base, "d1", "w1", "Sales", "2026-11-10T00:00:00Z");
        let result = recompile_for_fields(&doc, &base, &[]);
        assert!(result.affected.is_empty());
        assert_eq!(
            serde_json::to_value(&result.doc).unwrap(),
            serde_json::to_value(&doc).unwrap()
        );
    }

    #[test]
    fn a_repaired_binding_validates_against_the_corrected_profile() {
        let base = profile();
        let doc = compile(&base, "d1", "w1", "Sales", "2026-11-10T00:00:00Z");
        let mut corrected = doc.clone();
        corrected.workspace.field_overrides.push(FieldOverride {
            field: "amount".into(),
            dtype: Some("utf8".into()),
            role: None,
        });
        let result = recompile_for_fields(&corrected, &base, &["amount".to_string()]);
        assert!(
            morphic_schema::validate_bindings(&result.doc, &result.effective).is_empty(),
            "a correction must not leave an uncomputable binding behind"
        );
    }
}
