//! The interaction command bus (M1.3 task 1.3.2, docs/architecture/02 §3, 05 §4).
//!
//! # Atomic by construction
//!
//! [`apply`] transforms a **clone** of the document and only returns it once every command has
//! succeeded and the result passes schema validation. A rejected command in a batch of five
//! leaves the caller's document untouched — there is no partial application to undo, because
//! nothing was applied. Persistence happens in `Engine::apply`, after this returns.
//!
//! # Affected components, not "everything"
//!
//! The outcome names the components whose data can have changed. A component sort touches one
//! component; a global filter touches all of them, because that is what global means. Setting a
//! value to what it already is affects **nothing** and does not bump the revision — which is
//! what makes a debounced search field cheap and a repeated tap idempotent.
//!
//! The affected list is an optimization hint for the UI. Correctness does not depend on it:
//! the result cache is keyed by `(dataRevision, planHash)`, so an unaffected component hits the
//! cache even if the UI asks for it again.

use morphic_schema::{FieldOverride, FilterExpr, SortRule, WorkspaceDoc, DATA_TYPES, FIELD_ROLES};
use serde::{Deserialize, Serialize};

use crate::CoreError;

/// A user interaction, expressed as data. The vocabulary is closed: Flutter sends one of these
/// and never edits the document itself.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Command {
    /// Replace the whole global filter set. Add/edit/remove a chip is composed by the UI and
    /// sent as the resulting set, so "clear all" is simply an empty vector and there is no
    /// separate remove command whose index could go stale.
    SetGlobalFilter { filters: Vec<FilterExpr> },
    SetComponentFilter {
        #[serde(rename = "componentId")]
        component_id: String,
        filter: Option<FilterExpr>,
    },
    SetComponentSort {
        #[serde(rename = "componentId")]
        component_id: String,
        sort: Vec<SortRule>,
    },
    SetSearch {
        #[serde(rename = "componentId")]
        component_id: String,
        text: Option<String>,
    },
    /// Switch a component's visualization. The engine converts the binding through a closed
    /// compatibility matrix (docs/architecture/04 §4) and validates the result before the
    /// batch is committed; a rejected switch leaves the document untouched.
    ChangeComponentType {
        #[serde(rename = "componentId")]
        component_id: String,
        #[serde(rename = "targetType")]
        target_type: String,
    },
    /// Reorder one component in the persisted layout. The whole order is still owned by Rust.
    MoveComponent {
        #[serde(rename = "componentId")]
        component_id: String,
        #[serde(rename = "toIndex")]
        to_index: usize,
    },
    /// Persist a user correction to a field's inferred physical type. Recompilation of the
    /// affected bindings is 1.5.5; storing and undoing the command arrives with 1.5.1.
    OverrideFieldType { field: String, dtype: String },
    /// Persist a user correction to a field's inferred semantic role.
    OverrideFieldRole { field: String, role: String },
}

/// The result of applying a batch to a document. `changed` is false for a no-op batch.
#[derive(Debug, Clone)]
pub struct Applied {
    pub doc: WorkspaceDoc,
    /// Component ids whose data may have changed, in layout order.
    pub affected: Vec<String>,
    pub changed: bool,
}

