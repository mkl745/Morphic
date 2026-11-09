# Scored outputs (`fixtures/expected/`)

Hand-written ground truth for the fixture corpus. The corpus itself is in `../valid/` and
`../malformed/`; this directory says what the *right answer* is, so accuracy can be measured
instead of asserted.

| File | Scores | Consumer |
|---|---|---|
| `schema-labels.json` | per-field dtype + semantic role (AT-02) | `engine/crates/morphic-core/tests/schema_accuracy.rs` |
| `plans.json` | component selection per fixture (AT-12) | `engine/crates/morphic-core/tests/plan_accuracy.rs` |

## How to label

**Never run the profiler and copy its output.** That measures the engine against itself and
always scores 100%. Read the file and decide what a person would say the field is.

- **dtype** is what the bytes justify. `01/02/2024` with no value above 12 has an unresolved
  day/month order, so `utf8` is correct even though the field is obviously a date.
- **role** is what the field *means*, independently of its storage type. A CLF timestamp kept
  as text is still `temporal`. An integer column of HTTP status codes is a `dimension`,
  because a mean status code is meaningless.
- **identifier** means the value identifies a row or entity: ids, pids, ordinals. Uniqueness
  in a small sample is not evidence of identity — `latency_ms` and `qty` are measures that
  happen to be distinct in five and twenty rows.
- **text** is an opaque payload a user reads; **dimension** is a category a user groups by.
- A boolean is a two-valued **dimension**.

Where a call is genuinely arguable, the entry carries a `note` explaining the choice. Arguing
with a label is the intended workflow: edit the JSON with a reason, and the diff is reviewable.
Lowering a target to make a run green is not.

## Running the score

```bash
cargo test -p morphic-core --test schema_accuracy
cat target/schema-accuracy.md
```

The test writes the scorecard **before** it asserts, so a failing run still lists every miss.
CI prints the same file in its Rust commit comment. Targets live in the JSON (`targets`), not
in the test, and mirror AT-02: 95% dtype, 85% role.

The scorer also fails on **label drift in both directions** — a labelled column the parser no
longer emits, or an emitted column nobody labelled. An unlabelled column is a hole in the
ground truth, not a free pass.

## Plan labels (AT-12)

```bash
cargo test -p morphic-core --test plan_accuracy
cat target/plan-accuracy.md
```

`plans.json` labels the **multiset of component types** a person would expect for each file — not
ids, titles or order. Whether a log file deserves an error count is a person's call; what the card
is called is the planner's business. Two expected metric cards against one emitted scores 1/2, so a
quietly dropped component is a miss rather than a pass.

The three AT-12 guarantees are asserted **per file, never averaged**: every workspace keeps a table,
every bucketable time axis gets a time view, every severity field gets a restricted error count. An
85% mean must not be able to excuse a workspace with no table.

### The scorer also renders every chart

A selection can be right and still be dead. The first scorecard measured **100% selection with three
charts that failed at the first draw**: the planner proposed a time axis on a `utf8` column (CLF
month names, RFC3164 with no year, unresolved day/month order) and the query layer refuses to bucket
text. All five validator passes were green, because pass 4 checks the *role*.

So every generated chart is rendered against its own fixture, and a render failure is reported beside
the selection score. Selection quality and renderability are different claims; only the second one
is invisible to a set comparison.

The planner now declines those axes. **The labels were not changed to match** — they still ask for a
time view, so those three files score as misses and the corpus keeps reporting the gap until ingest
parses those formats. Current score: 96.6% (85/88), 18/21 exact, 0 unrenderable charts.

## Tuning caveat — read this before quoting the score

The role heuristics in `morphic-semantic` were **revised against this corpus** after the first
scorecard measured 72.2%. The revisions are principled (booleans are categories, prose is not a
key, a name is stronger evidence than a five-row sample), and the vocabularies are ordinary
English field names rather than fixture strings. But the same 21 files were used to find the
problems and to confirm the fix.

**A high score on a corpus the rules were tuned against is an upper bound, not a generalisation
estimate.** To turn it into an estimate:

1. Add files that nobody tuned against — real exports, unfamiliar column names, other locales —
   and score them **before** touching a rule.
2. Keep a held-out split: label new files, run the scorer, and only then decide whether a miss
   is an engine bug or a label error. Both happen; the first scorecard found one of each.
3. Never lower `targets` to make a run green. If the target is wrong, change it in
   `mvp-acceptance-tests.md` with a reason, so the spec and the scorer stay in agreement.

The same caveat applies to `plans.json`: the rule table was written against these 21 files, so its
score is an upper bound too. The two corpora share a failure mode — a label edited to match the
engine stops being ground truth — and the same rule covers both.

Two label decisions are worth knowing because they look like engine bugs and are not:

- `access.log`'s `ident` is `-` on every line. There is no data, so `null` / `unknown` is
  correct. The first scorecard caught this label being wrong.
- `mixed_types.name` and `tolerant_types.name` are labelled `dimension` even though every value
  is unique. Uniqueness in 5 and 20 rows is a property of the sample, not evidence of a key.
