BEGIN;

-- ---------------------------------------------------------------- currencies
CREATE TABLE currencies (
    code     CHAR(3)  PRIMARY KEY,
    exponent SMALLINT NOT NULL CHECK (exponent BETWEEN 0 AND 4)
);
INSERT INTO currencies (code, exponent) VALUES
    ('NZD', 2), ('USD', 2), ('AUD', 2), ('EUR', 2), ('GBP', 2), ('JPY', 0);

-- ---------------------------------------------------------------- merchants
CREATE TABLE merchants (
    id         BIGSERIAL PRIMARY KEY,
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- accounts
-- Double-entry chart of accounts. The journal is authoritative; balances are
-- a cache in account_balances, rebuildable from journal_lines at any time.
-- Sign convention: positive = debit, negative = credit.
CREATE TABLE accounts (
    id          BIGSERIAL PRIMARY KEY,
    -- code is a human-readable identifier, not a data source. Never parse it.
    code        TEXT NOT NULL UNIQUE,
    type        TEXT NOT NULL CHECK (type IN ('asset','liability','revenue','expense')),
    -- purpose carries the meaning you would otherwise be tempted to read out of code.
    purpose     TEXT NOT NULL CHECK (purpose IN
                  ('master','receivable','pending','available','platform_fee','processor_fee')),
    currency    CHAR(3) NOT NULL REFERENCES currencies(code),
    merchant_id BIGINT REFERENCES merchants(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT accounts_merchant_check CHECK (
        (purpose IN ('pending','available')) = (merchant_id IS NOT NULL)
    )
);

INSERT INTO accounts (code, type, purpose, currency) VALUES
    ('bank:master:NZD',          'asset',   'master',       'NZD'),
    ('psp:receivable:NZD',       'asset',   'receivable',   'NZD'),
    ('revenue:platform_fee:NZD', 'revenue', 'platform_fee', 'NZD'),
    ('expense:processor_fee:NZD','expense', 'processor_fee','NZD');
-- Per merchant, per currency, two liability accounts are created at onboarding:
--   merchant:<id>:pending:<ccy>    owed, but not yet payable
--   merchant:<id>:available:<ccy>  withdrawable

-- ---------------------------------------------------------------- journal
CREATE TABLE journal_entries (
    id          BIGSERIAL PRIMARY KEY,
    kind        TEXT NOT NULL CHECK (kind IN
                  ('payment','refund','chargeback','platform_fee','adjustment','settlement')),
    reference   TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    memo        TEXT NOT NULL DEFAULT ''
);
CREATE INDEX journal_entries_reference ON journal_entries (reference);
CREATE INDEX journal_entries_occurred  ON journal_entries (occurred_at);

-- One row per debit or credit. Sum per entry must be zero.
CREATE TABLE journal_lines (
    id               BIGSERIAL PRIMARY KEY,
    journal_entry_id BIGINT NOT NULL REFERENCES journal_entries(id) ON DELETE CASCADE,
    account_id       BIGINT NOT NULL REFERENCES accounts(id),
    amount_minor     BIGINT NOT NULL CHECK (amount_minor <> 0),
    currency         CHAR(3) NOT NULL REFERENCES currencies(code)
);
CREATE INDEX journal_lines_account ON journal_lines (account_id);
CREATE INDEX journal_lines_entry   ON journal_lines (journal_entry_id);

-- Every entry must balance to zero. Deferred, so an entry can be written
-- across several statements and validated once at COMMIT.
CREATE FUNCTION assert_entry_balanced() RETURNS TRIGGER AS $$
DECLARE
    entry_id BIGINT;
    total    BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN entry_id := OLD.journal_entry_id;
    ELSE entry_id := NEW.journal_entry_id;
    END IF;

    SELECT COALESCE(SUM(amount_minor), 0) INTO total
    FROM journal_lines WHERE journal_entry_id = entry_id;

    IF total <> 0 THEN
        RAISE EXCEPTION 'journal entry % is unbalanced by % minor units', entry_id, total;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE CONSTRAINT TRIGGER journal_lines_balanced
    AFTER INSERT OR UPDATE OR DELETE ON journal_lines
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION assert_entry_balanced();

-- ---------------------------------------------------------------- balances
-- Derived cache. NOT the source of truth: it is rebuilt from journal_lines and
-- compared on a schedule. Statement-level on purpose - a per-row upsert on a hot
-- account costs 155s per 300k lines; this costs 1.8s.
CREATE TABLE account_balances (
    account_id    BIGINT PRIMARY KEY REFERENCES accounts(id),
    balance_minor BIGINT NOT NULL DEFAULT 0,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE FUNCTION apply_balance_delta() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO account_balances(account_id, balance_minor)
    SELECT account_id, SUM(amount_minor) FROM new_rows GROUP BY account_id
    ON CONFLICT (account_id) DO UPDATE
       SET balance_minor = account_balances.balance_minor + EXCLUDED.balance_minor,
           updated_at = now();
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER journal_lines_balance
    AFTER INSERT ON journal_lines
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION apply_balance_delta();

-- ---------------------------------------------------------------- external: processor
CREATE TABLE settlement_files (
    id              BIGSERIAL PRIMARY KEY,
    merchant_id     BIGINT NOT NULL REFERENCES merchants(id),
    psp             TEXT NOT NULL,
    batch_ref       TEXT NOT NULL,
    settlement_date DATE NOT NULL,
    currency        CHAR(3) NOT NULL REFERENCES currencies(code),
    line_count      INTEGER NOT NULL DEFAULT 0,
    gross_minor     BIGINT NOT NULL DEFAULT 0,
    fee_minor       BIGINT NOT NULL DEFAULT 0,
    net_minor       BIGINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (psp, batch_ref)
);
COMMENT ON COLUMN settlement_files.psp IS
    'payment service provider that produced this file';
COMMENT ON COLUMN settlement_files.net_minor IS
    'gross minus fees: the amount expected to be paid out for this batch';

CREATE TABLE settlement_lines (
    id              BIGSERIAL PRIMARY KEY,
    file_id         BIGINT NOT NULL REFERENCES settlement_files(id) ON DELETE CASCADE,
    kind            TEXT NOT NULL DEFAULT 'payment' CHECK (kind IN
                      ('payment','refund','chargeback','adjustment','reserve_hold','reserve_release')),
    psp_ref         TEXT NOT NULL,
    amount_minor    BIGINT NOT NULL,
    fee_minor       BIGINT NOT NULL DEFAULT 0,
    net_minor       BIGINT NOT NULL,
    currency        CHAR(3) NOT NULL REFERENCES currencies(code),
    settlement_date DATE NOT NULL,
    raw             JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT settlement_lines_net_check CHECK (net_minor = amount_minor - fee_minor)
);
CREATE INDEX settlement_lines_ref    ON settlement_lines (psp_ref);
CREATE INDEX settlement_lines_amount ON settlement_lines (currency, amount_minor);
CREATE INDEX settlement_lines_date   ON settlement_lines (settlement_date);

-- ---------------------------------------------------------------- external: bank
CREATE TABLE bank_statements (
    id            BIGSERIAL PRIMARY KEY,
    account       TEXT NOT NULL,
    currency      CHAR(3) NOT NULL REFERENCES currencies(code),
    period_start  DATE NOT NULL,
    period_end    DATE NOT NULL,
    opening_minor BIGINT NOT NULL,
    closing_minor BIGINT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE bank_lines (
    id           BIGSERIAL PRIMARY KEY,
    statement_id BIGINT NOT NULL REFERENCES bank_statements(id) ON DELETE CASCADE,
    bank_ref     TEXT NOT NULL,
    amount_minor BIGINT NOT NULL,
    currency     CHAR(3) NOT NULL REFERENCES currencies(code),
    value_date   DATE NOT NULL,
    narrative    TEXT NOT NULL DEFAULT '',
    raw          JSONB,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX bank_lines_date   ON bank_lines (value_date);
CREATE INDEX bank_lines_amount ON bank_lines (currency, amount_minor);

COMMIT;