/// Apply a batch atomically. `fields` is the dataset's column names when the source is loaded;
/// `None` in degraded mode, where field references cannot be checked and are accepted on trust
/// rather than making the workspace unusable offline.
pub(crate) fn apply(
    doc: &WorkspaceDoc,
    commands: &[Command],
    fields: Option<&[String]>,
    profile: Option<&morphic_model::DatasetProfile>,
    now_iso: &str,
) -> Result<Applied, CoreError> {
    if commands.is_empty() {
        return Ok(Applied {
            doc: doc.clone(),
            affected: Vec::new(),
            changed: false,
        });
    }
    let mut next = doc.clone();
    let mut touched: Vec<String> = Vec::new();
    let mut global_changed = false;
    let mut layout_changed = false;
    let mut override_changed = false;
    let mut type_changed = false;

    for (i, cmd) in commands.iter().enumerate() {
        match cmd {
            Command::SetGlobalFilter { filters } => {
                for f in filters {
                    check_fields(f, fields).map_err(|m| at(i, m))?;
                }
                if next.workspace.global_filters != *filters {
                    next.workspace.global_filters = filters.clone();
                    global_changed = true;
                }
            }
            Command::SetComponentFilter {
                component_id,
                filter,
            } => {
                let c = component(&mut next, component_id).map_err(|m| at(i, m))?;
                if !c.interactions.filter {
                    return Err(at(
                        i,
                        format!(
                            "'{}' ({}) does not allow filtering",
                            component_id, c.component_type
                        ),
                    ));
                }
                if let Some(f) = filter {
                    check_fields(f, fields).map_err(|m| at(i, m))?;
                }
                if c.state.filter != *filter {
                    c.state.filter = filter.clone();
                    touched.push(component_id.clone());
                }
            }
            Command::SetComponentSort { component_id, sort } => {
                let c = component(&mut next, component_id).map_err(|m| at(i, m))?;
                if !c.interactions.sort {
                    return Err(at(
                        i,
                        format!(
                            "'{}' ({}) does not allow sorting",
                            component_id, c.component_type
                        ),
                    ));
                }
                if let Some(names) = fields {
                    for rule in sort {
                        if !names.contains(&rule.field) {
                            return Err(at(i, format!("unknown sort field '{}'", rule.field)));
                        }
                    }
                }
                if c.state.sort != *sort {
                    c.state.sort = sort.clone();
                    touched.push(component_id.clone());
                }
            }
            Command::ChangeComponentType {
                component_id,
                target_type,
            } => {
                let Some(p) = profile else {
                    return Err(at(
                        i,
                        "cannot change a component type without the dataset profile (degraded mode)"
                            .to_string(),
                    ));
                };
                let c = component(&mut next, component_id).map_err(|m| at(i, m))?;
                if c.component_type == *target_type {
                    continue;
                }
                let converted = morphic_schema::convert_component_type(c, target_type, p)
                    .map_err(|m| at(i, m))?;
                *c = converted;
                touched.push(component_id.clone());
                type_changed = true;
            }
            Command::MoveComponent {
                component_id,
                to_index,
            } => {
                let order = &mut next.workspace.layout.order;
                let Some(from) = order.iter().position(|id| id == component_id) else {
                    return Err(at(i, format!("unknown component '{component_id}'")));
                };
                let to = (*to_index).min(order.len().saturating_sub(1));
                if from != to {
                    let id = order.remove(from);
                    order.insert(to, id);
                    layout_changed = true;
                }
            }
            Command::OverrideFieldType { field, dtype } => {
                check_override_field(field, fields).map_err(|m| at(i, m))?;
                if !DATA_TYPES.contains(&dtype.as_str()) {
                    return Err(at(i, format!("unknown dtype override '{dtype}'")));
                }
                override_changed |=
                    upsert_override(&mut next, field.clone(), Some(dtype.clone()), None);
            }
            Command::OverrideFieldRole { field, role } => {
                check_override_field(field, fields).map_err(|m| at(i, m))?;
                if !FIELD_ROLES.contains(&role.as_str()) {
                    return Err(at(i, format!("unknown role override '{role}'")));
                }
                override_changed |=
                    upsert_override(&mut next, field.clone(), None, Some(role.clone()));
            }
            Command::SetSearch { component_id, text } => {
                let c = component(&mut next, component_id).map_err(|m| at(i, m))?;
                if !c.interactions.search {
                    return Err(at(
                        i,
                        format!(
                            "'{}' ({}) does not allow search",
                            component_id, c.component_type
                        ),
                    ));
                }
                // An empty or whitespace-only search is "no search", not a search for "".
                let normalized = text
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string);
                if c.state.search != normalized {
                    c.state.search = normalized;
                    touched.push(component_id.clone());
                }
            }
        }
    }

    let broad_changed = global_changed || layout_changed || override_changed;
    let changed = broad_changed || !touched.is_empty();
    if !changed {
        return Ok(Applied {
            doc: doc.clone(),
            affected: Vec::new(),
            changed: false,
        });
    }

    // Validate the *result*, not each step: a batch may pass through an intermediate document
    // that would not stand on its own, and only the committed state has to be valid.
    let issues = morphic_schema::validate(&next);
    if !issues.is_empty() {
        let first = &issues[0];
        return Err(CoreError::Command(format!(
            "batch would produce an invalid document at {}: {}",
            first.pointer, first.rule
        )));
    }

    // A converted binding is checked against the live profile too (pass 3). This is a second,
    // stricter gate than the matrix: the matrix already applies the query layer's bucketing
    // rule, and this catches any field reference the proposal invented. Both run before the
    // document is committed, so a rejected switch changes nothing.
    if let (true, Some(p)) = (type_changed, profile) {
        let binding_issues = morphic_schema::validate_bindings(&next, p);
        if !binding_issues.is_empty() {
            let first = &binding_issues[0];
            return Err(CoreError::Command(format!(
                "type change would produce an uncomputable binding at {}: {}",
                first.pointer, first.rule
            )));
        }
    }

    // Global filters reach every component. Order by layout so the list is deterministic and
    // matches the order the UI paints.
    let affected: Vec<String> = if broad_changed {
        next.workspace
            .layout
            .order
            .iter()
            .filter(|id| next.workspace.components.iter().any(|c| &c.id == *id))
            .cloned()
            .collect()
    } else {
        next.workspace
            .layout
            .order
            .iter()
            .filter(|id| touched.contains(id))
            .cloned()
            .collect()
    };

    next.workspace.revision = next.workspace.revision.saturating_add(1);
    next.workspace.modified_at = now_iso.to_string();
    Ok(Applied {
        doc: next,
        affected,
        changed: true,
    })
}

