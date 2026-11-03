-- Fusion des périodes de responsabilité découpées par l'ancien code
-- APPLIQUÉE le 2026-10-15 : 27 tenures réunies, 261 -> 222 lignes,
-- périodes actives inchangées (174), plus aucun enchaînement résiduel.
--
-- NE PAS relancer comme contrôle de non-régression : la détection
-- d'enchaînement (date_fin = date_debut suivante) ne distingue pas une
-- tenure découpée par une correction de date d'un retrait suivi d'une
-- remise du même responsable le même jour, qui est légitime.
-- ---------------------------------------------------------------------------
-- Avant maj_role_site(), corriger la date de début du responsable en place
-- clôturait la période en cours et en ouvrait une nouvelle à la date du jour.
-- Une tenure continue s'est donc retrouvée découpée en tranches qui
-- s'enchaînent : la date_fin de l'une vaut la date_debut de la suivante, pour
-- la MÊME personne sur le MÊME site.
--
-- Ce script réunit chaque suite de tranches en une seule période, partant de
-- la date la plus ancienne et conservant l'état de la dernière ligne (donc
-- active si la tenure est en cours). Les tranches intermédiaires sont
-- supprimées.
--
-- Ne touche QUE les suites réellement contiguës. Un vrai changement de
-- titulaire, ou un retour après interruption, laisse un trou entre date_fin et
-- la date_debut suivante : la rupture est détectée et les périodes restent
-- distinctes.
--
-- Terminé par ROLLBACK : passer à COMMIT pour appliquer.

BEGIN;

-- 1. Marquage des suites contiguës -------------------------------------------
CREATE TEMP TABLE periodes ON COMMIT DROP AS
WITH p AS (
  SELECT site_id, user_id, date_debut, date_fin, actif,
         lag(date_fin) OVER w AS fin_precedente
    FROM gestcons.responsable_sites
  WINDOW w AS (PARTITION BY site_id, user_id ORDER BY date_debut))
SELECT *,
       sum(CASE WHEN fin_precedente = date_debut::date THEN 0 ELSE 1 END)
         OVER (PARTITION BY site_id, user_id ORDER BY date_debut) AS grp
  FROM p;

CREATE TEMP TABLE fusion ON COMMIT DROP AS
SELECT site_id, user_id, grp,
       min(date_debut) AS debut_min,
       max(date_debut) AS debut_garde,
       count(*)        AS tranches
  FROM periodes
 GROUP BY site_id, user_id, grp
HAVING count(*) > 1;

SELECT 'AVANT  lignes' AS quoi, count(*) FROM gestcons.responsable_sites
UNION ALL
SELECT 'AVANT  actives', count(*) FROM gestcons.responsable_sites WHERE actif
UNION ALL
SELECT 'tenures a fusionner', count(*) FROM fusion
UNION ALL
SELECT 'lignes a supprimer', coalesce(sum(tranches - 1), 0) FROM fusion;

-- 2. Suppression des tranches intermédiaires ---------------------------------
-- La suppression précède la mise à jour : repositionner d'abord la ligne
-- conservée sur debut_min entrerait en collision avec la première tranche,
-- qui porte déjà cette date dans la clé primaire.
DELETE FROM gestcons.responsable_sites r
 USING periodes pe
  JOIN fusion f USING (site_id, user_id, grp)
 WHERE r.site_id    = pe.site_id
   AND r.user_id    = pe.user_id
   AND r.date_debut = pe.date_debut
   AND pe.date_debut < f.debut_garde;

-- 3. La ligne conservée reprend la date de début la plus ancienne ------------
UPDATE gestcons.responsable_sites r
   SET date_debut        = f.debut_min,
       modifie_par       = 'fusion-periodes',
       date_modification = NOW()
  FROM fusion f
 WHERE r.site_id    = f.site_id
   AND r.user_id    = f.user_id
   AND r.date_debut = f.debut_garde;

-- 4. Vérifications -----------------------------------------------------------
SELECT 'APRES  lignes' AS quoi, count(*) FROM gestcons.responsable_sites
UNION ALL
SELECT 'APRES  actives', count(*) FROM gestcons.responsable_sites WHERE actif
UNION ALL
SELECT 'sites sans responsable actif',
       count(*) FROM gestcons.sites s
        WHERE s.type_site_id = 1
          AND EXISTS (SELECT 1 FROM gestcons.responsable_sites r WHERE r.site_id = s.id)
          AND NOT EXISTS (SELECT 1 FROM gestcons.responsable_sites r
                           WHERE r.site_id = s.id AND r.actif);

-- Reste-t-il des enchaînements ? doit renvoyer 0
WITH p AS (
  SELECT site_id, user_id, date_debut, date_fin,
         lag(date_fin) OVER (PARTITION BY site_id, user_id ORDER BY date_debut) AS fin_prec
    FROM gestcons.responsable_sites)
SELECT 'enchainements restants' AS quoi, count(*)
  FROM p WHERE fin_prec = date_debut::date;

-- Échantillon des tenures fusionnées
SELECT r.site_id, r.user_id, r.date_debut::date AS debut, r.date_fin, r.actif
  FROM gestcons.responsable_sites r
  JOIN fusion f ON f.site_id = r.site_id AND f.user_id = r.user_id
 WHERE r.date_debut = f.debut_min
 ORDER BY f.tranches DESC, r.site_id
 LIMIT 8;

ROLLBACK;
