//! Property tests for plan execution — the verification the plan asks of task 1.3.1
//! ("property tests: filter algebra, sort stability").
//!
//! Seeded and deterministic: no RNG crate, no flakiness, and a failure prints the seed so it
//! can be replayed. `MORPHIC_PROP_CASES` and `MORPHIC_PROP_SEED` override the sweep, the same
//! convention the parser fuzz smoke uses.
//!
//! These check *laws*, not examples. An example test says "this filter returns these rows"; a
//! law says "no filter can disagree with its own double negation", which holds for inputs
//! nobody thought to write down.

use morphic_model::{Column, ColumnValues, DataType, Table};
use morphic_query::{query_groups, query_page, AggSpec, Direction, Nulls, Plan, SortSpec};
use serde_json::{json, Value};

const DEFAULT_CASES: u64 = 300;

fn env_num(name: &str, fallback: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(fallback)
}

/// splitmix64. Same generator as the ingest fuzz smoke, so a seed means the same thing across
/// both suites.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }
}

/// id is the row index, which lets a stability check read source order straight off the result.
fn table(rng: &mut Rng, rows: usize) -> Table {
    let groups = ["alpha", "beta", "gamma", "delta"];
    Table {
        columns: vec![
            Column {
                name: "id".into(),
                dtype: DataType::Int64,
                values: ColumnValues::Int64((0..rows as i64).collect()),
                nulls: vec![false; rows],
            },
            Column {
                name: "grp".into(),
                dtype: DataType::Utf8,
                values: ColumnValues::Utf8(
                    (0..rows)
                        .map(|_| groups[rng.below(groups.len())].to_string())
                        .collect(),
                ),
                nulls: (0..rows).map(|_| rng.below(7) == 0).collect(),
            },
            Column {
                name: "val".into(),
                dtype: DataType::Float64,
                // A small value domain, so ties are common and stability is actually exercised.
                values: ColumnValues::Float64((0..rows).map(|_| rng.below(5) as f64).collect()),
                nulls: (0..rows).map(|_| rng.below(6) == 0).collect(),
            },
            Column {
                name: "flag".into(),
                dtype: DataType::Bool,
                values: ColumnValues::Bool((0..rows).map(|_| rng.below(2) == 0).collect()),
                nulls: (0..rows).map(|_| rng.below(8) == 0).collect(),
            },
        ],
        row_count: rows,
    }
}

fn leaf(rng: &mut Rng) -> Value {
    match rng.below(8) {
        0 => {
            // Bound first: json! parses a leading `[` as an array literal, not an index expr.
            let g = ["alpha", "beta", "gamma"][rng.below(3)];
            json!({"op": "eq", "field": "grp", "value": g})
        }
        1 => json!({"op": "neq", "field": "grp", "value": "delta"}),
        2 => json!({"op": "gte", "field": "val", "value": rng.below(5)}),
        3 => json!({"op": "lt", "field": "val", "value": rng.below(5)}),
        4 => json!({"op": "is_null", "field": "val"}),
        5 => json!({"op": "not_null", "field": "grp"}),
        6 => json!({"op": "in", "field": "grp", "value": ["alpha", "delta"]}),
        _ => json!({"op": "eq", "field": "flag", "value": rng.below(2) == 0}),
    }
}

/// ids of every matching row, unpaged.
fn ids(t: &Table, filter: Value) -> Vec<i64> {
    let page = query_page(
        t,
        &Plan {
            filter: Some(filter),
            limit: 1024,
            ..Default::default()
        },
    )
    .expect("generated plans must be valid");
    page.rows.iter().map(|r| r[0].as_i64().unwrap()).collect()
}

fn sorted_ids(t: &Table, specs: Vec<SortSpec>) -> Vec<i64> {
    query_page(
        t,
        &Plan {
            sort: specs,
            limit: 1024,
            ..Default::default()
        },
    )
    .unwrap()
    .rows
    .iter()
    .map(|r| r[0].as_i64().unwrap())
    .collect()
}

