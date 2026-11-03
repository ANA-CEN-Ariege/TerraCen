# Serveur principal

APP_VERSION <- trimws(readLines("VERSION", n = 1, warn = FALSE))

# Identifiant unique du PROCESSUS R (change à chaque (re)lancement de l'appli).
# Envoyé au client : si à une reconnexion il a changé -> l'appli a été relancée.
TC_BOOT_ID <- paste0(Sys.getpid(), "-", as.numeric(Sys.time()))

library(shiny)
library(DBI)
library(RPostgres)
library(dplyr)
library(leaflet)
library(glue)
library(sf)
library(shinyFeedback)
library(leaflet.extras)
library(bslib)
library(shinyWidgets)
library(shinyjs)
library(pool)

# Taille max des fichiers uploadés (pièces jointes contrats, docs, etc.)
options(shiny.maxRequestSize = 30 * 1024^2)  # 30 Mo

# ---- extraction des en-têtes de la requête initiale ----
extract_initial_headers <- function(req) {
  # httpuv récent : req$HEADERS
  if (!is.null(req$HEADERS)) {
    h <- req$HEADERS
    names(h) <- tolower(names(h))
    return(h)
  }
  # fallback : variables HTTP_* / CONTENT_*
  r <- as.list(req)
  nms <- names(r)
  keep <- grep("^(HTTP_|CONTENT_)", nms, value = TRUE)
  h <- r[keep]
  names(h) <- tolower(gsub("_","-", sub("^HTTP_", "", keep)))
  h
}

# ---- getters robustes et insensibles à la casse ----
safe_get_header <- function(h, name, default = NULL) {
  if (is.null(h) || !length(h) || is.null(names(h))) return(default)
  idx <- which(tolower(names(h)) == tolower(name))
  if (!length(idx)) return(default)
  v <- h[[idx[1]]]
  if (is.null(v) || length(v) == 0) default else paste(as.character(v), collapse = "; ")
}

safe_get_header_any <- function(h, names_vec, default = NULL) {
  if (is.null(h) || !length(h)) return(default)
  for (nm in names_vec) {
    val <- safe_get_header(h, nm, default = NA_character_)
    if (!is.na(val)) return(val)
  }
  default
}

source("R/helpers.R")
source("R/mod_actions.R")
source("R/mod_sites.R")
source("R/mod_strategie.R")
source("R/mod_contrats.R")
source("R/mod_docs_gestion.R")
source("R/mod_acteurs.R")
source("R/mod_utilisateurs.R")



# 🔗 Connexion PostgreSQL (pool partagé)
con <- dbPool(
  drv = RPostgres::Postgres(),
  dbname = Sys.getenv("DB_NAME"),
  host = Sys.getenv("DB_HOST"),
  port = 5432,
  user = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD"),
  sslmode = "require",
  minSize = 1,  # Toujours garder 1 connexion ouverte
  maxSize = 10, # Max 10 connexions simultanées vers la DB
  idleTimeout = 3600 # Fermer les connexions inactives après 1h
)
onStop(function() { poolClose(con) })

# Connexion de l'onglet Analyses, sous un rôle qui ne sait que lire les vues du
# schéma `analyses` (cf. scripts/analyse_role_lecture.sql). Tant que le mot de
# passe n'est pas posé sur le serveur, elle vaut NULL et l'onglet le dit, plutôt
# que d'empêcher l'application de démarrer.
pool_analyses <- local({
  mdp <- Sys.getenv("ANALYSE_DB_PASSWORD")
  if (!nzchar(mdp)) return(NULL)
  tryCatch(
    dbPool(
      drv = RPostgres::Postgres(),
      dbname = Sys.getenv("DB_NAME"), host = Sys.getenv("DB_HOST"), port = 5432,
      user = "terracen_analyse", password = mdp, sslmode = "require",
      minSize = 0, maxSize = 3, idleTimeout = 600
    ),
    error = function(e) {
      message("Analyses : connexion de lecture indisponible — ", conditionMessage(e))
      NULL
    }
  )
})
onStop(function() { if (!is.null(pool_analyses)) poolClose(pool_analyses) })

# L'onglet Analyses interroge l'API Claude, ce qui prend des dizaines de
# secondes. shiny-server ne donne qu'UN processus R à toute l'application : un
# appel synchrone y gelait l'écran de TOUS les utilisateurs. La conversation
# part donc dans un processus séparé (R/mod_analyse.R, analyse_conversation).
#
# Deux travailleurs : l'onglet est réservé aux administrateurs et les questions
# ne se chevauchent guère. Chacun est une session R qui ne charge que httr,
# jsonlite, DBI et RPostgres — pas l'application entière.
if (requireNamespace("future", quietly = TRUE)) {
  future::plan(future::multisession, workers = 2)
} else {
  message("future absent : l'onglet Analyses bloquera le processus pendant ses appels.")
}

# 📚 Référentiels globaux (dictionnaires, zones de protection, communes, sites,
# valeurs par défaut) : chargés une fois au démarrage du process via
# load_referentiels() (R/helpers.R), puis réinjectés sous leurs noms
# historiques — les modules y accèdent par ces noms (portée lexicale).
ref_globaux <- load_referentiels(con)
list2env(ref_globaux, envir = environment())
rm(ref_globaux)

