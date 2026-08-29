# OptimCE - Migrator

Applies sequential SQL migrations to OptimCE databases. Each target database tracks its
schema with a `schema_version` table; the updater compares the current version against a
manifest, then applies every newer SQL file in order, in a transaction.

No Alembic. SQLAlchemy async + asyncpg, plain `.sql` files, hand-curated manifest.

## Layout

```
optimce-migrator/
  migrator.py
  database.config                       # which databases to manage
  migrations/
    <database-name>/
      migration.json                    # version -> sql file map (REQUIRED, even if empty)
      001_init_schema_version.sql
      002_...sql
```

One subfolder per key in `database.config`: `optimce-crm`, `allocation-key`,
`simulation-key`, `news-board`, `billing`, `administrative-document`.

## database.config

JSON. Lists databases by name and points each at the env var that holds its async
connection URL. Credentials never live in this file.

```json
{
  "databases": {
    "optimce-crm":             { "url_env": "OPTIMCE_CRM_DATABASE_URL", "ssl": false },
    "allocation-key":          { "url_env": "OPTIMCE_ALLOCATION_KEY_DATABASE_URL", "ssl": false },
    "simulation-key":          { "url_env": "OPTIMCE_SIMULATION_KEY_DATABASE_URL", "ssl": false },
    "news-board":              { "url_env": "OPTIMCE_NEWS_BOARD_DATABASE_URL", "ssl": false },
    "billing":                 { "url_env": "OPTIMCE_BILLING_DATABASE_URL", "ssl": false },
    "administrative-document": { "url_env": "OPTIMCE_ADMINISTRATIVE_DOCUMENT_DATABASE_URL", "ssl": false }
  }
}
```

Six databases, one per key. The key names the **database**, not the service that owns
it — `optimce-crm` is `crm_db`, `allocation-key` is `allocation_key_local`. Insertion
order is the run order (`_run_all` iterates the list in file order), and `optimce-crm`
comes first because every annexe reads the CRM.

| field    | required | meaning                                                                     |
|----------|----------|-----------------------------------------------------------------------------|
| url_env  | yes      | name of the env var holding `postgresql+asyncpg://user:pass@host:port/db`   |
| ssl      | no       | when true, connect with a default SSL context                               |

The key (`optimce-crm`) is also the name of the migrations subfolder.

> **Every entry needs its env var set, on every unscoped run.** `load_database_config`
> walks the whole file and raises on the first variable it cannot resolve, so adding a
> database here breaks every caller that has not also been given its URL — before any
> database is touched. Add the entry and the deployment's URL in the same change, or
> scope the run with `--database`.
>
> In the compose deployment those six URLs live in one `environment:` block in
> `production/docker-compose/docker-compose.yml`. That file and this image are updated
> by two *different* commands — `git pull` and `docker compose pull` — and nothing
> enforces their order. Pull the repo first. Reversed, the run exits 1 with a message
> that names an environment variable and not the file it belongs in. The saving grace
> is that it fails at config-resolution time, before a single connection is opened, so
> the blast radius is a failed one-shot rather than a half-migrated database.

### Two shapes of migration set

Which version a set starts at depends on who creates the database:

- **`optimce-crm`** — the CRM base schema (`crm-backend/database_script/init.sql`)
  carries **no** `schema_version` table, so this set bootstraps it at version 1 and
  climbs from there.
- **annexe databases** (`allocation-key`, `simulation-key`, `news-board`, `billing`,
  `administrative-document`) — each service's own `scripts/sql/schema.sql` creates
  `schema_version` *and* self-inserts a row for **every version it already embodies**.
  Those sets therefore **start at version 2** and ship no bootstrap migration.

**`schema.sql` is not "version 1 forever", and that is the part people get wrong.**
`allocation-key-generation/scripts/sql/schema.sql` inserts rows 1, 2 **and** 3, so a
database created from it today is already at 3 and this migrator correctly skips both of
its files. They exist for the databases created *before* them.

| set | starts at | top version here | upstream source |
|---|---|---|---|
| `optimce-crm`             | 1 | 10 | `crm-backend/database_script/*.sql` |
| `allocation-key`          | 2 |  3 | `allocation-key-generation/scripts/sql/migrations/` |
| `simulation-key`          | 2 |  2 | `simulation-key/scripts/sql/migrations/` |
| `news-board`              | — |  — | `news-board/scripts/sql/` — nothing pending yet |
| `billing`                 | 2 |  2 | `billing/scripts/sql/migrations/` |
| `administrative-document` | 2 |  2 | `administrative-document/scripts/sql/seeds/` |

