-- Migration: 2026-10-29 — outbox_event: the transactional outbox of the core's domain events.
--
-- Every event the core publishes (shared/outbox/core-events.ts) is written here
-- in the SAME transaction as the CRM change it describes, so a change that
-- commits always has its event and a change that rolls back never does.
-- crm-outbox-relay (src/outbox-relay.ts) reads the unpublished rows in id order,
-- publishes each on `core.evt.<event_type>` with `event_id` as Nats-Msg-Id, then
-- stamps `published_at`. A relay that dies between the publish and the stamp
-- republishes after restart and JetStream's duplicate window drops the copy.
--
--   * No FK on id_community: an event must outlive what it describes.
--   * GENERATED ALWAYS AS IDENTITY: no sequence to grant to the relay's role.
--   * The partial index keeps the claim query the size of the backlog.
--
-- database_script/init.sql and tests/sql/init.sql carry the same table.
--
-- Ported from crm-backend/database_script/2026-10-29_outbox_event.sql, without its BEGIN/COMMIT: the
-- runner wraps this file and its schema_version row in one transaction.

CREATE TABLE IF NOT EXISTS outbox_event (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id       UUID NOT NULL UNIQUE,
    id_community   INT NOT NULL,
    aggregate_type VARCHAR(32) NOT NULL,
    aggregate_id   VARCHAR(64) NOT NULL,
    event_type     VARCHAR(64) NOT NULL,
    payload        JSONB NOT NULL DEFAULT '{}'::jsonb,
    occurred_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at   TIMESTAMPTZ,
    attempts       SMALLINT NOT NULL DEFAULT 0,
    last_error     TEXT
);

CREATE INDEX IF NOT EXISTS ix_outbox_event_unpublished ON outbox_event (id) WHERE published_at IS NULL;
