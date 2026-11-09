//! AT-12 — planner selection quality, scored against hand-written ground truth.
//!
//! `docs/roadmap/mvp-acceptance-tests.md` claims planner selections match expected component
//! sets at least 85% of the time, that temporal data always gets a time-based view, that
//! severity data always gets an error metric, and that every workspace keeps a table. Until
//! this file existed none of those four claims was measured.
//!
//! Ground truth lives in `fixtures/expected/plans.json` and is authored **from the file
//! contents and the planning rules, never from the planner's output** — scoring a program
//! against its own answers measures nothing. It labels the *multiset of component types*, not
//! ids or titles: two metric cards are two entries, so quietly dropping one is a miss.
//!
//! The scorecard is written to `target/plan-accuracy.md` **before** any assertion runs, so a
//! failing round reports every miss instead of only the first. CI prints it.
//!
//! ## Why this file also renders every chart
//!
//! A selection can be right and still be dead. The planner names a field; the query layer has
//! to aggregate it. `series_scene` refuses a text x-axis and `timeline_scene` refuses a
//! non-timestamp time field, while the planner accepts a *role* of Temporal whose dtype is
//! still utf8 (CLF and RFC3164 times, unresolved day/month order). Those documents validate —
//! pass 4 checks the role — and then fail at the first draw. Selecting the right component and
//! emitting a binding that cannot render are different failures, and only the second one is
//! invisible to a selection score. So every generated chart is rendered here against its own
//! fixture, and a render failure is reported next to the selection score.

use std::collections::BTreeMap;
use std::fmt::Write as _;

use morphic_compiler::compile;
use morphic_core::{Engine, ImportRequest};
use morphic_ingest::IngestOptions;
use morphic_model::{DatasetProfile, FieldRole};
use morphic_schema::{Binding, WorkspaceDoc};
use serde::Deserialize;

const ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../..");
const NOW: &str = "2026-11-05T00:00:00Z";

#[derive(Deserialize)]
struct Labels {
    schema: String,
    targets: Targets,
    files: Vec<FileLabels>,
}

#[derive(Deserialize)]
struct Targets {
    #[serde(rename = "selectionAccuracy")]
    selection_accuracy: f64,
}

#[derive(Deserialize)]
struct FileLabels {
    path: String,
    components: Vec<String>,
}

fn labels() -> Labels {
    let path = format!("{ROOT}/fixtures/expected/plans.json");
    let text = std::fs::read_to_string(&path).expect("plans.json must exist");
    serde_json::from_str(&text).expect("plans.json must parse")
}

fn read_fixture(rel: &str) -> Vec<u8> {
    std::fs::read(format!("{ROOT}/fixtures/{rel}")).expect("fixture must exist")
}

fn extension(rel: &str) -> String {
    rel.rsplit('.').next().unwrap_or_default().to_string()
}

/// The real pipeline, minus persistence: detect → parse → profile → compile.
fn plan_fixture(rel: &str) -> (WorkspaceDoc, DatasetProfile) {
    let bytes = read_fixture(rel);
    let opts = IngestOptions {
        extension: Some(extension(rel)),
        ..Default::default()
    };
    let (table, _report) = morphic_ingest::ingest_with(&bytes, &opts, None, &mut |_| {})
        .unwrap_or_else(|e| panic!("{rel} must import cleanly: {e}"));
    let profile = morphic_semantic::profile(&table);
    let doc = compile(&profile, "dataset_at12", "workspace_at12", "AT-12", NOW);
    (doc, profile)
}

/// Multiset of emitted component types, sorted so the comparison ignores layout order.
fn emitted(doc: &WorkspaceDoc) -> Vec<String> {
    let mut kinds: Vec<String> = doc
        .workspace
        .components
        .iter()
        .map(|c| c.component_type.clone())
        .collect();
    kinds.sort();
    kinds
}

/// Multiset difference, keeping duplicates: two expected metrics against one emitted is a miss.
fn missing(want: &[String], got: &[String]) -> Vec<String> {
    let mut remaining: Vec<&str> = got.iter().map(|s| s.as_str()).collect();
    let mut out = Vec::new();
    for w in want {
        match remaining.iter().position(|g| *g == w.as_str()) {
            Some(i) => {
                remaining.remove(i);
            }
            None => out.push(w.clone()),
        }
    }
    out
}

