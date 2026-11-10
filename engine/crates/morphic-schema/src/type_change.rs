//! `ChangeComponentType` (M1.4 task 1.4.7, docs/architecture/04 §4).
//!
//! A visualization switch is **not** a UI-only relabel: the binding, the declared interactions,
//! the persisted state and the title all have to change with it, or pass 2 (`binding.kind()` must
//! equal `type`) and pass 5 (state keys must fit the declared interactions) reject the document.
//! This module is the closed matrix of conversions the engine will perform, as a pure function
//! of `(component, target, profile)`. Nothing here mutates or persists anything.
//!
//! # Why the matrix does not trust `validate_bindings`
//!
//! Pass 3 accepts a `Utf8` column whose *inferred role* is Temporal for a line chart's `x` and
//! a timeline's `time_field`. The query layer does not: `series_scene` only buckets
//! `Timestamp`/`Int64`/`Float64` columns and `timeline_scene` only buckets `Timestamp`. 1.4.5
//! found three generated charts that passed all five validation passes and then failed at the
//! first draw. A manual switch is a second way to produce that exact document, so the matrix
//! applies the **query layer's** rule, not the validator's, before it agrees to convert.

use crate::{
    Aggregation, Binding, ComponentSpec, Explanation, FilterExpr, Interactions, ACTIVE_COMPONENTS,
    MAX_BAR_LIMIT,
};
use morphic_model::{DataType, DatasetProfile, FieldProfile, FieldRole};

/// Written into a converted component's explanation. Not a planner rule — the compiler never
/// emits it. Public so the Dart heading map can be drift-checked against the same string.
pub const TYPE_CHANGE_REASON: &str = "user_type_change";

/// Above this, a column is a key rather than a category. Mirrors the semantic ceiling and
/// `morphic_query::MAX_BAR_POINTS`; the bar renderer shows 12 and folds the rest into `Other`.
const MAX_DIMENSION_CARDINALITY: usize = 50;
const MAX_TABLE_COLUMNS: usize = 8;

fn field<'a>(profile: &'a DatasetProfile, name: &str) -> Option<&'a FieldProfile> {
    profile.fields.iter().find(|f| f.name == name)
}

/// `morphic_query::chart::series_scene`'s x-axis rule. A Temporal *role* on text is not enough.
fn bucketable(f: &FieldProfile) -> bool {
    f.dtype == DataType::Timestamp || f.dtype.is_numeric()
}

fn require_bucketable(profile: &DatasetProfile, name: &str, what: &str) -> Result<(), String> {
    match field(profile, name) {
        Some(f) if bucketable(f) => Ok(()),
        Some(f) => Err(format!(
            "{what} '{name}' is {}, not a bucketable time/numeric axis",
            f.dtype.as_str()
        )),
        None => Err(format!("{what} field '{name}' does not exist")),
    }
}

fn require_timestamp(profile: &DatasetProfile, name: &str) -> Result<(), String> {
    match field(profile, name) {
        Some(f) if f.dtype == DataType::Timestamp => Ok(()),
        Some(f) => Err(format!(
            "timeline time_field '{name}' is {}, not epoch milliseconds",
            f.dtype.as_str()
        )),
        None => Err(format!("timeline field '{name}' does not exist")),
    }
}

fn count_all() -> Aggregation {
    Aggregation {
        op: "count".into(),
        field: None,
        filter: None,
    }
}

fn collect_filter_fields(f: &FilterExpr, out: &mut Vec<String>) {
    if let Some(name) = &f.field {
        if !name.is_empty() {
            out.push(name.clone());
        }
    }
    for arg in &f.args {
        collect_filter_fields(arg, out);
    }
}

