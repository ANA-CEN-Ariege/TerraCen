# Effets des actions

Ce document décrit, pour chaque geste de l'interface, **ce qui est écrit en
base et ce qui se déclenche en plus**. Il est tiré du code, module par module,
et sert à répondre à la question « qu'est-ce que ça touche, au juste ? » avant
de modifier ou de supprimer quelque chose.

Les noms entre parenthèses sont les identifiants des observateurs Shiny, pour
retrouver le code.

---

## Conventions transversales

Quatre mécanismes reviennent partout et ne sont pas répétés dans chaque fiche.

| Mécanisme | Ce qu'il fait |
|---|---|
| `contrats_update_trigger` | Déclencheur **global**. Toute écriture de parcelle ou de contrat l'incrémente, et cinq modules rechargent alors leurs données — y compris les onglets masqués. |
| `acteurs_existants_rv` | Liste partagée des acteurs. Rafraîchie après création d'acteurs propriétaires ; les tableaux Acteurs et les sélecteurs de Contrats suivent. |
| `invalidate_sites_coords_cache()` | Vide le cache des coordonnées de sites, utilisé par les marqueurs de la carte générale. |
| `log_action()` | Trace applicative (horodatage, utilisateur, IP) dans le journal Shiny. Distincte du trigger `trg_audit` en base, qui n'existe **pas** sur les tables de liaison de contrats. |

**Transactions** — depuis la v2.0, les écritures multiples sont atomiques et
toute erreur SQL remonte. Les chemins qui restent hors transaction sont
signalés dans les fiches.

---

## Site

### Créer un site (`create_site`)

En **une transaction** :

1. `sites` — la fiche.
2. `sites_statuts` — le statut initial.
3. `contrats_fonciers` — **un contrat par défaut est créé automatiquement**, nommé d'après le site (tronqué à 240 caractères).
4. `responsable_sites`, `conservateur_benevole`, `animateur_sites` — si renseignés.

Puis : cache des coordonnées invalidé, déclencheur global incrémenté.

> Si l'insertion du site échoue, un `stop()` force le rollback : rien n'est écrit.

### Modifier un site (`update_site`)

En **une transaction**, jusqu'à neuf écritures sur cinq tables :

1. `sites` — la fiche.
2. `sites_statuts` — si le statut change : clôture de la ligne courante puis insertion de la nouvelle.
3. `responsable_sites` et `conservateur_benevole` — via `maj_role_site()`, voir **Rôles de site** plus bas.
4. `animateur_sites` — désactivation des animateurs retirés, `INSERT … ON CONFLICT DO UPDATE` pour les autres.

Puis : cache des coordonnées invalidé, sélecteur de sites rechargé.

### Supprimer un site

**Aucun chemin dans l'interface.** La suppression passe par
`scripts/delete_site.sql`, qui purge dans l'ordre les liaisons de contrats,
d'actions et de protection, les sources géométriques, les périmètres manuels,
les parcelles, les rôles, les statuts, puis le site.

---

## Rôles de site — responsable et bénévole conservateur

Les deux passent par `maj_role_site()` (helpers.R), qui distingue trois gestes.
**L'historique des périodes est conservé** : rien n'est jamais supprimé.

| Saisie | Écriture |
|---|---|
| Même personne, date modifiée | **Correction** — la ligne en cours est modifiée, aucune période ouverte |
| Personne différente | La période en cours est close (`date_fin`, `actif = FALSE`), une nouvelle s'ouvre |
| Plus personne | Clôture seule |
| Personne ayant déjà tenu le rôle **à cette même date** | Sa ligne est rouverte, pas dupliquée |

Appelé depuis trois endroits : les deux blocs de la fiche d'un site, et la
fiche d'un secteur.

---

## Secteur d'intervention prioritaire

### Créer ou modifier un secteur (`enregistrer`)

1. `sites` — insertion ou mise à jour, avec `type_site_id = 2`.
2. `responsable_sites` — via `maj_role_site()`.

Le bouton reste inactif tant que les six champs obligatoires ne sont pas
renseignés.

### Ajouter des parcelles (`ajouter_au_secteur`)

1. `parcelles_base` — insertion avec `perimetre = true` et la priorité choisie.
2. `parcelles_sources_geom` — la liaison de source géométrique, obligatoire.

> Contrairement à l'ajout à un site ou à une continuité, **les propriétaires ne
> sont pas créés en acteurs** sur ce chemin.

### Retirer des parcelles (`parc_retirer`, `retrait_lot_confirm`)

`parcelles_sources_geom` puis `parcelles_base`, dans cet ordre — la liaison est
en `NO ACTION`, elle doit partir avant la parcelle.

### Promouvoir un secteur en site (`promo_confirm`)

Le secteur **devient** le site, il ne lui en crée pas un nouveau :

