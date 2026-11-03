-- Migration — journal des questions : garder le MOTIF de l'échec.
--
-- POURQUOI. La table enregistrait qu'une question avait échoué, jamais
-- pourquoi. Le 2026-10-28, une question restée sans réponse en production n'a
-- pas pu être diagnostiquée depuis les traces : il a fallu la rejouer contre
-- l'API, donc la repayer, pour découvrir qu'il lui manquait une donnée — la
-- notion d'intercommunalité, ajoutée deux heures plus tard.
--
-- Le message est celui que l'onglet affiche à l'utilisateur : « Pas de
-- réponse après N allers-retours », une erreur SQL remontée, un refus des
-- garde-fous du modèle. Tronqué à 500 caractères, ce qui suffit à trier.
--
-- À exécuter sous adminsig :
--   psql -h <hote> -U adminsig -d anaweb -f scripts/migration_analyses_questions_erreur.sql
-- Rejouable : ADD COLUMN IF NOT EXISTS.

BEGIN;

ALTER TABLE gestcons.analyses_questions
  ADD COLUMN IF NOT EXISTS message_erreur VARCHAR(500);

COMMENT ON COLUMN gestcons.analyses_questions.message_erreur IS
  'Motif de l''échec, tel que l''onglet l''a affiché ; NULL quand la question a abouti.';

COMMIT;

-- ---------------------------------------------------------------------------
-- Contrôle
-- ---------------------------------------------------------------------------
-- Les questions en échec, avec leur motif :
--   SELECT date_question::timestamp(0), pose_par, nb_requetes, message_erreur
--     FROM gestcons.analyses_questions WHERE erreur ORDER BY id DESC;
--   -- les lignes antérieures à cette migration ont un motif vide : il n'a
--   -- jamais été enregistré, ce n'est pas une perte.
