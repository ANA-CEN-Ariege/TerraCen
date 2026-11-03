-- =============================================================================
-- Analyses : tout voir, et le milieu des secteurs
-- =============================================================================
-- 1. Les vues d'Analyses n'écartent plus les sites sensibles ou non
--    diffusables : Analyses est un outil INTERNE, il voit tout (décision de
--    l'utilisateur, 2026-10-28). Le filtre retirait le site de
--    v_analyses_sites et, par v_analyses_perimetre, ses parcelles de toutes
--    les vues de détail — de quoi fausser en silence n'importe quelle somme
--    dès qu'un site serait coché. Les vues tournées vers l'extérieur
--    (v_mapcen_*) gardent leur filtre ; elles ne sont pas touchées ici.
-- 2. v_analyses_sites expose sensibilite, non_diffusion et remq_sensibilite,
--    pour que la réponse puisse signaler qu'un site est sensible.
-- 3. v_analyses_secteurs expose type_milieu, même nomenclature que celle des
--    sites.
--
-- ⚠️ Les trois blocs ci-dessous sont EXTRAITS LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas les modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée : seules trois vues sont remplacées,
-- et CREATE OR REPLACE conserve leurs droits.
-- =============================================================================

BEGIN;

-- v_analyses_perimetre d'abord : les vues de détail en dépendent, ses
-- colonnes ne changent pas.
CREATE OR REPLACE VIEW gestcons.v_analyses_perimetre AS
  SELECT s.id, s.libelle AS nom_site,
         CASE WHEN s.type_site_id = 2 THEN 'secteur' ELSE 'site' END AS type_site
  FROM gestcons.sites s
  -- Ni sensibilité ni diffusion : Analyses voit tout (cf. v_analyses_sites).
  -- Ce filtre retirait aussi les PARCELLES de tout site marqué, de toutes les
  -- vues de détail.
  WHERE s.actif AND s.type_site_id IN (1, 2);

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
  LEFT JOIN gestcons.dico_type_milieu tm ON tm.id = s.type_milieu_id
  -- Ni sensibilité ni diffusion : Analyses voit tout (cf. v_analyses_sites).
  WHERE s.actif AND s.type_site_id = 2;

COMMENT ON VIEW gestcons.v_analyses_secteurs IS
  'Onglet Analyses : un secteur d''intervention prioritaire par ligne — une zone de prospection, parcelles sans contrat repérées comme futur site conservatoire possible. Un secteur n''est pas un site : il n''a ni statut ni gestionnaire.';

COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_parcelles_manuelles IS 'parcelles à géométrie dessinée, sans référence cadastrale — elles n''ont ni commune ni propriétaire connu';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.surface_m2             IS 'somme des surfaces des parcelles du secteur, en m²';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.nb_priorite_1          IS 'parcelles en priorité 1 (la plus urgente)';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.communes               IS 'communes couvertes par le secteur, séparées par des virgules';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.responsables           IS 'responsables EN COURS ; un secteur n''a ni animateur ni conservateur bénévole';
COMMENT ON COLUMN gestcons.v_analyses_secteurs.type_milieu            IS 'type de milieu visé par le secteur (gîtes à chiroptères, tourbières et marais…) — même nomenclature que type_milieu dans v_analyses_sites, ce qui permet de comparer sites et secteurs par milieu';

-- Une vue lit avec les droits de SON propriétaire.
ALTER VIEW gestcons.v_analyses_perimetre OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_sites     OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_secteurs  OWNER TO adminsig;

-- ---------------------------------------------------------------------------
-- Contrôles
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- sites exposés, dont sensibles / non diffusables'
SELECT count(*) AS sites,
       count(*) FILTER (WHERE sensibilite)   AS sensibles,
       count(*) FILTER (WHERE non_diffusion) AS non_diffusables
  FROM gestcons.v_analyses_sites;

\echo '--- secteurs exposés, et combien ont un milieu (les deux doivent être égaux)'
SELECT count(*) AS secteurs, count(type_milieu) AS avec_milieu
  FROM gestcons.v_analyses_secteurs;

\echo '--- secteurs par milieu'
SELECT type_milieu, count(*) AS secteurs
  FROM gestcons.v_analyses_secteurs GROUP BY 1 ORDER BY 2 DESC;

COMMIT;