**A manifest `description` must be byte-identical to the string the upstream
`schema.sql` self-inserts for that version.** A fresh install writes it from
`schema.sql`, a migrated install writes it from the manifest, and `schema_version` is
the only record either path leaves. If the two strings differ, "version 3" names two
different changes depending on how the database came to exist.

**`news-board` is registered with an empty manifest** — literally
`{"migrations": []}`. `load_migrations` returns an empty list, `update_database` logs
`0 pending migration(s)` and returns; the cost is one connection. It is registered ahead
of need so the deployment's environment block is already complete on the day news-board
gets its first migration — the alternative is a release that has to change
`database.config` here and the compose file there in the same breath, which is the
coupling that has already failed once. Note that the manifest **file** is what makes
this work: `load_migrations` raises `FileNotFoundError` on a missing `migration.json`,
so an empty directory is not enough.

A migration set is **not** a from-scratch schema. `optimce-crm` creates 9 of the CRM's 30
tables and assumes the rest exist: migration 002 references `sharing_operation`, 005
references `community`, 010 assumes `address`, and nothing here ever creates
`update_changetimestamp_column()`. The base schema stands a database up; the migrator
evolves it. Provision first, migrate second.

## migration.json

```json
{
  "migrations": [
    { "version": 1, "file": "001_init_schema_version.sql", "description": "Bootstrap schema_version table" }
  ]
}
```

Versions are positive integers, must be unique, and are applied in ascending order.

## Adding a migration

1. Create `migrations/<db-name>/NNN_what_it_does.sql`.
2. Append a new entry to `migrations/<db-name>/migration.json` with the next version
   number, the file name, and a short description.
3. Commit both files together.

**A file on disk that is not in the manifest does not exist.** `load_migrations` reads
only `migration.json`; an unregistered `.sql` file is silently never applied, and nothing
warns you. Adding the file and forgetting the manifest entry is the easiest mistake to
make here and the hardest to notice.

Rules for the SQL itself:

- **Do not open a transaction.** No `BEGIN;`/`COMMIT;` — the runner wraps each file in one
  transaction together with the `INSERT INTO schema_version`, so a failure rolls back
  both. A `COMMIT` inside the file ends that transaction early and re-splits them, which
  is exactly the "applied DDL, no version recorded" state the wrapper exists to prevent.
- **Do not insert your own `schema_version` row.** The runner writes it, using the version
  and description from the manifest. A file that inserts its own collides on the primary
  key and aborts.
- **Be idempotent.** `CREATE TABLE`/`INDEX IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`,
  `DROP TRIGGER IF EXISTS` before `CREATE TRIGGER`, `ON CONFLICT DO NOTHING` on data.
  A migration can be replayed — against a database restored from a base schema that
  already contains some of its objects, for instance — and must survive it.
- **Adapting an upstream file? Strip three things.** Annexe migrations are copied from
  `<service>/scripts/sql/migrations/`, where they are written to be run by hand with
  `psql`. Every one of them opens `BEGIN;`/`COMMIT;`, self-inserts its `schema_version`
  row, and may not be replay-safe — `ALTER TABLE ... RENAME COLUMN` has no `IF EXISTS`
  (see `allocation-key/002_file_storage_key.sql` for the `DO $$` guard that fixes it).
  Remove the first two, fix the third, and keep the description byte-identical to the
  one the upstream `schema.sql` inserts.

For a database whose base schema has no `schema_version` table, the first migration
**must** create it: the runner treats "table not found" as version `0`, so the bootstrap
applies itself cleanly on a fresh database. Annexe databases whose `schema.sql` already
self-inserts its versions skip this and start at version 2.

## Running

