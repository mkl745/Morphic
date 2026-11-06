//! Deterministic parser fuzz smoke — the M1.2 exit's "malformed corpus never crashes".
//!
//! # What this is, and what it is not
//!
//! **Not** coverage-guided fuzzing: no cargo-fuzz, no libFuzzer, no new dependency (the
//! dependency policy in ADR-0012 is deliberately tight, and a fuzzer that only runs on a
//! nightly which has never executed is worth less than a smoke that runs on every push).
//!
//! **Is** a seeded mutation harness over the real fixture corpus. Every case goes through the
//! public [`ingest_with`] entry point — format detection included, because a misdetection is
//! exactly the kind of bug a per-parser fuzz would miss.
//!
//! The guarantees are bounded and stated plainly. Over N deterministic cases:
//!
//! 1. no parser panics (a panic fails the test);
//! 2. every outcome is a `Table` or a typed [`IngestError`] — never a hang, never a silent skip;
//! 3. on success, structural invariants hold: every column buffer matches the row count, and
//!    the report's accounting matches the table it describes;
//! 4. no single case takes pathologically long (a cheap guard against catastrophic regex
//!    backtracking, which is the realistic denial-of-service in a log parser);
//! 5. re-parsing the same bytes gives the same answer, because reopen depends on it;
//! 6. a pre-cancelled token is honoured even on adversarial input.
//!
//! Run deeper with `MORPHIC_FUZZ_CASES=40000 cargo test -p morphic-ingest --test fuzz_smoke`.
//! The nightly workflow does exactly that. `MORPHIC_FUZZ_SEED` changes the stream; the default
//! is fixed so a failure is reproducible from the reported seed alone.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::time::{Duration, Instant};

use morphic_ingest::{ingest_with, CancelToken, IngestError, IngestOptions};
use morphic_model::{ColumnValues, ImportReport, Table};

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");
const DEFAULT_CASES: usize = 3000;
const DEFAULT_SEED: u64 = 0x4D4F_5250_4849_4301;
/// Keeps the suite fast and the worst case bounded. The gate paths are covered separately by
/// `structural_attacks_are_refused_with_typed_errors`, which lowers the limits instead.
const MAX_CASE_BYTES: usize = 64 * 1024;
/// A single small input taking this long means a parser is in trouble, not that CI is slow.
const MAX_CASE_TIME: Duration = Duration::from_secs(10);

const NASTY: &[&[u8]] = &[
    b"\0",
    b"\xff\xfe",
    b"\xc3",           // truncated UTF-8 sequence
    b"\xed\xa0\x80",   // lone surrogate, invalid UTF-8
    b"\xef\xbb\xbf",   // BOM in the middle of a stream
    b"\"",
    b"\"\"",
    b"\\",
    b"\r\n",
    b"\r",
    b"\t;",
    b"NaN",
    b"1e999",
    b"-Infinity",
    b"null",
    b"0x10",
    b"1_000",
    b"2026-13-45T99:99:99Z",
    b"{}",
    b"[]",
    b"[[]]",
    b"{\"a\":",
    b",,,,,,,,",
    b"\x1b[31m",
];

const DELIMITERS: &[u8] = b",;\t|";

/// splitmix64. Small, fast, and identical on every platform, which is what makes a reported
/// seed enough to reproduce a failure.
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// `n` must be non-zero; every call site guards its slice first.
    fn below(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }
}

fn env_usize(key: &str, fallback: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(fallback)
}

fn seed_corpus() -> Vec<(String, Vec<u8>)> {
    let mut seeds = Vec::new();
    for dir in ["valid", "malformed"] {
        let path = format!("{ROOT}/fixtures/{dir}");
        let entries = std::fs::read_dir(&path).unwrap_or_else(|e| panic!("read {path}: {e}"));
        for entry in entries {
            let entry = entry.expect("readable fixture entry");
            let name = format!("{dir}/{}", entry.file_name().to_string_lossy());
            let bytes = std::fs::read(entry.path()).expect("readable fixture");
            seeds.push((name, bytes));
        }
    }
    // Synthetic seeds for shapes the curated corpus does not contain.
    let extra: &[(&str, &[u8])] = &[
        ("synthetic/empty", b""),
        ("synthetic/bom_only", b"\xef\xbb\xbf"),
        ("synthetic/nul_only", b"\0\0\0"),
        ("synthetic/deep_json", br#"{"a":{"a":{"a":{"a":{"a":1}}}}}"#),
        ("synthetic/quote_flood", b"a,b\n\"\"\"\"\"\",2\n"),
        ("synthetic/wide_row", b"a,b,c,d,e,f\n1,2,3,4,5,6\n"),
        ("synthetic/iso_flood", b"t\n2026-01-01T00:00:00Z\n2026-01-01T00:00:01Z\n"),
        ("synthetic/logfmt", b"time=2026-01-01T00:00:00Z level=error msg=\"x\" n=1\n"),
        ("synthetic/clf", b"1.2.3.4 - - [10/Oct/2000:13:55:36 -0700] \"GET / HTTP/1.0\" 200 1\n"),
    ];
    for (name, bytes) in extra {
        seeds.push(((*name).to_string(), bytes.to_vec()));
    }
    assert!(seeds.len() >= 20, "the seed corpus is too small to be worth mutating");
    seeds
}

fn pick_seed<'a>(rng: &mut Rng, seeds: &'a [(String, Vec<u8>)]) -> &'a (String, Vec<u8>) {
    &seeds[rng.below(seeds.len())]
}

