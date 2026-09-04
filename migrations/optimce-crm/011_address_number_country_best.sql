-- Migration: 2026-08-30 — house numbers become text, plus the BeSt link.
--
-- `address.number` has been an INT since the schema was written, and a Belgian
-- house number is not a number. The federal BeSt Address register — the
-- authority for all three regions — returns `12A`, `2B`, `12-14`, `1/3`,
-- `12 bis`, `2/0001`. One street in Namur alone yields `20A` and `2B`. So the
-- column cannot store what the official register hands back, and an address
-- picker fed by that register would have to mangle or reject real addresses.
--
-- The new columns support matching a stored address to the register:
--   country            ISO-3166-1 alpha-2. Defaults to BE; the schema had no
--                      country at all.
--   best_address_id    the register's stable object id, e.g.
--                      `geodata.wallonie.be/id/Address/1948446/2`. Written when
--                      a user PICKS an address from the register, so a later
--                      edit can tell a chosen address from a typed one.
--
-- ORDERING — THE ONE THING THIS MIGRATION CANNOT ENFORCE FOR ITSELF.
-- Deploy the crm-backend image BEFORE running this. `address.number` is read
-- through the `houseNumberToString` transformer, so the API emits a string
-- whether the column is `int` or `varchar` — but only once that build is live.
-- Applied first, this flips the wire type of every address response underneath
-- a frontend that was not deployed for it.
--
-- That inverts the usual order in production/DATABASE_CONSOLIDATION.md §0.0,
-- which runs the migrator (§9.1) BEFORE §8's image pull. For this release the
-- image pull moves ahead of the migrator run. production/DEPLOYMENT_PLAN.md
-- Step 6b → Step 7 is already in the right order.
--
-- REVERSIBLE, but only for now: `ALTER COLUMN number TYPE INT USING
-- number::integer` works while every stored value is still digits-only. Once
-- the API accepts `12A` that stops being true, which is why widening the
-- validation pattern is a separate, later deploy.
--
-- The type change is a full table rewrite under ACCESS EXCLUSIVE. It is
-- sub-second at this size, but it is not an online change — run it in a window,
-- not against live traffic.
--
-- Idempotent: safe to re-run.
--
-- Ported from crm-backend/database_script/2026-08-30_address_number_country_best.sql,
-- which is written to be run by hand with psql. The outer BEGIN;/COMMIT; is
-- removed: the runner wraps this file and the schema_version INSERT in ONE
-- transaction, and a COMMIT here would end it early and reintroduce exactly the
-- "applied DDL, no version recorded" state that wrapper exists to prevent.
-- Nothing else changed — the upstream file inserts no schema_version row of its
-- own and is already replay-safe.

-- The one non-idempotent statement, so it is guarded on the current type rather
-- than on IF NOT EXISTS. `USING` is required: Postgres has no implicit
-- int -> varchar assignment cast for ALTER TYPE.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE
            table_name = 'address'
            AND column_name = 'number'
            AND data_type = 'integer'
    ) THEN
        ALTER TABLE address ALTER COLUMN number TYPE VARCHAR(32) USING number::TEXT;
    END IF;
END
$$;

-- An INT NOT NULL column could not be blank; a VARCHAR one can. The DTO merge
-- in member.service.ts uses `??`, which falls back only on null/undefined, so a
-- client sending `number: ""` would otherwise write an empty house number.
ALTER TABLE address DROP CONSTRAINT IF EXISTS chk_address_number_not_blank;
ALTER TABLE address ADD CONSTRAINT chk_address_number_not_blank
CHECK (btrim(number) <> '');

ALTER TABLE address
ADD COLUMN IF NOT EXISTS country CHAR(2) NOT NULL DEFAULT 'BE';

ALTER TABLE address DROP CONSTRAINT IF EXISTS chk_address_country;
ALTER TABLE address ADD CONSTRAINT chk_address_country
CHECK (country ~ '^[A-Z]{2}$');

ALTER TABLE address ADD COLUMN IF NOT EXISTS best_address_id VARCHAR(64);

-- Partial, like idx_address_geocode_queue: empty until addresses start being
-- matched, and therefore free until then.
CREATE INDEX IF NOT EXISTS idx_address_best_id
ON address (best_address_id) WHERE best_address_id IS NOT NULL;

-- `AddressRepository.addAddress` dedups on these three columns on every write
-- and the table carried no index for it, so that lookup was a sequential scan.
-- An address picker raises write volume enough to make that matter.
CREATE INDEX IF NOT EXISTS idx_address_dedup
ON address (postcode, street, number);