/// The fields a binding reads. `any -> data_table` projects exactly these, so switching a view
/// never quietly widens or narrows what a person can see.
fn bound_fields(binding: &Binding, profile: &DatasetProfile) -> Vec<String> {
    let mut names = Vec::new();
    let mut aggs: Vec<&Aggregation> = Vec::new();
    match binding {
        Binding::MetricCard { aggregation } => aggs.push(aggregation),
        Binding::DataTable { columns, .. } => names.extend(columns.iter().cloned()),
        Binding::BarChart {
            dimension, measure, ..
        } => {
            names.push(dimension.clone());
            aggs.push(measure);
        }
        Binding::LineChart { x, y, group_by } => {
            names.push(x.clone());
            aggs.extend(y.iter());
            if let Some(g) = group_by {
                names.push(g.clone());
            }
        }
        Binding::Timeline {
            time_field,
            group_by,
            severity_field,
        } => {
            names.push(time_field.clone());
            if let Some(g) = group_by {
                names.push(g.clone());
            }
            if let Some(s) = severity_field {
                names.push(s.clone());
            }
        }
    }
    for a in aggs {
        if let Some(f) = &a.field {
            names.push(f.clone());
        }
        if let Some(f) = &a.filter {
            collect_filter_fields(f, &mut names);
        }
    }
    let mut out: Vec<String> = Vec::new();
    for n in names {
        if field(profile, &n).is_some() && !out.contains(&n) {
            out.push(n);
        }
    }
    out.truncate(MAX_TABLE_COLUMNS);
    if out.is_empty() {
        out = profile
            .fields
            .iter()
            .take(MAX_TABLE_COLUMNS)
            .map(|f| f.name.clone())
            .collect();
    }
    out
}

/// Prefer the columns the old view already showed; break every tie by name so a proposal is
/// deterministic. A ranking that kept source order would make the same file produce different
/// workspaces after a re-import.
fn candidates<'a>(profile: &'a DatasetProfile, preferred: &[String]) -> Vec<&'a FieldProfile> {
    let mut v: Vec<&FieldProfile> = profile.fields.iter().collect();
    v.sort_by(|a, b| {
        let pa = preferred
            .iter()
            .position(|n| n == &a.name)
            .unwrap_or(usize::MAX);
        let pb = preferred
            .iter()
            .position(|n| n == &b.name)
            .unwrap_or(usize::MAX);
        pa.cmp(&pb).then_with(|| a.name.cmp(&b.name))
    });
    v
}

fn propose_dimension<'a>(
    profile: &'a DatasetProfile,
    preferred: &[String],
) -> Option<&'a FieldProfile> {
    candidates(profile, preferred).into_iter().find(|f| {
        f.dtype == DataType::Utf8
            && f.distinct_count > 1
            && f.distinct_count <= MAX_DIMENSION_CARDINALITY
    })
}

fn propose_axis<'a>(
    profile: &'a DatasetProfile,
    preferred: &[String],
    timestamp_only: bool,
) -> Option<&'a FieldProfile> {
    candidates(profile, preferred).into_iter().find(|f| {
        if timestamp_only {
            f.dtype == DataType::Timestamp
        } else {
            bucketable(f)
        }
    })
}

fn propose_severity(profile: &DatasetProfile) -> Option<String> {
    profile
        .fields
        .iter()
        .find(|f| f.inference.role == FieldRole::Severity)
        .map(|f| f.name.clone())
}

fn measure_label(agg: Option<&Aggregation>) -> String {
    match agg.and_then(|a| a.field.as_deref()) {
        Some(f) => format!("average {f}"),
        None => "record count".to_string(),
    }
}

fn metric_title(agg: &Aggregation) -> String {
    if agg.filter.is_some() {
        return "Errors".into();
    }
    match agg.field.as_deref() {
        None => "Records".into(),
        Some(f) => match agg.op.as_str() {
            "avg" => format!("Avg {f}"),
            "sum" => format!("Sum {f}"),
            "min" => format!("Min {f}"),
            "max" => format!("Max {f}"),
            "distinct_count" => format!("Distinct {f}"),
            other => format!("{other} {f}"),
        },
    }
}

fn title_for(binding: &Binding) -> Option<String> {
    match binding {
        Binding::MetricCard { aggregation } => Some(metric_title(aggregation)),
        Binding::DataTable { .. } => Some("Data".into()),
        Binding::BarChart {
            dimension, measure, ..
        } => Some(format!("{} by {dimension}", measure_label(Some(measure)))),
        Binding::LineChart { y, .. } => Some(format!("{} over time", measure_label(y.first()))),
        Binding::Timeline { .. } => Some("Timeline".into()),
    }
}

