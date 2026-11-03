-- =============================================================================
-- Analyses : les documents de gestion
-- =============================================================================
-- Analyses ne connaissait des documents de gestion que leur NOMBRE par site
-- (v_analyses_sites.nb_documents_gestion). Les 15 documents ont pourtant un
-- type, un statut, une période de validité, une évaluation et, pour quatre,
-- une validation du conseil scientifique.
--
-- Une vue, v_analyses_documents_gestion, au grain (document, site) : un plan
-- multi-sites y figure une fois par site. Elle porte `en_vigueur`, calculé à
-- la date du jour, parce que le statut saisi ne suffit pas : deux documents
-- « Actif » sont échus, et quatre n'ont pas de date de fin (`en_vigueur`
-- vide : validité inconnue).
--
-- ⚠️ Le bloc ci-dessous est EXTRAIT LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas le modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée : une vue créée, rendue à adminsig, et
-- accordée au seul rôle de lecture d'Analyses.
--
-- À passer depuis le Mac, dans /Users/claude/Developpements/TerraCen :
--   set -a; eval "$(grep -E '^DB_(HOST|PORT|NAME|USER|PASSWORD)=' ~/.Renviron)"; set +a
--   PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" \
--     -v ON_ERROR_STOP=1 -f scripts/migration_analyses_documents_gestion.sql
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Les documents de gestion : une ligne par couple document-site
--
-- v_analyses_sites n'en donnait que le NOMBRE par site. « Quels sites n'ont
-- pas de plan de gestion en cours ? » ou « lesquels expirent avant fin 2027 ? »
-- restaient sans réponse. Mesuré le 2026-10-29 : 15 documents, 20 liens à des
-- sites, deux plans multi-sites (2 et 5 sites).
--
-- ⚠️ Le STATUT saisi ne dit pas si la période de validité est écoulée : deux
-- documents « Actif » sont échus (fin au 2025-12-31 et au 2026-03-05). D'où
-- `en_vigueur`, calculé à la date du jour, que le modèle doit préférer au
-- statut pour dire si un site est couvert.
--
-- ⚠️ `en_vigueur` est VIDE — inconnu — pour un document Actif sans date de
-- fin, et non vrai : 4 documents sont dans ce cas au 2026-10-29, dont deux
-- dont le nom annonce une période close (« PDG 2017-2022 », « Plan de
-- gestion 2018-2022 »). Les compter en vigueur aurait masqué l'échéance que
-- la saisie a oubliée ; vide, ils se signalent.
--
-- Un document rattaché à aucun site du périmètre garde une ligne, site vide.
-- Le commentaire libre n'est pas repris : 1 document sur 15 en porte un.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_documents_gestion AS
  SELECT d.id                     AS document_id,
         d.nom                    AS nom_document,
         t.libelle                AS type_document,
         st.libelle               AS statut,
         d.date_debut_validite,
         d.date_fin_validite,
         -- dico_statut_doc_gestion : 1 = Actif. Archivé ou en cours
         -- d'élaboration, un document ne s'applique pas ; Actif sans date de
         -- fin, on ne sait pas.
         CASE WHEN d.statut_id IS DISTINCT FROM 1         THEN FALSE
              WHEN d.date_debut_validite > current_date   THEN FALSE
              WHEN d.date_fin_validite IS NULL            THEN NULL
              ELSE d.date_fin_validite >= current_date END AS en_vigueur,
         me.libelle               AS methode_elaboration,
         -- dico_doc_gestion_evaluation : 1 = Oui, 2 = Non.
         CASE d.evaluation_id WHEN 1 THEN TRUE WHEN 2 THEN FALSE END AS evalue,
         v.valide_cs,
         v.date_cs                AS date_validation_cs,
         d.surf_m2                AS surface_m2,
         l.site_id,
         l.nom_site,
         l.type_site,
         COALESCE(n.nb_sites, 0)  AS nb_sites
  FROM gestcons.doc_gestion d
  LEFT JOIN gestcons.dico_type_doc_gestion t ON t.id = d.type_doc_gestion_id
  LEFT JOIN gestcons.dico_statut_doc_gestion st ON st.id = d.statut_id
  LEFT JOIN gestcons.dico_methode_elaboration_doc_gestion me
         ON me.id = d.methode_elaboration_doc_gestion_id
  LEFT JOIN gestcons.validation_cs v ON v.doc_gestion_id = d.id
  -- Les liens filtrés AVANT la jointure : un lien vers un site hors
  -- périmètre ne doit pas produire une ligne au site vide à côté des autres.
  LEFT JOIN (
    SELECT ds.doc_gestion_id, pe.id AS site_id, pe.nom_site, pe.type_site
      FROM gestcons.docs_gestion_sites ds
      JOIN gestcons.v_analyses_perimetre pe ON pe.id = ds.site_id
  ) l ON l.doc_gestion_id = d.id
  LEFT JOIN (
    SELECT ds.doc_gestion_id, count(*)::int AS nb_sites
      FROM gestcons.docs_gestion_sites ds
      JOIN gestcons.v_analyses_perimetre pe ON pe.id = ds.site_id
     GROUP BY ds.doc_gestion_id
  ) n ON n.doc_gestion_id = d.id
  WHERE d.actif;

COMMENT ON VIEW gestcons.v_analyses_documents_gestion IS
  'Onglet Analyses : une ligne par couple document de gestion - site couvert. Un plan de gestion multi-sites y figure une fois par site : compter les document_id DISTINCTS pour compter des documents. Un site de v_analyses_sites absent d''ici n''a aucun document de gestion enregistré.';

COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.type_document       IS 'Plan de gestion, Notice de gestion, Plan de gestion multi-sites ou Document de gestion synthétique';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.statut              IS 'Actif, Archivé ou En cours d''élaboration — le statut SAISI, qui ne dit pas si la période de validité est écoulée : pour savoir si un document s''applique aujourd''hui, lire en_vigueur';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.date_fin_validite   IS 'fin de la période de validité ; vide quand aucune échéance n''est saisie, ce qui rend en_vigueur inconnu';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.en_vigueur          IS 'vrai si le document est Actif ET que la date du jour tombe dans sa période de validité ; faux s''il est archivé, en élaboration, pas encore commencé ou échu (un document Actif dont la fin est passée est échu) ; VIDE s''il est Actif sans date de fin saisie — validité inconnue, à signaler comme telle plutôt qu''à compter d''un côté ou de l''autre';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.methode_elaboration IS 'méthode CTT88 ou autre méthode';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.evalue              IS 'vrai si le document a fait l''objet d''une évaluation';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.valide_cs           IS 'validation par le conseil scientifique ; vide quand rien n''est saisi';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.surface_m2          IS 'surface couverte par le document, en m², quand elle est saisie';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.site_id             IS 'site couvert ; vide si le document n''est rattaché à aucun site';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.nb_sites            IS 'nombre de sites que couvre le document';

ALTER VIEW gestcons.v_analyses_documents_gestion OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_documents_gestion TO terracen_analyse;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- documents (15 au 2026-10-29), liens à un site (20), en vigueur (8) et de validité inconnue (4)'
SELECT count(DISTINCT document_id)                                       AS documents,
       count(site_id)                                                    AS liens_site,
       count(DISTINCT document_id) FILTER (WHERE en_vigueur)             AS en_vigueur,
       count(DISTINCT document_id) FILTER (WHERE en_vigueur IS NULL)     AS validite_inconnue
  FROM gestcons.v_analyses_documents_gestion;

COMMIT;
