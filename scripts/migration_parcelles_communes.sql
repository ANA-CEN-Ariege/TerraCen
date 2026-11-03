-- =============================================================================
-- Rattachement territorial des périmètres manuels
-- =============================================================================
-- Une parcelle cadastrale porte sa commune dans sa référence, et n'en a qu'une :
-- le cadastre est découpé par commune. Un périmètre manuel n'a qu'une forme, et
-- peut chevaucher plusieurs communes. Les 41 périmètres de la base (1 594 ha,
-- 37 en secteur, 4 en site) échappaient donc en silence à tout regroupement
-- territorial — plus que cinq des huit EPCI de l'Ariège réunis.
--
-- On les rattache à TOUTES les communes qu'ils recouvrent : 49 couples
-- (parcelle, commune) pour 41 parcelles. Mesuré avant écriture : aucun résidu
-- topologique, la plus petite intersection fait ~2 000 m².
--
-- ⚠️ `communes.geometry` et `perimetre_parcellaire_manuel.geometrie` sont tous
-- deux en Lambert-93 (2154). NE PAS écrire ST_Transform(co.geometry, 2154) :
-- la transformation ne transforme rien mais neutralise l'index GIST, et fait
-- passer un rattachement de 3 ms à 2 411 ms (mesuré, facteur 760).
--
-- Rejouable : tout est IF NOT EXISTS / OR REPLACE, et le recalcul est idempotent.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Réparer les géométries auto-intersectées
-- -----------------------------------------------------------------------------
-- 3 des 41 périmètres se recoupent (une boucle du tracé sur lui-même) :
-- parcellaires 79, 86 et 88. ST_Intersection lève une TopologyException dessus.
-- La réparation ne change aucune surface — vérifié : 263,2 / 13,2 / 45,7 ha
-- identiques avant et après.
UPDATE gestcons.perimetre_parcellaire_manuel
   SET geometrie = ST_Multi(ST_CollectionExtract(ST_MakeValid(geometrie), 3))
 WHERE NOT ST_IsValid(geometrie);

-- -----------------------------------------------------------------------------
-- 2. La table de liaison
-- -----------------------------------------------------------------------------
-- Stockée et non calculée à la volée : le rôle `terracen_analyse` tourne avec
-- statement_timeout = 8 s, une jointure spatiale dans chaque vue mangerait ce
-- budget. Ici, les vues ne font qu'une jointure sur un entier.
CREATE TABLE IF NOT EXISTS gestcons.parcelles_communes (
  parcelle_id integer     NOT NULL REFERENCES gestcons.parcelles_base(id) ON DELETE CASCADE,
  insee_com   varchar(5)  NOT NULL,
  surface_m2  integer     NOT NULL,
  principale  boolean     NOT NULL DEFAULT false,
  PRIMARY KEY (parcelle_id, insee_com)
);

CREATE INDEX IF NOT EXISTS parcelles_communes_insee_idx
  ON gestcons.parcelles_communes (insee_com);

COMMENT ON TABLE  gestcons.parcelles_communes IS
  'Communes recouvertes par une parcelle à géométrie manuelle (type_parcelle_id = 2), avec la surface dans chacune. Les parcelles cadastrales n''y figurent PAS : leur commune est portée par leur référence. Tenue à jour par trigger.';
COMMENT ON COLUMN gestcons.parcelles_communes.surface_m2 IS
  'Surface de la parcelle DANS cette commune, en m². C''est elle qui rend exacte une somme d''hectares par commune ou par EPCI, au lieu de créditer une commune de la totalité.';
COMMENT ON COLUMN gestcons.parcelles_communes.principale IS
  'Commune du point représentatif de la parcelle — celle qu''on retient quand une seule réponse est attendue. Identique à la commune majoritaire sur les 6 parcelles à cheval de la base.';

-- -----------------------------------------------------------------------------
-- 3. Le recalcul
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gestcons.maj_parcelles_communes(p_ids integer[])
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN RETURN; END IF;

  DELETE FROM gestcons.parcelles_communes WHERE parcelle_id = ANY(p_ids);

  -- ST_MakeValid reste ici malgré la réparation du point 1 : un périmètre tracé
  -- demain peut à son tour s'auto-intersecter, et ST_Intersection lèverait.
  INSERT INTO gestcons.parcelles_communes (parcelle_id, insee_com, surface_m2, principale)
  SELECT pb.id, co.insee_com,
         round(ST_Area(ST_Intersection(g.geom, co.geometry)))::int,
         ST_Contains(co.geometry, ST_PointOnSurface(g.geom))
    FROM gestcons.parcelles_base pb
    JOIN gestcons.perimetre_parcellaire_manuel pm
      ON pm.id = pb.parcellaire_id AND pb.type_parcelle_id = 2
   CROSS JOIN LATERAL (SELECT ST_MakeValid(pm.geometrie) AS geom) g
    JOIN gestcons.communes co ON ST_Intersects(g.geom, co.geometry)
   WHERE pb.id = ANY(p_ids)
     AND ST_Area(ST_Intersection(g.geom, co.geometry)) >= 1;

  -- Filet : si le point représentatif ne tombe dans aucune commune (périmètre
  -- hors couche, ou pile sur une limite), la plus grande surface fait office de
  -- commune principale. Aucun cas dans la base au 2026-10-28, mais sans ce
  -- filet une parcelle pourrait n'avoir AUCUNE principale.
  UPDATE gestcons.parcelles_communes pc
     SET principale = true
   WHERE pc.parcelle_id = ANY(p_ids)
     AND NOT EXISTS (SELECT 1 FROM gestcons.parcelles_communes x
                      WHERE x.parcelle_id = pc.parcelle_id AND x.principale)
     AND pc.surface_m2 = (SELECT max(y.surface_m2) FROM gestcons.parcelles_communes y
                           WHERE y.parcelle_id = pc.parcelle_id);
