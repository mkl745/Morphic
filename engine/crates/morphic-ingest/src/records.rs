//! Shared record-to-columns machinery for the JSON-shaped formats (M1.2).
//!
//! JSON arrays (1.2.1) and JSONL (1.2.2) must agree on flattening, nulls, naming, typing,
//! quarantine policy and warning text. Keeping two copies is how formats silently drift
//! apart, so both call this module — the same reason both go through
//! [`crate::column::build_column`] rather than typing values themselves.
//!
//! The policy itself is documented on [`crate::json`]; this module is the implementation.

use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};

use morphic_model::Column;
use serde_json::Value;

use crate::{column, CancelToken, IngestError, IngestOptions};

/// Deepest dotted path produced by flattening. `a.b.c.d` is kept; `a.b.c.d.e` is not.
pub const MAX_DEPTH: usize = 4;

/// A flattened field: dotted path, and `None` for a JSON null.
pub type Field = (String, Option<String>);

pub fn check_cancel(cancel: Option<&CancelToken>) -> Result<(), IngestError> {
    match cancel {
        Some(c) if c.is_cancelled() => Err(IngestError::Cancelled),
        _ => Ok(()),
    }
}

/// One-off observations that become a single warning each, not one per row.
#[derive(Default)]
pub struct Notes {
    arrays: HashSet<String>,
    deep: HashSet<String>,
    scalars: bool,
    empty_containers: bool,
    renamed: usize,
}

impl Notes {
    /// Emit one warning per observation, never one per row. `container` names the source
    /// shape in the copy ("array" for JSON, "file" for JSONL).
    pub fn extend_warnings(&self, container: &str, warnings: &mut Vec<String>) {
        if self.scalars {
            warnings.push(format!(
                "The {container} contained plain values rather than objects; they were \
                 imported into a single 'value' column."
            ));
        }
        if self.renamed > 0 {
            warnings.push(format!(
                "{} field name(s) collided after flattening and were given a numeric suffix.",
                self.renamed
            ));
        }
        if self.empty_containers {
            warnings.push(
                "Empty objects and arrays were kept as JSON text so the field is not lost.".into(),
            );
        }
        let mut array_cols: Vec<&String> = self.arrays.iter().collect();
        array_cols.sort();
        for name in array_cols {
            warnings.push(format!(
                "Column '{name}' holds JSON arrays; they were kept as JSON text rather than \
                 expanded into rows."
            ));
        }
        let mut deep_cols: Vec<&String> = self.deep.iter().collect();
        deep_cols.sort();
        for name in deep_cols {
            warnings.push(format!(
                "Column '{name}' is nested deeper than {MAX_DEPTH} levels; the remaining \
                 structure was kept as JSON text."
            ));
        }
    }
}

/// Partial-import policy (docs/architecture/05 §1.3): a few bad records are quarantined and
/// reported; a file that is mostly garbage fails instead of importing nonsense. `unit` is
/// the source noun used in the copy ("element" for JSON, "line" for JSONL).
pub fn report_quarantine(
    rows: usize,
    quarantined: usize,
    unit: &str,
    warnings: &mut Vec<String>,
) -> Result<(), IngestError> {
    let allowance = (rows / 100).max(1000);
    if quarantined > allowance {
        return Err(IngestError::Json(format!(
            "{quarantined} of {} {unit}(s) were unreadable, over the quarantine allowance \
             of {allowance}; the file is too damaged to import",
            rows + quarantined
        )));
    }
    if quarantined > 0 {
        warnings.push(format!(
            "{quarantined} {unit}(s) were not readable JSON records and were quarantined."
        ));
    }
    Ok(())
}

/// Flatten one record into ordered `(path, value)` pairs. `None` means "not a record".
pub fn row_fields(v: &Value, notes: &mut Notes) -> Option<Vec<Field>> {
    let mut out = Vec::new();
    match v {
        Value::Object(map) if map.is_empty() => {
            out.push(("value".to_string(), Some("{}".to_string())));
            notes.empty_containers = true;
        }
        Value::Object(map) => {
            for (k, sub) in map {
                flatten(k, sub, 1, &mut out, notes);
            }
        }
        // An array where a record belongs has no defensible column interpretation.
        Value::Array(_) => return None,
        Value::Null => out.push(("value".to_string(), None)),
        scalar => {
            out.push(("value".to_string(), Some(scalar_text(scalar))));
            notes.scalars = true;
        }
    }
    Some(out)
}

