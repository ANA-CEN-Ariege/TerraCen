-- ============================================================================
-- indexes_perf.sql — Index de performance pour la base gestcons (TerraCEN)
-- ----------------------------------------------------------------------------
-- Pourquoi : seules les TRÈS grosses tables justifient des index. Les tables
-- de travail de l'appli sont minuscules (parcelles ~2 300, contrats ~2 300,
-- liaisons < 300, rôles < 100) → un index n'y sert à rien (le planificateur
-- choisit un Seq Scan, déjà sub-milliseconde). Les seules tables volumineuses :
--   dico_cadastre     ~1,15 M lignes / ~1 Go
--   dico_proprietaire ~286 k lignes  / ~68 Mo
-- L'appli y fait des lookups par ÉGALITÉ sur des colonnes non indexées
-- (idpar, idprocpte, idcomtxt) → Seq Scans répétés de 1 Go.
--
-- Gain mesuré (EXPLAIN ANALYZE) sur dico_cadastre(idpar) :
--   AVANT : Parallel Seq Scan, ~1,15 M lignes filtrées → 127,9 ms (+ JIT)
--   APRÈS : Index Scan                                  →   0,039 ms  (~3 300×)
--
-- Exécution : DBeaver en AUTO-COMMIT (CONCURRENTLY ne tourne pas dans une
-- transaction). Lancer chaque ordre séparément. CONCURRENTLY = pas de verrou
-- bloquant sur la prod. Faire ANALYZE ensuite pour rafraîchir les stats.
-- ============================================================================


-- == 🔴 PRIORITÉ 1 — le gros gain ============================================

-- Lookups par référence cadastrale sur 1,15 M lignes, très fréquents :
--   WHERE c.idpar = ...  /  IN (...)  /  = ANY(...)  /  JOIN ON c2.idpar = b.idpar
--   (helpers.R, mod_parcelles.R, mod_actions.R, …)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_dico_cadastre_idpar
  ON gestcons.dico_cadastre (idpar);

-- Clé de la jointure propriétaire récurrente (≈15×) :
--   LEFT JOIN dico_proprietaire dp ON dp.idprocpte = c.idprocpte
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_dico_proprietaire_idprocpte
  ON gestcons.dico_proprietaire (idprocpte);


-- == 🟠 PRIORITÉ 2 ===========================================================

-- Filtre/jointure cadastre par compte propriétaire sur 1,15 M lignes :
--   WHERE c.idprocpte = '...' / IN (...)   (mod_parcelles.R:1532-1549)
--   JOIN ... ON dc.idprocpte = dp.idprocpte
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_dico_cadastre_idprocpte
  ON gestcons.dico_cadastre (idprocpte);

-- Liste des communes : SELECT DISTINCT idcomtxt FROM dico_cadastre
--   (get_liste_communes, helpers.R) → sinon full scan du 1 Go.
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_dico_cadastre_idcomtxt
  ON gestcons.dico_cadastre (idcomtxt);


-- == Rafraîchir les statistiques du planificateur ============================
ANALYZE gestcons.dico_cadastre;
ANALYZE gestcons.dico_proprietaire;


-- == 🧹 Nettoyage — index inutiles (confirmé par la volumétrie) ==============

-- parcelles ne fait que ~2 300 lignes → un index sur site_id n'est jamais
-- utilisé (le planificateur garde un Seq Scan, déjà < 0,3 ms).
DROP INDEX IF EXISTS gestcons.idx_parcelles_site_id;

-- Redondant avec la clé primaire (parcelles.id est déjà unique-indexé).
DROP INDEX IF EXISTS gestcons.parcelles_id_idx;


-- ============================================================================
-- Vérification post-création (optionnel)
-- ----------------------------------------------------------------------------
-- EXPLAIN ANALYZE SELECT * FROM gestcons.dico_cadastre WHERE idpar = '<réf>';
--   → doit afficher « Index Scan using idx_dico_cadastre_idpar ».
--
-- Lister les index d'une table :
--   SELECT indexname, indexdef FROM pg_indexes
--   WHERE schemaname = 'gestcons' AND tablename = 'dico_cadastre';
-- ============================================================================
