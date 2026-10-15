//! Placeholder benchmark for the WAL append path (doc 18 §2: hot-path code must
//! have a benchmark under `benches/`). Replaced when the writer lands.

use criterion::{Criterion, criterion_group, criterion_main};

fn wal_append(c: &mut Criterion) {
    c.bench_function("wal_append_placeholder", |b| {
        b.iter(|| std::hint::black_box(0u64));
    });
}

criterion_group!(benches, wal_append);
criterion_main!(benches);
