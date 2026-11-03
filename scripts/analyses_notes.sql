-- Mémoire de l'onglet Analyses : les consignes durables données à Claude.
--
-- Ce ne sont pas des questions mémorisées, mais ce qu'il doit savoir une fois
-- pour toutes — le vocabulaire maison, la colonne à prendre quand on dit
-- « surface », les pièges à éviter. Elles sont injectées dans le prompt
-- système à chaque question.
--
-- La table vit dans gestcons et non dans le schéma `analyses` : c'est
-- l'application qui l'écrit, sous l'utilisateur shiny, et le rôle de lecture
-- de l'onglet n'a aucune raison de la voir — Claude ne l'interroge pas, elle
-- lui est donnée.
--
-- Ce sont des CONSIGNES D'EXPLOITATION, pas des données : seuls les
-- administrateurs y ont accès, l'onglet leur étant déjà réservé.

BEGIN;

CREATE TABLE IF NOT EXISTS gestcons.analyses_notes (
  id                SERIAL PRIMARY KEY,
  note              TEXT    NOT NULL CHECK (btrim(note) <> ''),
  actif             BOOLEAN NOT NULL DEFAULT TRUE,
  ordre             INTEGER NOT NULL DEFAULT 0,
  cree_par          VARCHAR,
  date_creation     TIMESTAMPTZ NOT NULL DEFAULT now(),
  modifie_par       VARCHAR,
  date_modification TIMESTAMPTZ
);

COMMENT ON TABLE  gestcons.analyses_notes       IS 'Consignes durables injectées dans le prompt système de l''onglet Analyses.';
COMMENT ON COLUMN gestcons.analyses_notes.ordre IS 'Ordre d''affichage et d''injection ; à égalité, par id.';

-- Mêmes droits que les autres tables du schéma.
GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.analyses_notes TO shiny;
GRANT SELECT, INSERT, UPDATE, DELETE ON gestcons.analyses_notes TO claudeg;
GRANT USAGE, SELECT ON SEQUENCE gestcons.analyses_notes_id_seq TO shiny;
GRANT USAGE, SELECT ON SEQUENCE gestcons.analyses_notes_id_seq TO claudeg;

-- Deux consignes pour amorcer, tirées de ce que la première question a révélé.
INSERT INTO gestcons.analyses_notes (note, ordre, cree_par)
SELECT * FROM (VALUES
  ('Quand une question parle de « surface » sans préciser, prends surface_parcelles_m2 (les parcelles du site, hors continuité). Ne additionne jamais surface_parcelles_m2 et surface_continuite_m2 sans le dire.', 10, 'init'),
  ('Un « secteur d''intervention prioritaire » n''est pas un site conservatoire : la vue gestcons.v_analyses_sites ne contient que des sites conservatoires. Si la question porte sur les secteurs, dis qu''ils ne sont pas accessibles ici.', 20, 'init')
) v WHERE NOT EXISTS (SELECT 1 FROM gestcons.analyses_notes);

COMMIT;
