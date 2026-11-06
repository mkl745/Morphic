//! JSON ingestion (M1.2 task 1.2.1).
//!
//! # Shapes
//!
//! | Input | Result |
//! |---|---|
//! | `[{…}, {…}]` | one row per element (the common API/export shape) |
//! | `{…}` | a single row |
//! | `[1, 2, 3]` | one `value` column, one row per scalar |
//! | `42` / `"text"` | a single row with a `value` column |
//!
//! An array element that is itself an array is quarantined rather than guessed at; a
//! ragged union of object keys is normal and missing keys become null.
//!
//! # Bounded memory
//!
//! The whole document is **never** turned into a `serde_json::Value` tree when the top level
//! is an array — that is roughly 5–10× the file size and would defeat the 256 MB gate on a
//! 4 GB phone. [`ArrayElements`] walks the text once, tracking string/escape state and
//! nesting depth, and yields one element slice at a time. Peak parse memory is the largest
//! single element, not the file. A single top-level object is parsed whole, which the byte
//! gate already bounds.
//!
//! Two gates apply: `max_import_bytes` on the input, and `max_memory_bytes` on the estimated
//! size of the columnar text actually retained. Both fail with [`IngestError::ResourceLimit`]
//! and an actionable message rather than approaching OOM.
//!
//! # Flattening
//!
//! Nested objects become dotted paths (`user.city`). Depth is capped at [`MAX_DEPTH`] = 4.
//! **Nothing is dropped**: a subtree deeper than the cap, and any array value, is retained as
//! compact JSON text in that column, with one warning per affected column. Empty objects and
//! arrays are kept as `{}` / `[]` so the field's existence survives.
//!
//! # Typing
//!
//! Scalars are rendered to text and handed to the shared [`crate::column::build_column`]
//! ladder, so JSON and CSV agree on types and — importantly — ISO-8601 strings from JSON APIs
//! become real timestamps. The one deliberate difference from CSV: **nulls come only from
//! JSON `null` or an absent key**. The CSV null-token vocabulary is not applied, so the
//! string `"null"` stays a string and `""` stays an empty string. Applying CSV's vocabulary
//! here would silently destroy real JSON values.
//!
//! # Column order (a known limitation)
//!
//! Columns are ordered first-seen *across* rows, but **within** a record `serde_json`'s
//! default `Map` is a `BTreeMap`, so keys arrive **sorted, not in file order**. The result is
//! deterministic for a given file, but `{"date":…,"open":…,"close":…}` yields
//! `close, date, open`. Preserving source order is logged as debt for 1.2.4: it needs a local
//! order-tracking deserializer, because enabling `serde_json/preserve_order` workspace-wide
//! would reorder every serialized document and break the schema and compiler goldens.

use morphic_model::{ImportReport, Table};
use serde_json::Value;

use crate::records::{check_cancel, report_quarantine, row_fields, Grid, Notes};
use crate::{decode, CancelToken, IngestError, IngestOptions, Phase, Progress};

pub use crate::records::MAX_DEPTH;

/// Parse JSON bytes with default options and no progress/cancellation.
pub fn parse_json(bytes: &[u8]) -> Result<(Table, ImportReport), IngestError> {
    parse_json_with(bytes, &IngestOptions::default(), None, &mut |_| {})
}

