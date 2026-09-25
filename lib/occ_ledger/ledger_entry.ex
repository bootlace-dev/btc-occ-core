defmodule OccLedger.LedgerEntry do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "ledger_entries" do
    field :transaction_id, :binary_id
    field :account_id, :binary_id
    field :currency, Ecto.Enum, values: [:USD, :BTC, :SATS]
    field :direction, Ecto.Enum, values: [:debit, :credit]
    field :amount, :integer
    field :created_at, :utc_datetime
  end
end
