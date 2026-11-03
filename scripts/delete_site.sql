-- ============================================================
-- Suppression complète d’un site (ou d’un secteur) — gestcons
-- ============================================================
-- Reconstruit le 2026-10-15. Le script validé en août 2026 avait été écrasé
-- par erreur et n’était pas versionné.
-- Écrasé une SECONDE fois le 2026-10-28 (3731f7b) par un script de contrats —
-- conservé à part, scripts/fix_contrats_site43_pech_saint_sauveur.sql — puis
-- restauré depuis 2fc6379 et mis à jour : identifiant vide par défaut, purge
-- conditionnelle de parcelles_perimetre_old, contrats et actions devenus sans
-- parcelle listés en section 4. Revalidé le jour même en ROLLBACK.
--
-- ⚠️ RENSEIGNER L’IDENTIFIANT CI-DESSOUS, puis lire l’inventaire de la
--    section 2 AVANT de remplacer le ROLLBACK final par un COMMIT.
-- ⚠️ test et prod partagent cette base : la suppression vaut pour la prod.
--
-- Ordre imposé par les clés étrangères, presque toutes en NO ACTION :
--   1. les six tables qui pointent vers parcelles_base (une septième,
--      parcelles_communes — les communes d’un périmètre manuel — suit en
--      cascade)
--   2. parcelles_base  (le déclencheur trg_del_perimetre_manuel purge au
--      passage le polygone d’une parcelle manuelle — type_parcelle_id = 2)
--   3. parcelles_perimetre_old, vestige conditionnel
--   4. les sept autres tables qui pointent vers sites
--   5. sites
--
-- Les DOCUMENTS de gestion ne sont PAS supprimés : seul le lien au site l’est.
-- Un document peut être partagé, et des fichiers vivent sur le disque. La
-- section 4 liste ceux qui deviendraient orphelins, à traiter sciemment.
-- Même règle pour les CONTRATS et les ACTIONS : seuls leurs liens aux
-- parcelles du site partent. La section 4 liste ceux qui n’auraient plus
-- aucune parcelle — typiquement le contrat de préfiguration créé avec le
-- site. C’est en les oubliant qu’on accumule des contrats sans parcelle.
-- ============================================================

-- ---------- 1. LE SITE À SUPPRIMER ----------
-- DROP préalable : la connexion d’un client comme DBeaver survit à l’exécution,
-- donc la table temporaire d’un passage précédent est encore là et le CREATE
-- échouerait sur « relation cible already exists ». Le script reste rejouable.
DROP TABLE IF EXISTS pg_temp.cible;
CREATE TEMP TABLE cible AS SELECT NULL::int AS site_id;   -- ⬅️ À RENSEIGNER

-- Contrats et actions liés aux parcelles du site, relevés AVANT la suppression :
-- la section 4 dira lesquels se retrouvent sans aucune parcelle.
DROP TABLE IF EXISTS pg_temp.lies;
CREATE TEMP TABLE lies AS
  SELECT DISTINCT 'contrat foncier'::text AS nature, x.contrat_id AS id
    FROM gestcons.contrats_foncier_parcelles x
    JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id JOIN cible c ON c.site_id = p.site_id
  UNION SELECT DISTINCT 'contrat agricole', x.contrat_agri_id
    FROM gestcons.contrats_agricoles_parcelles x
    JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id JOIN cible c ON c.site_id = p.site_id
  UNION SELECT DISTINCT 'action foncière', x.animation_id
    FROM gestcons.animation_fonciere_parcelles x
    JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id JOIN cible c ON c.site_id = p.site_id
  UNION SELECT DISTINCT 'action agricole', x.animation_id
    FROM gestcons.animation_contrat_agricole_parcelles x
    JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id JOIN cible c ON c.site_id = p.site_id;

-- ---------- 2. INVENTAIRE AVANT ----------
SELECT 'site' AS objet,
       s.id || ' — ' || s.libelle || ' (' || d.libelle || ')' AS valeur
  FROM gestcons.sites s
  JOIN gestcons.dico_type_site d ON d.id = s.type_site_id
  JOIN cible c ON c.site_id = s.id
