#!/usr/bin/env bash
#
# deploy.sh — Met à jour une instance TerraCEN (test ou prod).
#
# À exécuter EN TANT QU'UTILISATEUR shiny, sur le serveur.
#
#   # Instance de TEST (suit main HEAD) :
#   sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN-Test/deploy.sh'
#
#   # Instance de PROD (bascule sur un tag de release) :
#   sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN/deploy.sh'           # dernière release
#   sudo -u shiny -H bash -c '/srv/shiny-server/TerraCEN/deploy.sh v0.85.1'   # version précise
#
# Le mode (test/prod) est déduit du nom du dossier (…-Test => test), ou forcé
# via la variable DEPLOY_MODE / le 1er argument 'test'. Un tag explicite en
# argument implique le mode prod.
#
# Étapes : vérifie l'utilisateur et l'arbre git, met à jour le code (git pull
# en test / checkout du tag en prod), restaure les paquets R via renv, recharge
# l'app via restart.txt, puis termine les processus R devenus obsolètes.
#
#   DEPLOY_KILL_STALE=0  laisse vivre les anciens processus (sessions en cours
#                        préservées, mais mémoire non rendue).
#
set -euo pipefail

# --- Paramètres (surchargeables par variable d'environnement) ---
# Dossier de l'app : par défaut l'emplacement même du script (il est versionné
# et donc présent dans chaque clone test/prod).
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
APP_DIR="${APP_DIR:-$SELF_DIR}"
EXPECTED_USER="${DEPLOY_USER:-shiny}"
BRANCH="${DEPLOY_BRANCH:-main}"
DEPLOY_LOG="${DEPLOY_LOG:-/var/log/terracen_deploy.log}"
R_TIMEOUT="${R_TIMEOUT:-900}"  # renv::restore() peut être long (compilation)
PREVIOUS_REF=""                # Pour rollback en cas d'erreur

# Locale imposée par l'environnement R du serveur (R 4.2.2 / shiny).
export LANG="${LANG:-C.utf8}"
export LC_ALL="${LC_ALL:-C.utf8}"

# --- Couleurs / log ---
info()  {
  msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '\033[1;34m[deploy]\033[0m %s\n' "$msg"
  [ -w "$(dirname "$DEPLOY_LOG")" ] && echo "$msg" >> "$DEPLOY_LOG" 2>/dev/null || true
}
warn()  { printf '\033[1;33m[deploy]\033[0m %s\n' "$*" >&2; }
die()   {
  printf '\033[1;31m[deploy] ERREUR :\033[0m %s\n' "$*" >&2
  [ -n "$PREVIOUS_REF" ] && { info "Rollback vers $PREVIOUS_REF…"; git checkout --quiet "$PREVIOUS_REF" 2>/dev/null || true; }
  exit 1
}

# --- 1. Argument & résolution du mode (test / prod) ---
TAG=""
MODE="${DEPLOY_MODE:-}"
ARG="${1:-}"
if [ "$ARG" = "test" ]; then
  MODE="test"
elif [ -n "$ARG" ]; then
  TAG="$ARG"                   # un tag explicite => mode prod
  MODE="${MODE:-prod}"
fi
if [ -z "$MODE" ]; then
  case "$(basename "$APP_DIR")" in
    *-Test|*-test) MODE="test" ;;
    *)             MODE="prod" ;;
  esac
fi

# --- 2. Vérification de l'utilisateur ---
CURRENT_USER="$(id -un)"
if [ "$CURRENT_USER" != "$EXPECTED_USER" ]; then
  die "à lancer en tant que '$EXPECTED_USER' (utilisateur courant : '$CURRENT_USER').
       Essaie : sudo -u $EXPECTED_USER -H bash -c '$APP_DIR/deploy.sh ${1:-}'"
fi

# --- 3. Vérification du dossier git ---
cd "$APP_DIR" || die "dossier introuvable : $APP_DIR"
[ -d .git ] || die "$APP_DIR n'est pas un clone git."

# Refuser de continuer si des modifications locales risquent d'être écrasées
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "des modifications locales non commités sont présentes dans $APP_DIR.
       Range-les (git stash) ou écrase-les (git checkout -- .) avant de redéployer."
fi

# --- 4. Mise à jour du code ---
if [ "$MODE" = "test" ]; then
  info "Mode TEST — mise à jour sur '$BRANCH' HEAD…"
  PREVIOUS_REF="$(git rev-parse --short HEAD)"
  git fetch --prune origin
  git checkout --quiet "$BRANCH"
  git pull --ff-only origin "$BRANCH" \
    || die "git pull --ff-only a échoué — l'historique local a divergé de origin/$BRANCH ?"
  info "Code à jour : $(git describe --tags --always)"