1. `sites` — `type_site_id` passe de 2 à 1, et les champs du formulaire sont appliqués.
2. `sites_statuts` — statut initial du nouveau site.
3. `parcelles_base` — les parcelles **sélectionnées** passent `perimetre = FALSE` : elles deviennent parcelles du site.
4. `contrats_foncier_parcelles` — ces parcelles sont rattachées au contrat choisi.
5. `parcelles_base` — **toutes** les priorités du site sont remises à `NULL`, y compris celles de la continuité.

Les parcelles non sélectionnées restent en `perimetre = true` : elles
deviennent la continuité du nouveau site. Puis le déclencheur global est
incrémenté et le nouveau site est ouvert dans l'onglet Sites.

### Supprimer un secteur (`supprimer_confirm`)

`responsable_sites` puis `sites`. **Refusé si le secteur porte encore des
parcelles** — le bouton de confirmation n'apparaît pas.

---

## Parcelle

### Ajouter des parcelles à un site (`valider_contrat_global`)

1. `parcelles` — insertion, avec les valeurs par défaut de maîtrise.
2. `parcelles_sources_geom` — source géométrique (4 = PCI pour le cadastre, 2 = numérisation manuelle).
3. `perimetre_parcellaire_manuel` — pour les polygones dessinés.
4. `contrats_foncier_parcelles` — rattachement au contrat choisi, **obligatoire**.
5. **Création des acteurs propriétaires** — `creer_acteurs_proprietaires()`, puis rafraîchissement de la liste partagée si des acteurs ont été insérés.

Puis : cache des coordonnées invalidé, déclencheur global incrémenté.

> Seules les **personnes physiques** deviennent acteurs : le filtre porte sur
> `dnomus`. Les personnes morales — communes, GFA, ONF, État — sont écartées.

### Ajouter des parcelles à la continuité (`add_to_perimetre`)

1. `parcelles_base` — insertion avec `perimetre = true`.
2. `parcelles_sources_geom`.
3. **Création des acteurs propriétaires**, comme ci-dessus.

Aucun contrat n'est rattaché : une parcelle de continuité n'en porte pas.

### Basculer une parcelle de la continuité vers le site (`bascule_confirm`)

1. `parcelles_base` — `perimetre` passe à `FALSE`.
2. `contrats_foncier_parcelles` — rattachement au contrat choisi.

Les acteurs ne sont pas recréés : ils l'ont déjà été à l'ajout en continuité.

### Basculer une parcelle du site vers la continuité (`confirm_bascule_vers_perimetre`)

1. `contrats_foncier_parcelles` et `contrats_agricoles_parcelles` — **les liaisons de contrat sont supprimées**.
2. `parcelles_base` — `perimetre` passe à `TRUE`.

### Modifier une parcelle (`update_parcelle`)

1. `parcelles` — les attributs de la fiche.
2. `parcelles_sources_geom` — purge puis pose, en deux ordres dans une transaction. **Jamais en CTE** : l'index d'unicité verrait encore l'ancienne ligne et l'insertion serait avalée.
3. `contrats_foncier_parcelles` et `contrats_agricoles_parcelles` — **seule la liaison affichée** est remplacée, les autres ne sont pas touchées.

### Supprimer une parcelle (`delete_parcelle_confirm`)

Confirmation obligatoire, annonçant le nombre de liaisons concernées. En **une
transaction** :

`contrats_foncier_parcelles`, `contrats_agricoles_parcelles`,
`animation_fonciere_parcelles`, `animation_contrat_agricole_parcelles`,
`parcelles_protection`, `parcelles_sources_geom`, puis `parcelles` — et
`perimetre_parcellaire_manuel` si la parcelle était un polygone dessiné.

Puis : cache des coordonnées invalidé, déclencheur global incrémenté.

---

## Contrat

### Créer un contrat (`create_contrat_save`)

En **une transaction** : `contrats_fonciers` ou `contrats_agricoles`, puis
`contrats_acteurs_fonciers` ou `contrats_agriculteurs` pour les acteurs liés.

> Un contrat agricole **actif** doit porter au moins un acteur : contrôlé avant
> écriture.

### Modifier un contrat (`update_contrat`)

En **une transaction** : la fiche, puis réécriture complète des liaisons
d'acteurs — suppression puis insertion.

### Rattacher des parcelles depuis la carte (`save_links`)

En **une transaction** :

1. Suppression des liaisons **de ce contrat** sur les sites que l'utilisateur peut éditer. Les autres sites ne sont pas touchés.
2. Insertion des liaisons retenues, en `ON CONFLICT DO NOTHING`.

La désélection d'une parcelle est donc prise en compte par la première étape.

> **Une parcelle ne peut porter qu'un contrat actif par type.** Le clic et le
> rectangle refusent une parcelle déjà engagée, en nommant le contrat qui la
> détient. Retirer une parcelle de la sélection reste toujours possible.

