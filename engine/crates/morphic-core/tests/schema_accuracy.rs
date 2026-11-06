//! AT-02 — schema detection accuracy, scored against hand-written ground truth.
//!
//! The claim in `docs/roadmap/mvp-acceptance-tests.md` is at least 95% per-field type accuracy
//! and at least 85% role accuracy across a labelled corpus of 20 or more valid files, with
//! every inference carrying confidence and evidence. Until this file existed that claim was
//! unmeasurable: there were labels in prose (the manifest's `expect` strings) and no scorer.
//!
//! Ground truth lives in `fixtures/expected/schema-labels.json` and is authored **from the
//! file contents, never from the profiler's output** — scoring a program against its own
//! answers measures nothing. The labels file documents its rules and flags the debatable
//! calls, so a disagreement is a reviewable edit rather than a silent threshold change.
//!
//! The scorecard is written to `target/schema-accuracy.md` **before** any assertion runs, so a
//! failing CI round still reports every miss instead of only the first one. CI prints it.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use morphic_ingest::IngestOptions;
use morphic_model::{DataType, DatasetProfile, FieldRole};
use serde::Deserialize;

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");

#[derive(Deserialize)]
struct Labels {
    schema: String,
    targets: Targets,
    files: Vec<FileLabels>,
}

#[derive(Deserialize)]
struct Targets {
    #[serde(rename = "dtypeAccuracy")]
    dtype_accuracy: f64,
    #[serde(rename = "roleAccuracy")]
    role_accuracy: f64,
}

#[derive(Deserialize)]
struct FileLabels {
    path: String,
    fields: BTreeMap<String, ExpectedField>,
}

#[derive(Deserialize)]
struct ExpectedField {
    dtype: String,
    role: String,
}

fn labels() -> Labels {
    let path = format!("{ROOT}/fixtures/expected/schema-labels.json");
    let text = std::fs::read_to_string(&path).expect("schema-labels.json must exist");
    serde_json::from_str(&text).expect("schema-labels.json must parse")
}

fn role_str(role: FieldRole) -> &'static str {
    match role {
        FieldRole::Unknown => "unknown",
        FieldRole::Temporal => "temporal",
        FieldRole::Measure => "measure",
        FieldRole::Dimension => "dimension",
        FieldRole::Severity => "severity",
        FieldRole::Identifier => "identifier",
        FieldRole::Text => "text",
    }
}

/// The real pipeline: detect the format from content, parse, then profile. No storage, no
/// compiler — AT-02 is about inference, and involving persistence would only add noise.
fn profile_fixture(rel: &str) -> DatasetProfile {
    let bytes = std::fs::read(format!("{ROOT}/fixtures/{rel}")).expect("fixture must exist");
    let extension = rel.rsplit('.').next().unwrap_or_default().to_string();
    let opts = IngestOptions {
        extension: Some(extension),
        ..Default::default()
    };
    let (table, _report) = morphic_ingest::ingest_with(&bytes, &opts, None, &mut |_| {})
        .unwrap_or_else(|e| panic!("{rel} must import cleanly: {e}"));
    morphic_semantic::profile(&table)
}

struct Score {
    fields: usize,
    dtype_hits: usize,
    role_hits: usize,
    card: String,
    problems: Vec<String>,
}

fn score_corpus(l: &Labels) -> Score {
    let mut s = Score {
        fields: 0,
        dtype_hits: 0,
        role_hits: 0,
        card: String::new(),
        problems: Vec::new(),
    };
    writeln!(s.card, "# AT-02 schema accuracy scorecard\n").unwrap();
    writeln!(s.card, "| file | fields | dtype | role | misses |").unwrap();
    writeln!(s.card, "|---|---|---|---|---|").unwrap();

    let mut detail = String::new();
    for f in &l.files {
        let profile = profile_fixture(&f.path);
        let mut actual: BTreeMap<&str, (String, String)> = BTreeMap::new();
        for p in &profile.fields {
            let facts = (
                p.dtype.as_str().to_string(),
                role_str(p.inference.role).to_string(),
            );
            actual.insert(p.name.as_str(), facts);
        }

        let (mut dtype_ok, mut role_ok, mut misses) = (0, 0, Vec::new());
        for (name, want) in &f.fields {
            s.fields += 1;
            match actual.get(name.as_str()) {
                None => {
                    misses.push(format!(
                        "`{name}`: labelled, but no such column was emitted"
                    ));
                    s.problems
                        .push(format!("{}: missing column {name}", f.path));
                }
                Some((dtype, role)) => {
                    if *dtype == want.dtype {
                        dtype_ok += 1;
                        s.dtype_hits += 1;
                    } else {
                        let m = format!("`{name}` dtype: want `{}`, got `{dtype}`", want.dtype);
                        misses.push(m);
                    }
                    if *role == want.role {
                        role_ok += 1;
                        s.role_hits += 1;
                    } else {
                        let m = format!("`{name}` role: want `{}`, got `{role}`", want.role);
                        misses.push(m);
                    }
                }
            }
        }
        // A column the corpus does not label is a hole in the ground truth, not a free pass.
        for name in actual.keys() {
            if !f.fields.contains_key(*name) {
                misses.push(format!("`{name}`: emitted by the parser but unlabelled"));
                s.problems
                    .push(format!("{}: unlabelled column {name}", f.path));
            }
        }

        let n = f.fields.len();
        writeln!(
            s.card,
            "| `{}` | {n} | {dtype_ok}/{n} | {role_ok}/{n} | {} |",
            f.path,
            misses.len()
        )
        .unwrap();
        if !misses.is_empty() {
            writeln!(detail, "\n**`{}`**\n", f.path).unwrap();
            for m in &misses {
                writeln!(detail, "- {m}").unwrap();
            }
        }
    }

    let dt = s.dtype_hits as f64 / s.fields as f64;
    let ro = s.role_hits as f64 / s.fields as f64;
    writeln!(
        s.card,
        "\n**Corpus:** {} files, {} labelled fields.\n",
        l.files.len(),
        s.fields
    )
    .unwrap();
    writeln!(
        s.card,
        "- **dtype accuracy: {:.1}%** ({}/{}) — target {:.0}%",
        100.0 * dt,
        s.dtype_hits,
        s.fields,
        100.0 * l.targets.dtype_accuracy
    )
    .unwrap();
    writeln!(
        s.card,
        "- **role accuracy: {:.1}%** ({}/{}) — target {:.0}%",
        100.0 * ro,
        s.role_hits,
        s.fields,
        100.0 * l.targets.role_accuracy
    )
    .unwrap();
    if !detail.is_empty() {
        writeln!(s.card, "\n## Every miss{detail}").unwrap();
    }

    std::fs::create_dir_all(format!("{ROOT}/target")).ok();
    std::fs::write(format!("{ROOT}/target/schema-accuracy.md"), &s.card)
        .expect("scorecard must be writable");
    s
}

