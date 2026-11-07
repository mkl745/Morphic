//! Turning canonical document state into a query plan (M1.3 task 1.3.2).
//!
//! This is the only place that decides what a component's data means. Flutter asks for a
//! component's page or metric and never assembles a filter itself — the "no Dart-side data
//! logic" clause of the M1.3 exit is enforced by there being nothing to reimplement.
//!
//! # Composition order
//!
//! `global filters AND component filter AND binding filter`. All three are conjuncts: a global
//! chip narrows every component, a component filter narrows one, and a metric card's binding
//! filter (e.g. `level = ERROR`) is part of what that card *means* and can never be widened by
//! the user. The binding filter goes last so the user's filters cannot escape it.
//!
//! # Why the cache key works
//!
//! The key is `(dataRevision, planHash)`, not the document revision. Editing one component
//! bumps the document revision but leaves every other component's plan byte-identical, so
//! those components hit the cache. Keying by document revision would invalidate everything on
//! every keystroke and make "affected-component recomputation only" impossible.

use morphic_query::{Direction, Nulls, Plan, SortSpec};
use morphic_schema::{Binding, ComponentSpec, FilterExpr, NullsOrder, SortDir, WorkspaceDoc};

use crate::{commands, CoreError};

/// Build the plan behind one component's rows.
pub(crate) fn for_component(
    doc: &WorkspaceDoc,
    component: &ComponentSpec,
    offset: usize,
    limit: usize,
) -> Result<Plan, CoreError> {
    let filter = composed_filter(doc, component)?;
    let sort = component
        .state
        .sort
        .iter()
        .map(|r| SortSpec {
            field: r.field.clone(),
            dir: match r.dir {
                SortDir::Asc => Direction::Asc,
                SortDir::Desc => Direction::Desc,
            },
            nulls: match r.nulls {
                NullsOrder::First => Nulls::First,
                NullsOrder::Last => Nulls::Last,
            },
        })
        .collect();

    Ok(Plan {
        search: component.state.search.clone(),
        filter,
        sort,
        offset,
        limit,
        ..Default::default()
    })
}

/// The selection plan behind a metric: filters and search, but no sort and no paging.
///
/// Sorting cannot change an aggregate, and including it in the plan would give the same value
/// two cache keys — a miss that recomputes an identical answer.
pub(crate) fn for_metric(doc: &WorkspaceDoc, component: &ComponentSpec) -> Result<Plan, CoreError> {
    Ok(Plan {
        search: component.state.search.clone(),
        filter: composed_filter(doc, component)?,
        ..Default::default()
    })
}

fn composed_filter(
    doc: &WorkspaceDoc,
    component: &ComponentSpec,
) -> Result<Option<serde_json::Value>, CoreError> {
    let mut parts: Vec<FilterExpr> = doc.workspace.global_filters.clone();
    if let Some(f) = &component.state.filter {
        parts.push(f.clone());
    }
    let binding_filter = match &component.binding {
        Binding::MetricCard { aggregation } => aggregation.filter.as_ref(),
        _ => None,
    };
    if let Some(f) = binding_filter {
        parts.push(f.clone());
    }
    match commands::combine(parts) {
        None => Ok(None),
        // FilterExpr's serde shape *is* the flat wire node the executor parses, so this needs
        // no hand-written mapping to drift out of date.
        Some(f) => serde_json::to_value(&f)
            .map(Some)
            .map_err(|e| CoreError::Command(format!("filter is not serializable: {e}"))),
    }
}

/// The page size a data table binding declares, clamped by the executor's own ceiling.
pub(crate) fn page_size(component: &ComponentSpec) -> usize {
    match &component.binding {
        Binding::DataTable { page_size, .. } => *page_size as usize,
        _ => morphic_query::DEFAULT_PAGE_SIZE,
    }
}
