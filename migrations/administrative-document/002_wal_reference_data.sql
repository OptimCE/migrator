-- Migration: 2026-08-11 — Walloon (CWaPE) reference data.
--
-- The regulatory deadline rules and the document-template catalogue that the
-- administrative-document service resolves against. Without them `deadline_rule`
-- and `document_template` are empty, so deadline computation and document
-- rendering have nothing to work from: the service starts and does nothing
-- useful.
--
-- Notes:
--   * Version 1 of this database is `administrative-document/scripts/sql/schema.sql`,
--     which creates the version ledger AND self-inserts row 1. That is why this
--     set starts at 2 and ships no bootstrap migration.
--   * This file is the three upstream seed files concatenated, in order, because
--     upstream records all three as a single version 2 — keeping that parity means
--     "administrative_document_local is at version 2" says the same thing whether
--     the rows arrived through this migrator or through the monorepo's seed mount.
--     Section 3 UPDATEs rows section 2 inserts, so the order is load-bearing and
--     one migration makes the whole set atomic.
--   * The upstream copy of section 3 records its own version row; that INSERT is
--     removed here because migrator.py writes the row itself, from the manifest.
--   * `file_ref` values point at s3://optimce-templates/administrative-document/…
--     The bundles must be in the templates bucket before rendering is attempted;
--     that is a storage-seeding step, not a database one.
--
-- Idempotent: every statement is ON CONFLICT DO NOTHING or an UPDATE keyed on a
-- stable natural key. Safe to re-run.


-- ####################################################################
-- 1/3 — regulatory deadline rules (platform defaults, id_community IS NULL)
-- source: administrative-document/scripts/sql/seeds/0001_wal_deadline_rules.sql
-- ####################################################################

-- ============================================================================
-- Reference data: Walloon (CWaPE) regulatory deadline rules.
--
-- These are PLATFORM DEFAULTS: id_community IS NULL. A community may override an
-- individual rule by inserting a row with its own id_community; resolution is
-- per deadline_type, most-specific-wins (see domain/deadlines.py::resolve_rules).
--
-- Coded values (shared/const.py):
--   region       1 = WAL
--   dossier_type 1 = CREATION_NOTIFICATION, 2 = MODIFICATION, 3 = ANNUAL_REPORT,
--                4 = SHARING_AUTHORIZATION, 5 = SHARING_MODIFICATION, 6 = CESSATION
--   offset_unit  1 = business_days (jours ouvres), 2 = months (calendar)
--
-- Idempotent: the unique index on
-- (id_community, region, dossier_type, trigger_event, deadline_type) is
-- NULLS NOT DISTINCT, so re-running this file changes nothing.
-- ============================================================================


INSERT INTO deadline_rule (
    id_community, region, dossier_type, trigger_event, deadline_type,
    offset_value, offset_unit, recurring, recur_months, description
) VALUES
    -- The CWaPE checks a notification dossier for completeness within 10
    -- business days of its submission.
    (NULL, 1, 1, 'dossier.submitted', 'completeness_check',
     10, 1, FALSE, NULL,
     'CWaPE completeness check, 10 business days after the notification is submitted'),

    -- A dossier acknowledged as INCOMPLETE lapses if it is not completed within
    -- six months. Calendar months: a legal period in months runs on the wall clock.
    (NULL, 1, 1, 'document.acknowledged.incomplete', 'lapse',
     6, 2, FALSE, NULL,
     'Incomplete notification dossier lapses 6 months after the first acknowledgment'),

    -- Once the dossier is complete the community owes an annual report, and owes
    -- one every year thereafter (rolled on resolution, one open occurrence at a time).
    (NULL, 1, 1, 'dossier.complete', 'annual_report',
     12, 2, TRUE, 12,
     'Annual reporting to the CWaPE, recurring every 12 months from completion'),

    -- A change to the community must be notified to the CWaPE within 15
    -- business days of the modification dossier being submitted.
    (NULL, 1, 2, 'dossier.modification', 'modification_notification',
     15, 1, FALSE, NULL,
     'CWaPE modification notification, 15 business days after the change is filed')
ON CONFLICT DO NOTHING;


-- ####################################################################
-- 2/3 — document catalogue: which forms exist, in what format
-- source: administrative-document/scripts/sql/seeds/0002_wal_templates.sql
-- ####################################################################

-- ============================================================================
-- Reference data: the Walloon (CWaPE) document catalogue.
--
-- PLATFORM DEFAULTS (id_community IS NULL). These rows register *which* forms
-- exist, in which mandated output format, and which version is currently in
-- force -- so the catalogue is queryable from day one and a document can already
-- record which template version it corresponds to.
--
-- file_ref and mapping_json are intentionally NULL: they hold the rendering
-- bundle and the field->CRM mapping, which arrive with Phase 2 (generation).
-- Registering a revised official form is then an INSERT of a new `version` row
-- plus setting the previous row's valid_to -- never a code change or a deploy.
--
-- Coded values: region 1 = WAL. Idempotent via the NULLS NOT DISTINCT unique
-- index on (id_community, region, doc_type, version).
-- ============================================================================


