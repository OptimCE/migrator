-- Migration: 2026-08-18 — allow a simulation to source its input from the CRM
-- database instead of an uploaded file.
--
-- Until now every simulation carried an uploaded CSV/XLSX, so file_storage_key,
-- file_name and injection_name were all NOT NULL. A CRM-sourced run has none of
-- them: it names a sharing operation and a date range, and the worker reads
-- meter_consumption directly, matching the simulated key's participant names
-- against meter EANs.
--
-- The three file columns therefore become nullable, and a CHECK constraint takes
-- over the job they were doing — each source shape must be fully populated, so a
-- half-specified row is still impossible.
--
-- data_warnings holds non-blocking findings from the pre-flight (currently:
-- participants whose meter has gaps, which are zero-filled). It is persisted
-- rather than only shown before launch, because a warning the manager sees once
-- and never again is not really a warning.
--
-- Notes:
--   * Version 1 of this database is `simulation-key/scripts/sql/schema.sql`,
--     which creates schema_version AND self-inserts rows 1 and 2. That is why
--     this set starts at 2 and ships no bootstrap migration, and why a fresh
--     install lands at 2 and skips this file.
--   * There is no rename here, unlike allocation-key: `simulation` has carried
--     `file_storage_key` since version 1. The two sets are one version apart for
--     that reason and no other.
--   * The upstream copy records its own version row; that INSERT is removed here
--     because migrator.py writes it, from the manifest.
--   * ADD CONSTRAINT validates every existing row, which is safe because the
--     three file columns were NOT NULL until the statement above it: every
--     pre-existing row has source = 1 with all three populated.
--
-- Idempotent: safe to re-run.

ALTER TABLE simulation
    ALTER COLUMN file_storage_key DROP NOT NULL,
    ALTER COLUMN file_name        DROP NOT NULL,
    ALTER COLUMN injection_name   DROP NOT NULL;

ALTER TABLE simulation
    ADD COLUMN IF NOT EXISTS source               SMALLINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS id_sharing_operation INTEGER  NULL,
    ADD COLUMN IF NOT EXISTS period_start         DATE     NULL,
    ADD COLUMN IF NOT EXISTS period_end           DATE     NULL,
    ADD COLUMN IF NOT EXISTS data_warnings        JSONB    NULL;

-- 1=FILE, 2=CRM. Existing rows keep the DEFAULT 1 and satisfy the FILE branch.
ALTER TABLE simulation DROP CONSTRAINT IF EXISTS ck_simulation_source;
ALTER TABLE simulation ADD CONSTRAINT ck_simulation_source CHECK (
    (source = 1
        AND file_storage_key IS NOT NULL
        AND file_name        IS NOT NULL
        AND injection_name   IS NOT NULL)
 OR (source = 2
        AND id_sharing_operation IS NOT NULL
        AND period_start         IS NOT NULL
        AND period_end           IS NOT NULL
        AND period_start <= period_end)
);