fn flatten(key: &str, v: &Value, depth: usize, out: &mut Vec<Field>, notes: &mut Notes) {
    match v {
        Value::Object(map) if map.is_empty() => {
            out.push((key.to_string(), Some("{}".to_string())));
            notes.empty_containers = true;
        }
        Value::Object(map) if depth < MAX_DEPTH => {
            for (k, sub) in map {
                flatten(&format!("{key}.{k}"), sub, depth + 1, out, notes);
            }
        }
        Value::Object(_) => {
            out.push((key.to_string(), Some(compact(v))));
            notes.deep.insert(key.to_string());
        }
        Value::Array(items) => {
            if items.is_empty() {
                notes.empty_containers = true;
            }
            out.push((key.to_string(), Some(compact(v))));
            notes.arrays.insert(key.to_string());
        }
        Value::Null => out.push((key.to_string(), None)),
        scalar => out.push((key.to_string(), Some(scalar_text(scalar)))),
    }
}

fn compact(v: &Value) -> String {
    serde_json::to_string(v).unwrap_or_else(|_| "null".to_string())
}

/// JSON scalars as text for the shared type ladder. Strings are passed through verbatim —
/// no trimming, no null-token matching, because those would alter real JSON data.
fn scalar_text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        other => compact(other),
    }
}

/// Column names must be addressable: trimmed, never empty.
fn normalize_key(key: &str) -> String {
    let t = key.trim();
    if t.is_empty() {
        "field".to_string()
    } else {
        t.to_string()
    }
}

/// The union of all record shapes, in first-seen order, with absent keys back-filled null.
pub struct Grid {
    pub order: Vec<String>,
    index: HashMap<String, usize>,
    pub raw: Vec<Vec<String>>,
    pub nulls: Vec<Vec<bool>>,
    pub rows: usize,
    max_columns: usize,
    est_bytes: usize,
}

impl Grid {
    pub fn new(max_columns: usize) -> Self {
        Self {
            order: Vec::new(),
            index: HashMap::new(),
            raw: Vec::new(),
            nulls: Vec::new(),
            rows: 0,
            max_columns,
            est_bytes: 0,
        }
    }

    pub fn push(
        &mut self,
        fields: Vec<Field>,
        opts: &IngestOptions,
        notes: &mut Notes,
    ) -> Result<(), IngestError> {
        let mut seen_here: HashSet<String> = HashSet::new();
        let mut cells: Vec<(usize, Option<String>)> = Vec::with_capacity(fields.len());
        let mut renames = 0usize;

        for (key, value) in fields {
            let base = normalize_key(&key);
            let mut name = base.clone();
            let mut suffix = 2;
            // Two source keys can flatten to the same path (`{"a.b":1}` and `{"a":{"b":2}}`).
            while !seen_here.insert(name.clone()) {
                name = format!("{base}_{suffix}");
                suffix += 1;
                renames += 1;
            }
            // Entry API rather than get-then-insert: one lookup, and no clippy::map_entry.
            let idx = match self.index.entry(name) {
                Entry::Occupied(e) => *e.get(),
                Entry::Vacant(e) => {
                    let i = self.order.len();
                    if i >= self.max_columns {
                        return Err(IngestError::TooManyColumns {
                            limit: self.max_columns,
                            found: i + 1,
                        });
                    }
                    self.order.push(e.key().clone());
                    // A column first seen on row N is null for rows 0..N.
                    self.raw.push(vec![String::new(); self.rows]);
                    self.nulls.push(vec![true; self.rows]);
                    e.insert(i);
                    i
                }
            };
            cells.push((idx, value));
        }

        for (raw, nulls) in self.raw.iter_mut().zip(self.nulls.iter_mut()) {
            raw.push(String::new());
            nulls.push(true);
        }
        for (i, value) in cells {
            if let Some(text) = value {
                self.est_bytes += text.len();
                self.raw[i][self.rows] = text;
                self.nulls[i][self.rows] = false;
            }
        }
        self.rows += 1;

        if self.est_bytes > opts.max_memory_bytes {
            return Err(IngestError::ResourceLimit(format!(
                "the decoded columns exceed the {} MiB memory budget; import a sample \
                 or fewer fields",
                opts.max_memory_bytes / (1024 * 1024)
            )));
        }
        // Accumulated so the warning appears once for the file, not once per row.
        notes.renamed += renames;
        Ok(())
    }

    /// Run the shared type ladder over every column, reporting coercion per column.
    pub fn build_columns(&self, opts: &IngestOptions, warnings: &mut Vec<String>) -> Vec<Column> {
        let mut columns = Vec::with_capacity(self.order.len());
        for (i, name) in self.order.iter().enumerate() {
            let built =
                column::build_column(name, &self.raw[i], &self.nulls[i], opts.type_tolerance);
            if built.coerced > 0 {
                warnings.push(format!(
                    "Column '{}': {} value(s) did not parse as {} and were set to null \
                     ({:.1}% of values parsed).",
                    name,
                    built.coerced,
                    built.column.dtype.as_str(),
                    100.0 * built.parse_ratio
                ));
            }
            if let Some(note) = &built.note {
                warnings.push(format!("Column '{}': {}.", name, note));
            }
            columns.push(built.column);
        }
        columns
    }
}
