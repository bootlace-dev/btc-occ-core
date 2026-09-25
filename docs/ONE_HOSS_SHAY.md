# The "One-Hoss Shay" Catalog of 12 Production Bottlenecks & Invariant Traps
## Engineering Artifact for OCC Fiduciary Bitcoin & Fiat Core Banking Systems

**Author & Systems Architecture**: @bootlace-dev  
**Methodology**: Recursive Multi-Model Adversarial Audit (Asymptotic Falsification Loop v3.0)  
**Target Domain**: High-Throughput Bitcoin & Fiat Core Ledger Architecture under **OCC National Trust Bank Charter (12 CFR Part 9 Fiduciary Standards)** running on **Elixir (Erlang BEAM) and PostgreSQL 16**.

---

### Executive Summary

In Oliver Wendell Holmes' classic poem *The Deacon's Masterpiece*, the deacon builds a "one-hoss shay" (carriage) designed so that every single component is equally strong, ensuring no single part breaks first—until, exactly one hundred years later, the entire carriage collapses into dust all at once.

In financial infrastructure, engineers constantly build the software equivalent of a one-hoss shay: an architecture that looks theoretically elegant on paper, performs gracefully in unit tests, and yet contains subtle, compounding physical impedance mismatches between the application runtime (Erlang BEAM) and the underlying storage substrate (PostgreSQL). Under 10,000+ RPS market volatility spikes (e.g. Bitcoin liquidation cascades), the system does not fail gracefully—it suffers total lock-manager collapse, unbacked balance drift, or catastrophic regulatory insolvency.

This catalog documents the **12 specific production bottlenecks, concurrency traps, and regulatory edge cases** surfaced through an adversarial multi-model falsification harness. It represents the concrete systems physics every scaling Bitcoin custodian faces when bridging the gap between high-concurrency actor runtimes and statutory bank examination.

---

### The 12 Production Vulnerabilities & Architectural Remediations

| # | Vulnerability Class | Root Mechanical Failure Mode |
| :--- | :--- | :--- |
| **01** | **Currency Netting Bypass** | Blind integer `SUM()` trigger enables cross-currency balance minting (1 BTC created via 10,000 pennies). |
| **02** | **Composite Key Cross-Inject** | Lack of composite FK on `(account_id, currency)` allows injecting USD entries into BTC accounts. |
| **03** | **Statement Trigger Abort** | PostgreSQL transition tables fire per-statement; multi-statement Ecto pipelines abort immediately. |
| **04** | **Non-Deferrable Batch Skew** | Multi-row statement triggers cannot be deferred to `COMMIT`; partial inserts cannot balance across steps. |
| **05** | **Non-Transactional Seq Gaps** | `nextval()` allocations never roll back; gaps trigger false-positive alarms in audit sweepers. |
| **06** | **Commit Order ≠ Alloc Order** | Fast Tx B commits before slow Tx A; range sweeper permanently skips and orphans Tx A from Merkle tree. |
| **07** | **Unordered FK Lock Inversion** | PostgreSQL acquires internal `FOR KEY SHARE` locks in physical row order, deadlocking with `ORDER BY ASC`. |
| **08** | **Bilateral Circular Deadlock** | Arbitrary account locking in transfer operations causes `40P01` deadlock cycles in lock manager. |
| **09** | **Visibility Map Heap Storm** | Newly inserted rows lack `VM_ALL_VISIBLE` bit; Index-Only Scans degrade into random disk heap fetches. |
| **10** | **MVCC Balance Tuple Bloat** | In-place balance mutations on 16 omnibus shards generate 625 dead tuples/sec, breaking HOT layout. |
| **11** | **Replication Slot Eviction** | `max_slot_wal_keep_size` invalidates slot on lag, permanently breaking continuous Merkle audit trail. |
| **12** | **Asynchronous Reserve Run** | Post-facto epoch checks allow concurrent micro-batches to deplete 12 CFR § 9.13 omnibus reserves. |

---

### Detailed Failure Traces & Concrete Remediations

