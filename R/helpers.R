# helpers.R
library(DBI)
library(glue)
library(sf)
library(dplyr)
library(leaflet)

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Flags de debug pilotables par variable d'environnement (défaut FALSE en prod).
# Pour activer côté test, définir dans ~shiny/.Renviron (sans modifier ce fichier,
# ce qui évite les conflits git au déploiement) :
#   TERRACEN_DEBUG=TRUE
#   TERRACEN_DEBUG_SQL=TRUE
#   TERRACEN_CACHE_DEBUG=TRUE
DEBUG     <- isTRUE(as.logical(Sys.getenv("TERRACEN_DEBUG", "FALSE")))
DEBUG_SQL <- isTRUE(as.logical(Sys.getenv("TERRACEN_DEBUG_SQL", "FALSE")))

# Si TRUE, les fonctions de cache (get_sites_coords, draw_parcelles_selectionnees)
# affichent des messages [cache] dans les logs pour diagnostiquer hit/miss.
CACHE_DEBUG <- isTRUE(as.logical(Sys.getenv("TERRACEN_CACHE_DEBUG", "FALSE")))

# Niveau de zoom minimum à partir duquel les parcelles cadastrales s'affichent.
ZOOM_CADASTRE_MIN <- 16

# Vue par défaut des cartes (Ariège) — partagée par init_map_base et les
# setView de réinitialisation des modules (valeurs auparavant en dur 7×).
MAP_DEFAULT_LNG  <- 1.5
MAP_DEFAULT_LAT  <- 43.0
MAP_DEFAULT_ZOOM <- 9.3

# Accent de l'interface, pour les arguments R qui attendent une couleur et où
# var() n'a pas cours — les spinners de shinybusy. Doit suivre le jeton
# --c-bleu-moyen de www/app.css, qui porte la même teinte côté CSS.
COULEUR_SPINNER <- "#2f5d50"

# Plafond de sélection en masse par rectangle : au-delà, la sélection est
# refusée (perf UI/DB). Partagé par Sites, Parcelles et Stratégie.
MAX_PARCELLES_RECTANGLE <- 5000

# Source géométrique posée à la création d'une parcelle (table de liaison
# gestcons.parcelles_sources_geom, dictionnaire dico_source_geom_parcelle).
# Elle alimente la colonne source_geom_parc_nature de l'export FCEN
# (vue v_fcen_parcelle_cen_04), qui traduit ces ids en codes de la
# nomenclature nationale : 4 -> 3, 2 -> 1.
# Statut « En cours d'élaboration » dans gestcons.dico_type_statut_contrat.
# Les autres : 3 Actif, 4 Suspendu, 5 Terminé, 6 Résilié.
STATUT_CONTRAT_ELABORATION <- 1L
STATUT_CONTRAT_ACTIF       <- 3L
STATUT_CONTRAT_SUSPENDU    <- 4L
STATUT_CONTRAT_TERMINE     <- 5L
STATUT_CONTRAT_RESILIE     <- 6L

# Contrôles de cohérence d'un contrat, partagés par les quatre points
# d'enregistrement — création et édition, foncier et agricole.
#
# Rend un message, ou NULL si tout se tient. Chaque contrôle porte sur un
# COUPLE de champs : un champ pris isolément est déjà validé par sa saisie.
#
# Aucun de ces contrôles n'a de faux positif : les 33 lignes qui les violaient
# ont été corrigées le 2026-10-28, et la base en compte zéro depuis. Ce sont
# donc des garde-fous pour la suite, pas des filets sous des données douteuses.
#
# Ce qui est VOLONTAIREMENT absent, et ne doit pas y être ajouté comme
# blocage : une signature postérieure au début (un bail peut prendre effet
# avant d'être signé — 5 contrats réels dans ce cas) et un statut « Actif »
# dont la date de fin est passée (c'est une péremption, pas une erreur de
# saisie). Ces deux-là relèvent de l'avertissement.
#
# @param duree_type  "sup18" / "inf18" / NULL — tiré du libellé du type de
#   maîtrise. La durée doit alors s'accorder au type déclaré.
# @return NULL si tout se tient, sinon list(champ, message). `champ` est le
#   suffixe du champ à incriminer — « date_fin », « date_rupture » — pour que
#   le message s'affiche SOUS lui et non dans un coin de l'écran.
valider_contrat <- function(date_debut = NULL, date_fin = NULL,
                            date_rupture = NULL, statut_id = NULL,
                            duree_type = NULL) {
  .d <- function(x) {
    if (is.null(x) || length(x) == 0) return(NULL)
    x <- suppressWarnings(as.Date(x))
    if (length(x) == 0 || is.na(x[1])) NULL else x[1]
  }
  deb <- .d(date_debut); fin <- .d(date_fin); rup <- .d(date_rupture)
  st  <- if (is.null(statut_id) || !nzchar(as.character(statut_id)[1])) NA_integer_
         else suppressWarnings(as.integer(statut_id)[1])

  if (!is.null(deb) && !is.null(fin) && deb > fin)
    return(list(champ = "date_fin", message = "La date de début est postérieure à la date de fin."))

  if (identical(st, STATUT_CONTRAT_RESILIE) && is.null(rup))
    return(list(champ = "date_rupture", message = "Un contrat résilié doit porter sa date de rupture."))

  if (!is.null(rup) && !is.null(deb) && rup < deb)
    return(list(champ = "date_rupture", message = "La date de rupture précède le début du contrat."))
  if (!is.null(rup) && !is.null(fin) && rup > fin)
    return(list(champ = "date_rupture", message = "La date de rupture est postérieure à la fin du contrat."))

  # Durée contre type déclaré. 18 ans comptés en jours sur l'année julienne :
  # la bascule se joue à la journée près et une année calendaire moyenne
  # décalerait la limite de quelques jours selon les bissextiles traversées.
  if (!is.null(duree_type) && !is.null(deb) && !is.null(fin)) {
    ans <- as.numeric(fin - deb) / 365.25
    if (identical(duree_type, "sup18") && ans < 18)
      return(list(champ = "date_fin", message = sprintf(paste0(
        "Le type annonce un contrat de gestion de 18 ans ou plus, mais la ",
        "période n'en couvre que %.1f."), ans)))
    if (identical(duree_type, "inf18") && ans >= 18)
      return(list(champ = "date_fin", message = sprintf(paste0(
        "Le type annonce un contrat de gestion de moins de 18 ans, mais la ",
        "période en couvre %.1f."), ans)))
  }
  NULL
}

# Lit le type de durée dans le libellé du type de maîtrise.
# ⚠️ C'est `libelle_mfu1` qui porte la distinction, PAS `libelle_mfu2` — ce
# dernier vaut « convention d'usage / de gestion / de mise à disposition »
# pour les deux.
duree_type_maitrise <- function(libelle) {
  if (is.null(libelle) || !length(libelle) || is.na(libelle[1])) return(NULL)
  l <- tolower(libelle[1])
  if (!grepl("18", l, fixed = TRUE)) return(NULL)
  if (grepl("\u2265|>=|sup", l)) "sup18" else if (grepl("<|inf", l)) "inf18" else NULL
}

# Types de site (gestcons.dico_type_site). Définis ICI et non dans
# mod_strategie.R : helpers.R est chargé en premier, et la couche des sites
# voisins en a besoin pour distinguer un secteur d'un site conservatoire.
TYPE_SITE_CONSERVATOIRE <- 1L
TYPE_SITE_SECTEUR       <- 2L

SOURCE_GEOM_PCI      <- 4L  # plan cadastral informatisé — parcelle cadastrale
SOURCE_GEOM_MANUELLE <- 2L  # numérisation manuelle CEN — polygone dessiné

# Accessibilité d'un site au public (gestcons.dico_accessibilite : 0 Non,
# 1 Oui, 2 Partielle). « Oui » par défaut, comme le DEFAULT de la colonne.
ACCESSIBILITE_SITE_DEFAUT <- 1L
ACCESSIBILITE_NON         <- 0L

# Noms de groupes centralisés (évite les typos)
GROUPS <- list(
  site        = "Parcelles du site",       # persistant
  cadastre    = "Parcelles cadastrales",   # persistant
  perimetres  = "Périmètres manuels",      # persistant (si tu l’as)
  selection   = "Parcelle sélectionnée",   # éphémère (ton orange)
  drawn       = "Polygones",               # éphémère (shapes dessinés)
  highlight   = "highlight",               # éphémère (si tu l’utilises)
  protection  = "Zones de Protection",
  zones_humides = "Zones humides",          # persistant, décoché par défaut
  voisins     = "Sites voisins",            # persistant, décoché par défaut
  communes    = "Limites communales"        # persistant, décoché par défaut
)

# Zones de protection : un groupe Leaflet PAR TYPE, pour que le contrôle des
# couches laisse choisir ce qu'on affiche plutôt que de tout allumer d'un coup
# (huit types en base : APPB, Natura 2000 ZPS et ZSC, RBD, RNCFS, RNR, ZNIEFF1
# et ZNIEFF2). Le préfixe sert aussi côté client : www/app.js regroupe sur lui
# toutes ces entrées sous un seul volet de l'accordéon, et l'efface à
# l'affichage pour ne laisser que le type.
PROTECTION_PREFIXE <- "Protection : "

protection_type_libelle <- function(x) {
  x <- as.character(x %||% character(0))
  x[is.na(x) | !nzchar(x)] <- "Non spécifié"
  x
}

protection_groupes <- function(zones_protection_data) {
  if (is.null(zones_protection_data) || !NROW(zones_protection_data)) return(character(0))
  paste0(PROTECTION_PREFIXE, sort(unique(protection_type_libelle(zones_protection_data$type))))
}

# Listes utiles
PERSISTENT_GROUPS <- c(GROUPS$site, GROUPS$cadastre, GROUPS$perimetres, GROUPS$protection,
                       GROUPS$zones_humides, GROUPS$voisins, GROUPS$communes) 
EPHEMERAL_GROUPS  <- c(GROUPS$selection, GROUPS$drawn, GROUPS$highlight, "Sélection", "Selection", "drawn")


# Définition des couleurs des parcelles par statut (centralisé)
COLORS_PARCELLES <- list(
  # Actif (bleu foncé)
  actif_fill      = "#0b5ed7", 
  actif_outline   = "#87aeea",
  # Draft (jaune/orange)
  draft_fill      = "#ffbb00",
  draft_outline   = "#f97316",
  # Autre (rouge/gris)
  other_fill      = "#e25f62",
  other_outline   = "#52525b"
)

# URLs des fonds de carte IGN (Géoportail). Modifiable ici en cas de
# changement de clé API ou de couche.
IGN_CARTES_URL <- paste0(
  "https://data.geopf.fr/private/wmts?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetTile",
  "&apikey=ign_scan_ws&LAYER=GEOGRAPHICALGRIDSYSTEMS.MAPS",
  "&EXCEPTIONS=text/xml&TILEMATRIXSET=PM",
  "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg&STYLE=normal"
)
IGN_SATELLITES_URL <- paste0(
  "https://data.geopf.fr/wmts?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetTile",
  "&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&TILEMATRIXSET=PM",
  "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg&STYLE=normal"
)

# Initialise la base d'une carte Leaflet : 4 panes standard (cadastre/site/
# selection/manuels, zIndex 410-440), 3 fonds (OSM + IGN Cartes + IGN
# Satellites) et vue par défaut centrée sur l'Ariège. Chaque module ajoute
# ensuite ses overlays et son addLayersControl propres.
init_map_base <- function(options = leaflet::leafletOptions(boxZoom = FALSE),
                          center_lng = MAP_DEFAULT_LNG,
                          center_lat = MAP_DEFAULT_LAT,
                          zoom = MAP_DEFAULT_ZOOM) {
  # Handler clavier désactivé, et forcé quelles que soient les options reçues.
  # Il rend le conteneur focusable (`tabIndex = "0"`) et, au mousedown, lui
  # donne le focus avant de restaurer le défilement par `window.scrollTo`. Or
  # ici le défilement appartient à `.right-rail-inner` (overflow:auto), pas à
  # la fenêtre : Leaflet remet donc en place un scroll qui n'a pas bougé et
  # laisse le div sauter pour rendre la carte visible. Le contenu se déplaçant
  # entre mousedown et mouseup, aucun clic n'est émis — cliquer une parcelle
  # après avoir fait défiler la page ne faisait que remonter la vue. On perd
  # le déplacement de la carte aux flèches, qui exigeait de toute façon de
  # cliquer d'abord dessus.
  options$keyboard <- FALSE
  leaflet::leaflet(options = options) %>%
    # Bouton plein écran sur toutes les cartes d'onglet (Sites, Parcelles,
    # Actions, Stratégie). pseudoFullscreen = TRUE : la carte remplit la fenêtre
    # du navigateur -> les modales restent utilisables (z-index relevé, app.R).
    # Les cartes modales (Actions) utilisent leaflet() direct : non concernées.
    leaflet.extras::addFullscreenControl(position = "topleft", pseudoFullscreen = TRUE) %>%
    # Zones humides : pane le plus bas de tous, la couche ne doit jamais
    # masquer une parcelle (elle est surfacique et semi-opaque).
    leaflet::addMapPane("zh",        zIndex = 405) %>%
    # Sites voisins : au-dessus des zones humides, mais SOUS le cadastre et le
    # site courant — c'est une couche de contexte, elle ne doit jamais prendre
    # le pas sur ce qu'on est en train d'éditer.
    leaflet::addMapPane("voisins",   zIndex = 407) %>%
    leaflet::addMapPane("cadastre",  zIndex = 410) %>%
    # Limites communales : JUSTE au-dessus du cadastre, pas en dessous. Un
    # trait de limite noyé sous des aplats de parcelles ne se suit plus d'un
    # bout à l'autre de l'écran, et c'est tout ce qu'on lui demande. La couche
    # est non interactive (cf. refresh_limites_communales) : le clic traverse
    # et atteint la parcelle, qui reste l'objet de travail.
    leaflet::addMapPane("communes",  zIndex = 412) %>%
    # Continuité du site conservatoire : pane dédié JUSTE au-dessus du cadastre, et sous les
    # parcelles du site (420) — exactement l'empilement obtenu jusqu'ici en le
    # redessinant après le cadastre à chaque déplacement de carte. Avec un pane,
    # l'ordre ne dépend plus de l'ordre de dessin : le redessin devient inutile.
    leaflet::addMapPane("perimetre", zIndex = 415) %>%
    leaflet::addMapPane("site",      zIndex = 420) %>%
    leaflet::addMapPane("selection", zIndex = 430) %>%
    leaflet::addMapPane("manuels",   zIndex = 440) %>%
    leaflet::addTiles(group = "OpenStreetMap") %>%
    leaflet::addTiles(
      urlTemplate = IGN_CARTES_URL,
      attribution = "IGN Géoportail",
      group = "IGN Cartes"
    ) %>%
    leaflet::addTiles(
      urlTemplate = IGN_SATELLITES_URL,
      attribution = "IGN – Orthophotos",
      group = "IGN Satellites"
    ) %>%
    # Charge la dépendance JS de la barre de dessin dès la création de la carte,
    # puis la retire aussitôt (pas de barre visible). Sans ça, un premier appel
    # proxy à removeDrawToolbar() — avant tout addDrawToolbar() — déclenche
    # « Unknown method removeDrawToolbar » côté client (méthode pas encore chargée).
    leaflet.extras::addDrawToolbar() %>%
    leaflet.extras::removeDrawToolbar() %>%
    leaflet::setView(lng = center_lng, lat = center_lat, zoom = zoom)
}

# Barre de dessin standard (leaflet.extras) : tout désactivé sauf demandé.
# Factorise les 6 configurations quasi identiques des modules.
# - rectangle : "selection" (bleu, sélection de parcelles — Sites/Parcelles/
#   Stratégie), "discret" (gris léger — Actions/Contrats) ou FALSE ;
# - polygon   : TRUE = tracé de périmètre manuel (rouge, Sites) ;
# - edit_remove : TRUE = corbeille de suppression des formes (Actions).
add_std_draw_toolbar <- function(map, rectangle = "selection", polygon = FALSE,
                                 target_group = "Polygones", edit_remove = FALSE) {
  rect_opts <- if (identical(rectangle, "selection")) {
    leaflet.extras::drawRectangleOptions(
      shapeOptions = leaflet.extras::drawShapeOptions(color = "blue", weight = 2))
  } else if (identical(rectangle, "discret")) {
    leaflet.extras::drawRectangleOptions(
      repeatMode = FALSE,
      shapeOptions = leaflet.extras::drawShapeOptions(color = "#222", weight = 1, fillOpacity = 0.1))
  } else FALSE

  leaflet.extras::addDrawToolbar(
    map,
    targetGroup = target_group,
    polylineOptions = FALSE,
    polygonOptions = if (isTRUE(polygon)) {
      leaflet.extras::drawPolygonOptions(
        shapeOptions = leaflet.extras::drawShapeOptions(color = "red", weight = 2))
    } else FALSE,
    rectangleOptions = rect_opts,
    circleOptions = FALSE,
    circleMarkerOptions = FALSE,
    markerOptions = FALSE,
    editOptions = if (isTRUE(edit_remove)) {
      leaflet.extras::editToolbarOptions(edit = FALSE, remove = TRUE)
    } else FALSE
  )
}

# Périmètres tracés mais pas encore enregistrés, dessinés DEPUIS L'ÉTAT.
#
# ⚠️ Leaflet.Draw dépose rectangles et polygones dans le MÊME groupe,
# « Polygones », et le rectangle de sélection vide ce groupe après chaque
# usage (clear_rect, dans Sites et dans Stratégie). Les tracés en attente
# disparaissaient donc de l'écran dès qu'on sélectionnait des parcelles, tout
# en restant dans l'état — et partaient à l'enregistrement sans avoir été
# revus. Constat Moyen 2 de l'audit du 2026-10-28, confirmé à l'écran.
#
# Désormais la forme de Leaflet.Draw est retirée dès sa capture, et c'est ce
# groupe-ci, redessiné à chaque changement de l'état, qui affiche les tracés :
# l'écran ne peut plus diverger de ce qui sera enregistré.
GROUPE_TRACES_ATTENTE <- "Périmètres en attente"

# Polygone sf (WGS84) depuis une forme Leaflet.Draw, ou NULL si elle n'en
# fait pas un exploitable. Leaflet ne referme pas toujours l'anneau ; sf l'exige.
polygone_depuis_trace <- function(feat) {
  coords <- tryCatch(feat$geometry$coordinates[[1]], error = function(e) NULL)
  if (is.null(coords) || length(coords) < 3) return(NULL)
  mat <- tryCatch(do.call(rbind, lapply(coords, function(pt) {
    suppressWarnings(c(as.numeric(pt[[1]]), as.numeric(pt[[2]])))
  })), error = function(e) NULL)
  if (is.null(mat) || ncol(mat) != 2 || any(!is.finite(mat))) return(NULL)
  if (!all(mat[1, ] == mat[nrow(mat), ])) mat <- rbind(mat, mat[1, ])
  if (nrow(mat) < 4) return(NULL)
  tryCatch(sf::st_polygon(list(mat)), error = function(e) NULL)
}

draw_traces_en_attente <- function(polys, map_id, session) {
  prx <- leaflet::leafletProxy(map_id, session = session) %>%
    leaflet::clearGroup(GROUPE_TRACES_ATTENTE)
  geoms <- Filter(Negate(is.null), lapply(polys %||% list(), polygone_depuis_trace))
  if (length(geoms) == 0) return(invisible())
  prx %>% leaflet::addPolygons(
    data = sf::st_sfc(geoms, crs = 4326), group = GROUPE_TRACES_ATTENTE,
    # Le style EXACT de l'outil de tracé (add_std_draw_toolbar) : trait rouge
    # d'épaisseur 2, et l'aplat par défaut de drawShapeOptions, bleu #03f à
    # 0,4, que le réglage du trait laisse en place. Rien ne doit changer à
    # l'œil quand la forme de Leaflet.Draw est remplacée par celle-ci.
    color = "red", weight = 2, opacity = 1,
    fillColor = "#03f", fillOpacity = 0.4,
    # Pane des périmètres manuels, au-dessus du cadastre ; non interactif, pour
    # que le clic atteigne la parcelle qui se trouve dessous.
    options = leaflet::pathOptions(pane = "manuels", interactive = FALSE))
  invisible()
}

# 🟢 Définition Centralisée des Couleurs des Zones de Protection
COLORS_PROTECTION <- c(
  "APPB" = "#FFD700",
  "Natura 2000 - ZPS" = "#00CED1",
  "Natura 2000 - ZSC" = "#20B2AA",
  "RBD" = "#FF5757",
  "RNCFS" = "#4169E1",
  "RNR" = "#228B22",
  "ZNIEFF1" = "#DDDDDD",
  "ZNIEFF2" = "#A9A9A9",
  "Non spécifié" = "#DDDDDD"
)

# --------- Helpers génériques Leaflet ---------

.to_logi <- function(x) {
  if (is.logical(x)) return(x)
  x %in% c(TRUE, "t", "T", 1, "1")
}

# Tolérance ST_Simplify (mètres) adaptée au niveau de zoom Leaflet.
# Plus on dézoome, plus on accepte de "lisser" les géométries pour réduire
# le volume transmis. Les parcelles cadastrales n'étant affichées qu'à partir
# de ZOOM_CADASTRE_MIN (16), on se limite à 2 paliers :
#   zoom 16  → 2 m   (vue la plus large, volontairement plus grossière)
#   zoom 17+ → 0,5 m (un seul palier au-delà)
# Les anciens paliers plus fins (1 m / 0,5 m / 0,25 m de 17 à 19+) étaient
# visuellement indistinguables et déclenchaient un redraw cadastre à chaque
# cran de zoom. Avec 2 paliers, seul le passage 16→17 redessine ; de 17 à 22
# la tolérance ne change plus → pas de redraw inutile au zoom.
simplify_tolerance <- function(zoom) {
  if (is.null(zoom) || !is.finite(zoom)) return(1.0)
  if (zoom < 17) 2.0 else 0.5
}

# Helpers d'interpolation SQL sûrs.
# Quoting ANSI (DBI::ANSI()) : indépendant de toute connexion. Valide pour
# PostgreSQL (apostrophes doublées, NA -> NULL, dates en 'YYYY-MM-DD'). On évite
# ainsi la dépendance fragile à un `con` global qui pouvait être non résolu dans
# le contexte d'appel (glue) -> « Failed to evaluate glue component ».
sql_int <- function(x) {
  xi <- suppressWarnings(as.integer(x))
  if (is.null(x) || is.na(xi)) "NULL" else as.character(xi)
}
sql_bool <- function(b) if (isTRUE(b)) "TRUE" else "FALSE"

# Emprise de carte envoyée par le navigateur (`input$map_bounds`), réduite à
# quatre nombres finis — ou NULL si elle n'en est pas. ⚠️ Ces valeurs viennent
# du CLIENT : un message websocket forgé peut y mettre n'importe quelle chaîne,
# et elles finissent dans du SQL (`ST_MakeEnvelope`). Les helpers de couche y
# échappaient déjà parce qu'ils leur retranchent une marge — l'arithmétique R
# refuse une chaîne —, mais pas les interpolations directes. Audit du
# 2026-10-28, constat Moyen 3.
bounds_num <- function(bounds) {
  if (is.null(bounds)) return(NULL)
  cles <- c("west", "south", "east", "north")
  v <- suppressWarnings(vapply(cles, function(k) as.numeric(bounds[[k]] %||% NA)[1],
                               numeric(1)))
  if (any(!is.finite(v))) return(NULL)
  as.list(v)
}
sql_date <- function(d) DBI::dbQuoteLiteral(DBI::ANSI(), as.character(d))
sql_txt  <- function(s) {
  if (is.null(s)) return("NULL")
  DBI::dbQuoteLiteral(DBI::ANSI(), as.character(s))
}