/// The capabilities the compiler declares for each generated type. A converted component must
/// declare the same ones, or pass 5 rejects state that the old view legitimately held.
fn interactions_for(kind: &str) -> Interactions {
    let mut i = Interactions {
        filter: true,
        ..Default::default()
    };
    match kind {
        "bar_chart" => {
            i.sort = true;
            i.select = true;
        }
        "line_chart" | "timeline" => i.select = true,
        "data_table" => {
            i.search = true;
            i.sort = true;
            i.select = true;
        }
        _ => {}
    }
    i
}

fn propose_bar(profile: &DatasetProfile, preferred: &[String]) -> Result<(String, u32), String> {
    let d = propose_dimension(profile, preferred)
        .ok_or_else(|| "no low-cardinality text column to break down by".to_string())?;
    Ok((
        d.name.clone(),
        (d.distinct_count as u32).clamp(1, MAX_BAR_LIMIT),
    ))
}

fn propose_x(
    profile: &DatasetProfile,
    preferred: &[String],
    timestamp_only: bool,
) -> Result<String, String> {
    let t = propose_axis(profile, preferred, timestamp_only).ok_or_else(|| {
        if timestamp_only {
            "no timestamp column to lay out as events".to_string()
        } else {
            "no temporal or numeric column to plot on x".to_string()
        }
    })?;
    Ok(t.name.clone())
}

fn convert_binding(
    from: &Binding,
    target: &str,
    profile: &DatasetProfile,
) -> Result<Binding, String> {
    let preferred = match from {
        Binding::DataTable { columns, .. } => columns.clone(),
        _ => bound_fields(from, profile),
    };
    match (from, target) {
        (_, "data_table") => Ok(Binding::DataTable {
            columns: bound_fields(from, profile),
            page_size: 256,
        }),
        (Binding::BarChart { measure, .. }, "metric_card") => Ok(Binding::MetricCard {
            aggregation: measure.clone(),
        }),
        (
            Binding::BarChart {
                dimension: d,
                measure,
                ..
            },
            "line_chart",
        ) => {
            require_bucketable(profile, d, "line_chart x")?;
            Ok(Binding::LineChart {
                x: d.clone(),
                y: vec![measure.clone()],
                group_by: None,
            })
        }
        (Binding::LineChart { x, y, .. }, "bar_chart") => {
            let f = field(profile, x).ok_or_else(|| format!("field '{x}' does not exist"))?;
            if f.distinct_count > MAX_DIMENSION_CARDINALITY {
                return Err(format!(
                    "line_chart x '{x}' has {} distinct values; a bar chart needs at most {}",
                    f.distinct_count, MAX_DIMENSION_CARDINALITY
                ));
            }
            Ok(Binding::BarChart {
                dimension: x.clone(),
                measure: y.first().cloned().unwrap_or_else(count_all),
                limit: (f.distinct_count as u32).clamp(1, MAX_BAR_LIMIT),
            })
        }
        (Binding::LineChart { x, group_by, .. }, "timeline") => {
            require_timestamp(profile, x)?;
            Ok(Binding::Timeline {
                time_field: x.clone(),
                group_by: None,
                severity_field: group_by.clone(),
            })
        }
        (
            Binding::Timeline {
                time_field,
                severity_field,
                ..
            },
            "line_chart",
        ) => {
            require_bucketable(profile, time_field, "line_chart x")?;
            Ok(Binding::LineChart {
                x: time_field.clone(),
                y: vec![count_all()],
                group_by: severity_field.clone(),
            })
        }
        (Binding::MetricCard { aggregation }, "bar_chart") => {
            let (d, limit) = propose_bar(profile, &preferred)?;
            Ok(Binding::BarChart {
                dimension: d,
                measure: aggregation.clone(),
                limit,
            })
        }
        (Binding::MetricCard { aggregation }, "line_chart") => {
            let x = propose_x(profile, &preferred, false)?;
            Ok(Binding::LineChart {
                x,
                y: vec![aggregation.clone()],
                group_by: None,
            })
        }
        (Binding::MetricCard { .. }, "timeline") => {
            let time_field = propose_x(profile, &preferred, true)?;
            Ok(Binding::Timeline {
                time_field,
                group_by: None,
                severity_field: propose_severity(profile),
            })
        }
        (Binding::DataTable { .. }, "metric_card") => Ok(Binding::MetricCard {
            aggregation: count_all(),
        }),
        (Binding::DataTable { .. }, "bar_chart") => {
            let (d, limit) = propose_bar(profile, &preferred)?;
            Ok(Binding::BarChart {
                dimension: d,
                measure: count_all(),
                limit,
            })
        }
        (Binding::DataTable { .. }, "line_chart") => {
            let x = propose_x(profile, &preferred, false)?;
            Ok(Binding::LineChart {
                x,
                y: vec![count_all()],
                group_by: None,
            })
        }
        (Binding::DataTable { .. }, "timeline") => {
            let time_field = propose_x(profile, &preferred, true)?;
            Ok(Binding::Timeline {
                time_field,
                group_by: None,
                severity_field: propose_severity(profile),
            })
        }
        _ => Err(format!(
            "there is no conversion from {} to {target}",
            from.kind()
        )),
    }
}

