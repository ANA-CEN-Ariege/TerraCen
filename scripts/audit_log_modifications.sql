-- ============================================================================
-- audit_log_modifications.sql
-- Journal d'audit des modifications (scénario B) — comptage PAR SITE
-- ----------------------------------------------------------------------------
-- But : enregistrer chaque INSERT/UPDATE/DELETE sur les tables liées à un site,
-- pour comptabiliser les modifications par site (sans attribution d'utilisateur).
--
-- Mécanique :
--   - table gestcons.audit_log (table, action, id de ligne, site_id, date)
--   - fonction trigger GÉNÉRIQUE gestcons.tg_audit_log()
--       * résout site_id automatiquement : colonne 'site_id' si présente,
--         sinon l'id de la ligne pour la table 'sites'
--       * SECURITY DEFINER : l'INSERT dans audit_log se fait au nom du
--         propriétaire (adminsig) -> l'utilisateur applicatif n'a PAS besoin de
--         droit d'écriture sur audit_log (juste SELECT pour l'afficher).
--   - un trigger par table auditée.
--
-- ⚠️ Base : anaweb (schéma gestcons). À exécuter en tant qu'adminsig.
-- ⚠️ NON rétroactif : ne capture que les modifications À PARTIR de son
--    installation (le passé n'est pas reconstituable ici — date_modification ne
--    garde que la dernière modif).
-- Rattachement INDIRECT (via parcelles) également géré pour contrats_fonciers,
-- contrats_agricoles, perimetre_parcellaire_manuel, animation_fonciere et
-- animation_contrat_agricole : une ligne d'audit par site concerné (en pratique
-- un seul, une parcelle n'appartenant qu'à un site).
-- ============================================================================


-- == 1. Table du journal =====================================================
CREATE TABLE IF NOT EXISTS gestcons.audit_log (
  id          bigserial PRIMARY KEY,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  table_name  text        NOT NULL,
  action      text        NOT NULL,      -- 'INSERT' | 'UPDATE' | 'DELETE'
  row_id      integer,                   -- id de la ligne touchée (NULL si pas d'id simple)
  site_id     integer                    -- site rattaché (NULL si non résoluble)
);
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at ON gestcons.audit_log (changed_at);
CREATE INDEX IF NOT EXISTS idx_audit_log_site_id    ON gestcons.audit_log (site_id);


-- == 2. Fonction trigger générique ===========================================
CREATE OR REPLACE FUNCTION gestcons.tg_audit_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = gestcons, pg_temp
AS $$
DECLARE
  v_row  jsonb;
  v_id   integer;
  v_site integer;
BEGIN
  IF (TG_OP = 'DELETE') THEN
    v_row := to_jsonb(OLD);
  ELSE
    v_row := to_jsonb(NEW);
  END IF;
  v_id := NULLIF(v_row ->> 'id', '')::int;

  -- 1) Rattachement DIRECT : colonne 'site_id' si présente ; sinon l'id lui-même
  -- pour la table 'sites'. to_jsonb(...)->>'clé' vaut NULL si la colonne n'existe
  -- pas (pas d'erreur) -> la même fonction marche pour toutes les tables.
  v_site := COALESCE(
    NULLIF(v_row ->> 'site_id', '')::int,
    CASE WHEN TG_TABLE_NAME = 'sites' THEN v_id END
  );
  IF v_site IS NOT NULL THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    VALUES (TG_TABLE_NAME, TG_OP, v_id, v_site);
    RETURN NULL;
  END IF;

  -- 2) Rattachement INDIRECT (via parcelles) : contrats et périmètres manuels.
  -- Une ligne d'audit PAR site concerné ; en pratique un seul (une parcelle
  -- n'appartient qu'à un site), le DISTINCT couvre le cas multi-sites théorique.
  -- Si rien n'est résolu (contrat sans parcelle, ou liens déjà supprimés en
  -- cascade lors d'un DELETE), aucune ligne n'est insérée.
  IF TG_TABLE_NAME = 'perimetre_parcellaire_manuel' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.parcelles p
    WHERE p.type_parcelle_id = 2 AND p.parcellaire_id = v_id AND p.site_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'contrats_fonciers' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.contrats_foncier_parcelles cfp
    JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id
    WHERE cfp.contrat_id = v_id AND p.site_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'contrats_agricoles' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.contrats_agricoles_parcelles cap
    JOIN gestcons.parcelles p ON p.id = cap.parcelle_id
    WHERE cap.contrat_agri_id = v_id AND p.site_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'animation_fonciere' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.animation_fonciere_parcelles afp
    JOIN gestcons.parcelles p ON p.id = afp.parcelle_id
    WHERE afp.animation_id = v_id AND p.site_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'animation_contrat_agricole' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.animation_contrat_agricole_parcelles acap
    JOIN gestcons.parcelles p ON p.id = acap.parcelle_id
    WHERE acap.animation_id = v_id AND p.site_id IS NOT NULL;

  ELSE
    -- Table auditée sans rattachement résolu : journalisée quand même (site NULL).
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    VALUES (TG_TABLE_NAME, TG_OP, v_id, NULL);
  END IF;

  RETURN NULL;  -- AFTER trigger : valeur de retour ignorée