#### 1. Multi-Currency Integer Netting Bypass
* **The Failure**: In double-entry schemas, a statement trigger checking `SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END) = 0` operates on raw integers. If currency is not part of the `GROUP BY` clause, an atomic batch inserting a Debit of 100,000,000 USD cents ($1,000,000) and a Credit of 100,000,000 BTC Satoshis (1.0 BTC) evaluates to net zero skew. The database approves the transaction, minting 1 full Bitcoin backed by nominal fiat pennies.
* **The Remediation**: Statement triggers must enforce relational partitioning strictly across `(transaction_id, currency)`:
  ```sql
  SELECT transaction_id, currency,
         SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END)
  FROM new_entries
  GROUP BY transaction_id, currency
  HAVING SUM(...) <> 0;
  ```

#### 2. Composite Relational Integrity Breach (Cross-Currency Injection)
* **The Failure**: Normalizing `accounts (id, currency)` and denormalizing `ledger_entries (id, account_id, currency)` creates an integrity hole if `ledger_entries` only maintains a simple foreign key `FOREIGN KEY (account_id) REFERENCES accounts(id)`. An application bug or malicious script can insert an entry for a BTC account stamped as `currency = 'USD'`. The statement trigger balances `'USD'`, but the BTC account balance is corrupted.
* **The Remediation**: Mandate composite foreign keys across all financial relationships:
  ```sql
  ALTER TABLE accounts ADD CONSTRAINT uq_accounts_id_curr UNIQUE (id, currency);
  ALTER TABLE ledger_entries ADD CONSTRAINT fk_entries_acc_curr 
      FOREIGN KEY (account_id, currency) REFERENCES accounts(id, currency);
  ```

#### 3. Statement Transition Table Multi-Statement Pipeline Abort
* **The Failure**: PostgreSQL transition tables (`REFERENCING NEW TABLE AS new_entries`) materialize strictly per-statement and cannot be deferred (`ERROR: statement triggers cannot be deferrable`). An ORM pipeline (such as standard Ecto multi) that inserts the Debit in Statement 1 and the Credit in Statement 2 immediately aborts on Statement 1 with a zero-sum violation.
* **The Remediation**: Adopt a strict **Single-Statement Atomic Batch Ingestion Contract**. The application layer compiles all balanced pairs into a single multi-row `INSERT INTO ledger_entries ... VALUES (...), (...)` statement or an unnested CTE.

#### 4. PostgreSQL CTE Snapshot Visibility Race on Deferred FKs
* **The Failure**: Combining `epoch_batches`, `ledger_transactions`, and `ledger_entries` into an atomic data-modifying CTE (`WITH new_epoch AS ... new_txs AS ... INSERT INTO ledger_entries ...`) encounters PostgreSQL's snapshot isolation rule: all CTE sub-statements execute with the exact same snapshot. Foreign keys referencing sibling CTE inserts will fail unless constraints are declared `DEFERRABLE INITIALLY DEFERRED` or the CTE explicitly projects the parent rows.
* **The Remediation**: Sequence CTE inserts using projection chaining: `new_txs` selects `(SELECT epoch_id FROM new_epoch)` directly into the transaction tuple.

#### 5. Non-Transactional Sequence Gaps vs Fiduciary Audit Sweepers
* **The Failure**: PostgreSQL sequences (`BIGINT GENERATED ALWAYS AS IDENTITY`) allocate values non-transactionally outside of MVCC to prevent concurrency bottlenecks. When a transaction aborts (e.g. Due to an overdraft), the allocated sequence numbers are permanently skipped. An external auditor or audit sweeper that queries for missing sequence numbers (`SELECT seq FROM generate_series(min, max) EXCEPT SELECT seq FROM ledger_entries`) raises catastrophic false alarms for missing ledger records.
* **The Remediation**: Separate high-throughput concurrency identifiers (UUIDv7) from monotonic gapless audit sequences. Anchor continuous Merkle proofs to discrete `epoch_batches` commits rather than raw row sequence IDs.

#### 6. Commit-Order vs Allocation-Order Race (Orphaned Epoch Rows)
* **The Failure**: High concurrency causes transaction commit order to diverge from sequence allocation order. Transaction A allocates sequence ID 100 at $t_0$, while Transaction B allocates sequence ID 101 at $t_1$. Transaction B commits at $t_2$. Transaction A commits at $t_4$. If an Epoch Sealer queries `WHERE tx_seq BETWEEN 1 AND 101` at $t_3$, Transaction 100 is invisible under MVCC snapshot rules and is skipped. When Transaction 100 commits at $t_4$, it is permanently orphaned outside of any Merkle-sealed epoch.
* **The Remediation**: Never range-scan sequences for epoch sealing. Seal transactions strictly by joining on their explicit foreign key: `WHERE epoch_id = $1`.

