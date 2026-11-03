-- Onglet « Analyses » : schéma exposé à Claude et rôle de lecture dédié.
--
-- L'onglet laisse poser une question en français ; Claude écrit un SELECT que
-- l'application exécute. La garde n'est PAS un filtrage de la requête — ça se
-- contourne — mais ce rôle PostgreSQL, qui ne peut rien faire d'autre que lire
-- qu'une seule vue.
--
-- Ce que le rôle NE PEUT PAS faire, par construction :
--   - écrire quoi que ce soit (default_transaction_read_only) ;
--   - lire une table de gestcons : USAGE sur le schéma ne donne pas le droit
--     de lire, il faut un SELECT objet par objet, et il n'en a qu'un. Vérifié
--     en SET ROLE : « permission denied for table dico_proprietaire » ;
--   - occuper le serveur (statement_timeout).
--
-- ⚠️ CE QUI TIENT CETTE SÛRETÉ, ET QU'IL FAUT SAVOIR : le rôle a USAGE sur un
-- schéma de 74 tables et 34 vues. Il ne peut en lire aucune parce qu'aucune
-- n'accorde de SELECT à PUBLIC. Le jour où quelqu'un en accorde un, ou pose un
-- ALTER DEFAULT PRIVILEGES trop large, le périmètre de ce rôle s'élargit SANS
-- QUE RIEN NE LE SIGNALE. La première version plaçait la vue dans un schéma à
-- part pour que cette question ne se pose pas ; le repli dans gestcons est un
-- choix assumé, en échange d'un objet de moins dans la base.
--
-- Réserve à connaître : les schémas `pr_zh` (33 tables, l'application Zones
-- humides) et `public` (5 tables) sont lisibles par PUBLIC dans cette base,
-- donc par ce rôle comme par tout autre compte. La frontière protégée ici est
-- celle de gestcons et de ses données personnelles, pas celle de la base
-- entière. L'application refuse en plus toute requête qui nomme un autre
-- schéma que `analyses` — deuxième verrou, plus faible, qui ne remplace pas le
-- premier.
--
-- Modèle de rôles, à respecter pour tout objet ajouté ici :
--   adminsig          — PROPRIÉTAIRE des tables et des vues, y compris celles
--                       de l'onglet. Une vue lit avec les droits de son
--                       propriétaire : en créer une sous un autre compte la
--                       rend impossible à remplacer par les migrations
--                       suivantes. Les v_analyses_* ont appartenu à claudeg
--                       jusqu'au 2026-10-27, c'était une anomalie.
--   shiny             — l'application TerraCEN.
--   terracen_analyse  — l'onglet Analyses SEUL, en lecture, sur les seules
--                       vues qui lui sont accordées nommément plus bas.
--
-- À exécuter en superutilisateur, puis recopier EXACTEMENT le même mot de
-- passe dans le .Renviron de l'utilisateur shiny (ANALYSE_DB_PASSWORD).
-- Le script est rejouable : chaque passage repose le mot de passe.

BEGIN;

-- ---------------------------------------------------------------------------
-- analyses.sites
--
-- Projection des deux vues de gestion existantes, actifs et préfiguration,
-- qui portent exactement les mêmes colonnes. On en retire :
--   responsables_actifs, animateurs_actifs, cree_par, modifie_par  -> noms de personnes
--   geometry                                                       -> inutile en texte, et lourd
--   les identifiants externes et les URL                           -> bruit, qui coûterait des jetons
--
-- AUCUN filtre sur la sensibilité ni sur la diffusion, et c'est voulu :
-- Analyses est un outil INTERNE, il voit tout (décision de l'utilisateur,
-- 2026-10-28). Jusque-là, un site sensible ou non diffusable sortait de cette
-- vue et, par v_analyses_perimetre, toutes ses parcelles avec lui — de quoi
-- fausser en silence n'importe quelle somme. Les deux drapeaux et la remarque
-- sont au contraire EXPOSÉS, pour que la réponse puisse signaler qu'un site
-- est sensible. Ce sont les vues tournées vers l'extérieur (v_mapcen_*) qui
-- filtrent, et elles seules.
--
-- ⚠️ Comme le reste des résultats, la remarque de sensibilité part chez
-- Anthropic avec les réponses. Accepté par l'utilisateur au même titre que
-- les noms de contrats (cf. plus bas).
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
         r.responsables, r.animateurs,
         -- En queue de liste : CREATE OR REPLACE n'ajoute de colonne qu'après
         -- les existantes.
         s.sensibilite, s.non_diffusion, s.remq_sensibilite
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
  ) r ON TRUE;

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
COMMENT ON COLUMN gestcons.v_analyses_sites.sensibilite          IS 'vrai si le site a un caractère sensible (espèce ou milieu à protéger) — le signaler dans la réponse quand le site est cité';
COMMENT ON COLUMN gestcons.v_analyses_sites.non_diffusion        IS 'vrai si le site ne doit pas être diffusé hors du CEN (cartes publiques, communication) ; il reste pleinement interrogeable ici';
COMMENT ON COLUMN gestcons.v_analyses_sites.remq_sensibilite     IS 'pourquoi le site est sensible, en texte libre ; renseignée seulement quand sensibilite est vrai';

-- ---------------------------------------------------------------------------
-- Rôle de lecture
--
-- Mot de passe à remplacer AVANT exécution, puis à reporter dans le .Renviron
-- de l'utilisateur shiny. NOINHERIT : le rôle ne récupère les droits d'aucun
-- groupe, même si on l'y ajoutait par inadvertance.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'terracen_analyse') THEN
    CREATE ROLE terracen_analyse LOGIN
      NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS;
  END IF;
END $$;

-- Le mot de passe est posé ICI, hors du bloc conditionnel : rejouer le script
-- doit toujours le remettre à la valeur écrite. Dans la première version il
-- était dans le CREATE ROLE, donc ignoré dès que le rôle existait — un second
-- passage ne corrigeait rien et laissait chercher ailleurs.
--
-- Sans accent ni caractère spécial : la même chaîne devra être recopiée dans
-- le .Renviron, que R lit en substituant ${...} et en retirant les espaces de
-- fin. Un mot de passe alphanumérique évite les deux pièges.
ALTER ROLE terracen_analyse PASSWORD 'A_REMPLACER';

