defmodule OccLedger.LoadGenerator do
  @moduledoc """
  Generates synthetic load and initial genesis liquidity.
  """
  alias OccLedger.{Repo, Account, EpochBatch, LedgerTransaction, LedgerEntry, BaselineProcessor}

  @hot_accounts [
    %{ref: "omnibus_fiduciary_btc", type: :omnibus_reserve, currency: :BTC},
    %{ref: "omnibus_fiduciary_usd", type: :omnibus_reserve, currency: :USD},
    %{ref: "treasury_operating_btc", type: :clearing_suspense, currency: :BTC},
    %{ref: "treasury_fee_escrow_btc", type: :fee_revenue, currency: :BTC}
  ]

  def seed(num_customers \\ 100) do
    # 1. Seed Accounts
    hot_accs = Enum.map(@hot_accounts, fn acc ->
      %Account{account_number: acc.ref, account_type: acc.type, currency: acc.currency, created_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:account_number])
      
      Repo.get_by!(Account, account_number: acc.ref)
    end)
    
    omnibus_btc = Enum.find(hot_accs, &(&1.account_number == "omnibus_fiduciary_btc"))
    treasury_btc = Enum.find(hot_accs, &(&1.account_number == "treasury_operating_btc"))
    fee_escrow_btc = Enum.find(hot_accs, &(&1.account_number == "treasury_fee_escrow_btc"))

    customers = for i <- 1..num_customers do
      %Account{account_number: "cust_#{i}_btc", account_type: :customer_fiduciary, currency: :BTC, created_at: DateTime.utc_now() |> DateTime.truncate(:second)}
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:account_number])
      
      Repo.get_by!(Account, account_number: "cust_#{i}_btc")
    end

    # 2. Mint Genesis Liquidity
    # We execute a single massive statement to fund everyone while satisfying the zero-sum trigger
    Repo.transaction(fn ->
      batch = %EpochBatch{batch_nonce: Ecto.UUID.generate(), tx_count: 1, entry_count: num_customers + 3, created_at: DateTime.utc_now() |> DateTime.truncate(:second)} |> Repo.insert!()
      tx = %LedgerTransaction{epoch_id: batch.id, reference_id: "GENESIS_#{Ecto.UUID.generate()}", description: "Genesis Mint", created_at: DateTime.utc_now() |> DateTime.truncate(:second)} |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      
      # Customer Credits
      {cust_entries, total_customer_sats} = Enum.map_reduce(customers, 0, fn c, acc ->
        amount = Enum.random(1_000_000..50_000_000)
        entry = %{transaction_id: tx.id, account_id: c.id, currency: :BTC, direction: :credit, amount: amount, created_at: now}
        {entry, acc + amount}
      end)

      # Omnibus Debit (matches customer credits)
      omnibus_entry = %{transaction_id: tx.id, account_id: omnibus_btc.id, currency: :BTC, direction: :debit, amount: total_customer_sats, created_at: now}

      # Treasury Funding
      treasury_funding = 5_000_000_000
      treasury_entry = %{transaction_id: tx.id, account_id: treasury_btc.id, currency: :BTC, direction: :debit, amount: treasury_funding, created_at: now}
      fee_entry = %{transaction_id: tx.id, account_id: fee_escrow_btc.id, currency: :BTC, direction: :credit, amount: treasury_funding, created_at: now}

      all_entries = [omnibus_entry, treasury_entry, fee_entry | cust_entries]
      Repo.insert_all(LedgerEntry, all_entries)
    end)
    
    IO.puts("Genesis liquidity minted successfully.")

    {omnibus_btc, treasury_btc, fee_escrow_btc, customers}
  end

  def run(concurrency \\ 20, requests_per_worker \\ 100) do
    IO.puts("Starting Zipfian Load Generator against Naive Baseline...")
    {omnibus, _treasury, _fee, customers} = seed()

    # CRITICAL FIX: Restart BatchCoordinator to hydrate new genesis balances
    Supervisor.terminate_child(OccLedger.Supervisor, OccLedger.BatchCoordinator)
    Supervisor.restart_child(OccLedger.Supervisor, OccLedger.BatchCoordinator)

    # The load simulation: customers continuously withdrawing from the omnibus
    tasks = for _w <- 1..concurrency do
      Task.async(fn ->
        for _r <- 1..requests_per_worker do
          cust = Enum.random(customers)
          ref_id = Ecto.UUID.generate()
          
          # Withdrawal: Debit Customer, Credit Omnibus
          try do
            :ok = OccLedger.BatchCoordinator.transfer(cust.id, omnibus.id, :BTC, 10, ref_id)
          rescue
            e -> 
              IO.inspect(e, label: "TRANSFER ERROR")
              :error 
          end
        end
        :ok
      end)
    end

    {time, _} = :timer.tc(fn -> Task.await_many(tasks, 120_000) end)
    
    total_tx = concurrency * requests_per_worker
    tps = (total_tx / (time / 1_000_000)) |> Float.round(2)
    IO.puts("Completed #{total_tx} transactions in #{time / 1000} ms.")
    IO.puts("Throughput: #{tps} TPS")
  end
end