INSERT INTO document_template (
    id_community, region, doc_type, version, valid_from, valid_to,
    file_ref, mapping_json, output_format, label
) VALUES
    -- Annexe 6 -- community notification (members/shareholders + installations).
    -- CWaPE mandated XLSX, document 5617, format of 2026-02-25.
    (NULL, 1, 'annex6_notification', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'xlsx', 'Annexe 6 - Notification de communaute (CWaPE 5617)'),

    -- Annexe 6 -- sharing form (sharing participants + installations).
    -- CWaPE mandated XLSX, document 5611.
    (NULL, 1, 'annex6_sharing_form', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'xlsx', 'Annexe 6 - Formulaire de partage (CWaPE 5611)'),

    -- Annexe 8 -- sworn declaration of the sharing participants (CWaPE 5612).
    (NULL, 1, 'annex8_sworn_declaration', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'pdf', 'Annexe 8 - Declaration sur l''honneur (CWaPE 5612)'),

    -- Standard agreement DSO <-> community representative (CWaPE 5614).
    (NULL, 1, 'dso_agreement_community', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'docx', 'Contrat type GRD - representant de communaute (CWaPE 5614)'),

    -- Standard agreement DSO <-> same-building sharing representative (CWaPE 5613).
    (NULL, 1, 'dso_agreement_building', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'docx', 'Contrat type GRD - partage au sein d''un meme batiment (CWaPE 5613)'),

    -- Up-to-date participant / installation lists for the annual reporting.
    -- Reuses the Annexe 6 layout.
    (NULL, 1, 'annual_participant_list', 1, DATE '2026-02-25', NULL,
     NULL, NULL, 'xlsx', 'Listes participants / installations (rapportage annuel)')
ON CONFLICT DO NOTHING;


-- ####################################################################
-- 3/3 — rendering bundles + the four main CWaPE forms Phase 1 omitted
-- source: administrative-document/scripts/sql/seeds/0003_wal_templates_phase2.sql
-- ####################################################################

-- ============================================================================
-- Phase 2: point the Walloon catalogue at its rendering bundles, and register
-- the four main CWaPE forms the Phase-1 catalogue did not cover.
--
-- file_ref is the versioned S3 prefix of a bundle under
-- administrative-document/document-templates/. mapping_json records what the
-- bundle can fill, for operators reading the registry -- the authoritative map
-- lives in the bundle's manifest.json, next to the document it describes.
--
-- Registering a revised official form stays a data change: add a row with the
-- next `version`, set the previous row's valid_to, and publish a new versioned
-- bundle directory. Never mutate a published prefix -- the template cache in
-- document-generation is keyed by URI and has no invalidation.
--
-- Coded values: region 1 = WAL. Idempotent.
-- ============================================================================


-- ---- bundles for the forms already registered in 0002 ----------------------

UPDATE document_template
   SET file_ref = 's3://optimce-templates/administrative-document/'
                  || doc_type || '/v1/',
       mapping_json = '{"engine": "xlsx", "sources": ["members", "installations"]}'::jsonb
 WHERE id_community IS NULL
   AND region = 1
   AND valid_to IS NULL
   AND doc_type IN ('annex6_notification', 'annual_participant_list');

UPDATE document_template
   SET file_ref = 's3://optimce-templates/administrative-document/'
                  || doc_type || '/v1/',
       mapping_json = '{"engine": "xlsx",
                        "sources": ["participants", "installations", "storage"]}'::jsonb
 WHERE id_community IS NULL
   AND region = 1
   AND valid_to IS NULL
   AND doc_type = 'annex6_sharing_form';

UPDATE document_template
   SET file_ref = 's3://optimce-templates/administrative-document/'
                  || doc_type || '/v1/',
       mapping_json = '{"engine": "pdf-form"}'::jsonb
 WHERE id_community IS NULL
   AND region = 1
   AND valid_to IS NULL
   AND doc_type = 'annex8_sworn_declaration';

-- The two DSO standard agreements (CWaPE 5614 / 5613): Word contracts rendered
-- by the docx engine from the regulator's own convention, with its
-- "[a completer]" markers turned into template expressions and nothing else
-- touched.
UPDATE document_template
   SET file_ref = 's3://optimce-templates/administrative-document/'
                  || doc_type || '/v1/',
       mapping_json = '{"engine": "docx"}'::jsonb
 WHERE id_community IS NULL
   AND region = 1
   AND valid_to IS NULL
   AND doc_type IN ('dso_agreement_community', 'dso_agreement_building');

-- ---- the main forms, not covered by the Phase-1 catalogue -------------------
-- Annexes 6/7/8 are attachments TO these; a dossier needs the covering form too.

INSERT INTO document_template (
    id_community, region, doc_type, version, valid_from, valid_to,
    file_ref, mapping_json, output_format, label
) VALUES
    (NULL, 1, 'community_notification', 1, DATE '2024-11-04', NULL,
     's3://optimce-templates/administrative-document/community_notification/v1/',
     '{"engine": "pdf-form"}'::jsonb, 'pdf',
     'Formulaire de notification d''une communaute d''energie (CWaPE)'),

    (NULL, 1, 'community_modification', 1, DATE '2024-06-27', NULL,
     's3://optimce-templates/administrative-document/community_modification/v1/',
     '{"engine": "pdf-form"}'::jsonb, 'pdf',
     'Formulaire de modification d''une communaute d''energie (CWaPE)'),

    (NULL, 1, 'sharing_notification', 1, DATE '2025-07-01', NULL,
     's3://optimce-templates/administrative-document/sharing_notification/v1/',
     '{"engine": "pdf-form"}'::jsonb, 'pdf',
     'Formulaire de notification d''une activite de partage (CWaPE)'),

    (NULL, 1, 'sharing_modification', 1, DATE '2025-07-01', NULL,
     's3://optimce-templates/administrative-document/sharing_modification/v1/',
     '{"engine": "pdf-form"}'::jsonb, 'pdf',
     'Formulaire de modification d''une activite de partage (CWaPE)'),

    -- Signed per legal-entity member, so the reviewer picks which one.
    (NULL, 1, 'annex7_legal_entity', 1, DATE '2026-02-06', NULL,
     's3://optimce-templates/administrative-document/annex7_legal_entity/v1/',
     '{"engine": "pdf-form"}'::jsonb, 'pdf',
     'Annexe 7 - Societes et associations (CWaPE)')
ON CONFLICT DO NOTHING;
