# mod_accueil.R
#
# Page d'accueil : ce que l'on voit en arrivant dans l'application, avant
# d'entrer dans un onglet.
#
# À droite, la carte des sites. Les cercles y sont volontairement INERTES :
# aucun observateur de clic n'est branché, seule l'infobulle au survol donne
# le nom du site, son responsable et son statut. C'est une vue d'ensemble, pas
# un point d'entrée d'édition — on choisit son site dans l'onglet voulu.
#
# À gauche, les chiffres clés et deux graphiques. Le graphique d'activité est
# EXACTEMENT celui de l'onglet Activité : il appelle monitoring_series()
# (helpers.R), qui sert aussi ce module.

accueil_ui <- function(id) {
  ns <- NS(id)

  tagList(
    # tc-accueil élargit la colonne gauche : deux graphiques ne sont pas
    # lisibles dans les 260 px du rail habituel.
    div(class = "flex-container tc-accueil",
        div(class = "sidebar-left-custom",
            titre_page("Accueil"),
            uiOutput(ns("chiffres")),
            div(class = "tc-accueil-bloc",
                h5("Évolution de la maîtrise foncière"),
                plotly::plotlyOutput(ns("evolution"), height = "220px")
            ),
            div(class = "tc-accueil-bloc",
                h5("Activité des douze derniers mois"),
                plotly::plotlyOutput(ns("activite"), height = "240px")
            ),
            uiOutput(ns("maitrise"))
        ),
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h4("🗺️ Les sites du CEN Ariège"),
                # La carte occupe toute la zone utile, moins le titre qui la
                # surmonte (34 px mesurés, marges comprises).
                leafletOutput(ns("map"), height = "calc(var(--h-travail) - 34px)")
            )
        )
    )
  )
}

