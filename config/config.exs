import Config

config :btc_occ_core, OccLedger.Repo,
  username: "occ_admin",
  password: "occ_secure_password",
  database: "occ_ledger_prod",
  hostname: "localhost",
  port: 5432,
  pool_size: 10
