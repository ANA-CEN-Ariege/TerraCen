#' Modules pour la gestion des documents de gestion
#' mod_doc_gestion.R

# -----------------------------
# UI du module
# -----------------------------
doc_gestion_ui <- function(id) {
  ns <- NS(id)
  tagList(
    # Styles des colonnes d'action (œil / crayon)
    tags$head(
      tags$style(HTML(sprintf("
    #%s .dg-edit-col, #%s th.dg-edit-col {
     width: 56px !important; min-width: 56px !important; max-width: 56px !important; text-align: center;
    }
    #%s .dg-act-col, #%s th.dg-act-col {
     width: 24px !important; min-width: 24px !important; max-width: 24px !important;
     text-align: center; padding-left: 2px; padding-right: 2px;
    }
   ", ns("table_docs"), ns("table_docs"), ns("table_docs"), ns("table_docs"))))
    ),
    
    div(class = "flex-container",
        div(class = "sidebar-left-custom",
            titre_page("Docs de gestion"),
            actionButton(ns("new_doc"), "➕ Nouveau document", class = "btn-success"),
            hr(),
            uiOutput(ns("doc_helper_text"))
        ),
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h4("📄 Documents de Gestion"),
                div(class = "dt-hscroll",
                    DT::DTOutput(ns("table_docs"), width = "100%")
                )
            )
        )
    ),
    # L'output qui va recevoir le formulaire de création ou d'édition/lecture
    uiOutput(ns("doc_form_modal_placeholder"))
  )
}