/// Parse JSON bytes with explicit options, optional cancellation, and progress events.
pub fn parse_json_with(
    bytes: &[u8],
    opts: &IngestOptions,
    cancel: Option<&CancelToken>,
    progress: &mut dyn FnMut(Progress),
) -> Result<(Table, ImportReport), IngestError> {
    if bytes.is_empty() {
        return Err(IngestError::Empty);
    }
    if bytes.len() > opts.max_import_bytes {
        return Err(IngestError::ResourceLimit(format!(
            "the file is {} MiB, over the {} MiB import limit; import a sample instead",
            bytes.len() / (1024 * 1024),
            opts.max_import_bytes / (1024 * 1024)
        )));
    }
    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Sniffing,
        rows_read: 0,
        bytes_read: 0,
    });

    let decoded = decode::decode(bytes);
    let text = decoded.text;
    if text.trim().is_empty() {
        return Err(IngestError::Empty);
    }
    let mut warnings = decoded.warnings;
    let total_bytes = text.len() as u64;

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Parsing,
        rows_read: 0,
        bytes_read: 0,
    });

    let mut grid = Grid::new(opts.max_columns);
    let mut notes = Notes::default();
    let mut quarantined = 0usize;
    let lead = text.trim_start();
    let open_at = text.len() - lead.len();

    if lead.starts_with('[') {
        let mut scan = ArrayElements::new(&text, open_at);
        let mut seen = 0usize;
        for item in scan.by_ref() {
            let element = item?;
            seen += 1;
            match serde_json::from_str::<Value>(element.src) {
                Ok(v) => match row_fields(&v, &mut notes) {
                    Some(fields) => {
                        grid.push(fields, opts, &mut notes)?;
                    }
                    None => quarantined += 1,
                },
                // One malformed element does not discard the rows already read.
                Err(_) => quarantined += 1,
            }
            if grid.rows > opts.max_rows {
                return Err(IngestError::TooManyRows {
                    limit: opts.max_rows,
                });
            }
            if seen % 4096 == 0 {
                check_cancel(cancel)?;
                progress(Progress {
                    phase: Phase::Parsing,
                    rows_read: grid.rows,
                    bytes_read: element.consumed.min(text.len()) as u64,
                });
            }
        }
        if scan.trailing_comma {
            warnings.push(
                "The JSON array had a trailing comma; it was accepted, but the file is not \
                 strictly valid JSON."
                    .into(),
            );
        }
        let rest = text[scan.end().min(text.len())..].trim();
        if !rest.is_empty() {
            warnings.push(format!(
                "{} byte(s) of content after the closing ']' were ignored.",
                rest.len()
            ));
        }
    } else {
        let v: Value = serde_json::from_str(text.trim())
            .map_err(|e| IngestError::Json(format!("the file is not valid JSON: {e}")))?;
        if let Value::Object(map) = &v {
            // A very common export shape is {"data": [...], "meta": {...}}. Guessing which
            // array the user meant would be wrong often enough to be harmful, so the object
            // is imported as one row and the user is told what was seen.
            let wrappers: Vec<&str> = map
                .iter()
                .filter(|(_, sub)| match sub {
                    Value::Array(items) => items.len() > 1 && items.iter().all(|i| i.is_object()),
                    _ => false,
                })
                .map(|(k, _)| k.as_str())
                .collect();
            if !wrappers.is_empty() {
                warnings.push(format!(
                    "This file is a single JSON object, so it became one row. Field(s) {} \
                     hold arrays of records; extract one of them to import those as rows.",
                    wrappers.join(", ")
                ));
            }
        }
        match row_fields(&v, &mut notes) {
            Some(fields) => grid.push(fields, opts, &mut notes)?,
            None => {
                return Err(IngestError::Json(
                    "a bare JSON array nested in this position is not a record".into(),
                ))
            }
        }
    }

    if grid.rows == 0 {
        if quarantined > 0 {
            return Err(IngestError::Json(format!(
                "none of the {quarantined} array element(s) could be read as records"
            )));
        }
        return Err(IngestError::Empty);
    }

    report_quarantine(grid.rows, quarantined, "element", &mut warnings)?;
    notes.extend_warnings("array", &mut warnings);

    check_cancel(cancel)?;
    progress(Progress {
        phase: Phase::Typing,
        rows_read: grid.rows,
        bytes_read: total_bytes,
    });

    let columns = grid.build_columns(opts, &mut warnings);

    let report = ImportReport {
        format: "json".into(),
        encoding: decoded.encoding,
        rows_imported: grid.rows,
        rows_quarantined: quarantined,
        field_count: grid.order.len(),
        warnings,
    };
    progress(Progress {
        phase: Phase::Done,
        rows_read: grid.rows,
        bytes_read: total_bytes,
    });
    Ok((
        Table {
            columns,
            row_count: grid.rows,
        },
        report,
    ))
}

/// A forward-only scanner over a top-level JSON array.
///
/// Yields one element's source slice at a time so peak memory is one element, not the file.
/// Tracks string and escape state so brackets and commas inside strings are not structure.
struct ArrayElements<'a> {
    src: &'a str,
    i: usize,
    closed: bool,
    failed: bool,
    after_comma: bool,
    trailing_comma: bool,
}

impl<'a> ArrayElements<'a> {
    /// `open` is the byte index of the array's `[`.
    fn new(src: &'a str, open: usize) -> Self {
        Self {
            src,
            i: open + 1,
            closed: false,
            failed: false,
            after_comma: false,
            trailing_comma: false,
        }
    }

    /// Byte index just past the closing `]`, for trailing-content detection.
    fn end(&self) -> usize {
        self.i
    }