#[test]
fn the_corpus_is_labelled_and_big_enough() {
    let l = labels();
    assert_eq!(l.schema, "morphic/schema-labels/1");
    assert!(
        l.files.len() >= 20,
        "AT-02 requires at least 20 valid files; the labels cover {}",
        l.files.len()
    );
    let dir = std::fs::read_dir(format!("{ROOT}/fixtures/valid")).expect("valid fixtures");
    let mut on_disk = Vec::new();
    for entry in dir {
        let entry = entry.expect("readable fixture entry");
        on_disk.push(entry.file_name().to_string_lossy().to_string());
    }
    for name in &on_disk {
        assert!(
            l.files.iter().any(|f| f.path == format!("valid/{name}")),
            "fixtures/valid/{name} has no labels; every valid fixture must be scored"
        );
    }
    assert_eq!(
        on_disk.len(),
        l.files.len(),
        "labels and fixtures must cover the same set"
    );
}

#[test]
fn every_inference_carries_confidence_and_evidence() {
    for f in &labels().files {
        let profile = profile_fixture(&f.path);
        for field in &profile.fields {
            let inf = &field.inference;
            if inf.role == FieldRole::Unknown {
                assert_eq!(
                    inf.confidence, 0.0,
                    "{} / {}: an unknown role must not claim confidence",
                    f.path, field.name
                );
                continue;
            }
            assert!(
                inf.confidence > 0.0 && inf.confidence <= 1.0,
                "{} / {}: confidence out of range: {}",
                f.path,
                field.name,
                inf.confidence
            );
            assert!(
                !inf.evidence.is_empty() && inf.evidence.iter().all(|e| !e.trim().is_empty()),
                "{} / {}: role {:?} has no evidence",
                f.path,
                field.name,
                inf.role
            );
        }
    }
}

#[test]
fn at_02_accuracy_meets_the_targets() {
    let l = labels();
    let s = score_corpus(&l);
    assert!(
        s.problems.is_empty(),
        "the corpus and its labels have drifted:\n{}",
        s.problems.join("\n")
    );
    let dtype = s.dtype_hits as f64 / s.fields as f64;
    let role = s.role_hits as f64 / s.fields as f64;
    assert!(
        dtype >= l.targets.dtype_accuracy,
        "AT-02 dtype accuracy {:.1}% is below the {:.0}% target; see target/schema-accuracy.md",
        100.0 * dtype,
        100.0 * l.targets.dtype_accuracy
    );
    assert!(
        role >= l.targets.role_accuracy,
        "AT-02 role accuracy {:.1}% is below the {:.0}% target; see target/schema-accuracy.md",
        100.0 * role,
        100.0 * l.targets.role_accuracy
    );
}

/// Guards the one thing that would make this whole file vacuous: a `DataType` whose `as_str`
/// spelling does not match the vocabulary the labels use.
#[test]
fn label_vocabulary_matches_the_engine() {
    for (dtype, spelled) in [
        (DataType::Null, "null"),
        (DataType::Bool, "bool"),
        (DataType::Int64, "int64"),
        (DataType::Float64, "float64"),
        (DataType::Utf8, "utf8"),
        (DataType::Timestamp, "timestamp"),
    ] {
        assert_eq!(dtype.as_str(), spelled);
    }
    let roles = [
        "unknown",
        "temporal",
        "measure",
        "dimension",
        "severity",
        "identifier",
        "text",
    ];
    for f in labels().files {
        for (name, want) in &f.fields {
            assert!(
                roles.contains(&want.role.as_str()),
                "{} / {}: unknown role label '{}'",
                f.path,
                name,
                want.role
            );
        }
    }
}
