defmodule OccLedger.BaselineProcessor do
  @moduledoc """
  The Naive "ORM-Style" baseline processor. 
  """
  import Ecto.Query
  alias OccLedger.{Repo, LedgerTransaction, LedgerEntry, EpochBatch}

  def process_transfer(debit_account_id, credit_account_id, currency, amount, ref_id) do
    Repo.transaction(fn ->
      # 1. Fetch current balance of debit account
      # Naive O(N) aggregate against the append-only ledger
      balance = calculate_balance(debit_account_id, currency)
      
      if balance < amount do
        Repo.rollback("Insufficient funds: required #{amount}, got #{balance}")
      end

      # 2. Insert Epoch Batch
      batch = %EpochBatch{
        batch_nonce: Ecto.UUID.generate(),
        tx_count: 1,
        entry_count: 2,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      } |> Repo.insert!()

      # 3. Insert Transaction
      tx = %LedgerTransaction{
        epoch_id: batch.epoch_id,
        reference_id: ref_id,
        description: "Naive ORM Transfer",
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      } |> Repo.insert!()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      
      # 4. Insert Debit and Credit via insert_all
      # We MUST insert them in a single statement to pass the database's 
      # statement-level verify_multi_currency_double_entry trigger.
      entries = [
        %{
          id: Ecto.UUID.generate(),
          transaction_id: tx.id,
          account_id: debit_account_id,
          currency: currency,
          direction: :debit,
          amount: amount,
          created_at: now
        },
        %{
          id: Ecto.UUID.generate(),
          transaction_id: tx.id,
          account_id: credit_account_id,
          currency: currency,
          direction: :credit,
          amount: amount,
          created_at: now
        }
      ]
      
      Repo.insert_all(LedgerEntry, entries)

      tx.id
    end)
  end

  defp calculate_balance(account_id, currency) do
    query = from e in LedgerEntry,
      where: e.account_id == ^account_id and e.currency == ^currency,
      select: sum(
        fragment("CASE WHEN ?::text = 'credit' THEN ? ELSE -? END", e.direction, e.amount, e.amount)
      )

    Repo.one(query) || 0
  end
end
