defmodule OccLedger.BatchCoordinator do
  use GenServer
  alias OccLedger.Repo
  import Ecto.Query

  # API
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def transfer(debit_id, credit_id, currency, amount, ref_id) do
    GenServer.call(__MODULE__, {:transfer, debit_id, credit_id, currency, amount, ref_id})
  end

  def flush_sync() do
    GenServer.call(__MODULE__, :flush_sync, 60_000)
  end

  # Callbacks
  @impl true
  def init(_) do
    # 1. WAL REPLAY (Crash Recovery)
    replay_wal_if_needed()

    # 2. TB-SCALE BOOT: Fetch from O(1) Checkpoints instead of O(N) Table Summation
    sql = """
    SELECT DISTINCT ON (account_id, currency) account_id, currency, settled_balance
    FROM account_checkpoints
    ORDER BY account_id, currency, epoch_id DESC;
    """
    
    result = Ecto.Adapters.SQL.query!(Repo, sql, [])
    balances = Enum.map(result.rows, fn [acc, curr, bal] -> 
      {{acc, String.to_atom(curr)}, bal}
    end) |> Enum.into(%{})

    # 3. OPEN WAL FOR APPENDING
    {:ok, wal_file} = :file.open(~c"occ_transactions.wal", [:append, :raw, :binary, :sync])

    # 4. START 5ms GROUP COMMIT LOOP
    Process.send_after(self(), :flush, 5)
    
    {:ok, %{
      wal_file: wal_file,
      balances: balances,
      pending_transfers: [],
      tx_count: 0
    }}
  end

  @impl true
  def handle_call({:transfer, debit_id, credit_id, currency, amount, ref_id}, _from, state) do
    debit_key = {debit_id, currency}
    credit_key = {credit_id, currency}
    
    debit_bal = Map.get(state.balances, debit_key, Decimal.new(0)) |> to_int()

    if debit_bal >= amount do
      new_debit_bal = debit_bal - amount
      credit_bal = Map.get(state.balances, credit_key, Decimal.new(0)) |> to_int()
      new_credit_bal = credit_bal + amount
      
      new_balances = 
        state.balances
        |> Map.put(debit_key, new_debit_bal)
        |> Map.put(credit_key, new_credit_bal)

      transfer = %{
        from: _from,
        debit_id: debit_id,
        credit_id: credit_id,
        currency: currency,
        amount: amount,
        ref_id: ref_id,
        timestamp: DateTime.utc_now()
      }

      new_state = %{state | 
        balances: new_balances, 
        pending_transfers: [transfer | state.pending_transfers],
        tx_count: state.tx_count + 1
      }
      
      if length(new_state.pending_transfers) >= 500 do
        send(self(), :flush)
      end

      {:noreply, new_state}
    else
      {:reply, {:error, :insufficient_funds}, state}
    end
  end

  @impl true
  def handle_call(:flush_sync, _from, state) do
    if length(state.pending_transfers) > 0 do
      process_batch(state)
    end
    {:reply, :ok, %{state | pending_transfers: []}}
  end

  @impl true
  def handle_info(:flush, state) do
    if length(state.pending_transfers) > 0 do
      process_batch(state)
    end
    
    Process.send_after(self(), :flush, 5)
    {:noreply, %{state | pending_transfers: []}}
  end

  defp process_batch(state) do
    transfers = Enum.reverse(state.pending_transfers)
    
    # 1. GROUP COMMIT: Physical FSYNC exactly once for the block
    wal_chunk = transfers 
                |> Enum.map(fn t -> Map.drop(t, [:from]) |> Jason.encode!() end)
                |> Enum.join("\n")
                |> Kernel.<>("\n")

    :ok = :file.write(state.wal_file, wal_chunk)
    
    # 2. ACKNOWLEDGE: Unblock clients (Durability achieved)
    Enum.each(transfers, fn t -> 
      if t.from, do: GenServer.reply(t.from, :ok)
    end)

    # 3. COMPUTE SNAPSHOTS: Find which accounts were affected in this exact batch to checkpoint them
    affected_keys = Enum.flat_map(transfers, fn t -> [{t.debit_id, t.currency}, {t.credit_id, t.currency}] end) |> Enum.uniq()
    snapshot_updates = Enum.map(affected_keys, fn key -> {key, Map.get(state.balances, key)} end)

    # 4. SUPERVISED DB WRITER: Flush transfers AND snapshots
    OccLedger.DBWriter.enqueue_batch(transfers, snapshot_updates)
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(i) when is_integer(i), do: i
  defp to_int(nil), do: 0

  # --- WAL REPLAY LOGIC ---
  defp replay_wal_if_needed() do
    wal_path = "occ_transactions.wal"
    if File.exists?(wal_path) do
      lines = File.read!(wal_path) |> String.split("\n", trim: true)
      
      if length(lines) > 0 do
        transfers = lines |> Enum.map(&Jason.decode!(&1, keys: :atoms))
        wal_refs = Enum.map(transfers, & &1.ref_id)
        
        existing_refs = Repo.all(
          from t in OccLedger.LedgerTransaction,
          where: t.reference_id in ^wal_refs,
          select: t.reference_id
        ) |> MapSet.new()

        missing_transfers = Enum.reject(transfers, fn t -> MapSet.member?(existing_refs, t.ref_id) end)

        if length(missing_transfers) > 0 do
          require Logger
          Logger.warning("WAL REPLAY: Found #{length(missing_transfers)} transactions dropped from DB. Replaying...")
          
          OccLedger.DBWriter.flush_to_db_sync(missing_transfers, [])
        end
        
        File.write!(wal_path, "")
      end
    end
  end
end
