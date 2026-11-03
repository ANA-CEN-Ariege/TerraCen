-- Migration — onglet « Analyses » : le code INSEE, pour exporter une couche
-- communale.
--
-- « Donne-moi la liste des communes concernées par les sites » ne proposait
-- aucun export : les vues ne portent la commune que comme un LIBELLÉ texte,
-- et l'export a besoin d'une clé qui se raccorde à une géométrie. Or
-- gestcons.communes (IGN ADMIN-EXPRESS, 34 955 communes, Lambert-93) existe
-- déjà dans la base. Apparié sans perte le 2026-10-27 : 102 communes
-- concernées par les sites et secteurs, 102 retrouvées, 0 orpheline.
--
-- code_insee est donc ajouté PARTOUT où `commune` figure déjà :
-- v_analyses_parcelles, v_analyses_parcelles_contrats, v_analyses_proprietaires.
-- En fin de liste de colonnes, parce que CREATE OR REPLACE VIEW n'autorise
-- que l'ajout en queue, jamais le réordonnancement.
--
-- gestcons.communes n'est PAS accordée à terracen_analyse : l'onglet n'en a
-- pas besoin, c'est l'application qui va y chercher la géométrie au moment
-- de l'export, avec ses propres droits.
--
-- À exécuter sous adminsig :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/migration_analyses_communes.sql
--
-- ⚠️ Ne PAS rejouer analyse_role_lecture.sql (ALTER ROLE ... PASSWORD). Les
-- blocs ci-dessous en sont extraits à l'identique.

BEGIN;

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
         c.idcom                            AS code_insee
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
COMMENT ON COLUMN gestcons.v_analyses_parcelles.nb_proprietaires IS 'nombre de propriétaires DISTINCTS de la parcelle ; NULL sur une parcelle manuelle, dont le propriétaire est inconnu faute de référence cadastrale — ce n''est pas zéro';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.en_indivision    IS 'vrai si la parcelle a plus d''un propriétaire';
COMMENT ON COLUMN gestcons.v_analyses_parcelles.code_insee       IS 'code INSEE de la commune — à renvoyer avec le libellé dès que la question porte sur les communes, c''est lui qui permet d''en exporter la couche';

-- ---------------------------------------------------------------------------
-- Le lien parcelle ↔ contrat : c'est lui qui manquait le plus
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW gestcons.v_analyses_parcelles_contrats AS
  SELECT p.parcelle_id, p.site_id, p.nom_site, p.nature, p.type_parcelle,
         p.reference_cadastrale, p.commune, p.surface_m2,
         k.type_contrat, k.contrat_id, k.nom_contrat, k.nature_contrat,
         k.statut, k.date_debut, k.date_fin, p.code_insee
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
ALTER VIEW gestcons.v_analyses_parcelles           OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_parcelles_contrats  OWNER TO adminsig;
ALTER VIEW gestcons.v_analyses_proprietaires       OWNER TO adminsig;

GRANT SELECT ON gestcons.v_analyses_parcelles           TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_parcelles_contrats  TO terracen_analyse;
GRANT SELECT ON gestcons.v_analyses_proprietaires       TO terracen_analyse;

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôles — après le COMMIT, en endossant le rôle de l'onglet.
-- ---------------------------------------------------------------------------
-- BEGIN;
--   SET LOCAL ROLE terracen_analyse;
--   SELECT count(DISTINCT code_insee) FROM gestcons.v_analyses_parcelles;  -- 102
--   SELECT count(*) FROM gestcons.v_analyses_parcelles WHERE code_insee IS NULL;
--     -- attendu : 41, les parcelles manuelles, sans référence cadastrale
--   SELECT * FROM gestcons.communes LIMIT 1;   -- doit ÉCHOUER : non accordée
-- ROLLBACK;
