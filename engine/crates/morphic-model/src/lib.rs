//! # morphic-model
//!
//! Shared domain primitives for the MORPHIC engine. This crate is the bottom of the
//! dependency DAG: it performs **no I/O** and knows nothing about UI, Flutter, or files.
//!
//! Boundary (docs/architecture/01): values, columns, tables, field schemas, semantic
//! profiles, and provenance. Every other engine crate depends on these types.

use serde::{Deserialize, Serialize};

pub mod temporal;

/// The physical types the Phase 1 columnar store understands.
///
/// `Timestamp` is **UTC milliseconds since the Unix epoch** (M1.1 task 1.1.2). Ingestion
/// normalizes to UTC and records the source format; values with no offset are *assumed*
/// UTC and that assumption is reported, never hidden.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DataType {
    Null,
    Bool,
    Int64,
    Float64,
    Utf8,
    Timestamp,
}

impl DataType {
    pub fn as_str(self) -> &'static str {
        match self {
            DataType::Null => "null",
            DataType::Bool => "bool",
            DataType::Int64 => "int64",
            DataType::Float64 => "float64",
            DataType::Utf8 => "utf8",
            DataType::Timestamp => "timestamp",
        }
    }

    /// True for types that support ordering and numeric aggregation.
    pub fn is_numeric(self) -> bool {
        matches!(self, DataType::Int64 | DataType::Float64)
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
    /// UTC milliseconds since the Unix epoch. Rows flagged in `Column::nulls` hold a
    /// placeholder (0) and must never be read as a real value.
    Timestamp(Vec<i64>),
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

/// Measured distribution facts for a numeric or temporal field (M1.1 task 1.1.2).
///
/// Quantiles are **exact** when the whole column fits the sample budget and **estimated**
/// otherwise; `sampled` tells the UI which, so an estimate is never presented as a fact.
/// The sampling scheme is systematic (every k-th non-null row), which is deterministic and
/// reproducible but can alias against periodic data — recorded as known debt.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NumericStats {
    /// Non-null values considered (the population, not the sample size).
    pub count: usize,
    pub mean: f64,
    /// Population standard deviation (0.0 when count < 2).
    pub std_dev: f64,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    /// True when quantiles were estimated from a sample rather than the full column.
    pub sampled: bool,
    /// How many values the quantiles were actually computed from.
    pub sample_size: usize,
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
    /// Distribution facts; `None` for non-numeric/non-temporal fields.
    pub stats: Option<NumericStats>,
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
        assert_eq!(DataType::Timestamp.as_str(), "timestamp");
    }

    #[test]
    fn timestamp_serializes_as_snake_case_and_utc_millis() {
        let json = serde_json::to_string(&DataType::Timestamp).unwrap();
        assert_eq!(json, "\"timestamp\"");
        let c = Column {
            name: "ts".into(),
            dtype: DataType::Timestamp,
            values: ColumnValues::Timestamp(vec![0, 1_700_000_000_000]),
            nulls: vec![false, false],
        };
        let json = serde_json::to_string(&c).unwrap();
        assert!(json.contains("\"kind\":\"Timestamp\""), "{json}");
        let back: Column = serde_json::from_str(&json).unwrap();
        assert_eq!(back.dtype, DataType::Timestamp);
        assert_eq!(back.len(), 2);
    }

    #[test]
    fn only_int_and_float_are_numeric() {
        assert!(DataType::Int64.is_numeric());
        assert!(DataType::Float64.is_numeric());
        // Timestamps are ordered but are NOT measures; they must not become metrics.
        assert!(!DataType::Timestamp.is_numeric());
        assert!(!DataType::Utf8.is_numeric());
        assert!(!DataType::Bool.is_numeric());
        assert!(!DataType::Null.is_numeric());
    }

    #[test]
    fn stats_is_omitted_when_absent_but_roundtrips_when_present() {
        let s = NumericStats {
            count: 10,
            mean: 5.0,
            std_dev: 2.0,
            p50: 5.0,
            p95: 9.0,
            p99: 10.0,
            sampled: false,
            sample_size: 10,
        };
        let json = serde_json::to_string(&s).unwrap();
        assert!(json.contains("\"stdDev\""), "{json}");
        assert!(json.contains("\"sampleSize\""), "{json}");
        let back: NumericStats = serde_json::from_str(&json).unwrap();
        assert_eq!(back.count, 10);
        assert!(!back.sampled);
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
