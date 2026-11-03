# TerraCEN

Application web interne de l'**Ana - Conservatoire d'espaces naturels Ariège** pour
la gestion des sites conservatoires : sites et parcellaire cadastral, contrats
fonciers, actions, documents de gestion, acteurs, stratégie foncière et analyses.

C'est une application **R Shiny** modulaire, adossée à une base **PostgreSQL /
PostGIS** (schéma `gestcons`), avec une cartographie **Leaflet**.

> Le code est public ; l'application, elle, est **interne**. L'authentification
> est assurée en amont par un reverse proxy **nginx** (OAuth Azure AD) ;
> l'autorisation applicative repose sur la table des utilisateurs et leurs rôles.

---

## Fonctionnalités

L'interface est organisée en onglets. Les quatre onglets du domaine des sites
sont regroupés sous le menu **📍 Sites**.

| Onglet | Rôle | Accès |
|---|---|---|
| 🏠 **Accueil** | Chiffres clés, évolution de la maîtrise foncière, activité des douze derniers mois, carte des sites. | Tous |
| 📍 **Création / modification sites et parcelles** | Sites, parcelles cadastrales associées, continuité du site conservatoire, périmètres manuels, propriétaires. | Tous |
| 📍 **Actions** | Actions d'animation foncière, réunions, etc., site par site, avec carte et rapport PDF. | Tous |
| 📍 **Contrats** | Contrats fonciers et agricoles, et leurs pièces jointes. | AD, RS |
| 📍 **Docs de gestion** | Documents de gestion rattachés aux sites. | Tous |
| 🎯 **Stratégie foncière** | Secteurs d'intervention prioritaire : parcelles repérées comme futur site, priorités, promotion d'un secteur en site. | AD, responsables d'un site ou d'un secteur |
| 👤 **Acteurs** | Annuaire des acteurs : propriétaires et agriculteurs. | AD, RS, AN |
| 👤 **Utilisateurs** | Comptes, statut (actif/inactif) et rôles. | AD |
| 🧭 **Analyses** | Questions posées en français : Claude (API Anthropic) les traduit en SQL sur des vues en lecture seule, et la requête est montrée avec la réponse. Export en tableau ou en couche (GeoPackage, Shapefile, GeoJSON, KML). | AD, RS |
| 📈 **Activité** | Activité mois par mois : actions, contrats, documents, modifications, connexions et questions posées. | AD, RS, AN |

AD : administrateur ; RS : responsable de site ; AN : animateur. Un administrateur
peut voir l'application comme un autre utilisateur, pour vérifier ses droits.

Sur les cartes : parcelles cadastrales chargées selon l'emprise et le zoom, zoom
sur une commune, couches de contexte (zones de protection, zones humides, sites
voisins, limites communales), plein écran, et conservation de l'emprise d'un
onglet à l'autre. L'interface existe en mode clair et en mode sombre.

---

## Stack technique

- **R 4.2.2**, la version du serveur, verrouillée avec les paquets par
  [renv](renv.lock).
- **Shiny** en modules (`moduleServer`), interface **Bootstrap 5** via `bslib`,
  `shinyjs`, `shinyFeedback`, `shinybusy`.
- **Leaflet** + `leaflet.extras` (dessin, contrôle des couches) ; `sf` pour le
  géospatial.
- **PostgreSQL / PostGIS** via `DBI`, `RPostgres` et `pool` ; `dplyr`, `glue`.
- `DT` pour les tableaux, `plotly` pour les graphiques, `rmarkdown` et LaTeX pour
  les rapports PDF.
- Onglet Analyses : API **Claude** d'Anthropic, appelée en HTTP (`httr`), en
  tâche de fond (`future`, `promises`).
- JS/CSS personnalisés dans [www/](www/) (`app.js`, `app.css`).

---

## Structure du dépôt

```
app.R                  # Point d'entrée (UI + server) : connexion, identité, droits, onglets
VERSION                # Source unique de vérité de la version (lue au démarrage)
deploy.sh              # Mise à jour d'une instance sur le serveur (test ou prod)
R/
  helpers.R            # Fonctions partagées (carte, SQL, cache cadastre, formulaires…)
  mod_accueil.R        # Accueil
  mod_sites.R          # Sites et leurs parcelles
  mod_actions.R        # Actions
  mod_contrats.R       # Contrats
  mod_docs_gestion.R   # Documents de gestion
  mod_strategie.R      # Stratégie foncière
  mod_acteurs.R        # Acteurs
  mod_utilisateurs.R   # Utilisateurs
  mod_analyse.R        # Analyses
  mod_monitoring.R     # Activité
www/
  app.js, app.css      # Assets front (chargés avec ?v={VERSION} pour le cache)
  help_*.html          # Pages d'aide des onglets
  rapport_*.Rmd        # Modèles des rapports PDF (avec rapport.css, header_logo.tex)
scripts/               # Migrations SQL, vues d'Analyses, maintenance (voir plus bas)
.github/workflows/     # Annonce des issues et PR dans le salon Matrix
renv.lock, renv/       # Environnement R reproductible
CHANGELOG.md           # Journal des versions (CHANGES.txt : les toutes premières)
CONTRIBUTING.md        # Versioning, releases, renv, déploiement
EFFETS-DES-ACTIONS.md  # Ce que chaque geste de l'interface écrit en base
LICENSE                # GNU GPL v3
```

