defmodule OccLedger.DBWriter do
  @moduledoc """
  A dedicated sequential shock-absorber for PostgreSQL flushes.
  Prevents Ecto connection pool exhaustion by forcing all async DB writes
  into a single queue (concurrency of 1).
  Also manages TB-scale Materialized Checkpoint isolation.
  """
  use GenServer
  alias OccLedger.Repo

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def enqueue_batch(transfers, snapshot_updates) do
    GenServer.cast(__MODULE__, {:flush_batch, transfers, snapshot_updates})
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:flush_batch, transfers, snapshot_updates}, state) do
    flush_to_db_sync(transfers, snapshot_updates)
    {:noreply, state}
  end

  def flush_to_db_sync(transfers, snapshot_updates) do
    tx_count = length(transfers)
    entry_count = tx_count * 2
    
    sql = """
    WITH 
      batch AS (
        INSERT INTO epoch_batches (tx_count, entry_count) VALUES ($1, $2) RETURNING epoch_id
      ),
      txs AS (
        INSERT INTO ledger_transactions (epoch_id, reference_id, description)
        SELECT epoch_id, t.ref_id, 'Memory Batch'
        FROM batch, json_to_recordset($3::json) AS t(ref_id text)
        RETURNING id, reference_id
      ),
      entries AS (
        INSERT INTO ledger_entries (transaction_id, account_id, currency, direction, amount)
        SELECT txs.id, (t.data->>'account_id')::uuid, (t.data->>'currency')::currency_code, (t.data->>'direction')::entry_direction, (t.data->>'amount')::bigint
        FROM txs
        JOIN json_to_recordset($4::json) AS t(ref_id text, data json) ON t.ref_id = txs.reference_id
        RETURNING id
      ),
      snaps AS (
        INSERT INTO account_checkpoints (account_id, currency, epoch_id, settled_balance)
        SELECT (s.data->>'account_id')::uuid, (s.data->>'currency')::currency_code, epoch_id, (s.data->>'settled_balance')::bigint
        FROM batch, json_to_recordset($5::json) AS s(data json)
        ON CONFLICT (account_id, currency, epoch_id) DO UPDATE 
        SET settled_balance = EXCLUDED.settled_balance, updated_at = clock_timestamp()
        RETURNING account_id
      )
    SELECT count(*) FROM entries;
    """
    
    tx_json = Enum.map(transfers, & %{ref_id: &1.ref_id}) |> Jason.encode!()
    
    entries_json = Enum.flat_map(transfers, fn t -> 
      [
        %{ref_id: t.ref_id, data: %{account_id: t.debit_id, currency: t.currency, direction: "debit", amount: t.amount}},
        %{ref_id: t.ref_id, data: %{account_id: t.credit_id, currency: t.currency, direction: "credit", amount: t.amount}}
      ]
    end) |> Jason.encode!()
    
    # Snapshot updates array: format into json array
    snaps_json = Enum.map(snapshot_updates, fn {{acc_id, curr}, bal} -> 
      %{data: %{account_id: acc_id, currency: curr, settled_balance: bal}}
    end) |> Jason.encode!()

    Ecto.Adapters.SQL.query!(Repo, sql, [tx_count, entry_count, tx_json, entries_json, snaps_json])
  end
end