-- Lecture seule imposée au niveau de la session : même un UPDATE syntaxiquement
-- valide échouera avant d'écrire quoi que ce soit.
ALTER ROLE terracen_analyse SET default_transaction_read_only = on;
ALTER ROLE terracen_analyse SET statement_timeout = '8s';
ALTER ROLE terracen_analyse SET search_path = gestcons;

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
  -- Ni sensibilité ni diffusion : Analyses voit tout (cf. v_analyses_sites).
  -- Ce filtre retirait aussi les PARCELLES de tout site marqué, de toutes les
  -- vues de détail.
  WHERE s.actif AND s.type_site_id IN (1, 2);

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

-- ---------------------------------------------------------------------------
-- Une ligne par couple (parcelle, commune) — pour les sommes territoriales
-- ---------------------------------------------------------------------------
-- v_analyses_parcelles garde une ligne par parcelle : c'est ce qui permet de
-- COMPTER des parcelles. Mais un périmètre manuel peut chevaucher plusieurs
-- communes, et l'y rattacher à une seule crédite cette commune de la totalité
-- de la surface. Le Rocher de Scaramus, par exemple, fait 62,3 ha sur Caussou
-- et 59,7 sur Prades : une règle à une commune en donnerait 122 à l'une et 0 à
-- l'autre.
--
-- Cette vue-ci porte donc l'autre grain : une ligne par couple, avec la part
-- de surface qui revient à chaque commune. C'est elle qu'il faut interroger
-- dès qu'on SOMME des hectares par commune ou par EPCI — et surtout pas pour
-- compter des parcelles, qui y apparaissent plusieurs fois.
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
         k.statut, k.date_debut, k.date_fin, p.code_insee, p.siren_epci, p.epci
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
         cm.communes,
         r.responsables,
         -- En QUEUE de liste : CREATE OR REPLACE VIEW n'accepte d'ajouter une
         -- colonne qu'après les existantes. Même nomenclature que
         -- v_analyses_sites.type_milieu, vérifié identique sur les 57 sites
         -- exposés le 2026-10-28 : sites et secteurs se comparent par milieu.
         tm.libelle                AS type_milieu
  FROM gestcons.sites s
  LEFT JOIN LATERAL (
    SELECT count(*)::int                                              AS nb_parcelles,
           count(*) FILTER (WHERE pb.type_parcelle_id = 1)::int       AS nb_parcelles_cadastrales,
           count(*) FILTER (WHERE pb.type_parcelle_id <> 1)::int      AS nb_parcelles_manuelles,
           COALESCE(sum(pb.surf_parc_maitrise_m2), 0)                 AS surface_m2,
           count(*) FILTER (WHERE pb.priorite_id = 1)::int            AS nb_priorite_1,
           count(*) FILTER (WHERE pb.priorite_id = 2)::int            AS nb_priorite_2,
           count(*) FILTER (WHERE pb.priorite_id IS NULL)::int        AS nb_sans_priorite
    FROM gestcons.parcelles_base pb
    WHERE pb.site_id = s.id AND pb.actif
  ) p ON TRUE
  -- Communes du secteur : celles de ses parcelles cadastrales ET de ses
  -- périmètres tracés à la main (gestcons.parcelles_communes). Elles ne
  -- lisaient que le cadastre : 31 des 77 secteurs qui ont des parcelles
  -- n'avaient aucune commune ici (corrigé le 2026-10-28).
  --
  -- ⚠️ À part du LATERAL des comptes : jointes là, les communes
  -- multiplieraient les lignes d'un périmètre à cheval sur plusieurs
  -- communes, et fausseraient comptes et surfaces.
  -- ⚠️ Ensembliste et non par secteur : gestcons.communes couvre toute la
  -- France (34 955 lignes) sans index sur insee_com. Une sous-requête
  -- corrélée la rebalayait à chaque secteur — 2,7 s, mesuré — là où une
  -- jointure unique coûte 61 ms.
  -- Noms de la couche IGN pour toutes : ceux du cadastre ne diffèrent que
  -- par la casse et les accents (vérifié sur les 102 communes concernées), et
  -- une liste homogène se cherche d'un seul ILIKE.
  LEFT JOIN (
    SELECT x.site_id, string_agg(co.nom, ', ' ORDER BY co.nom) AS communes
      FROM (
        SELECT pb.site_id, c.idcom AS insee
          FROM gestcons.parcelles_base pb
          JOIN gestcons.dico_cadastre c
            ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
         WHERE pb.actif
        UNION
        SELECT pb.site_id, pc.insee_com
          FROM gestcons.parcelles_base pb
          JOIN gestcons.parcelles_communes pc ON pc.parcelle_id = pb.id
         WHERE pb.actif AND pb.type_parcelle_id = 2
      ) x
      JOIN gestcons.communes co ON co.insee_com = x.insee
     GROUP BY x.site_id
  ) cm ON cm.site_id = s.id
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
  LEFT JOIN gestcons.dico_type_milieu tm ON tm.id = s.type_milieu_id
  -- Ni sensibilité ni diffusion : Analyses voit tout (cf. v_analyses_sites).
  WHERE s.actif AND s.type_site_id = 2;

COMMENT ON VIEW gestcons.v_analyses_secteurs IS
  'Onglet Analyses : un secteur d''intervention prioritaire par ligne — une zone de prospection, parcelles sans contrat repérées comme futur site conservatoire possible. Un secteur n''est pas un site : il n''a ni statut ni gestionnaire.';

COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_parcelles_manuelles IS 'parcelles à géométrie dessinée, sans référence cadastrale — elles n''ont pas de propriétaire connu ; leurs communes sont celles que recouvre leur tracé';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.surface_m2             IS 'somme des surfaces des parcelles du secteur, en m²';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_priorite_1          IS 'parcelles en priorité 1 (la plus urgente)';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.communes               IS 'communes couvertes par le secteur, parcelles cadastrales ET périmètres tracés à la main, séparées par des virgules, noms de l''IGN (avec accents) — chercher une commune avec ILIKE';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.responsables           IS 'responsables EN COURS ; un secteur n''a ni animateur ni conservateur bénévole';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.type_milieu            IS 'type de milieu visé par le secteur (gîtes à chiroptères, tourbières et marais…) — même nomenclature que type_milieu dans v_analyses_sites, ce qui permet de comparer sites et secteurs par milieu';

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
         c.idcom                                AS code_insee,
         co.siren_epci,
         ep.nom                                 AS epci
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  JOIN gestcons.dico_cadastre c
    ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
  JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
  LEFT JOIN gestcons.communes co ON co.insee_com = c.idcom
  LEFT JOIN gestcons.dico_epci ep ON ep.siren = co.siren_epci
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

-- ---------------------------------------------------------------------------
-- L'animation foncière : une ligne par démarche
--
-- Les démarches que les salariés du CEN mènent auprès des propriétaires et
-- des exploitants — appel, courriel, rencontre, réunion, visite de terrain.
-- Mesuré le 2026-10-29 : 123 démarches de 2013 à 2026, dont 38 en 2026 ; 106
-- visent des parcelles (644 liens), toutes d'un seul site ou secteur à la
-- fois, et 17 n'en visent aucune (une réunion, un atelier).
--
-- Ce que la vue N'EXPOSE PAS, et pourquoi :
--   - la DESCRIPTION de la démarche. Texte libre de 2 000 caractères en
--     moyenne, jusqu'à 38 585 : des courriels collés entiers. Le résultat
--     d'une requête part tel quel dans le prompt, et quelques lignes
--     suffiraient à le remplir. Ce texte nomme en outre les personnes
--     contactées (10 démarches y portent une civilité) ;
--   - l'IDENTITÉ des personnes contactées (dico_acteurs_fonciers_agricoles) :
--     des propriétaires et des exploitants, tiers au CEN, exclus au même
--     titre que dans v_analyses_proprietaires. Seul leur nombre est rendu ;
--   - le NOM des pièces jointes, dont certains portent un patronyme. Seul
--     leur nombre est rendu.
--
-- Les SALARIÉS qui ont mené la démarche sont nommés, comme dans
-- v_analyses_roles_sites : des membres du CEN, déjà affichés partout dans
-- l'application.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_animations AS
  SELECT a.id                             AS animation_id,
         a.date                           AS date_action,
         t.libelle                        AS type_action,
         sal.salaries,
         COALESCE(sal.n, 0)               AS nb_salaries,
         COALESCE(par.n, 0)               AS nb_parcelles,
         par.sites,
         COALESCE(act.n_proprietaires, 0) AS nb_proprietaires_contactes,
         COALESCE(act.n_agriculteurs, 0)  AS nb_agriculteurs_contactes,
         COALESCE(doc.n, 0)               AS nb_documents
  FROM gestcons.animation_fonciere a
  LEFT JOIN gestcons.dico_type_action_animation t ON t.id = a.type_action_id
  LEFT JOIN LATERAL (
    SELECT string_agg(btrim(COALESCE(u.prenom, '') || ' ' || COALESCE(u.nom, '')), ', '
                      ORDER BY u.nom, u.prenom) AS salaries,
           count(*)::int                        AS n
      FROM gestcons.animation_fonciere_utilisateur au
      JOIN gestcons.dico_utilisateur u ON u.id = au.utilisateur_id
     WHERE au.animation_id = a.id
  ) sal ON TRUE
  -- Les parcelles comptées sont celles que v_analyses_animations_parcelles
  -- rend, actives et dans le périmètre : les deux vues doivent tomber juste
  -- l'une sur l'autre.
  LEFT JOIN LATERAL (
    SELECT count(*)::int                                         AS n,
           string_agg(DISTINCT pe.nom_site, ', ' ORDER BY pe.nom_site) AS sites
      FROM gestcons.animation_fonciere_parcelles ap
      JOIN gestcons.parcelles_base pb ON pb.id = ap.parcelle_id AND pb.actif
      JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
     WHERE ap.animation_id = a.id
  ) par ON TRUE
  -- dico_type_acteur : 1 = agriculteur, 2 = propriétaire.
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE ac.type_acteur_id = 2)::int AS n_proprietaires,
           count(*) FILTER (WHERE ac.type_acteur_id = 1)::int AS n_agriculteurs
      FROM gestcons.animation_fonciere_acteurs aa
      JOIN gestcons.dico_acteurs_fonciers_agricoles ac ON ac.id = aa.acteur_id
     WHERE aa.animation_id = a.id
  ) act ON TRUE
  LEFT JOIN LATERAL (
    SELECT count(*)::int AS n
      FROM gestcons.docs_animation_fonciere d
     WHERE d.animation_id = a.id
  ) doc ON TRUE;

COMMENT ON VIEW gestcons.v_analyses_animations IS
  'Onglet Analyses : une ligne par démarche d''animation foncière — appel, courriel, rencontre, réunion, visite de terrain… — menée par des salariés du CEN auprès de propriétaires ou d''exploitants. Les personnes contactées ne sont jamais nommées, seulement comptées, et le contenu des échanges n''est pas accessible. Les parcelles visées, une par ligne, sont dans v_analyses_animations_parcelles.';

