-- Migration — onglet « Analyses » : séparer les secteurs des sites.
--
-- Pourquoi : les vues de gestion qui alimentent v_analyses_sites ne filtrent
-- pas le type de site, alors que v_analyses_perimetre filtrait type_site_id=1.
-- Depuis la bascule de 111 sites en secteurs (2026-10-27), l'onglet présentait
-- donc 111 secteurs comme des sites « en préfiguration » à 0 parcelle, dont
-- les parcelles étaient comptées en continuité et absentes du détail.
-- Mesuré sur Aérodrome Pujols : nb_parcelles 0, nb_parcelles_continuite 96,
-- 0 ligne dans v_analyses_parcelles, pour 96 parcelles de secteur réelles.
--
-- Ce que fait ce script :
--   1. v_analyses_sites se restreint aux vrais sites (type_site_id = 1) ;
--   2. v_analyses_perimetre s'ouvre aux secteurs et porte une colonne type_site ;
--   3. v_analyses_parcelles lit ce type au lieu de lire `perimetre` à l'aveugle,
--      et expose type_site ;
--   4. v_analyses_secteurs apparaît, une ligne par secteur.
--
-- ⚠️ POURQUOI UN SCRIPT À PART, et ne PAS rejouer analyse_role_lecture.sql :
-- celui-ci contient « ALTER ROLE terracen_analyse PASSWORD 'A_REMPLACER' ».
-- Le rejouer sur la base en service remettrait ce mot de passe et casserait
-- l'onglet jusqu'à ce que le vrai soit reposé à la main. Le script de
-- référence reste la description de l'état final ; celui-ci est ce qu'on
-- exécute. Les blocs ci-dessous en sont extraits à l'identique.
--
-- ⚠️ CETTE EXÉCUTION-CI demande un superutilisateur, et c'est la DERNIÈRE :
-- les vues v_analyses_* appartiennent aujourd'hui à `claudeg`, alors que tout
-- le reste de gestcons appartient à `adminsig`. Le script répare cette
-- anomalie en fin de parcours (ALTER ... OWNER TO adminsig). Une fois passé,
-- `adminsig` possède tout et suffit aux migrations suivantes.
--
--   psql -h <hote> -U claudeg -d anaweb -f scripts/migration_analyses_secteurs.sql
--
-- Rejouable sans effet de bord : CREATE OR REPLACE, ALTER OWNER et GRANT sont
-- tous idempotents.
--
-- Rappel du modèle de rôles, qui ne change pas :
--   adminsig          — propriétaire des tables et des vues ;
--   shiny             — l'application TerraCEN ;
--   terracen_analyse  — l'onglet Analyses SEUL, lecture seule, sur les seules
--                       vues v_analyses_* qui lui sont accordées nommément.

BEGIN;

