//! Golden tests: fixture CSV → ingest → profile → compiled `WorkspaceDoc`.
//!
//! These lock the *generated interface*, not just the code path. Because the planner is
//! deterministic (fixed ids, fixed timestamps, stable tie-breaks), any change to a rule,
//! an explanation, or a binding shows up as a reviewable diff.
//!
//! Every golden is also asserted to pass all five validator passes, so a snapshot can never
//! enshrine an invalid document.
//!
//! Review a change with `cargo insta review`; regenerate deliberately with
//! `INSTA_UPDATE=always cargo test -p morphic-compiler`. CI runs with updates disabled.

use morphic_compiler::compile;
use morphic_model::DatasetProfile;
use morphic_schema::WorkspaceDoc;

const NOW: &str = "2026-11-05T00:00:00Z";

fn fixture(rel: &str) -> Vec<u8> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../fixtures")
        .join(rel);
    std::fs::read(&path).unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()))
}

/// Run the real pipeline. Fixed dataset/workspace ids and clock keep the output stable.
fn pipeline(bytes: &[u8]) -> (WorkspaceDoc, DatasetProfile) {
    let (table, _report) = morphic_ingest::parse_csv(bytes).expect("fixture must parse");
    let profile = morphic_semantic::profile(&table);
    let doc = compile(
        &profile,
        "dataset_golden",
        "workspace_golden",
        "Golden",
        NOW,
    );
    let issues = morphic_schema::validate_with_profile(&doc, &profile);
    assert!(issues.is_empty(), "compiled doc must validate: {issues:?}");
    (doc, profile)
}

#[test]
fn mixed_types() {
    let (doc, _) = pipeline(&fixture("valid/mixed_types.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn timestamps_with_offsets() {
    let (doc, _) = pipeline(&fixture("valid/timestamps.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn naive_timestamps() {
    let (doc, _) = pipeline(&fixture("valid/naive_timestamps.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn ambiguous_dates_stay_text() {
    let (doc, _) = pipeline(&fixture("valid/ambiguous_dates.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn day_first_dates() {
    let (doc, _) = pipeline(&fixture("valid/day_first_dates.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn headerless() {
    let (doc, _) = pipeline(&fixture("valid/headerless.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn tolerant_types() {
    let (doc, _) = pipeline(&fixture("valid/tolerant_types.csv"));
    insta::assert_json_snapshot!(doc);
}

#[test]
fn semicolon_delimited() {
    let (doc, _) = pipeline(&fixture("valid/semicolon.csv"));
    insta::assert_json_snapshot!(doc);
}

/// Temporal + severity but no measure ⇒ R4 timeline, not R3 line chart.
#[test]
fn event_log_uses_timeline() {
    let csv = b"time,level,service,message\n\
                2026-11-05T10:00:00Z,ERROR,api,failed\n\
                2026-11-05T10:01:00Z,INFO,api,ok\n\
                2026-11-05T10:02:00Z,WARN,db,slow\n\
                2026-11-05T10:03:00Z,ERROR,db,timeout\n";
    let (doc, _) = pipeline(csv);
    insta::assert_json_snapshot!(doc);
}

/// Dimensions only ⇒ R5 breakdown counts records instead of averaging a measure.
#[test]
fn dimensions_only_counts_records() {
    let csv = b"region,city\n\
                eu,berlin\n\
                eu,paris\n\
                us,boston\n\
                us,seattle\n";
    let (doc, _) = pipeline(csv);
    insta::assert_json_snapshot!(doc);
}

/// A single text column: nothing to chart, but the workspace is still usable.
#[test]
fn single_text_column() {
    let (doc, _) = pipeline(b"note\nalpha\nbeta\ngamma\n");
    insta::assert_json_snapshot!(doc);
}