COMMENT ON COLUMN gestcons.v_analyses_animations.date_action                IS 'date de la démarche';
COMMENT ON COLUMN gestcons.v_analyses_animations.type_action                IS 'Appel téléphonique, Envoi d''email, Rencontre individuelle, Réunion, Visite de terrain, Atelier…';
COMMENT ON COLUMN gestcons.v_analyses_animations.salaries                   IS 'salariés du CEN qui ont mené la démarche, prénom et nom, séparés par des virgules — pour compter PAR salarié, dépaqueter avec unnest(string_to_array(salaries, '', ''))';
COMMENT ON COLUMN gestcons.v_analyses_animations.nb_parcelles               IS 'parcelles visées ; 0 pour une démarche qui n''en vise aucune en particulier (réunion, atelier…)';
COMMENT ON COLUMN gestcons.v_analyses_animations.sites                      IS 'sites ou secteurs dont relèvent les parcelles visées, séparés par des virgules ; vide si la démarche ne vise aucune parcelle';
COMMENT ON COLUMN gestcons.v_analyses_animations.nb_proprietaires_contactes IS 'propriétaires contactés lors de la démarche — leur identité n''est pas accessible';
COMMENT ON COLUMN gestcons.v_analyses_animations.nb_agriculteurs_contactes  IS 'exploitants agricoles contactés lors de la démarche — leur identité n''est pas accessible';
COMMENT ON COLUMN gestcons.v_analyses_animations.nb_documents               IS 'pièces jointes à la démarche (compte-rendu, courrier, convention…) — leur contenu n''est pas accessible';

-- ---------------------------------------------------------------------------
-- Le lien démarche-parcelle : une ligne par couple
--
-- C'est par lui qu'une démarche se rattache à un site ou à un secteur, et
-- qu'on trouve les parcelles JAMAIS démarchées — celles de
-- v_analyses_parcelles absentes d'ici. Volontairement maigre : la commune, la
-- surface ou la priorité d'une parcelle se prennent dans v_analyses_parcelles,
-- par parcelle_id, plutôt que d'être recopiées ici avec le risque de diverger.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_animations_parcelles AS
  SELECT a.id                AS animation_id,
         a.date              AS date_action,
         t.libelle           AS type_action,
         pb.id               AS parcelle_id,
         c.idpar             AS reference_cadastrale,
         pe.id               AS site_id,
         pe.nom_site,
         pe.type_site,
         -- Même règle que v_analyses_parcelles : `perimetre` n'a pas le même
         -- sens selon le type, on ne le lit qu'à travers lui.
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END AS nature
  FROM gestcons.animation_fonciere_parcelles ap
  JOIN gestcons.animation_fonciere a ON a.id = ap.animation_id
  LEFT JOIN gestcons.dico_type_action_animation t ON t.id = a.type_action_id
  JOIN gestcons.parcelles_base pb ON pb.id = ap.parcelle_id AND pb.actif
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  LEFT JOIN gestcons.dico_cadastre c ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id;

COMMENT ON VIEW gestcons.v_analyses_animations_parcelles IS
  'Onglet Analyses : une ligne par couple démarche d''animation foncière - parcelle visée. Une démarche y figure autant de fois qu''elle vise de parcelles : compter les animation_id DISTINCTS pour compter des démarches. Pour la commune, la surface ou la priorité d''une parcelle, joindre v_analyses_parcelles sur parcelle_id ; une parcelle de v_analyses_parcelles absente d''ici n''a jamais été démarchée.';

COMMENT ON COLUMN gestcons.v_analyses_animations_parcelles.nature IS '« site » (parcelle maîtrisée, sous contrat), « continuité » (rattachée à un site, sans contrat) ou « secteur » (parcelle d''un secteur d''intervention prioritaire)';

-- ---------------------------------------------------------------------------
-- Les documents de gestion : une ligne par couple document-site
--
-- v_analyses_sites n'en donnait que le NOMBRE par site. « Quels sites n'ont
-- pas de plan de gestion en cours ? » ou « lesquels expirent avant fin 2027 ? »
-- restaient sans réponse. Mesuré le 2026-10-29 : 15 documents, 20 liens à des
-- sites, deux plans multi-sites (2 et 5 sites).
--
-- ⚠️ Le STATUT saisi ne dit pas si la période de validité est écoulée : deux
-- documents « Actif » sont échus (fin au 2025-12-31 et au 2026-03-05). D'où
-- `en_vigueur`, calculé à la date du jour, que le modèle doit préférer au
-- statut pour dire si un site est couvert.
--
-- ⚠️ `en_vigueur` est VIDE — inconnu — pour un document Actif sans date de
-- fin, et non vrai : 4 documents sont dans ce cas au 2026-10-29, dont deux
-- dont le nom annonce une période close (« PDG 2017-2022 », « Plan de
-- gestion 2018-2022 »). Les compter en vigueur aurait masqué l'échéance que
-- la saisie a oubliée ; vide, ils se signalent.
--
-- Un document rattaché à aucun site du périmètre garde une ligne, site vide.
-- Le commentaire libre n'est pas repris : 1 document sur 15 en porte un.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_documents_gestion AS
  SELECT d.id                     AS document_id,
         d.nom                    AS nom_document,
         t.libelle                AS type_document,
         st.libelle               AS statut,
         d.date_debut_validite,
         d.date_fin_validite,
         -- dico_statut_doc_gestion : 1 = Actif. Archivé ou en cours
         -- d'élaboration, un document ne s'applique pas ; Actif sans date de
         -- fin, on ne sait pas.
         CASE WHEN d.statut_id IS DISTINCT FROM 1         THEN FALSE
              WHEN d.date_debut_validite > current_date   THEN FALSE
              WHEN d.date_fin_validite IS NULL            THEN NULL
              ELSE d.date_fin_validite >= current_date END AS en_vigueur,
         me.libelle               AS methode_elaboration,
         -- dico_doc_gestion_evaluation : 1 = Oui, 2 = Non.
         CASE d.evaluation_id WHEN 1 THEN TRUE WHEN 2 THEN FALSE END AS evalue,
         v.valide_cs,
         v.date_cs                AS date_validation_cs,
         d.surf_m2                AS surface_m2,
         l.site_id,
         l.nom_site,
         l.type_site,
         COALESCE(n.nb_sites, 0)  AS nb_sites
  FROM gestcons.doc_gestion d
  LEFT JOIN gestcons.dico_type_doc_gestion t ON t.id = d.type_doc_gestion_id
  LEFT JOIN gestcons.dico_statut_doc_gestion st ON st.id = d.statut_id
  LEFT JOIN gestcons.dico_methode_elaboration_doc_gestion me
         ON me.id = d.methode_elaboration_doc_gestion_id
  LEFT JOIN gestcons.validation_cs v ON v.doc_gestion_id = d.id
  -- Les liens filtrés AVANT la jointure : un lien vers un site hors
  -- périmètre ne doit pas produire une ligne au site vide à côté des autres.
  LEFT JOIN (
    SELECT ds.doc_gestion_id, pe.id AS site_id, pe.nom_site, pe.type_site
      FROM gestcons.docs_gestion_sites ds
      JOIN gestcons.v_analyses_perimetre pe ON pe.id = ds.site_id
  ) l ON l.doc_gestion_id = d.id
  LEFT JOIN (
    SELECT ds.doc_gestion_id, count(*)::int AS nb_sites
      FROM gestcons.docs_gestion_sites ds
      JOIN gestcons.v_analyses_perimetre pe ON pe.id = ds.site_id
     GROUP BY ds.doc_gestion_id
  ) n ON n.doc_gestion_id = d.id
  WHERE d.actif;

