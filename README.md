# `btc-occ-core`
## High-Throughput Bitcoin & Fiat Double-Entry Ledger Engine for OCC National Trust Bank Charters (12 CFR Part 9)

[![PostgreSQL 16](https://img.shields.io/badge/PostgreSQL-16.x-336791.svg)](https://www.postgresql.org/)
[![Elixir BEAM](https://img.shields.io/badge/Elixir-1.15+-4B275F.svg)](https://elixir-lang.org/)
[![Regulatory Standard](https://img.shields.io/badge/OCC-12_CFR_Part_9-darkgreen.svg)](https://www.ecfr.gov/current/title-12/chapter-I/part-9)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An open-source reference ledger engine engineered to bridge the high-concurrency impedance mismatch between **Erlang BEAM (Elixir)** and **PostgreSQL 16**, maintaining statutory fiduciary asset segregation and real-time double-entry zero-sum guarantees under 10,000+ RPS market volatility spikes.

---

### Architectural Overview

Scaling institutional Bitcoin custodians and OCC-chartered trust banks face severe concurrency and regulatory constraints:
1. **BEAM-to-RDBMS Impedance**: BEAM manages $10^5$ lightweight concurrent actor processes; PostgreSQL connection pools are physically constrained (30–100 connections) to avoid kernel context-switching thrash.
2. **Statutory OCC Fiduciary Mandates (12 CFR § 9.13)**: Customer custodial assets (Bitcoin satoshis and USD cents) must remain strictly segregated from proprietary operating capital, with zero balance drift, immutable ledger entries, and non-negative balance constraints.
3. **Multi-Currency Zero-Sum**: In dual-currency systems, blind integer triggers create catastrophic netting holes (e.g. exchanging 100M satoshis for 100M pennies). Zero-sum must be enforced strictly per currency.

```
                  [Concurrent Client Traffic: 10,000+ RPS]
                                    │
                                    ▼
                [Phoenix Router / Domain Entrypoint]
                                    │
       ┌────────────────────────────┴────────────────────────────┐
       │ (Mutations: Deposit, Trade, Withdrawal)                 │ (Telemetry, Queries, Reports)
       ▼                                                         ▼
[OccLedger.BatchIngestCoordinator]                       [OccLedger.AnalyticsRepo]
  ├── Multi-Producer / Single-Drainer Batch Queue          ├── Read Replica Pool (20 conns)
  ├── Sorts Accounts Lexicographically in Memory           ├── Native CoDel Queue Shedding
  ├── Drains every 5ms / 100 Transactions                  └── Dynamic Throttling under Spikes
  └── Submits Single Atomic CTE Multi-Row Transaction             │
       │                                                         │
       ▼                                                         ▼
[OccLedger.CoreRepo (PostgreSQL 16 Storage Engine)]
  ├── Dedicated Connection Pool (30 conns)
  ├── epoch_batches (Authoritative monotonic epoch_id per batch commit)
  ├── ledger_transactions (Foreign Key: epoch_id REFERENCES epoch_batches)
  ├── ledger_entries (Composite FK: (account_id, currency) REFERENCES accounts)
  ├── Multi-Currency Statement Transition Trigger (Enforces sum(D) == sum(C) PER CURRENCY)
  └── Covering Index: idx_entries_account_currency_cov INCLUDE (direction, amount)
```

---

### Core Engineering Invariants

1. **Multi-Currency Zero-Sum Isolation**:
   Evaluated strictly per currency within each transaction using PostgreSQL 16 Statement Transition Tables (`REFERENCING NEW TABLE`):
   $$\sum_{i} \text{Debit}_i - \sum_{j} \text{Credit}_j = 0 \quad \forall \; C \in \{\text{'USD'}, \text{'BTC'}, \text{'SATS'}\}$$

2. **Composite Relational Integrity**:
   Accounts define `UNIQUE (id, currency)`. All ledger entries enforce composite foreign key references:
   ```sql
   CONSTRAINT fk_entries_account_currency 
       FOREIGN KEY (account_id, currency) 
       REFERENCES accounts(id, currency) ON DELETE RESTRICT
   ```
   Completely eliminates cross-currency injection attacks.

3. **Deterministic Foreign-Key Lock Ordering**:
   `BatchIngestCoordinator` pre-sorts all batch entries by `account_id ASC` in memory before statement generation, preventing PostgreSQL's internal `FOR KEY SHARE` row-locking mechanism from triggering deadlock cycles (`SQLSTATE 40P01`).

4. **Discrete Monotonic Epoch Sealing**:
   Transactions explicitly reference an `epoch_id` foreign key committed in the same atomic CTE batch. Merkle sealing operates strictly over `WHERE epoch_id = $1`, eliminating sequence race conditions and slow-committing transaction orphans.

---

### The "One-Hoss Shay" Catalog of 12 Failure Modes

This architecture was developed using a recursive adversarial falsification harness, uncovering 12 specific production failure modes in high-throughput ledger engines. See the complete analysis in [docs/ONE_HOSS_SHAY.md](docs/ONE_HOSS_SHAY.md):

1. **Currency Netting Bypass**: Blind integer `SUM()` enabling cross-currency balance minting.
2. **Composite Key Cross-Inject**: Mismatched currency entry injection into single-currency accounts.
3. **Statement Trigger Abort**: Non-deferrable transition table aborts on multi-statement pipelines.
4. **Non-Deferrable Batch Skew**: Partial insert evaluation failure across separate Ecto operations.
5. **Non-Transactional Seq Gaps**: Sequence gap alarms during regulatory audit sweeps.
6. **Commit Order ≠ Alloc Order**: Range-based epoch sealers orphaning slow-committing transactions.
7. **Unordered FK Lock Inversion**: Internal PostgreSQL `FOR KEY SHARE` deadlock cycles (`40P01`).
8. **Bilateral Circular Deadlock**: Lock-order inversions during simultaneous bidirectional user transfers.
9. **Visibility Map Heap Storm**: Index-Only Scans degrading to random disk reads on dirty pages.
10. **MVCC Balance Tuple Bloat**: Dead-tuple churn on hot omnibus reserve accounts breaking HOT optimization.
11. **Replication Slot Eviction**: `max_slot_wal_keep_size` invalidating CDC slots during lag.
12. **Asynchronous Reserve Run**: Post-facto epoch checks failing to prevent real-time 12 CFR § 9.13 reserve breaches.

---

### Quick Start & Verification

#### Prerequisites
- Docker & Docker Compose
- Python 3.8+ (for invariant falsification test suite)

#### 1. Run PostgreSQL 16 Cluster
```bash
docker compose up -d postgres
```

#### 2. Run the Invariant Falsification Suite
```bash
python3 scripts/run_falsification_suite.py
```

Expected output:
```text
================================================================================
▶ Running btc-occ-core Invariant Falsification Suite
================================================================================
[TEST 1] Verifying Multi-Currency Zero-Sum Isolation Logic...
  ✓ PASS: Multi-currency netting bypass successfully blocked.
[TEST 2] Verifying Composite Foreign Key Invariant (account_id, currency)...
  ✓ PASS: Composite foreign key constraint successfully rejected cross-currency injection.
[TEST 3] Verifying Deterministic In-Memory Account Pre-Sorting...
  ✓ PASS: Total lexicographical ordering eliminates 40P01 bilateral lock inversions.
================================================================================
🎉 All 3 Invariant Falsification Gates PASSED with Zero Defects.
================================================================================
```

---

### Intellectual Homage

Architectural principles and PostgreSQL mechanical optimization directly inspired by **Dimitri Fontaine's *The Art of PostgreSQL***.

---

### License

MIT License. See [LICENSE](LICENSE) for details.
