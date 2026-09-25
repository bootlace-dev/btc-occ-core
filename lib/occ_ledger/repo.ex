defmodule OccLedger.Repo do
  use Ecto.Repo,
    otp_app: :btc_occ_core,
    adapter: Ecto.Adapters.Postgres
end