UNION ALL SELECT 'parcelles du site', count(*)::text FROM gestcons.parcelles_base p, cible c
  WHERE p.site_id = c.site_id AND NOT p.perimetre
UNION ALL SELECT 'parcelles de continuité', count(*)::text FROM gestcons.parcelles_base p, cible c
  WHERE p.site_id = c.site_id AND p.perimetre
UNION ALL SELECT 'dont parcelles manuelles', count(*)::text FROM gestcons.parcelles_base p, cible c
  WHERE p.site_id = c.site_id AND p.type_parcelle_id = 2
UNION ALL SELECT 'liens de contrat foncier', count(*)::text FROM gestcons.contrats_foncier_parcelles x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'liens de contrat agricole', count(*)::text FROM gestcons.contrats_agricoles_parcelles x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'actions foncières', count(*)::text FROM gestcons.animation_fonciere_parcelles x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'actions agricoles', count(*)::text FROM gestcons.animation_contrat_agricole_parcelles x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'protections de parcelles', count(*)::text FROM gestcons.parcelles_protection x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'sources géométriques', count(*)::text FROM gestcons.parcelles_sources_geom x
  JOIN gestcons.parcelles_base p ON p.id = x.parcelle_id, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'documents de gestion liés', count(*)::text FROM gestcons.docs_gestion_sites x, cible c
  WHERE x.site_id = c.site_id
UNION ALL SELECT 'statuts', count(*)::text FROM gestcons.sites_statuts x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'responsables', count(*)::text FROM gestcons.responsable_sites x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'bénévoles', count(*)::text FROM gestcons.conservateur_benevole x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'animateurs', count(*)::text FROM gestcons.animateur_sites x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'habitats cartographiés', count(*)::text FROM gestcons.carto_habitat x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'ouvertures au public', count(*)::text FROM gestcons.ouverture_public_sites x, cible c WHERE x.site_id = c.site_id;

-- Verdict de la garde. Volontairement NON bloquant : une exception abandonne
-- la transaction, et DBeaver refuse alors tout le reste du script avec
-- « current transaction is aborted », qui masque la vraie cause. On affiche
-- donc un verdict a LIRE. Sans COMMIT, un identifiant errone ne supprime de
-- toute facon rien.
SELECT CASE WHEN count(*) = 0
            THEN '*** ARRET — aucun site avec cet identifiant. Renseignez la table cible, section 1. NE PAS passer au COMMIT. ***'
            ELSE '*** OK — site trouve. Relisez l inventaire ci-dessus avant de passer au COMMIT. ***'
       END AS verdict
  FROM gestcons.sites s, cible c WHERE s.id = c.site_id;

-- ---------- 3. SUPPRESSION ----------
-- La transaction ne commence QU ICI. Les sections 1 et 2 sont en lecture seule :
-- si la garde echoue, elle echoue seule, avec son message. Ouvrir la
-- transaction plus tot ferait refuser tout ce qui suit avec
-- « current transaction is aborted », qui masque la vraie cause.
BEGIN;

SET lock_timeout = '10s';

-- 3a. Les six tables qui pointent vers parcelles_base
DELETE FROM gestcons.contrats_foncier_parcelles x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;
DELETE FROM gestcons.contrats_agricoles_parcelles x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;
DELETE FROM gestcons.animation_fonciere_parcelles x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;
DELETE FROM gestcons.animation_contrat_agricole_parcelles x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;
DELETE FROM gestcons.parcelles_protection x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;
DELETE FROM gestcons.parcelles_sources_geom x
 USING gestcons.parcelles_base p, cible c
 WHERE x.parcelle_id = p.id AND p.site_id = c.site_id;

-- 3b. Les parcelles. trg_del_perimetre_manuel purge le polygone des manuelles.
DELETE FROM gestcons.parcelles_base p USING cible c WHERE p.site_id = c.site_id;

-- 3c. Vestige de la fusion de 2026 : parcelles_perimetre_old garde une cle
-- etrangere vers sites. Purge CONDITIONNELLE, pour que le script survive a la
-- suppression de la table : EXECUTE, et non un DELETE ecrit en clair, qu'il
-- faudrait sinon penser a retirer d'ici ce jour-la.
DO $$
BEGIN
  IF to_regclass('gestcons.parcelles_perimetre_old') IS NOT NULL THEN
    EXECUTE 'DELETE FROM gestcons.parcelles_perimetre_old p USING cible c WHERE p.site_id = c.site_id';
  END IF;
