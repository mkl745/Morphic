//! # morphic-model
//!
//! Shared domain primitives for the MORPHIC engine. This crate is the bottom of the
//! dependency DAG: it performs **no I/O** and knows nothing about UI, Flutter, or files.
//!
//! Boundary (docs/architecture/01): values, columns, tables, field schemas, semantic
//! profiles, and provenance. Every other engine crate depends on these types.

use serde::{Deserialize, Serialize};

/// The physical types the Phase 1 columnar store understands.
///
/// Timestamp normalization to UTC milliseconds arrives in M1.1; for Phase 0 temporal
/// fields are detected as a *role* over `Utf8` data (see `morphic-semantic`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataType {
    Null,
    Bool,
    Int64,
    Float64,
    Utf8,
}

impl DataType {
    pub fn as_str(self) -> &'static str {
        match self {
            DataType::Null => "null",
            DataType::Bool => "bool",
            DataType::Int64 => "int64",
            DataType::Float64 => "float64",
            DataType::Utf8 => "utf8",
        }
    }
}

/// A typed, nullable column. Phase 0 stores values in simple `Vec`s with a parallel
/// null flag vector; the Arrow-shaped bitmap layout arrives with the query engine (M1.3).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Column {
    pub name: String,
    pub dtype: DataType,
    pub values: ColumnValues,
    /// `nulls[i] == true` means row `i` is null/missing.
    pub nulls: Vec<bool>,
}

impl Column {
    pub fn len(&self) -> usize {
        self.nulls.len()
    }
    pub fn is_empty(&self) -> bool {
        self.nulls.is_empty()
    }
}

/// Tagged column buffers. Keeping one variant per physical type makes the FFI mapping
/// (one bulk buffer per column per page) straightforward.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", content = "values")]
pub enum ColumnValues {
    Bool(Vec<bool>),
    Int64(Vec<i64>),
    Float64(Vec<f64>),
    Utf8(Vec<String>),
    /// All-null column (type could not be inferred).
    Null,
}

/// A materialized table: the output of ingestion and the input to semantics/query.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Table {
    pub columns: Vec<Column>,
    pub row_count: usize,
}

impl Table {
    pub fn field_names(&self) -> Vec<&str> {
        self.columns.iter().map(|c| c.name.as_str()).collect()
    }
}

/// Schema-level description of one field (name + inferred physical type).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FieldSchema {
    pub name: String,
    pub dtype: DataType,
    pub nullable: bool,
}

/// A semantic role hint. These are *interpretations*, not facts: they carry confidence
/// and evidence (docs/architecture/05 §3.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FieldRole {
    Unknown,
    Temporal,
    Measure,
    Dimension,
    Severity,
    Identifier,
    Text,
}

/// Provenance for an uncertain inference.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Inference {
    pub role: FieldRole,
    pub confidence: f64,
    pub evidence: Vec<String>,
}

/// Measured facts about one field (confidence is always 1.0 for facts).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldProfile {
    pub name: String,
    pub dtype: DataType,
    pub null_count: usize,
    pub distinct_count: usize,
    pub min: Option<String>,
    pub max: Option<String>,
    pub top_values: Vec<ValueCount>,
    pub inference: Inference,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ValueCount {
    pub value: String,
    pub count: usize,
}

/// The full semantic profile of a dataset: facts + role inferences per field.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DatasetProfile {
    pub row_count: usize,
    pub field_count: usize,
    pub fields: Vec<FieldProfile>,
}

/// A report returned alongside a successful import.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportReport {
    pub format: String,
    pub encoding: String,
    pub rows_imported: usize,
    pub rows_quarantined: usize,
    pub field_count: usize,
    pub warnings: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datatype_str_roundtrip() {
        assert_eq!(DataType::Int64.as_str(), "int64");
        assert_eq!(DataType::Utf8.as_str(), "utf8");
    }

    #[test]
    fn column_len_tracks_nulls() {
        let c = Column {
            name: "x".into(),
            dtype: DataType::Int64,
            values: ColumnValues::Int64(vec![1, 2, 3]),
            nulls: vec![false, true, false],
        };
        assert_eq!(c.len(), 3);
        assert!(!c.is_empty());
    }
}