fn insert_at(bytes: &[u8], at: usize, token: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len() + token.len());
    out.extend_from_slice(&bytes[..at]);
    out.extend_from_slice(token);
    out.extend_from_slice(&bytes[at..]);
    out
}

fn mutate_once(rng: &mut Rng, seeds: &[(String, Vec<u8>)], bytes: Vec<u8>) -> Vec<u8> {
    match rng.below(10) {
        0 => {
            let mut b = bytes;
            if !b.is_empty() {
                let n = rng.below(b.len());
                b.truncate(n);
            }
            b
        }
        1 => {
            let mut b = bytes;
            if !b.is_empty() {
                for _ in 0..(1 + rng.below(8)) {
                    let i = rng.below(b.len());
                    b[i] = (rng.next_u64() & 0xFF) as u8;
                }
            }
            b
        }
        2 => {
            let token = NASTY[rng.below(NASTY.len())];
            let at = if bytes.is_empty() { 0 } else { rng.below(bytes.len()) };
            insert_at(&bytes, at, token)
        }
        3 => {
            if bytes.len() > 1 {
                let start = rng.below(bytes.len() - 1);
                let end = start + 1 + rng.below(bytes.len() - start - 1);
                let mut out = bytes[..start].to_vec();
                out.extend_from_slice(&bytes[end..]);
                out
            } else {
                bytes
            }
        }
        4 => {
            if bytes.is_empty() {
                return bytes;
            }
            let start = rng.below(bytes.len());
            let end = start + 1 + rng.below(bytes.len() - start);
            let chunk = bytes[start..end].to_vec();
            let mut out = bytes;
            out.extend_from_slice(&chunk);
            out
        }
        5 => {
            let (_, other) = pick_seed(rng, seeds);
            let mut out = bytes;
            out.extend_from_slice(other);
            out
        }
        6 => match rng.below(3) {
            0 => {
                let mut out = b"[".to_vec();
                out.extend_from_slice(&bytes);
                out.push(b']');
                out
            }
            1 => {
                let mut out = b"{".to_vec();
                out.extend_from_slice(&bytes);
                out.push(b'}');
                out
            }
            _ => {
                let mut out = b"a,b\n".to_vec();
                out.extend_from_slice(&bytes);
                out
            }
        },
        7 => {
            let from = DELIMITERS[rng.below(DELIMITERS.len())];
            let to = DELIMITERS[rng.below(DELIMITERS.len())];
            bytes
                .into_iter()
                .map(|c| if c == from { to } else { c })
                .collect()
        }
        8 => {
            let k = 2 + rng.below(3);
            let mut out = Vec::new();
            for _ in 0..k {
                out.extend_from_slice(&bytes);
                if out.len() >= MAX_CASE_BYTES {
                    break;
                }
            }
            out
        }
        _ => {
            let at = if bytes.is_empty() { 0 } else { rng.below(bytes.len()) };
            insert_at(&bytes, at, b"\n")
        }
    }
}

fn error_kind(e: &IngestError) -> &'static str {
    match e {
        IngestError::Csv(_) => "csv",
        IngestError::NoHeader => "no_header",
        IngestError::Empty => "empty",
        IngestError::Cancelled => "cancelled",
        IngestError::TooManyColumns { .. } => "too_many_columns",
        IngestError::TooManyRows { .. } => "too_many_rows",
        IngestError::Json(_) => "json",
        IngestError::ResourceLimit(_) => "resource_limit",
    }
}

fn buffer_len(values: &ColumnValues) -> Option<usize> {
    match values {
        ColumnValues::Bool(v) => Some(v.len()),
        ColumnValues::Int64(v) => Some(v.len()),
        ColumnValues::Float64(v) => Some(v.len()),
        ColumnValues::Utf8(v) => Some(v.len()),
        ColumnValues::Timestamp(v) => Some(v.len()),
        ColumnValues::Null => None,
    }
}