END $$;

-- 3d. Les sept autres tables qui pointent vers sites
DELETE FROM gestcons.docs_gestion_sites   x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.sites_statuts        x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.responsable_sites    x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.conservateur_benevole x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.animateur_sites      x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.carto_habitat        x USING cible c WHERE x.site_id = c.site_id;
DELETE FROM gestcons.ouverture_public_sites x USING cible c WHERE x.site_id = c.site_id;

-- 3e. Le site
DELETE FROM gestcons.sites s USING cible c WHERE s.id = c.site_id;

-- ---------- 4. CONTRÔLES — tout doit être à 0 ----------
SELECT 'site restant' AS controle, count(*)::text AS valeur FROM gestcons.sites s, cible c WHERE s.id = c.site_id
UNION ALL SELECT 'parcelles restantes', count(*)::text FROM gestcons.parcelles_base p, cible c WHERE p.site_id = c.site_id
UNION ALL SELECT 'statuts restants', count(*)::text FROM gestcons.sites_statuts x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'responsables restants', count(*)::text FROM gestcons.responsable_sites x, cible c WHERE x.site_id = c.site_id
UNION ALL SELECT 'liens de documents restants', count(*)::text FROM gestcons.docs_gestion_sites x, cible c WHERE x.site_id = c.site_id;

-- Documents devenus orphelins : à traiter sciemment, fichiers compris.
SELECT 'document orphelin' AS info, d.id::text || ' — ' || COALESCE(d.nom, '(sans nom)') AS valeur
  FROM gestcons.doc_gestion d
 WHERE NOT EXISTS (SELECT 1 FROM gestcons.docs_gestion_sites x WHERE x.doc_gestion_id = d.id);

-- Contrats et actions qui n’ont plus AUCUNE parcelle : à supprimer ou à
-- garder sciemment, depuis l’onglet Contrats ou Actions.
SELECT l.nature || ' sans parcelle' AS info, l.id::text || ' — ' || COALESCE(n.nom, '(sans nom)') AS valeur
  FROM lies l
  LEFT JOIN LATERAL (
    SELECT cf.nom FROM gestcons.contrats_fonciers cf WHERE l.nature = 'contrat foncier' AND cf.id = l.id
    UNION ALL SELECT ca.nom FROM gestcons.contrats_agricoles ca WHERE l.nature = 'contrat agricole' AND ca.id = l.id
    -- Une action n’a pas de titre : sa date et le début de sa description.
    UNION ALL SELECT to_char(af.date, 'DD/MM/YYYY') || ' — ' || left(COALESCE(af.description, ''), 60)
      FROM gestcons.animation_fonciere af WHERE l.nature = 'action foncière' AND af.id = l.id
    UNION ALL SELECT to_char(ag.date, 'DD/MM/YYYY') || ' — ' || left(COALESCE(ag.description, ''), 60)
      FROM gestcons.animation_contrat_agricole ag WHERE l.nature = 'action agricole' AND ag.id = l.id
  ) n ON TRUE
 WHERE (l.nature = 'contrat foncier'
        AND NOT EXISTS (SELECT 1 FROM gestcons.contrats_foncier_parcelles x WHERE x.contrat_id = l.id))
    OR (l.nature = 'contrat agricole'
        AND NOT EXISTS (SELECT 1 FROM gestcons.contrats_agricoles_parcelles x WHERE x.contrat_agri_id = l.id))
    OR (l.nature = 'action foncière'
        AND NOT EXISTS (SELECT 1 FROM gestcons.animation_fonciere_parcelles x WHERE x.animation_id = l.id))
    OR (l.nature = 'action agricole'
        AND NOT EXISTS (SELECT 1 FROM gestcons.animation_contrat_agricole_parcelles x WHERE x.animation_id = l.id))
 ORDER BY 1, 2;

-- Remplacer par COMMIT une fois l’inventaire et les contrôles lus.
ROLLBACK;
