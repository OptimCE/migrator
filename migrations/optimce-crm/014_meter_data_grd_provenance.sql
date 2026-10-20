-- Migration: 2026-10-13 — meter_data.grd stores stable ids, with its provenance.
--
-- The meter form now prefills the GRD (the DSO) from the address, through the
-- internal dso-lookup service and the belgian-dso-map data release. That
-- release names operators by STABLE ID — `ores`, `fluvius-imewo`, `elia` — and
-- `meter_data.grd` now stores the id instead of the select's display name
-- ("ORES", "Fluvius Imewo"). Two columns record where the value came from:
--
--   grd_source        'auto'   the form kept what dso-lookup prefilled
--                     'manual' the user picked it
--                     NULL     origin unknown — every row older than this migration
--   grd_data_version  the data release an 'auto' value came from ('2026.10.0'),
--                     NULL otherwise
--
-- ORDERING — APPLY BEFORE THE NEW crm-backend IMAGE. The `MeterData` entity
-- (crm-backend `src/modules/meters/domain/meter.models.ts`) declares both
-- columns, and TypeORM selects every entity column by name: on a database
-- without them every meter_data read fails on `column ... does not exist`, and
-- with them missing the meters pages answer 500. The previous crm-backend never
-- names the new columns and keeps working on the migrated table, so migrating
-- first is safe with the old image still running.
--
-- NO CHECK constraint on grd or grd_source, deliberately: grd stays free text
-- (the operator list lives in an external data release, and refusing an id a
-- future release adds would block meter creation), and crm-backend validates
-- grd_source on the way in. A CHECK would also be re-evaluated on every UPDATE
-- of a legacy row (see migration 012), for no gain here.
--
-- THE REWRITE. Every value equal to a known display name — trimmed, case- and
-- hyphen-insensitive, the same rule as `normaliseGrd` in crm-backend
-- `src/modules/meters/shared/grd.ts` — becomes its id. Anything else is LEFT
-- AS IS; grd_source stays NULL on every rewritten row, because nobody knows who
-- chose those values. A bare "Fluvius" is ambiguous (eight DSOs) and is left
-- alone on purpose.
--
-- RUN THE REPORT FIRST (read-only), and again after: before, it lists every
-- value that is not an id yet, legacy names included; after, only the values
-- this migration does not know, to be mapped by hand or left as free text.
--
--   SELECT grd, count(*) AS rows, count(DISTINCT id_community) AS communities
--     FROM meter_data
--    WHERE grd IS NOT NULL
--      AND grd NOT IN ('ores', 'resa', 'aieg', 'aiesh', 'rew', 'sibelga',
--                      'fluvius-antwerpen', 'fluvius-halle-vilvoorde',
--                      'fluvius-imewo', 'fluvius-kempen', 'fluvius-limburg',
--                      'fluvius-midden-vlaanderen', 'fluvius-west',
--                      'fluvius-zenne-dijle', 'enexis', 'elia')
--    GROUP BY grd
--    ORDER BY 2 DESC;
--
-- Notes:
--   * SAFE ONLINE. ADD COLUMN of a nullable column without a default is a
--     catalogue change (ACCESS EXCLUSIVE for milliseconds, no rewrite). The
--     UPDATE locks only the rows whose value actually changes, so a replay
--     touches nothing and does not bump `updated_at`.
--   * The FIRST run does bump `updated_at` on every rewritten row: the
--     BEFORE UPDATE trigger `update_meter_data_modtime` sets it to now(). The
--     rows' business dates (start_date, end_date) do not move.
--   * `SET LOCAL lock_timeout`, as in 012: the default of 0 turns a lock wait
--     behind a live backend's open transaction into an outage. LOCAL, so it
--     dies with the runner's transaction.
--   * REVERSIBLE in part: `ALTER TABLE meter_data DROP COLUMN grd_data_version,
--     DROP COLUMN grd_source;` drops the provenance. The rewrite is not undone —
--     the ids ARE the canonical values, and administrative-document already
--     maps the Walloon ones to its form labels.
--   * The base schema (crm-backend `database_script/init.sql`, vendored by the
--     production repo as `schemas/crm_db.sql`) gains both columns in the same
--     release, so a fresh install and a migrated install converge.
--
-- Idempotent: safe to re-run.
--
-- Ported from crm-backend/database_script/2026-10-13_meter_data_grd_provenance.sql,
-- which is written to be run by hand with psql. The outer BEGIN;/COMMIT; is
-- removed: the runner wraps this file and the schema_version INSERT in one
-- transaction, and a COMMIT here would end it early and reintroduce exactly the
-- "applied DDL, no version recorded" state that wrapper exists to prevent.
-- Nothing else changed — the upstream file inserts no schema_version row of its
-- own and is already replay-safe.

SET LOCAL lock_timeout = '5s';

ALTER TABLE meter_data ADD COLUMN IF NOT EXISTS grd_source VARCHAR(16);
ALTER TABLE meter_data ADD COLUMN IF NOT EXISTS grd_data_version VARCHAR(32);

-- Legacy display names -> stable ids. The key is the value lower-cased, with
-- every run of whitespace and hyphens collapsed to one space, then trimmed:
-- "Fluvius Midden-Vlaanderen" and "FLUVIUS MIDDEN VLAANDEREN" both match
-- 'fluvius midden vlaanderen'. `md.grd <> m.id` skips rows already migrated.
UPDATE meter_data AS md
SET grd = m.id
FROM (
    VALUES
    ('ores', 'ores'),
    ('resa', 'resa'),
    ('aieg', 'aieg'),
    ('aiesh', 'aiesh'),
    ('rew', 'rew'),
    ('sibelga', 'sibelga'),
    ('fluvius antwerpen', 'fluvius-antwerpen'),
    ('fluvius halle vilvoorde', 'fluvius-halle-vilvoorde'),
    ('fluvius imewo', 'fluvius-imewo'),
    ('fluvius kempen', 'fluvius-kempen'),
    ('fluvius limburg', 'fluvius-limburg'),
    ('fluvius midden vlaanderen', 'fluvius-midden-vlaanderen'),
    ('fluvius west', 'fluvius-west'),
    ('fluvius zenne dijle', 'fluvius-zenne-dijle'),
    ('enexis', 'enexis'),
    ('elia', 'elia')
) AS m (legacy_key, id)
WHERE btrim(regexp_replace(lower(md.grd), '[\s-]+', ' ', 'g')) = m.legacy_key
    AND md.grd <> m.id;
