-- Migration: 2026-11-21 — the community's public contact.
-- Ported from crm-backend/database_script/2026-11-21_community_public_contact.sql, without
-- its BEGIN/COMMIT: the runner wraps this file and its schema_version row in one transaction.
--
-- The public communities directory (GET /communities/:id/public) lets any signed-in user
-- contact a public community in one click (mailto: / tel:). representative_email is the
-- representative's own address towards the GRD and the regulator, never meant for the
-- directory, so the community gets a contact of its own, set by an ADMIN.
--
-- crm-backend maps both columns on its Community entity: run this BEFORE the crm-backend
-- image that carries them starts, or every read of a community fails.
--
-- All optional (nullable, no default: no table rewrite). Idempotent: safe to re-run.
--
-- `SET LOCAL lock_timeout`: ADD COLUMN takes ACCESS EXCLUSIVE on community. With the
-- default of 0 an open transaction there makes this wait forever, and every later read
-- queues behind it. LOCAL, so it dies with the runner's transaction. Added here: the
-- upstream script has none.

SET LOCAL lock_timeout = '5s';

ALTER TABLE community
    ADD COLUMN IF NOT EXISTS contact_email VARCHAR(255) NULL;

ALTER TABLE community
    ADD COLUMN IF NOT EXISTS contact_phone VARCHAR(32) NULL;
