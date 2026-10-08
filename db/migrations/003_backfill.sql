-- Repeatable sample backfill. A production-sized table needs bounded batches.
UPDATE orders SET currency = 'USD' WHERE currency IS NULL;
INSERT INTO schema_migrations(version) VALUES ('003') ON CONFLICT DO NOTHING;