-- ---------------------------------------------------------------------------
-- analyses.sites
--
-- Projection des deux vues de gestion existantes, actifs et préfiguration,
-- qui portent exactement les mêmes colonnes. On en retire :
--   responsables_actifs, animateurs_actifs, cree_par, modifie_par  -> noms de personnes
--   remq_sensibilite                                               -> texte libre sur la sensibilité
--   geometry                                                       -> inutile en texte, et lourd
--   les identifiants externes et les URL                           -> bruit, qui coûterait des jetons
--
-- Le filtre sur non_diffusion et sensibilite ne retire aucune ligne
-- aujourd'hui (0 site marqué, vérifié le 2026-10-26) : il est là pour que le
-- jour où un site le sera, il sorte du périmètre sans que personne ait à y
-- penser.
-- ---------------------------------------------------------------------------
-- ⚠️ surface_maitrisee_m2 des deux vues sources N'EST PAS reprise. Elle vaut
-- sum(p.surf_parc_maitrise_m2) sous une cascade de LEFT JOIN vers les
-- contrats, les documents et les responsables : chaque parcelle y est comptée
-- autant de fois qu'elle a de liaisons. nb_parcelles, lui, est protégé par un
-- count(DISTINCT), d'où une incohérence invisible. Constaté le 2026-10-26 sur
-- 27 sites des 170, avec des facteurs ronds qui signent la démultiplication :
-- Saint-Barthélémy 2 832 ha au lieu de 566 (×5), Montagne de la Frau 1 700 au
-- lieu de 850 (×2). Les surfaces sont donc recalculées ici par sous-requête,
-- et séparées selon la nature de la parcelle, ce que « maîtrisée » ne disait
-- pas.
--
-- surface_totale_m2 n'est pas reprise non plus, pour une autre raison : c'est
-- un ST_Area(ST_Union(...)) — donc juste — mais sous un
-- CASE WHEN p.type_parcelle_id = 1 THEN union(cadastre) ELSE union(manuel) END
-- où p.type_parcelle_id n'est pas groupé : une seule des deux branches est
-- retenue, au hasard de la ligne. Sans conséquence sur les 99 sites tout
-- cadastre ni sur les 32 tout manuel, fausse sur les 2 sites mixtes. Plutôt
-- que d'exposer deux surfaces qui se contredisent, on n'en expose qu'une.
-- Contrôle : sur les sites tout cadastre, somme cadastrale et union
-- géométrique s'accordent à 0,5 % près (850,4 contre 853,0 ha sur Montagne de
-- la Frau), l'écart n'étant que l'arrondi du cadastre.
CREATE OR REPLACE VIEW gestcons.v_analyses_sites AS
  WITH source AS (
    SELECT 'actif'::text AS etat_gestion, s.* FROM gestcons.sites_gestion_terracen_actifs s
    UNION ALL
    SELECT 'préfiguration'::text, s.* FROM gestcons.sites_gestion_terracen_prefiguration s
  )
  SELECT s.etat_gestion, s.id, s.nom_site, s.description_site,
         s.date_crea_site, s.type_milieu, s.nature_perimetre, s.geologie,
         s.gestionnaire_libelle_long AS gestionnaire, s.operateur,
         s.statut_actuel, s.statut_depuis, s.ouverture_public,
         p.nb_parcelles, p.nb_parcelles_continuite,
         p.surface_parcelles_m2, p.surface_continuite_m2,
         s.nb_contrats_fonciers, s.nb_contrats_agricoles, s.nb_documents_gestion
  FROM source s
  -- Les deux vues de gestion amont ne filtrent PAS le type de site : sans ce
  -- JOIN, un secteur d'intervention prioritaire y apparaît comme un site en
  -- préfiguration, et ses parcelles tombent dans nb_parcelles_continuite,
  -- puisque celles d'un secteur portent perimetre = true. Les secteurs ont
  -- leur propre vue, v_analyses_secteurs.
  JOIN gestcons.sites si ON si.id = s.id AND si.type_site_id = 1
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE NOT pb.perimetre)::int              AS nb_parcelles,
           count(*) FILTER (WHERE pb.perimetre)::int                  AS nb_parcelles_continuite,
           COALESCE(sum(pb.surf_parc_maitrise_m2) FILTER (WHERE NOT pb.perimetre), 0) AS surface_parcelles_m2,
           COALESCE(sum(pb.surf_parc_maitrise_m2) FILTER (WHERE pb.perimetre), 0)     AS surface_continuite_m2
    FROM gestcons.parcelles_base pb
    WHERE pb.site_id = s.id AND pb.actif
  ) p ON TRUE
  WHERE NOT COALESCE(s.non_diffusion, false)
    AND NOT COALESCE(s.sensibilite, false);

COMMENT ON VIEW gestcons.v_analyses_sites IS
  'Onglet Analyses : un site conservatoire par ligne, actif ou en préfiguration, sans aucune donnée personnelle. Seule vue lisible par le rôle terracen_analyse.';

COMMENT ON COLUMN gestcons.v_analyses_sites.etat_gestion            IS 'actif ou préfiguration';
COMMENT ON COLUMN gestcons.v_analyses_sites.nb_parcelles            IS 'parcelles du site (hors continuité)';
COMMENT ON COLUMN gestcons.v_analyses_sites.nb_parcelles_continuite IS 'parcelles de la continuité du site';
COMMENT ON COLUMN gestcons.v_analyses_sites.surface_parcelles_m2    IS 'surface des parcelles du site, hors continuité, en m² — somme des surfaces cadastrales';
COMMENT ON COLUMN gestcons.v_analyses_sites.surface_continuite_m2   IS 'surface des parcelles de la continuité, en m²';
COMMENT ON COLUMN gestcons.v_analyses_sites.statut_actuel        IS 'statut courant du site (Actif, Préfiguration, Archivé…)';
COMMENT ON COLUMN gestcons.v_analyses_sites.ouverture_public     IS 'conditions d''ouverture au public';