/// A table that disagrees with its own report is silent corruption, which is worse than a
/// crash: the user sees numbers that came from nowhere.
fn check_invariants(table: &Table, report: &ImportReport, label: &str) {
    assert_eq!(
        report.field_count,
        table.columns.len(),
        "{label}: the report describes {} fields, the table has {}",
        report.field_count,
        table.columns.len()
    );
    assert_eq!(
        report.rows_imported, table.row_count,
        "{label}: the report claims {} rows, the table holds {}",
        report.rows_imported, table.row_count
    );
    for col in &table.columns {
        assert_eq!(
            col.nulls.len(),
            table.row_count,
            "{label}: column '{}' has {} null flags for {} rows",
            col.name,
            col.nulls.len(),
            table.row_count
        );
        if let Some(len) = buffer_len(&col.values) {
            assert_eq!(
                len,
                table.row_count,
                "{label}: column '{}' buffer holds {len} values for {} rows",
                col.name,
                table.row_count
            );
        }
    }
}

fn opts_for(name: &str) -> IngestOptions {
    IngestOptions {
        extension: Some(name.rsplit('.').next().unwrap_or("dat").to_string()),
        ..Default::default()
    }
}

#[test]
fn mutation_smoke_never_panics_and_always_returns_a_typed_outcome() {
    let cases = env_usize("MORPHIC_FUZZ_CASES", DEFAULT_CASES);
    let seed = std::env::var("MORPHIC_FUZZ_SEED")
        .ok()
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(DEFAULT_SEED);
    let seeds = seed_corpus();
    let mut rng = Rng(seed);

    let mut ok = 0usize;
    let mut kinds: BTreeMap<&str, usize> = BTreeMap::new();
    let mut formats: BTreeMap<String, usize> = BTreeMap::new();
    let mut slowest = Duration::ZERO;
    let mut slowest_case = String::new();
    let mut biggest = 0usize;
    let started = Instant::now();

    for case in 0..cases {
        let (name, base) = pick_seed(&mut rng, seeds);
        let name = name.clone();
        let mut bytes = base.clone();
        for _ in 0..(1 + rng.below(3)) {
            bytes = mutate_once(&mut rng, &seeds, bytes);
        }
        bytes.truncate(MAX_CASE_BYTES);
        biggest = biggest.max(bytes.len());

        let label = format!("case {case} from {name} ({} bytes, seed {seed})", bytes.len());
        let opts = opts_for(&name);
        let t0 = Instant::now();
        let outcome = ingest_with(&bytes, &opts, None, &mut |_| {});
        let elapsed = t0.elapsed();
        assert!(
            elapsed <= MAX_CASE_TIME,
            "{label} took {elapsed:?}, over the {MAX_CASE_TIME:?} budget: a parser is \
             backtracking or looping on adversarial input"
        );
        if elapsed > slowest {
            slowest = elapsed;
            slowest_case = label.clone();
        }

        match outcome {
            Ok((table, report)) => {
                ok += 1;
                check_invariants(&table, &report, &label);
                *formats.entry(report.format.clone()).or_insert(0) += 1;
                // Reopen re-ingests the stored bytes, so the two paths must agree exactly.
                if case % 32 == 0 {
                    let repeat = ingest_with(&bytes, &opts, None, &mut |_| {});
                    let (again, report2) = repeat.expect("deterministic reparse");
                    assert_eq!(again.row_count, table.row_count, "{label}: row count drifted");
                    assert_eq!(again.field_names(), table.field_names(), "{label}: names drifted");
                    assert_eq!(report2.format, report.format, "{label}: format drifted");
                    assert_eq!(report2.warnings, report.warnings, "{label}: warnings drifted");
                }
            }
            Err(e) => {
                // A typed error is a legitimate outcome. An empty message is not: every error
                // the user can reach has to say something.
                assert!(
                    !e.to_string().trim().is_empty(),
                    "{label}: error {} has no message",
                    error_kind(&e)
                );
                *kinds.entry(error_kind(&e)).or_insert(0) += 1;
            }
        }
    }

    let total = started.elapsed();
    let mut card = String::new();
    writeln!(card, "# Parser fuzz smoke\n").unwrap();
    writeln!(card, "- seed: `{seed}` (set `MORPHIC_FUZZ_SEED` to change it)").unwrap();
    writeln!(card, "- cases: **{cases}**, seeded from {} corpus files", seeds.len()).unwrap();
    writeln!(card, "- accepted as a table: **{ok}**").unwrap();
    writeln!(card, "- refused with a typed error: **{}**", cases - ok).unwrap();
    writeln!(card, "- largest input: {biggest} bytes").unwrap();
    writeln!(card, "- total time: {total:?}; slowest case: {slowest:?}").unwrap();
    writeln!(card, "- slowest: {slowest_case}\n").unwrap();
    writeln!(card, "| detected format | tables |\n|---|---|").unwrap();
    for (format, n) in &formats {
        writeln!(card, "| {format} | {n} |").unwrap();
    }
    writeln!(card, "\n| typed error | count |\n|---|---|").unwrap();
    for (kind, n) in &kinds {
        writeln!(card, "| {kind} | {n} |").unwrap();
    }
    writeln!(
        card,
        "\n> **Scope.** Seeded mutation, not coverage-guided fuzzing. It proves no panic, a \
         typed outcome, structural consistency and bounded time over these {cases} cases — \
         not the absence of bugs. A failure is reproducible from the seed above."
    )
    .unwrap();
    std::fs::create_dir_all(format!("{ROOT}/target")).ok();
    std::fs::write(format!("{ROOT}/target/fuzz-smoke.md"), &card).expect("report must be writable");

    // A smoke that quietly stopped exercising the parsers would still be green, so assert the
    // stream really did reach both outcomes and more than one format.
    assert!(ok > 0, "no case produced a table; the mutation stream is degenerate");
    assert!(
        cases - ok > 0,
        "no case was refused; the mutation stream is not exercising failure paths"
    );
    assert!(
        formats.len() >= 2,
        "only {} format(s) detected; detection is not being exercised: {formats:?}",
        formats.len()
    );
}