### Supprimer un contrat (`delete_contrat_confirm`)

Confirmation obligatoire, annonçant le nombre de parcelles et d'acteurs liés.
En **une transaction** : les liaisons de parcelles, les liaisons d'acteurs,
puis le contrat.

> Les parcelles concernées se retrouvent **sans contrat**.

---

## Action — animation foncière ou agricole

### Créer une action (`af_create`)

En **une transaction** : `animation_fonciere` ou `animation_contrat_agricole`,
puis les liaisons de parcelles, d'acteurs et d'utilisateurs. La pièce jointe
éventuelle est enregistrée dans la foulée, une fois l'action dotée d'un id.

### Modifier une action (`af_save`, `ag_edit_save`)

En **une transaction** : la fiche, puis réécriture complète des liaisons
d'utilisateurs et d'acteurs — suppression puis insertion.

### Supprimer une action (`af_delete_confirm`, `ag_delete_confirm`)

Confirmation obligatoire, annonçant le nombre de documents joints.

1. **Les fichiers joints sont supprimés du disque**, un par un, et leurs lignes avec.
2. Puis les liaisons de parcelles, d'acteurs et d'utilisateurs, et l'action.

> Les fichiers sont effacés **avant** les suppressions en base, et les trois
> `DELETE` ne sont pas atomiques entre eux.

---

## Document de gestion

### Créer (`create_doc_save`), modifier (`update_doc`)

En **une transaction** : `doc_gestion`, `docs_gestion_sites` pour les sites
rattachés, `doc_evaluation_doc_gestion` et `validation_cs` le cas échéant. Le
fichier est copié sur le serveur avant l'écriture ; **si l'insertion échoue, il
est retiré du disque**.

> Le type de fichier est contrôlé **côté serveur** avant toute écriture.

### Supprimer (`delete_doc_confirm`)

Confirmation obligatoire, annonçant le nombre de sites rattachés et de fichiers
concernés. La transaction purge `validation_cs`,
`doc_evaluation_doc_gestion`, `docs_gestion_sites` puis `doc_gestion` — et
**les fichiers ne sont effacés du disque qu'après** le succès de la
transaction.

---

## Acteur

### Créer (`save_acteur`), modifier (`update_acteur`)

`dico_acteurs_fonciers_agricoles`, puis rafraîchissement de la liste partagée.

> Déduplication par `(type_acteur_id, nom, prénom, adresse)`, normalisés sans
> accents ni casse. **`nom_entite` n'entre pas dans la clé.**

### Supprimer (`delete_acteur_confirm`)

Confirmation obligatoire, qui distingue deux comportements :

| Liaison | Effet |
|---|---|
| `contrats_acteurs_fonciers`, `contrats_agriculteurs` | `NO ACTION` — **la base refuse la suppression** |
| `animation_fonciere_acteurs`, `animation_contrat_agricole_acteurs` | `CASCADE` — les liaisons **partent silencieusement** |

Le refus est signalé explicitement.

---

## Utilisateur

### Créer (`save_user`)

`dico_utilisateur`.

### Modifier (`update_user`)

En **une transaction** : `dico_utilisateur`, et **si le compte passe à
inactif**, clôture de ses rôles — `responsable_sites`, `conservateur_benevole`
et `animateur_sites` sont passés à `actif = FALSE`.

### Supprimer (`delete_user`)

En **une transaction** : `responsable_sites`, `conservateur_benevole`, puis
`dico_utilisateur`.

> **La suppression échoue le plus souvent, et c'est normal.** Dix-sept clés
> étrangères pointent vers `dico_utilisateur`, dont quinze en `NO ACTION` : le
> helper n'en purge que deux. Bloquent notamment `animateur_sites` (16 des 60
> utilisateurs y figurent), `connexion_log` (7 utilisateurs, et toute
> connexion y laisse une trace définitive) et une douzaine de tables du schéma
> `si`, qui appartient à **une autre application**. Seule
> `animation_fonciere_utilisateur` est en `CASCADE`.
>
> En pratique, **désactiver** un utilisateur est le geste prévu : la
> modification clôt ses rôles et conserve son historique.

---

## Points à connaître

- **Le déclencheur global est grossier.** Une écriture de parcelle sur un site
  relance le chargement complet des parcelles dans Sites, Parcelles et
  Activité, y compris sur les onglets masqués.
- **Les tables de liaison de contrats n'ont pas de trigger d'audit.** Une
  modification y est intraçable.
- **La règle « un contrat actif par type et par parcelle » n'est pas contrainte
  en base** : un index unique ne peut pas lire le statut dans une autre table.
  Elle est gardée dans l'interface, sur la carte d'association uniquement.
- **`parcelles` est une vue de compatibilité** au-dessus de `parcelles_base` ;
  les deux noms apparaissent dans le code.
