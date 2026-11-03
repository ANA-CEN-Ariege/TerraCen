# mod_utilisateurs.R

#' Module pour gérer les utilisateurs
#'
#' @param id Identifiant du module
utilisateurs_ui <- function(id) {
  ns <- NS(id)
  
  tagList(
    # Clic sur les icônes du tableau (👁 consultation, ✏️ édition)
div(class = "flex-container",
        div(class = "sidebar-left-custom",
            titre_page("Utilisateurs"),
            actionButton(ns("add_user"), "➕ Ajouter un utilisateur", class = "btn-success"),
            hr(),
            uiOutput(ns("utilisateurs_helper_text"))
        ),
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h4("👥 Liste des utilisateurs"),
                div(class = "dt-hscroll",
                    DT::DTOutput(ns("table_utilisateurs"), width = "100%")
                )
            )
        )
    )
  )
}

#' @param con connexion DBI
#' @param dico_utilisateur_rv reactiveVal(data.frame) passé depuis l'app principale
utilisateurs_server <- function(id, con, dico_utilisateur_rv, current_user_rv, user_roles) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    
    # --- Réactif local pour le tableau (nom, prénom, email, id)
    refresh_local_users <- function() {
      
      # Requête pour agréger les rôles par site pour chaque utilisateur
      sql_query <- "
    WITH site_roles AS (
      -- Rôles de Responsable (RS)
      SELECT r.user_id, s.libelle AS site_name, 'RS' AS role_code
      FROM gestcons.responsable_sites r
      JOIN gestcons.sites s ON s.id = r.site_id
      WHERE r.actif = TRUE
      UNION ALL
      -- Rôles d'Animateur (AN) - inclut les Bénévoles
      SELECT a.user_id, s.libelle AS site_name, 'AN' AS role_code
      FROM gestcons.animateur_sites a
      JOIN gestcons.sites s ON s.id = a.site_id
      WHERE a.actif = TRUE
      UNION ALL
      -- Rôles de Bénévole (AN)
      SELECT b.user_id, s.libelle AS site_name, 'AN' AS role_code
      FROM gestcons.conservateur_benevole b
      JOIN gestcons.sites s ON s.id = b.site_id
      WHERE b.actif = TRUE
    ),
    aggregated_roles AS (
      SELECT
        user_id,
        string_agg(
          -- Format: Site (RS/AN) - Note: la duplication RS/AN est possible, 
          -- mais on ne la filtre pas à cette étape pour garder la trace.
          s.site_name || ' (' || s.role_code || ')',
          ', ' ORDER BY s.site_name, s.role_code
        ) AS site_roles_text
      FROM site_roles s
      GROUP BY user_id
    )
    SELECT
      u.id, u.nom, u.prenom, u.email, u.actif, u.administrateur,
      COALESCE(ar.site_roles_text, '—') AS site_roles
    FROM gestcons.dico_utilisateur u
    LEFT JOIN aggregated_roles ar ON ar.user_id = u.id
    ORDER BY u.nom, u.prenom
  "
      safe_db_query(con, sql_query)
    }
    
    utilisateurs <- reactiveVal(refresh_local_users())

    # --- Droit de gestion ------------------------------------------------------
    # La gestion des comptes est réservée aux administrateurs. L'onglet ne leur
    # est déjà montré qu'à eux (app.R, set_tab_visible("tab-users", is_admin)),
    # mais un onglet masqué n'est pas une garde : la règle est rejouée ici, et
    # le crayon ne promet plus que ce qu'il tient.
    .est_admin <- function() isTRUE(user_roles()$global_role == "AD")

    .refus_lecture_seule <- function() {
      showToast("warning", "Lecture seule",
                "La gestion des utilisateurs est réservée aux administrateurs.")
      invisible(NULL)
    }

    observe({
      shinyjs::toggle("add_user", condition = .est_admin())
    })
    
    # --- Helper modal pour le formulaire utilisateur -------------------------
    show_user_modal <- function(title = NULL) {
      showModal(modalDialog(
        title = title %||% "Utilisateur",
        size = "l",
        easyClose = TRUE,
        footer = NULL,  # les boutons sont dans le formulaire
        uiOutput(ns("user_form"))
      ))
    }
    
    observeEvent(utilisateurs(), {
      reset_dt_selection(ns("table_utilisateurs"), session)
    }, ignoreInit = TRUE)
    
    
    show_help_utilisateurs_modal <- function(anim_id, step3 = FALSE) {
      showModal(modalDialog(
        title = "En savoir plus...",
        size = "l", easyClose = TRUE,
        footer = NULL,   # fermeture par la croix de l'en-tête
        fluidPage(
          h5("Ce module vous permet de gérer les utilisateurs gestionnaires de sites conservatoires.")
        )
      ))
    }
    
    # Texte d’aide quand aucun site n’est sélectionné
    output$utilisateurs_helper_text <- renderUI({
      # Aucun site si NULL ou valeur " " (vide contrôlé)
      if (is.null(input$af_site_selector) || identical(input$af_site_selector, " ")) {
        tags$p(
          class = "text-muted",
          "Ce module vous permet de gérer les utilisateurs. ",
          actionLink(ns("utilisateurs_help"), "En savoir plus...")
        )
      } else {
        NULL
      }
    })
    
    # Clic sur "En savoir plus..." → ouvre le modal d'aide
    observeEvent(input$utilisateurs_help, {
      show_help_utilisateurs_modal()
    })
    
    # --- Tableau
    output$table_utilisateurs <- DT::renderDT({
      d <- utilisateurs()
      
      # S'assurer que les colonnes existent
      if (is.null(d) || nrow(d) == 0) {
        d <- data.frame(nom = character(0), prenom = character(0), email = character(0),
                        statut = character(0), site_roles = character(0))
      } else {
        # Statut lisible à partir du booléen actif
        d$statut <- ifelse(d$actif %in% TRUE, "Actif", "Inactif")
        d <- d[, c("nom", "prenom", "email", "statut", "site_roles")]
      }

      colnames(d) <- c("Nom", "Prénom", "Mail", "Statut", "Rôles par Site")

      # Actions explicites en tête de ligne : le clic sur la ligne ne déclenche
      # plus rien. Le crayon n'apparaît que pour un administrateur.
      ids <- if (is.null(utilisateurs()) || nrow(utilisateurs()) == 0) integer(0) else utilisateurs()$id
      editable <- .est_admin()
      d <- cbind(
        data.frame(
          `👁` = sprintf("<a href='#' class='usr-view tc-act' data-input='%s' data-id='%s' title='Voir la fiche'>👁</a>", ns("usr_view"), ids),
          `✏️` = if (editable)
            sprintf("<a href='#' class='usr-edit tc-act' data-input='%s' data-id='%s' title='Modifier'>✏️</a>", ns("usr_edit"), ids)
          else rep("", length(ids)),
          check.names = FALSE, stringsAsFactors = FALSE
        ), d)

      DT::datatable(
        d,
        escape    = FALSE,
        rownames  = FALSE,
        selection = "none",
        options   = list(
          pageLength = 10,
          dom = DT_DOM_PAGINATION_HAUT,
          scrollX    = TRUE, # Ajout du scroll horizontal pour la lisibilité
          columnDefs = list(
            list(targets = c(0, 1), orderable = FALSE, searchable = FALSE,
                 className = "dt-center", width = "24px"),
            list(targets = 2, width = "100px")
          )
        )
      )
      
    })
    
    
      # --- Formulaire d'ajout (modal, 2 colonnes) ------------------------------
      observeEvent(input$add_user, {
        if (!.est_admin()) return(.refus_lecture_seule())
        debug_print(paste0("Ajout d'un utilisateur dans le module ", id))
        output$user_form <- renderUI({
          tagList(
            h5("➕ Nouvel utilisateur"),
            fluidRow(
              column(
                width = 6,
                textInput(ns("new_user_nom"), "Nom *"),
                textInput(ns("new_user_prenom"), "Prénom *"),
                textInput(ns("new_user_email"), "Email *")
              ),
              column(
                width = 6,
                checkboxInput(ns("new_user_admin"), "Administrateur ?", value = FALSE),
                checkboxInput(ns("new_user_actif"), "Compte actif ?", value = TRUE)
              )
            ),
            br(),
            div(
              class = "text-right text-end",
              shinyjs::disabled(actionButton(ns("save_user"), "💾 Enregistrer", class = "btn-primary"))
            )
          )
        })
        show_user_modal("Nouvel utilisateur")
      })

    # Boutons désactivés tant que les champs obligatoires (*) ne sont pas remplis.
    observe({
      toggle_submit_state(input, "save_user",
                          c("new_user_nom", "new_user_prenom", "new_user_email"))
      toggle_submit_state(input, "update_user",
                          c("edit_user_nom", "edit_user_prenom", "edit_user_email"))
    })


    # --- Enregistrer (CREATE)
    observeEvent(input$save_user, {
      if (!.est_admin()) return(.refus_lecture_seule())
      debug_print(paste0("Enregistrement d'un nouvel utilisateur dans le module ", id))
      req(input$new_user_nom, input$new_user_prenom)

      safe_db_execute(con, glue::glue_sql("
        INSERT INTO gestcons.dico_utilisateur (nom, prenom, email, actif, administrateur)
        VALUES (
          {input$new_user_nom},
          {input$new_user_prenom},
          {input$new_user_email},
          {DBI::SQL(sql_bool(input$new_user_actif))},
          {DBI::SQL(sql_bool(input$new_user_admin))}
        )
      ", .con = con))
      
      # Refresh local + reactiveVal global (nom_complet)
      utilisateurs(refresh_local_users())
      dico_utilisateur_rv(safe_db_query(con, "
        SELECT id, CONCAT(nom, ' ', prenom) AS nom_complet
        FROM gestcons.dico_utilisateur
        WHERE actif = TRUE
        ORDER BY nom, prenom
      "))
      
      showToast("success", "Utilisateur ajouté", "✅ L'utilisateur a été ajouté.")
      log_action(session, current_user_rv, "Création d'un utilisateur")
      output$user_form <- renderUI(NULL)
      removeModal()
    })
    
    # --- Formulaire modification / suppression (modal, 2 colonnes) ----------
    # Ligne de l'utilisateur à partir de son id (les icônes portent l'id)
    .usr_row <- function(uid) {
      df <- utilisateurs()
      if (is.null(df) || !nrow(df)) return(NULL)
      r <- df[as.character(df$id) == as.character(uid), , drop = FALSE]
      if (!nrow(r)) NULL else r[1, , drop = FALSE]
    }
    usr_sel_id <- reactiveVal(NULL)

    # 👁 Fiche de consultation, avec bascule vers l'édition
    observeEvent(input$usr_view, {
      req(input$usr_view$id)
      user <- .usr_row(input$usr_view$id)
      if (is.null(user)) return(invisible(NULL))
      usr_sel_id(user$id)
      .l <- function(lbl, val) {
        v <- val[1]
        tags$p(tags$strong(paste0(lbl, " : ")),
               tags$span(if (is.null(v) || is.na(v) || !nzchar(as.character(v))) "—" else as.character(v)))
      }
      showModal(modalDialog(
        title = trimws(paste(user$prenom[1] %||% "", user$nom[1] %||% "")),
        size = "l", easyClose = TRUE,
        footer = if (.est_admin())
          actionButton(ns("usr_view_edit"), "✏️ Modifier", class = "btn-primary")
        else modalButton("Fermer"),
        fluidRow(
          column(6,
            .l("Nom", user$nom), .l("Prénom", user$prenom), .l("Mail", user$email)),
          column(6,
            .l("Compte", if (isTRUE(user$actif[1])) "Actif" else "Inactif"),
            .l("Administrateur", if (isTRUE(user$administrateur[1])) "Oui" else "Non"))
        ),
        tags$hr(),
        .l("Rôles par site", user$site_roles)
      ))
    })

    observeEvent(input$usr_view_edit, {
      uid <- usr_sel_id(); req(uid)
      removeModal()
      shinyjs::runjs(sprintf(
        "Shiny.setInputValue('%s', {id: '%s', nonce: Date.now()}, {priority:'event'});",
        session$ns("usr_edit"), uid))
    })

    # ✏️ Édition
    observeEvent(input$usr_edit, {
      if (!.est_admin()) return(.refus_lecture_seule())
      req(input$usr_edit$id)
      user <- .usr_row(input$usr_edit$id)
      if (!is.null(user)) {
        usr_sel_id(user$id)
        output$user_form <- renderUI({
          tagList(
            h4("✏️ Modifier l'utilisateur"),
            fluidRow(
              column(
                width = 6,
                textInput(ns("edit_user_nom"),    "Nom *",    value = user$nom),
                textInput(ns("edit_user_prenom"), "Prénom *", value = user$prenom),
                textInput(ns("edit_user_email"),  "Email *",  value = user$email)
              ),
              column(
                width = 6,
                checkboxInput(ns("edit_user_admin"), "Administrateur ?", value = user$administrateur),
                checkboxInput(ns("edit_user_actif"), "Compte actif ?",    value = user$actif)
              )
            ),
            br(),
            div(
              class = "text-right text-end",
              actionButton(ns("update_user"), "💾 Mettre à jour", class = "btn-primary"),
              # actionButton(ns("delete_user"), "🗑 Supprimer", class = "btn-danger")
            )
          )
        })
        show_user_modal("Modifier l'utilisateur")
      }
    })
    
    
    
    # --- UPDATE
    observeEvent(input$update_user, {
      if (!.est_admin()) return(.refus_lecture_seule())
      debug_print(paste0("Mise à jour d'un utilisateur dans le module ", id))
      # L'utilisateur visé vient désormais de l'icône cliquée (plus de sélection
      # de ligne dans le tableau)
      uid <- usr_sel_id()
      req(uid)
      desactivation <- !isTRUE(input$edit_user_actif)   # passage (ou maintien) à inactif

      # poolWithTransaction annule la transaction dès qu'une erreur remonte.
      # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
      # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
      tx_ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          DBI::dbExecute(conn, glue::glue_sql("
            UPDATE gestcons.dico_utilisateur
            SET nom = {input$edit_user_nom},
                prenom = {input$edit_user_prenom},
                email = {input$edit_user_email},
                actif = {DBI::SQL(sql_bool(input$edit_user_actif))},
                administrateur = {DBI::SQL(sql_bool(input$edit_user_admin))}
            WHERE id = {uid}
          ", .con = conn))

          # Si l'utilisateur devient inactif, on CLÔTURE ses rôles actifs (on
          # préserve l'historique : date_fin + actif=FALSE, pas de suppression).
          if (desactivation) {
            DBI::dbExecute(conn, glue::glue_sql("
              UPDATE gestcons.responsable_sites
              SET date_fin = NOW(), actif = FALSE, date_modification = NOW()
              WHERE user_id = {uid} AND actif = TRUE
            ", .con = conn))
            DBI::dbExecute(conn, glue::glue_sql("
              UPDATE gestcons.conservateur_benevole
              SET date_fin = NOW(), actif = FALSE, date_modification = NOW()
              WHERE user_id = {uid} AND actif = TRUE
            ", .con = conn))
            # animateur_sites n'a pas de date_fin : on désactive seulement le rôle.
            DBI::dbExecute(conn, glue::glue_sql("
              UPDATE gestcons.animateur_sites
              SET actif = FALSE, date_modification = NOW()
              WHERE user_id = {uid} AND actif = TRUE
            ", .con = conn))
          }
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Modification impossible", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(tx_ok)) return(invisible(NULL))

      # Refresh local + reactiveVal global
      utilisateurs(refresh_local_users())
      dico_utilisateur_rv(safe_db_query(con, "
        SELECT id, CONCAT(nom, ' ', prenom) AS nom_complet
        FROM gestcons.dico_utilisateur
        WHERE actif = TRUE
        ORDER BY nom, prenom
      "))
      
      showToast("success", "Utilisateur modifié", "✅ Les modifications ont été enregistrées.")
      log_action(session, current_user_rv, "Modification d'un utilisateur")
      output$user_form <- renderUI(NULL)
      removeModal()
    })
    
    # --- DELETE
    observeEvent(input$delete_user, {
      if (!.est_admin()) return(.refus_lecture_seule())
      debug_print(paste0("Suppression d'un utilisateur dans le module ", id))
      # L'utilisateur visé vient désormais de l'icône cliquée (plus de sélection
      # de ligne dans le tableau)
      uid <- usr_sel_id()
      req(uid)
      
      # La transaction est annulée dès qu'une erreur remonte. Sans interception
      # elle romprait la session, et la suite s'exécuterait comme si l'utilisateur
      # avait bien été supprimé.
      tx_ok <- tryCatch({
        delete_utilisateur(con, uid)
        TRUE
      }, error = function(e) {
        showToast("error", "Suppression impossible", conditionMessage(e))
        FALSE
      })
      if (!isTRUE(tx_ok)) return(invisible(NULL))
      
      # Refresh local + reactiveVal global
      utilisateurs(refresh_local_users())
      dico_utilisateur_rv(safe_db_query(con, "
        SELECT id, CONCAT(nom, ' ', prenom) AS nom_complet
        FROM gestcons.dico_utilisateur
        WHERE actif = TRUE
        ORDER BY nom, prenom
      "))
      
      showToast("warning", "Utilisateur supprimé", "🗑 L'utilisateur a été supprimé.")
      log_action(session, current_user_rv, "Suppression d'un utilisateur")
      output$user_form <- renderUI(NULL)
      removeModal()
    })
    
    reset <- function() {
      # 1) Efface la sélection côté client
      reset_dt_selection("table_utilisateurs", session)
      
      # 2) Retire le formulaire (plutôt que vider les inputs)
      output$user_form <- renderUI(NULL)
      
      # 3) Ferme un éventuel modal
      try(removeModal(), silent = TRUE)
    }
    
    
    return(list(reset = reset))
    
  })
}

delete_utilisateur <- function(con, id) {
  pool::poolWithTransaction(con, function(conn) {
    safe_db_execute(conn, log_query(glue::glue_sql("DELETE FROM gestcons.responsable_sites WHERE user_id = {id}", .con = conn)))
    safe_db_execute(conn, log_query(glue::glue_sql("DELETE FROM gestcons.conservateur_benevole WHERE user_id = {id}", .con = conn)))
    safe_db_execute(conn, log_query(glue::glue_sql("DELETE FROM gestcons.dico_utilisateur WHERE id = {id}", .con = conn)))
  })
}
