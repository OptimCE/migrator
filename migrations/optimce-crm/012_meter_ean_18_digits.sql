-- Migration: 2026-09-22 — meter.ean is exactly 18 digits.
--
-- A Belgian EAN — the DSO's connection identifier and this table's primary key
-- — is 18 digits, starting 54144x. `meter.ean` is an unbounded VARCHAR with no
-- CHECK, and until the release this ships with, `POST /meters {"EAN":"123"}`
-- was accepted: the only format rule in the platform lived in the browser.
-- crm-backend now rejects anything but 18 digits on the one path that mints an
-- EAN (`CreateMeterDTO`, modules/meters/shared/ean.ts). This closes direct SQL.
--
-- 18 digits, and nothing more. No `54` prefix requirement: that is a convention
-- of the issuing DSOs, and this repo's own functional fixtures
-- (`123456789012345678`, `999999999999999999`) are deliberately outside it. No
-- GS1 mod-10 check digit either — `541448200000000001`, the EAN every seed, e2e
-- spec and RESA test workbook is built on, FAILS mod-10 (its check digit would
-- be 8), so a checksum here would reject the platform's own data.
--
-- SCOPE — `meter.ean` ONLY, deliberately:
--   * `meter_data.ean` and `meter_consumption.ean` are foreign keys to it and
--     are therefore already constrained transitively. A CHECK on either would
--     additionally make THEIR rows read-only for no gain, and `meter_data` IS
--     updated (patch_meter_data, deactivate).
--   * `consumer.name` holds an EAN by CONVENTION only and is free text by
--     design: a file-based allocation key legitimately carries arbitrary
--     spreadsheet column headers, and a manual key legitimately names a
--     consumer "Maison Dupont".
--
-- VALIDATED, NOT `NOT VALID` — and this is the whole design of the file.
-- Postgres enforces a NOT VALID CHECK "against subsequent inserts or updates …
-- they'll fail unless the new row matches the specified check condition", and a
-- CHECK is re-evaluated on every UPDATE of the row whether or not the checked
-- column changed. (The skip-if-unchanged optimisation is FK-only.) So NOT VALID
-- would buy nothing here but a hidden trap: every legacy non-conforming meter
-- would become READ-ONLY — its address could never be repaired
-- (`PATCH /meters/address`) and its configuration never updated. Worse, nothing
-- in the platform can rewrite an EAN — `updateMeter` and `updateMeterAddress`
-- use it only in the WHERE clause — so the only remedy would be DELETE, which
-- cascades `meter_data` and `meter_consumption` away and destroys the meter's
-- whole consumption history.
--
-- Hence the guard below: this migration REFUSES to apply to a database it would
-- trap. The runner wraps this file and the `schema_version` INSERT in ONE
-- transaction, so the RAISE rolls back both — version 12 is never recorded for
-- a constraint that is not there, and the next run retries cleanly.
--
-- RUN `postgres/verify/ean-survey.sh` FIRST. It is read-only, reports the same
-- count with sample values across every database, and exits 0/1/2 for
-- clean/dirty/could-not-look. Expect production to need a look rather than a
-- rubber stamp: the deployed crm-frontend image enforced a THIRTEEN-digit rule
-- from 2026-06-08 until this release, so the old form accepted exactly 13
-- digits and rows created through it will fail this constraint.
--
-- ORDERING — SAFE ONLINE, unlike migration 011. No column type change, no table
-- rewrite, no backfill, and no wire-type flip: both the old and the new
-- crm-backend can only ever write an 18-digit EAN once the frontend is current.
-- ADD CONSTRAINT takes ACCESS EXCLUSIVE on `meter` for one sequential scan,
-- which is milliseconds at this volume. crm-backend does NOT have to be stopped.
--
-- `SET LOCAL lock_timeout` is not decoration: the default of 0 is what turns a
-- lock wait into an outage, because a live backend holding an open transaction
-- would make this wait forever and every later query would queue behind it.
-- Better to fail in five seconds and be re-run. LOCAL, so it dies with the
-- runner's transaction rather than leaking into the schema_version INSERT.
--
-- REVERSIBLE: `ALTER TABLE meter DROP CONSTRAINT chk_meter_ean_18_digits;`
--
-- Idempotent: safe to re-run (DROP IF EXISTS then ADD, as in 011).
--
-- Ported from crm-backend/database_script/2026-09-22_meter_ean_18_digits.sql,
-- which is written to be run by hand with psql. The outer BEGIN;/COMMIT; is
-- removed: the runner wraps this file and the schema_version INSERT in one
-- transaction, and a COMMIT here would end it early and reintroduce exactly the
-- "applied DDL, no version recorded" state that wrapper exists to prevent.
-- Nothing else changed — the upstream file inserts no schema_version row of its
-- own and is already replay-safe.

SET LOCAL lock_timeout = '5s';

-- Refuse rather than trap. See the VALIDATED note above for why there is no
-- NOT VALID escape hatch.
DO $$
DECLARE
    offending bigint;
    sample    text;
BEGIN
    SELECT count(*) INTO offending FROM meter WHERE ean !~ '^[0-9]{18}$';

    IF offending > 0 THEN
        SELECT string_agg(ean, ', ') INTO sample
        FROM (
            SELECT ean FROM meter WHERE ean !~ '^[0-9]{18}$' ORDER BY ean LIMIT 5
        ) s;

        RAISE EXCEPTION
            'meter.ean: % row(s) are not 18 digits (e.g. %). This constraint '
            'would make them read-only, and nothing in the platform can rewrite '
            'a meter EAN, so the only remedy left would be DELETE — which '
            'cascades meter_data and meter_consumption away. Run '
            'postgres/verify/ean-survey.sh, re-encode or retire those meters, '
            'then re-run this migration.',
            offending, sample;
    END IF;
END
$$;

ALTER TABLE meter DROP CONSTRAINT IF EXISTS chk_meter_ean_18_digits;
ALTER TABLE meter ADD CONSTRAINT chk_meter_ean_18_digits
CHECK (ean ~ '^[0-9]{18}$');
