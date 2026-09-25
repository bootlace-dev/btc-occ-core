defmodule OccLedger.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "accounts" do
    field :account_number, :string
    field :account_type, Ecto.Enum, values: [:customer_fiduciary, :omnibus_reserve, :clearing_suspense, :fee_revenue]
    field :currency, Ecto.Enum, values: [:USD, :BTC, :SATS]
    field :created_at, :utc_datetime
  end
end