-- ---------------------------------------------------------------------------
-- Les trois vues de détail. Une seule vue par site ne permettait de répondre
-- qu'aux questions agrégées : ni le statut d'un contrat, ni son rattachement
-- aux parcelles n'y figuraient. « Combien de parcelles ont un contrat en
-- élaboration ? » était sans réponse.
--
-- ⚠️ Les NOMS DE CONTRATS partent chez Anthropic avec les réponses, et
-- certains portent un patronyme (« Convention assistance technique CAMARADE -
-- GUIBERT »). Demande explicite de l'utilisateur, consignée pour que le choix
-- reste visible.
-- ---------------------------------------------------------------------------
-- Les sites ET les secteurs du périmètre, une fois pour toutes.
--
-- ⚠️ Cette vue portait `type_site_id = 1`, donc les parcelles des secteurs
-- d'intervention prioritaire étaient absentes de TOUTES les vues de détail,
-- alors que v_analyses_sites, elle, les laissait passer (les vues de gestion
-- amont ne filtrent pas le type). L'onglet présentait donc 111 secteurs comme
-- des sites « en préfiguration » à 0 parcelle. Le type est désormais porté par
-- une colonne plutôt que par un filtre : chaque vue en aval décide.
CREATE OR REPLACE VIEW gestcons.v_analyses_perimetre AS
  SELECT s.id, s.libelle AS nom_site,
         CASE WHEN s.type_site_id = 2 THEN 'secteur' ELSE 'site' END AS type_site
  FROM gestcons.sites s
  WHERE s.actif AND s.type_site_id IN (1, 2)
    AND NOT COALESCE(s.non_diffusion, false)
    AND NOT COALESCE(s.sensibilite, false);

-- ---------------------------------------------------------------------------
-- Une ligne par parcelle
-- ---------------------------------------------------------------------------
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
         c.idcomtxt                          AS commune,
         pb.surf_parc_maitrise_m2            AS surface_m2,
         c.dcntpa::numeric                   AS surface_cadastrale_m2,
         dp.libelle                          AS priorite,
         pb.remarque,
         (SELECT count(*)::int FROM gestcons.contrats_foncier_parcelles j
           WHERE j.parcelle_id = pb.id)      AS nb_contrats_fonciers,
         (SELECT count(*)::int FROM gestcons.contrats_agricoles_parcelles j
           WHERE j.parcelle_id = pb.id)      AS nb_contrats_agricoles,
         pe.type_site
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  LEFT JOIN gestcons.dico_cadastre c ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
  LEFT JOIN gestcons.dico_priorite dp ON dp.id = pb.priorite_id
  WHERE pb.actif;

COMMENT ON VIEW gestcons.v_analyses_parcelles IS
  'Onglet Analyses : une ligne par parcelle active d''un site conservatoire. Surfaces en m².';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.nature        IS '« site » (parcelle maîtrisée, sous contrat), « continuité » (parcelle rattachée à un site, sans contrat) ou « secteur » (parcelle d''un secteur d''intervention prioritaire, zone de prospection)';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.type_site     IS '« site » (site conservatoire) ou « secteur » (secteur d''intervention prioritaire) — dit à quel objet la parcelle appartient';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.priorite      IS 'priorité d''intervention, renseignée sur les parcelles de secteur uniquement';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.type_parcelle IS '« cadastrale » (référence au cadastre) ou « manuelle » (polygone dessiné)';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.surface_m2    IS 'surface maîtrisée, en m² — c''est celle à sommer par défaut';

-- ---------------------------------------------------------------------------
-- Une ligne par contrat, foncier ou agricole
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_contrats AS
  SELECT 'foncier'::text AS type_contrat,
         cf.id           AS contrat_id,
         cf.nom          AS nom_contrat,
         t.libelle_mfu1  AS nature_contrat,
         t.libelle_mfu2  AS detail_contrat,
         ds.libelle      AS statut,
         cf.date_signature, cf.date_debut, cf.date_fin, cf.date_rupture,
         NULL::numeric   AS surface_declaree_m2,
         (SELECT count(*)::int FROM gestcons.contrats_foncier_parcelles j
           WHERE j.contrat_id = cf.id) AS nb_parcelles
  FROM gestcons.contrats_fonciers cf
  LEFT JOIN gestcons.dico_type_contrat_foncier t ON t.id = cf.type_maitrise_id
  LEFT JOIN gestcons.dico_type_statut_contrat ds ON ds.id = cf.statut_id
  UNION ALL
  SELECT 'agricole', ca.id, ca.nom,
         'contrat agricole', dta.libelle,
         ds.libelle,
         NULL::date, ca.date_debut, ca.date_fin, ca.date_rupture,
         ca.surf_m2,
         (SELECT count(*)::int FROM gestcons.contrats_agricoles_parcelles j
           WHERE j.contrat_agri_id = ca.id)
  FROM gestcons.contrats_agricoles ca
  LEFT JOIN gestcons.dico_type_contrat_agricole dta ON dta.id = ca.type_contrat_id
  LEFT JOIN gestcons.dico_type_statut_contrat ds ON ds.id = ca.statut_id;

