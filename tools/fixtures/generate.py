#!/usr/bin/env python3
"""Deterministic synthetic fixtures for the retail schema (doc 17 §11).

    python3 tools/fixtures/generate.py --size s [--seed 42] [--out DIR]

Writes one CSV per table to ``tools/fixtures/out/<size>/`` plus a ``MANIFEST``
with the SHA-256 of every file. Output for a given (seed, size, GENERATOR_VERSION)
is byte-identical across runs and machines; CI pins the digests (doc 17 §11).

Guarantees the tests rely on:

* Every string column embeds the sentinel ``ZQX-<seed>`` in a fixed fraction of
  rows (``SENTINEL_EVERY``: 1 row in 100, chosen by row index) so log-leak tests
  can grep for it in any table.
* Exactly ``UNDERPRICED_EVERY`` (1 in 50 = 2 %) of ``prices`` rows have
  ``price < products.cost``; every other row has ``price > cost``.
* Rows stream straight to disk; nothing is accumulated in memory, so ``xl``
  (10M products, 10M invoices) runs in constant memory.
* Python 3.11+, standard library only.

The schema of each CSV matches ``schema.sql`` minus ``last_modified``, which the
database fills at load time.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import os
import random
import shutil
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

GENERATOR_VERSION = "1"
SCHEMA_VERSION = "1"

# Row counts from doc 17 §11. ledger_entries is not sized by the doc; it follows
# invoices (one posting per invoice) so the fold-table generators have a bigint
# PK table of the same magnitude.
SIZES: dict[str, dict[str, int]] = {
    "s":  {"products": 1_000,      "customers": 500,       "invoices": 5_000},
    "m":  {"products": 100_000,    "customers": 20_000,    "invoices": 200_000},
    "l":  {"products": 1_000_000,  "customers": 200_000,   "invoices": 2_000_000},
    "xl": {"products": 10_000_000, "customers": 1_000_000, "invoices": 10_000_000},
}

SENTINEL_EVERY = 100      # 1 % of rows carry the sentinel in every string column
UNDERPRICED_EVERY = 50    # 2 % of prices rows have price < cost

# Tables in FK order; the loader copies them in this order.
TABLES = ["products", "prices", "inventory", "customers", "invoices", "ledger_entries"]

COLUMNS = {
    "products":       ["sku", "name", "category", "cost"],
    "prices":         ["sku", "price", "currency", "updated_at"],
    "inventory":      ["sku", "qty", "received_at"],
    "customers":      ["id", "name", "email", "segment"],
    "invoices":       ["id", "customer_id", "status", "total", "issued_at"],
    "ledger_entries": ["id", "account", "amount", "posted_at"],
}

CATEGORIES = ["apparel", "electronics", "grocery", "home", "toys", "sports", "beauty", "garden"]
ADJECTIVES = ["Compact", "Classic", "Premium", "Basic", "Eco", "Pro", "Mini", "Max", "Ultra", "Lite"]
NOUNS = ["Lamp", "Kettle", "Jacket", "Sneaker", "Headset", "Blender", "Backpack", "Tent",
         "Notebook", "Speaker", "Mug", "Chair", "Drill", "Scarf", "Monitor", "Puzzle"]
CURRENCIES = ["USD", "USD", "USD", "EUR", "GBP"]       # weighted
SEGMENTS = ["consumer", "smb", "enterprise", "partner"]
FIRST = ["Ada", "Ben", "Chloe", "Dev", "Elin", "Femi", "Gus", "Hana", "Ivo", "Jun",
         "Kai", "Lea", "Max", "Nia", "Omar", "Pia", "Quin", "Rui", "Sam", "Tove"]
LAST = ["Abara", "Berg", "Chen", "Diaz", "Evans", "Fischer", "Garcia", "Haddad", "Ito", "Jensen",
        "Kowal", "Lund", "Mori", "Nakamura", "Okafor", "Patel", "Quist", "Rossi", "Silva", "Tan"]
DOMAINS = ["example.com", "example.org", "example.net", "mail.example"]
STATUSES = ["draft", "issued", "paid", "paid", "paid", "void"]
ACCOUNTS = ["1000-cash", "1200-receivable", "2000-payable", "4000-revenue", "5000-cogs", "6100-shipping"]

EPOCH = datetime(2025, 1, 1, tzinfo=timezone.utc)


def sentinel(seed: int) -> str:
    return f"ZQX-{seed}"


def ts(seconds: int) -> str:
    """Fixed-format UTC timestamp (no microseconds, stable across platforms)."""
    return (EPOCH + timedelta(seconds=seconds)).strftime("%Y-%m-%d %H:%M:%S+00")


def money(x: float) -> str:
    return f"{x:.2f}"


def customer_id(seed: int, i: int) -> str:
    """Customer UUIDs are a pure function of (seed, index) so invoices can
    reference them without keeping the customer table in memory."""
    digest = hashlib.blake2b(f"{seed}:customer:{i}".encode(), digest_size=16).digest()
    return str(uuid.UUID(bytes=digest, version=4))


def row_uuid(rng: random.Random) -> str:
    return str(uuid.UUID(int=rng.getrandbits(128), version=4))


class HashingWriter:
    """Text sink that writes to a file and feeds a SHA-256 at the same time."""

    def __init__(self, path: Path):
        self.path = path
        self._fh = open(path, "w", encoding="utf-8", newline="")
        self._sha = hashlib.sha256()
        self._buf = io.StringIO()
        self.csv = csv.writer(self._buf, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
        self.rows = 0

    def writerow(self, row) -> None:
        self.csv.writerow(row)
        self.rows += 1
        if self._buf.tell() > 1 << 16:
            self._flush_buf()

    def _flush_buf(self) -> None:
        data = self._buf.getvalue()
        self._buf.seek(0)
        self._buf.truncate()
        self._fh.write(data)
        self._sha.update(data.encode("utf-8"))

    def close(self) -> str:
        self._flush_buf()
        self._fh.close()
        return self._sha.hexdigest()


def table_rng(seed: int, table: str) -> random.Random:
    # One independent stream per table so adding a column to one table does not
    # reshuffle the others.
    return random.Random(f"steward-fixtures:{GENERATOR_VERSION}:{seed}:{table}")


def gen_products_prices_inventory(out: Path, seed: int, n: int, manifest: dict[str, tuple[str, int]]) -> None:
    """products, prices and inventory in one pass so prices can see cost
    without a lookup table."""
    rng_p = table_rng(seed, "products")
    rng_pr = table_rng(seed, "prices")
    rng_inv = table_rng(seed, "inventory")
    mark = sentinel(seed)

    w_p = HashingWriter(out / "products.csv")
    w_pr = HashingWriter(out / "prices.csv")
    w_inv = HashingWriter(out / "inventory.csv")
    for w, t in ((w_p, "products"), (w_pr, "prices"), (w_inv, "inventory")):
        w.writerow(COLUMNS[t])

    for i in range(n):
        tagged = i % SENTINEL_EVERY == 0
        sku = f"SKU-{i:08d}"
        name = f"{rng_p.choice(ADJECTIVES)} {rng_p.choice(NOUNS)} {rng_p.randrange(100, 1000)}"
        category = rng_p.choice(CATEGORIES)
        cost = round(rng_p.uniform(1.0, 500.0), 2)
        if tagged:
            name = f"{name} {mark}"
            category = f"{category}-{mark}"
        w_p.writerow([sku, name, category, money(cost)])

        # Exactly 1 in UNDERPRICED_EVERY rows is priced below cost.
        if i % UNDERPRICED_EVERY == 0:
            price = round(cost * rng_pr.uniform(0.50, 0.95), 2)
            if price >= cost:  # cannot happen for cost >= 1.00, but keep the invariant explicit
                price = round(cost - 0.01, 2)
        else:
            price = round(cost * rng_pr.uniform(1.05, 3.00), 2)
        currency = rng_pr.choice(CURRENCIES)
        if tagged:
            currency = f"{currency}-{mark}"
        updated_at = ts(rng_pr.randrange(0, 180 * 86400))
        w_pr.writerow([sku, money(price), currency, updated_at])

        qty = rng_inv.randrange(0, 5000)
        received_at = ts(rng_inv.randrange(0, 180 * 86400))
        w_inv.writerow([sku, qty, received_at])

    for w, t in ((w_p, "products"), (w_pr, "prices"), (w_inv, "inventory")):
        manifest[f"{t}.csv"] = (w.close(), w.rows - 1)


def gen_customers(out: Path, seed: int, n: int, manifest: dict[str, tuple[str, int]]) -> None:
    rng = table_rng(seed, "customers")
    mark = sentinel(seed)
    w = HashingWriter(out / "customers.csv")
    w.writerow(COLUMNS["customers"])
    for i in range(n):
        tagged = i % SENTINEL_EVERY == 0
        first, last = rng.choice(FIRST), rng.choice(LAST)
        name = f"{first} {last}"
        local = f"{first.lower()}.{last.lower()}.{i}"
        domain = rng.choice(DOMAINS)
        segment = rng.choice(SEGMENTS)
        if tagged:
            name = f"{name} {mark}"
            local = f"{local}+{mark}"   # sentinel kept verbatim (case-sensitive grep)
            segment = f"{segment}-{mark}"
        email = f"{local}@{domain}"
        w.writerow([customer_id(seed, i), name, email, segment])
    manifest["customers.csv"] = (w.close(), w.rows - 1)


def gen_invoices_ledger(out: Path, seed: int, n: int, n_customers: int, manifest: dict[str, tuple[str, int]]) -> None:
    rng_i = table_rng(seed, "invoices")
    rng_l = table_rng(seed, "ledger_entries")
    mark = sentinel(seed)
    w_i = HashingWriter(out / "invoices.csv")
    w_l = HashingWriter(out / "ledger_entries.csv")
    w_i.writerow(COLUMNS["invoices"])
    w_l.writerow(COLUMNS["ledger_entries"])
    for i in range(n):
        tagged = i % SENTINEL_EVERY == 0
        inv_id = row_uuid(rng_i)
        cust = customer_id(seed, rng_i.randrange(n_customers))
        status = rng_i.choice(STATUSES)
        total = round(rng_i.uniform(5.0, 5000.0), 2)
        issued = rng_i.randrange(0, 270 * 86400)
        if tagged:
            status = f"{status}-{mark}"
        w_i.writerow([inv_id, cust, status, money(total), ts(issued)])

        # One ledger posting per invoice; sign by account type.
        account = rng_l.choice(ACCOUNTS)
        amount = round(rng_l.uniform(-5000.0, 5000.0), 2)
        if tagged:
            account = f"{account}-{mark}"
        w_l.writerow([i + 1, account, money(amount), ts(issued + rng_l.randrange(0, 3 * 86400))])
    manifest["invoices.csv"] = (w_i.close(), w_i.rows - 1)
    manifest["ledger_entries.csv"] = (w_l.close(), w_l.rows - 1)


def write_manifest(out: Path, seed: int, size: str, manifest: dict[str, tuple[str, int]]) -> None:
    lines = [
        f"# steward fixtures  size={size} seed={seed} "
        f"generator_version={GENERATOR_VERSION} schema_version={SCHEMA_VERSION}",
        f"# sentinel={sentinel(seed)} sentinel_every={SENTINEL_EVERY} underpriced_every={UNDERPRICED_EVERY}",
        "# sha256  rows  file",
    ]
    for t in TABLES:
        digest, rows = manifest[f"{t}.csv"]
        lines.append(f"{digest}  {rows}  {t}.csv")
    (out / "MANIFEST").write_text("\n".join(lines) + "\n", encoding="utf-8")


def generate(size: str, seed: int, out_root: Path, quiet: bool = False) -> Path:
    counts = SIZES[size]
    out = out_root / size
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    manifest: dict[str, tuple[str, int]] = {}

    def say(msg: str) -> None:
        if not quiet:
            print(msg, file=sys.stderr)

    say(f"generating size={size} seed={seed} -> {out}")
    gen_products_prices_inventory(out, seed, counts["products"], manifest)
    say(f"  products/prices/inventory: {counts['products']} rows each")
    gen_customers(out, seed, counts["customers"], manifest)
    say(f"  customers: {counts['customers']} rows")
    gen_invoices_ledger(out, seed, counts["invoices"], counts["customers"], manifest)
    say(f"  invoices/ledger_entries: {counts['invoices']} rows each")
    write_manifest(out, seed, size, manifest)
    say(f"  MANIFEST written")
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--size", choices=sorted(SIZES, key=lambda s: SIZES[s]["products"]), default="s")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--out", type=Path, default=Path(__file__).resolve().parent / "out",
                   help="output root; CSVs go to <out>/<size>/ (default: tools/fixtures/out)")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)
    if sys.version_info < (3, 11):
        p.error("Python 3.11+ required")
    out = generate(args.size, args.seed, args.out, args.quiet)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
