-- ============================================================
-- Secteurs d'intervention prioritaire — structure
-- ============================================================
-- Un « secteur d'intervention prioritaire » est une zone de prospection :
-- des parcelles sans contrat, repérées comme pouvant devenir un futur site
-- conservatoire. Il est modélisé comme un SITE d'un type différent, et ses
-- parcelles comme des lignes ordinaires de parcelles_base portant
-- perimetre = true — le drapeau qui les dispense de la contrainte d'unicité
-- globale et de la règle « une parcelle de site a toujours un contrat ».
--
-- Deux ajouts seulement : un axe de typage sur les sites, une priorité sur
-- les parcelles. La remarque existe déjà (parcelles_base.remarque).
--
-- DRY-RUN : se termine par ROLLBACK. Remplacer par COMMIT après lecture.
-- ⚠️ test et prod partagent cette base.
-- ============================================================

BEGIN;

SET lock_timeout = '10s';

-- Photo de l'export FCEN AVANT migration : la structure ne doit rien y changer.
CREATE TEMP TABLE fcen_avant AS SELECT count(*) AS n FROM gestcons.v_fcen_parcelle_cen_04;

-- ---------- 1. Typage des sites ----------
CREATE TABLE IF NOT EXISTS gestcons.dico_type_site (
  id      smallint PRIMARY KEY,
  libelle varchar(100) NOT NULL
);
INSERT INTO gestcons.dico_type_site (id, libelle) VALUES
  (1, 'Site conservatoire'),
  (2, 'Secteur d''intervention prioritaire')
ON CONFLICT (id) DO NOTHING;

ALTER TABLE gestcons.sites ADD COLUMN IF NOT EXISTS type_site_id smallint;
-- Les sites existants sont tous des sites conservatoires.
UPDATE gestcons.sites SET type_site_id = 1 WHERE type_site_id IS NULL;
-- Le DEFAUT protège tout code qui insère un site sans connaître la colonne.
ALTER TABLE gestcons.sites
  ALTER COLUMN type_site_id SET DEFAULT 1,
  ALTER COLUMN type_site_id SET NOT NULL;

DO $$ BEGIN
  ALTER TABLE gestcons.sites
    ADD CONSTRAINT sites_type_site_fk
      FOREIGN KEY (type_site_id) REFERENCES gestcons.dico_type_site(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Les listes de sites filtrent par type : un index partiel suffit, la table
-- est minuscule mais le filtre sera systématique.
CREATE INDEX IF NOT EXISTS idx_sites_type_site ON gestcons.sites (type_site_id);

-- ---------- 2. Priorité des parcelles ----------
CREATE TABLE IF NOT EXISTS gestcons.dico_priorite (
  id      smallint PRIMARY KEY,
  libelle varchar(100) NOT NULL
);
INSERT INTO gestcons.dico_priorite (id, libelle) VALUES
  (1, 'Priorité 1'),
  (2, 'Priorité 2')
ON CONFLICT (id) DO NOTHING;

-- Nullable : les parcelles des sites conservatoires n'en portent pas.
ALTER TABLE gestcons.parcelles_base ADD COLUMN IF NOT EXISTS priorite_id smallint;

DO $$ BEGIN
  ALTER TABLE gestcons.parcelles_base
    ADD CONSTRAINT parcelles_priorite_fk
      FOREIGN KEY (priorite_id) REFERENCES gestcons.dico_priorite(id);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------- 3. Contrôles ----------
SELECT 'sites par type' AS controle,
       string_agg(d.libelle || ' : ' || t.n, ' | ' ORDER BY d.id) AS valeur
  FROM (SELECT type_site_id, count(*) AS n FROM gestcons.sites GROUP BY 1) t
  JOIN gestcons.dico_type_site d ON d.id = t.type_site_id
UNION ALL
SELECT 'sites sans type (doit être 0)', count(*)::text
  FROM gestcons.sites WHERE type_site_id IS NULL
UNION ALL
SELECT 'parcelles avec priorité (doit être 0 à ce stade)', count(*)::text
  FROM gestcons.parcelles_base WHERE priorite_id IS NOT NULL;

-- ---------- 4. L'export FCEN est-il intact ? ----------
SELECT 'export FCEN avant -> après' AS controle,
       a.n || ' -> ' || count(*) ||
       CASE WHEN a.n = count(*) THEN '  (inchangé)' ELSE '  ⚠️ ÉCART' END AS valeur
  FROM gestcons.v_fcen_parcelle_cen_04, fcen_avant a
 GROUP BY a.n;

-- Remplacer par COMMIT une fois les contrôles lus.
ROLLBACK;
