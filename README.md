# TerraCEN

Application web interne de l'**Ana - Conservatoire d'espaces naturels Ariège** pour
la gestion des sites conservatoires : périmètres, parcellaire cadastral, contrats
fonciers, actions de gestion, documents et acteurs.

C'est une application **R Shiny** modulaire, adossée à une base **PostgreSQL /
PostGIS** (schéma `gestcons`), avec une cartographie **Leaflet**.

> Application **interne, non publique**. L'authentification est assurée en amont
> par un reverse proxy **nginx** (OAuth Azure AD) ; l'autorisation applicative
> repose sur la table des utilisateurs.

---

## Fonctionnalités

L'interface est organisée en onglets :

| Onglet | Rôle |
|---|---|
| 🛠 **Actions** | Saisie et suivi des actions de gestion (avec cartographie). |
| 📍 **Sites** | Création/édition des sites, périmètres, association de parcelles cadastrales, propriétaires. |
| 📍 **Parcelles** | Exploration du parcellaire cadastral et lien aux sites. |
| 📑 **Contrats** | Contrats fonciers et pièces jointes. |
| 📄 **Docs Gestion** | Documents de gestion rattachés aux sites. |
| 👤 **Acteurs** | Annuaire des acteurs / structures. |
| 👤 **Utilisateurs** | Gestion des comptes, statut (actif/inactif) et rôles (responsable, bénévole, animateur). |

Points cartographiques notables : parcelles cadastrales chargées dynamiquement
selon l'emprise et le zoom, périmètres manuels, zones de protection, conservation
de l'emprise au changement d'onglet, et overlay de chargement.

---

## Stack technique

- **R 4.2.2** (version verrouillée via [renv](renv.lock)).
- **Shiny** (modules `NS`/`moduleServer`), `shinyjs`, `shinyWidgets`,
  `shinyFeedback`, `shinythemes`.
- **Leaflet** + `leaflet.extras` (dessin, contrôle des couches).
- **PostgreSQL / PostGIS** via `DBI`, `RPostgres`, `pool` (+ `sf` pour le
  géospatial).
- `dplyr`, `glue`.
- JS/CSS personnalisés dans [www/](www/) (`app.js`, `app.css`).

---

## Structure du dépôt

```
app.R                  # Point d'entrée (UI + server), connexion DB, auth
VERSION                # Source unique de vérité de la version (lue au démarrage)
R/
  helpers.R            # Fonctions utilitaires (carte, SQL sûr, cache cadastre…)
  mod_sites.R          # Module Sites
  mod_parcelles.R      # Module Parcelles
  mod_actions.R        # Module Actions
  mod_contrats.R       # Module Contrats
  mod_docs_gestion.R   # Module Documents de gestion
  mod_acteurs.R        # Module Acteurs
  mod_utilisateurs.R   # Module Utilisateurs
www/
  app.js, app.css      # Assets front (chargés avec ?v={VERSION} pour le cache)
scripts/
  check_missing_docs.R # Pièces jointes référencées en base mais absentes du disque
  check_orphan_files.R # Fichiers sur disque non référencés en base
renv.lock, renv/       # Environnement R reproductible
db_schema_gestcons.sql # Référence du schéma de la base (gestcons)
CHANGELOG.md           # Journal des versions
CONTRIBUTING.md        # Versioning, procédure de release
```

---

## Configuration

L'application se configure par **variables d'environnement** :

| Variable | Description |
|---|---|
| `DB_NAME` | Nom de la base PostgreSQL. |
| `DB_HOST` | Hôte de la base. |
| `DB_USER` | Utilisateur de la base. |
| `DB_PASSWORD` | Mot de passe de la base. |
| `AZURE_TENANT_ID` | Tenant Azure AD (déconnexion / réauthentification OAuth). |
| `TERRACEN_DEBUG` | `TRUE`/`FALSE` — logs de debug applicatifs. |
| `TERRACEN_DEBUG_SQL` | `TRUE`/`FALSE` — log des requêtes SQL. |
| `TERRACEN_CACHE_DEBUG` | `TRUE`/`FALSE` — logs du cache cadastre. |
| `TERRACEN_DEMO_MODE` | Mode démonstration. |

> Le port PostgreSQL est `5432`. Les en-têtes d'authentification
> (`X-Email`, `X-Auth-Request-Email`, …) sont injectés par le reverse proxy nginx.

---

## Lancement en local

Prérequis : R 4.2.x, les dépendances système de `sf`/PostGIS (GDAL, GEOS, PROJ)
et un accès à une base `gestcons`.

```r
# Depuis la racine du dépôt
renv::restore()        # restaure les paquets verrouillés
shiny::runApp()        # lance l'application
```

Définir au préalable les variables d'environnement (par ex. dans `.Renviron`) :

```
DB_NAME=...
DB_HOST=...
DB_USER=...
DB_PASSWORD=...
AZURE_TENANT_ID=...
```

---

## Déploiement

Hébergement sur **Shiny Server** (Debian). Deux instances partagent la **même
base** :

- **`TerraCEN-Test`** — suit `main` HEAD (`git pull`).
- **`TerraCEN`** (prod) — suit un **tag** (HEAD détaché).

> ⚠️ **Toujours déployer et valider sur l'instance de test avant la prod.**

```bash
# Test
sudo -u shiny LANG=C.utf8 LC_ALL=C.utf8 bash -c \
  'cd /srv/shiny-server/TerraCEN-Test && git pull && cat VERSION'
sudo -u shiny touch /srv/shiny-server/TerraCEN-Test/restart.txt

# Prod (sur un tag de release)
sudo -u shiny LANG=C.utf8 LC_ALL=C.utf8 bash -c \
  'cd /srv/shiny-server/TerraCEN && git fetch --tags && git checkout vX.Y.Z && cat VERSION'
sudo -u shiny touch /srv/shiny-server/TerraCEN/restart.txt
```

Les assets `app.js`/`app.css` étant servis avec `?v={VERSION}`, les navigateurs
récupèrent automatiquement les nouvelles versions après un bump de `VERSION`.

---

## Versioning & releases

Schéma **SemVer light** : `MAJEUR.MINEUR[.PATCH]`. La version est stockée dans
[VERSION](VERSION) (source unique de vérité), lue au démarrage par `app.R` et
affichée dans l'UI. Un **tag annoté** `vX.Y.Z` est créé pour chaque release.

Voir [CONTRIBUTING.md](CONTRIBUTING.md) pour la procédure détaillée et
[CHANGELOG.md](CHANGELOG.md) pour le journal des versions.

> Règle d'or : **ne jamais déplacer un tag déjà publié** — créer une nouvelle
> version à la place.

---

## Maintenance

Scripts utilitaires (dans [scripts/](scripts/)) pour auditer la cohérence entre
les pièces jointes référencées en base et les fichiers sur le disque :

```r
source("scripts/check_missing_docs.R")   # liens cassés (en base, absents du disque) -> CSV
source("scripts/check_orphan_files.R")   # fichiers orphelins (sur disque, pas en base)
```

## Licence

TerraCEN est un logiciel libre, distribué sous la licence GNU GPL v3 : il peut
être réutilisé, modifié et redistribué, à condition que toute version modifiée
qui est redistribuée le soit sous la même licence. Le texte complet est dans
[LICENSE](LICENSE).

---

*ANA - CEN Ariège — application interne.*