/// Convert one component to `target`. Returns an error with a human-readable reason when the
/// matrix has no rule or the data cannot support the new binding; the caller must leave the
/// document untouched in that case.
pub fn convert_component_type(
    component: &ComponentSpec,
    target: &str,
    profile: &DatasetProfile,
) -> Result<ComponentSpec, String> {
    if !ACTIVE_COMPONENTS.contains(&target) {
        return Err(format!("unknown component type '{target}'"));
    }
    if target == component.component_type {
        return Ok(component.clone());
    }
    let binding = convert_binding(&component.binding, target, profile)?;
    let interactions = interactions_for(target);

    // State belongs to the *old* view. Keeping a bar sort on a metric card would make pass 5
    // reject the converted document, and discarding it silently would lose the user's work.
    // Clear it and name what was cleared in the explanation, which 1.4.6's sheet now renders.
    let mut state = component.state.clone();
    let mut dropped = Vec::new();
    if !interactions.sort && !state.sort.is_empty() {
        state.sort.clear();
        dropped.push("sort");
    }
    if !interactions.search && state.search.is_some() {
        state.search = None;
        dropped.push("search");
    }
    if !interactions.filter && state.filter.is_some() {
        state.filter = None;
        dropped.push("filter");
    }

    let mut detail = format!(
        "You changed this view from {} to {target}; the binding was converted.",
        component.component_type
    );
    detail.push_str(" The same fields stay in view.");
    let mut evidence = vec![
        format!("previous type: {}", component.component_type),
        format!("new type: {target}"),
    ];
    if !dropped.is_empty() {
        detail.push_str(" State the new view cannot hold was cleared.");
        evidence.push(format!("cleared state: {}", dropped.join(", ")));
    }

    Ok(ComponentSpec {
        id: component.id.clone(),
        component_type: target.to_string(),
        type_version: component.type_version.clone(),
        title: title_for(&binding),
        data_source: component.data_source.clone(),
        binding,
        interactions,
        state,
        explanation: Some(Explanation {
            reason: TYPE_CHANGE_REASON.into(),
            detail,
            evidence,
            confidence: 1.0,
        }),
    })
}