fn check_override_field(field: &str, fields: Option<&[String]>) -> Result<(), String> {
    let Some(names) = fields else {
        return Ok(());
    };
    if !names.iter().any(|n| n == field) {
        return Err(format!("override names unknown field '{field}'"));
    }
    Ok(())
}

/// One field has at most one override record; a second command of the other kind edits it
/// instead of creating a duplicate that validation would reject.
fn upsert_override(
    doc: &mut WorkspaceDoc,
    field: String,
    dtype: Option<String>,
    role: Option<String>,
) -> bool {
    if let Some(existing) = doc
        .workspace
        .field_overrides
        .iter_mut()
        .find(|o| o.field == field)
    {
        let before = (existing.dtype.clone(), existing.role.clone());
        if dtype.is_some() {
            existing.dtype = dtype;
        }
        if role.is_some() {
            existing.role = role;
        }
        return before != (existing.dtype.clone(), existing.role.clone());
    }
    doc.workspace
        .field_overrides
        .push(FieldOverride { field, dtype, role });
    true
}

fn at(index: usize, msg: String) -> CoreError {
    CoreError::Command(format!("command {index}: {msg}"))
}

fn component<'d>(
    doc: &'d mut WorkspaceDoc,
    id: &str,
) -> Result<&'d mut morphic_schema::ComponentSpec, String> {
    doc.workspace
        .components
        .iter_mut()
        .find(|c| c.id == id)
        .ok_or_else(|| format!("unknown component '{id}'"))
}

/// Every field a filter reads must exist. Rejecting here rather than at query time turns a typo
/// into an error the user sees immediately, instead of a filter chip that silently matches
/// nothing.
fn check_fields(f: &FilterExpr, fields: Option<&[String]>) -> Result<(), String> {
    let Some(names) = fields else {
        return Ok(());
    };
    let unknown = f
        .field
        .as_deref()
        .filter(|n| !n.is_empty())
        .filter(|n| !names.iter().any(|x| x == n));
    if let Some(name) = unknown {
        return Err(format!("unknown field '{name}'"));
    }
    for arg in &f.args {
        check_fields(arg, fields)?;
    }
    Ok(())
}

/// Combine filter parts into one expression. Global filters are conjuncts: every chip must
/// hold. One part is returned as-is so the common case does not grow a pointless `and` node.
pub(crate) fn combine(mut parts: Vec<FilterExpr>) -> Option<FilterExpr> {
    match parts.len() {
        0 => None,
        1 => parts.pop(),
        _ => Some(FilterExpr {
            op: "and".into(),
            field: None,
            value: None,
            args: parts,
        }),
    }
}
