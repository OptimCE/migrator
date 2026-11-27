-- Migration: 2026-11-15 — export_job / export_part: the data export (RGPD art. 15 and 20).
-- Ported from crm-backend/database_script/2026-11-15_data_export.sql, without its BEGIN/COMMIT:
-- the runner wraps this file and its schema_version row in one transaction.
--
-- One export_job per request for "all the data about a user" or "all the data of a
-- community", and one export_part per service that holds some of it (the contract is
-- contracts/export/README.md at the monorepo root). crm-backend's API creates the job and
-- its parts in one transaction, then publishes `export.job.requested`; crm-export-worker
-- (same image, its own process) keeps its whole state in these two tables.
--
--   * scope_id / requester_user_id are Keycloak ids; id_community / id_requester are the
--     same two as internal ids. id_community is set exactly when the scope is a
--     community (ck_export_job_scope).
--   * uq_export_job_active: one active export per requester and scope (the API's 409).
--   * Deleting a user or a community deletes its jobs; the archive, if any, is removed by
--     the `exports` bucket's lifecycle rule.
--
-- New tables only: no row can violate a CHECK. No GRANT: the migrator runs as crm_svc,
-- which owns them, and the provisioning's default privileges give every annexe role its
-- SELECT. database_script/init.sql carries the same tables. Idempotent: safe to re-run.
--
-- `SET LOCAL lock_timeout`: the foreign keys take SHARE ROW EXCLUSIVE on community and
-- app_user. With the default of 0 an open transaction there makes this wait forever, and
-- every later write queues behind it. LOCAL, so it dies with the runner's transaction.
-- Added here: the upstream script has none (a crm-backend test holds its body equal to
-- init.sql's).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS export_job (
    id                UUID PRIMARY KEY,
    scope_type        VARCHAR(16) NOT NULL CHECK (scope_type IN ('user', 'community')),
    scope_id          VARCHAR(255) NOT NULL,
    id_community      INT NULL REFERENCES community (id) ON DELETE CASCADE,
    requester_user_id VARCHAR(255) NOT NULL,
    id_requester      INT NOT NULL REFERENCES app_user (id) ON DELETE CASCADE,
    status            VARCHAR(16) NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'collecting', 'assembling', 'ready', 'failed', 'expired')),
    schema_version    VARCHAR(16) NOT NULL,
    locale            VARCHAR(8) NOT NULL CHECK (locale IN ('fr', 'en', 'nl', 'de')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    started_at        TIMESTAMPTZ NULL,
    completed_at      TIMESTAMPTZ NULL,
    expires_at        TIMESTAMPTZ NULL,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    object_key        TEXT NULL,
    size_bytes        BIGINT NULL,
    sha256            CHAR(64) NULL,
    assembly_attempts SMALLINT NOT NULL DEFAULT 0,
    error_code        VARCHAR(64) NULL,
    error_detail      TEXT NULL,
    CONSTRAINT ck_export_job_scope CHECK ((scope_type = 'community') = (id_community IS NOT NULL)),
    CONSTRAINT ck_export_job_ready CHECK (status <> 'ready' OR (object_key IS NOT NULL AND expires_at IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_export_job_active
    ON export_job (requester_user_id, scope_type, scope_id)
    WHERE status IN ('pending', 'collecting', 'assembling');
CREATE INDEX IF NOT EXISTS ix_export_job_scope_created
    ON export_job (scope_type, scope_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_export_job_requester
    ON export_job (id_requester, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_export_job_community
    ON export_job (id_community, created_at DESC) WHERE id_community IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_export_job_open
    ON export_job (created_at) WHERE status IN ('pending', 'collecting', 'assembling');
CREATE INDEX IF NOT EXISTS ix_export_job_expiry
    ON export_job (expires_at) WHERE status = 'ready';

CREATE TABLE IF NOT EXISTS export_part (
    id            UUID PRIMARY KEY,
    export_job_id UUID NOT NULL REFERENCES export_job (id) ON DELETE CASCADE,
    service       VARCHAR(64) NOT NULL CHECK (service ~ '^[a-z][a-z0-9-]{1,62}$'),
    status        VARCHAR(16) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'failed')),
    attempts      SMALLINT NOT NULL DEFAULT 0,
    requested_at  TIMESTAMPTZ NULL,
    result        JSONB NULL,
    last_error    TEXT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_export_part_service UNIQUE (export_job_id, service)
);
