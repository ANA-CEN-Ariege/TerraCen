-- Migration — export FCEN : exclure explicitement les secteurs.
--
-- POURQUOI. Le code et les commentaires affirment qu'un secteur d'intervention
-- prioritaire reste hors de l'export FCEN « parce qu'il n'a ni statut ni
-- gestionnaire ». C'est FAUX depuis la bascule du 2026-10-27 : les 111 sites
-- devenus secteurs ont gardé leur statut (Préfiguration) et leur gestionnaire.
--
-- Ce qui les tient réellement dehors est plus mince que ça :
--   1. v_fcen_site_perimetre_04 exige un statut courant « actif », et les 113
--      secteurs sont tous en Préfiguration ;
--   2. leurs parcelles ne franchissent aucune des trois portes d'entrée —
--      0 maîtrise, 0 protection RNN/RNR/RNC, 0 mesure compensatoire (vérifié
--      le 2026-10-28).
--
-- Autrement dit, la protection est une PROPRIÉTÉ DE LA DONNÉE, pas de la
-- structure : passer un secteur en statut « Actif », ou lui rattacher un
-- contrat, le ferait entrer dans un export officiel sans que rien ne le
-- signale. Cette migration ajoute la garde manquante, sur le type de site.
--
-- EFFET AUJOURD'HUI : AUCUN. Zéro secteur passe le filtre actuel, donc zéro
-- ligne change. C'est une garde pour la suite, pas une correction de données.
--
-- La vue est recréée à partir de sa définition courante, relue dans le
-- catalogue, à laquelle une SEULE condition est ajoutée — la dernière ligne
-- du WHERE. Rien d'autre n'est touché, et la liste des colonnes est
-- inchangée, ce qu'exige CREATE OR REPLACE VIEW.
--
-- À exécuter sous adminsig, propriétaire de la vue :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/migration_fcen_exclure_secteurs.sql
-- Rejouable sans effet de bord.

BEGIN;

CREATE OR REPLACE VIEW gestcons.v_fcen_site_perimetre_04 AS
SELECT s.id,
    s.id_cen,
    s.id_site_cen,
    s.id_site_inpn,
    s.id_site_fcen,
    s.libelle,
    s.terrain_militaire_id,
    s.site_marin_id,
    s.type_milieu_id,
    s.nature_site_inpn,
    s.geol_site_inpn,
    s.geol_id,
    s.date_crea_site,
    s.date_maj_site,
    s.nature_perimetre_id,
    s.echelle_num_id,
    s.precision_num_site_id,
    s.gestionnaire_site,
    s.operateur,
    s.surf_libre_evolution_m2,
    s.url_fiche_inpn,
    s.url_fiche_cen,
    s.doc_justif_admin,
    s.description_site,
    s.url_site_photo,
    s.sensibilite,
    s.remq_sensibilite,
    s.non_diffusion,
    s.actif,
    s.cree_par,
    s.date_creation,
    s.modifie_par,
    s.date_modification,
    NULLIF(regexp_replace(s.id_site_fcen::text, '\s'::text, ''::text, 'g'::text), ''::text) AS id_site_fcen_net,
    st.libelle AS statut_a_date_ref
   FROM gestcons.sites s
     CROSS JOIN gestcons.v_fcen_parametres prm
     LEFT JOIN LATERAL ( SELECT dss.libelle
           FROM gestcons.sites_statuts ss
             JOIN gestcons.dico_statut_sites dss ON dss.id = ss.statut_site_id
          WHERE ss.site_id = s.id AND ss.date_debut <= prm.date_ref AND (ss.date_fin IS NULL OR ss.date_fin > prm.date_ref)
          ORDER BY ss.date_debut DESC, (lower(unaccent(btrim(dss.libelle::text))) = 'actif'::text), ss.statut_site_id
         LIMIT 1) st ON true
  WHERE s.actif AND lpad(s.gestionnaire_site::text, 2, '0'::text) = prm.id_cen AND lower(unaccent(btrim(st.libelle::text))) = 'actif'::text
    AND s.type_site_id = 1;

COMMENT ON VIEW gestcons.v_fcen_site_perimetre_04 IS
  'Sites entrant dans l''export FCEN : actifs, gérés par le CEN, de statut courant « actif », et de TYPE SITE CONSERVATOIRE — les secteurs d''intervention prioritaire en sont exclus explicitement depuis le 2026-10-28.';

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles
-- ---------------------------------------------------------------------------
-- Aucun secteur ne doit figurer dans le périmètre de l'export :
--   SELECT count(*) FROM gestcons.v_fcen_site_perimetre_04 v
--    JOIN gestcons.sites s ON s.id = v.id WHERE s.type_site_id <> 1;   -- 0
--
-- Et le nombre de sites retenus ne doit PAS avoir bougé (aucun secteur ne
-- passait le filtre avant) : comparer avant/après la migration.
--   SELECT count(*) FROM gestcons.v_fcen_site_perimetre_04;