END;
$fn$;

COMMENT ON FUNCTION gestcons.maj_parcelles_communes(integer[]) IS
  'Recalcule le rattachement territorial des parcelles données (ignore celles qui ne sont pas à géométrie manuelle). ~3 ms par parcelle.';

-- -----------------------------------------------------------------------------
-- 4. Les triggers
-- -----------------------------------------------------------------------------
-- Un trigger et non du code applicatif : les périmètres manuels s'écrivent par
-- plusieurs chemins (tracé, édition et suppression dans Sites, suppression dans
-- Stratégie), et l'un d'eux laissait encore des géométries orphelines en
-- octobre 2026. Un trigger ne s'oublie pas.
--
-- DEUX triggers, parce que l'ordre d'écriture l'impose : l'application insère
-- d'abord la géométrie, PUIS la parcelle qui la désigne. À l'insertion de la
-- géométrie, il n'y a donc encore rien à rattacher.
CREATE OR REPLACE FUNCTION gestcons.trg_perimetre_manuel_communes()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM gestcons.maj_parcelles_communes(
    ARRAY(SELECT id FROM gestcons.parcelles_base
           WHERE type_parcelle_id = 2 AND parcellaire_id = NEW.id));
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS perimetre_manuel_communes ON gestcons.perimetre_parcellaire_manuel;
CREATE TRIGGER perimetre_manuel_communes
AFTER INSERT OR UPDATE OF geometrie ON gestcons.perimetre_parcellaire_manuel
FOR EACH ROW EXECUTE FUNCTION gestcons.trg_perimetre_manuel_communes();

CREATE OR REPLACE FUNCTION gestcons.trg_parcelle_base_communes()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.type_parcelle_id = 2 THEN
    PERFORM gestcons.maj_parcelles_communes(ARRAY[NEW.id]);
  END IF;
  RETURN NULL;
END;
$fn$;

DROP TRIGGER IF EXISTS parcelle_base_communes ON gestcons.parcelles_base;
CREATE TRIGGER parcelle_base_communes
AFTER INSERT OR UPDATE OF parcellaire_id, type_parcelle_id ON gestcons.parcelles_base
FOR EACH ROW EXECUTE FUNCTION gestcons.trg_parcelle_base_communes();

-- -----------------------------------------------------------------------------
-- 5. Premier remplissage
-- -----------------------------------------------------------------------------
SELECT gestcons.maj_parcelles_communes(
         ARRAY(SELECT id FROM gestcons.parcelles_base WHERE type_parcelle_id = 2));

-- -----------------------------------------------------------------------------
-- 6. Propriété et droits
-- -----------------------------------------------------------------------------
-- adminsig propriétaire, comme tout le reste du schéma : une vue lit avec les
-- droits de SON propriétaire, et `terracen_analyse` n'a donc besoin d'aucun
-- droit sur cette table — seulement sur les vues qui la lisent.
ALTER TABLE    gestcons.parcelles_communes OWNER TO adminsig;
ALTER FUNCTION gestcons.maj_parcelles_communes(integer[])        OWNER TO adminsig;
ALTER FUNCTION gestcons.trg_perimetre_manuel_communes()          OWNER TO adminsig;
ALTER FUNCTION gestcons.trg_parcelle_base_communes()             OWNER TO adminsig;

-- `shiny` écrit dans parcelles_base : les triggers s'exécutent sous son rôle.
GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.parcelles_communes TO shiny;

-- -----------------------------------------------------------------------------
-- 7. Contrôles
-- -----------------------------------------------------------------------------
\echo ''
\echo '--- géométries invalides restantes (doit être 0)'
SELECT count(*) AS invalides FROM gestcons.perimetre_parcellaire_manuel
 WHERE NOT ST_IsValid(geometrie);

\echo '--- rattachements'
SELECT count(*)                           AS couples,
       count(DISTINCT parcelle_id)        AS parcelles,
       count(DISTINCT insee_com)          AS communes,
       count(*) FILTER (WHERE principale) AS principales,
       round((sum(surface_m2)/10000.0)::numeric,1) AS ha_total
FROM gestcons.parcelles_communes;

\echo '--- une et une seule commune principale par parcelle (doit être 0)'
SELECT count(*) AS anomalies FROM (
  SELECT parcelle_id FROM gestcons.parcelles_communes
   GROUP BY parcelle_id HAVING count(*) FILTER (WHERE principale) <> 1) t;

\echo '--- la somme des surfaces par commune retombe sur la surface totale (écart en m2)'
SELECT round(abs(
         (SELECT sum(surface_m2) FROM gestcons.parcelles_communes)::numeric
       - (SELECT sum(ST_Area(pm.geometrie)) FROM gestcons.perimetre_parcellaire_manuel pm
           JOIN gestcons.parcelles_base pb ON pb.parcellaire_id = pm.id
            AND pb.type_parcelle_id = 2)::numeric)) AS ecart_m2;

\echo '--- les parcelles à cheval'
SELECT pc.parcelle_id, co.nom,
       round((pc.surface_m2/10000.0)::numeric,1) AS ha,
       pc.principale
FROM gestcons.parcelles_communes pc
JOIN gestcons.communes co ON co.insee_com = pc.insee_com
WHERE pc.parcelle_id IN (SELECT parcelle_id FROM gestcons.parcelles_communes
                          GROUP BY parcelle_id HAVING count(*) > 1)
ORDER BY pc.parcelle_id, pc.surface_m2 DESC;

COMMIT;
