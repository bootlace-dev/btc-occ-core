# Baseline Checkpoint

## Environment
* Target: c2-standard-4 (Simulated via current execution environment)
* OS: Ubuntu / Linux Kernel
* DB: PostgreSQL 16 (Dockerized, parameters overridden per docker-compose.yml)
* Application: Elixir 1.15 / Ecto 3.14

## Constraints & Blindspots Acknowledged
1. **Mock Mentality**: As a POC, this baseline intentionally executes unoptimized sequential inserts without a mempool boundary.
2. **Infrastructure**: We are bypassing a true `bitcoind` Regtest/Testnet4 node, assuming instant L1 state resolution. Future iterations targeting CPFP and Package Relay strictly require cottage infra (dedicated `bitcoind` testnet nodes) for true mempool validation.
3. **Double-Entry Tax**: The `verify_multi_currency_double_entry` SQL trigger forces the naive processor to use `Repo.insert_all` rather than separate statements, masking some ORM inefficiencies but preserving the 6-round-trip penalty.

## Baseline Run Results
* **Throughput**: ~1,524 TPS
* **Execution**: 2,000 transactions in ~1312ms.
* **Limiting Factor**: 6 Network Round-Trips per transaction combined with Ecto connection pool saturation (10 connections).
