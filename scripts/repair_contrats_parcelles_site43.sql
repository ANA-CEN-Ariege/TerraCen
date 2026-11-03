-- Pech Saint-Sauveur (site 43) : un seul contrat ACTIF par parcelle
-- ---------------------------------------------------------------------------
-- Sept parcelles portaient DEUX contrats actifs simultanément :
--   11 « Convention Danièle Bacquié »              actif 2023-12-22 → 2033-12-22
--   68 « Convention de partenariat Commune de Foix » actif 2015-11-12 → 2035-07-07
--
-- Le partage se lit dans la propriété, pas dans les contrats :
--   - six parcelles appartiennent à l'indivision BACQUIÉ / BLAZY (13,17 ha)
--   - une seule, 091220000D0212 (21,70 ha), appartient à la COMMUNE DE FOIX
-- et les six autres parcelles du contrat 68, sur Pech de Foix, sont toutes
-- communales. Chaque contrat ne garde donc que les parcelles de son
-- propriétaire.
--
-- N'est PAS concerné : le site 125, dont les deux parcelles portent un contrat
-- terminé puis un contrat actif qui s'enchaînent au jour près — historique
-- légitime, à conserver tel quel.
--
-- Terminé par ROLLBACK : passer à COMMIT pour appliquer.

BEGIN;

CREATE TEMP TABLE avant ON COMMIT DROP AS
SELECT cfp.contrat_id, c.idpar
  FROM gestcons.contrats_foncier_parcelles cfp
  JOIN gestcons.parcelles_base p ON p.id = cfp.parcelle_id
  JOIN gestcons.dico_cadastre c  ON c.id = p.parcellaire_id
 WHERE p.site_id = 43 AND cfp.contrat_id IN (11, 68);

SELECT 'AVANT' AS etat, cfp.contrat_id, s.libelle AS site, count(*) AS parcelles
  FROM gestcons.contrats_foncier_parcelles cfp
  JOIN gestcons.parcelles_base p ON p.id = cfp.parcelle_id
  JOIN gestcons.sites s ON s.id = p.site_id
 WHERE cfp.contrat_id IN (11, 68)
 GROUP BY cfp.contrat_id, s.libelle ORDER BY cfp.contrat_id, s.libelle;

-- 1. Le contrat communal abandonne les parcelles de l'indivision.
DELETE FROM gestcons.contrats_foncier_parcelles cfp
 USING gestcons.parcelles_base p, gestcons.dico_cadastre c
 WHERE cfp.parcelle_id = p.id AND c.id = p.parcellaire_id
   AND cfp.contrat_id = 68 AND p.site_id = 43
   AND c.idpar <> '091220000D0212';

-- 2. Le contrat de l'indivision abandonne la parcelle communale.
DELETE FROM gestcons.contrats_foncier_parcelles cfp
 USING gestcons.parcelles_base p, gestcons.dico_cadastre c
 WHERE cfp.parcelle_id = p.id AND c.id = p.parcellaire_id
   AND cfp.contrat_id = 11 AND p.site_id = 43
   AND c.idpar = '091220000D0212';

-- 3. Vérifications
SELECT 'APRES' AS etat, cfp.contrat_id, s.libelle AS site, count(*) AS parcelles
  FROM gestcons.contrats_foncier_parcelles cfp
  JOIN gestcons.parcelles_base p ON p.id = cfp.parcelle_id
  JOIN gestcons.sites s ON s.id = p.site_id
 WHERE cfp.contrat_id IN (11, 68)
 GROUP BY cfp.contrat_id, s.libelle ORDER BY cfp.contrat_id, s.libelle;

SELECT 'parcelles a plusieurs contrats ACTIFS (doit etre 0)' AS controle, count(*)
  FROM (SELECT cfp.parcelle_id
          FROM gestcons.contrats_foncier_parcelles cfp
          JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
         WHERE cf.statut_id = 3
         GROUP BY 1 HAVING count(*) > 1) t;

SELECT 'parcelles du site 43 sans aucun contrat (doit etre 0)' AS controle, count(*)
  FROM gestcons.parcelles_base p
 WHERE p.site_id = 43 AND NOT p.perimetre
   AND NOT EXISTS (SELECT 1 FROM gestcons.contrats_foncier_parcelles x
                    WHERE x.parcelle_id = p.id)
   AND NOT EXISTS (SELECT 1 FROM gestcons.contrats_agricoles_parcelles y
                    WHERE y.parcelle_id = p.id);

ROLLBACK;