# 🖥 UI
ui <- function(req) {
  # --- NOUVEAU : capture des en-têtes de la requête initiale ---
  initial_headers <- extract_initial_headers(req)
  header_names   <- names(initial_headers)
  header_values  <- unname(as.list(initial_headers))
  
  headers_json       <- jsonlite::toJSON(initial_headers,  auto_unbox = TRUE, null = "null")
  header_names_json  <- jsonlite::toJSON(header_names,     auto_unbox = TRUE, null = "null")
  header_values_json <- jsonlite::toJSON(header_values,    auto_unbox = TRUE, null = "null")
  
  fluidPage(
    # Bootstrap 5 via bslib, étape 5 de la refonte. Le thème lumen existe dans
    # les deux versions : on garde la même famille, pas le même socle. primary
    # est forcé sur --c-bleu pour que les boutons et les liens de Bootstrap
    # tombent sur le bleu des jetons, et non sur celui de lumen.
    # font_scale : Bootstrap 5 porte le texte de base à 16 px là où lumen en
    # Bootstrap 3 était à 14. Toute l'application grossissait de 14 % —
    # libellés, cellules de tableau, champs — sans que personne l'ait demandé.
    # 0,875 × 16 = 14 px : on retrouve la densité d'avant la bascule.
    # Les couleurs sémantiques de Bootstrap sont ramenées dans les huit teintes
    # de la maquette : sans cela, le vert vif et le rouge de lumen juraient à
    # côté du vert de pin. La maquette n'ayant qu'un accent et qu'un signal,
    # « créer » et « enregistrer » partagent désormais l'accent — c'est le ➕
    # qui distingue la création.
    theme = bslib::bs_theme(
      version = 5, bootswatch = "lumen", font_scale = 0.875,
      primary   = "#2f5d50",  # --c-accent
      success   = "#2f5d50",
      danger    = "#b4551f",  # --c-signal
      warning   = "#b4551f",
      info      = "#5c6861",  # --c-encre-douce
      secondary = "#5c6861"
    ),
    useShinyFeedback(),
    shinyjs::useShinyjs(),
    
    tags$head(
      tags$title("TerraCEN"),
      # Summernote en version « lite » : la version principale s'appuie sur les
      # déroulants de Bootstrap, dont l'attribut a changé de nom en 5
      # (data-toggle -> data-bs-toggle) ; sa barre d'outils cesserait de
      # s'ouvrir. La lite n'a aucune dépendance à Bootstrap.
      tags$link(rel="stylesheet", href="https://cdn.jsdelivr.net/npm/summernote@0.9.0/dist/summernote-lite.min.css"),
      tags$script(src="https://cdn.jsdelivr.net/npm/summernote@0.9.0/dist/summernote-lite.min.js"),
      
      # Tes assets locaux. Bust cache : version + date de modification du
      # fichier — la seule version ne suffit pas entre deux releases (les
      # déploiements test livrent des JS/CSS modifiés sous la même version,
      # et le navigateur ressert alors l'ancien fichier en cache).
      tags$link(rel = "stylesheet", type = "text/css",
                href = paste0("app.css?v=", APP_VERSION, ".",
                              as.integer(file.mtime(file.path("www", "app.css"))))),
      tags$link(rel = "shortcut icon", type = "image/png", href = "Ana-Cen-Ariège.png"),
      # Handlers/keep-alive et styles UI : dans app.js / app.css
      tags$script(src = paste0("app.js?v=", APP_VERSION, ".",
                               as.integer(file.mtime(file.path("www", "app.js")))))
    ),
    
    tags$head(
      # Dépendances Bootstrap4 Popper (si pas déjà incluses)
      tags$script(src = "https://cdnjs.cloudflare.com/ajax/libs/popper.js/1.16.1/umd/popper.min.js")
    ),
    
    # 1. Écran de chargement (avant que l'accès soit vérifié)
    conditionalPanel(
      # Condition JS: NE PAS afficher si l'accès est déjà déterminé (soit VRAI, soit FAUX)
      # On utilise output.app_ready (qui est TRUE une fois current_user évalué)
      condition = "!output.app_ready", 
      div(
        id = "welcome-screen",
        class = "welcome-screen",
        # Le logo d'abord, l'accueil dessous, le spinner en dernier : placé
        # avant le titre comme il l'était, il se serait glissé entre le logo
        # et la bienvenue.
        img(src = "logo_terracen.png", class = "welcome-logo",
            alt = "TerraCEN"),
        h1("Bienvenue sur terraCEN"),
        p("Chargement de l’application…"),
        div(class = "loader")                  # ← spinner animé
      )
    ),
    
    # 2. Application principale (Si l'app est prête ET l'utilisateur est connu)
    conditionalPanel(
      condition = "output.app_ready && output.has_app_access",
      div(class = "app-shell",
          # Barre du haut : marque, version et identité sur une ligne. Elle
          # remplace le rail vertical et son titre pivoté (étape 2 de la
          # refonte) — même bleu, mais la largeur gagnée revient à la carte.
          div(class = "tc-topbar",
              div(class = "tc-brand",
                  img(src = "logo_terracen.png", class = "brand-logo"),
                  div(
                    div(class = "tc-brand-name", "terraCEN"),
                    div(class = "tc-brand-sub", "Gestion des sites conservatoires")
                  )
              ),
              div(class = "tc-topbar-right",
                  div(class = "app-version", paste0("v", APP_VERSION)),
                  div(class = "user-info-bar",
                      uiOutput("user_info_ui")
                  ),
                  # Clair / sombre. Sans `mode`, le sélecteur part du réglage du
                  # système et retient ensuite le choix de l'utilisateur. Il pose
                  # data-bs-theme sur <html> : Bootstrap 5.3 bascule ses propres
                  # variables, et app.css bascule les huit jetons de la palette.
                  bslib::input_dark_mode(id = "mode_couleur")
              )
          ),
          div(class = "right-rail",
              tabsetPanel(id = "main_tabs",
                          # Tous les onglets du domaine « Sites » sont repliés dans le
                          # menu déroulant, donc retirés de la barre : on désigne
                          # explicitement l'onglet qui s'ouvre au démarrage, et c'est
                          # la page d'accueil, pas un onglet de travail.
                          selected = "tab-accueil",
                          tabPanel("🏠 Accueil",    value = "tab-accueil",   div(class="right-rail-inner", accueil_ui("accueil"))),
                          tabPanel("🛠 Actions",   value = "tab-anim",      div(class="right-rail-inner", animations_ui("animations"))),
                          tabPanel("📍 Sites",        value = "tab-sites",     div(class="right-rail-inner", sites_ui("sites"))),
                          tabPanel("📑 Contrats",     value = "tab-contrats",  div(class="right-rail-inner", contrats_ui("contrats"))),
                          tabPanel("📄 Docs Gestion", value = "tab-docgestion",div(class="right-rail-inner", doc_gestion_ui("doc_gestion"))),
                          tabPanel("🎯 Stratégie foncière", value = "tab-strategie", div(class="right-rail-inner", strategie_ui("strategie"))),
                          tabPanel("👤 Acteurs",      value = "tab-acteurs",   div(class="right-rail-inner", acteurs_ui("acteurs"))),
                          tabPanel("👤 Utilisateurs", value = "tab-users",     div(class="right-rail-inner", utilisateurs_ui("utilisateurs"))),
                          tabPanel("🧭 Analyses",   value = "tab-analyses",  div(class="right-rail-inner", analyse_ui("analyse"))),
                          tabPanel("📈 Activité",   value = "tab-monitoring",div(class="right-rail-inner", monitoring_ui("monitoring")))
              )
          )
      )
    ),
    
    # 3. Écran d'accès restreint (Si l'app est prête ET l'utilisateur n'est PAS connu)
    conditionalPanel(
      condition = "output.app_ready && !output.has_app_access",
      div(
        id = "denied-screen",
        class = "welcome-screen", # Réutiliser le style centré
        h1("🚫 Accès Restreint"),
        p(paste0("Votre compte email (", safe_get_header_any(initial_headers, c("X-Email","X-Auth-Request-Email","X-Forwarded-Email"), "non trouvé"), ") est bien connecté à Azure mais il n'est pas autorisé dans l'application terraCEN.")),
        p("Veuillez contacter l'administrateur de l'application.")
      )
    ),
    
    # --- NOUVEAU : push robuste des en-têtes initiaux vers le server ---
    tags$script(HTML(sprintf("
      (function(){
        var HN = %s;   // noms calculés côté R (fiables)
        var HV = %s;   // valeurs calculées côté R (fiables)
        function push(){
          if (window.Shiny && Shiny.setInputValue){
            Shiny.setInputValue('initial_headers_names',  HN, {priority:'event'});
            Shiny.setInputValue('initial_headers_values', HV, {priority:'event'});
          } else {
            setTimeout(push, 50);
          }
        }
        if (document.readyState === 'loading'){ document.addEventListener('DOMContentLoaded', push); }
        else { push(); }
      })();
    ", header_names_json, header_values_json)))
  )
}

# 🚀 SERVER
server <- function(input, output, session) {

  debug_print("entrée dans server")

  # Détection de relance d'appli : on (ré)envoie le boot id du processus une fois
  # le client prêt. Le JS (www/app.js) compare : boot id différent = relance.
  session$onFlushed(function() {
    session$sendCustomMessage("tc_boot", TC_BOOT_ID)
  }, once = TRUE)
  
  # --- Helpers logout (à mettre DANS server) ---
  get_origin_url <- function(session) {
    proto <- session$clientData$url_protocol  # "http:" ou "https:"
    host  <- session$clientData$url_hostname
    port  <- session$clientData$url_port
    # si port 80/443 ou vide, on ne l'ajoute pas
    port_part <- if (!nzchar(port) || port %in% c("80", "443")) "" else paste0(":", port)
    paste0(proto, "//", host, port_part)
  }
  
  azure_tenant <- Sys.getenv("AZURE_TENANT_ID")
  
  # 📚 Réactif partagé pour forcer le rechargement des données géographiques liées aux contrats
  contrats_update_trigger <- reactiveVal(0) 
  
  # Gate d’affichage : FALSE au départ, TRUE quand l’app est prête
  app_ready <- reactiveVal(FALSE)
  
  # Expose au JS pour pouvoir l’utiliser dans conditionalPanel
  output$app_ready <- reactive({ app_ready() })
  outputOptions(output, "app_ready", suspendWhenHidden = FALSE)
  
  post_logout_url <- reactive({
    origin <- get_origin_url(session)
    
    # URL de logout Azure avec prompt=login pour forcer la réauthentification
    paste0(
      "https://login.microsoftonline.com/", azure_tenant,
      "/oauth2/v2.0/logout?post_logout_redirect_uri=",
      URLencode(origin, reserved = TRUE),
      "&prompt=login"  # <-- Ajout ici pour forcer la réauthentification
    )
  })
  
  session$onFlushed(function() {
    # si tu veux, tu peux mettre ici des checks (ex: !dbIsValid(con)) avant de passer à TRUE
    app_ready(TRUE)
  }, once = TRUE)
  
  oauth2_proxy_signout_url <- reactive({
    # 1) oauth2-proxy purge les cookies
    # 2) puis redirige (paramètre rd) vers le logout Azure
    paste0("/oauth2/sign_out?rd=", URLencode(post_logout_url(), reserved = TRUE))
  })
  # --- fin helpers logout ---
  
  # --- utilitaires ---
  get_header_ci <- function(session, names_try) {
    h <- session$request$headers
    if (is.null(h)) return(NULL)
    hn <- tolower(names(h))
    for (nm in names_try) {
      i <- match(tolower(nm), hn)
      if (!is.na(i)) {
        val <- h[[i]]
        if (!is.null(val) && !is.na(val) && nzchar(val)) return(val)
      }
    }
    NULL
  }
  
  # Reconstitution sûre des en-têtes initiaux poussés depuis ui(req)
  initial_headers_named <- reactive({
    if (!is.null(input$initial_headers_names) && !is.null(input$initial_headers_values)) {
      nms  <- tolower(as.character(input$initial_headers_names))
      vals <- lapply(input$initial_headers_values, function(v) if (is.null(v)) "" else v)
      return(stats::setNames(as.list(vals), nms))
    }
    list()
  })
  
  
  current_identity <- reactive({
    # 1) préférer l'email/user de la requête initiale (ui(req))
    h_init <- initial_headers_named()
    email  <- safe_get_header_any(h_init, c("X-Email","X-Auth-Request-Email","X-Forwarded-Email"))
    user   <- safe_get_header_any(h_init, c("X-User","X-Auth-Request-User","X-Auth-Request-Preferred-Username","X-Forwarded-User"))
    
    # 2) fallback : essayer côté WebSocket si rien en initial
    if (is.null(email) || !nzchar(email) || identical(email, "(absent)")) {
      h_ws <- session$request$headers
      if (!is.null(h_ws)) {
        # normaliser : certains httpuv donnent les clés déjà en minuscules
        # on les traite via safe_get_header_any qui est case-insensitive
        email <- safe_get_header_any(h_ws, c("X-Email","X-Auth-Request-Email","X-Forwarded-Email"))
        user  <- if (nzchar(user %||% "")) user else safe_get_header_any(h_ws, c("X-User","X-Auth-Request-User","X-Auth-Request-Preferred-Username","X-Forwarded-User"))
      }
    }
    
    list(
      email = if (!is.null(email) && nzchar(email)) email else NULL,
      user  = if (!is.null(user)  && nzchar(user))  user  else NULL
    )
  })
  
  # 🎭 Cible d'impersonation (réservée aux AD) : id dico_utilisateur ou NULL.
  impersonate_id <- reactiveVal(NULL)

  # Récupère une ligne dico_utilisateur par id (helper interne).
  fetch_user_by_id <- function(uid) {
    if (is.null(uid) || is.na(uid) || length(uid) == 0) return(NULL)
    sql <- glue::glue_sql("
      SELECT id, nom, prenom, email
      FROM gestcons.dico_utilisateur
      WHERE id = {uid}
      LIMIT 1
    ", .con = con)
    df <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) return(NULL)
    df[1, , drop = FALSE]
  }

  # Utilisateur RÉEL (basé sur l'email des en-têtes) — jamais affecté par l'impersonation.
  real_user <- reactive({
    remote_ip <- session$request$REMOTE_ADDR %||% ""
    is_local_ip <- remote_ip %in% c("127.0.0.1", "::1", "localhost")
    email <- current_identity()$email %||% if (is_local_ip) 'claude.g@ariegenature.fr' else NULL
    if (is.null(email) || !nzchar(email)) return(NULL)

    # ⚠️ adapte le nom de colonne si besoin (email / courriel / mail)
    sql <- glue::glue_sql("
    SELECT id, nom, prenom, email
    FROM gestcons.dico_utilisateur
    WHERE lower(email) = lower({email})
    LIMIT 1
  ", .con = con)

    df <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) return(NULL)
    df[1, , drop = FALSE]
  })

  # 📈 Journalisation des connexions : une ligne dans gestcons.connexion_log par
  # session, dès que le vrai utilisateur est connu. once = TRUE -> une seule fois
  # par session ; on logue toujours le VRAI user (jamais l'identité empruntée).
  # Échec silencieux (try) : ne jamais bloquer l'accès si l'insert échoue.
  observeEvent(real_user(), {
    ru <- real_user()
    if (is.null(ru) || is.null(ru$id) || is.na(ru$id)) return()
    # L'adresse vue par Shiny est celle de la socket locale avec shiny-server :
    # elle valait donc 127.0.0.1 pour TOUTES les connexions, ce qui rendait la
    # colonne inexploitable. On privilégie l'en-tête posé par le proxy, dont la
    # première valeur est le client d'origine (X-Forwarded-For peut lister la
    # chaîne complète : « client, proxy1, proxy2 »).
    ip <- {
      h   <- initial_headers_named()
      fwd <- safe_get_header_any(h, c("X-Forwarded-For", "X-Real-IP"))
      val <- if (!is.null(fwd) && nzchar(trimws(fwd))) {
        trimws(strsplit(fwd, ",", fixed = TRUE)[[1]][1])
      } else {
        session$request$REMOTE_ADDR %||% ""
      }
      # La colonne n'est pas bornée, mais l'en-tête vient du client : on borne
      # à 45 caractères, la longueur maximale d'une adresse IPv6.
      substr(val %||% "", 1, 45)
    }
    # Trace horodatée dans le log Shiny — UNE ligne par session (l'ancien
    # message() dans real_user() écrivait une ligne à chaque évaluation).
    log_time(paste0("Connexion : ", ru$email, " (", ip, ")"))
    try(DBI::dbExecute(con, glue::glue_sql(
      "INSERT INTO gestcons.connexion_log (user_id, email, ip)
       VALUES ({ru$id}, {ru$email}, {ip})", .con = con)), silent = TRUE)
  }, once = TRUE, ignoreNULL = TRUE)

  # Le vrai utilisateur est-il administrateur ? Garde-fou : seul un AD réel peut
  # impersonifier, et c'est ce qui garde le menu visible pendant l'impersonation.
  real_is_admin <- reactive({
    uid <- real_user()$id
    if (is.null(uid) || is.na(uid) || length(uid) == 0) return(FALSE)
    res <- safe_db_query(con, glue::glue_sql("
      SELECT administrateur FROM gestcons.dico_utilisateur
      WHERE id = {uid} LIMIT 1
    ", .con = con))
    isTRUE(res$administrateur[1] %||% FALSE)
  })

  # Impersonation effectivement active ? (cible définie + vrai user AD + cible ≠ soi)
  active_impersonation_id <- reactive({
    tid <- impersonate_id()
    if (is.null(tid) || !isTRUE(real_is_admin())) return(NULL)
    ru <- real_user()
    if (!is.null(ru) && isTRUE(as.integer(tid) == as.integer(ru$id))) return(NULL)
    tid
  })

  # Utilisateur EFFECTIF : la cible si impersonation active, sinon le vrai user.
  # Point d'injection unique : user_roles() en dépend, donc rôles/pastille/onglets
  # se recomportent automatiquement comme pour la cible.
  current_user <- reactive({
    tid <- active_impersonation_id()
    if (is.null(tid)) return(real_user())
    fetch_user_by_id(tid) %||% real_user()  # cible invalide -> retour au vrai user
  })
  
  # 📚 Réactif pour l'accès: TRUE si l'utilisateur est connu
  has_app_access <- reactive({
    !is.null(current_user())
  })
  
  # Expose au JS pour contrôler l'affichage (similaire à app_ready)
  output$has_app_access <- reactive({ has_app_access() })
  outputOptions(output, "has_app_access", suspendWhenHidden = FALSE)
  
  # 📚 Réactif pour déterminer les rôles de l'utilisateur connecté
  user_roles <- reactive({
    user_id <- current_user()$id
    
    # Si l'utilisateur n'est pas trouvé dans dico_utilisateur, c'est un invité
    if (is.null(user_id) || is.na(user_id) || length(user_id) == 0) {
      return(list(
        global_role = "IN",
        site_roles = data.frame(site_id = integer(0), role = character(0))
      ))
    }

    # 1. Rôle Administrateur (AD)
    is_admin <- safe_db_query(con, glue::glue_sql("
      SELECT administrateur FROM gestcons.dico_utilisateur
      WHERE id = {user_id}
      LIMIT 1
    ", .con = con))$administrateur[1] %||% FALSE
    
    if (isTRUE(is_admin)) {
      
      return(list(
        global_role = "AD",
        site_roles = data.frame(site_id = integer(0), role = character(0))
      ))
    }
    
    # 2. Rôles par site (RS et AN)
    # Requête unifiée pour Responsable (RS), Bénévole (RS), et Animateur (AN)
    site_roles_query <- glue::glue_sql("
      WITH responsable AS (
        SELECT rs.site_id, 'RS' AS role, s.type_site_id
        FROM gestcons.responsable_sites rs
        INNER JOIN gestcons.sites s ON s.id = rs.site_id
        WHERE rs.user_id = {user_id} AND rs.actif = TRUE
      ),
      benevole AS (
        SELECT cb.site_id, 'AN' AS role, s.type_site_id
        FROM gestcons.conservateur_benevole cb
        INNER JOIN gestcons.sites s ON s.id = cb.site_id
        WHERE cb.user_id = {user_id} AND cb.actif = TRUE
      ),
      animateur AS (
        SELECT ans.site_id, 'AN' AS role, s.type_site_id
        FROM gestcons.animateur_sites ans
        INNER JOIN gestcons.sites s ON s.id = ans.site_id
        WHERE ans.user_id = {user_id} AND ans.actif = TRUE
      )
      SELECT site_id, role, type_site_id FROM responsable
      UNION
      SELECT site_id, role, type_site_id FROM benevole
      UNION
      SELECT site_id, role, type_site_id FROM animateur
    ", .con = con)
    
    site_roles_df <- safe_db_query(con, site_roles_query)
    
    # Assurer que les sites_id sont des entiers
    site_roles_df$site_id <- suppressWarnings(as.integer(site_roles_df$site_id))
    if ("type_site_id" %in% names(site_roles_df)) {
      site_roles_df$type_site_id <- suppressWarnings(as.integer(site_roles_df$type_site_id))
    }
    
    # 3. Rôle par défaut (IN)
    default_role <- if (nrow(site_roles_df) > 0) "RS/AN" else "IN" # Si des rôles de site existent, on ne le considère pas comme simple invité, bien que le rôle "global" reste technique.
    
    return(list(
      global_role = if (default_role == "IN") "IN" else "UTILISATEUR", # Séparation Invité/Utilisateur (si n'est pas AD)
      site_roles = site_roles_df
    ))
  })
  
  output$user_roles_ui <- renderUI({
    roles <- user_roles()
    
    if (is.null(roles) || is.null(roles$global_role)) {
      return(tags$div(class="text-muted", "Rôles non chargés."))
    }
    
    tagList(
      tags$h5("Rôles de l'utilisateur (DEBUG) 🔑", style="margin-top:10px;"),
      tags$p(tags$strong("Rôle Global: "), roles$global_role),
      
      if (nrow(roles$site_roles) > 0) {
        tags$div(
          tags$strong("Rôles par Site:"),
          tags$ul(
            style = "padding-left: 20px; margin-top: 5px;",
            lapply(1:nrow(roles$site_roles), function(i) {
              role_type <- roles$site_roles$role[i]
              site_id <- roles$site_roles$site_id[i]
              
              # Recherche du libellé du site (pour affichage lisible)
              site_info <- sites_existants[sites_existants$id == site_id, ]
              site_libelle <- if (nrow(site_info) == 1) site_info$libelle[1] else paste("Site ID", site_id)
              
              tags$li(
                tags$code(role_type), 
                paste0(" sur ", htmltools::htmlEscape(site_libelle))
              )
            })
          )
        )
      } else if (roles$global_role != "AD") {
        tags$p(tags$em("Aucun rôle spécifique par site trouvé."))
      }
    )
  })
  extract_display_name <- function(email_or_user) {
    if (is.null(email_or_user) || !nzchar(email_or_user)) return("Utilisateur")
    localpart <- sub("@.*$", "", email_or_user)
    first <- strsplit(localpart, "[._-]")[[1]][1]
    tools::toTitleCase(ifelse(nzchar(first), first, email_or_user))
  }
  
  output$user_info_ui <- renderUI({
    ident <- current_identity()
    email <- ident$email %||% ""
    user_row <- current_user()
    roles <- user_roles() # Récupère les rôles

    # 🎭 État impersonation : seul un AD réel voit le menu ; indicateur si profil emprunté.
    is_real_admin <- isTRUE(real_is_admin())
    impersonating <- !is.null(active_impersonation_id())
    
    # Récupérer la liste complète des sites pour les libellés
    sites_list <- stats::setNames(sites_existants$libelle, sites_existants$id)
    secteurs_list <- stats::setNames(secteurs_existants$libelle, secteurs_existants$id)

    # ⚠️ sites_list est un VECTEUR nommé, pas une liste : `v[["absent"]]` y
    # lève « indice hors limites » au lieu de rendre NULL, si bien que le
    # garde-fou `!is.null(sites_list[[id]])` ne protégeait rien. Et depuis la
    # bascule de 111 sites en secteurs, un responsable de SECTEUR cherche un
    # identifiant que sites_existants, filtré sur le type 1, ne porte pas —
    # la pastille des rôles plantait pour lui.
    .libelle_objet <- function(id, type) {
      id <- as.character(id)
      if (id %in% names(sites_list))    return(unname(sites_list[[id]]))
      if (id %in% names(secteurs_list)) return(paste0(unname(secteurs_list[[id]]), " (secteur)"))
      if (identical(as.integer(type), 2L)) paste0("Secteur inconnu (id ", id, ")")
      else paste0("Site inconnu (id ", id, ")")
    }
    
    # 1. Déterminer le rôle pratique le plus élevé pour l'affichage (AD > RS > AN > IN)
    highest_role <- roles$global_role
    if (highest_role != "AD") {
      has_rs_role <- any(roles$site_roles$role == "RS")
      has_an_role <- any(roles$site_roles$role == "AN")
      
      if (has_rs_role) {
        highest_role <- "RS" 
      } else if (has_an_role) {
        highest_role <- "AN" 
      } else {
        highest_role <- "IN" 
      }
    }
    
    # 2. Construction du CONTENU DÉTAILLÉ (HTML pour le Tooltip/title)
    # Note: On utilise une fonction pour générer le HTML
    content_roles_html <- function() {
      
      if (highest_role == "AD") {
        return(tags$div(
          tags$strong("Administrateur Global (AD)"), tags$br(),
          tags$span("Accès total à tous les sites et utilisateurs."), 
          class = "user-roles-popup" # <-- AJOUT DE LA CLASSE
        ))
      }
      
      if (nrow(roles$site_roles) == 0) {
        return(tags$div(
          tags$strong("Invité (IN)"), tags$br(),
          tags$span("Accès en lecture seule."), 
          class = "user-roles-popup" # <-- AJOUT DE LA CLASSE
        ))
      }
      
      rs_sites <- roles$site_roles %>% dplyr::filter(role == "RS")
      an_sites <- roles$site_roles %>% dplyr::filter(role == "AN", !(site_id %in% rs_sites$site_id))
      
      content <- list()
      
      # Rôle RS (Responsable de site)
      if (nrow(rs_sites) > 0) {
        content <- append(content, list(
          tags$div(tags$b("Responsable (RS) :")),
          tags$ul(
            Map(function(id, type) tags$li(.libelle_objet(id, type)),
                rs_sites$site_id, rs_sites$type_site_id)
          )
        ))
      }
      
      # Rôle AN (Animateur)
      if (nrow(an_sites) > 0) {
        content <- append(content, list(
          tags$div(tags$b("Animateur (AN) :")),
          tags$ul(
            Map(function(id, type) tags$li(.libelle_objet(id, type)),
                an_sites$site_id, an_sites$type_site_id)
          )
        ))
      }
      
      # Encapsuler le tout
      # 💡 ENCAPSULER DANS UN SEUL DIV GÉNÉRAL ALIGNÉ À GAUCHE
      return(tags$div(content, class = "user-roles-popup"))
    }
    
    # 3. Préparation des variables
    name_to_show <- display_name(user_row, email)
    role_circle_id <- "user-role-circle" 
    logout_href <- oauth2_proxy_signout_url()
    
    # Le contenu HTML détaillé est encodé ici pour être injecté dans l'attribut 'title'
    # 'doRenderTags' est essentiel pour transformer la liste de tags R en une chaîne HTML valide.
    html_content_string <- htmltools::doRenderTags(content_roles_html())
    
    # 4. Initialisation JS du Tooltip (doit être exécuté après le rendu)
    session$onFlushed(function() {
      # Utilisation d'une initialisation Tooltip robuste (compatible BS3/BS4/BS5)
      js_tooltip_init <- sprintf("
        (function() {
          var el = document.getElementById('%s');
          if (!el) return;

          // Une seule initialisation par session
          if (el.getAttribute('data-tc-tooltip') === 'ok') return;

          if (window.bootstrap && window.bootstrap.Tooltip) {
             // Bootstrap 5 : plus de greffon jQuery, et html:true s'appelle
             // désormais { html: true } à la construction.
             window.bootstrap.Tooltip.getOrCreateInstance(el, {
                 container: 'body', html: true,
                 placement: 'bottom', trigger: 'hover'
             });
          } else if (typeof jQuery !== 'undefined' && jQuery.fn.tooltip) {
             jQuery(el).tooltip({
                 container: 'body', html: true,
                 placement: 'bottom', trigger: 'hover'
             });
          }
          el.setAttribute('data-tc-tooltip', 'ok');
        })();
      ", role_circle_id)
      shinyjs::runjs(js_tooltip_init)
      app_ready(TRUE) 
    }, once = TRUE)
    
    
    # 5. Rendu du HTML de la barre utilisateur
    div(
      class = "user-info",
      
      # Cercle de rôle avec les attributs Tooltip
      # 🎭 Cliquable uniquement pour un AD réel → ouvre le menu de changement de profil.
      tags$div(
        id = role_circle_id,
        class = paste("user-avatar", if (is_real_admin) "user-avatar-admin", if (impersonating) "user-avatar-impersonating"),

        # 🚨 Attributs Tooltip 🚨
        title = html_content_string,         # Contenu HTML détaillé (rendu en string)
        `data-bs-html` = "true",             # Indique à Bootstrap d'interpréter le contenu comme du HTML
        `data-bs-toggle` = "tooltip",        # Déclencheur du Tooltip
        `data-bs-placement` = "bottom",
        onclick = if (is_real_admin) "Shiny.setInputValue('open_impersonate_menu', Math.random(), {priority: 'event'});" else NULL,

        HTML(highest_role)
      ),

      # Bloc identité (avec indicateur si un profil est emprunté)
      div(
        tags$div(style="font-weight:600;", name_to_show),
        if (impersonating) tags$div(
          class = "impersonation-flag",
          title = "Vous utilisez l'application avec le profil et les droits (lecture ET écriture) d'un autre utilisateur. Les modifications seront enregistrées en son nom.",
          "🎭 profil emprunté"
        )
      ),
      
      tags$a(
        href   = logout_href,
        class  = "logout-link",
        title  = "Se déconnecter de l’application et d’Azure",
        "Se déconnecter"
      )
    )
  })

  # 🎭 Menu d'impersonation (réservé aux administrateurs réels) ----------------
  # Ouvre un modal listant les utilisateurs + leur niveau de droits. Choisir un
  # utilisateur fait agir avec ses droits complets (lecture ET écriture) ;
  # l'option « Mon profil » revient à l'identité réelle.
  observeEvent(input$open_impersonate_menu, {
    if (!isTRUE(real_is_admin())) return(NULL)

    users <- safe_db_query(con, glue::glue_sql("
      WITH roles AS (
        SELECT user_id, 'RS' AS r FROM gestcons.responsable_sites    WHERE actif = TRUE
        UNION
        SELECT user_id, 'AN' AS r FROM gestcons.animateur_sites       WHERE actif = TRUE
        UNION
        SELECT user_id, 'AN' AS r FROM gestcons.conservateur_benevole WHERE actif = TRUE
      )
      SELECT u.id, u.nom, u.prenom, u.administrateur,
             bool_or(roles.r = 'RS') AS has_rs,
             bool_or(roles.r = 'AN') AS has_an
      FROM gestcons.dico_utilisateur u
      LEFT JOIN roles ON roles.user_id = u.id
      WHERE u.actif = TRUE
      GROUP BY u.id, u.nom, u.prenom, u.administrateur
      ORDER BY u.nom, u.prenom
    ", .con = con))

    if (is.null(users) || nrow(users) == 0) {
      showModal(modalDialog(title = "Changer de profil",
                            "Aucun utilisateur disponible.", easyClose = TRUE))
      return(NULL)
    }

    # Niveau le plus élevé par utilisateur (AD > RS > AN > IN). %in% TRUE neutralise les NA.
    is_ad <- users$administrateur %in% TRUE
    is_rs <- users$has_rs %in% TRUE
    is_an <- users$has_an %in% TRUE
    niveau <- ifelse(is_ad, "AD", ifelse(is_rs, "RS", ifelse(is_an, "AN", "IN")))
    labels <- trimws(sprintf("%s %s — %s",
                             users$nom %||% "",
                             ifelse(is.na(users$prenom), "", users$prenom),
                             niveau))
    choices <- stats::setNames(as.character(users$id), labels)
    current_target <- active_impersonation_id()

    showModal(modalDialog(
      title = "🎭 Changer de profil (administrateur)",
      tags$p(class = "text-muted",
             "Utilisez l'application avec les droits complets d'un autre utilisateur ",
             "(lecture et écriture). ",
             tags$b("Attention"), " : les modifications seront enregistrées en son nom."),
      selectInput("impersonate_select", "Voir l'application en tant que :",
                  choices  = c("— Mon profil (administrateur) —" = "", choices),
                  selected = if (!is.null(current_target)) as.character(current_target) else ""),
      footer = tagList(
        modalButton("Annuler"),
        actionButton("impersonate_apply", "Appliquer", class = "btn-primary")
      ),
      easyClose = TRUE
    ))
  })

  observeEvent(input$impersonate_apply, {
    if (!isTRUE(real_is_admin())) { removeModal(); return(NULL) }
    sel <- input$impersonate_select
    ru  <- real_user()
    if (is.null(sel) || !nzchar(sel)) {
      impersonate_id(NULL)
      message(sprintf("[impersonation] %s revient à son profil.", ru$email %||% "?"))
    } else {
      impersonate_id(as.integer(sel))
      message(sprintf("[impersonation] %s (id=%s) emprunte le profil id=%s.",
                      ru$email %||% "?", ru$id %||% "?", sel))
    }
    removeModal()
  })
  
  # Affiche/masque un onglet du bandeau principal selon un droit. Si l'onglet
  # actif devient masqué, redirige vers l'onglet Sites. Factorise les blocs
  # jQuery autrefois dupliqués (Utilisateurs, Acteurs, Contrats, Docs,
  # Activité).
  set_tab_visible <- function(tab_value, visible) {
    if (isTRUE(visible)) {
      shinyjs::runjs(sprintf(
        "$('#main_tabs a[data-value=\"%s\"]').closest('li').show();", tab_value
      ))
    } else {
      shinyjs::runjs(sprintf(
        "$('#main_tabs a[data-value=\"%s\"]').closest('li').hide();", tab_value
      ))
      # Rediriger si l'utilisateur se trouve sur cet onglet.
      #
      # La détection de l'onglet actif et la bascule vivent dans app.js, qui
      # accepte le balisage de Bootstrap 3 comme celui des versions suivantes
      # (le <li> porte la classe active dans l'un, le <a> dans l'autre ; le
      # greffon jQuery d'onglets n'existe plus dans l'autre). Les redire ici
      # revenait à parier sur une seule version.
      #
      # Shiny.setInputValue ne suffirait pas : il renseigne la valeur côté
      # serveur, mais rien ne change à l'écran — c'est le greffon d'onglets qui
      # bascule l'affichage, et Shiny met alors son input à jour tout seul.
      shinyjs::delay(100, shinyjs::runjs(sprintf(
        "if (window.tcOngletActif && window.tcOngletActif() === '%s') {
           window.tcNaviguerOnglet('tab-sites');
         }", tab_value
      )))
    }
  }

  # Observer : visibilité des onglets selon les rôles de l'utilisateur
  observe({
    # S'assurer que user_roles est disponible
    shiny::req(user_roles())
    roles <- user_roles()
    
    # Déterminer les permissions
    is_admin <- roles$global_role == "AD"
    
    # 1. 🆕 Permission Acteurs (AD ou RS ou AN) - L'ancienne règle convient (is_privileged_user)
    is_privileged_user <- is_admin || roles$global_role == "UTILISATEUR" || nrow(roles$site_roles) > 0
    
    # 2. 🆕 Permission Contrats (AD ou RS uniquement)
    # ⚠️ RS sur un SITE CONSERVATOIRE seulement (type 1). Être responsable d'un
    # secteur d'intervention prioritaire — une zone de prospection — ne doit pas
    # ouvrir la gestion des contrats fonciers : les deux responsabilités n'ont
    # pas la même portée.
    .rs_sur_type <- function(t) {
      sr <- roles$site_roles
      if (is.null(sr) || nrow(sr) == 0) return(FALSE)
      if (!"type_site_id" %in% names(sr)) return(any(sr$role == "RS"))
      any(sr$role == "RS" & sr$type_site_id %in% t)
    }
    has_rs_role     <- .rs_sur_type(1L)   # responsable d'un site conservatoire
    has_rs_any      <- .rs_sur_type(c(1L, 2L))  # ou d'un secteur
    is_contracts_manager <- is_admin || has_rs_role
    
    # 3. Permission Docs Gestion (AD, RS, AN, IN -> TOUS)
    is_doc_gestion_viewer <- TRUE # ⬅️ NOUVEAU : Toujours VRAI pour la visibilité totale

    # 4. 🆕 Permission Activité / Monitoring (AD, RS ou AN)
    has_an_role <- any(roles$site_roles$role == "AN")
    is_monitoring_viewer <- is_admin || has_rs_role || has_an_role
    
    set_tab_visible("tab-users",      is_admin)               # Utilisateurs : AD
    # Analyses : AD ou responsable d'un SITE conservatoire. Même règle que
    # Contrats et Activité — être responsable d'un secteur n'y donne pas accès.
    # Les consignes restent modifiables par les seuls administrateurs, la
    # garde vit dans le module.
    set_tab_visible("tab-analyses",   is_contracts_manager)   # Analyses : AD/RS
    set_tab_visible("tab-acteurs",    is_privileged_user)     # Acteurs : AD/RS/AN
    set_tab_visible("tab-monitoring", is_monitoring_viewer)   # Activité : AD/RS/AN

    # Les quatre onglets du domaine « Sites » sont retirés de la barre et
    # regroupés sous une entrée déroulante. Ce sont donc les items du menu, et
    # non les onglets eux-mêmes, qui portent désormais les droits : un onglet
    # masqué resterait atteignable par son item.
    #
    # Sites et Actions n'ont jamais eu de condition, les deux autres gardent
    # exactement celles qu'elles avaient.
    #
    # L'onglet Parcelles ne figure plus au menu : ses fonctions ont été
    # ramenées dans Sites. Il faut donc le masquer explicitement, sinon il
    # réapparaîtrait dans la barre, le menu ne repliant que ses propres items.
    items_sites <- list(
      list(value = "tab-sites", label = "Création / modification sites et parcelles"),
      list(value = "tab-anim",  label = "Actions (animation foncière, réunion, etc.)")
    )
    if (isTRUE(is_contracts_manager))  items_sites <- c(items_sites,
      list(list(value = "tab-contrats",   label = "Contrats")))
    if (isTRUE(is_doc_gestion_viewer)) items_sites <- c(items_sites,
      list(list(value = "tab-docgestion", label = "Docs de gestion")))


    session$sendCustomMessage("tc-sites-menu",
                              list(label = "\U0001F4CD Sites", items = items_sites))
    # Stratégie foncière : AD ou responsable de site. Une zone de prospection
    # dit quelles parcelles le CEN convoite — ce n'est pas une information à
    # laisser voir à un simple invité.
    set_tab_visible("tab-strategie",  is_admin || has_rs_any)

  })

  observeEvent(selected_site_rv(), {
    sid <- selected_site_rv()
    if (is.null(sid)) {
      selected_site_bbox4326_rv(NULL)
    } else {
      # Emprise via le helper SQL commun (ST_Extent, léger — l'ancienne version
      # passait par la lourde get_parcelles_by_site) ; inclut les périmètres
      # manuels, que l'ancienne version ignorait (site 100 % manuel -> NULL).
      selected_site_bbox4326_rv(site_bbox_4326(con, sid))
    }
  })
  
  observe({
    debug_print("========headers")
    h <- session$request$headers
    if (!is.null(h)) debug_print(paste(capture.output(str(h)), collapse="\n"))
  })
  
  
  popup_mode <- reactiveVal(FALSE)  # TRUE tant qu'un popup de parcelle est affiché
  
  # Mode clair/sombre, pour ce qui ne suit pas le CSS — les graphiques plotly,
  # rendus en SVG, dont les couleurs sont des attributs et non des règles.
  mode_sombre <- reactive(identical(input$mode_couleur, "dark"))

  # Sélection de site partagée entre onglets (NULL = aucun site, sinon l'id entier)
  selected_site_rv <- reactiveVal(NULL)
  selected_site_bbox4326_rv <- reactiveVal(NULL)
  
  # réactif partagé
  sites_shared <- shiny::reactiveVal(sites_existants)
  
  # 📚 Réactif partagé pour la liste des contrats FONCIERS (existant)
  contrats_choices_rv <- reactiveVal(data.frame(id = integer(), nom = character()))
  reload_contrats_choices <- function(con) {
    df <- safe_db_query(con, "SELECT id, nom FROM gestcons.contrats_fonciers ORDER BY nom")
    contrats_choices_rv(df)
  }
  reload_contrats_choices(con)
  
  # 📚 NOUVEAU — Réactif partagé pour la liste des contrats AGRICOLES
  contrats_agri_choices_rv <- reactiveVal(data.frame(id = integer(), nom = character()))
  reload_contrats_agri_choices <- function(con) {
    df <- safe_db_query(con, "SELECT id, nom FROM gestcons.contrats_agricoles ORDER BY nom")
    contrats_agri_choices_rv(df)
  }
  reload_contrats_agri_choices(con)
  
  
  
  # 📂 Dossier où stocker les fichiers (ex: ./Docs à côté de l'app)
  docs_root <- normalizePath(file.path(getwd(), "Docs"), mustWork = FALSE)
  if (!dir.exists(docs_root)) dir.create(docs_root, recursive = TRUE)
  # URL statique /docs/... → pointe vers docs_root (pour ouvrir les fichiers dans le navigateur)
  shiny::addResourcePath("docs", docs_root)
  
  EPHEMERAL_GROUPS <- c("drawn", "hover", "selection", "buffer")
  
  dico_utilisateur <- reactiveVal(
    dbGetQuery(con, "
    SELECT id, CONCAT(nom, ' ', prenom) AS nom_complet
    FROM gestcons.dico_utilisateur
    WHERE actif = TRUE
    ORDER BY nom, prenom
  ")
  )
  
  # Forme imposée par fetch_acteurs_choices() : (id, acteur_label). C'est le
  # contrat de ce reactiveVal, partagé par Sites, Acteurs et Contrats.
  acteurs_existants_rv <- reactiveVal(fetch_acteurs_choices(con))
  
  # Vue courante des cartes, partagée entre onglets : déclarée AVANT les modules
  # car la Stratégie foncière doit pouvoir l'effacer quand elle bascule sur
  # l'onglet Sites pour montrer un site précis.
  map_view_rv <- reactiveVal(NULL)

  anim_handle <- animations_server(
    "animations",
    con,
    dico_type_action_animation,
    dico_utilisateur,
    sites_shared,
    docs_root,
    contrats_choices_rv,
    selected_site_rv,
    contrats_update_trigger = contrats_update_trigger,
    current_user_rv = current_user,
    user_roles,
    # Le canal commun ne doit relancer les requêtes de cet onglet que s'il est
    # à l'écran ; sinon le module note que ses données sont périmées.
    onglet_visible = reactive(identical(input$main_tabs, "tab-anim"))
  )
  
  sites_handle <- sites_server(
    "sites",
    con,
    dico_type_milieu,
    dico_geol,
    dico_nature_perimetre,
    dico_echelle,
    dico_precision,
    dico_cen,
    dico_chasse,
    dico_source_surf_parc,
    dico_statut_contrat,
    dico_statut_site,
    dico_utilisateur,
    acteurs_existants_rv,
    sites_shared,
    liste_communes,
    contrats_choices_rv,
    selected_site_rv,
    contrats_update_trigger = contrats_update_trigger,
    current_user_rv = current_user,
    user_roles,
    zones_protection_data = zones_protection_global,
    dico_accessibilite = dico_accessibilite
  )
  
  contrats_handle <- contrats_server(
    id                       = "contrats",
    con                      = con,
    dico_type_statut_contrat = dico_statut_contrat,
    dico_utilisateur_rv      = dico_utilisateur,
    acteurs_existants_rv     = acteurs_existants_rv,
    dico_type_maitrise       = dico_type_maitrise,
    dico_type_pratique_agricole = dico_type_pratique_agricole,
    dico_type_cheptel           = dico_type_cheptel,
    dico_type_culture           = dico_type_culture,
    dico_type_contrat_agricole  = dico_type_contrat_agricole,
    reload_contrats_choices     = function() reload_contrats_choices(con),
    reload_contrats_agri_choices= function() reload_contrats_agri_choices(con),
    docs_root                   = docs_root,
    contrats_update_trigger     = contrats_update_trigger,
    current_user_rv             = current_user,
    user_roles
  )
  
  
  doc_gestion_handle <- doc_gestion_server(
    id = "doc_gestion",
    con = con,
    sites_shared = sites_shared,
    docs_root = docs_root,
    current_user_rv = current_user,
    user_roles = user_roles,
    dico_evaluation = dico_doc_gestion_evaluation,
    dico_type_doc = dico_type_doc_gestion,
    dico_methode = dico_methode_elaboration_doc_gestion,
    dico_statut = dico_statut_doc_gestion  # cible de la FK doc_gestion.statut_id
  )
  
  acteurs_handle <- acteurs_server(
    "acteurs",
    con = con,
    dico_type_acteur = dico_type_acteur,
    acteurs_existants_rv = acteurs_existants_rv,
    current_user_rv = current_user,
    user_roles
  )
  
  users_handle <- utilisateurs_server(
    "utilisateurs",
    con,
    dico_utilisateur,
    current_user_rv = current_user,
    user_roles
  )

  accueil_server("accueil", con, mode_sombre)

  analyse_server("analyse", con, pool_analyses, current_user, user_roles)

  monitoring_server("monitoring", con, mode_sombre)

  strategie_server(
    "strategie",
    con,
    dico_type_milieu,
    dico_geol,
    dico_nature_perimetre,
    dico_echelle,
    dico_precision,
    dico_utilisateur,
    current_user_rv = current_user,
    user_roles      = user_roles,
    dico_cen        = dico_cen,
    dico_statut_site = dico_statut_site,
    selected_site_rv = selected_site_rv,
    sites_shared     = sites_shared,
    map_view_rv      = map_view_rv,
    contrats_update_trigger = contrats_update_trigger,
    acteurs_existants = acteurs_existants_rv,
    zones_protection_data = zones_protection_global,
    dico_accessibilite = dico_accessibilite,
    liste_communes     = liste_communes
  )

  SITES_TAB <- "tab-sites"
  
  
  # (map_view_rv est déclarée plus haut, avant les modules : la Stratégie
  # foncière doit pouvoir l'effacer. Seule la carte VISIBLE émet des événements
  # _bounds/_zoom, donc elle reflète bien la vue courante.)

  .tab_map_id <- c(
    "tab-sites"     = "sites-map",
    "tab-anim"      = "animations-af_map"
  )

  .capture_map_view <- function(mid) {
    observeEvent(list(input[[paste0(mid, "_bounds")]], input[[paste0(mid, "_zoom")]]), {
      # On n'enregistre l'emprise QUE depuis la carte de l'onglet actuellement
      # affiché. Sinon une carte cachée en cours d'initialisation peut émettre
      # une emprise « monde » transitoire qui polluerait la vue partagée et
      # ferait apparaître la mappemonde au changement d'onglet.
      cur <- input$main_tabs
      if (is.null(cur) || !identical(unname(.tab_map_id[cur]), mid)) return()
      b <- input[[paste0(mid, "_bounds")]]
      z <- input[[paste0(mid, "_zoom")]]
      if (!is.null(b) && !is.null(z)) {
        map_view_rv(list(
          lng  = (b$west + b$east) / 2,
          lat  = (b$south + b$north) / 2,
          zoom = z
        ))
      }
    }, ignoreInit = TRUE)
  }
  .capture_map_view("sites-map")
  .capture_map_view("animations-af_map")

  observeEvent(input$main_tabs, {
    cur <- input$main_tabs
    # La carte d'accueil n'entre pas dans .tab_map_id : c'est une vue
    # d'ensemble de l'Ariège, elle ne doit ni alimenter ni suivre l'emprise
    # partagée entre onglets. Elle a tout de même besoin d'un
    # invalidateSize au retour, comme toute carte rendue masquée.
    if (identical(cur, "tab-accueil")) {
      session$sendCustomMessage("invalidate-map", list(id = "accueil-map"))
    }
    # Entrer dans un onglet referme les groupes de son contrôle des couches :
    # on y retrouve un contrôle compact, et non le groupe laissé ouvert la
    # fois d'avant (www/app.js, gestionnaire tc-lc-fermer).
    if (!is.null(cur) && cur %in% names(.tab_map_id)) {
      session$sendCustomMessage("tc-lc-fermer", list(id = unname(.tab_map_id[[cur]])))
    }
    # Quitter l'onglet Sites annule une sélection de parcelles non enregistrée.
    if (!identical(cur, SITES_TAB)) sites_handle$clear_selection()
    # Les onglets sans carte (Utilisateurs, Acteurs, Contrats, Docs gestion) ne
    # sont pas dans .tab_map_id : on sort proprement (sinon [[ lève « indice hors
    # limites » sur un nom absent).
    if (is.null(cur) || !cur %in% names(.tab_map_id)) return()
    target <- .tab_map_id[[cur]]

    v <- map_view_rv()
    if (!is.null(v)) {
      # Réapplique la MÊME emprise/zoom que l'onglet précédent, de façon fiable
      # (le handler JS attend que la carte soit visible avant invalidateSize+setView).
      session$sendCustomMessage("set-map-view",
                                list(id = target, lng = v$lng, lat = v$lat, zoom = v$zoom))
    } else {
      # Aucune vue capturée encore : repli sur le recadrage du site sélectionné
      session$sendCustomMessage("invalidate-map", list(id = target))
      sid <- selected_site_rv()
      if (!is.null(sid) && !is.na(sid)) {
        handle <- switch(cur,
                         "tab-sites"     = sites_handle,
                         "tab-anim"      = anim_handle,
                         NULL)
        if (!is.null(handle)) handle$focus_site(sid)
      }
    }
  }, ignoreInit = TRUE)
  
  
  
}

# 🚀 Lancer l'app
shinyApp(ui, server)