#[test]
fn structural_attacks_are_refused_with_typed_errors() {
    // Wide: more columns than the cap.
    let wide = format!("{}\n{}\n", vec!["c"; 3000].join(","), vec!["1"; 3000].join(","));
    let opts = IngestOptions {
        format_hint: Some("csv".into()),
        ..Default::default()
    };
    let err = ingest_with(wide.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
    assert!(matches!(err, IngestError::TooManyColumns { .. }), "{err}");

    // Long: more rows than a lowered cap, so the test stays fast.
    let long = "a\n".to_string() + &"1\n".repeat(50);
    let opts = IngestOptions {
        format_hint: Some("csv".into()),
        max_rows: 10,
        ..Default::default()
    };
    let err = ingest_with(long.as_bytes(), &opts, None, &mut |_| {}).unwrap_err();
    assert!(matches!(err, IngestError::TooManyRows { .. }), "{err}");

    // Heavy: more bytes than a lowered gate.
    let opts = IngestOptions {
        max_import_bytes: 32,
        ..Default::default()
    };
    let heavy = [b'x'; 4096];
    let err = ingest_with(&heavy, &opts, None, &mut |_| {}).unwrap_err();
    assert!(matches!(err, IngestError::ResourceLimit(_)), "{err}");

    // Deep: nesting far past the cap must be retained or refused, never overflow the stack.
    let deep = format!("{}1{}", "{\"a\":".repeat(400), "}".repeat(400));
    let opts = IngestOptions {
        format_hint: Some("json".into()),
        ..Default::default()
    };
    // Either outcome is acceptable here; what is not acceptable is a stack overflow, which
    // would abort the process rather than return.
    if let Ok((table, report)) = ingest_with(deep.as_bytes(), &opts, None, &mut |_| {}) {
        check_invariants(&table, &report, "deep JSON");
    }

    // A single enormous line must not be treated as an unbounded allocation.
    let one_line = "a,b\n".to_string() + &"x".repeat(512 * 1024) + "\n";
    let opts = IngestOptions {
        format_hint: Some("csv".into()),
        ..Default::default()
    };
    if let Ok((table, report)) = ingest_with(one_line.as_bytes(), &opts, None, &mut |_| {}) {
        check_invariants(&table, &report, "one long line");
    }
}

#[test]
fn a_pre_cancelled_import_stops_even_on_adversarial_input() {
    let seeds = seed_corpus();
    let mut rng = Rng(DEFAULT_SEED ^ 0xCA0C_E11E_D000_0001);
    for _ in 0..200 {
        let (name, base) = pick_seed(&mut rng, &seeds);
        let bytes = mutate_once(&mut rng, &seeds, base.clone());
        if bytes.is_empty() {
            continue;
        }
        let token = CancelToken::new();
        token.cancel();
        let err = ingest_with(&bytes, &opts_for(name), Some(&token), &mut |_| {})
            .expect_err("a cancelled import must not succeed");
        assert!(
            matches!(err, IngestError::Cancelled),
            "{name}: cancellation was not honoured, got {err}"
        );
    }
}
