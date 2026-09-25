Application.ensure_all_started(:btc_occ_core)
# Clear old WAL data
File.rm("occ_transactions.wal")
# Execute heavy load test (1,000,000 total txns across 500 workers)
OccLedger.LoadGenerator.run(2000, 500)
