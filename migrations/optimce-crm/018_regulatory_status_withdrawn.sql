-- Migration: 2026-10-30 — regulatory_link_status: status 9, withdrawn.
--
-- The annexe opens an episode as soon as a change is filed (to_notify), so a
-- change that is then cancelled, excluded or compensated before it was
-- authorised needs a status of its own: the annexe has no DELETE on the table,
-- and the row stays as the trace of what was filed. 9 is not guarded by
-- ex_regulatory_link_one_operation (only 2-5 are), and the CRM shows no badge
-- for it.
--
--   regulatory_status  1 to_notify, 2 pending_grd, 3 pending_regulator,
--                      4 authorized, 5 active, 6 leaving, 7 ended, 8 refused,
--                      9 withdrawn
--
-- The column's CHECK was inline, so Postgres named it
-- regulatory_link_status_regulatory_status_check; it becomes the named
-- ck_regulatory_link_status_code, as in database_script/init.sql and
-- tests/sql/init.sql. Re-running the script changes nothing. The grants do
-- not change: regulatory_status is already one of the annexe's four columns.
--
-- Ported from crm-backend/database_script/2026-10-30_regulatory_status_withdrawn.sql, without its BEGIN/COMMIT: the
-- runner wraps this file and its schema_version row in one transaction.

ALTER TABLE regulatory_link_status
    DROP CONSTRAINT IF EXISTS regulatory_link_status_regulatory_status_check,
    DROP CONSTRAINT IF EXISTS ck_regulatory_link_status_code,
    ADD CONSTRAINT ck_regulatory_link_status_code CHECK (regulatory_status BETWEEN 1 AND 9);

