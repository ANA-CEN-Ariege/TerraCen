# Migration : fusion de `parcelles_perimetre` dans `parcelles` (scénario B)

> Plan d'actions sur la base `anaweb`, schéma `gestcons`.
> Objectif : une seule table physique (`parcelles_base`) portant les parcelles de
> site ET les parcelles du périmètre élargi (colonne `perimetre boolean`), avec une
> **vue de compatibilité** `gestcons.parcelles` (filtrée `WHERE NOT perimetre`) pour
> que tout le code existant — y compris la prod v0.97 pendant la transition —
> continue de fonctionner à l'identique.
>
> Contexte vérifié (2026-07-30) :
> - `parcelles` : `UNIQUE (parcellaire_id)` GLOBAL (une parcelle = un seul site) ;
> - `parcelles_perimetre` : `UNIQUE (site_id, parcellaire_id)` (multi-sites permis) ;
> - 83 références à `gestcons.parcelles` dans le code R (7 modules + pipeline) ;
> - 5 vues SQL référencent `parcelles` : `sites_gestion_terracen_actifs`,
>   `sites_gestion_terracen_prefiguration`, `vm_parcelles_protection` (matérialisée),
>   `v_fcen_parcelle_cen_04`, `v_fcen_site_cen_04` (indépendantes entre elles) ;
> - triggers sur `parcelles` : `trg_audit` (tg_audit_log), `trg_del_perimetre_manuel`
>   (BEFORE DELETE) ;
> - grants sur `parcelles` : `claudeg`/`shiny` RW, `shiny_lecteur` RO.

---

## Phase 0 — Préparation (hors fenêtre, sans impact)

1. **Backup** : `pg_dump` en `adminsig` du schéma gestcons (schéma + données de
   `parcelles` et `parcelles_perimetre` au minimum).
