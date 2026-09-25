-- OCC National Trust Bank Charter (12 CFR Part 9) Core Ledger Engine
-- Target Substrate: PostgreSQL 16
-- Multi-Currency Double-Entry Invariant & Explicit Epoch Membership Schema

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Currency Domain: ISO-4217 & Digital Assets
CREATE TYPE currency_code AS ENUM ('USD', 'BTC', 'SATS');
CREATE TYPE account_type AS ENUM ('customer_fiduciary', 'omnibus_reserve', 'clearing_suspense', 'fee_revenue');
CREATE TYPE entry_direction AS ENUM ('debit', 'credit');

-- 1. Accounts Table with Composite Key for Currency Isolation
CREATE TABLE accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_number VARCHAR(64) NOT NULL UNIQUE,
    account_type account_type NOT NULL,
    currency currency_code NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_accounts_id_currency UNIQUE (id, currency)
);

-- 2. Monotonic Epoch Batches (Gapless Batch Isolation)
CREATE TABLE epoch_batches (
    epoch_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_nonce UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    tx_count INTEGER NOT NULL,
    entry_count INTEGER NOT NULL,
    merkle_root BYTEA,
    sealed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- 3. Ledger Transactions (Anchor to Monotonic Batch)
CREATE TABLE ledger_transactions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    epoch_id BIGINT NOT NULL REFERENCES epoch_batches(epoch_id) ON DELETE RESTRICT,
    reference_id VARCHAR(128) NOT NULL UNIQUE,
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX idx_transactions_epoch_id ON ledger_transactions(epoch_id);

-- 4. Append-Only Ledger Entries
CREATE TABLE ledger_entries (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id BIGINT NOT NULL REFERENCES ledger_transactions(id) ON DELETE RESTRICT,
    account_id UUID NOT NULL,
    currency currency_code NOT NULL,
    direction entry_direction NOT NULL,
    amount BIGINT NOT NULL CHECK (amount > 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT fk_entries_account_currency 
        FOREIGN KEY (account_id, currency) 
        REFERENCES accounts(id, currency) ON DELETE RESTRICT
);

-- Covering Index for High-Speed Append and Balance Calculation
CREATE INDEX idx_entries_account_currency_cov 
    ON ledger_entries(account_id, currency) 
    INCLUDE (direction, amount);

CREATE INDEX idx_entries_tx_id 
    ON ledger_entries(transaction_id);

-- 5. Multi-Currency Statement-Level Transition Trigger Function
-- Enforces: SUM(Debits) - SUM(Credits) = 0 PER CURRENCY within each transaction
CREATE OR REPLACE FUNCTION verify_multi_currency_double_entry()
RETURNS TRIGGER AS $$
DECLARE
    v_violator RECORD;
BEGIN
    SELECT transaction_id, currency,
           SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END) AS skew
    INTO v_violator
    FROM new_entries
    GROUP BY transaction_id, currency
    HAVING SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END) <> 0
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'Double-entry zero-sum violation in transaction % for currency %: Net skew is %',
            v_violator.transaction_id, v_violator.currency, v_violator.skew
            USING ERRCODE = 'data_exception';
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Statement Trigger: Fires ONCE per INSERT statement across the Transition Table
CREATE TRIGGER trg_verify_multi_currency_double_entry
    AFTER INSERT ON ledger_entries
    REFERENCING NEW TABLE AS new_entries
    FOR EACH STATEMENT
    EXECUTE FUNCTION verify_multi_currency_double_entry();

-- 6. High-Frequency Balance Checkpoints Table (Rolling Snapshot)
CREATE TABLE account_checkpoints (
    account_id UUID NOT NULL,
    currency currency_code NOT NULL,
    epoch_id BIGINT NOT NULL REFERENCES epoch_batches(epoch_id),
    settled_balance BIGINT NOT NULL CHECK (settled_balance >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (account_id, currency, epoch_id),
    CONSTRAINT fk_checkpoints_account_currency
        FOREIGN KEY (account_id, currency)
        REFERENCES accounts(id, currency) ON DELETE CASCADE
);
