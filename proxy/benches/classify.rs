//! Placeholder benchmark for statement classification, which is on the per-query
//! hot path (doc 18 §2, doc 04 §7).

use criterion::{Criterion, criterion_group, criterion_main};

fn classify(c: &mut Criterion) {
    c.bench_function("classify_placeholder", |b| {
        b.iter(|| std::hint::black_box(0u64));
    });
}

criterion_group!(benches, classify);
criterion_main!(benches);
