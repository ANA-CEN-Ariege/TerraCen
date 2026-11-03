#' Modules pour la gestion des sites
#' #' mod_sites.R

#' -----------------------------
#' UI du module
#' -----------------------------
sites_ui <- function(id) {
  ns <- NS(id)
  
  
  tagList(
    div(class = "flex-container",
        div(class = "sidebar-left-custom",
            titre_page("Création / modification sites et parcelles"),
            selectizeInput(
              ns("site_selector"),
              "🔎 Sélectionner un site :",
              choices  = c(" " = "", getOption("gestcons.sites_choices_init", c())),
              selected = "",
              options = list(diacritics = TRUE, create = FALSE, placeholder = "Tapez un nom…")
            ),
            actionButton(ns("reset_site"), "❌ Réinitialiser",   class = "btn-default btn-secondary"),
            actionButton(ns("add_site"),   "➕ Ajouter un site", class = "btn-success"),
            hr(),
            uiOutput(ns("resume_site")),
            br(),
            conditionalPanel(
              condition = sprintf("typeof input['%s'] !== 'undefined' && input['%s'] !== ''",
                                  ns('site_selector'), ns('site_selector')),
              actionButton(ns("edit_site"), "✏️ Modifier ce site", width = "100%",
                           class = "btn-primary")
            ),
            br(),
            # Un champ où l'on tape directement le nom, comme le sélecteur de
            # site, et non une liste qui ouvre une zone de recherche au-dessous :
            # demandé par l'utilisateur. Même champ dans l'onglet Stratégie.
            selectizeInput(
              ns("commune_selector"),
              "Zoomer sur une commune :",
              choices  = c(" " = ""),
              selected = "",
              options  = list(diacritics = TRUE, create = FALSE, placeholder = "Tapez un nom…")
            ),
            hr(),
            uiOutput(ns("sites_helper_text"))   # <-- pas de virgule ici
        ),
        
        # --- Colonne droite (prend le reste) ---
        div(class = "right-rail",
            div(class = "right-rail-inner",
                div(class = "tc-page-carte",
                    leafletOutput(ns("map"), height = "calc(var(--h-carte))"),
                    uiOutput(ns("msg_associer_parcelles")),
                    div(class = "tc-page-bas",
                        uiOutput(ns("map_footer"))
                    )
                )
            )
        )
    )
  )
}