#[test]
fn filter_algebra_laws_hold_for_generated_trees() {
    let cases = env_num("MORPHIC_PROP_CASES", DEFAULT_CASES);
    let base = env_num("MORPHIC_PROP_SEED", 0x4D4F_5250_4849_43);
    let mut checked = 0u64;
    for c in 0..cases {
        let seed = base.wrapping_add(c);
        let mut rng = Rng(seed);
        let t = table(&mut rng, 120);
        let a = leaf(&mut rng);
        let b = leaf(&mut rng);
        let ra = ids(&t, a.clone());
        let rb = ids(&t, b.clone());

        // Double negation.
        let nn = json!({"op":"not","args":[{"op":"not","args":[a.clone()]}]});
        assert_eq!(ids(&t, nn), ra, "double negation, seed {seed:#x}");

        // Idempotence and commutativity of both connectives.
        for op in ["and", "or"] {
            let same = json!({"op":op,"args":[a.clone(), a.clone()]});
            assert_eq!(ids(&t, same), ra, "{op} idempotence, seed {seed:#x}");
            let ab = json!({"op":op,"args":[a.clone(), b.clone()]});
            let ba = json!({"op":op,"args":[b.clone(), a.clone()]});
            assert_eq!(
                ids(&t, ab),
                ids(&t, ba),
                "{op} commutativity, seed {seed:#x}"
            );
        }

        // De Morgan, both directions. Null semantics make this worth checking: `not` complements
        // the match, so the laws must survive rows whose fields are null.
        let not_a = json!({"op":"not","args":[a.clone()]});
        let not_b = json!({"op":"not","args":[b.clone()]});
        let lhs = json!({"op":"not","args":[{"op":"and","args":[a.clone(), b.clone()]}]});
        let rhs = json!({"op":"or","args":[not_a.clone(), not_b.clone()]});
        assert_eq!(
            ids(&t, lhs),
            ids(&t, rhs),
            "De Morgan (and), seed {seed:#x}"
        );
        let lhs = json!({"op":"not","args":[{"op":"or","args":[a.clone(), b.clone()]}]});
        let rhs = json!({"op":"and","args":[not_a, not_b]});
        assert_eq!(ids(&t, lhs), ids(&t, rhs), "De Morgan (or), seed {seed:#x}");

        // Intersection and union agree with set operations on the two result sets.
        let both = json!({"op":"and","args":[a.clone(), b.clone()]});
        let mut want: Vec<i64> = ra.iter().filter(|x| rb.contains(x)).copied().collect();
        want.sort_unstable();
        assert_eq!(ids(&t, both), want, "and == intersection, seed {seed:#x}");
        let either = json!({"op":"or","args":[a.clone(), b.clone()]});
        let mut want: Vec<i64> = ra.iter().chain(rb.iter()).copied().collect();
        want.sort_unstable();
        want.dedup();
        assert_eq!(ids(&t, either), want, "or == union, seed {seed:#x}");

        // Absorption: a OR (a AND b) == a.
        let absorbed = json!({"op":"or","args":[
            a.clone(), {"op":"and","args":[a.clone(), b.clone()]}
        ]});
        assert_eq!(ids(&t, absorbed), ra, "absorption, seed {seed:#x}");
        checked += 1;
    }
    assert_eq!(checked, cases);
    println!("filter algebra: {checked} generated cases, 9 laws each, all held");
}

#[test]
fn filter_and_search_commute() {
    let mut rng = Rng(env_num("MORPHIC_PROP_SEED", 0x5345_4152_4348));
    for _ in 0..60 {
        let t = table(&mut rng, 100);
        let f = leaf(&mut rng);
        let needle = ["alpha", "beta", "gam", "del"][rng.below(4)];
        let both = query_page(
            &t,
            &Plan {
                filter: Some(f.clone()),
                search: Some(needle.into()),
                limit: 1024,
                ..Default::default()
            },
        )
        .unwrap();
        let filtered = ids(&t, f);
        let searched = query_page(
            &t,
            &Plan {
                search: Some(needle.into()),
                limit: 1024,
                ..Default::default()
            },
        )
        .unwrap();
        let searched_ids: Vec<i64> = searched
            .rows
            .iter()
            .map(|r| r[0].as_i64().unwrap())
            .collect();
        let mut want: Vec<i64> = filtered
            .into_iter()
            .filter(|id| searched_ids.contains(id))
            .collect();
        want.sort_unstable();
        let got: Vec<i64> = both.rows.iter().map(|r| r[0].as_i64().unwrap()).collect();
        assert_eq!(got, want, "filter and search must intersect, not override");
    }
}