COMMENT ON VIEW gestcons.v_analyses_contrats IS
  'Onglet Analyses : une ligne par contrat, foncier ou agricole, avec son statut.';
COMMENT ON COLUMN gestcons.v_analyses_contrats.statut         IS 'En cours d''élaboration, Actif, Suspendu, Terminé ou Résilié';
COMMENT ON COLUMN gestcons.v_analyses_contrats.nature_contrat IS 'pour un contrat foncier : propriété, obligation réelle environnementale, contrats de gestion ≥ ou < 18 ans';
COMMENT ON COLUMN gestcons.v_analyses_contrats.nb_parcelles   IS 'parcelles rattachées, toutes natures et tous sites confondus';

-- ---------------------------------------------------------------------------
-- Le lien parcelle ↔ contrat : c'est lui qui manquait le plus
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_parcelles_contrats AS
  SELECT p.parcelle_id, p.site_id, p.nom_site, p.nature, p.type_parcelle,
         p.reference_cadastrale, p.commune, p.surface_m2,
         k.type_contrat, k.contrat_id, k.nom_contrat, k.nature_contrat,
         k.statut, k.date_debut, k.date_fin
  FROM gestcons.v_analyses_parcelles p
  JOIN (
    SELECT j.parcelle_id, c.* FROM gestcons.contrats_foncier_parcelles j
      JOIN gestcons.v_analyses_contrats c ON c.contrat_id = j.contrat_id AND c.type_contrat = 'foncier'
    UNION ALL
    SELECT j.parcelle_id, c.* FROM gestcons.contrats_agricoles_parcelles j
      JOIN gestcons.v_analyses_contrats c ON c.contrat_id = j.contrat_agri_id AND c.type_contrat = 'agricole'
  ) k ON k.parcelle_id = p.parcelle_id;

COMMENT ON VIEW gestcons.v_analyses_parcelles_contrats IS
  'Onglet Analyses : une ligne par couple parcelle-contrat. Une parcelle sans contrat n''y figure pas ; une parcelle à deux contrats y figure deux fois.';

-- ---------------------------------------------------------------------------
-- Une ligne par secteur d'intervention prioritaire
--
-- Un secteur n'est PAS un site : c'est une zone de prospection, des parcelles
-- sans contrat repérées comme futur site possible. Il n'a ni statut ni
-- gestionnaire — c'est précisément ce qui le tient hors de l'export FCEN — et
-- il ne passe donc pas par les vues de gestion, qui attendent les deux. D'où
-- une vue bâtie directement sur `sites` et `parcelles_base`.
--
-- Les surfaces sont sommées depuis les parcelles, comme pour les sites, et
-- pour la même raison : les surfaces agrégées des vues de gestion comptent
-- chaque parcelle autant de fois qu'elle a de liaisons.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_secteurs AS
  SELECT s.id                      AS secteur_id,
         s.libelle                 AS nom_secteur,
         s.description_site        AS description,
         s.date_crea_site,
         p.nb_parcelles,
         p.nb_parcelles_cadastrales,
         p.nb_parcelles_manuelles,
         p.surface_m2,
         p.nb_priorite_1,
         p.nb_priorite_2,
         p.nb_sans_priorite,
         p.communes
  FROM gestcons.sites s
  LEFT JOIN LATERAL (
    SELECT count(*)::int                                              AS nb_parcelles,
           count(*) FILTER (WHERE pb.type_parcelle_id = 1)::int       AS nb_parcelles_cadastrales,
           count(*) FILTER (WHERE pb.type_parcelle_id <> 1)::int      AS nb_parcelles_manuelles,
           COALESCE(sum(pb.surf_parc_maitrise_m2), 0)                 AS surface_m2,
           count(*) FILTER (WHERE pb.priorite_id = 1)::int            AS nb_priorite_1,
           count(*) FILTER (WHERE pb.priorite_id = 2)::int            AS nb_priorite_2,
           count(*) FILTER (WHERE pb.priorite_id IS NULL)::int        AS nb_sans_priorite,
           string_agg(DISTINCT c.idcomtxt, ', ')                      AS communes
    FROM gestcons.parcelles_base pb
    LEFT JOIN gestcons.dico_cadastre c
           ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
    WHERE pb.site_id = s.id AND pb.actif
  ) p ON TRUE
  WHERE s.actif AND s.type_site_id = 2
    AND NOT COALESCE(s.non_diffusion, false)
    AND NOT COALESCE(s.sensibilite, false);

