-- ============================================================
-- Une seule source géométrique par parcelle
-- ============================================================
-- gestcons.parcelles_sources_geom a été modélisée comme une liaison N-N :
-- sa clé primaire (parcelle_id, source_geom_id) autorise plusieurs sources
-- pour une même parcelle. Ce n'est pas le besoin — une parcelle a UNE source
-- géométrique, et l'export FCEN n'en retient d'ailleurs qu'une
-- (ORDER BY fcen_code LIMIT 1 dans v_fcen_parcelle_cen_04).
--
-- La clé primaire devient donc (parcelle_id) seul : la règle est portée par
-- le schéma, et non plus par la discipline des chemins d'écriture.
--
-- ⚠️ La table appartient à adminsig : exécuter avec un rôle qui en a la
--    propriété (ou superuser), sinon le ALTER échoue.
-- ⚠️ test et prod partagent cette base : l'écriture vaut pour la production.
--
-- DRY-RUN : se termine par ROLLBACK. Remplacer par COMMIT après lecture.
-- ============================================================

BEGIN;

SET lock_timeout = '10s';

-- ---------- 1. État avant ----------
SELECT 'lignes'  AS objet, count(*)::text AS valeur FROM gestcons.parcelles_sources_geom
UNION ALL
SELECT 'parcelles concernées', count(DISTINCT parcelle_id)::text FROM gestcons.parcelles_sources_geom
UNION ALL
SELECT 'parcelles à plusieurs sources', count(*)::text FROM (
  SELECT parcelle_id FROM gestcons.parcelles_sources_geom
   GROUP BY 1 HAVING count(*) > 1) t
UNION ALL
SELECT 'clé primaire actuelle', pg_get_constraintdef(oid)
  FROM pg_constraint WHERE conname = 'parcelles_sources_geom_pkey';

-- ---------- 2. Dédoublonnage ----------
-- Aucune ligne à ce jour, mais le script doit rester exécutable plus tard.
-- Critère déterministe : on garde le plus petit source_geom_id.
DELETE FROM gestcons.parcelles_sources_geom g
 WHERE g.source_geom_id <> (
         SELECT min(g2.source_geom_id)
           FROM gestcons.parcelles_sources_geom g2
          WHERE g2.parcelle_id = g.parcelle_id);

-- ---------- 3. Nouvelle clé primaire ----------
ALTER TABLE gestcons.parcelles_sources_geom
  DROP CONSTRAINT parcelles_sources_geom_pkey;
ALTER TABLE gestcons.parcelles_sources_geom
  ADD CONSTRAINT parcelles_sources_geom_pkey PRIMARY KEY (parcelle_id);

-- ---------- 4. Contrôles ----------
SELECT 'clé primaire après' AS controle, pg_get_constraintdef(oid) AS valeur
  FROM pg_constraint WHERE conname = 'parcelles_sources_geom_pkey'
UNION ALL
SELECT 'parcelles à plusieurs sources (doit être 0)', count(*)::text FROM (
  SELECT parcelle_id FROM gestcons.parcelles_sources_geom
   GROUP BY 1 HAVING count(*) > 1) t;

-- ---------- 5. La règle tient-elle ? ----------
-- Une seconde source sur une même parcelle doit désormais être refusée.
DO $$
DECLARE pid int;
BEGIN
  SELECT id INTO pid FROM gestcons.parcelles_base LIMIT 1;
  INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
       VALUES (pid, 4) ON CONFLICT DO NOTHING;
  BEGIN
    INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
         VALUES (pid, 5);
    RAISE EXCEPTION 'ÉCHEC : une deuxième source a été acceptée';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'OK : la deuxième source est refusée (unique_violation)';
  END;
END $$;

-- Remplacer par COMMIT une fois les contrôles lus.
ROLLBACK;
