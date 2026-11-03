# mod_acteurs.R

#' Module pour gérer les acteurs fonciers et agricoles
#'
#' @param id Identifiant du module
acteurs_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    # Clic sur les icônes du tableau (👁 consultation, ✏️ édition)
div(class = "flex-container",
        div(class = "sidebar-left-custom",
            titre_page("Acteurs"),
            actionButton(ns("add_acteur"), "➕ Ajouter un acteur", class = "btn-success"),
            hr(),
            ## on enlève le formulaire ici
            # uiOutput(ns("acteur_form")),
            uiOutput(ns("acteurs_helper_text"))
        ),
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h4("🏢 Liste des acteurs fonciers"),
                div(class = "dt-hscroll",
                    DT::DTOutput(ns("table_acteurs"), width = "100%")
                )
            )
        )
    )
  )
}


#' @param con Connexion DBI
#' @param dico_type_acteur data.frame(id, libelle)
#' @param acteurs_existants_rv (optionnel) reactiveVal(data.frame id, acteur_label) pour mettre à jour d’autres modules
acteurs_server <- function(id, con, dico_type_acteur, acteurs_existants_rv = NULL, current_user_rv, user_roles) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    # --- RV internes -----------------------------------------------------------
    act_sel_id <- reactiveVal(NULL)      # id de l’acteur sélectionné
    editing_id <- reactiveVal(NULL)      # id en édition (si utile)
    
    # --- Helpers SQL -----------------------------------------------------------
    query_acteurs <- "
      SELECT
        a.id, a.nom, a.prenom, a.nom_entite, a.adresse, a.type_acteur_id, a.cp, a.commune, a.telephone,
        COALESCE(string_agg(DISTINCT cf.nom, E'\\n'), '') AS contrats
      FROM gestcons.dico_acteurs_fonciers_agricoles a
      LEFT JOIN gestcons.contrats_acteurs_fonciers caf ON caf.acteur_id = a.id
      LEFT JOIN gestcons.contrats_fonciers cf ON caf.contrat_foncier_id = cf.id
      GROUP BY a.id, a.nom, a.prenom, a.nom_entite, a.adresse, a.type_acteur_id, a.cp, a.commune, a.telephone
      ORDER BY a.nom, a.prenom
    "
    
    refresh_acteurs <- function() safe_db_query(con, query_acteurs)

    # --- Droit de gestion ------------------------------------------------------
    # Les acteurs sont gérables par les administrateurs et par tout responsable
    # de site. L'onglet reste visible aux animateurs et conservateurs bénévoles,
    # mais en consultation seule : pas de ➕, pas de ✏️, seulement l'œil.
    .peut_gerer <- function() {
      roles <- user_roles()
      if (isTRUE(roles$global_role == "AD")) return(TRUE)
      sr <- roles$site_roles
      is.data.frame(sr) && nrow(sr) > 0 && any(sr$role == "RS")
    }

    .refus_lecture_seule <- function() {
      showToast("warning", "Lecture seule",
                "La gestion des acteurs est réservée aux responsables de site.")
      invisible(NULL)
    }

    # Le bouton d'ajout vit dans l'UI, qui ne connaît pas les rôles : on le
    # masque ici, une fois les rôles connus.
    observe({
      shinyjs::toggle("add_acteur", condition = .peut_gerer())
    })
    
    # --- Données affichées -----------------------------------------------------
    acteurs <- reactiveVal(refresh_acteurs())
    
    # --- Helper modal pour le formulaire acteur ------------------------------
    show_acteur_modal <- function(title = NULL) {
      showModal(modalDialog(
        title = title %||% "Acteur",
        size = "l",
        easyClose = TRUE,
        footer = NULL,  # les boutons sont dans le formulaire
        uiOutput(ns("acteur_form"))
      ))
    }
    
    # ⬇️ Rafraîchir quand un autre module met à jour le RV partagé
    if (!is.null(acteurs_existants_rv)) {
      observeEvent(acteurs_existants_rv(), ignoreInit = TRUE, {
        message(sprintf("[Acteurs] refresh (trigger externe) — n=%s", NROW(acteurs_existants_rv())))
        acteurs(refresh_acteurs())
      })
    }
    
    
    # Texte d’aide (existant) ---------------------------------------------------
    output$acteurs_helper_text <- renderUI({
      # Si ton app veut un message “standby”, sinon renvoie NULL.
      NULL
    })
    
    # --- DataTable (NE RÉIMPOSE PAS la sélection) ------------------------------
    output$table_acteurs <- DT::renderDT({
      d <- acteurs()
      if (is.null(d) || nrow(d) == 0) {
        d <- data.frame(
          nom = character(0), prenom = character(0), nom_entite = character(0),
          type_acteur = character(0), cp = character(0), commune = character(0)
        )
      } else {
        d <- d %>%
          dplyr::left_join(dico_type_acteur, by = c("type_acteur_id" = "id")) %>%
          dplyr::mutate(type_acteur = libelle) %>%
          dplyr::select(-type_acteur_id, -libelle)
        d <- d[, c("nom", "prenom", "nom_entite", "type_acteur", "cp", "commune")]
      }
      colnames(d) <- c("Nom", "Prénom", "Entité", "Type", "CP", "Commune")

      # Actions explicites en tête de ligne (👁 consultation, ✏️ édition) : le
      # clic sur la ligne ne déclenche plus rien. L'onglet est ouvert aux
      # AD/RS/AN, mais le crayon n'apparaît que pour AD et RS.
      ids <- if (is.null(acteurs()) || nrow(acteurs()) == 0) integer(0) else acteurs()$id
      editable <- .peut_gerer()
      d <- cbind(
        data.frame(
          `👁` = sprintf("<a href='#' class='act-view tc-act' data-input='%s' data-id='%s' title='Voir la fiche'>👁</a>", ns("act_view"), ids),
          `✏️` = if (editable)
            sprintf("<a href='#' class='act-edit tc-act' data-input='%s' data-id='%s' title='Modifier'>✏️</a>", ns("act_edit"), ids)
          else rep("", length(ids)),
          check.names = FALSE, stringsAsFactors = FALSE
        ), d)

      # Les deux colonnes d'icônes portent du HTML ; les six autres sont des
      # champs de formulaire libre et doivent être échappées. Un acteur nommé
      # « Fiona & Floriane » existe déjà en base : le rendu était donc déjà
      # incorrect avant même qu'on parle d'injection.
      d <- echapper_sauf(d, c("👁", "✏️"))

      DT::datatable(
        d,
        escape    = FALSE,
        rownames  = FALSE,
        selection = "none",
        options   = list(
          pageLength = 10,
          dom = DT_DOM_PAGINATION_HAUT,
          columnDefs = list(
            list(targets = c(0, 1), orderable = FALSE, searchable = FALSE,
                 className = "dt-center", width = "24px")
          )
        )
      )
      
    })
    
    # --- Formulaire d'ajout ----------------------------------------------------
    # --- Formulaire d'ajout (dans un modal, en 2 colonnes) --------------------
    observeEvent(input$add_acteur, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      output$acteur_form <- renderUI({
        tagList(
          h5("➕ Nouvel acteur"),
          fluidRow(
            column(
              width = 6,
              textInput(ns("acteur_nom"), "Nom *"),
              textInput(ns("acteur_prenom"), "Prénom"),
              textInput(ns("acteur_nom_entite"), "Nom entité"),
              selectInput(
                ns("acteur_type_id"),
                "Type d'acteur *",
                choices  = setNames(dico_type_acteur$id, dico_type_acteur$libelle),
                selected = dico_type_acteur$id[1]
              )
            ),
            column(
              width = 6,
              textInput(ns("acteur_adresse"), "Adresse"),
              textInput(ns("acteur_cp"), "Code postal"),
              textInput(ns("acteur_commune"), "Commune"),
              textInput(ns("acteur_tel"), "Téléphone")
            )
          ),
          br(),
          div(
            class = "text-right text-end",
            shinyjs::disabled(actionButton(ns("save_acteur"), "💾 Enregistrer", class = "btn-primary"))
          )
        )
      })
      
      show_acteur_modal("Nouvel acteur")
    })

    # Boutons « Enregistrer » désactivés tant que les champs obligatoires (*)
    # ne sont pas remplis (création et édition).
    observe({
      toggle_submit_state(input, "save_acteur",   c("acteur_nom", "acteur_type_id"))
      toggle_submit_state(input, "update_acteur", c("edit_acteur_nom", "edit_acteur_type_id"))
    })


    # --- CREATE ----------------------------------------------------------------
    observeEvent(input$save_acteur, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      req(input$acteur_nom)
      safe_db_execute(con, glue::glue_sql("
        INSERT INTO gestcons.dico_acteurs_fonciers_agricoles
          (nom, prenom, nom_entite, adresse, type_acteur_id, cp, commune, telephone)
        VALUES (
          {input$acteur_nom},
          {input$acteur_prenom},
          {input$acteur_nom_entite},
          {input$acteur_adresse},
          {input$acteur_type_id},
          {input$acteur_cp},
          {input$acteur_commune},
          {input$acteur_tel}
        )
      ", .con = con))
      
      acteurs(refresh_acteurs())
      
      # Mise à jour d’un RV partagé si fourni
      if (!is.null(acteurs_existants_rv)) {
        acteurs_existants_rv(fetch_acteurs_choices(con))
      }
      
      showToast("success", "Acteur ajouté", "✅ Acteur ajouté.")
      log_action(session, current_user_rv, "Création d'un acteur")
      output$acteur_form <- renderUI(NULL)
      removeModal()
    })
    
    # --- Sélection d'une ligne (mémorise l'ID + affiche formulaire) ------------
    # --- Sélection d'une ligne (mémorise l'ID + formulaire d'édition en modal) --
    # Ligne de l'acteur à partir de son id (les icônes portent l'id, plus l'index)
    .act_row <- function(aid) {
      df <- acteurs()
      if (is.null(df) || !nrow(df)) return(NULL)
      r <- df[as.character(df$id) == as.character(aid), , drop = FALSE]
      if (!nrow(r)) NULL else r[1, , drop = FALSE]
    }

    # 👁 Fiche de consultation, avec bascule vers l'édition
    observeEvent(input$act_view, {
      req(input$act_view$id)
      acteur <- .act_row(input$act_view$id)
      if (is.null(acteur)) return(invisible(NULL))
      act_sel_id(acteur$id)
      .l <- function(lbl, val) {
        v <- val[1]
        tags$p(tags$strong(paste0(lbl, " : ")),
               tags$span(if (is.null(v) || is.na(v) || !nzchar(as.character(v))) "—" else as.character(v)))
      }
      type_lib <- dico_type_acteur$libelle[dico_type_acteur$id == acteur$type_acteur_id[1]]
      showModal(modalDialog(
        title = trimws(paste(acteur$prenom[1] %||% "", acteur$nom[1] %||% "")),
        size = "l", easyClose = TRUE,
        footer = if (.peut_gerer())
          actionButton(ns("act_view_edit"), "✏️ Modifier", class = "btn-primary")
        else modalButton("Fermer"),
        fluidRow(
          column(6,
            .l("Nom", acteur$nom), .l("Prénom", acteur$prenom),
            .l("Entité", acteur$nom_entite),
            .l("Type d'acteur", if (length(type_lib)) type_lib else NA)),
          column(6,
            .l("Adresse", acteur$adresse), .l("Code postal", acteur$cp),
            .l("Commune", acteur$commune), .l("Téléphone", acteur$telephone))
        ),
        tags$hr(),
        {
          lst <- trimws(strsplit(acteur$contrats[1] %||% "", "\n", fixed = TRUE)[[1]])
          lst <- lst[nzchar(lst)]
          tagList(
            tags$p(tags$strong("Contrats associés :")),
            if (length(lst)) tags$ul(lapply(lst, tags$li)) else tags$p("—")
          )
        }
      ))
    })

    # Bouton « Modifier » de la fiche -> formulaire d'édition
    observeEvent(input$act_view_edit, {
      aid <- act_sel_id(); req(aid)
      removeModal()
      shinyjs::runjs(sprintf(
        "Shiny.setInputValue('%s', {id: '%s', nonce: Date.now()}, {priority:'event'});",
        session$ns("act_edit"), aid))
    })

    # ✏️ Édition
    observeEvent(input$act_edit, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      req(input$act_edit$id)
      acteur <- .act_row(input$act_edit$id)
      if (!is.null(acteur)) {
        act_sel_id(acteur$id)
        
        output$acteur_form <- renderUI({
          tagList(
            h4("✏️ Modifier l'acteur"),
            fluidRow(
              column(
                width = 6,
                textInput(ns("edit_acteur_nom"), "Nom *", value = acteur$nom),
                textInput(ns("edit_acteur_prenom"), "Prénom", value = acteur$prenom),
                textInput(ns("edit_acteur_nom_entite"), "Nom entité", value = acteur$nom_entite),
                selectInput(
                  ns("edit_acteur_type_id"),
                  "Type d'acteur *",
                  choices  = setNames(dico_type_acteur$id, dico_type_acteur$libelle),
                  selected = acteur$type_acteur_id
                )
              ),
              column(
                width = 6,
                textInput(ns("edit_acteur_adresse"), "Adresse", value = acteur$adresse),
                textInput(ns("edit_acteur_cp"), "Code postal", value = acteur$cp),
                textInput(ns("edit_acteur_commune"), "Commune", value = acteur$commune),
                textInput(ns("edit_acteur_tel"), "Téléphone", value = acteur$telephone)
              )
            ),
            br(),
            div(
              class = "text-right text-end",
              actionButton(ns("update_acteur"), "💾 Mettre à jour", class = "btn-primary"),
              actionButton(ns("delete_acteur"), "🗑 Supprimer", class = "btn-danger")
            )
          )
        })
        
        show_acteur_modal("Modifier l'acteur")
      }
    })
    
    
    # --- UPDATE ----------------------------------------------------------------
    observeEvent(input$update_acteur, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      id_acteur <- act_sel_id()
      req(!is.null(id_acteur))
      
      safe_db_execute(con, glue::glue_sql("
        UPDATE gestcons.dico_acteurs_fonciers_agricoles
        SET nom = {input$edit_acteur_nom},
            prenom = {input$edit_acteur_prenom},
            nom_entite = {input$edit_acteur_nom_entite},
            adresse = {input$edit_acteur_adresse},
            type_acteur_id = {input$edit_acteur_type_id},
            cp = {input$edit_acteur_cp},
            commune = {input$edit_acteur_commune},
            telephone = {input$edit_acteur_tel}
        WHERE id = {id_acteur}
      ", .con = con))
      
      acteurs(refresh_acteurs())
      
      if (!is.null(acteurs_existants_rv)) {
        acteurs_existants_rv(fetch_acteurs_choices(con))
      }
      
      showToast("success", "Acteur modifié", "✅ Acteur modifié.")
      log_action(session, current_user_rv, "Modification d'un acteur")
      output$acteur_form <- renderUI(NULL)
      removeModal()
    })
    
    # --- DELETE ----------------------------------------------------------------
    # La suppression partait au premier clic, sans confirmation, et affichait
    # « Acteur supprimé » même quand la base l'avait refusée.
    #
    # Les quatre liaisons de cet acteur ne se comportent pas pareil, et la
    # confirmation le dit : les contrats sont en NO ACTION — la base REFUSE la
    # suppression tant que l'acteur y figure — tandis que les liaisons d'action
    # sont en CASCADE et partent silencieusement avec lui.
    observeEvent(input$delete_acteur, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      id_acteur <- act_sel_id()
      req(!is.null(id_acteur))

      liens <- safe_db_query(con, glue::glue("
        SELECT
          CONCAT(a.nom, ' ', COALESCE(a.prenom, '')) AS libelle,
          (SELECT count(*) FROM gestcons.contrats_acteurs_fonciers WHERE acteur_id = {id_acteur})
        + (SELECT count(*) FROM gestcons.contrats_agriculteurs     WHERE acteur_id = {id_acteur}) AS n_contrats,
          (SELECT count(*) FROM gestcons.animation_fonciere_acteurs WHERE acteur_id = {id_acteur})
        + (SELECT count(*) FROM gestcons.animation_contrat_agricole_acteurs WHERE acteur_id = {id_acteur}) AS n_actions
          FROM gestcons.dico_acteurs_fonciers_agricoles a WHERE a.id = {id_acteur}
      "))
      req(nrow(liens) > 0)
      n_contrats <- as.integer(liens$n_contrats[1])
      n_actions  <- as.integer(liens$n_actions[1])

      details <- character(0)
      if (n_contrats > 0) {
        details <- c(details, sprintf(
          "Il est rattaché à <strong>%d contrat(s)</strong> : la base refusera la suppression tant qu'il y figure.",
          n_contrats))
      }
      if (n_actions > 0) {
        details <- c(details, sprintf(
          "<strong>%d liaison(s) d'action</strong> seront supprimées avec lui.", n_actions))
      }
      confirm_suppression(
        ns,
        quoi = sprintf("l'acteur <strong>%s</strong>",
                       htmltools::htmlEscape(trimws(liens$libelle[1]))),
        confirm_id = "delete_acteur_confirm",
        details = details
      )
    })

    observeEvent(input$delete_acteur_confirm, {
      if (!.peut_gerer()) return(.refus_lecture_seule())
      id_acteur <- act_sel_id()
      req(!is.null(id_acteur))

      n <- safe_db_execute(con, glue::glue("
        DELETE FROM gestcons.dico_acteurs_fonciers_agricoles
        WHERE id = {id_acteur}
      "))
      if (!isTRUE(as.integer(n) >= 1L)) {
        showToast("error", "Suppression refusée",
                  "La base a refusé la suppression : l'acteur est encore rattaché à un contrat.")
        return(invisible(NULL))
      }

      acteurs(refresh_acteurs())
      
      if (!is.null(acteurs_existants_rv)) {
        acteurs_existants_rv(fetch_acteurs_choices(con))
      }
      
      showToast("warning", "Acteur supprimé", "🗑 Acteur supprimé.")
      log_action(session, current_user_rv, "Suppression d'un acteur")
      output$acteur_form <- renderUI(NULL)
      removeModal()
    })
    
    # --- API de reset (appelée par app.R quand on QUITTE l'onglet) -------------
    reset <- function() {
      # 1) Efface la sélection côté client (clé)
      reset_dt_selection("table_acteurs", session)
      
      # 2) Purge les états internes
      try(act_sel_id(NULL), silent = TRUE)
      try(editing_id(NULL), silent = TRUE)
      
      # 3) Vide le formulaire d’édition/ajout
      output$acteur_form <- renderUI(NULL)
      
      # 4) Si tu utilises un modal, on le ferme
      try(removeModal(), silent = TRUE)
    }
    
    # <-- Très important : exposer l'API au parent
    return(list(reset = reset))
  })
}
