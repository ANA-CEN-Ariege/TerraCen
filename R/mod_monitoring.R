#' Module Monitoring : visualisation de l'activité sur les sites
#' mod_monitoring.R
#'
#' Affiche, en barres groupées (pas mensuel), des métriques d'activité :
#'   - Actions créées        : animation_fonciere + animation_contrat_agricole
#'   - Contrats ajoutés       : contrats_fonciers + contrats_agricoles
#'   - Docs de gestion        : docs_gestion_sites
#'   - Modifications          : gestcons.audit_log (UPDATE) — toutes tables auditées, parcelles comprises
#'   - Connexions (global)    : gestcons.connexion_log — vue globale uniquement
#'   - Questions Analyses     : gestcons.analyses_questions — vue globale uniquement
#'
#' Par défaut : vue GLOBALE (tous sites) sur les 12 derniers mois.
#' Colonne de gauche : sélecteur de site + période modifiable.

# Métriques (ordre = ordre de légende) et couleurs associées
.MONITORING_METRICS <- c(
  "Actions créées"      = "#2563eb",  # bleu
  "Contrats ajoutés"    = "#16a34a",  # vert
  "Docs de gestion"     = "#d97706",  # ambre
  "Modifications"       = "#9333ea",  # violet — depuis audit_log (UPDATE), parcelles comprises
  "Connexions"          = "#64748b",  # gris ardoise — métrique GLOBALE (app), non filtrée par site
  # Teal : distinct des cinq autres teintes, et distinct du gris des
  # connexions, avec lequel elle partage la nature globale.
  "Questions Analyses"  = "#0d9488"   # teal — métrique GLOBALE, sans historique avant 2026-10-27
)

#' -----------------------------
#' UI du module
#' -----------------------------
monitoring_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "flex-container",
        # --- Colonne gauche : filtres ---
        div(class = "sidebar-left-custom",
            titre_page("Activité des sites"),
            selectizeInput(
              ns("site_selector"),
              "🔎 Site (vide = global) :",
              choices  = c("Tous les sites" = "", getOption("gestcons.sites_choices_init", c())),
              selected = "",
              options  = list(diacritics = TRUE, create = FALSE, placeholder = "Tous les sites…")
            ),
            dateRangeInput(
              ns("date_range"),
              "Période :",
              start     = Sys.Date() - 365,
              end       = Sys.Date(),
              min       = "2000-01-01",
              max       = Sys.Date(),
              weekstart = 1,
              language  = "fr",
              separator = " au "
            ),
            actionButton(ns("reset"), "↩️ Réinitialiser (1 an, global)",
                         class = "btn-default btn-secondary", width = "100%"),
            hr(),
            uiOutput(ns("summary"))
        ),
        # --- Colonne droite : graphique ---
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h3(textOutput(ns("title"))),
                plotly::plotlyOutput(ns("plot"), height = "65vh")
            )
        )
    )
  )
}