# -----------------------------
# Server du module
# -----------------------------
# Arguments nécessaires (similaires à mod_contrats)
doc_gestion_server <- function(
    id, con, sites_shared, docs_root, current_user_rv, user_roles,
    dico_evaluation, dico_type_doc, dico_methode, dico_statut
) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    # Détermination des IDs pour la condition d'Évaluation ---
    type_doc_evaluation_ids_R <- tryCatch({
      # 🚨 MODIF : Utiliser `dico_type_doc` directement (sans jointure SQL)
      dico_type_doc %>%
        dplyr::filter(tolower(libelle) %in% c("plan de gestion", "plan de gestion multi-sites")) %>%
        dplyr::pull(id) %>%
        as.character()
    }, error = function(e) character(0))
    
    # 🚨 CORRECTION CRITIQUE 🚨 : Utiliser jsonlite pour générer un tableau JS valide
    type_doc_pg_ids_js <- reactiveVal(jsonlite::toJSON(type_doc_evaluation_ids_R, auto_unbox = FALSE))
    
    # Détermination de l'ID du Plan Multi-site (inchangé)
    dico_type_doc_multi_site_id <- tryCatch({
      dico_type_doc %>%
        dplyr::filter(tolower(libelle) == tolower("Plan de gestion multi-sites")) %>%
        dplyr::pull(id) %>%
        as.character() %||% "999999"
    }, error = function(e) "999999")
    
    # --- Utilitaires (Dupliqués de mod_contrats.R / helpers.R) ---
    # Utilisateur applicatif (id dico_utilisateur) pour cree_par/modifie_par.
    # Sys.getenv("USER") renvoyait le compte système du serveur : toutes les
    # écritures étaient attribuées à « shiny », quel que soit l'utilisateur.
    user_to_db <- make_user_to_db(current_user_rv)
    
    # Remplacer les appels à des fonctions externes par leur définition interne si nécessaire
    .is_blank <- function(x) {
      is.null(x) || length(x) == 0 ||
        (is.atomic(x) && length(x) == 1 && (is.na(x) || (is.character(x) && !nzchar(x))))
    }
    
    # Utilitaires "NULL-safe" pour glue_sql ----
    .is_empty_scalar <- function(x) {
      # 🟢 FIX 1: Gestion des vecteurs longs. Si c'est long, ce n'est PAS vide
      # L'erreur de longueur > 1 est souvent levée par cette fonction si x est long.
      if (is.null(x) || length(x) == 0) return(TRUE)
      if (length(x) > 1) {
        # Pour un vecteur de sites, s'il a des éléments, il n'est pas "empty"
        return(FALSE) 
      }
      
      # Si la longueur est 1 (scalaire)
      # Utilisez le test & vectoriel pour plus de sécurité, même si c'est length 1
      return(is.na(x) | (is.character(x) & !nzchar(x)))
    }
    
    val_or_null <- function(x) {
      if (.is_empty_scalar(x)) DBI::SQL("NULL") else DBI::dbQuoteLiteral(con, x)
    }
    
    int_or_null  <- function(x) {
      if (.is_empty_scalar(x)) DBI::SQL("NULL") else as.integer(x)
    }
    
    num_or_null  <- function(x) {
      if (.is_empty_scalar(x)) DBI::SQL("NULL") else as.numeric(x)
    }
    
    date_or_null <- function(x) {
      if (.is_empty_scalar(x)) return(DBI::SQL("NULL"))
      d <- try(as.Date(x), silent = TRUE)
      if (inherits(d, "try-error") || (length(d) == 1 && is.na(d))) DBI::SQL("NULL") else DBI::dbQuoteLiteral(con, d)
    }
    dateInput_value <- function(x) {
      if (is.null(x) || length(x) == 0) return(as.Date(NA))
      x <- x[1]
      if (inherits(x, "Date"))     return(x)
      if (inherits(x, c("POSIXct","POSIXt"))) return(as.Date(x))
      if (is.character(x)) {
        if (!nzchar(x)) return(as.Date(NA))
        d <- suppressWarnings(as.Date(x))
        return(if (is.na(d)) as.Date(NA) else d)
      }
      d <- suppressWarnings(as.Date(x))
      if (is.na(d)) as.Date(NA) else d
    }
    
    # --- Builder de résumé en lecture seule ---
    build_read_only_summary <- function(row) {
      
      # Mapping des statuts/types pour l'affichage
      get_libelle <- function(df, id_val) {
        if (is.null(id_val) || is.na(id_val)) return("—")
        df$libelle[df$id == id_val] %||% "Non spécifié"
      }
      
      type_doc_libelle <- get_libelle(dico_type_doc, row$type_doc_gestion_id)
      methode_libelle <- get_libelle(dico_methode, row$methode_elaboration_doc_gestion_id)
      statut_libelle <- get_libelle(dico_statut, row$statut_id)
      evaluation_libelle <- get_libelle(dico_evaluation, row$evaluation_id)
      
      # Sites liés (la colonne agrégée vient de la requête principale)
      sites_associes <- row$site_libelle %||% "Aucun"
      
      # Formatage des dates
      fmt_date <- function(d) {
        if (is.null(d) || is.na(d)) "—" else format(as.Date(d), "%d/%m/%Y")
      }
      
      tagList(
        tags$h5(tags$strong(row$nom %||% "Document sans titre")),
        tags$hr(),
        fluidRow(
          column(6,
                 tags$p(tags$strong("Type de document : "), tags$span(type_doc_libelle)),
                 tags$p(tags$strong("Sites associés : "), tags$span(sites_associes)),
                 tags$p(tags$strong("Statut : "), tags$span(statut_libelle)),
                 
                 # Lien du document
                 tags$p(tags$strong("URL : "),
                        if (nzchar(row$url_doc_gestion %||% "")) {
                          tags$a(href = row$url_doc_gestion, target = "_blank", row$url_doc_gestion)
                        } else {
                          tags$span("—")
                        }
                 ),
                 # `%||%` ne teste que NULL : un champ vide arrive ici en NA, et
                 # s'affichait « NA » au lieu de sa valeur de repli.
                 tags$p(tags$strong("Surface couverte (m²) : "),
                        tags$span(if (.is_blank(row$surf_m2)) "—" else row$surf_m2)),
                 tags$p(tags$strong("Commentaire :")),
                 tags$blockquote(if (.is_blank(row$commentaire)) "Aucun commentaire." else row$commentaire)
          ),
          column(6,
                 tags$p(tags$strong("Début de validité : "), tags$span(fmt_date(row$date_debut_validite))),
                 tags$p(tags$strong("Fin de validité : "), tags$span(fmt_date(row$date_fin_validite))),
                 tags$p(tags$strong("Date de mise à jour : "), tags$span(fmt_date(row$date_maj))),
                 tags$p(tags$strong("Méthode d'élaboration : "), tags$span(methode_libelle)),
                 tags$p(tags$strong("Évaluation : "), tags$span(evaluation_libelle))
          )
        ),
      )
    }
    
    # Helper pour déterminer si l'utilisateur peut éditer
    .user_can_edit <- function() {
      roles <- user_roles()  # 🎭 lecture réactive (suit l'impersonation)
      is_admin <- roles$global_role == "AD"
      has_rs_role <- any(roles$site_roles$role == "RS") # Vérifie si RS sur n'importe quel site

      # Pour les Documents de Gestion, nous utiliserons AD ou RS comme permission d'édition.
      return(is_admin || has_rs_role)
    }
    # Helper pour déterminer si un RS a des droits sur les sites d'un document
    .rs_has_site_rights_on_doc <- function(did, user_roles) {
      roles <- user_roles()  # 🎭 lecture réactive (suit l'impersonation)

      # ... (1. Récupération des ID de sites où l'utilisateur est RS) ...
      user_rs_site_ids <- roles$site_roles %>%
        dplyr::filter(role == "RS") %>%
        dplyr::pull(site_id)
      
      if (length(user_rs_site_ids) == 0) return(FALSE)
      
      # 2. Récupération des ID des sites associés au document
      # Requête SQL utilisant la table de liaison confirmée : gestcons.docs_gestion_sites
      query <- glue::glue("
    SELECT site_id FROM gestcons.docs_gestion_sites WHERE doc_gestion_id = {did}
   ")
      
      doc_site_ids <- tryCatch({
        DBI::dbGetQuery(con, query)$site_id
      }, error = function(e) {
        message("Erreur lors de la récupération des sites du document: ", e$message)
        return(integer(0))
      })
      
      # ... (3. Logique de vérification d'intersection) ...
      has_intersection <- any(doc_site_ids %in% user_rs_site_ids)
      
      return(has_intersection)
    }
    
    # --- Requête principale d’affichage ---
    query_docs_data <- function(con) {
      safe_db_query(con, "
    SELECT DISTINCT ON (dg.id)
     dg.id, dg.nom, dg.surf_m2, dg.url_doc_gestion,
     dt.libelle AS type_doc_gestion_libelle,
     dm.libelle AS methode_elaboration_libelle,
     ds.libelle AS statut_libelle,
     de.libelle AS evaluation_libelle,
     dg.date_debut_validite, dg.date_fin_validite, dg.date_maj, dg.commentaire,
    
     -- Agrégation pour les sites multiples
     (SELECT string_agg(s.libelle, ', ' ORDER BY s.libelle)
     FROM gestcons.docs_gestion_sites dgs JOIN gestcons.sites s ON s.id = dgs.site_id
     WHERE dgs.doc_gestion_id = dg.id) AS site_libelle,
    
     dg.type_doc_gestion_id, dg.statut_id, dg.evaluation_id, dg.methode_elaboration_doc_gestion_id
    FROM gestcons.doc_gestion dg
    LEFT JOIN gestcons.dico_type_doc_gestion dt ON dt.id = dg.type_doc_gestion_id
    LEFT JOIN gestcons.dico_methode_elaboration_doc_gestion dm ON dm.id = dg.methode_elaboration_doc_gestion_id
    LEFT JOIN gestcons.dico_statut_doc_gestion ds ON ds.id = dg.statut_id
    LEFT JOIN gestcons.dico_doc_gestion_evaluation de ON de.id = dg.evaluation_id
   
    ORDER BY dg.id, dg.nom NULLS LAST
   ")
    }
    
    # --- Réactifs de base ---
    # Chargement PARESSEUX (comme les contrats) : un reactive() n'est calculé
    # qu'à sa première lecture, donc au premier rendu du tableau — lui-même
    # suspendu tant que l'onglet n'est pas affiché. Surtout PAS un reactiveVal
    # écrit depuis le renderDT : écrire un réactif pendant un rendu invalide ce
    # rendu et désynchronise la machine à états du client.
    docs_reload_nonce <- reactiveVal(0L)
    docs <- reactive({
      docs_reload_nonce()
      query_docs_data(con)
    })
    form_mode <- reactiveVal("none")
    editing_id <- reactiveVal(NULL)
    
    # Choices
    eval_choices <- reactive({ setNames(dico_evaluation$id, dico_evaluation$libelle) })
    type_choices <- reactive({ setNames(dico_type_doc$id, dico_type_doc$libelle) })
    methode_choices <- reactive({ setNames(dico_methode$id, dico_methode$libelle) })
    # Le dictionnaire des DOCUMENTS, pas celui des contrats : lui seul est la
    # cible de la clé étrangère. Le menu proposait des statuts contractuels
    # (Résilié, Suspendu, Terminé) absents de la cible — donc impossibles à
    # enregistrer — et inversait le sens des deux autres.
    statut_choices <- reactive({ setNames(dico_statut$id, dico_statut$libelle) })
    sites_choices <- reactive({
      df <- sites_shared() %||% data.frame(id=integer(0), libelle=character(0))
      # 🟢 CORRECTION : Utiliser le libellé comme nom affiché et l'ID comme valeur retournée (standard Shiny)
      setNames(df$id, df$libelle) # <-- CORRECTION DE LA LOGIQUE
    })
    validation_cs_choices <- c("NON" = 0, "OUI" = 1)
    
    # ---------- Tableau (DT::renderDT) ----------
    output$table_docs <- DT::renderDT({
      d <- try(docs(), silent = TRUE)
      if (!is.data.frame(d) || nrow(d) == 0) {
        return(DT::datatable(
          data.frame(Nom = character(0), Site = character(0)),
          options = list(dom = "t", language = list(emptyTable = "Aucun document de gestion trouvé."))
        ))
      }
      
      # 🚨 CORRECTION DÉFINITIVE DE LA TYPO 🚨
      d <- as.data.frame(d, stringsAsFactors = FALSE)
      
      # Formatage des dates
      fmt_date_col <- function(v) {
        d <- suppressWarnings(as.Date(v))
        ifelse(is.na(d), "", format(d, "%d/%m/%Y"))
      }
      
      # Construction du DF d'affichage
      d_display <- d %>%
        dplyr::mutate(
          Debut = fmt_date_col(date_debut_validite),
          Fin = fmt_date_col(date_fin_validite),
          URL_LINK = ifelse(
            !is.na(url_doc_gestion) & nzchar(url_doc_gestion),
            sprintf('<a href="%s" target="_blank">🔗 ouvrir</a>', url_doc_gestion),
            ""
          )
        ) %>%
        dplyr::select(
          Nom = nom,
          Site = site_libelle,      
          Type = type_doc_gestion_libelle,
          Statut = statut_libelle,
          Évaluation = evaluation_libelle,
          `URL` = URL_LINK,
          id = id             # masquée via columnDefs
        )

      # Déterminer si l'utilisateur peut éditer
      is_editable <- .user_can_edit()

      # Colonnes d'action en tête de ligne : œil (fiche complète) puis crayon
      # (édition, réservé aux éditeurs). Les dates de validité sont retirées du
      # tableau : la fiche 👁 et le formulaire les affichent.
      d_display <- cbind(
        data.frame(
          `👁` = sprintf("<a href='#' class='dg-view tc-act' data-input='%s' data-id='%s' title='Voir la fiche complète'>👁</a>", ns("dg_view"), d$id),
          `✏️` = if (isTRUE(is_editable))
            sprintf("<a href='#' class='dg-edit tc-act' data-input='%s' data-id='%s' title='Modifier ce document'>✏️</a>", ns("dg_edit"), d$id)
          else "",
          check.names = FALSE, stringsAsFactors = FALSE
        ),
        d_display
      )

      # Indices des colonnes
      view_idx <- which(names(d_display) == "👁") - 1L
      edit_idx <- which(names(d_display) == "✏️") - 1L
      url_idx  <- which(names(d_display) == "URL") - 1L
      id_idx   <- which(names(d_display) == "id") - 1L

      # Seules les icônes et le lien portent du HTML ; Nom, Site, Type, Statut et
      # Évaluation sont du texte saisi. Un document s'appelle déjà
      # « … Le Pla & Mijanès ».
      d_display <- echapper_sauf(d_display, c("👁", "✏️", "URL", "id"))

      DT::datatable(
        d_display,
        escape = FALSE,
        rownames = FALSE,
        # Plus de sélection de ligne : l'action passe par les icônes explicites
        selection = "none",
        options = list(
          pageLength = 10,
          dom = DT_DOM_PAGINATION_HAUT,
          columnDefs = list(
            list(targets = id_idx, visible = FALSE),
            list(className = "dg-act-col", targets = c(view_idx, edit_idx),
                 orderable = FALSE, searchable = FALSE),
            list(className = "dg-edit-col", targets = url_idx, orderable = FALSE, searchable = FALSE)
          )
        )
      )
    })
    
    # --- Builders de formulaires ---
    build_create_form <- function() {
      
      # Récupération des IDs pour la condition
      multi_site_id  <- dico_type_doc_multi_site_id
      pg_ids_for_eval_js <- type_doc_pg_ids_js()
      
      tagList(
        h5("➕ Créer un document de gestion"),
        
        fluidRow(
          # 🔹 Colonne gauche
          column(
            6,
            
            # 1. Type de document
            selectInput(
              ns("create_dg_type_doc_id"),
              "Type de document *",
              choices = type_choices(),
              selected = NULL
            ),
            
            # 2. Sites associés (simple ou multiple suivant le type)
            tags$label("Sites associés (rattachement) *"),
            
            # Multi-sites
            conditionalPanel(
              condition = sprintf("input['%s'] == '%s'", ns("create_dg_type_doc_id"), multi_site_id),
              selectizeInput(
                ns("create_dg_site_ids_multi"),
                label = NULL,
                choices = sites_choices(),
                selected = NULL,
                multiple = TRUE,
                options = list(placeholder = "Sélectionnez un ou plusieurs sites")
              )
            ),
            
            # Site unique
            conditionalPanel(
              condition = sprintf("input['%s'] != '%s'", ns("create_dg_type_doc_id"), multi_site_id),
              selectInput(
                ns("create_dg_site_ids_single"),
                label = NULL,
                choices = c("— Sélectionner un site —" = "", sites_choices()),
                selected = NULL,
                multiple = FALSE
              )
            ),
            
            # Nom + Fichier
            textInput(ns("create_dg_nom"), "Nom du document *"),
            
            fileInput(
              ns("create_dg_file"),
              "Document à charger (PDF, DOCX, ZIP, etc.) *",
              accept = c(
                ".pdf",".doc",".docx",".xls",".xlsx",
                ".png",".jpg",".jpeg",".tif",".tiff",
                ".odt",".ods",".txt",".csv",".zip"
              )
            ),
            
            # Méthode d'élaboration
            selectInput(
              ns("create_dg_methode_id"),
              "Méthode d'élaboration *",
              choices = methode_choices()
            ),
            
            # Surface
            numericInput(
              ns("create_dg_surf_m2"),
              "Surface couverte (m²)",
              value = NA,
              min = 0,
              step = 1
            )
          ),
          
          # 🔹 Colonne droite
          column(
            6,
            
            # Statut
            selectInput(
              ns("create_dg_statut_id"),
              "Statut *",
              choices = statut_choices()
            ),
            
            # Bloc Évaluation + Validation CS (uniquement pour les types PG)
            conditionalPanel(
              condition = sprintf("(%s).indexOf(input['%s']) > -1", pg_ids_for_eval_js, ns("create_dg_type_doc_id")),
              
              selectInput(
                ns("create_dg_eval_id"),
                "Évaluation *",
                choices = eval_choices()
              ),
              
              selectInput(
                ns("create_dg_valide_cs"),
                "Validation du Conseil Scientifique ?",
                choices = validation_cs_choices, # 0/1
                selected = 0
              ),
              
              conditionalPanel(
                condition = sprintf("input['%s'] == 1", ns("create_dg_valide_cs")), # 1 = OUI
                dateInput(
                  ns("create_dg_date_cs"),
                  "Date de validation"
                )
              )
            ),
            
            # Dates
            dateInput(
              ns("create_dg_date_debut"),
              "Date de début de validité *",
              value = Sys.Date()
            ),
            dateInput(
              ns("create_dg_date_fin"),
              "Date de fin de validité (optionnelle)",
              value = as.Date(NA)
            ),
            dateInput(
              ns("create_dg_date_maj"),
              "Date de mise à jour",
              value = as.Date(NA)
            ),
            
            # 📢 NOUVEL EMPLACEMENT : Commentaire en bas de la 2ème colonne
            textAreaInput(
              ns("create_dg_commentaire"),
              "Commentaire",
              value = "",
              height = "70px"
            )
          )
        ),
        
        # L'ancien Commentaire pleine largeur a été supprimé ici
        
        # 🔹 Boutons en bas
        div(
          shinyjs::disabled(actionButton(ns("create_doc_save"), "✅ Enregistrer", class = "btn-primary")),
        ),
        
        tags$small(em("(*) champs obligatoires"))
      )
    }
    
    # --- Builders de formulaires ---
    build_edit_form <- function(row) {
      is_admin <- .user_can_edit()
      
      # Sites liés (liste des IDs de sites)
      current_sites <- tryCatch({
        safe_db_query(con, glue::glue("
          SELECT site_id FROM gestcons.docs_gestion_sites
          WHERE doc_gestion_id = {row$id}
          ORDER BY date_creation ASC
          "))
      }, error = function(e) data.frame(site_id = NA_integer_))
      linked_site_ids <- current_sites$site_id[!is.na(current_sites$site_id)]
      
      # Infos validation CS
      validation_cs_info <- tryCatch({
        safe_db_query(con, glue::glue("
          SELECT valide_cs, date_cs
          FROM gestcons.validation_cs
          WHERE doc_gestion_id = {row$id}
          "))
      }, error = function(e) data.frame(valide_cs = NA, date_cs = as.Date(NA)))
      
      valide_cs_val <- validation_cs_info$valide_cs[1] %||% 0
      date_cs_val <- validation_cs_info$date_cs[1] %||% as.Date(NA)
      
      # Type de doc / PG ?
      doc_type_id <- as.character(row$type_doc_gestion_id)
      is_pg <- doc_type_id %in% type_doc_evaluation_ids_R
      
      # Libellé type
      current_type_doc_libelle <- dico_type_doc$libelle[dico_type_doc$id == row$type_doc_gestion_id] %||% "Non spécifié"
      
      # Libellés des sites via sites_shared()
      df_sites <- sites_shared() %||% data.frame(id = integer(0), libelle = character(0))
      sites_libelles_clean <- df_sites$libelle[df_sites$id %in% linked_site_ids]
      sites_display_text <- if (length(sites_libelles_clean) == 0) "—" else paste(sites_libelles_clean, collapse = ", ")
      
      # 💡 NOUVEAU: Récupération de l'URL d'évaluation existante
      current_eval_doc <- tryCatch({
        safe_db_query(con, glue::glue_sql("SELECT url_doc_evaluation FROM gestcons.doc_evaluation_doc_gestion WHERE doc_gestion_id = {row$id} LIMIT 1", .con = con))
      }, error = function(e) data.frame(url_doc_evaluation = NA_character_))
      eval_url_val <- current_eval_doc$url_doc_evaluation[1] %||% ""
      debug_print(paste("eval_url_val = ", eval_url_val))
      # CORRECTION: Teste si la valeur n'est pas NA ET si elle est non vide
      is_eval_uploaded <- !is.na(eval_url_val) && nzchar(eval_url_val)
      debug_print(paste("is_eval_uploaded = ", is_eval_uploaded))
      
      tagList(
        h4(sprintf("✏️ Modifier « %s »", row$nom %||% paste("Document", row$id))),
        
        # Info type + sites au-dessus des colonnes
        tags$p(
          class = "text-muted",
          tags$strong("Type de document : "),
          tags$span(current_type_doc_libelle, style = "font-weight: 600;")
        ),
        
        shinyjs::hidden(
          numericInput(ns("edit_dg_type_doc_id"), NULL, value = row$type_doc_gestion_id)
        ),
        
        tags$p(
          class = "text-muted",
          tags$strong("Sites associés : "),
          tags$span(sites_display_text, style = "font-weight: 600;")
        ),
        
        shinyjs::hidden(
          textInput(
            ns("edit_dg_site_ids"),
            label = NULL,
            value = paste(linked_site_ids, collapse = ",")
          )
        ),
        
        hr(),
        
        fluidRow(
          # 🔹 Colonne gauche (Commentaire remonté ici)
          column(
            6,
            
            textInput(
              ns("edit_dg_nom"),
              "Nom du document *",
              value = row$nom %||% ""
            ),
            
            # Affichage du lien actuel (lecture seule)
            tags$p(
              class = "text-muted",
              tags$strong("URL actuelle : "),
              if (nzchar(row$url_doc_gestion %||% "")) {
                tags$a(
                  href = row$url_doc_gestion,
                  target = "_blank",
                  row$url_doc_gestion
                )
              } else {
                tags$span("—")
              }
            ),
            
            selectInput(
              ns("edit_dg_methode_id"),
              "Méthode d'élaboration *",
              choices = methode_choices(),
              selected = row$methode_elaboration_doc_gestion_id %||% ""
            ),
            
            numericInput(
              ns("edit_dg_surf_m2"),
              "Surface couverte (m²)",
              value = if (!is.na(row$surf_m2)) row$surf_m2 else NA,
              min = 0,
              step = 1
            ),
            
            # 📢 NOUVEAU EMPLACEMENT : Commentaire en bas de la 1ère colonne
            # Un commentaire absent arrive en NA, que `%||%` laisse passer : la
            # zone affichait « NA », et l'enregistrement, qui compare chaque
            # champ à la base (NA ≠ "NA"), l'écrivait.
            textAreaInput(
              ns("edit_dg_commentaire"),
              "Commentaire",
              value = if (.is_blank(row$commentaire)) "" else row$commentaire,
              height = "70px"
            ),
            
            selectInput(
              ns("edit_dg_statut_id"),
              "Statut *",
              choices = statut_choices(),
              selected = row$statut_id %||% ""
            )
            
          ),
          
          # 🔹 Colonne droite
          column(
            6,
            
            # 💡 NOUVEAU: Champ Évaluation
            selectInput(
              ns("edit_dg_eval_id"),
              "Évaluation *",
              choices = eval_choices(),
              selected = row$evaluation_id %||% ""
            ),
            
            # Bloc conditionnel pour l'upload d'un document d'évaluation
            # Condition: S'affiche si l'ID d'évaluation est '1'.
            conditionalPanel(
              condition = sprintf("input['%s'] == '1'", ns("edit_dg_eval_id")),
              tags$div(
                class = "well well-sm tc-encadre",
                tags$strong("Rapport d'évaluation :"),
                
                # Lien du document actuel (si existant)
                if (is_eval_uploaded) {
                  tagList(
                    tags$p(
                      class = "text-muted", style = "margin-bottom: 5px;",
                      tags$strong("Actuel : "),
                      tags$a(
                        href = eval_url_val,
                        target = "_blank",
                        tags$i(class = "fa fa-external-link"),
                        " Ouvrir le document actuel"
                      )
                    )
                    # L'option de suppression du doc d'évaluation a été retirée ici
                  )
                } else if (row$evaluation_id == 1) {
                  tags$p(class = "text-muted", "Aucun document d'évaluation lié actuellement.")
                },
                
                # Champ d'upload pour le nouveau fichier
                fileInput(
                  ns("edit_dg_eval_file"),
                  "Téléverser un nouveau rapport (optionnel)",
                  accept = c(".pdf", ".doc", ".docx", ".zip")
                )
              )
            ),
            
            # Bloc Validation CS si PG (le bloc n'est plus conditionnel au type de doc, mais à l'input de l'utilisateur)
            if (isTRUE(is_pg)) {
              tagList(
                
                selectInput(
                  ns("edit_dg_valide_cs"),
                  "Validation du Conseil Scientifique ?",
                  choices = validation_cs_choices,
                  selected = valide_cs_val
                ),
                
                conditionalPanel(
                  condition = sprintf("input['%s'] == 1", ns("edit_dg_valide_cs")),
                  dateInput(
                    ns("edit_dg_date_cs"),
                    "Date de validation",
                    value = dateInput_value(date_cs_val)
                  )
                )
              )
            } else {
              shinyjs::hidden(
                # Ces inputs cachés sont importants pour que l'absence de valeur ne soit pas NULL mais NA/""
                selectInput(ns("edit_dg_valide_cs"), NULL, choices = validation_cs_choices, selected = 0),
                dateInput(ns("edit_dg_date_cs"), NULL, value = as.Date(NA))
              )
            },
            
            dateInput(
              ns("edit_dg_date_debut"),
              "Date de début de validité *",
              value = dateInput_value(row$date_debut_validite)
            ),
            dateInput(
              ns("edit_dg_date_fin"),
              "Date de fin de validité",
              value = dateInput_value(row$date_fin_validite)
            ),
            dateInput(
              ns("edit_dg_date_maj"),
              "Date de mise à jour",
              value = dateInput_value(row$date_maj)
            )
          )
        ),
        
        # 🔹 L'ancien Commentaire pleine largeur a été supprimé ici
        
        # 🔹 Boutons
        div(
          actionButton(
            ns("update_doc"),
            "💾 Mettre à jour",
            class = "btn-primary",
            style = "margin-bottom: 8px;"
          ),
          # Par DOCUMENT, et non « peut éditer quelque chose » : la variable
          # is_admin ci-dessus vaut .user_can_edit(), vraie pour tout
          # responsable de site, quel que soit le document affiché.
          if (!is.null(row$id) && isTRUE(.dg_can_edit_doc(row$id[1]))) {
            actionButton(
              ns("delete_doc"),
              "🗑 Supprimer",
              class = "btn-danger"
            )
          },
          tags$span(" ", style = "margin-left:6px;"),
        ),
        
        tags$small(em("(*) champs obligatoires"))
      )
    }
    
    # --- Utilitaires de Diffing pour UPDATE (à conserver dans le fichier) ---
    get_changed_fields <- function(did, inputs) {
      current_row <- safe_db_query(con, glue::glue_sql("SELECT * FROM gestcons.doc_gestion WHERE id = {did} LIMIT 1", .con = con))
      if (nrow(current_row) == 0) return(list(sets = NULL, changed = FALSE))
      
      fields_map <- list(
        "nom" = "edit_dg_nom",
        "statut_id" = "edit_dg_statut_id",
        "methode_elaboration_doc_gestion_id" = "edit_dg_methode_id",
        "date_debut_validite" = "edit_dg_date_debut",
        "date_fin_validite" = "edit_dg_date_fin",
        "date_maj" = "edit_dg_date_maj",
        "surf_m2" = "edit_dg_surf_m2",
        "commentaire" = "edit_dg_commentaire",
        "type_doc_gestion_id" = "edit_dg_type_doc_id"
      )
      
      sets <- list()
      
      for (db_col in names(fields_map)) {
        input_id <- fields_map[[db_col]]
        
        new_val <- inputs[[input_id]]
        old_val <- current_row[[db_col]][1]
        
        if (db_col %in% c("date_debut_validite", "date_fin_validite", "date_maj")) {
          old_val_fmt <- dateInput_value(old_val)
          new_val_fmt <- dateInput_value(new_val)
          
          if (!isTRUE(all.equal(old_val_fmt, new_val_fmt, check.attributes = FALSE))) {
            sets[[db_col]] <- date_or_null(new_val_fmt)
          }
        } else if (db_col == "surf_m2") {
          old_val_num <- as.numeric(old_val)
          new_val_num <- as.numeric(new_val)
          if (length(new_val_num) == 0 || is.na(new_val_num)) new_val_num <- NULL
          
          if (!isTRUE(all.equal(old_val_num, new_val_num, check.attributes = FALSE))) {
            sets[[db_col]] <- val_or_null(new_val_num)
          }
        } else {
          new_val_char <- as.character(new_val)
          old_val_char <- as.character(old_val)
          
          if (!isTRUE(all.equal(old_val_char, new_val_char, check.attributes = FALSE))) {
            sets[[db_col]] <- val_or_null(new_val_char)
          }
        }
      }
      
      return(list(sets = sets, changed = length(sets) > 0, old_row = current_row))
    }
    # --- Fin Utilitaires de Diffing ---
    
    # --- Affichage dynamique du formulaire (CORRIGÉ) ---
    output$doc_form_modal_placeholder <- renderUI({
      # Ce placeholder est nécessaire pour éviter que showModal n'échoue
      # Cependant, le contenu du modal est chargé par showModal et uiOutput(ns("doc_form"))
      NULL
    })
    
    output$doc_form <- renderUI({
      mode <- form_mode()
      did <- editing_id()
      
      # 1. 🛑 CORRECTION: Sortir si did est NULL, SAUF si on est en mode "create"
      if (mode != "create" && is.null(did)) {
        shiny::validate(shiny::need(FALSE, "Document introuvable ou mode non défini."))
        return(NULL) # Retourne NULL si did est NULL et qu'on n'est pas en création
      }
      
      if (mode == "create") {
        # Si c'est le mode création, on retourne le formulaire directement.
        return(build_create_form())
      }
      
      # 2. Si on est ici, did ne doit PAS être NULL (car mode est 'edit' ou 'readonly')
      # On récupère les données si on est en mode 'edit' ou 'readonly'
      req(did) # Sécurité additionnelle
      
      # Récupération de la ligne complète (nécessaire pour le résumé complet)
      row_full <- tryCatch(
        safe_db_query(con, glue::glue("
     SELECT * FROM gestcons.doc_gestion dg
     LEFT JOIN (SELECT doc_gestion_id, string_agg(s.libelle, ', ' ORDER BY s.libelle) as site_libelle
          FROM gestcons.docs_gestion_sites dgs JOIN gestcons.sites s ON s.id = dgs.site_id
          WHERE doc_gestion_id = {did} GROUP BY 1) dgs ON dgs.doc_gestion_id = dg.id
     WHERE dg.id = {did}
     LIMIT 1
    ")),
        error = function(e) data.frame()
      )
      
      shiny::validate(need(!inherits(row_full, "try-error") && nrow(row_full) == 1, "Document introuvable."))
      
      if (mode == "edit") {
        # Si c'est l'édition, on passe la ligne complète à build_edit_form
        return(build_edit_form(row_full))
      }
      
      if (mode == "readonly") {
        return(build_read_only_summary(row_full))
      }
      
      # Fallback
      return(NULL)
    })

    # Boutons « Enregistrer/Mettre à jour » désactivés tant que les champs
    # obligatoires (*) ne sont pas remplis (selon le mode création/édition).
    observe({
      m <- form_mode()
      if (identical(m, "create")) {
        nz <- function(x) { x <- x %||% ""; length(x) >= 1 && any(nzchar(as.character(x))) }
        scal_ok <- all(vapply(
          c("create_dg_nom", "create_dg_type_doc_id", "create_dg_statut_id",
            "create_dg_methode_id", "create_dg_date_debut"),
          function(i) nz(input[[i]]), logical(1)
        ))
        shinyjs::toggleState("create_doc_save",
                             condition = scal_ok && !is.null(input$create_dg_file))
      } else if (identical(m, "edit")) {
        toggle_submit_state(input, "update_doc",
                            c("edit_dg_nom", "edit_dg_statut_id",
                              "edit_dg_methode_id", "edit_dg_date_debut"))
      }
    })


    # --- Observers pour "Nouveau document" et sélection de ligne (avec modal) ---
    observeEvent(input$new_doc, {
      # Mode création
      form_mode("create")
      editing_id(NULL)
      
      showModal(modalDialog(
        title = "Nouveau document",
        size = "l",
        easyClose = TRUE,
        footer = NULL,
        uiOutput(ns("doc_form"))
      ))
    })
    
    # --- Ouverture du formulaire par les icônes de la ligne -------------------
    # (la sélection de ligne ne déclenche plus rien : actions explicites)
    # Droit d'édition sur CE document : administrateur, ou responsable d'au
    # moins un des sites qu'il concerne.
    .dg_can_edit_doc <- function(did) {
      if (!isTRUE(.user_can_edit())) return(FALSE)
      roles <- isolate(user_roles())
      identical(roles$global_role, "AD") ||
        (any(roles$site_roles$role == "RS") &&
           isTRUE(.rs_has_site_rights_on_doc(as.integer(did), user_roles)))
    }

    .dg_open <- function(did, mode) {
      editing_id(NULL)          # force output$doc_form à se recalculer
      editing_id(as.integer(did))
      form_mode(mode)
      showModal(modalDialog(
        title = if (mode == "edit") "Modifier un document" else "Détails du document",
        size  = if (mode == "edit") "l" else "m",
        easyClose = TRUE,
        footer = if (mode == "edit") NULL else tagList(
          # Bascule consultation -> édition, comme dans Contrats. Le bouton
          # n'apparaît que si l'utilisateur peut réellement éditer ce document.
          if (.dg_can_edit_doc(did))
            actionButton(ns("dg_view_edit"), "✏️ Modifier", class = "btn-primary")
        ),
        uiOutput(ns("doc_form"))
      ))
    }

    # 👁 Fiche complète, en lecture seule, ouverte à tout le monde
    observeEvent(input$dg_view, {
      req(input$dg_view$id)
      .dg_open(input$dg_view$id, "readonly")
    })

    # ✏️ Édition : réservée aux administrateurs et aux responsables du site
    # concerné (le crayon n'est de toute façon pas affiché aux non-éditeurs).
    observeEvent(input$dg_edit, {
      req(input$dg_edit$id)
      did <- as.integer(input$dg_edit$id)
      if (!.dg_can_edit_doc(did)) {
        showToast("warning", "Lecture seule",
                  "Vous n'êtes pas responsable d'un site concerné par ce document.")
        .dg_open(did, "readonly")
        return()
      }
      .dg_open(did, "edit")
    })

    # Bouton « Modifier » du pied de la fiche de consultation
    observeEvent(input$dg_view_edit, {
      did <- isolate(editing_id()); req(did)
      removeModal()
      .dg_open(did, "edit")
    })

    
    # ----------------- Logique de Sauvegarde (INSERT) - AVEC UPLOAD -----------------
    observeEvent(input$create_doc_save, {
      {
        debug_print("observeEvent(input$create_doc_save")
        
        # --- MODIFICATION ICI : Validation explicite du NOM ---
        if (is.null(input$create_dg_nom) || trimws(input$create_dg_nom) == "") {
          showToast("error", "Champ manquant", "Le champ Nom est obligatoire")
          return(NULL)
        }
        
        # Vérification du type de doc
        if (.is_empty_scalar(input$create_dg_type_doc_id)) {
          showToast("error", "Champ manquant", "Le type de document est obligatoire")
          return(NULL)
        }
        
        type_doc_val <- input$create_dg_type_doc_id
        multi_site_id <- dico_type_doc_multi_site_id
        
        site_id_saisi <- if (type_doc_val == multi_site_id) {
          input$create_dg_site_ids_multi %||% character(0)
        } else {
          input$create_dg_site_ids_single %||% character(0)
        }
        
        # 🟢 FIX 2: Vérification de l'existence des sites via la longueur du vecteur
        if (length(site_id_saisi) == 0) { 
          showToast("warning", "Sites manquants", "Le document doit être rattaché à au moins un site.")
          return(NULL)
        }
        
        file <- input$create_dg_file
        
        if (is.null(file) || isTRUE(is.na(file$datapath)) || !file.exists(file$datapath)) {
          showToast("error", "Fichier manquant", "Veuillez choisir un document à envoyer.")
          return(NULL) # ❗ On sort SANS fermer le modal
        }

        # Contrôle serveur du type : l'attribut « accept » du fileInput n'est
        # qu'un filtre de boîte de dialogue. Vérifié AVANT toute écriture.
        refus <- tryCatch({ verifier_extension_doc(file$name); NULL },
                          error = function(e) conditionMessage(e))
        if (!is.null(refus)) {
          showToast("error", "Fichier refusé", refus)
          return(NULL)
        }
        
        # 2️⃣ Si on arrive ici, toutes les vérifs sont OK ---------------------------
        shinybusy::show_modal_spinner(
          spin = "circle",
          color = COULEUR_SPINNER,
          text = "💾 Téléversement et enregistrement…"
        )
        on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
        
        site_ids   <- as.integer(site_id_saisi)
        url_doc_gestion <- NULL
        abs_path   <- NULL # Défini pour cleanup en cas d'erreur
        
        tryCatch({
          
          # --- GESTION DU FICHIER ---
          subdir <- "doc_gestion_files"
          dir.create(file.path(docs_root, subdir), recursive = TRUE, showWarnings = FALSE)
          
          original_name <- basename(file$name)
          safe_name  <- gsub("[^A-Za-z0-9._-]", "_", original_name)
          
          rel_path <- file.path(
            subdir,
            paste0(format(Sys.time(), "%Y%m%d-%H%M%S-"), safe_name)
          )
          abs_path <- file.path(docs_root, rel_path)
          
          ok <- tryCatch(
            file.copy(file$datapath, abs_path, overwrite = TRUE),
            error = function(e) FALSE
          )
          if (!isTRUE(ok) || !file.exists(abs_path)) {
            stop("Impossible de copier le fichier sur le serveur.")
          }
          
          # URL enregistrée en DB (relative au point de montage Shiny : /docs/{rel_path})
          url_doc_gestion <- file.path("docs", rel_path)
          
          # 1. On récupère l'ID de l'évaluation depuis l'input
          eval_id_val <- input$create_dg_eval_id
          
          # 2. Pour la création, on ne gère pas encore le fichier d'évaluation (pas d'input file dédié en création)
          # On définit ces variables pour éviter que le code copié-collé plus bas ne plante
          is_eval_doc_changed <- FALSE 
          url_doc_evaluation  <- DBI::SQL("NULL")
          
          # --- INSERTION DB ---
          new_id <- NULL
          
          # poolWithTransaction annule la transaction dès qu'une erreur remonte.
          # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
          # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
          tx_ok <- tryCatch({
            pool::poolWithTransaction(con, function(conn) {
            
              # 1. Insertion du document principal
              # Note : pour glue_sql, l'objet de connexion sert au quoting. 
              # On peut utiliser 'conn' ou 'con', mais pour l'exécution (safe_db_insert), IL FAUT 'conn'.
              q_ins <- glue::glue_sql("
                INSERT INTO gestcons.doc_gestion
                (nom, type_doc_gestion_id, methode_elaboration_doc_gestion_id, statut_id, 
                 evaluation_id, date_debut_validite, date_fin_validite,
                 url_doc_gestion, surf_m2, commentaire,
                 cree_par, date_creation, modifie_par, date_modification)
                VALUES (
                  {val_or_null(input$create_dg_nom)},
                  {int_or_null(input$create_dg_type_doc_id)},
                  {int_or_null(input$create_dg_methode_id)},
                  {int_or_null(input$create_dg_statut_id)},
                  {int_or_null(eval_id_val)},
                  {date_or_null(input$create_dg_date_debut)},
                  {date_or_null(input$create_dg_date_fin)},
                  {val_or_null(url_doc_gestion)},
                  {num_or_null(input$create_dg_surf_m2)},
                  NULL,
                  {DBI::dbQuoteLiteral(conn, user_to_db())}, NOW(),
                  {DBI::dbQuoteLiteral(conn, user_to_db())}, NOW()
                )
                RETURNING id
          ", .con = conn)
            
              # IMPORTANT : On utilise 'conn' (la transaction) pour l'exécution
              new_id <<- safe_db_insert(conn, q_ins)
            
              if (is.null(new_id)) stop("L'insertion du document a échoué (ID nul).")
            
              # 2. Insertion des liaisons Sites (table gestcons.docs_gestion_sites)
              site_ids <- c()
              # Logique pour récupérer les IDs (inchangée)
              if (input$create_dg_type_doc_id == dico_type_doc_multi_site_id) {
                site_ids <- as.integer(input$create_dg_site_ids_multi)
              } else {
                if (nzchar(input$create_dg_site_ids_single)) {
                  site_ids <- as.integer(input$create_dg_site_ids_single)
                }
              }
              site_ids <- site_ids[!is.na(site_ids)]
            
              if (length(site_ids) > 0) {
                # Construction des values (id_doc, id_site, user, now)
                # On utilise dbQuoteLiteral avec conn
                u_lit <- DBI::dbQuoteLiteral(conn, user_to_db())
                values <- paste0(
                  sprintf("(%d, %d, %s, NOW())", new_id, site_ids, u_lit),
                  collapse = ","
                )
              
                safe_db_execute(conn, glue::glue("
                  INSERT INTO gestcons.docs_gestion_sites (doc_gestion_id, site_id, cree_par, date_creation)
                  VALUES {DBI::SQL(values)}
                  ON CONFLICT DO NOTHING
                "))
              }
            
              # 3. Mise à jour de la table doc_evaluation_doc_gestion (CONDITIONNEL)
              if (is_eval_doc_changed) {
                if (!identical(url_doc_evaluation, DBI::SQL("NULL"))) {
                  safe_db_execute(conn, glue::glue_sql("
                 INSERT INTO gestcons.doc_evaluation_doc_gestion 
                 (doc_gestion_id, url_doc_evaluation, cree_par, date_creation)
                 VALUES ({new_id}, {url_doc_evaluation}, {DBI::dbQuoteLiteral(conn, user_to_db())}, NOW())
                 ON CONFLICT (doc_gestion_id) DO UPDATE 
                   SET url_doc_evaluation = EXCLUDED.url_doc_evaluation,
                       modifie_par = EXCLUDED.cree_par,
                       date_modification = NOW()
               ", .con = conn))
                }
              }
            
            })
            TRUE
          }, error = function(e) {
            showToast("error", "Création impossible", conditionMessage(e))
            FALSE
          })
          if (!isTRUE(tx_ok)) return(invisible(NULL))
          
          # ✅ Succès final : on met à jour le tableau et on ferme le modal ---------
          showNotification("Document de gestion créé, fichier chargé et sites associés.", type = "message")
          log_action(session, current_user_rv, "Création d'un document de gestion")
          docs_reload_nonce(isolate(docs_reload_nonce()) + 1L) # Rechargement
          editing_id(new_id)
          form_mode("edit")
          
          # 💡 FIX pour le rafraîchissement de la sélection : Désélectionner
          proxy_dt <- DT::dataTableProxy('table_docs')  # <--- ICI
          DT::selectRows(proxy_dt, NULL)
          
          removeModal()
          
        }, error = function(e) {
          # Nettoyage et affichage d'erreur
          showToast("error", "Échec enregistrement/upload", paste("Erreur:", conditionMessage(e)))
          if (!is.null(abs_path) && file.exists(abs_path)) {
            try(unlink(abs_path, force = TRUE), silent = TRUE)
            message("Fichier nettoyé après échec DB/Upload: ", abs_path)
          }
        })
      }
    })
    
    # ----------------- Logique de Sauvegarde (UPDATE) - MULTI-SITE -----------------
    observeEvent(input$update_doc, {
      { # Début du bloc d'encapsulation
        did <- editing_id(); req(did)
        
        # --- 1. Gestion de l'évaluation et du fichier ---
        file_eval <- input$edit_dg_eval_file
        is_new_upload <- !is.null(file_eval) && file.exists(file_eval$datapath)
        if (isTRUE(is_new_upload)) {
          # Même contrôle serveur que pour le document principal.
          refus <- tryCatch({ verifier_extension_doc(file_eval$name); NULL },
                            error = function(e) conditionMessage(e))
          if (!is.null(refus)) {
            showToast("error", "Fichier refusé", refus)
            return(NULL)
          }
        }
        # L'option de suppression par case à cocher ayant été retirée, on gère la suppression par la sélection 'NON'
        
        url_doc_evaluation <- NULL
        abs_path_eval <- NULL
        
        # Récupérer l'URL existante (pour suppression si nécessaire)
        current_eval_info <- safe_db_query(con, glue::glue_sql("SELECT url_doc_evaluation FROM gestcons.doc_evaluation_doc_gestion WHERE doc_gestion_id = {did} LIMIT 1", .con = con))
        existing_eval_url <- current_eval_info$url_doc_evaluation[1] %||% ""
        
        # 1.1 Détermination de l'ID d'évaluation pour la table doc_gestion
        final_evaluation_id <- input$edit_dg_eval_id # Valeur saisie par l'utilisateur
        
        # 🚨 NOUVELLE RÈGLE : Forcer la suppression si l'évaluation est mise à NON (ID 2) et qu'il y a une ancienne URL
        eval_id_saisi <- as.character(input$edit_dg_eval_id)
        is_eval_set_to_non <- eval_id_saisi == "2" # Supposant que l'ID 2 correspond à "NON"
        delete_due_to_non_selection <- is_eval_set_to_non && !is_new_upload && nzchar(existing_eval_url)
        
        # 1.2 Nettoyage de l'ancien fichier sur le disque si remplacement ou passage à NON
        if (is_new_upload || delete_due_to_non_selection) {
          if (nzchar(existing_eval_url)) {
            rel_path_old <- sub("^docs/", "", existing_eval_url)
            abs_path_old <- file.path(docs_root, rel_path_old)
            if (file.exists(abs_path_old)) {
              try(unlink(abs_path_old, force = TRUE), silent = TRUE)
              message("Ancien fichier d'évaluation supprimé (cause: Remplacement ou Évaluation=NON): ", abs_path_old)
              if (delete_due_to_non_selection) {
                showToast("info", "Document d'évaluation supprimé", "L'évaluation est passée à 'NON', le document d'évaluation a été effacé.")
              }
            }
          }
        }
        
        # 1.3 Détermination de la nouvelle URL de la BDD
        if (is_new_upload) {
          tryCatch({
            subdir <- "doc_evaluation_files"
            dir.create(file.path(docs_root, subdir), recursive = TRUE, showWarnings = FALSE)
            
            original_name <- basename(file_eval$name)
            safe_name <- gsub("[^A-Za-z0-9._-]", "_", original_name)
            
            rel_path <- file.path(
              subdir,
              paste0(format(Sys.time(), "%Y%m%d-%H%M%S-"), safe_name)
            )
            abs_path_eval <- file.path(docs_root, rel_path)
            
            if (!file.copy(file_eval$datapath, abs_path_eval, overwrite = TRUE)) {
              stop("Impossible de copier le nouveau document d'évaluation.")
            }
            url_doc_evaluation <- file.path("docs", rel_path)
          }, error = function(e) {
            showToast("error", "Échec Upload Évaluation", paste("Erreur d'upload du document d'évaluation:", conditionMessage(e)))
            return(NULL)
          })
        } else if (delete_due_to_non_selection) {
          # Si passage à NON sans upload: l'URL doit être NULL
          url_doc_evaluation <- DBI::SQL("NULL")
        } else {
          # Conservation de l'ancienne URL
          url_doc_evaluation <- val_or_null(existing_eval_url)
        }
        # --- Fin Gestion Fichier Évaluation ---
        
        shinybusy::show_modal_spinner(spin = "circle", color = COULEUR_SPINNER, text = "💾 Mise à jour…")
        on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
        
        # Validation des champs requis
        req(!.is_empty_scalar(input$edit_dg_nom))
        req(!.is_empty_scalar(input$edit_dg_type_doc_id))
        
        site_ids_raw_string <- input$edit_dg_site_ids %||% ""
        site_ids_saisis <- if (nzchar(site_ids_raw_string)) {
          trimws(unlist(strsplit(site_ids_raw_string, ",", fixed = TRUE)))
        } else {
          character(0)
        }
        
        if (.is_empty_scalar(site_ids_saisis)) {
          showToast("warning", "Sites manquants", "Le document doit être rattaché à au moins un site.")
          return(NULL)
        }
        site_ids <- as.integer(site_ids_saisis)
        
        # 🚨 DEBUT LOGIQUE DE DIFFING 🚨
        diff <- get_changed_fields(did, input)
        sets <- diff$sets
        
        # Ajout du champ evaluation_id à la liste des mises à jour si modifié
        # final_evaluation_id a déjà la valeur corrigée (input ou 2)
        old_eval_id <- diff$old_row$evaluation_id[1] %||% ""
        new_eval_id <- final_evaluation_id %||% ""
        
        if (as.character(old_eval_id) != as.character(new_eval_id)) {
          sets$evaluation_id <- val_or_null(final_evaluation_id)
        }
        
        is_doc_gestion_changed <- length(sets) > 0

        # Sites actuellement liés, relus dans docs_gestion_sites. La table
        # doc_gestion n'a PAS de colonne site_id : diff$old_row$site_id valait
        # donc toujours NULL, la comparaison était toujours « changé », et les
        # liaisons étaient réécrites (DELETE + INSERT avec date_creation = NOW())
        # à chaque enregistrement — ce qui redate le document dans l'onglet
        # Activité, qui compte les liaisons par mois de création.
        old_site_ids <- tryCatch({
          r <- safe_db_query(con, glue::glue(
            "SELECT site_id FROM gestcons.docs_gestion_sites WHERE doc_gestion_id = {did}"))
          if (is.null(r) || !nrow(r)) integer(0) else as.integer(r$site_id)
        }, error = function(e) integer(0))
        is_sites_changed <- !identical(sort(unique(old_site_ids)),
                                       sort(unique(as.integer(site_ids))))
        
        # is_eval_doc_changed est vrai si nouvel upload, suppression forcée (NON), ou si l'ancienne URL est effacée
        is_eval_doc_changed <- is_new_upload || delete_due_to_non_selection || (identical(url_doc_evaluation, DBI::SQL("NULL")) && nzchar(existing_eval_url))
        
        # Vérifie si AUCUNE MODIFICATION n'a été faite
        if (!is_doc_gestion_changed && !is_sites_changed && !is_eval_doc_changed) {
          showToast("info", "Rien à mettre à jour", "Aucune modification détectée sur les champs ou les documents liés.")
          shinybusy::remove_modal_spinner()
          return(NULL)
        }
        # 🚨 FIN LOGIQUE DE DIFFING 🚨
        
        tryCatch({
          pool::poolWithTransaction(con, function(conn) {
            
            # 1. Mise à jour de la table doc_gestion (CONDITIONNEL)
            if (is_doc_gestion_changed) {
              set_clause <- paste(names(sets), sets, sep = " = ", collapse = ", ")
              
              # Ajout des champs d'audit
              # Note : on utilise 'conn' pour le quoting
              set_clause <- paste0(set_clause, ", modifie_par = ", DBI::dbQuoteLiteral(conn, user_to_db()), ", date_modification = NOW()")
              
              # Note : on utilise 'conn' pour l'exécution
              safe_db_execute(conn, glue::glue("
                UPDATE gestcons.doc_gestion SET
                  {DBI::SQL(set_clause)}
                WHERE id = {did}
              "))
            }
            
            # 2. Mise à jour des liaisons sites (CONDITIONNEL)
            if (is_sites_changed) {
              safe_db_execute(conn, glue::glue("
                DELETE FROM gestcons.docs_gestion_sites WHERE doc_gestion_id = {did}
              "))
              if (length(site_ids) > 0) {
                # Note : on utilise 'conn' pour le quoting
                u_lit <- DBI::dbQuoteLiteral(conn, user_to_db())
                values <- paste0(
                  sprintf("('%d', %d, %s, NOW())", did, site_ids, u_lit), collapse = ","
                )
                safe_db_execute(conn, glue::glue("
                  INSERT INTO gestcons.docs_gestion_sites (doc_gestion_id, site_id, cree_par, date_creation)
                  VALUES {DBI::SQL(values)} ON CONFLICT DO NOTHING
                "))
              }
            }
            
            # 3. Mise à jour de la table doc_evaluation_doc_gestion (CONDITIONNEL)
            if (is_eval_doc_changed) {
              if (!identical(url_doc_evaluation, DBI::SQL("NULL"))) {
                # Cas 3.1 : Update/Insert l'URL
                # On utilise 'conn' partout
                safe_db_execute(conn, glue::glue_sql("
                  INSERT INTO gestcons.doc_evaluation_doc_gestion (
                    doc_gestion_id, url_doc_evaluation, cree_par, date_creation, modifie_par, date_modification
                  ) VALUES (
                    {did}, {url_doc_evaluation}, {user_to_db()}, NOW(), {user_to_db()}, NOW()
                  )
                  ON CONFLICT (doc_gestion_id) DO UPDATE SET
                    url_doc_evaluation = EXCLUDED.url_doc_evaluation,
                    modifie_par = {user_to_db()},
                    date_modification = NOW()
                  ", .con = conn))
              } else {
                # Cas 3.2 : Suppression de l'entrée BDD
                safe_db_execute(conn, glue::glue("
                  DELETE FROM gestcons.doc_evaluation_doc_gestion WHERE doc_gestion_id = {did}
                "))
              }
            }
            
            # 4. Gestion de la Validation CS (inchangé mais avec conn)
            valide_cs_saisi <- as.integer(input$edit_dg_valide_cs %||% 0)
            doc_type_id_upd <- input$edit_dg_type_doc_id
            is_pg <- doc_type_id_upd %in% type_doc_evaluation_ids_R
            
            if (is_pg && valide_cs_saisi == 1) {
              if (.is_empty_scalar(input$edit_dg_date_cs)) {
                # Note: le stop fera un rollback automatique de la transaction pool
                stop("Validation CS incohérente (date manquante).")
              }
            }
            
            if (doc_type_id_upd %in% type_doc_evaluation_ids_R) {
              # Attention ici : date_or_null utilise 'con' par défaut dans sa définition plus haut. 
              # Pour être propre, il faudrait qu'il utilise conn, mais 'con' (pool) pour quoter passera.
              date_cs_val <- if (valide_cs_saisi == 1) date_or_null(input$edit_dg_date_cs) else DBI::SQL("NULL")
              valide_cs_sql <- if (as.integer(valide_cs_saisi) == 1) "TRUE" else "FALSE"
              
              q_upd_val <- glue::glue("
                INSERT INTO gestcons.validation_cs (doc_gestion_id, valide_cs, date_cs, cree_par, date_creation)
                VALUES ({did}, {DBI::SQL(valide_cs_sql)}, {date_cs_val}, {DBI::dbQuoteLiteral(conn, user_to_db())}, NOW())
                ON CONFLICT (doc_gestion_id) DO UPDATE SET
                valide_cs = EXCLUDED.valide_cs,
                date_cs = EXCLUDED.date_cs,
                cree_par = EXCLUDED.cree_par,
                date_creation = NOW()
               ")
              safe_db_execute(conn, q_upd_val)
              
            } else {
              safe_db_execute(conn, glue::glue("
                DELETE FROM gestcons.validation_cs WHERE doc_gestion_id = {did}
               "))
            }
          })
          
          showNotification("Document de gestion mis à jour et sites associés.", type = "message")
          log_action(session, current_user_rv, "Mise à jour d'un document de gestion")
          docs_reload_nonce(isolate(docs_reload_nonce()) + 1L) # Rechargement
          
          # 💡 FIX pour le rafraîchissement : Désélectionner
          proxy_dt <- DT::dataTableProxy('table_docs')  # <--- ICI
          DT::selectRows(proxy_dt, NULL)
          
          removeModal()
          
        }, error = function(e) {
          # Nettoyage et affichage d'erreur (si la transaction a échoué)
          showToast("error", "Échec Mise à Jour/Upload", paste("Erreur:", conditionMessage(e)))
          if (!is.null(abs_path_eval) && file.exists(abs_path_eval)) {
            try(unlink(abs_path_eval, force = TRUE), silent = TRUE)
            message("Fichier d'évaluation nettoyé après échec DB: ", abs_path_eval)
          }
        })
      } # Fin du bloc d'encapsulation
    })
    
    # ----------------- Logique de Suppression - NETTOYAGE FICHIER -----------------
    # La suppression d'un document partait au premier clic, et elle efface aussi
    # les fichiers du serveur : elle demande désormais confirmation, en disant
    # ce qu'elle entraîne.
    observeEvent(input$delete_doc, {
      did <- editing_id(); req(did)
      # Le bouton n'est rendu que si .user_can_edit() — mais celle-ci répond
      # vrai pour TOUT responsable de site, sur N'IMPORTE QUEL document, et un
      # bouton absent de la page n'empêche pas d'envoyer l'input à la main. On
      # rejoue donc ici le contrôle par document, celui-là même qu'utilise le
      # crayon ✏️ (.dg_can_edit_doc).
      if (!.dg_can_edit_doc(did)) {
        showToast("warning", "Lecture seule",
                  "Vous n'êtes pas responsable d'un site concerné par ce document.")
        return(invisible(NULL))
      }

      info <- safe_db_query(con, glue::glue("
        SELECT d.nom,
               (SELECT count(*) FROM gestcons.docs_gestion_sites s
                 WHERE s.doc_gestion_id = {did}) AS n_sites,
               (d.url_doc_gestion IS NOT NULL AND d.url_doc_gestion <> '') AS a_fichier,
               (SELECT count(*) FROM gestcons.doc_evaluation_doc_gestion e
                 WHERE e.doc_gestion_id = {did}
                   AND e.url_doc_evaluation IS NOT NULL
                   AND e.url_doc_evaluation <> '') AS n_eval
          FROM gestcons.doc_gestion d WHERE d.id = {did}
      "))
      req(nrow(info) > 0)

      n_sites   <- as.integer(info$n_sites[1])
      n_fichiers <- as.integer(isTRUE(info$a_fichier[1])) + as.integer(info$n_eval[1])

      details <- character(0)
      if (n_sites > 0) {
        details <- c(details, sprintf(
          "Il est rattaché à <strong>%d site(s)</strong> ; ces rattachements seront supprimés.",
          n_sites))
      }
      if (n_fichiers > 0) {
        details <- c(details, sprintf(
          "<strong>%d fichier(s)</strong> seront effacés du serveur.", n_fichiers))
      }
      confirm_suppression(
        ns,
        quoi = sprintf("le document <strong>%s</strong>",
                       htmltools::htmlEscape(info$nom[1] %||% "")),
        confirm_id = "delete_doc_confirm",
        details = details
      )
    })

    observeEvent(input$delete_doc_confirm, {
      did <- editing_id(); req(did)
      # Rejoué aussi à la confirmation : c'est elle qui efface, et elle a son
      # propre input.
      if (!.dg_can_edit_doc(did)) {
        showToast("warning", "Lecture seule",
                  "Vous n'êtes pas responsable d'un site concerné par ce document.")
        removeModal()
        return(invisible(NULL))
      }
      
      # Récupère l'URL avant suppression (pour nettoyer le disque)
      doc_info <- tryCatch({
        safe_db_query(con, glue::glue_sql("SELECT url_doc_gestion FROM gestcons.doc_gestion WHERE id = {did} LIMIT 1", .con = con))
      }, error = function(e) data.frame())
      
      file_url <- doc_info$url_doc_gestion[1] %||% NA_character_
      
      # Récupère l'URL d'évaluation avant suppression
      doc_eval_info <- tryCatch({
        safe_db_query(con, glue::glue_sql("SELECT url_doc_evaluation FROM gestcons.doc_evaluation_doc_gestion WHERE doc_gestion_id = {did} LIMIT 1", .con = con))
      }, error = function(e) data.frame())
      
      file_eval_url <- doc_eval_info$url_doc_evaluation[1] %||% NA_character_
      
      # Impératif ici : si la transaction échoue, le nettoyage des fichiers qui
      # suit effacerait du disque des documents encore référencés en base.
      tx_ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
        
          # 1. Suppression des liaisons sites
          # NOTE : On utilise 'conn' (la transaction) et pas 'con'
          safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.docs_gestion_sites WHERE doc_gestion_id = {did}
          "))
        
          # 2. Suppression de la validation CS
          safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.validation_cs WHERE doc_gestion_id = {did}
          "))
        
          # 3. Suppression de la ligne doc_evaluation
          safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.doc_evaluation_doc_gestion WHERE doc_gestion_id = {did}
          "))
        
          # 4. Suppression du document principal
          safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.doc_gestion WHERE id = {did}
          "))
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Suppression impossible", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(tx_ok)) return(invisible(NULL))
      
      # 5. Nettoyage du fichier physique après succès DB
      
      # Document principal
      if (!is.na(file_url) && nzchar(file_url)) {
        rel_path <- sub("^docs/", "", file_url)
        abs_path <- file.path(docs_root, rel_path)
        if (file.exists(abs_path)) {
          try(unlink(abs_path, force = TRUE), silent = TRUE)
          message("Fichier de document de gestion principal supprimé: ", abs_path)
        }
      }
      
      # 💡 NOUVEAU: Document d'évaluation
      if (!is.na(file_eval_url) && nzchar(file_eval_url)) {
        rel_path_eval <- sub("^docs/", "", file_eval_url)
        abs_path_eval <- file.path(docs_root, rel_path_eval)
        if (file.exists(abs_path_eval)) {
          try(unlink(abs_path_eval, force = TRUE), silent = TRUE)
          message("Fichier de document d'évaluation supprimé: ", abs_path_eval)
        }
      }
      
      showNotification("Document de gestion supprimé.", type = "warning")
      log_action(session, current_user_rv, "Suppression d'un document de gestion")
      docs_reload_nonce(isolate(docs_reload_nonce()) + 1L) # Rechargement
      form_mode("none")
      editing_id(NULL)
      removeModal()
    })
    
    # --- Texte d’aide quand aucun site n’est sélectionné (inchangé) ---
    output$doc_helper_text <- renderUI({
      # On affiche l'aide si aucun formulaire n'est actif
      if (form_mode() == "none") {
        tags$p(
          class = "text-muted",
          "Ce module permet de gérer les documents de gestion (plans de gestion, DOCOB, etc.) et de les associer aux sites conservatoires concernés."
        )
      } else {
        NULL
      }
    })
    
    return(list(reset = function() {
      form_mode("none")
      editing_id(NULL)
    }))
  })
}