    fn skip_ws(&mut self) {
        let b = self.src.as_bytes();
        while self.i < b.len() && matches!(b[self.i], b' ' | b'\t' | b'\n' | b'\r') {
            self.i += 1;
        }
    }

    fn fail(&mut self, msg: &str) -> Option<Result<Element<'a>, IngestError>> {
        self.failed = true;
        Some(Err(IngestError::Json(msg.to_string())))
    }
}

/// One array element, plus how much of the input has been consumed to reach past it.
/// Carrying the offset here is what lets the parse loop report progress without borrowing
/// the scanner it is iterating.
struct Element<'a> {
    src: &'a str,
    consumed: usize,
}

impl<'a> Iterator for ArrayElements<'a> {
    type Item = Result<Element<'a>, IngestError>;

    fn next(&mut self) -> Option<Self::Item> {
        if self.closed || self.failed {
            return None;
        }
        let b = self.src.as_bytes();
        self.skip_ws();
        if self.i >= b.len() {
            return self.fail("the JSON array is never closed");
        }
        if b[self.i] == b']' {
            self.trailing_comma = self.after_comma;
            self.closed = true;
            self.i += 1;
            return None;
        }
        if b[self.i] == b',' {
            return self.fail("unexpected comma in the JSON array");
        }

        let start = self.i;
        let mut depth: i32 = 0;
        let mut in_string = false;
        let mut escaped = false;
        while self.i < b.len() {
            let c = b[self.i];
            if in_string {
                if escaped {
                    escaped = false;
                } else if c == b'\\' {
                    escaped = true;
                } else if c == b'"' {
                    in_string = false;
                }
            } else {
                match c {
                    b'"' => in_string = true,
                    b'{' | b'[' => depth += 1,
                    b'}' => depth -= 1,
                    b']' if depth == 0 => break,
                    b']' => depth -= 1,
                    b',' if depth == 0 => break,
                    _ => {}
                }
            }
            self.i += 1;
        }

        if self.i >= b.len() {
            return self.fail("the JSON array is never closed");
        }
        if in_string {
            return self.fail("an element contains an unterminated string");
        }
        let end = self.i;
        if end == start {
            return self.fail("an empty element is not a JSON value");
        }
        self.after_comma = b[self.i] == b',';
        if self.after_comma {
            self.i += 1;
        }
        let src: &'a str = self.src;
        Some(Ok(Element {
            src: src[start..end].trim(),
            consumed: self.i,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use morphic_model::{Column, ColumnValues, DataType};

    fn parse(s: &str) -> (Table, ImportReport) {
        parse_json(s.as_bytes()).unwrap_or_else(|e| panic!("failed on {s}: {e}"))
    }

    fn col<'a>(t: &'a Table, name: &str) -> &'a Column {
        t.columns
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("no column '{name}' in {:?}", t.field_names()))
    }

    fn texts<'a>(t: &'a Table, name: &str) -> Vec<&'a str> {
        match &col(t, name).values {
            ColumnValues::Utf8(v) => v.iter().map(|s| s.as_str()).collect(),
            other => panic!("'{name}' is not Utf8: {other:?}"),
        }
    }

    fn names(t: &Table) -> Vec<&str> {
        t.columns.iter().map(|c| c.name.as_str()).collect()
    }

    fn warned(r: &ImportReport, needle: &str) -> bool {
        r.warnings.iter().any(|w| w.contains(needle))
    }

    // ---------------------------------------------------------------- shapes

    #[test]
    fn array_of_objects_becomes_rows() {
        let (t, r) = parse(r#"[{"id":1,"host":"a"},{"id":2,"host":"b"}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(names(&t), vec!["host", "id"]); // sorted within a record; see below
        assert_eq!(col(&t, "id").dtype, DataType::Int64);
        assert_eq!(col(&t, "host").dtype, DataType::Utf8);
        assert_eq!(r.format, "json");
        assert_eq!(r.rows_imported, 2);
        assert_eq!(r.rows_quarantined, 0);
        assert_eq!(r.field_count, 2);
    }

    #[test]
    fn single_object_becomes_one_row() {
        let (t, r) = parse(r#"{"id":7,"host":"solo"}"#);
        assert_eq!(t.row_count, 1);
        assert_eq!(texts(&t, "host"), vec!["solo"]);
        assert_eq!(r.rows_imported, 1);
    }

    #[test]
    fn array_of_scalars_becomes_a_value_column() {
        let (t, r) = parse("[3, 1, 2]");
        assert_eq!(t.row_count, 3);
        assert_eq!(names(&t), vec!["value"]);
        assert_eq!(col(&t, "value").dtype, DataType::Int64);
        assert!(warned(&r, "single 'value' column"));
    }

    #[test]
    fn top_level_scalar_becomes_one_row() {
        let (t, _) = parse("42");
        assert_eq!(t.row_count, 1);
        assert_eq!(names(&t), vec!["value"]);
        assert_eq!(col(&t, "value").dtype, DataType::Int64);
    }

    #[test]
    fn top_level_string_is_preserved_verbatim() {
        let (t, _) = parse("\"  keep my spaces  \"");
        assert_eq!(texts(&t, "value"), vec!["  keep my spaces  "]);
    }

    #[test]
    fn empty_array_is_empty_not_a_crash() {
        assert!(matches!(parse_json(b"[]"), Err(IngestError::Empty)));
        assert!(matches!(parse_json(b"  [ \n ]  "), Err(IngestError::Empty)));
    }

    #[test]
    fn empty_object_keeps_a_visible_field() {
        let (t, r) = parse("{}");
        assert_eq!(t.row_count, 1);
        assert_eq!(texts(&t, "value"), vec!["{}"]);
        assert!(warned(&r, "Empty objects"));
    }

    #[test]
    fn array_elements_that_are_arrays_are_quarantined_not_guessed() {
        let (t, r) = parse(r#"[{"a":1},[9,9],{"a":3}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 1);
        assert!(warned(&r, "quarantined"));
    }

    #[test]
    fn an_array_of_only_arrays_fails_with_a_reason() {
        let err = parse_json(b"[[1,2],[3,4]]").unwrap_err();
        match err {
            IngestError::Json(m) => assert!(m.contains("could be read as records"), "{m}"),
            other => panic!("wrong error: {other}"),
        }
    }

    #[test]
    fn wrapper_object_is_imported_as_one_row_and_explained() {
        let (t, r) = parse(r#"{"data":[{"x":1},{"x":2}],"count":2}"#);
        assert_eq!(t.row_count, 1);
        assert!(names(&t).contains(&"data"));
        assert!(warned(&r, "single JSON object"), "{:?}", r.warnings);
        assert!(warned(&r, "data"));
    }

    #[test]
    fn a_single_element_array_field_is_not_mistaken_for_a_wrapper() {
        let (_, r) = parse(r#"{"data":[{"x":1}]}"#);
        assert!(!warned(&r, "single JSON object"));
    }

    // ------------------------------------------------------------ flattening

    #[test]
    fn nested_objects_become_dotted_paths() {
        let (t, _) = parse(r#"[{"user":{"city":"Oslo","geo":{"lat":59.9}}}]"#);
        assert_eq!(names(&t), vec!["user.city", "user.geo.lat"]);
        assert_eq!(texts(&t, "user.city"), vec!["Oslo"]);
        assert_eq!(col(&t, "user.geo.lat").dtype, DataType::Float64);
    }

    #[test]
    fn depth_four_is_flattened_all_the_way() {
        let (t, r) = parse(r#"{"a":{"b":{"c":{"d":1}}}}"#);
        assert_eq!(names(&t), vec!["a.b.c.d"]);
        assert!(!warned(&r, "deeper than"));
    }

    #[test]
    fn depth_five_is_kept_as_json_text_with_a_warning() {
        let (t, r) = parse(r#"{"a":{"b":{"c":{"d":{"e":1}}}}}"#);
        assert_eq!(names(&t), vec!["a.b.c.d"]);
        assert_eq!(col(&t, "a.b.c.d").dtype, DataType::Utf8);
        assert_eq!(texts(&t, "a.b.c.d"), vec![r#"{"e":1}"#]);
        assert!(warned(&r, "deeper than 4 levels"), "{:?}", r.warnings);
    }

    #[test]
    fn array_values_are_kept_as_json_text() {
        let (t, r) = parse(r#"[{"tags":["x","y"]},{"tags":["z"]}]"#);
        assert_eq!(col(&t, "tags").dtype, DataType::Utf8);
        assert_eq!(texts(&t, "tags"), vec![r#"["x","y"]"#, r#"["z"]"#]);
        assert!(warned(&r, "holds JSON arrays"));
    }

    #[test]
    fn an_array_of_objects_inside_a_field_is_not_silently_dropped() {
        let (t, _) = parse(r#"{"items":[{"sku":"a","qty":2}]}"#);
        assert_eq!(texts(&t, "items"), vec![r#"[{"qty":2,"sku":"a"}]"#]);
    }

    #[test]
    fn empty_containers_do_not_make_the_field_vanish() {
        let (t, r) = parse(r#"[{"o":{},"a":[]},{"o":{"k":1},"a":[1]}]"#);
        assert!(names(&t).contains(&"o"));
        assert!(names(&t).contains(&"a"));
        assert!(warned(&r, "Empty objects"));
    }

    #[test]
    fn one_warning_per_affected_column_not_per_row() {
        let src = format!("[{}]", vec![r#"{"tags":["x"]}"#; 500].join(","));
        let (_, r) = parse(&src);
        let n = r
            .warnings
            .iter()
            .filter(|w| w.contains("holds JSON arrays"))
            .count();
        assert_eq!(n, 1, "{:?}", r.warnings);
    }

    // ----------------------------------------------------------------- nulls

    #[test]
    fn json_null_is_a_null() {
        let (t, _) = parse(r#"[{"a":null},{"a":1}]"#);
        assert!(col(&t, "a").nulls[0]);
        assert!(!col(&t, "a").nulls[1]);
    }

    #[test]
    fn absent_keys_are_back_filled_as_null_in_both_directions() {
        let (t, _) = parse(r#"[{"a":1},{"b":2},{"a":3,"b":4}]"#);
        assert_eq!(names(&t), vec!["a", "b"]);
        assert_eq!(col(&t, "a").nulls, vec![false, true, false]);
        assert_eq!(col(&t, "b").nulls, vec![true, false, false]);
        assert_eq!(col(&t, "b").dtype, DataType::Int64);
        match &col(&t, "a").values {
            ColumnValues::Int64(v) => assert_eq!(*v, [1, 0, 3]),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn the_csv_null_vocabulary_is_not_applied_to_json_strings() {
        // "null", "N/A" and "" are real data in JSON. Only JSON null / absent keys are null.
        let (t, _) = parse(r#"[{"a":"null"},{"a":"N/A"},{"a":""},{"a":null}]"#);
        assert_eq!(col(&t, "a").dtype, DataType::Utf8);
        assert_eq!(texts(&t, "a"), vec!["null", "N/A", "", ""]);
        assert_eq!(col(&t, "a").nulls, vec![false, false, false, true]);
    }

    #[test]
    fn an_all_null_column_is_typed_null() {
        let (t, _) = parse(r#"[{"a":null},{"a":null}]"#);
        assert_eq!(col(&t, "a").dtype, DataType::Null);
    }

    // ----------------------------------------------------------------- names

    #[test]
    fn blank_and_padded_keys_become_addressable_names() {
        let (t, _) = parse(r#"{"  ":"x","  padded  ":"y"}"#);
        assert!(names(&t).contains(&"field"), "{:?}", names(&t));
        assert!(names(&t).contains(&"padded"), "{:?}", names(&t));
    }

    #[test]
    fn flattening_collisions_are_suffixed_and_disclosed() {
        let (t, r) = parse(r#"{"a.b":1,"a":{"b":2}}"#);
        assert_eq!(t.columns.len(), 2);
        assert!(names(&t).contains(&"a.b"));
        assert!(names(&t).contains(&"a.b_2"), "{:?}", names(&t));
        assert!(warned(&r, "collided after flattening"));
    }

    #[test]
    fn keys_within_a_record_are_sorted_not_file_order() {
        // Pins the documented limitation. If a future order-tracking deserializer lands,
        // this test must be updated deliberately, not accidentally.
        let (t, _) = parse(r#"[{"date":"2024-01-01","open":1,"close":2}]"#);
        assert_eq!(names(&t), vec!["close", "date", "open"]);
    }

    #[test]
    fn union_order_is_deterministic_across_runs() {
        let src = r#"[{"z":1,"a":2},{"m":3,"a":4}]"#;
        let (t1, _) = parse(src);
        let (t2, _) = parse(src);
        assert_eq!(names(&t1), names(&t2));
        assert_eq!(names(&t1), vec!["a", "z", "m"]);
    }

    // ---------------------------------------------------------------- typing

    #[test]
    fn iso_strings_from_apis_become_timestamps() {
        let (t, _) = parse(r#"[{"at":"2024-01-01T05:00:00Z"},{"at":"2024-01-02T06:00:00Z"}]"#);
        assert_eq!(col(&t, "at").dtype, DataType::Timestamp);
    }

    #[test]
    fn json_booleans_stay_booleans() {
        let (t, _) = parse(r#"[{"ok":true},{"ok":false}]"#);
        assert_eq!(col(&t, "ok").dtype, DataType::Bool);
    }

    #[test]
    fn zero_one_flags_stay_integers() {
        let (t, _) = parse(r#"[{"flag":0},{"flag":1}]"#);
        assert_eq!(col(&t, "flag").dtype, DataType::Int64);
    }

    #[test]
    fn mixed_int_and_float_widens_to_float() {
        let (t, _) = parse(r#"[{"v":1},{"v":2.5}]"#);
        assert_eq!(col(&t, "v").dtype, DataType::Float64);
    }

    #[test]
    fn tolerance_coercion_is_reported_per_column() {
        let mut rows: Vec<String> = (0..100).map(|i| format!(r#"{{"v":{i}}}"#)).collect();
        rows.push(r#"{"v":"oops"}"#.to_string());
        let (t, r) = parse(&format!("[{}]", rows.join(",")));
        assert_eq!(col(&t, "v").dtype, DataType::Int64);
        assert!(col(&t, "v").nulls[100]);
        assert!(warned(&r, "Column 'v'"), "{:?}", r.warnings);
    }

    #[test]
    fn big_integers_are_not_silently_rounded() {
        let (t, _) = parse(r#"[{"v":9007199254740993},{"v":9007199254740992}]"#);
        assert_eq!(col(&t, "v").dtype, DataType::Int64);
        match &col(&t, "v").values {
            ColumnValues::Int64(v) => assert_eq!(v[0], 9_007_199_254_740_993),
            other => panic!("{other:?}"),
        }
    }

    // ------------------------------------------------------- scanner details

    #[test]
    fn delimiters_inside_strings_are_not_structure() {
        let (t, _) = parse(r#"[{"a":"x,y[z]{q}"},{"a":"plain"}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(texts(&t, "a"), vec!["x,y[z]{q}", "plain"]);
    }

    #[test]
    fn escaped_quotes_and_backslashes_survive_the_scan() {
        let (t, _) = parse(r#"[{"a":"he said \"hi, there\" [ok]"},{"a":"trail\\"}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(
            texts(&t, "a"),
            vec!["he said \"hi, there\" [ok]", "trail\\"]
        );
    }

    #[test]
    fn nested_arrays_inside_objects_do_not_split_elements() {
        let (t, _) = parse(r#"[{"m":[[1,2],[3,4]],"n":{"deep":[5,6]}},{"m":[[7]]}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(texts(&t, "m"), vec!["[[1,2],[3,4]]", "[[7]]"]);
    }

    #[test]
    fn whitespace_and_newlines_between_elements_are_fine() {
        let (t, _) = parse("[\n\t{ \"a\" : 1 }\r\n ,\n { \"a\" : 2 }\n]\n");
        assert_eq!(t.row_count, 2);
    }

    #[test]
    fn unicode_and_escapes_round_trip() {
        let (t, _) = parse(r#"[{"s":"café 東京"},{"s":"\u00e9\u0041"}]"#);
        assert_eq!(texts(&t, "s"), vec!["café 東京", "éA"]);
    }

    #[test]
    fn a_trailing_comma_is_accepted_but_disclosed() {
        let (t, r) = parse(r#"[{"a":1},{"a":2},]"#);
        assert_eq!(t.row_count, 2);
        assert!(warned(&r, "trailing comma"));
    }

    #[test]
    fn content_after_the_array_is_disclosed_not_ignored_silently() {
        let (t, r) = parse(r#"[{"a":1}] trailing junk"#);
        assert_eq!(t.row_count, 1);
        assert!(warned(&r, "after the closing ']'"));
    }

    // ----------------------------------------------------------- malformed

    #[test]
    fn a_non_json_document_is_a_typed_error() {
        let err = parse_json(b"name,age\nalice,30\n").unwrap_err();
        assert!(matches!(err, IngestError::Json(_)), "{err}");
    }

    #[test]
    fn an_unclosed_array_is_a_typed_error() {
        assert!(matches!(
            parse_json(br#"[{"a":1},{"a":2}"#),
            Err(IngestError::Json(_))
        ));
        assert!(matches!(
            parse_json(br#"[{"a":1},{"a":"#),
            Err(IngestError::Json(_))
        ));
    }

    #[test]
    fn a_leading_or_doubled_comma_is_a_typed_error() {
        assert!(matches!(parse_json(b"[,1]"), Err(IngestError::Json(_))));
        assert!(matches!(parse_json(b"[1,,2]"), Err(IngestError::Json(_))));
    }

    #[test]
    fn one_broken_element_does_not_discard_the_good_rows() {
        let (t, r) = parse(r#"[{"a":1},{"a":},{"a":3}]"#);
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 1);
        assert!(warned(&r, "not readable JSON records"));
    }

    #[test]
    fn a_mostly_broken_file_fails_instead_of_importing_nonsense() {
        let src = format!("[{}{{\"a\":1}}]", "[0],".repeat(1500));
        let err = parse_json(src.as_bytes()).unwrap_err();
        match err {
            IngestError::Json(m) => assert!(m.contains("quarantine allowance"), "{m}"),
            other => panic!("wrong error: {other}"),
        }
    }

    #[test]
    fn a_recursion_bomb_is_quarantined_without_overflowing_the_stack() {
        // serde_json refuses nesting past its own limit; we must survive that as a bad row.
        let bomb = format!("{}1{}", "{\"a\":".repeat(400), "}".repeat(400));
        let src = format!(r#"[{{"a":1}},{bomb},{{"a":2}}]"#);
        let (t, r) = parse(&src);
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 1);
    }

    #[test]
    fn empty_and_whitespace_only_input_is_empty() {
        assert!(matches!(parse_json(b""), Err(IngestError::Empty)));
        assert!(matches!(parse_json(b"   \n\t "), Err(IngestError::Empty)));
    }

    // --------------------------------------------------------------- gates

    #[test]
    fn the_byte_gate_refuses_before_parsing() {
        let opts = IngestOptions {
            max_import_bytes: 16,
            ..Default::default()
        };
        let err = parse_json_with(br#"[{"a":1},{"a":2}]"#, &opts, None, &mut |_| {}).unwrap_err();
        match err {
            IngestError::ResourceLimit(m) => assert!(m.contains("import a sample"), "{m}"),
            other => panic!("wrong error: {other}"),
        }
    }

    #[test]
    fn the_memory_gate_aborts_on_retained_text() {
        let opts = IngestOptions {
            max_memory_bytes: 64,
            ..Default::default()
        };
        let src = format!("[{}]", vec![r#"{"a":"0123456789"}"#; 20].join(","));
        let err = parse_json_with(src.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
        assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");
    }

    #[test]
    fn the_row_gate_is_enforced() {
        let opts = IngestOptions {
            max_rows: 2,
            ..Default::default()
        };
        let err = parse_json_with(b"[1,2,3]", &opts, None, &mut |_| {}).unwrap_err();
        assert!(
            matches!(err, IngestError::TooManyRows { limit: 2 }),
            "{err}"
        );
    }

    #[test]
    fn the_column_gate_counts_the_union_not_one_record() {
        let opts = IngestOptions {
            max_columns: 2,
            ..Default::default()
        };
        let err =
            parse_json_with(br#"[{"a":1},{"b":2},{"c":3}]"#, &opts, None, &mut |_| {}).unwrap_err();
        assert!(
            matches!(err, IngestError::TooManyColumns { limit: 2, .. }),
            "{err}"
        );
    }

    #[test]
    fn cancellation_is_honoured_before_work_starts() {
        let token = CancelToken::new();
        token.cancel();
        let err = parse_json_with(
            b"[1,2,3]",
            &IngestOptions::default(),
            Some(&token),
            &mut |_| {},
        )
        .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled), "{err}");
    }

    #[test]
    fn cancellation_is_honoured_mid_stream() {
        let token = CancelToken::new();
        let mut calls = 0usize;
        let src = format!("[{}]", vec![r#"{"a":1}"#; 20_000].join(","));
        let err = parse_json_with(
            src.as_bytes(),
            &IngestOptions::default(),
            Some(&token),
            &mut |_| {
                calls += 1;
                if calls == 2 {
                    token.cancel();
                }
            },
        )
        .unwrap_err();
        assert!(matches!(err, IngestError::Cancelled), "{err}");
    }

    #[test]
    fn progress_runs_through_every_phase_in_order() {
        let mut phases = Vec::new();
        parse_json_with(
            br#"[{"a":1},{"a":2}]"#,
            &IngestOptions::default(),
            None,
            &mut |p| {
                if phases.last() != Some(&p.phase) {
                    phases.push(p.phase);
                }
            },
        )
        .unwrap();
        assert_eq!(
            phases,
            vec![Phase::Sniffing, Phase::Parsing, Phase::Typing, Phase::Done]
        );
    }

    #[test]
    fn progress_bytes_never_exceed_the_input() {
        let src = br#"[{"a":1},{"a":2}]"#;
        parse_json_with(src, &IngestOptions::default(), None, &mut |p| {
            assert!(p.bytes_read <= src.len() as u64, "{p:?}");
        })
        .unwrap();
    }

    // ------------------------------------------------------------ encodings

    #[test]
    fn a_utf8_bom_does_not_hide_the_array() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(br#"[{"a":1}]"#);
        let (t, r) = parse_json(&bytes).unwrap();
        assert_eq!(t.row_count, 1);
        assert_eq!(r.encoding, "utf-8");
    }

    #[test]
    fn utf16_json_is_decoded_and_disclosed() {
        let src = r#"[{"a":"é"}]"#;
        let mut bytes = vec![0xFF, 0xFE];
        for unit in src.encode_utf16() {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        let (t, r) = parse_json(&bytes).unwrap();
        assert_eq!(texts(&t, "a"), vec!["é"]);
        assert!(r.encoding.contains("16"), "{}", r.encoding);
    }

    // ------------------------------------------------------------- fixtures

    const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../fixtures");

    fn fixture(rel: &str) -> Vec<u8> {
        std::fs::read(format!("{FIXTURES}/{rel}")).expect("fixture present")
    }

    #[test]
    fn fixture_records_json() {
        let (t, r) = parse_json(&fixture("valid/records.json")).unwrap();
        assert_eq!(t.row_count, 4);
        assert_eq!(r.field_count, 4);
        assert_eq!(col(&t, "id").dtype, DataType::Int64);
        assert_eq!(col(&t, "metric").dtype, DataType::Utf8);
        assert_eq!(col(&t, "value").dtype, DataType::Float64);
    }

    #[test]
    fn fixture_nested_json() {
        let (t, r) = parse_json(&fixture("valid/nested.json")).unwrap();
        assert_eq!(t.row_count, 3);
        assert!(names(&t).contains(&"user.city"));
        assert!(names(&t).contains(&"a.b.c.d"));
        assert!(warned(&r, "holds JSON arrays"));
        assert!(warned(&r, "deeper than 4 levels"));
    }

    #[test]
    fn fixture_single_object_json() {
        let (t, r) = parse_json(&fixture("valid/single_object.json")).unwrap();
        assert_eq!(t.row_count, 1);
        assert_eq!(
            names(&t),
            vec![
                "healthy",
                "limits.burst",
                "limits.rpm",
                "service",
                "version"
            ]
        );
        assert_eq!(col(&t, "healthy").dtype, DataType::Bool);
        assert_eq!(col(&t, "limits.rpm").dtype, DataType::Int64);
        assert_eq!(r.rows_imported, 1);
    }

    #[test]
    fn fixture_bad_element_keeps_the_good_rows() {
        let (t, r) = parse_json(&fixture("malformed/bad_element.json")).unwrap();
        assert_eq!(t.row_count, 2);
        assert_eq!(r.rows_quarantined, 1);
        assert_eq!(col(&t, "id").dtype, DataType::Int64);
        match &col(&t, "id").values {
            ColumnValues::Int64(v) => assert_eq!(*v, [1, 3]),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn fixture_truncated_json_is_a_typed_error_never_a_crash() {
        assert!(matches!(
            parse_json(&fixture("malformed/truncated.json")),
            Err(IngestError::Json(_))
        ));
    }

    // ------------------------------------------------------------ resilience

    #[test]
    fn arbitrary_bytes_never_panic() {
        // A deterministic byte-level fuzz sweep: every outcome is allowed except a panic.
        let mut state = 0x2545_F491_4F6C_DD1Du64;
        let alphabet = b"{}[]\",:0123456789.eE+-truefalsn \n\t\\\xc3\xa9\xff";
        for len in 0..48usize {
            for _ in 0..40 {
                let mut buf = Vec::with_capacity(len);
                for _ in 0..len {
                    state ^= state << 13;
                    state ^= state >> 7;
                    state ^= state << 17;
                    buf.push(alphabet[state as usize % alphabet.len()]);
                }
                let _ = parse_json(&buf);
            }
        }
    }

    #[test]
    fn every_truncation_of_a_valid_document_is_handled() {
        let doc = br#"[{"a":1,"b":{"c":[1,2]}},{"a":2,"b":{"c":"x,\"y"}}]"#;
        for cut in 0..doc.len() {
            let _ = parse_json(&doc[..cut]);
        }
    }
}
