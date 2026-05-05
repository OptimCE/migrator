"""Apply SQL migrations to OptimCE databases tracked by a `schema_version` table."""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import ssl
import sys
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.exc import ProgrammingError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "database.config"
MIGRATIONS_DIR = BASE_DIR / "migrations"

logger = logging.getLogger("optimce-updater")


@dataclass(frozen=True)
class DatabaseConfig:
    name: str
    url: str
    ssl: bool


@dataclass(frozen=True)
class Migration:
    version: int
    file: Path
    description: str


def _build_connect_args(use_ssl: bool) -> dict:
    if not use_ssl:
        return {}
    return {"ssl": ssl.create_default_context()}


def load_database_config(only: str | None) -> list[DatabaseConfig]:
    if not CONFIG_PATH.exists():
        raise FileNotFoundError(f"database.config not found at {CONFIG_PATH}")

    raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    entries = raw.get("databases") or {}
    if not entries:
        raise ValueError("database.config has no entries under 'databases'")

    if only is not None and only not in entries:
        raise KeyError(
            f"database '{only}' not found in database.config (known: {sorted(entries)})"
        )

    configs: list[DatabaseConfig] = []
    for name, entry in entries.items():
        if only is not None and name != only:
            continue
        env_var = entry["url_env"]
        url = os.environ.get(env_var)
        if not url:
            raise EnvironmentError(
                f"environment variable {env_var!r} (for database '{name}') is not set"
            )
        configs.append(DatabaseConfig(name=name, url=url, ssl=bool(entry.get("ssl", False))))
    return configs


def load_migrations(db_name: str) -> list[Migration]:
    folder = MIGRATIONS_DIR / db_name
    manifest_path = folder / "migration.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"no migration manifest at {manifest_path}")

    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = raw.get("migrations") or []

    migrations: list[Migration] = []
    seen: set[int] = set()
    for entry in entries:
        version = entry["version"]
        if not isinstance(version, int) or version <= 0:
            raise ValueError(f"{manifest_path}: version must be a positive int, got {version!r}")
        if version in seen:
            raise ValueError(f"{manifest_path}: duplicate version {version}")
        seen.add(version)

        sql_file = folder / entry["file"]
        if not sql_file.exists():
            raise FileNotFoundError(f"{manifest_path}: SQL file not found: {sql_file}")

        migrations.append(
            Migration(version=version, file=sql_file, description=entry.get("description", ""))
        )

    migrations.sort(key=lambda m: m.version)
    return migrations


async def get_current_version(engine: AsyncEngine) -> int:
    try:
        async with engine.connect() as conn:
            result = await conn.execute(
                text("SELECT COALESCE(MAX(version), 0) FROM schema_version")
            )
            return int(result.scalar_one())
    except ProgrammingError as exc:
        # asyncpg raises UndefinedTableError when schema_version doesn't exist yet;
        # SQLAlchemy surfaces it as ProgrammingError. Treat as "fresh database, version 0".
        if "schema_version" in str(exc).lower():
            return 0
        raise


async def apply_migration(engine: AsyncEngine, migration: Migration) -> None:
    sql_text = migration.file.read_text(encoding="utf-8")
    async with engine.begin() as conn:
        raw = await conn.get_raw_connection()
        await raw.driver_connection.execute(sql_text)  # asyncpg simple query, multi-statement OK
        await conn.execute(
            text("INSERT INTO schema_version (version, description) "
                 "VALUES (:version, :description)"),
            {"version": migration.version, "description": migration.description},
        )


async def update_database(db: DatabaseConfig, dry_run: bool) -> None:
    engine = create_async_engine(
        db.url,
        pool_pre_ping=True,
        connect_args=_build_connect_args(db.ssl),
    )
    try:
        current = await get_current_version(engine)
        all_migrations = load_migrations(db.name)
        pending = [m for m in all_migrations if m.version > current]

        logger.info(
            "[%s] current version: %d, %d pending migration(s)",
            db.name,
            current,
            len(pending),
        )

        if not pending:
            return

        for m in pending:
            logger.info(
                "[%s] %s version %d (%s) from %s",
                db.name,
                "would apply" if dry_run else "applying",
                m.version,
                m.description,
                m.file.name,
            )
            if not dry_run:
                await apply_migration(engine, m)
                logger.info("[%s] applied version %d", db.name, m.version)
    finally:
        await engine.dispose()


async def _run_all(
    databases: list[DatabaseConfig], dry_run: bool
) -> list[tuple[str, BaseException]]:
    failures: list[tuple[str, BaseException]] = []
    for db in databases:
        try:
            await update_database(db, dry_run=dry_run)
        except BaseException as exc:  # noqa: BLE001 - continue with remaining DBs
            logger.exception("[%s] update failed: %s", db.name, exc)
            failures.append((db.name, exc))
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", help="Apply migrations to this database only.")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report what would be applied without changing the database.",
    )
    parser.add_argument("--verbose", action="store_true", help="Enable DEBUG logging.")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        databases = load_database_config(args.database)
    except (FileNotFoundError, KeyError, ValueError, EnvironmentError) as exc:
        logger.error("configuration error: %s", exc)
        return 1

    failures = asyncio.run(_run_all(databases, dry_run=args.dry_run))

    if failures:
        logger.error(
            "completed with %d failure(s): %s",
            len(failures),
            ", ".join(name for name, _ in failures),
        )
        return 1

    logger.info("all databases up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
