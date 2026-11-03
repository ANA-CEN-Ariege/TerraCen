-- =============================================================================
-- Analyses : les communes des secteurs, périmètres tracés compris
-- =============================================================================
-- v_analyses_secteurs.communes ne lisait que le cadastre : 31 des 77 secteurs
-- qui ont des parcelles — ceux dont les parcelles sont des périmètres tracés
-- à la main — n'y avaient aucune commune, alors que la v3.7 les rattache à
-- toutes celles qu'ils recouvrent (gestcons.parcelles_communes).
--
-- La liste prend désormais les communes des deux sortes de parcelles, sous
-- les noms de la couche IGN — qui ne diffèrent de ceux du cadastre que par la
-- casse et les accents, vérifié sur les 102 communes concernées. Le
-- commentaire de nb_parcelles_manuelles, qui disait au modèle que ces
-- parcelles n'ont « ni commune », est corrigé.
--
-- ⚠️ Le bloc ci-dessous est EXTRAIT LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas le modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée : la vue seule est remplacée, ses droits
-- conservés par CREATE OR REPLACE.
-- =============================================================================

BEGIN;

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

ALTER VIEW gestcons.v_analyses_secteurs OWNER TO adminsig;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- secteurs qui ont des parcelles, et combien ont une commune (égaux attendus)'
SELECT count(*) FILTER (WHERE nb_parcelles > 0)                        AS avec_parcelles,
       count(*) FILTER (WHERE nb_parcelles > 0 AND communes IS NOT NULL) AS avec_commune
  FROM gestcons.v_analyses_secteurs;

COMMIT;
