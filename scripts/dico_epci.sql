-- Dictionnaire des intercommunalités (EPCI).
--
-- POURQUOI. gestcons.communes porte un `siren_epci` entièrement renseigné —
-- 327 communes d'Ariège sur 327, 8 EPCI distincts — mais aucun nom. On
-- pouvait donc grouper par intercommunalité sans pouvoir la nommer.
--
-- SOURCE. api.gouv.fr (geo.api.gouv.fr), relevé le 2026-10-28 via
-- l'endpoint des communes du département 09, qui rend le couple
-- (code, nom) de l'EPCI de chaque commune. L'endpoint /epci/<siren> ne
-- répond plus (404) : ne pas le réessayer.
--
-- PORTÉE. Les 8 EPCI d'Ariège, et eux seuls : les 102 communes couvertes par
-- les parcelles du CEN sont toutes en 09, vérifié. Un site hors département
-- demanderait d'étendre cette table — d'où la colonne `source`, pour savoir
-- d'où vient chaque ligne quand elles viendront de plusieurs endroits.
--
-- RÉSERVE MESURÉE. L'API rend 325 communes pour le 09 là où la photo IGN de
-- gestcons.communes en porte 327. L'écart tient aux fusions de communes entre
-- les deux millésimes ; il est sans effet ici, chaque commune du CEN portant
-- l'un des 8 SIREN ci-dessous.
--
-- À exécuter sous adminsig :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/dico_epci.sql
-- Rejouable : le INSERT est idempotent, et il RAFRAÎCHIT les noms.

BEGIN;

CREATE TABLE IF NOT EXISTS gestcons.dico_epci (
  siren      VARCHAR(9) PRIMARY KEY,
  nom        VARCHAR NOT NULL,
  source     VARCHAR NOT NULL DEFAULT 'geo.api.gouv.fr',
  date_maj   DATE    NOT NULL DEFAULT CURRENT_DATE
);

COMMENT ON TABLE  gestcons.dico_epci       IS 'Intercommunalités (EPCI) : le libellé qui manque au siren_epci de gestcons.communes.';
COMMENT ON COLUMN gestcons.dico_epci.siren IS 'SIREN de l''EPCI — se raccorde à gestcons.communes.siren_epci';

INSERT INTO gestcons.dico_epci (siren, nom) VALUES
  ('200044469', 'CC du Pays de Mirepoix'),
  ('200066223', 'CC Arize Lèze'),
  ('200066231', 'CC des Portes d''Ariège Pyrénées'),
  ('200066363', 'CC de la Haute Ariège'),
  ('200067791', 'CA L''Agglo Foix-Varilhes'),
  ('200067940', 'CC Couserans-Pyrénées'),
  ('240900431', 'CC du Pays de Tarascon'),
  ('240900464', 'CC du Pays d''Olmes')
ON CONFLICT (siren) DO UPDATE
  SET nom = EXCLUDED.nom, date_maj = CURRENT_DATE;

ALTER TABLE gestcons.dico_epci OWNER TO adminsig;
GRANT SELECT ON gestcons.dico_epci TO shiny;
GRANT SELECT ON gestcons.dico_epci TO claudeg;

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles
-- ---------------------------------------------------------------------------
-- Tout SIREN porté par une commune doit avoir son nom — doit renvoyer 0 :
--   SELECT count(DISTINCT c.siren_epci) FROM gestcons.communes c
--    WHERE c.insee_dep = '09'
--      AND NOT EXISTS (SELECT 1 FROM gestcons.dico_epci e WHERE e.siren = c.siren_epci);
--
-- Les 8 EPCI et leur nombre de communes :
--   SELECT e.nom, count(*)::int FROM gestcons.communes c
--     JOIN gestcons.dico_epci e ON e.siren = c.siren_epci
--    WHERE c.insee_dep = '09' GROUP BY 1 ORDER BY 2 DESC;