END;
$$;


-- == 3. Attacher le trigger aux tables liées à un site =======================
-- Tables avec site_id direct (ou 'sites' elle-même). Idempotent : on retire un
-- éventuel trigger existant avant de le (re)créer.
DO $$
DECLARE
  t text;
  cibles text[] := ARRAY[
    'sites',                        -- l'id = le site
    'parcelles',                    -- site_id
    'parcelles_perimetre',          -- site_id (périmètre élargi, onglet Stratégie)
    'docs_gestion_sites',           -- site_id
    'responsable_sites',            -- site_id
    'animateur_sites',              -- site_id
    'sites_statuts',                -- site_id
    'perimetre_parcellaire_manuel', -- site via parcelles (type_parcelle_id = 2)
    'contrats_fonciers',            -- site via contrats_foncier_parcelles -> parcelles
    'contrats_agricoles',           -- site via contrats_agricoles_parcelles -> parcelles
    'animation_fonciere',           -- site via animation_fonciere_parcelles -> parcelles
    'animation_contrat_agricole'    -- site via animation_contrat_agricole_parcelles -> parcelles
  ];
BEGIN
  FOREACH t IN ARRAY cibles LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON gestcons.%I', t);
    EXECUTE format(
      'CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON gestcons.%I
         FOR EACH ROW EXECUTE FUNCTION gestcons.tg_audit_log()', t);
  END LOOP;
END $$;


-- == 4. Droit de lecture pour l'appli ========================================
-- L'appli (DB_USER) n'a besoin que de SELECT (l'écriture passe par le trigger
-- SECURITY DEFINER). Remplacer ‹APP_USER› par la valeur de DB_USER.
GRANT SELECT ON gestcons.audit_log TO "shiny";


-- ============================================================================
-- EXEMPLES DE COMPTAGE (par site)
-- ----------------------------------------------------------------------------
-- Modifications par site et par mois (toutes actions confondues) :
--   SELECT date_trunc('month', a.changed_at)::date AS mois, s.libelle,
--          count(*) AS nb
--   FROM gestcons.audit_log a
--   JOIN gestcons.sites s ON s.id = a.site_id
--   GROUP BY 1, 2 ORDER BY 1, 2;
--
-- Uniquement les vraies modifications (UPDATE) d'un site donné :
--   SELECT count(*) FROM gestcons.audit_log
--   WHERE site_id = <sid> AND action = 'UPDATE';
--
-- Répartition par table pour un site :
--   SELECT table_name, action, count(*)
--   FROM gestcons.audit_log WHERE site_id = <sid>
--   GROUP BY 1, 2 ORDER BY 1, 2;
--
-- Contrôle rapide après quelques modifs dans l'appli :
--   SELECT * FROM gestcons.audit_log ORDER BY changed_at DESC LIMIT 20;
-- ============================================================================


-- ============================================================================
-- DÉSINSTALLATION (si besoin de tout retirer)
-- ----------------------------------------------------------------------------
-- DO $$ DECLARE t text; cibles text[] := ARRAY['sites','parcelles',
--   'docs_gestion_sites','responsable_sites','animateur_sites','sites_statuts',
--   'perimetre_parcellaire_manuel','contrats_fonciers','contrats_agricoles',
--   'animation_fonciere','animation_contrat_agricole'];
-- BEGIN FOREACH t IN ARRAY cibles LOOP
--   EXECUTE format('DROP TRIGGER IF EXISTS trg_audit ON gestcons.%I', t);
-- END LOOP; END $$;
-- DROP FUNCTION IF EXISTS gestcons.tg_audit_log();
-- DROP TABLE IF EXISTS gestcons.audit_log;
-- ============================================================================