fn temp_root(tag: &str) -> std::path::PathBuf {
    let mut root = std::env::temp_dir();
    root.push(format!(
        "morphic-at12-{tag}-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    root
}

/// Import through the real engine and draw every chart the planner emitted.
///
/// Returns one message per chart that could not be rendered. Persistence is involved here on
/// purpose: `chart_data` needs a session, and a session is what the app has.
fn render_failures(rel: &str) -> Vec<String> {
    let root = temp_root("render");
    let engine = Engine::new(&root).expect("engine must open");
    let bytes = read_fixture(rel);
    let id = "w_at12_render";
    let outcome = engine
        .import(
            ImportRequest {
                bytes: &bytes,
                title: "AT-12",
                workspace_id: id,
                now_iso: NOW,
                format_hint: None,
                extension: Some(extension(rel)),
                cancel: None,
            },
            &mut |_| {},
        )
        .unwrap_or_else(|e| panic!("{rel} must import cleanly: {e}"));

    let mut failures = Vec::new();
    for c in &outcome.doc.workspace.components {
        let is_chart = matches!(
            c.binding,
            Binding::BarChart { .. } | Binding::LineChart { .. } | Binding::Timeline { .. }
        );
        if !is_chart {
            continue;
        }
        if let Err(e) = engine.chart_data(id, &c.id) {
            failures.push(format!(
                "`{}` ({}) does not render: {e}",
                c.id, c.component_type
            ));
        }
    }
    let _ = std::fs::remove_dir_all(&root);
    failures
}

struct Score {
    /// Per-file intersection size over expected size, summed — the corpus numerator.
    hits: usize,
    expected: usize,
    exact: usize,
    card: String,
    /// Selection misses and extra components: reported, and counted against the score.
    render: Vec<String>,
}

fn score_corpus(l: &Labels) -> Score {
    let mut s = Score {
        hits: 0,
        expected: 0,
        exact: 0,
        card: String::new(),
        render: Vec::new(),
    };
    writeln!(s.card, "# AT-12 planner selection scorecard\n").unwrap();
    writeln!(s.card, "| file | expected | matched | extra | render |").unwrap();
    writeln!(s.card, "|---|---|---|---|---|").unwrap();

    let mut detail = String::new();
    for f in &l.files {
        let (doc, _profile) = plan_fixture(&f.path);
        let got = emitted(&doc);
        let mut want = f.components.clone();
        want.sort();

        let absent = missing(&want, &got);
        let extra = missing(&got, &want);
        let matched = want.len() - absent.len();
        s.hits += matched;
        s.expected += want.len();
        if absent.is_empty() && extra.is_empty() {
            s.exact += 1;
        }

        let render = render_failures(&f.path);
        let render_note = if render.is_empty() {
            "ok".to_string()
        } else {
            format!("**{} failed**", render.len())
        };
        writeln!(
            s.card,
            "| `{}` | {} | {}/{} | {} | {render_note} |",
            f.path,
            want.len(),
            matched,
            want.len(),
            extra.len()
        )
        .unwrap();

        if !absent.is_empty() || !extra.is_empty() || !render.is_empty() {
            writeln!(detail, "\n**`{}`**\n", f.path).unwrap();
            writeln!(detail, "- expected: `{}`", want.join(", ")).unwrap();
            writeln!(detail, "- emitted:  `{}`", got.join(", ")).unwrap();
            for m in &absent {
                writeln!(detail, "- missing `{m}`").unwrap();
            }
            for x in &extra {
                writeln!(detail, "- unexpected `{x}`").unwrap();
            }
            for r in &render {
                writeln!(detail, "- {r}").unwrap();
                s.render.push(format!("{}: {r}", f.path));
            }
        }
    }

    let accuracy = s.hits as f64 / s.expected as f64;
    writeln!(
        s.card,
        "\n**Corpus:** {} files, {} expected components.\n",
        l.files.len(),
        s.expected
    )
    .unwrap();
    writeln!(
        s.card,
        "- **selection accuracy: {:.1}%** ({}/{}) — target {:.0}%",
        100.0 * accuracy,
        s.hits,
        s.expected,
        100.0 * l.targets.selection_accuracy
    )
    .unwrap();
    writeln!(
        s.card,
        "- **exact set matches: {}/{} files**",
        s.exact,
        l.files.len()
    )
    .unwrap();
    writeln!(
        s.card,
        "- **charts that do not render: {}**",
        s.render.len()
    )
    .unwrap();
    writeln!(
        s.card,
        "\n> **What the percentage counts.** One point per expected component present, so a \
         file that should have three metric cards and emits two scores 2/3 there. Extra \
         components are listed but do not earn points; the invariants below are asserted \
         separately, because an average can hide a broken guarantee.\n\n\
         > **Tuning caveat.** The rule table was written against this corpus, so this score is \
         an upper bound on selection quality, not a generalisation estimate. See \
         `fixtures/expected/README.md`."
    )
    .unwrap();
    if !detail.is_empty() {
        writeln!(s.card, "\n## Every miss{detail}").unwrap();
    }

    std::fs::create_dir_all(format!("{ROOT}/target")).ok();
    std::fs::write(format!("{ROOT}/target/plan-accuracy.md"), &s.card)
        .expect("scorecard must be writable");
    s
}

#[test]
fn the_corpus_is_labelled_and_matches_the_fixtures() {
    let l = labels();
    assert_eq!(l.schema, "morphic/plan-labels/1");
    assert!(
        l.files.len() >= 20,
        "AT-12 scores the labelled corpus; the labels cover {} files",
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
            "fixtures/valid/{name} has no plan labels; every valid fixture must be scored"
        );
    }
    assert_eq!(
        on_disk.len(),
        l.files.len(),
        "labels and fixtures must cover the same set"
    );
}

/// A label the scorer cannot understand would silently score zero for that file.
#[test]
fn label_vocabulary_matches_the_registry() {
    let mut seen = BTreeMap::new();
    for f in labels().files {
        assert!(!f.components.is_empty(), "{} has no labels", f.path);
        for c in &f.components {
            assert!(
                morphic_schema::ACTIVE_COMPONENTS.contains(&c.as_str()),
                "{}: '{}' is not an active component type",
                f.path,
                c
            );
            *seen.entry(c.clone()).or_insert(0usize) += 1;
        }
        assert!(
            f.components.iter().any(|c| c == "data_table"),
            "{}: AT-12 requires a table in every workspace, including in the labels",
            f.path
        );
        assert!(
            !(f.components.iter().any(|c| c == "line_chart")
                && f.components.iter().any(|c| c == "timeline")),
            "{}: a line and a timeline would draw the same time axis twice",
            f.path
        );
    }
    // A corpus that never exercises a component cannot score the planner that emits it.
    for kind in [
        "metric_card",
        "data_table",
        "bar_chart",
        "line_chart",
        "timeline",
    ] {
        assert!(
            seen.contains_key(kind),
            "no fixture is labelled with `{kind}`; the corpus does not exercise it"
        );
    }
}

#[test]
fn at_12_selection_accuracy_meets_the_target() {
    let l = labels();
    let s = score_corpus(&l);
    let accuracy = s.hits as f64 / s.expected as f64;
    assert!(
        accuracy >= l.targets.selection_accuracy,
        "AT-12 selection accuracy {:.1}% is below the {:.0}% target; see target/plan-accuracy.md",
        100.0 * accuracy,
        100.0 * l.targets.selection_accuracy
    );
}

/// The three guarantees AT-12 states separately from the percentage. An 85% average must never
/// be allowed to excuse a workspace with no table.
#[test]
fn at_12_invariants_hold_for_every_fixture() {
    for f in labels().files {
        let (doc, profile) = plan_fixture(&f.path);
        let kinds = emitted(&doc);
        let has = |k: &str| kinds.iter().any(|c| c == k);

        assert!(
            has("data_table"),
            "{}: every workspace keeps every record reachable",
            f.path
        );

        let temporal = profile.fields.iter().any(|p| {
            p.inference.role == FieldRole::Temporal || p.dtype == morphic_model::DataType::Timestamp
        });
        if temporal {
            assert!(
                has("line_chart") || has("timeline"),
                "{}: temporal data must get a time-based view, got {kinds:?}",
                f.path
            );
        }

        let severity = profile
            .fields
            .iter()
            .any(|p| p.inference.role == FieldRole::Severity);
        if severity {
            let error_metric = doc.workspace.components.iter().any(|c| {
                matches!(&c.binding, Binding::MetricCard { aggregation }
                    if aggregation.op == "count" && aggregation.filter.is_some())
            });
            assert!(
                error_metric,
                "{}: severity data must get a restricted error count, not just a total",
                f.path
            );
        }

        assert!(
            doc.workspace.components.len() <= morphic_compiler::MAX_COMPONENTS,
            "{}: {} components exceeds the phone cap",
            f.path,
            doc.workspace.components.len()
        );
        assert!(
            morphic_schema::validate_with_profile(&doc, &profile).is_empty(),
            "{}: the generated document must validate",
            f.path
        );
    }
}

/// A right selection with an unrenderable binding is still a broken workspace.
#[test]
fn every_generated_chart_renders_against_its_own_fixture() {
    let mut failures = Vec::new();
    for f in labels().files {
        for r in render_failures(&f.path) {
            failures.push(format!("{}: {r}", f.path));
        }
    }
    assert!(
        failures.is_empty(),
        "the planner emitted bindings the query layer refuses:\n{}",
        failures.join("\n")
    );
}
