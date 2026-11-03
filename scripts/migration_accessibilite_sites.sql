-- =============================================================================
-- Sites : accessibilité au public et aux personnes à mobilité réduite
-- =============================================================================
-- Deux colonnes sur gestcons.sites :
--   - accessibilite_site     : le site est-il accessible au public ? Oui, Non
--                              ou Partielle, valeurs du nouveau dictionnaire
--                              gestcons.dico_accessibilite ;
--   - accessibilite_pmr_site : l'est-il aux personnes à mobilité réduite ?
--                              0 ou 1.
--
-- VALEURS PAR DÉFAUT, choix de l'utilisateur : un site est accessible au
-- public (Oui) et ne l'est pas aux personnes à mobilité réduite (0), tant
-- qu'on n'a pas saisi autre chose. Les deux colonnes sont NOT NULL, et ces
-- défauts s'appliquent aux 176 lignes existantes (63 sites, 113 secteurs)
-- comme à tout site créé par un code qui ne les nomme pas.
--
-- CODES. dico_accessibilite reprend la numérotation de dico_binaire et de
-- dico_ouverture_public : 0 = Non, 1 = Oui, 2 = la nuance, ici Partielle. Un 1
-- dit donc « oui » dans les deux colonnes.
--
-- accessibilite_pmr_site suit les indicateurs 0/1 déjà présents dans la table
-- (terrain_militaire_id, site_marin_id) : entier NOT NULL DEFAULT 0, borné à
-- 0 et 1 par une clé étrangère vers dico_binaire.
--
-- ⚠️ À distinguer de l'« ouverture au public » de l'export FCEN : le
-- dictionnaire dico_ouverture_public (non / oui / oui, selon les périodes) et
-- la liaison ouverture_public_sites, que lit v_fcen_site_cen_04. Cette liaison
-- est VIDE au 2026-10-30, et l'export envoie donc « non » pour ses 46 sites. La
-- migration n'y touche pas, et les nouvelles colonnes n'alimentent pas
-- l'export.
--
-- Sans effet sur le code en service : les deux INSERT de sites (mod_sites.R,
-- mod_strategie.R) nomment leurs colonnes, et les trois SELECT * de la table
-- lisent leurs champs par leur nom. Aucune vue ni contrainte existante n'est
-- modifiée.
--
-- À passer depuis le Mac, dans /Users/claude/Developpements/TerraCen :
--   set -a; eval "$(grep -E '^DB_(HOST|PORT|NAME|USER|PASSWORD)=' ~/.Renviron)"; set +a
--   PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" \
--     -v ON_ERROR_STOP=1 -f scripts/migration_accessibilite_sites.sql
-- Rejouable : la table, ses valeurs et les colonnes ne sont créées que si elles
-- manquent.
-- =============================================================================

BEGIN;

-- Si une session tient la table des sites, échouer vite plutôt que de bloquer
-- l'application derrière soi.
SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Le dictionnaire
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS gestcons.dico_accessibilite (
  id      integer      PRIMARY KEY,
  libelle varchar(255) NOT NULL
);

INSERT INTO gestcons.dico_accessibilite (id, libelle) VALUES
  (0, 'Non'),
  (1, 'Oui'),
  (2, 'Partielle')
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE gestcons.dico_accessibilite IS
  'Dictionnaire de l''accessibilité d''un site au public : Oui, Non ou Partielle';

ALTER TABLE gestcons.dico_accessibilite OWNER TO adminsig;
-- Lu par l'application, et par shiny_lecteur comme les autres dictionnaires
-- de la table des sites.
GRANT SELECT ON gestcons.dico_accessibilite TO shiny, shiny_lecteur;

-- ---------------------------------------------------------------------------
-- Les deux colonnes
-- ---------------------------------------------------------------------------
ALTER TABLE gestcons.sites
  ADD COLUMN IF NOT EXISTS accessibilite_site integer NOT NULL DEFAULT 1
    CONSTRAINT sites_accessibilite_site_fkey
    REFERENCES gestcons.dico_accessibilite (id),
  ADD COLUMN IF NOT EXISTS accessibilite_pmr_site integer NOT NULL DEFAULT 0
    CONSTRAINT sites_accessibilite_pmr_site_fkey
    REFERENCES gestcons.dico_binaire (id);

COMMENT ON COLUMN gestcons.sites.accessibilite_site IS
  'Accessibilité du site au public : Oui, Non ou Partielle (dico_accessibilite) ; Oui par défaut';
COMMENT ON COLUMN gestcons.sites.accessibilite_pmr_site IS
  'Indicateur accessibilité aux personnes à mobilité réduite (0 ou 1)';

-- ---------------------------------------------------------------------------
-- Contrôle : au 2026-10-30, 176 lignes, toutes à Oui et à 0
-- ---------------------------------------------------------------------------
SELECT count(*)                                           AS lignes,
       count(*) FILTER (WHERE accessibilite_site = 1)     AS accessibilite_oui,
       count(*) FILTER (WHERE accessibilite_pmr_site = 0) AS pmr_a_0
  FROM gestcons.sites;

COMMIT;