/// The targets a UI may offer for this component: every registered type for which the
/// conversion succeeds against the *live* profile. The engine is the authority; a caller that
/// offers an option this list omits will get a readable rejection instead of a broken chart.
pub fn component_type_options(
    component: &ComponentSpec,
    profile: &DatasetProfile,
) -> Vec<&'static str> {
    ACTIVE_COMPONENTS
        .iter()
        .copied()
        .filter(|t| *t != component.component_type.as_str())
        .filter(|t| convert_component_type(component, t, profile).is_ok())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{DataSourceRef, Generator, Layout, Workspace, WorkspaceDoc, SCHEMA_VERSION};

    fn f(name: &str, dtype: DataType, role: FieldRole, distinct: usize) -> FieldProfile {
        FieldProfile {
            name: name.into(),
            dtype,
            null_count: 0,
            distinct_count: distinct,
            min: None,
            max: None,
            top_values: vec![],
            stats: None,
            inference: morphic_model::Inference {
                role,
                confidence: 0.9,
                evidence: vec![format!("{name} evidence")],
            },
        }
    }

    fn profile() -> DatasetProfile {
        DatasetProfile {
            row_count: 100,
            field_count: 5,
            fields: vec![
                f("day_name", DataType::Utf8, FieldRole::Temporal, 7),
                f("latency_ms", DataType::Float64, FieldRole::Measure, 60),
                f("level", DataType::Utf8, FieldRole::Severity, 4),
                f("service", DataType::Utf8, FieldRole::Dimension, 3),
                f("time", DataType::Timestamp, FieldRole::Temporal, 20),
            ],
        }
    }

    fn component(kind: &str, binding: Binding) -> ComponentSpec {
        ComponentSpec {
            id: "c1".into(),
            component_type: kind.into(),
            type_version: "1.0".into(),
            title: Some("Original title".into()),
            data_source: "data".into(),
            binding,
            interactions: Interactions::default(),
            state: Default::default(),
            explanation: Some(Explanation {
                reason: "R1_records".into(),
                detail: "generated".into(),
                evidence: vec!["20 rows detected".into()],
                confidence: 1.0,
            }),
        }
    }

    fn bar(dimension: &str) -> Binding {
        Binding::BarChart {
            dimension: dimension.into(),
            measure: Aggregation {
                op: "avg".into(),
                field: Some("latency_ms".into()),
                filter: None,
            },
            limit: 12,
        }
    }

    fn doc(c: ComponentSpec) -> WorkspaceDoc {
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
                    version: "0.2.0".into(),
                },
                data_sources: vec![DataSourceRef {
                    alias: "data".into(),
                    dataset_id: "d1".into(),
                }],
                layout: Layout {
                    mode: "adaptive".into(),
                    order: vec!["c1".into()],
                    hints: vec![],
                },
                global_filters: vec![],
                field_overrides: vec![],
                components: vec![c],
            },
        }
    }

    /// The finding behind this task: pass 3 accepts a text x with a Temporal role, while the
    /// query layer refuses to bucket it. A conversion that only called `validate_bindings`
    /// would reintroduce the three broken charts 1.4.5 found, through the manual path.
    #[test]
    fn the_matrix_is_stricter_than_pass_three_for_text_time_axes() {
        let p = profile();
        let bad = component(
            "line_chart",
            Binding::LineChart {
                x: "day_name".into(),
                y: vec![count_all()],
                group_by: None,
            },
        );
        assert!(
            crate::validate_bindings(&doc(bad), &p).is_empty(),
            "pass 3 deliberately accepts a Utf8 Temporal role; the matrix must not"
        );
        let c = component("bar_chart", bar("day_name"));
        let err = convert_component_type(&c, "line_chart", &p).unwrap_err();
        assert!(err.contains("not a bucketable"), "{err}");
    }

    #[test]
    fn a_timestamp_dimension_becomes_a_line_but_a_category_does_not() {
        let p = profile();
        let ok = convert_component_type(&component("bar_chart", bar("time")), "line_chart", &p)
            .expect("a Timestamp axis is bucketable");
        assert!(matches!(ok.binding, Binding::LineChart { .. }));
        let c = component("bar_chart", bar("service"));
        assert!(
            convert_component_type(&c, "line_chart", &p).is_err(),
            "a text dimension must not become a line chart"
        );
    }

    #[test]
    fn line_to_timeline_needs_epoch_milliseconds_not_a_numeric_x() {
        let p = profile();
        let ok = convert_component_type(
            &component(
                "line_chart",
                Binding::LineChart {
                    x: "time".into(),
                    y: vec![count_all()],
                    group_by: Some("level".into()),
                },
            ),
            "timeline",
            &p,
        )
        .expect("Timestamp x can be an event timeline");
        assert!(matches!(
            ok.binding,
            Binding::Timeline {
                severity_field: Some(_),
                ..
            }
        ));
        let err = convert_component_type(
            &component(
                "line_chart",
                Binding::LineChart {
                    x: "latency_ms".into(),
                    y: vec![count_all()],
                    group_by: None,
                },
            ),
            "timeline",
            &p,
        )
        .unwrap_err();
        assert!(err.contains("epoch milliseconds"), "{err}");
    }

    #[test]
    fn a_high_cardinality_x_cannot_become_a_bar_chart() {
        let p = profile();
        let err = convert_component_type(
            &component(
                "line_chart",
                Binding::LineChart {
                    x: "latency_ms".into(),
                    y: vec![count_all()],
                    group_by: None,
                },
            ),
            "bar_chart",
            &p,
        )
        .unwrap_err();
        assert!(err.contains("distinct values"), "{err}");
    }

    #[test]
    fn every_conversion_produces_a_document_that_passes_all_five_passes() {
        let p = profile();
        let sources = [
            component("bar_chart", bar("service")),
            component(
                "line_chart",
                Binding::LineChart {
                    x: "time".into(),
                    y: vec![count_all()],
                    group_by: None,
                },
            ),
            component(
                "metric_card",
                Binding::MetricCard {
                    aggregation: count_all(),
                },
            ),
            component(
                "data_table",
                Binding::DataTable {
                    columns: vec!["service".into(), "time".into()],
                    page_size: 256,
                },
            ),
            component(
                "timeline",
                Binding::Timeline {
                    time_field: "time".into(),
                    group_by: None,
                    severity_field: None,
                },
            ),
        ];
        let mut checked = 0;
        for source in &sources {
            for target in component_type_options(source, &p) {
                let converted = convert_component_type(source, target, &p)
                    .unwrap_or_else(|e| panic!("{} -> {target}: {e}", source.component_type));
                assert_eq!(converted.component_type, target);
                assert_eq!(converted.binding.kind(), target);
                assert_eq!(converted.id, source.id);
                let issues = crate::validate(&doc(converted.clone()));
                assert!(
                    issues.is_empty(),
                    "{} -> {target}: {issues:?}",
                    source.component_type
                );
                let binding_issues = crate::validate_bindings(&doc(converted), &p);
                assert!(
                    binding_issues.is_empty(),
                    "{} -> {target}: {binding_issues:?}",
                    source.component_type
                );
                checked += 1;
            }
        }
        assert!(checked >= 10, "only {checked} conversions were exercised");
    }

    #[test]
    fn state_the_new_view_cannot_hold_is_cleared_and_named() {
        let p = profile();
        let mut source = component("bar_chart", bar("service"));
        source.state.sort.push(crate::SortRule {
            field: "service".into(),
            dir: crate::SortDir::Asc,
            nulls: crate::NullsOrder::Last,
        });
        let converted = convert_component_type(&source, "metric_card", &p).unwrap();
        assert!(converted.state.sort.is_empty());
        assert!(!converted.interactions.sort);
        let e = converted.explanation.as_ref().unwrap();
        assert_eq!(e.reason, TYPE_CHANGE_REASON);
        assert!(e.evidence.iter().any(|s| s.contains("cleared state: sort")));
        assert!(crate::validate(&doc(converted)).is_empty());
    }

    #[test]
    fn unknown_and_same_type_targets_are_handled_without_a_partial_edit() {
        let p = profile();
        let c = component("bar_chart", bar("service"));
        assert!(convert_component_type(&c, "pie_chart", &p).is_err());
        let same = convert_component_type(&c, "bar_chart", &p).unwrap();
        assert_eq!(same.title, c.title);
        assert_eq!(same.explanation.unwrap().reason, "R1_records");
    }
}
