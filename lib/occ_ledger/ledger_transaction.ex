defmodule OccLedger.LedgerTransaction do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "ledger_transactions" do
    field :epoch_id, :integer
    field :reference_id, :string
    field :description, :string
    field :created_at, :utc_datetime
  end
end
