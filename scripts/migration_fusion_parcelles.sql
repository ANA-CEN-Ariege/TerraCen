-- =============================================================================
-- migration_fusion_parcelles.sql
--
-- Fusion de gestcons.parcelles_perimetre dans gestcons.parcelles (scénario B).
-- Voir le plan détaillé : scripts/migration_fusion_parcelles_plan.md
--
-- Résultat :
--   - table physique  gestcons.parcelles_base  (site + périmètre, col. perimetre)
--   - vue de compat   gestcons.parcelles       (WHERE NOT perimetre) -> le code
--     existant, PROD COMPRISE, continue de fonctionner à l'identique
--   - parcelles_perimetre renommée en parcelles_perimetre_old (filet, à dropper
--     après validation post-release)
--
-- EXÉCUTION : rôle capable de modifier les objets d'adminsig (parcelles, vues)
-- ET de claudeg (parcelles_perimetre, fonction tg_audit_log) — donc un
-- SUPERUTILISATEUR, ou adminsig s'il est superuser. Un pré-contrôle en tête de
-- script échoue proprement si les droits manquent. Sinon, aligner d'abord les
-- owners (en tant que claudeg) :
--   ALTER TABLE gestcons.parcelles_perimetre OWNER TO adminsig;
--   ALTER FUNCTION gestcons.tg_audit_log() OWNER TO adminsig;
--
-- Le fichier est du SQL PUR (exécutable dans DBeaver « Exécuter le script »,
-- ou via psql) :
--   psql --set=ON_ERROR_STOP=on -h <hôte> -U adminsig -d anaweb -f migration_fusion_parcelles.sql
--
-- ⚠️ DBeaver : si le script s'arrête en erreur à mi-chemin, la transaction
-- reste ouverte (état « aborted ») -> exécuter ROLLBACK; manuellement avant
-- de relancer. La transaction garantit dans tous les cas que rien n'est
-- appliqué partiellement.
--
-- ⚠️ DRY-RUN PAR DÉFAUT : le script se termine par ROLLBACK.
--    Pour la vraie passe : remplacer le ROLLBACK final par COMMIT.
--    (Tout le DDL PostgreSQL est transactionnel : le dry-run joue TOUT le
--    script à blanc, y compris les vérifications, puis annule.)
--
-- ⚠️ Le script (dry-run compris) prend un verrou ACCESS EXCLUSIVE sur
--    parcelles : à lancer en fenêtre calme. lock_timeout = 10 s : si une
--    session bloque, le script échoue proprement au lieu de geler la prod.
-- =============================================================================

BEGIN;

SET LOCAL lock_timeout = '10s';
-- Force pg_get_viewdef à qualifier tous les objets (schema.objet) dans les
-- définitions capturées -> recréation fiable quel que soit le search_path.
SET LOCAL search_path = pg_catalog;

-- =============================================================================
-- 0. CONTRÔLES PRÉALABLES + RELEVÉS DE RÉFÉRENCE
-- =============================================================================

-- Pré-contrôle des DROITS : le script modifie des objets d'adminsig (parcelles,
-- vues) ET de claudeg (parcelles_perimetre, tg_audit_log). Échec immédiat et
-- explicite si le rôle courant ne peut pas tout faire.
DO $own$
DECLARE
  obj record;
BEGIN
  IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
    RETURN;  -- superuser : tous droits
  END IF;
  FOR obj IN
    SELECT c.oid::regclass::text AS nom, r.rolname AS owner
    FROM pg_class c
    JOIN pg_roles r ON r.oid = c.relowner
    WHERE c.oid IN ('gestcons.parcelles'::regclass, 'gestcons.parcelles_perimetre'::regclass)
      AND NOT pg_has_role(current_user, c.relowner, 'USAGE')
  LOOP
    RAISE EXCEPTION 'DROITS INSUFFISANTS : % appartient à % — exécuter en superuser ou aligner l''owner d''abord (voir en-tête du script)', obj.nom, obj.owner;
  END LOOP;
  IF NOT pg_has_role(current_user,
                     (SELECT proowner FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname = 'gestcons' AND p.proname = 'tg_audit_log'), 'USAGE') THEN
    RAISE EXCEPTION 'DROITS INSUFFISANTS : la fonction gestcons.tg_audit_log() appartient à claudeg — exécuter en superuser ou aligner l''owner d''abord';
  END IF;
