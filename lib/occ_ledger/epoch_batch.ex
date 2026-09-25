defmodule OccLedger.EpochBatch do
  use Ecto.Schema

  @primary_key {:epoch_id, :integer, autogenerate: false}
  schema "epoch_batches" do
    field :batch_nonce, Ecto.UUID
    field :tx_count, :integer
    field :entry_count, :integer
    field :merkle_root, :binary
    field :sealed_at, :utc_datetime
    field :created_at, :utc_datetime
  end
end
