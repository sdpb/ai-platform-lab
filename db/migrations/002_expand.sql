-- Additive scaffold: v1 does not read or write this field.
ALTER TABLE orders ADD COLUMN IF NOT EXISTS currency TEXT;
INSERT INTO schema_migrations(version) VALUES ('002') ON CONFLICT DO NOTHING;
