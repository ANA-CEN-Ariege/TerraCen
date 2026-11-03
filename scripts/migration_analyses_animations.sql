-- =============================================================================
-- Analyses : l'animation foncière
-- =============================================================================
-- Les démarches d'animation foncière — 123 au 2026-10-29, de 2013 à 2026, dont
-- 38 cette année — étaient invisibles d'Analyses. « Combien de démarches cette
-- année, par salarié ? », « quelles parcelles de priorité 1 n'ont jamais été
-- démarchées ? » restaient sans réponse.
--
-- Deux vues, deux grains :
--   1. v_analyses_animations           — une ligne par démarche ;
--   2. v_analyses_animations_parcelles — une ligne par couple démarche-parcelle.
--
-- Restent dehors : la description des démarches, l'identité des personnes
-- contactées et le nom des pièces jointes (raisons dans le bloc ci-dessous).
--
-- ⚠️ Le bloc ci-dessous est EXTRAIT LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas le modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée : deux vues créées, rendues à adminsig,
-- et accordées au seul rôle de lecture d'Analyses.
--
-- À passer depuis le Mac, dans /Users/claude/Developpements/TerraCen :
--   set -a; eval "$(grep -E '^DB_(HOST|PORT|NAME|USER|PASSWORD)=' ~/.Renviron)"; set +a
--   PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" \
--     -v ON_ERROR_STOP=1 -f scripts/migration_analyses_animations.sql
-- =============================================================================

BEGIN;

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

ALTER VIEW gestcons.v_analyses_animations OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_animations_parcelles OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_animations TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_animations_parcelles TO terracen_analyse;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- démarches, liens démarche-parcelle, et somme des nb_parcelles (les deux derniers égaux attendus)'
SELECT (SELECT count(*)          FROM gestcons.v_analyses_animations)           AS demarches,
       (SELECT count(*)          FROM gestcons.v_analyses_animations_parcelles) AS liens,
       (SELECT sum(nb_parcelles) FROM gestcons.v_analyses_animations)           AS somme_nb_parcelles;

COMMIT;