END
$own$;

DO $chk$
DECLARE
  n int;
BEGIN
  -- Une parcelle ne doit pas être à la fois parcelle du site ET au périmètre
  -- du même site (les garde-fous UI l'empêchent, on vérifie).
  SELECT count(*) INTO n
  FROM gestcons.parcelles_perimetre pp
  JOIN gestcons.parcelles p
    ON  p.parcellaire_id  = pp.parcellaire_id
    AND p.type_parcelle_id = pp.type_parcelle_id
    AND p.site_id          = pp.site_id;
  IF n > 0 THEN
    RAISE EXCEPTION 'ABANDON : % parcelle(s) présentes à la fois dans parcelles et parcelles_perimetre pour le même site', n;
  END IF;

  -- Toutes les lignes du périmètre doivent avoir leur parcelle cadastrale
  -- (nécessaire pour récupérer la contenance dcntpa).
  SELECT count(*) INTO n
  FROM gestcons.parcelles_perimetre pp
  LEFT JOIN gestcons.dico_cadastre c ON c.id = pp.parcellaire_id
  WHERE c.id IS NULL;
  IF n > 0 THEN
    RAISE EXCEPTION 'ABANDON : % ligne(s) de parcelles_perimetre sans correspondance dans dico_cadastre', n;
  END IF;
END
$chk$;

-- Comptes de référence (comparés en fin de script : tout écart => exception
-- => rollback automatique via ON_ERROR_STOP).
CREATE TEMP TABLE _ref ON COMMIT DROP AS
SELECT
  (SELECT count(*) FROM gestcons.parcelles)                            AS n_parcelles,
  (SELECT count(*) FROM gestcons.parcelles_perimetre)                  AS n_perimetre,
  (SELECT count(*) FROM gestcons.v_fcen_parcelle_cen_04)               AS n_fcen_parcelle,
  (SELECT count(*) FROM gestcons.v_fcen_site_cen_04)                   AS n_fcen_site,
  (SELECT count(*) FROM gestcons.sites_gestion_terracen_actifs)        AS n_sg_actifs,
  (SELECT count(*) FROM gestcons.sites_gestion_terracen_prefiguration) AS n_sg_pref;

-- Capture des définitions des 5 vues dépendantes AVANT le rename : le texte
-- déparsé référence encore « gestcons.parcelles » ; rejoué APRÈS la création
-- de la vue de compatibilité, il se rebranche dessus (donc reste filtré).
CREATE TEMP TABLE _defs ON COMMIT DROP AS
SELECT c.relname, pg_get_viewdef(c.oid, true) AS def
FROM pg_class c
JOIN pg_namespace s ON s.oid = c.relnamespace
WHERE s.nspname = 'gestcons'
  AND c.relname IN ('sites_gestion_terracen_actifs',
                    'sites_gestion_terracen_prefiguration',
                    'vm_parcelles_protection',
                    'v_fcen_parcelle_cen_04',
                    'v_fcen_site_cen_04');

DO $chk2$
DECLARE n int;
BEGIN
  SELECT count(*) INTO n FROM _defs;
  IF n <> 5 THEN
    RAISE EXCEPTION 'ABANDON : % définition(s) de vue capturée(s), 5 attendues', n;
  END IF;
END
$chk2$;

-- Index de la matview (recréés après son DROP/CREATE).
CREATE TEMP TABLE _idx ON COMMIT DROP AS
SELECT indexdef FROM pg_indexes
WHERE schemaname = 'gestcons' AND tablename = 'vm_parcelles_protection';

-- =============================================================================
-- 1. NOUVELLES COLONNES  (défaut constant -> instantané, pas de réécriture)
-- =============================================================================

ALTER TABLE gestcons.parcelles
  ADD COLUMN perimetre boolean NOT NULL DEFAULT false,
  ADD COLUMN remarque  text;

-- =============================================================================
-- 2. UNICITÉ : contrainte globale -> deux index uniques partiels
--    (sémantiques actuelles conservées À L'IDENTIQUE pour chaque population)
-- =============================================================================

ALTER TABLE gestcons.parcelles DROP CONSTRAINT parcelles_cadastre_id_key;

-- Parcelles de site : une parcelle cadastrale n'appartient qu'à UN site
-- (= l'ancienne contrainte UNIQUE(parcellaire_id) de parcelles).
CREATE UNIQUE INDEX parcelles_base_site_parcellaire_uniq
  ON gestcons.parcelles (parcellaire_id) WHERE NOT perimetre;

-- Périmètre : une parcelle peut être au périmètre de PLUSIEURS sites, une
-- seule fois par site (= l'ancienne UNIQUE(site_id, parcellaire_id) de
-- parcelles_perimetre).
CREATE UNIQUE INDEX parcelles_base_perimetre_site_parcellaire_uniq
  ON gestcons.parcelles (site_id, parcellaire_id) WHERE perimetre;

-- =============================================================================
-- 3. RENAME  (PK, FKs entrantes, index, triggers, séquence, grants : suivent)
-- =============================================================================

ALTER TABLE gestcons.parcelles RENAME TO parcelles_base;

-- =============================================================================
-- 4. VUE DE COMPATIBILITÉ + GRANTS  (⚠️ grants DANS la même transaction,
--    sinon la prod perd l'accès à « parcelles » au COMMIT)
-- =============================================================================

CREATE VIEW gestcons.parcelles AS
  SELECT * FROM gestcons.parcelles_base WHERE NOT perimetre;

ALTER VIEW gestcons.parcelles OWNER TO adminsig;
GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.parcelles TO claudeg;
GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.parcelles TO shiny;
GRANT SELECT ON gestcons.parcelles TO shiny_lecteur;

-- =============================================================================
-- 5. MIGRATION DES DONNÉES DU PÉRIMÈTRE
--    Mêmes défauts de maîtrise que la bascule / l'association de parcelles :
--    surf = contenance cadastrale, source 1, échelle 1, propriétaire (CEN) 4,
--    chasse 1, le reste 0, actif true. Traçabilité et remarque conservées.
--    Trigger d'audit suspendu : la migration ne doit pas générer des dizaines
--    de fausses « modifications » dans l'onglet Activité.
-- =============================================================================

ALTER TABLE gestcons.parcelles_base DISABLE TRIGGER trg_audit;

INSERT INTO gestcons.parcelles_base (
  site_id, parcellaire_id, type_parcelle_id, perimetre, remarque,
  mesure_compens_id, echelle_numerisation_id, source_surf_parc_id,
  bnd_id, pour_part_id, surf_parc_maitrise_m2, domaine_public_id,
  proprietaire_id, zpf_id, chasse_id, actif,
  cree_par, date_creation, modifie_par, date_modification
)
SELECT
  pp.site_id, pp.parcellaire_id, pp.type_parcelle_id, true, pp.remarque,
  0, 1, 1,
  0, 0, c.dcntpa, 0,
  '4', 0, 1, true,
  pp.cree_par, pp.date_creation, pp.modifie_par, pp.date_modification
FROM gestcons.parcelles_perimetre pp
JOIN gestcons.dico_cadastre c ON c.id = pp.parcellaire_id;

ALTER TABLE gestcons.parcelles_base ENABLE TRIGGER trg_audit;

-- =============================================================================
-- 6. RECRÉATION DES 5 VUES  (après le RENAME elles suivent la table physique
--    — OID — et verraient les lignes périmètre ; on les rebranche sur la vue
--    filtrée en rejouant leur définition capturée à l'étape 0)
--
--    Dépendances : v_fcen_parcelle_cen_04 ET v_fcen_site_cen_04 dépendent de
--    vm_parcelles_protection -> DROP des 2 vues, DROP/CREATE de la matview,
--    recréation des 2 vues. Les sites_gestion_* sont indépendantes -> simple
--    CREATE OR REPLACE (conserve leurs grants : claudeg, ana_gis, fdw_user,
--    shiny_lecteur).
-- =============================================================================

DO $views$
DECLARE
  d text;
  i record;
BEGIN
  -- 6a. Vues indépendantes : CREATE OR REPLACE (grants conservés)
  SELECT def INTO STRICT d FROM _defs WHERE relname = 'sites_gestion_terracen_actifs';
  EXECUTE 'CREATE OR REPLACE VIEW gestcons.sites_gestion_terracen_actifs AS ' || d;

  SELECT def INTO STRICT d FROM _defs WHERE relname = 'sites_gestion_terracen_prefiguration';
  EXECUTE 'CREATE OR REPLACE VIEW gestcons.sites_gestion_terracen_prefiguration AS ' || d;

  -- 6b. Vues dépendantes de la matview : DROP (ordre imposé)
  EXECUTE 'DROP VIEW gestcons.v_fcen_parcelle_cen_04';
  EXECUTE 'DROP VIEW gestcons.v_fcen_site_cen_04';
  EXECUTE 'DROP MATERIALIZED VIEW gestcons.vm_parcelles_protection';

  -- 6c. Matview : recréation (peuplée), index, owner, grants
  SELECT def INTO STRICT d FROM _defs WHERE relname = 'vm_parcelles_protection';
  EXECUTE 'CREATE MATERIALIZED VIEW gestcons.vm_parcelles_protection AS ' || d;
  FOR i IN SELECT indexdef FROM _idx LOOP
    EXECUTE i.indexdef;
  END LOOP;
  EXECUTE 'ALTER MATERIALIZED VIEW gestcons.vm_parcelles_protection OWNER TO adminsig';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.vm_parcelles_protection TO claudeg';
  EXECUTE 'GRANT SELECT ON gestcons.vm_parcelles_protection TO shiny_lecteur';

  -- 6d. Vues FCEN : recréation, owner, grants (claudeg seul, comme avant)
  SELECT def INTO STRICT d FROM _defs WHERE relname = 'v_fcen_parcelle_cen_04';
  EXECUTE 'CREATE VIEW gestcons.v_fcen_parcelle_cen_04 AS ' || d;
  EXECUTE 'ALTER VIEW gestcons.v_fcen_parcelle_cen_04 OWNER TO adminsig';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.v_fcen_parcelle_cen_04 TO claudeg';

  SELECT def INTO STRICT d FROM _defs WHERE relname = 'v_fcen_site_cen_04';
  EXECUTE 'CREATE VIEW gestcons.v_fcen_site_cen_04 AS ' || d;
  EXECUTE 'ALTER VIEW gestcons.v_fcen_site_cen_04 OWNER TO adminsig';
  EXECUTE 'GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.v_fcen_site_cen_04 TO claudeg';
END
$views$;

-- =============================================================================
-- 6bis. TRIGGER D'AUDIT : les branches ANIMATIONS résolvent le site via
--    parcelles_base (les actions peuvent désormais être liées à des parcelles
--    du périmètre élargi ; via la vue filtrée, ces liens seraient invisibles).
--    Les autres branches restent sur « gestcons.parcelles » (résolue en la vue
--    à l'exécution) : manuels et contrats ne concernent que les parcelles de
--    site — sémantique inchangée. NB : CREATE OR REPLACE conserve l'owner.
-- =============================================================================

CREATE OR REPLACE FUNCTION gestcons.tg_audit_log() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'gestcons', 'pg_temp'
    AS $fn$
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
    -- parcelles_base : couvre les liens vers les parcelles du site ET du
    -- périmètre élargi (fusion 2026-08).
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.animation_fonciere_parcelles afp
    JOIN gestcons.parcelles_base p ON p.id = afp.parcelle_id
    WHERE afp.animation_id = v_id AND p.site_id IS NOT NULL;

  ELSIF TG_TABLE_NAME = 'animation_contrat_agricole' THEN
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    SELECT DISTINCT TG_TABLE_NAME, TG_OP, v_id, p.site_id
    FROM gestcons.animation_contrat_agricole_parcelles acap
    JOIN gestcons.parcelles_base p ON p.id = acap.parcelle_id
    WHERE acap.animation_id = v_id AND p.site_id IS NOT NULL;

  ELSE
    -- Table auditée sans rattachement résolu : journalisée quand même (site NULL).
    INSERT INTO gestcons.audit_log (table_name, action, row_id, site_id)
    VALUES (TG_TABLE_NAME, TG_OP, v_id, NULL);
  END IF;

  RETURN NULL;  -- AFTER trigger : valeur de retour ignorée
END;
$fn$;

-- =============================================================================
-- 7. ANCIENNE TABLE : renommée, PAS supprimée (filet de sécurité).
--    DROP à faire plus tard, après validation complète post-release.
-- =============================================================================

ALTER TABLE gestcons.parcelles_perimetre RENAME TO parcelles_perimetre_old;

-- =============================================================================
-- 8. VÉRIFICATIONS  (tout écart => EXCEPTION => rien n'est appliqué)
-- =============================================================================

DO $verif$
DECLARE
  r record;
  n bigint;
BEGIN
  SELECT * INTO r FROM _ref;

  SELECT count(*) INTO n FROM gestcons.parcelles;
  IF n <> r.n_parcelles THEN
    RAISE EXCEPTION 'ÉCART vue parcelles : % ligne(s), attendu %', n, r.n_parcelles;
  END IF;

  SELECT count(*) INTO n FROM gestcons.parcelles_base WHERE perimetre;
  IF n <> r.n_perimetre THEN
    RAISE EXCEPTION 'ÉCART lignes périmètre migrées : %, attendu %', n, r.n_perimetre;
  END IF;

  SELECT count(*) INTO n FROM gestcons.v_fcen_parcelle_cen_04;
  IF n <> r.n_fcen_parcelle THEN
    RAISE EXCEPTION 'ÉCART v_fcen_parcelle_cen_04 : % ligne(s), attendu %', n, r.n_fcen_parcelle;
  END IF;

  SELECT count(*) INTO n FROM gestcons.v_fcen_site_cen_04;
  IF n <> r.n_fcen_site THEN
    RAISE EXCEPTION 'ÉCART v_fcen_site_cen_04 : % ligne(s), attendu %', n, r.n_fcen_site;
  END IF;

  SELECT count(*) INTO n FROM gestcons.sites_gestion_terracen_actifs;
  IF n <> r.n_sg_actifs THEN
    RAISE EXCEPTION 'ÉCART sites_gestion_terracen_actifs : % ligne(s), attendu %', n, r.n_sg_actifs;
  END IF;

  SELECT count(*) INTO n FROM gestcons.sites_gestion_terracen_prefiguration;
  IF n <> r.n_sg_pref THEN
    RAISE EXCEPTION 'ÉCART sites_gestion_terracen_prefiguration : % ligne(s), attendu %', n, r.n_sg_pref;
  END IF;

  RAISE NOTICE '==========================================================';
  RAISE NOTICE 'VÉRIFICATIONS OK';
  RAISE NOTICE '  parcelles (vue, = sites)  : % ligne(s)', r.n_parcelles;
  RAISE NOTICE '  périmètre migré           : % ligne(s)', r.n_perimetre;
  RAISE NOTICE '  v_fcen_parcelle_cen_04    : % ligne(s) (inchangé)', r.n_fcen_parcelle;
  RAISE NOTICE '  v_fcen_site_cen_04        : % ligne(s) (inchangé)', r.n_fcen_site;
  RAISE NOTICE '  sites_gestion actifs/préf : % / % (inchangé)', r.n_sg_actifs, r.n_sg_pref;
  RAISE NOTICE '==========================================================';
END
$verif$;

-- =============================================================================
-- 9. DRY-RUN par défaut.
--    Pour appliquer réellement : remplacer la ligne ROLLBACK par COMMIT.
-- =============================================================================

ROLLBACK;   -- <<< DRY-RUN. Remplacer par : COMMIT;

-- =============================================================================
-- APRÈS LE COMMIT (vraie passe uniquement) :
--   ANALYZE gestcons.parcelles_base;
--   -- vérif rapide prod (Sites, Parcelles, Contrats) : rien ne doit changer ;
--   -- l'onglet Stratégie prod est HS jusqu'à la release (attendu) ;
--   -- release le même jour ;
--   -- après validation complète : DROP TABLE gestcons.parcelles_perimetre_old;
-- =============================================================================
