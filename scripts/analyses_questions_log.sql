-- Journal des questions posées dans l'onglet Analyses.
--
-- POURQUOI UNE TABLE : `log_action()` n'écrit que dans le journal texte de
-- shiny-server, via message(). Rien n'y est interrogeable, donc l'onglet
-- Activité ne pouvait pas compter les questions. C'est la seule raison d'être
-- de cette table : rendre la métrique possible.
--
-- CE QU'ELLE NE CONTIENT PAS : le texte de la question. L'onglet Activité
-- compte, il ne relit pas. Ajouter la question serait une autre décision, à
-- prendre pour elle-même — il suffirait d'une colonne de plus.
--
-- Les jetons et le coût y figurent parce qu'ils sont déjà sous la main au
-- moment d'écrire la ligne, et qu'ils répondent d'avance à la question du
-- suivi de la dépense, restée ouverte faute d'un point d'API qui rende le
-- solde d'un abonnement.
--
-- Comme analyses_notes, la table vit dans gestcons et non dans un schéma à
-- part : c'est l'application qui l'écrit, sous l'utilisateur shiny, et le
-- rôle de lecture de l'onglet n'a aucune raison de la voir — Claude ne
-- l'interroge pas.
--
-- À exécuter sous adminsig, propriétaire du schéma :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/analyses_questions_log.sql
-- Rejouable sans effet de bord.

BEGIN;

CREATE TABLE IF NOT EXISTS gestcons.analyses_questions (
  id             SERIAL PRIMARY KEY,
  date_question  TIMESTAMPTZ NOT NULL DEFAULT now(),
  pose_par       VARCHAR,
  modele         VARCHAR,
  nb_requetes    INTEGER NOT NULL DEFAULT 0,
  jetons_entree  INTEGER,
  jetons_sortie  INTEGER,
  cout_usd       NUMERIC(12,6),
  erreur         BOOLEAN NOT NULL DEFAULT FALSE
);

COMMENT ON TABLE  gestcons.analyses_questions              IS 'Une ligne par question posée dans l''onglet Analyses. Sert à compter l''usage dans l''onglet Activité ; ne conserve pas le texte des questions.';
COMMENT ON COLUMN gestcons.analyses_questions.nb_requetes  IS 'nombre de requêtes SQL que le modèle a exécutées pour répondre';
COMMENT ON COLUMN gestcons.analyses_questions.cout_usd     IS 'coût de la question en dollars, calculé au barème du modèle employé';
COMMENT ON COLUMN gestcons.analyses_questions.erreur       IS 'vrai si la question n''a pas abouti — la ligne est écrite dans tous les cas, sans quoi le compte ne refléterait que les succès';

-- Mêmes droits que les autres tables de l'onglet. Le rôle terracen_analyse
-- n'en reçoit AUCUN : cette table n'est pas une donnée à interroger.
ALTER TABLE gestcons.analyses_questions OWNER TO adminsig;
GRANT SELECT, INSERT ON gestcons.analyses_questions TO shiny;
GRANT SELECT, INSERT ON gestcons.analyses_questions TO claudeg;
GRANT USAGE, SELECT ON SEQUENCE gestcons.analyses_questions_id_seq TO shiny;
GRANT USAGE, SELECT ON SEQUENCE gestcons.analyses_questions_id_seq TO claudeg;

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
-- SELECT count(*) FROM gestcons.analyses_questions;   -- 0 au départ : le
--   compte démarre à la mise en service, il n'y a pas d'historique à rattraper.
