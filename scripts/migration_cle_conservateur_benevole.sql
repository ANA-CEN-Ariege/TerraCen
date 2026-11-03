-- Migration : conservateur_benevole conserve l'historique des périodes
-- APPLIQUÉE le 2026-10-15. Clé vérifiée après coup :
--   PRIMARY KEY (site_id, user_id, date_debut)
-- ---------------------------------------------------------------------------
-- La clé primaire était (site_id, user_id) : une seule ligne par couple site /
-- personne, donc aucun historique possible. responsable_sites porte depuis
-- toujours (site_id, user_id, date_debut), qui autorise plusieurs périodes
-- successives pour la même personne sur le même site.
--
-- Cette migration aligne conservateur_benevole sur ce modèle. Elle accompagne
-- maj_role_site() (R/helpers.R), qui distingue la correction d'une date de
-- début — modification de la ligne en cours — du changement de titulaire, qui
-- seul ouvre une période. Sans cette distinction, la clé à trois colonnes
-- découperait les tenures continues en tranches, défaut observé sur
-- responsable_sites : 37 de ses 87 périodes closes s'enchaînent exactement sur
-- une période suivante de la même personne.
--
-- Aucune contrainte étrangère ne référence cette clé : vérifié sur
-- pg_constraint, seules les FK sortantes vers sites et dico_utilisateur
-- existent. La migration est donc sans dépendance.
--
-- Effet sur l'instance de production, qui tourne encore sur l'ancien code :
-- celui-ci emploie « ON CONFLICT DO NOTHING » sans cible, qui reste valide
-- quelle que soit la clé. Aucune régression ; le cas « remettre un ancien
-- bénévole avec une nouvelle date » cesse même d'y échouer en silence.
--
-- Testée en transaction annulée le 2026-10-15 : la bascule passe, et le
-- bénévole 11 du site 43 peut alors porter deux périodes distinctes.

BEGIN;

ALTER TABLE gestcons.conservateur_benevole
  DROP CONSTRAINT conservateur_benevole_pkey;

ALTER TABLE gestcons.conservateur_benevole
  ADD CONSTRAINT conservateur_benevole_pkey
  PRIMARY KEY (site_id, user_id, date_debut);

-- Vérification
SELECT conname, pg_get_constraintdef(oid) AS definition
  FROM pg_constraint
 WHERE conrelid = 'gestcons.conservateur_benevole'::regclass
   AND contype = 'p';

-- Passer à COMMIT pour appliquer.
ROLLBACK;
