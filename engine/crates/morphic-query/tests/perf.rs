//! Engine-side measurement for the M1.3 exit claim: filter + sort over 100k rows × 10 columns.
//!
//! # What this proves, and what it does not
//!
//! The plan's target is **≤150 ms on a mid-class ARM device**. This runs on a CI x86 runner, so
//! it cannot confirm that number and does not try: the assertion here is a generous regression
//! ceiling, and the measured figure is written to `target/query-perf.md` for the report. The
//! device figure has to come from the phone harness. Claiming the ARM target from this run
//! would be exactly the kind of unearned exit this repo has been correcting.
//!
//! The ceiling is deliberately loose (5 s) because a shared runner under load is not a
//! benchmark machine. It catches an accidental O(n²), not a 20% regression.

use std::time::Instant;

use morphic_model::{Column, ColumnValues, DataType, Table};
use morphic_query::{query_page, AggSpec, Plan, SortSpec};
use serde_json::json;

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");
const ROWS: usize = 100_000;
/// A shared CI runner is not a benchmark machine; this catches quadratic blowups, not drift.
const CEILING_MS: u128 = 5_000;

/// Deterministic 100k × 10 table: no RNG dependency, so the measurement is reproducible.
fn wide_table() -> Table {
    let regions = ["eu", "us", "apac", "latam", "mea"];
    let mut cols = Vec::new();
    cols.push(Column {
        name: "id".into(),
        dtype: DataType::Int64,
        values: ColumnValues::Int64((0..ROWS as i64).collect()),
        nulls: vec![false; ROWS],
    });
    cols.push(Column {
        name: "region".into(),
        dtype: DataType::Utf8,
        values: ColumnValues::Utf8(
            (0..ROWS)
                .map(|i| regions[i % regions.len()].to_string())
                .collect(),
        ),
        // Every 101st region is null, so the nulls policy is exercised at scale.
        nulls: (0..ROWS).map(|i| i % 101 == 0).collect(),
    });
    cols.push(Column {
        name: "amount".into(),
        dtype: DataType::Float64,
        values: ColumnValues::Float64(
            (0..ROWS).map(|i| ((i * 37) % 1000) as f64 / 7.0).collect(),
        ),
        nulls: (0..ROWS).map(|i| i % 97 == 0).collect(),
    });
    for c in 3..10 {
        cols.push(Column {
            name: format!("metric_{c}"),
            dtype: DataType::Int64,
            values: ColumnValues::Int64(
                (0..ROWS)
                    .map(|i| (i as i64 * (c as i64 + 1)) % 9973)
                    .collect(),
            ),
            nulls: vec![false; ROWS],
        });
    }
    Table {
        columns: cols,
        row_count: ROWS,
    }
}

#[test]
fn filter_and_sort_100k_by_10() {
    let table = wide_table();
    assert_eq!(table.columns.len(), 10);

    let plan = Plan {
        filter: Some(json!({"op": "and", "args": [
            {"op": "in", "field": "region", "value": ["eu", "us"]},
            {"op": "gte", "field": "amount", "value": 20.0}
        ]})),
        sort: vec![SortSpec::desc("amount"), SortSpec::asc("id")],
        limit: 256,
        ..Default::default()
    };

    // One warm run so the first-touch page faults are not charged to the measurement.
    let warm = query_page(&table, &plan).expect("plan must be valid");
    let start = Instant::now();
    let page = query_page(&table, &plan).expect("plan must be valid");
    let elapsed = start.elapsed();
    assert_eq!(page.total_rows, warm.total_rows, "the query must be deterministic");
    assert_eq!(page.rows.len(), 256);

    // A second measurement with grouping, since charts take that path.
    let grouped = Plan {
        group_by: vec!["region".into()],
        aggs: vec![AggSpec::new("sum", Some("amount")), AggSpec::new("count", None)],
        ..plan.clone()
    };
    let gstart = Instant::now();
    let g = morphic_query::query_groups(&table, &grouped).expect("grouped plan must be valid");
    let gelapsed = gstart.elapsed();

    let scan_start = Instant::now();
    let unfiltered = query_page(&table, &Plan::default()).unwrap();
    let scan_elapsed = scan_start.elapsed();

    let mut card = String::new();
    card.push_str("# M1.3 engine-side query measurement\n\n");
    card.push_str(&format!(
        "Table: {ROWS} rows × {} columns, synthetic and deterministic.\n\n",
        table.columns.len()
    ));
    card.push_str("| workload | measured | matched rows |\n|---|---|---|\n");
    card.push_str(&format!(
        "| filter (in + gte) + 2-key sort + page | {:.1} ms | {} |\n",
        elapsed.as_secs_f64() * 1000.0,
        page.total_rows
    ));
    card.push_str(&format!(
        "| same filter + sort + group/agg | {:.1} ms | {} groups |\n",
        gelapsed.as_secs_f64() * 1000.0,
        g.total_groups
    ));
    card.push_str(&format!(
        "| unfiltered first page (baseline) | {:.1} ms | {} |\n",
        scan_elapsed.as_secs_f64() * 1000.0,
        unfiltered.total_rows
    ));
    card.push_str(
        "\n**This is a CI x86 runner, not a phone.** The M1.3 exit target is ≤150 ms on a\n"
    );
    card.push_str(
        "mid-class ARM device; that figure must come from the device harness. The assertion\n"
    );
    card.push_str(&format!(
        "here is a {CEILING_MS} ms regression ceiling, loose on purpose — it catches an\n"
    ));
    card.push_str("accidental quadratic path, not a 20% drift on a shared runner.\n");

    std::fs::create_dir_all(format!("{ROOT}/target")).ok();
    std::fs::write(format!("{ROOT}/target/query-perf.md"), &card)
        .expect("report must be writable");
    println!("{card}");

    assert!(
        elapsed.as_millis() < CEILING_MS,
        "filter+sort took {} ms, over the {CEILING_MS} ms regression ceiling",
        elapsed.as_millis()
    );
    assert!(
        gelapsed.as_millis() < CEILING_MS,
        "group path took {} ms",
        gelapsed.as_millis()
    );
}
