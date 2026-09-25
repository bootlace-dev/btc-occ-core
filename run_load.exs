Application.ensure_all_started(:btc_occ_core)
OccLedger.LoadGenerator.run(20, 100)