COMMENT ON VIEW gestcons.v_analyses_documents_gestion IS
  'Onglet Analyses : une ligne par couple document de gestion - site couvert. Un plan de gestion multi-sites y figure une fois par site : compter les document_id DISTINCTS pour compter des documents. Un site de v_analyses_sites absent d''ici n''a aucun document de gestion enregistré.';

COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.type_document       IS 'Plan de gestion, Notice de gestion, Plan de gestion multi-sites ou Document de gestion synthétique';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.statut              IS 'Actif, Archivé ou En cours d''élaboration — le statut SAISI, qui ne dit pas si la période de validité est écoulée : pour savoir si un document s''applique aujourd''hui, lire en_vigueur';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.date_fin_validite   IS 'fin de la période de validité ; vide quand aucune échéance n''est saisie, ce qui rend en_vigueur inconnu';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.en_vigueur          IS 'vrai si le document est Actif ET que la date du jour tombe dans sa période de validité ; faux s''il est archivé, en élaboration, pas encore commencé ou échu (un document Actif dont la fin est passée est échu) ; VIDE s''il est Actif sans date de fin saisie — validité inconnue, à signaler comme telle plutôt qu''à compter d''un côté ou de l''autre';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.methode_elaboration IS 'méthode CTT88 ou autre méthode';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.evalue              IS 'vrai si le document a fait l''objet d''une évaluation';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.valide_cs           IS 'validation par le conseil scientifique ; vide quand rien n''est saisi';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.surface_m2          IS 'surface couverte par le document, en m², quand elle est saisie';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.site_id             IS 'site couvert ; vide si le document n''est rattaché à aucun site';
COMMENT ON COLUMN gestcons.v_analyses_documents_gestion.nb_sites            IS 'nombre de sites que couvre le document';

-- ---------------------------------------------------------------------------
-- Le référentiel des communes : une ligne par commune de l'Ariège
--
-- Les autres vues ne connaissent que les communes où le CEN a des parcelles
-- (102 au 2026-10-27). « Quelles communes n'ont aucun site ? », ou une surface
-- maîtrisée rapportée à la population ou à la surface communale, étaient
-- donc sans réponse : il manquait les 327, et leurs attributs.
--
-- Source : gestcons.communes (IGN ADMIN EXPRESS, Lambert-93), qui couvre
-- toute la France — 34 955 lignes et 125 Mo de contours, sans index sur
-- insee_dep ni insee_com : chaque lecture est un balayage complet.
--
-- ⚠️ D'où la CTE MATÉRIALISÉE, qui n'est pas une coquetterie. Première
-- version, mesurée le 2026-10-29 : l'arrondissement venait d'une sous-requête
-- sur gestcons.communes, et joindre la vue à v_analyses_parcelles_communes
-- prenait 72 s. Le planificateur estimait la jointure à UNE ligne — le
-- `type_site` calculé par CASE dans v_analyses_perimetre ne s'estime pas — et
-- rebalayait la table entière pour chaque commune. Matérialisée, la lecture a
-- lieu une fois par requête quel que soit le plan, et l'arrondissement se
-- tire des 327 lignes déjà lues, par une fenêtre.
--
-- L'arrondissement est désigné par sa commune chef-lieu, celle qui porte le
-- statut de préfecture ou de sous-préfecture : la couche n'a que son code
-- (1, 2, 3), que personne ne cite. Pas de canton : seul son code existe.
--
-- Volontairement SANS compte de sites ni de parcelles : ceux-ci se tirent des
-- vues de détail par code_insee, et une seconde façon de les compter finirait
-- par donner un second résultat. Le commentaire de la vue dit au modèle de
-- les tirer par jointure : une sous-requête corrélée sur v_analyses_parcelles,
-- réévaluée pour 114 communes, a dépassé les 8 s à l'essai — là où la
-- jointure équivalente prend 0,7 s.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_communes AS
  WITH ariege AS MATERIALIZED (
    SELECT insee_com, nom, population, siren_epci, insee_arr, statut,
           round(ST_Area(geometry)::numeric) AS surface_m2
      FROM gestcons.communes
     WHERE insee_dep = '09'
  )
  SELECT co.insee_com::varchar(5)               AS code_insee,
         co.nom                                 AS commune,
         co.population,
         co.surface_m2                          AS surface_commune_m2,
         co.siren_epci::varchar(20)             AS siren_epci,
         ep.nom                                 AS epci,
         max(co.nom) FILTER (WHERE co.statut IN ('Préfecture', 'Sous-préfecture'))
           OVER (PARTITION BY co.insee_arr)     AS arrondissement
  FROM ariege co
  LEFT JOIN gestcons.dico_epci ep ON ep.siren = co.siren_epci;

