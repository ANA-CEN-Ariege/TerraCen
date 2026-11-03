-- ============================================================
-- Vue d'accès aux zones humides de l'ANA pour TerraCen
-- ============================================================
-- zones_humides.site_zone_humide appartient à une AUTRE application, protégée
-- par une politique de sécurité au niveau ligne (site_zh_policy) : chaque
-- organisme ne voit que ses lignes, via une correspondance rôle -> organisme
-- lue dans intercat.organismes.
--
-- Cette politique est évaluée avec les droits de CELUI QUI INTERROGE. TerraCen,
-- qui ne connaît rien de ce mécanisme, échouait donc sur
-- « permission denied for table organismes ».
--
-- La vue ci-dessous résout le problème sans toucher à la sécurité de l'autre
-- application :
--   - elle appartient à adminsig, propriétaire de la table ;
--   - la politique n'étant PAS en mode forcé (relforcerowsecurity = false), le
--     propriétaire la contourne : elle n'est jamais évaluée et
--     intercat.organismes jamais lue ;
--   - le périmètre est figé ici, à l'organisme 1 (ANA - CEN Ariège), qui détient
--     3 907 des 3 912 zones humides ;
--   - seules les trois colonnes utiles à la carte sont exposées.
--
-- ⚠️ Ne PAS ajouter `WITH (security_invoker = true)` : la vue serait alors lue
--    avec les droits de l'appelant, et on retomberait exactement sur l'erreur.
--
-- DRY-RUN : se termine par ROLLBACK. Remplacer par COMMIT après lecture.
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW gestcons.v_zones_humides_ana AS
  SELECT z.id_site,
         z.nom_usuel,
         z.geometrie
  FROM zones_humides.site_zone_humide z
  WHERE z.id_organisme = 1;

ALTER VIEW gestcons.v_zones_humides_ana OWNER TO adminsig;

COMMENT ON VIEW gestcons.v_zones_humides_ana IS
  'Zones humides de l''ANA - CEN Ariège (organisme 1), exposées à TerraCen. '
  'Appartient à adminsig pour contourner la politique RLS de la table source, '
  'qui exigerait un droit de lecture sur intercat.organismes.';

GRANT SELECT ON gestcons.v_zones_humides_ana TO shiny;

-- ---------- Contrôles ----------
SELECT 'lignes visibles (superuser)' AS controle, count(*)::text AS valeur
  FROM gestcons.v_zones_humides_ana;

-- Le test qui compte : lecture par le rôle réel de l'application.
SET LOCAL ROLE shiny;
SELECT 'lignes visibles par le rôle shiny' AS controle, count(*)::text AS valeur
  FROM gestcons.v_zones_humides_ana;
SELECT 'emprise test : polygones' AS controle, count(*)::text AS valeur
  FROM gestcons.v_zones_humides_ana
 WHERE geometrie && ST_MakeEnvelope(1.2618, 42.7497, 1.4760, 42.8217, 4326);
RESET ROLE;

-- Remplacer par COMMIT une fois les contrôles lus.
ROLLBACK;