COMMENT ON VIEW gestcons.v_analyses_secteurs IS
  'Onglet Analyses : un secteur d''intervention prioritaire par ligne — une zone de prospection, parcelles sans contrat repérées comme futur site conservatoire possible. Un secteur n''est pas un site : il n''a ni statut ni gestionnaire.';

COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_parcelles_manuelles IS 'parcelles à géométrie dessinée, sans référence cadastrale — elles n''ont ni commune ni propriétaire connu';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.surface_m2             IS 'somme des surfaces des parcelles du secteur, en m²';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_priorite_1          IS 'parcelles en priorité 1 (la plus urgente)';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.communes               IS 'communes couvertes par le secteur, séparées par des virgules';

-- ---------------------------------------------------------------------------
-- Propriété : tout revient à adminsig
--
-- Une vue lit avec les droits de SON propriétaire. Les v_analyses_* ayant été
-- créées par claudeg, elles lisaient jusqu'ici en superutilisateur, et
-- claudeg seul pouvait les remplacer — d'où une migration impossible à passer
-- sous adminsig comme le reste du schéma.
--
-- Transfert sans effet sur ce que les vues renvoient : vérifié le 2026-10-27,
-- AUCUNE des 74 tables de gestcons ne porte de RLS (relrowsecurity = false
-- partout), donc rien que le propriétaire précédent outrepassait.
-- ---------------------------------------------------------------------------
ALTER VIEW gestcons.v_analyses_sites              OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_secteurs           OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_perimetre          OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_parcelles          OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_contrats           OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_parcelles_contrats OWNER TO adminsig;

-- Même anomalie, autre objet : dico_priorite a été créée par claudeg lors de
-- la migration des secteurs (migration_secteurs_strategie.sql) et n'a jamais
-- été rendue. Elle est la SEULE table de gestcons qui n'appartienne pas à
-- adminsig, et `shiny` ne peut pas la lire — sans conséquence aujourd'hui, le
-- code n'y touche jamais (les priorités sont en dur dans les selectInput) et
-- la clé étrangère de parcelles_base s'applique sans droit de lecture.
-- Correction d'hygiène : si tu préfères la traiter à part, retire ces deux
-- lignes, le reste du script n'en dépend pas.
ALTER TABLE gestcons.dico_priorite OWNER TO adminsig;
GRANT SELECT ON gestcons.dico_priorite TO shiny;

-- Les droits, en UNE seule liste. Elle était écrite deux fois, ce qui est le
-- meilleur moyen d'ajouter une vue à l'une et de l'oublier dans l'autre.
GRANT USAGE  ON SCHEMA gestcons                            TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_sites                  TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_secteurs               TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles              TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_contrats               TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles_contrats     TO terracen_analyse;
-- v_analyses_perimetre reste INTERNE : elle ne sert qu'à bâtir les autres, qui
-- s'exécutent avec les droits de leur propriétaire. Pas de GRANT, pas de place
-- perdue dans le prompt.

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles — après le COMMIT, en superutilisateur. `claudeg` étant
-- superutilisateur, un SELECT direct ne prouve rien : il faut endosser le rôle.
-- ---------------------------------------------------------------------------
-- BEGIN;
--   SET LOCAL ROLE terracen_analyse;
--   SELECT count(*) FROM gestcons.v_analyses_sites;      -- sites SEULS, sans les secteurs
--   SELECT count(*) FROM gestcons.v_analyses_secteurs;   -- 113 au 2026-10-27
--   SELECT nature, count(*) FROM gestcons.v_analyses_parcelles GROUP BY 1;
--     -- attendu : secteur 3963, site 2389, continuité 346
--   SELECT nb_parcelles, nb_priorite_1 FROM gestcons.v_analyses_secteurs
--    WHERE nom_secteur ILIKE '%Pujol%';                  -- attendu : 96, 96
-- ROLLBACK;
--
-- Et la propriété, qui doit être adminsig partout :
--   SELECT c.relname, pg_get_userbyid(c.relowner) AS proprietaire
--     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--    WHERE n.nspname = 'gestcons' AND pg_get_userbyid(c.relowner) <> 'adminsig';
--   -- doit ne renvoyer aucune ligne
