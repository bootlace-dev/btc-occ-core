defmodule OccLedger.MixProject do
  use Mix.Project

  def project do
    [
      app: :btc_occ_core,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "High-Throughput Bitcoin & Fiat Double-Entry Ledger Engine for OCC National Trust Bank Charters (12 CFR Part 9) on Erlang BEAM + PostgreSQL 16"
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {OccLedger.Application, []}
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.17.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"}
    ]
  end
end