```bash
# install deps once
.venv/Scripts/python -m pip install -r requirements.txt

# point at the target databases. An UNSCOPED run needs one URL per entry in
# database.config — all six — or it exits 1 before touching anything. Working on
# one database? Use --database and export only its URL.
export OPTIMCE_CRM_DATABASE_URL=postgresql+asyncpg://crm_svc:pass@localhost:5432/crm_db
export OPTIMCE_ALLOCATION_KEY_DATABASE_URL=postgresql+asyncpg://allocation_key_svc:pass@localhost:5432/allocation_key_local
export OPTIMCE_SIMULATION_KEY_DATABASE_URL=postgresql+asyncpg://simulation_key_svc:pass@localhost:5432/simulation_key_local
export OPTIMCE_NEWS_BOARD_DATABASE_URL=postgresql+asyncpg://news_board_svc:pass@localhost:5432/news_board_local
export OPTIMCE_BILLING_DATABASE_URL=postgresql+asyncpg://billing_svc:pass@localhost:5432/billing_local
export OPTIMCE_ADMINISTRATIVE_DOCUMENT_DATABASE_URL=postgresql+asyncpg://administrative_document_svc:pass@localhost:5432/administrative_document_local
# preview pending migrations
python migrator.py --dry-run

# apply to every database in database.config
python migrator.py

# apply to one database only
python migrator.py --database optimce-crm
```

Flags:

- `--database NAME` — scope to a single database from `database.config`.
- `--dry-run` — list pending migrations, change nothing, do not require write access.
- `--verbose` — DEBUG-level logging.

## Behavior

- Each migration runs in its own transaction together with the `INSERT INTO schema_version`
  row, so a partial apply cannot record a false success — and the reverse: applied DDL
  cannot go unrecorded. This holds only because `apply_migration` forces the transaction
  open before executing the file (SQLAlchemy's asyncpg adapter starts it lazily, on the
  first statement issued through the adapter, and the migration itself runs on the raw
  connection) **and** because no migration file opens a transaction of its own. Both
  halves are load-bearing; see the comment in `apply_migration`.
- If a migration fails, prior migrations stay applied; fix the SQL (or the data) and
  re-run — the migrator will resume from the last recorded version.
- Multi-database runs are sequential. One database's failure does not abort the others;
  the script exits non-zero if any database failed and lists which ones.

## Docker

The Dockerfile bakes `migrator.py`, `database.config`, and the entire `migrations/` tree
into the image. **Each image release ships its target schema version** — pulling and
running a new image brings every database in `database.config` up to that version.

```bash
docker build -t optimce-updater:dev .
```

Run as a one-shot job inside the platform's docker network. The connection URL is
provided via env var (the same env var named in `database.config`):

```bash
docker run --rm \
  --network optimce_default \
  -e OPTIMCE_CRM_DATABASE_URL=postgresql+asyncpg://crm_user:pass@postgres:5432/crm_db \
  optimce-updater:dev
```

In `docker-compose.yml`:

```yaml
services:
  optimce-updater:
    image: optimce-updater:${TAG:-latest}
    restart: "no"
    environment:
      # One per entry in database.config — a missing one fails the whole run.
      OPTIMCE_CRM_DATABASE_URL: postgresql+asyncpg://crm_svc:${CRM_DB_PASSWORD}@postgres:5432/crm_db
      OPTIMCE_ALLOCATION_KEY_DATABASE_URL: postgresql+asyncpg://allocation_key_svc:${ALLOCATION_KEY_DB_PASSWORD}@postgres:5432/allocation_key_local
      OPTIMCE_SIMULATION_KEY_DATABASE_URL: postgresql+asyncpg://simulation_key_svc:${SIMULATION_KEY_DB_PASSWORD}@postgres:5432/simulation_key_local
      OPTIMCE_NEWS_BOARD_DATABASE_URL: postgresql+asyncpg://news_board_svc:${NEWS_BOARD_DB_PASSWORD}@postgres:5432/news_board_local
      OPTIMCE_BILLING_DATABASE_URL: postgresql+asyncpg://billing_svc:${BILLING_DB_PASSWORD}@postgres:5432/billing_local
      OPTIMCE_ADMINISTRATIVE_DOCUMENT_DATABASE_URL: postgresql+asyncpg://administrative_document_svc:${ADMINISTRATIVE_DOCUMENT_DB_PASSWORD}@postgres:5432/administrative_document_local
    depends_on:
      postgres:
        condition: service_healthy
```

The image's `ENTRYPOINT` is `python migrator.py`, so any flags (`--dry-run`, `--database`,
`--verbose`) can be passed as arguments to `docker run` or `command:` in compose:

```bash
docker run --rm ... optimce-updater:dev --dry-run
```