#' -----------------------------
#' Server du module
#' -----------------------------
monitoring_server <- function(id, con, mode_sombre = shiny::reactive(FALSE)) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    # Libellé du site sélectionné (ou "Tous les sites")
    .site_label <- function(sid) {
      if (is.null(sid) || !nzchar(sid)) return("Tous les sites")
      ch <- getOption("gestcons.sites_choices_init", c())
      nm <- names(ch)[match(sid, as.character(ch))]
      if (length(nm) && !is.na(nm) && nzchar(nm)) nm else paste("Site", sid)
    }

    # Réinitialisation
    observeEvent(input$reset, {
      updateSelectizeInput(session, "site_selector", selected = "")
      updateDateRangeInput(session, "date_range",
                           start = Sys.Date() - 365, end = Sys.Date())
    })

    # ---- Données réactives : data long (mois, metric, n) ----
    monitoring_data <- reactive({
      dr <- input$date_range
      req(dr, length(dr) == 2, !is.na(dr[1]), !is.na(dr[2]), dr[2] >= dr[1])

      # Les requêtes vivent dans helpers.R (monitoring_series) : la page
      # d'accueil montre le même graphique et ne doit pas les réécrire.
      monitoring_series(con, dr[1], dr[2], site_id = input$site_selector)
    })

    # ---- Détail par site (mois × métrique × site × n) pour les tooltips ----
    # Réutilise la logique de filtrage par site, en groupant AUSSI par site.
    # ⚠️ Actions/Contrats : un élément touchant plusieurs sites est compté
    # (DISTINCT) sous CHAQUE site concerné → la somme par site peut dépasser le
    # total de la barre (qui, lui, compte l'élément une seule fois). Docs et
    # Modifications sont rattachés à un seul site → la somme égale le total
    # (les modifs à site_id NULL sont juste absentes du détail par site).
    site_breakdown <- reactive({
      dr <- input$date_range
      req(dr, length(dr) == 2, !is.na(dr[1]), !is.na(dr[2]), dr[2] >= dr[1])
      start_q <- sql_date(dr[1])
      end_q   <- sql_date(dr[2] + 1)

      sid_raw <- input$site_selector
      sid     <- if (is.null(sid_raw) || !nzchar(sid_raw)) NA_integer_ else as.integer(sid_raw)
      has_sid <- !is.na(sid)
      f_p  <- if (has_sid) glue::glue(" AND p.site_id = {sid}")   else ""
      f_dg <- if (has_sid) glue::glue(" AND dgs.site_id = {sid}") else ""
      f_al <- if (has_sid) glue::glue(" AND a.site_id = {sid}")   else ""

      sql_actions <- glue::glue("
        SELECT date_trunc('month', d::timestamp)::date AS mois, site, count(DISTINCT eid)::int AS n FROM (
          SELECT af.date_creation AS d, s.libelle AS site, 'af'||af.id AS eid
            FROM gestcons.animation_fonciere af
            JOIN gestcons.animation_fonciere_parcelles afp ON afp.animation_id = af.id
            JOIN gestcons.parcelles_base p ON p.id = afp.parcelle_id
            JOIN gestcons.sites s ON s.id = p.site_id
           WHERE af.date_creation >= {start_q} AND af.date_creation < {end_q}{f_p}
          UNION ALL
          SELECT aca.date_creation, s.libelle, 'aca'||aca.id
            FROM gestcons.animation_contrat_agricole aca
            JOIN gestcons.animation_contrat_agricole_parcelles acap ON acap.animation_id = aca.id
            JOIN gestcons.parcelles_base p ON p.id = acap.parcelle_id
            JOIN gestcons.sites s ON s.id = p.site_id
           WHERE aca.date_creation >= {start_q} AND aca.date_creation < {end_q}{f_p}
        ) t GROUP BY 1, 2 ORDER BY 1, 2")

      sql_contrats <- glue::glue("
        SELECT date_trunc('month', d::timestamp)::date AS mois, site, count(DISTINCT eid)::int AS n FROM (
          SELECT cf.date_creation AS d, s.libelle AS site, 'cf'||cf.id AS eid
            FROM gestcons.contrats_fonciers cf
            JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.contrat_id = cf.id
            JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id
            JOIN gestcons.sites s ON s.id = p.site_id
           WHERE cf.date_creation >= {start_q} AND cf.date_creation < {end_q}{f_p}
          UNION ALL
          SELECT ca.date_creation, s.libelle, 'ca'||ca.id
            FROM gestcons.contrats_agricoles ca
            JOIN gestcons.contrats_agricoles_parcelles cap ON cap.contrat_agri_id = ca.id
            JOIN gestcons.parcelles p ON p.id = cap.parcelle_id
            JOIN gestcons.sites s ON s.id = p.site_id
           WHERE ca.date_creation >= {start_q} AND ca.date_creation < {end_q}{f_p}
        ) t GROUP BY 1, 2 ORDER BY 1, 2")

      sql_docs <- glue::glue("
        SELECT date_trunc('month', dgs.date_creation::timestamp)::date AS mois, s.libelle AS site, count(*)::int AS n
        FROM gestcons.docs_gestion_sites dgs
        JOIN gestcons.sites s ON s.id = dgs.site_id
        WHERE dgs.date_creation >= {start_q} AND dgs.date_creation < {end_q}{f_dg}
        GROUP BY 1, 2 ORDER BY 1")

      sql_modif <- glue::glue("
        SELECT date_trunc('month', a.changed_at::timestamp)::date AS mois, s.libelle AS site, count(*)::int AS n
        FROM gestcons.audit_log a
        JOIN gestcons.sites s ON s.id = a.site_id
        WHERE a.action = 'UPDATE'
          AND a.changed_at >= {start_q} AND a.changed_at < {end_q}{f_al}
        GROUP BY 1, 2 ORDER BY 1")

      one <- function(sql, metric) {
        df <- safe_db_query(con, sql)
        if (is.null(df) || nrow(df) == 0) return(NULL)
        data.frame(metric = metric, mois = as.Date(df$mois),
                   site = as.character(df$site), n = as.integer(df$n),
                   stringsAsFactors = FALSE)
      }
      out <- do.call(rbind, list(
        one(sql_actions,  "Actions créées"),
        one(sql_contrats, "Contrats ajoutés"),
        one(sql_docs,     "Docs de gestion"),
        one(sql_modif,    "Modifications")
      ))
      if (is.null(out)) {
        out <- data.frame(metric = character(), mois = as.Date(character()),
                          site = character(), n = integer(), stringsAsFactors = FALSE)
      }
      out
    })

    # Construit le contenu HTML du tooltip d'une barre (total + top 8 sites).
    .build_hover <- function(metric, mois, total, bd) {
      mlab   <- format(mois, "%b %Y")
      header <- sprintf("<b>%s</b><br>%s<br>Total : <b>%d</b>", metric, mlab, total)
      rows <- bd[bd$metric == metric & bd$mois == mois, c("site", "n"), drop = FALSE]
      if (nrow(rows) == 0) return(header)
      rows <- rows[order(-rows$n), , drop = FALSE]
      top  <- utils::head(rows, 8L)
      lines <- paste(sprintf("• %s : %d", top$site, top$n), collapse = "<br>")
      extra <- ""
      if (nrow(rows) > 8L) {
        rest <- rows$n[9:nrow(rows)]
        extra <- sprintf("<br>+ %d autres sites : %d", length(rest), sum(rest))
      }
      paste0(header, "<br>──────────<br>", lines, extra)
    }

    # ---- Titre ----
    output$title <- renderText({
      paste0("Activité — ", .site_label(input$site_selector))
    })

    # ---- Graphique interactif (barres groupées : 4 barres par mois) ----
    output$plot <- plotly::renderPlotly({
      d  <- monitoring_data()
      bd <- site_breakdown()

      # Axe X catégoriel = mois, en ordre chronologique
      lev <- format(sort(unique(d$mois)), "%b %Y")
      d$mois_lab <- factor(format(d$mois, "%b %Y"), levels = lev)

      # Tooltip par barre : total + détail par site (top 8 + autres)
      d$hover <- mapply(
        function(m, mo, n) .build_hover(m, as.Date(mo, origin = "1970-01-01"), n, bd),
        as.character(d$metric), d$mois, d$n, USE.NAMES = FALSE
      )

      hab <- plotly_habillage(mode_sombre())

      plotly::plot_ly(
        d, x = ~mois_lab, y = ~n, color = ~metric,
        # couleurs restreintes aux métriques présentes (Connexions absente si site filtré)
        colors = unname(.MONITORING_METRICS[levels(d$metric)]),
        type = "bar", text = ~hover, hoverinfo = "text"
      ) %>%
        plotly::layout(
          barmode = "group",
          paper_bgcolor = hab$fond, plot_bgcolor = hab$fond,
          font = list(color = hab$texte),
          xaxis = list(title = "", tickangle = -45,
                       categoryorder = "array", categoryarray = lev,
                       gridcolor = hab$grille),
          yaxis = list(title = "Nombre", rangemode = "tozero",
                       gridcolor = hab$grille, zerolinecolor = hab$grille),
          legend = list(orientation = "h", x = 0, y = 1.08, title = list(text = "")),
          hoverlabel = list(align = "left", bgcolor = hab$survol,
                            font = list(color = hab$texte)),
          margin = list(t = 30)
        ) %>%
        plotly::config(displayModeBar = FALSE, locale = "fr")
    })

    # ---- Résumé (totaux sur la période) ----
    output$summary <- renderUI({
      d <- monitoring_data()
      tot <- tapply(d$n, d$metric, sum)
      cols <- .MONITORING_METRICS
      # N'affiche que les métriques présentes : Connexions absente si un site est
      # filtré (levels(d$metric) ne contient alors que les 4 métriques par site).
      items <- lapply(levels(d$metric), function(m) {
        v <- tot[[m]]; if (is.null(v) || is.na(v)) v <- 0L
        # Connexions = métrique globale (non filtrée par site) -> on le signale.
        lbl <- if (identical(m, "Connexions")) paste0(m, " (global)") else m
        tags$li(
          tags$span(style = sprintf(
            "display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;background:%s;",
            cols[[m]])),
          sprintf("%s : ", lbl), tags$b(v)
        )
      })
      tagList(
        tags$b("Totaux sur la période :"),
        tags$ul(style = "list-style:none;padding-left:0;margin-top:6px;", items)
      )
    })
  })
}