2. **Contrôles de données préalables** (lecture seule) :
   - aucune parcelle à la fois dans `parcelles` et `parcelles_perimetre` **pour le
     même site** (les garde-fous UI l'empêchent, mais on vérifie) ;
   - toutes les lignes de `parcelles_perimetre` ont leur `parcellaire_id` dans
     `dico_cadastre` (nécessaire pour récupérer `dcntpa`).
3. **Relevés de référence** : comptes de `parcelles`, de `parcelles_perimetre`, et
   résultat-témoin des vues FCEN (pour comparer après migration).

---

## Fenêtre de migration — LE script (une seule transaction, exécuté en `adminsig`)

Dans cet ordre, tout entre `BEGIN` et `COMMIT` :

1. `ALTER TABLE parcelles ADD COLUMN perimetre boolean NOT NULL DEFAULT false`
   + `ADD COLUMN remarque text`
   *(défaut constant → instantané, pas de réécriture de table)*.

2. **Unicité** : `DROP CONSTRAINT parcelles_cadastre_id_key`, puis deux index
   uniques **partiels** :
   - `UNIQUE (parcellaire_id) WHERE NOT perimetre`
     → règle actuelle des parcelles de site, à l'identique ;
   - `UNIQUE (site_id, parcellaire_id) WHERE perimetre`
     → règle actuelle du périmètre, à l'identique.

3. `ALTER TABLE parcelles RENAME TO parcelles_base`
   *(PK, FKs entrantes des jonctions actions/contrats, index, triggers `trg_audit`
   et `trg_del_perimetre_manuel`, séquence, grants : tout suit automatiquement —
   rien à refaire)*.

4. **Vue de compatibilité** :
   `CREATE VIEW gestcons.parcelles AS SELECT * FROM parcelles_base WHERE NOT perimetre`
   **+ les GRANTS immédiatement** (`shiny` RW, `shiny_lecteur` RO, `claudeg` RW).
   ⚠️ **C'est LE point critique prod** : sans les grants dans la même transaction,
   la prod perd l'accès à `parcelles` au COMMIT et tombe en erreur partout.

5. **Migration des données** :
   `INSERT INTO parcelles_base (…) SELECT … FROM parcelles_perimetre pp JOIN dico_cadastre c …`
   avec `perimetre = true`, `remarque` conservée, traçabilité (`cree_par`/dates)
   conservée, et les mêmes défauts de maîtrise que la bascule :
   `surf_parc_maitrise_m2 = dcntpa`, `source_surf_parc_id = 1`,
   `echelle_numerisation_id = 1`, `proprietaire_id = 4`, `chasse_id = 1`,
   `bnd/pour_part/domaine_public/zpf/mesure_compens = 0`, `actif = true`.
   Les lignes reçoivent de **nouveaux id** (séquence de `parcelles`) — sans
   conséquence : rien ne référence les anciens id de `parcelles_perimetre`.

6. **Recréation des 5 vues** pour qu'elles se rebranchent sur la **vue filtrée**
   (après le RENAME, elles suivent la table physique — OID — et verraient les
   lignes périmètre) :
   - `CREATE OR REPLACE VIEW` (conserve les grants) pour
     `sites_gestion_terracen_actifs`, `sites_gestion_terracen_prefiguration`,
     `v_fcen_parcelle_cen_04`, `v_fcen_site_cen_04` — définitions reprises telles
     quelles du dump ;
   - `vm_parcelles_protection` (matérialisée) : `DROP` + `CREATE` + re-grants +
     `REFRESH` + recréation de ses index.

6bis. **Trigger d'audit `tg_audit_log()`** : `CREATE OR REPLACE` avec les branches
   ANIMATIONS résolues via `parcelles_base` (les actions peuvent être liées aux
   parcelles du périmètre élargi ; via la vue filtrée ces liens seraient
   invisibles). Les autres branches restent sur la vue (sémantique inchangée).

7. `ALTER TABLE parcelles_perimetre RENAME TO parcelles_perimetre_old`
   — **pas de DROP** : filet de sécurité jusqu'à validation post-release.

8. **Vérifications intégrées au script** :
   - `count(*)` de la vue `parcelles` = ancien compte de `parcelles` ;
   - `count(*) WHERE perimetre` = ancien compte de `parcelles_perimetre` ;
   - échantillon des vues FCEN identique aux relevés.
   Si écart → `ROLLBACK`.

9. `COMMIT` — ou `ROLLBACK` systématique en **dry-run** (le DDL PostgreSQL est
   transactionnel : le même script se rejoue à blanc intégralement).

---

## Après le script

10. `ANALYZE parcelles_base`.
11. Vérification fonctionnelle rapide de la **prod** (Sites, Parcelles, Contrats,
    exports) — tout doit être strictement identique via la vue.
12. **Release le même jour** (le code adapté doit être prêt et validé sur test
    avant d'ouvrir la fenêtre).
13. Plus tard, après validation complète : `DROP TABLE parcelles_perimetre_old`.

---

## Points d'attention / prod (base partagée)

| Point | Détail |
|---|---|
| **Verrous** | Le script prend un `ACCESS EXCLUSIVE` sur `parcelles` (ALTER/RENAME) : toute requête prod sur cette table est bloquée pendant l'exécution (quelques secondes, hors REFRESH de la matview). Fenêtre calme (soir) + `lock_timeout` en tête de script pour ne pas rester coincé derrière une requête longue — le script échoue proprement plutôt que de bloquer la prod. **Vaut aussi pour le dry-run** (mêmes verrous). |
| **Grants de la vue** | Dans la même transaction que sa création (étape 4) — sinon panne prod immédiate. |
| **Stratégie prod cassé** entre migration et release | La table `parcelles_perimetre` n'existe plus ; l'onglet Stratégie de la prod (v0.97) tombera en erreur. AD-only = un seul utilisateur : ne pas l'utiliser pendant la fenêtre. **Tout le reste de la prod fonctionne à l'identique.** |
| **Vues FCEN** | Recréées dans la même transaction → aucun instant où les exports verraient les parcelles du périmètre. |
| **`audit_log`** | Après le rename, le trigger enregistrera `table_name = 'parcelles_base'` (au lieu de `parcelles`), et les modifications du périmètre y passeront aussi. À vérifier côté R si l'onglet Activité affiche/filtre ce nom (point pour la phase code). |
| **Ordre impératif** | Données migrées (5) **avant** recréation des vues (6) mais **après** création de la vue de compat (4) — sinon soit les vues se lient à la table physique, soit la prod voit un état intermédiaire. La transaction unique garantit qu'aucun état intermédiaire n'est jamais visible. |
| **Double filet** | Backup pg_dump + `parcelles_perimetre_old` conservée. Rollback total possible tant que la release n'a pas eu lieu (re-rename inverse + re-drop de la colonne). |
| **Exécutant** | Rôle capable de modifier les objets d'**adminsig** (parcelles, vues) ET de **claudeg** (`parcelles_perimetre`, `tg_audit_log()`) → superutilisateur, ou owners alignés d'abord. Le script fait un **pré-contrôle des droits** et échoue proprement sinon. |

---

*Document local (non versionné), même politique que `create_parcelles_perimetre.sql`.
Le script SQL de migration sera livré avec dry-run par défaut (`ROLLBACK` final,
à remplacer par `COMMIT` pour la vraie passe).*

---

## Runbook complet (code + base) — week-end de migration

**Avant le WE** : commit + push du lot de code sur `main` (fusion Sites/Parcelles/
Actions/monitoring + suppression mod_strategie). Ne PAS puller sur test avant la
migration.

**Samedi (fenêtre calme), dans l'ordre :**
1. Backup depuis le poste :
   `pg_dump -h <hôte> -U adminsig -d anaweb -n gestcons --exclude-table='gestcons.*_backup*' -Fc -f gestcons_avant_fusion_<date>.dump`
   puis vérification : `pg_restore --list <dump> | head`
2. DRY-RUN du script (DBeaver « Exécuter le script » ou psql) → attendre les
   NOTICE « VÉRIFICATIONS OK » + ROLLBACK final. En cas d'erreur : ROLLBACK;
   manuel, ne pas insister.
3. Vraie passe : ROLLBACK final -> COMMIT, relancer.
4. `ANALYZE gestcons.parcelles_base;`
5. Serveur test : `git pull` + `touch restart.txt`.
6. Validation test : Sites (couches orange/contour, ajouter au périmètre,
   bascule, retirer, remarque, résumé) ; Parcelles (clic orange -> modal
   édition) ; Actions (parcelles périmètre sélectionnables SANS contrat, les 2
   domaines ; action suit la parcelle après bascule) ; Activité. Prod v0.97 :
   identique partout sauf Stratégie (HS attendu, ne pas utiliser).
7. Release (tag v0.98) -> déployer le tag en prod + restart -> vérif rapide.

**Après quelques jours** : `DROP TABLE gestcons.parcelles_perimetre_old;` ;
mettre à jour delete_site.sql local (purge des lignes périmètre d'un site avant
DROP du site, sinon FK bloquante) ; archiver le backup.
