-- Migration — onglet « Analyses » : responsables, bénévoles et animateurs.
--
-- Demande explicite : « des infos sur les responsables et bénévoles de site,
-- animateurs ». Cela n'a pas de sens sans savoir de QUI il s'agit, et c'est
-- donc le premier endroit du périmètre interrogeable qui nomme des personnes.
--
-- ⚠️ CE QUE ÇA CHANGE, ET CE QUE ÇA NE CHANGE PAS.
-- Ce qui entre : 31 personnes, salariés et bénévoles du CEN, dont les noms
-- sont déjà affichés partout dans l'application, dans un onglet réservé aux
-- administrateurs. Sans leur adresse courriel, qui n'ajoute rien à une
-- analyse et identifie plus fortement.
-- Ce qui reste dehors : les PROPRIÉTAIRES. v_analyses_proprietaires continue
-- de ne rendre que des types et une empreinte, jamais une identité, et
-- dico_proprietaire reste refusée au rôle de lecture. Les deux sujets n'ont
-- pas la même nature et ne se décident pas ensemble.
--
-- Ce que fait ce script :
--   1. v_analyses_roles_sites : une ligne par rôle tenu, historique compris ;
--   2. v_analyses_sites gagne responsables et animateurs EN COURS ;
--   3. v_analyses_secteurs gagne responsables — un secteur n'a ni animateur
--      ni conservateur bénévole, c'est une règle de gestion.
--
-- Repères mesurés le 2026-10-28 : 230 lignes de responsabilité dont 175 en
-- cours (18 personnes, un responsable par objet), 57 d'animation dont 29 en
-- cours (16 personnes), 21 de bénévolat dont AUCUNE en cours — la vue les
-- garde comme historique.
--
-- À exécuter sous adminsig :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/migration_analyses_roles.sql
--
-- ⚠️ Ne PAS rejouer analyse_role_lecture.sql (ALTER ROLE ... PASSWORD). Les
-- blocs ci-dessous en sont extraits à l'identique.

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
         s.nb_contrats_fonciers, s.nb_contrats_agricoles, s.nb_documents_gestion,
         r.responsables, r.animateurs
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
  -- Rôles EN COURS seulement : l'historique vit dans v_analyses_roles_sites.
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT btrim(COALESCE(u.prenom,'') || ' ' || COALESCE(u.nom,'')), ', ')
             FILTER (WHERE x.role = 'responsable') AS responsables,
           string_agg(DISTINCT btrim(COALESCE(u.prenom,'') || ' ' || COALESCE(u.nom,'')), ', ')
             FILTER (WHERE x.role = 'animateur')   AS animateurs
    FROM (SELECT site_id, user_id, 'responsable'::text AS role FROM gestcons.responsable_sites WHERE actif
          UNION ALL
          SELECT site_id, user_id, 'animateur' FROM gestcons.animateur_sites WHERE actif) x
    LEFT JOIN gestcons.dico_utilisateur u ON u.id = x.user_id
    WHERE x.site_id = s.id
  ) r ON TRUE
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
COMMENT ON COLUMN gestcons.v_analyses_sites.responsables         IS 'responsables EN COURS, séparés par des virgules ; l''historique est dans v_analyses_roles_sites';
COMMENT ON COLUMN gestcons.v_analyses_sites.animateurs           IS 'animateurs EN COURS, séparés par des virgules';

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
         p.communes,
         r.responsables
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
  -- Un secteur n'a ni animateur ni conservateur bénévole — c'est une règle de
  -- gestion, pas un hasard des données (mise en cohérence du 2026-10-28) —
  -- mais il peut avoir un responsable.
  LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT btrim(COALESCE(u.prenom,'') || ' ' || COALESCE(u.nom,'')), ', ')
             AS responsables
    FROM gestcons.responsable_sites rs
    LEFT JOIN gestcons.dico_utilisateur u ON u.id = rs.user_id
    WHERE rs.site_id = s.id AND rs.actif
  ) r ON TRUE
  WHERE s.actif AND s.type_site_id = 2
    AND NOT COALESCE(s.non_diffusion, false)
    AND NOT COALESCE(s.sensibilite, false);

COMMENT ON VIEW gestcons.v_analyses_secteurs IS
  'Onglet Analyses : un secteur d''intervention prioritaire par ligne — une zone de prospection, parcelles sans contrat repérées comme futur site conservatoire possible. Un secteur n''est pas un site : il n''a ni statut ni gestionnaire.';

COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_parcelles_manuelles IS 'parcelles à géométrie dessinée, sans référence cadastrale — elles n''ont ni commune ni propriétaire connu';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.surface_m2             IS 'somme des surfaces des parcelles du secteur, en m²';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_priorite_1          IS 'parcelles en priorité 1 (la plus urgente)';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.communes               IS 'communes couvertes par le secteur, séparées par des virgules';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.responsables           IS 'responsables EN COURS ; un secteur n''a ni animateur ni conservateur bénévole';

-- ---------------------------------------------------------------------------
-- Une ligne par couple parcelle × propriétaire — SANS AUCUN NOM
--
-- Ce que cette vue n'expose PAS, et qu'il ne faut pas y remettre : ddenom,
-- dnomus, dnomlp, dprnlp, dqualp (les noms), dlign3 à dlign6 (les adresses),
-- jdatnss et dldnss (date et lieu de naissance). Un propriétaire n'y figure
-- que par son TYPE et par une référence opaque.
--
-- `proprietaire_ref` est une empreinte de l'identifiant cadastral de la
-- personne. Elle existe parce que compter des propriétaires sans clé
-- d'identité donne un résultat faux : 262 personnes tiennent plus d'un compte
-- cadastral (jusqu'à 8), donc sommer les lignes surcompte. Elle permet aussi
-- de voir qu'un même propriétaire pèse sur plusieurs secteurs.
--
-- ⚠️ Ce que l'empreinte fait et ne fait pas : le sel est écrit ici, donc dans
-- le dépôt. Elle n'est pas une protection cryptographique contre qui
-- détiendrait à la fois ce fichier et le fichier MAJIC. Elle garantit une
-- seule chose, qui est celle qui compte ici : ce qui part vers l'API n'est
-- pas un identifiant cadastral exploitable.
--
-- Les parcelles manuelles n'ont pas de propriétaire connu : la jointure au
-- cadastre est INNER, elles sont donc simplement absentes.
--
-- Mesuré le 2026-10-27 sur le périmètre réel : 2 214 lignes de propriété,
-- 1 884 personnes distinctes, 1 359 comptes, et 0 doublon (compte, personne)
-- — usufruitier et nu-propriétaire sont toujours des personnes différentes,
-- donc une ligne vaut une personne, sans retraitement.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_proprietaires AS
  SELECT pb.id                                  AS parcelle_id,
         pe.id                                  AS site_id,
         pe.nom_site,
         pe.type_site,
         c.idpar                                AS reference_cadastrale,
         c.idcomtxt                             AS commune,
         pb.surf_parc_maitrise_m2               AS surface_m2,
         substr(md5('terracen-proprietaire:' || dp.idpersonne), 1, 10)
                                                AS proprietaire_ref,
         COALESCE(NULLIF(btrim(dp.catpro2txt), ''), 'inconnue')  AS categorie,
         COALESCE(NULLIF(btrim(dp.ccogrmtxt), ''), 'PERSONNE PHYSIQUE') AS groupe,
         COALESCE(NULLIF(btrim(dp.ccodrotxt), ''), 'inconnu')    AS droit_reel,
         btrim(dp.ccogrmtxt) IN ('ETAT', 'REGION', 'DEPARTEMENT', 'COMMUNE',
                                 'OFFICE HLM',
                                 'ETABLISSEMENTS PUBLICS OU ORGANISMES ASSIMILES')
                                                AS est_public,
         c.idcom                                AS code_insee
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  JOIN gestcons.dico_cadastre c
    ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
  JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
  WHERE pb.actif;

COMMENT ON VIEW gestcons.v_analyses_proprietaires IS
  'Onglet Analyses : une ligne par couple parcelle-propriétaire, pour les parcelles cadastrales des sites et des secteurs. AUCUN nom, aucune adresse, aucune date de naissance : un propriétaire n''y est qu''un type et une référence opaque. Une parcelle en indivision y figure autant de fois qu''elle a de propriétaires.';

COMMENT ON COLUMN gestcons.v_analyses_proprietaires.proprietaire_ref IS 'référence opaque et stable d''un propriétaire — sert à compter des propriétaires DISTINCTS et à repérer celui qui possède sur plusieurs sites ; ne désigne personne nommément';
COMMENT ON COLUMN gestcons.v_analyses_proprietaires.categorie        IS 'nature juridique : PERSONNE PHYSIQUE, COMMUNE, STRUCTURE AGRICOLE, SOCIETE CIVILE A VOCATION IMMOBILIERE, RESEAU ELECTRIQUE OU GAZ, ETAT…';
COMMENT ON COLUMN gestcons.v_analyses_proprietaires.groupe           IS 'groupe de personne morale au sens du cadastre ; PERSONNE PHYSIQUE quand la parcelle appartient à un particulier';
COMMENT ON COLUMN gestcons.v_analyses_proprietaires.droit_reel       IS 'PROPRIETAIRE, USUFRUITIER, NU-PROPRIETAIRE… — une parcelle démembrée a plusieurs lignes, une par droit';
COMMENT ON COLUMN gestcons.v_analyses_proprietaires.est_public       IS 'vrai pour l''État, une région, un département, une commune ou un établissement public';

-- ---------------------------------------------------------------------------
-- Une ligne par rôle tenu sur un site ou un secteur
--
-- ⚠️ CETTE VUE NOMME DES PERSONNES, et c'est le seul endroit du périmètre
-- interrogeable qui le fasse. Décision explicite de l'utilisateur : « des
-- infos sur les responsables, bénévoles et animateurs » n'a pas de sens sans
-- savoir de qui il s'agit.
--
-- Ce que ça recouvre, et pourquoi c'est d'une autre nature que les
-- propriétaires : 31 personnes, salariés et bénévoles du CEN, dont les noms
-- sont déjà affichés partout dans l'application, dans un onglet réservé aux
-- administrateurs. Les propriétaires, eux, sont 1 884 tiers dont l'identité
-- reste exclue — v_analyses_proprietaires ne rend que des types.
--
-- L'adresse courriel n'est PAS exposée : elle n'ajoute rien à une analyse et
-- identifie plus fortement que le nom.
--
-- Les trois rôles n'ont pas la même forme. responsable_sites et
-- conservateur_benevole portent une période (date_debut, date_fin) ;
-- animateur_sites n'a qu'un drapeau `actif`, c'est pourquoi ses dates sont
-- nulles ici — l'application elle-même se contente de désactiver ce rôle.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_roles_sites AS
  SELECT pe.id                                   AS site_id,
         pe.nom_site,
         pe.type_site,
         r.role,
         btrim(COALESCE(u.prenom, '') || ' ' || COALESCE(u.nom, '')) AS personne,
         r.actif,
         r.date_debut,
         r.date_fin
  FROM (
    SELECT site_id, user_id, 'responsable'::text AS role, actif,
           date_debut::date, date_fin::date
      FROM gestcons.responsable_sites
    UNION ALL
    SELECT site_id, user_id, 'conservateur bénévole', actif,
           date_debut::date, date_fin::date
      FROM gestcons.conservateur_benevole
    UNION ALL
    -- Pas de période pour l'animation : la table n'en porte pas.
    SELECT site_id, user_id, 'animateur', actif, NULL::date, NULL::date
      FROM gestcons.animateur_sites
  ) r
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = r.site_id
  LEFT JOIN gestcons.dico_utilisateur u ON u.id = r.user_id;

COMMENT ON VIEW gestcons.v_analyses_roles_sites IS
  'Onglet Analyses : une ligne par rôle tenu sur un site ou un secteur — responsable, conservateur bénévole ou animateur. Seule vue du périmètre qui nomme des personnes : des salariés et bénévoles du CEN, jamais des propriétaires. Contient l''historique, pas seulement les rôles en cours.';

COMMENT ON COLUMN gestcons.v_analyses_roles_sites.role       IS '« responsable », « conservateur bénévole » ou « animateur »';
COMMENT ON COLUMN gestcons.v_analyses_roles_sites.actif      IS 'vrai si le rôle est en cours ; les lignes closes sont conservées, c''est l''historique';
COMMENT ON COLUMN gestcons.v_analyses_roles_sites.date_debut IS 'début de la période ; toujours vide pour un animateur, dont la table ne porte pas de dates';
COMMENT ON COLUMN gestcons.v_analyses_roles_sites.personne   IS 'prénom et nom ; l''adresse courriel n''est pas exposée';
ALTER VIEW gestcons.v_analyses_sites       OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_secteurs    OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_roles_sites OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_sites       TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_secteurs    TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_roles_sites TO terracen_analyse;

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles — en endossant le rôle de l'onglet.
-- ---------------------------------------------------------------------------
-- BEGIN;
--   SET LOCAL ROLE terracen_analyse;
--   SELECT role, count(*), count(*) FILTER (WHERE actif) AS en_cours
--     FROM gestcons.v_analyses_roles_sites GROUP BY 1 ORDER BY 2 DESC;
--     -- attendu : responsable 230/175, animateur 57/29, bénévole 21/0
--   SELECT count(*) FROM gestcons.v_analyses_secteurs WHERE responsables IS NULL;  -- 0
--   SELECT * FROM gestcons.dico_utilisateur LIMIT 1;   -- doit ÉCHOUER
-- ROLLBACK;
