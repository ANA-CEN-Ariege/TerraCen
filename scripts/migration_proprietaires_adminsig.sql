-- =============================================================================
-- Tous les objets de gestcons à adminsig, et la fin de parcelles_perimetre_old
-- =============================================================================
-- Modèle de rôles du projet : adminsig possède tables, vues et fonctions ;
-- shiny est l'application ; terracen_analyse lit les vues d'Analyses. Une
-- vue lit avec les droits de SON propriétaire, et seul le propriétaire peut
-- remplacer un objet : un objet resté à claudeg ne se laisse donc pas
-- reprendre par une migration passée sous un autre compte.
--
-- Relevé le 2026-10-28 : 8 relations et 2 fonctions de déclencheur encore à
-- claudeg. Les 4 séquences relevées avec elles ne sont pas citées ici :
-- liées à une colonne, elles changent de propriétaire avec leur table, et
-- PostgreSQL refuserait de les changer seules.
--
-- Rien ne change dans le fonctionnement : claudeg et adminsig sont tous deux
-- superutilisateurs, et les droits accordés (shiny, mapcen_ro…) sont
-- conservés par ALTER … OWNER. tg_audit_log est SECURITY DEFINER : elle
-- s'exécutera sous adminsig, aux mêmes droits.
--
-- parcelles_perimetre_old — vestige de la fusion d'août 2026 — n'est
-- supprimée que si plus rien ne la lit. Au 2026-10-28, v_mapcen_parcelles la
-- lit encore. Ses 44 lignes sont une copie périmée : 3 sont dans
-- parcelles_base, et les 41 autres, la continuité de « Cap del Pouech »
-- (site 44), y ont été reprises à la fusion puis retirées depuis
-- l'application le 2026-08-19 (journal d'audit : 51 suppressions ce
-- jour-là). Sauvegarde locale : scripts/sauvegarde_parcelles_perimetre_old_2026-10-28.csv.
--
-- Rejouable : rejouer ce script une fois v_mapcen_parcelles corrigée suffit à
-- supprimer la table.
-- =============================================================================

BEGIN;

-- Ces tables sont écrites en continu (audit_log par déclencheur à chaque
-- écriture, connexion_log à chaque connexion) : ALTER … OWNER attend un verrou
-- exclusif bref. Mieux vaut échouer au bout de 10 s que bloquer l'application.
SET lock_timeout = '10s';

-- 1. Tables
ALTER TABLE gestcons.analyses_notes  OWNER TO adminsig;
ALTER TABLE gestcons.audit_log       OWNER TO adminsig;
ALTER TABLE gestcons.connexion_log   OWNER TO adminsig;
ALTER TABLE gestcons.dico_type_site  OWNER TO adminsig;

-- 2. Vues de MapCen
ALTER VIEW gestcons.v_mapcen_parcelles  OWNER TO adminsig;
ALTER VIEW gestcons.v_mapcen_protection OWNER TO adminsig;
ALTER VIEW gestcons.v_mapcen_sites      OWNER TO adminsig;

-- 3. Fonctions de déclencheur
ALTER FUNCTION gestcons.del_perimetre_manuel() OWNER TO adminsig;
ALTER FUNCTION gestcons.tg_audit_log()         OWNER TO adminsig;

-- 4. parcelles_perimetre_old : supprimée si plus rien ne la lit, sinon
--    conservée — et alignée sur adminsig, comme le reste.
DO $$
DECLARE
  dependants text;
BEGIN
  IF to_regclass('gestcons.parcelles_perimetre_old') IS NULL THEN
    RAISE NOTICE 'parcelles_perimetre_old : déjà supprimée.';
    RETURN;
  END IF;
  SELECT string_agg(DISTINCT v.oid::regclass::text, ', ')
    INTO dependants
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    JOIN pg_class v ON v.oid = r.ev_class
   WHERE d.refobjid = 'gestcons.parcelles_perimetre_old'::regclass
     AND v.oid <> 'gestcons.parcelles_perimetre_old'::regclass;
  IF dependants IS NOT NULL THEN
    EXECUTE 'ALTER TABLE gestcons.parcelles_perimetre_old OWNER TO adminsig';
    RAISE NOTICE 'parcelles_perimetre_old CONSERVÉE : % la lit encore. Rejouer ce script une fois la vue corrigée.', dependants;
  ELSE
    EXECUTE 'DROP TABLE gestcons.parcelles_perimetre_old';
    RAISE NOTICE 'parcelles_perimetre_old SUPPRIMÉE.';
  END IF;
END $$;

-- -----------------------------------------------------------------------------
-- Contrôle — doit rendre « 0 objet hors adminsig »
-- -----------------------------------------------------------------------------
\echo ''
SELECT count(*) || ' objet(s) hors adminsig' ||
       COALESCE(' : ' || string_agg(nom, ', ' ORDER BY nom), '') AS controle
  FROM (
    SELECT c.relname AS nom
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'gestcons' AND c.relkind IN ('r','v','m','S','f','p')
       AND pg_get_userbyid(c.relowner) <> 'adminsig'
    UNION ALL
    SELECT p.proname || '()'
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'gestcons' AND pg_get_userbyid(p.proowner) <> 'adminsig'
  ) t;

COMMIT;
