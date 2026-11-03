# Contribuer à TerraCen

## Versioning et releases

L'application suit un schéma **SemVer light** : `MAJEUR.MINEUR[.PATCH]`.

| Type de changement | Bump | Exemple |
|---|---|---|
| Refactor interne, correctif mineur, ajout non visible utilisateur | PATCH | `0.79` → `0.79.1` |
| Nouvelle fonctionnalité, refonte d'un onglet, changement UX | MINEUR | `0.79` → `0.80` |
| Cassure incompatible (schéma DB, breaking change utilisateur) | MAJEUR | `0.x` → `1.0` |

### Source unique de vérité

La version est stockée dans le fichier **[VERSION](VERSION)** à la racine du
repo (une seule ligne, format `MAJEUR.MINEUR[.PATCH]`). Elle est lue au démarrage
par [app.R](app.R) :

```r
APP_VERSION <- trimws(readLines("VERSION", n = 1, warn = FALSE))
```

Elle alimente :
- le cache-buster CSS (`app.css?v={APP_VERSION}`) pour forcer le rechargement des
  feuilles de style après mise à jour ;
- l'affichage de la version dans l'UI (`v{APP_VERSION}`).

### Procédure de release

À faire quand un état de `main` est jugé livrable :

```bash
# 1. Bump le fichier VERSION (remplacer le contenu par la nouvelle version)
echo "0.80" > VERSION

# 2. Mettre à jour CHANGELOG.md (déplacer le contenu de [Non publié]
#    vers une nouvelle section [X.Y.Z] — AAAA-MM-JJ)

# 3. Commit dédié
git commit -am "Release v0.80"

# 4. Tag annoté (et non léger)
git tag -a v0.80 -m "Release v0.80"

# 5. Push avec les tags
git push --follow-tags

# 6. Release GitHub, à partir des notes du CHANGELOG (voir plus bas)
sed -n '/^## \[0.80\]/,/^## \[/p' CHANGELOG.md | sed '1d;$d' > /tmp/notes.md
gh release create v0.80 --verify-tag --title "v0.80" --notes-file /tmp/notes.md
```

### Pourquoi un tag annoté (`-a`)

Un tag annoté stocke un objet git complet (auteur, date, message), contrairement
à un tag léger qui n'est qu'un pointeur. Indispensable pour `gh release create`
et tout outil qui s'appuie sur les métadonnées du tag.

### Règle d'or : ne jamais déplacer un tag déjà publié

Une fois `git push --follow-tags` exécuté, le tag est considéré comme **immuable**.
Le déplacer (suppression + recréation à un autre commit) oblige tous les clones
existants à faire `git fetch --tags --force` pour s'aligner — sinon ils restent
silencieusement sur l'ancien commit, ce qui crée des divergences difficiles à
diagnostiquer (l'instance affiche une version qui ne correspond pas à son code).

Si on s'aperçoit après publication qu'il manque quelque chose à une release
(bump VERSION oublié, CHANGELOG incomplet, hotfix nécessaire), on publie une
**release suivante** :

- Oubli mineur de docs/version → release `PATCH` (`v0.83.1`)
- Correctif fonctionnel → release `PATCH` aussi (`v0.83.1`)
- Nouvelle feature → release `MINEUR` (`v0.84`)

C'est plus verbeux qu'un `tag --force` mais ça garde l'historique cohérent et
évite les bugs de déploiement entre instances.

### Release GitHub : un objet distinct du tag

Un **tag git** et une **Release GitHub** sont deux choses différentes.
`git push --follow-tags` ne crée que le tag ; le panneau « Releases » de la page
d'accueil du dépôt, lui, reste figé sur la dernière Release explicitement créée.
Faute de cette étape, il affichait `v0.89` (juin 2026) alors que les tags allaient
jusqu'à `v1.3` — les Releases `v0.99` à `v1.3` ont été créées après coup le
2026-09-28. Les tags antérieurs à `v0.99` restent volontairement sans Release.

Le déploiement ne dépend **que** des tags (cf. « Déployer une nouvelle release en
prod ») : la Release est la vitrine du dépôt, pas un maillon de la mise en ligne.

Les notes sont reprises du `CHANGELOG.md`, pas générées depuis les commits :
`--generate-notes` produit une liste de messages de commit, alors que le CHANGELOG
contient déjà les notes rédigées, qui disent le pourquoi de chaque changement.

Si plusieurs Releases sont créées d'affilée, les créer dans l'ordre **croissant** :
GitHub marque « Latest » la dernière créée, pas la plus haute en numéro.

## Branches

- `main` — branche principale, état déployable
- `dev` — branche d'intégration des fonctionnalités en cours

## Gestion des dépendances avec renv

Le projet utilise [renv](https://rstudio.github.io/renv/) pour figer les versions
des packages R et garantir la reproductibilité entre les machines de dev et le
serveur de prod.

### Fichiers versionnés

- `renv.lock` — manifeste de toutes les dépendances et leurs versions exactes.
- `.Rprofile` — active renv automatiquement au démarrage de R.
- `renv/activate.R` — script de bootstrap de renv.
- `renv/.gitignore` — exclut les sous-dossiers lourds (`library/`, `staging/`, etc.).

**Ne pas committer** : `renv/library/` (la bibliothèque locale matérialisée).

### Premier setup (nouveau dev)

```r
# Depuis la racine du projet, dans une session R
renv::restore()
```

`renv::restore()` lit `renv.lock` et installe localement (dans `renv/library/`)
les versions exactes des packages. La première exécution peut prendre plusieurs
minutes.

### Ajouter ou mettre à jour un package

```r
# Installer un nouveau package
renv::install("nomDuPackage")

# Mettre à jour le lockfile après ajout/mise à jour
renv::snapshot()
```

Puis committer le `renv.lock` modifié.

### Déploiement sur le serveur

Deux instances cohabitent sur le serveur :

- **Prod** : `/srv/shiny-server/TerraCEN/` — suit un **tag annoté** (`vX.Y[.Z]`) en detached HEAD. Promotion manuelle après validation sur test.
- **Test** : `/srv/shiny-server/TerraCEN-Test/` — suit **`main` HEAD**, mis à jour par simple `git pull`.

Les deux instances partagent la **même base de données** : attention aux tests destructifs depuis l'env de test.

`LANG=C.utf8 LC_ALL=C.utf8` est obligatoire avec `sudo -u shiny` (sinon erreurs d'encodage R, notamment `Setting LC_CTYPE failed`). `prompt = FALSE` rend `renv::restore` non-interactif.

#### Déployer une nouvelle release en prod

```bash
sudo -u shiny LANG=C.utf8 LC_ALL=C.utf8 bash -c '
  cd /srv/shiny-server/TerraCEN &&
  git fetch --tags &&
  git checkout vX.Y &&
  R -e "renv::restore(prompt = FALSE)"
'
sudo -u shiny touch /srv/shiny-server/TerraCEN/restart.txt
```

Ne jamais faire `git pull` sur la prod : ça la ramènerait sur `main` HEAD avec du WIP non releasé.

#### Mettre à jour l'env de test

```bash
sudo -u shiny LANG=C.utf8 LC_ALL=C.utf8 bash -c '
  cd /srv/shiny-server/TerraCEN-Test &&
  git pull &&
  R -e "renv::restore(prompt = FALSE)"
'
sudo -u shiny touch /srv/shiny-server/TerraCEN-Test/restart.txt
```
