# Scored outputs (`fixtures/expected/`)

Hand-written ground truth for the fixture corpus. The corpus itself is in `../valid/` and
`../malformed/`; this directory says what the *right answer* is, so accuracy can be measured
instead of asserted.

| File | Scores | Consumer |
|---|---|---|
| `schema-labels.json` | per-field dtype + semantic role (AT-02) | `engine/crates/morphic-core/tests/schema_accuracy.rs` |
| *(planned)* `plans.json` | component selection per fixture (AT-12) | M1.4 planner accuracy test |

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
