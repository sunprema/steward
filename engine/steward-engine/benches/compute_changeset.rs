//! Placeholder benchmark for `ComputeChangeset` (doc 18 §2, doc 05 §7).

use criterion::{Criterion, criterion_group, criterion_main};

fn compute_changeset(c: &mut Criterion) {
    c.bench_function("compute_changeset_placeholder", |b| {
        b.iter(|| std::hint::black_box(0u64));
    });
}

criterion_group!(benches, compute_changeset);
criterion_main!(benches);
