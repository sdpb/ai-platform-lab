CREATE TABLE IF NOT EXISTS schema_migrations (
    version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS orders (
    id UUID PRIMARY KEY,
    idempotency_key TEXT UNIQUE NOT NULL,
    request_hash TEXT NOT NULL,
    customer_id TEXT NOT NULL,
    sku TEXT NOT NULL,
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price_cents INTEGER NOT NULL CHECK (unit_price_cents >= 0),
    total_cents BIGINT NOT NULL CHECK (total_cents >= 0),
    status TEXT NOT NULL CHECK (status IN ('pending', 'confirmed', 'rejected')),
    payment_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS payments (
    id UUID PRIMARY KEY,
    order_id UUID UNIQUE NOT NULL,
    amount_cents BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS payment_decisions (
    order_id UUID PRIMARY KEY,
    amount_cents BIGINT NOT NULL,
    rejected BOOLEAN NOT NULL,
    decided_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
-- Allow the starter to be updated without losing existing payment identities.
INSERT INTO payment_decisions(order_id, amount_cents, rejected)
SELECT order_id, amount_cents, false FROM payments ON CONFLICT DO NOTHING;
-- No foreign key from payments to orders: this is an independently committed
-- downstream ledger, sharing this lab database only to keep setup small.
INSERT INTO schema_migrations(version) VALUES ('001') ON CONFLICT DO NOTHING;
