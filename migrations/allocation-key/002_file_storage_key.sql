-- Migration: 2026-05-12 — rename generation.file_url to file_storage_key.
--
-- Before this migration, file_url stored an externally hosted URL passed by the
-- client. After it, the column stores an opaque S3 object key inside
-- STORAGE_BUCKET (MinIO). The service uploads the file at creation time and the
-- worker deletes it on terminal outcomes. Widening to VARCHAR(512) gives
-- headroom for the longer keys (allocations/<community>/<uuid>/<filename>).
--
-- Notes:
--   * Version 1 of this database is
--     `allocation-key-generation/scripts/sql/schema.sql`, which creates
--     schema_version AND self-inserts rows 1, 2 AND 3. That is why this set
--     starts at 2 and ships no bootstrap migration — and why a fresh install
--     lands at 3 with nothing pending and never runs this file at all. It
--     exists for the databases created before it.
--   * The upstream copy records its own version row; that INSERT is removed here
--     because migrator.py writes it, from the manifest.
--   * The upstream copy is a bare `RENAME COLUMN`, which has no IF EXISTS and
--     fails with `column "file_url" does not exist` on a second pass. The runner
--     only offers a file whose version exceeds the recorded one, so on an honest
--     schema_version this runs at most once — but the recorded version and the
--     column shape are two independent facts. A data-only pg_restore, a
--     hand-deleted version row, or a volume created outside this repo all break
--     the correspondence, and without the guard the failure aborts the whole
--     allocation-key run BEFORE 003 gets a chance. The guard turns that into a
--     no-op.
--   * Both columns present at once is not a state this file can resolve — it
--     cannot know which one holds the data — so it stops loudly. The runner's
--     transaction rolls back and records nothing, so re-running after a manual
--     fix is safe.
--   * information_schema.columns rather than pg_attribute: the migrator connects
--     as this database's owner, so nothing is hidden from it, and the catalogue
--     view survives a major-version upgrade unchanged.
--
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'generation'
          AND column_name  = 'file_url'
    ) THEN
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name   = 'generation'
              AND column_name  = 'file_storage_key'
        ) THEN
            RAISE EXCEPTION
                'generation carries BOTH file_url and file_storage_key. This '
                'migration will not guess which one holds the data. Resolve by '
                'hand, then re-run the migrator.';
        END IF;

        EXECUTE 'ALTER TABLE generation RENAME COLUMN file_url TO file_storage_key';
    END IF;
END
$$;

-- Widen only when it is not already 512. A same-type ALTER skips the table
-- rewrite but still takes ACCESS EXCLUSIVE; skipping it makes a replay free
-- rather than merely harmless.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name   = 'generation'
          AND column_name  = 'file_storage_key'
          AND character_maximum_length IS DISTINCT FROM 512
    ) THEN
        EXECUTE 'ALTER TABLE generation ALTER COLUMN file_storage_key TYPE VARCHAR(512)';
    END IF;
END
$$;