#[test]
fn sort_is_a_permutation_and_is_ordered_and_stable_and_idempotent() {
    let cases = env_num("MORPHIC_PROP_CASES", DEFAULT_CASES);
    let base = env_num("MORPHIC_PROP_SEED", 0x534F_5254);
    for c in 0..cases {
        let seed = base.wrapping_add(c);
        let mut rng = Rng(seed);
        let t = table(&mut rng, 150);
        let field = ["val", "grp", "flag"][rng.below(3)];
        let dir = if rng.below(2) == 0 {
            Direction::Asc
        } else {
            Direction::Desc
        };
        let nulls = if rng.below(2) == 0 {
            Nulls::Last
        } else {
            Nulls::First
        };
        let specs = vec![SortSpec {
            field: field.into(),
            dir,
            nulls,
        }];
        let got = sorted_ids(&t, specs.clone());

        // 1. A permutation: same multiset of ids, no row invented or dropped.
        let mut want: Vec<i64> = (0..t.row_count as i64).collect();
        let mut seen = got.clone();
        seen.sort_unstable();
        want.sort_unstable();
        assert_eq!(seen, want, "sort must permute, seed {seed:#x}");

        // 2. Ordered, with nulls placed by policy rather than by direction.
        let col = t.columns.iter().find(|c| c.name == field).unwrap();
        for w in got.windows(2) {
            let (a, b) = (w[0] as usize, w[1] as usize);
            let (an, bn) = (col.nulls[a], col.nulls[b]);
            if an || bn {
                if an && !bn {
                    assert_eq!(nulls, Nulls::First, "null placement, seed {seed:#x}");
                } else if bn && !an {
                    assert_eq!(nulls, Nulls::Last, "null placement, seed {seed:#x}");
                }
                continue;
            }
            let ord = morphic_query::sort::compare_cells(col, a, b);
            let ok = match dir {
                Direction::Asc => ord != std::cmp::Ordering::Greater,
                Direction::Desc => ord != std::cmp::Ordering::Less,
            };
            assert!(ok, "order violated at {a},{b}, seed {seed:#x}");
        }

        // 3. Stability: within a run of equal keys, ids ascend (id == source row).
        for w in got.windows(2) {
            let (a, b) = (w[0] as usize, w[1] as usize);
            if !col.nulls[a]
                && !col.nulls[b]
                && morphic_query::sort::compare_cells(col, a, b) == std::cmp::Ordering::Equal
            {
                assert!(a < b, "ties must keep source order, seed {seed:#x}");
            }
        }

        // 4. Idempotence: re-sorting the sorted order changes nothing.
        let mut again: Vec<usize> = got.iter().map(|id| *id as usize).collect();
        morphic_query::sort::sort_selection(&t, &mut again, &specs);
        let again: Vec<i64> = again.into_iter().map(|i| i as i64).collect();
        assert_eq!(again, got, "sort must be idempotent, seed {seed:#x}");
    }
    println!("sort: {cases} generated cases × 4 properties, all held");
}

#[test]
fn paging_covers_every_matching_row_exactly_once() {
    let mut rng = Rng(env_num("MORPHIC_PROP_SEED", 0x5041_4745));
    for _ in 0..40 {
        let t = table(&mut rng, 130);
        let f = leaf(&mut rng);
        let specs = vec![SortSpec::desc("val"), SortSpec::asc("id")];
        let whole = query_page(
            &t,
            &Plan {
                filter: Some(f.clone()),
                sort: specs.clone(),
                limit: 1024,
                ..Default::default()
            },
        )
        .unwrap();
        let want: Vec<i64> = whole.rows.iter().map(|r| r[0].as_i64().unwrap()).collect();

        let mut got = Vec::new();
        let mut offset = 0usize;
        loop {
            let page = query_page(
                &t,
                &Plan {
                    filter: Some(f.clone()),
                    sort: specs.clone(),
                    offset,
                    limit: 7,
                    ..Default::default()
                },
            )
            .unwrap();
            assert_eq!(page.total_rows, whole.total_rows, "total must not drift");
            got.extend(page.rows.iter().map(|r| r[0].as_i64().unwrap()));
            if !page.has_more {
                break;
            }
            offset += page.rows.len();
            assert!(offset <= whole.total_rows, "pager must terminate");
        }
        assert_eq!(got, want, "pages must tile the result exactly");
    }
}

#[test]
fn group_counts_partition_the_matching_rows() {
    let mut rng = Rng(env_num("MORPHIC_PROP_SEED", 0x4752_4F55_50));
    for _ in 0..40 {
        let t = table(&mut rng, 140);
        let f = leaf(&mut rng);
        let matched = ids(&t, f.clone()).len();
        let g = query_groups(
            &t,
            &Plan {
                filter: Some(f),
                group_by: vec!["grp".into()],
                aggs: vec![AggSpec::new("count", None)],
                ..Default::default()
            },
        )
        .unwrap();
        assert!(!g.truncated, "at most 5 groups cannot hit the 2000 cap");
        let summed: i64 = g.rows.iter().map(|r| r[1].as_i64().unwrap()).sum();
        assert_eq!(
            summed as usize, matched,
            "groups must partition the selection"
        );
        assert_eq!(g.rows.len(), g.total_groups);
    }
}