#### 7. Unordered Foreign-Key Lock Inversion (40P01)
* **The Failure**: Even when an application sorts rows by `account_id ASC` in application code, PostgreSQL's foreign key validation engine acquires internal `FOR KEY SHARE` locks on referenced `accounts` rows in the physical tuple order of the input array. If two concurrent batches contain overlapping accounts in different array positions, PostgreSQL acquires `FOR KEY SHARE` locks in opposing orders, triggering deadlock `40P01`.
* **The Remediation**: Pre-sort all ledger entry tuples in memory across the entire batch by `account_id ASC` prior to constructing the multi-row insert parameter array.

#### 8. Bilateral Circular Transfer Deadlock
* **The Failure**: User 1 transfers funds to User 2 ($A \to B$) while User 2 transfers funds to User 1 ($B \to A$). If application handlers lock accounts individually (`SELECT ... FOR UPDATE`), Handler 1 locks Account A and waits for Account B, while Handler 2 locks Account B and waits for Account A.
* **The Remediation**: Enforce a global total acquisition order. All multi-account mutations must sort account IDs lexicographically (`ORDER BY id ASC`) before executing pessimistic row locks.

#### 9. Visibility Map Heap Thrashing Under Index-Only Scans
* **The Failure**: High-frequency balance lookups (`SELECT SUM(...) FROM ledger_entries WHERE account_id = $1`) rely on covering indexes (`idx_entries_account_currency_cov INCLUDE (direction, amount)`). However, newly inserted rows reside on dirty shared buffer pages where the PostgreSQL Visibility Map has not set `VM_ALL_VISIBLE`. PostgreSQL is forced to perform random disk heap accesses to verify tuple visibility, destroying query throughput.
* **The Remediation**: Maintain an incremental rolling rollup table (`account_checkpoints`) updated at epoch boundaries, querying `settled_balance + SUM(recent_entries)` rather than scanning the entire historical table.

#### 10. MVCC Dead Tuple Bloat on Hot Sharded Accounts
* **The Failure**: Storing a mutable `settled_balance` column on omnibus reserve or fee accounts updated hundreds of times per second produces massive dead tuple churn. PostgreSQL's Heap-Only Tuples (HOT) optimization fails when index attributes or page fillfactors saturate, triggering aggressive autovacuum worker starvation and connection pool lockups.
* **The Remediation**: Completely eliminate mutable balance columns from the hot transaction path. The core ledger table is strictly append-only.

#### 11. CDC Logical Replication Slot Invalidation
* **The Failure**: Relying on PostgreSQL logical decoding (`pgoutput`) to stream transactions to an external Merkle audit worker creates an operational single point of failure. If the consumer halts or lags during high-volume spikes, WAL files accumulate on the primary until `max_slot_wal_keep_size` is exceeded, at which point PostgreSQL forcefully drops the replication slot to save disk space, permanently breaking the continuous audit stream.
* **The Remediation**: Store epoch batch boundaries natively in-database (`epoch_batches`). The Merkle Sealer runs as an idempotent worker reading committed database tables directly.

#### 12. Asynchronous Fiduciary Reserve Depletion (12 CFR § 9.13 Run)
* **The Failure**: Validating omnibus reserve backing asynchronously (e.g. In the EpochSealer every 5 seconds) introduces a 5,000ms window where malicious or panicked withdrawals can drain customer liabilities beyond available omnibus custody reserves, violating OCC fiduciary solvency in real time.
* **The Remediation**: Synchronous reservation check at the coordination layer. High-frequency withdrawals check and decrement an in-memory BEAM atomic reservation pool synchronized with the latest database checkpoint before dispatching the database transaction.

---

### Intellectual Homage & Systems Literature

This architecture and failure catalog are directly informed by the foundational mechanical principles articulated in **Dimitri Fontaine's *The Art of PostgreSQL***, specifically:
- Treating SQL as a high-level concurrent programming language rather than a passive bit-bucket.
- Exploiting Transition Tables (`REFERENCING NEW TABLE`) for set-oriented business invariant assertions.
- Mastering MVCC visibility mechanics, HOT tuple ergonomics, and index-only scan constraints.