---

## Configuration

L'application se configure par **variables d'environnement**, par exemple dans
le `.Renviron` de l'instance (ignoré par git) :

| Variable | Description |
|---|---|
| `DB_HOST` | Hôte de la base. |
| `DB_PORT` | Port de la base, lu par l'onglet Analyses (la connexion principale utilise `5432`). |
| `DB_NAME` | Nom de la base PostgreSQL. |
| `DB_USER` | Utilisateur de la base. |
| `DB_PASSWORD` | Mot de passe de la base. |
| `AZURE_TENANT_ID` | Tenant Azure AD (déconnexion / réauthentification OAuth). |
| `ANTHROPIC_API_KEY` | Clé de l'API Claude, pour l'onglet Analyses. |
| `ANALYSE_DB_PASSWORD` | Mot de passe du rôle `terracen_analyse`, qui ne sait que lire les vues d'Analyses (rôle créé par `scripts/analyse_role_lecture.sql`). Sans lui, l'onglet Analyses le signale et le reste de l'application fonctionne. |
| `TERRACEN_DEBUG` | `TRUE`/`FALSE` — journal de débogage. |
| `TERRACEN_DEBUG_SQL` | `TRUE`/`FALSE` — journal des requêtes SQL. |
| `TERRACEN_CACHE_DEBUG` | `TRUE`/`FALSE` — journal du cache du cadastre. |

> Les connexions à la base exigent SSL (`sslmode = require`). Les en-têtes
> d'identité (`X-Email`, `X-Auth-Request-Email`, …) sont posés par le reverse
> proxy nginx.

---

## Lancement en local

Prérequis : R 4.2.x (la version du lockfile), les dépendances système de `sf`
(GDAL, GEOS, PROJ) et un accès à une base `gestcons`.

```r
# Depuis la racine du dépôt
renv::restore()        # restaure les paquets verrouillés
shiny::runApp()        # lance l'application
```

Définir au préalable les variables d'environnement, par exemple dans un
`.Renviron` à la racine du dépôt :

```
DB_HOST=...
DB_PORT=5432
DB_NAME=...
DB_USER=...
DB_PASSWORD=...
AZURE_TENANT_ID=...
```

> Sans le reverse proxy, aucun en-tête d'identité n'arrive. Une connexion locale
> (127.0.0.1) est alors reconnue sous l'adresse écrite dans `app.R`
> (`real_user`) : la remplacer par celle d'un compte de votre table des
> utilisateurs.

---

## Déploiement

Hébergement sur **Shiny Server** (Debian). Deux instances partagent la **même
base** :

- **`TerraCEN-Test`** — suit `main`.
- **`TerraCEN`** (prod) — suit un **tag** de release (HEAD détaché).

> ⚠️ **Toujours déployer et valider sur l'instance de test avant la prod.**

Le script [deploy.sh](deploy.sh), présent dans chaque instance, fait tout : il
vérifie l'arbre git, met à jour le code (`git pull` en test, bascule sur le tag
en prod), restaure les paquets avec renv, recharge l'application et arrête les
processus R devenus obsolètes. En cas d'échec, il revient à la version
précédente.

```bash
# Test
sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN-Test/deploy.sh'

# Prod : la dernière release, ou une version précise
sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN/deploy.sh'
sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN/deploy.sh vX.Y'
```

Les assets `app.js`/`app.css` étant servis avec `?v={VERSION}`, les navigateurs
récupèrent automatiquement les nouvelles versions après un changement de
`VERSION`.

---

## Versioning & releases

Schéma **SemVer light** : `MAJEUR.MINEUR[.PATCH]`. La version est stockée dans
[VERSION](VERSION) (source unique de vérité), lue au démarrage par `app.R` et
affichée dans l'UI. Un **tag annoté** `vX.Y[.Z]` est créé pour chaque release.

Voir [CONTRIBUTING.md](CONTRIBUTING.md) pour la procédure détaillée et
[CHANGELOG.md](CHANGELOG.md) pour le journal des versions.

> Règle d'or : **ne jamais déplacer un tag déjà publié** — créer une nouvelle
> version à la place.

---

## Maintenance

Scripts utilitaires, dans [scripts/](scripts/) :

| Script | Rôle |
|---|---|
| `check_missing_docs.R` | Pièces jointes référencées en base mais absentes du disque (→ CSV). |
| `check_orphan_files.R` | Fichiers sur disque non référencés en base. |
| `check_pj_fichiers.R` | Cohérence des pièces jointes entre le disque et la base. |
| `delete_pj_reference_cassee.R` | Nettoyage des références cassées. |
| `delete_site.sql` | Suppression complète d'un site ou d'un secteur. |
| `indexes_perf.sql` | Index de performance de la base. |

Les scripts `migration_*.sql` sont les migrations de la base, déjà passées sur
l'instance du CEN ; chacun décrit en tête ce qu'il modifie.

## Licence

TerraCEN est un logiciel libre, distribué sous la licence GNU GPL v3 : il peut
être réutilisé, modifié et redistribué, à condition que toute version modifiée
qui est redistribuée le soit sous la même licence. Le texte complet est dans
[LICENSE](LICENSE).

---

*ANA - CEN Ariège — application interne.*
