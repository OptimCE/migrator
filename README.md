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
      migration.json                    # version -> sql file map
      001_init_schema_version.sql
      002_...sql
```

## database.config

JSON. Lists databases by name and points each at the env var that holds its async
connection URL. Credentials never live in this file.

```json
{
  "databases": {
    "optimce-crm":             { "url_env": "OPTIMCE_CRM_DATABASE_URL", "ssl": false },
    "billing":                 { "url_env": "OPTIMCE_BILLING_DATABASE_URL", "ssl": false },
    "administrative-document": { "url_env": "OPTIMCE_ADMINISTRATIVE_DOCUMENT_DATABASE_URL", "ssl": false }
  }
}
```

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

### Two shapes of migration set

Which version a set starts at depends on who creates the database:

- **`optimce-crm`** — the CRM base schema (`crm-backend/database_script/init.sql`)
  carries **no** `schema_version` table, so this set bootstraps it at version 1 and
  climbs from there.
- **annexe databases** (`billing`, `administrative-document`) — each service's own
  `scripts/sql/schema.sql` creates `schema_version` *and* self-inserts row 1. Those sets
  therefore **start at version 2** and ship no bootstrap migration.

A migration set is **not** a from-scratch schema. `optimce-crm` creates 9 of the CRM's 30
tables and assumes the rest exist: migration 002 references `sharing_operation`, 005
references `community`, and nothing here ever creates `update_changetimestamp_column()`.
The base schema stands a database up; the migrator evolves it. Provision first, migrate
second.

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

For a database whose base schema has no `schema_version` table, the first migration
**must** create it: the runner treats "table not found" as version `0`, so the bootstrap
applies itself cleanly on a fresh database. Annexe databases whose `schema.sql` already
self-inserts row 1 skip this and start at version 2.

## Running

```bash
# install deps once
.venv/Scripts/python -m pip install -r requirements.txt

# point at the target database
export OPTIMCE_CRM_DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/crm_db
export OPTIMCE_BILLING_DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/billing_db
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
