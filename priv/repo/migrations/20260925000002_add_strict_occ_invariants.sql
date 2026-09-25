-- Statement-Level Fiduciary Constraints

-- 1. Invariant: Amount must be strictly positive
ALTER TABLE ledger_entries ADD CONSTRAINT chk_entries_amount_positive CHECK (amount > 0);

-- 2. Invariant: Multi-Currency Double-Entry Zero-Sum Check
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

CREATE TRIGGER trg_verify_multi_currency_double_entry
    AFTER INSERT ON ledger_entries
    REFERENCING NEW TABLE AS new_entries
    FOR EACH STATEMENT
    EXECUTE FUNCTION verify_multi_currency_double_entry();
