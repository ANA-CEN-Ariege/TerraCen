#' Module pour gérer les animations foncières
#'
#' @param id Identifiant du module.
#' @param con Connexion à la base de données.
#' @param dico_type_action_animation Dictionnaire des types d'actions d'animation.
#' @param dico_utilisateur Dictionnaire des utilisateurs.
#' @param sites_existants Liste des sites existants.
#' @param docs_root Chemin vers le dossier des documents.
#'
#' @return Une liste contenant les fonctions `animations_ui` et `animations_server`.

#' Module pour gérer les animations foncières — UI
#' Corrigé pour uniformiser le padding via .right-rail-inner
animations_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    div(class = "flex-container",
        div(class = "sidebar-left-custom",
            titre_page("Actions (animation foncière, réunion, etc.)"),
            selectizeInput(
              ns("af_site_selector"),
              "🔎 Sélectionner un site :",
              choices = c(" " = "", getOption("gestcons.sites_choices_init", c())),
              selected = "",
              options = list(
                diacritics = TRUE,
                create = FALSE,
                placeholder = "Tapez un nom…"
              )
            ),
            actionButton(ns("af_reset_site"), "❌ Réinitialiser", class = "btn-default btn-secondary"),
            
            conditionalPanel(
              condition = sprintf("typeof input['%s'] !== 'undefined' && input['%s'] !== ''",
                                  ns('af_site_selector'), ns('af_site_selector')),
              actionButton(ns("af_add"), "➕ Nouvelle action", class = "btn-success", width = "100%"),
              hr(),
              uiOutput(ns("resume_site_af"))
            ),
            
            # Texte d’aide si aucun site n’est sélectionné
            uiOutput(ns("af_helper_text"))
        ),
        
        # --- Colonne droite (prend le reste) ---
        div(class = "right-rail",
            div(class = "right-rail-inner",
                div(class = "tc-page-carte",
                    
                    # --- Carte et actions ---
                    # Vue unique depuis que le tableau accompagne la carte : le
                    # sélecteur Carte/Liste n'avait plus d'objet, dézoomer sur
                    # le site entier redonne la liste complète de ses actions.
                    div(id = ns("af_map_panel"), style = "width:100%;",
                        # 🔁 même hauteur que dans SITES (--h-carte, app.css)
                        leafletOutput(ns("af_map"), height = "calc(var(--h-carte))", width = "100%"),
                        # Actions portées par les parcelles présentes dans
                        # l'emprise : le tableau suit les déplacements et le
                        # zoom de la carte.
                        conditionalPanel(
                          condition = sprintf("typeof input['%s'] !== 'undefined' && input['%s'] !== ''",
                                              ns('af_site_selector'), ns('af_site_selector')),
                          div(style = "margin-top:12px;",
                              uiOutput(ns("af_map_table_title")),
                              div(style = "min-height: 180px;", DT::DTOutput(ns("af_map_table")))
                          )
                        )
                    ),
                    
                    hr(),
                    div(class = "tc-page-bas", span())
                )
            )
        )
        
    ),
    # Handlers JS
    # (af-invalidate-size vivait ici en double de celui d'app.js, qu'il
    #  écrasait ; les deux sont réunis dans app.js.)
    tags$script(HTML("
          // Init Summernote pour tous les <textarea class='summernote'> du modal ouvert
          $(document).on('shown.bs.modal', function(e) {
            var $root = $(e.target);
            $root.find('textarea.summernote').each(function(){
              var $ed = $(this);
              if (!$ed.next('.note-editor').length) {
                $ed.summernote({
                  height: 240,
                  toolbar: [
                    ['style', ['style']],      // 👈 menu Titres (H1…H6)
                    ['font',  ['bold','italic','underline','clear']],
                    ['para',  ['ul','ol','paragraph']],
                    ['insert',['link','table']],       // 👈 bouton Tableau
                    ['view',  ['codeview','help']]
                  ],
                  styleTags: ['p','h1','h2','h3','h4','h5','h6','pre','blockquote'],
                  popover: {
                    table: [
                      ['add',   ['addRowDown','addRowUp','addColLeft','addColRight']],
                      ['delete', ['deleteRow','deleteCol','deleteTable']]
                    ]
                  },
                  callbacks: {
                    onChange: function(contents){ $ed.val(contents).trigger('change'); }
                  }
                });
    
              }
            });
          });
    
          // Handlers (inchangés)
          Shiny.addCustomMessageHandler('setSummernoteContent', function(message){
            var $el = $('#' + message.id);
            if ($el.length) {
              if (!$el.next('.note-editor').length) {
                $el.val(message.value).trigger('change');
              } else {
                $el.summernote('code', message.value || '');
              }
            }
          });
          Shiny.addCustomMessageHandler('clearSummernote', function(message){
            var $el = $('#' + message.id);
            if ($el.length) {
              if (!$el.next('.note-editor').length) {
                $el.val('').trigger('change');
              } else {
                $el.summernote('reset');
                $el.summernote('code', '');
                $el.trigger('change');
              }
            }
          });
        "))
  )
}

