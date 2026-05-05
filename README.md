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
    "optimce-crm": {
      "url_env": "OPTIMCE_CRM_DATABASE_URL",
      "ssl": false
    }
  }
}
```

| field    | required | meaning                                                                     |
|----------|----------|-----------------------------------------------------------------------------|
| url_env  | yes      | name of the env var holding `postgresql+asyncpg://user:pass@host:port/db`   |
| ssl      | no       | when true, connect with a default SSL context                               |

The key (`optimce-crm`) is also the name of the migrations subfolder.

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

The first migration for any new database **must** create the `schema_version` table —
the updater treats "table not found" as version `0`, so the bootstrap migration applies
itself cleanly on a fresh database.

## Running

```bash
# install deps once
.venv/Scripts/python -m pip install -r requirements.txt

# point at the target database
export OPTIMCE_CRM_DATABASE_URL=postgresql+asyncpg://user:pass@localhost:5432/crm_db

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
  row, so a partial apply cannot record a false success.
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
      OPTIMCE_CRM_DATABASE_URL: postgresql+asyncpg://crm_user:${CRM_DB_PASSWORD}@postgres:5432/crm_db
    depends_on:
      postgres:
        condition: service_healthy
```

The image's `ENTRYPOINT` is `python updater.py`, so any flags (`--dry-run`, `--database`,
`--verbose`) can be passed as arguments to `docker run` or `command:` in compose:

```bash
docker run --rm ... optimce-updater:dev --dry-run
```
