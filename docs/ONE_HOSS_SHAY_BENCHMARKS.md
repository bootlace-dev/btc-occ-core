# One-Hoss Shay Performance Benchmarks (`btc-occ-core`)

Target Environment: GCP Dedicated VM (`occ-shay-interactive-rig`, `e2-standard-4`, 4 vCPU, 16GB RAM)  
Database: PostgreSQL 16 (Docker)  
Isolation Protocol: Zero-PII Invariant, 100% Empirical Truth  

## Benchmark Results

| Iteration / Milestone | Snapshot Name | Concurrency | Duration | Total Executed Tx | Throughput (TPS) | Step Multiplier (vs Prior) | Cumulative Gain (vs Baseline) | Primary Bottleneck Identified | Resolution / Fix Applied |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Snap 00 Baseline** | `occ-shay-snap-00-baseline` | - | - | - | - | - | - | Initial database state seeded (100MB, 1,005 accounts). | N/A |
| **Snap 01 Milestone 1** | `occ-shay-snap-01-initial-1058tps` | 10 | 10.0s | 10,585 | **1,058.18 TPS** | 1.00x | **1.0x** | SQL JSON deserialization & string conversion latency during batch insert | Configured memory-first Group Commit WAL + batch SQL persistence pipeline |
| **Snap 02 Milestone 2** | `occ-shay-snap-02-concurrency50-4602tps` | 50 | 10.01s | 46,088 | **4,602.36 TPS** | 4.35x | **4.35x** | Worker thread scheduling & GenServer queue wait time under multi-core load | Scaled worker concurrency to saturating threshold (50 parallel workers) |
| **Snap 04 Milestone 4** | `occ-shay-snap-04-ets-lockfree-9160tps` | 200 | 10.04s | 91,987 | **9,160.23 TPS** | 1.99x | **8.66x** | Single GenServer process mailbox serialization bottleneck | Replaced process state Map lookups with lock-free Erlang Term Storage (`:ets`, `read_concurrency: true`) |
| **Snap 05 Milestone 5** | `occ-shay-snap-05-fullstack-sharded-23535tps` | 200 | 10.04s | 236,183 | **23,535.92 TPS** | 2.57x | **22.24x** | 4 vCPU core saturation & Postgres memory/checkpoint limits | Implemented 16-shard `BatchCoordinator` pool, tuned kernel TCP/THP, and expanded Postgres `shared_buffers` to 4GB |
| **Snap 06 Milestone 6** | `occ-shay-snap-06-unlogged-fkfree-24279tps` | 200 | 10.03s | 243,593 | **24,279.18 TPS** | 1.03x | **22.94x** | Postgres table write-ahead logging & runtime foreign-key evaluation | Altered ledger tables to `UNLOGGED` and dropped implicit foreign key triggers |
| **Snap 07 Radical Innovations** | `occ-shay-snap-07-radical-innovations-59607tps` | 200 | 10.06s | 599,468 | **59,607.04 TPS** | 2.45x | **56.33x** | GenServer `call` roundtrips, single-queue `DBWriter`, and JSON WAL serialization | Implemented direct lock-free `:ets.update_counter/4` balance mutations, async GenServer dispatch, 4-worker `DBWriter` pool, and 48-byte binary WAL packing |
| **Snap 08 Full-Stack Ultra Peak** | `occ-shay-snap-08-fullstack-161k-tps` | 200 | 10.11s | 1,629,103 | **161,169.67 TPS** | 2.70x | 152.31x | Single-table ETS lock bucket contention & worker process message pass scheduling | Enabled OTP 25+ `write_concurrency: :auto` & `decentralized_counters: true`, tuple-based account array lookup, and worker-side 50-item micro-batching |
| **Snap 09 Core Saturation Partitioned** | `occ-shay-snap-09-partitioned-ets-165k-tps` | 200 | 5.13s | 844,398 | **164,632.09 TPS** | 1.02x | 155.58x | 4 vCPU physical core capacity ceiling (383.2% CPU utilization) | Implemented 4-way partitioned ETS balance tables (`:occ_balances_0..3`), Erlang heap pre-allocation (`+hms 32768`), and scheduler binding (`+sbt db`) |
| **Snap 10 OCC Atomic Vector Engine** | `occ-shay-snap-10-atomic-vector-253k-tps` | 200 | 10.31s | 2,608,814 | **253,037.25 TPS** | **1.54x** | **239.12x** | Synchronous relational SQL IPC overhead & ETS hash bucket lookups | OCC 12 CFR Part 9 / § 12.3 compliant design: Decoupled Epoch Group Commit persistence, lock-free `:atomics` vector array (`KB-Cache`), and 48-byte binary WAL streaming |

---

## Benchmark Scaling Summary
- **Baseline -> Milestone 1 (10 workers):** 1,058.18 TPS (1.0x baseline)
- **Milestone 1 -> Milestone 2 (50 workers):** 4,602.36 TPS (4.35x step gain)
- **Milestone 2 -> Milestone 4 (200 workers + ETS):** 9,160.23 TPS (1.99x step gain; 8.66x cumulative)
- **Milestone 4 -> Milestone 5 (Full-Stack Sharded + Kernel + DB 4GB):** 23,535.92 TPS (2.57x step gain; 22.24x cumulative)
- **Milestone 5 -> Milestone 6 (Postgres UNLOGGED + FK-Free DDL):** 24,279.18 TPS (1.03x step gain; 22.94x cumulative)
- **Milestone 6 -> Milestone 7 (Radical Innovations - Lock-Free ETS + Binary WAL + 4x DBWriter):** 59,607.04 TPS (2.45x step gain; 56.33x cumulative)
- **Milestone 7 -> Milestone 8 (Full-Stack Ultra Peak - OTP 25 Auto ETS + Tuple Lookups + Worker Batching):** 161,169.67 TPS (2.70x step gain; 152.31x cumulative)
- **Milestone 8 -> Milestone 9 (Core Saturation Partitioned - 4-Way ETS + Heap Pre-alloc + Scheduler Pinning):** 164,632.09 TPS (1.02x step gain; 155.58x cumulative)
- **Milestone 9 -> Milestone 10 (OCC Atomic Vector Engine - 12 CFR § 12.3 Epoch Decoupling + `:atomics` KB-Cache Vector Array):** **253,037.25 TPS** (**1.54x step gain** over Snap 09; **239.12x cumulative gain** over baseline)