animations_server <- function(
    id, con, dico_type_action_animation, dico_utilisateur,
    sites_shared, docs_root, contrats_choices_rv,
    selected_site_rv, contrats_update_trigger = NULL, current_user_rv, user_roles,
    onglet_visible = NULL) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    MAP_ID <- "af_map" 
    bbox_site_rv <- reactiveVal(NULL)
    
    LEGEND_ID <- ns("af_legend_control")
    
    af_map_nonce <- reactiveVal(0L)   # force un renderLeaflet frais à chaque ouverture
    af_map_ready <- reactiveVal(FALSE) # vrai quand la carte est prête à recevoir des proxy updates
    
    af_site_id <- reactiveVal(NULL)
    af_site_parcelles <- reactiveVal(NULL)
    af_anim_parcelles <- reactiveVal(NULL)
    af_anim_selected <- reactiveVal(character())
    
    # Détermine si l'utilisateur a les droits AD ou RS sur le site actif
    can_edit_site <- reactive({
      roles <- user_roles()
      site_id <- selected_site_rv()

      is_admin <- roles$global_role == "AD"
      
      # Vérifie si l'utilisateur est RS sur le site sélectionné (ou AD)
      is_rs_on_site <- is_admin || (
        !is.na(site_id) && 
          any(roles$site_roles$site_id == site_id & roles$site_roles$role == "RS")
      )
      return(is_rs_on_site)
    })
    
    observe({
      site_id <- selected_site_rv()
      roles <- user_roles() # Rôle partagé du parent

      is_admin <- roles$global_role == "AD"
      is_rs_on_site <- can_edit_site()

      # Vérifie si l'utilisateur est AN sur le site sélectionné (ou RS/AD)
      # (Seulement pour le module Actions)
      is_an_on_site <- is_rs_on_site || (
        !is.na(site_id) &&
          any(roles$site_roles$site_id == site_id & roles$site_roles$role == "AN")
      )

      # La permission d'édition est donnée si AD OU RS sur le site OU AN sur le site
      can_edit <- is_admin || is_rs_on_site || is_an_on_site
      
      # ➡️ MISE À JOUR : Stocker la permission dans le reactiveVal
      is_editor_on_site_rv(can_edit)
      
      # --- Logique spécifique à chaque module ---
      
      # Dans actions_server :
      shinyjs::toggle("af_add", condition = is_an_on_site)
    })
    
    # Logique de déselection/changement (Observe selected_site_rv())
    observeEvent(selected_site_rv(), {
      sel <- selected_site_rv()
      sel <- if (is.null(sel) || is.na(sel)) "" else as.character(sel)
      
      if (!identical(input$af_site_selector, sel)) {
        updateSelectizeInput(session, "af_site_selector", selected = sel)
      }
      
      current_site_id <- suppressWarnings(as.integer(sel))
      
      # 💡 CORRECTION: Utiliser is.na() de manière robuste et vérifier si l'ID est valide.
      if (is.null(sel) || sel == "" || is.na(current_site_id)) {
        # Logique de reset si site non sélectionné
        af_site_id(NULL)
        leaflet::leafletProxy(ns("af_map"), session = session) %>%
          leaflet::clearGroup(AF_GROUP) %>%
          leaflet::clearGroup("Parcelles du site") %>%
          leaflet::clearGroup("Parcelles cadastrales") %>%
          leaflet::clearGroup("Périmètres manuels") %>%
          leaflet::clearGroup("Sites existants") %>%
          leaflet::showGroup("Sites existants") %>%
          leaflet::setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = 9)
        session$sendCustomMessage('af-invalidate-size', ns('af_map'))
        z <- input$af_map_zoom; if (is.null(z) || is.na(z)) z <- 9
        draw_circles(con, map_id = ns("af_map"), zoom = z)
        session$sendCustomMessage('toggle-layer-overlays', list(id = ns('af_map'), hide = TRUE))
        
        remove_legend(ns(MAP_ID), session, layer_id = LEGEND_ID)
        
      } else { # L'ID est un entier non-NA valide (le seul cas restant)
        # Logique d'initialisation (si un site est sélectionné)
        af_site_id(current_site_id)
        leaflet::leafletProxy(ns("af_map"), session = session) %>% leaflet::clearGroup("Sites existants")
        
        add_actions_legend(ns(MAP_ID), session, layer_id = LEGEND_ID)
      }
    }, ignoreNULL = FALSE)
    
    AF_GROUP <- "Parcelles (Actions)"   # groupe local pour dessiner/vider
    # Couche de mise en évidence des actions cochées sous la carte : groupe
    # distinct, vidé sans toucher au dessin des parcelles.
    AF_SEL_GROUP <- "Sélection (actions)"
    # Parcelle cliquée qui filtre le tableau : couleur distincte du rouge de la
    # sélection, les deux repères pouvant être affichés en même temps.
    AF_FOCUS_GROUP <- "Parcelle filtrée"
    
    # État pour la fenêtre de documents
    af_docs_anim_id <- reactiveVal(NULL)
    af_docs_reload <- reactiveVal(0)
    af_doc_uploader_nonce <- reactiveVal(0)
    af_docs_kind <- reactiveVal("F")
    
    af_parcelle_title <- reactiveVal("📋 Actions de la parcelle")
    # Parcelle sur laquelle le tableau sous la carte est filtré (clic sur la
    # carte). NULL = le tableau suit l'emprise.
    af_focus_parcelle <- reactiveVal(NULL)
    
    af_new_nonce <- reactiveVal(0)
    
    af_new_site_sf <- reactiveVal(NULL)
    af_parcelle_contrats_rv <- reactiveVal(NULL)
    af_new_selected <- reactiveVal(character())
    af_table_reload <- reactiveVal(0)
    af_edit_id <- reactiveVal(NULL)
    af_proprietaires_site_rv <- reactiveVal(list()) # list(label = c(idprocpte1, idprocpte2), ...)
    af_edit_kind <- reactiveVal("F")  # "F" = foncier, "A" = agricole
    af_view_last_id <- reactiveVal(NULL)  # action affichée en fiche (bouton Modifier)
    af_anim_contrat_mix <- reactiveVal(NULL) 
    is_editor_on_site_rv <- reactiveVal(FALSE)
    
    # Utilisateur à enregistrer en DB (fabrique commune, helpers.R)
    user_to_db <- make_user_to_db(current_user_rv)
    
    
    
    # Charger les sites existants
    sites <- reactive({
      sites_shared()
    })
    
    # Récupère les parcelles visibles pour le site sélectionné, comme dans 'Sites'
    # ⚠️ Utilisez vos helpers existants si vous en avez (ex: get_site_parcelles_sf(con, site_code))
    # Le canal commun réveillait cette chaîne même onglet fermé : l'observateur
    # de dessin plus bas est vivant, il lisait af_parcelles_avec_flag(), donc
    # .af_fetch_site_parcelles() repartait en base (518 ms mesurées sur le site
    # 216, 1101 parcelles) pour redessiner une carte invisible. On passe par un
    # compteur local, qui n'avance que si l'onglet Actions est à l'écran ; sinon
    # on note que les données sont périmées et on rattrape à l'entrée.
    af_data_nonce <- reactiveVal(0L)
    af_perime     <- reactiveVal(FALSE)

    .onglet_actions_visible <- function() {
      is.null(onglet_visible) || isTRUE(onglet_visible())
    }

    observeEvent(contrats_update_trigger(), {
      if (.onglet_actions_visible()) af_data_nonce(isolate(af_data_nonce()) + 1L)
      else af_perime(TRUE)
    }, ignoreInit = TRUE)

    if (!is.null(onglet_visible)) {
      observeEvent(onglet_visible(), {
        if (isTRUE(onglet_visible()) && isTRUE(af_perime())) {
          af_perime(FALSE)
          af_data_nonce(isolate(af_data_nonce()) + 1L)
        }
      })
    }

    af_parcelles_site_sf <- reactive({
      # 🔁 dépend du canal commun, filtré par la visibilité de l'onglet
      af_data_nonce()
      sid <- af_site_id()
      if (is.null(sid)) return(NULL)
      .af_fetch_site_parcelles(sid)
    })
    
    
    
    # 2) Marque les parcelles concernées par des animations
    # ⚠️ ADAPTEZ le SQL ci-dessous à VOTRE schéma des animations :
    # - Remplacez 'gestcons.animations_foncieres_parcelles' par votre table/vue de liaison
    # - Assurez-vous que 'cadastre_plot_id' est la clé commune
    af_parcelles_avec_flag <- reactive({
      af_table_reload()
      
      sf_par <- af_parcelles_site_sf()
      sid <- af_site_id()
      if (is.null(sf_par) || is.null(sid) || nrow(sf_par) == 0) return(NULL)
      
      q <- glue::glue("
            WITH any_anim AS (
              SELECT parcelle_id FROM gestcons.animation_fonciere_parcelles
              UNION
              SELECT parcelle_id FROM gestcons.animation_contrat_agricole_parcelles
            )
            SELECT DISTINCT p.id AS parcelle_id
            FROM gestcons.parcelles_base p
            JOIN any_anim aa ON aa.parcelle_id = p.id
            WHERE p.site_id = {sid}
          ")
      flagged <- safe_db_query(con, q)
      
      if (!nrow(flagged)) {
        sf_par$has_animation <- FALSE
        return(sf_par)
      }
      
      sf_par$has_animation <- sf_par$parcelle_id %in% flagged$parcelle_id
      sf_par
    })
    
    # --- Helper : Vérifie si la parcelle 'code_new' a au moins un contrat commun avec 'codes_existing'
    # Lignes 383 (mod_animations.R)
    # --- Helper : Vérifie si la parcelle 'code_new' a le contrat specifique, 
    # --- ou si elle partage un contrat avec les existantes (si aucun specifique)
    .af_has_common_contrat <- function(code_new, codes_existing, contrat_specifique_mix = NULL) { # 💡 MODIFICATION DE LA SIGNATURE
      df_contrats <- af_parcelle_contrats_rv(); req(df_contrats)
      
      # 1. IDs des contrats de la nouvelle parcelle
      new_row <- df_contrats[df_contrats$code == code_new, ]
      if (nrow(new_row) == 0) return(FALSE)

      # Parcelle du PÉRIMÈTRE élargi : pas de contrat requis (animation
      # pré-acquisition — c'est précisément son objet).
      if (isTRUE(new_row$perimetre[1])) return(TRUE)

      new_f_ids <- new_row$contrats_foncier[[1]]
      new_a_ids <- new_row$contrats_agricole[[1]]
      
      # 2. CAS CONTRAT SPÉCIFIQUE (Étape 2 de la création ou Édition d'action existante)
      if (!is.null(contrat_specifique_mix) && nzchar(contrat_specifique_mix)) {
        kind      <- sub(":.+$", "", contrat_specifique_mix)
        contrat_id <- as.integer(sub("^.?:", "", contrat_specifique_mix))
        req(!is.na(contrat_id))
        
        # Validation : la parcelle doit posséder ce contrat
        if (kind == "F") {
          return(contrat_id %in% new_f_ids)
        } else if (kind == "A") {
          return(contrat_id %in% new_a_ids)
        }
        return(FALSE) # Cas non géré (ex: contrat vide mais specifique non-NULL)
      }
      
      return(length(new_f_ids) > 0 || length(new_a_ids) > 0)
      
    }
    
    # Quand des contrats changent ailleurs, rafraîchir la/les cartes AF
    observeEvent(contrats_update_trigger(), {
      # Si tu as une fonction qui redraw les couches AF pour le site courant, appelle-la ici.
      # A minima, invalide les cartes pour forcer les proxies à se remettre à jour.
      session$sendCustomMessage("invalidate-map", list(id = ns("af_map")))
      session$sendCustomMessage("invalidate-map", list(id = ns("af_new_map")))
    }, ignoreInit = TRUE)
    
    observeEvent(input$af_map_shape_click, {
      debug_print("============observeEvent(input$af_map_shape_click")
      cl <- input$af_map_shape_click
      req(!is.null(cl$id) && nzchar(cl$id))
      
      # 1) Clic sur un cercle "Sites existants" => sélectionne le site
      if (identical(cl$group, "Sites existants")) {
        debug_print("=========clearGroup(Sites existants)")
        sid <- suppressWarnings(as.integer(sub("^site_", "", as.character(cl$id))))
        req(!is.na(sid))
        
        # Sélectionne le site comme si on l'avait choisi dans le selecteur
        updateSelectizeInput(session, "af_site_selector", selected = sid)
        af_site_id(sid)
        
        # Efface immédiatement la couche de cercles
        leaflet::leafletProxy(ns("af_map"), session = session) %>%
          leaflet::clearGroup("Sites existants")
        
        return(invisible())
      }
      
      req(cl$group == AF_GROUP)
      
      pid <- suppressWarnings(as.integer(sub("^afp-", "", cl$id)))
      req(!is.na(pid))

      # Récup info lisible pour le titre (code/commune)
      sfall <- af_parcelles_avec_flag()
      row <- tryCatch(sfall[sfall$parcelle_id == pid, , drop = FALSE], error = function(e) NULL)
      code <- if (!is.null(row) && nrow(row)) row$code[1] else "—"
      commune <- if (!is.null(row) && nrow(row)) row$commune[1] else NA
      titre <- sprintf("📋 Actions liées à la parcelle %s%s",
                       code %||% "—",
                       if (!is.na(commune) && nzchar(commune)) paste0(" — ", commune) else "")
      af_parcelle_title(titre)
      
      # Le tableau sous la carte se restreint aux actions de cette parcelle
      # (au lieu d'ouvrir une modale : le tableau montre les mêmes colonnes
      # que la liste et reste sous les yeux). Recliquer la même parcelle rend
      # la main à l'emprise.
      af_map_selected(character(0))   # les cases cochées portaient sur un autre filtrage
                                      # (la réciproque est dans l'observer af_map_sel)
      af_focus_parcelle(if (identical(af_focus_parcelle(), pid)) NULL else pid)
    })
    
    # Convertit les codes des parcelles en ids gestcons.parcelles.id (site donné)
    .af_codes_to_parcelle_ids <- function(site_id, codes) {
      if (length(codes) == 0) return(integer(0))
      codes_cad <- codes[!grepl("^M-", codes)]
      mids      <- as.integer(sub("^M-", "", codes[grepl("^M-", codes)]))
      where_cad <- if (length(codes_cad)) paste0("AND c.idpar = ANY(ARRAY[", paste(dbQuoteLiteral(con, codes_cad), collapse=","), "])") else "AND FALSE"
      where_man <- if (length(mids))      paste0("AND ppm.id = ANY(ARRAY[", paste(mids, collapse=","), "])") else "AND FALSE"
      
      q <- glue::glue("
            WITH from_cad AS (
              -- parcelles_base : couvre les parcelles du site ET de la continuité du site conservatoire
              SELECT p.id
              FROM gestcons.parcelles_base p
              JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 1 {where_cad}
            ),
            from_man AS (
              SELECT p.id
              FROM gestcons.parcelles_base p
              JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 2 {where_man}
            )
            SELECT id FROM from_cad
            UNION ALL
            SELECT id FROM from_man
          ")
      df <- safe_db_query(con, q)
      if (!nrow(df)) integer(0) else as.integer(df$id)
    }
    
    
    # --- Utilitaire: convertit la feature Leaflet-Draw (rectangle) en sfc 4326
    .Polygones_to_sfc <- function(feat) {
      if (is.null(feat) || is.null(feat$geometry) || is.null(feat$geometry$coordinates)) return(NULL)
      # coords = liste de [lng, lat]
      coords <- feat$geometry$coordinates[[1]]
      if (length(coords) < 4) return(NULL)
      mat <- do.call(rbind, lapply(coords, function(pt) c(as.numeric(pt[[1]]), as.numeric(pt[[2]]))))
      sf::st_sfc(sf::st_polygon(list(mat)), crs = 4326)
    }
    
    # --- Utilisateurs: choices pour selectize (uniquement via la DB)
    .af_fetch_utilisateurs_choices <- function() {
      df <- safe_db_query(con, "
            SELECT id, trim(coalesce(nullif(prenom,''),'') || ' ' || coalesce(nullif(nom,''),'')) AS label
            FROM gestcons.dico_utilisateur
            WHERE actif = TRUE
            ORDER BY nom, prenom
          ")
      
      if (nrow(df) > 0) setNames(df$id, df$label) else c()
    }
    
    # Sélection du site
    observeEvent(input$af_site_selector, {
      if (input$af_site_selector == "") {
        selected_site_rv(NULL)
      } else {
        val <- suppressWarnings(as.integer(input$af_site_selector))
        if (!is.na(val)) selected_site_rv(val)
      }
      sel <- input$af_site_selector
      if (!is.null(sel) && nzchar(sel)) {
        # Met à jour l'id (si ce n'est pas déjà fait ailleurs)
        af_site_id(as.integer(sel))
        
        # Efface la couche de cercles
        leaflet::leafletProxy(ns("af_map"), session = session) %>%
          leaflet::clearGroup("Sites existants")
      } else {
        # Si on déselectionne le site => on pourra revoir les cercles (géré par les observers ci-dessus)
      }
    }, ignoreInit = TRUE)
    
    # helper: site sélectionné ?
    .actions_site_is_empty <- function(x) {
      is.null(x) || is.na(x) || identical(x, "") || identical(as.character(x), "")
    }
    
    # 1) Sur changement de l'ID du site sélectionné
    observeEvent(af_site_id(), {
      hide <- .actions_site_is_empty(af_site_id())
      session$sendCustomMessage('toggle-layer-overlays', list(id = ns('af_map'), hide = hide))
    }, ignoreInit = FALSE)
    
    # 2) Sur changement via le selectize (au cas où)
    observeEvent(input$af_site_selector, {
      hide <- .actions_site_is_empty(input$af_site_selector)
      session$sendCustomMessage('toggle-layer-overlays', list(id = ns('af_map'), hide = hide))
    }, ignoreInit = FALSE)
    
    # Bouton Réinitialiser (ACTION)
    observeEvent(input$af_reset_site, {
      debug_print("observeEvent(input$af_reset_site) -> Appel global de reset")
      # 💡 Changement CLES : Définit le réactif partagé à NULL.
      selected_site_rv(NULL)
    })
    
    
    
    # --- Table des animations du site sélectionné
    af_refresh <- function(site_id) {
      sql <- glue::glue("
    WITH 
    acteurs_fonciers AS (
      SELECT afa.animation_id,
             string_agg(
               trim(coalesce(nullif(a.prenom,''),'') || ' ' || coalesce(nullif(a.nom,''),'')),
               ', ' ORDER BY a.nom, a.prenom
             ) AS acteurs
      FROM gestcons.animation_fonciere_acteurs afa
      JOIN gestcons.dico_acteurs_fonciers_agricoles a ON a.id = afa.acteur_id
      GROUP BY afa.animation_id
    ),
    acteurs_agricoles AS (
      SELECT acaa.animation_id,
             string_agg(
               trim(coalesce(nullif(a.prenom,''),'') || ' ' || coalesce(nullif(a.nom,''),'')),
               ', ' ORDER BY a.nom, a.prenom
             ) AS acteurs
      FROM gestcons.animation_contrat_agricole_acteurs acaa
      JOIN gestcons.dico_acteurs_fonciers_agricoles a ON a.id = acaa.acteur_id
      GROUP BY acaa.animation_id
    ),
    utilisateurs AS (
      SELECT
        afu.animation_id,
        string_agg(
          COALESCE(
            NULLIF(trim(concat_ws(' ', NULLIF(u.prenom,''), NULLIF(u.nom,''))), ''),
            NULLIF(u.email,''),
            'Utilisateur #'||u.id::text
          ),
          ', ' ORDER BY u.nom, u.prenom, u.email
        ) AS utilisateurs
      FROM gestcons.animation_fonciere_utilisateur afu
      JOIN gestcons.dico_utilisateur u ON u.id = afu.utilisateur_id
      GROUP BY afu.animation_id
    ),
    docs_f AS (
      SELECT animation_id, COUNT(*) AS nb_docs
      FROM gestcons.docs_animation_fonciere
      GROUP BY animation_id
    ),
    docs_a AS (
      SELECT animation_id, COUNT(*) AS nb_docs
      FROM gestcons.docs_animation_agricole
      GROUP BY animation_id
    )

    SELECT * FROM (
      -- Bloc FONCIER
      SELECT
        af.id,
        'Foncier'::text AS domaine,
        '—'::text AS contrat,
        dtaa.libelle AS type_action,
        af.date,
        -- 💡 JOINTURE ACTEURS FONCIERS
        COALESCE(acteurs_fonciers.acteurs, '—') AS acteurs,
        COALESCE(utilisateurs.utilisateurs, '—') AS utilisateurs,
        af.description,
        af.cree_par,
        af.date_creation,
        af.modifie_par,
        af.date_modification,
        COALESCE(docs_f.nb_docs, 0)::int AS nb_docs
      FROM gestcons.animation_fonciere af
      LEFT JOIN gestcons.dico_type_action_animation dtaa ON dtaa.id = af.type_action_id
      LEFT JOIN acteurs_fonciers ON acteurs_fonciers.animation_id = af.id
      LEFT JOIN utilisateurs ON utilisateurs.animation_id = af.id
      LEFT JOIN docs_f ON docs_f.animation_id = af.id
      WHERE EXISTS (
        SELECT 1
        FROM gestcons.animation_fonciere_parcelles afp
        JOIN gestcons.parcelles_base p ON p.id = afp.parcelle_id
        WHERE afp.animation_id = af.id
          AND p.site_id = {site_id}
      )

      UNION ALL

      -- Bloc AGRICOLE
      SELECT
        ag.id,
        'Agricole'::text AS domaine,
        '—'::text AS contrat,
        dtaa.libelle AS type_action,
        ag.date,
        -- 💡 JOINTURE ACTEURS AGRICOLES
        COALESCE(acteurs_agricoles.acteurs, '—') AS acteurs,
        '—'::text AS utilisateurs, -- Pas de table utilisateurs dédiée pour l'agricole
        ag.description,
        ag.cree_par,
        ag.date_creation,
        ag.modifie_par,
        ag.date_modification,
        COALESCE(docs_a.nb_docs, 0)::int AS nb_docs
      FROM gestcons.animation_contrat_agricole ag
      LEFT JOIN gestcons.dico_type_action_animation dtaa ON dtaa.id = ag.type_action_id
      LEFT JOIN acteurs_agricoles ON acteurs_agricoles.animation_id = ag.id
      LEFT JOIN docs_a ON docs_a.animation_id = ag.id
      WHERE EXISTS (
        SELECT 1
        FROM gestcons.animation_contrat_agricole_parcelles ap
        JOIN gestcons.parcelles_base p ON p.id = ap.parcelle_id
        WHERE ap.animation_id = ag.id
          AND p.site_id = {site_id}
      )
    ) t
    ORDER BY date DESC NULLS LAST, id DESC
  ")
      
      df <- safe_db_query(con, sql)
      
      # ... (Le reste de la fonction af_refresh pour le renommage et les liens reste inchangé)
      
      # colonnes finales & libellés (ajout de 'domaine')
      # Colonnes d'action en tête de ligne : œil pour tous, crayon uniquement
      # pour les utilisateurs habilités sur le site courant.
      peut_editer <- isTRUE(is_editor_on_site_rv())
      final_order <- c("Voir_fiche",
                       if (peut_editer) "Modifier",
                       "id","domaine","date","type_action","acteurs","utilisateurs",
                       "description","contrat","Voir_carte","📎")
      rename_map <- c(
        Voir_fiche   = "👁",
        Modifier     = "✏️",
        id           = "id",
        domaine      = "Domaine",
        date         = "Date",
        type_action  = "Type d'action",
        acteurs      = "Acteurs",
        utilisateurs = "Utilisateurs",
        description  = "Description",
        contrat      = "Contrat",
        Voir_carte   = "🗺️ Carte",
        "📎"         = "Pièces jointes"
      )
      
      n <- nrow(df)
      
      # Liens (uniquement pour les actions FONCIÈRES qui ont les handlers existants)
      if (n > 0) {
        pref <- ifelse(df$domaine == "Agricole", "A", "F")
        df$Voir_carte <- sprintf('<a href="#" class="af-show tc-act" data-input="%s" data-id="%s:%s" title="Voir sur la carte">🗺️</a>', ns("af_show"), pref, df$id)
        df$Voir_fiche <- sprintf('<a href="#" class="af-view tc-act" data-input="%s" data-mode="view" data-id="%s:%s" title="Voir la fiche complète">👁</a>', ns("af_row_click"), pref, df$id)
        df$Modifier   <- sprintf('<a href="#" class="af-edit tc-act" data-input="%s" data-id="%s:%s" title="Modifier cette action">✏️</a>', ns("af_row_click"), pref, df$id)
        
        # Compteur simple (la gestion des PJ se fait dans la modale de l'action)
        df$`📎` <- sprintf('📎 %s', ifelse(is.na(df$nb_docs), 0, df$nb_docs))
        
        # Clé unique sûre (au cas improbable où les IDs coïncident entre tables)
        df$.key <- paste0(df$domaine, ":", df$id)
        df <- df[!duplicated(df$.key), , drop = FALSE]
        df$.key <- NULL
      }
      
      # S’assurer que toutes les colonnes finales existent
      for (col in final_order) {
        if (!col %in% names(df)) {
          df[[col]] <- if (n > 0) rep("", n) else character(0)
        }
      }
      
      # Sous-ensemble et ordre final
      df <- df[, final_order, drop = FALSE]
      
      # Renommage (appliqué même si df est vide)
      names(df) <- unname(rename_map[names(df)])
      
      df
    }
    
    
    # Handler de téléchargement pour le PDF
    output$af_download_pdf <- downloadHandler(
      filename = function() {
        sprintf("rapport-animation-%s-%s.pdf",
                as.integer(af_edit_id() %||% 0),
                format(Sys.Date(), "%Y-%m-%d"))
      },
      contentType = "application/pdf",
      content = function(file) {
        shinybusy::show_modal_spinner(text = "Génération du PDF en cours...")
        on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
        on.exit({ af_table_reload(isolate(af_table_reload()) + 1) }, add = TRUE)
        
        anim_id <- af_edit_id(); req(anim_id)
        
        ## --- Données ---
        anim_data <- safe_db_query(con, glue::glue("
              SELECT af.id, af.date, af.description, dtaa.libelle AS type_action
              FROM gestcons.animation_fonciere af
              LEFT JOIN gestcons.dico_type_action_animation dtaa ON dtaa.id = af.type_action_id
              WHERE af.id = {anim_id}
            "))
        
        acteurs <- safe_db_query(con, glue::glue("
              SELECT trim(coalesce(nullif(a.prenom,''),'') || ' ' || coalesce(nullif(a.nom,''),'')) AS acteur
              FROM gestcons.animation_fonciere_acteurs afa
              JOIN gestcons.dico_acteurs_fonciers_agricoles a ON a.id = afa.acteur_id
              WHERE afa.animation_id = {anim_id}
              ORDER BY a.nom
            "))
        
        utilisateurs <- safe_db_query(con, glue::glue("
              SELECT COALESCE(
                NULLIF(trim(concat_ws(' ', NULLIF(u.prenom,''), NULLIF(u.nom,''))), ''),
                NULLIF(u.email,''),
                'Utilisateur #'||u.id::text
              ) AS utilisateur
              FROM gestcons.animation_fonciere_utilisateur afu
              JOIN gestcons.dico_utilisateur u ON u.id = afu.utilisateur_id
              WHERE afu.animation_id = {anim_id}
              ORDER BY u.nom, u.prenom, u.email
            "))
        
        parcelles_df <- safe_db_query(con, glue::glue("
              WITH parcelles_site AS (
                SELECT p.id AS parcelle_id,
                       CASE p.type_parcelle_id
                         WHEN 1 THEN c.idpar::text
                         WHEN 2 THEN ('M-' || ppm.id)::text
                       END AS code,
                       CASE p.type_parcelle_id
                         WHEN 1 THEN COALESCE(string_agg(DISTINCT dp.ddenom, ', '), '')
                         ELSE NULL::text
                       END AS proprietaires,
                       CASE p.type_parcelle_id
                         WHEN 1 THEN c.idcomtxt::text
                         ELSE NULL::text
                       END AS commune,
                       CASE p.type_parcelle_id
                         WHEN 1 THEN ST_Area(ST_Transform(c.geompar, 2154))::numeric
                         WHEN 2 THEN ST_Area(ST_Transform(ppm.geometrie, 2154))::numeric
                       END AS surface_m2,
                       NULL::text AS contrats
                FROM gestcons.parcelles_base p
                JOIN gestcons.animation_fonciere_parcelles afp ON afp.parcelle_id = p.id
                LEFT JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id AND p.type_parcelle_id = 1
                LEFT JOIN gestcons.dico_proprietaire dp ON c.id IS NOT NULL AND dp.idprocpte = c.idprocpte
                LEFT JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id AND p.type_parcelle_id = 2
                WHERE afp.animation_id = {anim_id}
                GROUP BY p.id, c.idpar, ppm.id, c.idcomtxt, c.geompar, ppm.geometrie
              )
              SELECT * FROM parcelles_site
            "))
        
        ## --- Titre dynamique "CR d'animation pour le site <site>" ---
        site_label <- {
          sid <- tryCatch(af_site_id(), error = function(e) NA)
          lbl <- NA_character_
          if (!is.null(sid) && !is.na(sid)) {
            res <- safe_db_query(con, glue::glue("
                  SELECT libelle FROM gestcons.sites WHERE id = {sid} LIMIT 1
                "))
            if (nrow(res)) lbl <- res$libelle[1]
          }
          # Fallback : déduire via les parcelles liées à l'animation
          if (!nzchar(lbl)) {
            res2 <- safe_db_query(con, glue::glue("
                  SELECT DISTINCT s.libelle
                  FROM gestcons.parcelles_base p
                  JOIN gestcons.animation_fonciere_parcelles afp ON afp.parcelle_id = p.id
                  JOIN gestcons.sites s ON s.id = p.site_id
                  WHERE afp.animation_id = {anim_id}
                  LIMIT 1
                "))
            if (nrow(res2)) lbl <- res2$libelle[1]
          }
          if (!nzchar(lbl)) "—" else lbl
        }
        
        titre_doc <- sprintf("CR d'action pour le site %s", site_label)
        
        ## --- Chemins & template ---
        template_file <- normalizePath(file.path(getwd(), "www", "rapport_action.Rmd"), mustWork = TRUE)
        tmpl_dir  <- dirname(template_file)
        logo_abs  <- normalizePath(file.path(tmpl_dir, "logo_cen.png"), mustWork = TRUE)
        footer_img_path <- normalizePath(file.path(tmpl_dir, "bas_de_page.png"),
                                         winslash = "/", mustWork = FALSE)
        # Dossier temporaire isolé
        # Dossier temporaire isolé
        tmp_dir <- tempfile("rapport_")
        dir.create(tmp_dir, recursive = TRUE, showWarnings = FALSE)
        
        # Dossier debug persistant (créé AVANT render)
        debug_dir <- file.path(docs_root, "_debug_rapports")
        if (!dir.exists(debug_dir)) {
          ok <- dir.create(debug_dir, recursive = TRUE, showWarnings = FALSE)
          if (!ok) {
            debug_dir <- file.path(tempdir(), "rapport_debug")
            dir.create(debug_dir, recursive = TRUE, showWarnings = FALSE)
          }
        }
        
        pdf_out <- file.path(tmp_dir, "rapport_action.pdf")
        
        # --- rendu LaTeX 
        res <- tryCatch({
          rmarkdown::render(
            input             = template_file,
            output_format     = rmarkdown::pdf_document(
              latex_engine    = "xelatex",
              number_sections = FALSE,
              keep_tex        = TRUE
            ),
            output_file       = basename(pdf_out),
            output_dir        = tmp_dir,
            intermediates_dir = tmp_dir,
            knit_root_dir     = tmpl_dir,
            params            = list(
              titre        = titre_doc,
              footer_left  = "ANA-CEN Ariège",
              footer_right = "Confidentiel – Diffusion restreinte",
              logo         = logo_abs,
              footer_img   = footer_img_path,
              anim_data    = anim_data,
              acteurs      = acteurs,
              utilisateurs = utilisateurs,
              parcelles    = parcelles_df
            ),
            clean = FALSE,
            quiet = FALSE
          )
        }, error = function(e) {
          message("render() ERROR: ", conditionMessage(e))
          e
        }, finally = {
          # copie .log/.tex vers debug_dir (même en cas d’échec)
          logs_tex <- list.files(tmp_dir, pattern = "\\.(log|tex)$", full.names = TRUE)
          if (length(logs_tex)) file.copy(logs_tex, debug_dir, overwrite = TRUE)
          message("Fichiers debug copiés vers: ", normalizePath(debug_dir, winslash = "/", mustWork = FALSE))
        })
        
        # Si ça a planté : stop (Shiny affichera l’erreur)
        if (inherits(res, "error")) stop(res)
        
        # Vérif et copie du PDF final
        if (!file.exists(pdf_out) || isTRUE(file.info(pdf_out)$size <= 0)) {
          stop("PDF non généré.")
        }
        if (!file.copy(pdf_out, file, overwrite = TRUE)) {
          stop("Impossible d'écrire le PDF dans le flux de téléchargement.")
        }
        
      }
    )
    
    # ✅ NOUVEAU : l'id correspond à l'UI (af_map)
    output$af_map <- renderLeaflet({
      # This part of the code is executed only once at the beginning
      # The actual rendering and redrawing will happen in an observer.
      init_map_base(
        options = leafletOptions(boxZoom = FALSE, zoomControl = TRUE),
        zoom = 9
      ) %>%
        addScaleBar(position = "bottomleft") %>%
        addLayersControl(
          baseGroups = c("OpenStreetMap", "IGN Cartes", "IGN Satellites"),
          # AF_GROUP n'est volontairement PAS listé : c'est la raison d'être de
          # cet onglet, pouvoir l'éteindre ne laisserait qu'une carte vide.
          # Absente du contrôle, la couche reste affichée en permanence — rien
          # ne l'appelle en hideGroup. Même parti pris que « Parcelle
          # sélectionnée » dans Stratégie foncière et dans Sites.
          options = layersControlOptions(collapsed = FALSE)
        ) %>%
        showGroup("OpenStreetMap")  # <-- Affiche une couche par défaut
    })
    
    # (la carte survit au passage sur un autre onglet sans se recalculer)
    outputOptions(output, "af_map", suspendWhenHidden = FALSE)
    
    
    # --- [AJOUT SERVER] Dessin des parcelles colorées selon 'has_animation'
    # --- [REMPLACER ICI] Dessin des parcelles colorées selon 'has_animation'
    observeEvent(
      af_parcelles_avec_flag(),
      ignoreInit = TRUE,
      {
        sf_par <- af_parcelles_avec_flag()
        m <- leaflet::leafletProxy(mapId = ns("af_map"), session = session)
        
        if (is.null(sf_par) || nrow(sf_par) == 0) {
          m %>% leaflet::clearGroup(AF_GROUP)
          return(invisible(NULL))
        }
        
        # Nettoyage du groupe local (infobulles fermées d'abord : un path
        # recréé ne reçoit jamais le mouseout -> infobulle orpheline)
        close_map_tooltips(ns("af_map"), session)
        m %>% leaflet::clearGroup(AF_GROUP)
        
        # Split avec/sans animation, puis site/périmètre dans chaque catégorie :
        # les parcelles de continuité sont HACHURÉES (classe pp-hachures) et le
        # signal avec/sans animation est reporté sur leur BORDURE (le motif
        # remplace le remplissage).
        sf_ok  <- sf_par[sf_par$has_animation %in% TRUE, ]
        sf_nok <- sf_par[!(sf_par$has_animation %in% TRUE), ]
        
        pal_ok  <- "#ff7f00"
        pal_nok <- "#3b82f6"

        nok_std  <- sf_nok[!(sf_nok$perimetre %in% TRUE), ]
        nok_peri <- sf_nok[sf_nok$perimetre %in% TRUE, ]
        ok_std   <- sf_ok[!(sf_ok$perimetre %in% TRUE), ]
        ok_peri  <- sf_ok[sf_ok$perimetre %in% TRUE, ]

        # ... à l’identique, et ajoute juste layerId = ~paste0("parc-", parcelle_id)
        # Parcelles SANS animation → survol OK, pas de clic (pas de layerId)
        if (nrow(nok_std) > 0) {
          m %>% leaflet::addPolygons(
            data = nok_std,
            group = AF_GROUP,
            weight = 1, color = "#00000066",
            fillColor = pal_nok, fillOpacity = 0.35,
            label = .cf_make_labels(nok_std, user_roles()),
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE)
            # ⛔️ pas de layerId ici → aucun clic ne sera capté
          )
        }
        if (nrow(nok_peri) > 0) {
          m %>% leaflet::addPolygons(
            data = nok_peri,
            group = AF_GROUP,
            weight = 1.5, color = pal_nok,
            fillColor = "#f97316", fillOpacity = 0.2,  # repli si JS indisponible
            label = .cf_make_labels(nok_peri, user_roles()),
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
            options = leaflet::pathOptions(className = "pp-hachures")
          )
        }
        
        # Parcelles AVEC animation → cliquables (layerId présent)
        if (nrow(ok_std) > 0) {
          m %>% leaflet::addPolygons(
            data = ok_std,
            group = AF_GROUP,
            weight = 1.5, color = "#00000099",
            fillColor = pal_ok, fillOpacity = 0.55,
            label = .cf_make_labels(ok_std, user_roles()),
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("afp-", parcelle_id)  # ✅ clics autorisés uniquement pour celles-ci
          )
        }
        if (nrow(ok_peri) > 0) {
          m %>% leaflet::addPolygons(
            data = ok_peri,
            group = AF_GROUP,
            weight = 2, color = pal_ok,
            fillColor = "#f97316", fillOpacity = 0.2,  # repli si JS indisponible
            label = .cf_make_labels(ok_peri, user_roles()),
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("afp-", parcelle_id),
            options = leaflet::pathOptions(className = "pp-hachures")
          )
        }
        if (nrow(nok_peri) > 0 || nrow(ok_peri) > 0) {
          session$sendCustomMessage("tc-hatch", list(id = ns("af_map")))
        }
        
        
        
        bb <- try(sf::st_bbox(sf_par), silent = TRUE)
        if (!inherits(bb, "try-error")) {
          bbox_site_rv(bb)  # ✅ mémorise l’emprise pour focus_site()
          leaflet::fitBounds(
            map = m,
            lng1 = as.numeric(bb["xmin"]), lat1 = as.numeric(bb["ymin"]),
            lng2 = as.numeric(bb["xmax"]), lat2 = as.numeric(bb["ymax"])
          )
        }
        
        m %>% leaflet::showGroup(AF_GROUP)
      }
    )
    
    output$resume_site_af <- renderUI({
      req(af_site_id())
      # Canal commun : suit les écritures de parcelles des autres onglets.
      if (!is.null(contrats_update_trigger)) contrats_update_trigger()
      ui <- tryCatch(
        build_resume_site_ui(con, af_site_id()),
        error = function(e) div(class = "text-muted", paste("Résuméee indisponible :", conditionMessage(e)))
      )
      ui
    })
    
    # Lignes des actions du site, avant filtrage par l'emprise ou par la
    # parcelle cliquée.
    af_rows_site <- reactive({
      af_table_reload()
      sid <- af_site_id()
      if (is.null(sid)) return(NULL)
      af_refresh(sid)
    })

    # Rendu du tableau des actions, séparé de la préparation des lignes.
    # `empty_msg` remplace le « No data available » de DT quand la sélection
    # est vide sans que ce soit une anomalie.
    .af_actions_datatable <- function(df, empty_msg = NULL,
                                      sel_input = NULL, sel_keys = character(0)) {
      if (is.null(df)) df <- data.frame()

      # Retire "Description" si présent
      drop_cols <- intersect(names(df), c("description", "Description"))
      if (length(drop_cols)) df <- df[, setdiff(names(df), drop_cols), drop = FALSE]
      
      # Colonne de sélection (tableau sous la carte uniquement). L'état coché
      # est relu à chaque rendu depuis la sélection courante : le tableau est
      # reconstruit à chaque déplacement de la carte, les cases doivent y
      # survivre.
      if (!is.null(sel_input) && nrow(df) > 0) {
        keys <- paste0(df$Domaine, ":", df$id)
        df <- data.frame(
          `☑` = sprintf(
            paste0('<input type="checkbox" class="tc-check" data-input="%s" data-key="%s"%s ',
                   'title="Mettre en évidence les parcelles de cette action">'),
            sel_input, keys, ifelse(keys %in% sel_keys, " checked", "")),
          df,
          check.names = FALSE, stringsAsFactors = FALSE
        )
      }
      
      if (nrow(df) == 0) {
        opts <- list(pageLength = 10, dom = "tip")
        if (!is.null(empty_msg)) opts$language <- list(emptyTable = empty_msg)
        return(DT::datatable(
          df, escape = FALSE, rownames = FALSE,
          options = opts
        ))
      }
      
      # Actions explicites en tête de ligne (👁 / ✏️) : le clic sur la ligne ne
      # déclenche plus rien.
      map_idx  <- which(names(df) == "🗺️ Carte") - 1L
      id_idx0  <- which(names(df) == "id") - 1L
      act_idx  <- which(names(df) %in% c("👁", "✏️")) - 1L

      coldefs <- list()
      if (length(map_idx)) coldefs <- c(coldefs, list(
        list(targets = map_idx, orderable = FALSE, searchable = FALSE)))
      if (length(act_idx)) coldefs <- c(coldefs, list(
        list(targets = act_idx, orderable = FALSE, searchable = FALSE,
             className = "dt-center", width = "24px")))
      if (length(id_idx0)) coldefs <- c(coldefs, list(list(targets = id_idx0, visible = FALSE)))
      # Colonne des cases : largeur imposée par la classe (app.css) — sans
      # autoWidth, DataTables ignore le `width` des columnDefs.
      chk_idx <- which(names(df) == "☑") - 1L
      if (length(chk_idx)) coldefs <- c(coldefs, list(
        list(targets = chk_idx, orderable = FALSE, searchable = FALSE,
             className = "dt-center tc-check-col")))

      DT::datatable(
        df,
        escape = FALSE, rownames = FALSE, selection = "none",
        filter = "top",
        options = list(
          pageLength = 10,
          # « tip » et non « ftip » : pas de boîte de recherche globale, les
          # filtres par colonne (filter = "top") suffisent.
          dom = "tip",
          autoWidth = FALSE,
          scrollX = FALSE,
          orderCellsTop = TRUE,
          columnDefs = coldefs
        )
      )
    }

    # --- Tableau sous la carte : actions des parcelles visibles -------------
    # L'emprise change à chaque déplacement et à chaque zoom : on la débounce
    # comme le zoom (500 ms), sinon un simple pan déclencherait une rafale de
    # recalculs.
    af_map_bounds_debounced <- shiny::debounce(reactive(input$af_map_bounds), 500)

    # Liens action -> parcelle pour le site courant, les deux domaines.
    # `parcelles_base` et non la vue `parcelles` : les parcelles de la zone
    # d'intérêt portent des actions elles aussi.
    af_anim_parcelle_links <- reactive({
      af_table_reload()
      sid <- af_site_id()
      if (is.null(sid)) return(NULL)
      safe_db_query(con, glue::glue("
            SELECT 'Foncier'::text AS domaine, afp.animation_id AS id, afp.parcelle_id
            FROM gestcons.animation_fonciere_parcelles afp
            JOIN gestcons.parcelles_base p ON p.id = afp.parcelle_id
            WHERE p.site_id = {sid}
            UNION ALL
            SELECT 'Agricole'::text AS domaine, ap.animation_id AS id, ap.parcelle_id
            FROM gestcons.animation_contrat_agricole_parcelles ap
            JOIN gestcons.parcelles_base p ON p.id = ap.parcelle_id
            WHERE p.site_id = {sid}
          "))
    })

    # Parcelles du site dont la géométrie touche l'emprise affichée. Le calcul
    # porte sur les géométries DÉJÀ chargées pour le dessin : aucune requête
    # supplémentaire au fil des déplacements.
    af_visible_parcelle_ids <- reactive({
      b      <- af_map_bounds_debounced()
      sf_par <- af_parcelles_avec_flag()
      if (is.null(b) || is.null(sf_par) || nrow(sf_par) == 0) return(integer(0))
      
      # as.numeric() : st_bbox exige des valeurs NON nommées, sinon les noms
      # xmin/ymin/… ne sont plus reconnus et la bbox part en NA.
      box <- sf::st_as_sfc(sf::st_bbox(
        c(xmin = as.numeric(b$west),  ymin = as.numeric(b$south),
          xmax = as.numeric(b$east),  ymax = as.numeric(b$north)),
        crs = sf::st_crs(sf_par)
      ))
      hit <- tryCatch(
        lengths(sf::st_intersects(sf::st_geometry(sf_par), box)) > 0,
        error = function(e) rep(FALSE, nrow(sf_par))
      )
      as.integer(sf_par$parcelle_id[hit])
    })

    af_map_rows <- reactive({
      df <- af_rows_site()
      if (is.null(df) || nrow(df) == 0) return(df)
      
      # Une parcelle cliquée sur la carte prime sur l'emprise : le tableau reste
      # sur ses actions même si un déplacement la sort de l'écran, sans quoi il
      # se viderait sous les yeux de qui vient de la choisir.
      pid   <- af_focus_parcelle()
      ids   <- if (!is.null(pid)) pid else af_visible_parcelle_ids()
      liens <- af_anim_parcelle_links()
      if (length(ids) == 0 || is.null(liens) || nrow(liens) == 0) {
        return(df[0, , drop = FALSE])
      }
      
      # Une action peut porter sur plusieurs parcelles : elle est retenue dès
      # que l'une d'elles est visible. La clé domaine:id lève l'ambiguïté entre
      # les deux tables d'animations, qui numérotent chacune de leur côté.
      vus <- unique(paste0(liens$domaine, ":", liens$id)[liens$parcelle_id %in% ids])
      df[paste0(df$Domaine, ":", df$id) %in% vus, , drop = FALSE]
    })

    # --- Sélection d'actions dans le tableau sous la carte ------------------
    # Clés « Domaine:id », tenues côté serveur : le tableau est reconstruit à
    # chaque déplacement de la carte, et DT ne garde dans le DOM que la page
    # affichée. Une action cochée le reste même si elle sort de l'emprise — ses
    # parcelles restent en évidence, et le lien du titre permet de tout
    # décocher sans avoir à la retrouver.
    af_map_selected <- reactiveVal(character(0))

    output$af_map_table_title <- renderUI({
      df   <- af_map_rows()
      n    <- if (is.null(df)) 0L else nrow(df)
      nsel <- length(af_map_selected())
      pid  <- af_focus_parcelle()
      tagList(
        if (!is.null(pid)) {
          tagList(
            h4(HTML(sprintf("%s <span style='color:var(--c-accent);'>(%d)</span>",
                            htmltools::htmlEscape(af_parcelle_title()), n))),
            div(class = "text-muted", style = "margin-top:-8px; margin-bottom:8px;",
                "Le tableau ne suit plus la carte. ",
                actionLink(ns("af_focus_clear"), "Revenir aux parcelles visibles"))
          )
        } else {
          h4(HTML(sprintf(
            "📋 Actions des parcelles visibles <span style='color:var(--c-accent);'>(%d)</span>", n
          )))
        },
        if (nsel > 0) {
          div(class = "text-muted", style = "margin-top:-8px; margin-bottom:8px;",
              sprintf("%d action(s) cochée(s) — parcelles cerclées de rouge sur la carte. ", nsel),
              actionLink(ns("af_map_sel_clear"), "Tout décocher"))
        }
      )
    })

    output$af_map_table <- DT::renderDT({
      req(af_site_id())
      # isolate() sur la sélection : sans lui, cocher une case redessinerait
      # tout le tableau — page et tri réinitialisés à chaque clic. Le rendu ne
      # suit que l'emprise et les données ; la case, elle, se coche côté
      # navigateur et l'état est relu au prochain rendu.
      .af_actions_datatable(
        af_map_rows(),
        empty_msg = "Aucune action sur les parcelles visibles à l'écran",
        sel_input = session$ns("af_map_sel"),
        sel_keys  = isolate(af_map_selected())
      )
    })

    observeEvent(input$af_map_sel, {
      ev <- input$af_map_sel
      req(!is.null(ev$key))
      cur <- af_map_selected()
      af_map_selected(
        if (isTRUE(ev$checked)) union(cur, ev$key) else setdiff(cur, ev$key)
      )
      # Réciproque du clic sur une parcelle, qui décoche les actions : cocher
      # une action relâche la parcelle et rend le tableau à l'emprise. Les deux
      # filtrages restent exclusifs, quel que soit l'ordre des gestes.
      af_focus_parcelle(NULL)
    })

    observeEvent(input$af_map_sel_clear, { af_map_selected(character(0)) })

    # Retour au filtrage par l'emprise (le clic sur la parcelle elle-même fait
    # aussi la bascule).
    observeEvent(input$af_focus_clear, { af_focus_parcelle(NULL) })

    # Changement de site : sélection et filtre ne veulent plus rien dire.
    observeEvent(af_site_id(), {
      af_map_selected(character(0))
      af_focus_parcelle(NULL)
    }, ignoreNULL = FALSE)

    # Repère de la parcelle qui filtre le tableau. Non interactif, pour que le
    # clic atteigne la parcelle dessous et rebascule vers l'emprise.
    observeEvent(
      list(af_focus_parcelle(), af_parcelles_avec_flag()),
      ignoreInit = TRUE,
      {
        m <- leaflet::leafletProxy(ns("af_map"), session = session)
        m %>% leaflet::clearGroup(AF_FOCUS_GROUP)
        
        pid <- af_focus_parcelle()
        if (is.null(pid)) return(invisible(NULL))
        
        sf_par <- af_parcelles_avec_flag()
        if (is.null(sf_par) || nrow(sf_par) == 0) return(invisible(NULL))
        foc <- sf_par[sf_par$parcelle_id %in% pid, , drop = FALSE]
        if (nrow(foc) == 0) return(invisible(NULL))
        
        m %>%
          leaflet::addPolygons(
            data = foc, group = AF_FOCUS_GROUP,
            fill = FALSE, color = "#7c3aed", weight = 4, dashArray = "8 4",
            options = leaflet::pathOptions(interactive = FALSE)
          ) %>%
          leaflet::showGroup(AF_FOCUS_GROUP)
      }
    )

    # Mise en évidence des parcelles des actions cochées : contour rouge épais
    # et non interactif (mêmes réglages que « Périmètre sélectionné » dans
    # Sites), pour ne masquer ni les infobulles ni les clics des parcelles
    # dessous. Aucune requête : liens et géométries sont déjà en mémoire.
    observeEvent(
      list(af_map_selected(), af_parcelles_avec_flag()),
      ignoreInit = TRUE,
      {
        m <- leaflet::leafletProxy(ns("af_map"), session = session)
        m %>% leaflet::clearGroup(AF_SEL_GROUP)
        
        keys <- af_map_selected()
        if (length(keys) == 0) return(invisible(NULL))
        
        liens  <- af_anim_parcelle_links()
        sf_par <- af_parcelles_avec_flag()
        if (is.null(liens) || nrow(liens) == 0 || is.null(sf_par) || nrow(sf_par) == 0) {
          return(invisible(NULL))
        }
        
        pids <- unique(liens$parcelle_id[paste0(liens$domaine, ":", liens$id) %in% keys])
        sel  <- sf_par[sf_par$parcelle_id %in% pids, , drop = FALSE]
        if (nrow(sel) == 0) return(invisible(NULL))
        
        m %>%
          leaflet::addPolygons(
            data = sel, group = AF_SEL_GROUP,
            fill = FALSE, color = "#dc2626", weight = 4,
            options = leaflet::pathOptions(interactive = FALSE)
          ) %>%
          leaflet::showGroup(AF_SEL_GROUP)
      }
    )
    
    
    # Texte d’aide quand aucun site n’est sélectionné
    output$af_helper_text <- renderUI({
      # Aucun site si NULL ou valeur " " (vide contrôlé)
      # if (is.null(input$af_site_selector) || identical(input$af_site_selector, "")) {
      tags$p(
        class = "text-muted",
        "Ce module vous permet de gérer les actions foncières et agricoles pour les sites conservatoires que vous gérez. ",
        actionLink(ns("af_help"), "En savoir plus...")
      )
      # } else {
      #   NULL
      # }
    })
    
    # Clic sur "En savoir plus..." → ouvre le modal d'aide
    observeEvent(input$af_help, {
      show_help_animation_modal()
    })
    
    
    # --- Fetch parcelles du site (cadastre + périmètres manuels)
    # --- Parcelles du site (cadastre + périmètres manuels) AVEC attributs pour labels
    .af_fetch_site_parcelles <- function(site_id) {
      debug_print("==========================.af_fetch_site_parcelles <- function")
      if (is.null(site_id) || is.na(site_id)) return(NULL)
      
      q <- glue::glue("
            WITH base AS (
              SELECT
                p.id::int                         AS parcelle_id,
                1::int                            AS type_parcelle,
                c.idpar::text                     AS code,
                c.idprocpte                       AS idprocpte,  -- 💡 AJOUT de l'ID propriétaire cadastral
                NULL::int                         AS perimetre_id,
                c.idcomtxt::text                  AS commune,
                ST_Area(ST_Transform(c.geompar, 2154))::numeric AS surface_m2,
                NULL::text                        AS remarque,
                ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom,
                -- [MODIF] Flag de contrat (foncier ou agricole) pour cette parcelle
                EXISTS (
                    SELECT 1 FROM gestcons.contrats_foncier_parcelles cfp WHERE cfp.parcelle_id = p.id
                    UNION ALL
                    SELECT 1 FROM gestcons.contrats_agricoles_parcelles cap WHERE cap.parcelle_id = p.id
                ) AS has_contrat
              FROM gestcons.parcelles p
              JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 1
            ),
            proprietaires AS (
              SELECT
                b.parcelle_id,
                string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires
              FROM base b
              JOIN gestcons.parcelles p ON p.id = b.parcelle_id
              JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
              LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
              GROUP BY b.parcelle_id
            ),
            foncier AS (
              SELECT
                b.parcelle_id,
                NULLIF(string_agg(DISTINCT cf.nom, ', ' ORDER BY cf.nom), '') AS contrats_fonciers
              FROM base b
              LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.parcelle_id = b.parcelle_id
              LEFT JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
              GROUP BY b.parcelle_id
            ),
            agricole AS (
              SELECT
                b.parcelle_id,
                NULLIF(string_agg(DISTINCT ca.nom, ', ' ORDER BY ca.nom), '') AS contrats_agricoles
              FROM base b
              LEFT JOIN gestcons.contrats_agricoles_parcelles cap ON cap.parcelle_id = b.parcelle_id
              LEFT JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
              GROUP BY b.parcelle_id
            ),
            man AS (
              SELECT
                p.id::int                         AS parcelle_id,
                2::int                            AS type_parcelle,
                ('M-'||ppm.id)::text              AS code,
                ppm.id                            AS perimetre_id,
                NULL::text                        AS proprietaires,
                NULL::text                        AS commune,
                ST_Area(ST_Transform(ppm.geometrie, 2154))::numeric AS surface_m2,
                COALESCE(ppm.remarque,'')         AS remarque,
                ST_Transform(ppm.geometrie, 4326) AS geom,
                -- [MODIF] Flag de contrat (foncier ou agricole) pour cette parcelle
                EXISTS (
                    SELECT 1 FROM gestcons.contrats_foncier_parcelles cfp WHERE cfp.parcelle_id = p.id
                    UNION ALL
                    SELECT 1 FROM gestcons.contrats_agricoles_parcelles cap WHERE cap.parcelle_id = p.id
                ) AS has_contrat,
                (
                  SELECT NULLIF(string_agg(DISTINCT cf.nom, ', ' ORDER BY cf.nom), '')
                  FROM gestcons.contrats_foncier_parcelles cfp
                  JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
                  WHERE cfp.parcelle_id = p.id
                ) AS contrats_fonciers,
                (
                  SELECT NULLIF(string_agg(DISTINCT ca.nom, ', ' ORDER BY ca.nom), '')
                  FROM gestcons.contrats_agricoles_parcelles cap
                  JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
                  WHERE cap.parcelle_id = p.id
                ) AS contrats_agricoles
              FROM gestcons.parcelles p
              JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 2
            ),
            peri AS (
              -- Parcelles du PÉRIMÈTRE élargi : sélectionnables pour les actions
              -- (animation pré-acquisition), sans contrat requis.
              SELECT
                pb.id::int                        AS parcelle_id,
                1::int                            AS type_parcelle,
                c.idpar::text                     AS code,
                c.idprocpte                       AS idprocpte,
                NULL::int                         AS perimetre_id,
                c.idcomtxt::text                  AS commune,
                ST_Area(ST_Transform(c.geompar, 2154))::numeric AS surface_m2,
                COALESCE(pb.remarque,'')          AS remarque,
                ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom
              FROM gestcons.parcelles_base pb
              JOIN gestcons.dico_cadastre c ON c.id = pb.parcellaire_id
              WHERE pb.site_id = {site_id} AND pb.perimetre
            ),
            peri_prop AS (
              SELECT
                pe.parcelle_id,
                string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires
              FROM peri pe
              JOIN gestcons.parcelles_base pb ON pb.id = pe.parcelle_id
              JOIN gestcons.dico_cadastre c ON c.id = pb.parcellaire_id
              LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
              GROUP BY pe.parcelle_id
            )
            SELECT
              b.parcelle_id, b.type_parcelle, b.code, b.code AS idpar,  -- idpar pour compat helpers
              b.perimetre_id, COALESCE(pr.proprietaires,'') AS proprietaires,
              b.commune, b.surface_m2, b.remarque, b.geom,
              COALESCE(f.contrats_fonciers,'') AS contrats_fonciers,
              COALESCE(a.contrats_agricoles,'') AS contrats_agricoles,
              b.idprocpte,
              b.has_contrat,
              false AS perimetre
            FROM base b
            LEFT JOIN proprietaires pr USING (parcelle_id)
            LEFT JOIN foncier f       USING (parcelle_id)
            LEFT JOIN agricole a      USING (parcelle_id)
          
            UNION ALL
          
            SELECT
              m.parcelle_id, m.type_parcelle, m.code, m.code AS idpar,
              m.perimetre_id, m.proprietaires, m.commune, m.surface_m2, m.remarque, m.geom,
              m.contrats_fonciers,
              m.contrats_agricoles,
              NULL::text AS idprocpte, -- 💡 AJOUT : NULL pour manuels
              -- [MODIF] AJOUT DE LA COLONNE HAS_CONTRAT
              m.has_contrat,
              false AS perimetre
            FROM man m
          
            UNION ALL
          
            SELECT
              pe.parcelle_id, pe.type_parcelle, pe.code, pe.code AS idpar,
              pe.perimetre_id, COALESCE(pp2.proprietaires,'') AS proprietaires,
              pe.commune, pe.surface_m2, pe.remarque, pe.geom,
              ''::text AS contrats_fonciers,
              ''::text AS contrats_agricoles,
              pe.idprocpte,
              false AS has_contrat,
              true  AS perimetre
            FROM peri pe
            LEFT JOIN peri_prop pp2 USING (parcelle_id)
          ")
      
      log_query(q)
      tryCatch(sf::st_read(con, query = q), error = function(e) NULL)
    }
    
    # --- Helper : Récupère les IDs de contrats pour chaque parcelle du site
    .af_get_parcelle_contrat_ids <- function(site_id) {
      if (is.null(site_id) || is.na(site_id)) return(NULL)
      
      q <- glue::glue("
            WITH foncier AS (
              SELECT
                p.id::int AS parcelle_id,
                string_agg(cf.id::text, ',' ORDER BY cf.id) AS contrat_foncier_ids
              FROM gestcons.parcelles_base p
              JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.parcelle_id = p.id
              JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
              WHERE p.site_id = {site_id}
              GROUP BY p.id
            ),
            agricole AS (
              SELECT
                p.id::int AS parcelle_id,
                string_agg(ca.id::text, ',' ORDER BY ca.id) AS contrat_agricole_ids
              FROM gestcons.parcelles_base p
              JOIN gestcons.contrats_agricoles_parcelles cap ON cap.parcelle_id = p.id
              JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
              WHERE p.site_id = {site_id}
              GROUP BY p.id
            )
            SELECT
              p.id::int AS parcelle_id,
              p.type_parcelle_id,
              COALESCE(c.idpar, 'M-' || ppm.id)::text AS code,
              COALESCE(f.contrat_foncier_ids, '') AS contrat_foncier_ids,
              COALESCE(a.contrat_agricole_ids, '') AS contrat_agricole_ids,
              p.perimetre
            FROM gestcons.parcelles_base p
            LEFT JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id AND p.type_parcelle_id = 1
            LEFT JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id AND p.type_parcelle_id = 2
            LEFT JOIN foncier f ON f.parcelle_id = p.id
            LEFT JOIN agricole a ON a.parcelle_id = p.id
            WHERE p.site_id = {site_id}
          ")
      
      df <- safe_db_query(con, q)
      # Convertir les chaînes d'IDs en listes d'IDs numériques
      df$contrats_foncier <- lapply(df$contrat_foncier_ids, function(x) {
        if (x == "") integer(0) else as.integer(unlist(strsplit(x, ",")))
      })
      df$contrats_agricole <- lapply(df$contrat_agricole_ids, function(x) {
        if (x == "") integer(0) else as.integer(unlist(strsplit(x, ",")))
      })
      df$contrat_foncier_ids <- df$contrat_agricole_ids <- NULL
      return(df)
    }
    
    # --- Parcelles rattachées à UNE animation, mêmes attributs
    .af_fetch_anim_parcelles <- function(site_id, animation_id, kind = c("F","A")) {
      kind <- match.arg(kind)
      if (is.null(site_id) || is.na(site_id) || is.null(animation_id)) return(NULL)
      jt <- if (identical(kind,"A")) 
        "gestcons.animation_contrat_agricole_parcelles" 
      else 
        "gestcons.animation_fonciere_parcelles"
      
      
      q <- glue::glue("
            WITH base AS (
              SELECT
                p.id::int                         AS parcelle_id,
                1::int                            AS type_parcelle,
                c.idpar::text                     AS code,
                NULL::int                         AS perimetre_id,
                c.idcomtxt::text                  AS commune,
                ST_Area(ST_Transform(c.geompar, 2154))::numeric AS surface_m2,
                NULL::text                        AS remarque,
                ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom
              FROM gestcons.parcelles_base p
              JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
              JOIN {jt} afp ON afp.parcelle_id = p.id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 1 AND afp.animation_id = {animation_id}
            ),
            proprietaires AS (
              SELECT
                b.parcelle_id,
                string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires
              FROM base b
              JOIN gestcons.parcelles_base p ON p.id = b.parcelle_id
              JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
              LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
              GROUP BY b.parcelle_id
            ),
            foncier AS (
              SELECT
                b.parcelle_id,
                NULLIF(string_agg(DISTINCT cf.nom, ', ' ORDER BY cf.nom), '') AS contrats_fonciers
              FROM base b
              LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.parcelle_id = b.parcelle_id
              LEFT JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
              GROUP BY b.parcelle_id
            ),
            agricole AS (
              SELECT
                b.parcelle_id,
                NULLIF(string_agg(DISTINCT ca.nom, ', ' ORDER BY ca.nom), '') AS contrats_agricoles
              FROM base b
              LEFT JOIN gestcons.contrats_agricoles_parcelles cap ON cap.parcelle_id = b.parcelle_id
              LEFT JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
              GROUP BY b.parcelle_id
            ),
            man AS (
              SELECT
                p.id::int                         AS parcelle_id,
                2::int                            AS type_parcelle,
                ('M-'||ppm.id)::text              AS code,
                ppm.id                            AS perimetre_id,
                NULL::text                        AS proprietaires,
                NULL::text                        AS commune,
                ST_Area(ST_Transform(ppm.geometrie, 2154))::numeric AS surface_m2,
                COALESCE(ppm.remarque,'')         AS remarque,
                ST_Transform(ppm.geometrie, 4326) AS geom
              FROM gestcons.parcelles_base p
              JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id
              JOIN {jt} afp ON afp.parcelle_id = p.id
              WHERE p.site_id = {site_id} AND p.type_parcelle_id = 2 AND afp.animation_id = {animation_id}
            )
            SELECT
              b.parcelle_id, b.type_parcelle, b.code, b.code AS idpar,
              b.perimetre_id, COALESCE(pr.proprietaires,'') AS proprietaires,
              b.commune, b.surface_m2, b.remarque, b.geom,
              COALESCE(f.contrats_fonciers,'') AS contrats_fonciers,
              COALESCE(a.contrats_agricoles,'') AS contrats_agricoles
            FROM base b
            LEFT JOIN proprietaires pr USING (parcelle_id)
            LEFT JOIN foncier f       USING (parcelle_id)
            LEFT JOIN agricole a      USING (parcelle_id)
          
            UNION ALL
          
            SELECT
              m.parcelle_id, m.type_parcelle, m.code, m.code AS idpar,
              m.perimetre_id, m.proprietaires, m.commune, m.surface_m2, m.remarque, m.geom,
              NULL::text AS contrats_fonciers,
              NULL::text AS contrats_agricoles
            FROM man m
          ")
      
      
      sf <- tryCatch(sf::st_read(con, query = q), error = function(e) NULL)
      sf
    }
    
    
    # --- Clic sur 🗺️ : ouvrir le modal & dessiner
    observeEvent(input$af_show, {
      raw  <- as.character(input$af_show$id)
      kind <- if (!is.null(raw) && grepl("^A:", raw)) "A" else "F"
      anim_id <- as.integer(sub("^[FA]:", "", raw))
      req(!is.na(anim_id), af_site_id())
      
      af_edit_id(anim_id)
      af_edit_kind(kind)
      
      af_anim_contrat_mix(NULL)
      
      af_edit_id(anim_id)
      
      site_sf <- .af_fetch_site_parcelles(af_site_id())
      anim_sf <- .af_fetch_anim_parcelles(af_site_id(), anim_id, kind)
      
      # ✅ AJOUT: Récupérer et stocker les IDs de contrats pour la validation
      parcelle_contrats_data <- .af_get_parcelle_contrat_ids(af_site_id())
      af_parcelle_contrats_rv(parcelle_contrats_data) 
      
      af_site_parcelles(site_sf)
      af_anim_parcelles(anim_sf)
      
      sel_codes <- if (!is.null(anim_sf) && nrow(anim_sf) > 0) anim_sf$code else character(0)
      af_anim_selected(unique(sel_codes))
      
      af_map_ready(FALSE)
      af_map_nonce(isolate(af_map_nonce()) + 1L)
      
      is_rs_on_site <- can_edit_site()
      
      showModal(modalDialog(
        title = paste0("🗺️ Action ", if (identical(kind,"A")) "[Agricole] " else "[Foncier] ",
                       "#", anim_id, " — gérer les parcelles"),
        size = "l",
        easyClose = TRUE,
        footer = if (isTRUE(is_rs_on_site)) {
          tagList(
            tags$div(
              style = "display:flex; align-items:center; justify-content:space-between; width:100%;",
              tags$div(
                actionButton(ns("af_anim_select_all"), "Tout sélectionner", class = "btn btn-sm btn-info"),
                actionButton(ns("af_anim_clear"), "Vider", class = "btn btn-sm btn-default btn-secondary")
              ),
              tags$div(
                modalButton("Fermer"),
                actionButton(ns("af_anim_save"), "💾 Enregistrer", class = "btn btn-primary")
              )
            )
          )
        } else {
          # Sans droits d'édition : aucun bouton, la croix de l'en-tête suffit
          NULL
        },
        fluidPage(
          helpText("Clique sur les parcelles bleues du site (ou oranges de la continuité du site conservatoire) pour les ajouter / retirer de l’action (en rouge)."),
          uiOutput(ns("af_anim_count")),
          leafletOutput(ns("af_modal_map"), height = "70vh")
        )
      ))
      # Réveille leaflet dans le modal (taille correcte)
      session$sendCustomMessage('af-invalidate-size', ns('af_modal_map'))
      
    })
    
    # --- Carte dans le modal
    # --- Carte dans le modal (render une seule fois par ouverture)
    output$af_modal_map <- renderLeaflet({
      af_map_nonce()  # <- force un render complet à chaque ouverture
      
      site_sf <- af_site_parcelles()
      
      m <- leaflet() %>%
        addMapPane("af_site", zIndex = 430) %>%
        addMapPane("af_anim", zIndex = 440) %>%
        addTiles(group = "Fond OSM") %>%
        # --- Outil rectangle
        add_std_draw_toolbar(rectangle = "discret") %>%
        addLayersControl(
          baseGroups = c("Fond OSM"),
          overlayGroups = c("Parcelles du site", "Parcelles de l'action"),
          options = layersControlOptions(collapsed = FALSE)
        )
      
      if (!is.null(site_sf) && nrow(site_sf) > 0) {
        # Split site / périmètre : les hachures (classe pp-hachures + handler
        # tc-hatch) ne peuvent s'appliquer qu'à une couche dédiée.
        sf_std  <- site_sf[!(site_sf$perimetre %in% TRUE), , drop = FALSE]
        sf_peri <- site_sf[site_sf$perimetre %in% TRUE, , drop = FALSE]
        if (nrow(sf_std) > 0) {
          m <- m %>% addPolygons(
            data = sf_std,
            group = "Parcelles du site",
            color = "blue", weight = 1, fillOpacity = 0.3,
            label = .cf_make_labels(sf_std, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("site-", code),
            options = pathOptions(pane = "af_site")
          )
        }
        if (nrow(sf_peri) > 0) {
          m <- m %>% addPolygons(
            data = sf_peri,
            group = "Parcelles du site",
            color = "#ea580c", weight = 1,
            fillColor = "#f97316", fillOpacity = 0.2,  # repli si JS indisponible
            label = .cf_make_labels(sf_peri, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("site-", code),
            options = pathOptions(pane = "af_site", className = "pp-hachures")
          )
          session$sendCustomMessage("tc-hatch", list(id = ns("af_modal_map")))
        }
      }
      
      
      bb <- if (!is.null(site_sf) && nrow(site_sf) > 0) sf::st_bbox(site_sf) else NULL
      m <- if (!is.null(bb)) {
        m %>% fitBounds(
          lng1 = as.numeric(bb["xmin"]), lat1 = as.numeric(bb["ymin"]),
          lng2 = as.numeric(bb["xmax"]), lat2 = as.numeric(bb["ymax"])
        )
      } else {
        m %>% setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = 9)
      }
      
      # ✅ Déclare la carte prête après flush de ce render
      shiny::onFlush(function() af_map_ready(TRUE), once = TRUE)
      
      m
    })
    
    af_map_zoom_debounced <- shiny::debounce(reactive(input$af_map_zoom), 500)

    observeEvent(list(af_map_ready(), af_map_zoom_debounced()), {
      req(af_map_ready())

      # ⚠️ On ne dessine les cercles que s'il n'y a PAS de site sélectionné
      req(is.null(af_site_id()) || is.na(af_site_id()) || identical(af_site_id(), ""))

      # input$af_map_zoom peut être NULL au tout premier render
      z <- af_map_zoom_debounced()
      if (is.null(z) || is.na(z)) z <- 9.3
      draw_circles(con, map_id = ns("af_map"), zoom = z)  # group = "Sites existants" par défaut
    }, ignoreInit = FALSE)
    
    
    # Évite la suspension quand le modal est fermé/rouvert
    outputOptions(output, "af_modal_map", suspendWhenHidden = FALSE)
    
    # --- Redessine la couche rouge quand la sélection change (sans toucher au zoom)
    # --- Redessine la couche rouge quand la sélection change (sans toucher au zoom)
    # --- Redessine la couche rouge quand la sélection change OU quand la carte devient prête
    observeEvent(list(af_anim_selected(), af_map_ready()), {
      req(af_map_ready())  # ne dessine que quand la carte existe
      site_sf <- af_site_parcelles()
      req(site_sf)
      
      sel <- af_anim_selected()
      proxy <- leafletProxy(ns("af_modal_map")) %>% clearGroup("Parcelles de l'action")
      
      if (length(sel) > 0) {
        sub <- site_sf[site_sf$code %in% sel, , drop = FALSE]
        if (nrow(sub) > 0) {
          proxy %>% addPolygons(
            data = sub,
            group = "Parcelles de l'action",
            color = "red", weight = 2, fillOpacity = 0.5,
            label = .cf_make_labels(sub, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("anim-", code),
            options = pathOptions(pane = "af_anim")
          )
          
        }
      }
    }, ignoreInit = FALSE)
    
    observeEvent(contrats_choices_rv(), {
      contrats <- contrats_choices_rv()
      updateSelectInput(
        session,
        "af_form_contrat",
        choices = c("Aucun" = "", setNames(contrats$id, contrats$nom)),
        selected = ""
      )
      updateSelectInput(
        session,
        "af_edit_contrat",
        choices = c("Aucun" = "", setNames(contrats$id, contrats$nom)),
        selected = ""
      )
    })
    
    # --- Rectangle dessiné sur la carte du modal : ajoute toutes les parcelles intersectées
    # Lignes 1222-1259 (mod_animations.R)
    # --- Rectangle dessiné sur la carte du modal D'ÉDITION : ajoute les parcelles valides ---
    # R/mod_actions.R (Lignes 1475 à 1522 environ)
    
    # --- Rectangle dessiné sur la carte du modal D'ÉDITION : ajoute les parcelles valides ---
    observeEvent(input$af_modal_map_draw_new_feature, {
      
      # 🚨 GARDE 2: Bloquer l'interaction si l'utilisateur n'est pas éditeur 🚨
      if (!isTRUE(is_editor_on_site_rv())) {
        showToast("error", "Lecture seule", "Vous ne pouvez pas utiliser le mode sélection par rectangle.")
        # Nettoyer immédiatement la forme dessinée pour éviter la confusion
        leafletProxy(ns("af_modal_map")) %>% clearGroup("Polygones")
        return(invisible(NULL)) 
      }
      # 🚨 FIN DE LA GARDE 🚨
      
      feat <- input$af_modal_map_draw_new_feature
      rect <- .Polygones_to_sfc(feat)
      req(rect)
      
      site_sf <- af_site_parcelles(); req(site_sf, nrow(site_sf) > 0)
      parc_contrats <- af_parcelle_contrats_rv(); req(parc_contrats) # <-- AJOUT
      
      hit <- sf::st_intersects(site_sf, rect, sparse = FALSE)[,1]
      codes_in_rect <- site_sf$code[which(hit)]
      
      # 1. État initial de la sélection
      current_sel <- isolate(af_anim_selected())
      
      # Parcelles dans le rectangle et non encore sélectionnées
      codes_to_add <- setdiff(codes_in_rect, current_sel)
      
      # 2. Logique de validation et d'ajout 
      
      # 💡 NOUVELLE LOGIQUE : Identifier les codes de parcelles qui ont au moins UN contrat (F ou A)
      contractualized_codes <- parc_contrats$code[
        sapply(parc_contrats$contrats_foncier, length) > 0 | 
          sapply(parc_contrats$contrats_agricole, length) > 0
      ]
      
      # Codes valides à ajouter (dans le rectangle ET contractualisés)
      valid_codes_to_add <- intersect(codes_to_add, contractualized_codes)
      
      # Nouvelle sélection = ancienne sélection + codes valides du rectangle
      new_sel <- c(current_sel, valid_codes_to_add)
      
      # 3. Messages de succès/échec
      added_count <- length(valid_codes_to_add)
      rejected_count <- length(codes_to_add) - added_count
      
      if (added_count > 0) {
        showToast("success", "Sélection rapide", sprintf("%d parcelle(s) ajoutée(s) à l’action.", added_count))
      }
      
      if (rejected_count > 0) {
        showToast("warning", "Parcelles ignorées", 
                  sprintf("%d parcelle(s) du rectangle ignorée(s) car non associées à un contrat (foncier ou agricole).", rejected_count))
      }
      
      if (added_count == 0 && rejected_count == 0) {
        if (length(current_sel) > 0) {
          # On ne montre pas d'alerte si l'utilisateur a simplement re-dessiné sur une zone déjà sélectionnée
          # mais on le notifie si l'intention était d'ajouter et que rien n'a bougé.
          if (length(codes_to_add) > 0) {
            showToast("info", "Rien à ajouter", "Toutes les parcelles éligibles du rectangle sont déjà sélectionnées.")
          }
        }
      }
      
      af_anim_selected(unique(new_sel))
      
      # Nettoie le rectangle dessiné
      session$sendCustomMessage('clear-polygones', ns("af_modal_map"))
      leafletProxy(mapId = ns("af_modal_map"), session = session) %>% 
        clearGroup("Polygones") %>%
        # AJOUTER CECI, car Leaflet.Draw utilise souvent 'drawnItems' ou 'drawn'
        clearGroup("drawnItems") %>%
        clearGroup("drawn")
      
      # NOTE : Le redessinage du polygone rouge se fait via l'observateur réactif
      # 'observeEvent(list(af_anim_selected(), af_map_ready()), ...)'
    })
    
    # (l'observer de bascule Liste -> Carte a disparu avec le sélecteur : la
    # carte est désormais toujours affichée. Les cercles des sites restent
    # dessinés par l'observer af_map_ready/zoom, et effacés à la sélection
    # d'un site par l'observer du sélecteur.)

    # --- Compteur
    output$af_anim_count <- renderUI({
      n <- length(af_anim_selected())
      tags$p(HTML(paste0("Parcelles dans l’action : <b>", n, "</b>")))
    })
    
    # --- Tout sélectionner
    # --- Tout sélectionner (seulement les parcelles liées au contrat de l'action)
    # Lignes 1319 à 1360 (à modifier)
    # --- Tout sélectionner (seulement les parcelles liées au contrat de l'action)
    # R/mod_actions.R (Lignes 1319 à 1360 environ - À REMPLACER)
    
    # --- Tout sélectionner (Toutes les parcelles qui ont un contrat)
    observeEvent(input$af_anim_select_all, {
      site_sf <- af_site_parcelles(); req(site_sf, nrow(site_sf) > 0)
      
      # ⚠️ REMOVAL : Suppression de la vérification du contrat_specifique pour forcer la sélection globale
      # contrat_specifique <- af_anim_contrat_mix(); 
      
      parc_contrats <- af_parcelle_contrats_rv(); req(parc_contrats)
      
      # 💡 LOGIQUE UNIFIÉE : Sélectionner toutes les parcelles qui ont au moins UN contrat (F ou A).
      final_sel_codes <- parc_contrats$code[
        sapply(parc_contrats$contrats_foncier, length) > 0 | 
          sapply(parc_contrats$contrats_agricole, length) > 0 |
          parc_contrats$perimetre %in% TRUE
      ]
      
      if (length(final_sel_codes) == 0) {
        showToast("info", "Aucune parcelle", "Aucune parcelle du site n'est liée à un contrat.")
      } else {
        showToast("success", "Sélection rapide", 
                  sprintf("%d parcelle(s) avec contrat ont été sélectionnée(s).", length(final_sel_codes)))
      }
      
      af_anim_selected(final_sel_codes)
      
      # Redessinage de la couche rouge (déclenché par l'observeEvent de af_anim_selected())
    })
    
    
    # --- Vider la sélection
    observeEvent(input$af_anim_clear, {
      af_anim_selected(character(0))
    })
    
    # --- Toggle sélection au clic
    # Lignes 1283-1308 (mod_animations.R)
    # --- Toggle sélection au clic
    observeEvent(input$af_modal_map_shape_click, {
      
      # 🚨 GARDE 1: Bloquer l'interaction si l'utilisateur n'est pas éditeur 🚨
      if (!isTRUE(is_editor_on_site_rv())) {
        showToast("error", "Lecture seule", "Vous ne pouvez pas modifier la sélection des parcelles.")
        return(invisible(NULL)) 
      }
      # 🚨 FIN DE LA GARDE 🚨
      
      click <- input$af_modal_map_shape_click
      req(click$id, click$group %in% c("Parcelles du site", "Parcelles de l'action"))
      
      code <- sub("^(site-|anim-)", "", click$id)  # retire le préfixe
      sel <- af_anim_selected()
      
      # 💡 NEUTRALISATION DE af_anim_contrat_mix() (puisque la colonne est supprimée)
      contrat_specifique <- NULL 
      
      if (code %in% sel) {
        # DÉSELECTION : TOUJOURS AUTORISÉE
        sel <- setdiff(sel, code)
      } else {
        # SÉLECTION D'UNE NOUVELLE PARCELLE : SOUMISE À LA CONTRAINTE
        
        # 💡 NOUVELLE LOGIQUE : VÉRIFIER SEULEMENT SI LA PARCELLE A AU MOINS UN CONTRAT
        # (le contrat_specifique est NULL, donc .af_has_common_contrat vérifie la contractualisation simple)
        is_valid <- .af_has_common_contrat(code, sel, contrat_specifique_mix = contrat_specifique)
        
        if (is_valid) {
          sel <- c(sel, code)
        } else {
          # 💡 MESSAGE D'ERREUR UNIFIÉ
          showToast("warning", "Contrat requis", "La parcelle doit être associée à au moins un contrat (foncier ou agricole) pour être ajoutée.")
          return() # Empêche l'ajout
        }
      }
      
      af_anim_selected(unique(sel)) 
    })
    
    observeEvent(input$af_anim_close, {  # ← si tu ajoutes un actionButton(ns("af_anim_close"), "Fermer")
      removeModal()
      af_table_reload(isolate(af_table_reload()) + 1)  # ← refresh de la liste après coup
    })
    
    
    # --- Enregistrer les parcelles sélectionnées
    observeEvent(input$af_anim_save, {
      shinybusy::show_modal_spinner(
        spin  = "circle",           # ← style local, différent du global
        color = COULEUR_SPINNER,
        text  = "💾 Sauvegarde en cours..."
      )
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
      
      anim_id <- af_edit_id()
      if (is.null(anim_id)) {
        showToast("error", "Action inconnue",
                  "Impossible d'enregistrer : identifiant d’action manquant.")
        return()
      }
      req(af_site_id())
      codes <- af_anim_selected()
      
      # 🛑 ne pas autoriser 0
      if (length(codes) == 0) {
        showToast("warning", "Sélection vide",
                  "Une action doit contenir au moins une parcelle.")
        return()
      }
      
      jt <- if (identical(af_edit_kind(), "A")) 
        "gestcons.animation_contrat_agricole_parcelles" 
      else 
        "gestcons.animation_fonciere_parcelles"
      
      # Résolution de TOUS les codes en UNE requête (.af_codes_to_parcelle_ids,
      # déjà utilisée ailleurs dans le module), puis DELETE + INSERT groupé dans
      # UNE transaction. L'ancienne boucle faisait 2 requêtes par parcelle
      # (2N+1 : 200 allers-retours pour un rectangle de 100 parcelles) et hors
      # transaction : si un INSERT échouait, le DELETE restait acquis et
      # l'action perdait silencieusement ses parcelles, avec un toast de succès.
      ids <- .af_codes_to_parcelle_ids(af_site_id(), unique(codes))
      ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          tx_execute(conn, log_query(glue::glue("
            DELETE FROM {jt}
            WHERE animation_id = {anim_id}
          ")))
          if (length(ids) > 0) {
            values <- paste0("(", anim_id, ", ", ids, ")", collapse = ",")
            tx_execute(conn, log_query(glue::glue("
              INSERT INTO {jt} (animation_id, parcelle_id)
              VALUES {DBI::SQL(values)}
              ON CONFLICT DO NOTHING
            ")))
          }
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Erreur SQL",
                  paste("Enregistrement des parcelles impossible :", conditionMessage(e)))
        FALSE
      })
      if (!isTRUE(ok)) return(invisible(NULL))

      showToast("success", "Action mise à jour", "✅ Parcelles enregistrées.")
      log_action(session, current_user_rv, "Action : parcelles de l'action mises à jour")
      # 💡 On reste dans le modal: pas de removeModal() ni de refresh du tableau ici.
      af_table_reload(isolate(af_table_reload()) + 1) 
      
    })
    
    .af_build_proprio_dict <- function(site_id, sf_site_parcelles) {
      if (is.null(sf_site_parcelles) || nrow(sf_site_parcelles) == 0) return(list())
      
      df_cad <- sf::st_drop_geometry(sf_site_parcelles) %>% 
        dplyr::filter(type_parcelle == 1) %>% # Seules les cadastrales ont un idprocpte fiable
        dplyr::select(code, proprietaires, idprocpte)
      
      if (nrow(df_cad) == 0) return(list())
      
      proprio_list <- df_cad %>%
        # Retire les parcelles sans propriétaire renseigné
        dplyr::filter(nzchar(proprietaires)) %>% 
        # Crée une clé combinée pour éviter les conflits si deux propriétaires
        # ont le même nom mais sont deux entités distinctes (ce qui ne devrait 
        # pas arriver car l'idprocpte est unique)
        dplyr::mutate(
          proprio_key = paste0(proprietaires, " (", idprocpte, ")")
        ) %>%
        dplyr::group_by(proprio_key) %>%
        dplyr::summarise(
          codes = list(code),
          display_label = dplyr::first(proprietaires)
        )
      
      if (nrow(proprio_list) == 0) return(list())
      
      # Construction du dictionnaire {label: c(code_parcelle)}
      dict <- df_cad %>%
        dplyr::filter(nzchar(proprietaires)) %>%
        dplyr::group_by(proprietaires) %>%
        dplyr::summarise(codes = list(code))
      
      # Le libellé du sélecteur sera la colonne 'proprietaires', qui est déjà 
      # le résultat agrégé de la requête. S'il contient des virgules (ex: 'Mr A, Mme B'),
      # le selectize le verra comme une seule entrée.
      # Si vous voulez forcer l'éclatement des co-propriétaires:
      
      final_dict <- list()
      for (i in seq_len(nrow(dict))) {
        # Éclate les co-propriétaires séparés par des virgules dans le libellé
        labels <- stringr::str_split(dict$proprietaires[i], ",\\s*")[[1]]
        
        # Pour chaque nom, ajoute les codes de parcelle associés au libellé propre
        # (ceci crée une duplication si un même nom apparaît dans plusieurs lignes de dict, 
        # mais assure qu'il n'y a qu'un nom par entrée de sélecteur)
        for (label in labels) {
          label_key <- stringr::str_trim(label)
          # Ajoute les codes à la liste pour cette entrée unique de nom
          final_dict[[label_key]] <- unique(c(final_dict[[label_key]], dict$codes[[i]]))
        }
      }
      
      # On trie les clés du dictionnaire (les noms des propriétaires)
      sorted_keys <- sort(names(final_dict))
      final_dict <- final_dict[sorted_keys]
      
      # Retourne une liste nommée [Nom Complet 1] = c(code_parcelle1, ...)
      final_dict
    }
    
    
    # --- Clic sur "➕ Nouvelle animation"
    observeEvent(input$af_add, {
      if (is.null(af_site_id())) {
        showToast("warning", "Site manquant", "Sélectionne d'abord un site à gauche.")
        return()
      }
      site_sf <- .af_fetch_site_parcelles(af_site_id())
      if (is.null(site_sf) || nrow(site_sf) == 0) {
        showToast("warning", "Aucune parcelle", "Ce site n'a pas (encore) de parcelle.")
        return()
      }
      
      parcelle_contrats_data <- .af_get_parcelle_contrat_ids(af_site_id())
      
      af_new_site_sf(site_sf)
      af_parcelle_contrats_rv(parcelle_contrats_data)
      af_new_selected(character(0))
      
      proprio_dict <- .af_build_proprio_dict(af_site_id(), site_sf)
      af_proprietaires_site_rv(proprio_dict)
      proprio_choices <- c("— Sélectionner —" = "", names(proprio_dict))
      
      af_new_nonce(isolate(af_new_nonce()) + 1L)
      
      showModal(modalDialog(
        title = "Étape 1/2 — Sélectionner les parcelles de l'action",
        size = "l",
        easyClose = FALSE,   # assistant : un clic à côté perdrait la saisie
        footer = tagList(
          tags$div(
            style = "display:flex; align-items:center; justify-content:space-between; width:100%;",
            actionButton(ns("af_select_all"), "Tout sélectionner", class = "btn btn-sm btn-info"),
            div(
              style = "display: flex; gap: 10px; align-items: flex-end;",
              selectizeInput(
                ns("af_proprio_selector"),
                label = "",
                choices = proprio_choices,
                options = list(
                  placeholder = "Propriétaire (parcelles à l'écran)…",
                  diacritics = TRUE,
                  create = FALSE
                )
              ),
              #actionButton(ns("af_proprio_select_action"), "Sélectionner", class = "btn btn-sm btn-info")
            ),
            tags$div(
              actionButton(ns("af_cancel"), "Annuler", class = "btn btn-default btn-secondary"),
              actionButton(ns("af_next"), "Continuer", class = "btn btn-primary")
            )
          )
        ),
        fluidPage(
          p("Clique sur les parcelles pour les ajouter/retirer de la sélection."),
          uiOutput(ns("af_new_count")),
          leafletOutput(ns("af_new_map"), height = "70vh")
        )
      ))
      
      session$sendCustomMessage('af-reset-click', ns('af_new_map'))
      session$sendCustomMessage('af-invalidate-size', ns('af_new_map'))
    })
    
    # Propriétaires proposés : ceux des parcelles PRÉSENTES DANS L'EMPRISE de la
    # carte de sélection. La condition « site ou continuité du site conservatoire » est déjà
    # acquise — `af_new_site_sf` ne contient que celles-là — seul le cadrage
    # restait à appliquer. Le dictionnaire filtré sert aussi à la sélection :
    # choisir un propriétaire ne prend que ses parcelles à l'écran, jamais des
    # parcelles hors champ que personne n'a vues.
    #
    # L'observer ne suit QUE les bornes (débouncées comme ailleurs) : à
    # l'ouverture de la modale, le dictionnaire complet vient d'être posé et le
    # cadrage sur le site entier donne la même liste. Le faire dépendre aussi
    # de af_new_site_sf() ferait filtrer un instant sur le cadrage de la modale
    # précédente.
    af_new_map_bounds_debounced <- shiny::debounce(reactive(input$af_new_map_bounds), 500)

    observeEvent(af_new_map_bounds_debounced(), {
      site_sf <- af_new_site_sf()
      req(site_sf, nrow(site_sf) > 0)
      b <- af_new_map_bounds_debounced()
      req(b)
      
      box <- sf::st_as_sfc(sf::st_bbox(
        c(xmin = as.numeric(b$west),  ymin = as.numeric(b$south),
          xmax = as.numeric(b$east),  ymax = as.numeric(b$north)),
        crs = sf::st_crs(site_sf)
      ))
      hit <- tryCatch(
        lengths(sf::st_intersects(sf::st_geometry(site_sf), box)) > 0,
        error = function(e) rep(TRUE, nrow(site_sf))
      )
      
      dict <- .af_build_proprio_dict(af_site_id(), site_sf[hit, , drop = FALSE])
      af_proprietaires_site_rv(dict)
      updateSelectizeInput(
        session, "af_proprio_selector",
        choices  = c("— Sélectionner —" = "", names(dict)),
        selected = ""
      )
    })
    
    # --- Carte de sélection
    # Archive 8.zip/R/mod_animations.R (remplace le bloc existant vers la ligne 1461)
    
    output$af_new_map <- renderLeaflet({
      af_new_nonce()
      req(af_new_site_sf())
      site_sf <- af_new_site_sf()
      
      # NOUVEAU: Récupérer la sélection courante pour filtrer les cliquables
      sel <- isolate(af_new_selected())
      parc_contrats <- af_parcelle_contrats_rv(); req(parc_contrats)
      
      # Les parcelles cliquables sont celles:
      # 1. Qui ont un contrat (si la sélection est vide)
      # 2. OU qui ont au moins un contrat commun avec la sélection existante
      
      parc_cliquables_codes <- character(0)
      
      if (length(sel) == 0) {
        # Cas 1: Sélection vide. Cliquables = Parcelles avec au moins 1 contrat F ou A
        parc_cliquables_codes <- parc_contrats$code[
          sapply(parc_contrats$contrats_foncier, length) > 0 | 
            sapply(parc_contrats$contrats_agricole, length) > 0 |
            parc_contrats$perimetre %in% TRUE
        ]
      } else {
        # Cas 2: Sélection non vide. Cliquables = Parcelles qui ont un contrat commun avec l'INTERSECTION
        # Des contrats de la sélection existante.
        
        # Contrats communs à la sélection existante (Foncier + Agricole)
        existing_rows <- parc_contrats[parc_contrats$code %in% sel, ]
        f_common_existing <- Reduce(intersect, existing_rows$contrats_foncier)
        a_common_existing <- Reduce(intersect, existing_rows$contrats_agricole)
        
        # Les parcelles éligibles (qui peuvent être la prochaine)
        # 1. Elles sont déjà sélectionnées (pour permettre la déselection)
        # 2. OU elles ne sont PAS sélectionnées MAIS ont un contrat (F ou A) qui est dans l'intersection des contrats de la sélection existante.
        for (i in 1:nrow(parc_contrats)) {
          code <- parc_contrats$code[i]
          is_selected <- code %in% sel
          
          if (is_selected) {
            parc_cliquables_codes <- c(parc_cliquables_codes, code)
          } else if (isTRUE(parc_contrats$perimetre[i])) {
            # Parcelle de la continuité du site conservatoire : toujours sélectionnable (pas de contrat requis)
            parc_cliquables_codes <- c(parc_cliquables_codes, code)
          } else {
            new_f_ids <- parc_contrats$contrats_foncier[[i]]
            new_a_ids <- parc_contrats$contrats_agricole[[i]]
            
            has_common_f <- any(new_f_ids %in% f_common_existing)
            has_common_a <- any(new_a_ids %in% a_common_existing)
            
            if (has_common_f || has_common_a) {
              parc_cliquables_codes <- c(parc_cliquables_codes, code)
            }
          }
        }
      }
      
      # Séparation pour le rendu
      sf_cliquables <- site_sf[site_sf$code %in% parc_cliquables_codes, ]
      sf_non_cliquables <- site_sf[!(site_sf$code %in% parc_cliquables_codes), ]
      
      # Couleurs pour le rendu initial
      col_cliquable <- "#3b82f6"  # Bleu (avec contrat, sélectionnable)
      col_non_cliquable <- "#9ca3af"  # Gris (sans contrat, non sélectionnable)
      
      m <- leaflet() %>%
        addMapPane("af_sel", zIndex = 430) %>%
        addTiles(group = "Fond OSM") %>%
        # --- Outil rectangle
        add_std_draw_toolbar(rectangle = "discret", edit_remove = TRUE) %>%
        addLayersControl(
          baseGroups = c("Fond OSM"),
          overlayGroups = c("Parcelles du site", "Sélection action"),
          options = layersControlOptions(collapsed = FALSE)
        )
      
      # Couche 1: Parcelles NON cliquables (grisées, sans layerId)
      if (nrow(sf_non_cliquables) > 0) {
        m <- m %>% leaflet::addPolygons(
          data = sf_non_cliquables,
          group = "Parcelles du site",
          color = "#00000066", weight = 1, fillOpacity = 0.2,
          fillColor = col_non_cliquable,
          label = .cf_make_labels(sf_non_cliquables, user_roles()),
          highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
          options = pathOptions(pane = "af_sel")
        )
      }
      
      # Couche 2: Parcelles cliquables (bleues, avec layerId) — split site /
      # périmètre pour appliquer les hachures à la couche périmètre.
      sf_cliq_std  <- sf_cliquables[!(sf_cliquables$perimetre %in% TRUE), , drop = FALSE]
      sf_cliq_peri <- sf_cliquables[sf_cliquables$perimetre %in% TRUE, , drop = FALSE]
      if (nrow(sf_cliq_std) > 0) {
        m <- m %>% leaflet::addPolygons(
          data = sf_cliq_std,
          group = "Parcelles du site",
          color = "#00000099", weight = 1, fillOpacity = 0.5,
          fillColor = col_cliquable,
          label = .cf_make_labels(sf_cliq_std, user_roles()),
          highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
          layerId = ~paste0("site-", code), # ✅ layerId POUR le clic/sélection
          options = pathOptions(pane = "af_sel")
        )
      }
      if (nrow(sf_cliq_peri) > 0) {
        m <- m %>% leaflet::addPolygons(
          data = sf_cliq_peri,
          group = "Parcelles du site",
          color = "#ea580c", weight = 1,
          fillColor = "#f97316", fillOpacity = 0.2,  # repli si JS indisponible
          label = .cf_make_labels(sf_cliq_peri, user_roles()),
          highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
          layerId = ~paste0("site-", code),
          options = pathOptions(pane = "af_sel", className = "pp-hachures")
        )
        session$sendCustomMessage("tc-hatch", list(id = ns("af_new_map")))
      }
      
      # Zoom/Fit
      bb <- try(sf::st_bbox(site_sf), silent = TRUE)
      m <- if (!inherits(bb, "try-error")) {
        m %>% fitBounds(
          lng1 = as.numeric(bb["xmin"]), lat1 = as.numeric(bb["ymin"]),
          lng2 = as.numeric(bb["xmax"]), lat2 = as.numeric(bb["ymax"])
        )
      } else {
        m %>% setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = 9)
      }
      
      # ✅ Déclare la carte prête après flush de ce render
      shiny::onFlush(function() af_map_ready(TRUE), once = TRUE)
      
      m
    })
    
    outputOptions(output, "af_new_map", suspendWhenHidden = FALSE)
    
    
    # --- Tout sélectionner (toutes les parcelles du site)
    # R/mod_actions.R (Lignes 1699 à 1761 environ)
    
    # --- Tout sélectionner (toutes les parcelles du site)
    # R/mod_actions.R (Lignes 1708 à 1761 environ - REMPLACER CE BLOC)
    
    # --- Tout sélectionner (toutes les parcelles du site)
    observeEvent(input$af_select_all, {
      req(af_new_site_sf())
      site_sf <- af_new_site_sf()
      parc_contrats <- af_parcelle_contrats_rv(); req(parc_contrats)
      
      # 💡 LOGIQUE SIMPLIFIÉE : Sélectionne toutes les parcelles qui ont au moins UN contrat (F ou A)
      final_sel_codes <- parc_contrats$code[
        sapply(parc_contrats$contrats_foncier, length) > 0 | 
          sapply(parc_contrats$contrats_agricole, length) > 0 |
          parc_contrats$perimetre %in% TRUE
      ]
      
      if (length(final_sel_codes) == 0) {
        showToast("warning", "Aucun contrat", 
                  "Aucune parcelle du site n'est associée à un contrat (foncier ou agricole).")
        af_new_selected(character(0))
        leafletProxy(ns("af_new_map")) %>% clearGroup("Sélection action")
        return()
      } else {
        showToast("success", "Sélection rapide", 
                  sprintf("%d parcelle(s) avec contrat ont été sélectionnée(s).", length(final_sel_codes)))
      }
      
      af_new_selected(final_sel_codes)
      
      # Redessinage de la couche rouge (déclenché par l'observeEvent du toggle, mais forcé ici pour la clarté)
      site_sf <- af_new_site_sf()
      if (is.null(site_sf)) return()
      
      idx <- which(site_sf$code %in% final_sel_codes)
      sel_sf <- site_sf[idx, , drop = FALSE]
      
      leafletProxy(ns("af_new_map")) %>% clearGroup("Sélection action")
      if (nrow(sel_sf) > 0) {
        sel_sf <- sf::st_as_sf(sel_sf)
        invalid <- which(!sf::st_is_valid(sel_sf))
        if (length(invalid)) sel_sf[invalid, "geom"] <- sf::st_make_valid(sel_sf[invalid, ])
        sel_sf <- sf::st_transform(sel_sf, 4326)
        
        leafletProxy(ns("af_new_map")) %>%
          addPolygons(
            data = sel_sf,
            group = "Sélection action",
            color = "red", weight = 2, fillOpacity = 0.5,
            label = .cf_make_labels(sel_sf, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("sel-", code),
            options = pathOptions(pane = "af_sel")
          )
        
      }
    })
    
    # --- Toggle sélection au clic (dans le modal)
    observeEvent(input$af_new_map_shape_click, {
      click <- input$af_new_map_shape_click
      req(click$id)
      if (!click$group %in% c("Parcelles du site", "Sélection action")) return()
      
      sel <- af_new_selected()
      code_clicked <- sub("^(site-|sel-)", "", click$id)
      
      if (code_clicked %in% sel) {
        # DÉSELECTION : TOUJOURS AUTORISÉE
        sel <- setdiff(sel, code_clicked)
      } else {
        # SÉLECTION : AUTORISÉE SEULEMENT SI LA RÈGLE EST RESPECTÉE
        # 💡 L'étape 1 N'A PAS de contrat spécifique, donc on utilise l'ancienne logique d'intersection.
        if (.af_has_common_contrat(code_clicked, sel)) { # 💡 Appel SANS contrat_specifique_mix
          sel <- c(sel, code_clicked)
        } else {
          # 💡 MODIFICATION DU MESSAGE D'ERREUR
          showToast("warning", "Contrat requis", 
                    "La parcelle doit être associée à au moins un contrat (foncier ou agricole) pour être sélectionnée.")
          return() # Sortir sans modifier af_new_selected
        }
      }
      af_new_selected(sel)
      
      site_sf <- af_new_site_sf()
      if (is.null(site_sf)) return()
      
      idx <- which(site_sf$code %in% sel)
      sel_sf <- site_sf[idx, , drop = FALSE]
      
      leafletProxy(ns("af_new_map")) %>% clearGroup("Sélection action")
      if (nrow(sel_sf) > 0) {
        sel_sf <- sf::st_as_sf(sel_sf)
        invalid <- which(!sf::st_is_valid(sel_sf))
        if (length(invalid)) sel_sf[invalid, "geom"] <- sf::st_make_valid(sel_sf[invalid, ])
        sel_sf <- sf::st_transform(sel_sf, 4326)
        
        leafletProxy(ns("af_new_map")) %>%
          addPolygons(
            data = sel_sf,
            group = "Sélection action",
            color = "red", weight = 2, fillOpacity = 0.5,
            label = .cf_make_labels(sel_sf, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("sel-", code),
            options = pathOptions(pane = "af_sel")
          )
        
      }
    })
    
    # --- Rectangle dessiné sur la carte "Nouvelle action"
    observeEvent(input$af_new_map_draw_new_feature, {
      feat <- input$af_new_map_draw_new_feature
      rect <- .Polygones_to_sfc(feat)
      req(rect)
      
      site_sf <- af_new_site_sf(); req(site_sf, nrow(site_sf) > 0)
      
      hit <- sf::st_intersects(site_sf, rect, sparse = FALSE)[,1]
      codes_in_rect <- site_sf$code[which(hit)]
      
      # 1. État initial de la sélection
      current_sel <- isolate(af_new_selected())
      new_sel <- current_sel
      
      codes_to_add <- setdiff(codes_in_rect, current_sel)
      
      # 2. Logique de validation et d'ajout progressif
      
      # Pour chaque parcelle du rectangle qui n'est PAS déjà sélectionnée :
      for (code in codes_to_add) {
        # 💡 La vérification se fait sans la contrainte de contrat commun
        if (.af_has_common_contrat(code, new_sel)) { # 💡 Appel SANS contrat_specifique_mix
          # Si la parcelle est valide (a au moins un contrat)
          # On l'ajoute à new_sel
          new_sel <- c(new_sel, code)
        }
      }
      
      # 3. Mise à jour et messages
      
      if (length(new_sel) == length(current_sel)) {
        # Si aucune nouvelle parcelle n'a pu être ajoutée
        if (length(current_sel) > 0) {
          # 💡 MODIFICATION DU MESSAGE D'ERREUR
          showToast("warning", "Contrat requis",
                    "Aucune parcelle du rectangle n'a pu être ajoutée car elles ne sont pas associées à un contrat (foncier ou agricole).")
        }
      }
      
      af_new_selected(unique(new_sel))
      
      # 4. Redessinage (utilise 'new_sel' qui est déjà l'état final)
      leafletProxy(ns("af_new_map")) %>% clearGroup("Sélection action")
      if (length(new_sel) > 0) {
        sel_sf <- site_sf[site_sf$code %in% new_sel, , drop = FALSE]
        if (nrow(sel_sf) > 0) {
          inv <- which(!sf::st_is_valid(sel_sf))
          if (length(inv)) sel_sf[inv, "geom"] <- sf::st_make_valid(sel_sf[inv, ])
          sel_sf <- sf::st_transform(sel_sf, 4326)
          
          leafletProxy(ns("af_new_map")) %>%
            addPolygons(
              data = sel_sf,
              group = "Sélection action",
              color = "red", weight = 2, fillOpacity = 0.5,
              label = .cf_make_labels(sel_sf, user_roles()),
              labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
              highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
              layerId = ~paste0("sel-", code),
              options = pathOptions(pane = "af_sel")
            )
        }
      }
      
      # Nettoie le rectangle dessiné
      session$sendCustomMessage('clear-polygones', ns("af_new_map"))
      leafletProxy(mapId = ns("af_new_map"), session = session) %>% 
        clearGroup("Polygones") %>%
        # AJOUTER CECI, car Leaflet.Draw utilise souvent 'drawnItems' ou 'drawn'
        clearGroup("drawnItems") %>%
        clearGroup("drawn")
    })
    
    # --- Sélectionner par Propriétaire
    observeEvent(input$af_proprio_selector, {
      req(input$af_proprio_selector, nzchar(input$af_proprio_selector))
      
      proprio_label <- input$af_proprio_selector
      proprio_dict  <- af_proprietaires_site_rv()
      codes_proprio <- proprio_dict[[proprio_label]]
      
      if (is.null(codes_proprio) || length(codes_proprio) == 0) {
        showToast("warning", "Aucune parcelle", "Ce propriétaire n'a pas de parcelles cadastrales sur ce site.")
        return()
      }
      
      current_sel <- isolate(af_new_selected())
      new_sel     <- current_sel
      codes_to_add <- setdiff(codes_proprio, current_sel)
      
      # --- Logique de validation par contrat commun ---
      if (length(current_sel) == 0) {
        # CAS 1: Sélection vide. Valider les parcelles du propriétaire.
        parc_contrats <- af_parcelle_contrats_rv(); req(parc_contrats)
        proprio_rows <- parc_contrats[parc_contrats$code %in% codes_proprio, , drop = FALSE]
        
        # Les parcelles de la ZONE D'INTÉRÊT n'ont pas de contrat — c'est leur
        # objet même (action de pré-acquisition) — et le clic parcelle par
        # parcelle les exempte déjà de la règle (.af_has_common_contrat). Les
        # faire entrer dans l'intersection la vidait à coup sûr : un
        # propriétaire ayant ne serait-ce qu'une parcelle en continuité du site conservatoire
        # était refusé en bloc.
        peri_codes <- proprio_rows$code[proprio_rows$perimetre %in% TRUE]
        rows_site  <- proprio_rows[!(proprio_rows$perimetre %in% TRUE), , drop = FALSE]
        
        # Les parcelles du SITE restent soumises au contrat commun, entre elles.
        site_codes <- character(0)
        if (nrow(rows_site) > 0) {
          f_common_proprio <- Reduce(intersect, rows_site$contrats_foncier)
          a_common_proprio <- Reduce(intersect, rows_site$contrats_agricole)
          if (length(f_common_proprio) > 0 || length(a_common_proprio) > 0) {
            site_codes <- rows_site$code
          }
        }
        
        if (length(peri_codes) == 0 && length(site_codes) == 0) {
          showToast("warning", "Contrat manquant", 
                    "Aucune des parcelles de ce propriétaire n'a de contrat commun avec les autres. Sélection impossible.")
          return()
        }
        if (nrow(rows_site) > 0 && length(site_codes) == 0) {
          showToast("info", "Sélection partielle",
                    sprintf(paste("%d parcelle(s) de la continuité du site conservatoire sélectionnée(s).",
                                  "%d parcelle(s) du site écartée(s) : elles ne partagent pas de contrat commun."),
                            length(peri_codes), nrow(rows_site)))
        }
        
        new_sel <- unique(c(current_sel, peri_codes, site_codes))
        
      } else {
        # CAS 2: Sélection non vide. Valider progressivement.
        
        # Itération sur les nouvelles parcelles du propriétaire
        for (code in codes_to_add) {
          if (.af_has_common_contrat(code, new_sel)) { # Utilise 'new_sel' comme référence progressive
            new_sel <- c(new_sel, code)
          }
        }
        
        if (length(new_sel) == length(current_sel)) {
          showToast("warning", "Contrat commun requis",
                    "Aucune parcelle du propriétaire n'a pu être ajoutée car elles ne partagent pas de contrat commun avec la sélection existante.")
          return()
        }
      }
      
      # --- Mise à jour finale ---
      af_new_selected(unique(new_sel))
      
      # Redessinage (le code est déjà dans l'observeEvent du toggle, mais on le force ici pour clarté)
      site_sf <- af_new_site_sf(); req(site_sf)
      idx <- which(site_sf$code %in% new_sel)
      sel_sf <- site_sf[idx, , drop = FALSE]
      
      leafletProxy(ns("af_new_map")) %>% clearGroup("Sélection action")
      if (nrow(sel_sf) > 0) {
        sel_sf <- sf::st_as_sf(sel_sf)
        invalid <- which(!sf::st_is_valid(sel_sf))
        if (length(invalid)) sel_sf[invalid, "geom"] <- sf::st_make_valid(sel_sf[invalid, ])
        sel_sf <- sf::st_transform(sel_sf, 4326)
        
        leafletProxy(ns("af_new_map")) %>%
          addPolygons(
            data = sel_sf,
            group = "Sélection action",
            color = "red", weight = 2, fillOpacity = 0.5,
            label = .cf_make_labels(sel_sf, user_roles()),
            labelOptions = labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("sel-", code),
            options = pathOptions(pane = "af_sel")
          )
      }
      
      # Réinitialiser le sélecteur pour permettre une nouvelle sélection
      updateSelectInput(session, "af_proprio_selector", selected = "")
    })
    
    # --- Compteur sélection
    output$af_new_count <- renderUI({
      n <- length(af_new_selected())
      tags$p(HTML(paste0("Parcelles sélectionnées : <b>", n, "</b>")))
    })
    
    # --- Passage à l'étape 2 (formulaire)
    observeEvent(input$af_next, {
      if (length(af_new_selected()) == 0) {
        showToast("warning", "Sélection vide", "Sélectionne au moins une parcelle.")
        return()
      }
      removeModal()
      
      contrats_site <- safe_db_query(con, glue::glue("
            SELECT DISTINCT cf.id, cf.nom
            FROM gestcons.contrats_fonciers cf
            JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.contrat_id = cf.id
            JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id
            WHERE p.site_id = {af_site_id()}
            ORDER BY cf.nom
          "))
      
      acteurs_df <- safe_db_query(con, "
            SELECT id, trim(coalesce(nullif(prenom,''),'') || ' ' || coalesce(nullif(nom,''),'')) AS label
            FROM gestcons.dico_acteurs_fonciers_agricoles
            ORDER BY nom, prenom
          ")
      acteurs_choices <- if (nrow(acteurs_df)) setNames(acteurs_df$id, acteurs_df$label) else c()
      
      utilisateurs_choices <- .af_fetch_utilisateurs_choices()
      
      # Parcelles sélectionnées -> ids de parcelles
      parc_ids <- .af_codes_to_parcelle_ids(af_site_id(), af_new_selected())
      #mix <- .af_build_mixed_contrat_choices(parc_ids) # <-- MAINTENANT, retourne UNIQUEMENT les communs
      
      showModal(modalDialog(
        title = "Étape 2/2 — Détails de l'action",
        size = "l", easyClose = FALSE,   # assistant : un clic à côté perdrait la saisie
        footer = tagList(
          modalButton("Annuler"),
          # Rendu ACTIF : les champs obligatoires ont toujours une valeur par
          # défaut (date du jour, 1er type du dico). Le rendre disabled créait
          # une course avec shinyjs (désactivation différée après le bind,
          # écrasant toute réactivation) -> bouton grisé aux ouvertures
          # suivantes, faute d'événement input. L'observer toggle_submit_state
          # le désactive si l'utilisateur vide un champ.
          actionButton(ns("af_create"), "Créer l'action", class = "btn-primary")
        ),
        fluidPage(
          dateInput(ns("af_form_date"), "📆 Date de l'action *", value = Sys.Date()),
          radioButtons(
            ns("af_form_domaine"),
            label = "Domaine de l'action :",
            choices = c("Foncier" = "F", "Agricole" = "A"),
            selected = "F",
            inline = TRUE
          ),
          selectInput(
            ns("af_form_type"), "Type d'action *",
            choices = setNames(dico_type_action_animation$id, dico_type_action_animation$libelle)
          ),
          # ⬇️ ⬇️ NOUVEAU : multi-sélecteur d'acteurs
          
          selectizeInput(
            ns("af_form_acteurs"),
            "Acteurs concernés",
            choices = acteurs_choices,
            multiple = TRUE,
            options = list(
              placeholder = "Sélectionnez un ou plusieurs acteurs…", 
              plugins = list("remove_button")
            )
          ),
          selectizeInput(
            ns("af_form_utilisateurs"),
            "Utilisateurs (CEN) impliqués",
            choices = utilisateurs_choices,
            multiple = TRUE,
            options = list(
              placeholder = "Sélectionnez un ou plusieurs utilisateurs…",
              plugins = list("remove_button")
            )
          ),
          tags$textarea(
            id    = ns("af_form_description"),
            class = "form-control summernote",
            rows  = 8,
            placeholder = "Saisissez le compte-rendu (mise en forme, listes, liens, …)"
          ),
          # Documents dans la MÊME modale que les détails (la troisième étape
          # a disparu) : la pièce jointe part avec l'action, comme en édition.
          # Rien à lister ni à supprimer, l'action n'existe pas encore.
          .af_docs_section(is_editor = TRUE, existing = FALSE,
                           save_label = "Créer l'action")
        )
      ))
      # Vide le Summernote de création au moment de l’ouverture
      session$sendCustomMessage("clearSummernote", list(
        id = ns("af_form_description")
      ))
      # Uploader vierge : sans ce nonce, le fichier resté sélectionné lors d'une
      # édition précédente serait joint à la nouvelle action.
      af_docs_anim_id(NULL)
      af_doc_uploader_nonce(isolate(af_doc_uploader_nonce()) + 1)
      
    })
    
    # --- Création effective
    # --- Création effective (remplacement complet) ---
    # --- Création effective (COMPLET, version corrigée avec type_action_id côté agricole) ---
    # R/mod_actions.R (Lignes 2108-2200 environ - Remplacer le bloc existant)
    
    # Boutons « Enregistrer » désactivés tant que les champs obligatoires (*) ne
    # sont pas remplis (les 3 formulaires d'action + l'ajout de document).
    observe({
      toggle_submit_state(input, "af_create",   c("af_form_date", "af_form_type"))
      toggle_submit_state(input, "af_save",      c("af_edit_date", "af_edit_type"))
      toggle_submit_state(input, "ag_edit_save", c("ag_edit_date", "ag_edit_type"))
      # Supprimer un document : actif seulement si une ligne est sélectionnée
      # (donc jamais actif sur une liste vide).
      shinyjs::toggleState("af_doc_delete",
                           condition = length(input$af_docs_table_rows_selected) == 1)
    })

    # --- Écritures animations : helpers communs foncier/agricole -------------
    # Tables cibles par domaine ("F" = foncier, "A" = agricole)
    .af_tables <- function(domaine) {
      if (identical(domaine, "A")) list(
        anim = "gestcons.animation_contrat_agricole",
        parc = "gestcons.animation_contrat_agricole_parcelles",
        act  = "gestcons.animation_contrat_agricole_acteurs",
        usr  = NULL,                                   # pas d'utilisateurs côté agricole
        lib  = "agricole"
      ) else list(
        anim = "gestcons.animation_fonciere",
        parc = "gestcons.animation_fonciere_parcelles",
        act  = "gestcons.animation_fonciere_acteurs",
        usr  = "gestcons.animation_fonciere_utilisateur",
        lib  = "foncière"
      )
    }

    # (Ré)écrit une table de liaison (animation_id, <col>) : DELETE puis INSERT.
    # Motif auparavant recopié 5× (créations F/A, éditions F/A).
    .af_rewrite_links <- function(conn, table, col, anim_id, ids, delete_first = TRUE) {
      if (delete_first) {
        safe_db_execute(conn, glue::glue("DELETE FROM {table} WHERE animation_id = {anim_id}"))
      }
      ids <- if (is.null(ids)) integer(0) else as.integer(ids)
      if (length(ids) > 0) {
        values_sql <- paste(sprintf("(%d, %d)", anim_id, ids), collapse = ",")
        safe_db_execute(conn, glue::glue("
          INSERT INTO {table} (animation_id, {col})
          VALUES {values_sql}
          ON CONFLICT DO NOTHING
        "))
      }
      invisible(NULL)
    }

    # Création d'une animation + liaisons, en une transaction. Les deux branches
    # de af_create (~130 lignes en miroir) ne différaient que par les tables.
    .af_insert_animation <- function(domaine, type_id, date_txt, desc_html,
                                     parc_ids, sel_acteurs, sel_users, user_db_val) {
      t <- .af_tables(domaine)
      anim_id <- NULL
      pool::poolWithTransaction(con, function(conn) {
        q_anim <- glue::glue_sql("
          INSERT INTO {tbl}
            (type_action_id, date, description,
             cree_par, date_creation, modifie_par, date_modification)
          VALUES (
            {type_id}, {date_txt}, {desc_html},
            {user_db_val}, NOW(),
            {user_db_val}, NOW()
          )
          RETURNING id
        ", tbl = DBI::SQL(t$anim), .con = conn)
        anim_id <<- safe_db_insert(conn, q_anim)
        if (is.null(anim_id)) stop(paste0("Insertion de l'action ", t$lib, " échouée."))

        .af_rewrite_links(conn, t$parc, "parcelle_id", anim_id, parc_ids,    delete_first = FALSE)
        .af_rewrite_links(conn, t$act,  "acteur_id",   anim_id, sel_acteurs, delete_first = FALSE)
        if (!is.null(t$usr)) {
          .af_rewrite_links(conn, t$usr, "utilisateur_id", anim_id, sel_users, delete_first = FALSE)
        }
      })
      anim_id
    }

    observeEvent(input$af_create, {
      shinybusy::show_modal_spinner(spin="circle", color = COULEUR_SPINNER, text="💾 Sauvegarde en cours...")
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
      
      req(af_site_id(), input$af_form_type, input$af_form_domaine) # 💡 AJOUT REQ DOMAINE
      
      # 1) Description (Summernote) nettoyée
      desc_html <- input$af_form_description
      if (is.null(desc_html) || is.na(desc_html)) desc_html <- ""
      desc_html <- gsub("&nbsp;?", " ", desc_html, perl = TRUE)
      
      # 2) Acteurs / Utilisateurs sélectionnés
      sel_acteurs <- input$af_form_acteurs
      sel_acteurs <- if (is.null(sel_acteurs)) integer(0) else as.integer(sel_acteurs)
      
      sel_users <- input$af_form_utilisateurs
      sel_users <- if (is.null(sel_users)) integer(0) else as.integer(sel_users)
      
      # 3) Parcelles sélectionnées -> ids
      parc_ids <- .af_codes_to_parcelle_ids(af_site_id(), af_new_selected())
      
      # 4) Détermination du domaine cible
      domaine_cible <- input$af_form_domaine
      user_db_val <- user_to_db()
      
      # =======================================================
      # Création (foncier OU agricole) — helper commun
      # =======================================================
      t_lib <- .af_tables(domaine_cible)$lib
      anim_id <- tryCatch(
        .af_insert_animation(
          domaine     = domaine_cible,
          type_id     = as.integer(input$af_form_type),
          date_txt    = as.character(input$af_form_date),
          desc_html   = desc_html,
          parc_ids    = parc_ids,
          sel_acteurs = sel_acteurs,
          sel_users   = sel_users,
          user_db_val = user_db_val
        ),
        error = function(e) {
          showToast("error", "Erreur",
                    paste0("Impossible de créer l'action ", t_lib, " : ", e$message))
          NULL
        }
      )
      if (is.null(anim_id)) return()

      showToast("success", paste("Action", t_lib, "créée"), "✅ L'action a été ajoutée.")
      log_action(session, current_user_rv,
                 paste0("Création d'une action ", t_lib, " (id ", anim_id, ")"))

      # Pièce jointe éventuellement chargée dans la section 📎 de la même
      # modale : elle s'enregistre maintenant que l'action a un id — c'est ce
      # que fait déjà « 💾 Enregistrer » en édition. Sans fichier choisi,
      # l'appel ne fait rien.
      # ⚠️ af_docs_kind doit refléter le domaine créé : les écritures de
      # documents lisent cette valeur — sans ça, une valeur périmée d'un 📎
      # consulté auparavant enverrait la PJ dans la table de l'autre domaine.
      af_docs_kind(domaine_cible)
      af_docs_anim_id(anim_id)
      .af_upload_pending_doc()

      removeModal()
      af_new_selected(character(0))
      af_new_site_sf(NULL)
      af_table_reload(isolate(af_table_reload()) + 1)
    })
    
    # --- Annuler la création
    observeEvent(input$af_cancel, {
      af_new_selected(character(0))
      removeModal()
      session$sendCustomMessage('af-reset-click', ns('af_new_map'))
    })
    
    # --- Clic sur ✏️ : ouvrir le formulaire d'édition FONCIER ou AGRICOLE ---
    observeEvent(input$af_row_click, {
      debug_print("============observeEvent(input$af_row_click")
      
      # --- Helper : Formatage Lecture Seule (Champ : Valeur) ---
      format_read_only_data <- function(det, acteurs_df, pre_sel_ids, utilisateurs_df, pre_user_ids, kind) {
        req(nrow(det) == 1)
        
        # 1. Type d'action
        type_action_lib <- dico_type_action_animation$libelle[dico_type_action_animation$id == det$type_action_id[1]] %||% "Non spécifié"
        
        # 2. Acteurs (libellés)
        acteurs_noms <- acteurs_df$label[acteurs_df$id %in% pre_sel_ids]
        acteurs_aff <- if (length(acteurs_noms) > 0) paste(sort(acteurs_noms), collapse = ", ") else "Aucun acteur concerné"
        
        # 3. Utilisateurs (libellés, uniquement pour Foncier)
        utilisateurs_aff <- "N/A (Action Agricole)"
        if (identical(kind, "F")) {
          users_noms <- utilisateurs_df$label[utilisateurs_df$id %in% pre_user_ids]
          utilisateurs_aff <- if (length(users_noms) > 0) paste(sort(users_noms), collapse = ", ") else "Aucun utilisateur CEN impliqué"
        }
        
        # 4. Description (HTML)
        # Saisie libre, Summernote offrant un bouton « codeview » : assainie
        # avant d'être réinjectée en HTML. Cf. assainir_html() (helpers.R).
        description_html <- assainir_html(det$description[1])
        if (!nzchar(description_html)) description_html <- "(Aucune description fournie)"
        
        tagList(
          tags$p(tags$strong("📆 Date : "), as.character(det$date[1])),
          tags$p(tags$strong("🎯 Type d’action : "), type_action_lib),
          tags$p(tags$strong("👥 Acteurs : "), htmltools::htmlEscape(acteurs_aff)),
          if (identical(kind, "F")) {
            tags$p(tags$strong("👤 Utilisateurs (CEN) : "), htmltools::htmlEscape(utilisateurs_aff))
          },
          tags$hr(),
          tags$h5("📝 Description :"),
          # La description est déjà en HTML, on l'affiche directement
          tags$div(class = "well well-sm tc-bloc-lecture", HTML(description_html))
        )
      }
      
      # mode = 'view' (clic sur 👁) : consultation forcée, même pour un éditeur
      mode_view <- identical(isolate(input$af_row_click$mode), "view")
      is_editor <- isTRUE(is_editor_on_site_rv()) && !mode_view
      af_view_last_id(isolate(input$af_row_click$id))
      
      req(input$af_row_click, af_site_id())
      raw_id <- as.character(input$af_row_click$id)
      req(nzchar(raw_id))
      
      if (grepl("^F:", raw_id)) {
        # ====== ÉDITION FONCIÈRE ======
        anim_id <- as.integer(sub("^F:", "", raw_id))
        af_edit_id(anim_id)
        
        det <- safe_db_query(con, glue::glue("
              SELECT id, type_action_id, date, description
              FROM gestcons.animation_fonciere
              WHERE id = {anim_id}
            "))
        if (nrow(det) == 0) {
          showToast("error", "Introuvable", paste0("Aucune action foncière #", anim_id))
          return()
        }
        
        # Parcelles de l'action foncière -> liste de contrats fonciers proposés
        pid_df <- safe_db_query(con, glue::glue("
              SELECT parcelle_id
              FROM gestcons.animation_fonciere_parcelles
              WHERE animation_id = {anim_id}
            "))
        parc_ids <- if (nrow(pid_df)) as.integer(pid_df$parcelle_id) else integer(0)
        
        # Construit la liste mixte puis filtre F: uniquement
        
        pre_val <- ""
        
        # Acteurs (liste + présélection)
        acteurs_df <- safe_db_query(con, "
              SELECT id, trim(coalesce(nullif(prenom,''),'') || ' ' || coalesce(nullif(nom,''),'')) AS label
              FROM gestcons.dico_acteurs_fonciers_agricoles
              ORDER BY nom, prenom
            ")
        acteurs_choices <- if (nrow(acteurs_df)) setNames(acteurs_df$id, acteurs_df$label) else c()
        
        pre_sel <- safe_db_query(con, glue::glue("
              SELECT acteur_id FROM gestcons.animation_fonciere_acteurs
              WHERE animation_id = {anim_id}
            "))
        pre_sel_ids <- if (nrow(pre_sel)) pre_sel$acteur_id else integer(0)
        
        # Utilisateurs (liste + présélection)
        utilisateurs_choices <- .af_fetch_utilisateurs_choices()
        # Le libellé est fabriqué ici, comme dans le tableau et le rapport PDF.
        # La fiche 👁 lit `label` ; `dico_utilisateur()` nomme cette colonne
        # `nom_complet`, si bien qu'elle n'affichait jamais personne. La
        # jointure externe montre aussi les utilisateurs devenus inactifs, que
        # le menu d'édition n'a plus dans ses choix.
        pre_users <- safe_db_query(con, glue::glue("
              SELECT afu.utilisateur_id,
                     COALESCE(
                       NULLIF(trim(concat_ws(' ', NULLIF(u.prenom,''), NULLIF(u.nom,''))), ''),
                       NULLIF(u.email,''),
                       'Utilisateur #'||afu.utilisateur_id::text
                     ) AS label
              FROM gestcons.animation_fonciere_utilisateur afu
              LEFT JOIN gestcons.dico_utilisateur u ON u.id = afu.utilisateur_id
              WHERE afu.animation_id = {anim_id}
              ORDER BY u.nom, u.prenom, u.email
            "))
        pre_user_ids <- if (nrow(pre_users)) pre_users$utilisateur_id else integer(0)
        
        utilisateurs_df <- if (nrow(pre_users)) {
          data.frame(id = pre_users$utilisateur_id, label = pre_users$label,
                     stringsAsFactors = FALSE)
        } else {
          data.frame(id = integer(0), label = character(0), stringsAsFactors = FALSE)
        }

        # Alimente la section 📎 Documents embarquée dans la modale
        af_docs_kind("F")
        af_docs_anim_id(anim_id)
        af_doc_uploader_nonce(isolate(af_doc_uploader_nonce()) + 1)
        af_docs_reload(isolate(af_docs_reload()) + 1)

        showModal(modalDialog(
          title = paste0(if(is_editor) "✏️ Modifier l’action foncière #" else "👁️ Détails de l’action foncière #", anim_id),
          size = "l", easyClose = TRUE,
          footer = if (is_editor) {
            tagList(
              actionButton(ns("af_delete"), "🗑 Supprimer", class = "btn-danger"),
              actionButton(ns("af_save"), "💾 Enregistrer", class = "btn-primary")  # actif : champs pré-remplis (cf. af_create)
            )
          } else {
            tagList(
              # Bascule consultation -> édition, seulement si l'utilisateur a
              # les droits sur le site (donc si la fiche a été ouverte par 👁).
              if (isTRUE(is_editor_on_site_rv()))
                actionButton(ns("af_view_edit"), "✏️ Modifier", class = "btn-primary"),
              downloadButton(ns("af_download_pdf"), "⬇️ Exporter en PDF", class = "btn-info")
            )
          },
          fluidPage(
            # 💡 NOUVEAU : Affichage conditionnel
            if (is_editor) {
              # --- CONTENU ÉDITEUR (FORMULAIRE) ---
              tagList(
                dateInput(ns("af_edit_date"), "📆 Date *", value = as.Date(det$date[1])),
                selectInput(
                  ns("af_edit_type"), "Type d’action *",
                  choices = setNames(dico_type_action_animation$id, dico_type_action_animation$libelle),
                  selected = det$type_action_id[1]
                ),
                selectizeInput(
                  ns("af_edit_acteurs"),
                  "Acteurs fonciers",
                  choices = acteurs_choices,
                  selected = pre_sel_ids,
                  multiple = TRUE,
                  options = list(placeholder = "Sélectionnez…", plugins = list("remove_button"))
                ),
                selectizeInput(
                  ns("af_edit_utilisateurs"),
                  "Utilisateurs (CEN) impliqués",
                  choices = utilisateurs_choices,
                  selected = pre_user_ids,
                  multiple = TRUE,
                  options = list(placeholder = "Sélectionnez…", plugins = list("remove_button"))
                ),
                tags$label(`for` = ns("af_edit_description"), "Description"),
                tags$textarea(
                  id    = ns("af_edit_description"),
                  class = "form-control summernote",
                  rows  = 8
                )
              )
            } else {
              # --- CONTENU LECTURE SEULE ---
              format_read_only_data(det, acteurs_df, pre_sel_ids, utilisateurs_df, pre_user_ids, kind = "F")
            },
            # 📎 Gestion des documents intégrée à la modale de l'action
            .af_docs_section(is_editor)
          )
        ))
        # pré-remplissage Summernote (seulement si is_editor est VRAI)
        if (is_editor) {
          desc_html <- det$description[1]; if (is.na(desc_html)) desc_html <- ""
          session$sendCustomMessage("setSummernoteContent", list(
            id = ns("af_edit_description"),
            value = as.character(desc_html)
          ))
        }
      } else if (grepl("^A:", raw_id)) {
        # ====== ÉDITION AGRICOLE ======
        ag_id <- as.integer(sub("^A:", "", raw_id))
        
        det <- safe_db_query(con, glue::glue("
              SELECT id, type_action_id, date, description
              FROM gestcons.animation_contrat_agricole
              WHERE id = {ag_id}
            "))
        if (nrow(det) == 0) {
          showToast("error", "Introuvable", paste0("Aucune action agricole #", ag_id))
          return()
        }
        
        
        # Parcelles de l'action agricole -> liste de contrats agricoles proposés
        pid_df <- safe_db_query(con, glue::glue("
              SELECT parcelle_id
              FROM gestcons.animation_contrat_agricole_parcelles
              WHERE animation_id = {ag_id}
            "))
        parc_ids <- if (nrow(pid_df)) paste(unique(as.integer(pid_df$parcelle_id)), collapse = ",") else ""
        choices_agri <- c()
        if (nzchar(parc_ids)) {
          df_ca <- safe_db_query(con, glue::glue("
                SELECT DISTINCT ca.id, ca.nom
                FROM gestcons.contrats_agricoles ca
                JOIN gestcons.contrats_agricoles_parcelles cap ON cap.contrat_agri_id = ca.id
                WHERE cap.parcelle_id IN ({parc_ids})
                ORDER BY ca.nom
              "))
          if (nrow(df_ca))
            choices_agri <- setNames(paste0("A:", df_ca$id), sprintf("🌾 [Agricole] %s", df_ca$nom))
        }
        pre_val <- ""
        
        # Acteurs (liste + présélection)
        acteurs_df <- safe_db_query(con, "
              SELECT id, trim(coalesce(nullif(prenom,''),'') || ' ' || coalesce(nullif(nom,''),'')) AS label
              FROM gestcons.dico_acteurs_fonciers_agricoles
              ORDER BY nom, prenom
            ")
        acteurs_choices <- if (nrow(acteurs_df)) setNames(acteurs_df$id, acteurs_df$label) else c()
        
        pre_sel <- safe_db_query(con, glue::glue("
              SELECT acteur_id FROM gestcons.animation_contrat_agricole_acteurs
              WHERE animation_id = {ag_id}
            "))
        pre_sel_ids <- if (nrow(pre_sel)) pre_sel$acteur_id else integer(0)
        
        utilisateurs_df <- dico_utilisateur() # Pour le helper (même si non utilisé pour l'Agri)

        # Alimente la section 📎 Documents embarquée dans la modale
        af_docs_kind("A")
        af_docs_anim_id(ag_id)
        af_doc_uploader_nonce(isolate(af_doc_uploader_nonce()) + 1)
        af_docs_reload(isolate(af_docs_reload()) + 1)

        showModal(modalDialog(
          title = paste0(if(is_editor) "✏️ Modifier l’action agricole #" else "👁️ Détails de l’action agricole #", ag_id),
          size  = "l", easyClose = TRUE,
          footer = if (is_editor) {
            tagList(
              actionButton(ns("ag_delete"), "🗑 Supprimer", class = "btn-danger"),
              actionButton(ns("ag_edit_save"), "💾 Enregistrer", class = "btn-primary")  # actif : champs pré-remplis (cf. af_create)
            )
          } else {
            tagList(
              if (isTRUE(is_editor_on_site_rv()))
                actionButton(ns("af_view_edit"), "✏️ Modifier", class = "btn-primary")
            )
          },
          fluidPage(
            # 💡 NOUVEAU : Affichage conditionnel
            if (is_editor) {
              # --- CONTENU ÉDITEUR (FORMULAIRE) ---
              tagList(
                dateInput(ns("ag_edit_date"), "📆 Date *", value = as.Date(det$date[1])),
                selectInput(
                  ns("ag_edit_type"), "Type d’action *",
                  choices = setNames(dico_type_action_animation$id, dico_type_action_animation$libelle),
                  selected = det$type_action_id[1]
                ),
                selectizeInput(
                  ns("ag_edit_acteurs"),
                  "Acteurs agricoles",
                  choices = acteurs_choices,
                  selected = pre_sel_ids,
                  multiple = TRUE,
                  options = list(placeholder = "Sélectionnez…", plugins = list("remove_button"))
                ),
                tags$label(`for` = ns("ag_edit_description"), "Description"),
                tags$textarea(
                  id    = ns("ag_edit_description"),
                  class = "form-control summernote",
                  rows  = 8
                )
              )
            } else {
              # --- CONTENU LECTURE SEULE ---
              format_read_only_data(det, acteurs_df, pre_sel_ids, utilisateurs_df, pre_user_ids, kind = "A")
            },
            # 📎 Gestion des documents intégrée à la modale de l'action
            .af_docs_section(is_editor)
          )
        ))
        # pré-remplissage Summernote (seulement si is_editor est VRAI)
        if (is_editor) {
          desc_html <- det$description[1]; if (is.na(desc_html)) desc_html <- ""
          session$sendCustomMessage("setSummernoteContent", list(
            id = ns("ag_edit_description"),
            value = as.character(desc_html)
          ))
        }
      }
    })
    
    # Enregistrer une action AGRICOLE
    observeEvent(input$ag_edit_save, {
      req(input$ag_edit_date, input$ag_edit_type)
      desc_edit <- input$ag_edit_description
      if (is.null(desc_edit) || is.na(desc_edit)) desc_edit <- ""
      desc_edit <- gsub("&nbsp;?", " ", desc_edit, perl = TRUE)
      
      # Récupération de l'id depuis le titre de la modale n'étant pas fiable, on le re-dérive du dernier clic
      raw_id <- as.character(isolate(input$af_row_click$id))
      ag_id  <- as.integer(sub("^A:", "", raw_id))
      
      user_db_val <- user_to_db()
      
      # Même défaut que l'action foncière : l'UPDATE et la réécriture des
      # acteurs étaient validés séparément, et le bandeau de succès
      # s'affichait quoi qu'il arrive.
      tx_ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          tx_execute(conn, glue::glue_sql("
                UPDATE gestcons.animation_contrat_agricole
                SET type_action_id    = {as.integer(input$ag_edit_type)},
                    date              = {as.character(input$ag_edit_date)},
                    description       = {desc_edit},
                    modifie_par       = {user_db_val},
                    date_modification = NOW()
                WHERE id = {ag_id}
              ", .con = conn))
          # Réécriture ACTEURS (agricole)
          .af_rewrite_links(conn, "gestcons.animation_contrat_agricole_acteurs", "acteur_id",
                            ag_id, input$ag_edit_acteurs)
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Enregistrement impossible", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(tx_ok)) return(invisible(NULL))
      showToast("success", "Action agricole", "✅ Modifications enregistrées.")
      log_action(session, current_user_rv, paste0("Modification de l'action agricole #", ag_id))
      # Enregistre aussi la PJ chargée dans la section Documents, le cas échéant.
      .af_upload_pending_doc()
    })
    
    # Fermer la modale agricole
    # (Rien à faire à la fermeture du modal : af_save et ag_edit_save rechargent
    # déjà le tableau au moment de l'enregistrement, et fermer sans enregistrer
    # ne change rien.)
    
    # --- Suppression d'une action : confirmation obligatoire --------------
    # La confirmation REMPLACE la modale d'édition (Shiny n'empile pas les
    # modales) : « Annuler » la rouvre par le canal du bouton « ✏️ Modifier ».
    # Les saisies non enregistrées sont perdues au passage, le formulaire se
    # rechargeant depuis la base — l'annulation ramène donc à l'état enregistré.
    .af_confirm_delete <- function(quoi, nb_docs, confirm_id) {
      showModal(modalDialog(
        title = "Confirmer la suppression",
        easyClose = TRUE,
        footer = tagList(
          actionButton(ns("af_delete_cancel"), "Annuler"),
          actionButton(ns(confirm_id), "🗑 Confirmer la suppression", class = "btn btn-danger")
        ),
        tags$p(htmltools::HTML(sprintf("Supprimer définitivement %s ?", quoi))),
        if (nb_docs > 0) {
          tags$p(sprintf("%d document(s) joint(s) seront supprimé(s), fichiers compris.", nb_docs))
        },
        tags$p(tags$strong("Cette opération est irréversible."))
      ))
    }

    observeEvent(input$af_delete, {
      anim_id <- af_edit_id(); req(anim_id)
      nb_docs <- nrow(docs_fetch(con, "gestcons.docs_animation_fonciere", "animation_id", anim_id))
      .af_confirm_delete(
        quoi       = sprintf("l'action foncière <strong>n°%d</strong>", anim_id),
        nb_docs    = nb_docs,
        confirm_id = "af_delete_confirm"
      )
    })

    observeEvent(input$ag_delete, {
      raw_id <- as.character(isolate(input$af_row_click$id))
      req(nzchar(raw_id))
      ag_id <- suppressWarnings(as.integer(sub("^A:", "", raw_id)))
      req(!is.na(ag_id))
      nb_docs <- nrow(docs_fetch(con, "gestcons.docs_animation_agricole", "animation_id", ag_id))
      .af_confirm_delete(
        quoi       = sprintf("l'action agricole <strong>n°%d</strong>", ag_id),
        nb_docs    = nb_docs,
        confirm_id = "ag_delete_confirm"
      )
    })

    # Annulation : retour à la fiche d'édition, par le même canal que le bouton
    # « ✏️ Modifier » de la fiche de consultation.
    observeEvent(input$af_delete_cancel, {
      raw <- af_view_last_id(); req(raw)
      removeModal()
      shinyjs::runjs(sprintf(
        "Shiny.setInputValue('%s', {id: '%s', mode: 'edit', nonce: Date.now()}, {priority:'event'});",
        session$ns("af_row_click"), raw))
    })

    # Supprimer une action AGRICOLE (après confirmation)
        #' Suppression d'une action, foncière ou agricole.
    #'
    #' ⚠️ UNE transaction pour toutes les lignes, les fichiers ENSUITE. Avant,
    #' trois DELETE partaient sur le pool, chacun pour soi, et safe_db_execute
    #' avalait l'erreur : un échec en route laissait l'action à moitié
    #' supprimée — ses fichiers, effacés en premier, déjà perdus — sous un toast
    #' de succès inconditionnel. Désormais rien ne bouge sur le disque tant que
    #' la base n'a pas tout accepté, et un échec annule tout en le disant. Un
    #' fichier qui résisterait à l'effacement après coup resterait orphelin sur
    #' le disque, ce qui ne trompe personne ; l'inverse — une ligne pointant
    #' vers un fichier disparu — si.
    #'
    #' Les documents sont lus AVANT la transaction, pour garder leurs chemins.
    #' Fichier par fichier, jamais le dossier : animation_{id} est PARTAGÉ entre
    #' foncier et agricole, une action de l'autre domaine et de même
    #' identifiant numérique pouvant y avoir les siens. Documents, acteurs et
    #' utilisateurs suivent aussi l'action en cascade ; ils sont supprimés
    #' explicitement pour que la liste se lise ici.
    .supprimer_action <- function(id, table, liens, docs_table) {
      docs <- docs_fetch(con, docs_table, "animation_id", id)
      chemins <- if (nrow(docs) > 0) {
        unname(mapply(function(u, f) docs_chemin(docs_root, u, f),
                      docs$url, docs$nom_fichier))
      } else character(0)
      ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          tx_execute(conn, glue::glue("DELETE FROM {docs_table} WHERE animation_id = {id}"))
          for (t in liens) {
            tx_execute(conn, glue::glue("DELETE FROM {t} WHERE animation_id = {id}"))
          }
          n <- tx_execute(conn, glue::glue("DELETE FROM {table} WHERE id = {id}"))
          if (!identical(as.integer(n), 1L)) {
            stop("cette action n'existe plus ; la liste est rafraîchie.")
          }
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Suppression impossible", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(ok)) return(FALSE)
      for (chemin in chemins[!is.na(chemins)]) {
        if (file.exists(chemin)) try(unlink(chemin, force = TRUE), silent = TRUE)
      }
      TRUE
    }

    observeEvent(input$ag_delete_confirm, {
      shinybusy::show_modal_spinner(spin = "circle", color = COULEUR_SPINNER,
                                    text = "💾 Suppression en cours...")
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)

      raw_id <- as.character(isolate(input$af_row_click$id))
      ag_id  <- suppressWarnings(as.integer(sub("^A:", "", raw_id)))
      if (length(ag_id) != 1 || is.na(ag_id)) return(invisible(NULL))

      ok <- .supprimer_action(
        id = ag_id, table = "gestcons.animation_contrat_agricole",
        liens = c("gestcons.animation_contrat_agricole_parcelles",
                  "gestcons.animation_contrat_agricole_acteurs"),
        docs_table = "gestcons.docs_animation_agricole")
      # La liste est rafraîchie dans les deux cas : un échec peut tenir à une
      # action déjà supprimée ailleurs.
      removeModal()
      af_table_reload(isolate(af_table_reload()) + 1)
      if (!isTRUE(ok)) return(invisible(NULL))
      showToast("warning", "Action supprimée", "🗑 Action agricole supprimée.")
      log_action(session, current_user_rv, paste0("Suppression de l'action agricole #", ag_id))
    })
    
    
    
    # --- Enregistrer les modifications
    # --- Enregistrer les modifications
    observeEvent(input$af_save, {
      # ⛔️ supprime le spinner modal qui ferme la modale principale
      # shinybusy::show_modal_spinner(spin="circle", color = COULEUR_SPINNER, text="💾 Sauvegarde en cours...")
      # on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
      
      tx_ok <- withProgress(message = "💾 Sauvegarde en cours...", value = 0, {
        req(af_edit_id())
        
        # --- Description (Summernote) : préparer avant glue() ---
        desc_edit <- input$af_edit_description
        if (is.null(desc_edit) || is.na(desc_edit)) desc_edit <- ""
        desc_edit <- gsub("&nbsp;?", " ", desc_edit, perl = TRUE)
        
        user_db_val <- user_to_db()
        
        # Les trois écritures — l'action, ses utilisateurs, ses acteurs — étaient
        # validées séparément sur le pool. Un échec sur la seconde laissait
        # l'action modifiée et ses liaisons à moitié réécrites, le DELETE étant
        # acquis et l'INSERT perdu, pendant que le bandeau annonçait un succès.
        # .af_rewrite_links prend déjà une connexion en argument : il suffit de
        # lui passer celle de la transaction.
        tryCatch({
          pool::poolWithTransaction(con, function(conn) {
            q <- glue::glue_sql("
                  UPDATE gestcons.animation_fonciere
                  SET type_action_id    = {as.integer(input$af_edit_type)},
                      date              = {as.character(input$af_edit_date)},
                      description       = {desc_edit},
                      modifie_par       = {user_db_val},
                      date_modification = NOW()
                  WHERE id = {af_edit_id()}
                ", .con = conn)
            tx_execute(conn, q); incProgress(0.4)
        
            # Réécriture UTILISATEURS
            .af_rewrite_links(conn, "gestcons.animation_fonciere_utilisateur", "utilisateur_id",
                              af_edit_id(), input$af_edit_utilisateurs)
            incProgress(0.3)
        
            # Réécriture ACTEURS
            .af_rewrite_links(conn, "gestcons.animation_fonciere_acteurs", "acteur_id",
                              af_edit_id(), input$af_edit_acteurs)
            incProgress(0.3)
          })
          TRUE
        }, error = function(e) {
          showToast("error", "Enregistrement impossible", conditionMessage(e))
          FALSE
        })
      })
      if (!isTRUE(tx_ok)) return(invisible(NULL))
      
      # ❗️Ne pas fermer la modale ici
      showToast("success", "Action mise à jour", "✅ Modifications enregistrées.")
      log_action(session, current_user_rv, paste0("Modification de l'action foncière #", af_edit_id()))
      # Enregistre aussi la PJ chargée dans la section Documents, le cas échéant.
      .af_upload_pending_doc()
    })
    
    
    # --- Gérer la fermeture du modal

    
    # Ajoutez cet événement pour rafraîchir le tableau quand la modale se ferme
    # L'événement "af_edit_id" est remis à NULL quand la modale est fermée.
    # On détecte ce changement pour recharger la table.
    observeEvent(af_edit_id(), {
      if (is.null(af_edit_id())) {
        af_table_reload(isolate(af_table_reload()) + 1)
      }
    }, ignoreInit = TRUE)
    
    # --- Supprimer l’animation FONCIÈRE (après confirmation)
        observeEvent(input$af_delete_confirm, {
      shinybusy::show_modal_spinner(
        spin  = "circle",           # ← style local, différent du global
        color = COULEUR_SPINNER,
        text  = "💾 Suppression en cours..."
      )
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
      req(af_edit_id())
      anim_id <- suppressWarnings(as.integer(af_edit_id()))
      if (length(anim_id) != 1 || is.na(anim_id)) return(invisible(NULL))

      ok <- .supprimer_action(
        id = anim_id, table = "gestcons.animation_fonciere",
        liens = c("gestcons.animation_fonciere_parcelles",
                  "gestcons.animation_fonciere_utilisateur",
                  "gestcons.animation_fonciere_acteurs"),
        docs_table = "gestcons.docs_animation_fonciere")
      removeModal()
      af_table_reload(isolate(af_table_reload()) + 1)
      if (!isTRUE(ok)) return(invisible(NULL))
      showToast("warning", "Action supprimée",
                "🗑 Action, documents et liens supprimés.")
      log_action(session, current_user_rv, paste0("Suppression de l'action foncière #", anim_id))
    })
    
    # --- Gestion des documents
    output$af_doc_uploader <- renderUI({
      af_doc_uploader_nonce()
      fileInput(ns("af_doc_file"), "Sélectionner un fichier *", accept = DOCS_FILE_ACCEPT)
    })
    
    # Pièces jointes : composant commun (helpers.R) paramétré par la table
    .af_doc_table <- function() {
      kind <- isolate(af_docs_kind()) %||% "F"
      if (identical(kind, "A")) "gestcons.docs_animation_agricole" else "gestcons.docs_animation_fonciere"
    }

    .af_fetch_docs <- function(anim_id) {
      docs_fetch(con, .af_doc_table(), "animation_id", anim_id)
    }
    
    
    # Section « 📎 Documents » embarquée dans la modale d'édition d'une action
    # (remplace l'ancienne modale dédiée ouverte par le lien 📎 du tableau).
    # Réutilise les composants existants (af_docs_table, af_doc_uploader,
    # observer af_doc_delete), pilotés par af_docs_anim_id /
    # af_docs_kind — à renseigner AVANT d'ouvrir la modale.
    # `existing` : à la création, l'action n'a pas encore d'id — ni documents
    # déjà joints, ni suppression possible ; seul l'ajout a un sens.
    # `save_label` nomme le bouton qui enregistrera la pièce jointe.
    .af_docs_section <- function(is_editor, existing = TRUE, save_label = "Enregistrer") {
      tagList(
        tags$hr(),
        tags$h4("📎 Documents"),
        if (existing) DT::DTOutput(ns("af_docs_table")),
        if (is_editor) {
          tagList(
            if (existing) {
              tagList(
                shinyjs::disabled(actionButton(ns("af_doc_delete"), "🗑 Supprimer le document sélectionné", class = "btn btn-danger")),
                tags$hr()
              )
            },
            # Pas de bouton dédié : le fichier chargé ici est enregistré par le
            # bouton d'enregistrement de l'action (infos + PJ en un seul clic).
            tags$h5("Joindre un fichier"),
            uiOutput(ns("af_doc_uploader")),
            textInput(ns("af_doc_type"), "Type de document (ex. Convention, Compte-rendu, Photo)", ""),
            textAreaInput(ns("af_doc_remarque"), "Remarque", "", height = "70px"),
            tags$p(class = "text-muted", style = "font-size:.9em;",
                   sprintf("La pièce jointe sera enregistrée avec l'action via « %s ».", save_label))
          )
        }
      )
    }

    # Enregistre la pièce jointe chargée dans le fileInput, si présente.
    # Appelée à l'enregistrement de l'action (création comme édition) : la PJ
    # est optionnelle, l'absence de fichier n'est donc pas une erreur.
    # Renvoie TRUE si un fichier a été enregistré.
    .af_upload_pending_doc <- function() {
      if (!isTruthy(af_docs_anim_id())) return(FALSE)
      file <- input$af_doc_file
      if (is.null(file) || isTRUE(is.na(file$datapath)) || !file.exists(file$datapath)) {
        return(FALSE)
      }
      anim_id <- af_docs_anim_id()
      kind    <- isolate(af_docs_kind()) %||% "F"
      ok <- tryCatch({
        docs_add(con, docs_root, .af_doc_table(), "animation_id", anim_id,
                 subdir = sprintf("animation_%s_%d", kind, anim_id),
                 file = file, type = input$af_doc_type, remarque = input$af_doc_remarque)
        TRUE
      }, error = function(e) {
        showToast("error", "Échec upload", conditionMessage(e))
        FALSE
      })
      if (!ok) return(FALSE)
      log_action(session, current_user_rv,
                 paste0("Action ", kind, " #", anim_id, " : pièce jointe ajoutée"))
      showToast("success", "Document enregistré", "📎 Pièce jointe ajoutée à l'action.")
      af_docs_reload(isolate(af_docs_reload()) + 1)
      af_table_reload(isolate(af_table_reload()) + 1)
      af_doc_uploader_nonce(isolate(af_doc_uploader_nonce()) + 1)
      # Pas de ns() ici : `session` est déjà celle du module, le double
      # préfixe visait un input inexistant et les champs n'étaient pas vidés.
      updateTextInput(session, "af_doc_type", value = "")
      updateTextAreaInput(session, "af_doc_remarque", value = "")
      TRUE
    }

    show_help_animation_modal <- function(anim_id, step3 = FALSE) {
      showModal(modalDialog(
        title = "En savoir plus...",
        size = "l", easyClose = TRUE,
        footer = NULL,   # fermeture par la croix de l'en-tête
        fluidPage(
          h5("Ce module vous permet de gérer les actions foncières et agricoles pour les sites conservatoires que vous gérez."),
          h5("Une fois le site sélectionné, la carte affiche ses parcelles et le tableau, sous la carte, les actions portées par celles qui sont à l'écran."),
          h5("Vous pouvez alors soit modifier une des actions existantes en la sélectionnant dans la liste ou en créer de nouvelles en cliquant sur le bouton \"NOUVELLE ACTION\"."),
          
        )
      ))
    }
    
    output$af_docs_table <- DT::renderDT({
      req(af_docs_anim_id())
      af_docs_reload()
      
      docs_datatable(.af_fetch_docs(af_docs_anim_id()))
    })
    
    # (la gestion des PJ est intégrée à la modale de l'action, en création
    # comme en édition : plus de modale Documents séparée.)

    
    
    observeEvent(input$af_doc_delete, {
      # Pas de show_modal_spinner ici : c'est lui-même une modale, empilée sur
      # la modale de l'action -> son retrait refermait la modale d'édition. La
      # suppression est instantanée (unlink + DELETE), pas besoin de spinner.
      req(af_docs_anim_id())
      sel <- input$af_docs_table_rows_selected
      if (length(sel) != 1) {
        showToast("warning", "Sélection requise", "Sélectionnez une ligne du tableau.")
        return()
      }
      
      df <- .af_fetch_docs(af_docs_anim_id())
      if (length(sel) != 1 || sel < 1 || sel > nrow(df)) return()
      doc_id <- df$id[sel]
      
      docs_delete(con, docs_root, .af_doc_table(), doc_id,
                  url = df$url[sel], nom_fichier = df$nom_fichier[sel])


      showToast("warning", "Document supprimé", "🗑 Fichier et enregistrement supprimés.")
      log_action(session, current_user_rv,
                 paste0("Action #", af_docs_anim_id(), " : pièce jointe supprimée"))
      af_docs_reload(isolate(af_docs_reload()) + 1)
      af_table_reload(isolate(af_table_reload()) + 1)
    })
    
    # Recharge les sites existants
    observe({
      
      updateSelectizeInput(session, "af_site_selector",
                           choices = c("Choisissez une valeur" = "", setNames(sites_shared()$id, sites_shared()$libelle)),
                           selected = ""
      )
    })
    
    observeEvent(contrats_update_trigger(), {
      # 1) force le recalcul de af_parcelles_avec_flag()
      af_table_reload(isolate(af_table_reload()) + 1L)
      
      # 2) on invalide la taille de la carte puis on laisse l'observer existant
      #    (af_parcelles_avec_flag) repeindre via leafletProxy
      session$sendCustomMessage("invalidate-map", list(id = ns("af_map")))
    }, ignoreInit = TRUE)
    
    observeEvent(contrats_update_trigger(), {
      sid <- af_site_id()
      if (is.null(sid) || is.na(sid)) return()

      # Cet observer ne sert qu'à rafraîchir la carte du MODAL. Tant que
      # celui-ci n'a jamais été ouvert (af_map_ready encore FALSE), il n'y a
      # rien à repeindre : on évitait ainsi de relancer inutilement, à chaque
      # écriture de n'importe quel onglet, la requête la plus lourde du module.
      if (!isTRUE(af_map_ready())) return()

      # Réutilise le réactif partagé — invalidé par le même trigger, donc déjà
      # calculé pour ce cycle — au lieu de relancer .af_fetch_site_parcelles()
      # (6 CTE) une seconde fois.
      site_sf <- af_parcelles_site_sf()
      af_site_parcelles(site_sf)

      # Si on édite une action existante, recharge sa couche rouge
      if (!is.null(af_edit_id())) {
        kind <- af_edit_kind() %||% "F"  # "F" ou "A"
        anim_sf <- .af_fetch_anim_parcelles(sid, af_edit_id(), kind)
        af_anim_parcelles(anim_sf)
      }
      
      # Repeindre le modal si existant
      # (safe même si la carte n'est pas affichée)
      m <- leaflet::leafletProxy(mapId = ns("af_modal_map"))
      m %>% leaflet::clearGroup("Parcelles du site") %>% leaflet::clearGroup("Parcelles de l'action")
      
      # 🔁 Redessine le bleu (site)
      site_sf <- af_site_parcelles()
      if (!is.null(site_sf) && nrow(site_sf) > 0) {
        # même options que lors de l'ouverture du modal
        m %>% leaflet::addPolygons(
          data = site_sf, group = "Parcelles du site",
          weight = 1, color = "#377eb8", fillOpacity = 0.35,
          layerId = ~paste0("site-", code)
        )
      }
      
      # 🔁 Redessine le rouge (action)
      anim_sf <- af_anim_parcelles()
      if (!is.null(anim_sf) && nrow(anim_sf) > 0) {
        m %>% leaflet::addPolygons(
          data = anim_sf, group = "Parcelles de l'action",
          weight = 1, color = "#e41a1c", fillOpacity = 0.50,
          layerId = ~paste0("anim-", code)
        )
      }
      
      # optionnel : refit sur l’emprise du site
      if (!is.null(site_sf) && nrow(site_sf) > 0) {
        bb <- try(sf::st_bbox(site_sf), silent = TRUE)
        if (!inherits(bb, "try-error")) {
          leaflet::fitBounds(
            m,
            lng1 = as.numeric(bb["xmin"]), lat1 = as.numeric(bb["ymin"]),
            lng2 = as.numeric(bb["xmax"]), lat2 = as.numeric(bb["ymax"])
          )
        }
      }
    }, ignoreInit = TRUE)
    
    # Bouton « Modifier » du pied de la fiche de consultation : réouvre la même
    # action en mode édition (on repasse par le même canal, sans mode 'view').
    observeEvent(input$af_view_edit, {
      raw <- af_view_last_id(); req(raw)
      removeModal()
      shinyjs::runjs(sprintf(
        "Shiny.setInputValue('%s', {id: '%s', mode: 'edit', nonce: Date.now()}, {priority:'event'});",
        session$ns("af_row_click"), raw))
    })

    # --- API de reset appelée par le parent ---
    reset <- function() {
      # 1) Réinitialise les sélections/états
      bbox_site_rv(NULL)
      updateSelectizeInput(session, "af_site_selector", selected = "")
      af_site_id(NULL)
      af_edit_id(NULL)
      af_new_selected(character(0))
      af_anim_selected(character(0))
      
      # 2) Nettoyage carte sans pipe RHS en bloc
      prx <- try(leaflet::leafletProxy(ns("af_map"), session), silent = TRUE)
      if (!inherits(prx, "try-error")) {
        prx <- leaflet::clearPopups(prx)
        if (exists("EPHEMERAL_GROUPS", inherits = TRUE)) {
          for (g in EPHEMERAL_GROUPS) {
            prx <- leaflet::clearGroup(prx, g)
          }
        }
      }
      
      remove_site_legend(ns(MAP_ID), session, layer_id = LEGEND_ID)
      
      # (optionnel) messages custom JS si tu les utilises
      try(session$sendCustomMessage("clear-polygones", ns("af_map")), silent = TRUE)
      try(session$sendCustomMessage("af-reset-click",  ns("af_map")), silent = TRUE)
      
      selected_site_rv(NULL)
      
    }
    
    # ✅ FONCTION FOCUS_SITE ADAPTÉE POUR ACTIONS
    focus_site <- make_focus_site(bbox_site_rv, ns(MAP_ID), session)
    
    # <- IMPORTANT : renvoyer l’API au parent
    return(list(
      reset = reset,
      focus_site = focus_site
    ))
    
    
  })
}
