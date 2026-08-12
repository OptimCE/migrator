-- Migration: 2026-05-10 — community subscription (annexe service entitlement).
--
-- One row per (community, feature) recording whether that community has the
-- annexe service switched on. `feature` is a coded string managed at the
-- application layer, not an enum, so adding a service needs no migration.
--
-- Notes:
--   * The unique constraint is what makes the table an entitlement ledger rather
--     than an event log: a community either has a feature or it does not.
--   * `update_changetimestamp_column()` is NOT created here. It comes from the
--     CRM base schema (crm-backend/database_script/init.sql), which this
--     migration set assumes is already applied — see the migrator README.
--
-- Idempotent: safe to re-run.
CREATE TABLE IF NOT EXISTS community_subscription (
    id           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_community INTEGER     NOT NULL,
    feature      VARCHAR(64) NOT NULL,
    is_active    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_community_subscription_community_feature
        UNIQUE (id_community, feature)
);
CREATE INDEX IF NOT EXISTS idx_community_subscription_community
    ON community_subscription (id_community);

-- Guarded like every other CREATE TRIGGER in this set (see 002). Without the
-- DROP, replaying this migration against a database whose base schema already
-- created the trigger fails with "trigger already exists".
DROP TRIGGER IF EXISTS update_community_subscription_modtime ON community_subscription;
CREATE TRIGGER update_community_subscription_modtime
BEFORE UPDATE ON community_subscription
FOR EACH ROW
EXECUTE FUNCTION update_changetimestamp_column();