accueil_server <- function(id, con, mode_sombre = shiny::reactive(FALSE)) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    .nombre <- function(x, chiffres = 0) {
      if (is.null(x) || length(x) == 0 || is.na(x[1])) return("—")
      format(round(as.numeric(x[1]), chiffres), big.mark = " ",
             decimal.mark = ",", nsmall = chiffres, scientific = FALSE,
             trim = TRUE)
    }

    .carte_chiffre <- function(valeur, unite, libelle, precision) {
      div(class = "tc-kpi",
          span(class = "tc-kpi-val", .nombre(valeur)),
          if (nzchar(unite)) span(class = "tc-kpi-unite", unite),
          div(class = "tc-kpi-lbl", libelle),
          if (!is.null(precision)) div(class = "tc-kpi-sous", precision))
    }

    # ---- Chiffres clés --------------------------------------------------
    # « En gestion » = parcelles de site (hors continuité) couvertes par un
    # contrat foncier ACTIF — choix de l'utilisateur, le 2026-10-26, parmi les
    # trois définitions possibles (3 267 ha ici ; 4 063 ha si l'on prenait
    # toutes les parcelles des sites gérés ; 7 575 ha pour tous les sites).
    # La ligne de référence sous le chiffre ne compare donc qu'aux sites qui
    # ont un contrat actif : y mêler les 125 autres sites n'aurait aucun sens.
    chiffres_rv <- reactive({
      safe_db_query(con, glue::glue("
        WITH sites_cen AS (
          SELECT id FROM gestcons.sites
          WHERE type_site_id = {TYPE_SITE_CONSERVATOIRE} AND actif
        ),
        parc AS (
          SELECT pb.site_id,
                 pb.surf_parc_maitrise_m2 AS m2,
                 EXISTS (
                   SELECT 1 FROM gestcons.contrats_foncier_parcelles j
                   JOIN gestcons.contrats_fonciers c ON c.id = j.contrat_id
                   WHERE j.parcelle_id = pb.id
                     AND c.statut_id = {STATUT_CONTRAT_ACTIF}
                 ) AS sous_contrat
          FROM gestcons.parcelles_base pb
          JOIN sites_cen s ON s.id = pb.site_id
          WHERE NOT pb.perimetre
        ),
        parc2 AS (   -- le site entier est-il « géré » ? (au moins une parcelle sous contrat)
          SELECT site_id, m2, sous_contrat,
                 bool_or(sous_contrat) OVER (PARTITION BY site_id) AS site_gere
          FROM parc
        )
        SELECT (SELECT count(*) FROM sites_cen)::int                    AS nb_sites,
               count(DISTINCT site_id) FILTER (WHERE site_gere)::int    AS nb_sites_geres,
               COALESCE(sum(m2) FILTER (WHERE site_gere), 0) / 10000.0  AS ha_sites_geres,
               COALESCE(sum(m2) FILTER (WHERE sous_contrat), 0) / 10000.0 AS ha_geres
        FROM parc2"))
    })

    output$chiffres <- renderUI({
      d <- chiffres_rv()
      if (is.null(d) || nrow(d) == 0) return(div(class = "text-muted", "Chiffres indisponibles."))
      tagList(
        .carte_chiffre(d$nb_sites, "", "sites conservatoires",
                       sprintf("dont %s avec un contrat foncier actif",
                               .nombre(d$nb_sites_geres))),
        .carte_chiffre(d$ha_geres, "ha", "surface en gestion",
                       sprintf("sur %s ha rattachés à ces %s sites",
                               .nombre(d$ha_sites_geres), .nombre(d$nb_sites_geres)))
      )
    })

    # ---- Évolution : cumul des sites et des hectares ---------------------
    # L'axe du temps est la date de DÉBUT du plus ancien contrat foncier actif
    # de chaque parcelle. sites.date_crea_site ne convient pas : 100 des 174
    # sites y portent la même journée (2026-10-08), trace d'une reprise de
    # données, ce qui écraserait toute la courbe sur une seule année.
    evolution_rv <- reactive({
      safe_db_query(con, glue::glue("
        WITH parc AS (
          SELECT pb.id, pb.site_id, pb.surf_parc_maitrise_m2 AS m2,
                 min(c.date_debut)::date AS debut
          FROM gestcons.parcelles_base pb
          JOIN gestcons.sites s ON s.id = pb.site_id
                               AND s.type_site_id = {TYPE_SITE_CONSERVATOIRE}
          JOIN gestcons.contrats_foncier_parcelles j ON j.parcelle_id = pb.id
          JOIN gestcons.contrats_fonciers c ON c.id = j.contrat_id
                               AND c.statut_id = {STATUT_CONTRAT_ACTIF}
          WHERE NOT pb.perimetre AND c.date_debut IS NOT NULL
          GROUP BY pb.id, pb.site_id, pb.surf_parc_maitrise_m2
        ),
        site_an AS (SELECT site_id, min(extract(year from debut))::int AS y FROM parc GROUP BY site_id),
        ha_an   AS (SELECT extract(year from debut)::int AS y, sum(m2)/10000.0 AS ha FROM parc GROUP BY 1),
        annees  AS (
          SELECT generate_series(min(y), max(y)) AS y
          FROM (SELECT y FROM site_an UNION SELECT y FROM ha_an) u
        )
        SELECT a.y::int AS annee,
               sum(COALESCE(s.n, 0)) OVER (ORDER BY a.y)::int AS sites,
               sum(COALESCE(h.ha, 0)) OVER (ORDER BY a.y)     AS ha
        FROM annees a
        LEFT JOIN (SELECT y, count(*) AS n FROM site_an GROUP BY y) s ON s.y = a.y
        LEFT JOIN ha_an h ON h.y = a.y
        ORDER BY a.y"))
    })

    output$evolution <- plotly::renderPlotly({
      d <- evolution_rv()
      validate(need(!is.null(d) && nrow(d) > 0, "Aucun contrat daté."))
      hab <- plotly_habillage(mode_sombre())
      plotly::plot_ly(d) %>%
        plotly::add_trace(
          x = ~annee, y = ~ha, type = "scatter", mode = "lines",
          name = "Surface (ha)", fill = "tozeroy",
          line = list(color = "#16a34a", width = 2),
          fillcolor = "rgba(22,163,74,.15)",
          hovertemplate = "%{y:.0f} ha en %{x}<extra></extra>"
        ) %>%
        plotly::add_trace(
          x = ~annee, y = ~sites, type = "scatter", mode = "lines+markers",
          name = "Sites", yaxis = "y2",
          line = list(color = "#2563eb", width = 2),
          marker = list(size = 4),
          hovertemplate = "%{y} sites en %{x}<extra></extra>"
        ) %>%
        plotly::layout(
          margin = list(l = 45, r = 45, t = 10, b = 30),
          paper_bgcolor = hab$fond, plot_bgcolor = hab$fond,
          font   = list(color = hab$texte),
          xaxis  = list(title = "", dtick = 5, gridcolor = hab$grille,
                        zerolinecolor = hab$grille),
          yaxis  = list(title = "ha", rangemode = "tozero",
                        gridcolor = hab$grille, zerolinecolor = hab$grille),
          yaxis2 = list(title = "sites", overlaying = "y", side = "right",
                        rangemode = "tozero", showgrid = FALSE),
          legend = list(orientation = "h", x = 0, y = 1.15),
          hovermode = "x unified",
          hoverlabel = list(bgcolor = hab$survol, font = list(color = hab$texte))
        ) %>%
        plotly::config(displayModeBar = FALSE, locale = "fr")
    })

    # ---- Activité : le graphique de l'onglet Activité, en vue globale ----
    activite_rv <- reactive({
      monitoring_series(con, Sys.Date() - 365, Sys.Date())
    })

    output$activite <- plotly::renderPlotly({
      d <- activite_rv()
      validate(need(!is.null(d) && nrow(d) > 0, "Aucune activité sur la période."))

      # Axe X catégoriel en ordre chronologique : même construction que
      # l'onglet Activité, pour que les deux graphiques se ressemblent.
      lev <- format(sort(unique(d$mois)), "%b %Y")
      d$mois_lab <- factor(format(d$mois, "%b %Y"), levels = lev)
      hab <- plotly_habillage(mode_sombre())

      plotly::plot_ly(
        d, x = ~mois_lab, y = ~n, color = ~metric,
        colors = unname(.MONITORING_METRICS[levels(d$metric)]),
        type = "bar",
        hovertemplate = "%{y}<extra>%{fullData.name}</extra>"
      ) %>%
        plotly::layout(
          barmode = "group",
          margin  = list(l = 40, r = 10, t = 10, b = 60),
          paper_bgcolor = hab$fond, plot_bgcolor = hab$fond,
          font    = list(color = hab$texte),
          xaxis   = list(title = "", tickangle = -45,
                         categoryorder = "array", categoryarray = lev,
                         gridcolor = hab$grille),
          yaxis   = list(title = "", rangemode = "tozero",
                         gridcolor = hab$grille, zerolinecolor = hab$grille),
          legend  = list(orientation = "h", x = 0, y = 1.18,
                         font = list(size = 10), title = list(text = "")),
          hoverlabel = list(bgcolor = hab$survol, font = list(color = hab$texte))
        ) %>%
        plotly::config(displayModeBar = FALSE, locale = "fr")
    })

    # ---- Types de maîtrise ------------------------------------------------
    # code_mfu1 du référentiel FCEN : P = propriété, O = obligation réelle
    # environnementale, L et C = contrats de gestion (≥ et < 18 ans). Les deux
    # derniers sont regroupés sous « conventions de gestion ».
    maitrise_rv <- reactive({
      safe_db_query(con, glue::glue("
        SELECT t.code_mfu1 AS code, count(*)::int AS n
        FROM gestcons.contrats_fonciers c
        JOIN gestcons.dico_type_contrat_foncier t ON t.id = c.type_maitrise_id
        WHERE c.statut_id = {STATUT_CONTRAT_ACTIF}
        GROUP BY 1"))
    })

    output$maitrise <- renderUI({
      d <- maitrise_rv()
      if (is.null(d)) return(NULL)
      n <- function(codes) sum(d$n[d$code %in% codes], na.rm = TRUE)
      lignes <- list(
        c("Conventions de gestion", n(c("L", "C"))),
        c("Obligations réelles environnementales", n("O")),
        c("Acquisitions", n("P"))
      )
      div(class = "tc-accueil-bloc",
          h5("Contrats fonciers actifs"),
          tags$table(class = "tc-maitrise",
                     lapply(lignes, function(l)
                       tags$tr(tags$td(l[1]), tags$td(class = "tc-maitrise-n", l[2])))))
    })

    # ---- Carte ------------------------------------------------------------
    output$map <- renderLeaflet({
      init_map_base() %>%
        addLayersControl(
          baseGroups    = c("OpenStreetMap", "IGN Cartes", "IGN Satellites"),
          overlayGroups = "Sites existants",
          options       = layersControlOptions(collapsed = FALSE)
        )
    })

    # Les cercles ont un rayon en mètres : il doit suivre le zoom, comme dans
    # les autres onglets. Aucun observateur de clic n'est branché — c'est
    # voulu : la carte informe, elle ne sélectionne pas.
    observe({
      z <- input$map_zoom %||% MAP_DEFAULT_ZOOM
      draw_circles(con, map_id = ns("map"), zoom = z, details = TRUE)
    })
  })
}
