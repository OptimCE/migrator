CREATE TABLE IF NOT EXISTS schema_version (
    version      INTEGER     PRIMARY KEY,
    description  TEXT        NOT NULL,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
