//! Phase 0 perf-harness skeleton: CSV parse throughput baseline.
//! Run: `cargo bench -p morphic-ingest`. The Dart frame-timing collector and on-device
//! harness arrive in M1.1 (docs/engineering/quality-and-performance.md).

use criterion::{criterion_group, criterion_main, Criterion};

fn generate_csv(rows: usize) -> String {
    let mut s = String::from("id,name,amount,active\n");
    for i in 0..rows {
        s.push_str(&format!(
            "{},name_{},{:.2},{}\n",
            i,
            i,
            (i as f64) * 1.5,
            i % 2 == 0
        ));
    }
    s
}

fn bench_parse(c: &mut Criterion) {
    let csv = generate_csv(10_000);
    c.bench_function("parse_csv_10k_rows", |b| {
        b.iter(|| morphic_ingest::parse_csv(std::hint::black_box(csv.as_bytes())).unwrap())
    });
}

criterion_group!(benches, bench_parse);
criterion_main!(benches);