COMMENT ON VIEW gestcons.v_analyses_communes IS
  'Onglet Analyses : une ligne par commune de l''Ariège — les 327, qu''elles portent ou non un site, une continuité ou un secteur. Pour trouver les communes SANS site, partir d''ici et écarter les code_insee présents dans v_analyses_parcelles_communes (en filtrant nature ou type_site selon la question). Pour rapporter une surface maîtrisée à la population ou à la surface de la commune, joindre sur code_insee. Pour compter ou sommer PAR commune, écrire une jointure suivie d''un GROUP BY, jamais une sous-requête par commune : les vues de parcelles sont lourdes, et les réévaluer pour chacune des 327 communes dépasse le délai de 8 s.';

COMMENT ON COLUMN gestcons.v_analyses_communes.code_insee         IS 'code INSEE de la commune — clé de jointure avec les autres vues, et à renvoyer avec le libellé : c''est lui qui permet d''exporter la couche des communes';
COMMENT ON COLUMN gestcons.v_analyses_communes.commune            IS 'nom officiel de la commune (IGN), avec accents';
COMMENT ON COLUMN gestcons.v_analyses_communes.population         IS 'population municipale, selon la couche IGN ADMIN EXPRESS de la base';
COMMENT ON COLUMN gestcons.v_analyses_communes.surface_commune_m2 IS 'surface TOTALE de la commune, en m², calculée sur son contour — à ne pas confondre avec une surface maîtrisée';
COMMENT ON COLUMN gestcons.v_analyses_communes.siren_epci         IS 'SIREN de l''intercommunalité — à renvoyer avec son nom dès que la question porte sur les communautés de communes, c''est lui qui permet d''en exporter la couche';
COMMENT ON COLUMN gestcons.v_analyses_communes.epci               IS 'nom de l''intercommunalité (communauté de communes ou d''agglomération)';
COMMENT ON COLUMN gestcons.v_analyses_communes.arrondissement     IS 'arrondissement, désigné par sa commune chef-lieu : Foix, Pamiers ou Saint-Girons';

