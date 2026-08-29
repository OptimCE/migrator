-- Migration: 2026-08-18 — allow a generation to source its input from the CRM
-- database instead of an uploaded file.
--
-- Until now every generation carried an uploaded CSV/XLSX, so file_storage_key,
-- file_name and injection_name were all NOT NULL. A CRM-sourced run has none of
-- them: it names a sharing operation and a date range, and the worker reads
-- meter_consumption directly.
--
-- The three file columns therefore become nullable, and a CHECK constraint takes
-- over the job they were doing — each source shape must be fully populated, so a
-- half-specified row is still impossible.
--
-- data_warnings holds non-blocking findings from the pre-flight (currently:
-- meters with gaps, which are zero-filled). It is persisted rather than only
-- shown before launch, because a warning the manager sees once and never again
-- is not really a warning.
--
-- Notes:
--   * The upstream copy records its own version row; that INSERT is removed here
--     because migrator.py writes it, from the manifest.
--   * The SQL is otherwise unchanged, because it is already replay-safe: DROP
--     NOT NULL on an already-nullable column is a no-op rather than an error,
--     every ADD COLUMN is guarded, and the constraint is dropped before it is
--     added.
--   * ADD CONSTRAINT validates every existing row. That is safe here precisely
--     because the three file columns were NOT NULL until the statement above it:
--     every pre-existing row has source = 1 (the DEFAULT) with all three
--     populated, so it satisfies the FILE branch. If it ever fails, the runner's
--     transaction rolls back and nothing is recorded.
--   * This file assumes `file_storage_key` exists, which is migration 002's job.
--     A database whose schema_version claims 2 while the column is still
--     `file_url` fails here with `column "file_storage_key" does not exist`. The
--     fix is to correct schema_version, not to edit this file.
--
-- Idempotent: safe to re-run.

ALTER TABLE generation
    ALTER COLUMN file_storage_key DROP NOT NULL,
    ALTER COLUMN file_name        DROP NOT NULL,
    ALTER COLUMN injection_name   DROP NOT NULL;

ALTER TABLE generation
    ADD COLUMN IF NOT EXISTS source               SMALLINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS id_sharing_operation INTEGER  NULL,
    ADD COLUMN IF NOT EXISTS period_start         DATE     NULL,
    ADD COLUMN IF NOT EXISTS period_end           DATE     NULL,
    ADD COLUMN IF NOT EXISTS data_warnings        JSONB    NULL;

-- 1=FILE, 2=CRM. Existing rows keep the DEFAULT 1 and satisfy the FILE branch.
ALTER TABLE generation DROP CONSTRAINT IF EXISTS ck_generation_source;
ALTER TABLE generation ADD CONSTRAINT ck_generation_source CHECK (
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
