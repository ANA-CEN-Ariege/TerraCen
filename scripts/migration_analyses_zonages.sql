-- =============================================================================
-- Analyses : les zonages réglementaires
-- =============================================================================
-- « Quelle surface maîtrisée en Natura 2000 ? », « quels secteurs sont en
-- ZNIEFF 1 ? » : Analyses ne savait rien des zonages. Les croiser à la volée
-- avec les 6 700 parcelles prend 4,5 à 28 s, trop près ou au-delà du délai
-- de 8 s du rôle de lecture.
--
-- Ce que fait ce script :
--   1. gestcons.vm_analyses_zonages — le croisement, fait d'avance (~5 s),
--      avec les unions par famille qui évitent de compter deux fois ce que
--      ZSC et ZPS, ou ZNIEFF 1 et 2, recouvrent ensemble ;
--   2. gestcons.rafraichir_zonages_analyses() — le recalcul, seulement si
--      des parcelles ont changé depuis ; l'onglet l'appelle avant chaque
--      question, sous le rôle de l'application (EXECUTE accordé à shiny) ;
--   3. v_analyses_zonages — une ligne par couple parcelle-zonage ;
--   4. v_analyses_surfaces_zonees — une ligne par parcelle, surfaces en
--      Natura 2000, en ZNIEFF et zonée, sans double compte.
--
-- gestcons.vm_parcelles_protection, qui sert l'export FCEN, n'est PAS touchée.
--
-- ⚠️ Le bloc ci-dessous est EXTRAIT LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas le modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée. Rejouable : la vue matérialisée et son
-- index ne sont créés que s'ils n'existent pas — changer leur définition
-- demandera un DROP ... CASCADE, puis de rejouer ce script.
--
-- À passer depuis le Mac, dans /Users/claude/Developpements/TerraCen :
--   set -a; eval "$(grep -E '^DB_(HOST|PORT|NAME|USER|PASSWORD)=' ~/.Renviron)"; set +a
--   PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" \
--     -v ON_ERROR_STOP=1 -f scripts/migration_analyses_zonages.sql
-- =============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- Les zonages réglementaires : un calcul fait d'avance, et deux vues
--
-- ZNIEFF 1 et 2, Natura 2000 (ZSC, ZPS), APPB, réserves : 140 zonages, dans
-- gestcons.dico_protection. Les croiser avec les 6 700 parcelles prend de
-- 4,5 s (zonages découpés à 256 sommets) à 28 s (sans découpage), mesuré le
-- 2026-10-29 : trop près du délai de 8 s du rôle de lecture, et à refaire à
-- chaque requête. Le croisement est donc fait D'AVANCE, dans une vue
-- matérialisée que deux vues ordinaires présentent.
--
-- ⚠️ gestcons.vm_parcelles_protection, qui existait déjà, ne convient pas :
-- bâtie sur la vue de compatibilité gestcons.parcelles, elle ne couvre que
-- les parcelles contractuelles du cadastre — ni continuités, ni secteurs, ni
-- périmètres tracés — et n'a plus été recalculée depuis le 2026-08-04. Elle
-- sert l'export FCEN, on n'y touche pas ici.
--
-- ⚠️ Une vue matérialisée sans rafraîchissement prévu, c'est
-- vm_parcelles_protection : trois mois de retard sans que rien ne le dise.
-- Celle-ci se rafraîchit par gestcons.rafraichir_zonages_analyses(), que
-- l'onglet appelle avant chaque question. La fonction ne recalcule que si une
-- parcelle a changé depuis le dernier calcul — le journal d'audit le dit —
-- ou si ce calcul a plus de 7 jours : les zonages eux-mêmes ne sont pas
-- audités, d'où ce plafond. Les vues portent la date du calcul.
--
-- ⚠️ NE JAMAIS ADDITIONNER les surfaces de zonages de TYPES différents : ZSC
-- et ZPS se recouvrent, ZNIEFF 1 et 2 aussi. Mesuré sur nos parcelles : 5 508
-- ha en sommant ZSC et ZPS, 3 626 ha en réalité. D'où les unions par famille,
-- calculées ici sans double compte, et exposées par parcelle. Deux zonages
-- d'un MÊME type, eux, ne se recouvrent pas — ils ne font que se toucher,
-- vérifié — et se somment sans risque.
--
-- Les surfaces sont des PARTS de la surface géométrique, appliquées dans les
-- vues à surf_parc_maitrise_m2 : la surface que toutes les autres vues
-- somment. Une surface zonée se rapporte ainsi à la même base que le reste.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS gestcons.vm_analyses_zonages AS
  WITH morceaux_zonage AS MATERIALIZED (
    -- Découpés à 256 sommets : une ZNIEFF de type 2 en compte des milliers,
    -- et chaque intersection les reparcourrait tous.
    SELECT d.id AS zonage_id,
           CASE WHEN d.type LIKE 'Natura 2000%' THEN 'natura2000'
                WHEN d.type LIKE 'ZNIEFF%'      THEN 'znieff' END AS famille,
           ST_Subdivide(d.geometrie, 256) AS g
      FROM gestcons.dico_protection d
  ), parcelles AS MATERIALIZED (
    SELECT pb.id AS parcelle_id,
           COALESCE(c.geompar, ST_MakeValid(pm.geometrie)) AS geom
      FROM gestcons.parcelles_base pb
      LEFT JOIN gestcons.dico_cadastre c
             ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
      LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
             ON pb.type_parcelle_id = 2 AND pm.id = pb.parcellaire_id
     WHERE pb.actif
  ), morceaux AS MATERIALIZED (
    SELECT p.parcelle_id, z.zonage_id, z.famille,
           ST_Area(p.geom)              AS surface_geo_m2,
           ST_Intersection(p.geom, z.g) AS g
      FROM parcelles p
      JOIN morceaux_zonage z ON ST_Intersects(p.geom, z.g)
  ), unions AS (
    -- Par parcelle, l'union des morceaux de chaque famille : c'est ce qui
    -- retire le recouvrement ZSC/ZPS ou ZNIEFF 1/2.
    SELECT parcelle_id,
           ST_Area(ST_Union(g) FILTER (WHERE famille = 'natura2000')) AS natura2000_m2,
           ST_Area(ST_Union(g) FILTER (WHERE famille = 'znieff'))     AS znieff_m2,
           ST_Area(ST_Union(g))                                       AS zonee_m2
      FROM morceaux
     GROUP BY parcelle_id
  )
  SELECT m.parcelle_id,
         m.zonage_id,
         -- Bornées à 1 contre les arrondis du calcul géométrique.
         LEAST(sum(ST_Area(m.g)) / NULLIF(max(m.surface_geo_m2), 0), 1)                   AS part,
         LEAST(COALESCE(max(u.natura2000_m2), 0) / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_natura2000,
         LEAST(COALESCE(max(u.znieff_m2), 0)     / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_znieff,
         LEAST(COALESCE(max(u.zonee_m2), 0)      / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_zonee,
         now()                                                                           AS calcule_le
    FROM morceaux m
    JOIN unions u USING (parcelle_id)
   GROUP BY m.parcelle_id, m.zonage_id
  -- Même seuil que l'export FCEN : sous 10 m², c'est l'écart entre deux
  -- dessins d'une même limite, pas une parcelle dans un zonage.
  HAVING sum(ST_Area(m.g)) > 10;

-- REFRESH ... CONCURRENTLY l'exige, et c'est lui qui laisse lire la vue
-- pendant le calcul : sans lui, une question posée à ce moment attendrait.
CREATE UNIQUE INDEX IF NOT EXISTS vm_analyses_zonages_cle
  ON gestcons.vm_analyses_zonages (parcelle_id, zonage_id);

ALTER MATERIALIZED VIEW gestcons.vm_analyses_zonages OWNER TO adminsig;

-- SECURITY DEFINER : rafraîchir une vue matérialisée est réservé à son
-- propriétaire, et l'application n'est pas adminsig. Elle n'a le droit
-- d'exécuter que cette fonction, qui ne fait que ça.
CREATE OR REPLACE FUNCTION gestcons.rafraichir_zonages_analyses(forcer boolean DEFAULT false)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  calcule timestamptz;
  modifie timestamptz;
BEGIN
  -- Un seul calcul à la fois : de deux questions simultanées, la seconde part
  -- avec les données en place au lieu d'attendre.
  IF NOT pg_try_advisory_xact_lock(hashtext('gestcons.vm_analyses_zonages')) THEN
    RETURN 'en_cours';
  END IF;
  SELECT z.calcule_le INTO calcule FROM gestcons.vm_analyses_zonages z LIMIT 1;
  SELECT max(a.changed_at) INTO modifie
    FROM gestcons.audit_log a
   WHERE a.table_name IN ('parcelles_base', 'perimetre_parcellaire_manuel');
  -- La minute de marge couvre une modification en vol pendant le dernier
  -- calcul : horodatée avant lui, validée après.
  IF NOT forcer
     AND calcule IS NOT NULL
     AND calcule - interval '1 minute' >= COALESCE(modifie, '-infinity'::timestamptz)
     AND calcule > now() - interval '7 days' THEN
    RETURN 'a_jour';
  END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY gestcons.vm_analyses_zonages;
  RETURN 'recalcule';
END
$fn$;

ALTER FUNCTION gestcons.rafraichir_zonages_analyses(boolean) OWNER TO adminsig;
REVOKE ALL ON FUNCTION gestcons.rafraichir_zonages_analyses(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gestcons.rafraichir_zonages_analyses(boolean) TO shiny;

-- ---------------------------------------------------------------------------
-- Une ligne par couple parcelle-zonage : QUELS zonages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_zonages AS
  SELECT z.parcelle_id,
         c.idpar                         AS reference_cadastrale,
         pe.id                           AS site_id,
         pe.nom_site,
         pe.type_site,
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END            AS nature,
         d.id                            AS zonage_id,
         d.type                          AS type_zonage,
         d.libelle                       AS nom_zonage,
         d.id_mnhn                       AS code_zonage,
         round(pb.surf_parc_maitrise_m2 * z.part::numeric) AS surface_zonee_m2,
         round(z.part::numeric, 3)       AS part_de_la_parcelle,
         z.calcule_le
  FROM gestcons.vm_analyses_zonages z
  JOIN gestcons.parcelles_base pb ON pb.id = z.parcelle_id AND pb.actif
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  JOIN gestcons.dico_protection d ON d.id = z.zonage_id
  LEFT JOIN gestcons.dico_cadastre c ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id;

COMMENT ON VIEW gestcons.v_analyses_zonages IS
  'Onglet Analyses : une ligne par couple parcelle - zonage réglementaire qu''elle recoupe (ZNIEFF, Natura 2000, APPB, réserves) ; une parcelle hors de tout zonage n''y figure pas. Les surfaces d''un MÊME type de zonage se somment ; celles de types DIFFÉRENTS jamais, car ils se recouvrent (ZSC et ZPS, ZNIEFF 1 et 2) : pour une surface en Natura 2000, en ZNIEFF ou dans au moins un zonage, prendre v_analyses_surfaces_zonees. Recoupements calculés d''avance, à la date de calcule_le.';

COMMENT ON COLUMN gestcons.v_analyses_zonages.type_zonage         IS 'ZNIEFF1 et ZNIEFF2 (zones naturelles d''intérêt écologique, faunistique et floristique de type 1 et 2), Natura 2000 - ZSC (directive Habitats), Natura 2000 - ZPS (directive Oiseaux), APPB (arrêté préfectoral de protection de biotope), RNR (réserve naturelle régionale), RBD (réserve biologique dirigée), RNCFS (réserve nationale de chasse et de faune sauvage)';
COMMENT ON COLUMN gestcons.v_analyses_zonages.nom_zonage          IS 'nom officiel du zonage';
COMMENT ON COLUMN gestcons.v_analyses_zonages.code_zonage         IS 'identifiant national du zonage à l''INPN (FR7312003, 730030551…)';
COMMENT ON COLUMN gestcons.v_analyses_zonages.surface_zonee_m2    IS 'surface de la parcelle située dans CE zonage, en m² — rapportée à surface_m2 de v_analyses_parcelles';
COMMENT ON COLUMN gestcons.v_analyses_zonages.part_de_la_parcelle IS 'fraction de la parcelle dans ce zonage, de 0 à 1';
COMMENT ON COLUMN gestcons.v_analyses_zonages.calcule_le          IS 'date du calcul des recoupements, refait automatiquement quand des parcelles changent';

-- ---------------------------------------------------------------------------
-- Une ligne par parcelle : COMBIEN, sans double compte
--
-- TOUTES les parcelles, y compris hors zonage (surfaces à 0) : une part du
-- total se calcule donc ici sans jointure, et sans le piège d'un
-- dénominateur qui ne compterait que les parcelles zonées.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_surfaces_zonees AS
  SELECT pb.id                           AS parcelle_id,
         pe.id                           AS site_id,
         pe.nom_site,
         pe.type_site,
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END            AS nature,
         pb.surf_parc_maitrise_m2        AS surface_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_natura2000, 0)::numeric) AS surface_natura2000_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_znieff, 0)::numeric)     AS surface_znieff_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_zonee, 0)::numeric)      AS surface_zonee_m2,
         s.zonages,
         k.calcule_le
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  LEFT JOIN (
    SELECT z.parcelle_id,
           max(z.part_parcelle_natura2000)                   AS part_natura2000,
           max(z.part_parcelle_znieff)                       AS part_znieff,
           max(z.part_parcelle_zonee)                        AS part_zonee,
           string_agg(DISTINCT d.type, ', ' ORDER BY d.type) AS zonages
      FROM gestcons.vm_analyses_zonages z
      JOIN gestcons.dico_protection d ON d.id = z.zonage_id
     GROUP BY z.parcelle_id
  ) s ON s.parcelle_id = pb.id
  CROSS JOIN (SELECT max(calcule_le) AS calcule_le FROM gestcons.vm_analyses_zonages) k
  WHERE pb.actif;