# Fragment SQL : libellé lisible d'un propriétaire (table dico_proprietaire,
# alias par défaut `dp`) — dnomus + 1er prénom d'usage si présents, sinon
# ddenom. Source UNIQUE de l'expression (elle était recopiée dans 11 requêtes) ;
# variante btrim retenue (la plus robuste des ex-copies : ignore les valeurs
# blanches, pas d'espace parasite). À interpoler dans les requêtes glue.
sql_proprio_label <- function(alias = "dp") {
  glue::glue("
    CASE
      WHEN NULLIF(btrim({alias}.dnomus), '') IS NULL THEN {alias}.ddenom
      ELSE {alias}.dnomus ||
           CASE WHEN NULLIF(btrim({alias}.dprnlp), '') IS NULL
                THEN '' ELSE ' ' || split_part({alias}.dprnlp, ' ', 1)
           END
    END")
}

# Reactive « utilisateur à enregistrer en DB » : id dico_utilisateur en
# caractère (pour dbQuoteLiteral), fallback login système si non résolu.
# Fabrique commune aux modules (Sites, Parcelles, Actions, Stratégie), qui
# dupliquaient tous ce reactive à l'identique.
make_user_to_db <- function(current_user_rv) {
  shiny::reactive({
    user_row <- current_user_rv()
    if (is.null(user_row) || nrow(user_row) == 0 || is.na(user_row$id[1])) {
      # Fallback: retourne le login de session (doit être un caractère pour la DB)
      return(Sys.getenv("USER", "system"))
    }
    as.character(user_row$id[1])
  })
}

# Emprise WGS84 c(xmin, ymin, xmax, ymax) d'un ensemble de géométries, calculée
# côté PostGIS (ST_Extent). `geom_sql` : requête renvoyant une colonne g
# (geometry, SRID quelconque). NULL si aucune géométrie.
get_bbox_4326 <- function(con, geom_sql) {
  bb <- safe_db_query(con, glue::glue("
    SELECT ST_XMin(e) AS xmin, ST_YMin(e) AS ymin,
           ST_XMax(e) AS xmax, ST_YMax(e) AS ymax
    FROM (SELECT ST_Extent(ST_Transform(g, 4326)) AS e FROM ({geom_sql}) t) t2
  "))
  if (is.null(bb) || nrow(bb) == 0 || any(is.na(bb[1, ]))) return(NULL)
  as.numeric(bb[1, c("xmin", "ymin", "xmax", "ymax")])
}

# Emprise WGS84 d'un site : parcelles cadastrales, périmètres manuels (type 2)
# et, si demandé, continuité du site conservatoire (Stratégie). Remplace les implémentations
# dispersées (compute_site_bbox_4326 d'app.R — qui passait par la lourde
# get_parcelles_by_site —, requête ad hoc de Stratégie). NULL si site vide.
#
# ⚠️ Lire `parcelles_base`, JAMAIS la vue de compatibilité `parcelles` : celle-ci
# filtre `NOT perimetre`. Un secteur, dont TOUTES les parcelles portent
# `perimetre = true`, n'en ressortait donc jamais — et les 31 secteurs à
# géométrie manuelle seule n'avaient aucune emprise du tout, la carte restant
# cadrée sur l'Ariège. Le drapeau est porté ici par une condition unique,
# appliquée aux deux types de parcellaire ; l'ancienne troisième branche ne
# rattrapait que le cadastre, et sans filtre de type elle exposait la jointure
# polymorphe `parcellaire_id` à une collision avec `dico_cadastre`.
site_bbox_4326 <- function(con, site_id, include_manuels = TRUE, include_perimetre = FALSE) {
  if (is.null(site_id) || is.na(site_id)) return(NULL)
  sid <- as.integer(site_id)
  cond <- if (include_perimetre) "TRUE" else "NOT p.perimetre"
  parts <- c(
    glue::glue("SELECT c.geompar AS g
                 FROM gestcons.parcelles_base p
                 JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
                WHERE p.site_id = {sid} AND p.type_parcelle_id = 1 AND {cond}"),
    if (include_manuels) glue::glue(
               "SELECT m.geometrie AS g
                 FROM gestcons.parcelles_base p
                 JOIN gestcons.perimetre_parcellaire_manuel m ON m.id = p.parcellaire_id
                WHERE p.site_id = {sid} AND p.type_parcelle_id = 2 AND {cond}")
  )
  get_bbox_4326(con, paste(parts, collapse = "\nUNION ALL\n"))
}

# Fabrique du rafraîchisseur de la liste des sites d'un sélecteur. Relit
# gestcons.sites et met à jour le selectize, en conservant la sélection
# courante si toujours valide (ou `select` si fourni, ex. après création d'un
# site).
make_refresh_sites_choices <- function(con, session, input, input_id = "site_selector") {
  function(select = NULL) {
    debug_print("refresh_sites_choices <- function")
    df <- safe_db_query(con, "SELECT id, libelle FROM gestcons.sites
                              WHERE type_site_id = 1 ORDER BY libelle")
    choices <- c(" " = "", setNames(df$id, df$libelle))

    sel <- if (!is.null(select)) as.character(select) else shiny::isolate(input[[input_id]])
    ids_char <- as.character(df$id)
    if (is.null(sel) || !(sel %in% c("", ids_char))) sel <- ""

    updateSelectizeInput(session, input_id, choices = choices, selected = sel)
  }
}

# Active/désactive un bouton de soumission selon que TOUS les champs requis sont
# remplis (non vides). À appeler dans un observe() pour réagir aux saisies.
# - button_id     : id (non namespacé) du bouton, ex. "create_site"
# - required_ids  : vecteur d'ids (non namespacés) des inputs obligatoires
# shinyjs gère automatiquement le namespace via la session du module.
toggle_submit_state <- function(input, button_id, required_ids) {
  # Non vide : gère scalaires, multi-select (selectize), et objets non-null
  # (ex. fileInput renvoie un data.frame une fois un fichier chargé).
  nz <- function(x) {
    x <- x %||% ""
    length(x) >= 1 && any(nzchar(as.character(x)), na.rm = TRUE)
  }
  ok <- all(vapply(required_ids, function(id) nz(input[[id]]), logical(1)))
  shinyjs::toggleState(button_id, condition = ok)
}

# Habillage d'un graphique plotly selon le mode clair/sombre.
#
# Plotly rend du SVG : ses couleurs sont des attributs, pas du CSS, et ne
# suivent donc pas le data-bs-theme posé par le sélecteur de la barre du haut.
# Il faut les lui passer explicitement. Les fonds sont transparents dans les
# deux modes : le graphique prend la surface qui est derrière lui.
#
# Les couleurs des séries ne sont pas touchées : comme celles de la carte,
# elles portent un sens.
plotly_habillage <- function(sombre = FALSE) {
  if (isTRUE(sombre)) {
    list(fond = "rgba(0,0,0,0)", texte = "#e9ece8",
         grille = "#2c342e", survol = "#191e1a")
  } else {
    list(fond = "rgba(0,0,0,0)", texte = "#1a211d",
         grille = "#dfe3de", survol = "#ffffff")
  }
}

# Trace applicative d'une action de MODIFICATION : horodatage, utilisateur,
# IP, description — une ligne par action métier dans le log Shiny, ex. :
#   2026-07-13 10:22:33  - [prenom.n@ariegenature.fr @ 10.0.1.42] Création du site « X » (id 123)
# Complément lisible du journal gestcons.audit_log (triggers : table/ligne/site,
# mais sans utilisateur ni IP). NB : identité EFFECTIVE (comme modifie_par) —
# en impersonation, c'est le profil emprunté qui est tracé.
log_action <- function(session, current_user_rv, description) {
  user <- tryCatch({
    u <- current_user_rv()
    if (!is.null(u) && nrow(u) > 0 && !is.na(u$email[1])) u$email[1] else "?"
  }, error = function(e) "?")
  ip <- tryCatch(session$request$REMOTE_ADDR %||% "?", error = function(e) "?")
  log_time(paste0("[", user, " @ ", ip, "] ", description))
}

log_time <- function(txt) {
  message(format(Sys.time(), "%Y-%m-%d %H:%M:%S "), " - ", txt)
}

close_map_tooltips <- function(map_id, session = shiny::getDefaultReactiveDomain()) {
  if (!is.null(session)) session$sendCustomMessage("closeLeafletTooltips", map_id)
}

# Message contextuel « 🔍 Zoomez davantage pour afficher les parcelles
# cadastrales » (cadastre visible dès ZOOM_CADASTRE_MIN) : overlay centré en
# bas du conteneur de carte, fondu automatique après 4 s. Position non native
# dans Leaflet, d'où l'injection directe dans la div de la carte.
# map_id / hint_id : ids NAMESPACÉS (ns("map"), ns("zoom_cadastre_hint")).
# Utilisé par Sites et Stratégie.
show_zoom_hint <- function(map_id, hint_id) {
  shinyjs::runjs(sprintf(
    "(function(){var m=document.getElementById('%s');if(!m)return;var old=document.getElementById('%s');if(old)old.remove();var d=document.createElement('div');d.id='%s';d.innerHTML='\\uD83D\\uDD0D Zoomez davantage pour afficher les parcelles cadastrales';d.style.cssText='position:absolute;bottom:14px;left:50%%;transform:translateX(-50%%);z-index:1000;pointer-events:none;background:rgba(255,255,255,0.92);padding:6px 12px;border-radius:6px;box-shadow:0 1px 4px rgba(0,0,0,.3);font-size:13px;color:#b35900;font-weight:500;white-space:nowrap;';m.appendChild(d);d.animate([{opacity:1},{opacity:1,offset:0.7},{opacity:0}],{duration:4000,fill:'forwards'});})();",
    map_id, hint_id, hint_id
  ))
}
hide_zoom_hint <- function(hint_id) {
  shinyjs::runjs(sprintf("var d=document.getElementById('%s');if(d)d.remove();", hint_id))
}

# Vide plusieurs groupes Leaflet d'un coup, chaînable dans un pipe :
#   leafletProxy(...) %>% clear_groups(c("A", "B")) %>% showGroup("C")
# Remplace les enfilades de clearGroup() recopiées dans les modules carte.
clear_groups <- function(prx, groups) {
  for (g in groups) prx <- leaflet::clearGroup(prx, g)
  prx
}

# Désélectionne lignes/colonnes d'un tableau DT via proxy, sans erreur si le
# proxy est indisponible. Remplace le bloc try(dataTableProxy...) recopié dans
# les modules Acteurs/Utilisateurs.
reset_dt_selection <- function(output_id, session) {
  prx <- try(DT::dataTableProxy(outputId = output_id, session = session), silent = TRUE)
  if (!inherits(prx, "try-error")) {
    try(DT::selectRows(prx, NULL), silent = TRUE)
    try(DT::selectColumns(prx, NULL), silent = TRUE)
  }
  invisible(NULL)
}

# --- Composant « documents joints » (Actions & Contrats) --------------------
# Les deux modules géraient à l'identique la liste, l'ajout et la suppression
# des pièces jointes ; seuls varient la table, la colonne FK et le sous-dossier
# de stockage. Fonctions paramétrées — les observers restent dans les modules
# (droits d'édition et triggers de rechargement spécifiques).

# Extensions acceptées à l'upload (fileInput des deux modules)
DOCS_FILE_ACCEPT <- c(".pdf", ".doc", ".docx", ".xls", ".xlsx",
                      ".png", ".jpg", ".jpeg", ".tif", ".tiff",
                      ".odt", ".ods", ".txt", ".csv", ".zip")

# Contrôle SERVEUR de l'extension d'un fichier téléversé.
#
# DOCS_FILE_ACCEPT ne servait jusqu'ici que d'attribut « accept » sur les
# fileInput : un filtre de boîte de dialogue côté navigateur, jamais revérifié.
# Or app.R publie tout l'arbre des documents par addResourcePath, donc sous la
# MÊME origine que l'application, et la liste les ouvre dans un onglet. Un
# .html ou un .svg téléversé s'y exécuterait avec le cookie de session de la
# personne qui clique. Un POST multipart direct suffit à contourner « accept ».
#
# L'extension retenue est la DERNIÈRE : « note.pdf.html » est donc refusé, et
# « note.html.pdf » accepté puis servi en PDF. Lève une erreur, à intercepter
# par l'appelant.
verifier_extension_doc <- function(nom_fichier, accept = DOCS_FILE_ACCEPT) {
  nom <- basename(nom_fichier %||% "")
  ext <- if (grepl("\\.[^.]+$", nom)) tolower(sub("^.*(\\.[^.]+)$", "\\1", nom)) else ""
  if (!nzchar(ext) || !(ext %in% accept)) {
    stop("Type de fichier refusé", if (nzchar(ext)) paste0(" (", ext, ")") else "",
         ". Formats acceptés : ", paste(accept, collapse = ", "), ".")
  }
  invisible(ext)
}

# Liste des documents d'une entité (contrat ou animation)
docs_fetch <- function(con, table, fk_col, parent_id) {
  safe_db_query(con, glue::glue("
    SELECT id, nom_fichier, url, type_document, date_creation, remarque
    FROM {table}
    WHERE {fk_col} = {as.integer(parent_id)}
    ORDER BY date_creation DESC NULLS LAST, id DESC
  "))
}

# Enregistre un fichier uploadé sous {docs_root}/{subdir}/ (nom assaini +
# horodaté pour l'unicité) puis insère la ligne. stop() si la copie échoue
# (à attraper côté appelant pour afficher un toast).
docs_add <- function(con, docs_root, table, fk_col, parent_id, subdir,
                     file, type, remarque) {
  verifier_extension_doc(file$name)
  original_name <- basename(file$name)
  safe_name <- gsub("[^A-Za-z0-9._-]", "_", original_name)

  dir.create(file.path(docs_root, subdir), recursive = TRUE, showWarnings = FALSE)
  rel_path <- file.path(subdir, paste0(format(Sys.time(), "%Y%m%d-%H%M%S-"), safe_name))
  abs_path <- file.path(docs_root, rel_path)

  ok <- tryCatch(file.copy(file$datapath, abs_path, overwrite = TRUE), error = function(e) FALSE)
  if (!isTRUE(ok) || !file.exists(abs_path)) {
    stop("Impossible de copier le fichier sur le serveur.")
  }

  url <- paste("docs", gsub("\\\\", "/", rel_path), sep = "/")

  # Le résultat de l'insertion est TESTÉ. Hors transaction, safe_db_execute
  # capture l'erreur et renvoie 0 : la fonction renvoyait donc TRUE alors que
  # le fichier était sur le disque et la ligne absente de la base. L'appelant
  # annonçait un succès, et la pièce jointe n'apparaissait nulle part.
  n <- safe_db_execute(con, glue::glue("
    INSERT INTO {table}
      ({fk_col}, nom_fichier, url, type_document, date_creation, remarque)
    VALUES (
      {as.integer(parent_id)},
      {DBI::dbQuoteLiteral(con, original_name)},
      {DBI::dbQuoteLiteral(con, url)},
      {DBI::dbQuoteLiteral(con, type %||% '')},
      NOW(),
      {DBI::dbQuoteLiteral(con, remarque %||% '')}
    )
  "))

  if (!isTRUE(as.integer(n) >= 1L)) {
    # Le fichier vient d'être copié : sans ce retrait il resterait orphelin sur
    # le disque, sans ligne pour le désigner ni moyen de le retrouver.
    try(unlink(abs_path), silent = TRUE)
    stop("Le document a été copié mais n'a pas pu être enregistré en base.")
  }
  invisible(TRUE)
}

# Supprime le fichier sur disque (chemin résolu depuis url, sinon nom_fichier)
# puis la ligne en base.
# Chemin absolu d'un document joint, d'après son URL ou son nom de fichier ; NA
# s'il n'en a pas. Extrait de docs_delete pour qu'un appelant puisse effacer
# les fichiers APRÈS avoir fait valider la suppression par la base (cf. la
# suppression d'une action, mod_actions.R).
docs_chemin <- function(docs_root, url = NA, nom_fichier = NA) {
  rel_path <- NA_character_
  if (!is.null(url) && length(url) == 1 && !is.na(url) && nzchar(url)) {
    rel_path <- sub("^/?docs/?", "", sub("^\\./", "", url))
  } else if (!is.null(nom_fichier) && length(nom_fichier) == 1 &&
             !is.na(nom_fichier) && grepl("/", nom_fichier)) {
    rel_path <- nom_fichier
  }
  if (is.na(rel_path) || !nzchar(rel_path)) return(NA_character_)
  file.path(docs_root, rel_path)
}

docs_delete <- function(con, docs_root, table, doc_id, url = NA, nom_fichier = NA) {
  abs_path <- docs_chemin(docs_root, url, nom_fichier)
  if (!is.na(abs_path) && file.exists(abs_path)) try(unlink(abs_path, force = TRUE), silent = TRUE)
  safe_db_execute(con, glue::glue("DELETE FROM {table} WHERE id = {as.integer(doc_id)}"))
  invisible(TRUE)
}

# Échappe les colonnes de saisie libre d'un tableau rendu en escape = FALSE.
#
# Plusieurs tableaux doivent rester en escape = FALSE pour une colonne qui porte
# vraiment du HTML — un lien, une icône d'action. Toutes les AUTRES colonnes y
# arrivent alors en HTML brut, y compris des champs saisis par les utilisateurs.
# Le puits est déjà alimenté : un acteur se nomme « Fiona & Floriane », un
# document « … Le Pla & Mijanès » — le rendu est donc déjà incorrect avant même
# qu'on parle d'injection.
echapper_colonnes <- function(df, cols) {
  for (col in intersect(cols, names(df))) {
    df[[col]] <- htmltools::htmlEscape(as.character(df[[col]]))
  }
  df
}

# --- Assainissement du HTML saisi par les utilisateurs ----------------------
# La description d'une action est saisie dans Summernote, dont la barre d'outils
# offre un bouton « codeview » : l'utilisateur tape donc du HTML brut, qui était
# réinjecté tel quel dans la fiche. Une balise <img src=x onerror=…> s'y
# exécutait dans la session de quiconque ouvrait la fiche, même origine, sans
# CSP — soit l'élévation d'un utilisateur authentifié vers un autre.
#
# Assaini au RENDU et non à l'écriture : la base garde ses 101 descriptions
# telles quelles, et les gabarits du rapport PDF, qui ont leur propre traitement
# des collages Word, continuent d'être alimentés comme avant.
#
# Ces balises partent AVEC leur contenu : il n'y a rien à y conserver, et c'est
# par elles que passe l'essentiel des injections.
HTML_BALISES_INTERDITES <- c("script", "style", "iframe", "object", "embed",
                             "svg", "math", "form", "input", "button",
                             "textarea", "select", "noscript", "base",
                             "meta", "link", "img", "xml")

# Tous les attributs tombent, sauf un href de schéma sûr sur <a> : plus de
# gestionnaire d'événement, plus de style, plus de src. Au passage, cela nettoie
# les attributs « mso-… » des descriptions collées depuis Word.
#
# Sans xml2, on échappe TOUT plutôt que de bricoler à l'expression régulière :
# un assainisseur fondé sur des regex donne l'illusion de la sécurité. Le texte
# s'affiche alors en clair, rien ne s'exécute.
assainir_html <- function(x) {
  if (is.null(x) || length(x) == 0) return("")
  x <- as.character(x)[1]
  if (is.na(x) || !nzchar(x)) return("")
  if (!grepl("<", x, fixed = TRUE)) return(htmltools::htmlEscape(x))
  if (!requireNamespace("xml2", quietly = TRUE)) return(htmltools::htmlEscape(x))

  doc <- tryCatch(
    xml2::read_html(paste0('<html><body><div id="tc-sain">', x, "</div></body></html>")),
    error = function(e) NULL)
  if (is.null(doc)) return(htmltools::htmlEscape(x))
  racine <- xml2::xml_find_first(doc, "//div[@id='tc-sain']")
  if (inherits(racine, "xml_missing")) return(htmltools::htmlEscape(x))

  interdites <- xml2::xml_find_all(
    racine, paste0(".//", HTML_BALISES_INTERDITES, collapse = " | "))
  for (n in rev(interdites)) xml2::xml_remove(n)

  for (n in xml2::xml_find_all(racine, ".//*")) {
    est_lien <- identical(tolower(xml2::xml_name(n)), "a")
    href <- if (est_lien) xml2::xml_attr(n, "href") else NA_character_
    for (a in names(xml2::xml_attrs(n))) xml2::xml_attr(n, a) <- NULL
    # Le schéma est vérifié APRÈS le parsage, donc sur la valeur décodée :
    # « javascr&#105;pt: » ne passe pas davantage que « javascript: ».
    if (!is.na(href) && grepl("^\\s*(https?:|mailto:|/|#)", href, ignore.case = TRUE)) {
      xml2::xml_attr(n, "href") <- href
      xml2::xml_attr(n, "target") <- "_blank"
      xml2::xml_attr(n, "rel") <- "noopener noreferrer"
    }
  }
  # On ne renvoie que le CONTENU du conteneur : ce qu'une description
  # refermerait pour s'en échapper tombe simplement hors du résultat.
  paste0(vapply(xml2::xml_contents(racine), as.character, character(1)),
         collapse = "")
}

# Variante à privilégier : on nomme les colonnes qui portent VRAIMENT du HTML,
# tout le reste est échappé. Une colonne ajoutée plus tard est ainsi protégée
# par défaut, au lieu de l'être si quelqu'un pense à l'ajouter à une liste.
echapper_sauf <- function(df, cols_html) {
  echapper_colonnes(df, setdiff(names(df), cols_html))
}

# --- Édition en masse de parcelles : formulaire -----------------------------
# Partagé par l'onglet Parcelles et l'onglet Sites. Les champs sont nommés
# bulk_* dans les deux modules ; chacun garde son propre espace de noms, donc
# les deux formulaires coexistent sans se marcher dessus.
#
# Les quatre dictionnaires sont REÇUS en paramètre : ce sont des arguments des
# modules appelants, pas des globales — supposer l'inverse faisait échouer le
# formulaire à l'ouverture depuis l'onglet Sites.
#
# dico_source_geom et les deux listes de contrats sont relus ici : l'onglet
# Sites ne les reçoit pas, et les lui faire traverser app.R pour ce seul
# formulaire alourdirait trois signatures. Ce sont de petites tables, lues à
# l'ouverture de la modale.
parcelles_bulk_fields <- function(ns, con, dico_cen, dico_source_surf_parc,
                                  dico_echelle, dico_chasse) {
  dico_source_geom <- safe_db_query(
    con, "SELECT id, libelle FROM gestcons.dico_source_geom_parcelle ORDER BY libelle")
  contrats_existants <- safe_db_query(
    con, "SELECT id, nom FROM gestcons.contrats_fonciers ORDER BY nom")
  contrats_agri_existants <- safe_db_query(
    con, "SELECT id, nom FROM gestcons.contrats_agricoles ORDER BY nom")

  fluidPage(
    fluidRow(
      column(4,
             selectInput(ns("bulk_bnd_id"), "BND ?",
                         choices = c("— ne pas modifier —" = "", "Oui" = "1", "Non" = "0"), selected = ""
             ),
             selectInput(ns("bulk_pour_part_id"), "Pour partie ?",
                         choices = c("— ne pas modifier —" = "", "Oui" = "1", "Non" = "0"), selected = ""
             ),
             selectInput(ns("bulk_domaine_public_id"), "Domaine public ?",
                         choices = c("— ne pas modifier —" = "", "Oui" = "1", "Non" = "0"), selected = ""
             ),
             selectInput(ns("bulk_zpf_id"), "ZPF ?",
                         choices = c("— ne pas modifier —" = "", "Oui" = "1", "Non" = "0"), selected = "")
      ),
      column(4,
             selectInput(ns("bulk_proprietaire_id"), "CEN concerné",
                         choices = c("— ne pas modifier —" = "", setNames(dico_cen$id, dico_cen$libelle_long)), selected = ""
             ),
             selectInput(ns("bulk_source_surf_parc_id"), "Source de la surface",
                         choices = c("— ne pas modifier —" = "", setNames(dico_source_surf_parc$id, dico_source_surf_parc$libelle)), selected = ""
             ),
             selectInput(ns("bulk_source_geom_id"), "Source géométrique",
                         choices = c("— ne pas modifier —" = "", setNames(dico_source_geom$id, dico_source_geom$libelle)), selected = ""
             ),
             selectInput(ns("bulk_echelle_numerisation_id"), "Échelle de numérisation",
                         choices = c("— ne pas modifier —" = "", setNames(dico_echelle$id, dico_echelle$libelle)), selected = ""
             ),
             selectInput(ns("bulk_chasse_id"), "Chasse",
                         choices = c("— ne pas modifier —" = "", setNames(dico_chasse$id, dico_chasse$libelle)), selected = "")
      ),
      column(4,
             selectInput(ns("bulk_contrat_id"), "Contrat foncier",
                         choices = c("— ne pas modifier —" = "",
                                     "❌ Retirer tout contrat" = "__REMOVE__",
                                     setNames(contrats_existants$id, contrats_existants$nom)),
                         selected = ""
             ),
             selectInput(ns("bulk_contrat_agri_id"), "Contrat agricole",
                        choices = c("— ne pas modifier —" = "",
                                      "❌ Retirer tout contrat" = "__REMOVE__",
                                       setNames(contrats_agri_existants$id, contrats_agri_existants$nom)),
                        selected = ""
             ),
             
             div(style="margin-top:12px;color:var(--c-encre-douce);",
                 HTML("Chaque champ laissé sur « — ne pas modifier — » sera ignoré."))
      )
    )
  )
}

# --- Édition en masse de parcelles : écriture ------------------------------
# Partagée par l'onglet Parcelles et l'onglet Sites, qui proposent le même
# formulaire sur leurs sélections respectives.
#
# `ids_db` sont des identifiants de gestcons.parcelles déjà résolus : la façon
# de les obtenir diffère d'un onglet à l'autre, pas ce qu'on en fait. `input`
# est celui du module appelant ; les champs sont nommés bulk_* dans les deux,
# puisqu'ils viennent de la même fabrique d'interface.
#
# Renvoie TRUE si la transaction a été validée.
parcelles_bulk_apply <- function(con, ids_db, input, user_db_val) {
    setv <- c()
    add_set <- function(sql_piece) if (nzchar(sql_piece)) setv <<- c(setv, sql_piece)
    
    if (nzchar(input$bulk_bnd_id))                  add_set(glue("bnd_id = {as.integer(input$bulk_bnd_id)}"))
    if (nzchar(input$bulk_pour_part_id))            add_set(glue("pour_part_id = {as.integer(input$bulk_pour_part_id)}"))
    if (nzchar(input$bulk_source_surf_parc_id))     add_set(glue("source_surf_parc_id = {as.integer(input$bulk_source_surf_parc_id)}"))
    if (nzchar(input$bulk_echelle_numerisation_id)) add_set(glue("echelle_numerisation_id = {as.integer(input$bulk_echelle_numerisation_id)}"))
    if (nzchar(input$bulk_domaine_public_id))       add_set(glue("domaine_public_id = {as.integer(input$bulk_domaine_public_id)}"))
    if (nzchar(input$bulk_proprietaire_id))         add_set(glue("proprietaire_id = {as.integer(input$bulk_proprietaire_id)}"))
    if (nzchar(input$bulk_zpf_id))                  add_set(glue("zpf_id = {as.integer(input$bulk_zpf_id)}"))
    if (nzchar(input$bulk_chasse_id))               add_set(glue("chasse_id = {as.integer(input$bulk_chasse_id)}"))
    
    
    # 1. On réserve la connexion
    conn <- pool::poolCheckout(con) 
    
    # 2. CRUCIAL : On s'assure qu'elle revient quoi qu'il arrive (même si erreur)
    on.exit(pool::poolReturn(conn), add = TRUE)
    
    # 3. On travaille UNIQUEMENT sur 'conn' (la connexion dédiée)
    dbBegin(conn)
    ok <- FALSE
    tryCatch({
      if (length(setv) > 0) {
        safe_db_execute(conn, glue("
          UPDATE gestcons.parcelles
          SET {paste(setv, collapse = ', ')},
              modifie_par = {dbQuoteLiteral(conn, user_db_val)},
              date_modification = NOW()
          WHERE id IN ({paste(ids_db, collapse = ',')})
        "))
      }
      
      # Source géométrique : liaison, donc hors du SET ci-dessus. Purge puis
      # pose pour tout le lot, dans la même transaction (cf. la perte
      # silencieuse constatée avec la forme en CTE).
      if (!is.null(input$bulk_source_geom_id) && nzchar(input$bulk_source_geom_id)) {
        src_geom <- as.integer(input$bulk_source_geom_id)
        ids_sql  <- paste(ids_db, collapse = ",")
        safe_db_execute(conn, glue("
          DELETE FROM gestcons.parcelles_sources_geom
          WHERE parcelle_id IN ({ids_sql})
        "))
        safe_db_execute(conn, glue("
          INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
          SELECT p.id, {src_geom}
          FROM gestcons.parcelles_base p
          WHERE p.id IN ({ids_sql})
        "))
      }
      
      # ---- Contrats FONCIER et AGRICOLE (tri-état) ----
      #
      # Une parcelle n'a qu'un contrat ACTIF par type à un instant donné,
      # l'historique étant porté par le statut des contrats eux-mêmes. On
      # retire donc les liaisons vers un contrat actif, puis on pose celle
      # choisie ; les liaisons vers des contrats terminés ou résiliés restent
      # en place comme trace.
      #
      # Il y avait ici un « UPDATE … SET contrat_id = X WHERE parcelle_id IN
      # (…) » qui écrasait TOUTES les liaisons d'un coup : sur une parcelle
      # qui en porte deux, il posait deux fois la même valeur et violait la
      # clé primaire. L'erreur étant avalée, le changement ne s'écrivait pas
      # et l'application annonçait un succès. Même défaut que celui corrigé
      # sur la fiche d'une parcelle.
      ids_sql    <- paste(ids_db, collapse = ",")
      values_sql <- paste(sprintf("(%d)", ids_db), collapse = ",")

      .bulk_contrat <- function(choix, tbl, tbl_contrat, col) {
        if (is.null(choix) || !nzchar(choix)) return(invisible(NULL))

        tx_execute(conn, glue("
          DELETE FROM gestcons.{tbl} l
           USING gestcons.{tbl_contrat} ct
           WHERE ct.id = l.{col}
             AND ct.statut_id = {STATUT_CONTRAT_ACTIF}
             AND l.parcelle_id IN ({ids_sql})
        "))

        if (identical(choix, "__REMOVE__")) return(invisible(NULL))

        cid <- as.integer(choix)
        # ON CONFLICT DO NOTHING : un conflit signifie que la liaison existe
        # déjà, soit l'état voulu — rien de significatif n'est avalé.
        tx_execute(conn, glue("
          INSERT INTO gestcons.{tbl} ({col}, parcelle_id)
          SELECT {cid}, v.id FROM (VALUES {values_sql}) AS v(id)
          ON CONFLICT DO NOTHING
        "))
      }

      .bulk_contrat(input$bulk_contrat_id,
                    "contrats_foncier_parcelles", "contrats_fonciers", "contrat_id")
      .bulk_contrat(input$bulk_contrat_agri_id,
                    "contrats_agricoles_parcelles", "contrats_agricoles", "contrat_agri_id")
      
      dbCommit(conn)
      ok <- TRUE
    }, error = function(e) {
      dbRollback(conn)
      showToast("error", "Erreur SQL", paste("Impossible de mettre à jour :", e$message))
    })
  ok
}

# --- Activité : série mensuelle (mois × métrique × n) ------------------------
# Extraite de mod_monitoring.R pour que la page d'accueil montre EXACTEMENT le
# même graphique que l'onglet Activité, sans en réécrire les requêtes.
# L'accueil l'appelle en vue globale sur douze mois ; l'onglet y ajoute son
# site et sa période. Les métriques « Connexions » et « Questions Analyses »
# n'existent qu'en vue globale : ni gestcons.connexion_log ni
# gestcons.analyses_questions n'ont de notion de site.
#
# @param site_id NA / NULL / "" -> vue globale.
# @return data.frame(mois, metric, n), grille mensuelle complète (mois vides à 0)
monitoring_series <- function(con, start_d, end_d, site_id = NA_integer_) {
  start_d <- as.Date(start_d)
  end_d   <- as.Date(end_d)

  .floor_month <- function(d) as.Date(format(d, "%Y-%m-01"))

  .monthly <- function(sql) {
    df <- safe_db_query(con, sql)
    if (is.null(df) || nrow(df) == 0) {
      return(data.frame(mois = as.Date(character()), n = integer()))
    }
    data.frame(mois = as.Date(df$mois), n = as.integer(df$n))
  }

    start_q <- sql_date(start_d)
    end_q   <- sql_date(end_d + 1)   # borne haute exclusive -> inclut le jour de fin

    sid     <- if (is.null(site_id) || length(site_id) == 0 ||
                   (is.character(site_id) && !nzchar(site_id))) NA_integer_
               else suppressWarnings(as.integer(site_id))
    has_sid <- !is.na(sid)

    # Clauses de filtre par site (EXISTS -> compte chaque entité une seule fois)
    f_af  <- if (has_sid) glue::glue(" AND EXISTS (SELECT 1 FROM gestcons.animation_fonciere_parcelles afp JOIN gestcons.parcelles_base p ON p.id = afp.parcelle_id WHERE afp.animation_id = af.id AND p.site_id = {sid})") else ""
    f_aca <- if (has_sid) glue::glue(" AND EXISTS (SELECT 1 FROM gestcons.animation_contrat_agricole_parcelles acap JOIN gestcons.parcelles_base p ON p.id = acap.parcelle_id WHERE acap.animation_id = aca.id AND p.site_id = {sid})") else ""
    f_cf  <- if (has_sid) glue::glue(" AND EXISTS (SELECT 1 FROM gestcons.contrats_foncier_parcelles cfp JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id WHERE cfp.contrat_id = cf.id AND p.site_id = {sid})") else ""
    f_ca  <- if (has_sid) glue::glue(" AND EXISTS (SELECT 1 FROM gestcons.contrats_agricoles_parcelles cap JOIN gestcons.parcelles p ON p.id = cap.parcelle_id WHERE cap.contrat_agri_id = ca.id AND p.site_id = {sid})") else ""
    f_dg  <- if (has_sid) glue::glue(" AND site_id = {sid}") else ""
    f_pc  <- if (has_sid) glue::glue(" AND site_id = {sid}") else ""

    sql_actions <- glue::glue("
      SELECT date_trunc('month', d::timestamp)::date AS mois, count(*)::int AS n FROM (
        SELECT af.date_creation AS d FROM gestcons.animation_fonciere af
         WHERE af.date_creation >= {start_q} AND af.date_creation < {end_q}{f_af}
        UNION ALL
        SELECT aca.date_creation AS d FROM gestcons.animation_contrat_agricole aca
         WHERE aca.date_creation >= {start_q} AND aca.date_creation < {end_q}{f_aca}
      ) t GROUP BY 1 ORDER BY 1")

    sql_contrats <- glue::glue("
      SELECT date_trunc('month', d::timestamp)::date AS mois, count(*)::int AS n FROM (
        SELECT cf.date_creation AS d FROM gestcons.contrats_fonciers cf
         WHERE cf.date_creation >= {start_q} AND cf.date_creation < {end_q}{f_cf}
        UNION ALL
        SELECT ca.date_creation AS d FROM gestcons.contrats_agricoles ca
         WHERE ca.date_creation >= {start_q} AND ca.date_creation < {end_q}{f_ca}
      ) t GROUP BY 1 ORDER BY 1")

    sql_docs <- glue::glue("
      SELECT date_trunc('month', date_creation::timestamp)::date AS mois, count(*)::int AS n
      FROM gestcons.docs_gestion_sites
      WHERE date_creation >= {start_q} AND date_creation < {end_q}{f_dg}
      GROUP BY 1 ORDER BY 1")

    # Modifications : depuis le journal d'audit (gestcons.audit_log), action
    # 'UPDATE' uniquement -> vraies modifications de lignes existantes (les
    # créations sont déjà couvertes par les barres « créés/ajoutés »). Couvre
    # TOUTES les tables auditées, parcelles comprises. Filtrable par site
    # (audit_log.site_id, via f_pc). 0 tant que les triggers n'ont pas produit
    # de lignes (table vide/inaccessible -> .monthly renvoie 0, pas d'erreur).
    sql_modif <- glue::glue("
      SELECT date_trunc('month', changed_at::timestamp)::date AS mois, count(*)::int AS n
      FROM gestcons.audit_log
      WHERE action = 'UPDATE'
        AND changed_at >= {start_q} AND changed_at < {end_q}{f_pc}
      GROUP BY 1 ORDER BY 1")

    parts <- list(
      "Actions créées"   = .monthly(sql_actions),
      "Contrats ajoutés" = .monthly(sql_contrats),
      "Docs de gestion"  = .monthly(sql_docs),
      "Modifications"    = .monthly(sql_modif)
    )

    # Connexions à l'appli : métrique GLOBALE (gestcons.connexion_log n'a pas de
    # notion de site). On ne l'affiche QUE dans la vue globale -> dès qu'un site
    # est sélectionné, on ne l'ajoute pas (barre ET total masqués). Si la table
    # est vide/inaccessible, .monthly renvoie 0 (pas d'erreur).
    if (!has_sid) {
      sql_conn <- glue::glue("
        SELECT date_trunc('month', date_connexion::timestamp)::date AS mois, count(*)::int AS n
        FROM gestcons.connexion_log
        WHERE date_connexion >= {start_q} AND date_connexion < {end_q}
        GROUP BY 1 ORDER BY 1")
      parts[["Connexions"]] <- .monthly(sql_conn)

      # Questions posées dans l'onglet Analyses : métrique GLOBALE elle aussi,
      # une question ne portant sur aucun site en particulier. Les lignes sont
      # écrites par mod_analyse, erreurs comprises.
      #
      # ⚠️ Le compte démarre à la mise en service de gestcons.analyses_questions
      # (2026-10-27) : les questions posées avant n'étaient consignées que dans le
      # journal texte du serveur. Les mois antérieurs valent donc 0, et c'est
      # un défaut d'historique, pas une absence d'usage.
      sql_quest <- glue::glue("
        SELECT date_trunc('month', date_question::timestamp)::date AS mois, count(*)::int AS n
        FROM gestcons.analyses_questions
        WHERE date_question >= {start_q} AND date_question < {end_q}
        GROUP BY 1 ORDER BY 1")
      parts[["Questions Analyses"]] <- .monthly(sql_quest)
    }

    # Grille mensuelle complète -> les mois sans activité apparaissent à 0
    months <- seq(.floor_month(start_d), .floor_month(end_d), by = "month")
    # Métriques actives = clés de `parts` : 6 en vue globale, 4 si un site est
    # filtré (Connexions et Questions Analyses, toutes deux globales, sont
    # alors absentes). L'ordre suit celui d'insertion, donc .MONITORING_METRICS.
    metrics <- names(parts)
    grid <- expand.grid(mois = months, metric = metrics,
                        KEEP.OUT.ATTRS = FALSE, stringsAsFactors = FALSE)

    counts <- do.call(rbind, lapply(metrics, function(m) {
      d <- parts[[m]]
      if (nrow(d) == 0) return(NULL)
      data.frame(mois = d$mois, metric = m, n = d$n)
    }))

    # Aucune activité du tout (ex. site sans parcelles ni docs sur la période)
    # -> `counts` est NULL : on renvoie la grille à 0 sans tenter de merge.
    if (is.null(counts) || nrow(counts) == 0) {
      out <- grid
      out$n <- 0L
    } else {
      out <- merge(grid, counts, by = c("mois", "metric"), all.x = TRUE)
      out$n[is.na(out$n)] <- 0L
    }
    out$metric <- factor(out$metric, levels = metrics)
    out[order(out$metric, out$mois), ]
}

# --- Recadrer la carte sur le site courant ----------------------------------
# Écrite deux fois à l'identique dans Sites et dans Actions — 33 lignes chacune,
# aux commentaires près. L'emprise n'est pas toujours prête au moment du clic :
# si elle l'est, on recadre ; sinon on attend sa PREMIÈRE arrivée, puis on se
# détruit. Le délai laisse l'onglet finir son animation Bootstrap, sans quoi
# Leaflet recadre sur un conteneur encore replié.
make_focus_site <- function(bbox_rv, map_id, session) {
  function(site_id = NULL) {
    recadrer <- function() {
      bx <- shiny::isolate(bbox_rv())
      if (is.null(bx)) return(invisible(NULL))
      coins <- as.numeric(unname(bx[c("xmin", "ymin", "xmax", "ymax")]))
      session$sendCustomMessage("invalidate-map", list(id = map_id))
      shinyjs::delay(200, {
        leaflet::leafletProxy(map_id, session = session) %>%
          leaflet::fitBounds(coins[1], coins[2], coins[3], coins[4])
      })
    }
    if (!is.null(shiny::isolate(bbox_rv()))) {
      recadrer()
    } else {
      obs <- NULL
      obs <- shiny::observeEvent(bbox_rv(), {
        if (!is.null(bbox_rv())) {
          recadrer()
          obs$destroy()
        }
      }, ignoreInit = TRUE, once = TRUE)
    }
    invisible(NULL)
  }
}

# --- Tableaux : pagination en haut ET en bas --------------------------------
# Les tableaux de Contrats, Docs de gestion, Acteurs et Utilisateurs font dix
# lignes : pour changer de page il fallait descendre jusqu'au pied, puis
# remonter. Le `dom` de DataTables reprend la disposition Bootstrap par défaut
# et ajoute un bloc de pagination en haut À DROITE, aligné sur celui du bas.
#
# Éprouvé avec la DataTables livrée par DT : deux blocs sont bien créés, et
# ils restent SYNCHRONISÉS — cliquer la page 2 en haut met aussi le bas sur 2.
DT_DOM_PAGINATION_HAUT <- paste0(
  '<"row"<"col-sm-6"l><"col-sm-6"f>>',          # longueur + recherche
  '<"row"<"col-sm-12 text-right text-end"p>>',           # navigation, SOUS la recherche
  '<"row"<"col-sm-12"tr>>',                     # le tableau
  '<"row"<"col-sm-5"i><"col-sm-7"p>>'           # info + navigation, en pied
)

# --- Titre de page, en tête de colonne gauche -------------------------------
# Les quatre pages du domaine « Sites » sont repliées sous une même entrée de
# menu : une fois dedans, la barre d'onglets ne dit plus où l'on se trouve.
# Chaque page l'affiche donc elle-même, avec le libellé exact de son item.
titre_page <- function(txt) {
  tags$div(class = "tc-page-title", txt)
}

# --- Confirmation d'une suppression définitive ------------------------------
# L'onglet Activité était le seul du dépôt à en demander une. Supprimer un
# contrat — et avec lui toutes ses liaisons de parcelles —, un acteur, un
# document de gestion avec son fichier sur le serveur, ou une parcelle depuis
# l'onglet Parcelles, partait au premier clic.
#
# `quoi` est du HTML (le nom de l'objet y est mis en gras) : l'appelant échappe
# ce qui vient de la base. `details` liste ce que la suppression entraîne.
# ⚠️ `quoi` et chaque élément de `details` sont rendus en HTML BRUT, pour que
# les appelants puissent y mettre du <strong>. Toute valeur venant d'une saisie
# doit donc être échappée PAR L'APPELANT (htmltools::htmlEscape). Les cinq
# appelants le font ; le dernier ne le faisait pas, corrigé le 2026-10-27.
confirm_suppression <- function(ns, quoi, confirm_id, details = character(0)) {
  shiny::showModal(shiny::modalDialog(
    title = "Confirmer la suppression",
    easyClose = TRUE,
    footer = shiny::tagList(
      shiny::modalButton("Annuler"),
      shiny::actionButton(ns(confirm_id), "🗑 Confirmer la suppression",
                          class = "btn btn-danger")
    ),
    shiny::tags$p(htmltools::HTML(sprintf("Supprimer définitivement %s ?", quoi))),
    lapply(details, function(d) shiny::tags$p(htmltools::HTML(d))),
    shiny::tags$p(shiny::tags$strong("Cette opération est irréversible."))
  ))
}

# Tableau DT des documents : lien « ouvrir », colonnes renommées, id masqué.
docs_datatable <- function(df) {
  if (nrow(df) > 0) {
    # L'URL est échappée en contexte d'ATTRIBUT : elle contient le nom de
    # fichier assaini pour le disque, mais rien n'interdit une apostrophe ou un
    # guillemet selon les chemins d'écriture.
    df$Ouvrir <- sprintf('<a href="./%s" target="_blank">🔗 ouvrir</a>',
                         htmltools::htmlEscape(df$url, attribute = TRUE))
  } else {
    df$Ouvrir <- character(0)
  }
  # Le nom de fichier est celui d'ORIGINE, tel que téléversé : l'assainissement
  # de docs_add() ne sert qu'au nom sur disque, et basename() ne retire que ce
  # qui précède un « / ». Un nom contenant « < » arrive donc intact.
  df <- echapper_colonnes(df, c("type_document", "nom_fichier", "remarque"))

  keep <- intersect(c("id", "Ouvrir", "type_document", "nom_fichier", "date_creation", "remarque"),
                    names(df))
  df <- df[, keep, drop = FALSE]

  id_idx     <- which(names(df) == "id") - 1L
  ouvrir_idx <- which(names(df) == "Ouvrir") - 1L

  names(df)[names(df) == "Ouvrir"]        <- " "
  names(df)[names(df) == "type_document"] <- "Type de document"
  names(df)[names(df) == "nom_fichier"]   <- "Nom du fichier"
  names(df)[names(df) == "date_creation"] <- "Date"
  names(df)[names(df) == "remarque"]      <- "Remarque"

  DT::datatable(
    df, escape = FALSE, selection = "single", rownames = FALSE,
    options = list(pageLength = 8, dom = "tip",
                   columnDefs = list(
                     list(targets = ouvrir_idx, orderable = FALSE, searchable = FALSE),
                     list(targets = id_idx,     visible   = FALSE)))
  )
}

clear_ephemeral_layers <- function(map_id, session) {
  prx <- leaflet::leafletProxy(mapId = map_id, session = session)
  for (g in unique(EPHEMERAL_GROUPS)) {
    prx <- prx %>% leaflet::clearGroup(g)
  }
  invisible(prx)
}

get_zones_protection <- function(con) {
  debug_print("✅✅✅✅✅✅✅✅✅✅✅✅get_zone  s_protection")
  # 1. Requête SQL: sélectionner toutes les colonnes nécessaires, y compris 'geometrie' native
  query <- glue::glue("
    SELECT
      id,
      type,
      libelle,
      id_mnhn,
      ST_SimplifyPreserveTopology(geom_wgs84, 0.0001) AS geom
    FROM gestcons.dico_protection
    WHERE geom_wgs84 IS NOT NULL -- Utiliser la colonne 4326 pré-calculée pour le filtre
  ")
  debug_print(paste0(Sys.time(), " - 1. Requête définie"))
  
  # 2. Lecture
  zones_protection <- tryCatch(
    sf::st_read(con, query = query, quiet = TRUE),
    error = function(e) {
      message("Erreur de lecture dico_protection: ", conditionMessage(e))
      return(NULL)
    }
  )
  
  return(zones_protection)
  
}

#' Fabrique UNIQUE des infobulles de parcelles (tous onglets carte).
#'
#' @param fields lignes à inclure, dans l'ordre fixe parcelle / propriétaire /
#'   commune / surface / contrats / remarque. Le défaut reproduit la sortie
#'   historique complète ; un appelant peut se limiter à un sous-ensemble
#'   (ex. Stratégie : c("parcelle","proprietaire","surface")). Commencer par
#'   "parcelle" (les autres lignes sont préfixées d'un <br>).
#'
#' Normalisation d'entrée : accepte dcntpa (cadastre brut) comme alias de
#' surface_m2 et idcomtxt comme alias de commune — évite les renommages chez
#' les appelants (source de divergences, cf. bug « surface à 0 » du résumé
#' Stratégie). La censure des propriétaires (mode démo -> « XXXX », invité ->
#' « Accès restreint ») est appliquée ici, donc à TOUTES les infobulles.
.cf_make_labels <- function(sfobj, user_roles,
                            fields = c("type", "parcelle", "proprietaire", "commune",
                                       "surface", "contrats", "priorite", "remarque")) {
  must <- c("code","proprietaires","commune","surface_m2","contrats_fonciers","contrats_agricoles","remarque")

  debug_print(paste("=============================global_role = ", user_roles$global_role))
  is_guest   <- user_roles$global_role == "IN"

  # Normalisation des noms de colonnes (alias fréquents des requêtes cadastre)
  if (!"surface_m2" %in% names(sfobj) && "dcntpa" %in% names(sfobj)) sfobj$surface_m2 <- sfobj$dcntpa
  if (!"commune"    %in% names(sfobj) && "idcomtxt" %in% names(sfobj)) sfobj$commune  <- sfobj$idcomtxt

  for (m in must) if (!m %in% names(sfobj)) sfobj[[m]] <- NA

  .nz <- function(x) !is.na(x) & nzchar(as.character(x))

  # --- LOGIQUE DE CENSURE ---
  if (is_guest) {
    debug_print("Guest")
    proprio_label <- "Accès restreint"
  } else {
    debug_print("Pas Guest")
    proprio_label <- ifelse(
      .nz(sfobj$proprietaires),
      htmltools::htmlEscape(sfobj$proprietaires),
      ""
    )
  }

  # Chaque segment est construit à l'identique de la version historique, puis
  # inclus ou non selon `fields` (vide sinon) -> sortie inchangée par défaut.
  blank <- rep("", nrow(sfobj))

  # Type de parcelle (site / continuité du site conservatoire) : affiché seulement si la donnée
  # porte le drapeau `perimetre` (données issues de parcelles_base). Les couches
  # sans ce drapeau (parcelles du site via la vue, manuels...) sont inchangées.
  seg_type <- if ("type" %in% fields && "perimetre" %in% names(sfobj)) {
    ifelse(sfobj$perimetre %in% TRUE,
           "<b>\U0001F3AF Continuité du site conservatoire</b><br>",
           "<b>\U0001F4CD Parcelle du site</b><br>")
  } else blank

  seg_parcelle <- if ("parcelle" %in% fields) {
    paste0("<b>Parcelle : </b>", sfobj$idpar)
  } else blank

  seg_proprio <- if ("proprietaire" %in% fields) {
    # La ligne "Propriétaire :" s'affiche si un propriétaire existe,
    # ou si on est invité (Guest).
    paste0(
      ifelse(.nz(sfobj$proprietaires) | is_guest, "<br>👤 Propriétaire : ", ""),
      proprio_label
    )
  } else blank

  seg_commune <- if ("commune" %in% fields) {
    paste0(
      ifelse(.nz(sfobj$commune), "<br>🏘️ Commune : ", ""),
      ifelse(.nz(sfobj$commune), htmltools::htmlEscape(sfobj$commune), "")
    )
  } else blank

  seg_surface <- if ("surface" %in% fields) {
    paste0("<br>📐 Surface : ", format(round(as.numeric(sfobj$surface_m2)), big.mark = " "), " m²")
  } else blank

  seg_contrats <- if ("contrats" %in% fields) {
    paste0(
      ifelse(.nz(sfobj$contrats_fonciers), "<br>📜 Contrat foncier : ", ""),
      ifelse(.nz(sfobj$contrats_fonciers), htmltools::htmlEscape(sfobj$contrats_fonciers), "—"),
      ifelse(.nz(sfobj$contrats_agricoles), "<br>📜 Contrat agricole : ", ""),
      ifelse(.nz(sfobj$contrats_agricoles), htmltools::htmlEscape(sfobj$contrats_agricoles), "—")
    )
  } else blank

  seg_remarque <- if ("remarque" %in% fields) {
    ifelse(.nz(sfobj$remarque), paste0("<br>📝 ", htmltools::htmlEscape(sfobj$remarque)), "")
  } else blank

  # Priorité : propre aux parcelles de périmètre (continuité du site conservatoire d'un site ou
  # secteur d'intervention prioritaire). Silencieuse quand la donnée ne porte
  # pas la colonne, pour ne rien changer aux couches qui l'ignorent.
  seg_priorite <- if ("priorite" %in% fields && "priorite_id" %in% names(sfobj)) {
    ifelse(is.na(sfobj$priorite_id), "",
           paste0("<br>🎯 Priorité ", as.integer(sfobj$priorite_id)))
  } else blank

  lab <- paste0(seg_type, seg_parcelle, seg_proprio, seg_commune, seg_surface,
                seg_contrats, seg_priorite, seg_remarque)

  lapply(lab, htmltools::HTML)
}


# --- Helpers généraux ---
.is_blank <- function(x) {
  is.null(x) || length(x) == 0 ||
    (is.atomic(x) && length(x) == 1 && (is.na(x) || (is.character(x) && !nzchar(x))))
}


# Helpers locaux au module
.safe_val <- function(x) {
  if (is.null(x) || length(x) == 0 || is.na(x) || (is.character(x) && !nzchar(x))) "—" else as.character(x)
}

# helpers.R


safe_db_query <- function(con, sql) {
  log_query(sql)
  if (.dans_transaction(con)) return(DBI::dbGetQuery(con, sql))  # erreur laissée remonter
  tryCatch(
    expr = {
      dbGetQuery(con, sql)   # essaie la requête
    },
    error = function(e) {
      message("❌ Erreur SQL : ", e$message)
      return(data.frame())        # retourne un DF vide en cas d'erreur
    },
    warning = function(w) {
      message("⚠️ Avertissement SQL : ", w$message)
      invokeRestart("muffleWarning")  # supprime l'avertissement
    },
    finally = {
      if(DEBUG_SQL) {
        message("✅ Requête exécutée (ou tentative)")
      }
    }
  )
}

safe_db_insert <- function(con, sql, id_col = "id") {
  log_query(sql)
  if (.dans_transaction(con)) {
    res <- DBI::dbGetQuery(con, sql)   # erreur laissée remonter
    if (nrow(res) == 0 || !id_col %in% names(res)) {
      stop("L'insertion n'a renvoyé aucune colonne '", id_col, "'.")
    }
    return(res[[id_col]][1])
  }
  tryCatch(
    {
      res <- DBI::dbGetQuery(con, sql)
      if (nrow(res) == 0 || !id_col %in% names(res)) {
        warning("⚠️ L'insertion a réussi mais aucune colonne '", id_col, "' n'a été trouvée.")
        return(NULL)
      }
      return(res[[id_col]][1])
    },
    error = function(e) {
      message("❌ Erreur SQL (insert) : ", e$message)
      # Optionnel : log dans un fichier
      message("INSERT ERROR:", e$message, sql)
      return(NULL)
    }
  )
}

# --- Garde-fou : ne JAMAIS capturer une erreur SQL dans une transaction ------
# PostgreSQL met une transaction en état « avorté » dès la première erreur :
# tous les ordres suivants échouent, et le COMMIT final renvoie un ROLLBACK
# SANS lever d'erreur. Capturer l'erreur revient donc à annuler la transaction
# en silence pendant que l'application annonce un succès — rien n'est écrit.
#
# Les fonctions safe_db_* ci-dessous détectent donc leur contexte et laissent
# remonter l'erreur quand une transaction est ouverte, pour que le tryCatch de
# l'appelant déclenche son rollback et affiche la vraie cause. Hors transaction,
# leur comportement est inchangé.
#
# La sonde lit l'état libpq localement : mesuré à 4 µs, aucun aller-retour au
# serveur. Un objet Pool n'est jamais en transaction — chaque instruction y
# prend sa propre connexion —, d'où le repli sur FALSE.
.dans_transaction <- function(con) {
  isTRUE(tryCatch(RPostgres::postgresIsTransacting(con), error = function(e) FALSE))
}

safe_db_execute <- function(con, sql) {
  log_query(sql)  # ton logger (affiche/stocke la requête)
  if (.dans_transaction(con)) return(DBI::dbExecute(con, sql))  # erreur laissée remonter
  tryCatch(
    expr = {
      n <- dbExecute(con, sql)   # exécute la requête
      message("✅ Requête exécutée avec succès (", n, " ligne(s) affectée(s))")
      return(n)  # retourne le nombre de lignes modifiées
    },
    error = function(e) {
      message("❌ Erreur SQL : ", e$message)
      return(0L)   # 0 lignes affectées si erreur
    },
    warning = function(w) {
      message("⚠️ Avertissement SQL : ", w$message)
      invokeRestart("muffleWarning")
      return(0L)   # en cas de warning, on retourne 0
    },
    finally = {
      # facultatif : toujours exécuté (pour logs, nettoyage…)
    }
  )
}

# --- Variantes STRICTES pour usage À L'INTÉRIEUR d'une transaction ----------
# Contrairement à safe_db_execute / safe_db_insert (qui capturent l'erreur et
# renvoient 0L / NULL), ces variantes LAISSENT REMONTER l'erreur : indispensable
# dans un bloc dbBegin/dbCommit pour que le tryCatch déclenche bien le rollback.
# À utiliser uniquement avec la connexion dédiée `conn` (pool::poolCheckout).
tx_execute <- function(conn, sql) {
  log_query(sql)
  DBI::dbExecute(conn, sql)
}

tx_insert <- function(conn, sql, id_col = "id") {
  log_query(sql)
  res <- DBI::dbGetQuery(conn, sql)
  if (nrow(res) == 0 || !id_col %in% names(res)) {
    stop("L'insertion n'a renvoyé aucune colonne '", id_col, "'.")
  }
  res[[id_col]][1]
}

# --- Rôles de site : titulaire courant + historique des périodes ------------
# responsable_sites et conservateur_benevole ont la même forme et la même
# logique. Trois situations, qu'il faut distinguer — c'est tout l'enjeu :
#
#   - même personne, date de début modifiée : CORRECTION de saisie. On modifie
#     la ligne en cours. Ouvrir une période ne représenterait rien, le
#     titulaire n'ayant pas changé.
#   - personne différente : CHANGEMENT de titulaire. On clôt la période en
#     cours et on en ouvre une nouvelle.
#   - plus personne : fin de rôle sans remplaçant. On clôt seulement.
#
# Sans cette distinction, chaque correction de date découpait une tenure
# continue en tranches. Mesuré sur responsable_sites : 37 des 87 périodes
# closes s'enchaînent exactement sur une période suivante de la MÊME personne,
# la date_fin de l'une valant la date_debut de la suivante.
#
# Délibérément sans ON CONFLICT : la vérification d'existence explicite
# fonctionne que la clé primaire porte date_debut ou non. Le code reste donc
# valable avant comme après la migration de clé de conservateur_benevole, ce
# qui évite d'avoir à déployer la base et les deux instances au même instant.
#
# À appeler DANS une transaction : les écritures ne doivent jamais survivre
# séparément. Renvoie le cas traité, pour le journal.
maj_role_site <- function(conn, table, site_id, user_id, date_debut_char,
                          user_db_val, user_actuel) {
  tbl  <- DBI::SQL(table)
  u    <- DBI::dbQuoteLiteral(conn, user_db_val)
  jour <- DBI::dbQuoteLiteral(conn, date_debut_char)

  # Garde-fou commun : une période OUVERTE qui commencerait avant une période
  # déjà close en engloberait la durée entière. C'est ainsi que naissaient les
  # chevauchements — 22 relevés le 2026-10-28, dont la forme type sur le site
  # 43 : une période ouverte de 2023 contenant trois périodes courtes de 2025.
  # L'erreur remonte, donc la transaction est annulée et l'appelant l'affiche.
  # `exclure` écarte la ligne qu'on est en train de déplacer : sans elle, une
  # correction se prend elle-même pour un conflit et le message nomme sa
  # propre période, ce qui n'aide personne.
  .refuser_si_englobe <- function(exclure = "") {
    d <- safe_db_query(conn, glue::glue("
      SELECT min(date_debut)::date AS d FROM gestcons.{tbl}
       WHERE site_id = {site_id} AND date_debut::date > {jour}::date {DBI::SQL(exclure)}
    "))
    if (nrow(d) > 0 && !is.na(d$d[1]))
      stop(sprintf(paste0("Cette période commencerait le %s, avant une période ",
                          "déjà enregistrée qui débute le %s. Corrigez d'abord ",
                          "celle-ci, ou choisissez une date postérieure."),
                   format(as.Date(date_debut_char), "%d/%m/%Y"),
                   format(d$d[1], "%d/%m/%Y")))
    invisible(NULL)
  }

  # 1. Correction : même titulaire, seule la date change.
  if (identical(user_id, user_actuel) && !is.na(user_id)) {
    # La période en cours est précisément celle qu'on corrige.
    .refuser_si_englobe("AND NOT actif")
    tx_execute(conn, glue::glue("
      UPDATE gestcons.{tbl}
         SET date_debut = {jour}, modifie_par = {u}, date_modification = NOW()
       WHERE site_id = {site_id} AND actif = TRUE
    "))
    return(invisible("correction"))
  }

  # 2. Changement de titulaire : la période en cours est close AU JOUR SAISI,
  #    et non à NOW(). Fermer à maintenant alors que la nouvelle période
  #    commence plus tôt créait un chevauchement par construction — c'était la
  #    seconde source des 22 relevés le 2026-10-28. Les deux périodes se
  #    touchent désormais au lieu de se recouvrir.
  en_cours <- safe_db_query(conn, glue::glue("
    SELECT date_debut::date AS d FROM gestcons.{tbl}
     WHERE site_id = {site_id} AND actif = TRUE LIMIT 1
  "))
  if (nrow(en_cours) > 0 && !is.na(en_cours$d[1]) &&
      as.Date(date_debut_char) < en_cours$d[1])
    stop(sprintf(paste0("La nouvelle période commencerait le %s, avant le début ",
                        "de la période en cours (%s)."),
                 format(as.Date(date_debut_char), "%d/%m/%Y"),
                 format(en_cours$d[1], "%d/%m/%Y")))

  tx_execute(conn, glue::glue("
    UPDATE gestcons.{tbl}
       SET date_fin = {jour}, actif = FALSE,
           modifie_par = {u}, date_modification = NOW()
     WHERE site_id = {site_id} AND actif = TRUE
  "))

  if (is.na(user_id)) return(invisible("cloture"))

  # 3. Nouvelle période. Si cette personne a déjà tenu le rôle à partir de
  #    cette même date, on rouvre sa ligne : la clé interdit le doublon, et un
  #    ON CONFLICT DO NOTHING l'aurait avalé en silence — c'est exactement le
  #    défaut qui retirait le bénévole du site.
  # Comparaison sur le JOUR : date_debut est un timestamptz, et l'égalité
  # avec un littéral de date dépendrait du fuseau de la session — minuit UTC
  # n'est pas minuit à Paris, la ligne existante ne serait pas retrouvée et
  # l'INSERT violerait la clé. Mesuré sur le site 43.
  deja <- safe_db_query(conn, glue::glue("
    SELECT 1 FROM gestcons.{tbl}
     WHERE site_id = {site_id} AND user_id = {user_id}
       AND date_debut::date = {jour}::date
  "))

  if (nrow(deja) > 0) {
    # Rouvrir une période ancienne la rend sans fin : même garde que la
    # correction, sinon elle engloberait tout ce qui a suivi. La ligne
    # rouverte est elle-même écartée du contrôle.
    .refuser_si_englobe(glue::glue(
      "AND NOT (user_id = {user_id} AND date_debut::date = {jour}::date)"))
    tx_execute(conn, glue::glue("
      UPDATE gestcons.{tbl}
         SET date_fin = NULL, actif = TRUE,
             modifie_par = {u}, date_modification = NOW()
       WHERE site_id = {site_id} AND user_id = {user_id}
         AND date_debut::date = {jour}::date
    "))
    return(invisible("reouverture"))
  }

  .refuser_si_englobe()
  tx_execute(conn, glue::glue("
    INSERT INTO gestcons.{tbl}
      (site_id, user_id, date_debut, actif,
       cree_par, date_creation, modifie_par, date_modification)
    VALUES ({site_id}, {user_id}, {jour}, TRUE, {u}, NOW(), {u}, NOW())
  "))
  invisible("nouvelle")
}

# La date de début est un timestamptz ; le champ du formulaire, une Date.
# Les comparer en texte brut dépendait du fuseau de la session R : minuit UTC
# s'affiche « 2021-05-19 02:00:00 » en Europe/Paris, et toute sauvegarde
# passait alors pour un changement de date. On ramène les deux au jour.
.jour_txt <- function(x) {
  if (is.null(x) || length(x) == 0 || all(is.na(x))) return(NA_character_)
  as.character(as.Date(x[1]))
}


# --- helpers.R : lire les commentaires de colonnes (pg_description) ---
get_table_column_comments <- function(con, schema, table) {
  req <- "
    SELECT 
      c.column_name,
      pgd.description AS comment
    FROM information_schema.columns c
    LEFT JOIN pg_catalog.pg_statio_all_tables st
      ON st.schemaname = c.table_schema
     AND st.relname    = c.table_name
    LEFT JOIN pg_catalog.pg_description pgd
      ON pgd.objoid   = st.relid
     AND pgd.objsubid = c.ordinal_position
    WHERE c.table_schema = $1
      AND c.table_name   = $2
    ORDER BY c.ordinal_position
  "
  df <- DBI::dbGetQuery(con, req, params = list(schema, table))
  stats::setNames(df$comment, df$column_name)  # retourne une named list
}

#' Ajoute un contrôle de légende pour les parcelles du site (couleurs des contrats)
#'
#' @param map_id ID Leaflet (souvent ns("map"))
#' @param session Session Shiny
#' Moteur UNIQUE des légendes de carte (même rendu sur tous les onglets).
#'
#' Construit et pose le contrôle de légende (classes CSS `legend legend--mini
#' site-legend-control`, position bottomleft). Les fonctions add_*_legend
#' ci-dessous ne sont plus que de minces wrappers : titre + couples
#' couleur/libellé. layerId namespacé -> suppression fiable via remove_legend.
# Pastille de légende « hachures » de la continuité du site conservatoire : le paramètre colors
# d'add_map_legend est injecté dans background: -> un dégradé CSS répétitif
# (mêmes diagonales oranges que le pattern SVG des cartes) + bordure dont la
# couleur/épaisseur sont paramétrables (la carte Actions code le statut
# avec/sans action dans la bordure des parcelles hachurées).
legend_hatch_swatch <- function(border = "#ea580c", border_px = 1,
                                line = "rgba(234,88,12,0.6)") paste0(
  "repeating-linear-gradient(45deg, transparent, transparent 3px, ",
  line, " 3px, ", line, " 4.5px); ",
  "border: ", border_px, "px solid ", border
)
# Sites/Parcelles : hachures BLEUES (même bleu que les parcelles du site,
# COLORS_PARCELLES$actif_fill) ; les cartes Actions gardent l'orange.
LEGEND_HATCH_PERIMETRE <- legend_hatch_swatch("#0b5ed7", 1, "rgba(11,94,215,0.6)")

# Coin bas-gauche : c'est là que se trouve déjà la légende des zones de
# protection dans l'onglet Sites, et Leaflet empile les contrôles d'un même
# coin plutôt que de les superposer. Aucun appelant ne force la position, ce
# défaut vaut donc pour les quatre légendes — Sites, Parcelles, Activité et
# Stratégie foncière.
add_map_legend <- function(map_id, session, layer_id, title, labels, colors,
                           position = "bottomleft") {
  stopifnot(length(labels) == length(colors))

  legend_items <- paste0(
    "<div class='legend-item'>",
    # L'opacité vient de leafletfix.css et non d'un style en ligne, qui
    # l'emporterait sur toute règle : le mode sombre a besoin de la relever.
    "<i style='background:", colors, ";'></i>",
    htmltools::htmlEscape(labels),
    "</div>",
    collapse = ""
  )

  leaflet::addControl(
    leaflet::leafletProxy(map_id, session = session),
    position = position,
    className = "leaflet-control legend legend--mini site-legend-control",
    html = htmltools::HTML(paste0(
      "<div class='legend-title'>", htmltools::htmlEscape(title), "</div>",
      "<div class='legend-items-container'>",
      legend_items,
      "</div>"
    )),
    layerId = layer_id
  )
}

#' Légende Sites/Parcelles : statut du contrat foncier des parcelles du site.
#' include_perimetre ajoute l'entrée continuité du site conservatoire (orange) ; include_contour
#' (Sites seulement) celle du contour englobant (violet). Fonctionnalités
#' reprises de l'ex-onglet Stratégie foncière. Couleurs : COLORS_PARCELLES.
add_site_legend <- function(map_id, session, layer_id,
                            include_perimetre = FALSE,
                            include_contour   = include_perimetre) {
  # Les trois statuts restants de dico_type_statut_contrat, les deux premiers
  # ayant leur propre entrée. « Non contractualisé » désignait un cas qui
  # n'existe plus : une parcelle de site porte toujours un contrat.
  labels <- c("Contrat actif (foncier)",
              "Contrat en élaboration (foncier)",
              "Résilié / Suspendu / Terminé")
  colors <- c(COLORS_PARCELLES$actif_fill,
              COLORS_PARCELLES$draft_fill,
              COLORS_PARCELLES$other_fill)
  if (include_perimetre) {
    labels <- c(labels, "Continuité du site conservatoire")
    colors <- c(colors, LEGEND_HATCH_PERIMETRE)   # hachures oranges (cf. cartes)
  }
  if (include_contour) {
    labels <- c(labels, "Contour (site + continuité du site conservatoire)")
    colors <- c(colors, "#7c3aed")   # trait violet tireté
  }
  add_map_legend(
    map_id, session, layer_id,
    title  = if (include_perimetre) "Légende" else "Statut Contrat Foncier",
    labels = labels,
    colors = colors
  )
}

#' Ajoute un contrôle de légende pour les parcelles du site (couleurs des actions)
#'
#' @param map_id ID Leaflet (souvent ns("map"))
#' @param session Session Shiny
add_actions_legend <- function(map_id, session, layer_id) {
  add_map_legend(
    map_id, session, layer_id,
    title  = "Statut Action",
    labels = c("Parcelle du site avec action(s)",
               "Parcelle du site sans action",
               "Continuité du site conservatoire avec action(s)",
               "Continuité du site conservatoire sans action"),
    colors = c("#ff7f00",                              # pal_ok : site AVEC action
               "#3b82f6",                              # pal_nok : site SANS action
               legend_hatch_swatch("#ff7f00", 2),      # hachures, bordure pal_ok
               legend_hatch_swatch("#3b82f6", 2))      # hachures, bordure pal_nok
  )
}
#' Supprime le contrôle de légende des parcelles du site
#'
#' @param map_id ID Leaflet (souvent ns("map"))
#' @param session Session Shiny
#' @param layer_id Layer ID du contrôle à supprimer (doit être namespacé)
remove_legend <- function(map_id, session, layer_id) {
  debug_print("-------------------remove_legend")
  # Utilise layerId pour la suppression, plus fiable que la position
  leaflet::removeControl(leaflet::leafletProxy(map_id, session = session), layerId = layer_id) # ⬅️ Utilise l'ID fourni
}

# Parcelles du site (bleu)
draw_parcelles_site <- function(sf_parcelles, map_id, session, group_name = "Parcelles du site", user_roles) {
  debug_print("draw_parcelles_site <- function")

  # Init du cache de hash session-scoped
  if (is.null(session$userData$site_layer_hash)) {
    session$userData$site_layer_hash <- new.env(parent = emptyenv())
  }

  # Garde-fous : data nulle/vide -> clear + reset cache pour ce map
  if (is.null(sf_parcelles) || inherits(sf_parcelles, "try-error") ||
      !inherits(sf_parcelles, "sf") || nrow(sf_parcelles) == 0) {
    leaflet::leafletProxy(map_id, session = session) %>% leaflet::clearGroup(group_name)
    session$userData$site_layer_hash[[map_id]] <- NULL
    return(invisible(NULL))
  }

  # Court-circuit : si la data n'a pas bougé depuis le dernier dessin,
  # éviter le clearGroup + addPolygons (coûteux côté JS Leaflet)
  current_hash <- digest::digest(sf_parcelles)
  if (identical(session$userData$site_layer_hash[[map_id]], current_hash)) {
    if (CACHE_DEBUG) message(sprintf("[cache] parcelles_site(%s): noop (%d rows)",
                                     map_id, nrow(sf_parcelles)))
    return(invisible(NULL))
  }
  session$userData$site_layer_hash[[map_id]] <- current_hash
  if (CACHE_DEBUG) message(sprintf("[cache] parcelles_site(%s): redraw (%d rows)",
                                   map_id, nrow(sf_parcelles)))

  # CRS cohérent pour Leaflet
  sf_parcelles <- tryCatch(sf::st_transform(sf_parcelles, 4326), error = function(e) sf_parcelles)
  
  # Assurer la présence des colonnes (elles devraient être là suite à la modif de get_parcelles_by_site)
  if (!"has_actif_contrat" %in% names(sf_parcelles)) sf_parcelles$has_actif_contrat <- FALSE
  if (!"has_draft_contrat" %in% names(sf_parcelles)) sf_parcelles$has_draft_contrat <- FALSE
  # Cette fonction ne dessine QUE des parcelles du site : drapeau posé pour que
  # le segment « type » des infobulles affiche 📍 Parcelle du site.
  if (!"perimetre" %in% names(sf_parcelles)) sf_parcelles$perimetre <- FALSE
  
  # Par défaut, tout est 'other' (UTILISATION DES CONSTANTES)
  sf_parcelles$._fill    <- COLORS_PARCELLES$other_fill
  sf_parcelles$._stroke  <- COLORS_PARCELLES$other_outline
  
  # 1. CAS ACTIF : Si au moins un contrat foncier est 'actif'
  is_actif <- sf_parcelles$has_actif_contrat
  sf_parcelles[is_actif, "._fill"]   <- COLORS_PARCELLES$actif_fill
  sf_parcelles[is_actif, "._stroke"] <- COLORS_PARCELLES$actif_outline
  
  # 2. CAS DRAFT : Si au moins un contrat foncier est 'draft' ET aucun n'est 'actif'
  #    (Draft est prioritaire sur 'Other' mais pas sur 'Actif')
  is_draft <- sf_parcelles$has_draft_contrat & !is_actif
  sf_parcelles[is_draft, "._fill"]   <- COLORS_PARCELLES$draft_fill
  sf_parcelles[is_draft, "._stroke"] <- COLORS_PARCELLES$draft_outline
  
  # Règle de remplissage et opacité (simple, pour garder le contraste)
  sf_parcelles$._opacity <- 0.7
  
  
  labels <- .cf_make_labels(sf_parcelles, user_roles)

  close_map_tooltips(map_id, session)
  leaflet::leafletProxy(map_id, session = session) %>%
    leaflet::clearGroup(group_name) %>%
    leaflet::addPolygons(
      data     = sf_parcelles,
      group    = group_name,
      layerId  = paste0("site_", sf_parcelles$idpar),
      label    = labels,
      weight   = 1,
      color    = sf_parcelles$._stroke,   # outline par parcelle
      fillColor= sf_parcelles$._fill,     # remplissage par parcelle
      fillOpacity = sf_parcelles$._opacity,
      smoothFactor = 0,
      stroke   = TRUE,
      options  = leaflet::pathOptions(pane = "site"),
      highlightOptions = leaflet::highlightOptions(weight = 2.5, bringToFront = TRUE)
    )
  
  invisible(TRUE)
}


# Invalide le cache incrémental de draw_parcelles_selectionnees pour une carte.
# À appeler dès qu'on fait un clearGroup("Parcelle sélectionnée") manuel sur le
# leafletProxy : sans ça, le prochain draw_parcelles_selectionnees croira que
# les anciennes parcelles sont toujours dessinées et ne fera pas le redraw.
clear_selection_cache <- function(map_id, session) {
  if (!is.null(session$userData$sel_cache)) {
    session$userData$sel_cache[[map_id]] <- NULL
  }
  if (CACHE_DEBUG) message(sprintf("[cache] sel(%s): invalidated", map_id))
  invisible(NULL)
}

# Invalide le hash de calque cadastre -> force un redessin au prochain
# refresh_parcelles_cadastrales. À appeler chaque fois qu'on efface manuellement
# le groupe « Parcelles cadastrales » HORS de cette fonction : sinon le
# court-circuit par hash croit le calque toujours dessiné et saute le redraw,
# laissant le cadastre vide.
invalidate_cadastre_hash <- function(map_id, session) {
  if (!is.null(session) && !is.null(session$userData$cadastre_layer_hash)) {
    session$userData$cadastre_layer_hash[[map_id]] <- NULL
  }
  invisible(NULL)
}

# Mêmes invalidateurs pour les couches « Parcelles du site » (draw_parcelles_site)
# et « Périmètres manuels » (draw_perimetres_manuels), protégées elles aussi par
# un hash session-scoped. À appeler à chaque clearGroup manuel de ces groupes
# HORS des fonctions de dessin : sans ça, le court-circuit par hash croit la
# couche toujours affichée et saute le redessin — la couche reste vide jusqu'à
# ce que les données changent (typiquement : on désélectionne un site puis on
# re-sélectionne le même, et ses parcelles n'apparaissent plus).
invalidate_site_layer_hash <- function(map_id, session) {
  if (!is.null(session) && !is.null(session$userData$site_layer_hash)) {
    session$userData$site_layer_hash[[map_id]] <- NULL
  }
  invisible(NULL)
}
invalidate_perim_layer_hash <- function(map_id, session) {
  if (!is.null(session) && !is.null(session$userData$perim_layer_hash)) {
    session$userData$perim_layer_hash[[map_id]] <- NULL
  }
  invisible(NULL)
}

# Parcelles sélectionnées (orange) — récupérées par idpar depuis la BD
# Dessine les parcelles sélectionnées en ROUGE
#
# Cache incrémental session-scoped : à chaque appel, on calcule le delta
# (parcelles à ajouter / à retirer) vs l'état précédent stocké dans
# session$userData$sel_cache. On ne requête la DB que pour les nouvelles
# parcelles, et on n'envoie au navigateur que les addPolygons / removeShape
# nécessaires. Si rien n'a changé (cas fréquent : pan/zoom sans toucher
# à la sélection), la fonction retourne immédiatement sans requête ni MAJ.
#
# ⚠️ Ne JAMAIS faire `clearGroup("Parcelle sélectionnée")` juste avant un appel
# à cette fonction : ça désynchronise le cache de l'état Leaflet et certaines
# parcelles ne seront pas redessinées. Si on doit vider la sélection visuelle
# en dehors de cette fonction (reset de carte, fermeture de site), appeler
# clear_selection_cache(map_id, session) en plus du clearGroup.
draw_parcelles_selectionnees <- function(
    idpars, con, map_id, session,
    group_name = "Parcelle sélectionnée", user_roles
) {
  # Lecture de l'état précédent depuis le cache session
  if (is.null(session$userData$sel_cache)) {
    session$userData$sel_cache <- new.env(parent = emptyenv())
  }
  prev <- session$userData$sel_cache[[map_id]]
  prev_idpars <- if (is.null(prev)) character(0) else prev$idpars
  prev_sf     <- if (is.null(prev)) NULL              else prev$sf

  idpars <- if (is.null(idpars)) character(0) else as.character(idpars)

  # Reset complet si la sélection est vide
  if (length(idpars) == 0) {
    if (length(prev_idpars) > 0) {
      leaflet::leafletProxy(map_id, session = session) %>%
        leaflet::clearGroup(group_name)
    }
    session$userData$sel_cache[[map_id]] <- NULL
    if (CACHE_DEBUG) message(sprintf("[cache] sel(%s): cleared", map_id))
    return(invisible(NULL))
  }

  to_add    <- setdiff(idpars,      prev_idpars)
  to_remove <- setdiff(prev_idpars, idpars)

  # Fast path : rien n'a changé
  if (length(to_add) == 0 && length(to_remove) == 0) {
    if (CACHE_DEBUG) message(sprintf("[cache] sel(%s): noop (%d in cache)",
                                     map_id, length(prev_idpars)))
    return(invisible(NULL))
  }

  # Fetch DB uniquement pour les nouveaux idpars
  new_sf <- NULL
  if (length(to_add) > 0) {
    in_clause <- paste(DBI::dbQuoteString(con, to_add), collapse = ",")
    sql <- glue::glue("
      SELECT
        c.idpar,
        ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom,
        c.dcntpa::numeric                         AS surface_m2,
        c.idcomtxt::text                          AS commune,
        string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires,
        NULLIF(string_agg(DISTINCT cf.nom, ', '), '') AS contrats,
        NULL::text                                AS remarque
      FROM gestcons.dico_cadastre c
      LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
      LEFT JOIN gestcons.parcelles p ON p.type_parcelle_id = 1 AND p.parcellaire_id = c.id
      LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.parcelle_id = p.id
      LEFT JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
      WHERE c.idpar IN ({in_clause})
      GROUP BY c.idpar, c.geompar, c.dcntpa, c.idcomtxt
    ")
    log_query(sql)
    new_sf <- tryCatch(sf::st_read(con, query = sql, quiet = TRUE), error = function(e) NULL)
    if (!is.null(new_sf) && nrow(new_sf) > 0) {
      new_sf <- sf::st_set_crs(new_sf, 4326)
    } else {
      new_sf <- NULL
    }
  }

  # MAJ du cache sf : on retire les anciennes, on ajoute les nouvelles
  current_sf <- prev_sf
  if (length(to_remove) > 0 && !is.null(current_sf) && nrow(current_sf) > 0) {
    current_sf <- current_sf[!current_sf$idpar %in% to_remove, , drop = FALSE]
  }
  if (!is.null(new_sf)) {
    current_sf <- if (is.null(current_sf) || nrow(current_sf) == 0) new_sf
                  else rbind(current_sf, new_sf)
  }
  session$userData$sel_cache[[map_id]] <- list(idpars = idpars, sf = current_sf)

  # MAJ Leaflet : removeShape pour les supprimés, addPolygons pour les nouveaux
  proxy <- leaflet::leafletProxy(map_id, session = session)

  if (length(to_remove) > 0) {
    for (idp in to_remove) {
      proxy <- proxy %>% leaflet::removeShape(paste0("sel_", idp))
    }
  }

  if (!is.null(new_sf)) {
    labs <- .cf_make_labels(new_sf, user_roles)
    if (length(labs) == 0) {
      labs <- lapply(sprintf("<b>Parcelle %s</b>", new_sf$idpar), htmltools::HTML)
    }
    proxy <- proxy %>%
      leaflet::addPolygons(
        data = new_sf,
        group = group_name,
        layerId = ~paste0("sel_", idpar),
        label = labs,
        labelOptions = leaflet::labelOptions(direction = "auto"),
        options = leaflet::pathOptions(pane = "selection"),
        color = "#dc2626", weight = 0,
        fillColor = "#ef4444", fillOpacity = 0.35,
        smoothFactor = 0.2,
        highlightOptions = leaflet::highlightOptions(
          weight = 0, color = "#b91c1c", fillOpacity = 0.45, bringToFront = TRUE
        )
      )
  }

  if (CACHE_DEBUG) {
    message(sprintf("[cache] sel(%s): +%d -%d (total=%d)",
                    map_id, length(to_add), length(to_remove), length(idpars)))
  }

  invisible(TRUE)
}

#'' Redessine une seule parcelle cadastrale dans le groupe "Parcelles cadastrales"
#''
#'' @param idpar ID de la parcelle cadastrale à afficher
#'' @param con Connexion à la base PostgreSQL
#'' @param map_id ID Leaflet (souvent ns("map"))
#'' @param session Session Shiny
#'' @param group_name Nom du groupe Leaflet (par défaut "Parcelles cadastrales")
#''
draw_parcelle_cadastrale <- function(
    idpar,
    con,
    map_id,
    session,
    group_name     = "Parcelles cadastrales",
    pane           = "selection",   # au-dessus du pane "site"
    outline        = "#555555",     # contour
    weight         = 2,
    clear_previous = TRUE,           # enlève l'ancienne “couche top” si elle existe
    user_roles
) {
  debug_print("draw_parcelle_cadastrale <- function")
  if (length(idpar) == 0 || is.null(idpar) || is.na(idpar)) return(invisible(NULL))
  
  # 1) Nettoie un éventuel contour “top” précédent
  if (isTRUE(clear_previous)) {
    leaflet::leafletProxy(map_id, session = session) %>%
      leaflet::removeShape(paste0("cad_", idpar))
  }
  
  # 2) Récupère UNIQUEMENT cette parcelle
  
  query <- glue::glue("
    SELECT
      c.idpar,
      ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom,
      c.dcntpa::numeric                         AS surface_m2,
      c.idcomtxt::text                          AS commune,
      string_agg(DISTINCT dp.ddenom, ', ')      AS proprietaires,
      NULLIF(string_agg(DISTINCT cf.nom, ', '), '') AS contrats,
      NULL::text                                AS remarque
    FROM gestcons.dico_cadastre c
    LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
    LEFT JOIN gestcons.parcelles p ON p.type_parcelle_id = 1 AND p.parcellaire_id = c.id
    LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.parcelle_id = p.id
    LEFT JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
    WHERE c.idpar = {DBI::dbQuoteLiteral(con, idpar)}
    GROUP BY c.idpar, c.geompar, c.dcntpa, c.idcomtxt
  ")
  log_query(query)
  
  sf_parcelle <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) NULL)
  if (is.null(sf_parcelle) || nrow(sf_parcelle) == 0) return(invisible(NULL))
  sf_parcelle <- tryCatch(sf::st_transform(sf_parcelle, 4326), error = function(e) sf_parcelle)
  
  # 3) Label HTML
  label <- .cf_make_labels(sf_parcelle, user_roles)
  
  # 4) Ajoute le contour (aucun remplissage) AU-DESSUS pour re-cliquable
  leaflet::leafletProxy(map_id, session = session) %>%
    leaflet::addPolygons(
      data    = sf_parcelle,
      layerId = paste0("cad_", sf_parcelle$idpar),  # id distinct pour pouvoir l’enlever
      group   = group_name,
      label   = label,
      weight  = 0,
      color   = outline,
      opacity = 0.2,
      fillOpacity = 0,             # <- contour uniquement
      smoothFactor = 0,
      stroke  = TRUE,
      options = leaflet::pathOptions(pane = pane),
      highlightOptions = leaflet::highlightOptions(weight = weight, bringToFront = TRUE)
    ) %>%
    leaflet::showGroup(group_name)
  
  invisible(TRUE)
}



# Périmètres manuels (jaune)
draw_perimetres_manuels <- function(pm,
                                    map_id = "map",
                                    session = shiny::getDefaultReactiveDomain()) {
  debug_print("draw_perimetres_manuels <- function")
  pane_name <- "perimetres-pane"

  # Init du cache de hash session-scoped (par map_id)
  if (!is.null(session) && is.null(session$userData$perim_layer_hash)) {
    session$userData$perim_layer_hash <- new.env(parent = emptyenv())
  }

  # Cas vide : clear + reset cache, sortir
  if (is.null(pm) || nrow(pm) == 0) {
    leafletProxy(map_id, session = session) %>%
      addMapPane(pane_name, zIndex = 450) %>%
      clearGroup("Périmètres manuels")
    if (!is.null(session)) session$userData$perim_layer_hash[[map_id]] <- NULL
    return(invisible())
  }

  # Court-circuit : data identique au dernier dessin
  if (!is.null(session)) {
    current_hash <- digest::digest(pm)
    if (identical(session$userData$perim_layer_hash[[map_id]], current_hash)) {
      if (CACHE_DEBUG) message(sprintf("[cache] perim_manuels(%s): noop (%d rows)",
                                       map_id, nrow(pm)))
      return(invisible())
    }
    session$userData$perim_layer_hash[[map_id]] <- current_hash
    if (CACHE_DEBUG) message(sprintf("[cache] perim_manuels(%s): redraw (%d rows)",
                                     map_id, nrow(pm)))
  }

  # Setup pane + clear (uniquement si on va effectivement redessiner)
  leafletProxy(map_id, session = session) %>%
    addMapPane(pane_name, zIndex = 450) %>%
    clearGroup("Périmètres manuels")
  
  # surfaces en m² / ha (en 2154), puis reprojection 4326 pour affichage
  area_m2 <- units::drop_units(sf::st_area(sf::st_make_valid(sf::st_transform(pm, 2154))))
  pm$surf_m2 <- round(as.numeric(area_m2))
  pm$surf_ha <- round(as.numeric(area_m2) / 10000, 2)
  pm <- sf::st_transform(pm, 4326)
  
  pm$has_actif   <- if ("has_actif"   %in% names(pm)) .to_logi(pm$has_actif)   else FALSE
  pm$has_draft   <- if ("has_draft"   %in% names(pm)) .to_logi(pm$has_draft)   else FALSE
  pm$has_contrat <- if ("has_contrat" %in% names(pm)) .to_logi(pm$has_contrat) else FALSE

  # Priorité actif > draft > other, alignée sur COLORS_PARCELLES et la légende du site
  pm$._fill   <- COLORS_PARCELLES$other_fill
  pm$._stroke <- COLORS_PARCELLES$other_outline

  is_actif <- pm$has_actif
  pm[is_actif, "._fill"]   <- COLORS_PARCELLES$actif_fill
  pm[is_actif, "._stroke"] <- COLORS_PARCELLES$actif_outline

  is_draft <- pm$has_draft & !is_actif
  pm[is_draft, "._fill"]   <- COLORS_PARCELLES$draft_fill
  pm[is_draft, "._stroke"] <- COLORS_PARCELLES$draft_outline

  mk_lbl <- function(d) {
    n <- nrow(d)
    cf_vals <- if (!is.null(d$contrats_fonciers))  d$contrats_fonciers  else rep(NA_character_, n)
    ca_vals <- if (!is.null(d$contrats_agricoles)) d$contrats_agricoles else rep(NA_character_, n)

    cf_ok <- !is.na(cf_vals) & nzchar(cf_vals)
    ca_ok <- !is.na(ca_vals) & nzchar(ca_vals)

    # Noms de contrats échappés, comme le fait .cf_make_labels sur ces mêmes
    # colonnes : ce sont des champs de saisie libre, et le tout part dans un
    # htmltools::HTML() juste en dessous.
    cf_str <- ifelse(cf_ok, paste0("<br>📜 Contrat foncier : ",
                                   htmltools::htmlEscape(cf_vals)), "")
    ca_str <- ifelse(ca_ok, paste0("<br>📜 Contrat agricole : ",
                                   htmltools::htmlEscape(ca_vals)), "")

    # Les communes recouvertes. Colonne absente des appels qui ne la
    # fournissent pas (dessin temporaire) : le segment est alors vide.
    com_vals <- if (!is.null(d$communes)) d$communes else rep(NA_character_, n)
    com_ok   <- !is.na(com_vals) & nzchar(com_vals)
    com_str  <- ifelse(com_ok, paste0("<br>🏘️ Commune : ",
                                      htmltools::htmlEscape(com_vals)), "")

    paste0(
      "<b>Périmètre :</b> ", d$id,
      com_str,
      "<br>Surface : ", d$surf_m2, " m²",
      cf_str, ca_str
    ) |> lapply(htmltools::HTML)
  }

  leafletProxy(map_id, session = session) %>%
    addPolygons(
      data = pm, group = "Périmètres manuels",
      color = pm$._stroke, fillColor = pm$._fill,
      weight = 2, fillOpacity = 0.7,
      label = mk_lbl(pm), layerId = ~id,
      options = pathOptions(pane = pane_name)
    )

  # Le périmètre manuel masque le cadastre au survol (pane 450 contre 410).
  # Côté navigateur, app.js complète son infobulle avec la parcelle cadastrale
  # située sous le curseur ; ce message câble la carte (idempotent).
  if (!is.null(session)) {
    session$sendCustomMessage("tc-perim-hover", map_id)
  }

  invisible()
}

# Cache partagé entre sessions Shiny (par process R). La requête de coordonnées
# des sites est lourde (ST_Union + ST_PointOnSurface sur tout le cadastre du
# site) mais le résultat est quasi-immuable. On la cache 30 minutes par défaut.
.app_cache <- new.env(parent = emptyenv())
SITES_COORDS_CACHE_TTL <- 30L * 60L  # secondes

# Un cache PAR TYPE d'objet : les sites conservatoires et les secteurs
# d'intervention n'alimentent pas les mêmes cartes, et une seule case les
# aurait fait se chasser l'un l'autre à chaque changement d'onglet.
.cle_coords <- function(type_site_id) paste0("sites_coords_", type_site_id)

# Force le re-fetch au prochain appel de get_sites_coords(). À appeler après
# toute modification susceptible de changer le résultat : INSERT/UPDATE sites,
# parcelles, perimetre_parcellaire_manuel, responsable_sites, sites_statuts.
# Vide les DEUX types : une bascule site <-> secteur change les deux à la fois.
invalidate_sites_coords_cache <- function() {
  for (t in c(1L, 2L)) {
    k <- .cle_coords(t)
    if (CACHE_DEBUG && !is.null(.app_cache[[k]])) message("[cache] ", k, ": INVALIDATED")
    .app_cache[[k]] <- NULL
  }
}

# Récupère les coordonnées de centroïde + métadonnées, avec cache TTL.
#
# ⚠️ `type_site_id` est arrivé le 2026-10-28, et son défaut à 1 n'est pas un
# détail : la requête ne filtrait RIEN, si bien que depuis la bascule de 111
# sites en secteurs, les cartes de Sites, d'Accueil et d'Actions affichaient
# aussi les 113 secteurs en pastilles. 1 = site conservatoire, 2 = secteur
# d'intervention prioritaire.
get_sites_coords <- function(con, force_refresh = FALSE, type_site_id = 1L) {
  type_site_id <- as.integer(type_site_id)[1]
  now <- Sys.time()
  cache <- .app_cache[[.cle_coords(type_site_id)]]
  if (!force_refresh && !is.null(cache) &&
      difftime(now, cache$timestamp, units = "secs") < SITES_COORDS_CACHE_TTL) {
    if (CACHE_DEBUG) {
      message(sprintf("[cache] %s: HIT (age=%.0fs, %d rows)", .cle_coords(type_site_id),
                      as.numeric(difftime(now, cache$timestamp, units = "secs")),
                      nrow(cache$data)))
    }
    return(cache$data)
  }
  if (CACHE_DEBUG) message("[cache] ", .cle_coords(type_site_id), ": MISS -> fetching from DB")

  # ⚠️ La source est `parcelles_base`, PAS la vue de compatibilité
  # `gestcons.parcelles` : celle-ci vaut `WHERE NOT perimetre`, et comme
  # TOUTES les parcelles d'un secteur portent perimetre = true, elle n'en
  # rend aucune — le type 2 ressortait vide. La condition reproduit donc
  # exactement l'ancien comportement pour un site (ses parcelles propres,
  # hors continuité) et prend tout pour un secteur.
  cond_parc <- if (identical(type_site_id, 2L)) "p.perimetre" else "NOT p.perimetre"

  data <- tryCatch(
    DBI::dbGetQuery(con, paste0("
      SELECT
        s.id,
        s.libelle,
        COALESCE(
          (SELECT CONCAT(u.nom, ' ', u.prenom)
           FROM gestcons.responsable_sites rs
           JOIN gestcons.dico_utilisateur u ON u.id = rs.user_id
           WHERE rs.site_id = s.id AND rs.actif = TRUE
           LIMIT 1),
          'Aucun responsable'
        ) AS responsable,
        COALESCE(
          (SELECT ds.libelle
           FROM gestcons.sites_statuts ss
           JOIN gestcons.dico_statut_sites ds ON ds.id = ss.statut_site_id
           WHERE ss.site_id = s.id AND ss.date_fin IS NULL
           ORDER BY ss.date_debut DESC
           LIMIT 1),
          'Non renseigné'
        ) AS statut,
        -- ::int sur les comptages : count() renvoie un bigint, que RPostgres
        -- rend en integer64. Lu comme un double, il ressort en 4.9e-324 —
        -- aucune erreur, juste un chiffre absurde dans l'infobulle.
        -- Communes, surface et contrats : lus ici parce que la requête est déjà
        -- en cache de session, et qu'une infobulle ne peut pas aller les
        -- chercher au survol. Les deux premières s'agrègent sans danger, la
        -- jointure ne produisant qu'une ligne par parcelle ; les contrats,
        -- eux, passent par des sous-requêtes — les joindre démultiplierait la
        -- somme des surfaces, défaut constaté ailleurs dans cette base.
        string_agg(DISTINCT c.idcomtxt, ', ' ORDER BY c.idcomtxt) AS communes,
        COALESCE(sum(p.surf_parc_maitrise_m2), 0) AS surface_m2,
        (SELECT count(DISTINCT j.contrat_id)
           FROM gestcons.contrats_foncier_parcelles j
           JOIN gestcons.parcelles_base pb ON pb.id = j.parcelle_id
          WHERE pb.site_id = s.id)::int AS nb_contrats_fonciers,
        (SELECT count(DISTINCT j.contrat_id)
           FROM gestcons.contrats_foncier_parcelles j
           JOIN gestcons.parcelles_base pb ON pb.id = j.parcelle_id
           JOIN gestcons.contrats_fonciers cf
             ON cf.id = j.contrat_id AND cf.statut_id = 3
          WHERE pb.site_id = s.id)::int AS nb_contrats_fonciers_actifs,
        (SELECT count(DISTINCT j.contrat_agri_id)
           FROM gestcons.contrats_agricoles_parcelles j
           JOIN gestcons.parcelles_base pb ON pb.id = j.parcelle_id
          WHERE pb.site_id = s.id)::int AS nb_contrats_agricoles,
        ST_X(ST_PointOnSurface(ST_Union(ST_Transform(COALESCE(c.geompar, pm.geometrie), 4326)))) AS lon,
        ST_Y(ST_PointOnSurface(ST_Union(ST_Transform(COALESCE(c.geompar, pm.geometrie), 4326)))) AS lat
      FROM gestcons.sites s
      JOIN gestcons.parcelles_base p ON p.site_id = s.id AND ", cond_parc, "
      LEFT JOIN gestcons.dico_cadastre c
        ON p.type_parcelle_id = 1 AND c.id = p.parcellaire_id
      LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
        ON p.type_parcelle_id = 2 AND pm.id = p.parcellaire_id
      WHERE COALESCE(c.geompar, pm.geometrie) IS NOT NULL
        AND s.type_site_id = ", type_site_id, "
      GROUP BY s.id, s.libelle
    ")),
    error = function(e) NULL
  )

  if (!is.null(data)) {
    .app_cache[[.cle_coords(type_site_id)]] <- list(data = data, timestamp = now)
  }
  data
}

# `couleur` impose une teinte unique à toutes les pastilles, au lieu de les
# colorer par statut. C'est ce qu'il faut pour les secteurs : ils sont TOUS en
# statut Préfiguration — c'est une règle de gestion, pas un hasard — donc la
# coloration par statut les rendrait tous verts et n'apprendrait rien.
draw_circles <- function(con, map_id, group = "Sites existants", zoom = 9.3,
                         details = FALSE, type_site_id = 1L, couleur = NULL) {
  # Couleurs
  statut_col_map <- c(
    "Préfiguration" = "#22c55e",
    "Actif"         = "#3b82f6",
    "Archivé"       = "#ef4444",
    "Non renseigné" = "#9ca3af"
  )

  sites_coords <- get_sites_coords(con, type_site_id = type_site_id)

  # 2) Garde-fous
  if (is.null(sites_coords) || !is.data.frame(sites_coords) || nrow(sites_coords) == 0) {
    leaflet::leafletProxy(map_id) %>% leaflet::clearGroup(group)
    return(invisible(NULL))
  }
  
  # 3) Coordonnées propres
  sites_coords$lon <- suppressWarnings(as.numeric(sites_coords[["lon"]]))
  sites_coords$lat <- suppressWarnings(as.numeric(sites_coords[["lat"]]))
  keep <- is.finite(sites_coords$lon) & is.finite(sites_coords$lat)
  if (!any(keep)) {
    leaflet::leafletProxy(map_id) %>% leaflet::clearGroup(group)
    return(invisible(NULL))
  }
  sites_coords <- sites_coords[keep, , drop = FALSE]
  
  # 4) Couleurs / labels
  sites_coords$statut <- as.character(sites_coords$statut %||% "Non renseigné")
  col <- unname(statut_col_map[sites_coords$statut])
  col[is.na(col)] <- statut_col_map[["Non renseigné"]]
  if (!is.null(couleur) && nzchar(couleur[1])) col[] <- couleur[1]
  sites_coords$col <- col
  
  # `details` : la page d'accueil montre en plus communes, surface et contrats.
  # Les onglets de travail gardent l'infobulle courte — on y survole les
  # cercles pour se repérer, pas pour lire une fiche.
  .communes_txt <- function(x) {
    if (is.na(x) || !nzchar(x)) return("—")
    v <- trimws(strsplit(x, ",", fixed = TRUE)[[1]])
    v <- v[nzchar(v)]
    if (length(v) <= 3) return(paste(v, collapse = ", "))
    paste0(paste(v[1:3], collapse = ", "), " et ", length(v) - 3, " autre",
           if (length(v) - 3 > 1) "s" else "")
  }
  .ha_txt <- function(m2) {
    if (is.na(m2)) return("—")
    paste0(format(round(as.numeric(m2) / 10000, 1), big.mark = " ",
                  decimal.mark = ",", nsmall = 1, trim = TRUE), " ha")
  }
  .contrats_txt <- function(nf, nfa, na) {
    bouts <- character(0)
    if (!is.na(nf) && nf > 0)
      bouts <- c(bouts, sprintf("%d foncier%s%s", nf, if (nf > 1) "s" else "",
                                if (!is.na(nfa) && nfa > 0) sprintf(" (%d actif%s)", nfa,
                                                                    if (nfa > 1) "s" else "") else ""))
    if (!is.na(na) && na > 0)
      bouts <- c(bouts, sprintf("%d agricole%s", na, if (na > 1) "s" else ""))
    if (!length(bouts)) "aucun" else paste(bouts, collapse = " · ")
  }

  base_txt <- paste0(
    if (identical(as.integer(type_site_id)[1], 2L)) "<b>Secteur :</b> " else "<b>Site :</b> ",
    htmltools::htmlEscape(sites_coords$libelle),
    "<br>👤 Responsable : ", htmltools::htmlEscape(sites_coords$responsable %||% "—"),
    "<br>📌 Statut : ", htmltools::htmlEscape(sites_coords$statut %||% "Non renseigné")
  )

  # Une version antérieure du cache peut ne pas porter les nouvelles colonnes :
  # on ne les lit que si elles sont là, plutôt que de faire échouer le dessin.
  sup <- c("communes", "surface_m2", "nb_contrats_fonciers")
  if (isTRUE(details) && all(sup %in% names(sites_coords))) {
    base_txt <- paste0(
      base_txt,
      "<br>📍 Communes : ", htmltools::htmlEscape(
        vapply(sites_coords$communes, .communes_txt, character(1), USE.NAMES = FALSE)),
      "<br>📐 Surface : ", vapply(sites_coords$surface_m2, .ha_txt, character(1), USE.NAMES = FALSE),
      "<br>📜 Contrats : ", mapply(.contrats_txt,
                                           sites_coords$nb_contrats_fonciers,
                                           sites_coords$nb_contrats_fonciers_actifs,
                                           sites_coords$nb_contrats_agricoles,
                                           USE.NAMES = FALSE)
    )
  }
  label <- lapply(base_txt, htmltools::HTML)
  
  # 5) Calcul du rayon en fonction du zoom
  # Rayon en MÈTRES (addCircles, pas addCircleMarkers) : le cercle garde donc
  # sa taille au sol et grandit à l'écran quand on zoome, d'où la division par
  # le zoom. Plancher et facteur ont été divisés par deux le 2026-10-16, pour
  # que la réduction vaille à tous les niveaux.
  radius_calc <- function(z) {
    pmax(5, 2500 / (1.5^(z-9)))
  }
  
  # 6) Dessin
  close_map_tooltips(map_id)
  leaflet::leafletProxy(map_id) %>%
    leaflet::clearGroup(group) %>%
    leaflet::addCircles(
      data = sites_coords,
      lng = ~lon, lat = ~lat,
      radius = radius_calc(zoom),
      color = ~col, fillColor = ~col,
      fillOpacity = 0.3, weight = 2,
      label = label, layerId = ~id, group = group
    )
  
  invisible(TRUE)
}

#' Dessine les polygones de dico_protection (zones de protection)
#'
#' @param con Connexion à la base de données
#' @param map_id ID Leaflet (souvent ns("map"))
#' @param session Session Shiny
#' @param group_name Nom du groupe Leaflet
draw_dico_protection <- function(con, map_id, session, zones_protection_data) {
  group_name <- protection_groupes(zones_protection_data)
  debug_print(paste0(Sys.time(), " - draw_dico_protection <- function (Priorité à la plus petite zone)"))

  sf_protection <- zones_protection_data
    
  debug_print(paste0(Sys.time(), "  ================================= %- 2. Lecture BD terminée (n=", nrow(sf_protection), ")"))
  
  if (is.null(sf_protection) || nrow(sf_protection) == 0) {
    leaflet::leafletProxy(map_id, session = session) %>% leaflet::clearGroup(group_name)
    return(invisible(NULL))
  }
  
  sf_protection <- sf_protection %>% 
    dplyr::filter(!sf::st_is_empty(geom)) %>%
    # S'assure que le type de géométrie est un polygone (code 3) ou un multipolygone (code 7)
    dplyr::filter(sf::st_geometry_type(geom) %in% c("POLYGON", "MULTIPOLYGON"))
  
  debug_print(paste0(Sys.time(), " ================================= % - 3. Validation géométrie terminée. Calcul surface (n=", nrow(sf_protection), ")."))
  
  # CALCUL DE SURFACE (utilise la colonne geometrie native si présente)
  if ("geometrie" %in% names(sf_protection) && !inherits(sf_protection$geometrie, "sfc")) {
    # Forcer la conversion de la colonne 'geometrie' en sfc si elle est encore en wkb/text brut
    sf_protection <- sf_protection %>% 
      dplyr::mutate(
        geometrie_sfc = sf::st_as_sfc(geometrie, crs = 2154)
      ) %>%
      dplyr::mutate(
        surface_m2 = units::drop_units(sf::st_area(geometrie_sfc))
      )
  } else {
    # Utiliser la colonne geom (4326) si geometrie n'est pas fiable/présente
    sf_protection <- sf_protection %>% 
      dplyr::mutate(
        surface_m2 = units::drop_units(sf::st_area(sf::st_transform(geom, 2154)))
      )
  }
  
  # Trier du plus grand au plus petit
  sf_protection <- sf_protection %>% 
    dplyr::arrange(dplyr::desc(surface_m2))
  
  sf_protection <- sf::st_set_geometry(sf_protection, "geom")
  sf_protection <- sf::st_cast(sf_protection, "MULTIPOLYGON", warn = FALSE)

  # Le groupe Leaflet de chaque polygone. L'ORDRE de dessin reste global, du
  # plus grand au plus petit : Leaflet empile dans l'ordre d'insertion au sein
  # d'un même pane, quel que soit le groupe, donc les petites zones restent
  # au-dessus des grandes comme avant la répartition par type.
  sf_protection$groupe_leaflet <- paste0(PROTECTION_PREFIXE,
                                         protection_type_libelle(sf_protection$type))
  
  debug_print(paste0(Sys.time(), " - 4. Tri par surface terminé. Création palette."))
  
  # 4. Création de la palette et des couleurs par type 🎨
  # Le domaine est l'ensemble des valeurs uniques présentes dans les données + le fallback 'Non spécifié'
  all_domain_values <- unique(c(sf_protection$type %||% character(0), "Non spécifié"))
  
  # Utiliser les couleurs définies dans la constante globale
  custom_colors_vec <- COLORS_PROTECTION[names(COLORS_PROTECTION) %in% all_domain_values]
  
  # Si un type est dans les données mais pas dans la palette, il sera gris (#999999)
  protection_pal <- leaflet::colorFactor(
    palette = unname(custom_colors_vec), # ✅ Utiliser le vecteur de couleurs, pas l'objet nommé
    levels = names(custom_colors_vec),   # ✅ Définir les niveaux par l'ordre défini dans la constante
    na.color = "#999999"
  )
  
  sf_protection$type_facteur <- as.factor(sf_protection$type %||% "Non spécifié")
  # 💡 Important : Re-générer les niveaux basés sur le domaine complet
  sf_protection$type_facteur <- factor(
    sf_protection$type_facteur, 
    levels = names(custom_colors_vec) 
  )
  
  sf_protection$fill_color <- protection_pal(sf_protection$type_facteur)
  
  debug_print(paste0(Sys.time(), " - 5. Palette et couleurs définies. Création labels."))
  
  # 5. Création des labels
  labels <- lapply(
    paste0(
      "<b>Zone de protection :</b> ", htmltools::htmlEscape(sf_protection$libelle),
      "<br><b>Type :</b> ", htmltools::htmlEscape(sf_protection$type %||% "—"),
      "<br>📐 Surface: ", format(round(sf_protection$surface_m2), big.mark = " "), " m²",
      "<br>ID MNHN : ", htmltools::htmlEscape(sf_protection$id_mnhn %||% "—"),
      "<br>ID DB : ", htmltools::htmlEscape(sf_protection$id)
    ),
    htmltools::HTML
  )
  
  debug_print(paste0(Sys.time(), " - 6. Labels créés. Début du rendu Leaflet."))
  
  # --- Rendu Final : Dessin Séquentiel (du plus grand au plus petit) ---

  close_map_tooltips(map_id, session)
  proxy <- leaflet::leafletProxy(map_id, session = session) %>%
    leaflet::clearGroup(group_name)
  
  # Définition de seuil_index_passif (Utilisation de la moitié des polygones comme seuil de passivité)
  seuil_index_passif <- round(nrow(sf_protection) * 0.5)
  
  # 8. Rendu des polygones (du plus grand au plus petit)
  for (i in 1:nrow(sf_protection)) {
    poly <- sf_protection[i, ]
    
    # Si le polygone est dans la moitié des plus grands, on le rend non-agressif au survol.
    is_passive_layer <- i <= seuil_index_passif 
    
    fill_color_val <- poly$fill_color
    
    # 💡 DÉFINITION DE L'OPACITÉ DE BASE (visible, mais transparent pour le chevauchement)
    fill_opac_base <- 0.4
    
    # Définir l'opacité de remplissage pour la zone (plus transparent pour le fond)
    fill_opac <- if (is_passive_layer) 0.3 else fill_opac_base
    
    # 💡 DÉFINITION DE L'INTERACTION : Surlignement par augmentation d'opacité
    highlight_opt <- leaflet::highlightOptions(
      weight = 0,               # Contour invisible (0)
      color = fill_color_val,   # Conserver la couleur du fond (seulement pour un éventuel contour minimal)
      fillOpacity = 0.8,        # <--- Augmentation de l'opacité de remplissage au survol
      bringToFront = !is_passive_layer # Remonte uniquement si ce n'est pas une grande zone de fond
    )
    
    # Toutes les zones sont interactive = TRUE
    interactive_state <- TRUE 
    
    proxy <- proxy %>% leaflet::addPolygons(
      data = poly,
      group = poly$groupe_leaflet,
      layerId = poly$id,
      label = labels[[i]], 
      weight = 1,                   # Poids de contour très léger (0.5) pour la visibilité du tracé
      color = "#333333",         # Couleur de la zone (contour)
      fillColor = fill_color_val,
      fillOpacity = fill_opac,        # Opacité de base (0.15 ou 0.4)
      smoothFactor = 0.5,
      options = leaflet::pathOptions(pane = "manuels",
                                     interactive = interactive_state), 
      highlightOptions = highlight_opt
    )
  }
  
  proxy %>% leaflet::hideGroup(group_name)
  debug_print(paste0(Sys.time(), " - FIN draw_dico_protection (Rendu Leaflet terminé)"))
  invisible(TRUE)
}


# Charger les parcelles d'un site depuis la base de données
#
# @param site_id Identifiant du site
# @param con Connexion à la base de données
# @return Un objet `sf` ou NULL si aucune parcelle n'est trouvée

# Après : site_id en 1er, con en 2e
get_parcelles_by_site <- function(site_id, con, idpars = NULL) {
  debug_print("get_parcelles_by_site <- function")
  
  extra_filter <- ""
  if (!is.null(idpars) && length(idpars) > 0) {
    in_vals <- paste(DBI::dbQuoteString(con, idpars), collapse = ",")
    extra_filter <- paste0(" AND c.idpar IN (", in_vals, ") ")
  }
  
  sql <- glue::glue("
    WITH base AS (
      SELECT
        p.id              AS p_id,
        p.site_id,
        c.idpar,
        ST_SimplifyPreserveTopology(c.geompar, 1.0) AS geompar,
        c.dcntpa,
        c.idcomtxt
      FROM gestcons.parcelles p
      JOIN gestcons.dico_cadastre c
        ON p.type_parcelle_id = 1 AND c.id = p.parcellaire_id
      WHERE p.site_id = {DBI::dbQuoteLiteral(con, site_id)}
      {SQL(extra_filter)}
    ),
    proprietaires AS (
      SELECT
        b.idpar,
        b.site_id,
        string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires
      FROM base b
      LEFT JOIN gestcons.dico_cadastre c2
        ON c2.idpar = b.idpar
      LEFT JOIN gestcons.dico_proprietaire dp
        ON dp.idprocpte = c2.idprocpte
      GROUP BY b.idpar, b.site_id
    ),
    foncier AS (
      SELECT
        b.idpar,
        b.site_id,
        NULLIF(string_agg(DISTINCT cf.nom, ', ' ORDER BY cf.nom), '') AS contrats_fonciers,
        COUNT(cf.id)                                                   AS nb_contrats_fonciers,
        -- NOUVEAUX INDICATEURS BINAIRES POUR LE STATUT DU CONTRAT FONCIER
        BOOL_OR(LOWER(dtsc.libelle) = 'actif') AS has_actif_contrat,
        BOOL_OR(LOWER(dtsc.libelle) IN ('en cours d''élaboration', 'en cours d’éléboration', 'en cours d élaboration')) AS has_draft_contrat,
        -- (L'ancien has_bad_statut n'est plus nécessaire pour le rendu, mais je le garde par sécurité)
        BOOL_OR(
          cf.id IS NOT NULL AND NOT (
            LOWER(dtsc.libelle) = 'actif'
            OR LOWER(dtsc.libelle) = 'en cours d''élaboration'
            OR LOWER(dtsc.libelle) = 'en cours d’éléboration'
            OR LOWER(dtsc.libelle) = 'en cours d élaboration'
          )
        ) AS has_bad_statut_foncier
      FROM base b
      LEFT JOIN gestcons.contrats_foncier_parcelles cfp
        ON cfp.parcelle_id = b.p_id
      LEFT JOIN gestcons.contrats_fonciers cf
        ON cf.id = cfp.contrat_id
      LEFT JOIN gestcons.dico_type_statut_contrat dtsc
        ON dtsc.id = cf.statut_id
      GROUP BY b.idpar, b.site_id
    ),
    agricole AS (
      SELECT
        b.idpar,
        b.site_id,
        NULLIF(string_agg(DISTINCT ca.nom, ', ' ORDER BY ca.nom), '')  AS contrats_agricoles,
        COUNT(ca.id)                                                   AS nb_contrats_agricoles,
        BOOL_OR(
          ca.id IS NOT NULL AND NOT (
            LOWER(dtsc_a.libelle) = 'actif'
            OR LOWER(dtsc_a.libelle) = 'en cours d''élaboration'
            OR LOWER(dtsc_a.libelle) = 'en cours d’éléboration'
            OR LOWER(dtsc_a.libelle) = 'en cours d élaboration'
          )
        ) AS has_bad_statut_agri
      FROM base b
      LEFT JOIN gestcons.contrats_agricoles_parcelles cap
        ON cap.parcelle_id = b.p_id
      LEFT JOIN gestcons.contrats_agricoles ca
        ON ca.id = cap.contrat_agri_id      -- ✅ correction ici
      LEFT JOIN gestcons.dico_type_statut_contrat dtsc_a
        ON dtsc_a.id = ca.statut_id
      GROUP BY b.idpar, b.site_id
    )
    SELECT
      b.idpar,
      b.site_id,
      b.geompar,
      b.dcntpa  AS surface_m2,
      b.idcomtxt AS commune,
      pr.proprietaires,
      f.contrats_fonciers AS contrats_fonciers,
      a.contrats_agricoles AS contrats_agricoles,
      COALESCE(f.nb_contrats_fonciers, 0) + COALESCE(a.nb_contrats_agricoles, 0) AS nb_contrats,
      COALESCE(f.has_bad_statut_foncier, FALSE) OR COALESCE(a.has_bad_statut_agri, FALSE) AS has_bad_statut,
      -- AJOUT DES NOUVEAUX CHAMPS
      COALESCE(f.has_actif_contrat, FALSE) AS has_actif_contrat,
      COALESCE(f.has_draft_contrat, FALSE) AS has_draft_contrat
    FROM base b
    LEFT JOIN proprietaires pr ON pr.idpar = b.idpar
    LEFT JOIN foncier       f  ON f.idpar  = b.idpar
    LEFT JOIN agricole      a  ON a.idpar  = b.idpar
  ")
  
  log_query(sql)
  tryCatch({
    sf::st_read(con, query = sql, quiet = TRUE) |>
      sf::st_transform(4326)
  }, error = function(e) {
    message(glue::glue("[get_parcelles_by_site] Erreur SQL (site_id={site_id}) : {conditionMessage(e)}"))
    sf::st_sf(geometry = sf::st_sfc(), crs = 4326)
  })
}




# Affichage des parcelles cadastrales
refresh_parcelles_cadastrales <- function(
    con,
    zoom,
    bounds,                          # list avec west/south/east/north (input$map_bounds)
    map_id                 = "map",  # id du leafletOutput
    group_name             = "Parcelles cadastrales",
    parcelles_cache,                 # reactiveVal sf
    parcelles_cache_bbox,            # reactiveVal numeric bbox nommée
    buffer_deg             = 0.001,   # ~100 m (à ajuster si besoin)
    user_roles,
    show_group             = TRUE,    # respecte la case "Parcelles cadastrales"
    session                = shiny::getDefaultReactiveDomain()
) {
  debug_print("refresh_parcelles_cadastrales <- function")
  if (CACHE_DEBUG) message(sprintf("[cache] cadastre(%s): enter (zoom=%s)", map_id, zoom))

  # 0) Pré-conditions
  if (is.null(zoom) || is.null(bounds)) {
    if (CACHE_DEBUG) message(sprintf("[cache] cadastre(%s): exit (zoom/bounds null)", map_id))
    return(invisible())
  }

  # Init du cache de hash session-scoped
  if (!is.null(session) && is.null(session$userData$cadastre_layer_hash)) {
    session$userData$cadastre_layer_hash <- new.env(parent = emptyenv())
  }

  close_map_tooltips(map_id)

  # 2) Ne rien charger si trop dézoomé
  if (zoom < ZOOM_CADASTRE_MIN) {
    leafletProxy(map_id, session = session) %>%
      clearGroup(group_name) %>%
      hideGroup(group_name)
    if (!is.null(session)) session$userData$cadastre_layer_hash[[map_id]] <- NULL
    if (CACHE_DEBUG) message(sprintf("[cache] cadastre(%s): exit (zoom<%d)", map_id, ZOOM_CADASTRE_MIN))
    return(invisible())
  }
  
  # 3) BBOX courante en numérique
  bbox_current <- c(
    xmin = bounds$west,
    ymin = bounds$south,
    xmax = bounds$east,
    ymax = bounds$north
  )
  
  bbox_contains <- function(cache, cur) {
    cache["xmin"] <= cur["xmin"] && cache["ymin"] <= cur["ymin"] &&
      cache["xmax"] >= cur["xmax"] && cache["ymax"] >= cur["ymax"]
  }

  bbox_cache <- parcelles_cache_bbox()
  tol_current <- simplify_tolerance(zoom)
  tol_cache   <- if (!is.null(bbox_cache)) attr(bbox_cache, "tol") else NULL

  # 4) Soit on filtre le cache, soit on charge depuis la BD
  #    Le cache n'est valide que si bbox courante incluse ET même tolérance.
  if (!is.null(bbox_cache) && bbox_contains(bbox_cache, bbox_current) &&
      !is.null(tol_cache) && identical(tol_cache, tol_current)) {
    bbox_sfc <- sf::st_as_sfc(sf::st_bbox(bbox_current, crs = 4326))
    parcelles_filtered <- tryCatch(
      sf::st_filter(parcelles_cache(), bbox_sfc, .predicate = sf::st_intersects),
      error = function(e) sf::st_sf(geometry = sf::st_sfc(crs = 4326))
    )

  } else {
    # Si la tolérance a changé, on jette tout le cache (les anciennes
    # géométries ont été simplifiées à une autre précision).
    if (!is.null(tol_cache) && !identical(tol_cache, tol_current)) {
      parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
      bbox_cache <- NULL
    }

    xmin_q <- bbox_current["xmin"] - buffer_deg
    ymin_q <- bbox_current["ymin"] - buffer_deg
    xmax_q <- bbox_current["xmax"] + buffer_deg
    ymax_q <- bbox_current["ymax"] + buffer_deg

    query <- glue::glue("
      SELECT
        c.idpar, c.dcntpa, c.idcomtxt, ST_SimplifyPreserveTopology(c.geompar, {tol_current}) AS geompar,
        string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires
      FROM gestcons.dico_cadastre c
      LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
      WHERE c.geompar && ST_Transform(ST_MakeEnvelope({xmin_q}, {ymin_q}, {xmax_q}, {ymax_q}, 4326), 2154)
      GROUP BY c.idpar, c.dcntpa, c.idcomtxt, c.geompar
    ")
    
    new_data <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) NULL)
    
    if (!is.null(new_data) && nrow(new_data) > 0) {
      invalid <- which(!sf::st_is_valid(new_data))
      if (length(invalid) > 0) {
        debug_print(paste("❌ nb geometries invalides", length(invalid)))
        new_data[invalid, "geometry"] <- sf::st_make_valid(new_data[invalid, ])
      }
      new_data <- sf::st_transform(new_data, 4326)
      
      # Fusion dans le cache (clé = idpar)
      if (nrow(parcelles_cache()) > 0) {
        parcelles_cache(
          dplyr::bind_rows(parcelles_cache(), new_data) |>
            dplyr::distinct(idpar, .keep_all = TRUE)
        )
      } else {
        parcelles_cache(new_data)
      }
      
      # MAJ de la bbox du cache (avec attribut tol pour invalidation
      # quand le zoom change de palier de simplification)
      nb <- sf::st_bbox(new_data)
      nb <- c(
        xmin = as.numeric(nb["xmin"]), ymin = as.numeric(nb["ymin"]),
        xmax = as.numeric(nb["xmax"]), ymax = as.numeric(nb["ymax"])
      )
      new_bbox <- if (is.null(bbox_cache)) nb else c(
        xmin = min(bbox_cache["xmin"], nb["xmin"]),
        ymin = min(bbox_cache["ymin"], nb["ymin"]),
        xmax = max(bbox_cache["xmax"], nb["xmax"]),
        ymax = max(bbox_cache["ymax"], nb["ymax"])
      )
      attr(new_bbox, "tol") <- tol_current
      parcelles_cache_bbox(new_bbox)

      # On charge le tampon dans le cache (pour les pans courts), mais on
      # n'AFFICHE que l'emprise exacte — cohérent avec le cache hit et avec la
      # liste/sélection des propriétaires (« parcelles affichées à l'instant T »).
      bbox_sfc_disp <- sf::st_as_sfc(sf::st_bbox(bbox_current, crs = 4326))
      parcelles_filtered <- tryCatch(
        sf::st_filter(new_data, bbox_sfc_disp, .predicate = sf::st_intersects),
        error = function(e) new_data
      )
    } else {
      parcelles_filtered <- sf::st_sf(geometry = sf::st_sfc(crs = 4326))
    }
  }
  
  # 5) Rien à afficher ?
  if (is.null(parcelles_filtered) || nrow(parcelles_filtered) == 0) {
    leafletProxy(map_id, session = session) %>%
      clearGroup(group_name) %>%
      hideGroup(group_name)
    if (!is.null(session)) session$userData$cadastre_layer_hash[[map_id]] <- NULL
    return(invisible())
  }

  # 5b) Court-circuit : si idpars + tolérance inchangés depuis le dernier
  # rendu, éviter le clearGroup + addPolygons (coûteux côté JS Leaflet).
  current_hash <- digest::digest(list(
    sort(as.character(parcelles_filtered$idpar)),
    tol_current
  ))
  if (!is.null(session) &&
      identical(session$userData$cadastre_layer_hash[[map_id]], current_hash)) {
    if (CACHE_DEBUG) message(sprintf("[cache] cadastre(%s): noop (%d rows, tol=%g)",
                                     map_id, nrow(parcelles_filtered), tol_current))
    return(invisible())
  }
  if (!is.null(session)) session$userData$cadastre_layer_hash[[map_id]] <- current_hash
  if (CACHE_DEBUG) message(sprintf("[cache] cadastre(%s): redraw (%d rows, tol=%g)",
                                   map_id, nrow(parcelles_filtered), tol_current))

  # 6) Labels
  parcelles_filtered <- parcelles_filtered |>
    dplyr::mutate(
      commune    = idcomtxt,                                   # attendu par .cf_make_labels
      surface_m2 = suppressWarnings(as.numeric(dcntpa)),       # attendu par .cf_make_labels
      contrats   = NA_character_,                              # placeholder si non dispo
      remarque   = NA_character_                               # placeholder si non dispo
    )

  lbl <- .cf_make_labels(parcelles_filtered, user_roles)

  # 7) Dessin
  prx <- leafletProxy(map_id, session = session) %>%
    clearGroup(group_name) %>%
    addPolygons(
      data = parcelles_filtered,
      group = group_name,
      color = "brown", weight = 1, fillOpacity = 0,
      label = lbl, layerId = ~idpar,
      highlightOptions = highlightOptions(color = "yellow", weight = 2, bringToFront = TRUE)
    )
  # On ne force l'affichage du calque QUE si l'utilisateur ne l'a pas décoché
  # dans le contrôle des couches (sinon un pan/zoom le réactiverait).
  if (isTRUE(show_group)) prx %>% showGroup(group_name) else prx %>% hideGroup(group_name)

  invisible()
}

# Fonction de débogage personnalisée
debug_print <- function(message) {
  # Vous pouvez ajouter des fonctionnalités supplémentaires ici, comme l'écriture dans un fichier log
  if(DEBUG) {
    message("DEBUG : ", message)
  }
}

log_query <- function(query) {
  if(DEBUG_SQL) {
    message("🔍 SQL exécutée :")
    message(query)
  }
  return(query)
}

get_contrats <- function(con) {
  res <- safe_db_query(con, glue("
        SELECT id, nom FROM gestcons.contrats_fonciers  
        ORDER BY nom
      "))
}

#' Récupère la liste unique des communes du cadastre
#' @param con connexion DBI active
#' @return vecteur de noms de communes (triés)
get_liste_communes <- function(con) {
  debug_print("get_liste_communes")
  req <- "
    SELECT DISTINCT idcomtxt
    FROM gestcons.dico_cadastre
    WHERE idcomtxt IS NOT NULL AND idcomtxt <> ''
  "
  res <- safe_db_query(con, req)
  v <- sort(unique(as.character(res$idcomtxt)))  # ← force en caractère
  v[nzchar(v)]                                   # ← retire les vides résiduels
}


load_dico <- function(con, table, id_col = "id", label_col = "libelle", order_col = NULL) {
  order_col <- order_col %||% label_col
  sql <- sprintf("SELECT %s, %s FROM %s ORDER BY %s", id_col, label_col, table, order_col)
  safe_db_query(con, sql)
}


build_resume_site_ui <- function(con, site_id) {
  debug_print("build_resume_site_ui")
  req(site_id)
  site_id <- as.integer(site_id)
  
  # Infos du site + libellés joints
  # - dico_type_milieu : libellé du type de milieu
  # - dico_cen (ou équivalent) : libellé long du gestionnaire (si présent)
  infos <- tryCatch({
    dbGetQuery(con, log_query(glue::glue("
      SELECT s.*,
             dtm.libelle       AS type_milieu_libelle,
             dc.libelle_long   AS gestionnaire_libelle_long
      FROM gestcons.sites s
      LEFT JOIN gestcons.dico_type_milieu dtm
        ON dtm.id = s.type_milieu_id
      LEFT JOIN gestcons.dico_cen dc
        ON dc.id::varchar = s.gestionnaire_site  -- adapte si gestionnaire_site est un int
      WHERE s.id = {site_id}
      LIMIT 1
    ")))
  }, error = function(e) data.frame())
  if (nrow(infos) == 0) return(div("Aucune donnée trouvée"))
  
  # Statut actuel
  statut_actuel <- tryCatch({
    dbGetQuery(con, log_query(glue::glue("
      SELECT ss.statut_site_id, ds.libelle, ss.date_debut, ss.remarque
      FROM gestcons.sites_statuts ss
      JOIN gestcons.dico_statut_sites ds ON ss.statut_site_id = ds.id
      WHERE ss.site_id = {site_id} AND ss.date_fin IS NULL
      ORDER BY ss.date_debut DESC
      LIMIT 1
    ")))
  }, error = function(e) data.frame())
  
  # Responsable & bénévole actifs
  responsable <- tryCatch({
    dbGetQuery(con, log_query(glue::glue("
      SELECT u.nom, u.prenom
      FROM gestcons.responsable_sites r
      JOIN gestcons.dico_utilisateur u ON r.user_id = u.id
      WHERE r.site_id = {site_id} AND r.actif = TRUE
      LIMIT 1
    ")))
  }, error = function(e) data.frame())
  
  benevole <- tryCatch({
    dbGetQuery(con, log_query(glue::glue("
      SELECT u.nom, u.prenom
      FROM gestcons.conservateur_benevole b
      JOIN gestcons.dico_utilisateur u ON b.user_id = u.id
      WHERE b.site_id = {site_id} AND b.actif = TRUE
      LIMIT 1
    ")))
  }, error = function(e) data.frame())
  
  # Libellés / fallbacks
  lib_type_milieu <- .safe_val(infos$type_milieu_libelle[1])
  lib_gestionnaire <- .safe_val(infos$gestionnaire_libelle_long[1])
  lib_statut <- if (nrow(statut_actuel) > 0) .safe_val(statut_actuel$libelle[1]) else "(non renseigné)"

  # Parcelles du site et de la continuité du site conservatoire : nombres et surfaces, en une seule
  # requête (FILTER) plutôt qu'un aller-retour chacun.
  # ⚠️ count(*)/sum() PostgreSQL = bigint -> integer64 côté R : conversion
  # explicite obligatoire (sprintf("%d", integer64) plante, "%f" imprime du bruit).
  # La surface par parcelle est calculée dans la sous-requête pour n'écrire
  # l'expression qu'une fois, les quatre agrégats se contentant de la filtrer.
  perimetre <- tryCatch({
    dbGetQuery(con, glue::glue("
      SELECT count(*) FILTER (WHERE NOT perimetre) AS n_site,
             count(*) FILTER (WHERE perimetre)     AS n,
             COALESCE(sum(surf) FILTER (WHERE NOT perimetre), 0) AS surf_site_m2,
             COALESCE(sum(surf) FILTER (WHERE perimetre), 0)     AS surf_m2
      FROM (
        SELECT pb.perimetre,
               COALESCE(c.dcntpa, ST_Area(ST_Transform(ppm.geometrie, 2154))) AS surf
        FROM gestcons.parcelles_base pb
        -- parcellaire_id est POLYMORPHE : son référent dépend de
        -- type_parcelle_id — dico_cadastre pour une parcelle cadastrale (1),
        -- perimetre_parcellaire_manuel pour une parcelle dessinée à la main (2).
        -- D'où les deux jointures, EXTERNES (une jointure interne sur le seul
        -- cadastre escamoterait les parcelles manuelles : le site 122, dont
        -- l'unique parcelle est manuelle, affichait « 0 ») et DISCRIMINÉES par
        -- type_parcelle_id — les deux tables ont des espaces d'identifiants
        -- indépendants, rien n'interdit qu'un id manuel existe aussi au cadastre.
        -- COALESCE sur le type : une ligne au type non renseigné est traitée en
        -- cadastrale, son état d'origine.
        LEFT JOIN gestcons.dico_cadastre c
          ON c.id = pb.parcellaire_id AND COALESCE(pb.type_parcelle_id, 1) = 1
        LEFT JOIN gestcons.perimetre_parcellaire_manuel ppm
          ON ppm.id = pb.parcellaire_id AND pb.type_parcelle_id = 2
        WHERE pb.site_id = {site_id}
      ) t
    "))
  }, error = function(e) data.frame(n_site = 0L, n = 0L, surf_site_m2 = 0, surf_m2 = 0))
  n_site    <- suppressWarnings(as.integer(as.numeric(perimetre$n_site[1])))
  n_peri    <- suppressWarnings(as.integer(as.numeric(perimetre$n[1])))
  surf_site <- suppressWarnings(as.numeric(perimetre$surf_site_m2[1]))
  surf_peri <- suppressWarnings(as.numeric(perimetre$surf_m2[1]))
  if (is.na(n_site)) n_site <- 0L
  if (is.na(n_peri)) n_peri <- 0L
  if (is.na(surf_site)) surf_site <- 0
  if (is.na(surf_peri)) surf_peri <- 0
  
  tagList(
    h4(paste("Site :", infos$libelle)),
    tags$ul(
      tags$li(strong("Type de milieu : "),        htmltools::htmlEscape(lib_type_milieu)),
      tags$li(strong("Statut : "),                htmltools::htmlEscape(lib_statut)),
      tags$li(strong("Gestionnaire : "),          htmltools::htmlEscape(lib_gestionnaire)),
      tags$li(strong("Date création : "),         htmltools::htmlEscape(.safe_val(infos$date_crea_site[1]))),
      tags$li(strong("Description : "),           htmltools::htmlEscape(.safe_val(infos$description_site[1]))),
      tags$li(strong("Parcelles du site : "),
              sprintf("%d parcelle(s), %.2f ha", n_site, surf_site / 10000)),
      if (n_peri > 0) {
        tags$li(strong("Continuité du site conservatoire : "),
                sprintf("%d parcelle(s), %.2f ha", n_peri, surf_peri / 10000))
      },
      tags$li(strong("Surface totale (site + continuité du site conservatoire) : "),
              sprintf("%.2f ha", (surf_site + surf_peri) / 10000)),
      if (nrow(responsable) > 0) {
        tags$li(strong("Responsable : "),
                htmltools::htmlEscape(paste(.safe_val(responsable$prenom[1]), .safe_val(responsable$nom[1]))))
      } else if (nrow(benevole) > 0) {
        tags$li(strong("Bénévole : "),
                htmltools::htmlEscape(paste(.safe_val(benevole$prenom[1]), .safe_val(benevole$nom[1]))))
      } else {
        list(
          tags$li(strong("Responsable : "), "—"),
          tags$li(strong("Bénévole : "), "—")
        )
      }
    )
  )
}


# Petit icône avec info-bulle (tooltip)
tooltip_info <- function(text, bs_version = c("auto","3","5")) {
  bs_version <- match.arg(bs_version)
  if (bs_version == "auto") {
    # on génère les deux attributs ; l'init JS (étape 2) choisira le bon
    return(tags$span(
      class = "af-info-icon",
      `data-toggle`    = "tooltip",        # BS3
      `data-bs-toggle` = "tooltip",        # BS5
      title = text,
      tags$i(class = "fa fa-info-circle")  # ou tags$span(" i ")
    ))
  } else if (bs_version == "5") {
    return(tags$span(
      class = "af-info-icon",
      `data-bs-toggle` = "tooltip",
      title = text,
      tags$i(class = "fa fa-info-circle")
    ))
  } else {
    return(tags$span(
      class = "af-info-icon",
      `data-toggle` = "tooltip",
      title = text,
      tags$i(class = "fa fa-info-circle")
    ))
  }
}

# Nom d’affichage à partir de la ligne utilisateur ou de l’email
display_name <- function(user_row = NULL, email = NULL) {
  if (!is.null(user_row) && nrow(user_row) == 1) {
    nom <- user_row$nom %||% ""
    prenom <- user_row$prenom %||% ""
    full <- paste(c(prenom, nom), collapse = " ")
    full <- gsub("\\s+", " ", full)
    full <- trimws(full)
    if (nzchar(full)) return(full)
  }
  if (!is.null(email) && nzchar(email)) return(email)
  "Utilisateur"
}


#' Charge tous les référentiels globaux du démarrage : dictionnaires,
#' zones de protection, valeurs par défaut, liste des sites, communes.
#'
#' Le corps est le bloc historique de app.R, déplacé tel quel : les objets
#' créés deviennent des variables locales, renvoyées en liste nommée. À
#' réinjecter via list2env(..., environment()) pour recréer les mêmes noms
#' globaux (les modules y accèdent par ces noms, portée lexicale).
#' Effet de bord conservé : options(gestcons.sites_choices_init = ...).
#' Log la durée totale (diagnostic du temps de démarrage).
#'
#' @param con Connexion/pool DBI
#' @return liste nommée (un élément par objet global à créer)
load_referentiels <- function(con) {
  t0 <- Sys.time()

# 📚 Dictionnaires
dico_type_milieu <- load_dico(con, "gestcons.dico_type_milieu", "id", "libelle", "libelle")
dico_geol <- safe_db_query(con, "
  SELECT id, libelle, parent_id, parent_id_2, parent_id_3
  FROM gestcons.dico_geologie
  ORDER BY libelle
")
dico_nature_perimetre <-  load_dico(con, "gestcons.dico_nature_perimetre", "id", "libelle", "libelle")
dico_echelle <- load_dico(con, "gestcons.dico_echelle_numerisation", "id", "libelle", "libelle")
dico_precision <- load_dico(con, "gestcons.dico_precision_num_site", "id", "libelle", "libelle")
dico_cen <- load_dico(con, "gestcons.dico_cen", "id", "libelle_long", "libelle_long")
dico_binaire <- load_dico(con, "gestcons.dico_binaire", "id", "libelle", "id")
dico_accessibilite <- load_dico(con, "gestcons.dico_accessibilite", "id", "libelle", "id")
dico_chasse <- load_dico(con, "gestcons.dico_chasse", "id", "libelle", "id")
dico_source_surf_parc <- load_dico(con, "gestcons.dico_source_surf_parc", "id", "libelle", "libelle")
dico_source_geom <- load_dico(con, "gestcons.dico_source_geom_parcelle", "id", "libelle", "libelle")
dico_type_maitrise <- safe_db_query(
  con,
  "SELECT 
     id, 
     CASE 
       WHEN libelle_mfu1 = libelle_mfu2 
       THEN libelle_mfu1
       ELSE CONCAT(libelle_mfu1, ' - ', libelle_mfu2)
     END AS libelle_concat
   FROM gestcons.dico_type_contrat_foncier
   ORDER BY libelle_mfu1, libelle_mfu2"
)
dico_statut_contrat <- load_dico(con, "gestcons.dico_type_statut_contrat", "id", "libelle", "libelle")
# Statut d'un DOCUMENT DE GESTION : dictionnaire distinct de celui des contrats.
# Les deux n'attribuent pas le même sens aux mêmes identifiants (3 = « Actif »
# côté contrats, « En cours d'élaboration » ici) — ne jamais les intervertir,
# c'est la cible de la clé étrangère doc_gestion_statut_id_fkey.
dico_statut_doc_gestion <- load_dico(con, "gestcons.dico_statut_doc_gestion", "id", "libelle", "libelle")
dico_statut_site <- load_dico(con, "gestcons.dico_statut_sites", "id", "libelle", "libelle")
dico_type_acteur <- dbGetQuery(                       # ⬅️ AJOUTE ICI
  con, "SELECT id, libelle FROM gestcons.dico_type_acteur ORDER BY libelle"
)
dico_type_action_animation <- dbGetQuery(
  con,
  "SELECT id, libelle 
   FROM gestcons.dico_type_action_animation 
   WHERE actif = TRUE 
   ORDER BY libelle"
)
dico_type_pratique_agricole <- load_dico(con, "gestcons.dico_type_pratique_agricole", "id", "libelle", "libelle")
dico_type_cheptel           <- load_dico(con, "gestcons.dico_type_cheptel",           "id", "libelle", "libelle")
dico_type_culture           <- load_dico(con, "gestcons.dico_type_culture",           "id", "libelle", "libelle")
dico_type_contrat_agricole <- load_dico(con, "gestcons.dico_type_contrat_agricole",   "id", "libelle", "libelle")

dico_doc_gestion_evaluation <- load_dico(con, "gestcons.dico_doc_gestion_evaluation", "id", "libelle", "libelle")
dico_type_doc_gestion <- load_dico(con, "gestcons.dico_type_doc_gestion", "id", "libelle", "libelle")
dico_methode_elaboration_doc_gestion <- load_dico(con, "gestcons.dico_methode_elaboration_doc_gestion", "id", "libelle", "libelle")

# Chargement des zones de protection au démarrage (Global)
zones_protection_global <- get_zones_protection(con)

# 🟦 Récupère l'ID de “Inconnue” dans la table échelle
default_echelle <- dico_echelle$id[dico_echelle$libelle == "inconnue"]
# 🟢 ID du gestionnaire par défaut
default_cen <- dico_cen$id[dico_cen$libelle_long == "Conservatoire d'espaces naturels d'Ariège"]
# 🟢 ID de la nature du périmètre par défaut
default_nature_perimetre <- dico_nature_perimetre$id[dico_nature_perimetre$libelle == "fusion des parcelles maîtrisées (foncier et/ou usage)"]
# 🟢 ID de la precision par défaut
default_precision <- dico_precision$id[dico_precision$libelle == "Non estimée"]

debug_print(paste0("default_nature_perimetre = ",default_nature_perimetre))

# 📋 Liste des sites
sites_existants <- dbGetQuery(con, "SELECT id, libelle FROM gestcons.sites
                                     WHERE type_site_id = 1 ORDER BY libelle")

# 📋 Liste des SECTEURS d'intervention. Elle ne sert pas à un sélecteur — la
# Stratégie foncière construit le sien — mais à nommer un secteur partout où
# l'on tient un identifiant sans son libellé, à commencer par la pastille des
# rôles de la barre du haut : un responsable de secteur y cherchait un id
# absent de sites_existants, qui filtre le type 1.
secteurs_existants <- dbGetQuery(con, "SELECT id, libelle FROM gestcons.sites
                                        WHERE type_site_id = 2 ORDER BY libelle")

sites_choices_init <- setNames(
  sites_existants$id,        # valeur envoyée (id)
  sites_existants$libelle    # libellé affiché
)
options(gestcons.sites_choices_init = sites_choices_init)



liste_communes <- get_liste_communes(con)

  # Tous les objets créés ci-dessus (variables locales), sous leurs noms.
  ref <- as.list(environment())
  ref$con <- NULL
  ref$t0  <- NULL
  log_time(sprintf("load_referentiels : %d objets chargés en %.1f s",
                   length(ref), as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  ref
}

#' Crée les acteurs « propriétaire » manquants pour un lot de parcelles
#' ------------------------------------------------------------------
#' Reprend les propriétaires cadastraux des parcelles désignées par leur `idpar`
#' et insère dans `dico_acteurs_fonciers_agricoles` ceux qui n'y figurent pas
#' encore. Extrait du chemin « association d'une parcelle au site » (mod_sites)
#' pour que l'ajout à la continuité du site conservatoire applique exactement la même règle, sans
#' en dupliquer la logique.
#'
#' Deux filtres hérités de l'original, à ne pas relâcher sans décision :
#' - PERSONNES PHYSIQUES uniquement (`dnomus` renseigné) ; les personnes morales
#'   (communes, État, SAFER…) sont écartées.
#' - dédoublonnage sur la clé normalisée nom/prénom/adresse de l'index
#'   `dico_acteurs_dedupe_idx`, en base (le LEFT JOIN `deja`) ET à l'insertion
#'   (ON CONFLICT), ce qui rend l'appel rejouable.
#'
#' @param conn Connexion (ou connexion de transaction) — pas un pool.
#' @param idpars Vecteur d'idpar cadastraux.
#' @param type_acteur_id Id du type d'acteur « Propriétaire ».
#' @return data.frame des acteurs insérés — 0 ligne si aucun.
# --- Acteurs : la forme ATTENDUE par les listes déroulantes -----------------
# Le reactiveVal partagé acteurs_existants_rv a cinq points d'écriture, dans
# app.R, mod_acteurs.R et mod_sites.R. Quatre y poussaient (id, acteur_label),
# le cinquième un tout autre schéma (id, nom, prenom, adresse, cp, commune,
# type_acteur_id) : les quatre listes « Acteurs » de l'onglet Contrats se
# vidaient alors silencieusement, et pour le reste de la session.
#
# Cette fabrique est le contrat unique du reactiveVal. Tout point d'écriture
# passe par elle ; aucun ne réécrit la requête.
fetch_acteurs_choices <- function(con) {
  safe_db_query(con, "
    SELECT id, CONCAT(nom, ' ', prenom) AS acteur_label
    FROM gestcons.dico_acteurs_fonciers_agricoles
    ORDER BY nom, prenom
  ")
}


creer_acteurs_proprietaires <- function(conn, idpars, type_acteur_id) {
  debug_print("creer_acteurs_proprietaires")
  idpars <- unique(idpars[!is.na(idpars) & nzchar(idpars)])
  vide <- data.frame(nom = character(0), prenom = character(0),
                     adresse = character(0), cp = character(0),
                     commune = character(0), stringsAsFactors = FALSE)
  if (length(idpars) == 0 || is.null(type_acteur_id) || length(type_acteur_id) == 0) {
    return(vide)
  }

  arr_txt <- paste0("ARRAY[",
                    paste(DBI::dbQuoteString(conn, idpars), collapse = ","),
                    "]::text[]")

  prospects <- safe_db_query(conn, glue::glue("
    WITH
    sel_idpar AS (
      SELECT UNNEST({arr_txt}) AS idpar
    ),
    parc_proprio AS (
      SELECT DISTINCT dc.idpar, dc.idprocpte
      FROM gestcons.dico_cadastre dc
      JOIN sel_idpar s ON s.idpar = dc.idpar
      WHERE NULLIF(btrim(dc.idprocpte), '') IS NOT NULL
    ),
    owners AS (
      SELECT DISTINCT
        p.idpar,
        pp.idprocpte,
        btrim(pp.dnomus) AS nom,
        NULLIF(
          split_part(
            regexp_replace(COALESCE(pp.dprnlp, ''), '[[:space:]]+', ' ', 'g'),
            ' ', 1
          ),
          ''
        ) AS prenom,
        COALESCE(NULLIF(btrim(pp.dlign3), ''), NULLIF(btrim(pp.dlign4), '')) AS adresse,
        btrim(pp.dlign6) AS dlign6_brute
      FROM parc_proprio p
      JOIN gestcons.dico_proprietaire pp ON pp.idprocpte = p.idprocpte
      WHERE NULLIF(btrim(pp.dnomus), '') IS NOT NULL  -- personnes physiques
    ),
    candidats AS (
      SELECT idpar, idprocpte, nom, prenom, adresse, dlign6_brute FROM owners
      WHERE NULLIF(nom, '') IS NOT NULL
    ),
    deja AS (
      -- Clé normalisée alignée sur l'index dico_acteurs_dedupe_idx
      SELECT
        LOWER(public.f_unaccent(TRIM(COALESCE(a.nom,     '')))) AS k_nom,
        LOWER(public.f_unaccent(TRIM(COALESCE(a.prenom,  '')))) AS k_prenom,
        LOWER(public.f_unaccent(TRIM(COALESCE(a.adresse, '')))) AS k_adresse
      FROM gestcons.dico_acteurs_fonciers_agricoles a
      WHERE a.type_acteur_id = {type_acteur_id}
    )
    SELECT DISTINCT
      c.idprocpte, c.nom, c.prenom, c.adresse, c.dlign6_brute
    FROM candidats c
    LEFT JOIN deja d
      ON d.k_nom     = LOWER(public.f_unaccent(TRIM(COALESCE(c.nom,     ''))))
     AND d.k_prenom  = LOWER(public.f_unaccent(TRIM(COALESCE(c.prenom,  ''))))
     AND d.k_adresse = LOWER(public.f_unaccent(TRIM(COALESCE(c.adresse, ''))))
    WHERE d.k_nom IS NULL
    ORDER BY c.nom, c.prenom NULLS LAST
  "))

  if (is.null(prospects) || nrow(prospects) == 0) return(vide)

  # Une même personne peut détenir plusieurs parcelles du lot.
  prospects <- dplyr::distinct(prospects, idprocpte, nom, prenom, .keep_all = TRUE)

  # CP et commune sont agglutinés dans dlign6 (« 09000 FOIX »).
  prospects <- prospects %>%
    dplyr::mutate(
      dlign6_brute = stringr::str_trim(dlign6_brute),
      m       = stringr::str_match(dlign6_brute, "^([0-9]{5})\\s+(.*)$"),
      cp      = ifelse(!is.na(m[, 1]), m[, 2], NA_character_),
      commune = ifelse(!is.na(m[, 1]), stringr::str_trim(m[, 3]), NA_character_)
    ) %>%
    dplyr::select(-m)

  a_inserer <- prospects %>%
    dplyr::transmute(
      commune        = commune,
      cp             = cp,
      type_acteur_id = !!type_acteur_id,
      adresse        = dplyr::coalesce(stringr::str_trim(adresse), NA_character_),
      prenom         = dplyr::na_if(stringr::str_trim(prenom), ""),
      nom            = dplyr::na_if(stringr::str_trim(nom), "")
    ) %>%
    dplyr::filter(!is.na(nom) & nom != "")

  if (nrow(a_inserer) == 0) return(vide)

  # Ne garder que les colonnes réellement présentes côté base.
  cols_tbl <- DBI::dbGetQuery(conn, "
    SELECT column_name FROM information_schema.columns
     WHERE table_schema = 'gestcons'
       AND table_name   = 'dico_acteurs_fonciers_agricoles'")$column_name
  a_inserer <- a_inserer[, intersect(c("commune", "cp", "type_acteur_id",
                                       "adresse", "prenom", "nom"), cols_tbl),
                         drop = FALSE]
  if (ncol(a_inserer) == 0) return(vide)

  sql_insert <- DBI::sqlAppendTable(
    conn,
    DBI::Id(schema = "gestcons", table = "dico_acteurs_fonciers_agricoles"),
    a_inserer
  )
  DBI::dbExecute(conn, paste0(
    as.character(sql_insert),
    " ON CONFLICT (",
    "type_acteur_id, ",
    "LOWER(public.f_unaccent(TRIM(COALESCE(nom,     '')))), ",
    "LOWER(public.f_unaccent(TRIM(COALESCE(prenom,  '')))), ",
    "LOWER(public.f_unaccent(TRIM(COALESCE(adresse, ''))))",
    ") DO NOTHING"
  ))

  a_inserer
}

# Tolérance de simplification des zones humides, en DEGRÉS (la couche est déjà
# en 4326, contrairement au cadastre qui est en 2154). Deux paliers seulement,
# pour la même raison que simplify_tolerance() : éviter un redraw à chaque cran
# de zoom. 0,0003° ≈ 33 m, 0,00005° ≈ 5 m.
# Marge chargée autour de l'emprise visible, en degrés (~2 km). Tant que la
# carte reste dans cette zone, aucune requête n'est relancée. Mesuré sur une
# emprise de site : 94 polygones sans tampon, 220 avec (64 Ko -> 145 Ko), pour
# environ 2 km de déplacement libre.
ZH_BUFFER_DEG <- 0.02

zh_simplify_tolerance <- function(zoom) {
  if (is.null(zoom) || !is.finite(zoom)) return(0.0003)
  if (zoom < 15) 0.0003 else 0.00005
}

#' Dessine les zones humides de l'emprise visible
#' ---------------------------------------------
#' Lit `gestcons.v_zones_humides_ana` (3 907 sites de l'ANA), et NON la table
#' `zones_humides.site_zone_humide` dont elle dérive : celle-ci appartient à une
#' autre application et porte une politique de sécurité au niveau ligne, évaluée
#' avec les droits de l'appelant, qui exigerait un accès à `intercat.organismes`.
#' La vue appartient au propriétaire de la table et neutralise ce détour
#' (cf. scripts/create_vue_zones_humides.sql).
#' Chargée à l'emprise, comme le cadastre, mais sans cache par bbox : la table
#' est petite et son index GiST rend la requête négligeable. Court-circuit par
#' hash de session pour ne pas redessiner à l'identique après un déplacement.
#'
#' @param show_group FALSE => on vide le groupe et on sort sans rien interroger.
refresh_zones_humides <- function(con, bounds, zoom, map_id,
                                  group_name = GROUPS$zones_humides,
                                  show_group = FALSE,
                                  session = shiny::getDefaultReactiveDomain()) {
  debug_print("refresh_zones_humides")
  prx <- leaflet::leafletProxy(map_id, session = session)

  if (!isTRUE(show_group)) {
    prx %>% leaflet::clearGroup(group_name) %>% leaflet::hideGroup(group_name)
    if (!is.null(session) && !is.null(session$userData$zh_layer_hash)) {
      session$userData$zh_layer_hash[[map_id]] <- NULL
    }
    if (!is.null(session) && !is.null(session$userData$zh_bbox)) {
      session$userData$zh_bbox[[map_id]] <- NULL
    }
    return(invisible())
  }
  if (is.null(bounds)) return(invisible())

  tol <- zh_simplify_tolerance(zoom)

  # Cache par emprise. Le hash plus bas évite de REDESSINER à l'identique, mais
  # il arrive trop tard : la requête et la lecture sf ont déjà coûté ~160 ms. On
  # court-circuite donc en amont tant que la vue reste dans la zone déjà
  # chargée et que la tolérance n'a pas changé.
  if (!is.null(session)) {
    if (is.null(session$userData$zh_bbox)) {
      session$userData$zh_bbox <- new.env(parent = emptyenv())
    }
    c_ <- session$userData$zh_bbox[[map_id]]
    if (!is.null(c_) && identical(c_$tol, tol) &&
        bounds$west  >= c_$xmin && bounds$east  <= c_$xmax &&
        bounds$south >= c_$ymin && bounds$north <= c_$ymax) {
      if (CACHE_DEBUG) message(sprintf("[cache] zones_humides(%s): bbox hit", map_id))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
  }

  xmin <- bounds$west  - ZH_BUFFER_DEG
  ymin <- bounds$south - ZH_BUFFER_DEG
  xmax <- bounds$east  + ZH_BUFFER_DEG
  ymax <- bounds$north + ZH_BUFFER_DEG

  query <- glue::glue("
    SELECT z.id_site, z.nom_usuel,
           ST_SimplifyPreserveTopology(z.geometrie, {tol}) AS geometrie
    FROM gestcons.v_zones_humides_ana z
    WHERE z.geometrie && ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326)
  ")
  # tryCatch : si la vue n'existe pas encore sur une instance, ou si les droits
  # manquent, la carte doit continuer de fonctionner sans la couche.
  zh <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) {
    message("Zones humides : ", conditionMessage(e)); NULL
  })

  # L'emprise chargée n'est mémorisée qu'en cas de succès : une erreur ou une
  # zone vide doit pouvoir être retentée au déplacement suivant.
  if (!is.null(session) && !is.null(zh) && nrow(zh) > 0) {
    session$userData$zh_bbox[[map_id]] <- list(
      tol = tol, xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax
    )
  }

  if (is.null(zh) || nrow(zh) == 0) {
    prx %>% leaflet::clearGroup(group_name)
    if (!is.null(session) && !is.null(session$userData$zh_layer_hash)) {
      session$userData$zh_layer_hash[[map_id]] <- NULL
    }
    return(invisible())
  }

  if (!is.null(session) && is.null(session$userData$zh_layer_hash)) {
    session$userData$zh_layer_hash <- new.env(parent = emptyenv())
  }
  if (!is.null(session)) {
    h <- digest::digest(list(sort(as.character(zh$id_site)), tol))
    if (identical(session$userData$zh_layer_hash[[map_id]], h)) {
      if (CACHE_DEBUG) message(sprintf("[cache] zones_humides(%s): noop (%d)", map_id, nrow(zh)))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
    session$userData$zh_layer_hash[[map_id]] <- h
    if (CACHE_DEBUG) message(sprintf("[cache] zones_humides(%s): redraw (%d)", map_id, nrow(zh)))
  }

  lbl <- lapply(
    paste0("<b>💧 Zone humide</b><br>",
           ifelse(is.na(zh$nom_usuel) | !nzchar(zh$nom_usuel),
                  "(sans nom)", htmltools::htmlEscape(zh$nom_usuel))),
    htmltools::HTML
  )

  prx %>%
    leaflet::clearGroup(group_name) %>%
    leaflet::addPolygons(
      data = zh, group = group_name,
      color = "#0ea5e9", weight = 1, opacity = 0.9,
      fillColor = "#38bdf8", fillOpacity = 0.25,
      label = lbl, layerId = ~paste0("zh-", id_site),
      options = leaflet::pathOptions(pane = "zh", interactive = TRUE)
    ) %>%
    leaflet::showGroup(group_name)

  invisible()
}

#' Dessine les LIMITES COMMUNALES de l'emprise visible
#' ----------------------------------------------------
#' Couche de repère : elle dit dans quelle commune on se trouve, ce que ni le
#' cadastre ni les parcelles ne montrent à l'écran. Utile surtout pour les
#' périmètres tracés à la main, qui n'ont aucune référence cadastrale et
#' peuvent chevaucher plusieurs communes.
#'
#' ⚠️ `gestcons.communes` est la couche IGN de TOUTE la France : 34 955 lignes
#' et 400 Mo de géométrie. Pas question de la charger entière — on filtre à
#' l'emprise, comme le cadastre, avec un cache de bbox et un court-circuit par
#' hash, exactement sur le modèle de `refresh_zones_humides`.
#'
#' ⚠️ La transformation porte sur l'ENVELOPPE, pas sur `c.geometry`. Transformer
#' la colonne la rendrait non indexable et le GiST ne servirait plus : mesuré
#' ailleurs dans ce fichier, un `ST_Transform` posé du mauvais côté fait passer
#' une jointure spatiale de 3 ms à 2 411 ms.
#'
#' NON INTERACTIVE, donc sans infobulle : la carte se pilote au clic sur les
#' parcelles, et une couche interactive posée au-dessus du cadastre
#' intercepterait ces clics. Le nom de la commune est déjà dans l'infobulle de
#' la parcelle et dans la fiche du site ou du secteur.
COMMUNES_BUFFER_DEG <- 0.01

# Tolérance en MÈTRES : la couche est en Lambert-93, pas en degrés comme les
# zones humides. 100 m de loin — un trait de limite ne se juge pas au mètre —,
# 10 m de près, où l'on regarde une parcelle contre une limite.
communes_simplify_tolerance <- function(zoom) {
  if (is.null(zoom) || !is.finite(zoom)) return(50)
  if (zoom < 11) 100 else if (zoom < 14) 50 else 10
}

refresh_limites_communales <- function(con, bounds, zoom, map_id,
                                       group_name = GROUPS$communes,
                                       show_group = FALSE,
                                       session = shiny::getDefaultReactiveDomain()) {
  debug_print("refresh_limites_communales")
  prx <- leaflet::leafletProxy(map_id, session = session)

  if (!isTRUE(show_group)) {
    prx %>% leaflet::clearGroup(group_name) %>% leaflet::hideGroup(group_name)
    if (!is.null(session)) {
      if (!is.null(session$userData$com_layer_hash)) session$userData$com_layer_hash[[map_id]] <- NULL
      if (!is.null(session$userData$com_bbox))       session$userData$com_bbox[[map_id]]       <- NULL
    }
    return(invisible())
  }
  if (is.null(bounds)) return(invisible())

  tol <- communes_simplify_tolerance(zoom)

  # Cache par emprise : tant que la vue reste dans la zone déjà chargée et que
  # la tolérance n'a pas changé, on ne réinterroge pas. Le hash plus bas évite
  # le redessin, mais il arrive après la requête — trop tard pour l'économiser.
  if (!is.null(session)) {
    if (is.null(session$userData$com_bbox)) {
      session$userData$com_bbox <- new.env(parent = emptyenv())
    }
    c_ <- session$userData$com_bbox[[map_id]]
    if (!is.null(c_) && identical(c_$tol, tol) &&
        bounds$west  >= c_$xmin && bounds$east  <= c_$xmax &&
        bounds$south >= c_$ymin && bounds$north <= c_$ymax) {
      if (CACHE_DEBUG) message(sprintf("[cache] communes(%s): bbox hit", map_id))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
  }

  xmin <- bounds$west  - COMMUNES_BUFFER_DEG
  ymin <- bounds$south - COMMUNES_BUFFER_DEG
  xmax <- bounds$east  + COMMUNES_BUFFER_DEG
  ymax <- bounds$north + COMMUNES_BUFFER_DEG

  query <- glue::glue("
    SELECT c.insee_com, c.nom,
           ST_Transform(ST_SimplifyPreserveTopology(c.geometry, {tol}), 4326) AS geometrie
    FROM gestcons.communes c
    WHERE c.geometry && ST_Transform(
            ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)
  ")
  com <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) {
    message("Limites communales : ", conditionMessage(e)); NULL
  })

  # L'emprise n'est mémorisée qu'en cas de succès : une erreur doit pouvoir
  # être retentée au déplacement suivant.
  if (!is.null(session) && !is.null(com) && nrow(com) > 0) {
    session$userData$com_bbox[[map_id]] <- list(
      tol = tol, xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax
    )
  }

  if (is.null(com) || nrow(com) == 0) {
    prx %>% leaflet::clearGroup(group_name)
    if (!is.null(session) && !is.null(session$userData$com_layer_hash)) {
      session$userData$com_layer_hash[[map_id]] <- NULL
    }
    return(invisible())
  }

  if (!is.null(session) && is.null(session$userData$com_layer_hash)) {
    session$userData$com_layer_hash <- new.env(parent = emptyenv())
  }
  if (!is.null(session)) {
    h <- digest::digest(list(sort(as.character(com$insee_com)), tol))
    if (identical(session$userData$com_layer_hash[[map_id]], h)) {
      if (CACHE_DEBUG) message(sprintf("[cache] communes(%s): noop (%d)", map_id, nrow(com)))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
    session$userData$com_layer_hash[[map_id]] <- h
    if (CACHE_DEBUG) message(sprintf("[cache] communes(%s): redraw (%d)", map_id, nrow(com)))
  }

  prx %>%
    leaflet::clearGroup(group_name) %>%
    leaflet::addPolygons(
      data = com, group = group_name,
      # Trait seul : un aplat, même très clair, masquerait les parcelles, et
      # une limite n'a pas de surface à montrer. Tireté pour ne pas se
      # confondre avec le contour d'un site, qui est plein.
      fill = FALSE, color = "#334155", weight = 2, opacity = 0.85,
      dashArray = "6,4",
      options = leaflet::pathOptions(pane = "communes", interactive = FALSE)
    ) %>%
    leaflet::showGroup(group_name)

  invisible()
}

# Couleurs des sites voisins. Volontairement désaturées et distinctes de tout ce
# qui désigne le site courant : bleu pour ses parcelles, violet tireté pour son
# contour, orange pour sa continuité du site conservatoire. L'ardoise ne dit « site » qu'au second
# plan.
# Jaune depuis le 2026-10-26, à la demande de l'utilisateur.
#
# ATTENTION au voisinage de COLORS_PARCELLES$draft_fill (#ffbb00), l'ambre des
# parcelles du site courant sous contrat en élaboration : un jaune d'or type
# #facc15 en est à 17 points de vert et 21 de bleu, indiscernable sur la
# carte. On prend donc un jaune franchement plus clair, et le contour reste
# sombre — sans quoi un aplat clair n'a plus de bord lisible sur fond
# satellite. Les voisins sont en outre tiretés et dans un pane inférieur,
# là où les parcelles du site ont un contour plein.
COLORS_VOISINS <- list(outline = "#a16207", fill = "#fde047")
# La CONTINUITÉ d'un site voisin garde l'ardoise. Les secteurs passent au
# jaune hachuré (ci-dessous) : si la continuité suivait ses parcelles en jaune
# hachuré elle aussi, les deux natures seraient indiscernables sur la carte.
COLOR_CONTINUITE_VOISINS <- list(outline = "#475569", fill = "#64748b")
# Secteurs d'intervention prioritaire — les périmètres de la stratégie
# foncière — vus depuis la carte d'un site : même jaune que les voisins, ce
# sont les hachures qui les distinguent.
COLOR_SECTEURS_VOISINS <- "#fde047"

#' Dessine les sites VOISINS du site sélectionné
#' ---------------------------------------------
#' Un polygone par site ET par nature, pour l'union des parcelles cadastrales
#' présentes dans l'emprise. Le site courant est exclu. Trois natures sont
#' dessinées, dans la même couche :
#'   - les parcelles des sites voisins, en aplat JAUNE ;
#'   - leur continuité, HACHURÉE en ardoise — elle dit ce qu'un voisin
#'     convoite, par opposition à ce qu'il maîtrise ;
#'   - les parcelles des secteurs d'intervention prioritaire — les périmètres
#'     de la stratégie foncière — HACHURÉES dans le même jaune que les
#'     voisins, les hachures suffisant à les distinguer d'un aplat.
#'
#' Une couche Leaflet PAR nature : la classe CSS qui porte le motif s'applique
#' à toute la couche et ne peut pas varier d'une entité à l'autre.
#'
#' Même mécanique que `refresh_zones_humides` : chargement à l'emprise avec
#' marge, cache de bbox pour ne pas réinterroger au moindre déplacement, et
#' court-circuit par hash. La clé de cache inclut le site courant, puisqu'il
#' détermine qui est « voisin ».
#'
#' @param site_id Site sélectionné (exclu du résultat). NULL => rien à dessiner.
#' @param show_group FALSE => on vide le groupe et on sort sans interroger.
refresh_sites_voisins <- function(con, bounds, site_id, map_id,
                                  group_name = GROUPS$voisins,
                                  show_group = FALSE,
                                  session = shiny::getDefaultReactiveDomain()) {
  debug_print("refresh_sites_voisins")
  prx <- leaflet::leafletProxy(map_id, session = session)

  vider <- function() {
    prx %>% leaflet::clearGroup(group_name)
    if (!is.null(session)) {
      if (!is.null(session$userData$voisins_hash)) session$userData$voisins_hash[[map_id]] <- NULL
      if (!is.null(session$userData$voisins_bbox)) session$userData$voisins_bbox[[map_id]] <- NULL
    }
  }

  if (!isTRUE(show_group)) {
    vider()
    prx %>% leaflet::hideGroup(group_name)
    return(invisible())
  }
  # Sans site sélectionné, la notion de voisin n'a pas de sens : la couche
  # « Sites existants » joue déjà ce rôle à l'échelle du département.
  if (is.null(bounds) || is.null(site_id) || is.na(site_id)) {
    vider()
    return(invisible())
  }
  sid <- as.integer(site_id)

  if (!is.null(session)) {
    if (is.null(session$userData$voisins_bbox)) {
      session$userData$voisins_bbox <- new.env(parent = emptyenv())
    }
    c_ <- session$userData$voisins_bbox[[map_id]]
    if (!is.null(c_) && identical(c_$sid, sid) &&
        bounds$west  >= c_$xmin && bounds$east  <= c_$xmax &&
        bounds$south >= c_$ymin && bounds$north <= c_$ymax) {
      if (CACHE_DEBUG) message(sprintf("[cache] sites_voisins(%s): bbox hit", map_id))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
  }

  xmin <- bounds$west  - ZH_BUFFER_DEG
  ymin <- bounds$south - ZH_BUFFER_DEG
  xmax <- bounds$east  + ZH_BUFFER_DEG
  ymax <- bounds$north + ZH_BUFFER_DEG

  # Le filtre « NOT p.perimetre » a disparu : on veut aussi la continuité des
  # voisins et les secteurs. La nature est calculée ici plutôt qu'en trois
  # requêtes. L'ordre du CASE compte : les parcelles d'un secteur portent
  # toutes perimetre = true, c'est le type de site qui les distingue.
  query <- glue::glue("
    SELECT s.id, s.libelle,
           CASE WHEN s.type_site_id = {TYPE_SITE_SECTEUR} THEN 'secteur'
                WHEN p.perimetre THEN 'continuite'
                ELSE 'site' END AS nature,
           ST_Transform(ST_Union(c.geompar), 4326) AS geom
    FROM gestcons.parcelles_base p
    JOIN gestcons.dico_cadastre c
      ON c.id = p.parcellaire_id AND p.type_parcelle_id = 1
    JOIN gestcons.sites s ON s.id = p.site_id
    WHERE p.site_id <> {sid}
      AND c.geompar && ST_Transform(
            ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)
    GROUP BY s.id, s.libelle, 3
  ")
  d <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) {
    message("Sites voisins : ", conditionMessage(e)); NULL
  })

  if (!is.null(session) && !is.null(d) && nrow(d) > 0) {
    session$userData$voisins_bbox[[map_id]] <- list(
      sid = sid, xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax
    )
  }

  if (is.null(d) || nrow(d) == 0) {
    vider()
    return(invisible())
  }

  if (!is.null(session)) {
    if (is.null(session$userData$voisins_hash)) {
      session$userData$voisins_hash <- new.env(parent = emptyenv())
    }
    h <- digest::digest(list(sort(paste0(d$id, "/", d$nature)), sid))
    if (identical(session$userData$voisins_hash[[map_id]], h)) {
      if (CACHE_DEBUG) message(sprintf("[cache] sites_voisins(%s): noop (%d)", map_id, nrow(d)))
      prx %>% leaflet::showGroup(group_name)
      return(invisible())
    }
    session$userData$voisins_hash[[map_id]] <- h
    if (CACHE_DEBUG) message(sprintf("[cache] sites_voisins(%s): redraw (%d)", map_id, nrow(d)))
  }

  # Une couche PAR nature. La classe CSS qui porte le motif de hachures
  # s'applique à toute la couche et ne peut pas varier d'une entité à l'autre :
  # un className vectorisé ne donnerait rien. Même découpage que mod_actions.R.
  #
  # Le remplissage plein reste posé : il sert de repli si le JS ne tourne pas,
  # et tc-hatch le remplace par le motif SVG sur les tracés pp-hachures.
  couches <- list(
    list(nature = "site",       titre = "\U0001F5FA Site voisin",
         col = COLORS_VOISINS$outline, remplissage = COLORS_VOISINS$fill,
         opacite = 0.35, classe = NULL),
    list(nature = "continuite", titre = "\U0001F5FA Continuité d'un site voisin",
         col = COLOR_CONTINUITE_VOISINS$outline, remplissage = COLOR_CONTINUITE_VOISINS$fill,
         opacite = 0.10, classe = "pp-hachures pp-hachures-voisins"),
    list(nature = "secteur",    titre = "\U0001F3AF Secteur d'intervention prioritaire",
         col = "#a16207", remplissage = COLOR_SECTEURS_VOISINS,
         opacite = 0.10, classe = "pp-hachures pp-hachures-secteurs")
  )

  prx %>% leaflet::clearGroup(group_name)

  for (couche in couches) {
    sel <- d$nature == couche$nature
    if (!any(sel)) next
    dd  <- d[sel, , drop = FALSE]
    lbl <- lapply(
      paste0("<b>", couche$titre, "</b><br>", htmltools::htmlEscape(dd$libelle)),
      htmltools::HTML
    )
    prx <- prx %>% leaflet::addPolygons(
      data = dd, group = group_name,
      color = couche$col, weight = 2, opacity = 0.9,
      dashArray = "6 3",
      fillColor = couche$remplissage, fillOpacity = couche$opacite,
      label = lbl,
      # La nature entre dans l'identifiant : un même site apparaît à la fois
      # en « site » et en « continuite », les deux entrées se télescoperaient.
      layerId = ~paste0("voisin-", couche$nature, "-", id),
      options = leaflet::pathOptions(pane = "voisins", className = couche$classe)
    )
  }

  prx %>% leaflet::showGroup(group_name)
  if (!is.null(session)) {
    session$sendCustomMessage("tc-hatch", list(id = map_id))
  }

  invisible()
}

# Remarque de sensibilité à ENREGISTRER, d'après la case et le texte saisis :
# le texte s'il y a lieu, NA sinon — sql_txt() et glue_sql() le rendent en
# NULL, que la colonne accepte. Décocher « Sensible ? » efface donc la
# remarque : elle n'aurait plus de sens, et resterait sinon dans la base sans
# qu'aucun formulaire ne la montre.
remq_sensibilite_saisie <- function(sensible, texte) {
  if (!isTRUE(sensible)) return(NA_character_)
  t <- trimws(as.character(texte %||% "")[1])
  if (is.na(t) || !nzchar(t)) NA_character_ else t
}

# Accessibilité au public à ENREGISTRER, ou à présélectionner : l'identifiant
# choisi, la valeur par défaut s'il manque. La colonne est NOT NULL, un NULL
# ferait échouer tout l'enregistrement du site. Un identifiant étranger au
# dictionnaire passe tel quel : la clé étrangère le refusera.
accessibilite_saisie <- function(x) {
  v <- suppressWarnings(as.integer(x))
  if (length(v) == 0 || is.na(v[1])) ACCESSIBILITE_SITE_DEFAUT else v[1]
}

# PMR à ENREGISTRER : 0 pour un site non accessible au public. Sa case est
# alors masquée, et une valeur cochée auparavant resterait sinon en base sans
# qu'aucun formulaire ne la montre — même règle que la remarque de
# sensibilité.
accessibilite_pmr_saisie <- function(accessibilite, pmr) {
  if (identical(accessibilite_saisie(accessibilite), ACCESSIBILITE_NON)) return(0L)
  if (isTRUE(pmr)) 1L else 0L
}

#' Champs du formulaire d'un site — fabrique PARTAGÉE
#' -------------------------------------------------
#' Extrait tel quel du modal de l'onglet Sites, pour que la promotion d'un
#' secteur d'intervention prioritaire en site présente EXACTEMENT le même
#' formulaire. Sans cette mise en commun, les deux auraient divergé au premier
#' champ ajouté d'un côté.
#'
#' Le bloc est repris à l'identique ; seul le sélecteur de géologie est injecté
#' par `geol_ui`, l'onglet Sites fournissant son sélecteur en cascade et la
#' Stratégie foncière une liste à plat.
#'
#' @param infos data.frame d'une ligne (le site), ou NULL en création.
#' @param statut_actuel data.frame du statut courant, ou NULL.
#' @param geol_ui UI du choix de géologie, montée par l'appelant.
#' @param get_comment fonction colonne -> texte d'infobulle.
#' @return un tags$div à deux colonnes, à placer dans un modalDialog.
site_form_fields <- function(
    ns, infos = NULL, statut_actuel = NULL,
    dico_type_milieu, dico_nature_perimetre, dico_echelle, dico_precision,
    dico_cen, dico_accessibilite, current_dico_utilisateur,
    choices_statut, choices_users,
    default_echelle, default_precision, default_cen, default_nature_perimetre,
    geol_ui = NULL,
    get_comment = function(col) "Aucune information disponible.") {
  if (is.null(infos)) infos <- list()
          # 🚨 DEBUT DU BLOC MODIFIÉ POUR LES 2 COLONNES 🚨
          tags$div(
            style = "display: flex; gap: 20px; flex-wrap: wrap; margin-bottom: 20px;", # Conteneur Flexbox principal
            
            # --- Colonne de Gauche (prend 50% de la largeur) ---
            tags$div(
              style = "flex: 1 1 45%; min-width: 300px;", # Flex: grandit, rétrécit, base 45%
              
              # LIGNE 1 : Nom du site
              textInput(ns("libelle"), "Nom du site *", value = ifelse(is.null(infos$libelle), "", infos$libelle)),
              
              # LIGNE 1.bis : Identifiant FCEN 
              textInput(ns("id_site_fcen"), "Identifiant FCEN du site", value = ifelse(is.null(infos$id_site_fcen), "", infos$id_site_fcen)),
              
              # LIGNE 2 : Responsable
              selectInput(
                ns("site_responsable_id"), "Responsable du site",
                choices = choices_users,
                selected = {
                  rid <- infos$responsable_user_id
                  ids <- as.character(current_dico_utilisateur$id)
                  if (!is.null(rid) && as.character(rid) %in% ids) as.character(rid) else ""
                }
              ),
              
              # LIGNE 3 : Début responsabilité (ConditionalPanel)
              conditionalPanel(
                condition = sprintf("input['%s'] != ''", ns("site_responsable_id")),
                dateInput(
                  ns("site_responsable_date"), "📆 Début responsabilité",
                  value = if (!is.null(infos$responsable_date_debut)) as.Date(infos$responsable_date_debut) else Sys.Date()
                )
              ),
              
              # LIGNE 4 : Bénévole
              selectInput(
                ns("site_benevole_id"), "Bénévole conservateur",
                choices = choices_users,
                selected = {
                  bid <- infos$benevole_user_id
                  ids <- as.character(current_dico_utilisateur$id)
                  if (!is.null(bid) && as.character(bid) %in% ids) as.character(bid) else ""
                }
              ),
              
              # LIGNE 5 : Début bénévolat (ConditionalPanel)
              conditionalPanel(
                condition = sprintf("input['%s'] != ''", ns("site_benevole_id")),
                dateInput(
                  ns("site_benevole_date"), "📆 Début bénévolat",
                  value = if (!is.null(infos$benevole_date_debut)) as.Date(infos$benevole_date_debut) else Sys.Date()
                )
              ),
              
              #  Sélecteur Animateurs
              selectizeInput(
                ns("site_animateurs_ids"),
                "Animateurs (utilisateurs CEN)",
                choices = choices_users[choices_users != ""], # Retire "— Aucun —" pour multi-select
                selected = as.character(infos$animateurs_user_ids),
                multiple = TRUE,
                options = list(placeholder = "Sélectionner un ou plusieurs animateurs...")
              ),
              
              br(),
              
              # LIGNE 6 : Type de milieu
              selectInput(
                ns("type_milieu_id"),
                label = tagList("Type de milieu *", tooltip_info(get_comment("type_milieu_id"))),
                choices = setNames(dico_type_milieu$id, dico_type_milieu$libelle),
                selected = ifelse(is.null(infos$type_milieu_id), "", as.character(infos$type_milieu_id))
              ),
              
              # LIGNE 7 : Géologie — fournie par l'appelant (cf. geol_ui)
              geol_ui,
              
              # LIGNE 8 : Nature du périmètre
              selectInput(
                ns("nature_perimetre_id"), 
                label = tagList("Nature du périmètre *",tooltip_info(get_comment("nature_perimetre_id"))),
                choices = setNames(dico_nature_perimetre$id, dico_nature_perimetre$libelle),
                selected = ifelse(is.null(infos$nature_perimetre_id), default_nature_perimetre, as.character(infos$nature_perimetre_id))
              ),
              
              # LIGNE 9 : Échelle
              selectInput(
                ns("echelle_num_id"), "Échelle de numérisation *",
                choices = setNames(dico_echelle$id, dico_echelle$libelle),
                selected = ifelse(is.null(infos$echelle_num_id), default_echelle, as.character(infos$echelle_num_id))
              )
              
            ), # --- Fin Colonne de Gauche ---
            
            # --- Colonne de Droite (prend 50% de la largeur) ---
            tags$div(
              style = "flex: 1 1 45%; min-width: 300px;", # Flex: grandit, rétrécit, base 45%
              
              # LIGNE 10 : Précision
              selectInput(
                ns("precision_num_site_id"), 
                label = tagList("Précision *", tooltip_info(get_comment("precision_num_site_id"))),
                choices = setNames(dico_precision$id, dico_precision$libelle),
                selected = ifelse(is.null(infos$precision_num_site_id), default_precision, as.character(infos$precision_num_site_id))
              ),
              
              # LIGNE 11 : Gestionnaire
              selectInput(
                ns("gestionnaire_site"), "Gestionnaire du site",
                choices = setNames(dico_cen$id, dico_cen$libelle_long),
                selected = ifelse(is.null(infos$gestionnaire_site), default_cen, as.character(infos$gestionnaire_site))
              ),
              
              # LIGNE 12 : Checkboxes
              tags$div(
                style = "display: flex; gap: 20px;",
                checkboxInput(ns("terrain_militaire"), "Terrain militaire ?", value = ifelse(is.null(infos$terrain_militaire_id), FALSE, infos$terrain_militaire_id == 1)),
                checkboxInput(ns("site_marin"), "Site marin ?", value = ifelse(is.null(infos$site_marin_id), FALSE, infos$site_marin_id == 1))
              ),

              # LIGNE 12.bis : Sensibilité et diffusion (2026-10-28). Le
              # formulaire d'un SECTEUR les portait, celui d'un site non : c'est
              # désormais l'inverse. La remarque n'a de sens que pour un site
              # sensible — elle ne s'affiche, et ne s'enregistre, que si la case
              # est cochée (cf. remq_sensibilite_saisie). isTRUE() : FALSE par
              # défaut en création comme sur une valeur absente.
              tags$div(
                style = "display: flex; gap: 20px;",
                checkboxInput(ns("sensibilite"), "Sensible ?",
                              value = isTRUE(as.logical(infos$sensibilite))),
                checkboxInput(ns("non_diffusion"), "Non diffusable ?",
                              value = isTRUE(as.logical(infos$non_diffusion)))
              ),
              conditionalPanel(
                condition = sprintf("input['%s'] === true", ns("sensibilite")),
                textAreaInput(
                  ns("remq_sensibilite"), "📝 Remarque sur la sensibilité",
                  # Jamais %||% seul : il laisse passer NA, que textAreaInput
                  # écrirait « NA » en toutes lettres — le défaut corrigé sur les
                  # remarques de rupture des contrats.
                  value = {
                    r <- infos$remq_sensibilite
                    if (is.null(r) || length(r) == 0 || is.na(r[1])) "" else as.character(r[1])
                  },
                  height = "60px")
              ),

              # LIGNE 12.ter : Accessibilité (2026-10-30). En création, les
              # DEFAULT de la base : accessible au public, pas aux PMR. La case
              # PMR disparaît pour un site non accessible, et s'enregistre
              # alors à 0 (cf. accessibilite_pmr_saisie).
              selectInput(
                ns("accessibilite_site"), "Accessible au public",
                choices = setNames(dico_accessibilite$id, dico_accessibilite$libelle),
                selected = as.character(accessibilite_saisie(infos$accessibilite_site))
              ),
              conditionalPanel(
                condition = sprintf("input['%s'] !== '%d'", ns("accessibilite_site"), ACCESSIBILITE_NON),
                checkboxInput(ns("accessibilite_pmr_site"), "Accessible aux PMR ?",
                              value = isTRUE(infos$accessibilite_pmr_site == 1))
              ),

              # LIGNE 13 : Date création
              dateInput(ns("date_crea_site"), "📆 Date de création", value = if (is.null(infos$date_crea_site)) Sys.Date() else as.Date(infos$date_crea_site)),
              
              # LIGNE 14 : Date MAJ
              dateInput(ns("date_maj_site"), "📆 Date de mise à jour", value = if (is.null(infos$date_maj_site)) Sys.Date() else as.Date(infos$date_maj_site)),
              
              # LIGNE 15 : Description (prend plus de place)
              textAreaInput(ns("description_site"), "📝 Description", value = ifelse(is.null(infos$description_site), "", infos$description_site), height = "80px"),
              
              # LIGNE 16 : Statut
              selectInput(
                ns("statut_site_id"), "Statut du site",
                choices = choices_statut,
                selected = if (!is.null(statut_actuel) && nrow(statut_actuel) > 0 && !is.null(statut_actuel$statut_site_id[1])) {
                  as.character(statut_actuel$statut_site_id[1])
                } else { "" }
              ),
              
              # LIGNE 17 : Date statut
              dateInput(
                ns("statut_date_debut"), "Date de début du statut",
                value = if (!is.null(statut_actuel) && nrow(statut_actuel) > 0 && !is.null(statut_actuel$date_debut[1])) {
                  as.Date(statut_actuel$date_debut[1])
                } else { Sys.Date() }
              ),
              
              # LIGNE 18 : Remarque statut
              textAreaInput(
                ns("statut_remarque"), "Remarque statut",
                value = if (!is.null(statut_actuel) && nrow(statut_actuel) > 0 && !is.null(statut_actuel$remarque[1])) statut_actuel$remarque[1] else "",
                height = "50px"
              )
              
            ) # --- Fin Colonne de Droite ---
          ) # --- Fin du bloc à deux colonnes ---
}
