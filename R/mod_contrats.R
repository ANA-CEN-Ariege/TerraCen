    #' Modules pour la gestion des contrats
    #' mod_contrats.R
    #' -----------------------------
    #' Server du module
    #' -----------------------------
    #' Arguments:
    #' - con: connexion DBI
    #' - dico_type_statut_contrat: data.frame(id, libelle)
    #' - dico_utilisateur_rv: reactiveVal(data.frame id, nom_complet) fourni par l'app
    #' - acteurs_existants_rv: reactiveVal(data.frame id, acteur_label) fourni par l'app
    
    # mod_contrats.R
    
    # Utilitaire: opérateur "or" nul
    `%||%` <- function(a, b) if (is.null(a)) b else a
  
  # -----------------------------
  # UI du module
  # -----------------------------
  contrats_ui <- function(id) {
    ns <- NS(id)
    tagList(
      tags$head(
        tags$style(HTML(sprintf("
        #%s .cf-map-col, #%s th.cf-map-col {
          width: 56px !important; min-width: 56px !important; max-width: 56px !important; text-align: center;
        }
        #%s .cf-act-col, #%s th.cf-act-col {
          width: 24px !important; min-width: 24px !important; max-width: 24px !important;
          text-align: center; padding-left: 2px; padding-right: 2px;
        }
      ", ns("table_contrats"), ns("table_contrats"), ns("table_contrats"), ns("table_contrats"))))
      ),
      
      div(class = "flex-container",
          div(class = "sidebar-left-custom",
              titre_page("Contrats"),
              actionButton(ns("new_contrat"), "➕ Nouveau contrat", class = "btn-success"),
              hr(),
              uiOutput(ns("contrats_helper_text"))
          ),
          div(class = "right-rail",
              div(class = "right-rail-inner",
                  h4("📄 Contrats"),
                  div(class = "dt-hscroll",  # <- active l’ascenseur horizontal
                      DT::DTOutput(ns("table_contrats"), width = "100%")
                  )
              )
          )
      )
    )
  }
  
  # -----------------------------
  # Server du module
  # -----------------------------
  # Arguments:
  # - con: connexion DBI
  # - dico_type_statut_contrat: data.frame(id, libelle) OU un named vector
  # - dico_utilisateur_rv: reactiveVal(data.frame id, nom_complet) (facultatif, pas requis ici)
  # - acteurs_existants_rv: reactiveVal(data.frame id, acteur_label)
  # - dico_type_maitrise: data.frame(id, libelle_mfu2) OU named vector
  contrats_server <- function(
    id, con, dico_type_statut_contrat, dico_utilisateur_rv,
    acteurs_existants_rv, dico_type_maitrise,
    dico_type_pratique_agricole, dico_type_cheptel, dico_type_culture, 
    dico_type_contrat_agricole,
    reload_contrats_choices = function(){},
    reload_contrats_agri_choices = function(){},
    docs_root,
    contrats_update_trigger = NULL, 
    current_user_rv, 
    user_roles
  ) {
    moduleServer(id, function(input, output, session) {
      ns <- session$ns
      
      # Toujours retourner un Date scalaire ou NA (jamais NULL) pour ne PAS pré-remplir
      dateInput_value <- function(x) {
        if (is.null(x) || length(x) == 0) return(as.Date(NA))
        x <- x[1]
        if (inherits(x, "Date"))          return(x)
        if (inherits(x, c("POSIXct","POSIXt"))) return(as.Date(x))
        if (is.character(x)) {
          if (!nzchar(x)) return(as.Date(NA))
          d <- suppressWarnings(as.Date(x))
          return(if (is.na(d)) as.Date(NA) else d)
        }
        d <- suppressWarnings(as.Date(x))
        if (is.na(d)) as.Date(NA) else d
      }
      
      is_nonneg_integer <- function(x) {
        !is.null(x) && !is.na(x) && is.finite(x) && floor(x) == x && x >= 0
      }
      # Utilitaires "NULL-safe" pour glue_sql ----
      .is_empty_scalar <- function(x) {
        is.null(x) || length(x) == 0 ||
          (is.character(x) && !nzchar(x)) ||
          (length(x) == 1 && is.na(x))
      }
      
      val_or_null  <- function(x) {
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
      
      # --- Rupture de contrat : une seule écriture pour les deux types -------
      # Le trio dateInput / conditionalPanel / textAreaInput existait en double
      # (préfixes edit_cf_ et ca_), et les deux copies ne traitaient pas NA de
      # la même façon : la copie agricole utilisait `row$remarque_rupture %||%
      # ""`, or %||% ne teste que is.null. Une remarque NULL en base arrivait
      # donc dans la zone de texte sous la forme littérale « NA », puis
      # repartait telle quelle en base au premier enregistrement. Les contrats
      # agricoles 1 et 17 portent cette chaîne « NA » (constaté le 2026-10-26).
      .txt_ou_vide <- function(x) {
        if (is.null(x) || length(x) == 0 || is.na(x[1])) "" else as.character(x[1])
      }

      .champs_rupture <- function(prefix, row) {
        id_date <- ns(paste0(prefix, "date_rupture"))
        tagList(
          dateInput(id_date, "Date rupture (optionnelle)",
                    value = dateInput_value(row$date_rupture)),
          conditionalPanel(
            condition = sprintf(
              "typeof input['%s'] !== 'undefined' && input['%s'] && input['%s'] !== ''",
              id_date, id_date, id_date),
            textAreaInput(
              ns(paste0(prefix, "remarque_rupture")),
              "Remarque rupture",
              value       = .txt_ou_vide(row$remarque_rupture),
              height      = "70px",
              placeholder = "Contexte, motif, conditions particulières…"
            )
          )
        )
      }

      # Couple (date, remarque) prêt à interpoler. Les deux membres sont des
      # objets DBI::SQL : ils passent tels quels dans glue() comme dans
      # glue_sql(). Sans date de rupture, la remarque est effacée — c'était
      # déjà la règle des deux côtés, écrite deux fois.
      .sql_rupture <- function(prefix) {
        d <- input[[paste0(prefix, "date_rupture")]]
        r <- input[[paste0(prefix, "remarque_rupture")]]
        if (.is_blank(d)) return(list(date = DBI::SQL("NULL"), remarque = DBI::SQL("NULL")))
        list(date     = date_or_null(d),
             remarque = val_or_null(if (.is_blank(r)) NULL else r))
      }

      .user_can_edit_site <- function(site_id) {
        roles <- user_roles()  # 🎭 lecture réactive (suit l'impersonation)
        # L'administrateur passe AVANT le test sur le site : un site inconnu ne
        # doit pas lui fermer la porte (c'est le cas d'un contrat sans parcelle).
        if (isTRUE(roles$global_role == "AD")) return(TRUE)
        if (is.null(site_id) || is.na(site_id)) return(FALSE)
        any(roles$site_roles$site_id == site_id & roles$site_roles$role == "RS")
      }

      # --- Droit d'édition d'un contrat -------------------------------------
      # Un contrat n'a pas de site en propre : le sien se déduit de ses
      # parcelles (colonne site_ids de query_contrats, identifiants séparés par
      # des virgules). Trois cas :
      #   - administrateur                      -> toujours
      #   - contrat rattaché à au moins un site -> RS de l'un de ces sites
      #   - contrat sans aucune parcelle        -> tout RS, car il n'y a aucun
      #     site à protéger et c'est l'état d'un contrat qu'on vient de créer,
      #     avant de lui rattacher des parcelles (94 contrats fonciers et 3
      #     agricoles sont dans cet état au 2026-10-26).
      .contrat_site_ids <- function(site_ids_txt) {
        if (is.null(site_ids_txt) || length(site_ids_txt) == 0) return(integer(0))
        v <- site_ids_txt[1]
        if (is.na(v) || !nzchar(trimws(as.character(v)))) return(integer(0))
        ids <- suppressWarnings(as.integer(trimws(strsplit(as.character(v), ",", fixed = TRUE)[[1]])))
        ids[!is.na(ids)]
      }

      # Même règle, à partir de l'identifiant : relit la table chargée plutôt que
      # de refaire une requête. Sert de garde serveur, car un lien ✏️ absent de
      # la page n'empêche pas d'envoyer l'input à la main.
      .peut_editer_contrat_id <- function(cid, type) {
        d <- try(isolate(contrats()), silent = TRUE)
        if (inherits(d, "try-error") || !is.data.frame(d) || !nrow(d)) return(FALSE)
        k <- which(d$id == cid & d$type_contrat == type)
        if (!length(k)) return(FALSE)
        .peut_editer_contrat(d$site_ids[k[1]])
      }

      # Vectorisée : le tableau compte 259 lignes, les rôles ne sont lus qu'une
      # fois (une lecture réactive par ligne serait inutilement coûteuse).
      .peut_editer_contrats <- function(site_ids_vec) {
        n <- length(site_ids_vec)
        roles <- user_roles()
        if (isTRUE(roles$global_role == "AD")) return(rep(TRUE, n))
        sr <- roles$site_roles
        rs_ids <- if (is.data.frame(sr) && nrow(sr)) sr$site_id[sr$role == "RS"] else integer(0)
        if (length(rs_ids) == 0) return(rep(FALSE, n))
        vapply(seq_len(n), function(i) {
          ids <- .contrat_site_ids(site_ids_vec[i])
          if (length(ids) == 0) TRUE else any(ids %in% rs_ids)
        }, logical(1))
      }

      .peut_editer_contrat <- function(site_ids_txt) {
        isTRUE(.peut_editer_contrats(site_ids_txt)[1])
      }
      
      # ---------- Helpers génériques ----------
      # .is_blank vient de helpers.R (redéfinition locale identique supprimée)
      # Utilisateur applicatif (id dico_utilisateur) pour cree_par/modifie_par.
      # Sys.getenv("USER") renvoyait le compte système du serveur : toutes les
      # écritures étaient attribuées à « shiny », quel que soit l'utilisateur.
      # Même fabrique que Sites/Parcelles/Actions, donc même valeur enregistrée
      # (et l'impersonation est suivie, puisque make_user_to_db lit user_roles).
      user_to_db <- make_user_to_db(current_user_rv)
      
      # Détection dico statut (compat)
      statut_dic <- dico_type_statut_contrat
      
      # --- AJOUT pour les documents ---
      c_docs_contrat_id <- reactiveVal(NULL)
      c_docs_contrat_kind <- reactiveVal(NULL) # "F" ou "A"
      c_docs_reload <- reactiveVal(0)
      c_doc_uploader_nonce <- reactiveVal(0)
      
      # ---------- Helpers DB / schéma ----------
      column_exists <- function(schema_tbl, col) {
        parts <- strsplit(schema_tbl, "\\.")[[1]]
        sch <- if (length(parts) == 2) parts[1] else "public"
        tbl <- if (length(parts) == 2) parts[2] else parts[1]
        sql <- glue::glue("
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = {DBI::dbQuoteLiteral(con, sch)}
          AND table_name   = {DBI::dbQuoteLiteral(con, tbl)}
          AND column_name  = {DBI::dbQuoteLiteral(con, col)}
        LIMIT 1
      ")
        res <- tryCatch(dbGetQuery(con, sql), error = function(e) data.frame())
        nrow(res) > 0
      }
      table_exists <- function(schema_tbl) {
        parts <- strsplit(schema_tbl, "\\.")[[1]]
        sch <- if (length(parts) == 2) parts[1] else "public"
        tbl <- if (length(parts) == 2) parts[2] else parts[1]
        sql <- glue::glue("
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = {DBI::dbQuoteLiteral(con, sch)}
          AND table_name   = {DBI::dbQuoteLiteral(con, tbl)}
        LIMIT 1
      ")
        nrow(safe_db_query(con, sql)) > 0
      }
      
      # Lire les commentaires pour gestcons.sites (une fois)
      comments_sites <- get_table_column_comments(con, "gestcons", "contrats_fonciers")
      
      # Petit helper pour récupérer le commentaire d'une colonne
      get_comment <- function(col) {
        val <- comments_sites[[col]]
        if (is.null(val) || is.na(val) || !nzchar(trimws(val))) "Aucune information disponible." else val
      }
      
      # Présence / structure des tables géo
      gp_has_geom       <- table_exists("gestcons.parcelles") && column_exists("gestcons.parcelles", "geometry")
      gp_has_idparcelle <- table_exists("gestcons.parcelles") && column_exists("gestcons.parcelles", "id_parcelle")
      pp_has_all        <- table_exists("public.parcelles")   && column_exists("public.parcelles","geometry") &&
        column_exists("public.parcelles","id_parcelle")
      
      # ---------- Requête principale d’affichage ----------
      query_contrats <- function() {
        safe_db_query(con, "
        WITH foncier AS (
          SELECT
            'foncier'::text AS type_contrat,
            cf.id,
            cf.nom,
            cf.type_maitrise_id,
            cf.statut_id,
            cf.date_signature,
            cf.date_debut,
            cf.date_fin,
            cf.date_rupture,
            cf.remarque_rupture,
            cf.url,
            cf.remarque,
            string_agg(DISTINCT s.libelle, ', ') AS site,
            /* identifiants bruts : servent au droit d'édition (crayon ✏️), pas à l'affichage */
            string_agg(DISTINCT s.id::text, ',')  AS site_ids,
            COALESCE(df.nb_docs, 0) AS nb_docs, -- AJOUT
            /* champs agri à NULL pour l'union */
            NULL::numeric AS surf_m2,
            NULL::int     AS type_pratique_agricole_id,
            NULL::int     AS type_cheptel_id,
            NULL::int     AS nb_cheptel,
            NULL::int     AS type_culture_id,
            NULL::int     AS type_contrat_id,
            NULL::text    AS type_contrat_agri_libelle
          FROM gestcons.contrats_fonciers cf
          LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.contrat_id = cf.id
          LEFT JOIN gestcons.parcelles p ON cfp.parcelle_id = p.id
          LEFT JOIN gestcons.sites s ON p.site_id = s.id
          LEFT JOIN (SELECT contrat_id, COUNT(*) AS nb_docs FROM gestcons.docs_contrat_foncier GROUP BY contrat_id) df ON df.contrat_id = cf.id -- AJOUT
          GROUP BY
            cf.id, cf.nom, cf.type_maitrise_id, cf.statut_id,
            cf.date_signature, cf.date_debut, cf.date_fin,
            cf.date_rupture, cf.remarque_rupture, cf.remarque, df.nb_docs
        ),
        agricole AS (
          SELECT
            'agricole'::text AS type_contrat,
            ca.id,
            ca.nom,
            NULL::int  AS type_maitrise_id,
            ca.statut_id,
            NULL::date AS date_signature,
            ca.date_debut,
            ca.date_fin,
            ca.date_rupture,
            ca.remarque_rupture,
            ca.url,
            NULL::text AS remarque,
            -- CORRECTION: Utiliser string_agg pour les sites liés via les parcelles agricoles
            string_agg(DISTINCT s.libelle, ', ') AS site, 
            /* identifiants bruts : servent au droit d'édition (crayon ✏️), pas à l'affichage */
            string_agg(DISTINCT s.id::text, ',')  AS site_ids,
            COALESCE(da.nb_docs, 0) AS nb_docs, -- AJOUT
            ca.surf_m2,
            ca.type_pratique_agricole_id,
            ca.type_cheptel_id,
            ca.nb_cheptel,
            ca.type_culture_id,
            ca.type_contrat_id,
            dtca.libelle AS type_contrat_agri_libelle
          FROM gestcons.contrats_agricoles ca
          LEFT JOIN gestcons.dico_type_contrat_agricole dtca
            ON dtca.id = ca.type_contrat_id
          LEFT JOIN (SELECT contrat_id, COUNT(*) AS nb_docs FROM gestcons.docs_contrat_agricole GROUP BY contrat_id) da ON da.contrat_id = ca.id 
          -- JOINTURES NÉCESSAIRES POUR AGGREGATION DE SITE
          LEFT JOIN gestcons.contrats_agricoles_parcelles cap ON cap.contrat_agri_id = ca.id
          LEFT JOIN gestcons.parcelles p ON cap.parcelle_id = p.id
          LEFT JOIN gestcons.sites s ON p.site_id = s.id
          
          GROUP BY -- Ajout du GROUP BY pour l'agrégation
            ca.id, ca.nom, ca.statut_id, ca.date_debut, ca.date_fin, ca.date_rupture,
            ca.remarque_rupture, da.nb_docs, ca.surf_m2, ca.type_pratique_agricole_id,
            ca.type_cheptel_id, ca.nb_cheptel, ca.type_culture_id, ca.type_contrat_id, dtca.libelle
        )
        SELECT * FROM foncier
        UNION ALL
        SELECT * FROM agricole
        ORDER BY nom NULLS LAST, id
      ")
      }
      
      # Pièces jointes : composant commun (helpers.R) paramétré par la table
      .c_doc_table <- function(kind) {
        if (kind == "F") "gestcons.docs_contrat_foncier" else "gestcons.docs_contrat_agricole"
      }

      .c_fetch_docs <- function(id, kind) {
        docs_fetch(con, .c_doc_table(kind), "contrat_id", id)
      }

      .c_doc_add <- function(id, kind, file, type, remarque) {
        docs_add(con, docs_root, .c_doc_table(kind), "contrat_id", id,
                 subdir = sprintf("contrat_%s_%d", kind, id),
                 file = file, type = type, remarque = remarque)
      }

      .c_doc_delete <- function(doc_id, contrat_id, kind, sel_row) {
        df <- .c_fetch_docs(contrat_id, kind)
        docs_delete(con, docs_root, .c_doc_table(kind), doc_id,
                    url = df$url[sel_row], nom_fichier = df$nom_fichier[sel_row])
      }
      
      # --- UI du modal Documents (réutilisation de la logique de 'mod_animations.R') ---
      output$c_doc_uploader <- renderUI({
        c_doc_uploader_nonce()
        fileInput(ns("c_doc_file"), "Sélectionner un fichier", accept = DOCS_FILE_ACCEPT)
      })
      
      output$c_docs_table <- DT::renderDT({
        req(c_docs_contrat_id(), c_docs_contrat_kind())
        c_docs_reload()
        
        docs_datatable(.c_fetch_docs(c_docs_contrat_id(), c_docs_contrat_kind()))
      })
      
      # Section « 📎 Documents » embarquée dans la modale d'édition du contrat
      # (remplace l'ancienne modale dédiée). Pas de bouton d'enregistrement
      # dédié : la PJ chargée est enregistrée par « 💾 Mettre à jour ».
      .c_docs_section <- function() {
        tagList(
          tags$hr(),
          tags$h4("📎 Documents"),
          DT::DTOutput(ns("c_docs_table")),
          shinyjs::disabled(actionButton(ns("c_doc_delete"), "🗑 Supprimer le document sélectionné", class = "btn btn-danger")),
          tags$hr(),
          tags$h5("Joindre un fichier"),
          uiOutput(ns("c_doc_uploader")),
          textInput(ns("c_doc_type"), "Type de document (ex. Convention, Compte-rendu, Photo)", ""),
          textAreaInput(ns("c_doc_remarque"), "Remarque", "", height = "70px"),
          tags$p(class = "text-muted", style = "font-size:.9em;",
                 "La pièce jointe sera enregistrée avec le contrat via « Mettre à jour ».")
        )
      }

      # Enregistre la PJ chargée dans le fileInput, si présente (sinon skip
      # silencieux). Appelée au « Mettre à jour » du contrat. Renvoie TRUE si
      # un fichier a été enregistré.
      .c_upload_pending_doc <- function() {
        if (!isTruthy(c_docs_contrat_id()) || !isTruthy(c_docs_contrat_kind())) return(FALSE)
        file <- input$c_doc_file
        if (is.null(file) || isTRUE(is.na(file$datapath)) || !file.exists(file$datapath)) return(FALSE)
        ok <- tryCatch({
          .c_doc_add(id = c_docs_contrat_id(), kind = c_docs_contrat_kind(),
                     file = file, type = input$c_doc_type, remarque = input$c_doc_remarque)
          TRUE
        }, error = function(e) {
          showToast("error", "Échec upload", paste("Erreur:", conditionMessage(e))); FALSE
        })
        if (!ok) return(FALSE)
        showToast("success", "Document enregistré", "📎 Pièce jointe ajoutée au contrat.")
        log_action(session, current_user_rv,
                   paste0("Contrat ", c_docs_contrat_kind(), " #", c_docs_contrat_id(), " : pièce jointe ajoutée"))
        c_docs_reload(isolate(c_docs_reload()) + 1)
        contrats_reload_nonce(isolate(contrats_reload_nonce()) + 1L)
        c_doc_uploader_nonce(isolate(c_doc_uploader_nonce()) + 1)
        # Pas de ns() : `session` est déjà celle du module, le double préfixe
        # visait un input inexistant et les champs n'étaient pas vidés.
        updateTextInput(session, "c_doc_type", value = "")
        updateTextAreaInput(session, "c_doc_remarque", value = "")
        TRUE
      }

      
      # Supprimer un document : actif seulement si une ligne est sélectionnée
      # (donc jamais actif sur une liste vide).
      observe({
        shinyjs::toggleState("c_doc_delete",
                             condition = length(input$c_docs_table_rows_selected) == 1)
      })

      # --- Supprimer un document (dans la modale du contrat, reste ouverte) ---
      observeEvent(input$c_doc_delete, {
        # Pas de show_modal_spinner : c'est une modale, empilée sur la modale du
        # contrat -> son retrait la refermerait. La suppression est instantanée.
        req(c_docs_contrat_id(), c_docs_contrat_kind())
        sel <- input$c_docs_table_rows_selected
        if (length(sel) != 1) {
          showToast("warning", "Sélection requise", "Sélectionnez une ligne du tableau.")
          return()
        }
        
        df <- .c_fetch_docs(c_docs_contrat_id(), c_docs_contrat_kind())
        if (nrow(df) < sel) return()
        doc_id <- df$id[sel]
        
        tryCatch({
          .c_doc_delete(doc_id, c_docs_contrat_id(), c_docs_contrat_kind(), sel)
          showToast("warning", "Document supprimé", "🗑 Fichier et enregistrement supprimés.")
          log_action(session, current_user_rv,
                     paste0("Contrat ", c_docs_contrat_kind(), " #", c_docs_contrat_id(), " : pièce jointe supprimée"))
          c_docs_reload(isolate(c_docs_reload()) + 1)
          contrats_reload_nonce(isolate(contrats_reload_nonce()) + 1L)
        }, error = function(e) {
          showToast("error", "Échec suppression", paste("Erreur:", conditionMessage(e)))
        })
      })
      
      # OBSERVEUR POUR LE TRIGGER PARTAGÉ
      observeEvent(contrats_update_trigger(), {
        req(contrats_update_trigger() > 0)
        # Recharge les données du tableau principal des contrats
        contrats_reload_nonce(isolate(contrats_reload_nonce()) + 1L)
      }, ignoreInit = TRUE)

      # Canal UNIQUE de rechargement du tableau après une écriture : on bumpe le
      # trigger partagé, dont l'observer ci-dessus se charge de recharger. Les
      # handlers appelaient la requête EN PLUS du bump, donc la grosse UNION
      # partait deux fois par action. Repli sur l'appel direct si le module est
      # monté sans trigger.
      .reload_contrats <- function() {
        if (!is.null(contrats_update_trigger)) {
          contrats_update_trigger(shiny::isolate(contrats_update_trigger()) + 1)
        } else {
          contrats_reload_nonce(isolate(contrats_reload_nonce()) + 1L)
        }
      }

      # --- Réactifs ---
      # Chargement PARESSEUX : cette UNION agrégée est lourde et partait à
      # l'ouverture de CHAQUE session, même pour un utilisateur qui ne visite
      # jamais l'onglet Contrats. Un reactive() n'est calculé qu'à sa première
      # lecture — donc au premier rendu du tableau, lui-même suspendu tant que
      # l'onglet n'est pas affiché.
      # NB : surtout PAS un reactiveVal écrit depuis le renderDT — écrire un
      # réactif pendant un rendu invalide ce rendu en cours et désynchronise la
      # machine à états du client (« unexpected state of: running/idle »).
      contrats_reload_nonce <- reactiveVal(0L)
      contrats <- reactive({
        contrats_reload_nonce()   # dépendance : bumper suffit à recharger
        query_contrats()
      })
      form_mode  <- reactiveVal("none")   # "none" | "create" | "edit"
      editing_id <- reactiveVal(NULL)     # id du contrat en cours d'édition (si mode "edit")
      editing_type <- reactiveVal(NULL)   # "foncier" | "agricole"
      cf_view_target <- reactiveVal(NULL) # contrat affiché dans la fiche (œil)
      cf_current_contrat_id <- reactiveVal(NULL)
      cf_current_kind       <- reactiveVal("F")  # "F" ou "A"
      
      # Réactif pour obtenir l'ID du statut 'Actif'
      statut_actif_id_rv <- reactive({
        # Recherche l'ID correspondant au libellé 'Actif' (insensible à la casse/accents)
        actif_row <- dico_type_statut_contrat %>%
          dplyr::filter(tolower(libelle) %in% c("actif", "actiff")) %>%
          dplyr::select(id) %>%
          dplyr::slice(1)
        
        if (nrow(actif_row) > 0) {
          return(as.character(actif_row$id))
        }
        # Fallback: utiliser le premier ID si 'Actif' n'est pas trouvé (pour ne pas crasher)
        return(as.character(dico_type_statut_contrat$id[1] %||% "NA"))
      })
      
      # ---------- Tableau (mapping dicos + col. carte) ----------
      output$table_contrats <- DT::renderDT({
        d <- try(contrats(), silent = TRUE)
        shiny::validate(
          need(!inherits(d, "try-error"), "Erreur lors du chargement des contrats depuis la base de données.")
        )
        
        # Si d n'est pas un data frame ou s'il est vide, renvoyer une table vide pour éviter l'erreur $
        if (!is.data.frame(d) || nrow(d) == 0) {
          return(DT::datatable(
            data.frame(Nom = character(0), Type = character(0)),
            options = list(dom = "t", language = list(emptyTable = "Aucun contrat trouvé."))
          ))
        }
        
        d <- as.data.frame(d, stringsAsFactors = FALSE)
        
        # 2. Ajout de colonnes nécessaires si absentes (pour éviter les erreurs $ ultérieures)
        # Ceci est crucial car si la base de données retourne 0 lignes, d peut manquer de colonnes
        needed_cols <- c("site", "site_ids", "type_contrat", "id", "nb_docs", "url")
        for (col in needed_cols) {
          if (!col %in% names(d)) d[[col]] <- NA
        }
        
        # Mapping des dicos lisibles
        if ("statut_id" %in% names(d)) {
          dic <- statut_dic
          if (is.atomic(dic) && !is.null(names(dic))) {
            d$statut_id <- unname(dic[as.character(d$statut_id)])
          } else if (is.data.frame(dic) && all(c("id","libelle") %in% names(dic))) {
            d <- dplyr::left_join(d, dic[, c("id","libelle")], by = c("statut_id" = "id")) |>
              dplyr::mutate(statut_id = .data$libelle) |>
              dplyr::select(-libelle)
          }
        }
        # Libellé Type
        if ("type_contrat" %in% names(d)) {
          d$type_contrat <- ifelse(d$type_contrat == "agricole", "Contrat agricole", "Contrat foncier")
        }
        
        if ("type_maitrise_id" %in% names(d)) {
          dic2 <- dico_type_maitrise
          if (is.atomic(dic2) && !is.null(names(dic2))) {
            d$type_maitrise_id <- unname(dic2[as.character(d$type_maitrise_id)])
          } else if (is.data.frame(dic2) && all(c("id","libelle_concat") %in% names(dic2))) {
            d <- dplyr::left_join(d, dic2[, c("id","libelle_concat")],
                                  by = c("type_maitrise_id" = "id")) |>
              dplyr::mutate(type_maitrise_id = .data$libelle_concat) |>
              dplyr::select(-libelle_concat)
          }
        }
        
        # Réorganisation colonnes + URL cliquable
        # --- Colonnes à masquer du tableau
        cols_to_hide <- c(
          "remarque",                # texte remarque (à masquer)
          "surf_m2",                 # surface (à masquer)
          "type_pratique_agricole_id",
          "type_cheptel_id",
          "nb_cheptel",
          "type_culture_id",
          "type_contrat_agri_libelle",  # -> "Type (agri)"
          "type_maitrise_id",           # -> "Type maitrise"
          "date_rupture",
          "date_debut",                 # retirées du tableau (fiche 👁 et
          "date_fin",                   # formulaire d'édition les affichent)
          "url",
          "site_ids"                    # technique : droit d'édition du crayon
        )
        
        # Réorganisation colonnes + URL cliquable (tolérant)
        first <- intersect(c("nom","site"), names(d))
        keep  <- c(
          "type_contrat",
          first,
          setdiff(
            names(d),
            c("id", first, "remarque_rupture", "type_contrat", cols_to_hide)
          ),
          "id" # ✅ ON GARDE L'ID (requis par le JS)
        )
        keep <- intersect(keep, names(d))  # évite 'undefined columns selected'
        d_display <- d[, keep, drop = FALSE]
        
        # Montrer le libellé du type de contrat agricole et masquer l'id brut s'il remonte
        if ("type_contrat_agri_libelle" %in% names(d_display)) {
          names(d_display)[names(d_display) == "type_contrat_agri_libelle"] <- "Type (agri)"
        }
        # Toujours masquer l'id brut du type agri s'il est là
        drop_cols <- intersect(c("type_contrat_id"), names(d_display))
        if (length(drop_cols)) {
          d_display <- d_display[, setdiff(names(d_display), drop_cols), drop = FALSE]
        }
        
        # -- Affichage des dates : jj/mm/aaaa (sans l'heure)
        fmt_date_col <- function(v) {
          d <- suppressWarnings(as.Date(v))    # gère Date, POSIXct et "YYYY-mm-dd HH:MM:SS"
          ifelse(is.na(d), "", format(d, "%d/%m/%Y"))
        }
        
        # Cible explicitement les colonnes dates connues si elles existent
        date_cols <- intersect(c("date_signature", "date_debut", "date_fin", "date_rupture"), names(d_display))
        for (nm in date_cols) d_display[[nm]] <- fmt_date_col(d_display[[nm]])
        
        # (Si tu fais tes renommages AVANT, tu peux aussi cibler par motif)
        # for (nm in names(d_display)) if (grepl("date", nm, ignore.case = TRUE)) d_display[[nm]] <- fmt_date_col(d_display[[nm]])
        
        # Renommages lisibles
        ren <- c(
          type_contrat = "Type",
          site = "Site<br>concerné",
          nom = "Nom",
          date_signature = "Date<br>signature",
          date_debut = "Date<br>début",
          date_fin = "Date<br>fin",
          date_rupture = "Date<br>rupture",
          statut_id = "Statut",
          type_maitrise_id = "Type<br>maîtrise"
        )
        for (k in intersect(names(ren), names(d_display))) {
          names(d_display)[names(d_display) == k] <- ren[[k]]
        }
        
        
        # Colonne carte : n'afficher l'icône que si le champ 'site' n'est pas vide/NULL.
        has_site <- !is.na(d$site) & nzchar(d$site)
        is_foncier <- d$type_contrat == "Contrat foncier"
        
        map_col <- ifelse(
          # Condition d'affichage (si un site est associé)
          has_site,
          
          # Icône avec le préfixe de type de contrat
          ifelse(
            is_foncier,
            sprintf("<a href='#' class='cf-show tc-act' data-input='%s' data-id='F:%s' title='Associer / dissocier des parcelles'>🗺️</a>", ns("cf_show"), d$id),
            sprintf("<a href='#' class='cf-show tc-act' data-input='%s' data-id='A:%s' title='Associer / dissocier des parcelles'>🗺️</a>", ns("cf_show"), d$id)
          ),
          
          # Sinon, laisser la cellule vide
          ""
        )
        d_display$`🗺️` <- map_col
        
        
        # Colonne Pièces jointes : compteur simple (la gestion se fait dans la
        # modale du contrat, plus de lien).
        d_display$`📎` <- sprintf('📎 %s', d$nb_docs)

        # Colonne URL : lien cliquable (nouvel onglet) quand la colonne url du
        # contrat est renseignée. La colonne brute reste masquée (cols_to_hide) ;
        # on n'affiche que l'icône. rel='noopener' : le document ouvert ne peut
        # pas manipuler l'onglet de l'appli.
        url_vals <- trimws(as.character(d$url %||% NA_character_))
        d_display$`🔗` <- ifelse(
          !is.na(url_vals) & nzchar(url_vals),
          sprintf("<a href='%s' target='_blank' rel='noopener' title='Ouvrir le document lié'>🔗</a>",
                  htmltools::htmlEscape(url_vals, attribute = TRUE)),
          ""
        )

        # Colonnes d'action en tête de ligne : crayon (édition) et œil
        # (consultation). Le clic sur la ligne entière ne déclenche plus rien.
        type_key <- ifelse(d$type_contrat == "Contrat agricole", "agricole", "foncier")
        # Le crayon ne s'affiche que sur les contrats que l'utilisateur peut
        # vraiment modifier, comme dans Actions et Docs Gestion : son absence
        # signifie « lecture seule », l'œil reste disponible.
        peut_editer <- .peut_editer_contrats(d$site_ids)
        d_display$`✏️` <- ifelse(
          peut_editer,
          sprintf(
            "<a href='#' class='cf-edit tc-act' data-input='%s' data-id='%s' data-type='%s' title='Modifier ce contrat'>✏️</a>",
            ns("contrat_row_click"), d$id, type_key),
          "")
        d_display$`👁` <- sprintf(
          "<a href='#' class='cf-view tc-act' data-input='%s' data-id='%s' data-type='%s' title='Voir la fiche complète'>👁</a>",
          ns("cf_view"), d$id, type_key)
        
        # Retirer explicitement la colonne “Pièces jointes” si présente
        if ("Pièces jointes" %in% names(d_display)) d_display[["Pièces jointes"]] <- NULL
        if ("nb_docs" %in% names(d_display))         d_display[["nb_docs"]] <- NULL
        
        # On met 'Pièces jointes' à côté de la carte, et on fait le datatable avec escape=FALSE
        # On s'assure que 'id' est bien présent (même s'il sera caché)
        # Crayon et œil en TÊTE de ligne, icônes de fin inchangées
        actions_col <- c("👁", "✏️")
        fin_col     <- c("🗺️", "📎", "🔗", "id")
        d_display <- d_display[, c(actions_col,
                                   setdiff(names(d_display), c(actions_col, fin_col)),
                                   fin_col), drop = FALSE]
        edit_idx <- which(names(d_display) == "✏️") - 1
        view_idx <- which(names(d_display) == "👁") - 1
        map_idx  <- which(names(d_display) == "🗺️") - 1
        docs_idx <- which(names(d_display) == "📎") - 1
        url_idx  <- which(names(d_display) == "🔗") - 1
        id_idx   <- which(names(d_display) == "id") - 1
        
        
        
        # Cinq colonnes portent du HTML — les icônes d'action et le lien. Tout le
        # reste vient de la base, dont le nom du contrat et celui du site :
        # quatre contrats sur 250 et deux sites sur 177 contiennent déjà un
        # caractère à échapper.
        d_display <- echapper_sauf(d_display, c("✏️", "👁", "🗺️", "📎", "🔗", "id"))

        DT::datatable(
          d_display,
          escape = FALSE,
          rownames = FALSE,
          selection = list(mode = "single", selected = NULL, target = "row"),
          options = list(
            pageLength = 10,
            dom = DT_DOM_PAGINATION_HAUT,
            columnDefs = list(
              list(className = "cf-map-col", targets = map_idx),
              list(className = "cf-act-col", targets = c(edit_idx, view_idx),
                   orderable = FALSE, searchable = FALSE),
              list(targets = docs_idx, orderable = FALSE, searchable = FALSE),
              list(targets = url_idx,  orderable = FALSE, searchable = FALSE),
              list(targets = id_idx, visible = FALSE) # ✅ ON CACHE L'ID
            )
          )
        )
        
      })
      
      # ========== FORMULAIRES À GAUCHE ==========
      # Choices statuts / types / acteurs
      type_contrat_agri_choices <- reactive({
        df <- dico_type_contrat_agricole %||% data.frame(id=integer(0), libelle=character(0))
        if (!all(c("id","libelle") %in% names(df))) return(integer(0))
        setNames(df$id, df$libelle)  # on affiche libelle, on stocke l'id
      })
      statut_choices <- reactive({
        dic <- statut_dic
        if (is.atomic(dic) && !is.null(names(dic))) {
          setNames(as.integer(names(dic)), as.character(dic))
        } else if (is.data.frame(dic) && all(c("id","libelle") %in% names(dic))) {
          setNames(dic$id, dic$libelle)
        } else integer(0)
      })
      # Libellé d'un type de maîtrise depuis son id — type_choices() est un
      # vecteur nommé (noms = libellés, valeurs = ids). Sert au seul contrôle
      # de durée, qui a besoin de lire « ≥ 18 ans » ou « < 18 ans ».
      .libelle_maitrise <- function(id) {
        ch <- type_choices()
        if (!length(ch)) return(NULL)
        i <- match(suppressWarnings(as.integer(id)[1]), as.integer(ch))
        if (is.na(i)) NULL else names(ch)[i]
      }

      # Refus commun aux quatre points d'enregistrement. Rend TRUE quand il
      # faut abandonner, après avoir dit pourquoi — même forme que les refus
      # déjà en place dans ce module.
      # Le message s'affiche DANS le formulaire, au-dessus du bouton, et pas
      # seulement en toast : la modale reste ouverte quand l'enregistrement est
      # refusé, et un bandeau qui ne s'efface pas se lit là où se trouve déjà
      # le regard — sur le bouton qu'on vient de cliquer. Le toast est gardé en
      # plus, pour le cas où le formulaire est long et le bandeau hors écran.
      coherence_rv <- reactiveVal(NULL)

      output$coherence_msg <- renderUI({
        msg <- coherence_rv()
        if (is.null(msg)) return(NULL)
        div(class = "alert alert-danger",
            style = "padding:8px 12px;margin-bottom:10px;",
            tags$b("Enregistrement refusé — "), msg)
      })

      # Le bandeau disparaît quand le formulaire change de mode : il parlerait
      # sinon d'une saisie qui n'est plus à l'écran.
      observeEvent(form_mode(), coherence_rv(NULL), ignoreNULL = FALSE)

      # `prefixe` est celui des champs du formulaire concerné — « create_cf_ »,
      # « edit_cf_ » ou « ca_ » — car valider_contrat() nomme le champ fautif
      # sans savoir dans quel formulaire il vit.
      #
      # shinyFeedback applique lui-même session$ns() : on lui passe donc l'id
      # SANS namespace, sous peine de le voir namespacé deux fois et de ne
      # rien afficher du tout.
      .CHAMPS_DATE <- c("date_debut", "date_fin", "date_rupture")

      .refuser_contrat <- function(prefixe, ...) {
        for (ch in .CHAMPS_DATE) shinyFeedback::hideFeedback(paste0(prefixe, ch))
        r <- valider_contrat(...)
        coherence_rv(if (is.null(r)) NULL else r$message)
        if (is.null(r)) return(FALSE)
        shinyFeedback::showFeedbackDanger(paste0(prefixe, r$champ), text = r$message)
        showToast("error", "Enregistrement refusé", r$message)
        TRUE
      }

      type_choices <- reactive({
        dic <- dico_type_maitrise
        if (is.atomic(dic) && !is.null(names(dic))) {
          setNames(as.integer(names(dic)), as.character(dic))
        } else if (is.data.frame(dic) && all(c("id","libelle_concat") %in% names(dic))) {
          setNames(dic$id, dic$libelle_concat)
        } else integer(0)
      })
      # Lecture ISOLÉE, et volontairement une fonction et non un reactive.
      #
      # Les formulaires sont construits dans un renderUI : une dépendance
      # réactive au reactiveVal les reconstruirait entièrement à chaque création
      # d'acteur, effaçant la saisie en cours. En revanche, l'ancienne forme —
      # un reactive dont le seul intrant était isolé — n'avait aucune dépendance
      # et se figeait sur sa PREMIÈRE évaluation pour toute la session. Une
      # simple fonction lit la valeur courante à chaque construction, sans rien
      # faire dépendre de rien.
      #
      # Le garde-fou qui réduisait le tableau à 0 ligne quand les colonnes
      # attendues manquaient a disparu : tous les points d'écriture passent
      # désormais par fetch_acteurs_choices(), qui impose la forme. Il
      # transformait un schéma incompatible en liste vide, c'est-à-dire en
      # panne silencieuse.
      acteurs_choices <- function() {
        df <- isolate(acteurs_existants_rv())
        if (is.null(df) || nrow(df) == 0) return(integer(0))
        setNames(df$id, df$acteur_label)
      }

      # Un formulaire DÉJÀ ouvert ne se reconstruit pas : on lui pousse les
      # nouveaux choix, en conservant la sélection en cours. Les sélecteurs
      # absents du mode courant ignorent simplement le message.
      observeEvent(acteurs_existants_rv(), ignoreInit = TRUE, {
        ch <- acteurs_choices()
        for (sel in c("create_cf_acteurs_ids", "create_ca_acteurs_ids",
                      "edit_cf_acteurs_ids",   "edit_ca_acteurs_ids")) {
          updateSelectizeInput(session, sel, choices = ch,
                               selected = isolate(input[[sel]]))
        }
      })
      
      
      # Builders de formulaires
      build_create_form <- function() {
        tagList(
          h5("➕ Créer un contrat"),
          
          # choix du type (plein largeur)
          selectInput(
            ns("type_contrat"),
            "Type de contrat",
            choices = c("Contrat foncier" = "foncier", "Contrat agricole" = "agricole"),
            selected = "foncier"
          ),
          
          # ======= CONTRAT FONCIER =======
          conditionalPanel(
            condition = sprintf("input['%s'] == 'foncier'", ns("type_contrat")),
            fluidRow(
              # Colonne gauche
              column(
                width = 6,
                textInput(ns("create_cf_nom"), "Nom du contrat *"),
                selectInput(
                  ns("create_cf_type_maitrise_id"),
                  label = tagList("Type de maîtrise *", tooltip_info(get_comment("type_maitrise_id"))),
                  choices = type_choices()
                ),
                selectInput(
                  ns("create_cf_statut_id"),
                  label = tagList("Statut *", tooltip_info(get_comment("statut_id"))),
                  choices = statut_choices()
                ),
                selectizeInput(
                  ns("create_cf_acteurs_ids"),
                  "Acteurs fonciers associés",
                  multiple = TRUE,
                  choices = acteurs_choices()
                )
              ),
              # Colonne droite
              column(
                width = 6,
                dateInput(ns("create_cf_date_signature"), "Date de signature", value = as.Date(NA)),
                dateInput(ns("create_cf_date_debut"), "Date de début *", value = Sys.Date()),
                dateInput(ns("create_cf_date_fin"), "Date de fin (optionnelle)", value = as.Date(NA)),
                textInput(ns("create_cf_url"), "URL", value = "",
                          placeholder = "Lien vers le document (optionnel)"),
                textAreaInput(ns("create_cf_remarque"), "Remarque", value = "", height = "70px")
              )
            )
          ),
          
          # ======= CONTRAT AGRICOLE =======
          conditionalPanel(
            condition = sprintf("input['%s'] == 'agricole'", ns("type_contrat")),
            fluidRow(
              # Colonne gauche
              column(
                width = 6,
                textInput(ns("ca_nom"), "Nom du contrat *"),
                selectInput(
                  ns("ca_type_contrat_id"),
                  "Type de contrat (agricole) *",
                  choices = type_contrat_agri_choices()
                ),
                selectInput(
                  ns("ca_statut_id"),
                  "Statut",
                  choices = setNames(dico_type_statut_contrat$id, dico_type_statut_contrat$libelle)
                ),
                selectizeInput(
                  ns("create_ca_acteurs_ids"),
                  "Acteurs",
                  multiple = TRUE,
                  choices = acteurs_choices()
                ),
                numericInput(ns("ca_surf_m2"), "Surface (m²)", value = NA, min = 0, step = 1),
                textInput(ns("ca_url"), "URL")
              ),
              # Colonne droite
              column(
                width = 6,
                dateInput(ns("ca_date_debut"), "Date de début *", value = Sys.Date()),
                dateInput(ns("ca_date_fin"),   "Date fin", value = as.Date(NA)),
                selectInput(
                  ns("ca_type_pratique_agricole_id"),
                  "Type de pratique agricole",
                  choices = setNames(dico_type_pratique_agricole$id, dico_type_pratique_agricole$libelle)
                ),
                selectInput(
                  ns("ca_type_cheptel_id"),
                  "Type de cheptel",
                  choices = setNames(dico_type_cheptel$id, dico_type_cheptel$libelle)
                ),
                numericInput(ns("ca_nb_cheptel"), "Nombre de têtes (entier)", value = NA, min = 0, step = 1),
                selectInput(
                  ns("ca_type_culture_id"),
                  "Type de culture",
                  choices = setNames(dico_type_culture$id, dico_type_culture$libelle)
                )
              )
            )
          ),
          
          br(),
          uiOutput(ns("coherence_msg")),
          div(
            shinyjs::disabled(actionButton(ns("create_contrat_save"), "✅ Enregistrer", class = "btn-primary")),
          ),
          tags$small(em("(*) champs obligatoires"))
        )
      }
      
      build_edit_form <- function(row, linked_acteurs) {
        roles_cur <- user_roles()  # 🎭 lecture réactive (suit l'impersonation)
        is_admin <- roles_cur$global_role == "AD"
        
        # Détermine le type réel du contrat depuis la ligne (pas depuis un input)
        t <- tolower(as.character(row$type_contrat %||% "foncier"))
        t <- ifelse(t == "contrat agricole" || t == "agricole", "agricole", "foncier")
        
        # Petit badge lisible et non modifiable
        type_badge <- div(
          style = "margin: 6px 0 12px 0;",
          tags$span(
            style = "display:inline-block;padding:4px 8px;border-radius:8px;font-weight:600;",
            if (t == "agricole") "Type : Contrat agricole (non modifiable)" else "Type : Contrat foncier"
          )
        )
        
        if (t == "foncier") {
          # ========================
          #      CONTRAT FONCIER
          # ========================
          tagList(
            h4(sprintf("✏️ Modifier « %s »", row$nom %||% paste("Contrat", row$id))),
            type_badge,
            
            fluidRow(
              # Colonne gauche
              column(
                width = 6,
                textInput(ns("edit_cf_nom"), "Nom du contrat *", value = row$nom %||% ""),
                selectInput(
                  ns("edit_cf_type_maitrise_id"),
                  "Type de maîtrise *",
                  choices  = type_choices(),
                  selected = as.character(row$type_maitrise_id)
                ),
                selectInput(
                  ns("edit_cf_statut_id"),
                  "Statut *",
                  choices  = statut_choices(),
                  selected = as.character(row$statut_id %||% "")
                ),
                selectizeInput(
                  ns("edit_cf_acteurs_ids"),
                  "Acteurs fonciers associés",
                  choices  = acteurs_choices(),
                  selected = linked_acteurs,
                  multiple = TRUE
                )
              ),
              
              # Colonne droite
              column(
                width = 6,
                dateInput(
                  ns("edit_cf_date_signature"),
                  "Date de signature",
                  value = dateInput_value(row$date_signature)
                ),
                dateInput(
                  ns("edit_cf_date_debut"),
                  "Date de début",
                  value = dateInput_value(row$date_debut)
                ),
                dateInput(
                  ns("edit_cf_date_fin"),
                  "Date de fin (optionnelle)",
                  value = dateInput_value(row$date_fin)
                ),
                textInput(
                  ns("edit_cf_url"),
                  "URL",
                  placeholder = "Lien vers le document (optionnel)",
                  # url absente de query_contrats (retirée de l'affichage) :
                  # relue en base, sinon le champ s'ouvrirait vide et écraserait
                  # la valeur existante à l'enregistrement.
                  value = tryCatch({
                    u <- safe_db_query(con, glue::glue(
                      "SELECT url FROM gestcons.contrats_fonciers WHERE id = {as.integer(row$id)}"))$url[1]
                    if (length(u) == 0 || is.na(u)) "" else u
                  }, error = function(e) "")
                ),
                textAreaInput(
                  ns("edit_cf_remarque"),
                  "Remarque",
                  value  = row$remarque %||% "",
                  height = "70px"
                ),
                .champs_rupture("edit_cf_", row)
              )
            ),
            
            # 📎 Gestion des documents intégrée à la modale du contrat
            .c_docs_section(),
            br(),
            uiOutput(ns("coherence_msg")),
            div(
              actionButton(ns("update_contrat"), "💾 Mettre à jour", class = "btn-primary", style = "margin-bottom: 8px;"),
              if (is_admin) {
                actionButton(ns("delete_contrat"), "🗑 Supprimer", class = "btn-danger")
              },
              tags$span(" ", style = "margin-left:6px;"),
              ),
            tags$small(em("(*) champs obligatoires"))
          )
          
        } else {
          # ========================
          #      CONTRAT AGRICOLE
          # ========================
          tagList(
            h4(sprintf("✏️ Modifier « %s »", row$nom %||% paste("Contrat", row$id))),
            type_badge,
            
            fluidRow(
              # Colonne gauche
              column(
                width = 6,
                selectInput(
                  ns("ca_type_contrat_id"),
                  "Type de contrat (agricole) *",
                  choices  = type_contrat_agri_choices(),
                  selected = as.character(row$type_contrat_id %||% "")
                ),
                selectInput(
                  ns("ca_statut_id"),
                  "Statut",
                  choices  = setNames(dico_type_statut_contrat$id, dico_type_statut_contrat$libelle),
                  selected = as.character(row$statut_id %||% "")
                ),
                selectizeInput(
                  ns("edit_ca_acteurs_ids"),
                  "Acteurs",
                  multiple = TRUE,
                  choices  = acteurs_choices(),
                  selected = linked_acteurs
                ),
                dateInput(
                  ns("ca_date_debut"),
                  "Date début *",
                  value = dateInput_value(row$date_debut)
                ),
                dateInput(
                  ns("ca_date_fin"),
                  "Date fin",
                  value = dateInput_value(row$date_fin)
                ),
                numericInput(
                  ns("ca_surf_m2"),
                  "Surface (m²)",
                  value = if (!is.na(row$surf_m2)) row$surf_m2 else NA,
                  min   = 0,
                  step  = 1
                ),
                textInput(
                  ns("ca_nom"),
                  "Nom",
                  value = row$nom %||% ""
                ),
                textInput(
                  ns("ca_url"),
                  "URL",
                  # url absente de query_contrats (retirée de l'affichage) :
                  # relue en base, sinon le champ s'ouvre vide et l'écrase
                  # à l'enregistrement.
                  value = tryCatch({
                    u <- safe_db_query(con, glue::glue(
                      "SELECT url FROM gestcons.contrats_agricoles WHERE id = {as.integer(row$id)}"))$url[1]
                    if (length(u) == 0 || is.na(u)) "" else u
                  }, error = function(e) "")
                )
              ),
              
              # Colonne droite
              column(
                width = 6,
                selectInput(
                  ns("ca_type_pratique_agricole_id"),
                  "Type de pratique agricole",
                  choices  = setNames(dico_type_pratique_agricole$id, dico_type_pratique_agricole$libelle),
                  selected = as.character(row$type_pratique_agricole_id %||% "")
                ),
                selectInput(
                  ns("ca_type_cheptel_id"),
                  "Type de cheptel",
                  choices  = setNames(dico_type_cheptel$id, dico_type_cheptel$libelle),
                  selected = as.character(row$type_cheptel_id %||% "")
                ),
                numericInput(
                  ns("ca_nb_cheptel"),
                  "Nombre de têtes (entier)",
                  value = if (!is.null(row$nb_cheptel) && !is.na(row$nb_cheptel)) as.integer(row$nb_cheptel) else NA,
                  min   = 0,
                  step  = 1
                ),
                selectInput(
                  ns("ca_type_culture_id"),
                  "Type de culture",
                  choices  = setNames(dico_type_culture$id, dico_type_culture$libelle),
                  selected = as.character(row$type_culture_id %||% "")
                ),
                .champs_rupture("ca_", row)
              )
            ),
            
            # 📎 Gestion des documents intégrée à la modale du contrat
            .c_docs_section(),
            br(),
            uiOutput(ns("coherence_msg")),
            div(
              actionButton(ns("update_contrat"), "💾 Mettre à jour", class = "btn-primary", style = "margin-bottom: 8px;"),
              if (is_admin) {
                actionButton(ns("delete_contrat"), "🗑 Supprimer", class = "btn-danger")
              },
              tags$span(" ", style = "margin-left:6px;"),
              ),
            tags$small(em("(*) champs obligatoires"))
          )
        }
      }
      
      
      # Affichage dynamique du formulaire
      output$contrat_form <- renderUI({
        mode <- form_mode()
        if (mode == "create") return(build_create_form())
        if (mode == "edit") {
          cid <- editing_id(); req(cid)
          ctype <- editing_type(); req(ctype) # On récupère aussi le type
          
          debug_print(paste("cid = ", cid, "ctype =", ctype))
          
          # Correction : filtrer sur l'ID ET le type de contrat
          row <- try(contrats()[contrats()$id == cid & contrats()$type_contrat == ctype, ], silent = TRUE)
          
          shiny::validate(need(!inherits(row, "try-error") && nrow(row) == 1, "Contrat introuvable."))
          
          # L'édition se base sur le type stocké dans 'editing_type', plus besoin de le recalculer ici
          # On peut retirer la ligne redondante qui était ici.
          # Ancien code retiré : editing_type(ifelse(tolower(as.character(row$type_contrat[1])) == "agricole", "agricole", "foncier"))
          
          # acteurs liés (seulement pour les fonciers, comme avant)
          current_acteurs <- tryCatch({
            if (ctype == "foncier") {
              DBI::dbGetQuery(con, glue::glue("
              SELECT acteur_id FROM gestcons.contrats_acteurs_fonciers
              WHERE contrat_foncier_id = {cid}
              ORDER BY acteur_id
            "))
            } else {
              DBI::dbGetQuery(con, glue::glue("
              SELECT acteur_id FROM gestcons.contrats_agriculteurs
              WHERE contrat_agri_id = {cid}
              ORDER BY acteur_id
            "))
            }
          }, error = function(e) data.frame(acteur_id = integer(0)))
          linked_acteurs <- current_acteurs$acteur_id
          
          
          return(build_edit_form(row, current_acteurs$acteur_id))
        }
      })

      # Boutons « Enregistrer/Mettre à jour » désactivés tant que les champs
      # obligatoires (*) ne sont pas remplis. Le jeu de champs dépend du mode
      # (création/édition) et du type (foncier/agricole), via les reactiveVals.
      observe({
        if (identical(form_mode(), "create")) {
          if (identical(input$type_contrat, "agricole")) {
            toggle_submit_state(input, "create_contrat_save",
                                c("ca_nom", "ca_type_contrat_id", "ca_date_debut"))
          } else {
            toggle_submit_state(input, "create_contrat_save",
                                c("create_cf_nom", "create_cf_type_maitrise_id",
                                  "create_cf_statut_id", "create_cf_date_debut"))
          }
        } else if (identical(form_mode(), "edit")) {
          if (identical(editing_type(), "agricole")) {
            toggle_submit_state(input, "update_contrat",
                                c("ca_type_contrat_id", "ca_date_debut"))
          } else {
            toggle_submit_state(input, "update_contrat",
                                c("edit_cf_nom", "edit_cf_type_maitrise_id", "edit_cf_statut_id"))
          }
        }
      })
      
      # Afficher le formulaire de contrat dans un modal
      show_contrat_modal <- function(title = NULL) {
        showModal(modalDialog(
          title = title %||% "Contrat",
          size = "l",
          easyClose = TRUE,
          footer = NULL,  # boutons déjà dans le formulaire (Enregistrer / Annuler / Supprimer)
          uiOutput(ns("contrat_form"))
        ))
      }
      
      # Bouton "Nouveau contrat" -> mode création
      observeEvent(input$new_contrat, {
        editing_id(NULL)
        editing_type(NULL)
        form_mode("create")
        show_contrat_modal("Nouveau contrat")
      })
      
      # ✅ REMPLACEMENT DE L'OBSERVER rows_selected PAR L'EVENT CUSTOM JS
      observeEvent(input$contrat_row_click, {
        # On récupère l'objet envoyé par JS : { id: ..., type: ... }
        res <- input$contrat_row_click
        req(res$id)

        # Garde serveur : même règle que l'affichage du crayon, rejouée ici.
        if (!.peut_editer_contrat_id(as.integer(res$id), res$type)) {
          showToast("warning", "Lecture seule",
                    "Vous n'êtes responsable d'aucun site concerné par ce contrat.")
          .show_cf_fiche(res)
          return(invisible(NULL))
        }

        # Mise à jour des variables réactives pour l'édition
        editing_id(as.integer(res$id))
        editing_type(res$type) # "foncier" ou "agricole"
        form_mode("edit")

        # Alimente la section 📎 Documents intégrée à la modale
        c_docs_contrat_id(as.integer(res$id))
        c_docs_contrat_kind(if (identical(res$type, "agricole")) "A" else "F")
        c_doc_uploader_nonce(isolate(c_doc_uploader_nonce()) + 1)
        c_docs_reload(isolate(c_docs_reload()) + 1)

        show_contrat_modal(sprintf("Édition du contrat #%s", res$id))
      })
      
      # ---------- Consultation (œil) : fiche complète en lecture seule ----------
      .c_libelle <- function(dic, id_val, col = "libelle") {
        if (is.null(id_val) || length(id_val) == 0 || is.na(id_val)) return("—")
        if (is.data.frame(dic) && all(c("id", col) %in% names(dic))) {
          v <- dic[[col]][dic$id == id_val]
          if (length(v) && !is.na(v[1]) && nzchar(v[1])) return(v[1])
        } else if (is.atomic(dic) && !is.null(names(dic))) {
          v <- dic[[as.character(id_val)]]
          if (!is.null(v) && !is.na(v) && nzchar(v)) return(v)
        }
        "—"
      }
      .c_txt  <- function(x) if (is.null(x) || length(x) == 0 || is.na(x[1]) || !nzchar(as.character(x[1]))) "—" else as.character(x[1])
      .c_date <- function(x) { d <- suppressWarnings(as.Date(x[1])); if (is.na(d)) "—" else format(d, "%d/%m/%Y") }
      .c_ligne <- function(lbl, val) tags$p(tags$strong(paste0(lbl, " : ")), tags$span(val))

      .show_cf_fiche <- function(res) {
        res <- input$cf_view
        req(res$id)
        cid  <- as.integer(res$id)
        agri <- identical(res$type, "agricole")
        tbl  <- if (agri) "gestcons.contrats_agricoles" else "gestcons.contrats_fonciers"

        row <- safe_db_query(con, glue::glue("SELECT * FROM {tbl} WHERE id = {cid} LIMIT 1"))
        if (is.null(row) || nrow(row) == 0) {
          showToast("error", "Contrat introuvable", "Cette fiche n'existe plus.")
          return(invisible(NULL))
        }

        # Sites concernés (via les parcelles liées) et acteurs associés
        jt <- if (agri) "gestcons.contrats_agricoles_parcelles" else "gestcons.contrats_foncier_parcelles"
        cc <- if (agri) "contrat_agri_id" else "contrat_id"
        sites <- safe_db_query(con, glue::glue("
          SELECT s.libelle, count(*)::int AS nb
          FROM {jt} j JOIN gestcons.parcelles_base p ON p.id = j.parcelle_id
          JOIN gestcons.sites s ON s.id = p.site_id
          WHERE j.{cc} = {cid} GROUP BY s.libelle ORDER BY s.libelle"))
        at <- if (agri) "gestcons.contrats_agriculteurs" else "gestcons.contrats_acteurs_fonciers"
        ac <- if (agri) "contrat_agri_id" else "contrat_foncier_id"
        acteurs <- safe_db_query(con, glue::glue("
          SELECT a.nom, a.prenom FROM {at} ca
          JOIN gestcons.dico_acteurs_fonciers_agricoles a ON a.id = ca.acteur_id
          WHERE ca.{ac} = {cid} ORDER BY a.nom, a.prenom"))
        # Les pièces jointes elles-mêmes, et plus seulement leur nombre : la
        # fiche se consultait sans pouvoir ouvrir un seul document, il fallait
        # passer par le formulaire d'édition — donc en avoir le droit.
        docs <- .c_fetch_docs(cid, if (agri) "A" else "F")
        nb_docs <- if (is.null(docs)) 0L else nrow(docs)

        sites_txt <- if (is.null(sites) || !nrow(sites)) "—" else
          paste0(sites$libelle, " (", sites$nb, ")", collapse = ", ")
        acteurs_txt <- if (is.null(acteurs) || !nrow(acteurs)) "—" else
          paste(trimws(paste(acteurs$prenom %||% "", acteurs$nom)), collapse = ", ")

        url_val <- .c_txt(row$url)
        showModal(modalDialog(
          title = htmltools::HTML(paste0(
            if (agri) "Contrat agricole — " else "Contrat foncier — ",
            "<span style='color:var(--c-accent);'>", htmltools::htmlEscape(.c_txt(row$nom)), "</span>")),
          size = "l", easyClose = TRUE,
          footer = if (.peut_editer_contrat_id(cid, if (agri) "agricole" else "foncier"))
            tagList(actionButton(ns("cf_view_edit"), "✏️ Modifier", class = "btn-primary"))
          else
            tagList(modalButton("Fermer")),
          fluidRow(
            column(6,
              .c_ligne("Statut", .c_libelle(statut_dic, row$statut_id)),
              if (agri) .c_ligne("Type de contrat", .c_libelle(dico_type_contrat_agricole, row$type_contrat_id))
              else      .c_ligne("Type de maîtrise", .c_libelle(dico_type_maitrise, row$type_maitrise_id, "libelle_concat")),
              .c_ligne("Sites concernés", sites_txt),
              .c_ligne("Acteurs associés", acteurs_txt),
              .c_ligne("Pièces jointes", nb_docs),
              tags$p(tags$strong("URL : "),
                     if (identical(url_val, "—")) tags$span("—")
                     else tags$a(href = url_val, target = "_blank", rel = "noopener", url_val))
            ),
            column(6,
              if (!agri) .c_ligne("Date de signature", .c_date(row$date_signature)),
              .c_ligne("Date de début", .c_date(row$date_debut)),
              .c_ligne("Date de fin", .c_date(row$date_fin)),
              .c_ligne("Date de rupture", .c_date(row$date_rupture)),
              if (agri) .c_ligne("Surface (m²)", .c_txt(row$surf_m2)),
              if (agri) .c_ligne("Type de culture", .c_libelle(dico_type_culture, row$type_culture_id)),
              if (agri) .c_ligne("Pratique agricole", .c_libelle(dico_type_pratique_agricole, row$type_pratique_agricole_id)),
              if (agri) .c_ligne("Cheptel", paste(.c_libelle(dico_type_cheptel, row$type_cheptel_id),
                                                  if (!is.na(row$nb_cheptel[1])) paste0("(", row$nb_cheptel[1], ")") else "")),
              .c_ligne("Modifié par", .c_txt(row$modifie_par)),
              .c_ligne("Dernière modification", .c_date(row$date_modification))
            )
          ),
          tags$hr(),
          tags$p(tags$strong("Remarque :")),
          tags$blockquote(.c_txt(row$remarque)),
          if (!identical(.c_txt(row$remarque_rupture), "—")) tagList(
            tags$p(tags$strong("Remarque de rupture :")),
            tags$blockquote(.c_txt(row$remarque_rupture))),
          .c_pieces_jointes(docs)
        ))
        # Mémorise la cible pour le bouton « Modifier » du pied de fiche
        cf_view_target(list(id = cid, type = if (agri) "agricole" else "foncier"))
      }

      # Liste de liens plutôt qu'un tableau : la fiche est bâtie d'un bloc par
      # showModal, sans output ni renderDT où brancher docs_datatable().
      #
      # L'URL est échappée en contexte d'ATTRIBUT, le nom de fichier en
      # contexte de TEXTE : le second est celui d'origine, tel que téléversé —
      # l'assainissement de docs_add() ne vaut que pour le nom sur disque, et
      # un nom contenant « < » arrive donc intact. rel='noopener' : le document
      # ouvert ne peut pas manipuler l'onglet de l'application.
      .c_pieces_jointes <- function(docs) {
        if (is.null(docs) || !nrow(docs)) {
          return(tagList(tags$hr(),
                         tags$p(tags$strong("Pièces jointes :"), " aucune")))
        }
        lignes <- lapply(seq_len(nrow(docs)), function(i) {
          d <- docs[i, ]
          type_txt <- .c_txt(d$type_document)
          remq     <- .c_txt(d$remarque)
          tags$li(
            tags$a(href = paste0("./", d$url), target = "_blank", rel = "noopener",
                   paste0("🔗 ", .c_txt(d$nom_fichier))),
            if (!identical(type_txt, "—"))
              tags$span(class = "text-muted", paste0(" — ", type_txt)),
            if (!identical(remq, "—"))
              tags$span(class = "text-muted", paste0(" (", remq, ")"))
          )
        })
        tagList(
          tags$hr(),
          tags$p(tags$strong(sprintf("Pièces jointes (%d) :", nrow(docs)))),
          tags$ul(lignes)
        )
      }

      observeEvent(input$cf_view, { .show_cf_fiche(input$cf_view) })

      # Bascule consultation -> édition
      observeEvent(input$cf_view_edit, {
        t <- cf_view_target(); req(t)
        if (!.peut_editer_contrat_id(as.integer(t$id), t$type)) {
          showToast("warning", "Lecture seule",
                    "Vous n'êtes responsable d'aucun site concerné par ce contrat.")
          return(invisible(NULL))
        }
        removeModal()
        editing_id(as.integer(t$id)); editing_type(t$type); form_mode("edit")
        c_docs_contrat_id(as.integer(t$id))
        c_docs_contrat_kind(if (identical(t$type, "agricole")) "A" else "F")
        c_doc_uploader_nonce(isolate(c_doc_uploader_nonce()) + 1)
        c_docs_reload(isolate(c_docs_reload()) + 1)
        show_contrat_modal(sprintf("Édition du contrat #%s", t$id))
      })

      # Si la date est vide, on efface la remarque (cohérent avec l'UI masquée)
      for (.p in c("edit_cf_", "ca_")) local({
        prefix <- .p
        observeEvent(input[[paste0(prefix, "date_rupture")]], {
          if (.is_blank(input[[paste0(prefix, "date_rupture")]])) {
            updateTextAreaInput(session, paste0(prefix, "remarque_rupture"), value = "")
          }
        })
      })
      
      show_help_contrats_modal <- function(anim_id, step3 = FALSE) {
        showModal(modalDialog(
          title = "En savoir plus...",
          size = "l", easyClose = TRUE,
          footer = NULL,   # fermeture par la croix de l'en-tête
          fluidPage(
            h5("Ce module vous permet de gérer les contrats fonciers ou agricoles pour les sites conservatoires que vous gérez.")
          )
        ))
      }
      
      # Texte d’aide quand aucun site n’est sélectionné
      output$contrats_helper_text <- renderUI({
        # Aucun site si NULL ou valeur " " (vide contrôlé)
        if (is.null(input$af_site_selector) || identical(input$af_site_selector, " ")) {
          tags$p(
            class = "text-muted",
            "Ce module vous permet de gérer les contrats fonciers ou agricoles pour les sites conservatoires que vous gérez.",
            actionLink(ns("contrats_help"), "En savoir plus...")
          )
        } else {
          NULL
        }
      })
      
      # Clic sur "En savoir plus..." → ouvre le modal d'aide
      observeEvent(input$contrats_help, {
        show_help_contrats_modal()
      })
      
      # Annuler (revient à l'état neutre)
      
      # ----------------- Enregistrer (création) -----------------
      observeEvent(input$create_contrat_save, {
        req(input$type_contrat %in% c("foncier","agricole"))

        # ⚠️ AVANT le spinner, et c'est tout l'enjeu : remove_modal_spinner()
        # REFERME la modale du contrat — le code le note déjà plus bas, à
        # propos de l'édition. Posé après, un refus fermait donc la modale
        # qu'il prétendait garder ouverte, et le message s'affichait dans le
        # vide. Le contrôle ne coûte rien, il peut passer en premier.
        refus <- if (identical(input$type_contrat, "foncier"))
          .refuser_contrat("create_cf_",
                           date_debut = input$create_cf_date_debut,
                           date_fin   = input$create_cf_date_fin,
                           statut_id  = input$create_cf_statut_id,
                           duree_type = duree_type_maitrise(
                             .libelle_maitrise(input$create_cf_type_maitrise_id)))
        else
          .refuser_contrat("ca_",
                           date_debut   = input$ca_date_debut,
                           date_fin     = input$ca_date_fin,
                           date_rupture = input$ca_date_rupture,
                           statut_id    = input$ca_statut_id)
        if (isTRUE(refus)) return(invisible(NULL))

        shinybusy::show_modal_spinner(spin = "circle", color = COULEUR_SPINNER, text = "💾 Enregistrement…")
        on.exit(shinybusy::remove_modal_spinner(), add = TRUE)
        
        sys_user_sql <- DBI::dbQuoteLiteral(con, user_to_db())
        
        if (identical(input$type_contrat, "foncier")) {
          # ===== Création FONCIER =====
          req(!.is_blank(input$create_cf_nom))
          req(!.is_blank(input$create_cf_type_maitrise_id))
          req(!.is_blank(input$create_cf_statut_id))
          
          is_actif <- input$create_cf_statut_id == statut_actif_id_rv()
          has_acteurs <- length(input$create_cf_acteurs_ids) > 0
          
          nom_sql   <- DBI::dbQuoteLiteral(con, input$create_cf_nom)
          type_id   <- as.integer(input$create_cf_type_maitrise_id)
          statut_id <- as.integer(input$create_cf_statut_id)
          rem_sql   <- DBI::dbQuoteLiteral(con, input$create_cf_remarque %||% "")
          # url : champ vide -> NULL (et non chaîne vide)
          url_sql   <- if (.is_blank(input$create_cf_url)) "NULL" else DBI::dbQuoteLiteral(con, trimws(input$create_cf_url))
          
          d_sig_sql <- if (.is_blank(input$create_cf_date_signature)) "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$create_cf_date_signature))
          d_deb_sql <- if (.is_blank(input$create_cf_date_debut))     "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$create_cf_date_debut))
          d_fin_sql <- if (.is_blank(input$create_cf_date_fin))       "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$create_cf_date_fin))

          new_id <- NULL
          
          # poolWithTransaction annule la transaction dès qu'une erreur remonte.
          # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
          # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
          tx_ok <- tryCatch({
            pool::poolWithTransaction(con, function(conn) {
              sql <- glue::glue("
              INSERT INTO gestcons.contrats_fonciers
                (nom, type_maitrise_id, statut_id, date_signature, date_debut, date_fin, url, remarque,
                 cree_par, date_creation, modifie_par, date_modification, actif)
              VALUES ({nom_sql}, {type_id}, {statut_id}, {d_sig_sql}, {d_deb_sql}, {d_fin_sql}, {url_sql}, {rem_sql},
                      {sys_user_sql}, NOW(), {sys_user_sql}, NOW(), TRUE)
              RETURNING id
            ")
              # IMPORTANT : on utilise 'conn' (la transaction) et pas 'con' (le pool)
              new_id <<- safe_db_insert(conn, sql)
            
              # Liaisons acteurs (si renseignés)
              act_ids <- input$create_cf_acteurs_ids %||% integer(0)
              act_ids <- as.integer(act_ids[!is.na(act_ids)])
              if (length(act_ids) > 0) {
                values <- paste0("(", new_id, ", ", act_ids, ")", collapse = ",")
                safe_db_execute(conn, glue::glue("
                INSERT INTO gestcons.contrats_acteurs_fonciers (contrat_foncier_id, acteur_id)
                VALUES {DBI::SQL(values)}
                ON CONFLICT DO NOTHING
              "))
              }
            })
            TRUE
          }, error = function(e) {
            showToast("error", "Création impossible", conditionMessage(e))
            FALSE
          })
          if (!isTRUE(tx_ok)) return(invisible(NULL))
          
          reload_contrats_choices()
          showNotification("Contrat foncier créé.", type = "message")
          log_action(session, current_user_rv, "Création d'un contrat foncier")
          editing_id(new_id); editing_type("foncier"); form_mode("edit")
          
        } else {
          # ===== Création AGRICOLE =====
          # validations minimales
          is_nonneg_integer <- function(x) is.finite(x) && floor(x) == x && x >= 0
          
          nb <- suppressWarnings(as.numeric(input$ca_nb_cheptel))
          
          # ✅ Autorise vide (NULL / NA / ""), sinon exige entier ≥ 0
          if (!.is_blank(nb) && !is_nonneg_integer(nb)) {
            showToast("error", "Nombre de têtes invalide", "Doit être un entier ≥ 0 ou laissé vide.")
            return()
          }
          
          is_actif <- input$ca_statut_id == statut_actif_id_rv()
          has_acteurs <- length(input$create_ca_acteurs_ids) > 0
          
          if (is_actif && !has_acteurs) {
            showToast(
              "error", 
              "Validation Requise", 
              "Un contrat 'Agricole' Actif doit être associé à au moins un Acteur Foncier."
            )
            return(NULL)
          }
          
          rupt_sql <- .sql_rupture("ca_")

        q_ins <- glue::glue_sql("
          INSERT INTO gestcons.contrats_agricoles
            (type_contrat_id, type_culture_id, date_debut, date_fin, surf_m2, statut_id,
             nom, url, date_rupture, actif, remarque_rupture,
             cree_par, date_creation, modifie_par, date_modification,
             type_pratique_agricole_id, type_cheptel_id, nb_cheptel)
          VALUES (
            {as.integer(input$ca_type_contrat_id)},
            {as.integer(input$ca_type_culture_id)},
            {date_or_null(input$ca_date_debut)},
            {date_or_null(input$ca_date_fin)},
            {num_or_null(input$ca_surf_m2)},
            {as.integer(input$ca_statut_id)},
            {val_or_null(input$ca_nom)},
            {val_or_null(input$ca_url)},
            {rupt_sql$date},
            TRUE,
            {rupt_sql$remarque},
            {user_to_db()}, NOW(), {user_to_db()}, NOW(),
            {as.integer(input$ca_type_pratique_agricole_id)},
            {as.integer(input$ca_type_cheptel_id)},
            {int_or_null(input$ca_nb_cheptel)}
          )
          RETURNING id
        ", .con = con)
          
          new_id <- NULL
          # poolWithTransaction annule la transaction dès qu'une erreur remonte.
          # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
          # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
          tx_ok <- tryCatch({
            pool::poolWithTransaction(con, function(conn) {
              new_id <<- DBI::dbGetQuery(conn, q_ins)$id[1]

              act_ids <- input$create_ca_acteurs_ids %||% integer(0)
              act_ids <- as.integer(act_ids[!is.na(act_ids)])

              if (length(act_ids) > 0) {
                values <- paste0("(", new_id, ", ", act_ids, ")", collapse = ",")
                safe_db_execute(conn, glue::glue("
                  INSERT INTO gestcons.contrats_agriculteurs (contrat_agri_id, acteur_id)
                  VALUES {DBI::SQL(values)}
                  ON CONFLICT DO NOTHING
                "))
              }
            })
            TRUE
          }, error = function(e) {
            showToast("error", "Création impossible", conditionMessage(e))
            FALSE
          })
          if (!isTRUE(tx_ok)) return(invisible(NULL))
          
          
          showNotification("Contrat agricole créé.", type = "message")
          log_action(session, current_user_rv, "Création d'un contrat agricole")
          reload_contrats_agri_choices()
          editing_id(new_id); editing_type("agricole"); form_mode("edit")
        }
        
        .reload_contrats()
      })
      
      
      # ----------------- Mettre à jour (édition) -----------------
      observeEvent(input$update_contrat, {
        cid <- editing_id(); req(cid)
        ctype <- editing_type() %||% "foncier"

        # Pas de show_modal_spinner : c'est une modale, empilée sur la modale du
        # contrat -> son retrait la refermerait (on veut la garder ouverte pour
        # voir la PJ ajoutée). La mise à jour est rapide.
        sys_user_sql <- DBI::dbQuoteLiteral(con, user_to_db())
        
        if (ctype == "foncier") {
          # ===== UPDATE FONCIER =====
          req(!.is_blank(input$edit_cf_nom))
          req(!.is_blank(input$edit_cf_type_maitrise_id))
          req(!.is_blank(input$edit_cf_statut_id))
          
          is_actif <- input$edit_cf_statut_id == statut_actif_id_rv()
          has_acteurs <- length(input$edit_cf_acteurs_ids) > 0
          
          nom_sql      <- DBI::dbQuoteLiteral(con, input$edit_cf_nom)
          type_id      <- as.integer(input$edit_cf_type_maitrise_id)
          statut_id    <- as.integer(input$edit_cf_statut_id)
          rem_sql      <- DBI::dbQuoteLiteral(con, input$edit_cf_remarque %||% "")
          
          d_sig_sql    <- if (.is_blank(input$edit_cf_date_signature)) "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$edit_cf_date_signature))
          d_deb_sql    <- if (.is_blank(input$edit_cf_date_debut))     "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$edit_cf_date_debut))
          d_fin_sql    <- if (.is_blank(input$edit_cf_date_fin))       "NULL" else DBI::dbQuoteLiteral(con, as.Date(input$edit_cf_date_fin))
          rupt_sql     <- .sql_rupture("edit_cf_")

          if (.refuser_contrat("edit_cf_",
                               date_debut   = input$edit_cf_date_debut,
                               date_fin     = input$edit_cf_date_fin,
                               date_rupture = input$edit_cf_date_rupture,
                               statut_id    = statut_id,
                               duree_type   = duree_type_maitrise(.libelle_maitrise(type_id))))
            return(invisible(NULL))
          
          # url : champ vide -> NULL (et non chaîne vide, qui était la trace
          # laissée en base par l'ancienne écriture depuis un input inexistant)
          url_sql      <- if (.is_blank(input$edit_cf_url)) "NULL" else DBI::dbQuoteLiteral(con, trimws(input$edit_cf_url))

          # poolWithTransaction annule la transaction dès qu'une erreur remonte.
          # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
          # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
          tx_ok <- tryCatch({
            pool::poolWithTransaction(con, function(conn) {
              # UPDATE contrat + audit
              # Note : utilisez 'conn' pour l'exécution
              safe_db_execute(conn, glue::glue("
              UPDATE gestcons.contrats_fonciers SET
                nom = {nom_sql},
                type_maitrise_id = {type_id},
                statut_id = {statut_id},
                date_signature = {d_sig_sql},
                date_debut = {d_deb_sql},
                date_fin = {d_fin_sql},
                date_rupture = {rupt_sql$date},
                remarque_rupture = {rupt_sql$remarque},
                url = {url_sql},
                remarque = {rem_sql},
                modifie_par = {sys_user_sql},
                date_modification = NOW()
              WHERE id = {cid}
            "))
            
              # Re-écrire les liaisons acteurs
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_acteurs_fonciers WHERE contrat_foncier_id = {cid}
            "))
              act_ids <- input$edit_cf_acteurs_ids %||% integer(0)
              act_ids <- as.integer(act_ids[!is.na(act_ids)])
              if (length(act_ids) > 0) {
                values <- paste0("(", cid, ", ", act_ids, ")", collapse = ",")
                safe_db_execute(conn, glue::glue("
                INSERT INTO gestcons.contrats_acteurs_fonciers (contrat_foncier_id, acteur_id)
                VALUES {DBI::SQL(values)}
                ON CONFLICT DO NOTHING
              "))
              }
            })
            TRUE
          }, error = function(e) {
            showToast("error", "Mise à jour impossible", conditionMessage(e))
            FALSE
          })
          if (!isTRUE(tx_ok)) return(invisible(NULL))
          
          reload_contrats_choices()
          showNotification("Contrat foncier mis à jour.", type = "message")
          log_action(session, current_user_rv, "Mise à jour d'un contrat foncier")
          
        } else {
          # ===== UPDATE AGRICOLE =====
          # helper sûr (tu as déjà .is_blank ; sinon garde celui-ci)
          is_nonneg_integer <- function(x) is.finite(x) && floor(x) == x && x >= 0
          
          nb <- suppressWarnings(as.numeric(input$ca_nb_cheptel))
          
          # ✅ Autorise vide (NULL / NA / ""), sinon exige entier ≥ 0
          if (!.is_blank(nb) && !is_nonneg_integer(nb)) {
            showToast("error", "Nombre de têtes invalide", "Doit être un entier ≥ 0 ou laissé vide.")
            return()
          }
          
          is_actif <- input$ca_statut_id == statut_actif_id_rv()
          has_acteurs <- length(input$edit_ca_acteurs_ids) > 0
          
          if (is_actif && !has_acteurs) {
            showToast(
              "error", 
              "Validation Requise", 
              "Un contrat 'Agricole' Actif doit être associé à au moins un Acteur Foncier."
            )
            return(NULL)
          }
          
          rupt_sql <- .sql_rupture("ca_")

          if (.refuser_contrat("ca_",
                               date_debut   = input$ca_date_debut,
                               date_fin     = input$ca_date_fin,
                               date_rupture = input$ca_date_rupture,
                               statut_id    = input$ca_statut_id))
            return(invisible(NULL))

          # La branche foncière, trente lignes plus haut, est transactionnelle ;
          # celle-ci ne l'était pas. Le DELETE des agriculteurs était donc validé
          # seul, et un INSERT en échec — un acteur supprimé entre-temps viole la
          # clé étrangère, que le ON CONFLICT ne couvre pas — laissait le contrat
          # SANS aucun acteur. Or la règle métier posée trente lignes plus haut
          # exige qu'un contrat agricole actif en porte au moins un.
          tx_ok <- tryCatch({
            pool::poolWithTransaction(con, function(conn) {
              tx_execute(conn, glue::glue_sql("
              UPDATE gestcons.contrats_agricoles SET
                type_contrat_id = {as.integer(input$ca_type_contrat_id)},
                type_culture_id = {as.integer(input$ca_type_culture_id)},
                date_debut      = {date_or_null(input$ca_date_debut)},
                date_fin        = {date_or_null(input$ca_date_fin)},
                surf_m2         = {num_or_null(input$ca_surf_m2)},
                statut_id       = {as.integer(input$ca_statut_id)},
                nom             = {val_or_null(input$ca_nom)},
                url             = {val_or_null(input$ca_url)},
                date_rupture    = {rupt_sql$date},
                remarque_rupture= {rupt_sql$remarque},
                type_pratique_agricole_id = {as.integer(input$ca_type_pratique_agricole_id)},
                type_cheptel_id = {as.integer(input$ca_type_cheptel_id)},
                nb_cheptel      = {int_or_null(input$ca_nb_cheptel)},
                modifie_par     = {user_to_db()},
                date_modification = NOW()
              WHERE id = {editing_id()}
            ", .con = conn))
          
              # Re-écrire les liaisons acteurs AGRICOLES
              tx_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_agriculteurs WHERE contrat_agri_id = {cid}
            "))
              act_ids <- input$edit_ca_acteurs_ids %||% integer(0)
              act_ids <- as.integer(act_ids[!is.na(act_ids)])
              if (length(act_ids) > 0) {
                values <- paste0("(", cid, ", ", act_ids, ")", collapse = ",")
                tx_execute(conn, glue::glue("
                INSERT INTO gestcons.contrats_agriculteurs (contrat_agri_id, acteur_id)
                VALUES {DBI::SQL(values)}
                ON CONFLICT DO NOTHING
              "))
              }
            })
            TRUE
          }, error = function(e) {
            showToast("error", "Mise à jour impossible", conditionMessage(e))
            FALSE
          })
          if (!isTRUE(tx_ok)) return(invisible(NULL))
          
          showNotification("Contrat agricole mis à jour.", type = "message")
          log_action(session, current_user_rv, "Mise à jour d'un contrat agricole")
          
          
        }
        # Enregistre aussi la PJ chargée dans la section Documents, le cas échéant.
        .c_upload_pending_doc()
        .reload_contrats()
      })
      
      
      # ----------------- Supprimer (édition) -----------------
      # Supprimer un contrat détruit toutes ses liaisons de parcelles et
      # d'acteurs. Cela partait au premier clic, là où supprimer une action
      # demandait confirmation depuis le début.
      observeEvent(input$delete_contrat, {
        cid <- editing_id(); req(cid)
        ctype <- editing_type() %||% "foncier"
        agri  <- identical(ctype, "agricole")

        tbl_c <- if (agri) "gestcons.contrats_agricoles" else "gestcons.contrats_fonciers"
        tbl_p <- if (agri) "gestcons.contrats_agricoles_parcelles" else "gestcons.contrats_foncier_parcelles"
        tbl_a <- if (agri) "gestcons.contrats_agriculteurs" else "gestcons.contrats_acteurs_fonciers"
        # Les deux tables de liaison ne nomment pas leur clé de la même façon :
        # contrats_foncier_parcelles porte contrat_id, contrats_acteurs_fonciers
        # porte contrat_foncier_id. Côté agricole, les deux portent
        # contrat_agri_id.
        col_p <- if (agri) "contrat_agri_id" else "contrat_id"
        col_a <- if (agri) "contrat_agri_id" else "contrat_foncier_id"

        info <- safe_db_query(con, glue::glue("
          SELECT c.nom,
                 (SELECT count(*) FROM {tbl_p} WHERE {col_p} = {cid}) AS n_parcelles,
                 (SELECT count(*) FROM {tbl_a} WHERE {col_a} = {cid}) AS n_acteurs
            FROM {tbl_c} c WHERE c.id = {cid}
        "))
        req(nrow(info) > 0)
        n_parcelles <- as.integer(info$n_parcelles[1])
        n_acteurs   <- as.integer(info$n_acteurs[1])

        details <- character(0)
        if (n_parcelles > 0) {
          details <- c(details, sprintf(
            "<strong>%d parcelle(s)</strong> y sont rattachées et se retrouveront sans ce contrat.",
            n_parcelles))
        }
        if (n_acteurs > 0) {
          details <- c(details, sprintf(
            "<strong>%d liaison(s) d'acteur</strong> seront supprimées.", n_acteurs))
        }
        confirm_suppression(
          ns,
          quoi = sprintf("le contrat %s <strong>%s</strong>",
                         if (agri) "agricole" else "foncier",
                         htmltools::htmlEscape(info$nom[1] %||% "")),
          confirm_id = "delete_contrat_confirm",
          details = details
        )
      })

      observeEvent(input$delete_contrat_confirm, {
        cid <- editing_id(); req(cid)
        ctype <- editing_type() %||% "foncier"
        
        # poolWithTransaction annule la transaction dès qu'une erreur remonte.
        # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
        # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
        tx_ok <- tryCatch({
          pool::poolWithTransaction(con, function(conn) {
            if (ctype == "foncier") {
              # Suppression des liaisons Parcelles -> Contrat Foncier
              # NOTE : On utilise 'conn' (la transaction) et non 'con' (le pool)
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_foncier_parcelles WHERE contrat_id = {cid}
            "))
              # Suppression des liaisons Acteurs -> Contrat Foncier
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_acteurs_fonciers WHERE contrat_foncier_id = {cid}
            "))
              # Suppression de la table principale
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_fonciers WHERE id = {cid}
            "))
            } else {
              # Suppression des liaisons Parcelles -> Contrat Agricole
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_agricoles_parcelles WHERE contrat_agri_id = {cid}
            "))
              # Suppression des liaisons Acteurs -> Contrat Agricole
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_agriculteurs WHERE contrat_agri_id = {cid}
            "))
              # Suppression de la table principale
              safe_db_execute(conn, glue::glue("
              DELETE FROM gestcons.contrats_agricoles WHERE id = {cid}
            "))
            }
          })
          TRUE
        }, error = function(e) {
          showToast("error", "Suppression impossible", conditionMessage(e))
          FALSE
        })
        if (!isTRUE(tx_ok)) return(invisible(NULL))
        
        reload_contrats_choices()
        showNotification("Contrat supprimé.", type = "warning")
        log_action(session, current_user_rv, "Suppression d'un contrat")
        form_mode("none"); editing_id(NULL); editing_type(NULL)
        removeModal()
        
        .reload_contrats()
      })
      
      
      # =======================================================
      # 🗺️  MODAL CARTE : associer des parcelles au contrat
      # =======================================================
      # Reactifs pour la carte
      cf_map_nonce  <- reactiveVal(0L)
      cf_map_ready  <- reactiveVal(FALSE)
      cf_sites_sf   <- reactiveVal(NULL)      # toutes les parcelles (cadastre + manuelles) des sites concernés (bleu)
      cf_contrat_sf <- reactiveVal(NULL)      # parcelles déjà liées au contrat (rouge)
      cf_sel_codes  <- reactiveVal(character())  # codes sélectionnés (idpar ou "M-<id>")
      
      # Labels fallback si helpers absent
      .cf_build_labels <- function(sfobj, mode = c("site","contrat"), max_prop = 120) {
        mode <- match.arg(mode)
        if (is.null(sfobj) || !nrow(sfobj)) return(character(0))
        n <- nrow(sfobj)
        esc <- htmltools::htmlEscape
        code         <- if ("code" %in% names(sfobj)) as.character(sfobj$code) else as.character(sfobj$parcelle_id)
        site_nom     <- if ("site_nom" %in% names(sfobj)) as.character(sfobj$site_nom) else rep(NA_character_, n)
        commune      <- if ("commune" %in% names(sfobj)) as.character(sfobj$commune) else rep(NA_character_, n)
        surface_m2   <- if ("surface_m2" %in% names(sfobj)) as.numeric(sfobj$surface_m2) else rep(NA_real_, n)
        proprietaires<- if ("proprietaires" %in% names(sfobj)) as.character(sfobj$proprietaires) else rep(NA_character_, n)
        remarque     <- if ("remarque" %in% names(sfobj)) as.character(sfobj$remarque) else rep(NA_character_, n)
        perimetre_id <- if ("perimetre_id" %in% names(sfobj)) sfobj$perimetre_id else rep(NA, n)
        typm         <- ifelse(is.na(perimetre_id), "Cadastral", "Manuel")
        surf_ha <- ifelse(!is.na(surface_m2), paste0(formatC(surface_m2/10000, format = "f", digits = 2, big.mark = "\u00A0"), " ha"), NA_character_)
        too_long   <- !is.na(proprietaires) & nzchar(proprietaires) & (nchar(proprietaires) > max_prop)
        prop_short <- ifelse(too_long, paste0(substr(proprietaires, 1, max_prop), "…"), proprietaires)
        prop_html <- ifelse(!is.na(prop_short) & nzchar(prop_short),
                            paste0("<br/><b>Propriétaire(s)&nbsp;:</b> ",
                                   "<span title='", esc(proprietaires), "'>", esc(prop_short), "</span>"), "")
        rem_html <- ifelse(!is.na(remarque) & nzchar(remarque),
                           paste0("<br/><b>Remarque&nbsp;:</b> ", esc(remarque)), "")
        header <- if (mode == "site") {
          paste0(ifelse(!is.na(site_nom) & nzchar(site_nom), paste0("<b>📍 ", esc(site_nom), "</b>"), "<b>📍 Parcelle</b>"),
                 " — ", esc(code),
                 ifelse(!is.na(typm) & nzchar(typm), paste0(" <i>(", esc(typm), ")</i>"), ""))
        } else {
          paste0("<b>🟥 Contrat</b> — ", esc(code),
                 ifelse(!is.na(site_nom) & nzchar(site_nom), paste0(" <i>(", esc(site_nom), ")</i>"), ""),
                 ifelse(!is.na(typm) & nzchar(typm), paste0(" <i>· ", esc(typm), "</i>"), ""))
        }
        commune_line <- ifelse(!is.na(commune) & nzchar(commune), paste0("<br/><b>Commune&nbsp;:</b> ", esc(commune)), "")
        surf_line    <- ifelse(!is.na(surf_ha) & nzchar(surf_ha), paste0("<br/><b>Surface&nbsp;:</b> ", surf_ha), "")
        paste0(header, commune_line, surf_line, prop_html, rem_html)
      }
      
      # Utilitaires DB -> SF
      .cf_fetch_sites_ids_for_contrat <- function(cid) {
        safe_db_query(con, glue::glue("
        SELECT DISTINCT p.site_id
        FROM gestcons.contrats_foncier_parcelles cfp
        JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id
        WHERE cfp.contrat_id = {cid}
      "))$site_id
      }
      .cf_fetch_sites_parcelles <- function(site_ids) {
        if (length(site_ids) == 0) return(NULL)
        ids_sql <- paste(as.integer(site_ids), collapse = ",")
        q <- glue::glue("
        WITH cad AS (
          SELECT
            1::int                                   AS type_parcelle,
            p.id                                     AS parcelle_id,
            p.site_id                                AS site_id,
            s.libelle                                AS site_nom,
            c.idpar::text                            AS code,
            c.idpar::text                            AS idpar,                     -- ✅ ajouté
            NULL::int                                AS perimetre_id,
            COALESCE(string_agg(DISTINCT dp.ddenom, ', '), '') AS proprietaires,
            c.idcomtxt::text                         AS commune,
            ST_Area(ST_Transform(c.geompar, 2154))::numeric AS surface_m2,
            NULL::text                               AS remarque,
            COALESCE(cf_nom.foncier, '')             AS contrats_fonciers,         -- ✅ ajouté
            COALESCE(ca_nom.agri, '')                AS contrats_agricoles,        -- ✅ ajouté
            CASE WHEN ST_SRID(c.geompar)=4326 THEN c.geompar ELSE ST_Transform(c.geompar,4326) END AS geom
          FROM gestcons.parcelles p
          JOIN gestcons.sites s              ON s.id = p.site_id
          JOIN gestcons.dico_cadastre c      ON c.id = p.parcellaire_id
          LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
        
          -- ✅ blocs d’agrégation des contrats (à insérer tels quels)
          LEFT JOIN (
            SELECT cfp.parcelle_id, string_agg(cf.nom, ', ' ORDER BY cf.nom) AS foncier
            FROM gestcons.contrats_foncier_parcelles cfp
            JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
            GROUP BY cfp.parcelle_id
          ) cf_nom ON cf_nom.parcelle_id = p.id
        
          LEFT JOIN (
            SELECT cap.parcelle_id, string_agg(ca.nom, ', ' ORDER BY ca.nom) AS agri
            FROM gestcons.contrats_agricoles_parcelles cap
            JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
            GROUP BY cap.parcelle_id
          ) ca_nom ON ca_nom.parcelle_id = p.id
        
          WHERE p.type_parcelle_id = 1 AND p.site_id IN ({ids_sql})
          GROUP BY p.id, p.site_id, s.libelle, c.idpar, c.idcomtxt, c.geompar,      -- ⬅️
                   cf_nom.foncier, ca_nom.agri                                      -- ✅ ajouter ces deux colonnes au GROUP BY
        ),
        man AS (
          SELECT
            2::int                                   AS type_parcelle,
            p.id                                     AS parcelle_id,
            p.site_id                                AS site_id,
            s.libelle                                AS site_nom,
            ('M-'||ppm.id)::text                     AS code,
            ('M-'||ppm.id)::text                     AS idpar,                     -- ✅ ajouté
            ppm.id                                   AS perimetre_id,
            NULL::text                               AS proprietaires,
            NULL::text                               AS commune,
            ST_Area(ST_Transform(ppm.geometrie,2154))::numeric AS surface_m2,
            COALESCE(ppm.remarque,'')                AS remarque,
            COALESCE(cf_nom.foncier, '')             AS contrats_fonciers,         -- ✅ ajouté
            COALESCE(ca_nom.agri, '')                AS contrats_agricoles,        -- ✅ ajouté
            CASE WHEN ST_SRID(ppm.geometrie)=4326 THEN ppm.geometrie ELSE ST_Transform(ppm.geometrie,4326) END AS geom
          FROM gestcons.parcelles p
          JOIN gestcons.sites s                         ON s.id = p.site_id
          JOIN gestcons.perimetre_parcellaire_manuel ppm ON ppm.id = p.parcellaire_id
        
          -- ✅ mêmes agrégations
          LEFT JOIN (
            SELECT cfp.parcelle_id, string_agg(cf.nom, ', ' ORDER BY cf.nom) AS foncier
            FROM gestcons.contrats_foncier_parcelles cfp
            JOIN gestcons.contrats_fonciers cf ON cf.id = cfp.contrat_id
            GROUP BY cfp.parcelle_id
          ) cf_nom ON cf_nom.parcelle_id = p.id
        
          LEFT JOIN (
            SELECT cap.parcelle_id, string_agg(ca.nom, ', ' ORDER BY ca.nom) AS agri
            FROM gestcons.contrats_agricoles_parcelles cap
            JOIN gestcons.contrats_agricoles ca ON ca.id = cap.contrat_agri_id
            GROUP BY cap.parcelle_id
          ) ca_nom ON ca_nom.parcelle_id = p.id
        
          WHERE p.type_parcelle_id = 2 AND p.site_id IN ({ids_sql})
        )
        SELECT * FROM cad
        UNION ALL
        SELECT * FROM man
      ")
        tryCatch(sf::st_read(con, query = q, quiet = TRUE), error = function(e) NULL)
      }
      
      # Parcelles d'un contrat (foncier OU agricole) : cadastrales + manuelles,
      # avec agrégation de TOUS les contrats liés à chaque parcelle. Les deux
      # anciennes fonctions (~190 lignes) ne différaient que par la table de
      # liaison pilote (contrats_foncier_parcelles.contrat_id vs
      # contrats_agricoles_parcelles.contrat_agri_id) ; fusionnées ici, les
      # noms historiques restant des wrappers.
      .cf_fetch_contrat_parcelles_kind <- function(cid, kind) {
        if (kind == "F") {
          drv    <- "gestcons.contrats_foncier_parcelles drv"
          drv_fk <- "drv.contrat_id"
        } else {
          drv    <- "gestcons.contrats_agricoles_parcelles drv"
          drv_fk <- "drv.contrat_agri_id"
        }

        # Sous-requêtes d'agrégation communes (tous les contrats de la parcelle)
        agg_joins <- "
          LEFT JOIN (
            SELECT cfp2.parcelle_id, string_agg(cf2.nom, ', ' ORDER BY cf2.nom) AS foncier
            FROM gestcons.contrats_foncier_parcelles cfp2
            JOIN gestcons.contrats_fonciers cf2 ON cf2.id = cfp2.contrat_id
            GROUP BY cfp2.parcelle_id
          ) cf_nom ON cf_nom.parcelle_id = p.id
          LEFT JOIN (
            SELECT cap2.parcelle_id, string_agg(ca2.nom, ', ' ORDER BY ca2.nom) AS agri
            FROM gestcons.contrats_agricoles_parcelles cap2
            JOIN gestcons.contrats_agricoles ca2 ON ca2.id = cap2.contrat_agri_id
            GROUP BY cap2.parcelle_id
          ) ca_nom ON ca_nom.parcelle_id = p.id"

        q <- glue::glue("
        WITH cad AS (
          SELECT
            1::int                                   AS type_parcelle,
            p.id                                     AS parcelle_id,
            p.site_id                                AS site_id,
            s.libelle                                AS site_nom,
            c.idpar::text                            AS code,
            c.idpar::text                            AS idpar,                     -- requis par .cf_make_labels()
            NULL::int                                AS perimetre_id,
            COALESCE(string_agg(DISTINCT dp.ddenom, ', '), '') AS proprietaires,
            c.idcomtxt::text                         AS commune,
            ST_Area(ST_Transform(c.geompar, 2154))::numeric AS surface_m2,
            NULL::text                               AS remarque,
            COALESCE(cf_nom.foncier, '')             AS contrats_fonciers,
            COALESCE(ca_nom.agri, '')                AS contrats_agricoles,
            CASE WHEN ST_SRID(c.geompar)=4326 THEN c.geompar ELSE ST_Transform(c.geompar,4326) END AS geom
          FROM {drv}
          JOIN gestcons.parcelles p           ON p.id = drv.parcelle_id
          JOIN gestcons.sites s               ON s.id = p.site_id
          JOIN gestcons.dico_cadastre c       ON c.id = p.parcellaire_id
          LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
          {agg_joins}
          WHERE {drv_fk} = {cid} AND p.type_parcelle_id = 1
          GROUP BY p.id, p.site_id, s.libelle, c.idpar, c.idcomtxt, c.geompar,
                   cf_nom.foncier, ca_nom.agri
        ),
        man AS (
          SELECT
            2::int                                   AS type_parcelle,
            p.id                                     AS parcelle_id,
            p.site_id                                AS site_id,
            s.libelle                                AS site_nom,
            ('M-'||ppm.id)::text                     AS code,
            ('M-'||ppm.id)::text                     AS idpar,
            ppm.id                                   AS perimetre_id,
            NULL::text                               AS proprietaires,
            NULL::text                               AS commune,
            ST_Area(ST_Transform(ppm.geometrie,2154))::numeric AS surface_m2,
            COALESCE(ppm.remarque,'')                AS remarque,
            COALESCE(cf_nom.foncier, '')             AS contrats_fonciers,
            COALESCE(ca_nom.agri, '')                AS contrats_agricoles,
            CASE WHEN ST_SRID(ppm.geometrie)=4326 THEN ppm.geometrie ELSE ST_Transform(ppm.geometrie,4326) END AS geom
          FROM {drv}
          JOIN gestcons.parcelles p                        ON p.id = drv.parcelle_id
          JOIN gestcons.sites s                            ON s.id = p.site_id
          JOIN gestcons.perimetre_parcellaire_manuel ppm   ON ppm.id = p.parcellaire_id
          {agg_joins}
          WHERE {drv_fk} = {cid} AND p.type_parcelle_id = 2
        )
        SELECT * FROM cad
        UNION ALL
        SELECT * FROM man
      ")
        tryCatch(sf::st_read(con, query = q, quiet = TRUE), error = function(e) NULL)
      }

      .cf_fetch_contrat_parcelles <- function(cid) {
        .cf_fetch_contrat_parcelles_kind(cid, "F")
      }
      
      # Utilitaires DB -> SF pour contrats Agricoles
      .cf_fetch_sites_ids_for_contrat_agri <- function(cid) {
        safe_db_query(con, glue::glue("
        SELECT DISTINCT p.site_id
        FROM gestcons.contrats_agricoles_parcelles cap
        JOIN gestcons.parcelles p ON p.id = cap.parcelle_id
        WHERE cap.contrat_agri_id = {cid}
      "))$site_id
      }
      
      .cf_fetch_contrat_parcelles_agri <- function(cid) {
        .cf_fetch_contrat_parcelles_kind(cid, "A")
      }
      
      .pad_bbox <- function(bb, min_pad = 0.0008) {
        if (is.null(bb)) return(NULL)
        bb <- as.numeric(bb)
        dx <- max(bb[3] - bb[1], min_pad)
        dy <- max(bb[4] - bb[2], min_pad)
        cx <- (bb[1] + bb[3]) / 2
        cy <- (bb[2] + bb[4]) / 2
        c(cx - dx/2, cy - dy/2, cx + dx/2, cy + dy/2)
      }
      
      # Carte
      output$cf_map <- leaflet::renderLeaflet({
        cf_map_nonce()  # rerender à chaque ouverture
        sites_sf <- cf_sites_sf()
        
        m <- leaflet::leaflet() %>%
          leaflet::addMapPane("cf_sites",   zIndex = 430) %>%
          leaflet::addMapPane("cf_contrat", zIndex = 440) %>%
          leaflet::addTiles(group = "OSM") %>%
          leaflet::addTiles(
            urlTemplate = "https://data.geopf.fr/private/wmts?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetTile&apikey=ign_scan_ws&LAYER=GEOGRAPHICALGRIDSYSTEMS.MAPS&EXCEPTIONS=text/xml&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg&STYLE=normal",
            attribution = "IGN Géoportail",
            group = "IGN Cartes"
          ) %>%
          leaflet::addTiles(
            urlTemplate = "https://data.geopf.fr/wmts?SERVICE=WMTS&VERSION=1.0.0&REQUEST=GetTile&LAYER=ORTHOIMAGERY.ORTHOPHOTOS&TILEMATRIXSET=PM&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}&FORMAT=image/jpeg&STYLE=normal",
            attribution = "IGN – Orthophotos",
            group = "IGN Satellites"
          ) %>%
          add_std_draw_toolbar(rectangle = "discret", target_group = "cf_rect") %>%
          leaflet::addLayersControl(
            baseGroups = c("OSM", "IGN Cartes", "IGN Satellites"),
            overlayGroups = c("Parcelles des sites", "Parcelles du contrat"),
            options = leaflet::layersControlOptions(collapsed = FALSE)
          )
        
        if (!is.null(sites_sf) && nrow(sites_sf) > 0) {
          # Labels : helpers.R si dispo, sinon fallback
          lab_fun <- get0(".cf_make_labels", ifnotfound = NULL)
          labels_sites <- if (!is.null(lab_fun)) lab_fun(sites_sf, user_roles()) else .cf_build_labels(sites_sf, "site")
          
          m <- m %>%
            leaflet::addPolygons(
              data = sites_sf,
              group = "Parcelles des sites",
              color = "blue", weight = 1, fillOpacity = 0.3,
              label = labels_sites,
              labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
              highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
              layerId = ~paste0("site-", code),
              options = leaflet::pathOptions(pane = "cf_sites")
            )
        }
        
        # 🔎 Zoom : bbox
        bb <- if (!is.null(sites_sf) && nrow(sites_sf) > 0) sf::st_bbox(sites_sf) else NULL
        if (is.null(bb)) {
          csf <- cf_contrat_sf()
          bb  <- if (!is.null(csf) && nrow(csf) > 0) sf::st_bbox(csf) else NULL
        }
        if (!is.null(bb)) {
          bbn <- c(as.numeric(bb["xmin"]), as.numeric(bb["ymin"]), as.numeric(bb["xmax"]), as.numeric(bb["ymax"]))
          bbp <- .pad_bbox(bbn)
          m <- m %>% leaflet::fitBounds(bbp[1], bbp[2], bbp[3], bbp[4])
        } else {
          m <- m %>% leaflet::setView(lng = 2, lat = 46.5, zoom = 6)
        }
        
        shiny::onFlush(function() cf_map_ready(TRUE), once = TRUE)
        m
      })
      outputOptions(output, "cf_map", suspendWhenHidden = FALSE)
      
      # NB : il y avait ici un session$onFlushed(..., once = FALSE), donc un
      # rappel exécuté après CHAQUE cycle réactif de la session, pour toute sa
      # durée de vie — y compris à chaque déplacement de carte d'un autre
      # onglet. Mesuré : 3 invalidations par pan envoyées à cette carte de
      # modal, pourtant fermée. L'invalidation est désormais faite à
      # l'ouverture du modal uniquement (voir showModal plus bas).
      
      # Redessiner la couche ROUGE (parcelles du contrat) quand prêt ou sélection change
      # Remplacement de l'observeur complet (lignes 1128 à 1205 environ)
      
      # Redessiner la couche ROUGE (parcelles du contrat) quand prêt ou sélection change
      observeEvent(list(cf_sel_codes(), cf_map_ready()), {
        req(cf_map_ready())
        sites_sf <- cf_sites_sf(); req(sites_sf)
        
        # Récupération des droits d'édition pour chaque site concerné
        site_ids_uniques <- unique(sites_sf$site_id)
        can_edit_map <- sapply(site_ids_uniques, .user_can_edit_site)
        names(can_edit_map) <- site_ids_uniques
        
        # Créer une colonne booléenne `can_edit` dans sites_sf (pour l'interactivité)
        sites_sf$can_edit <- as.logical(can_edit_map[as.character(sites_sf$site_id)])
        
        leaflet::leafletProxy(mapId = ns("cf_map"), session = session) %>% 
          leaflet::clearGroup("Parcelles du contrat") %>%
          leaflet::clearGroup("Parcelles des sites") # <--- Nettoyer AVANT de redessiner
        
        # --- 1. Rendu des parcelles des sites (COUCHE BLEUE UNIFIÉE) ---
        
        # Les labels doivent être générés sur toutes les parcelles
        lab_fun <- get0(".cf_make_labels", ifnotfound = NULL)
        labels_sites <- if (!is.null(lab_fun)) lab_fun(sites_sf, user_roles()) else .cf_build_labels(sites_sf, "site")
        
        # Définir le layerId conditionnel : NULL si non éditable, l'ID si éditable.
        sites_sf$map_layer_id <- ifelse(
          sites_sf$can_edit, 
          paste0("site-", sites_sf$code), 
          NA_character_
        )
        
        leaflet::leafletProxy(mapId = ns("cf_map"), session = session) %>%
          leaflet::addPolygons(
            data = sites_sf,
            group = "Parcelles des sites",
            color = "blue", 
            weight = 1, 
            fillColor = "blue",
            fillOpacity = 0.3, # <--- STYLE UNIFIÉ (bleu)
            label = labels_sites,
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~map_layer_id, # <--- Layer ID UNIQUEMENT pour les éditables (NA sinon)
            options = leaflet::pathOptions(pane = "cf_sites")
          )
        
        # --- 2. Rendu de la SELECTION ROUGE (Parcelles du contrat - TOUJOURS éditables) ---
        sel <- cf_sel_codes()
        
        if (!length(sel)) return(invisible(NULL))
        
        # On filtre sites_sf pour obtenir seulement les parcelles sélectionnées
        sub <- sites_sf[sites_sf$code %in% sel, , drop = FALSE]
        if (!nrow(sub)) return(invisible(NULL))
        
        # Labels pour la sélection
        labels_sub <- if (!is.null(lab_fun)) lab_fun(sub, user_roles()) else .cf_build_labels(sub, "contrat")
        
        leaflet::leafletProxy(mapId = ns("cf_map"), session = session) %>%
          leaflet::addPolygons(
            data = sub,
            group = "Parcelles du contrat",
            color = "red", weight = 2, fillOpacity = 0.5,
            label = labels_sub,
            labelOptions = leaflet::labelOptions(direction = "auto", sticky = TRUE, textsize = "12px"),
            highlightOptions = leaflet::highlightOptions(weight = 3, bringToFront = TRUE),
            layerId = ~paste0("contrat-", code), # Doit être cliquable pour être désélectionné
            options = leaflet::pathOptions(pane = "cf_contrat")
          )
      }, ignoreInit = FALSE)
      
      
      # Ouvre le modal et initialise la carte ----
      observeEvent(input$cf_show, {
        raw_id <- as.character(input$cf_show$id)
        req(raw_id)
        
        # Déterminer le type et l'ID
        kind <- if (grepl("^A:", raw_id)) "A" else "F"
        contrat_id <- as.integer(sub("^[FA]:", "", raw_id))
        req(!is.na(contrat_id))
        
        cf_current_contrat_id(contrat_id)
        cf_current_kind(kind)
        
        # Tables DB
        tbl_contrat <- if (kind == "F") "gestcons.contrats_fonciers" else "gestcons.contrats_agricoles"
        # tbl_joint non utilisé ici
        
        # 🔎 Nom du contrat
        res <- tryCatch(
          dbGetQuery(con, glue::glue_sql("SELECT nom FROM {tbl} WHERE id = {contrat_id} LIMIT 1", tbl = DBI::SQL(tbl_contrat), .con = con)),
          error = function(e) data.frame(nom = NA_character_)
        )
        contrat_nom <- if (nrow(res) == 1 && !is.na(res$nom[1]) && nzchar(res$nom[1])) res$nom[1] else paste("Contrat", contrat_id)
        
        # 1) sites concernés = sites des parcelles déjà rattachées
        site_ids <- if (kind == "F") {
          .cf_fetch_sites_ids_for_contrat(contrat_id)
        } else {
          .cf_fetch_sites_ids_for_contrat_agri(contrat_id)
        }
        
        # 2) parcelles bleues = toutes les parcelles de ces sites (cadastre + manuelles)
        sites_sf <- .cf_fetch_sites_parcelles(site_ids)
        
        # 3) parcelles rouges = celles du contrat
        contrat_sf <- if (kind == "F") {
          .cf_fetch_contrat_parcelles(contrat_id)
        } else {
          .cf_fetch_contrat_parcelles_agri(contrat_id)
        }
        
        cf_sites_sf(sites_sf)
        cf_contrat_sf(contrat_sf)
        # 1. Parcelles actuellement liées au contrat (tous sites)
        initial_codes_contrat <- if (!is.null(contrat_sf) && nrow(contrat_sf) > 0) {
          unique(contrat_sf$code) 
        } else {
          character(0)
        }
        
        # 2. Déterminer les sites éditables parmi ceux qui contiennent des parcelles (cf_sites_sf)
        # 🚨 Modification pour utiliser sites_sf pour la liste des sites affichés.
        sites_affiches <- if (!is.null(sites_sf) && nrow(sites_sf) > 0) unique(sites_sf$site_id) else integer(0)
        editable_site_ids <- sites_affiches[sapply(sites_affiches, .user_can_edit_site)]
        
        # 3. Filtrer les parcelles liées au contrat pour ne garder que celles sur des sites éditables.
        #    Nous devons filtrer `sites_sf` qui contient les IDs des sites.
        editable_parcels_in_contract <- sites_sf %>% 
          dplyr::filter(code %in% initial_codes_contrat) %>%
          dplyr::filter(site_id %in% editable_site_ids)
        
        # L'ensemble initial des codes sélectionnés est l'intersection de la sélection actuelle 
        # du contrat ET des parcelles qui sont éditables.
        # Seules ces parcelles seront affichées en rouge et comptées.
        cf_sel_codes(unique(editable_parcels_in_contract$code)) # <--- OK
        
        # 🚨 VÉRIFICATION CLÉ : L'utilisateur a-t-il les droits sur au moins un site affiché ?
        can_interact <- length(editable_site_ids) > 0 # <--- Utiliser la liste des sites éditables réels
        
        cf_map_ready(FALSE)
        cf_map_nonce(isolate(cf_map_nonce()) + 1L)
        
        showModal(modalDialog(
          title = htmltools::HTML(
            paste0("Associer des parcelles au contrat ", if (kind == "A") "Agricole " else "Foncier ",
                   "— <span style='color:var(--c-accent);'>", htmltools::htmlEscape(contrat_nom), "</span>")
          ),
          size = "l", easyClose = TRUE, 
          footer = if (isTRUE(can_interact)) { # <--- AFFICHAGE CONDITIONNEL
            tagList(
              actionButton(ns("save_links"), "💾 Enregistrer la sélection",
                           class = "btn-primary btn-sm"),
              actionButton(ns("clear_links"), "🧹 Vider la sélection", class = "btn-default btn-secondary btn-sm"),
              modalButton("Fermer")
            )
          } else {
            tagList(
              tags$span(class = "text-danger", "⚠️ Lecture seule : pas de droits d'édition sur les sites concernés."),
              tags$span(" ", style = "margin-left:6px;")
            )
          },
          tagList(
            tags$style(HTML(sprintf("
            #%s-container .map-footer { display:flex; align-items:flex-end; gap:12px; padding:8px 0; }
            #%s-container .map-footer .spacer { flex:1; }
            #%s-container .map-footer .btn { margin-bottom:0; }
            #%s-container .map-footer .count { font-weight:600; }
          ", ns("cf_map"), ns("cf_map"), ns("cf_map"), ns("cf_map")))),
            div(id = paste0(ns("cf_map"), "-container"),
                leaflet::leafletOutput(ns("cf_map"), height = 520),
                div(class = "map-footer",
                    span(class = "count", textOutput(ns("sel_count"), inline = TRUE)),
                    span(class = "spacer")
                )
            )
          )
        ))
        # Invalidation immédiate, puis une seconde après le prochain cycle :
        # au moment du showModal le conteneur n'a pas encore sa taille finale.
        session$sendCustomMessage("invalidate-map", list(id = ns("cf_map")))
        session$onFlushed(function() {
          session$sendCustomMessage("invalidate-map", list(id = ns("cf_map")))
        }, once = TRUE)

      })
      
      # Sélection via rectangle
      # Remplacement de l'observeur complet (lignes 1260 à 1272 environ)
      
      # Sélection via rectangle
      observeEvent(input$cf_map_draw_new_feature, {
        feat <- input$cf_map_draw_new_feature
        if (is.null(feat$geometry) || is.null(feat$geometry$coordinates)) return()
        coords <- feat$geometry$coordinates[[1]]
        if (length(coords) < 4) return()
        mat  <- do.call(rbind, lapply(coords, function(pt) c(as.numeric(pt[[1]]), as.numeric(pt[[2]]))))
        rect <- sf::st_sfc(sf::st_polygon(list(mat)), crs = 4326)
        
        sites_sf <- cf_sites_sf(); req(sites_sf, nrow(sites_sf) > 0)
        
        # ⚠️ ÉTAPE 1: Filtrer sites_sf pour ajouter la colonne can_edit si elle n'est pas déjà là (sécurité)
        site_ids_uniques <- unique(sites_sf$site_id)
        can_edit_map <- sapply(site_ids_uniques, .user_can_edit_site)
        names(can_edit_map) <- site_ids_uniques
        sites_sf$can_edit <- as.logical(can_edit_map[as.character(sites_sf$site_id)])
        
        # ÉTAPE 2: Intersection spatiale (identifie TOUTES les parcelles touchées)
        hit   <- sf::st_intersects(sites_sf, rect, sparse = FALSE)[,1]
        
        # ÉTAPE 3: Filtrer les parcelles touchées pour ne garder que les éditables
        codes <- sites_sf$code[which(hit & sites_sf$can_edit)]

        # Même règle que le clic : on n'ajoute pas une parcelle déjà tenue par
        # un autre contrat actif du même type. Le rectangle les écarte en
        # silence serait pire — on dit combien et pourquoi.
        nouvelles <- setdiff(codes, isolate(cf_sel_codes()))
        bloques   <- .cf_codes_bloques(nouvelles)
        if (nrow(bloques) > 0) {
          codes <- setdiff(codes, bloques$code)
          showToast(
            "warning", "Parcelles écartées",
            sprintf(paste0("%d parcelle(s) sont déjà rattachées à un autre ",
                           "contrat %s actif et n'ont pas été sélectionnées."),
                    nrow(bloques), .cf_libelle_type())
          )
        }

        cf_sel_codes(unique(c(isolate(cf_sel_codes()), codes)))
        leaflet::leafletProxy(mapId = ns("cf_map"), session = session) %>% leaflet::clearGroup("cf_rect")
      })
      
      # Parcelles déjà tenues par un AUTRE contrat ACTIF du même type.
      #
      # Règle métier : une parcelle n'a qu'un contrat actif PAR TYPE à un
      # instant donné — au plus un foncier et au plus un agricole. L'édition
      # d'une parcelle la respectait déjà, son sélecteur remplaçant le contrat
      # affiché. Cette carte, elle, ne la gardait pas : le clic était une
      # simple bascule, et sa requête charge toutes les parcelles des sites, y
      # compris celles déjà sous contrat — elle agrège même le nom de leurs
      # contrats, mais seulement pour l'infobulle. Sept parcelles de Pech
      # Saint-Sauveur ont acquis leur second contrat actif par ce chemin.
      #
      # Renvoie un data.frame (code, contrats) pour les codes à écarter.
      .cf_codes_bloques <- function(codes) {
        vide <- data.frame(code = character(0), contrats = character(0),
                           stringsAsFactors = FALSE)
        codes <- unique(codes[!is.na(codes) & nzchar(codes)])
        if (length(codes) == 0) return(vide)

        sites_sf <- cf_sites_sf()
        cid      <- isolate(cf_current_contrat_id())
        kind     <- isolate(cf_current_kind())
        if (is.null(sites_sf) || nrow(sites_sf) == 0 || !isTruthy(cid)) return(vide)

        ids <- unique(sites_sf$parcelle_id[sites_sf$code %in% codes])
        ids <- ids[!is.na(ids)]
        if (length(ids) == 0) return(vide)

        agri <- identical(kind, "A")
        tbl  <- if (agri) "gestcons.contrats_agricoles_parcelles" else "gestcons.contrats_foncier_parcelles"
        tblc <- if (agri) "gestcons.contrats_agricoles"           else "gestcons.contrats_fonciers"
        col  <- if (agri) "contrat_agri_id"                       else "contrat_id"

        res <- safe_db_query(con, glue::glue("
          SELECT c.idpar AS code, string_agg(DISTINCT ct.nom, ', ') AS contrats
            FROM {tbl} l
            JOIN {tblc} ct ON ct.id = l.{col}
                          AND ct.statut_id = {as.integer(statut_actif_id_rv())}
            JOIN gestcons.parcelles_base p ON p.id = l.parcelle_id
            JOIN gestcons.dico_cadastre c  ON c.id = p.parcellaire_id
           WHERE l.parcelle_id IN ({paste(as.integer(ids), collapse = ',')})
             AND l.{col} <> {as.integer(cid)}
           GROUP BY c.idpar
        "))
        if (is.null(res) || nrow(res) == 0) return(vide)
        res[res$code %in% codes, , drop = FALSE]
      }

      .cf_libelle_type <- function() {
        if (identical(isolate(cf_current_kind()), "A")) "agricole" else "foncier"
      }

      # Toggle au clic
      observeEvent(input$cf_map_shape_click, {
        cl <- input$cf_map_shape_click
        req(cl$id, cl$group %in% c("Parcelles des sites", "Parcelles du contrat"))
        code <- sub("^(site-|contrat-)", "", cl$id)
        sel  <- cf_sel_codes()

        # Retirer une parcelle de la sélection ne pose jamais de problème.
        if (code %in% sel) {
          cf_sel_codes(setdiff(sel, code))
          return(invisible(NULL))
        }

        bloques <- .cf_codes_bloques(code)
        if (nrow(bloques) > 0) {
          showToast(
            "warning", "Parcelle déjà sous contrat",
            sprintf(paste0("Elle est rattachée à « %s ». Une parcelle ne peut ",
                           "avoir qu'un contrat %s actif à la fois : terminez ",
                           "ou résiliez l'autre d'abord."),
                    htmltools::htmlEscape(bloques$contrats[1]), .cf_libelle_type())
          )
          return(invisible(NULL))
        }
        cf_sel_codes(unique(c(sel, code)))
      })
      
      # Vider
      observeEvent(input$clear_links, { cf_sel_codes(character(0)) })
      
      # Compteur
      output$sel_count <- renderText({
        n <- length(cf_sel_codes()) # <--- UTILISER LE RÉACTIF cf_sel_codes()
        # On affiche l'information uniquement si la carte est dans le modal
        if (!isTruthy(cf_current_contrat_id())) return("")
        
        paste0(n, ifelse(n > 1, " parcelles sélectionnées", " parcelle sélectionnée"))
      })
      
      # Enregistrer : codes -> ids (via cf_sites_sf)
      observeEvent(input$save_links, {
        
        cid  <- isolate(cf_current_contrat_id())
        kind <- isolate(cf_current_kind())
        
        if (is.na(cid) || is.null(cid)) {
          showNotification("Aucun contrat sélectionné.", type = "error")
          return(invisible(NULL))
        }
        
        tbl_joint <- if (kind == "F") "gestcons.contrats_foncier_parcelles" else "gestcons.contrats_agricoles_parcelles"
        col_id <- if (kind == "F") "contrat_id" else "contrat_agri_id"
        
        sites_sf <- cf_sites_sf()

        # Sites que l'utilisateur peut réellement éditer, parmi ceux affichés.
        # À l'ouverture du modal, cf_sel_codes n'est initialisé qu'avec les
        # parcelles de CES sites : la sauvegarde doit se restreindre au même
        # périmètre. Sans ça, un responsable d'un seul site efface les liaisons
        # du contrat sur les autres sites — qu'il n'a jamais vues sélectionnées.
        editable_site_ids <- if (!is.null(sites_sf) && inherits(sites_sf, "sf") && nrow(sites_sf) > 0) {
          sids <- unique(sites_sf$site_id)
          sids[vapply(sids, function(s) isTRUE(.user_can_edit_site(s)), logical(1))]
        } else {
          integer(0)
        }

        # Aucun site éditable (ou carte non chargée) : ne rien détruire.
        if (length(editable_site_ids) == 0) {
          showNotification("Aucun site modifiable dans cette carte : rien n'a été enregistré.",
                           type = "warning")
          return(invisible(NULL))
        }
        sites_sql <- paste(as.integer(editable_site_ids), collapse = ",")

        # Parcelles sélectionnées, elles aussi restreintes aux sites éditables
        codes <- unique(cf_sel_codes())
        keep  <- sites_sf$code %in% codes & sites_sf$site_id %in% editable_site_ids
        ids   <- unique(sites_sf$parcelle_id[keep])
        ids   <- ids[!is.na(ids)]

        # poolWithTransaction annule la transaction dès qu'une erreur remonte.
        # On l'intercepte ici : sans cela elle romprait la session Shiny, et le
        # code de succès qui suit s'exécuterait comme si l'écriture avait eu lieu.
        tx_ok <- tryCatch({
          pool::poolWithTransaction(con, function(conn) {
            # 1) Liaisons existantes de CE contrat, UNIQUEMENT sur les sites que
            # l'utilisateur peut éditer : les autres sites sont hors de portée de
            # cette carte et doivent rester intacts.
            safe_db_execute(conn, glue::glue("
            DELETE FROM {tbl_joint}
            WHERE {col_id} = {cid}
              AND parcelle_id IN (
                SELECT p.id FROM gestcons.parcelles p WHERE p.site_id IN ({sites_sql})
              )
          "))
          
            # 2) On pose les liaisons retenues.
            #
            # Il y avait ici un second DELETE, « WHERE parcelle_id IN (ids) »,
            # sans filtre sur le contrat : il effaçait les liaisons des AUTRES
            # contrats portant sur ces mêmes parcelles. Rejoué en BEGIN/ROLLBACK
            # sur les données réelles — sauvegarde du contrat 68, site 43 — les
            # 7 liaisons du contrat 11 passaient à 0, sans trace, cette table
            # n'ayant pas de trigger d'audit. Neuf parcelles portent aujourd'hui
            # deux contrats : le cas est atteignable.
            #
            # Il était inutile : l'étape 1 a déjà retiré toutes les liaisons de
            # CE contrat sur les sites éditables, et les parcelles retenues sont
            # elles aussi restreintes à ces sites. La désélection d'une parcelle
            # est donc bien prise en compte par la seule étape 1 — vérifié.
            #
            # ON CONFLICT DO NOTHING : l'insertion devient idempotente. Ici le
            # conflit signifie « la liaison existe déjà », qui est précisément
            # l'état voulu — rien n'est avalé de significatif.
            if (length(ids) > 0) {
              values <- paste0("(", cid, ", ", ids, ")", collapse = ",")
              safe_db_execute(conn, glue::glue("
              INSERT INTO {tbl_joint} ({col_id}, parcelle_id)
              VALUES {DBI::SQL(values)}
              ON CONFLICT DO NOTHING
            "))
            }
          })
          TRUE
        }, error = function(e) {
          showToast("error", "Enregistrement impossible", conditionMessage(e))
          FALSE
        })
        if (!isTRUE(tx_ok)) return(invisible(NULL))
        
        
        showNotification(paste("Liaisons parcelles enregistrées pour le contrat", kind), type = "message")
        log_action(session, current_user_rv,
                   paste0("Contrat ", kind, " : liaisons parcelles mises à jour"))
        
        .reload_contrats()
        
        
        # Recentrer sur les sites concernés (inchangé, mais la vérification ci-dessus protège l'accès à sites_sf)
        if (!is.null(sites_sf) && nrow(sites_sf) > 0) {
          bb <- sf::st_bbox(sites_sf)
          bbn <- c(as.numeric(bb["xmin"]), as.numeric(bb["ymin"]), as.numeric(bb["xmax"]), as.numeric(bb["ymax"]))
          bbp <- .pad_bbox(bbn)
          leaflet::leafletProxy(mapId = ns("cf_map"), session = session) %>% leaflet::fitBounds(bbp[1], bbp[2], bbp[3], bbp[4])
        }
      })
      
      reset <- function() {
        # annule édition/création
        if (exists("form_mode",   inherits = TRUE)) try(form_mode("none"),          silent = TRUE)
        if (exists("editing_id",  inherits = TRUE)) try(editing_id(NULL),           silent = TRUE)
        if (exists("cf_sel_codes",inherits = TRUE)) try(cf_sel_codes(character(0)), silent = TRUE)
        
        # efface la sélection du tableau (ID NU + session)
        prx <- try(DT::dataTableProxy(outputId = "table_contrats", session = session), silent = TRUE)
        if (!inherits(prx, "try-error")) {
          try(DT::selectRows(prx, NULL), silent = TRUE)
          try(DT::selectColumns(prx, NULL), silent = TRUE)
        }
      }
      
      
      return(list(reset = reset))
      
    })
  }