-- ---------------------------------------------------------------------------
-- Les zonages réglementaires : un calcul fait d'avance, et deux vues
--
-- ZNIEFF 1 et 2, Natura 2000 (ZSC, ZPS), APPB, réserves : 140 zonages, dans
-- gestcons.dico_protection. Les croiser avec les 6 700 parcelles prend de
-- 4,5 s (zonages découpés à 256 sommets) à 28 s (sans découpage), mesuré le
-- 2026-10-29 : trop près du délai de 8 s du rôle de lecture, et à refaire à
-- chaque requête. Le croisement est donc fait D'AVANCE, dans une vue
-- matérialisée que deux vues ordinaires présentent.
--
-- ⚠️ gestcons.vm_parcelles_protection, qui existait déjà, ne convient pas :
-- bâtie sur la vue de compatibilité gestcons.parcelles, elle ne couvre que
-- les parcelles contractuelles du cadastre — ni continuités, ni secteurs, ni
-- périmètres tracés — et n'a plus été recalculée depuis le 2026-08-04. Elle
-- sert l'export FCEN, on n'y touche pas ici.
--
-- ⚠️ Une vue matérialisée sans rafraîchissement prévu, c'est
-- vm_parcelles_protection : trois mois de retard sans que rien ne le dise.
-- Celle-ci se rafraîchit par gestcons.rafraichir_zonages_analyses(), que
-- l'onglet appelle avant chaque question. La fonction ne recalcule que si une
-- parcelle a changé depuis le dernier calcul — le journal d'audit le dit —
-- ou si ce calcul a plus de 7 jours : les zonages eux-mêmes ne sont pas
-- audités, d'où ce plafond. Les vues portent la date du calcul.
--
-- ⚠️ NE JAMAIS ADDITIONNER les surfaces de zonages de TYPES différents : ZSC
-- et ZPS se recouvrent, ZNIEFF 1 et 2 aussi. Mesuré sur nos parcelles : 5 508
-- ha en sommant ZSC et ZPS, 3 626 ha en réalité. D'où les unions par famille,
-- calculées ici sans double compte, et exposées par parcelle. Deux zonages
-- d'un MÊME type, eux, ne se recouvrent pas — ils ne font que se toucher,
-- vérifié — et se somment sans risque.
--
-- Les surfaces sont des PARTS de la surface géométrique, appliquées dans les
-- vues à surf_parc_maitrise_m2 : la surface que toutes les autres vues
-- somment. Une surface zonée se rapporte ainsi à la même base que le reste.
-- ---------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS gestcons.vm_analyses_zonages AS
  WITH morceaux_zonage AS MATERIALIZED (
    -- Découpés à 256 sommets : une ZNIEFF de type 2 en compte des milliers,
    -- et chaque intersection les reparcourrait tous.
    SELECT d.id AS zonage_id,
           CASE WHEN d.type LIKE 'Natura 2000%' THEN 'natura2000'
                WHEN d.type LIKE 'ZNIEFF%'      THEN 'znieff' END AS famille,
           ST_Subdivide(d.geometrie, 256) AS g
      FROM gestcons.dico_protection d
  ), parcelles AS MATERIALIZED (
    SELECT pb.id AS parcelle_id,
           COALESCE(c.geompar, ST_MakeValid(pm.geometrie)) AS geom
      FROM gestcons.parcelles_base pb
      LEFT JOIN gestcons.dico_cadastre c
             ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
      LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
             ON pb.type_parcelle_id = 2 AND pm.id = pb.parcellaire_id
     WHERE pb.actif
  ), morceaux AS MATERIALIZED (
    SELECT p.parcelle_id, z.zonage_id, z.famille,
           ST_Area(p.geom)              AS surface_geo_m2,
           ST_Intersection(p.geom, z.g) AS g
      FROM parcelles p
      JOIN morceaux_zonage z ON ST_Intersects(p.geom, z.g)
  ), unions AS (
    -- Par parcelle, l'union des morceaux de chaque famille : c'est ce qui
    -- retire le recouvrement ZSC/ZPS ou ZNIEFF 1/2.
    SELECT parcelle_id,
           ST_Area(ST_Union(g) FILTER (WHERE famille = 'natura2000')) AS natura2000_m2,
           ST_Area(ST_Union(g) FILTER (WHERE famille = 'znieff'))     AS znieff_m2,
           ST_Area(ST_Union(g))                                       AS zonee_m2
      FROM morceaux
     GROUP BY parcelle_id
  )
  SELECT m.parcelle_id,
         m.zonage_id,
         -- Bornées à 1 contre les arrondis du calcul géométrique.
         LEAST(sum(ST_Area(m.g)) / NULLIF(max(m.surface_geo_m2), 0), 1)                   AS part,
         LEAST(COALESCE(max(u.natura2000_m2), 0) / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_natura2000,
         LEAST(COALESCE(max(u.znieff_m2), 0)     / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_znieff,
         LEAST(COALESCE(max(u.zonee_m2), 0)      / NULLIF(max(m.surface_geo_m2), 0), 1) AS part_parcelle_zonee,
         now()                                                                           AS calcule_le
    FROM morceaux m
    JOIN unions u USING (parcelle_id)
   GROUP BY m.parcelle_id, m.zonage_id
  -- Même seuil que l'export FCEN : sous 10 m², c'est l'écart entre deux
  -- dessins d'une même limite, pas une parcelle dans un zonage.
  HAVING sum(ST_Area(m.g)) > 10;

-- REFRESH ... CONCURRENTLY l'exige, et c'est lui qui laisse lire la vue
-- pendant le calcul : sans lui, une question posée à ce moment attendrait.
CREATE UNIQUE INDEX IF NOT EXISTS vm_analyses_zonages_cle
  ON gestcons.vm_analyses_zonages (parcelle_id, zonage_id);

ALTER MATERIALIZED VIEW gestcons.vm_analyses_zonages OWNER TO adminsig;

-- SECURITY DEFINER : rafraîchir une vue matérialisée est réservé à son
-- propriétaire, et l'application n'est pas adminsig. Elle n'a le droit
-- d'exécuter que cette fonction, qui ne fait que ça.
CREATE OR REPLACE FUNCTION gestcons.rafraichir_zonages_analyses(forcer boolean DEFAULT false)
  RETURNS text
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE
  calcule timestamptz;
  modifie timestamptz;
BEGIN
  -- Un seul calcul à la fois : de deux questions simultanées, la seconde part
  -- avec les données en place au lieu d'attendre.
  IF NOT pg_try_advisory_xact_lock(hashtext('gestcons.vm_analyses_zonages')) THEN
    RETURN 'en_cours';
  END IF;
  SELECT z.calcule_le INTO calcule FROM gestcons.vm_analyses_zonages z LIMIT 1;
  SELECT max(a.changed_at) INTO modifie
    FROM gestcons.audit_log a
   WHERE a.table_name IN ('parcelles_base', 'perimetre_parcellaire_manuel');
  -- La minute de marge couvre une modification en vol pendant le dernier
  -- calcul : horodatée avant lui, validée après.
  IF NOT forcer
     AND calcule IS NOT NULL
     AND calcule - interval '1 minute' >= COALESCE(modifie, '-infinity'::timestamptz)
     AND calcule > now() - interval '7 days' THEN
    RETURN 'a_jour';
  END IF;
  REFRESH MATERIALIZED VIEW CONCURRENTLY gestcons.vm_analyses_zonages;
  RETURN 'recalcule';
END
$fn$;

ALTER FUNCTION gestcons.rafraichir_zonages_analyses(boolean) OWNER TO adminsig;
REVOKE ALL ON FUNCTION gestcons.rafraichir_zonages_analyses(boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gestcons.rafraichir_zonages_analyses(boolean) TO shiny;

-- ---------------------------------------------------------------------------
-- Une ligne par couple parcelle-zonage : QUELS zonages
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_zonages AS
  SELECT z.parcelle_id,
         c.idpar                         AS reference_cadastrale,
         pe.id                           AS site_id,
         pe.nom_site,
         pe.type_site,
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END            AS nature,
         d.id                            AS zonage_id,
         d.type                          AS type_zonage,
         d.libelle                       AS nom_zonage,
         d.id_mnhn                       AS code_zonage,
         round(pb.surf_parc_maitrise_m2 * z.part::numeric) AS surface_zonee_m2,
         round(z.part::numeric, 3)       AS part_de_la_parcelle,
         z.calcule_le
  FROM gestcons.vm_analyses_zonages z
  JOIN gestcons.parcelles_base pb ON pb.id = z.parcelle_id AND pb.actif
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  JOIN gestcons.dico_protection d ON d.id = z.zonage_id
  LEFT JOIN gestcons.dico_cadastre c ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id;

COMMENT ON VIEW gestcons.v_analyses_zonages IS
  'Onglet Analyses : une ligne par couple parcelle - zonage réglementaire qu''elle recoupe (ZNIEFF, Natura 2000, APPB, réserves) ; une parcelle hors de tout zonage n''y figure pas. Les surfaces d''un MÊME type de zonage se somment ; celles de types DIFFÉRENTS jamais, car ils se recouvrent (ZSC et ZPS, ZNIEFF 1 et 2) : pour une surface en Natura 2000, en ZNIEFF ou dans au moins un zonage, prendre v_analyses_surfaces_zonees. Recoupements calculés d''avance, à la date de calcule_le.';

COMMENT ON COLUMN gestcons.v_analyses_zonages.type_zonage         IS 'ZNIEFF1 et ZNIEFF2 (zones naturelles d''intérêt écologique, faunistique et floristique de type 1 et 2), Natura 2000 - ZSC (directive Habitats), Natura 2000 - ZPS (directive Oiseaux), APPB (arrêté préfectoral de protection de biotope), RNR (réserve naturelle régionale), RBD (réserve biologique dirigée), RNCFS (réserve nationale de chasse et de faune sauvage)';
COMMENT ON COLUMN gestcons.v_analyses_zonages.nom_zonage          IS 'nom officiel du zonage';
COMMENT ON COLUMN gestcons.v_analyses_zonages.code_zonage         IS 'identifiant national du zonage à l''INPN (FR7312003, 730030551…)';
COMMENT ON COLUMN gestcons.v_analyses_zonages.surface_zonee_m2    IS 'surface de la parcelle située dans CE zonage, en m² — rapportée à surface_m2 de v_analyses_parcelles';
COMMENT ON COLUMN gestcons.v_analyses_zonages.part_de_la_parcelle IS 'fraction de la parcelle dans ce zonage, de 0 à 1';
COMMENT ON COLUMN gestcons.v_analyses_zonages.calcule_le          IS 'date du calcul des recoupements, refait automatiquement quand des parcelles changent';

-- ---------------------------------------------------------------------------
-- Une ligne par parcelle : COMBIEN, sans double compte
--
-- TOUTES les parcelles, y compris hors zonage (surfaces à 0) : une part du
-- total se calcule donc ici sans jointure, et sans le piège d'un
-- dénominateur qui ne compterait que les parcelles zonées.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_surfaces_zonees AS
  SELECT pb.id                           AS parcelle_id,
         pe.id                           AS site_id,
         pe.nom_site,
         pe.type_site,
         CASE WHEN pe.type_site = 'secteur' THEN 'secteur'
              WHEN pb.perimetre             THEN 'continuité'
              ELSE 'site' END            AS nature,
         pb.surf_parc_maitrise_m2        AS surface_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_natura2000, 0)::numeric) AS surface_natura2000_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_znieff, 0)::numeric)     AS surface_znieff_m2,
         round(pb.surf_parc_maitrise_m2 * COALESCE(s.part_zonee, 0)::numeric)      AS surface_zonee_m2,
         s.zonages,
         k.calcule_le
  FROM gestcons.parcelles_base pb
  JOIN gestcons.v_analyses_perimetre pe ON pe.id = pb.site_id
  LEFT JOIN (
    SELECT z.parcelle_id,
           max(z.part_parcelle_natura2000)                   AS part_natura2000,
           max(z.part_parcelle_znieff)                       AS part_znieff,
           max(z.part_parcelle_zonee)                        AS part_zonee,
           string_agg(DISTINCT d.type, ', ' ORDER BY d.type) AS zonages
      FROM gestcons.vm_analyses_zonages z
      JOIN gestcons.dico_protection d ON d.id = z.zonage_id
     GROUP BY z.parcelle_id
  ) s ON s.parcelle_id = pb.id
  CROSS JOIN (SELECT max(calcule_le) AS calcule_le FROM gestcons.vm_analyses_zonages) k
  WHERE pb.actif;

