-- =============================================================================
-- Analyses : les communes d'un périmètre manuel, toutes
-- =============================================================================
-- À exécuter APRÈS scripts/migration_parcelles_communes.sql, qui crée la table
-- gestcons.parcelles_communes dont ces deux vues dépendent.
--
-- ⚠️ Les deux blocs ci-dessous sont EXTRAITS LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql (le script de référence, qui décrit l'état
-- final et qu'on ne rejoue JAMAIS : il repose le mot de passe du rôle). Ne pas
-- les modifier ici — modifier la référence, puis réextraire.
--
-- Ce que ça change :
--   - v_analyses_parcelles gagne `communes` (la liste) et `nb_communes`, et
--     remplit enfin commune / code_insee / siren_epci / epci pour les 41
--     parcelles à géométrie manuelle, qui n'en avaient aucune ;
--   - v_analyses_parcelles_communes est NOUVELLE : une ligne par couple
--     (parcelle, commune), avec la part de surface de chacune.
--
-- Après exécution, déclarer la nouvelle vue dans ANALYSE_VUES
-- (R/mod_analyse.R) — sans quoi le second verrou de l'onglet la refusera.
-- =============================================================================

BEGIN;

CREATE OR REPLACE VIEW gestcons.v_analyses_parcelles AS
  SELECT pb.id                               AS parcelle_id,
         pe.id                               AS site_id,
         pe.nom_site,
         -- ⚠️ `perimetre` a un sens INVERSE selon le type : pour un site il
         -- distingue la continuité de la parcelle contractuelle, pour un
         -- secteur TOUTES les parcelles le portent. Lire ce booléen sans
         -- regarder le type donne « continuité » à tout un secteur.
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END                AS nature,
         CASE WHEN pb.type_parcelle_id = 1 THEN 'cadastrale' ELSE 'manuelle' END AS type_parcelle,
         c.idpar                             AS reference_cadastrale,
         -- Une parcelle cadastrale tient sa commune de sa référence, et n'en a
         -- qu'UNE : le cadastre est découpé par commune. Un périmètre manuel
         -- n'a qu'une forme et peut en chevaucher plusieurs ; ses communes
         -- viennent de gestcons.parcelles_communes, calculée géométriquement.
         -- `commune` porte ici la PRINCIPALE, pour que la vue garde une ligne
         -- par parcelle. Le détail commune par commune, avec la surface dans
         -- chacune, est dans v_analyses_parcelles_communes.
         -- ⚠️ Les casts ne sont pas cosmétiques : CREATE OR REPLACE VIEW
         -- REFUSE de changer le type d'une colonne existante, et un COALESCE
         -- entre varchar(255) et varchar(50) rend un varchar sans longueur.
         COALESCE(c.idcomtxt, pcp.nom)::varchar(255) AS commune,
         pb.surf_parc_maitrise_m2            AS surface_m2,
         c.dcntpa::numeric                   AS surface_cadastrale_m2,
         dp.libelle                          AS priorite,
         pb.remarque,
         (SELECT count(*)::int FROM gestcons.contrats_foncier_parcelles j
           WHERE j.parcelle_id = pb.id)      AS nb_contrats_fonciers,
         (SELECT count(*)::int FROM gestcons.contrats_agricoles_parcelles j
           WHERE j.parcelle_id = pb.id)      AS nb_contrats_agricoles,
         pe.type_site,
         -- Compté sur idpersonne et non sur les lignes : une même personne
         -- peut tenir plusieurs comptes cadastraux. Mesuré le 2026-10-27 :
         -- 2 214 lignes pour 1 884 personnes et 1 359 comptes, et 262
         -- personnes à plus d'un compte.
         -- NULL — et non 0 — sur une parcelle manuelle : elle n'a pas de
         -- référence cadastrale, donc son propriétaire est INCONNU, ce qui
         -- n'est pas « aucun propriétaire ». Un count() sans ligne rend 0,
         -- d'où le CASE, sans quoi une moyenne serait tirée vers le bas.
         CASE WHEN pb.type_parcelle_id = 1 THEN
           (SELECT count(DISTINCT dp.idpersonne)::int
              FROM gestcons.dico_proprietaire dp
             WHERE dp.idprocpte = c.idprocpte) END  AS nb_proprietaires,
         CASE WHEN pb.type_parcelle_id = 1 THEN
           (SELECT count(DISTINCT dp.idpersonne) > 1
              FROM gestcons.dico_proprietaire dp
             WHERE dp.idprocpte = c.idprocpte) END  AS en_indivision,
         -- Le code INSEE accompagne TOUJOURS le libellé de commune : c'est
         -- lui qui permet d'exporter une couche communale, en se raccordant
         -- à gestcons.communes (IGN ADMIN-EXPRESS). Apparié sans perte au
         -- 2026-10-27 : 102 communes concernées, 102 retrouvées.
         COALESCE(c.idcom, pcp.insee_com)::varchar(5)   AS code_insee,
         -- L'intercommunalité suit la commune, par gestcons.communes qui
         -- porte le siren_epci, et dico_epci qui lui donne son nom.
         COALESCE(co.siren_epci, pcp.siren_epci)::varchar(20) AS siren_epci,
         ep.nom                             AS epci,
         -- ⚠️ En QUEUE de liste, et pas à côté de `commune` : CREATE OR REPLACE
         -- VIEW n'accepte d'ajouter une colonne qu'après les existantes.
         COALESCE(pcl.noms, c.idcomtxt)     AS communes,
         COALESCE(NULLIF(pcl.n, 0),
                  CASE WHEN c.idcom IS NOT NULL THEN 1 END) AS nb_communes
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  LEFT JOIN gestcons.dico_cadastre c ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
  LEFT JOIN gestcons.dico_priorite dp ON dp.id = pb.priorite_id
  LEFT JOIN gestcons.communes co ON co.insee_com = c.idcom
  -- La commune principale d'un périmètre manuel : celle de son point
  -- représentatif — identique à la majoritaire sur les 6 parcelles à cheval
  -- que compte la base.
  LEFT JOIN LATERAL (
    SELECT pc.insee_com, co2.nom, co2.siren_epci
      FROM gestcons.parcelles_communes pc
      JOIN gestcons.communes co2 ON co2.insee_com = pc.insee_com
     WHERE pc.parcelle_id = pb.id AND pc.principale
     LIMIT 1) pcp ON true
  -- Et la liste complète, de la plus grande emprise à la plus petite.
  -- ⚠️ count(*) sur zéro ligne rend 0 et non NULL : d'où le NULLIF sur `n`.
  LEFT JOIN LATERAL (
    SELECT string_agg(co3.nom, ', ' ORDER BY pc.surface_m2 DESC) AS noms,
           count(*)::int                                         AS n
      FROM gestcons.parcelles_communes pc
      JOIN gestcons.communes co3 ON co3.insee_com = pc.insee_com
     WHERE pc.parcelle_id = pb.id) pcl ON true
  LEFT JOIN gestcons.dico_epci ep ON ep.siren = COALESCE(co.siren_epci, pcp.siren_epci)
  WHERE pb.actif;

COMMENT ON VIEW gestcons.v_analyses_parcelles IS
  'Onglet Analyses : une ligne par parcelle active d''un site conservatoire. Surfaces en m².';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.nature        IS '« site » (parcelle maîtrisée, sous contrat), « continuité » (parcelle rattachée à un site, sans contrat) ou « secteur » (parcelle d''un secteur d''intervention prioritaire, zone de prospection)';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.type_site     IS '« site » (site conservatoire) ou « secteur » (secteur d''intervention prioritaire) — dit à quel objet la parcelle appartient';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.priorite      IS 'priorité d''intervention, renseignée sur les parcelles de secteur uniquement';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.type_parcelle IS '« cadastrale » (référence au cadastre) ou « manuelle » (polygone dessiné)';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.surface_m2    IS 'surface maîtrisée, en m² — c''est celle à sommer par défaut';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.nb_proprietaires IS 'nombre de propriétaires DISTINCTS de la parcelle ; NULL sur une parcelle manuelle, dont le propriétaire est inconnu faute de référence cadastrale — ce n''est pas zéro';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.en_indivision    IS 'vrai si la parcelle a plus d''un propriétaire';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.communes         IS 'TOUTES les communes recouvertes par la parcelle, de la plus grande emprise à la plus petite. Une parcelle cadastrale n''en a qu''une ; un périmètre manuel peut en avoir plusieurs. Pour SOMMER des hectares par commune, passer par v_analyses_parcelles_communes et non par cette colonne';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.nb_communes      IS 'nombre de communes recouvertes : 1 pour une parcelle cadastrale, 1 à 3 pour un périmètre manuel';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.code_insee       IS 'code INSEE de la commune — à renvoyer avec le libellé dès que la question porte sur les communes, c''est lui qui permet d''en exporter la couche';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.siren_epci       IS 'SIREN de l''intercommunalité — à renvoyer avec son nom dès que la question porte sur les communautés de communes, c''est lui qui permet d''en exporter la couche';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.epci             IS 'nom de l''intercommunalité (communauté de communes ou d''agglomération)';

CREATE OR REPLACE VIEW gestcons.v_analyses_parcelles_communes AS
  -- Parcelles cadastrales : une commune, celle de leur référence, et toute
  -- leur surface y est.
  SELECT pb.id                              AS parcelle_id,
         pe.id                              AS site_id,
         pe.nom_site,
         pe.type_site,
         'cadastrale'::text                 AS type_parcelle,
         c.idcom                            AS code_insee,
         c.idcomtxt                         AS commune,
         co.siren_epci,
         ep.nom                             AS epci,
         pb.surf_parc_maitrise_m2::numeric  AS surface_m2,
         true                               AS commune_principale
    FROM gestcons.parcelles_base pb
    JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
    JOIN gestcons.dico_cadastre c ON c.id = pb.parcellaire_id
    LEFT JOIN gestcons.communes co ON co.insee_com = c.idcom
    LEFT JOIN gestcons.dico_epci ep ON ep.siren = co.siren_epci
   WHERE pb.actif AND pb.type_parcelle_id = 1
  UNION ALL
  -- Périmètres manuels : une ligne par commune recouverte. La surface est
  -- celle de la parcelle, répartie AU PRORATA de l'emprise géométrique dans
  -- chaque commune — et non l'aire géométrique brute, pour que la somme par
  -- parcelle retombe exactement sur le surface_m2 de v_analyses_parcelles.
  -- Deux vues qui ne donnent pas le même total, c'est deux réponses
  -- contradictoires à la même question.
  SELECT pb.id,
         pe.id,
         pe.nom_site,
         pe.type_site,
         'manuelle'::text,
         pc.insee_com,
         co.nom,
         co.siren_epci,
         ep.nom,
         round(pb.surf_parc_maitrise_m2 * pc.surface_m2 / NULLIF(t.tot, 0)),
         pc.principale
    FROM gestcons.parcelles_base pb
    JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
    JOIN gestcons.parcelles_communes pc ON pc.parcelle_id = pb.id
    JOIN gestcons.communes co ON co.insee_com = pc.insee_com
    LEFT JOIN gestcons.dico_epci ep ON ep.siren = co.siren_epci
   CROSS JOIN LATERAL (SELECT sum(x.surface_m2)::numeric AS tot
                         FROM gestcons.parcelles_communes x
                        WHERE x.parcelle_id = pb.id) t
   WHERE pb.actif AND pb.type_parcelle_id = 2;

COMMENT ON VIEW gestcons.v_analyses_parcelles_communes IS
  'Onglet Analyses : une ligne par couple (parcelle, commune). À utiliser pour SOMMER des surfaces par commune ou par intercommunalité, car un périmètre manuel peut en recouvrir plusieurs et sa surface est alors répartie entre elles. NE PAS s''en servir pour compter des parcelles : une parcelle à cheval y figure plusieurs fois — v_analyses_parcelles est là pour ça.';
COMMENT ON COLUMN gestcons.v_analyses_parcelles_communes.surface_m2 IS
  'part de la surface maîtrisée de la parcelle qui revient à cette commune, en m². Sommée sur toutes les communes d''une parcelle, elle retombe sur le surface_m2 de v_analyses_parcelles';
COMMENT ON COLUMN gestcons.v_analyses_parcelles_communes.commune_principale IS
  'vrai pour la commune retenue quand une seule réponse est attendue (celle du point représentatif) ; toujours vrai pour une parcelle cadastrale, qui n''en a qu''une';
COMMENT ON COLUMN gestcons.v_analyses_parcelles_communes.type_parcelle IS
  '« cadastrale » (référence au cadastre, une seule commune) ou « manuelle » (polygone dessiné, pouvant en recouvrir plusieurs)';

-- ---------------------------------------------------------------------------
-- Propriété et droits
-- ---------------------------------------------------------------------------
-- Une vue lit avec les droits de SON propriétaire : créée sous un autre compte,
-- elle deviendrait irremplaçable par les migrations suivantes.
ALTER VIEW gestcons.v_analyses_parcelles          OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_parcelles_communes OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_parcelles_communes TO terracen_analyse;

-- ---------------------------------------------------------------------------
-- Contrôles
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- parcelles sans commune (doit être 0)'
SELECT count(*) AS sans_commune FROM gestcons.v_analyses_parcelles WHERE commune IS NULL;

\echo '--- grain conservé : v_analyses_parcelles reste à une ligne par parcelle'
SELECT count(*) AS lignes, count(DISTINCT parcelle_id) AS parcelles
FROM gestcons.v_analyses_parcelles;

\echo '--- parcelles sur plusieurs communes'
SELECT nb_communes, count(*) FROM gestcons.v_analyses_parcelles
 GROUP BY 1 ORDER BY 1;

\echo '--- les deux vues donnent le même total de surface (écart en m2)'
SELECT round(abs((SELECT sum(surface_m2) FROM gestcons.v_analyses_parcelles)
                -(SELECT sum(surface_m2) FROM gestcons.v_analyses_parcelles_communes))) AS ecart_m2;

\echo '--- hectares par intercommunalité, au prorata'
SELECT epci, round((sum(surface_m2)/10000)::numeric,1) AS ha,
       count(DISTINCT parcelle_id) AS parcelles
FROM gestcons.v_analyses_parcelles_communes
WHERE epci IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

COMMIT;
