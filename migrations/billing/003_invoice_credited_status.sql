-- Migration: 2026-10-09 — backfill InvoiceStatus.CREDITED (7).
--
-- Issuing a credit note now moves the consumer invoice it corrects to CREDITED,
-- a terminal status: not payable, not sendable, never swept OVERDUE, and out of
-- every "unpaid" count (those count ISSUED/SENT/OVERDUE). Credit notes issued
-- before that release left their invoice ISSUED/SENT/OVERDUE/PAID, so the
-- overdue sweep could still mark a corrected bill OVERDUE and mail the member
-- that it "remains unpaid". This brings those rows to the state the service now
-- produces.
--
-- Notes:
--   * Source: `billing/scripts/sql/migrations/0003_invoice_credited_status.sql`,
--     same statement. It mirrors CREDITABLE_STATUSES in billing's
--     `shared/const.py`:
--       types:    1 = INVOICE, 2 = CREDIT_NOTE
--       statuses: 0 = DRAFT, 1 = ISSUED, 2 = SENT, 3 = PAID, 4 = OVERDUE,
--                 5 = CANCELLED, 6 = RENDER_FAILED, 7 = CREDITED
--     A DRAFT or CANCELLED credit note credits nothing; only an issued one does.
--   * Data only. `invoice.status` is a plain INTEGER with no CHECK, so neither
--     `billing/scripts/sql/schema.sql` nor this set changes the schema, and on a
--     database built from schema.sql (no rows) this is a no-op that records the
--     version.
--   * No notification is sent for the backfilled rows.
--   * ORDERING — run it with `billing` stopped or already on the image that
--     knows status 7. The previous image does not: it still accepts a second
--     credit note against the invoice, and a forced re-render of it raises on
--     `InvoiceStatus(7)`. `docker-stack.sh` (stop, migrate, start) gives that.
--
-- Idempotent: safe to re-run.
UPDATE invoice AS original
SET status = 7
FROM invoice AS credit
WHERE credit.corrects_invoice_id = original.id
  AND credit.id_community = original.id_community
  AND credit.type = 2
  AND credit.status NOT IN (0, 5)
  AND original.type = 1
  AND original.status IN (1, 2, 3, 4, 6);