COMMENT ON VIEW gestcons.v_analyses_surfaces_zonees IS
  'Onglet Analyses : une ligne par parcelle — TOUTES, même hors zonage — avec sa surface en Natura 2000, en ZNIEFF et dans au moins un zonage, calculées SANS double compte (ZSC et ZPS, ZNIEFF 1 et 2 se recouvrent). C''est la vue à sommer pour une surface en Natura 2000, en ZNIEFF ou zonée, et pour une part du total : sum(surface_natura2000_m2) / sum(surface_m2). Le détail zonage par zonage, avec les noms, est dans v_analyses_zonages.';

COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_m2            IS 'surface de la parcelle, en m² — la même que surface_m2 de v_analyses_parcelles';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_natura2000_m2 IS 'surface de la parcelle en Natura 2000, ZSC et ZPS réunies sans double compte ; 0 hors Natura 2000';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_znieff_m2     IS 'surface de la parcelle en ZNIEFF, types 1 et 2 réunis sans double compte ; 0 hors ZNIEFF';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_zonee_m2      IS 'surface de la parcelle dans AU MOINS UN zonage, tous types réunis sans double compte ; 0 si elle n''en recoupe aucun';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.zonages               IS 'types de zonages recoupés, séparés par des virgules ; vide si aucun';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.calcule_le            IS 'date du calcul des recoupements, refait automatiquement quand des parcelles changent';

ALTER VIEW gestcons.v_analyses_zonages OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_surfaces_zonees OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_zonages TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_surfaces_zonees TO terracen_analyse;

-- ---------------------------------------------------------------------------
-- Contrôles
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- couples parcelle-zonage (~14 750 au 2026-10-29), parcelles zonées, date du calcul'
SELECT count(*) AS couples, count(DISTINCT parcelle_id) AS parcelles_zonees, max(calcule_le) AS calcule_le
  FROM gestcons.vm_analyses_zonages;

\echo ''
\echo '--- Natura 2000 sur toutes nos parcelles : somme naïve ZSC + ZPS contre union (~5 508 contre ~3 626 ha)'
SELECT (SELECT round(sum(surface_zonee_m2) / 1e4) FROM gestcons.v_analyses_zonages
         WHERE type_zonage LIKE 'Natura 2000%')                       AS ha_somme_naive,
       (SELECT round(sum(surface_natura2000_m2) / 1e4)
          FROM gestcons.v_analyses_surfaces_zonees)                   AS ha_union;

\echo ''
\echo '--- la fonction de rafraîchissement, juste après le calcul : a_jour attendu'
SELECT gestcons.rafraichir_zonages_analyses() AS etat;

COMMIT;
