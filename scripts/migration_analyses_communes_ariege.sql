-- =============================================================================
-- Analyses : le référentiel des communes de l'Ariège
-- =============================================================================
-- Les vues d'Analyses ne connaissaient que les communes où le CEN a des
-- parcelles. « Quelles communes n'ont aucun site ? » était sans réponse, faute
-- des autres ; et rien ne permettait de rapporter une surface maîtrisée à la
-- population ou à la surface d'une commune.
--
-- Une vue, v_analyses_communes : les 327 communes de l'Ariège, avec leur
-- population, leur surface, leur intercommunalité et leur arrondissement.
--
-- ⚠️ Le bloc ci-dessous est EXTRAIT LITTÉRALEMENT de
-- scripts/analyse_role_lecture.sql, qu'on ne rejoue JAMAIS (il repose le mot
-- de passe du rôle). Ne pas le modifier ici : modifier la référence, puis
-- réextraire.
--
-- Aucune table ni contrainte touchée : une vue créée, rendue à adminsig, et
-- accordée au seul rôle de lecture d'Analyses.
--
-- À passer depuis le Mac, dans /Users/claude/Developpements/TerraCen :
--   set -a; eval "$(grep -E '^DB_(HOST|PORT|NAME|USER|PASSWORD)=' ~/.Renviron)"; set +a
--   PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" -d "$DB_NAME" \
--     -v ON_ERROR_STOP=1 -f scripts/migration_analyses_communes_ariege.sql
-- =============================================================================

BEGIN;

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

ALTER VIEW gestcons.v_analyses_communes OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_communes TO terracen_analyse;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
\echo ''
\echo '--- communes (327), sans intercommunalité ni arrondissement (0 attendu), population et surface totales'
SELECT count(*)                                       AS communes,
       count(*) FILTER (WHERE epci IS NULL)           AS sans_epci,
       count(*) FILTER (WHERE arrondissement IS NULL) AS sans_arrondissement,
       sum(population)                                AS population,
       round(sum(surface_commune_m2) / 1e6)           AS km2
  FROM gestcons.v_analyses_communes;

COMMIT;
