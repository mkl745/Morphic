//! # morphic-ingest
//!
//! Format detection and streaming parsers. **Phase 0 implements CSV only** — the
//! demonstrable data-processing proof of concept. JSON / JSONL / TXT / log parsers and
//! the full sniffing/encoding pipeline land in M1.1–M1.2 (docs/architecture/05).
//!
//! Boundary: produces a `Table` + `ImportReport`. It does not infer semantics or compile UI.

use morphic_model::{Column, ColumnValues, DataType, ImportReport, Table};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum IngestError {
    #[error("CSV parse error: {0}")]
    Csv(#[from] csv::Error),
    #[error("the file has no header row")]
    NoHeader,
    #[error("the file is empty")]
    Empty,
}

/// Parse CSV bytes into a columnar `Table` with per-column type inference.
///
/// Phase 0 policy (documented simplification of docs/architecture/05 §1):
/// * first row is the header; ragged rows are padded/truncated to the header width;
/// * empty cells are treated as null;
/// * a column is typed only if **all** non-null values parse as that type (the 95%
///   tolerance + quarantine policy arrives in M1.1);
/// * malformed CSV records are counted as quarantined, never fatal.
pub fn parse_csv(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    if bytes.is_empty() {
        return Err(IngestError::Empty);
    }
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(true)
        .flexible(true)
        .from_reader(bytes);

    let headers = reader.headers().map_err(IngestError::Csv)?.clone();
    let ncols = headers.len();
    if ncols == 0 {
        return Err(IngestError::NoHeader);
    }

    let mut raw_cols: Vec<Vec<String>> = vec![Vec::new(); ncols];
    let mut null_cols: Vec<Vec<bool>> = vec![Vec::new(); ncols];
    let mut rows = 0usize;
    let mut quarantined = 0usize;

    for record in reader.records() {
        match record {
            Ok(rec) => {
                rows += 1;
                for i in 0..ncols {
                    let cell = rec.get(i).unwrap_or("");
                    raw_cols[i].push(cell.to_string());
                    null_cols[i].push(cell.is_empty());
                }
            }
            Err(_) => quarantined += 1,
        }
    }

    let columns: Vec<Column> = headers
        .iter()
        .enumerate()
        .map(|(i, name)| infer_column(name, &raw_cols[i], &null_cols[i]))
        .collect();

    let table = Table { columns, row_count: rows };
    let report = ImportReport {
        format: "csv".into(),
        encoding: "utf-8".into(),
        rows_imported: rows,
        rows_quarantined: quarantined,
        field_count: ncols,
        warnings: Vec::new(),
    };
    Ok((table, report))
}

fn infer_column(name: &str, raw: &[String], nulls: &[bool]) -> Column {
    let non_null: Vec<&str> = raw
        .iter()
        .zip(nulls)
        .filter(|(_, &n)| !n)
        .map(|(s, _)| s.as_str())
        .collect();

    if non_null.is_empty() {
        return Column {
            name: name.to_string(),
            dtype: DataType::Null,
            values: ColumnValues::Null,
            nulls: nulls.to_vec(),
        };
    }

    // bool (restricted vocabulary so 0/1 integers are not misread as booleans)
    if non_null.iter().all(|s| {
        matches!(s.to_ascii_lowercase().as_str(), "true" | "false" | "yes" | "no")
    }) {
        let values = raw
            .iter()
            .zip(nulls)
            .map(|(s, &n)| {
                !n && matches!(s.to_ascii_lowercase().as_str(), "true" | "yes")
            })
            .collect();
        return Column {
            name: name.to_string(),
            dtype: DataType::Bool,
            values: ColumnValues::Bool(values),
            nulls: nulls.to_vec(),
        };
    }

    // int64
    if non_null.iter().all(|s| s.parse::<i64>().is_ok()) {
        let values = raw
            .iter()
            .zip(nulls)
            .map(|(s, &n)| if n { 0 } else { s.parse::<i64>().unwrap_or(0) })
            .collect();
        return Column {
            name: name.to_string(),
            dtype: DataType::Int64,
            values: ColumnValues::Int64(values),
            nulls: nulls.to_vec(),
        };
    }

    // float64
    if non_null.iter().all(|s| s.parse::<f64>().is_ok()) {
        let values = raw
            .iter()
            .zip(nulls)
            .map(|(s, &n)| if n { 0.0 } else { s.parse::<f64>().unwrap_or(0.0) })
            .collect();
        return Column {
            name: name.to_string(),
            dtype: DataType::Float64,
            values: ColumnValues::Float64(values),
            nulls: nulls.to_vec(),
        };
    }

    // utf8 fallback
    Column {
        name: name.to_string(),
        dtype: DataType::Utf8,
        values: ColumnValues::Utf8(raw.to_vec()),
        nulls: nulls.to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_mixed_types() {
        let csv = b"id,name,amount,active\n1,alice,10.5,true\n2,bob,20.0,false\n3,carol,30.25,true\n";
        let (table, report) = parse_csv(csv).unwrap();
        assert_eq!(table.row_count, 3);
        assert_eq!(report.field_count, 4);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
        assert_eq!(table.columns[1].dtype, DataType::Utf8);
        assert_eq!(table.columns[2].dtype, DataType::Float64);
        assert_eq!(table.columns[3].dtype, DataType::Bool);
    }

    #[test]
    fn empty_cells_are_null() {
        let csv = b"a,b\n1,x\n,\n3,z\n";
        let (table, _) = parse_csv(csv).unwrap();
        assert_eq!(table.columns[0].nulls, vec![false, true, false]);
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn integers_not_misread_as_bool() {
        let csv = b"flag\n0\n1\n1\n";
        let (table, _) = parse_csv(csv).unwrap();
        assert_eq!(table.columns[0].dtype, DataType::Int64);
    }

    #[test]
    fn empty_file_errors() {
        assert!(matches!(parse_csv(b""), Err(IngestError::Empty)));
    }

    #[test]
    fn header_only_is_zero_rows() {
        let (table, report) = parse_csv(b"a,b,c\n").unwrap();
        assert_eq!(table.row_count, 0);
        assert_eq!(report.rows_imported, 0);
    }
}