#' -----------------------------
#' Server du module
#' -----------------------------
sites_server <- function(
    id, con, dico_type_milieu, dico_geol, dico_nature_perimetre, dico_echelle,
    dico_precision, dico_cen, dico_chasse, dico_source_surf_parc,
    dico_statut_contrat, dico_statut_site, dico_utilisateur_rv,
    acteurs_existants, sites_shared, liste_communes, contrats_choices_rv,
    selected_site_rv, contrats_update_trigger = NULL, current_user_rv, user_roles,
    zones_protection_data,
    # En dernier, et nommé à l'appel : app.R passe les précédents par position.
    dico_accessibilite
) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    MAP_ID <- "map"  # <-- mets l’ID réel de ta map dans ce module
    bbox_site_rv <- reactiveVal(NULL)
    
    # NOUVEAU: Déclencheur pour le chargement asynchrone des zones de protection
    draw_protection_trigger <- reactiveVal(0)
    
    # ID du contrôle de légende (namespacé) pour garantir la suppression
    LEGEND_ID <- ns("site_legend_control")
    
    
    # Les zones de protection ne sont PAS rechargées ici. Elles sont calculées
    # une fois au démarrage de l'application — zones_protection_global
    # (helpers.R) —, et ce module les reçoit en paramètre sous le nom
    # zones_protection_data : c'est lui qu'utilisent la légende et le dessin.
    # L'appel qui se trouvait ici refaisait la requête à chaque ouverture de
    # session et rangeait le résultat dans une variable que rien ne relisait.
    # Mesuré : 469, 490 et 468 ms sur trois exécutions à chaud, plus le parsage
    # de 1,37 Mo de géométrie côté R. Shiny étant mono-thread par processus,
    # cette attente bloquait aussi les autres utilisateurs du même processus.

    # Utilisateur à enregistrer en DB (fabrique commune, helpers.R)
    user_to_db <- make_user_to_db(current_user_rv)
    
    #' -------------------------
    #' Réactifs
    #' -------------------------
    parcelles_cache <- reactiveVal(st_sf(geometry = st_sfc(crs = 4326)))
    parcelles_cache_bbox <- reactiveVal(NULL)
    parcelles_site_data <- reactiveVal(NULL)
    perimetres_manuelles_data <- reactiveVal(NULL)
    polygones_manuels_temp <- reactiveVal(list())
    dico_proprio_global <- reactiveVal(list())
    parcelles_selectionnees <- reactiveVal(character(0))
    resume_site_trigger <- reactiveVal(0)

    # Continuité du site conservatoire (fonctionnalités reprises de l'ex-onglet Stratégie)
    perimetre_selection <- reactiveVal(character(0))  # idpar des parcelles oranges sélectionnées
    # Parcelles DU SITE sélectionnées. Même modèle que la continuité : le clic
    # et ⇧ + rectangle remplissent cette liste, et les actions — retirer,
    # modifier, basculer — vivent dans le pied de carte.
    site_selection <- reactiveVal(character(0))
    # Nature des éléments retenus : 1 = parcelle cadastrale du site, 2 = périmètre
    # manuel. On ne mélange pas — retirer vingt parcelles cadastrales et un
    # polygone dessiné n'est pas le même geste, et le formulaire d'édition n'est
    # pas le même non plus. NA tant que rien n'est retenu.
    site_selection_type <- reactiveVal(NA_integer_)

    .site_type_libelle <- function(t) {
      if (identical(as.integer(t), 2L)) "périmètres manuels" else "parcelles du site"
    }

    # TRUE si l'on peut ajouter un élément de ce type à la sélection courante.
    .site_type_compatible <- function(t) {
      cur <- isolate(site_selection_type())
      if (is.na(cur) || length(isolate(site_selection())) == 0) return(TRUE)
      if (identical(as.integer(cur), as.integer(t))) return(TRUE)
      showToast("warning", "Sélection d'une seule nature",
                sprintf(paste0("Une sélection de %s est en cours. Videz-la ",
                               "(❌ Vider) avant de retenir des %s."),
                        .site_type_libelle(cur), .site_type_libelle(t)))
      FALSE
    }
    perimetre_trigger   <- reactiveVal(0)             # invalide perimetre_data après écriture
    formulaire_site_visible <- reactiveVal(FALSE)
    site_id_edition <- reactiveVal(NULL)
    parcelles_en_attente <- reactiveVal(character(0))
    polygones_en_attente <- reactiveVal(list())
    a_supprimer_bbox <- reactiveVal(NULL)  # data.frame avec parcelle_db_id / type_parcelle_id / code_affiche
    parcelle_a_supprimer_site <- reactiveVal(NULL)
    
    # Remplacer les CHOIX d'un selectize fait transiter son input par une valeur
    # vide avant que la sélection demandée ne soit appliquée. Sans ce drapeau,
    # ce vide passager est pris pour une désélection : la branche de
    # réinitialisation efface les couches et repose la vue par défaut sur
    # l'Ariège — juste après que le cadrage du site a été appliqué.
    ignorer_vide_selecteur <- reactiveVal(FALSE)

    # Garde pour ignorer la première initialisation des selectize inputs
    # Ce que les sélecteurs de rôle affichent après la dernière construction du
    # formulaire, et la date qui va avec. Sert à ne pas confondre un choix de
    # l'utilisateur avec la reconstruction de la fiche.
    resp_rendu        <- reactiveVal("")
    benev_rendu       <- reactiveVal("")
    resp_date_rendue  <- reactiveVal(NULL)
    benev_date_rendue <- reactiveVal(NULL)

    # Incrémenté à chaque construction du formulaire de site. Les boutons
    # d'enregistrement naissent désactivés et ne sont activés que par
    # l'observateur de validation ; sans ce déclencheur, rouvrir la fiche sans
    # modifier aucun champ obligatoire ne le réveillait pas, et le bouton
    # restait grisé.
    form_site_rendu <- reactiveVal(0L)
    
    # Détermine si l'utilisateur a les droits AD ou RS sur le site actif
    can_edit_site <- reactive({
      roles <- user_roles()
      site_id <- site_id_edition()

      is_admin <- roles$global_role == "AD"
      
      # Vérifie si l'utilisateur est RS sur le site sélectionné (ou AD)
      is_rs_on_site <- is_admin || (
        !is.na(site_id) && 
          any(roles$site_roles$site_id == site_id & roles$site_roles$role == "RS")
      )
      return(is_rs_on_site)
    })
    
    # 💡 NOUVEAU RÉACTIF : Contenu HTML de la Légende Dico Protection
    # Chaque type de protection ayant son propre interrupteur, la légende ne
    # décrit plus que les types RÉELLEMENT cochés. Elle recevait auparavant la
    # liste complète, et lançait au passage une requête dont le résultat ne
    # servait qu'à une palette jamais utilisée.
    dico_protection_legend_html <- function(types_visibles) {
      colors_map   <- COLORS_PROTECTION
      types_legend <- names(colors_map)[names(colors_map) %in% types_visibles]
      if (!length(types_legend)) return(NULL)

      # Construction du contenu HTML
      legend_content <- tags$div(
        class = "dico-protection-legend-box", # <-- Nouvelle classe personnalisée pour ciblage futur si besoin
        style = "background: white; padding: 6px; border-radius: 5px; box-shadow: 0 0 15px rgba(0,0,0,0.2);", # Conserver le style intérieur pour le fond blanc
        tags$div(
          style = "font-weight: bold; margin-bottom: 5px;",
          "Type de Protection"
        ),
        tags$ul(
          style = "list-style: none; padding-left: 0; margin-bottom: 0;",
          lapply(types_legend, function(type) {
            color <- colors_map[type]
            tags$li(
              tags$i(style=paste0("background-color:", color, "; width:10px; height:10px; display:inline-block; margin-right:5px; border: 1px solid #000;")),
              htmltools::htmlEscape(type)
            )
          })
        )
      )
      
      # Rendre le HTML en tant que chaîne de caractères
      htmltools::doRenderTags(legend_content)
    }
    
    observe({
      site_id <- selected_site_rv()
      roles <- user_roles() # Rôle partagé du parent
      
      is_rs_on_site <- can_edit_site()
      is_admin <- roles$global_role == "AD"
      
      # Vérifie si l'utilisateur est AN sur le site sélectionné (ou RS/AD)
      # (Seulement pour le module Actions)
      is_an_on_site <- is_rs_on_site || (
        !is.na(site_id) && 
          any(roles$site_roles$site_id == site_id & roles$site_roles$role == "AN")
      )
      
      # --- Logique spécifique à chaque module ---
      
      # Dans sites_server :
      shinyjs::toggle("add_site", condition = is_admin) # Seul AD peut créer un nouveau site (règle plus stricte)
      shinyjs::toggle("edit_site", condition = is_rs_on_site) # AD ou RS pour l'édition
      
    })
    
    observeEvent(selected_site_rv(), {
      sel <- selected_site_rv()
      # Assure sel est un caractère, même si NULL ou NA
      sel <- if (is.null(sel) || is.na(sel)) "" else as.character(sel)
      
      if (!identical(input$site_selector, sel)) {
        if (nzchar(sel)) {
          # La liste n'est chargée qu'à l'initialisation du module : un site
          # créé ailleurs — notamment un secteur promu depuis la Stratégie
          # foncière — n'y figure pas encore, et la sélection échouerait en
          # silence. On la relit donc avant de sélectionner.
          ignorer_vide_selecteur(TRUE)
          refresh_sites_choices(select = sel)
        } else {
          updateSelectizeInput(session, "site_selector", selected = sel)
        }
      }
      
      current_site_id <- suppressWarnings(as.integer(sel))
      
      # Logique de synchronisation et de reset
      # 💡 CORRECTION: Le bloc de code qui était à la ligne 800+ est remonté ici et rendu robuste.
      if (is.null(sel) || sel == "" || is.na(current_site_id[1])) {
        
        # --- RESET/DÉSELECTION ---
        site_id_edition(NULL)
        bbox_site_rv(NULL)
        # On pourrait ajouter plus de réinitialisation ici, mais l'essentiel est fait:
        # vider site_id_edition pour arrêter les calculs internes.
        formulaire_site_visible(FALSE)
        parcelles_selectionnees(character(0))
        parcelles_site_data(NULL)
        perimetres_manuelles_data(NULL)
        polygones_manuels_temp(list())
        
        leafletProxy(mapId = ns("map"), session = session) %>%
          removeDrawToolbar() %>%
          clear_groups(c("Parcelles du site", "Parcelles cadastrales", "Périmètres manuels",
                         "Continuité du site conservatoire", "Contour", "Périmètre sélectionné",
                         "Parcelle sélectionnée", "Polygones")) %>%
          showGroup("Sites existants") %>%
          setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = MAP_DEFAULT_ZOOM)
        clear_selection_cache(ns("map"), session)
        invalidate_cadastre_hash(ns("map"), session)
        invalidate_site_layer_hash(ns("map"), session)
        invalidate_perim_layer_hash(ns("map"), session)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        draw_circles(con, map_id = ns("map"), zoom = input$map_zoom)
        session$sendCustomMessage("tc-sites-ready", ns("map"))
        session$sendCustomMessage('toggle-layer-overlays', list(id = ns('map'), hide = TRUE))
        
        remove_legend(ns("map"), session, layer_id = LEGEND_ID)
        
      } else {
        # --- SÉLECTION DU SITE ---
        site_id_edition(current_site_id)
        # On repart d'une sélection vierge : une sélection de parcelles non
        # enregistrée ne doit pas persister d'un site à l'autre.
        parcelles_selectionnees(character(0))
        clear_selection_cache(ns("map"), session)
        # Nettoyage visuel initial après sélection
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelle sélectionnée") %>%
          hideGroup("Sites existants")
      }
      
    }, ignoreNULL = FALSE)
    
    type_acteur_proprio_id <- dbGetQuery(con, "
      SELECT id
      FROM gestcons.dico_type_acteur
      WHERE lower(unaccent(libelle)) = lower(unaccent('Propriétaire'))
      LIMIT 1
    ")$id
    
    #' -------------------------
    #' Defaults
    #' -------------------------
    default_echelle <- dico_echelle$id[dico_echelle$libelle == "inconnue"]
    default_cen <- dico_cen$id[dico_cen$libelle_long == "Conservatoire d'espaces naturels d'Ariège"]
    default_nature_perimetre <- dico_nature_perimetre$id[dico_nature_perimetre$libelle == "fusion des parcelles maîtrisées (foncier et/ou usage)"]
    default_precision <- dico_precision$id[dico_precision$libelle == "Non estimée"]
    
    # Lire les commentaires pour gestcons.sites (une fois)
    comments_sites <- get_table_column_comments(con, "gestcons", "sites")
    
    # ---- Helpers: construire une arborescence simple id/parent_id ----
    make_children_index <- function(df){
      # retourne une liste: parent_id -> vecteur d'id enfants
      split(df$id, df$parent_id)
    }
    
    focus_site <- make_focus_site(bbox_site_rv, ns(MAP_ID), session)
    
    
    # Vide la sélection de parcelles en cours (état + visuel + cache), y compris
    # la sélection de la continuité du site conservatoire. Appelée au changement de site et au
    # changement d'onglet : une sélection non enregistrée ne doit pas persister.
    clear_selection <- function() {
      parcelles_selectionnees(character(0))
      leafletProxy(ns("map"), session = session) %>%
        clearGroup("Parcelle sélectionnée")
      clear_selection_cache(ns("map"), session)
      clear_perimetre_selection()
    }

    # construction récursive des <li>/<ul>
    build_menu_ul <- function(df, children_index, parent, level = 1){
      # enfants directs du parent
      kids <- children_index[[as.character(parent)]]
      if (is.null(kids) || length(kids) == 0) return(NULL)
      
      tags$ul(
        class = if (level == 1) "hh-menu" else "hh-sub",
        lapply(kids, function(kid){
          row <- df[df$id == kid, ][1, ]
          has_children <- !is.null(children_index[[as.character(kid)]])
          li <- tags$li(
            class = paste0("hh-item level-", level, if(!has_children) " hh-leaf"),
            `data-id` = kid,
            tags$span(class = "hh-label", row$libelle),
            if (has_children) tags$span(class = "hh-chevron", HTML("&rsaquo;")),
            if (has_children) build_menu_ul(df, children_index, kid, level+1)
          )
          li
        })
      )
    }
    
    output$geol_selector_ui <- renderUI({
      ns <- session$ns
      req(dico_geol)
      
      ## -------------------------------
      ## 1) Construire le parent immédiat
      ## -------------------------------
      geol <- dico_geol
      stopifnot(all(c("id","libelle","parent_id","parent_id_2","parent_id_3") %in% names(geol)))
      
      # Lignes 313 à 322 du code fourni :
      
      geol$id          <- as.integer(geol$id)
      geol$libelle     <- as.character(geol$libelle)
      geol$parent_id   <- as.integer(ifelse(is.na(geol$parent_id),   0L, geol$parent_id))
      geol$parent_id_2 <- as.integer(ifelse(is.na(geol$parent_id_2), 0L, geol$parent_id_2))
      geol$parent_id_3 <- as.integer(ifelse(is.na(geol$parent_id_3), 0L, geol$parent_id_3))
      
      ## Règle EXACTE (selon votre description)
      ## Niv 1 (parent_id = 0) -> Parent = 0
      ## Niv 2 (parent_id > 0, parent_id_2 = 0) -> Parent = parent_id
      ## Niv 3 (parent_id_2 > 0, parent_id_3 = 0) -> Parent = parent_id_2
      ## Niv 4 (parent_id_3 > 0) -> Parent = parent_id_3
      
      parent_immediat <- ifelse(geol$parent_id == 0L, 0L, geol$parent_id)
      
      ## Tableau plat AVEC NIVEAU pour l'affichage (level)
      level <- ifelse(geol$parent_id == 0L, 1L,    # Niveau 1 si parent_id = 0
                      ifelse(geol$parent_id_2 == 0L, 2L, # Niveau 2 si parent_id_2 = 0
                             ifelse(geol$parent_id_3 == 0L, 3L, 4L))) # Niveau 3 ou 4
      
      data_flat <- data.frame(
        id        = geol$id,
        libelle   = geol$libelle,
        parent_id = as.integer(parent_immediat), # Utilisera uniquement parent_id ou 0
        level     = as.integer(level),           # Nouvelle colonne calculée
        stringsAsFactors = FALSE
      )
      
      ## (option) tri stable pour un rendu propre
      data_flat <- data_flat[order(data_flat$parent_id, data_flat$libelle, na.last = TRUE), ]
      
      path_from_id <- function(id, dico){
        if (is.null(id) || is.na(id)) return(NA_character_)
        id_chr <- as.character(id)
        dico$id_chr <- as.character(dico$id)
        
        # Tous les préfixes: "1222" -> "1","12","122","1222"
        prefixes <- vapply(seq_len(nchar(id_chr)), function(k) substr(id_chr, 1, k),
                           FUN.VALUE = character(1))
        
        labs <- dico$libelle[match(prefixes, dico$id_chr)]
        # ⚠️ Ne plus supprimer les NA: on les remplace par l'ID pour garder tous les niveaux
        labs[is.na(labs)] <- prefixes[is.na(labs)]
        paste(labs, collapse = " › ")
      }
      
      output$geo_breadcrumbs <- renderUI({
        sel <- input$geologie_id       # <-- utilise toujours le même inputId
        if (is.null(sel) || !length(sel)) return(NULL)
        
        trails <- unique(vapply(sel, path_from_id, FUN.VALUE = character(1), dico = dico_geol))
        trails <- trails[nzchar(trails)]
        
        if (!length(trails)) return(NULL)
        
        tags$div(
          lapply(trails, function(x){
            tags$div(class = "geo-breadcrumb-item", x)
          })
        )
      })
      
      
      # --- NOUVEAU HELPER : Reconstruire le chemin de l'ID sélectionné ---
      reconstruct_geol_path <- function(id, flat_data) {
        id <- as.integer(id)
        if (is.null(id) || is.na(id) || !(id %in% flat_data$id)) {
          return(NULL)
        }
        path <- c()
        current_id <- id
        
        # Remonter l'arborescence jusqu'à la racine (parent_id = 0)
        while (current_id != 0 && current_id %in% flat_data$id) {
          row <- flat_data[flat_data$id == current_id, ][1, ]
          path <- c(row$libelle, path) # Ajoute le libellé au début du chemin
          
          # Déterminer le parent_id correct à partir de la ligne complète (dico_geol)
          geol_row <- geol[geol$id == current_id, ][1, ]
          if (geol_row$parent_id_3 > 0) {
            current_id <- geol_row$parent_id_3
          } else if (geol_row$parent_id_2 > 0) {
            current_id <- geol_row$parent_id_2
          } else if (geol_row$parent_id > 0) {
            current_id <- geol_row$parent_id
          } else {
            current_id <- 0 # Racine
          }
        }
        
        return(path) # Renvoie un vecteur de chaînes de caractères
      }
      
      ## ---------------------------------
      ## 2) Liste imbriquée (même logique)
      ## ---------------------------------
      build_nested_list <- function(data, parent_id = 0L) {
        children <- data[data$parent_id == parent_id, , drop = FALSE]
        if (nrow(children) == 0) return(NULL)
        ## on trie par libellé à chaque niveau (si souhaité)
        children <- children[order(children$libelle, na.last = TRUE), , drop = FALSE]
        
        menu_list <- vector("list", nrow(children))
        for (i in seq_len(nrow(children))) {
          id_val      <- children$id[i]
          libelle_val <- children$libelle[i]
          level_val   <- children$level[i] # <-- NOUVEAU: Récupère le niveau calculé
          sub_list    <- build_nested_list(data, parent_id = id_val)
          menu_list[[i]] <- list(
            value = as.character(id_val),
            label = libelle_val,
            level = level_val, # <-- NOUVEAU: Ajoute le niveau à la liste
            sub   = sub_list
          )
        }
        menu_list
      }
      MENU_DATA <- build_nested_list(data_flat, parent_id = 0L)
      
      ## ---------------------------------
      ## 3) HTML récursif (classes .hh- *)
      ## ---------------------------------
      build_menu_html_hh <- function(data, level = 1) {
        if (is.null(data) || length(data) == 0) return(NULL)
        htmltools::tags$ul(
          class = if (level == 1) "hh-menu" else "hh-sub",
          lapply(data, function(item) {
            has_sub <- !is.null(item$sub) && length(item$sub) > 0
            htmltools::tags$li(
              class = paste0("hh-item level-", level, if(!has_sub) " hh-leaf"),
              `data-id` = item$value,
              htmltools::tags$span(class = "hh-label", item$label),
              if (has_sub) htmltools::tags$span(class = "hh-chevron", icon("caret-right", class = "fa-lg")), # fa-lg pour une taille plus grande
              
              if (has_sub) build_menu_html_hh(item$sub, level + 1)
            )
          })
        )
      }
      
      ## ---------------------------------
      ## 4) Libellé courant sur le bouton et chemin complet
      ## ---------------------------------
      selected_path_vec <- reconstruct_geol_path(input$geologie_id, data_flat)
      
      # Le texte affiché dans le bouton (juste le dernier niveau)
      cur_txt <- {
        sel <- input$geologie_id
        if (!is.null(sel) && nzchar(sel) && as.integer(sel) %in% data_flat$id) {
          tail(selected_path_vec, 1) # N'affiche que l'élément le plus bas dans le bouton
        } else {
          "Sélectionner…"
        }
      }
      
      # Le texte affiché sous le bouton (le chemin complet)
      full_path_txt <- if (!is.null(selected_path_vec)) {
        paste(selected_path_vec, collapse = " \u25B8 ") # Sépare par la flèche (►)
      } else {
        NULL
      }
      
      ## ---------------------------------
      ## 5) CSS/JS (si tu as déjà un bloc global, tu peux retirer celui-ci)
      ## ---------------------------------
      dom_id <- ns("geol_menu_wrap")
      
      
      js_txt <- paste0("
        (function(){
          var wrap = document.getElementById('", dom_id, "');
          if(!wrap) return;
          var trigger = wrap.querySelector('.hh-trigger');
          var menu = wrap.querySelector('.hh-menu');
        
          // --- ouverture/fermeture du panneau principal ---
          if(trigger){
            trigger.addEventListener('click', function(){
              menu.classList.toggle('hidden');
              trigger.setAttribute('aria-expanded', !menu.classList.contains('hidden'));
            });
          }
          document.addEventListener('click', function(e){
            if(!wrap.contains(e.target)){
              menu.classList.add('hidden');
              trigger && trigger.setAttribute('aria-expanded','false');
              // ferme toute branche ouverte
              wrap.querySelectorAll('.hh-item.open').forEach(function(n){ n.classList.remove('open'); });
            }
          });
        
          // utilitaires
          function closeSiblings(li){
            if(!li || !li.parentElement) return;
            Array.from(li.parentElement.children).forEach(function(sib){
              if(sib !== li) sib.classList.remove('open');
            });
          }
          function closeBranch(li){
            if(!li) return;
            li.classList.remove('open');
            li.querySelectorAll('.hh-item.open').forEach(function(n){ n.classList.remove('open'); });
          }
          function within(node, container){
            return !!(node && container && container.contains(node));
          }
        
          // --- OUVERTURE : utiliser un évènement qui bulle (mouseover/pointerover)
          wrap.addEventListener('pointerover', function(e){
            var li = e.target.closest('.hh-item[data-id]');
            if(!li || !wrap.contains(li)) return;
            var sub = li.querySelector(':scope > .hh-sub');
            closeSiblings(li);
            if(sub){ li.classList.add('open'); }
          }, true);
        
          // --- FERMETURE par item : quand on sort VRAIMENT de l’item (et pas vers son sous-menu)
          wrap.addEventListener('mouseout', function(e){
            var li = e.target.closest('.hh-item[data-id]');
            if(!li || !wrap.contains(li)) return;
            var rt = e.relatedTarget;
            if (within(rt, li)) return;   // on reste dans l’item/sous-menu → ne pas fermer
            closeBranch(li);              // sinon on ferme la branche de cet item
          }, true);
        
          // --- FERMETURE globale : quitter la zone du menu → tout fermer + cacher le panneau
          wrap.addEventListener('mouseleave', function(){
            wrap.querySelectorAll('.hh-item.open').forEach(function(n){ n.classList.remove('open'); });
            menu.classList.add('hidden');
            trigger && trigger.setAttribute('aria-expanded','false');
          });
        
          // --- Sélection par clic sur un libellé
          wrap.addEventListener('click', function(e){
            var lab = e.target.closest('.hh-label');
            if(!lab || !wrap.contains(lab)) return;
            var li = lab.closest('.hh-item[data-id]');
            if(!li) return;
        
            var id  = li.getAttribute('data-id');
            var txt = lab.textContent.trim();
        
            if(window.Shiny && Shiny.setInputValue){
              Shiny.setInputValue('", ns("geologie_id"), "', id, {priority:'event'});
            }
            var tg = wrap.querySelector('.hh-trigger .hh-current');
            if(tg){ tg.textContent = txt; }
        
            // tout fermer et cacher
            wrap.querySelectorAll('.hh-item.open').forEach(function(n){ n.classList.remove('open'); });
            menu.classList.add('hidden');
            trigger && trigger.setAttribute('aria-expanded','false');
          });
        
          // --- ESC : tout fermer
          document.addEventListener('keydown', function(ev){
            if(ev.key === 'Escape'){
              wrap.querySelectorAll('.hh-item.open').forEach(function(n){ n.classList.remove('open'); });
              menu.classList.add('hidden');
              trigger && trigger.setAttribute('aria-expanded','false');
            }
          });
        })();
        ")
      
      lbl_id  <- ns("geol_label")
      trig_id <- ns("geol_trigger")
      
      ## ---------------------------------
      ## 6) Rendu final
      ## ---------------------------------
      htmltools::tagList(
        
        
        htmltools::div(
          class = "form-group shiny-input-container",
          htmltools::tags$label(
            id = lbl_id,
            class = "control-label form-label",
            `for` = trig_id,
            htmltools::tagList("Géologie *", tooltip_info(get_comment("geol_id")))
          ),
          htmltools::div(
            class = "hh-wrap", id = dom_id,
            htmltools::div(
              class = "hh-trigger",
              id = trig_id, tabindex = "0", role = "button",
              `aria-haspopup` = "listbox", `aria-expanded` = "false",
              `aria-labelledby` = lbl_id,
              htmltools::span(class = "hh-current",  cur_txt),
              htmltools::span(class = "hh-chevron", htmltools::HTML("&rsaquo;"))
            ),
            {
              build_menu_html_hh(MENU_DATA, level = 1) %>%
                htmltools::tagAppendAttributes(
                  class = "hh-menu hidden",
                  `aria-labelledby` = lbl_id
                )
            }
          )
        )
        ,
        htmltools::tags$script(htmltools::HTML(js_txt))
      )
    })
    
    
    # Rafraîchit le reactiveVal PARTAGÉ avec les onglets Acteurs et Contrats.
    # Il poussait ici un tout autre schéma que les quatre autres points
    # d'écriture — id, nom, prenom, adresse, cp, commune, type_acteur_id — et
    # les listes « Acteurs » des formulaires de contrat se vidaient alors en
    # silence, pour le reste de la session. Les colonnes supplémentaires ne
    # servaient à personne : ce module n'a jamais relu ce reactiveVal, et les
    # deux appelants ignorent la valeur de retour.
    refresh_acteurs <- function(con) {
      df <- fetch_acteurs_choices(con)
      acteurs_existants(df)
      invisible(df)
    }
    
    
    # Cette fonction doit se trouver avant son utilisation dans votre script server.R
    make_sql_text_array <- function(vec) {
      vec <- unique(vec)
      vec <- vec[!is.na(vec) & nzchar(vec)]
      if (length(vec) == 0) {
        # Si le vecteur est vide, retourne un tableau vide explicitement typé pour PostgreSQL
        return("ARRAY[]::text[]") 
      }
      # Retourne le tableau formaté (par exemple : ARRAY['A001', 'A002'])
      # dbQuoteString pour l'échappement SQL (et jamais shQuote, quotation shell)
      paste0("ARRAY[", paste(DBI::dbQuoteString(con, vec), collapse = ","), "]::text[]")
    }
    
    # Petit helper pour récupérer le commentaire d'une colonne
    get_comment <- function(col) {
      val <- comments_sites[[col]]
      if (is.null(val) || is.na(val) || !nzchar(trimws(val))) "Aucune information disponible." else val
    }
    
    #' -------------------------
    #' Rafraîchir la liste des utilisateurs (met à jour le reactiveVal parent)
    #' -------------------------
    refresh_dico_utilisateur <- function() {
      df <- safe_db_query(
        con,
        "SELECT id, CONCAT(nom, ' ', prenom) AS nom_complet
         FROM gestcons.dico_utilisateur
         WHERE actif = TRUE
         ORDER BY nom, prenom"
      )
      dico_utilisateur_rv(df)
      invisible(df)
    }
    
    
    
    # 1) Handler générique via input$.. pour tous les boutons commençant par info_
    #    On liste les ids des champs pour lesquels on place un info_button(...)
    af_info_ids <- c(
      "libelle",
      "type_milieu_id",
      "nature_site_inpn",
      "geol_id",
      "date_crea_site",
      "nature_perimetre_id",
      "echelle_num_id",
      "precision_num_site_id",
      "gestionnaire_site",
      "operateur",
      "surf_libre_evolution_m2",
      "url_fiche_inpn",
      "url_fiche_cen",
      "description_site",
      "sensibilite",
      "non_diffusion"
      # <-- ajoute ici les colonnes de gestcons.sites réellement présentes dans TON formulaire
    )
    
    # Crée dynamiquement un observeEvent par id déclaré ci-dessus
    lapply(af_info_ids, function(col) {
      observeEvent(input[[paste0("info_", col)]], ignoreInit = TRUE, {
        showModal(modalDialog(
          title = sprintf("ℹ️ %s — information", col),
          easyClose = TRUE, footer = NULL,   # fermeture par la croix de l'en-tête
          size = "s",
          HTML(get_comment(col))
        ))
      })
    })
    
    #' -------------------------
    #' Init module (une fois)
    #' -------------------------
    observeEvent(TRUE, {
      debug_print("observeEvent(TRUE")
      try(refresh_dico_utilisateur(), silent = TRUE)
      refresh_sites_choices()
      
      # -- si liste_communes est déjà un vecteur, prends-le tel quel
      communes <- if (is.function(liste_communes)) liste_communes() else liste_communes
      communes <- unique(communes)
      communes <- as.character(communes)
      communes <- communes[!is.na(communes) & nzchar(communes)]
      communes <- sort(communes)
      
      debug_print(sprintf("Commune choices: n=%d", length(communes)))
      
      # Rempli comme le sélecteur de site ci-dessus. Le remplacement des choix
      # fait passer le champ par une valeur vide, sans effet : le zoom sur
      # commune s'arrête sur une commune vide.
      updateSelectizeInput(session, "commune_selector",
                           choices  = c(" " = "", stats::setNames(communes, communes)),
                           selected = "")
    }, once = TRUE)
    
    
    
    #' -------------------------
    #' Carte de base
    #' -------------------------
    output$map <- renderLeaflet({
      # Les zones de protection ne sont plus un interrupteur unique : chaque
      # type a le sien (cf. protection_groupes(), helpers.R).
      overlays_sites <- c("Parcelles du site", "Continuité du site conservatoire", "Contour",
                          "Périmètres manuels", "Parcelles cadastrales",
                          protection_groupes(zones_protection_data),
                          "Zones humides", "Sites voisins", GROUPS$communes)
      init_map_base() %>%
        addLayersControl(
          baseGroups = c("OpenStreetMap", "IGN Cartes", "IGN Satellites"),
          overlayGroups = overlays_sites,
          options = layersControlOptions(collapsed = FALSE)
        ) %>%
        hideGroup(c("Parcelles du site", "Continuité du site conservatoire", "Contour",
                    "Périmètre sélectionné", "Périmètres manuels", "Parcelles cadastrales",
                    "Parcelle sélectionnée", "Polygones",
                    protection_groupes(zones_protection_data),
                    "Zones humides", "Sites voisins", GROUPS$communes)) %>%
        htmlwidgets::onRender("
          function(el, x){
            // (Optionnel) retitrage de la toolbar
            if (L && L.drawLocal && L.drawLocal.draw && L.drawLocal.draw.toolbar && L.drawLocal.draw.toolbar.buttons){
              L.drawLocal.draw.toolbar.buttons.polygon   = 'Tracer un périmètre manuel';
              L.drawLocal.draw.toolbar.buttons.rectangle = 'Sélectionner des parcelles cadastrales à ajouter au site — maintenir ⇧ (Maj) pendant le tracé pour retenir au contraire les parcelles DÉJÀ dans le site';
            }
            function retitle(){
              var p = el.querySelector('.leaflet-draw-draw-polygon a') || el.querySelector('.leaflet-draw-draw-polygon');
              if(p){ p.title = 'Tracer un périmètre manuel'; p.setAttribute('aria-label','Tracer un périmètre manuel'); }
              var r = el.querySelector('.leaflet-draw-draw-rectangle a') || el.querySelector('.leaflet-draw-draw-rectangle');
              // L'infobulle dit les DEUX gestes : sans ⇧ on prend dans le
              // cadastre, avec ⇧ on reprend les parcelles du site. Le second
              // ne s'invente pas, et rien à l'écran ne le laissait deviner.
              if(r){ r.title = 'Sélectionner des parcelles cadastrales à ajouter au site — maintenir ⇧ (Maj) pendant le tracé pour retenir au contraire les parcelles DÉJÀ dans le site'; r.setAttribute('aria-label','Sélectionner des parcelles cadastrales à ajouter au site — maintenir ⇧ (Maj) pendant le tracé pour retenir au contraire les parcelles DÉJÀ dans le site'); }
            }
            retitle(); setTimeout(retitle,50); setTimeout(retitle,200);
            new MutationObserver(function(){ retitle(); }).observe(el, { childList:true, subtree:true });
          
            // === INPUT namespacé pour SHIFT
            var baseId = el.id.replace(/-map$/, ''); // ns(prefix)
            function pushShift(v){
              // 'force:true' pour déclencher même si la valeur ne change pas à haute fréquence
              Shiny.setInputValue(baseId + '-shift_pressed', !!v, {priority:'event', force:true});
            }
            var shiftDown = false;
          
            // clavier global
            window.addEventListener('keydown', function(e){
              if(e.key === 'Shift'){ shiftDown = true;  pushShift(true); }
            }, {capture:true});
            window.addEventListener('keyup', function(e){
              if(e.key === 'Shift'){ shiftDown = false; pushShift(false); }
            }, {capture:true});
          
            // sécurité : lors du mousedown sur la carte, on envoie l’état courant du modifieur
            var widget = HTMLWidgets.find('#' + el.id);
            var map = (widget && widget.getLeaflet) ? widget.getLeaflet() : (el.htmlwidget_data ? el.htmlwidget_data._map : el._leaflet_map);
            if (map) {
              map.on('mousedown', function(e){
                var fromMouse = !!(e.originalEvent && e.originalEvent.shiftKey);
                // on synchronise shiftDown (utile si le focus clavier était ailleurs)
                shiftDown = fromMouse;
                pushShift(shiftDown);
              });
            }

            // Intention UTILISATEUR sur la case « Parcelles cadastrales ».
            // L'événement 'change' ne se déclenche QUE sur un clic réel (pas sur
            // un showGroup/hideGroup programmatique au zoom) -> on distingue ainsi
            // un décochage volontaire d'un masquage automatique.
            el.addEventListener('change', function(ev){
              var t = ev.target;
              if (t && t.classList && t.classList.contains('leaflet-control-layers-selector')){
                var lbl = t.closest ? t.closest('label') : null;
                var txt = lbl ? (lbl.textContent || '') : '';
                if (txt.indexOf('Parcelles cadastrales') !== -1){
                  Shiny.setInputValue(baseId + '-cadastre_user_show', !!t.checked, {priority:'event'});
                }
              }
            }, true);

            // === Overlay animé pendant le chargement initial de la carte ===
            // Indépendant de la variable `map` ci-dessus (qui peut être nulle au
            // moment du onRender) : on crée toujours l'overlay (il n'a besoin que
            // de `el`), puis on attache les événements de tuiles quand la carte
            // est disponible. Masqué quand tuiles dessinées ET sites dessinés.
            try {
              if (!document.getElementById('tc-map-loading-style')) {
                var tcSt = document.createElement('style');
                tcSt.id = 'tc-map-loading-style';
                tcSt.textContent =
                  '.tc-map-loading{position:absolute;inset:0;z-index:1500;display:flex;' +
                  'flex-direction:column;align-items:center;justify-content:center;' +
                  'background:rgba(255,255,255,.55);pointer-events:none;' +
                  'transition:opacity .35s ease;}' +
                  '.tc-map-loading.tc-hide{opacity:0;}' +
                  '.tc-map-loader{width:54px;height:54px;border:6px solid var(--c-accent-voile);' +
                  'border-top-color:var(--c-accent);border-radius:50%;animation:tc-spin .9s linear infinite;}' +
                  '.tc-map-loading-txt{margin-top:12px;color:var(--c-encre);font:600 14px/1.2 sans-serif;}' +
                  '@keyframes tc-spin{to{transform:rotate(360deg);}}';
                document.head.appendChild(tcSt);
              }
              if (getComputedStyle(el).position === 'static') { el.style.position = 'relative'; }
              var ov = document.createElement('div');
              ov.className = 'tc-map-loading';
              var sp = document.createElement('div'); sp.className = 'tc-map-loader';
              var tx = document.createElement('div'); tx.className = 'tc-map-loading-txt';
              tx.textContent = 'Chargement de la carte…';
              ov.appendChild(sp); ov.appendChild(tx);
              el.appendChild(ov);
              ov.style.display = 'flex';   // visible d'emblée pour le 1er rendu

              // État RÉPÉTABLE. L'overlay ne se masque que lorsque TOUT est dessiné :
              //   - tuiles de fond chargées (événements client),
              //   - serveur « idle » = vue rechargée côté R (cadastre, périmètres,
              //     sélection…) via le message 'tc-map-idle',
              //   - cercles de sites dessinés (1er affichage seulement).
              // Tout déplacement / zoom (moveend/zoomend) arme l'attente d'un nouvel
              // idle serveur -> on patiente jusqu'au cadastre, pas seulement les tuiles.
              var tcActive = true;                      // un cycle d'affichage est en cours
              var tcTiles = false, tcExpectTiles = true;        // tuiles
              var tcServerIdle = false, tcExpectServer = false; // serveur (cadastre…)
              var tcSites = !!el._tcSitesReadyFlag, tcFirstCycle = true;
              var tcShownAt = null, tcHideT = null, tcFadeT = null, tcMaxT = null;
              var TC_MIN_MS = 500;      // durée minimale d'affichage (anti-flash)
              var TC_SETTLE_MS = 300;   // anti-rebond avant masquage
              var TC_MAX_MS = 2500;     // filet de sécurité par cycle (borne le pire cas)
              function tcNow(){ return (window.performance && performance.now) ? performance.now() : 0; }
              function tcVisible(){ return el.offsetWidth > 0 && el.offsetHeight > 0; }
              function tcArmMax(){ if (tcMaxT) clearTimeout(tcMaxT); tcMaxT = setTimeout(tcFadeNow, TC_MAX_MS); }
              function tcShow(){
                if (!tcVisible()) return;            // seulement si la carte est affichée
                if (tcHideT){ clearTimeout(tcHideT); tcHideT = null; }
                if (tcFadeT){ clearTimeout(tcFadeT); tcFadeT = null; }
                ov.classList.remove('tc-hide');
                ov.style.display = 'flex';
                if (tcShownAt === null) tcShownAt = tcNow();
                tcArmMax();
              }
              function tcStartCycle(){
                if (!tcActive){
                  tcActive = true; tcTiles = false; tcExpectTiles = false;
                  tcServerIdle = false; tcExpectServer = false; tcShownAt = null;
                }
                tcShow();
              }
              function tcFadeNow(){
                if (tcMaxT){ clearTimeout(tcMaxT); tcMaxT = null; }
                if (tcHideT){ clearTimeout(tcHideT); tcHideT = null; }
                ov.classList.add('tc-hide');
                tcFadeT = setTimeout(function(){
                  ov.style.display = 'none';
                  ov.classList.remove('tc-hide');
                }, 400);
                tcActive = false; tcFirstCycle = false; tcShownAt = null;
              }
              function tcReady(){
                if (!tcActive) return false;
                if (tcExpectTiles && !tcTiles) return false;       // tuiles pas finies
                if (tcExpectServer && !tcServerIdle) return false; // serveur pas idle
                if (tcFirstCycle && !tcSites) return false;        // cercles pas dessinés
                return true;
              }
              function tcMaybeHide(){
                if (!tcReady()) return;
                var elapsed = (tcShownAt === null) ? TC_MIN_MS : (tcNow() - tcShownAt);
                var wait = Math.max(TC_SETTLE_MS, TC_MIN_MS - elapsed);
                if (tcHideT) clearTimeout(tcHideT);
                tcHideT = setTimeout(tcFadeNow, wait);
              }
              el._tcSitesReady = function(){ tcSites = true; tcMaybeHide(); };
              el._tcIdle = function(){ tcServerIdle = true; tcMaybeHide(); };

              // Distingue un vrai geste UTILISATEUR (souris/molette/tactile/clavier)
              // d'un mouvement PROGRAMMATIQUE (setView au changement d'onglet — 3×
              // dans app.js — et resize déclenché par invalidate-map). Sans ce garde,
              // ces mouvements programmatiques ré-armaient le cycle en boucle et
              // l'overlay ne se levait qu'au timeout → carte « lente » à chaque entrée
              // sur l'onglet, alors qu'elle était déjà dessinée sous le voile.
              var tcGestureUntil = 0;
              function tcMarkGesture(){ tcGestureUntil = tcNow() + 800; }
              function tcIsGesture(){ return tcNow() < tcGestureUntil; }
              // mousedown/touchstart couvrent le DÉBUT du geste (movestart) ; mouseup/
              // touchend/pointerup couvrent la FIN (moveend au relâché, après un drag
              // qui peut durer plus que la fenêtre). wheel = zoom molette ; keydown =
              // pan clavier.
              var tcGestureEvents = ['pointerdown','pointerup','mousedown','mouseup','wheel','touchstart','touchend','keydown'];
              tcGestureEvents.forEach(function(evt){
                el.addEventListener(evt, tcMarkGesture, { capture:true, passive:true });
              });

              function tcOnViewChange(){
                // On ne ré-arme l'attente serveur QUE sur un geste utilisateur : un
                // pan/zoom réel déclenche un rechargement cadastre qu'on veut attendre.
                // Les setView/resize programmatiques sont ignorés (sinon overlay bloqué).
                if (!tcIsGesture()) return;
                tcExpectServer = true; tcServerIdle = false;
                tcStartCycle();
              }
              function tcBindMap(m){
                function tcBindLayer(layer){
                  if (layer && window.L && L.GridLayer && layer instanceof L.GridLayer){
                    layer.on('loading', function(){
                      if (tcVisible()){ tcExpectTiles = true; tcTiles = false; tcStartCycle(); }
                    });
                    // 'load' fiable seulement carte VISIBLE (onglet caché -> 0 tuile)
                    layer.on('load', function(){
                      if (tcActive && tcVisible()){
                        if (tcShownAt === null) tcShownAt = tcNow();
                        tcTiles = true; tcMaybeHide();
                      }
                    });
                  }
                }
                m.eachLayer(tcBindLayer);
                m.on('layeradd', function(e){
                  tcBindLayer(e.layer);
                  if (e.layer && !(window.L && L.GridLayer && e.layer instanceof L.GridLayer)){
                    tcSites = true; tcMaybeHide();
                  }
                });
                m.on('movestart zoomstart moveend zoomend', tcOnViewChange);
              }
              // La carte n'est pas toujours retrouvable au onRender : on réessaie.
              (function tcWaitMap(tries){
                var m = (typeof getLeafletMapById === 'function') ? getLeafletMapById(el.id) : null;
                if (m){ tcBindMap(m); return; }
                if (tries < 80){ setTimeout(function(){ tcWaitMap(tries + 1); }, 100); }
              })(0);
            } catch(tcErr){ if (window.console) console.warn('[tc-map-loading]', tcErr); }
          }
        ")
    })
    
    session$onFlushed(function(){
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
    }, once = FALSE)
    
    outputOptions(output, "map", suspendWhenHidden = FALSE)
    
    # S'assurer que la toolbar est présente quand la carte devient visible
    # 2. Modifier l'observeEvent(input$map_shown) existant (vers ligne 480)
    # Pour qu'il recadre la carte à chaque fois que l'onglet devient visible
    observeEvent(input$map_shown, {
      debug_print("observeEvent(input$map_shown) -> Recalcul Vue")
      
      # Invalide la taille pour corriger le fond gris
      session$sendCustomMessage("invalidate-map", list(id = ns(MAP_ID)))
      
      roles <- user_roles()
      site_id <- site_id_edition()
      is_rs_on_site <- can_edit_site()
      
      if (isTruthy(site_id_edition()) && isTRUE(is_rs_on_site)) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          removeDrawToolbar() %>%
          add_std_draw_toolbar(polygon = TRUE)   # polygone rouge (périmètre) + rectangle bleu (sélection)
      }

      # Les couches ont pu être dessinées alors que l'onglet était MASQUÉ :
      # Leaflet ne rend rien dans un conteneur de taille nulle, et le
      # court-circuit par hash croit ensuite la couche à jour — la carte reste
      # vide jusqu'à un changement de site. C'est ce qui arrivait après la
      # promotion d'un secteur, qui bascule sur cet onglet depuis un autre.
      # On invalide donc les hachages et on redessine à l'affichage.
      if (isTruthy(site_id)) {
        invalidate_site_layer_hash(ns("map"), session)
        invalidate_perim_layer_hash(ns("map"), session)
        draw_parcelles_site(parcelles_site_data(), map_id = ns("map"),
                            session = session, user_roles = roles)
        draw_perimetres_manuels(perimetres_manuelles_data(), map_id = ns("map"),
                                session = session)
        draw_perimetre()
        draw_contour()
        session$sendCustomMessage("invalidate-map", list(id = ns(MAP_ID)))
        # Recadrage. remap() a bien tourné au changement de site, mais pendant
        # que l'onglet était masqué — un fitBounds sur une carte de taille nulle
        # ne va nulle part. Les couches étaient donc dessinées hors du champ
        # visible, ce qui donnait une carte vide à l'œil.
        #
        # On ne rappelle PAS remap() ici : il enchaîne fitBounds puis
        # invalidation de la taille, ordre qui perd le cadrage sur une carte
        # qui vient d'apparaître. focus_site() fait l'inverse — invalidation,
        # puis fitBounds après un délai, le temps que le conteneur ait sa
        # taille réelle. remap() a déjà renseigné l'emprise dans bbox_site_rv.
        focus_site(site_id)
      }
    }, ignoreInit = TRUE)
    
    output$map_footer <- renderUI({
      is_rs_on_site <- can_edit_site()
      if(!isTRUE(is_rs_on_site)) return()
      
      req(site_id_edition())
      
      nb_sel  <- length(parcelles_selectionnees())
      nb_poly <- length(polygones_manuels_temp())
      has_any <- (nb_sel + nb_poly) > 0

      nb_pp   <- length(perimetre_selection())
      nb_ps   <- length(site_selection())
      has_ps  <- nb_ps > 0
      # La bascule vers la continuité n'est offerte que si la maîtrise n'est
      # acquise sur AUCUNE des parcelles retenues : toutes leurs liaisons de
      # contrat doivent être en élaboration. C'est la règle qu'appliquait la
      # modale du clic, conservée ici pour une sélection entière.
      bascule_ok <- has_ps && .site_sel_bascule_possible(site_selection())
      has_pp  <- nb_pp > 0

      tagList(
        div(
          class = "map-footer",                     #' ← classe commune
          #' ⬅️ Colonne sélecteur
          div(
            class = "field-stack",                  #' ← empile label + input, collés en bas
            tags$label("🔍 Filtrer par propriétaire :", `for` = ns("proprio_selector")),
            selectInput(
              ns("proprio_selector"),
              label = NULL,
              choices = c("Aucun" = "", names(isolate(dico_proprio_global())))
            )
          ),

          div(class = "spacer"),                    #' ← pousse les boutons à droite

          #' ➡️ Boutons (uniquement s'il y a qqch)
          if (has_any) {
            div(
              style = "display:flex; align-items:flex-end; gap:8px;",
              actionButton(ns("save_selection"),  "💾 Ajouter au site", class = "btn btn-success btn-sm"),
              if (nb_sel > 0) {
                actionButton(ns("add_to_perimetre"),
                             sprintf("🎯 Ajouter à la continuité du site conservatoire (%d)", nb_sel),
                             class = "btn btn-warning btn-sm")
              },
              actionButton(ns("clear_selection"), "❌ Vider la sélection",       class = "btn btn-default btn-secondary btn-sm")
            )
          }
        ),

        #' Actions sur la sélection de la continuité du site conservatoire (parcelles oranges)
        if (has_pp) {
          div(
            style = "margin-top:10px; padding-top:8px; border-top:1px solid var(--c-trait);
                     display:flex; align-items:center; gap:8px; flex-wrap:wrap;",
            tags$span(style = "color:#c2410c; margin-right:auto;",
                      HTML(sprintf("🎯 Continuité du site conservatoire sélectionnée : <strong>%d</strong>", nb_pp))),
            actionButton(ns("bascule_open"),
                         sprintf("➡️ Basculer en parcelles du site (%d)", nb_pp),
                         class = "btn btn-primary btn-sm"),
            actionButton(ns("perimetre_retirer"),
                         sprintf("🗑 Retirer de la continuité du site conservatoire (%d)", nb_pp),
                         class = "btn btn-danger btn-sm"),
            if (nb_pp == 1) {
              actionButton(ns("perimetre_editer"), "✏️ Modifier",
                           class = "btn btn-default btn-secondary btn-sm")
            },
            actionButton(ns("clear_perimetre_selection"), "❌ Vider",
                         class = "btn btn-default btn-secondary btn-sm")
          )
        },

        if (has_ps) {
          div(
            style = "margin-top:10px; padding-top:8px; border-top:1px solid var(--c-trait);
                     display:flex; align-items:center; gap:8px; flex-wrap:wrap;",
            tags$span(style = "color:#b91c1c; margin-right:auto;",
                      HTML(sprintf("📍 Parcelles du site sélectionnées : <strong>%d</strong>", nb_ps))),
            actionButton(ns("site_sel_modifier"),
                         sprintf("✏️ Modifier les infos (%d)", nb_ps),
                         class = "btn btn-primary btn-sm"),
            if (isTRUE(bascule_ok)) {
              actionButton(ns("site_sel_basculer"),
                           sprintf("➡️ Basculer en continuité (%d)", nb_ps),
                           class = "btn btn-default btn-secondary btn-sm")
            },
            actionButton(ns("site_sel_retirer"),
                         sprintf("🗑 Retirer du site (%d)", nb_ps),
                         class = "btn btn-danger btn-sm"),
            actionButton(ns("site_sel_vider"), "❌ Vider",
                         class = "btn btn-default btn-secondary btn-sm")
          )
        }
      )
    })
    
    
    #' -------------------------
    #' Message associer parcelles
    #' -------------------------
    output$msg_associer_parcelles <- renderUI({
      is_rs_on_site <- can_edit_site()
      if(!isTRUE(is_rs_on_site)) return()
      
      req(site_id_edition())
      if (!is.null(site_id_edition()) && !is.na(site_id_edition())) {
        nom_site <- safe_db_query(con, glue::glue_sql("SELECT libelle FROM gestcons.sites WHERE id = {site_id_edition()}", .con = con))$libelle[1]
        tagList(
          tags$div(
            style = "margin: 12px 0; font-size: 1.1em; color: var(--c-accent);",
            HTML(glue(
              'Associez des parcelles au site <strong>{nom_site}</strong> ' ,
              'soit en <u>cliquant</u> sur la carte, soit via un propriétaire, ',
              'soit en <u>traçant un rectangle</u> pour sélectionner en masse.'
            ))
          )
        )
      } else {
        NULL
      }
    })
    
    #' -------------------------
    #' Résumé site
    #' -------------------------
    output$resume_site <- renderUI({
      req(site_id_edition())
      resume_site_trigger()
      # Canal commun : les nombres et surfaces du résumé changent à CHAQUE
      # écriture de parcelle, y compris celles faites depuis un autre onglet ou
      # par un chemin qui n'incrémente pas resume_site_trigger (l'enregistrement
      # d'une sélection et des polygones dessinés, notamment).
      if (!is.null(contrats_update_trigger)) contrats_update_trigger()
      build_resume_site_ui(con, site_id_edition())
    })
    
    
    
    # Texte d’aide quand aucun site n’est sélectionné
    output$sites_helper_text <- renderUI({
      # Aucun site si NULL ou valeur "" (vide contrôlé)
      #if (is.null(input$site_selector) || identical(input$site_selector, "")) {
      tags$p(
        class = "text-muted",
        "Ce module vous permet de gérer les sites conservatoires que vous gérez. ",
        actionLink(ns("sites_help"), "En savoir plus...")
      )
      #} else {
      #  NULL
      #}
    })
    
    observeEvent(input$map_groups, {
      
      groupes_protection <- grep(paste0("^", PROTECTION_PREFIXE), input$map_groups, value = TRUE)
      types_protection   <- sub(paste0("^", PROTECTION_PREFIXE), "", groupes_protection)
      legende_protection <- if (length(types_protection)) dico_protection_legend_html(types_protection)
      # Un type coché dont la couleur est inconnue ne produit aucune légende :
      # on n'ajoute pas un contrôle vide.
      is_protection_visible <- !is.null(legende_protection)
      
      proxy <- leaflet::leafletProxy(ns(MAP_ID), session = session)
      
      # Layer ID pour la légende, qui doit être unique au module
      LEGEND_LAYER_ID <- "dico_protection_custom_control"
      
      # 1. Toujours retirer l'ancienne version du contrôle
      proxy %>% leaflet::removeControl(layerId = LEGEND_LAYER_ID)
      
      # 2. Si la couche est cochée, ajouter le contrôle Leaflet (qui le positionne correctement)
      if (is_protection_visible) {
        
        proxy %>% leaflet::addControl(
          html = legende_protection,
          position = "bottomleft", # Position classique pour les légendes
          layerId = LEGEND_LAYER_ID,
          className = ""
        )
      }
      
      # L'événement force le recalcul du rendu des polygones par Leaflet, 
      # mais assure aussi que notre légende est bien positionnée dans le DOM de la carte.
      debug_print(paste("Leaflet map groups changed:", paste(input$map_groups, collapse = ", ")))
    }, ignoreInit = FALSE)
    
    # Clic sur "En savoir plus..." → ouvre le modal d'aide
    observeEvent(input$sites_help, {
      show_help_sites_modal()
    })
    
    # Parcelles déjà associées au site ET intersectant la bbox (en 2154 côté BD)
    select_site_features_in_bbox <- function(xmin, ymin, xmax, ymax) {
      sid <- site_id_edition()
      if (is.null(sid) || is.na(sid)) return(data.frame())
      
      env2154 <- glue::glue(
        "ST_Transform(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)"
      )
      
      sql <- glue::glue("
        SELECT
          p.id                               AS parcelle_db_id,
          p.type_parcelle_id,
          CASE
            WHEN p.type_parcelle_id = 1 THEN c.idpar::text
            ELSE pm.id::text
          END                                 AS code_affiche
        FROM gestcons.parcelles p
        LEFT JOIN gestcons.dico_cadastre c
          ON p.type_parcelle_id = 1 AND c.id = p.parcellaire_id
        LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
          ON p.type_parcelle_id = 2 AND pm.id = p.parcellaire_id
        WHERE p.site_id = {sid}
          AND (
            (p.type_parcelle_id = 1 AND c.geompar && {env2154} AND ST_Intersects(c.geompar, {env2154}))
            OR
            (p.type_parcelle_id = 2 AND pm.geometrie && {env2154} AND ST_Intersects(pm.geometrie, {env2154}))
          )
      ")
      
      tryCatch(dbGetQuery(con, sql), error = function(e) data.frame())
    }
    
    select_parcelles_in_bbox <- function(xmin, ymin, xmax, ymax) {
      # Utiliser near() pour comparer les valeurs flottantes
      if (near(xmin, xmax, tol = 1e-6) || near(ymin, ymax, tol = 1e-6)) {
        showToast("warning", "Sélection invalide", "Le rectangle est trop petit. Veuillez redessiner.")
        return(character(0))
      }
      
      # Envelope en 2154 (pré-calcul pour réutilisation)
      env2154 <- glue("
        ST_Transform(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)
      ")

      # Exclusions : parcelles déjà dans UN site (vue parcelles) + parcelles du
      # continuité du site conservatoire de CE site (gérées par leurs propres actions : bascule…)
      sid_peri <- site_id_edition()
      excl_peri <- if (isTruthy(sid_peri)) glue("
          AND c.id NOT IN (
            SELECT parcellaire_id FROM gestcons.parcelles_base
            WHERE perimetre AND site_id = {sid_peri}
          )") else ""

      # 1) Compter avec pré-filtre bbox (index) + test exact ST_Intersects
      q_count <- glue("
        SELECT COUNT(*) AS n
        FROM gestcons.dico_cadastre c
        WHERE c.geompar && {env2154}
          AND ST_Intersects(c.geompar, {env2154})
          AND c.id NOT IN (
            SELECT parcellaire_id FROM gestcons.parcelles
          )
          {SQL(excl_peri)}
      ")
      
      n <- tryCatch({
        dbGetQuery(con, q_count)$n[1]
      }, error = function(e) {
        showToast("error", "Erreur SQL", paste("Impossible de compter les parcelles :", e$message))
        0L
      })
      
      if (is.na(n) || n == 0) return(character(0))
      
      if (n > MAX_PARCELLES_RECTANGLE) {
        showToast("warning", "Sélection trop large",
                  glue("Le rectangle couvre {n} parcelles potentielles. Zoomez ou réduisez l'emprise."))
        return(character(0))
      }
      
      # 2) Récupérer les idpar avec le même double test (bbox + intersects)
      q_ids <- glue("
        SELECT c.idpar
        FROM gestcons.dico_cadastre c
        WHERE c.geompar && {env2154}
          AND ST_Intersects(c.geompar, {env2154})
          AND c.id NOT IN (
            SELECT parcellaire_id FROM gestcons.parcelles
          )
          {SQL(excl_peri)}
      ")
      
      ids <- tryCatch({
        dbGetQuery(con, q_ids)$idpar
      }, error = function(e) {
        showToast("error", "Erreur SQL", paste("Impossible de récupérer les parcelles :", e$message))
        character(0)
      })
      
      unique(ids)
    }
    
    
    # petit utilitaire local
    .near0 <- function(a, b, tol = 1e-6) isTRUE(abs(a - b) <= tol)
    
    # traite une bbox: selon shift -> ajout sélection (cadastre) OU suppression (éléments du site)
    .handle_rectangle_bbox <- function(xmin, ymin, xmax, ymax, with_shift) {
      # Nettoyage de la forme dessinée — à appeler sur TOUTES les sorties (y
      # compris anticipées : rectangle trop petit, zoom insuffisant, aucune
      # parcelle), sinon le rectangle reste affiché sur la carte.
      clear_rect <- function() {
        session$sendCustomMessage('clear-polygones', ns("map"))
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Polygones") %>%
          clearGroup("drawnItems") %>%
          clearGroup("drawn")
      }

      # rectangle trop petit ?
      if (.near0(xmin, xmax) || .near0(ymin, ymax)) {
        clear_rect()
        showToast("warning", "Sélection invalide", "Le rectangle est trop petit. Veuillez redessiner.")
        return(invisible(NULL))
      }
      
      if (isTRUE(with_shift)) {
        # === MODE ⇧ : cibler ce qui est déjà lié AU SITE dans la bbox ===
        if (.autre_selection_en_cours("site")) {
          clear_rect()
          return(invisible(NULL))
        }
        rows <- select_site_features_in_bbox(xmin, ymin, xmax, ymax)
        clear_rect()

        if (is.null(rows) || nrow(rows) == 0) {
          showToast("info", "Rien à sélectionner", "Aucun élément du site dans cette emprise.")
          return(invisible(NULL))
        }

        # Une emprise peut recouvrir des parcelles cadastrales ET des polygones
        # dessinés. On n'en retient qu'une nature : celle déjà en cours, sinon
        # les parcelles cadastrales, le cas courant. Ce qui est écarté est dit,
        # faute de quoi l'utilisateur croirait avoir tout pris.
        type_cur <- isolate(site_selection_type())
        if (is.na(type_cur) || !length(isolate(site_selection()))) {
          type_cur <- if (any(rows$type_parcelle_id == 1L)) 1L else 2L
        }
        n_avant <- nrow(rows)
        rows <- rows[rows$type_parcelle_id == type_cur, , drop = FALSE]
        if (!nrow(rows)) {
          showToast("warning", "Sélection d'une seule nature",
                    sprintf(paste0("Cette emprise ne contient que des %s, et une ",
                                   "sélection de %s est en cours. Videz-la (❌ Vider) d'abord."),
                            .site_type_libelle(if (identical(type_cur, 1L)) 2L else 1L),
                            .site_type_libelle(type_cur)))
          return(invisible(NULL))
        }
        ecartes <- n_avant - nrow(rows)

        # Le rectangle ALIMENTE la sélection, il ne décide de rien : c'est le
        # pied de carte qui propose ensuite de retirer, de modifier ou de
        # basculer. Même convention que le rectangle de l'onglet Stratégie.
        codes <- as.character(rows$code_affiche)
        codes <- codes[!is.na(codes) & nzchar(codes)]
        site_selection(unique(c(isolate(site_selection()), codes)))
        site_selection_type(type_cur)
        draw_site_selection()
        showToast("success", "Sélection",
                  sprintf("%d %s ajouté(s) à la sélection.%s",
                          length(codes), .site_type_libelle(type_cur),
                          if (ecartes > 0)
                            sprintf(" %d élément(s) d'une autre nature écarté(s).", ecartes)
                          else ""))
        return(invisible(NULL))

      } else {
        # === MODE normal : sélectionner dans le CADASTRE (non encore liés au site) ===

        # Garde de zoom : même règle que la sélection au clic. Sous
        # ZOOM_CADASTRE_MIN le cadastre n'est pas affiché -> le rectangle
        # sélectionnerait « à l'aveugle » des parcelles invisibles.
        z <- input$map_zoom
        if (is.null(z) || z < ZOOM_CADASTRE_MIN) {
          clear_rect()
          showToast("warning", "Zoom insuffisant",
                    "Zoomez davantage (parcelles cadastrales visibles) avant de sélectionner au rectangle.")
          return(invisible(NULL))
        }

        # Exclusivité : une seule nature de sélection à la fois (cf. clics)
        if (.autre_selection_en_cours("candidates")) {
          clear_rect()
          return(invisible(NULL))
        }

        nouvelles <- select_parcelles_in_bbox(xmin, ymin, xmax, ymax)  # vecteur idpar
        if (length(nouvelles) == 0) {
          clear_rect()
          showToast("info", "Aucune parcelle", "Aucune parcelle trouvée dans cette emprise (hors éléments déjà liés au site).")
          return(invisible(NULL))
        }

        selection_complete <- unique(c(parcelles_selectionnees(), nouvelles))
        parcelles_selectionnees(selection_complete)
        showToast("success", "Sélection mise à jour",
                  glue::glue("{length(nouvelles)} parcelle(s) ajoutée(s) — {length(selection_complete)} sélectionnée(s) au total."))

        # rafraîchit l'habillage « Parcelle sélectionnée » via le cache incrémental
        # (pas de clearGroup ici : il désynchroniserait le cache, cf. helpers.R)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        draw_parcelles_selectionnees(parcelles_selectionnees(), con = con, map_id = ns("map"),
                                     session = session, user_roles = user_roles())

        clear_rect()
      }

      invisible(NULL)
    }
    
    # Les tracés en attente s'affichent DEPUIS L'ÉTAT, et non plus par la forme
    # de Leaflet.Draw : cf. draw_traces_en_attente (helpers.R).
    observe({ draw_traces_en_attente(polygones_manuels_temp(), ns("map"), session) })

    observeEvent(input$map_draw_new_feature, {
      debug_print("observeEvent(input$map_draw_new_feature)")
      feat <- input$map_draw_new_feature
      if (is.null(feat)) return(invisible(NULL))
      
      ftype <- tryCatch(tolower(as.character(feat$properties$feature_type)), error = function(e) "")
      if (identical(ftype, "polygon")) {
        # Périmètres manuels : on empile tels quels, puis on retire aussitôt la
        # forme de Leaflet.Draw. Elle vivait dans « Polygones », que le rectangle
        # de sélection vide après chaque usage : le tracé disparaissait de
        # l'écran en restant dans l'état, et partait à l'enregistrement sans
        # avoir été revu. C'est l'observateur ci-dessus qui l'affiche désormais.
        # Refusé si une sélection de parcelles est en cours : la forme est
        # retirée, et le toast nomme la sélection à vider.
        if (.autre_selection_en_cours("traces")) {
          session$sendCustomMessage('clear-polygones', ns("map"))
          leafletProxy(mapId = ns("map"), session = session) %>%
            clearGroup("Polygones") %>%
            clearGroup("drawnItems") %>%
            clearGroup("drawn")
          return(invisible(NULL))
        }
        polygs <- polygones_manuels_temp()
        polygs[[length(polygs) + 1]] <- feat
        polygones_manuels_temp(polygs)
        session$sendCustomMessage('clear-polygones', ns("map"))
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Polygones") %>%
          clearGroup("drawnItems") %>%
          clearGroup("drawn")
        return(invisible(NULL))
      }
      
      if (identical(ftype, "rectangle")) {
        # bbox depuis les coords du rectangle Leaflet
        coords <- feat$geometry$coordinates[[1]]
        lng <- vapply(coords, function(pt) as.numeric(pt[[1]]), numeric(1))
        lat <- vapply(coords, function(pt) as.numeric(pt[[2]]), numeric(1))
        xmin <- min(lng); xmax <- max(lng)
        ymin <- min(lat); ymax <- max(lat)
        
        # état ⇧ exposé par onRender() -> input$shift_pressed
        with_shift <- isTRUE(input$shift_pressed)
        
        .handle_rectangle_bbox(xmin, ymin, xmax, ymax, with_shift)
        return(invisible(NULL))
      }
      
      invisible(NULL)
    }, ignoreInit = TRUE)
    
    # (Un observer mettait ici à jour un sélecteur « site_contract_selector »
    # qui n'existe dans aucune interface — supprimé.)

    #' -------------------------
    #' Zoom sur commune
    #' -------------------------
    observeEvent(input$commune_selector, {
      parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
      parcelles_cache_bbox(NULL)
      req(input$commune_selector, input$commune_selector != "")
      # Emprise de la commune via le helper commun (ST_Extent côté PostGIS)
      bbox <- get_bbox_4326(con, glue::glue(
        "SELECT geompar AS g FROM gestcons.dico_cadastre
          WHERE idcomtxt = {DBI::dbQuoteString(con, input$commune_selector)}"))
      if (!is.null(bbox)) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          fitBounds(lng1 = bbox[1], lat1 = bbox[2], lng2 = bbox[3], lat2 = bbox[4])
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
      } else {
        showToast("warning", "Pas d’emprise", "Aucune parcelle trouvée pour cette commune.")
      }
    })
    
    .sites_is_empty <- function(x) {
      is.null(x) || is.na(x) || identical(x, "") || identical(as.character(x), "")
    }
    
    observe({
      val <- input$site_selector
      hide <- is.null(val) || is.na(val) || !nzchar(val)
      session$sendCustomMessage('toggle-layer-overlays', list(id = ns('map'), hide = hide))
    })
    
    #' -------------------------
    #' Bouton Réinitialiser
    #' -------------------------
    observeEvent(input$reset_site, {
      debug_print("observeEvent(input$reset_site")
      selected_site_rv(NULL)
    })
    
    #' -------------------------
    #' Ajouter / Modifier site
    #' -------------------------
    observeEvent(input$add_site, {
      show_site_form_modal(site_id = NULL)
    })
    
    observeEvent(input$edit_site, {
      current_id <- site_id_edition()
      if (!is.null(current_id) && !is.na(current_id)) {
        show_site_form_modal(current_id)
      } else {
        showToast("error", "Aucun site sélectionné", "Impossible de modifier : aucun site actif.")
      }
    })
    
    #' -------------------------
    #' Sélection d'un site via le sélecteur
    #' -------------------------
    observeEvent(input$site_selector, {
      debug_print("observeEvent(input$site_selector")
      if (identical(input$site_selector, "") && isTRUE(ignorer_vide_selecteur())) {
        # Vide passager d'un remplacement de choix : on l'absorbe UNE fois.
        # La vraie valeur suit dans le même aller-retour.
        ignorer_vide_selecteur(FALSE)
        return(invisible(NULL))
      }
      ignorer_vide_selecteur(FALSE)
      if (input$site_selector == "") {
        selected_site_rv(NULL)
        site_id_edition(NULL)
        bbox_site_rv(NULL)
        updateTextInput(session, "libelle", value = "")
        updateSelectInput(session, "type_milieu_id", selected = "")
        updateSelectInput(session, "geologie_id", selected = "")
        updateSelectInput(session, "nature_perimetre_id", selected = default_nature_perimetre)
        updateSelectInput(session, "echelle_num_id", selected = default_echelle)
        updateSelectInput(session, "precision_num_site_id", selected = default_precision)
        updateSelectInput(session, "gestionnaire_site", selected = default_cen)
        updateCheckboxInput(session, "terrain_militaire", value = FALSE)
        updateCheckboxInput(session, "site_marin", value = FALSE)
        updateDateInput(session, "date_crea_site", value = Sys.Date())
        updateDateInput(session, "date_maj_site", value = Sys.Date())
        updateTextAreaInput(session, "description_site", value = "")
        updateTextInput(session, "cree_par", value = "")
        updateTextInput(session, "modifie_par", value = "")
        parcelles_site_data(NULL)
        perimetres_manuelles_data(NULL)
        parcelles_selectionnees(character(0))
        polygones_manuels_temp(list())
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelles du site") %>%
          clearGroup("Parcelles cadastrales") %>%
          setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = MAP_DEFAULT_ZOOM)
        invalidate_cadastre_hash(ns("map"), session)
        invalidate_site_layer_hash(ns("map"), session)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

      } else {
        #' Utilisez req pour vous assurer que la valeur n'est pas NULL
        new_site_id <- tryCatch({ as.integer(req(input$site_selector)) }, error = function(e) NULL)
        if (!is.null(new_site_id)) selected_site_rv(new_site_id)
        
        if (!is.null(new_site_id) && !is.na(new_site_id)) {
          site_id_edition(new_site_id)
        }
      }
    })
    
    observeEvent(site_id_edition(), {
      debug_print("observeEvent(site_id_edition")
      
      # --- Détermination des droits ---
      roles <- user_roles()
      site_id <- site_id_edition()
      is_rs_on_site <- can_edit_site()
      
      parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
      parcelles_cache_bbox(NULL)
      leafletProxy(mapId = ns("map"), session = session) %>% removeDrawToolbar()
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      
      if (isTruthy(site_id_edition())) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          hideGroup("Sites existants") %>%
          showGroup(c("Parcelles du site", "Continuité du site conservatoire", "Périmètre sélectionné",
                      "Périmètres manuels", "Parcelle sélectionnée", "Polygones"))
        # NB : « Contour » volontairement absent du showGroup -> masqué par
        # défaut, activable via le contrôle de couches (il est dessiné quoi
        # qu'il arrive ; la visibilité du groupe fait le reste).

        # ✅ Afficher la légende en passant l'ID namespacé
        add_site_legend(ns("map"), session, layer_id = LEGEND_ID, include_perimetre = TRUE)

        # ❌ L'appel à draw_dico_protection est RETIRÉ D'ICI (pour la performance)
        # Ancienne ligne: draw_dico_protection(con, map_id = ns("map"), session = session, zones_protection_data)

      } else {
        leafletProxy(mapId = ns("map"), session = session) %>%
          showGroup("Sites existants") %>%
          hideGroup(c("Parcelles du site", "Continuité du site conservatoire", "Contour", "Périmètre sélectionné",
                      "Périmètres manuels", "Parcelle sélectionnée", "Parcelles cadastrales"))
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
        draw_circles(con, map_id = ns("map"), zoom = input$map_zoom)
        session$sendCustomMessage("tc-sites-ready", ns("map"))
        
        # ✅ Masquer la légende en utilisant l'ID namespacé
        remove_legend(ns("map"), session, layer_id = LEGEND_ID) 
      }
      
      # 🚨 CONTRÔLE D'AFFICHAGE DE LA BARRE D'OUTILS 🚨
      leafletProxy(mapId = ns("map"), session = session) %>% removeDrawToolbar()
      
      if (isTruthy(site_id_edition()) && isTRUE(is_rs_on_site)) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          add_std_draw_toolbar(polygon = TRUE)   # polygone rouge (périmètre) + rectangle bleu (sélection)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
      } else {
        leafletProxy(mapId = ns("map"), session = session) %>% removeDrawToolbar()
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
      }
      
      load_parcelles_sites()
      load_perimetres_manuels()

      # Changement de site -> la sélection de parcelles de continuité ne vaut plus
      clear_perimetre_selection()

      if (isTruthy(site_id_edition())) {
        remap()
        # 🟢 NOUVEAU : Déclenchement du chargement asynchrone des zones de protection
        draw_protection_trigger(draw_protection_trigger() + 1)

      } else {
        leafletProxy(mapId = ns("map"), session = session) %>%
          clear_groups(c("Parcelles du site", "Périmètres manuels", "Continuité du site conservatoire", "Contour", "Périmètre sélectionné"))
        invalidate_site_layer_hash(ns("map"), session)
        invalidate_perim_layer_hash(ns("map"), session)
        # Vide AUSSI l'état de la sélection (pas seulement affichage + cache) :
        # une sélection conservée invisible ressurgissait intégralement au
        # prochain rectangle ou au prochain pan (redraw de conservation) ->
        # « parcelles hors rectangle sélectionnées ».
        clear_selection()
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      }
    })

    # --- NOUVEAU Bloc pour le chargement des Zones de Protection (Asynchrone) ---
    # Ceci s'exécutera APRÈS que le code de l'Étape 2 soit terminé.
    # --- Bloc pour le chargement des Zones de Protection (Asynchrone) ---
    observeEvent(draw_protection_trigger(), {
      # On ignore le trigger initial (valeur 0)
      req(draw_protection_trigger() > 0)
      
      # S'assurer qu'un site est sélectionné
      req(isTruthy(site_id_edition()))
      
      # 🟢 CORRECTION : Passez zones_protection_data en argument
      draw_dico_protection(con, map_id = ns("map"), session = session, zones_protection_data)
      
    }, ignoreInit = TRUE)
    
    #' -------------------------
    #' Rafraîchir les choix du sélecteur de sites
    #' -------------------------
    # Rafraîchisseur de la liste des sites (fabrique commune, helpers.R)
    refresh_sites_choices <- make_refresh_sites_choices(con, session, input)
    
    #' -------------------------
    #' Formulaire (modal) Site
    #' -------------------------
    show_site_form_modal <- function(site_id = NULL) {
      #' Optionnel : rafraîchir pour être sûr d'avoir la dernière version des utilisateurs
      try(refresh_dico_utilisateur(), silent = TRUE)
      
      #' Initialisation des informations par défaut
      infos <- list(
        libelle = "",
        id_site_fcen = "",
        type_milieu_id = "",
        geol_id = "",
        nature_perimetre_id = default_nature_perimetre,
        echelle_num_id = default_echelle,
        precision_num_site_id = default_precision,
        gestionnaire_site = default_cen,
        terrain_militaire_id = 0,
        site_marin_id = 0,
        date_crea_site = Sys.Date(),
        date_maj_site = Sys.Date(),
        description_site = "",
        # ⚠️ Liste FERMÉE : seules ces clés sont recopiées depuis la ligne du
        # site (boucle plus bas). Une colonne absente d'ici ne serait jamais
        # relue — le formulaire s'ouvrirait décoché, et l'enregistrement
        # remettrait la valeur par défaut en silence.
        sensibilite = FALSE,
        non_diffusion = FALSE,
        remq_sensibilite = "",
        accessibilite_site = ACCESSIBILITE_SITE_DEFAUT,
        accessibilite_pmr_site = 0,
        responsable_user_id = NULL,
        responsable_date_debut = Sys.Date(),
        benevole_user_id = NULL,
        benevole_date_debut = Sys.Date(),
        animateurs_user_ids = integer(0)
      )
      
      #' Initialisation des données pour le statut actuel
      statut_actuel <- data.frame(
        statut_site_id = integer(0),
        libelle = character(0),
        date_debut = as.Date(character(0)),
        remarque = character(0)
      )
      
      #' Lecture de la liste des utilisateurs depuis le reactiveVal passé au module
      current_dico_utilisateur <- isolate(dico_utilisateur_rv())
      if (is.null(current_dico_utilisateur)) {
        current_dico_utilisateur <- data.frame(
          id = integer(0),
          nom_complet = character(0),
          stringsAsFactors = FALSE
        )
      } else {
        #' robustesse : si nom_complet manquant
        if (!("nom_complet" %in% names(current_dico_utilisateur))) {
          current_dico_utilisateur$nom_complet <- ""
        }
      }
      
      #' Si un site_id est fourni, récupérer les informations existantes
      if (!is.null(site_id)) {
        db_infos <- tryCatch({
          dbGetQuery(con, glue::glue_sql("SELECT * FROM gestcons.sites WHERE id = {site_id}", .con = con))
        }, error = function(e) data.frame())
        
        if (nrow(db_infos) > 0) {
          for (n in names(infos)) {
            if (n %in% names(db_infos)) {
              infos[[n]] <- db_infos[[n]][1]
            }
          }
        }
        
        #' Récupération du statut actuel du site
        statut_actuel <- tryCatch({
          dbGetQuery(con, glue("
            SELECT ss.statut_site_id, ds.libelle, ss.date_debut, ss.remarque
            FROM gestcons.sites_statuts ss
            JOIN gestcons.dico_statut_sites ds ON ss.statut_site_id = ds.id
            WHERE ss.site_id = {site_id} AND ss.date_fin IS NULL
            ORDER BY ss.date_debut DESC LIMIT 1
          "))
        }, error = function(e) {
          data.frame(
            statut_site_id = integer(0),
            libelle = character(0),
            date_debut = as.Date(character(0)),
            remarque = character(0)
          )
        })
        
        #' Récupération du responsable actuel du site
        resp <- tryCatch({
          dbGetQuery(con, glue("
            SELECT user_id, date_debut FROM gestcons.responsable_sites
            WHERE site_id = {site_id} AND actif = TRUE
            LIMIT 1
          "))
        }, error = function(e) data.frame(user_id = integer(0), date_debut = as.Date(character(0))))
        
        if (nrow(resp) > 0) {
          infos$responsable_user_id <- resp$user_id[1]
          infos$responsable_date_debut <- resp$date_debut[1]
        }
        
        #' Récupération du bénévole conservateur actuel du site
        benev <- tryCatch({
          dbGetQuery(con, glue("
            SELECT user_id, date_debut FROM gestcons.conservateur_benevole
            WHERE site_id = {site_id} AND actif = TRUE
            LIMIT 1
          "))
        }, error = function(e) data.frame(user_id = integer(0), date_debut = as.Date(character(0))))
        
        if (nrow(benev) > 0) {
          infos$benevole_user_id <- benev$user_id[1]
          infos$benevole_date_debut <- benev$date_debut[1]
        }
        # Récupération des animateurs actuels du site
        animateurs <- tryCatch({
          dbGetQuery(con, glue("
            SELECT user_id FROM gestcons.animateur_sites
            WHERE site_id = {site_id} AND actif = TRUE
            ORDER BY user_id
          "))
        }, error = function(e) data.frame(user_id = integer(0)))
        
        if (nrow(animateurs) > 0) {
          infos$animateurs_user_ids <- animateurs$user_id
        }
      }
      
      #' Préparation des choix pour Responsable/Bénévole (labels = nom_complet, valeurs = id)
      choices_users <- c("— Aucun —" = "")
      if (nrow(current_dico_utilisateur) > 0) {
        choices_users <- c(
          choices_users,
          setNames(current_dico_utilisateur$id, current_dico_utilisateur$nom_complet)
        )
      }
      
      #' Choix statut
      choices_statut <- c("— Aucun —" = "")
      if (nrow(dico_statut_site) > 0) {
        choices_statut <- c(choices_statut, setNames(dico_statut_site$id, dico_statut_site$libelle))
      }
      
      #' Valeurs réellement posées dans les sélecteurs de rôle, calculées
      #' exactement comme site_form_fields() le fait. Les observateurs de date
      #' s'en servent pour distinguer un choix de l'utilisateur d'une simple
      #' reconstruction du formulaire.
      .valeur_rendue <- function(id) {
        ids <- as.character(current_dico_utilisateur$id)
        if (!is.null(id) && as.character(id) %in% ids) as.character(id) else ""
      }
      resp_rendu(.valeur_rendue(infos$responsable_user_id))
      benev_rendu(.valeur_rendue(infos$benevole_user_id))
      resp_date_rendue(as.Date(infos$responsable_date_debut))
      benev_date_rendue(as.Date(infos$benevole_date_debut))
      form_site_rendu(isolate(form_site_rendu()) + 1L)


      #' Affichage de la modal
      showModal(
        modalDialog(
          title = if (is.null(site_id)) "➕ Ajouter un site" else paste("✏️ Modifier le site", infos$libelle),
          size = "l",
          footer = NULL,
          easyClose = TRUE,
          
          # Champs du formulaire : fabrique PARTAGÉE avec la promotion d'un
          # secteur en site (helpers.R). Le sélecteur de géologie en cascade
          # reste propre à cet onglet, il est donc injecté.
          site_form_fields(
            ns = ns, infos = infos, statut_actuel = statut_actuel,
            dico_type_milieu = dico_type_milieu,
            dico_nature_perimetre = dico_nature_perimetre,
            dico_echelle = dico_echelle, dico_precision = dico_precision,
            dico_cen = dico_cen,
            dico_accessibilite = dico_accessibilite,
            current_dico_utilisateur = current_dico_utilisateur,
            choices_statut = choices_statut, choices_users = choices_users,
            default_echelle = default_echelle,
            default_precision = default_precision,
            default_cen = default_cen,
            default_nature_perimetre = default_nature_perimetre,
            get_comment = get_comment,
            geol_ui = tagList(
              uiOutput(ns("geol_selector_ui")),
              tags$div(style = "display:none;",
                       textInput(ns("geologie_id"), label = NULL,
                                 value = if (!is.null(infos$geol_id) && !is.na(infos$geol_id))
                                           as.character(infos$geol_id) else "")),
              div(class = "geo-breadcrumbs", uiOutput(ns("geo_breadcrumbs")))
            )
          ),
          
          #' Champs cachés (inchangés, après les colonnes)
          tags$div(style = "display: none;", textInput(ns("cree_par"), "ID Caché :", value = "CG")),
          tags$div(style = "display: none;", textInput(ns("modifie_par"), "ID Caché :", value = "CG")),
          
          #' Boutons d'action (centrés/à droite)
          tags$div(
            style = "margin-top: 20px; text-align: right;",
            # Rendus ACTIFS, comme les boutons d'action (mod_actions.R) : les
            # envelopper dans shinyjs::disabled() crée une course, la
            # désactivation étant appliquée après le bind et écrasant la
            # réactivation envoyée par l'observateur. Le bouton restait alors
            # grisé aux ouvertures suivantes de la fiche. C'est l'observateur
            # de validation qui les désactive si un champ obligatoire manque,
            # et il est rejoué à chaque construction du formulaire.
            if (is.null(site_id)) {
              actionButton(ns("create_site"), "✅ Créer ce site", class = "btn btn-primary")
            } else {
              actionButton(ns("update_site"), "💾 Mettre à jour ce site", class = "btn btn-primary")
            }
          )
        )
      )
    }
    
    
    
    #' -------------------------
    #' Remap vue
    #' -------------------------
    #' -------------------------
    #' Remap vue (parcelles cadastrales OU périmètres manuels)
    #' -------------------------
    remap <- function() {
      #' Récupère les jeux éventuels (site, manuels, continuité du site conservatoire)
      sf_parc <- parcelles_site_data()
      sf_perm <- perimetres_manuelles_data()
      sf_peri <- perimetre_data()
      
      #' Helper local : bbox en 4326 si objet valide, sinon NULL
      get_bbox_4326 <- function(sfobj) {
        if (is.null(sfobj)) return(NULL)
        if (inherits(sfobj, "try-error")) return(NULL)
        if (!inherits(sfobj, "sf")) return(NULL)
        if (nrow(sfobj) == 0) return(NULL)
        #' Transforme en 4326 et calcule bbox
        bb <- tryCatch(sf::st_bbox(sf::st_transform(sfobj, 4326)), error = function(e) NULL)
        if (is.null(bb)) return(NULL)
        #' Vérifie finitude
        nums <- suppressWarnings(as.numeric(bb))
        if (any(!is.finite(nums))) return(NULL)
        #' Retourne nommée
        setNames(nums, names(bb))
      }
      
      b1 <- get_bbox_4326(sf_parc)
      b2 <- get_bbox_4326(sf_perm)
      b3 <- get_bbox_4326(sf_peri)

      #' Aucun des trois -> vue par défaut
      if (is.null(b1) && is.null(b2) && is.null(b3)) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          clear_groups(c("Parcelles du site", "Périmètres manuels")) %>%
          setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = MAP_DEFAULT_ZOOM)
        invalidate_site_layer_hash(ns("map"), session)
        invalidate_perim_layer_hash(ns("map"), session)
        clear_selection()  # état + visuel + cache (sélection invisible sinon)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        return(invisible(NULL))
      }
      
      #' Fusion des bboxes disponibles
      xmin <- min(c(if (!is.null(b1)) b1["xmin"], if (!is.null(b2)) b2["xmin"], if (!is.null(b3)) b3["xmin"]), na.rm = TRUE)
      ymin <- min(c(if (!is.null(b1)) b1["ymin"], if (!is.null(b2)) b2["ymin"], if (!is.null(b3)) b3["ymin"]), na.rm = TRUE)
      xmax <- max(c(if (!is.null(b1)) b1["xmax"], if (!is.null(b2)) b2["xmax"], if (!is.null(b3)) b3["xmax"]), na.rm = TRUE)
      ymax <- max(c(if (!is.null(b1)) b1["ymax"], if (!is.null(b2)) b2["ymax"], if (!is.null(b3)) b3["ymax"]), na.rm = TRUE)
      
      #' Padding léger (3%) pour éviter un zoom trop serré
      dx <- (xmax - xmin) * 0.03
      dy <- (ymax - ymin) * 0.03
      if (!is.finite(dx) || dx == 0) dx <- 0.0005
      if (!is.finite(dy) || dy == 0) dy <- 0.0005
      
      bbox_site_rv(c(xmin = xmin, ymin = ymin, xmax = xmax, ymax = ymax))
      
      leafletProxy(mapId = ns("map"), session = session) %>%
        fitBounds(
          lng1 = as.numeric(xmin - dx),
          lat1 = as.numeric(ymin - dy),
          lng2 = as.numeric(xmax + dx),
          lat2 = as.numeric(ymax + dy)
        )
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      
    }
    
    
    
    load_parcelles_sites <- function() {
      site_id <- site_id_edition()
      if (is.null(site_id) || is.na(site_id)) {
        parcelles_site_data(NULL)
      } else {
        parcelles_site_data(get_parcelles_by_site(site_id, con))
      }
    }
    
    #' -------------------------
    #' Charger périmètres manuels
    #' -------------------------
    load_perimetres_manuels <- function() {
      site_id <- site_id_edition()
      if (is.null(site_id) || is.na(site_id)) {
        perimetres_manuelles_data(NULL)
      } else {
        query <- glue("
      SELECT
        m.id,
        m.remarque,
        m.geometrie,
        p.site_id,
        p.id AS parcelle_db_id,
        EXISTS (
          SELECT 1
          FROM gestcons.contrats_foncier_parcelles cfp
          WHERE cfp.parcelle_id = p.id
        ) AS has_contrat,
        EXISTS (
          SELECT 1
          FROM gestcons.contrats_foncier_parcelles cfp
          JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
          JOIN gestcons.dico_type_statut_contrat ds ON ds.id = cf.statut_id
          WHERE cfp.parcelle_id = p.id
            AND lower(ds.libelle) = 'actif'
        ) AS has_actif,
        EXISTS (
          SELECT 1
          FROM gestcons.contrats_foncier_parcelles cfp
          JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
          JOIN gestcons.dico_type_statut_contrat ds ON ds.id = cf.statut_id
          WHERE cfp.parcelle_id = p.id
            AND lower(ds.libelle) IN ('en cours d''élaboration','en cours d''elaboration')
        ) AS has_draft,
        (
          SELECT NULLIF(string_agg(DISTINCT cf.nom, ', '), '')
          FROM gestcons.contrats_foncier_parcelles cfp
          JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
          WHERE cfp.parcelle_id = p.id
        ) AS contrats_fonciers,
        (
          SELECT NULLIF(string_agg(DISTINCT ca.nom, ', '), '')
          FROM gestcons.contrats_agricoles_parcelles cap
          JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
          WHERE cap.parcelle_id = p.id
        ) AS contrats_agricoles
      ,
        -- Les communes recouvertes, toutes, de la plus grande emprise à la
        -- plus petite : un périmètre tracé ne s'arrête pas aux limites
        -- communales. Calculées par gestcons.parcelles_communes.
        (
          SELECT string_agg(co.nom, ', ' ORDER BY pc.surface_m2 DESC)
          FROM gestcons.parcelles_communes pc
          JOIN gestcons.communes co ON co.insee_com = pc.insee_com
          WHERE pc.parcelle_id = p.id
        ) AS communes
      FROM gestcons.perimetre_parcellaire_manuel m
      JOIN gestcons.parcelles p ON p.parcellaire_id = m.id
      WHERE p.site_id = {site_id} AND p.type_parcelle_id = 2
    ")
        parcelles_manuelles <- tryCatch(st_read(con, query = query), error = function(e) NULL)
        perimetres_manuelles_data(parcelles_manuelles)
      }
    }
    
    show_help_sites_modal <- function() {
      # 1) Cherche le fichier (priorité à www/)
      path <- if (file.exists(file.path("www", "help_sites.html"))) {
        file.path("www", "help_sites.html")
      } else {
        "help_sites.html"
      }
      
      # 2) Prépare le contenu
      body_ui <- if (file.exists(path)) {
        includeHTML(path)  # insère le HTML tel quel
      } else {
        tagList(
          h5("Aide introuvable"),
          p(
            "Placez un fichier ",
            tags$code("help_sites.html"),
            " dans le dossier ",
            tags$code("www/"),
            " ou à la racine de l’application."
          )
        )
      }
      
      # 3) Affiche le modal
      showModal(modalDialog(
        title = "En savoir plus...",
        size = "l",
        easyClose = TRUE,
        footer = NULL,   # fermeture par la croix de l'en-tête
        body_ui
      ))
    }
    
    
    #' -------------------------
    #' Clics carte
    #' -------------------------
    #' --- PATCH clics carte ---
    # Archive.zip/R/mod_sites.R (Remplacement complet de l'observeEvent(input$map_shape_click, {...}) )
    
    observeEvent(input$map_shape_click, {
      debug_print("observeEvent(input$map_shape_click")
      click <- input$map_shape_click
      req(click$id)
      
      #' ID brut et ID normalisé (retire les préfixes de calques)
      raw_id <- as.character(click$id)
      idpar <- sub("^(cad_|sel_|site_|pp_)", "", raw_id)

      #' 👉 Ne touche au sélecteur de site QUE si on clique un site existant
      if (click$group == "Sites existants") {
        updateSelectizeInput(session, "site_selector", selected = idpar)
        site_id_edition(suppressWarnings(as.integer(idpar)))
        formulaire_site_visible(TRUE)
        return()
      }

      # ------------------------------------------------------------------
      # Récupération et vérification des droits (AD ou RS sur le site)
      # Nécessaire pour bloquer la sélection (cas 1) et l'interaction (cas 2)
      roles <- user_roles()
      site_id <- site_id_edition()

      is_rs_on_site <- can_edit_site()

      #' ----------------------------------------------------
      #' 0. Clic sur une parcelle du PÉRIMÈTRE élargi (orange) -> toggle de la
      #'    sélection périmètre (surbrillance rouge). Les actions (basculer /
      #'    retirer / remarque) apparaissent sous la carte. Mêmes droits que
      #'    les parcelles du site (AD ou RS du site).
      #' ----------------------------------------------------
      if (identical(click$group, "Continuité du site conservatoire")) {
        if (!isTruthy(site_id_edition())) return()
        if (!isTRUE(is_rs_on_site)) {
          showToast("warning", "Lecture seule",
                    "Vous n'avez pas les droits (AD/RS) pour agir sur la continuité du site conservatoire.")
          return(invisible(NULL))
        }
        if (.autre_selection_en_cours("continuite")) return(invisible(NULL))
        cur <- perimetre_selection()
        if (idpar %in% cur) {
          perimetre_selection(setdiff(cur, idpar))
        } else {
          perimetre_selection(c(cur, idpar))
        }
        # La couche de base est redessinée AUSSI : c'est elle qui porte les
        # hachures, et leur teinte dépend maintenant de ce qui est retenu.
        draw_perimetre()
        draw_perimetre_selection()
        return()
      }
      
      #' ----------------------------------------------------
      #' 1. Sélection de parcelles cadastrales (Ajout/Retrait de la sélection)
      #' ----------------------------------------------------
      if (click$group %in% c("Parcelles cadastrales", "Parcelle sélectionnée")) {
        if (!isTruthy(site_id_edition())) return()
        
        # 🚨 GARDE 1: Bloquer le toggle de sélection si pas AD/RS 🚨
        roles <- user_roles() # Nécessaire pour obtenir le contexte
        site_id <- site_id_edition() 
        
        if (!isTRUE(is_rs_on_site)) {
          showToast("warning", "Lecture seule", 
                    "Vous n'avez pas les droits (AD/RS) pour modifier la sélection de parcelles cadastrales.")
          return(invisible(NULL))
        }
        # 🚨 FIN DE GARDE 🚨

        # Exclusivité : pas de sélection de candidates pendant une sélection du
        # périmètre (les deux jeux d'actions seraient ambigus).
        if (.autre_selection_en_cours("candidates")) return(invisible(NULL))
        
        cur <- parcelles_selectionnees()
        if (idpar %in% cur) {
          parcelles_selectionnees(setdiff(cur, idpar))
          draw_parcelle_cadastrale(
            idpar = idpar,
            con = con,
            map_id = ns("map"),
            session = session,
            user_roles = user_roles()
          )
        } else {
          # Nouvelle parcelle, on vérifie si elle est déjà affectée ailleurs (logique existante)
          
          # 1. On récupère l'ID interne de la parcelle
          parcelle_interne_id <- safe_db_query(con, glue("
                SELECT id FROM gestcons.dico_cadastre WHERE idpar = {dbQuoteLiteral(con, idpar)}"))$id[1]
          
          # 2. On vérifie si cet ID est déjà dans la table des parcelles
          if (!is.null(parcelle_interne_id) && !is.na(parcelle_interne_id)) {
            assignment_result <- safe_db_query(con, glue("
                        SELECT site_id FROM gestcons.parcelles
                        WHERE parcellaire_id = {parcelle_interne_id}
                        AND type_parcelle_id = 1
                      "))
            
            # 3. Si la parcelle appartient déjà à un site, on bloque : autre site,
            # ou site COURANT (clic arrivé sur le cadastre parce que la couche
            # « Parcelles du site » est masquée -> pas une candidate).
            if (nrow(assignment_result) > 0) {
              site_assigne <- assignment_result$site_id[1]
              if (!is.na(site_assigne) && site_assigne != site_id_edition()) {
                showToast("warning", "Parcelle déjà affectée",
                          "Cette parcelle est déjà rattachée à un autre site et ne peut pas être sélectionnée.")
                return(invisible(NULL))
              }
              if (!is.na(site_assigne) && site_assigne == site_id_edition()) {
                showToast("warning", "Parcelle déjà dans le site",
                          "Cette parcelle fait déjà partie du site (affichez la couche « Parcelles du site » pour la gérer).")
                return(invisible(NULL))
              }
            }

            # 3bis. Déjà dans la continuité du site conservatoire de CE site (clic arrivé sur le
            # cadastre parce que la couche « Continuité du site conservatoire » est masquée) :
            # pas une candidate non plus — même exclusion que le rectangle.
            deja_peri <- safe_db_query(con, glue("
                        SELECT 1 FROM gestcons.parcelles_base
                        WHERE parcellaire_id = {parcelle_interne_id}
                          AND perimetre AND site_id = {site_id_edition()}
                      "))
            if (nrow(deja_peri) > 0) {
              showToast("warning", "Parcelle déjà dans la continuité du site conservatoire",
                        "Cette parcelle est déjà dans la continuité du site conservatoire (affichez la couche « Continuité du site conservatoire » pour la gérer : bascule, retrait, remarque).")
              return(invisible(NULL))
            }
          }
          
          # 4. Si la vérification a réussi, on ajoute la parcelle à la sélection
          parcelles_selectionnees(c(cur, idpar))
        }
        # Pas de clearGroup ici : draw_parcelles_selectionnees gère le delta
        # via son cache incrémental (un clearGroup le désynchroniserait).
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        draw_parcelles_selectionnees(parcelles_selectionnees(), con = con, map_id = ns("map"), session = session, user_roles = user_roles())
        return()
      }
      
      #' ----------------------------------------------------
      #' 2. Clic sur une parcelle DU site ou un périmètre manuel (pour la retirer)
      #' ----------------------------------------------------
      if (click$group %in% c("Parcelles du site", "Périmètres manuels")) {

        if (!isTRUE(is_rs_on_site)) {
          showToast("warning", "Lecture seule",
                    "Vous n'avez pas les droits (AD ou RS) pour agir sur les parcelles du site.")
          return(invisible(NULL))
        }

        if (.autre_selection_en_cours("site")) return(invisible(NULL))

        # Le clic SÉLECTIONNE désormais, au lieu d'ouvrir une modale d'action.
        # Les gestes possibles — retirer du site, modifier les informations,
        # basculer en continuité — vivent dans le pied de carte, comme pour la
        # continuité. Le même geste vaut donc pour une parcelle ou pour vingt.
        #
        # Le groupe Leaflet dit la nature de l'élément cliqué : pas besoin
        # d'interroger la base pour savoir si l'on mélange les genres.
        type_clic <- if (identical(click$group, "Périmètres manuels")) 2L else 1L
        cur <- site_selection()
        if (idpar %in% cur) {
          reste <- setdiff(cur, idpar)
          site_selection(reste)
          if (!length(reste)) site_selection_type(NA_integer_)
        } else {
          if (!.site_type_compatible(type_clic)) return(invisible(NULL))
          site_selection(c(cur, idpar))
          site_selection_type(type_clic)
        }
        draw_site_selection()
        return()
      }
    })
    
    
    #' -------------------------
    #' Sélecteur de contrat (commun)
    #' -------------------------
    #' Une parcelle du site doit toujours être rattachée à un contrat. Le même
    #' sélecteur sert donc à l'ajout de parcelles et à la bascule d'une parcelle
    #' de la continuité du site conservatoire vers le site. Renvoie NULL s'il n'existe aucun
    #' contrat — au caller d'afficher .modal_aucun_contrat().
    .contrat_selector_ui <- function() {
      contrats_existants <- get_contrats(con)
      if (nrow(contrats_existants) == 0) return(NULL)

      # Pré-sélection du contrat de préfiguration du site. Même construction du
      # nom que .create_default_contrat (troncature à 240), sans quoi la
      # pré-sélection ne le retrouverait pas.
      site_id  <- site_id_edition()
      site_nom <- safe_db_query(con, glue::glue_sql(
        "SELECT libelle FROM gestcons.sites WHERE id = {site_id}", .con = con))$libelle[1]
      draft_nom_cible <- glue::glue("Préfiguration {substr(site_nom, 1, 240)}")
      draft_id <- safe_db_query(con, glue::glue("
        SELECT id FROM gestcons.contrats_fonciers
        WHERE nom = {DBI::dbQuoteLiteral(con, draft_nom_cible)}
        LIMIT 1
      "))$id[1]

      selectInput(
        ns("contrat_choisi"),
        "Contrat",
        choices   = setNames(contrats_existants$id, contrats_existants$nom),
        selected  = if (!is.null(draft_id) && !is.na(draft_id)) as.character(draft_id) else NULL,
        selectize = TRUE
      )
    }

    .modal_aucun_contrat <- function() {
      showModal(modalDialog(
        title = "📜 Aucun contrat disponible",
        size = "m",
        easyClose = TRUE,
        footer = NULL,   # fermeture par la croix de l'en-tête
        p("Aucun contrat foncier n’existe encore. Vous devez d’abord créer un contrat, puis revenir enregistrer la sélection.")
      ))
    }

    #' Contrat choisi dans la modale, validé. NULL si absent ou invalide (un
    #' toast a alors déjà été affiché).
    .contrat_choisi_valide <- function() {
      if (is.null(input$contrat_choisi) || !nzchar(trimws(input$contrat_choisi))) {
        showToast("error", "Contrat obligatoire", "Veuillez sélectionner un contrat.")
        return(NULL)
      }
      cid <- suppressWarnings(as.integer(input$contrat_choisi[1]))
      if (!is.finite(cid)) {
        showToast("error", "Contrat invalide", "Le contrat sélectionné est invalide.")
        return(NULL)
      }
      cid
    }

    #' -------------------------
    #' Sauvegarder sélection
    #' -------------------------
    observeEvent(input$save_selection, {
      debug_print("observeEvent(input$save_selection")
      ids   <- parcelles_selectionnees()
      polys <- polygones_manuels_temp()
      
      parcelles_en_attente(ids)
      polygones_en_attente(polys)
      
      #' ⚠️ Contrat obligatoire (PAS de valeur vide possible)
      sel_contrat <- .contrat_selector_ui()
      if (is.null(sel_contrat)) { .modal_aucun_contrat(); return(invisible(NULL)) }

      showModal(
        modalDialog(
          title = "📜 Associer les parcelles à un contrat (obligatoire)",
          size = "m",
          easyClose = TRUE,
          footer = tagList(
            modalButton("Annuler"),
            actionButton(ns("valider_contrat_global"), "Enregistrer", class = "btn-primary")
          ),
          fluidPage(
            helpText("Sélectionnez le contrat auquel rattacher les éléments à enregistrer."),
            sel_contrat
          )
        )
      )
    })
    
    observeEvent(input$valider_contrat_global, {
      shinybusy::show_modal_spinner(
        spin  = "circle",
        color = COULEUR_SPINNER,
        text  = "💾 Sauvegarde en cours..."
      )
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
      debug_print("observeEvent(input$valider_contrat_global)")
      
      sid <- site_id_edition()
      if (is.null(sid) || is.na(sid)) {
        showToast("error", "Aucun site actif", "Sélectionnez d'abord un site.")
        return(invisible(NULL))
      }
      
      ids   <- parcelles_en_attente(); if (is.null(ids))   ids   <- character(0)
      polys <- polygones_en_attente(); if (is.null(polys)) polys <- list()
      
      if (length(ids) == 0 && length(polys) == 0) {
        showToast("info", "Aucune sélection", "Ajoutez des parcelles ou dessinez un polygone.")
        return(invisible(NULL))
      }
      
      #' ⚠️ Contrat obligatoire
      contrat_id <- .contrat_choisi_valide()
      if (is.null(contrat_id)) return(invisible(NULL))
      
      user <- tryCatch(as.character(session$user)[1], error = function(e) NA_character_)
      if (!nzchar(user) || is.na(user)) user <- Sys.getenv("USER", unset = "system")
      
      # 1. On réserve la connexion
      conn <- pool::poolCheckout(con) 
      
      # 2. CRUCIAL : On s'assure qu'elle revient quoi qu'il arrive (même si erreur)
      on.exit(pool::poolReturn(conn), add = TRUE)
      
      # 3. On travaille UNIQUEMENT sur 'conn' (la connexion dédiée)
      dbBegin(conn)
      ok <- FALSE
      user_db_val <- user_to_db()
      tryCatch({
        #' ---------- Parcelles cadastrales ----------
        if (length(ids) > 0) {
          existing_parcelles <- safe_db_query(conn, glue("
            SELECT p.id, c.idpar
            FROM gestcons.parcelles p
            JOIN gestcons.dico_cadastre c ON p.parcellaire_id = c.id
            WHERE c.idpar IN ({paste(DBI::dbQuoteString(conn, ids), collapse = ',')})
              AND p.site_id = {sid}
          "))
          existing_parcelles_map <- split(existing_parcelles$id, existing_parcelles$idpar)
          
          missing_parcelles <- setdiff(ids, names(existing_parcelles_map))
          if (length(missing_parcelles) > 0) {
            parcelles_info <- safe_db_query(conn, glue("
              SELECT id, dcntpa FROM gestcons.dico_cadastre
              WHERE idpar IN ({paste(DBI::dbQuoteString(conn, missing_parcelles), collapse = ',')})
            "))
            if (nrow(parcelles_info) > 0) {
              for (i in seq_len(nrow(parcelles_info))) {
                parcelle_info <- parcelles_info[i, ]
                parcelle_db_id <- tx_insert(conn, glue("
                  INSERT INTO gestcons.parcelles (
                    site_id, parcellaire_id, bnd_id, pour_part_id, surf_parc_maitrise_m2,
                    source_surf_parc_id, echelle_numerisation_id, domaine_public_id,
                    proprietaire_id, zpf_id, chasse_id, actif,
                    cree_par, date_creation, modifie_par, date_modification, type_parcelle_id
                  ) VALUES (
                    {sid}, {parcelle_info$id}, 0, 0, {parcelle_info$dcntpa},
                    1, 1, 0, 4, 0, 1, TRUE,
                    {dbQuoteLiteral(conn, user_db_val)}, NOW(),
                    {dbQuoteLiteral(conn, user_db_val)}, NOW(),
                    1
                  ) RETURNING id
                "))
                
                debug_print(paste0("parcelle_db_id = ", parcelle_db_id))
                
                # ⬇️ à ajouter après une modification effective des parcelles du site
                if (!is.null(contrats_update_trigger)) {
                  contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
                }
                
                
                # Sécurisation
                if (is.null(parcelle_db_id)) {
                  showToast("error", "Erreur d'insertion", "L'insertion d'une parcelle a échoué.")
                  dbRollback(conn)
                  return(invisible(NULL))
                }
                
                # Source géométrique : une parcelle cadastrale vient du PCI.
                tx_execute(conn, glue("
                  INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
                  VALUES ({parcelle_db_id}, {SOURCE_GEOM_PCI})
                  ON CONFLICT DO NOTHING
                "))

                #' Lien contrat (obligatoire)
                tx_execute(conn, glue("
                  INSERT INTO gestcons.contrats_foncier_parcelles (contrat_id, parcelle_id)
                  VALUES ({contrat_id}, {parcelle_db_id})
                  ON CONFLICT DO NOTHING
                "))
              }
            }
          }
          
          if (nrow(existing_parcelles) > 0) {
            for (parcelle_db_id in existing_parcelles$id) {
              tx_execute(conn, glue("
                INSERT INTO gestcons.contrats_foncier_parcelles (contrat_id, parcelle_id)
                VALUES ({contrat_id}, {parcelle_db_id})
                ON CONFLICT DO NOTHING
              "))
            }
          }
          
          # LIGNE CRUCIALE : Récupère tous les idpar qui ont été traités/commités (existants et manquants)
          idpars_commites <- unique(c(
            if (exists("existing_parcelles") && nrow(existing_parcelles) > 0) existing_parcelles$idpar else character(0),
            if (exists("missing_parcelles")  && length(missing_parcelles)  > 0) missing_parcelles          else character(0)
          ))
          
          # --- Acteurs « propriétaire » des parcelles associées ---
          # Logique partagée avec l'ajout à la continuité du site conservatoire (helpers.R) :
          # personnes physiques seulement, dédoublonnage sur la clé normalisée.
          acteurs_ins <- creer_acteurs_proprietaires(
            conn, idpars_commites, type_acteur_proprio_id
          )
          if (nrow(acteurs_ins) > 0) {
            labs <- with(acteurs_ins, {
              pren <- ifelse(is.na(prenom) | prenom == "", "", paste0(" ", prenom))
              loc  <- trimws(paste(ifelse(is.na(cp), "", cp), ifelse(is.na(commune), "", commune)))
              loc  <- ifelse(nchar(loc) > 0, paste0(" [", loc, "]"), "")
              paste0(nom, pren, loc)
            })
            max_show <- 50L
            shown  <- paste(utils::head(labs, max_show), collapse = ", ")
            suffix <- if (length(labs) > max_show) sprintf(" ... (+%d)", length(labs) - max_show) else ""
            message(sprintf("✅ %d acteur(s) inséré(s) : %s%s", length(labs), shown, suffix))
            shinyFeedback::showToast("success", "Acteurs ajoutés",
                                     sprintf("%d acteur(s) inséré(s).", nrow(acteurs_ins)))
          } else {
            message("ℹ️ Aucun nouvel acteur à insérer.")
          }
          ok <- TRUE
        }
        
        #' ---------- Polygones dessinés ----------
        if (length(polys) > 0) {
          now <- Sys.time()
          for (poly in polys) {
            coords <- poly$geometry$coordinates[[1]]
            mat <- do.call(rbind, lapply(coords, function(pt) c(as.numeric(pt[[1]]), as.numeric(pt[[2]]))))
            if (nrow(mat) < 3) next
            if (!all(mat[1, ] == mat[nrow(mat), ])) mat <- rbind(mat, mat[1, ])
            if (nrow(mat) < 4) next
            
            sfc       <- sf::st_sfc(sf::st_polygon(list(mat)), crs = 4326)
            sfc_2154  <- sf::st_transform(sfc, 2154)
            surface_m2 <- as.numeric(sf::st_area(sfc_2154))
            if (is.na(surface_m2)) next
            wkt <- sf::st_as_text(sfc_2154)
            
            new_id <- tx_insert(conn, glue("
              INSERT INTO gestcons.perimetre_parcellaire_manuel
              (geometrie, date_modification, modifie_par, date_creation, actif, remarque, cree_par)
              VALUES (ST_GeomFromText('{wkt}', 2154), {dbQuoteLiteral(conn, now)},
                      {dbQuoteLiteral(conn, user_db_val)}, {dbQuoteLiteral(conn, now)}, TRUE, ' ', {dbQuoteLiteral(conn, user_db_val)})
              RETURNING id
            "))
            
            debug_print(paste0("new_id = ", new_id))
            
            # Sécurisation
            if (is.null(new_id)) {
              showToast("error", "Erreur d'insertion", "L'insertion d'un polygone a échoué.")
              next # Continuez la boucle si un polygone a un problème
            }
            
            parcelle_db_id <- tx_insert(conn, glue("
              INSERT INTO gestcons.parcelles (
                site_id, parcellaire_id, bnd_id, pour_part_id, surf_parc_maitrise_m2,
                source_surf_parc_id, echelle_numerisation_id, domaine_public_id,
                proprietaire_id, zpf_id, chasse_id, actif,
                cree_par, date_creation, modifie_par, date_modification, type_parcelle_id
              ) VALUES (
                {sid}, {new_id}, 0, 0, {round(surface_m2)},
                1, 1, 0, 4, 0, 1, TRUE,
                {dbQuoteLiteral(conn, user_db_val)}, NOW(),
                {dbQuoteLiteral(conn, user_db_val)}, NOW(),
                2
              ) RETURNING id
            "))
            
            # Sécurisation
            if (is.null(parcelle_db_id)) {
              showToast("error", "Erreur d'insertion", "L'insertion d'une parcelle a échoué.")
              dbRollback(conn)
              return(invisible(NULL))
            }
            debug_print(paste0("parcelle_db_id = ", parcelle_db_id))
            
            # ⬇️ à ajouter après une modification effective des parcelles du site
            if (!is.null(contrats_update_trigger)) {
              contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
            }
            
            # Source géométrique : un polygone dessiné est une numérisation CEN.
            tx_execute(conn, glue("
              INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
              VALUES ({parcelle_db_id}, {SOURCE_GEOM_MANUELLE})
              ON CONFLICT DO NOTHING
            "))

            #' Lien contrat (obligatoire)
            tx_execute(conn, glue("
              INSERT INTO gestcons.contrats_foncier_parcelles (contrat_id, parcelle_id)
              VALUES ({contrat_id}, {parcelle_db_id})
              ON CONFLICT DO NOTHING
            "))
          }
          ok <- TRUE
        }
        
        dbCommit(conn)
        invalidate_sites_coords_cache()

        try(refresh_acteurs(conn), silent = TRUE)
        
        removeModal()
        parcelles_selectionnees(character(0))
        parcelles_en_attente(character(0))
        polygones_manuels_temp(list())
        polygones_en_attente(list())
        
        load_parcelles_sites()
        load_perimetres_manuels()

        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelle sélectionnée") %>%
          clearGroup("Polygones")
        clear_selection_cache(ns("map"), session)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        session$sendCustomMessage('clear-polygones', ns("map"))
        
        showToast("success", "Sélection enregistrée", "Parcelles et polygones ont été enregistrés avec le contrat sélectionné.")
        log_action(session, current_user_rv,
                   paste0("Site #", sid, " : parcelles et périmètres manuels rattachés (avec contrat)"))
        
      }, error = function(e) {
        dbRollback(conn)
        showToast("error", "Erreur lors de l'enregistrement", paste("Détails :", e$message))
      })
      
      if (!ok) invisible(NULL)
    })
    
    #' -------------------------
    #' Vider la sélection
    #' -------------------------
    observeEvent(input$clear_selection, {
      debug_print("observeEvent(input$clear_selection")
      # État côté serveur
      polygones_manuels_temp(list())

      # Chemin canonique : état + visuel + CACHE incrémental de « Parcelle
      # sélectionnée » (+ sélection de continuité). ⚠️ Sans l'invalidation du
      # cache, re-sélectionner la même parcelle passait en fast-path « déjà
      # dessinée » -> compteur juste mais aucune parcelle affichée en rouge.
      clear_selection()

      # Efface les groupes éphémères restants (polygones dessinés…)
      clear_ephemeral_layers(ns("map"), session)
      session$sendCustomMessage('clear-polygones', ns("map"))

      # Surtout : ne redessine pas les persistants — on ne les a pas effacés.
    })
    
    #' -------------------------
    #' Update site
    #' -------------------------
    observeEvent(input$update_site, {
      debug_print("observeEvent(input$update_site")
      req(site_id_edition())
      
      if (is.null(input$libelle) || input$libelle == "") {
        showToast("error", "Nom manquant", "⚠️ Le site doit avoir un nom.")
        return()
      }
      user_db_val <- user_to_db()
      tryCatch({
        # Les neuf écritures de l'enregistrement d'un site — sites,
        # sites_statuts, responsable_sites, conservateur_benevole et
        # animateur_sites — étaient validées séparément sur le pool. Un échec
        # en cours de route laissait le site à moitié enregistré : la fiche
        # modifiée mais le statut non clôturé, ou le responsable changé et les
        # animateurs non. Elles tiennent maintenant dans UNE transaction.
        #
        # Les deux appels à maj_role_site() y partagent désormais la même
        # connexion, au lieu d'ouvrir chacun la sienne.
        pool::poolWithTransaction(con, function(conn) {
          # Booléens par DBI::SQL(sql_bool()) et non {isTRUE()} : glue_sql rend un
          # booléen R en 1/0, qu'une colonne boolean refuse.
          # ⚠️ Jamais de commentaire DANS la chaîne ci-dessous : glue y lirait
          # chaque {…} comme une formule à évaluer, et « # » n'est pas un
          # commentaire SQL. C'est ce qui a cassé cet enregistrement le
          # 2026-10-28 (« Failed to evaluate glue component »).
          query <- glue::glue_sql("
            UPDATE gestcons.sites
            SET libelle = {input$libelle},
                id_site_fcen = {input$id_site_fcen},
                type_milieu_id = {as.integer(input$type_milieu_id)},
                geol_id = {as.integer(input$geologie_id)},
                nature_perimetre_id = {as.integer(input$nature_perimetre_id)},
                echelle_num_id = {as.integer(input$echelle_num_id)},
                precision_num_site_id = {input$precision_num_site_id},
                gestionnaire_site = {input$gestionnaire_site},
                terrain_militaire_id = {ifelse(input$terrain_militaire, 1L, 0L)},
                site_marin_id = {ifelse(input$site_marin, 1L, 0L)},
                date_crea_site = {as.character(input$date_crea_site)},
                date_maj_site = {as.character(input$date_maj_site)},
                description_site = {input$description_site},
                sensibilite = {DBI::SQL(sql_bool(input$sensibilite))},
                non_diffusion = {DBI::SQL(sql_bool(input$non_diffusion))},
                remq_sensibilite = {remq_sensibilite_saisie(input$sensibilite, input$remq_sensibilite)},
                accessibilite_site = {accessibilite_saisie(input$accessibilite_site)},
                accessibilite_pmr_site = {accessibilite_pmr_saisie(input$accessibilite_site, input$accessibilite_pmr_site)},
                modifie_par = {as.character(user_db_val)},
                date_modification = NOW()
            WHERE id = {site_id_edition()}
          ", .con = conn)
        
          tx_execute(conn, query)
        
          sql <- glue("
            SELECT statut_site_id FROM gestcons.sites_statuts
            WHERE site_id = {site_id_edition()} AND date_fin IS NULL
          ")
          statut_courant <- safe_db_query(conn, sql)
        
          if (
            nrow(statut_courant) == 0 ||
            statut_courant$statut_site_id[1] != input$statut_site_id
          ) {
            tx_execute(conn, glue("
              UPDATE gestcons.sites_statuts
              SET date_fin = NOW()
              WHERE site_id = {site_id_edition()} AND date_fin IS NULL
            "))
            tx_execute(conn, glue::glue_sql("
              INSERT INTO gestcons.sites_statuts (site_id, statut_site_id, date_debut, remarque)
              VALUES ({site_id_edition()}, {as.integer(input$statut_site_id)}, {as.character(input$statut_date_debut)}, {input$statut_remarque})
            ", .con = conn))
          }
        
          # 1. Récupération de l'état initial du Responsable actif
          resp_initial <- safe_db_query(conn, glue("
              SELECT user_id, date_debut FROM gestcons.responsable_sites
              WHERE site_id = {site_id_edition()} AND actif = TRUE
              LIMIT 1
          "))
        
          id_responsable_initial <- resp_initial$user_id[1] %||% NA_integer_
          # Conversion en caractère pour comparaison facile, NA si NULL/vide
          date_debut_initial_char <- .jour_txt(resp_initial$date_debut)
        
          # 2. Valeurs saisies par l'utilisateur
          user_id_saisi <- suppressWarnings(as.integer(input$site_responsable_id))
          user_id_saisi <- user_id_saisi %||% NA_integer_
          date_saisie_char <- .jour_txt(input$site_responsable_date)
        
          # 3. Détermination si une action (changement de personne OU de date) est nécessaire
          responsable_id_change <- !identical(user_id_saisi, id_responsable_initial)
          date_debut_change_for_same_user <- 
            identical(user_id_saisi, id_responsable_initial) && 
            !identical(date_saisie_char, date_debut_initial_char)
        
          if (isTRUE(responsable_id_change) || isTRUE(date_debut_change_for_same_user)) {

            # Correction de date, changement de titulaire ou fin de rôle : la
            # distinction est faite par maj_role_site(), qui conserve l'historique
            # des périodes sans le découper à chaque correction de saisie.
            maj_role_site(conn, "responsable_sites", site_id_edition(),
                          user_id_saisi, date_saisie_char,
                          user_db_val, id_responsable_initial)
          }
        
          # 1. Récupération de l'état initial du Bénévole actif
          benev_initial <- safe_db_query(conn, glue("
              SELECT user_id, date_debut FROM gestcons.conservateur_benevole
              WHERE site_id = {site_id_edition()} AND actif = TRUE
              LIMIT 1
          "))
        
          id_benevole_initial <- benev_initial$user_id[1] %||% NA_integer_
          date_debut_initial_benev_char <- .jour_txt(benev_initial$date_debut)
        
          # 2. Valeurs saisies par l'utilisateur
          benevole_id_saisi <- suppressWarnings(as.integer(input$site_benevole_id))
          benevole_id_saisi <- benevole_id_saisi %||% NA_integer_
          date_saisie_benev_char <- .jour_txt(input$site_benevole_date)
        
          # 3. Détermination si une action est nécessaire
          benevole_id_change <- !identical(benevole_id_saisi, id_benevole_initial)
          date_debut_change_for_same_benevole <- 
            identical(benevole_id_saisi, id_benevole_initial) && 
            !identical(date_saisie_benev_char, date_debut_initial_benev_char)
        
          if (isTRUE(benevole_id_change) || isTRUE(date_debut_change_for_same_benevole)) {

            # Correction de date, changement de titulaire ou fin de rôle : la
            # distinction est faite par maj_role_site(), qui conserve l'historique
            # des périodes sans le découper à chaque correction de saisie.
            maj_role_site(conn, "conservateur_benevole", site_id_edition(),
                          benevole_id_saisi, date_saisie_benev_char,
                          user_db_val, id_benevole_initial)
          }
        
          # 1. Lire les animateurs actifs actuels (IDs)
          animateurs_actifs_actuels <- safe_db_query(conn, glue("
            SELECT user_id FROM gestcons.animateur_sites
            WHERE site_id = {site_id_edition()} AND actif = TRUE
            ORDER BY user_id
          "))$user_id
        
          # 2. Lire les IDs soumis par l'utilisateur
          animateurs_ids_saisis <- input$site_animateurs_ids %||% integer(0)
          animateurs_ids_saisis <- suppressWarnings(as.integer(animateurs_ids_saisis[!is.na(animateurs_ids_saisis)]))
        
          # 3. Vérifier si les deux listes sont identiques (c-à-d, pas de modification)
          listes_identiques <- setequal(
            sort(animateurs_actifs_actuels), 
            sort(animateurs_ids_saisis)
          )
        
          if (!isTRUE(listes_identiques)) {
          
            # Si les listes sont différentes : exécuter la désactivation et l'insertion/réactivation
          
            # 1. DELETE/DÉSACTIVER les anciens animateurs (simplement pour réinsérer propre)
            tx_execute(conn, glue::glue("
                UPDATE gestcons.animateur_sites
                SET actif = FALSE,
                    modifie_par = {dbQuoteLiteral(conn, user_db_val)},
                    date_modification = NOW()
                WHERE site_id = {site_id_edition()} AND actif = TRUE
              "))
          
            # 2. INSERT/ACTIVER la nouvelle liste
            if (length(animateurs_ids_saisis) > 0) {
              values_sql <- paste0(
                "('", site_id_edition(), "', ", animateurs_ids_saisis, ", TRUE, ", 
                sql_txt(user_db_val), ", NOW(), ", 
                sql_txt(user_db_val), ", NOW())",
                collapse = ","
              )
            
              # Tentative d'insertion (avec ON CONFLICT DO UPDATE)
              tx_execute(conn, glue::glue("
                  INSERT INTO gestcons.animateur_sites
                    (site_id, user_id, actif, cree_par, date_creation, modifie_par, date_modification)
                  VALUES {DBI::SQL(values_sql)}
                  ON CONFLICT (site_id, user_id) DO UPDATE SET
                    actif = TRUE,
                    modifie_par = {dbQuoteLiteral(conn, user_db_val)},
                    date_modification = NOW()
                "))
            }
          }
        })
        # Fin du bloc d'action des animateurs
        
        resume_site_trigger(isolate(resume_site_trigger()) + 1)
        
        log_action(session, current_user_rv,
                   paste0("Mise à jour du site #", site_id_edition()))
        showToast("success", "Site mis à jour",
                  paste0("✅ Le site « ", input$libelle, " » a été modifié."))
        invalidate_sites_coords_cache()

        sites_df <- safe_db_query(con, "SELECT id, libelle FROM gestcons.sites
                                        WHERE type_site_id = 1 ORDER BY libelle")
        
        sites_shared(sites_df)
        
        updateSelectizeInput(session, "site_selector",
                             choices = c(" " = "",
                                         setNames(sites_df$id, sites_df$libelle)),
                             selected = site_id_edition())
        
      }, error = function(e) {
        showToast("error", "Erreur SQL", paste("⚠️ Impossible de mettre à jour :", e$message))
      })
      refresh_sites_choices(select = site_id_edition())
    })
    
    #' -------------------------
    #' Créer un contrat par défaut (utilitaire)
    #' -------------------------
    .create_default_contrat <- function(conn, site_id, site_libelle, user_db_val) {
      # Nom basé sur le libellé du site (cohérent avec la pré-sélection par nom,
      # cf. draft_nom_cible). Tronqué pour rester sous contrats_fonciers.nom (varchar 255).
      libelle_contrat <- glue::glue("Préfiguration {substr(site_libelle, 1, 240)}")
      
      # Statut "En cours d'élaboration" (vérifier l'ID correspondant)
      statut_draft_id <- dico_statut_contrat$id[tolower(trimws(dico_statut_contrat$libelle)) %in% c("en cours d'élaboration", "en cours d’élaboration", "en cours d élaboration")][1]
      if (is.na(statut_draft_id)) {
        statut_draft_id <- dico_statut_contrat$id[1] # Fallback
        message("⚠️ Statut 'En cours d'élaboration' non trouvé, utilisation du statut ID ", statut_draft_id)
      }
      
      # Type de maîtrise fixé à 48, comme demandé
      type_maitrise_fixe_id <- 48L
      
      sql <- glue::glue("
        INSERT INTO gestcons.contrats_fonciers
          (nom, type_maitrise_id, statut_id, date_debut, remarque,
           cree_par, date_creation, modifie_par, date_modification, actif)
        VALUES (
          {DBI::dbQuoteLiteral(conn, libelle_contrat)},
          {type_maitrise_fixe_id},
          {statut_draft_id},
          NOW(),
          {DBI::dbQuoteLiteral(conn, 'Contrat provisoire créé automatiquement à la création du site.')},
          {DBI::dbQuoteLiteral(conn, user_db_val)},
          NOW(),
          {DBI::dbQuoteLiteral(conn, user_db_val)},
          NOW(),
          TRUE
        )
        RETURNING id
      ")

      contrat_id <- tx_insert(conn, sql)
      # NB : la liste partagée des contrats est rechargée par l'appelant APRÈS
      # le commit — ici la transaction n'est pas encore validée, et le contrat
      # ne serait pas visible depuis une autre connexion du pool.
      return(contrat_id)
    }
    
    #' -------------------------
    #' Créer un site
    #' -------------------------
    #' -------------------------
    #' Créer un site
    #' -------------------------
    # Active le bouton « Enregistrer » (création ET édition) uniquement quand
    # tous les champs obligatoires (marqués d'un *) du formulaire sont renseignés.
    observe({
      # Dépendance explicite : les champs obligatoires peuvent être identiques
      # d'une ouverture à l'autre, auquel cas Shiny n'émet rien et ce bloc ne
      # serait jamais rejoué sur le bouton fraîchement créé.
      form_site_rendu()

      nz <- function(x) isTRUE(nzchar(x %||% ""))
      champs_ok <- nz(input$libelle) &&
        nz(input$type_milieu_id) &&
        nz(input$geologie_id) &&
        nz(input$nature_perimetre_id) &&
        nz(input$echelle_num_id) &&
        nz(input$precision_num_site_id)
      shinyjs::toggleState("create_site", condition = champs_ok)
      shinyjs::toggleState("update_site", condition = champs_ok)
    })

    observeEvent(input$create_site, {
      debug_print("observeEvent(input$create_site")
      #' ✅ validation minimale
      if (is.null(input$libelle) || input$libelle == "") {
        showToast("error", "Nom manquant", "⚠️ Le site doit avoir un nom.")
        return()
      }
      
      # ⚠️ NOUVELLE VALIDATION : Géologie obligatoire
      if (is.null(input$geologie_id) || !nzchar(input$geologie_id)) {
        showToast("error", "Géologie manquante", "⚠️ La géologie du site doit être sélectionnée.")
        return()
      }
      
      new_site_id <- NULL  #' 👈 défini avant tryCatch
      user_db_val <- user_to_db()
      
      # 1. On réserve la connexion
      conn <- pool::poolCheckout(con) 
      
      # 2. CRUCIAL : On s'assure qu'elle revient quoi qu'il arrive (même si erreur)
      on.exit(pool::poolReturn(conn), add = TRUE)
      
      # 3. On travaille UNIQUEMENT sur 'conn' (la connexion dédiée)
      dbBegin(conn) # Début de transaction pour assurer l'atomicité Site + Contrat
      
      tryCatch({
        #' Champs (entiers) qui peuvent être vides → NULL
        q_insert <- glue::glue("
          INSERT INTO gestcons.sites (
            libelle,  id_site_fcen, type_milieu_id, geol_id, nature_perimetre_id,
            echelle_num_id, precision_num_site_id, gestionnaire_site,
            terrain_militaire_id, site_marin_id,
            date_crea_site, date_maj_site, description_site,
            sensibilite, non_diffusion, remq_sensibilite,
            accessibilite_site, accessibilite_pmr_site,
            cree_par, date_creation, modifie_par, date_modification
          ) VALUES (
            {sql_txt(input$libelle)},
            {sql_txt(input$id_site_fcen)},
            {sql_int(input$type_milieu_id)},
            {sql_int(input$geologie_id)},
            {sql_int(input$nature_perimetre_id)},
            {sql_int(input$echelle_num_id)},
            {sql_txt(input$precision_num_site_id)},
            {sql_txt(input$gestionnaire_site)},
            {ifelse(isTRUE(input$terrain_militaire), 1L, 0L)},
            {ifelse(isTRUE(input$site_marin), 1L, 0L)},
            {sql_date(input$date_crea_site)},
            {sql_date(input$date_maj_site)},
            {sql_txt(input$description_site)},
            {sql_bool(input$sensibilite)},
            {sql_bool(input$non_diffusion)},
            {sql_txt(remq_sensibilite_saisie(input$sensibilite, input$remq_sensibilite))},
            {accessibilite_saisie(input$accessibilite_site)},
            {accessibilite_pmr_saisie(input$accessibilite_site, input$accessibilite_pmr_site)},
            {sql_txt(user_db_val)},
            NOW(),
            {sql_txt(user_db_val)},
            NOW()
          ) RETURNING id
        ")
        
        new_site_id <- tx_insert(conn, q_insert)   # <- renvoie l'ID ou NULL
        debug_print(paste0("new_site_id = ", new_site_id))
        
        if (is.null(new_site_id)) {
          showToast("error", "Erreur", "Impossible de créer le site.")
          stop("Insert site failed → rollback")        # force le rollback de la transaction
        }
        
        # 🟢 NOUVELLE ÉTAPE : CRÉATION DU CONTRAT PAR DÉFAUT
        new_contrat_id <- .create_default_contrat(
          conn = conn,
          site_id = new_site_id,
          site_libelle = input$libelle,
          user_db_val = user_db_val
        )
        if (is.null(new_contrat_id)) {
          stop("Insert default contrat failed → rollback")
        }
        
        # ⬇️ à ajouter après une modification effective des parcelles du site
        if (!is.null(contrats_update_trigger)) {
          contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
        }
        
        #' Statut (insérer seulement si choisi)
        statut_id <- suppressWarnings(as.integer(input$statut_site_id))
        if (!is.na(statut_id)) {
          tx_execute(conn, glue::glue("
            INSERT INTO gestcons.sites_statuts (site_id, statut_site_id, date_debut, remarque)
            VALUES ({new_site_id}, {statut_id}, {sql_date(input$statut_date_debut)}, {sql_txt(input$statut_remarque)})
          "))
        }
        
        #' Responsable (si choisi)
        if (!is.null(input$site_responsable_id) && nzchar(input$site_responsable_id)) {
          tx_execute(conn, glue::glue("
            INSERT INTO gestcons.responsable_sites
              (site_id, user_id, date_debut, actif, cree_par, date_creation, modifie_par, date_modification)
            VALUES (
              {new_site_id},
              {as.integer(input$site_responsable_id)},
              {sql_date(input$site_responsable_date)},
              TRUE,
              {sql_txt(user_db_val)},
              NOW(),
              {sql_txt(user_db_val)},
              NOW()
            )
          "))
        }
        
        #' Bénévole (si choisi)
        if (!is.null(input$site_benevole_id) && nzchar(input$site_benevole_id)) {
          tx_execute(conn, glue::glue("
            INSERT INTO gestcons.conservateur_benevole
              (site_id, user_id, date_debut, actif, cree_par, date_creation, modifie_par, date_modification)
            VALUES (
              {new_site_id},
              {as.integer(input$site_benevole_id)},
              {sql_date(input$site_benevole_date)},
              TRUE,
              {sql_txt(user_db_val)},
              NOW(),
              {sql_txt(user_db_val)},
              NOW()
            )
          "))
        }
        
        # Animateurs (si choisis)
        animateurs_ids <- input$site_animateurs_ids %||% integer(0)
        animateurs_ids <- suppressWarnings(as.integer(animateurs_ids[!is.na(animateurs_ids)]))
        
        if (length(animateurs_ids) > 0) {
          # Prépare les valeurs pour insertion de masse (site_id, user_id, actif, cree_par, date_creation, modifie_par, date_modification)
          values_sql <- paste0(
            "('", new_site_id, "', ", animateurs_ids, ", TRUE, ", 
            sql_txt(user_db_val), ", NOW(), ", 
            sql_txt(user_db_val), ", NOW())",
            collapse = ","
          )
          tx_execute(conn, glue::glue("
            INSERT INTO gestcons.animateur_sites
              (site_id, user_id, actif, cree_par, date_creation, modifie_par, date_modification)
            VALUES {DBI::SQL(values_sql)}
            ON CONFLICT DO NOTHING
          "))
        }
        
        dbCommit(conn) # Commit de la transaction
        invalidate_sites_coords_cache()

        # Recharge la liste partagée des contrats fonciers : sans ça, le contrat
        # de préfiguration créé juste au-dessus n'apparaît pas dans les listes
        # déroulantes de Parcelles et Actions. (L'ancien code y posait NULL, que
        # leurs observers ignorent — ignoreNULL par défaut.)
        if (is.function(contrats_choices_rv)) {
          try({
            df_contrats <- safe_db_query(
              con, "SELECT id, nom FROM gestcons.contrats_fonciers ORDER BY nom")
            if (!is.null(df_contrats)) contrats_choices_rv(df_contrats)
          }, silent = TRUE)
        }

        #' ✅ MAJ UI
        site_id_edition(new_site_id)
        
        sites_df <<- safe_db_query(con, "SELECT id, libelle FROM gestcons.sites
                                         WHERE type_site_id = 1 ORDER BY libelle")
        sites_shared(sites_df)
        
        updateSelectizeInput(session, "site_selector",
                             choices = c(" " = "", setNames(sites_df$id, sites_df$libelle)),
                             selected = new_site_id
        )
        
        removeModal()
        showToast("success", "Site créé", paste0("✅ Le site « ", input$libelle, " » a été ajouté avec le contrat de préfiguration n°", new_contrat_id, "."))
        log_action(session, current_user_rv,
                   paste0("Création du site « ", input$libelle, " » (id ", new_site_id, ")"))
        
        #' Placez refresh ici (new_site_id est garanti)
        refresh_sites_choices(select = new_site_id)
        
      }, error = function(e) {
        dbRollback(conn)
        showToast("error", "Erreur SQL", paste("⚠️ Impossible de créer le site et/ou le contrat :", e$message))
      })
    })
    
    
    
    observeEvent(input$confirm_delete_bbox_site, {
      debug_print("observeEvent(input$confirm_delete_bbox_site")
      removeModal()
      rows <- a_supprimer_bbox()
      if (is.null(rows) || nrow(rows) == 0) return(invisible(NULL))
      
      sid <- site_id_edition()
      if (is.null(sid) || is.na(sid)) {
        showToast("error", "Aucun site", "Aucun site actif.")
        return(invisible(NULL))
      }
      
      ids_db <- paste(rows$parcelle_db_id, collapse = ",")
      
      
      # 1. On réserve la connexion
      conn <- pool::poolCheckout(con) 
      
      # 2. CRUCIAL : On s'assure qu'elle revient quoi qu'il arrive (même si erreur)
      on.exit(pool::poolReturn(conn), add = TRUE)
      
      # Supprime liens de contrat puis périmètres manuels associés (si type 2), puis les parcelles
      tryCatch({
        DBI::dbBegin(conn)
        
        # 1) Lien contrats
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.contrats_foncier_parcelles
          WHERE parcelle_id IN ({ids_db})
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.contrats_agricoles_parcelles
          WHERE parcelle_id IN ({ids_db})
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.animation_fonciere_parcelles
          WHERE parcelle_id IN ({ids_db})
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.animation_contrat_agricole_parcelles
          WHERE parcelle_id IN ({ids_db})
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_protection
          WHERE parcelle_id IN ({ids_db})
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_sources_geom
          WHERE parcelle_id IN ({ids_db})
        "))
        
        # 2) Périmètres manuels portés par ces entrées (type_parcelle_id = 2)
        #    On efface d'abord dans pm via jointure sur p.id
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.perimetre_parcellaire_manuel pm
          USING gestcons.parcelles p
          WHERE pm.id = p.parcellaire_id
            AND p.type_parcelle_id = 2
            AND p.id IN ({ids_db})
            AND p.site_id = {sid}
        "))
        
        # 3) Les entrées dans gestcons.parcelles
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles
          WHERE id IN ({ids_db})
            AND site_id = {sid}
        "))

        DBI::dbCommit(conn)
        invalidate_sites_coords_cache()
        
        # ⬇️ à ajouter après une modification effective des parcelles du site
        if (!is.null(contrats_update_trigger)) {
          contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
        }
        
        # MAJ UI
        a_supprimer_bbox(NULL)
        clear_site_selection()
        load_parcelles_sites()
        load_perimetres_manuels()
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelle sélectionnée") %>%
          clearGroup("Polygones")
        clear_selection_cache(ns("map"), session)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
        session$sendCustomMessage('clear-polygones', ns("map"))
        
        log_action(session, current_user_rv,
                   "Site : éléments retirés du site (sélection rectangle)")
        showToast("success", "Supprimées",
                  glue::glue("🗑 {nrow(rows)} élément(s) retiré(s) du site."))
        
      }, error = function(e) {
        DBI::dbRollback(conn)
        showToast("error", "Erreur suppression", conditionMessage(e))
      })
    })
    
    #' -------------------------
    #' (Anciens handlers `delete_parcelle` / `delete_perimetre` supprimés.)
    #' Code mort et bogué : aucun bouton du namespace `sites` ne les déclenchait
    #' (le bouton « Supprimer du site » vit dans mod_parcelles.R), et ils
    #' référençaient des variables inexistantes (`conn`, `parcelle_db_id`),
    #' ciblaient la mauvaise réactive et n'étaient pas transactionnels.
    #' La suppression réelle passe par `confirm_delete_single_parcelle_site`
    #' (parcelle unique) et `confirm_delete_bbox_site` (sélection), tous deux
    #' transactionnels ci-dessous.
    #' -------------------------

    #' -------------------------
    #' Sélection via propriétaire
    #' -------------------------
    observeEvent(input$proprio_selector, {
      selected_label <- input$proprio_selector
      req(selected_label, selected_label != "")

      if (.autre_selection_en_cours("candidates")) return(invisible(NULL))
      
      # Récupération des IDs correspondant au libellé sélectionné
      ids <- dico_proprio_global()[[selected_label]]
      
      if (is.null(ids)) {
        showToast("warning", "Aucun propriétaire trouvé", "La sélection est vide ou invalide.")
        return()
      }
      
      bounds <- input$map_bounds
      if (is.null(bounds)) return()
      # Coordonnées CONVERTIES : elles viennent du navigateur et finissent dans
      # du SQL. Cf. bounds_num (helpers.R).
      bb <- bounds_num(bounds)
      if (is.null(bb)) return()
      xmin <- bb$west
      xmax <- bb$east
      ymin <- bb$south
      ymax <- bb$north
      
      # Construire la clause SQL pour les IDs
      # dbQuoteString, et surtout pas shQuote : c'est une quotation SHELL. Sur
      # une valeur contenant une apostrophe elle bascule en guillemets doubles,
      # qui délimitent un IDENTIFIANT en SQL, et elle échappe « " » par « \" »,
      # que PostgreSQL ne reconnaît pas dans un identifiant.
      ids_sql <- paste(DBI::dbQuoteString(con, as.character(ids)), collapse = ',')
      
      query <- glue("
        SELECT c.idpar, c.geompar,
               {sql_proprio_label()} AS proprietaire
        FROM gestcons.dico_cadastre c
        LEFT JOIN gestcons.dico_proprietaire dp ON c.idprocpte = dp.idprocpte
        WHERE c.geompar && ST_Transform(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)
          AND c.idprocpte IN ({ids_sql})
          AND NOT EXISTS (
            SELECT 1
            FROM gestcons.parcelles p
            WHERE p.parcellaire_id = c.id
          )
          AND NOT EXISTS (
            SELECT 1
            FROM gestcons.parcelles_base pb
            WHERE pb.parcellaire_id = c.id AND pb.perimetre AND pb.site_id = {site_id_edition()}
          )
      ")
      parcelles_proprio <- tryCatch(
        st_read(con, query = query),
        error = function(e) {
          return(NULL)
        }
      )
      
      if (!is.null(parcelles_proprio) && nrow(parcelles_proprio) > 0) {
        parcelles_proprio <- st_transform(parcelles_proprio, 4326)
        
        nouvelles <- parcelles_proprio$idpar
        selection_actuelle <- parcelles_selectionnees()
        selection_complete <- unique(c(selection_actuelle, nouvelles))
        parcelles_selectionnees(selection_complete)
        
        draw_parcelles_selectionnees(parcelles_selectionnees(), con = con, map_id = ns("map"), session = session, user_roles = user_roles())
      }
      
      # Réinitialiser le sélecteur pour permettre une nouvelle sélection
      updateSelectInput(
        session, "proprio_selector",
        selected = "",
        choices = c("Aucun" = "", names(isolate(dico_proprio_global())))
      )
      
    })
    
    
    #' -------------------------
    #' Bounds / Zoom (debounce)
    #' -------------------------
    # Message « zoomez davantage » : helpers communs (show/hide_zoom_hint,
    # helpers.R — partagés avec Stratégie).
    ZOOM_HINT_ID <- session$ns("zoom_cadastre_hint")

    # Visibilité de la couche : on lit l'input natif du binding Leaflet, qui
    # donne la liste des groupes affichés, plutôt qu'un écouteur JS maison sur
    # la case à cocher — celui-ci ne se déclenchait pas.
    zh_visible <- reactive({
      g <- input$map_groups
      !is.null(g) && GROUPS$zones_humides %in% g
    })

    voisins_visible <- reactive({
      g <- input$map_groups
      !is.null(g) && GROUPS$voisins %in% g
    })

    communes_visible <- reactive({
      g <- input$map_groups
      !is.null(g) && GROUPS$communes %in% g
    })

    # Cocher la case doit afficher la couche tout de suite, sans attendre un
    # déplacement de carte ; la décocher doit la vider immédiatement.
    observeEvent(zh_visible(), {
      refresh_zones_humides(
        con = con, bounds = input$map_bounds, zoom = input$map_zoom,
        map_id = ns("map"), show_group = zh_visible(), session = session
      )
    })

    observeEvent(voisins_visible(), {
      refresh_sites_voisins(
        con = con, bounds = input$map_bounds, site_id = site_id_edition(),
        map_id = ns("map"), show_group = voisins_visible(), session = session
      )
    })

    observeEvent(communes_visible(), {
      refresh_limites_communales(
        con = con, bounds = input$map_bounds, zoom = input$map_zoom,
        map_id = ns("map"), show_group = communes_visible(), session = session
      )
    })

    # Changer de site change qui est « voisin » : on redessine si la couche est
    # affichée, sans quoi l'ancien voisinage resterait à l'écran.
    observeEvent(site_id_edition(), {
      refresh_sites_voisins(
        con = con, bounds = input$map_bounds, site_id = site_id_edition(),
        map_id = ns("map"), show_group = voisins_visible(), session = session
      )
    }, ignoreNULL = FALSE)

    debounced_bounds <- debounce(reactive(input$map_bounds), millis = 300)
    
    observeEvent(debounced_bounds(), {
      debug_print("observeEvent(debounced_bounds()")
      bounds <- debounced_bounds()
      zoom <- input$map_zoom
      if (is.null(bounds) || is.null(zoom)) return()

      # Fin de (re)chargement de la vue (cadastre, périmètres, sélection, proprios…)
      # -> signale au client que l'overlay de chargement peut se masquer.
      on.exit(session$sendCustomMessage("tc-map-idle", ns("map")), add = TRUE)

      # Zones humides : indépendantes du site, donc traitées AVANT la sortie
      # anticipée ci-dessous. Rien n'est interrogé tant que la case est décochée.
      refresh_zones_humides(
        con = con, bounds = bounds, zoom = zoom, map_id = ns("map"),
        show_group = zh_visible(), session = session
      )
      refresh_sites_voisins(
        con = con, bounds = bounds, site_id = site_id_edition(),
        map_id = ns("map"), show_group = voisins_visible(), session = session
      )
      # Limites communales : indépendantes du site elles aussi, donc AVANT la
      # sortie anticipée. Rien n'est interrogé tant que la case est décochée.
      refresh_limites_communales(
        con = con, bounds = bounds, zoom = zoom, map_id = ns("map"),
        show_group = communes_visible(), session = session
      )

      # Si pas de site actif, on sort vite.
      if (!isTruthy(site_id_edition())) {
        hide_zoom_hint(ZOOM_HINT_ID)
        return()
      }
      
      if (zoom >= ZOOM_CADASTRE_MIN) {
        refresh_parcelles_cadastrales(
          con = con,
          zoom = zoom,
          bounds = bounds,
          map_id = ns("map"),
          group_name = "Parcelles cadastrales",
          parcelles_cache = parcelles_cache,
          parcelles_cache_bbox = parcelles_cache_bbox,
          buffer_deg = 0.001,
          user_roles = user_roles(),
          # Respecte la case "Parcelles cadastrales" : si l'utilisateur l'a
          # décochée, on ne réaffiche pas le calque au pan/zoom.
          show_group = !identical(input$cadastre_user_show, FALSE),
          session = session
        )
        # Zoom suffisant : on retire le message d'invitation à zoomer
        hide_zoom_hint(ZOOM_HINT_ID)
      } else {
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelles cadastrales") %>%
          hideGroup("Parcelles cadastrales")
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
        parcelles_cache_bbox(NULL)
        invalidate_cadastre_hash(ns("map"), session)

        # Site actif mais zoom insuffisant : on (ré)affiche le message d'invitation
        # à zoomer (fondu automatique après 4 s, géré côté JS).
        show_zoom_hint(ns("map"), ZOOM_HINT_ID)
      }
      
      # 💡 CONSERVATION : On redessine ici les éléments du site.
      # (draw_parcelles_site et draw_perimetres_manuels sont protégés par un
      # hash : ils ne réémettent rien si les données n'ont pas changé.)
      draw_parcelles_site(parcelles_site_data(), map_id = ns("map"), session = session, user_roles = user_roles())
      draw_perimetres_manuels(perimetres_manuelles_data(), map_id = ns("map"), session = session)
      # La continuité du site conservatoire n'est PLUS redessiné ici : il vit dans son propre
      # pane (« perimetre », z-index 415), son empilement ne dépend donc plus de
      # l'ordre de dessin. Son observer sur perimetre_data() suffit. Mesuré :
      # 48 polygones détruits et recréés à CHAQUE déplacement de carte.
      draw_contour()
      draw_perimetre_selection()

      # 3. Dessin des éléments SÉLECTIONNÉS (rouge/orange, peut être vide)
      draw_parcelles_selectionnees(parcelles_selectionnees(), con = con, map_id = ns("map"), session = session, user_roles = user_roles())
      
      #' Remplissage du sélecteur propriétaires seulement si un site est actif
      if (!isTruthy(site_id_edition())) {
        updateSelectInput(session, "proprio_selector", choices = c("Aucun" = ""))
        return()
      }

      #' Barrière de perf : ne liste pas les proprio si zoom trop faible
      if (zoom < ZOOM_CADASTRE_MIN) {
        updateSelectInput(session, "proprio_selector",
                          choices = c("🔎 Zoomez pour lister les propriétaires" = ""))
        return()
      }
      
      # Emprise EXACTE (= ce qui est réellement affiché) : la liste des
      # propriétaires correspond exactement aux parcelles visibles.
      # Coordonnées CONVERTIES : elles viennent du navigateur et finissent dans
      # du SQL. Cf. bounds_num (helpers.R).
      bb <- bounds_num(bounds)
      if (is.null(bb)) return()
      xmin <- bb$west
      xmax <- bb$east
      ymin <- bb$south
      ymax <- bb$north

      proprietaires_visibles <- safe_db_query(con, glue("
        SELECT DISTINCT dp.idprocpte,
               {sql_proprio_label()} AS proprietaire_label
        FROM gestcons.dico_cadastre dc
        LEFT JOIN gestcons.dico_proprietaire dp
               ON dc.idprocpte = dp.idprocpte
        WHERE dc.geompar && ST_Transform(ST_MakeEnvelope({xmin}, {ymin}, {xmax}, {ymax}, 4326), 2154)
          AND NOT EXISTS (
            SELECT 1
            FROM gestcons.parcelles p
            WHERE p.parcellaire_id = dc.id
          )
        ORDER BY proprietaire_label
      "))
      
      if (nrow(proprietaires_visibles) == 0) {
        updateSelectInput(session, "proprio_selector", choices = c("Aucun" = ""))
      } else {
        dico_proprio <- split(proprietaires_visibles$idprocpte, proprietaires_visibles$proprietaire_label)
        dico_proprio_global(dico_proprio)
        updateSelectInput(session, "proprio_selector",
                          choices = c("Aucun" = "", names(dico_proprio)))
      }
    })
    
    #' -------------------------
    #' Observe global léger (pas de reset du sélecteur de site ici)
    #' -------------------------
    observe({
      # si aucun site, on peut agir sans attendre bounds/zoom
      if (!isTruthy(site_id_edition())) {
        leafletProxy(mapId = ns("map"), session = session) %>%
          showGroup("Sites existants")
        hide_zoom_hint(ZOOM_HINT_ID)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))

        draw_circles(con, map_id = ns("map"), zoom = input$map_zoom)
        session$sendCustomMessage("tc-sites-ready", ns("map"))
        return()
      }
      # sinon (site actif), on peut garder le garde si tu veux
      bounds <- input$map_bounds
      zoom   <- input$map_zoom
      if (is.null(bounds) || is.null(zoom)) return()
      leafletProxy(mapId = ns("map"), session = session) %>% hideGroup("Sites existants")
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      
    })
    
    
    #' =========================================================
    #' PÉRIMÈTRE ÉLARGI (fonctionnalités reprises de l'ex-onglet Stratégie)
    #' Données : gestcons.parcelles_base WHERE perimetre (table fusionnée).
    #' Couche orange visible par tous ; actions réservées AD/RS du site
    #' (mêmes droits que les parcelles du site).
    #' =========================================================

    # Parcelles de la continuité du site conservatoire du site actif (sf, geom 4326)
    perimetre_data <- reactive({
      perimetre_trigger()
      # Canal commun : rafraîchit aussi quand un AUTRE onglet modifie les parcelles
      if (!is.null(contrats_update_trigger)) contrats_update_trigger()
      sid <- site_id_edition()
      if (!isTruthy(sid)) return(NULL)
      query <- glue("
        SELECT pb.id, pb.remarque, pb.priorite_id, c.idpar, c.dcntpa, c.idcomtxt,
               string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires,
               ST_Transform(ST_SimplifyPreserveTopology(c.geompar, 1.0), 4326) AS geom
        FROM gestcons.parcelles_base pb
        JOIN gestcons.dico_cadastre c ON c.id = pb.parcellaire_id
        LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
        WHERE pb.site_id = {sid} AND pb.perimetre
        GROUP BY pb.id, pb.remarque, pb.priorite_id, c.idpar, c.dcntpa, c.idcomtxt, c.geompar
      ")
      tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) NULL)
    })

    # Contour englobant : union exacte (PostGIS) des parcelles cadastrales du
    # site ET de la continuité du site conservatoire — une seule table depuis la fusion. Dépend
    # aussi de parcelles_site_data() : l'ajout/retrait d'une parcelle du site
    # doit redessiner le contour.
    contour_data <- reactive({
      perimetre_trigger()
      parcelles_site_data()
      if (!is.null(contrats_update_trigger)) contrats_update_trigger()
      sid <- site_id_edition()
      if (!isTruthy(sid)) return(NULL)
      query <- glue("
        SELECT ST_Transform(ST_Union(c.geompar), 4326) AS geom
        FROM gestcons.parcelles_base p
        JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
        WHERE p.site_id = {sid} AND p.type_parcelle_id = 1
      ")
      out <- tryCatch(sf::st_read(con, query = query, quiet = TRUE), error = function(e) NULL)
      if (is.null(out) || nrow(out) == 0 || all(sf::st_is_empty(out))) return(NULL)
      out
    })

    # Teinte de la sélection de continuité. Elle sert DEUX fois : au contour
    # épais de draw_perimetre_selection(), et aux hachures des mêmes parcelles
    # — sans quoi une parcelle retenue garderait des diagonales bleues dans un
    # cadre d'une autre couleur. Son pendant JS est la classe
    # `pp-hachures-selection` dans www/app.js, où la teinte est répétée en dur
    # comme pour les quatre autres : si l'une change, changer l'autre.
    COULEUR_SEL_CONTINUITE <- "#dc2626"

    # Continuité du site conservatoire, layerId préfixé pp_ pour router les clics.
    # ⚠️ Pas de showGroup ici (géré par l'observeEvent(site_id_edition())).
    draw_perimetre <- function() {
      d <- perimetre_data()
      # Ferme les infobulles ouvertes AVANT le clearGroup : un <path> recréé ne
      # reçoit jamais le mouseout de son prédécesseur -> infobulle orpheline.
      close_map_tooltips(ns("map"), session)
      prx <- leafletProxy(mapId = ns("map"), session = session) %>%
        clearGroup("Continuité du site conservatoire")
      if (!is.null(d) && inherits(d, "sf") && nrow(d) > 0) {
        d$perimetre <- TRUE   # drapeau pour le segment « type » de l'infobulle
        # Mêmes informations que l'infobulle du cadastre, plus les deux champs
        # propres au périmètre : priorité et remarque. Les contrats sont exclus :
        # une parcelle de continuité du site conservatoire n'en porte jamais.
        lbl <- .cf_make_labels(d, user_roles(),
                               fields = c("type", "parcelle", "proprietaire", "commune",
                                          "surface", "priorite", "remarque"))
        # DEUX tracés plutôt qu'un : le motif de hachures est porté par une
        # CLASSE CSS, et une classe vaut pour tout un addPolygons — il n'y a
        # pas de className par entité. Séparer les parcelles retenues est donc
        # le seul moyen de leur donner des diagonales d'une autre teinte.
        #
        # isolate() est délibéré : draw_perimetre() est appelée depuis des
        # observateurs qui ne doivent PAS se remettre à dépendre de la
        # sélection — ils redessineraient la couche entière à chaque clic, en
        # double avec l'appel explicite posé aux deux endroits qui changent la
        # sélection.
        sel_pp <- isolate(perimetre_selection())
        retenue <- d$idpar %in% sel_pp
        .tracer <- function(sous, etiquettes, classe, teinte) {
          if (!nrow(sous)) return(invisible(NULL))
          prx <<- prx %>%
            addPolygons(
              data = sous, group = "Continuité du site conservatoire",
              layerId = ~paste0("pp_", idpar),
              color = teinte, weight = 2,
              # Remplissage de repli, pour le cas où le JS serait indisponible ;
              # le motif hachuré est posé par tc-hatch via la classe.
              fillColor = teinte, fillOpacity = 0.2,
              label = etiquettes,
              options = pathOptions(pane = "perimetre",
                                    className = paste("pp-hachures", classe)),
              highlightOptions = highlightOptions(color = "#083d8c", weight = 3,
                                                  bringToFront = TRUE)
            )
        }
        # Non retenues : même bleu que les parcelles du site
        # (COLORS_PARCELLES$actif_fill) ; la distinction site/continuité est
        # portée par les hachures.
        .tracer(d[!retenue, , drop = FALSE], lbl[!retenue],
                "pp-hachures-bleu", COLORS_PARCELLES$actif_fill)
        # Retenues : la teinte de la sélection, diagonales comprises.
        .tracer(d[retenue, , drop = FALSE], lbl[retenue],
                "pp-hachures-selection", COULEUR_SEL_CONTINUITE)
        session$sendCustomMessage("tc-hatch", list(id = ns("map")))
      }
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      invisible(NULL)
    }

    # Contour englobant (violet tireté, sans remplissage). Non interactif :
    # les clics passent au travers (sélection cadastre/périmètre non gênée).
    draw_contour <- function() {
      d <- contour_data()
      prx <- leafletProxy(mapId = ns("map"), session = session) %>%
        clearGroup("Contour")
      if (!is.null(d)) {
        prx %>%
          addPolygons(
            data = d, group = "Contour",
            fill = FALSE, color = "#7c3aed", weight = 3, dashArray = "8 4",
            options = pathOptions(interactive = FALSE)
          )
      }
      invisible(NULL)
    }

    # Surbrillance des parcelles de continuité SÉLECTIONNÉES (contour rouge
    # épais, non interactif : le clic passe à la parcelle orange dessous).
    draw_perimetre_selection <- function() {
      prx <- leafletProxy(mapId = ns("map"), session = session) %>%
        clearGroup("Périmètre sélectionné")
      sel <- perimetre_selection()
      d   <- perimetre_data()
      if (length(sel) > 0 && !is.null(d) && inherits(d, "sf") && nrow(d) > 0) {
        dd <- d[d$idpar %in% sel, , drop = FALSE]
        if (nrow(dd) > 0) {
          prx %>%
            addPolygons(
              data = dd, group = "Périmètre sélectionné",
              fill = FALSE, color = COULEUR_SEL_CONTINUITE, weight = 4,
              options = pathOptions(interactive = FALSE)
            )
        }
      }
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      invisible(NULL)
    }

    # Exclusivité des QUATRE chantiers de cet onglet : parcelles candidates,
    # continuité, parcelles du site, et périmètres tracés. Les actions du pied
    # de carte seraient ambiguës si deux coexistaient — et les gardes posées
    # une à une ne couvraient qu'une partie des paires.
    #
    # Les périmètres tracés y sont depuis le 2026-10-28, à la demande de
    # l'utilisateur : tracés et parcelles candidates s'enregistraient ENSEMBLE
    # sous un même contrat, et c'est ce mélange qui rendait la disparition des
    # tracés si piégeuse.
    #
    # `sauf` est la sélection qu'on cherche à alimenter. Renvoie TRUE si
    # l'action doit être abandonnée, après avoir nommé celle à vider.
    .autre_selection_en_cours <- function(sauf) {
      autres <- list(
        candidates = list(n = length(parcelles_selectionnees()),
                          nom = "de parcelles candidates"),
        continuite = list(n = length(perimetre_selection()),
                          nom = "de la continuité du site conservatoire"),
        site       = list(n = length(site_selection()),
                          nom = "de parcelles du site"),
        traces     = list(n = length(polygones_manuels_temp()),
                          nom = "de périmètres tracés")
      )
      autres[[sauf]] <- NULL
      for (a in autres) {
        if (a$n > 0) {
          showToast("warning", "Sélection en cours",
                    sprintf(paste0("Une sélection %s est en cours (%d). Videz-la ",
                                   "(❌ Vider) avant d'en commencer une autre."),
                            a$nom, a$n))
          return(TRUE)
        }
      }
      FALSE
    }

    # Contour ORANGE, et non plus rouge. Le rouge se confondait avec le
    # remplissage des parcelles sans maîtrise (COLORS_PARCELLES$other_fill,
    # #e25f62) : sur celles-là, on ne voyait pas qu'on les avait retenues.
    # L'orange reste par ailleurs distinct du rouge de la sélection de la
    # continuité, qui garde le sien : deux sélections, deux couleurs.
    COULEUR_SEL_SITE <- "#ea580c"
    CONTOUR_SEL_SITE <- "#9a3412"   # le même orange, assombri, pour le bord

    # Le surlignage était posé dans le pane par défaut (z-index 400), donc SOUS
    # les parcelles du site (420), sous le cadastre (410) et sous les
    # périmètres manuels (450). Un simple contour s'en tirait tant bien que mal
    # à travers les remplissages semi-transparents ; un aplat, lui, aurait été
    # purement invisible. Il lui faut donc son pane, au-dessus de tous les
    # autres. addMapPane est idempotent, comme le fait déjà
    # draw_perimetres_manuels.
    PANE_SEL_SITE <- "selection-site-pane"

    draw_site_selection <- function() {
      prx <- leafletProxy(mapId = ns("map"), session = session) %>%
        addMapPane(PANE_SEL_SITE, zIndex = 460) %>%
        clearGroup("Parcelle du site sélectionnée")
      sel <- site_selection()

      if (length(sel) > 0) {
        # Parcelles cadastrales.
        d <- parcelles_site_data()
        if (!is.null(d) && inherits(d, "sf") && nrow(d) > 0) {
          dd <- d[d$idpar %in% sel, , drop = FALSE]
          if (nrow(dd) > 0) {
            prx <- prx %>%
              addPolygons(
                data = dd, group = "Parcelle du site sélectionnée",
                fillColor = COULEUR_SEL_SITE, fillOpacity = 0.55,
                color = CONTOUR_SEL_SITE, weight = 2, opacity = 0.95,
                # interactive = FALSE : le clic traverse l'aplat et atteint la
                # parcelle dessous, sans quoi on ne pourrait plus désélectionner.
                options = pathOptions(pane = PANE_SEL_SITE, interactive = FALSE)
              )
          }
        }

        # Périmètres manuels. Ils vivent dans un autre réactif —
        # get_parcelles_by_site ne joint que le cadastre (type_parcelle_id = 1)
        # — et n'étaient donc PAS surlignés : en sélectionner un ne produisait
        # aucun retour à l'écran. La sélection les retient par l'identifiant du
        # périmètre, converti en texte, d'où la comparaison sur as.character.
        pm <- perimetres_manuelles_data()
        if (!is.null(pm) && inherits(pm, "sf") && nrow(pm) > 0) {
          pp <- pm[as.character(pm$id) %in% sel, , drop = FALSE]
          if (nrow(pp) > 0) {
            pp <- sf::st_transform(pp, 4326)
            prx %>%
              addPolygons(
                data = pp, group = "Parcelle du site sélectionnée",
                fillColor = COULEUR_SEL_SITE, fillOpacity = 0.55,
                color = CONTOUR_SEL_SITE, weight = 2, opacity = 0.95,
                options = pathOptions(pane = PANE_SEL_SITE, interactive = FALSE)
              )
          }
        }
      }
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      invisible(NULL)
    }

    clear_site_selection <- function() {
      site_selection_type(NA_integer_)
      if (length(isolate(site_selection())) == 0) return(invisible(NULL))
      site_selection(character(0))
      leafletProxy(mapId = ns("map"), session = session) %>%
        clearGroup("Parcelle du site sélectionnée")
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
    }

    # Les lignes de gestcons.parcelles correspondant à la sélection du site.
    # Même forme que select_site_features_in_bbox, pour réutiliser le chemin de
    # suppression existant sans le dupliquer.
    .site_sel_rows <- function(codes) {
      sid <- site_id_edition()
      if (is.null(sid) || length(codes) == 0) return(NULL)
      in_vals <- paste(dbQuoteString(con, as.character(codes)), collapse = ",")
      safe_db_query(con, glue::glue("
        SELECT p.id AS parcelle_db_id, p.type_parcelle_id,
               COALESCE(c.idpar, p.parcellaire_id::text) AS code_affiche
          FROM gestcons.parcelles p
          LEFT JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
         WHERE p.site_id = {sid} AND NOT p.perimetre
           AND COALESCE(c.idpar, p.parcellaire_id::text) IN ({in_vals})
      "))
    }

    # Toutes les parcelles retenues sont-elles éligibles à la bascule ?
    # Règle reprise de la modale du clic : une parcelle cadastrale, portant au
    # moins un contrat, et dont TOUS les contrats sont en élaboration. Un
    # contrat actif interdit la rétrogradation.
    .site_sel_bascule_possible <- function(codes) {
      r <- .site_sel_rows(codes)
      if (is.null(r) || nrow(r) == 0) return(FALSE)
      if (any(r$type_parcelle_id != 1)) return(FALSE)
      ids <- paste(as.integer(r$parcelle_db_id), collapse = ",")
      n <- safe_db_query(con, glue::glue("
        SELECT
          count(*) FILTER (WHERE cf.statut_id <> {STATUT_CONTRAT_ELABORATION}) AS hors_elab,
          count(DISTINCT cfp.parcelle_id) AS avec_contrat
          FROM gestcons.contrats_foncier_parcelles cfp
          JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
         WHERE cfp.parcelle_id IN ({ids})
      "))
      isTRUE(as.integer(n$hors_elab[1]) == 0L) &&
        isTRUE(as.integer(n$avec_contrat[1]) == nrow(r))
    }

    observeEvent(input$site_sel_vider, { clear_site_selection() })

    observeEvent(input$site_sel_retirer, {
      rows <- .site_sel_rows(site_selection())
      if (is.null(rows) || nrow(rows) == 0) {
        showToast("warning", "Rien à retirer", "La sélection est vide.")
        return(invisible(NULL))
      }
      # Réutilise le chemin de suppression existant, qui sait déjà purger les
      # liaisons de contrats, d'actions, de protection et de source géométrique.
      a_supprimer_bbox(rows)
      n_cad <- sum(rows$type_parcelle_id == 1, na.rm = TRUE)
      n_pm  <- sum(rows$type_parcelle_id == 2, na.rm = TRUE)
      details <- character(0)
      if (n_cad > 0) details <- c(details, sprintf("%d parcelle(s) cadastrale(s)", n_cad))
      if (n_pm  > 0) details <- c(details, sprintf("%d périmètre(s) manuel(s)", n_pm))
      confirm_suppression(
        ns,
        quoi = sprintf("<strong>%d</strong> élément(s) du site", nrow(rows)),
        confirm_id = "confirm_delete_bbox_site",
        details = c(paste(details, collapse = " et "),
                    "Leurs liaisons de contrats et d'actions seront supprimées.")
      )
    })

    observeEvent(input$site_sel_basculer, {
      rows <- .site_sel_rows(site_selection())
      if (is.null(rows) || nrow(rows) == 0) return(invisible(NULL))
      parcelle_a_supprimer_site(as.integer(rows$parcelle_db_id))
      showModal(modalDialog(
        title = "➡️ Basculer en continuité du site conservatoire",
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("confirm_bascule_vers_perimetre"), "Confirmer la bascule",
                       class = "btn btn-primary")
        ),
        tags$p(HTML(sprintf(
          "Basculer <strong>%d</strong> parcelle(s) du site vers la continuité ?",
          nrow(rows)))),
        tags$p("Leurs liaisons de contrat seront supprimées : une parcelle de continuité n'en porte pas.")
      ))
    })

    # Édition en masse des parcelles du site. Même formulaire et même écriture
    # que l'onglet Parcelles — fabriques partagées de helpers.R —, appliqués
    # ici à la sélection de cet onglet. Les périmètres manuels en sont exclus,
    # comme dans l'onglet Parcelles : le formulaire ne décrit que des parcelles
    # cadastrales.
    # --- Modifier UNE parcelle : le formulaire d'avant, pré-rempli ---------
    #
    # Avec plusieurs parcelles retenues, le formulaire d'édition en masse est
    # le bon outil : chaque champ y part sur « ne pas modifier ». Avec UNE
    # seule, il obligeait à ressaisir ce qu'on voyait déjà. On retrouve donc
    # ici le formulaire de l'ancien onglet Parcelles, valeurs courantes
    # comprises — et sa variante pour les périmètres manuels, qui ne portent
    # ni propriétaire ni surface cadastrale.
    parcelle_edit_id   <- reactiveVal(NULL)
    parcelle_edit_type <- reactiveVal(NULL)   # 1 = cadastre, 2 = manuel
    # Chaque sélecteur de contrat n'affiche QUE la première liaison, alors
    # qu'une parcelle peut en porter plusieurs. On retient laquelle était à
    # l'écran pour ne remplacer que celle-là (cf. mod_contrats, même règle).
    contrat_f_rendu <- reactiveVal(NA_integer_)
    contrat_a_rendu <- reactiveVal(NA_integer_)

    .form_parcelle_unique <- function(row) {
      pid  <- as.integer(row$parcelle_db_id[1])
      type <- as.integer(row$type_parcelle_id[1])

      infos <- safe_db_query(con, glue::glue_sql("
        SELECT p.bnd_id, p.pour_part_id, p.source_surf_parc_id,
               p.echelle_numerisation_id, p.domaine_public_id,
               p.proprietaire_id, p.zpf_id, p.chasse_id,
               COALESCE((SELECT g.source_geom_id
                           FROM gestcons.parcelles_sources_geom g
                          WHERE g.parcelle_id = p.id
                          ORDER BY g.source_geom_id LIMIT 1),
                        {SOURCE_GEOM_MANUELLE}) AS source_geom_id
          FROM gestcons.parcelles p
         WHERE p.id = {pid}", .con = con))
      if (is.null(infos) || !nrow(infos)) {
        showToast("error", "Parcelle introuvable", "Elle a peut-être été retirée du site.")
        return(invisible(NULL))
      }

      # `dico_source_geom_parcelle`, et non `dico_source_geom` : cette table
      # n'existe pas. La requête échouait en silence depuis le 2026-10-26 et
      # la liste sortait vide — le champ ne pouvait plus être modifié.
      dico_source_geom <- safe_db_query(con,
        "SELECT id, libelle FROM gestcons.dico_source_geom_parcelle ORDER BY libelle")
      cf <- safe_db_query(con, "SELECT id, nom FROM gestcons.contrats_fonciers ORDER BY nom")
      ca <- safe_db_query(con, "SELECT id, nom FROM gestcons.contrats_agricoles ORDER BY nom")
      lien_f <- safe_db_query(con, glue::glue_sql(
        "SELECT contrat_id FROM gestcons.contrats_foncier_parcelles WHERE parcelle_id = {pid}", .con = con))
      lien_a <- safe_db_query(con, glue::glue_sql(
        "SELECT contrat_agri_id FROM gestcons.contrats_agricoles_parcelles WHERE parcelle_id = {pid}", .con = con))

      f_actuel <- if (!is.null(lien_f) && nrow(lien_f) && !is.na(lien_f$contrat_id[1])) as.integer(lien_f$contrat_id[1]) else NA_integer_
      a_actuel <- if (!is.null(lien_a) && nrow(lien_a) && !is.na(lien_a$contrat_agri_id[1])) as.integer(lien_a$contrat_agri_id[1]) else NA_integer_

      parcelle_edit_id(pid); parcelle_edit_type(type)
      contrat_f_rendu(f_actuel); contrat_a_rendu(a_actuel)

      sel_contrats <- tagList(
        selectInput(ns("pu_contrat_id"), "Contrat foncier associé",
                    choices  = c("— Aucun contrat —" = " ", stats::setNames(cf$id, cf$nom)),
                    selected = if (!is.na(f_actuel)) as.character(f_actuel) else " ",
                    selectize = TRUE),
        selectInput(ns("pu_contrat_agri_id"), "Contrat agricole associé",
                    choices  = c("— Aucun contrat —" = " ", stats::setNames(ca$id, ca$nom)),
                    selected = if (!is.na(a_actuel)) as.character(a_actuel) else " ",
                    selectize = TRUE)
      )
      sel_geom <- tagList(
        selectInput(ns("pu_source_geom_id"), "Source géométrique",
                    choices = stats::setNames(dico_source_geom$id, dico_source_geom$libelle),
                    selected = infos$source_geom_id[1]),
        selectInput(ns("pu_echelle_numerisation_id"), "Échelle de numérisation",
                    choices = stats::setNames(dico_echelle$id, dico_echelle$libelle),
                    selected = infos$echelle_numerisation_id[1])
      )

      if (identical(type, 2L)) {
        showModal(modalDialog(
          title = paste("✏️ Modifier le périmètre manuel", row$code_affiche[1]),
          size = "l", easyClose = TRUE,
          fluidPage(sel_geom, sel_contrats),
          footer = tagList(modalButton("Annuler"),
                           actionButton(ns("pu_maj_perimetre"), "💾 Mettre à jour",
                                        class = "btn-primary"))
        ))
      } else {
        showModal(modalDialog(
          title = paste("✏️ Modifier la parcelle", row$code_affiche[1]),
          size = "l", easyClose = TRUE,
          fluidPage(
            checkboxInput(ns("pu_bnd_id"), "BND ?", value = isTRUE(infos$bnd_id[1] == 1)),
            checkboxInput(ns("pu_pour_part_id"), "Pour partie ?", value = isTRUE(infos$pour_part_id[1] == 1)),
            selectInput(ns("pu_source_surf_parc_id"), "Source de la surface",
                        choices = stats::setNames(dico_source_surf_parc$id, dico_source_surf_parc$libelle),
                        selected = infos$source_surf_parc_id[1]),
            sel_geom,
            checkboxInput(ns("pu_domaine_public_id"), "Domaine public ?", value = isTRUE(infos$domaine_public_id[1] == 1)),
            selectInput(ns("pu_proprietaire_id"), "Propriétaire",
                        choices = stats::setNames(dico_cen$id, dico_cen$libelle_long),
                        selected = infos$proprietaire_id[1]),
            checkboxInput(ns("pu_zpf_id"), "ZPF ?", value = isTRUE(infos$zpf_id[1] == 1)),
            selectInput(ns("pu_chasse_id"), "Chasse",
                        choices = stats::setNames(dico_chasse$id, dico_chasse$libelle),
                        selected = infos$chasse_id[1]),
            sel_contrats
          ),
          footer = tagList(modalButton("Annuler"),
                           actionButton(ns("pu_maj_parcelle"), "💾 Mettre à jour",
                                        class = "btn-primary"))
        ))
      }
      invisible(NULL)
    }

    # Source géométrique : une parcelle n'en porte qu'une. Purge puis pose en
    # DEUX ordres dans une même transaction, et non en un seul via CTE :
    # l'index d'unicité verrait encore l'ancienne ligne au moment de
    # l'insertion, et le ON CONFLICT avalerait l'insertion en silence.
    .pu_source_geom <- function(pid) {
      src <- suppressWarnings(as.integer(input$pu_source_geom_id))
      if (is.na(src)) return(TRUE)
      tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          tx_execute(conn, glue::glue_sql(
            "DELETE FROM gestcons.parcelles_sources_geom WHERE parcelle_id = {pid}", .con = conn))
          tx_execute(conn, glue::glue_sql(
            "INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
             VALUES ({pid}, {src})", .con = conn))
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Source géométrique non enregistrée", conditionMessage(e)); FALSE
      })
    }

    # Contrats : on ne remplace QUE la liaison affichée. L'ancien code posait
    # un UPDATE sur parcelle_id seul, qui écrasait toutes les liaisons d'un
    # coup et violait la clé primaire sur les parcelles multi-contrat.
    .pu_contrats <- function(pid) {
      .num_ou_na <- function(x) {
        if (is.null(x) || identical(x, " ") || !nzchar(trimws(as.character(x)))) NA_integer_
        else suppressWarnings(as.integer(x))
      }
      f_nouveau <- .num_ou_na(input$pu_contrat_id)
      a_nouveau <- .num_ou_na(input$pu_contrat_agri_id)
      f_ancien  <- contrat_f_rendu(); a_ancien <- contrat_a_rendu()
      if (identical(f_nouveau, f_ancien) && identical(a_nouveau, a_ancien)) return(TRUE)
      tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          .remplacer <- function(tbl, col, ancien, nouveau) {
            if (identical(ancien, nouveau)) return(invisible(NULL))
            if (!is.na(ancien)) tx_execute(conn, glue("
              DELETE FROM gestcons.{tbl} WHERE parcelle_id = {pid} AND {col} = {ancien}"))
            if (!is.na(nouveau)) tx_execute(conn, glue("
              INSERT INTO gestcons.{tbl} ({col}, parcelle_id)
              VALUES ({nouveau}, {pid}) ON CONFLICT DO NOTHING"))
            invisible(NULL)
          }
          .remplacer("contrats_foncier_parcelles",   "contrat_id",      f_ancien, f_nouveau)
          .remplacer("contrats_agricoles_parcelles", "contrat_agri_id", a_ancien, a_nouveau)
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Contrats non enregistrés", conditionMessage(e)); FALSE
      })
    }

    .pu_apres_enregistrement <- function(quoi) {
      load_parcelles_sites(); load_perimetres_manuels()
      if (!is.null(contrats_update_trigger))
        contrats_update_trigger(isolate(contrats_update_trigger()) + 1)
      removeModal()
      clear_site_selection()
      draw_parcelles_site(parcelles_site_data(), map_id = ns("map"),
                          session = session, user_roles = user_roles())
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      showToast("success", quoi, "💾 Les informations ont été mises à jour.")
      log_action(session, current_user_rv, paste("Sites :", quoi))
    }

    observeEvent(input$pu_maj_parcelle, {
      pid <- parcelle_edit_id(); req(!is.null(pid))
      user_db_val <- user_to_db()
      ok <- safe_db_execute(con, glue::glue_sql("
        UPDATE gestcons.parcelles
        SET bnd_id = {ifelse(isTRUE(input$pu_bnd_id), 1L, 0L)},
            pour_part_id = {ifelse(isTRUE(input$pu_pour_part_id), 1L, 0L)},
            source_surf_parc_id = {as.integer(input$pu_source_surf_parc_id)},
            echelle_numerisation_id = {as.integer(input$pu_echelle_numerisation_id)},
            domaine_public_id = {ifelse(isTRUE(input$pu_domaine_public_id), 1L, 0L)},
            proprietaire_id = {as.integer(input$pu_proprietaire_id)},
            zpf_id = {ifelse(isTRUE(input$pu_zpf_id), 1L, 0L)},
            chasse_id = {as.integer(input$pu_chasse_id)},
            modifie_par = {user_db_val},
            date_modification = NOW()
        WHERE id = {pid}", .con = con))
      if (!isTRUE(.pu_source_geom(pid))) return(invisible(NULL))
      if (!isTRUE(.pu_contrats(pid)))    return(invisible(NULL))
      .pu_apres_enregistrement("Parcelle mise à jour")
    })

    observeEvent(input$pu_maj_perimetre, {
      pid <- parcelle_edit_id(); req(!is.null(pid))
      user_db_val <- user_to_db()
      safe_db_execute(con, glue::glue_sql("
        UPDATE gestcons.parcelles
        SET echelle_numerisation_id = {as.integer(input$pu_echelle_numerisation_id)},
            modifie_par = {user_db_val},
            date_modification = NOW()
        WHERE id = {pid}", .con = con))
      if (!isTRUE(.pu_source_geom(pid))) return(invisible(NULL))
      if (!isTRUE(.pu_contrats(pid)))    return(invisible(NULL))
      .pu_apres_enregistrement("Périmètre manuel mis à jour")
    })

    observeEvent(input$site_sel_modifier, {
      rows <- .site_sel_rows(site_selection())

      # Une seule parcelle retenue : son formulaire, pré-rempli — y compris
      # pour un périmètre manuel, que l'édition en masse ne sait pas traiter.
      if (!is.null(rows) && nrow(rows) == 1) {
        return(.form_parcelle_unique(rows))
      }

      cad  <- if (is.null(rows)) NULL else rows[rows$type_parcelle_id == 1, , drop = FALSE]
      if (is.null(cad) || nrow(cad) == 0) {
        showToast("warning", "Aucune parcelle cadastrale",
                  "La sélection ne contient que des périmètres manuels, qui ne se modifient pas par ce formulaire.")
        return(invisible(NULL))
      }
      showModal(modalDialog(
        title = sprintf("🛠️ Modifier %d parcelle(s) du site", nrow(cad)),
        size = "l", easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("apply_bulk_update"), "💾 Appliquer", class = "btn btn-primary")
        ),
        parcelles_bulk_fields(ns, con, dico_cen, dico_source_surf_parc,
                              dico_echelle, dico_chasse)
      ))
    })

    observeEvent(input$apply_bulk_update, {
      shinybusy::show_modal_spinner(spin = "circle", color = COULEUR_SPINNER,
                                    text = "Mise à jour en cours...")
      on.exit(shinybusy::remove_modal_spinner(), add = TRUE)

      rows <- .site_sel_rows(site_selection())
      if (is.null(rows) || nrow(rows) == 0) return(invisible(NULL))
      ids_db <- as.integer(rows$parcelle_db_id[rows$type_parcelle_id == 1])
      if (length(ids_db) == 0) return(invisible(NULL))

      ok <- parcelles_bulk_apply(con, ids_db, input, user_to_db())
      if (!isTRUE(ok)) return(invisible(NULL))

      removeModal()
      load_parcelles_sites()
      draw_parcelles_site(parcelles_site_data(), map_id = ns("map"),
                          session = session, user_roles = user_roles())
      clear_site_selection()
      showToast("success", "Modifications appliquées",
                sprintf("%d parcelle(s) mise(s) à jour.", length(ids_db)))
      log_action(session, current_user_rv,
                 "Modification en masse de parcelles depuis l'onglet Sites")
      if (!is.null(contrats_update_trigger)) {
        contrats_update_trigger(isolate(contrats_update_trigger()) + 1)
      }
    })

    clear_perimetre_selection <- function() {
      if (length(isolate(perimetre_selection())) == 0) return(invisible(NULL))
      perimetre_selection(character(0))
      leafletProxy(mapId = ns("map"), session = session) %>%
        clearGroup("Périmètre sélectionné")
      # Rendre leurs diagonales bleues aux parcelles qui ne sont plus retenues.
      draw_perimetre()
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
    }

    observeEvent(input$clear_perimetre_selection, {
      clear_perimetre_selection()
    })

    # (Re)dessin quand les données changent (choix du site, ajout/retrait…)
    observeEvent(perimetre_data(), {
      draw_perimetre()
      draw_perimetre_selection()
    }, ignoreNULL = FALSE)

    observeEvent(contour_data(), {
      draw_contour()
    }, ignoreNULL = FALSE)

    # Ajout de la sélection cadastrale à la continuité du site conservatoire. Défauts de maîtrise
    # identiques à l'association d'une parcelle au site (surface = contenance) ;
    # garde-fous : pas déjà parcelle de CE site, doublons ignorés (ON CONFLICT
    # sur l'index unique partiel du périmètre).
    observeEvent(input$add_to_perimetre, {
      if (!isTRUE(can_edit_site())) return()
      sid <- site_id_edition()
      ids <- parcelles_selectionnees()
      req(sid, length(ids) > 0)
      u       <- dbQuoteLiteral(con, user_to_db())
      in_vals <- paste(dbQuoteString(con, ids), collapse = ",")
      # Un seul ordre SQL : la source géométrique des parcelles insérées est
      # posée dans la foulée (PCI, elles sont cadastrales). Le compte rendu par
      # safe_db_execute reste le nombre de parcelles, une ligne de liaison étant
      # créée par parcelle insérée.
      n <- safe_db_execute(con, glue("
        WITH ins AS (
          INSERT INTO gestcons.parcelles_base (
            site_id, parcellaire_id, type_parcelle_id, perimetre,
            mesure_compens_id, echelle_numerisation_id, source_surf_parc_id,
            bnd_id, pour_part_id, surf_parc_maitrise_m2, domaine_public_id,
            proprietaire_id, zpf_id, chasse_id, actif,
            cree_par, date_creation, modifie_par, date_modification
          )
          SELECT {sid}, c.id, 1, true,
                 0, 1, 1,
                 0, 0, c.dcntpa, 0,
                 '4', 0, 1, true,
                 {u}, NOW(), {u}, NOW()
          FROM gestcons.dico_cadastre c
          WHERE c.idpar IN ({in_vals})
            AND NOT EXISTS (
              SELECT 1 FROM gestcons.parcelles_base p
              WHERE p.parcellaire_id = c.id AND p.type_parcelle_id = 1
                AND p.site_id = {sid} AND NOT p.perimetre
            )
          ON CONFLICT (site_id, parcellaire_id) WHERE perimetre DO NOTHING
          RETURNING id
        )
        INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
        SELECT id, {SOURCE_GEOM_PCI} FROM ins
        ON CONFLICT DO NOTHING
      "))
      # Acteurs « propriétaire » : même règle que l'association au site. On passe
      # toute la sélection et non les seules lignes insérées — l'appel est
      # dédoublonné, et le propriétaire d'une parcelle déjà présente est de
      # toute façon déjà acteur.
      acteurs_ins <- tryCatch(
        pool::poolWithTransaction(con, function(conn) {
          creer_acteurs_proprietaires(conn, ids, type_acteur_proprio_id)
        }),
        error = function(e) {
          message("Acteurs (continuité du site conservatoire) : ", conditionMessage(e))
          NULL
        }
      )
      if (!is.null(acteurs_ins) && nrow(acteurs_ins) > 0) {
        try(refresh_acteurs(con), silent = TRUE)
        showToast("success", "Acteurs ajoutés",
                  sprintf("%d acteur(s) inséré(s).", nrow(acteurs_ins)))
      }

      clear_selection()
      perimetre_trigger(isolate(perimetre_trigger()) + 1)
      resume_site_trigger(isolate(resume_site_trigger()) + 1)
      if (!is.null(contrats_update_trigger)) contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      showToast("success", "Continuité du site conservatoire",
                sprintf("✅ %s parcelle(s) ajoutée(s) à la continuité du site conservatoire.", n))
      log_action(session, current_user_rv,
                 paste0("Site #", sid, " : ", n, " parcelle(s) ajoutée(s) à la continuité du site conservatoire"))
    })

    # Bascule périmètre -> parcelles du site : confirmation légère (nb + surface)
    observeEvent(input$bascule_open, {
      if (!isTRUE(can_edit_site())) return()
      sel <- perimetre_selection()
      if (length(sel) == 0) return()
      d <- perimetre_data()
      surf <- 0
      if (!is.null(d) && inherits(d, "sf")) {
        dd <- sf::st_drop_geometry(d)
        surf <- sum(suppressWarnings(as.numeric(dd$dcntpa[dd$idpar %in% sel])), na.rm = TRUE)
      }
      # Une parcelle du site est toujours rattachée à un contrat : la bascule
      # présente donc le même sélecteur que l'ajout de parcelles au site.
      sel_contrat <- .contrat_selector_ui()
      if (is.null(sel_contrat)) { .modal_aucun_contrat(); return(invisible(NULL)) }

      showModal(modalDialog(
        title = "Basculer en parcelles du site",
        tags$p(sprintf("Vous allez basculer %d parcelle(s) (%.2f ha) de la continuité du site conservatoire vers les parcelles du site.",
                       length(sel), surf / 10000)),
        tags$p(class = "text-muted",
               "La maîtrise foncière est initialisée par défaut (surface = contenance cadastrale), ",
               "à préciser ensuite dans l'onglet Parcelles. ",
               "Le propriétaire cadastral est conservé automatiquement."),
        helpText("Sélectionnez le contrat auquel rattacher les parcelles basculées."),
        sel_contrat,
        footer = tagList(
          actionButton(ns("bascule_confirm"), "➡️ Confirmer la bascule", class = "btn btn-primary"),
          modalButton("Annuler")
        ),
        easyClose = TRUE
      ))
    })

    # Bascule = UPDATE : la parcelle GARDE son id, donc son historique (liens
    # d'actions notamment) la suit automatiquement. Garde-fou : la parcelle ne
    # doit pas déjà être parcelle de site ailleurs (unicité globale des
    # parcelles de site). La remarque du périmètre est abandonnée (décision).
    observeEvent(input$bascule_confirm, {
      if (!isTRUE(can_edit_site())) return()
      sid <- site_id_edition()
      ids <- perimetre_selection()
      req(sid)
      if (length(ids) == 0) return()
      # Contrat obligatoire, comme à l'ajout d'une parcelle au site.
      contrat_id <- .contrat_choisi_valide()
      if (is.null(contrat_id)) return(invisible(NULL))

      u       <- dbQuoteLiteral(con, user_to_db())
      in_vals <- paste(dbQuoteString(con, ids), collapse = ",")

      # UPDATE et rattachement au contrat dans la MÊME transaction : une
      # parcelle de site sans contrat serait un état incohérent.
      # RETURNING donne les id réellement basculés — le NOT EXISTS peut en
      # écarter, et ce sont eux, et eux seuls, qu'il faut rattacher.
      n <- tryCatch(
        pool::poolWithTransaction(con, function(conn) {
          bascules <- DBI::dbGetQuery(conn, glue("
            UPDATE gestcons.parcelles_base p
            SET perimetre = false,
                remarque  = NULL,
                modifie_par = {u},
                date_modification = NOW()
            FROM gestcons.dico_cadastre c
            WHERE c.id = p.parcellaire_id
              AND p.site_id = {sid} AND p.perimetre
              AND c.idpar IN ({in_vals})
              AND NOT EXISTS (
                SELECT 1 FROM gestcons.parcelles_base q
                WHERE q.parcellaire_id = p.parcellaire_id
                  AND q.type_parcelle_id = 1 AND NOT q.perimetre
              )
            RETURNING p.id
          "))
          if (nrow(bascules) > 0) {
            vals <- paste(sprintf("(%d, %d)", contrat_id, as.integer(bascules$id)), collapse = ", ")
            # La clé primaire est (contrat_id, parcelle_id) : ON CONFLICT couvre
            # une parcelle déjà rattachée à ce contrat dans une vie antérieure.
            tx_execute(conn, glue("
              INSERT INTO gestcons.contrats_foncier_parcelles (contrat_id, parcelle_id)
              VALUES {vals}
              ON CONFLICT DO NOTHING
            "))
          }
          nrow(bascules)
        }),
        error = function(e) {
          showToast("error", "Bascule impossible", paste("Détails :", conditionMessage(e)))
          NULL
        }
      )
      if (is.null(n)) return(invisible(NULL))
      removeModal()
      clear_perimetre_selection()
      perimetre_trigger(isolate(perimetre_trigger()) + 1)
      resume_site_trigger(isolate(resume_site_trigger()) + 1)
      # Les parcelles du site ont changé : notification via le canal commun
      # (rechargement + redessin ici même et dans l'onglet Parcelles).
      if (!is.null(contrats_update_trigger)) {
        contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      } else {
        load_parcelles_sites()
        draw_parcelles_site(parcelles_site_data(), map_id = ns("map"), session = session, user_roles = user_roles())
      }
      showToast("success", "Bascule effectuée",
                sprintf("✅ %s parcelle(s) basculée(s) en parcelles du site.", n))
      log_action(session, current_user_rv,
                 paste0("Site #", sid, " : ", n, " parcelle(s) basculée(s) de la continuité du site conservatoire vers les parcelles du site"))
    })

    # Retrait du périmètre (en lot) : confirmation puis suppression.
    observeEvent(input$perimetre_retirer, {
      if (!isTRUE(can_edit_site())) return()
      sel <- perimetre_selection()
      if (length(sel) == 0) return()
      showModal(modalDialog(
        title = "Retirer de la continuité du site conservatoire",
        tags$p(sprintf("Retirer %d parcelle(s) de la continuité du site conservatoire ? Elles ne deviennent PAS des parcelles du site.",
                       length(sel))),
        footer = tagList(
          actionButton(ns("perimetre_retirer_confirm"), "🗑 Confirmer le retrait", class = "btn btn-danger"),
          modalButton("Annuler")
        ),
        easyClose = TRUE
      ))
    })

    observeEvent(input$perimetre_retirer_confirm, {
      if (!isTRUE(can_edit_site())) return()
      sid <- site_id_edition()
      sel <- perimetre_selection()
      req(sid)
      if (length(sel) == 0) return()
      in_vals <- paste(dbQuoteString(con, sel), collapse = ",")
      # Un seul ordre SQL : la liaison de source géométrique est purgée avec la
      # parcelle. Sa clé étrangère est en NO ACTION, donc vérifiée en fin
      # d'instruction — les deux DELETE d'un même ordre ne se gênent pas.
      n <- safe_db_execute(con, glue("
        WITH cibles AS (
          SELECT p.id
          FROM gestcons.parcelles_base p
          JOIN gestcons.dico_cadastre c ON c.id = p.parcellaire_id
          WHERE p.site_id = {sid} AND p.perimetre
            AND c.idpar IN ({in_vals})
        ), purge AS (
          DELETE FROM gestcons.parcelles_sources_geom
          WHERE parcelle_id IN (SELECT id FROM cibles)
        )
        DELETE FROM gestcons.parcelles_base
        WHERE id IN (SELECT id FROM cibles)
      "))
      removeModal()
      clear_perimetre_selection()
      perimetre_trigger(isolate(perimetre_trigger()) + 1)
      resume_site_trigger(isolate(resume_site_trigger()) + 1)
      if (!is.null(contrats_update_trigger)) contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      showToast("success", "Continuité du site conservatoire", sprintf("%s parcelle(s) retirée(s).", n))
      log_action(session, current_user_rv,
                 paste0("Site #", sid, " : ", n, " parcelle(s) retirée(s) de la continuité du site conservatoire"))
    })

    #' Modification d'une parcelle de la continuité du site conservatoire.
    #' --------------------------------------------------
    #' Les deux champs que porte une parcelle de périmètre et qui lui sont
    #' propres : sa remarque — pourquoi elle intéresse — et sa priorité, la
    #' même notion que dans l'onglet Stratégie foncière, puisque c'est la même
    #' colonne de `parcelles_base`. Le reste des caractéristiques de maîtrise
    #' n'a pas de sens ici : la parcelle n'est pas maîtrisée.
    observeEvent(input$perimetre_editer, {
      if (!isTRUE(can_edit_site())) return(invisible(NULL))
      sel <- perimetre_selection()
      if (length(sel) != 1) return(invisible(NULL))
      d <- perimetre_data()
      if (is.null(d)) return(invisible(NULL))
      ligne <- sf::st_drop_geometry(d)[d$idpar == sel[1], , drop = FALSE]
      if (nrow(ligne) == 0) return(invisible(NULL))
      prio <- if (is.null(ligne$priorite_id)) NA else ligne$priorite_id[1]
      showModal(modalDialog(
        title = htmltools::HTML(glue::glue("Parcelle n°{sel[1]} — continuité du site conservatoire")),
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("perimetre_edit_save"), "💾 Enregistrer", class = "btn btn-primary")
        ),
        selectInput(ns("perimetre_edit_priorite"), "🎯 Priorité",
                    choices  = c("— Non renseignée —" = "", "Priorité 1" = "1", "Priorité 2" = "2"),
                    selected = if (is.na(prio)) "" else as.character(prio)),
        # Une remarque absente arrive en NA, que `%||%` laisse passer — il ne
        # teste que NULL : la zone afficherait « NA », et l'enregistrement
        # l'écrirait en base.
        textAreaInput(ns("perimetre_edit_remarque"), "📝 Remarque (intérêt de la parcelle)",
                      value = if (is.na(ligne$remarque[1])) "" else ligne$remarque[1],
                      rows = 4, width = "100%")
      ))
    })

    observeEvent(input$perimetre_edit_save, {
      if (!isTRUE(can_edit_site())) return(invisible(NULL))
      sid <- site_id_edition()
      sel <- perimetre_selection()
      req(sid, length(sel) == 1)
      prio <- input$perimetre_edit_priorite
      prio_sql <- if (is.null(prio) || !nzchar(prio)) "NULL" else as.character(as.integer(prio))
      ok <- tryCatch({
        safe_db_execute(con, glue::glue("
          UPDATE gestcons.parcelles_base p
             SET remarque    = {dbQuoteLiteral(con, input$perimetre_edit_remarque %||% '')},
                 priorite_id = {prio_sql},
                 modifie_par = {dbQuoteLiteral(con, user_to_db())},
                 date_modification = NOW()
            FROM gestcons.dico_cadastre c
           WHERE c.id = p.parcellaire_id
             AND p.site_id = {sid} AND p.perimetre
             AND c.idpar = {dbQuoteLiteral(con, sel[1])}
        "))
        TRUE
      }, error = function(e) {
        showToast("error", "Erreur d'enregistrement", conditionMessage(e)); FALSE
      })
      if (!isTRUE(ok)) return(invisible(NULL))
      removeModal()
      perimetre_trigger(isolate(perimetre_trigger()) + 1)
      if (!is.null(contrats_update_trigger)) contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      showToast("success", "Parcelle enregistrée", paste0("Parcelle ", sel[1], "."))
      log_action(session, current_user_rv,
                 paste0("Site #", sid, " : parcelle ", sel[1],
                        " de la continuité du site conservatoire modifiée"))
    })

    reset <- function() {
      clear_perimetre_selection()
      bbox_site_rv(NULL)
      
      updateSelectizeInput(session, "site_selector", selected = "")
      # si tu as un RV interne type site_id_edition(), remets-le à NULL ici :
      if (exists("site_id_edition", inherits = TRUE)) try(site_id_edition(NULL), silent = TRUE)
      # nettoyage doux de la carte (groupes éphémères + popups)
      prx <- leaflet::leafletProxy(ns("map"), session)
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      
      for (g in EPHEMERAL_GROUPS) prx <- prx |> leaflet::clearGroup(g)
      prx |> leaflet::clearPopups()
      
      remove_legend(ns("map"), session, layer_id = LEGEND_ID)
      
      session$sendCustomMessage("clear-polygones", ns("map"))
      session$sendCustomMessage("af-reset-click",  ns("map"))
      
      selected_site_rv(NULL)
    }
    
    # R/mod_sites.R (après les autres observeEvent de suppression)
    
    #' -------------------------
    #' Suppression simple d'une parcelle/périmètre du site (via clic)
    #' -------------------------
    #' Bascule d'une parcelle du site vers la continuité du site conservatoire
    #' -----------------------------------------------------
    #' Sens inverse de la bascule historique (continuité du site conservatoire -> site). La ligne
    #' est CONSERVÉE, seul `perimetre` passe à TRUE : l'id ne change pas, donc
    #' l'historique d'actions suit la parcelle — c'était la raison d'être de la
    #' fusion des deux tables. Les liens de contrat sont supprimés : une parcelle
    #' de la continuité du site conservatoire n'en porte pas, c'est l'invariant du modèle.
    observeEvent(input$confirm_bascule_vers_perimetre, {
      debug_print("observeEvent(input$confirm_bascule_vers_perimetre")
      pid <- parcelle_a_supprimer_site()
      sid <- site_id_edition()
      req(pid, sid)
      if (!isTRUE(can_edit_site())) {
        showToast("warning", "Lecture seule",
                  "Vous n'avez pas les droits (AD ou RS) pour modifier ce site.")
        return(invisible(NULL))
      }

      u <- user_to_db()
      ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          # pid porte PLUSIEURS parcelles depuis que la bascule se déclenche sur
          # une sélection et non plus sur un clic unique, d'où le IN et
          # l'expansion {pid*} de glue_sql.
          tx_execute(conn, glue::glue_sql("
            DELETE FROM gestcons.contrats_foncier_parcelles WHERE parcelle_id IN ({pid*})
          ", .con = conn))
          tx_execute(conn, glue::glue_sql("
            DELETE FROM gestcons.contrats_agricoles_parcelles WHERE parcelle_id IN ({pid*})
          ", .con = conn))
          # `AND NOT perimetre` : garde contre un double clic ou une session
          # concurrente qui aurait déjà basculé les parcelles.
          n <- tx_execute(conn, glue::glue_sql("
            UPDATE gestcons.parcelles_base
               SET perimetre = TRUE,
                   modifie_par = {u},
                   date_modification = NOW()
             WHERE id IN ({pid*}) AND NOT perimetre
          ", .con = conn))
          if (is.null(n) || n < length(pid)) {
            stop(sprintf("%d parcelle(s) sur %d ne sont plus des parcelles du site.",
                         length(pid) - (n %||% 0L), length(pid)))
          }
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Erreur de bascule", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(ok)) return(invisible(NULL))

      removeModal()
      parcelle_a_supprimer_site(NULL)
      clear_site_selection()

      # Les deux couches changent : la parcelle quitte « Parcelles du site » et
      # rejoint « Continuité du site conservatoire ».
      load_parcelles_sites()
      perimetre_trigger(isolate(perimetre_trigger()) + 1)
      resume_site_trigger(isolate(resume_site_trigger()) + 1)
      if (!is.null(contrats_update_trigger)) {
        contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      }
      invalidate_site_layer_hash(ns("map"), session)
      draw_parcelles_site(parcelles_site_data(), map_id = ns("map"),
                          session = session, user_roles = user_roles())
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))

      log_action(session, current_user_rv,
                 paste0("Site #", sid, " : parcelle #", pid,
                        " basculée du site vers la continuité du site conservatoire"))
      showToast("success", "Continuité du site conservatoire",
                "🎯 La parcelle a été basculée en continuité du site conservatoire ; ses liens de contrat ont été supprimés.")
    })

    observeEvent(input$confirm_delete_single_parcelle_site, {
      debug_print("observeEvent(input$confirm_delete_single_parcelle_site")
      removeModal()
      
      parcelle_db_id <- parcelle_a_supprimer_site()
      site_id        <- site_id_edition()
      req(parcelle_db_id, site_id)
      
      # Récupérer les infos nécessaires pour la suppression conditionnelle (périmètre manuel)
      parcelle_info <- safe_db_query(con, glue::glue("
        SELECT type_parcelle_id, parcellaire_id 
        FROM gestcons.parcelles 
        WHERE id = {parcelle_db_id} AND site_id = {site_id}
      "))
      
      if (nrow(parcelle_info) == 0) {
        showToast("error", "Erreur", "L'élément n'a pas pu être trouvé pour suppression.")
        return(invisible(NULL))
      }
      
      type_parcelle <- parcelle_info$type_parcelle_id[1]
      parcellaire_id <- parcelle_info$parcellaire_id[1]
      
      # 1. On réserve la connexion
      conn <- pool::poolCheckout(con) 
      
      # 2. CRUCIAL : On s'assure qu'elle revient quoi qu'il arrive (même si erreur)
      on.exit(pool::poolReturn(conn), add = TRUE)
      
      tryCatch({
        dbBegin(conn)
        
        # 1. Suppression du lien des contrats et du lien des actions
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.contrats_foncier_parcelles
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.contrats_agricoles_parcelles
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.animation_fonciere_parcelles
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.animation_contrat_agricole_parcelles
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_protection
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_sources_geom
          WHERE parcelle_id = {parcelle_db_id}
        "))
        
        # 2. Suppression de la géométrie manuelle si c'est un périmètre manuel (type 2)
        if (type_parcelle == 2) {
          tx_execute(conn, glue::glue("
            DELETE FROM gestcons.perimetre_parcellaire_manuel
            WHERE id = {parcellaire_id}
          "))
        }
        
        # 3. Suppression de l'entrée dans gestcons.parcelles
        tx_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles
          WHERE id = {parcelle_db_id} AND site_id = {site_id}
        "))

        DBI::dbCommit(conn)
        invalidate_sites_coords_cache()
        
        # ⬇️ à ajouter après une modification effective des parcelles du site
        if (!is.null(contrats_update_trigger)) {
          contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
        }
        
        # MAJ UI
        parcelle_a_supprimer_site(NULL)
        clear_site_selection()
        load_parcelles_sites()       # Rechargement des parcelles du site
        load_perimetres_manuels()    # Rechargement des périmètres manuels
        
        # Mise à jour de la carte
        leafletProxy(mapId = ns("map"), session = session) %>%
          clearGroup("Parcelles du site") %>%
          clearGroup("Périmètres manuels")
        # Indispensable ici : on redessine juste après. Sans invalidation, si les
        # données rechargées sont identiques (retrait d'un périmètre manuel, par
        # exemple), le redessin est court-circuité et la couche reste vide.
        invalidate_site_layer_hash(ns("map"), session)
        invalidate_perim_layer_hash(ns("map"), session)

        # Redessiner les couches persistantes
        draw_parcelles_site(parcelles_site_data(), map_id = ns("map"), session = session, user_roles = user_roles())
        draw_perimetres_manuels(perimetres_manuelles_data(), map_id = ns("map"), session = session)
        session$sendCustomMessage("invalidate-map", list(id = ns("map")))
        
        log_action(session, current_user_rv, "Site : élément retiré du site")
        showToast("warning", "Élément retiré", 
                  "🗑 L'élément a été retiré du site.")
        
      }, error = function(e) {
        DBI::dbRollback(conn)
        showToast("error", "Erreur de suppression", conditionMessage(e))
      })
    })
    
    #' -------------------------
    #' Observation du trigger de Contrats
    #' -------------------------
    observeEvent(contrats_update_trigger(), {
      debug_print("observeEvent(contrats_update_trigger) -> Rechargement forcé des données du site")
      req(site_id_edition()) # Ne s'exécute que si un site est actif
      
      # Recharge les données critiques (parcelles et périmètres)
      load_parcelles_sites()
      load_perimetres_manuels()
      
      # Force le redessin de la carte (pour mise à jour des couleurs)
      draw_parcelles_site(parcelles_site_data(), map_id = ns("map"), session = session, user_roles = user_roles())
      draw_perimetres_manuels(perimetres_manuelles_data(), map_id = ns("map"), session = session)
      
      # Nécessaire pour forcer le LeafletProxy (re)dessin
      session$sendCustomMessage("invalidate-map", list(id = ns("map"))) 
      
    }, ignoreInit = TRUE)
    
    
    # --- Date de début du responsable : aujourd'hui quand la personne change ---
    # Le formulaire est reconstruit à chaque ouverture de la fiche, et le
    # sélecteur émet alors une valeur qui n'est pas un choix de l'utilisateur.
    # On la reconnaît en la comparant à celle qui vient d'être affichée : sans
    # cela, rouvrir la fiche après avoir changé de personne sans enregistrer
    # réaffichait le bon titulaire, mais avec la date du jour. Un compteur de
    # première exécution ne suffit pas — il ne s'arme qu'une fois par session.
    # Revenir au titulaire d'origine rétablit aussi sa date enregistrée, plutôt
    # que de laisser celle du jour posée par le détour.
    observeEvent(input$site_responsable_id, {
      sel <- input$site_responsable_id
      if (is.null(sel)) return()

      if (identical(sel, resp_rendu())) {
        if (!is.null(resp_date_rendue())) {
          shiny::updateDateInput(session, "site_responsable_date", value = resp_date_rendue())
        }
        return()
      }

      if (nzchar(sel)) {
        shiny::updateDateInput(session, "site_responsable_date", value = Sys.Date())
      }
    }, ignoreInit = FALSE)

    # --- Date de début du bénévole conservateur : aujourd'hui quand la personne change ---
    # Le formulaire est reconstruit à chaque ouverture de la fiche, et le
    # sélecteur émet alors une valeur qui n'est pas un choix de l'utilisateur.
    # On la reconnaît en la comparant à celle qui vient d'être affichée : sans
    # cela, rouvrir la fiche après avoir changé de personne sans enregistrer
    # réaffichait le bon titulaire, mais avec la date du jour. Un compteur de
    # première exécution ne suffit pas — il ne s'arme qu'une fois par session.
    # Revenir au titulaire d'origine rétablit aussi sa date enregistrée, plutôt
    # que de laisser celle du jour posée par le détour.
    observeEvent(input$site_benevole_id, {
      sel <- input$site_benevole_id
      if (is.null(sel)) return()

      if (identical(sel, benev_rendu())) {
        if (!is.null(benev_date_rendue())) {
          shiny::updateDateInput(session, "site_benevole_date", value = benev_date_rendue())
        }
        return()
      }

      if (nzchar(sel)) {
        shiny::updateDateInput(session, "site_benevole_date", value = Sys.Date())
      }
    }, ignoreInit = FALSE)
    return(list(
      reset = reset,
      focus_site = focus_site,
      clear_selection = clear_selection
    ))
    
    
  })
}