else
  info "Mode PROD — déploiement sur un tag de release…"
  # --force pour rafraîchir un tag local divergent ; --prune-tags pour purger
  # en local les tags supprimés côté remote.
  git fetch --tags --force --prune --prune-tags origin

  # Sans argument : dernière release = plus haut tag de version (tri sémantique).
  if [ -z "$TAG" ]; then
    TAG="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -n1)"
    [ -n "$TAG" ] || die "aucune release (tag 'v*') trouvée sur origin."
    info "Aucune version fournie → dernière release détectée : $TAG"
  fi

  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || die "le tag '$TAG' n'existe pas (après fetch). Tags dispo : $(git tag -l | tr '\n' ' ')"

  PREVIOUS_REF="$(git describe --tags --exact-match 2>/dev/null || git rev-parse --short HEAD)"
  CURRENT_REF="$(git describe --tags --exact-match 2>/dev/null || true)"
  if [ "$CURRENT_REF" = "$TAG" ]; then
    info "Déjà sur $TAG — code inchangé (on poursuit avec renv + restart)."
  fi

  info "Bascule sur $TAG…"
  git checkout --quiet "$TAG"
  info "Code à jour : $(git describe --tags --always)"
fi

# --- 4b. Vérification des dépendances système (sf requiert gdal, geos, proj) ---
info "Vérification des dépendances système…"
for cmd in gdalinfo geos-config proj; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "⚠️  $cmd manquant. Pour utiliser sf : installez libgdal-dev, libgeos-dev, libproj-dev"
  fi
done

# --- 5. Dépendances R (renv : synchronise la lib avec renv.lock) ---
info "Restauration des paquets R via renv (renv.lock)…"
timeout "$R_TIMEOUT" Rscript -e 'renv::restore(prompt = FALSE)' \
  || die "échec de renv::restore() — voir la sortie ci-dessus."
info "Paquets R synchronisés avec renv.lock."

# --- 6. Rechargement de l'application (sans privilèges root) ---
# Recensement AVANT le touch : tout processus R vivant à cet instant exécute
# l'ancien code, donc est obsolète par construction. Le faire après ouvrirait
# une fenêtre où l'on tuerait le processus tout juste démarré par un visiteur.
STALE_PIDS=""
PROC_DIR="${PROC_DIR:-/proc}"   # paramétré pour rendre la sélection testable
if [ "${DEPLOY_KILL_STALE:-1}" = "1" ] && [ -d "$PROC_DIR" ]; then
  for p in $(pgrep -u "$CURRENT_USER" -f 'SockJSAdapter' 2>/dev/null || true); do
    # Le cwd est le SEUL discriminant : la ligne de commande est identique pour
    # test et prod. Comparaison exacte — « TerraCEN » ne doit pas matcher
    # « TerraCEN-Test », et réciproquement.
    if [ "$(readlink -f "$PROC_DIR/$p/cwd" 2>/dev/null || true)" = "$APP_DIR" ]; then
      STALE_PIDS="$STALE_PIDS $p"
    fi
  done
fi

if ! touch "$APP_DIR/restart.txt" 2>/dev/null; then
  die "impossible d'écrire restart.txt — vérifiez les permissions du répertoire"
fi
info "restart.txt mis à jour — shiny-server rechargera l'app à la prochaine visite."

# --- 6b. Arrêt des processus rendus obsolètes ---
# Sans cela ils s'empilent : app_idle_timeout élevé (démarrage à chaud) empêche
# shiny-server de récupérer un processus même sans connexion, et chaque
# déploiement en ajoute un de ~400 Mo — jusqu'à saturer la RAM.
# DEPLOY_KILL_STALE=0 pour désactiver (les sessions en cours sont interrompues).
if [ -n "${STALE_PIDS// /}" ]; then
  info "Processus R obsolètes :$STALE_PIDS — arrêt…"
  kill -TERM $STALE_PIDS 2>/dev/null || true
  REMAINING="$STALE_PIDS"
  for _ in $(seq 1 10); do
    sleep 0.5
    NEXT=""
    for p in $REMAINING; do
      if kill -0 "$p" 2>/dev/null; then NEXT="$NEXT $p"; fi
    done
    REMAINING="$NEXT"
    [ -z "${REMAINING// /}" ] && break
  done
  if [ -n "${REMAINING// /}" ]; then
    warn "⚠️  toujours vivants après 5 s :$REMAINING — SIGKILL."
    kill -KILL $REMAINING 2>/dev/null || true
  fi
  info "Mémoire des processus obsolètes libérée."
else
  info "Aucun processus R obsolète à arrêter."
fi

VERSION_STR="$(cat "$APP_DIR/VERSION" 2>/dev/null || echo '?')"
if [ "$MODE" = "test" ]; then
  TARGET_DESC="$BRANCH ($(git rev-parse --short HEAD))"
else
  TARGET_DESC="$TAG"
fi
info "Déploiement TerraCEN [$MODE] → $TARGET_DESC (VERSION $VERSION_STR) terminé ✅"
PREVIOUS_REF=""  # Succès : pas de rollback nécessaire