COMMENT ON VIEW gestcons.v_analyses_surfaces_zonees IS
  'Onglet Analyses : une ligne par parcelle — TOUTES, même hors zonage — avec sa surface en Natura 2000, en ZNIEFF et dans au moins un zonage, calculées SANS double compte (ZSC et ZPS, ZNIEFF 1 et 2 se recouvrent). C''est la vue à sommer pour une surface en Natura 2000, en ZNIEFF ou zonée, et pour une part du total : sum(surface_natura2000_m2) / sum(surface_m2). Le détail zonage par zonage, avec les noms, est dans v_analyses_zonages.';

COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_m2            IS 'surface de la parcelle, en m² — la même que surface_m2 de v_analyses_parcelles';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_natura2000_m2 IS 'surface de la parcelle en Natura 2000, ZSC et ZPS réunies sans double compte ; 0 hors Natura 2000';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_znieff_m2     IS 'surface de la parcelle en ZNIEFF, types 1 et 2 réunis sans double compte ; 0 hors ZNIEFF';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.surface_zonee_m2      IS 'surface de la parcelle dans AU MOINS UN zonage, tous types réunis sans double compte ; 0 si elle n''en recoupe aucun';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.zonages               IS 'types de zonages recoupés, séparés par des virgules ; vide si aucun';
COMMENT ON COLUMN gestcons.v_analyses_surfaces_zonees.calcule_le            IS 'date du calcul des recoupements, refait automatiquement quand des parcelles changent';

-- Les droits, en UNE seule liste. Elle était écrite deux fois, ce qui est le
-- meilleur moyen d'ajouter une vue à l'une et de l'oublier dans l'autre.
GRANT USAGE  ON SCHEMA gestcons                            TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_sites                  TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_secteurs               TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles              TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles_communes     TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_proprietaires          TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_roles_sites            TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_contrats               TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles_contrats     TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_animations             TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_animations_parcelles   TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_documents_gestion      TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_communes               TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_zonages                TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_surfaces_zonees        TO terracen_analyse;
-- vm_analyses_zonages reste INTERNE, comme v_analyses_perimetre : les deux
-- vues ci-dessus la lisent avec les droits de leur propriétaire.
-- v_analyses_perimetre reste INTERNE : elle ne sert qu'à bâtir les autres, qui
-- s'exécutent avec les droits de leur propriétaire. Pas de GRANT, pas de place
-- perdue dans le prompt.

-- ⚠️ Ne JAMAIS poser d'ALTER DEFAULT PRIVILEGES pour ce rôle dans gestcons :
-- il lui ouvrirait toutes les tables à venir du schéma. Chaque vue ajoutée à
-- l'onglet se accorde une par une, à la main, juste au-dessus.

-- Repli de la première version, qui plaçait la vue dans un schéma « analyses ».
DROP VIEW   IF EXISTS analyses.sites;
DROP SCHEMA IF EXISTS analyses;

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles — à passer après le COMMIT, en superutilisateur.
-- `claudeg` étant superutilisateur, un SELECT direct ne prouve rien : il faut
-- endosser le rôle pour éprouver ses droits.
-- ---------------------------------------------------------------------------
-- BEGIN;
--   SET LOCAL ROLE terracen_analyse;
--   SELECT count(*) FROM gestcons.v_analyses_sites;     -- sites SEULS, sans les secteurs
--   SELECT count(*) FROM gestcons.v_analyses_secteurs;  -- secteurs (113 au 2026-10-27)
--   SELECT * FROM gestcons.dico_proprietaire LIMIT 1;   -- doit échouer : permission denied
--   SELECT * FROM gestcons.sites LIMIT 1;               -- doit échouer : permission denied
-- ROLLBACK;
