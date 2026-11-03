#' =============================================================================
#' Module « Stratégie foncière » — secteurs d'intervention prioritaire
#' =============================================================================
#' Un secteur d'intervention prioritaire est une ZONE DE PROSPECTION : des
#' parcelles sans contrat, repérées comme pouvant devenir un futur site
#' conservatoire. Il est stocké comme un site ordinaire de `gestcons.sites`,
#' distingué par `type_site_id = 2`, et ses parcelles seront des lignes de
#' `parcelles_base` portant `perimetre = true`.
#'
#' Ce module est volontairement DISTINCT de mod_sites : il s'appuie sur les
#' mêmes helpers partagés mais n'y injecte aucune condition, pour qu'un défaut
#' ici ne puisse pas atteindre l'onglet Sites, qui porte le cœur du métier.
#'
#' Étape 2 : l'onglet, le formulaire et le cycle de vie d'un secteur. La carte
#' et la gestion des parcelles viennent ensuite.
#' =============================================================================

# Couleurs des parcelles d'un secteur, par priorité. Distinctes du vocabulaire
# de l'onglet Sites (bleu = parcelle du site, orange = continuité du site conservatoire) : une
# zone de prospection se lit d'abord par son degré d'urgence.
# Deux intensités d'une même teinte : un degré d'urgence se lit mieux dans une
# famille que dans deux couleurs étrangères.
#
# La priorité 1 reprend EXACTEMENT le bleu des parcelles sous contrat actif de
# l'onglet Sites — d'où la référence à la constante partagée plutôt qu'une
# copie de son code hexadécimal, pour qu'elles ne puissent pas diverger. La
# priorité 2 est LA MÊME TEINTE, simplement plus claire : #5891E5 est le bleu
# de la priorité 1 à la même tonalité (216°), saturation abaissée d'un tiers.
#
# ⚠️ UNE SEULE OPACITÉ pour les deux, et c'est délibéré. Les polygones sont
# dessinés sans bordure (weight = 0) : ce qui tient lieu de contour, c'est le
# trait brun du CADASTRE qui transparaît dessous. Un remplissage moins opaque
# le laisse ressortir, et la parcelle semble alors porter un contour plus
# marqué que sa voisine — deux opacités différentes donnaient donc deux
# épaisseurs de trait apparentes. La nuance est portée par la seule couleur.
#
# L'opacité vit ICI et non dans le code de dessin : la carte et la légende
# doivent afficher exactement la même chose, et la valeur était écrite en dur
# aux deux endroits, donc libre de diverger au premier réglage.
#
# Mesuré : à 0,70 sur fond clair, la priorité 1 rend #548EE3 (luminance
# 0,268) et la priorité 2 #8AB2ED (0,434) — 54 sur 255 d'écart. C'est bien
# au-dessus des 16 qui rendaient indiscernables les deux bleus d'origine.
#
# Aucun de ces tons n'entre en conflit avec le ROUGE des calques de sélection
# — #ef4444 pour la sélection cadastrale, #dc2626 pour l'anneau du secteur
# sélectionné — ni avec le brun du cadastre.
COLORS_PRIORITE <- list(
  p1      = COLORS_PARCELLES$actif_fill, # priorité 1 — le bleu des parcelles sous contrat
  p2      = "#5891E5",                   # priorité 2 — même teinte, plus claire
  sans    = "#9ca3af",                   # repli, hors légende — gris
  opacite = 0.70                         # une seule, carte ET légende : cf. ci-dessus
)

# ----------------------------------------------------------------------------
# ⚠️ VERRUE TEMPORAIRE — à retirer d'un bloc
#
# Un utilisateur nommément désigné voit la priorité 2 en rose vif au lieu du
# bleu clair. Demandé explicitement, et assumé comme provisoire : c'est la
# SEULE règle d'affichage de l'application qui dépende de QUI regarde.
# Il est désigné par son identifiant dans gestcons.dico_utilisateur, et non par
# son adresse : aucune adresse personnelle ne doit figurer dans le code publié.
#
# Pour l'enlever : supprimer ce bloc et les trois appels à `.couleur_p2()`
# dans le module, qui redeviennent `COLORS_PRIORITE$p2`. Rien d'autre ne s'y
# rattache.
#
# #ff2d95 mesuré à 0,70 d'opacité sur fond clair : rendu #FF6CB5, à 171 sur
# 255 de la priorité 1 — contre 54 pour le bleu clair habituel. Il reste à
# 113 du rouge de la sélection cadastrale (#ef4444) et à 143 de l'anneau du
# secteur sélectionné (#dc2626), donc sans confusion possible avec eux.
STRATEGIE_P2_ROSE_POUR   <- 7L   # identifiant dans gestcons.dico_utilisateur
STRATEGIE_P2_ROSE_TEINTE <- "#ff2d95"
# ----------------------------------------------------------------------------

# Couleur telle qu'elle apparaît une fois mélangée au fond de carte clair.
# Sert à ce que les pastilles de la légende montrent exactement ce que la carte
# dessine, opacité de remplissage comprise.
.sur_fond_clair <- function(hex, alpha) {
  c <- grDevices::col2rgb(hex)[, 1]
  grDevices::rgb(matrix(round(alpha * c + (1 - alpha) * 255), nrow = 1),
                 maxColorValue = 255)
}

# TYPE_SITE_SECTEUR et TYPE_SITE_CONSERVATOIRE sont définis dans helpers.R,
# chargé en premier : la couche des sites voisins en a besoin elle aussi.

#' -----------------------------
#' UI du module
#' -----------------------------
strategie_ui <- function(id) {
  ns <- NS(id)
  # Même structure que sites_ui : colonne de gauche (sélecteur, boutons,
  # résumé), carte à droite. Le formulaire s'ouvre en modale, comme pour un
  # site — il n'occupe pas la colonne.
  tagList(
    div(
      class = "flex-container",
      div(
        class = "sidebar-left-custom",
        titre_page("Stratégie foncière"),
        selectizeInput(
          ns("secteur_selector"),
          "🔎 Sélectionner un secteur :",
          choices  = c(" " = ""),
          selected = "",
          options  = list(diacritics = TRUE, create = FALSE, placeholder = "Tapez un nom…")
        ),
        actionButton(ns("reset_secteur"), "❌ Réinitialiser",       class = "btn-default btn-secondary"),
        actionButton(ns("add_secteur"),   "➕ Ajouter un secteur",  class = "btn-success"),
        hr(),
        uiOutput(ns("resume_secteur")),
        br(),
        conditionalPanel(
          condition = sprintf("typeof input['%s'] !== 'undefined' && input['%s'] !== ''",
                              ns("secteur_selector"), ns("secteur_selector")),
          actionButton(ns("edit_secteur"), "✏️ Modifier ce secteur", width = "100%",
                     class = "btn-primary")
        ),
        br(),
        # Un champ où l'on tape directement, comme le sélecteur de secteur, et
        # non une liste qui ouvre une zone de recherche au-dessous : demandé
        # par l'utilisateur. Même champ et même zoom que l'onglet Sites.
        selectizeInput(
          ns("commune_selector"),
          "Zoomer sur une commune :",
          choices  = c(" " = ""),
          selected = "",
          options  = list(diacritics = TRUE, create = FALSE, placeholder = "Tapez un nom…")
        ),
        hr(),
        uiOutput(ns("strategie_helper_text"))
      ),
      div(
        class = "right-rail",
        div(
          class = "right-rail-inner",
          div(
            class = "tc-page-carte",
            leafletOutput(ns("map"), height = "calc(var(--h-carte))"),
            uiOutput(ns("msg_associer_parcelles")),
            div(class = "tc-page-bas",
                uiOutput(ns("map_footer")))
          )
        )
      )
    )
  )
}

#' -----------------------------
#' Server du module
#' -----------------------------
strategie_server <- function(id, con, dico_type_milieu, dico_geol,
                             dico_nature_perimetre, dico_echelle, dico_precision,
                             dico_utilisateur_rv, current_user_rv, user_roles,
                             dico_cen, dico_statut_site, selected_site_rv,
                             sites_shared = NULL, map_view_rv = NULL,
                             contrats_update_trigger = NULL,
                             acteurs_existants = NULL,
                             zones_protection_data = NULL,
                             dico_accessibilite,
                             liste_communes) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    user_to_db <- make_user_to_db(current_user_rv)

    #' Retour à l'emprise de l'Ariège, comme le fait l'onglet Sites quand on
    #' quitte un site. Les trois constantes sont celles de helpers.R, partagées
    #' par tous les onglets.
    .vue_ariege <- function() {
      leafletProxy(ns("map"), session = session) %>%
        setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = MAP_DEFAULT_ZOOM)
    }


    # ⚠️ VERRUE TEMPORAIRE, cf. STRATEGIE_P2_ROSE_POUR en tête de fichier.
    # Point UNIQUE où la teinte de la priorité 2 est décidée : la carte, la
    # légende et le panneau de détail y passent tous les trois, sinon ils se
    # contrediraient à l'écran.
    .couleur_p2 <- function() {
      u <- tryCatch(current_user_rv(), error = function(e) NULL)
      uid <- if (!is.null(u) && nrow(u) > 0) suppressWarnings(as.integer(u$id[1])) else NA_integer_
      if (identical(uid, STRATEGIE_P2_ROSE_POUR))
        STRATEGIE_P2_ROSE_TEINTE
      else COLORS_PRIORITE$p2
    }

    # Même recherche que mod_sites : le libellé plutôt que l'identifiant en
    # dur, le dictionnaire pouvant être renuméroté.
    type_acteur_proprio_id <- safe_db_query(con, "
      SELECT id FROM gestcons.dico_type_acteur
      WHERE lower(unaccent(libelle)) = lower(unaccent('Propriétaire'))
      LIMIT 1")$id

    # Cinq colonnes de `sites` sont NOT NULL SANS valeur par défaut :
    # type_milieu_id, geol_id, nature_perimetre_id, echelle_num_id et
    # precision_num_site_id. Elles sont donc OBLIGATOIRES dans le formulaire —
    # pas d'option vide — et pré-remplies avec le repli le plus honnête pour un
    # secteur qui n'a encore fait l'objet d'aucune étude.
    .premier <- function(x, repli) if (length(x) > 0 && !is.na(x[1])) x[1] else repli
    DEFAUT_TYPE_MILIEU  <- 0L   # « inconnu »
    DEFAUT_NATURE_PERIM <- 0L   # « inconnue »
    DEFAUT_GEOL         <- 3L   # « aucune évaluation du patrimoine géologique »
    DEFAUT_ECHELLE      <- .premier(dico_echelle$id[dico_echelle$libelle == "inconnue"], 0L)
    # precision_num_site_id est un VARCHAR (codes « DC », « NE »…), pas un entier.
    DEFAUT_PRECISION    <- .premier(dico_precision$id[dico_precision$libelle == "Non estimée"],
                                    dico_precision$id[1])

    secteur_id      <- reactiveVal(NULL)
    refresh_trigger <- reactiveVal(0)

    # Sélection cadastrale en cours et cache de la couche, repris tels quels du
    # fonctionnement de l'onglet Sites (helpers partagés).
    selection            <- reactiveVal(character(0))
    parcelles_cache      <- reactiveVal(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
    parcelles_cache_bbox <- reactiveVal(NULL)
    parcelle_editee      <- reactiveVal(NULL)   # pid ouvert dans la modale
    parcelle_editee_lbl  <- reactiveVal(NULL)   # son libellé, pour les messages
    dico_proprio_global  <- reactiveVal(list())
    parcelles_a_retirer  <- reactiveVal(NULL)   # lot visé par ⇧ + rectangle
    parcelles_a_modifier <- reactiveVal(NULL)   # lot ouvert dans la modale par lot
    polygones_temp       <- reactiveVal(list())  # périmètres tracés, pas encore enregistrés

    # `selection_secteur()` porte des `parcelles_base.id` (cf. parcelles_secteur) :
    # ils arrivent en caractère, par les layerId de la carte. Une liste SQL
    # d'entiers, donc, jamais de chaînes quotées — et "NULL" pour une liste vide,
    # qui ne matche rien plutôt que de produire un `IN ()` invalide.
    .ids_sql <- function(ids) {
      v <- suppressWarnings(as.integer(ids))
      v <- v[!is.na(v)]
      if (length(v) == 0) "NULL" else paste(v, collapse = ",")
    }

    # Ce que le sélecteur de responsable affiche après la dernière construction
    # du formulaire, et la date qui va avec : sert à distinguer un choix de
    # l'utilisateur d'une simple reconstruction de la modale.
    resp_rendu       <- reactiveVal("")
    resp_date_rendue <- reactiveVal(NULL)

    # Incrémenté à chaque construction du formulaire de secteur. Les champs
    # obligatoires peuvent être identiques d'une ouverture à l'autre : Shiny
    # n'émet alors rien, et l'observateur qui gouverne le bouton ne serait
    # jamais rejoué sur le bouton fraîchement créé.
    form_secteur_rendu <- reactiveVal(0L)
    # Sélection persistante de parcelles DÉJÀ dans le secteur — même mécanique
    # que la continuité dans l'onglet Sites : le clic bascule, les actions
    # vivent sous la carte.
    selection_secteur    <- reactiveVal(character(0))

    # Exclusivité des deux sélections : les actions du pied de carte seraient
    # ambiguës si les deux coexistaient — même règle que l'onglet Sites. La
    # garde valait pour le clic seulement ; elle doit valoir pour TOUS les
    # chemins de sélection, rectangle et propriétaire compris, sans quoi on
    # contourne la règle sans s'en rendre compte. Renvoient TRUE si l'action
    # doit être abandonnée.
    .selection_secteur_en_cours <- function() {
      if (length(selection_secteur()) == 0) return(FALSE)
      showToast("warning", "Sélection du secteur en cours",
                "Videz d'abord la sélection de parcelles du secteur avant de sélectionner des parcelles cadastrales.")
      TRUE
    }
    .selection_cadastre_en_cours <- function() {
      if (length(selection()) == 0) return(FALSE)
      showToast("warning", "Sélection en cours",
                "Videz d'abord la sélection de parcelles cadastrales avant de sélectionner des parcelles du secteur.")
      TRUE
    }
    # Troisième chantier, exclusif des deux autres depuis le 2026-10-28 : on ne
    # sélectionne pas de parcelles tant que des périmètres tracés attendent
    # d'être ajoutés ou effacés. La réciproque est posée à la capture du tracé.
    .traces_en_cours <- function() {
      n <- length(polygones_temp())
      if (n == 0) return(FALSE)
      showToast("warning", "Périmètres tracés en attente",
                sprintf(paste0("%d périmètre(s) tracé(s) en attente. Ajoutez-les au ",
                               "secteur ou effacez-les (❌ Effacer les tracés) avant ",
                               "de sélectionner des parcelles."), n))
      TRUE
    }
    # Remplacer les CHOIX d'un selectize fait transiter son input par une valeur
    # vide avant d'appliquer la sélection demandée. Sans ce drapeau, ce vide
    # passager remet secteur_id à NULL et le secteur qu'on vient de créer n'est
    # pas sélectionné. Même parade que dans l'onglet Sites.
    ignorer_vide_selecteur <- reactiveVal(FALSE)
    ZOOM_HINT_ID         <- session$ns("zoom_cadastre_hint")

    #' Droits : AD, ou responsable du secteur courant — même règle que les sites.
    can_edit <- reactive({
      roles <- user_roles()
      sid   <- secteur_id()
      if (identical(roles$global_role, "AD")) return(TRUE)
      if (is.null(sid) || is.na(sid)) return(FALSE)
      any(roles$site_roles$site_id == sid & roles$site_roles$role == "RS")
    })
    # Création réservée aux administrateurs : un secteur neuf n'a pas encore de
    # responsable, aucune règle par site ne peut donc s'appliquer.
    can_create <- reactive(identical(user_roles()$global_role, "AD"))

    #' -------------------------
    #' Liste des secteurs
    #' -------------------------
    refresh_secteurs <- function(select = NULL) {
      df <- safe_db_query(con, glue::glue("
        SELECT id, libelle FROM gestcons.sites
         WHERE type_site_id = {TYPE_SITE_SECTEUR} AND actif
         ORDER BY libelle
      "))
      choices <- c(" " = "", stats::setNames(as.character(df$id), df$libelle))
      # À défaut de sélection explicite, on se fie à `secteur_id` et NON à la
      # valeur de l'input : celle-ci retarde d'un aller-retour avec le
      # navigateur. Après une création, elle est encore vide, et ce
      # rafraîchissement — déclenché juste après par refresh_trigger —
      # effaçait la sélection qu'on venait de poser.
      sel <- if (!is.null(select)) {
        as.character(select)
      } else {
        sid_cur <- isolate(secteur_id())
        if (is.null(sid_cur) || is.na(sid_cur)) isolate(input$secteur_selector) else as.character(sid_cur)
      }
      if (is.null(sel) || !(sel %in% choices)) sel <- ""
      if (nzchar(sel)) ignorer_vide_selecteur(TRUE)
      updateSelectizeInput(session, "secteur_selector", choices = choices, selected = sel)
      invisible(df)
    }
    observeEvent(refresh_trigger(), { refresh_secteurs() }, ignoreInit = FALSE)

    observeEvent(input$secteur_selector, {
      v <- input$secteur_selector
      if ((is.null(v) || !nzchar(v)) && isTRUE(ignorer_vide_selecteur())) {
        # Vide passager d'un remplacement de choix : la vraie valeur suit.
        ignorer_vide_selecteur(FALSE)
        return(invisible(NULL))
      }
      ignorer_vide_selecteur(FALSE)
      vide <- is.null(v) || !nzchar(v)
      secteur_id(if (vide) NULL else as.integer(v))
      # Vider le sélecteur à la main équivaut à réinitialiser : l'onglet Sites
      # recadre aussi dans ce cas, pas seulement sur son bouton.
      if (vide) .vue_ariege()
    }, ignoreNULL = FALSE)

    observeEvent(input$reset_secteur, {
      updateSelectizeInput(session, "secteur_selector", selected = "")
      secteur_id(NULL)
      .vue_ariege()
    })

    #' Infos du secteur courant. NULL en création.
    infos <- reactive({
      # Dépendance explicite au déclencheur : l'identifiant ne change pas quand
      # on enregistre une modification, donc sans lui le réactif n'est jamais
      # invalidé et le résumé de la colonne de gauche reste périmé.
      refresh_trigger()
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid)) return(NULL)
      df <- safe_db_query(con, glue::glue("
        SELECT * FROM gestcons.sites WHERE id = {sid} LIMIT 1
      "))
      if (nrow(df) == 0) return(NULL)
      df[1, , drop = FALSE]
    })

    responsable <- reactive({
      refresh_trigger()
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid)) return(NULL)
      df <- safe_db_query(con, glue::glue("
        SELECT r.user_id, r.date_debut, CONCAT(u.nom, ' ', u.prenom) AS nom_complet
          FROM gestcons.responsable_sites r
          LEFT JOIN gestcons.dico_utilisateur u ON u.id = r.user_id
         WHERE r.site_id = {sid} AND r.actif ORDER BY r.date_debut DESC LIMIT 1
      "))
      if (nrow(df) == 0) return(NULL)
      df[1, , drop = FALSE]
    })

    #' Parcelles du secteur : elles portent toutes perimetre = true.
    #'
    #' ⚠️ LES DEUX PARCELLAIRES. `parcellaire_id` est polymorphe : il désigne
    #' une ligne de `dico_cadastre` quand `type_parcelle_id = 1`, une ligne de
    #' `perimetre_parcellaire_manuel` quand il vaut 2. N'en joindre qu'un
    #' laissait 31 secteurs vides à l'écran. Patron repris de `mod_sites` :
    #' deux LEFT JOIN typés et un CASE par colonne qui diffère.
    #'
    #' ⚠️ La clé de sélection est `pid` (= `parcelles_base.id`), PAS `idpar` :
    #' un périmètre manuel n'a aucune référence cadastrale. `idpar` ne sert
    #' plus qu'à l'affichage, et porte pour eux un libellé explicite.
    #'
    #' `ST_MakeValid` n'est pas décoratif : 3 des 41 géométries manuelles
    #' s'auto-intersectent, et ST_SimplifyPreserveTopology échoue dessus.
    parcelles_secteur <- reactive({
      refresh_trigger()
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid)) return(NULL)
      out <- tryCatch(sf::st_read(con, query = glue::glue("
        SELECT p.id AS pid, p.priorite_id, p.remarque, p.perimetre,
               p.type_parcelle_id,
               CASE WHEN p.type_parcelle_id = 1 THEN c.idpar
                    ELSE 'périmètre manuel n°' || pm.id END AS idpar,
               CASE WHEN p.type_parcelle_id = 1 THEN c.dcntpa
                    ELSE round(ST_Area(ST_MakeValid(pm.geometrie)))::int END AS dcntpa,
               -- Une parcelle cadastrale n'a qu'une commune ; un périmètre
               -- manuel peut en recouvrir plusieurs, et l'infobulle les
               -- affiche TOUTES, de la plus grande emprise à la plus petite.
               COALESCE(c.idcomtxt, pcl.communes) AS idcomtxt,
               string_agg({sql_proprio_label()}, ', ' ORDER BY dp.ddenom) AS proprietaires,
               ST_Transform(ST_SimplifyPreserveTopology(
                 CASE WHEN p.type_parcelle_id = 1 THEN c.geompar
                      ELSE ST_MakeValid(pm.geometrie) END, 1.0), 4326) AS geom
          FROM gestcons.parcelles_base p
          LEFT JOIN gestcons.dico_cadastre c
            ON p.type_parcelle_id = 1 AND c.id = p.parcellaire_id
          LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
            ON p.type_parcelle_id = 2 AND pm.id = p.parcellaire_id
          LEFT JOIN gestcons.dico_proprietaire dp ON dp.idprocpte = c.idprocpte
          LEFT JOIN LATERAL (
            SELECT string_agg(co.nom, ', ' ORDER BY pc.surface_m2 DESC) AS communes
              FROM gestcons.parcelles_communes pc
              JOIN gestcons.communes co ON co.insee_com = pc.insee_com
             WHERE pc.parcelle_id = p.id) pcl ON true
         WHERE p.site_id = {sid} AND p.perimetre
           AND COALESCE(c.id, pm.id) IS NOT NULL
         GROUP BY p.id, p.priorite_id, p.remarque, p.perimetre, p.type_parcelle_id,
                  c.idpar, c.dcntpa, c.idcomtxt, c.geompar, pm.id, pm.geometrie,
                  pcl.communes
      "), quiet = TRUE), error = function(e) NULL)
      if (is.null(out) || nrow(out) == 0) return(NULL)
      out
    })

    #' La géologie est hiérarchique mais ne compte que 29 entrées : une liste à
    #' plat, indentée, évite de dupliquer le sélecteur en cascade de l'onglet
    #' Sites tout en gardant la hiérarchie lisible.
    geol_choices <- reactive({
      g <- dico_geol
      if (is.null(g) || nrow(g) == 0) return(stats::setNames(character(0), character(0)))
      pere <- function(col) if (col %in% names(g)) {
        v <- suppressWarnings(as.integer(g[[col]])); ifelse(is.na(v), 0L, v)
      } else rep(0L, nrow(g))
      p1 <- pere("parent_id"); p2 <- pere("parent_id_2"); p3 <- pere("parent_id_3")
      prof <- as.integer(p1 != 0) + as.integer(p2 != 0) + as.integer(p3 != 0)
      # Le dictionnaire arrive trié par libellé : on le réordonne par racine
      # puis par identifiant, sinon l'indentation apparaît dans le désordre.
      racine <- ifelse(p1 != 0, p1, as.integer(g$id))
      ordre  <- order(racine, as.integer(g$id))
      g <- g[ordre, , drop = FALSE]; prof <- prof[ordre]
      lab <- paste0(strrep("   ", prof), g$libelle)
      stats::setNames(as.character(g$id), lab)
    })

    #' -------------------------
    #' Colonne de gauche
    #' -------------------------
    output$resume_secteur <- renderUI({
      sid <- secteur_id()
      if (is.null(sid)) {
        return(div(class = "text-muted", "Aucun secteur sélectionné."))
      }
      d <- infos(); r <- responsable(); p <- parcelles_secteur()
      milieu <- if (is.null(d)) NA else dico_type_milieu$libelle[dico_type_milieu$id == d$type_milieu_id][1]

      # Ventilation par priorité : « 45 parcelles » ne dit rien de l'effort à
      # fournir, « 12 prioritaires pour 8 ha » répond à la question qu'on se
      # pose devant un secteur. La donnée est déjà dans la couche, aucune
      # requête supplémentaire.
      ligne <- function(libelle, couleur, sel) {
        n <- sum(sel)
        if (n == 0) return("")
        ha <- sum(suppressWarnings(as.numeric(p$dcntpa[sel])), na.rm = TRUE) / 10000
        glue::glue(
          "<div><i style='display:inline-block;width:10px;height:10px;",
          "background:{couleur};margin-right:6px;vertical-align:middle'></i>",
          "{libelle} : <b>{n}</b> — {format(round(ha, 2), nsmall = 2)} ha</div>"
        )
      }
      if (is.null(p) || nrow(p) == 0) {
        detail <- "<div class='text-muted'>Aucune parcelle rattachée.</div>"
        total  <- ""
      } else {
        prio <- suppressWarnings(as.integer(p$priorite_id))
        detail <- paste0(
          ligne("Priorité 1", COLORS_PRIORITE$p1, prio %in% 1L),
          ligne("Priorité 2", .couleur_p2(), prio %in% 2L)
        )
        ha_tot <- sum(suppressWarnings(as.numeric(p$dcntpa)), na.rm = TRUE) / 10000
        total <- glue::glue(
          "<div style='margin-top:4px;padding-top:4px;border-top:1px solid var(--c-trait)'>",
          "<b>Total :</b> {nrow(p)} parcelles — {format(round(ha_tot, 2), nsmall = 2)} ha</div>"
        )
      }

      # Communes du secteur. Aucune requête de plus : la donnée est déjà dans
      # la couche. `idcomtxt` y porte le libellé cadastral pour une parcelle du
      # cadastre, et la LISTE des communes recouvertes pour un périmètre manuel
      # — qui peut en chevaucher jusqu'à trois. D'où le découpage avant
      # dédoublonnage, sans lequel « Caussou, Prades » compterait pour une.
      communes <- if (is.null(p) || nrow(p) == 0) character(0) else {
        v <- unlist(strsplit(as.character(stats::na.omit(p$idcomtxt)), ",[[:space:]]*"))
        sort(unique(trimws(v[nzchar(v)])))
      }
      # Mesuré : 52 secteurs sur une commune, 18 sur deux, et un sur seize.
      # Au-delà de quatre on tronque, la liste entière restant au survol.
      communes_txt <- if (length(communes) == 0) "—" else {
        visible <- if (length(communes) > 4)
          paste0(paste(communes[1:4], collapse = ", "), "…")
        else paste(communes, collapse = ", ")
        sprintf("<span title=\"%s\">%s</span>",
                htmltools::htmlEscape(paste(communes, collapse = ", "), attribute = TRUE),
                htmltools::htmlEscape(visible))
      }
      communes_n <- if (length(communes) > 1) sprintf(" (%d)", length(communes)) else ""

      htmltools::HTML(glue::glue(
        "<div style='font-size:13px;line-height:1.4'>",
        "<div style='font-weight:600;margin-bottom:6px'>🎯 {htmltools::htmlEscape(d$libelle %||% '')}</div>",
        "<div><b>Milieu :</b> {htmltools::htmlEscape(milieu %||% '—')}</div>",
        "<div><b>Responsable :</b> {htmltools::htmlEscape(if (is.null(r)) '—' else r$nom_complet)}</div>",
        "<div><b>Commune{ifelse(length(communes) == 1L, '', 's')}{communes_n} :</b> {communes_txt}</div>",
        "<div style='margin-top:6px'>{detail}</div>{total}",
        "</div>"
      ))
    })

    output$strategie_helper_text <- renderUI({
      tags$p(
        class = "text-muted",
        "Un secteur d'intervention prioritaire regroupe des parcelles sans ",
        "contrat, repérées comme pouvant devenir un futur site conservatoire. ",
        actionLink(ns("strategie_help"), "En savoir plus...")
      )
    })

    #' Aide du module, sur le modèle de l'onglet Sites : le contenu vit dans
    #' www/help_strategie.html pour être modifiable sans toucher au code.
    observeEvent(input$strategie_help, {
      chemin <- if (file.exists(file.path("www", "help_strategie.html"))) {
        file.path("www", "help_strategie.html")
      } else "help_strategie.html"
      corps <- if (file.exists(chemin)) includeHTML(chemin) else tagList(
        h5("Aide introuvable"),
        p("Placez un fichier ", tags$code("help_strategie.html"),
          " dans le dossier ", tags$code("www/"), ".")
      )
      showModal(modalDialog(title = "En savoir plus...", size = "l",
                            easyClose = TRUE, footer = NULL, corps))
    })

    #' -------------------------
    #' Carte
    #' -------------------------
    output$map <- renderLeaflet({
      init_map_base() %>%
        addLayersControl(
          baseGroups    = c("OpenStreetMap", "IGN Cartes", "IGN Satellites"),
          # « Parcelle sélectionnée » n'est volontairement PAS listée : c'est un
          # calque de travail, pouvoir le masquer n'aurait pas de sens et
          # ferait croire à une sélection vide. Absente du contrôle, la couche
          # reste affichée en permanence. L'onglet Sites fait de même.
          # Mêmes familles de couches que l'onglet Sites — le contrôle les
          # range en accordéon côté client (www/app.js), et plus rien ne tombe
          # dans le fourre-tout « Autres couches ».
          overlayGroups = c("Secteurs", "Parcelles du secteur", "Parcelles cadastrales",
                            protection_groupes(zones_protection_data),
                            GROUPS$zones_humides, GROUPS$voisins, GROUPS$communes),
          options       = layersControlOptions(collapsed = FALSE)
        ) %>%
        # Les couches de contexte arrivent éteintes : elles coûtent une requête
        # chacune et ne sont pas ce qu'on vient regarder dans cet onglet.
        hideGroup(c(protection_groupes(zones_protection_data),
                    GROUPS$zones_humides, GROUPS$voisins, GROUPS$communes)) %>%
        # Deux outils : le rectangle bleu SÉLECTIONNE des parcelles du
        # cadastre, le polygone rouge DESSINE un périmètre manuel à rattacher
        # au secteur. 37 des 41 périmètres manuels de la base vivent déjà dans
        # des secteurs — ils y sont arrivés par la bascule site → secteur, et
        # rien ne permettait d'en créer un ici.
        add_std_draw_toolbar(rectangle = "selection", polygon = TRUE) %>%
        # État de la touche ⇧, exposé en input namespacé — même mécanique que
        # l'onglet Sites. Le `force` est nécessaire : sans lui, maintenir la
        # touche n'émettrait qu'un seul événement.
        htmlwidgets::onRender("
          function(el, x){
            // Les deux outils font des choses très différentes et rien à
            // l'écran ne le dit : le rectangle SÉLECTIONNE du cadastre, le
            // polygone DESSINE un périmètre. Les intitulés par défaut de
            // Leaflet.Draw sont en anglais et muets là-dessus. Retitrage au
            // rendu puis à la volée, la barre étant reconstruite.
            var T_POLY = 'Tracer un périmètre manuel à rattacher au secteur';
            var T_RECT = 'Sélectionner des parcelles cadastrales à ajouter au secteur — maintenir ⇧ (Maj) pendant le tracé pour viser au contraire les parcelles DÉJÀ dans le secteur';
            if (window.L && L.drawLocal && L.drawLocal.draw && L.drawLocal.draw.toolbar && L.drawLocal.draw.toolbar.buttons) {
              L.drawLocal.draw.toolbar.buttons.polygon   = T_POLY;
              L.drawLocal.draw.toolbar.buttons.rectangle = T_RECT;
            }
            function retitrer(){
              [['.leaflet-draw-draw-polygon', T_POLY],
               ['.leaflet-draw-draw-rectangle', T_RECT]].forEach(function(p){
                var b = el.querySelector(p[0] + ' a') || el.querySelector(p[0]);
                if (b) { b.title = p[1]; b.setAttribute('aria-label', p[1]); }
              });
            }
            retitrer();
            setTimeout(retitrer, 500);
            var baseId = el.id.replace(/-map$/, '');
            function pushShift(v){
              Shiny.setInputValue(baseId + '-shift_pressed', !!v,
                                  {priority:'event', force:true});
            }
            window.addEventListener('keydown', function(e){
              if(e.key === 'Shift') pushShift(true);
            }, {capture:true});
            window.addEventListener('keyup', function(e){
              if(e.key === 'Shift') pushShift(false);
            }, {capture:true});
            // Filet : au mousedown, on renvoie l'état réel du modifieur, utile
            // si le focus clavier était ailleurs au moment de l'appui.
            var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + el.id) : null;
            var map = (w && w.getLeaflet) ? w.getLeaflet() : (el._leaflet_map || null);
            if (map) {
              map.on('mousedown', function(e){
                pushShift(!!(e.originalEvent && e.originalEvent.shiftKey));
              });
            }
          }
        ")
    })

    LEGENDE_ID <- "strategie_priorite_legend"

    #' Pastilles des secteurs — même comportement que les sites voisins dans
    #' l'onglet Sites, et calqué sur lui : elles ne sont visibles QUE si
    #' aucun secteur n'est sélectionné, et elles sont redessinées au zoom,
    #' leur rayon étant exprimé en mètres.
    #'
    #' Un seul observe() plutôt que deux observateurs séparés : la lecture du
    #' zoom et celle de la sélection ne peuvent ainsi pas se contredire. Un
    #' redessin ramènerait sinon des pastilles qu'une sélection vient de
    #' masquer, hideGroup() ne valant que pour les tracés déjà posés.
    #'
    #' Orange, et non la couleur par statut : les 113 secteurs sont tous en
    #' Préfiguration, ils ressortiraient donc tous verts. La teinte vient de
    #' la palette plutôt que d'un neuvième orange écrit en dur.
    observe({
      refresh_trigger()
      if (!isTruthy(secteur_id())) {
        draw_circles(con, map_id = ns("map"), group = "Secteurs",
                     zoom = input$map_zoom %||% MAP_DEFAULT_ZOOM, type_site_id = 2L,
                     couleur = COLORS_PARCELLES$draft_outline)
        leafletProxy(ns("map"), session = session) %>% showGroup("Secteurs")
        return()
      }
      leafletProxy(ns("map"), session = session) %>% hideGroup("Secteurs")
    })

    #' Légende de la priorité, par le helper partagé de l'onglet Sites. Sans
    #' elle, les bleus de la carte ne sont interprétables par personne.
    #'
    #' ⚠️ `.couleur_p2()` figure dans l'ÉVÉNEMENT et non seulement dans le
    #' corps : le corps d'un observeEvent est isolé, les réactifs qu'il lit ne
    #' le redéclenchent pas. Sans ça, changer de profil ne repeindrait la
    #' légende qu'au prochain changement de secteur. Cf. la verrue temporaire
    #' en tête de fichier.
    observeEvent(list(secteur_id(), .couleur_p2()), {
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid)) {
        remove_legend(ns("map"), session, layer_id = LEGENDE_ID)
      } else {
        # Les pastilles reprennent la couleur TELLE QU'ELLE APPARAÎT sur la
        # carte, intensité comprise : le degré y est porté par l'opacité du
        # remplissage, et une légende qui afficherait les deux teintes à la
        # même intensité ne permettrait pas de retrouver la priorité 2.
        # Dérivé des mêmes constantes, pour que rien ne puisse diverger.
        # « Non renseignée » n'y figure pas : aucune parcelle ne peut l'être.
        add_map_legend(
          ns("map"), session, layer_id = LEGENDE_ID,
          title  = "Priorité",
          labels = c("Priorité 1", "Priorité 2"),
          colors = c(.sur_fond_clair(COLORS_PRIORITE$p1, COLORS_PRIORITE$opacite),
                     .sur_fond_clair(.couleur_p2(), COLORS_PRIORITE$opacite))
        )
      }
    }, ignoreNULL = FALSE)

    #' Dessin des parcelles du secteur + cadrage. Les couleurs disent la
    #' priorité : une zone de prospection se lit d'abord par là.
    #'
    #' ⚠️ `.couleur_p2()` est dans l'ÉVÉNEMENT pour la même raison que la
    #' légende : un changement de profil doit repeindre la carte tout de
    #' suite, sans attendre qu'on reclique sur un secteur.
    observeEvent(list(parcelles_secteur(), secteur_id(), .couleur_p2()), {
      prx <- leafletProxy(ns("map"), session = session) %>% clearGroup("Parcelles du secteur")
      d   <- parcelles_secteur()
      sid <- secteur_id()
      if (!is.null(d) && nrow(d) > 0) {
        # Fabrique partagée : mêmes informations que l'infobulle du cadastre —
        # propriétaire, commune, surface — plus la priorité et la remarque.
        # Les contrats sont exclus : une parcelle de secteur n'en porte pas.
        # Pas de segment « type » ici : dans cet onglet toutes les parcelles sont
        # des parcelles de secteur, et la fabrique l'étiquetterait « Zone
        # d'intérêt », ce qui serait trompeur.
        lbl <- .cf_make_labels(d, user_roles(),
                               fields = c("parcelle", "proprietaire", "commune",
                                          "surface", "priorite", "remarque"))

        # La couleur dit la priorité. Le repli gris ne devrait jamais servir :
        # les deux sélecteurs de priorité n'offrent plus de valeur vide. Il
        # reste pour une ligne écrite hors de l'application. Seule la couleur
        # distingue les degrés : l'opacité est la même pour tous.
        couleur <- ifelse(d$priorite_id %in% 1L, COLORS_PRIORITE$p1,
                   ifelse(d$priorite_id %in% 2L, .couleur_p2(), COLORS_PRIORITE$sans))
        prx %>% addPolygons(
          data = d, group = "Parcelles du secteur", layerId = ~paste0("sec_", pid),
          # Aplat sans contour. Les parcelles ne se confondent pas avec les
          # calques de sélection, qui sont rouges ; la bordure n'a donc plus
          # rien à distinguer. Au survol, highlightOptions en pose une.
          color = couleur, weight = 0, fillColor = couleur,
          fillOpacity = COLORS_PRIORITE$opacite,
          label = lbl,
          # Plan « site » (z-index 420) : le cadastre n'a PAS de plan dédié et
          # tombe dans celui par défaut (400). Sans ce pathOptions, le cadastre
          # — redessiné à chaque déplacement — repasse au-dessus et intercepte
          # le clic : une parcelle du secteur était alors simplement
          # sélectionnée au lieu d'ouvrir sa fiche.
          options = pathOptions(pane = "site"),
          highlightOptions = highlightOptions(color = "#111827", weight = 3, bringToFront = TRUE)
        ) %>% showGroup("Parcelles du secteur")
      }
      # Cadrage sur le secteur, s'il a des parcelles.
      if (!is.null(sid) && !is.na(sid)) {
        bb <- tryCatch(site_bbox_4326(con, sid, include_manuels = TRUE, include_perimetre = TRUE),
                       error = function(e) NULL)
        if (!is.null(bb)) {
          prx %>% fitBounds(bb[1], bb[2], bb[3], bb[4])
        }
      }
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
    }, ignoreNULL = FALSE)

    #' Chargement du cadastre à l'emprise, comme dans l'onglet Sites : même
    #' helper, même seuil de zoom, même message d'invitation à zoomer.
    #' Couches de contexte, reprises de l'onglet Sites : mêmes helpers, mêmes
    #' caches, même règle — rien n'est interrogé tant que la case est décochée.
    #' Cocher doit afficher tout de suite, sans attendre un déplacement de
    #' carte ; décocher doit vider immédiatement.
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

    observeEvent(zh_visible(), {
      refresh_zones_humides(
        con = con, bounds = input$map_bounds, zoom = input$map_zoom,
        map_id = ns("map"), show_group = zh_visible(), session = session
      )
    })
    observeEvent(communes_visible(), {
      refresh_limites_communales(
        con = con, bounds = input$map_bounds, zoom = input$map_zoom,
        map_id = ns("map"), show_group = communes_visible(), session = session
      )
    })
    observeEvent(list(voisins_visible(), secteur_id()), {
      # Changer de secteur change qui est « voisin » : on redessine si la
      # couche est affichée, sans quoi l'ancien voisinage resterait à l'écran.
      refresh_sites_voisins(
        con = con, bounds = input$map_bounds, site_id = secteur_id(),
        map_id = ns("map"), show_group = voisins_visible(), session = session
      )
    }, ignoreNULL = FALSE)

    #' Zones de protection : dessinées À LA DEMANDE, une seule fois par
    #' session. L'onglet Sites les dessine dès qu'un site est choisi ; ici
    #' elles ne sont pas le sujet, et les tracer d'office ferait payer à tout
    #' le monde une couche que peu ouvriront. `draw_dico_protection` masque
    #' les groupes en sortie — il faut donc rallumer ceux qu'on venait de
    #' cocher, sinon le clic de l'utilisateur serait défait sous ses yeux.
    protection_dessinee <- reactiveVal(FALSE)
    protection_visible  <- reactive({
      g <- input$map_groups
      grp <- protection_groupes(zones_protection_data)
      !is.null(g) && length(grp) > 0 && any(grp %in% g)
    })
    observeEvent(protection_visible(), {
      if (!isTRUE(protection_visible()) || isTRUE(protection_dessinee())) {
        return(invisible(NULL))
      }
      draw_dico_protection(con, map_id = ns("map"), session = session,
                           zones_protection_data)
      protection_dessinee(TRUE)
      coches <- intersect(protection_groupes(zones_protection_data), input$map_groups)
      if (length(coches) > 0) {
        leafletProxy(ns("map"), session = session) %>% showGroup(coches)
      }
    })

    #' Zoom sur une commune, repris de l'onglet Sites : même liste, même
    #' emprise calculée sur le cadastre. Vider le cache force le rechargement
    #' du cadastre à l'arrivée, si un secteur est choisi.
    #' Le remplissage de la liste fait passer le champ par une valeur vide :
    #' sans effet ici, l'observateur s'arrête sur une commune vide.
    observeEvent(TRUE, {
      communes <- if (is.function(liste_communes)) liste_communes() else liste_communes
      communes <- unique(communes)
      communes <- as.character(communes)
      communes <- communes[!is.na(communes) & nzchar(communes)]
      communes <- sort(communes)
      updateSelectizeInput(session, "commune_selector",
                           choices  = c(" " = "", stats::setNames(communes, communes)),
                           selected = "")
    }, once = TRUE)

    observeEvent(input$commune_selector, {
      parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
      parcelles_cache_bbox(NULL)
      req(input$commune_selector, input$commune_selector != "")
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

    debounced_bounds <- debounce(reactive(input$map_bounds), millis = 300)

    observeEvent(debounced_bounds(), {
      bounds <- debounced_bounds()
      zoom   <- input$map_zoom
      if (is.null(bounds) || is.null(zoom)) return()

      # ⚠️ Les couches de contexte ne dépendent PAS du secteur sélectionné :
      # elles passent donc avant la sortie anticipée ci-dessous, sans quoi
      # elles ne se rechargeraient jamais au déplacement tant qu'aucun secteur
      # n'est choisi. Même ordre que dans l'onglet Sites.
      refresh_zones_humides(
        con = con, bounds = bounds, zoom = zoom, map_id = ns("map"),
        show_group = zh_visible(), session = session
      )
      refresh_limites_communales(
        con = con, bounds = bounds, zoom = zoom, map_id = ns("map"),
        show_group = communes_visible(), session = session
      )
      refresh_sites_voisins(
        con = con, bounds = bounds, site_id = secteur_id(),
        map_id = ns("map"), show_group = voisins_visible(), session = session
      )

      if (!isTruthy(secteur_id()) || is.na(secteur_id())) {
        hide_zoom_hint(ZOOM_HINT_ID)
        return()
      }
      if (zoom >= ZOOM_CADASTRE_MIN) {
        refresh_parcelles_cadastrales(
          con = con, zoom = zoom, bounds = bounds, map_id = ns("map"),
          group_name = "Parcelles cadastrales",
          parcelles_cache = parcelles_cache,
          parcelles_cache_bbox = parcelles_cache_bbox,
          buffer_deg = 0.001, user_roles = user_roles(),
          show_group = TRUE, session = session
        )
        hide_zoom_hint(ZOOM_HINT_ID)
      } else {
        leafletProxy(ns("map"), session = session) %>%
          clearGroup("Parcelles cadastrales") %>% hideGroup("Parcelles cadastrales")
        parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
        parcelles_cache_bbox(NULL)
        invalidate_cadastre_hash(ns("map"), session)
        show_zoom_hint(ns("map"), ZOOM_HINT_ID)
      }
    })

    #' -------------------------
    #' Clic sur la carte
    #' -------------------------
    observeEvent(input$map_shape_click, {
      click <- input$map_shape_click
      req(click$id)
      # `sec_` porte un pid (parcelles_base.id), `cad_`/`sel_` un idpar : la
      # couche du secteur mêle désormais cadastre et périmètres manuels, et
      # ces derniers n'ont pas de référence cadastrale.
      cle   <- sub("^(cad_|sel_|sec_)", "", as.character(click$id))
      idpar <- cle

      # Pastille de secteur -> on le sélectionne. Ce branchement passe AVANT
      # la garde ci-dessous, qui exige qu'un secteur soit déjà choisi : c'est
      # précisément le cas qu'on veut traiter, celui où rien ne l'est encore.
      # On passe par le sélecteur plutôt que par secteur_id() directement,
      # pour que la liste déroulante montre le même secteur que la carte.
      if (identical(click$group, "Secteurs")) {
        sid <- suppressWarnings(as.integer(click$id))
        if (!is.na(sid)) {
          if (identical(sid, isolate(secteur_id()))) return(invisible(NULL))
          updateSelectizeInput(session, "secteur_selector", selected = as.character(sid))
        }
        return(invisible(NULL))
      }

      if (!isTruthy(secteur_id()) || is.na(secteur_id())) return()

      # Parcelle DÉJÀ dans le secteur -> bascule dans la sélection du secteur.
      if (identical(click$group, "Parcelles du secteur")) {
        if (!isTRUE(can_edit())) {
          showToast("warning", "Lecture seule",
                    "Vous n'êtes ni administrateur ni responsable de ce secteur.")
          return(invisible(NULL))
        }
        if (.selection_cadastre_en_cours() || .traces_en_cours()) return(invisible(NULL))
        cur <- selection_secteur()
        selection_secteur(if (cle %in% cur) setdiff(cur, cle) else c(cur, cle))
        draw_selection_secteur()
        return()
      }

      # Parcelle cadastrale -> bascule dans la sélection.
      if (click$group %in% c("Parcelles cadastrales", "Parcelle sélectionnée")) {
        if (!isTRUE(can_edit())) {
          showToast("warning", "Lecture seule",
                    "Vous n'êtes ni administrateur ni responsable de ce secteur.")
          return(invisible(NULL))
        }
        if (.selection_secteur_en_cours() || .traces_en_cours()) return(invisible(NULL))
        cur <- selection()
        selection(if (idpar %in% cur) setdiff(cur, idpar) else c(cur, idpar))
        draw_parcelles_selectionnees(selection(), con = con, map_id = ns("map"),
                                     session = session, user_roles = user_roles())
      }
    })

    #' -------------------------
    #' Pied de carte : la sélection et ce qu'on en fait
    #' -------------------------
    output$map_footer <- renderUI({
      sid <- secteur_id()
      if (is.null(sid)) {
        return(div(class = "text-muted", style = "margin-top:10px;",
                   "Sélectionnez un secteur, ou créez-en un pour commencer."))
      }
      if (is.na(sid)) return(NULL)
      n      <- length(selection())
      n_sec  <- length(selection_secteur())
      n_poly <- length(polygones_temp())
      has_any <- n > 0
      tagList(
        # Même structure que le pied de carte de l'onglet Sites : filtre
        # propriétaire à gauche, spacer, boutons poussés à droite, compte en
        # dessous.
        div(
          class = "map-footer",
          div(
            class = "field-stack",
            tags$label("🔍 Filtrer par propriétaire :", `for` = ns("proprio_selector")),
            selectInput(
              ns("proprio_selector"),
              label = NULL,
              choices = c("Aucun" = "", names(isolate(dico_proprio_global())))
            )
          ),
          div(class = "spacer"),
          if (has_any && isTRUE(can_edit())) {
            div(
              style = "display:flex; align-items:flex-end; gap:8px;",
              div(class = "field-stack",
                  tags$label("🎯 Priorité :", `for` = ns("ajout_priorite")),
                  selectInput(ns("ajout_priorite"), label = NULL,
                              choices = c("Priorité 1" = "1", "Priorité 2" = "2"),
                              selected = "1")),
              actionButton(ns("ajouter_au_secteur"),
                           sprintf("➕ Ajouter au secteur (%d)", n),
                           class = "btn btn-success btn-sm"),
              actionButton(ns("vider_selection"), "❌ Vider la sélection",
                           class = "btn btn-danger btn-sm")
            )
          }
        ),
        if (has_any) {
          div(
            style = "font-size:0.95em; color:var(--c-accent); margin-top:4px;",
            htmltools::HTML(sprintf("📌 Parcelles sélectionnées : <strong>%d</strong>", n))
          )
        } else if (n_sec == 0 && n_poly == 0) {
          div(class = "text-muted", style = "margin-top:4px;",
              "Zoomez pour afficher le cadastre, puis cliquez les parcelles à rattacher au secteur.")
        },

        #' Périmètres tracés en attente. Bloc à part : un tracé n'est pas une
        #' parcelle du cadastre, il n'a ni référence ni propriétaire, et le
        #' confondre avec la sélection cadastrale rendrait le compte du bouton
        #' incompréhensible.
        if (n_poly > 0 && isTRUE(can_edit())) {
          div(
            style = "margin-top:10px; padding-top:8px; border-top:1px solid var(--c-trait);
                     display:flex; align-items:flex-end; gap:8px; flex-wrap:wrap;",
            tags$span(style = "color:#b91c1c; margin-right:auto; align-self:center;",
                      htmltools::HTML(sprintf(
                        "✏️ Périmètres tracés : <strong>%d</strong>", n_poly))),
            div(class = "field-stack",
                tags$label("🎯 Priorité :", `for` = ns("ajout_priorite_poly")),
                selectInput(ns("ajout_priorite_poly"), label = NULL,
                            choices = c("Priorité 1" = "1", "Priorité 2" = "2"),
                            selected = "1")),
            actionButton(ns("ajouter_perimetre_secteur"),
                         sprintf("➕ Ajouter au secteur (%d)", n_poly),
                         class = "btn btn-success btn-sm"),
            actionButton(ns("vider_polygones"), "❌ Effacer les tracés",
                         class = "btn btn-danger btn-sm")
          )
        },

        #' Actions sur les parcelles DU SECTEUR sélectionnées. Bloc distinct du
        #' précédent : les deux sélections s'excluent, on n'en voit donc jamais
        #' qu'un à la fois.
        if (n_sec > 0 && isTRUE(can_edit())) {
          div(
            style = "margin-top:10px; padding-top:8px; border-top:1px solid var(--c-trait);
                     display:flex; align-items:center; gap:8px; flex-wrap:wrap;",
            tags$span(style = "color:#1d4ed8; margin-right:auto;",
                      htmltools::HTML(sprintf(
                        "🎯 Parcelles du secteur sélectionnées : <strong>%d</strong>", n_sec))),
            # Une parcelle : sa fiche, pré-remplie. Plusieurs — au rectangle
            # avec ⇧, typiquement : la modale d'édition par lot.
            actionButton(ns("parc_modifier"),
                         if (n_sec == 1) "✏️ Modifier" else sprintf("✏️ Modifier (%d)", n_sec),
                         class = "btn btn-default btn-secondary btn-sm"),
            actionButton(ns("promouvoir_secteur"),
                         sprintf("⬆️ Promouvoir en site (%d)", n_sec),
                         class = "btn btn-success btn-sm"),
            actionButton(ns("retirer_selection_secteur"),
                         sprintf("🗑 Retirer du secteur (%d)", n_sec),
                         class = "btn btn-danger btn-sm"),
            actionButton(ns("vider_selection_secteur"), "❌ Vider",
                         class = "btn btn-default btn-secondary btn-sm")
          )
        }
      )
    })

    #' -------------------------
    #' Message d'invitation, comme dans l'onglet Sites
    #' -------------------------
    output$msg_associer_parcelles <- renderUI({
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid) || !isTRUE(can_edit())) return(NULL)
      nom <- safe_db_query(con, glue::glue_sql(
        "SELECT libelle FROM gestcons.sites WHERE id = {sid}", .con = con))$libelle[1]
      tags$div(
        style = "margin: 12px 0; font-size: 1.1em; color: var(--c-accent);",
        htmltools::HTML(glue::glue(
          "Associez des parcelles au secteur <strong>{htmltools::htmlEscape(nom %||% '')}</strong> ",
          "soit en <u>cliquant</u> sur la carte, soit via un propriétaire, ",
          "soit en <u>traçant un rectangle</u> pour sélectionner en masse."
        ))
      )
    })

    #' -------------------------
    #' Propriétaires de l'emprise visible
    #' -------------------------
    #' Même principe que dans Sites : la liste ne propose que les propriétaires
    #' réellement à l'écran, et seulement au-delà du seuil de zoom du cadastre —
    #' en deçà, la requête porterait sur tout le département.
    observeEvent(debounced_bounds(), {
      # Convertie : l'emprise vient du navigateur et finit dans du SQL brut.
      bounds <- bounds_num(debounced_bounds())
      sid    <- secteur_id()
      if (is.null(bounds) || is.null(sid) || is.na(sid)) return()
      if (is.null(input$map_zoom) || input$map_zoom < ZOOM_CADASTRE_MIN) {
        dico_proprio_global(list())
        updateSelectInput(session, "proprio_selector",
                          choices = c("🔎 Zoomez pour lister les propriétaires" = ""))
        return()
      }
      props <- safe_db_query(con, glue::glue("
        SELECT DISTINCT dp.idprocpte, {sql_proprio_label()} AS proprietaire_label
          FROM gestcons.dico_cadastre dc
          LEFT JOIN gestcons.dico_proprietaire dp ON dc.idprocpte = dp.idprocpte
         WHERE dc.geompar && ST_Transform(
                 ST_MakeEnvelope({bounds$west}, {bounds$south},
                                 {bounds$east}, {bounds$north}, 4326), 2154)
           AND NOT EXISTS (
             SELECT 1 FROM gestcons.parcelles_base p
               LEFT JOIN gestcons.sites s ON s.id = p.site_id
              WHERE p.parcellaire_id = dc.id
                AND (p.site_id = {sid} OR s.type_site_id = 1))
         ORDER BY proprietaire_label
      "))
      if (nrow(props) == 0) {
        dico_proprio_global(list())
        updateSelectInput(session, "proprio_selector", choices = c("Aucun" = ""))
      } else {
        d <- split(props$idprocpte, props$proprietaire_label)
        dico_proprio_global(d)
        updateSelectInput(session, "proprio_selector",
                          choices = c("Aucun" = "", names(d)))
      }
    })

    #' Sélection de toutes les parcelles visibles d'un propriétaire.
    observeEvent(input$proprio_selector, {
      lab <- input$proprio_selector
      req(lab, nzchar(lab))
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid) || !isTRUE(can_edit())) return(invisible(NULL))
      # Même exclusivité que le clic et le rectangle : ce chemin l'ignorait.
      if (.selection_secteur_en_cours() || .traces_en_cours()) return(invisible(NULL))
      ids <- dico_proprio_global()[[lab]]
      bounds <- bounds_num(input$map_bounds)
      if (is.null(ids) || is.null(bounds)) return(invisible(NULL))
      ids_sql <- paste(dbQuoteString(con, as.character(ids)), collapse = ",")
      df <- safe_db_query(con, glue::glue("
        SELECT c.idpar FROM gestcons.dico_cadastre c
         WHERE c.geompar && ST_Transform(
                 ST_MakeEnvelope({bounds$west}, {bounds$south},
                                 {bounds$east}, {bounds$north}, 4326), 2154)
           AND c.idprocpte IN ({ids_sql})
           AND NOT EXISTS (
             SELECT 1 FROM gestcons.parcelles_base p
               LEFT JOIN gestcons.sites s ON s.id = p.site_id
              WHERE p.parcellaire_id = c.id
                AND (p.site_id = {sid} OR s.type_site_id = 1))
      "))
      if (nrow(df) == 0) {
        showToast("warning", "Aucune parcelle",
                  "Ce propriétaire n'a aucune parcelle libre dans l'emprise affichée.")
        return(invisible(NULL))
      }
      selection(union(selection(), as.character(df$idpar)))
      draw_parcelles_selectionnees(selection(), con = con, map_id = ns("map"),
                                   session = session, user_roles = user_roles())
      showToast("success", "Sélection",
                sprintf("%d parcelle(s) de %s ajoutée(s) à la sélection.", nrow(df), lab))
    })

    #' -------------------------
    #' Sélection par rectangle
    #' -------------------------
    #' Plus simple que dans Sites, qui doit aussi distinguer le polygone manuel
    #' et gérer un événement maison avec ⇧ : ici le rectangle est le seul outil
    #' de dessin, et il ne fait qu'ajouter à la sélection.
    observeEvent(input$map_draw_new_feature, {
      feat <- input$map_draw_new_feature
      sid  <- secteur_id()
      if (is.null(feat) || is.null(sid) || is.na(sid)) return(invisible(NULL))
      if (!isTRUE(can_edit())) return(invisible(NULL))
      ftype <- tryCatch(tolower(as.character(feat$properties$feature_type)),
                        error = function(e) "")

      # Périmètre tracé : on l'EMPILE sans rien écrire, et le pied de carte
      # propose ensuite de l'enregistrer. Même parti pris que l'onglet Sites :
      # dessiner n'est pas enregistrer.
      #
      # La forme de Leaflet.Draw est retirée aussitôt : elle vivait dans
      # « Polygones », que clear_rect() vide après chaque rectangle, et le
      # tracé s'effaçait de l'écran en restant dans l'état. C'est
      # draw_traces_en_attente(), alimenté par l'état, qui l'affiche.
      if (identical(ftype, "polygon")) {
        # Refusé pendant une sélection de parcelles, quelle qu'elle soit : la
        # forme est retirée et le toast dit quoi vider.
        if (length(selection()) > 0 || length(selection_secteur()) > 0) {
          showToast("warning", "Sélection en cours",
                    "Videz d'abord la sélection de parcelles avant de tracer un périmètre.")
          session$sendCustomMessage("clear-polygones", ns("map"))
          leafletProxy(ns("map"), session = session) %>%
            clearGroup("Polygones") %>%
            clearGroup("drawnItems") %>%
            clearGroup("drawn")
          return(invisible(NULL))
        }
        polys <- polygones_temp()
        polys[[length(polys) + 1]] <- feat
        polygones_temp(polys)
        session$sendCustomMessage("clear-polygones", ns("map"))
        leafletProxy(ns("map"), session = session) %>%
          clearGroup("Polygones") %>%
          clearGroup("drawnItems") %>%
          clearGroup("drawn")
        return(invisible(NULL))
      }

      if (!identical(ftype, "rectangle")) return(invisible(NULL))

      # Leaflet.Draw dépose sa forme dans SES propres calques, pas seulement
      # dans le groupe cible : sans ce triple nettoyage — plus le handler JS,
      # qui vide le groupe côté client — le rectangle reste dessiné à l'écran.
      # Défini avant la branche ⇧, qui s'en sert aussi.
      clear_rect <- function() {
        session$sendCustomMessage("clear-polygones", ns("map"))
        leafletProxy(ns("map"), session = session) %>%
          clearGroup("Polygones") %>%
          clearGroup("drawnItems") %>%
          clearGroup("drawn")
      }

      coords <- feat$geometry$coordinates[[1]]
      lng <- vapply(coords, function(pt) as.numeric(pt[[1]]), numeric(1))
      lat <- vapply(coords, function(pt) as.numeric(pt[[2]]), numeric(1))
      bbox <- glue::glue("ST_Transform(ST_MakeEnvelope({min(lng)}, {min(lat)}, ",
                         "{max(lng)}, {max(lat)}, 4326), 2154)")

      # ⇧ enfoncée : on vise ce qui est DÉJÀ dans le secteur, pour le retirer —
      # même convention que l'onglet Sites, où ⇧ cible les éléments du site.
      if (isTRUE(input$shift_pressed)) {
        # Vérifié AVANT la requête : inutile d'interroger la base pour refuser.
        if (.selection_cadastre_en_cours() || .traces_en_cours()) { clear_rect(); return(invisible(NULL)) }
        deja <- safe_db_query(con, glue::glue("
          SELECT p.id AS pid FROM gestcons.parcelles_base p
          LEFT JOIN gestcons.dico_cadastre c
            ON p.type_parcelle_id = 1 AND c.id = p.parcellaire_id
          LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
            ON p.type_parcelle_id = 2 AND pm.id = p.parcellaire_id
           WHERE p.site_id = {sid} AND p.perimetre
             AND COALESCE(c.geompar, pm.geometrie) && {bbox}
        "))
        clear_rect()
        if (nrow(deja) == 0) {
          showToast("info", "Rien à retirer",
                    "Aucune parcelle du secteur dans cette emprise.")
          return(invisible(NULL))
        }
        # Le rectangle ALIMENTE la sélection, il ne décide de rien : c'est le
        # pied de carte qui propose ensuite de retirer ou de promouvoir.
        selection_secteur(union(selection_secteur(), as.character(deja$pid)))
        draw_selection_secteur()
        showToast("success", "Sélection",
                  sprintf("%d parcelle(s) du secteur ajoutée(s) à la sélection.", nrow(deja)))
        return(invisible(NULL))
      }

      # Exclusivité, même règle que le clic : on ne complète pas une sélection
      # cadastrale pendant une sélection du secteur. Elle manquait ici, et le
      # rectangle permettait donc de contourner la règle.
      if (.selection_secteur_en_cours() || .traces_en_cours()) { clear_rect(); return(invisible(NULL)) }

      df <- safe_db_query(con, glue::glue("
        SELECT c.idpar FROM gestcons.dico_cadastre c
         WHERE c.geompar && {bbox}
           AND NOT EXISTS (
             SELECT 1 FROM gestcons.parcelles_base p
               LEFT JOIN gestcons.sites s ON s.id = p.site_id
              WHERE p.parcellaire_id = c.id
                AND (p.site_id = {sid} OR s.type_site_id = 1))
         LIMIT {MAX_PARCELLES_RECTANGLE}
      "))
      clear_rect()
      if (nrow(df) == 0) {
        showToast("warning", "Aucune parcelle",
                  "Le rectangle ne contient aucune parcelle libre.")
        return(invisible(NULL))
      }
      selection(union(selection(), as.character(df$idpar)))
      draw_parcelles_selectionnees(selection(), con = con, map_id = ns("map"),
                                   session = session, user_roles = user_roles())
      showToast("success", "Sélection",
                sprintf("%d parcelle(s) ajoutée(s) à la sélection.", nrow(df)))
    }, ignoreInit = TRUE)

    #' Retrait en lot, confirmé après un ⇧ + rectangle.
    #' La liaison de source géométrique est en NO ACTION : elle doit être purgée
    #' avant les parcelles, d'où le CTE — un seul ordre, tout ou rien.
    observeEvent(input$retrait_lot_confirm, {
      sid <- secteur_id()
      ids <- parcelles_a_retirer()
      req(sid, length(ids) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      in_vals <- .ids_sql(ids)
      n <- tryCatch(pool::poolWithTransaction(con, function(conn) {
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_sources_geom
           WHERE parcelle_id IN (
             SELECT p.id FROM gestcons.parcelles_base p
              WHERE p.site_id = {sid} AND p.perimetre AND p.id IN ({in_vals}))
        "))
        # Les périmètres manuels AVANT les parcelles : `parcellaire_id` étant
        # polymorphe, aucune clé étrangère ne les relie, et c'est la parcelle
        # seule qui dit lesquels viser. Supprimée d'abord, l'information est
        # perdue et la géométrie reste orpheline.
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.perimetre_parcellaire_manuel pm
           USING gestcons.parcelles_base p
           WHERE pm.id = p.parcellaire_id AND p.type_parcelle_id = 2
             AND p.site_id = {sid} AND p.perimetre AND p.id IN ({in_vals})
        "))
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_base
           WHERE site_id = {sid} AND perimetre AND id IN ({in_vals})
        "))
      }), error = function(e) {
        showToast("error", "Erreur de retrait", conditionMessage(e)); NULL
      })
      if (is.null(n)) return(invisible(NULL))
      removeModal()
      parcelles_a_retirer(NULL)
      .vider_selection_secteur()
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("warning", "Secteur",
                sprintf("🗑 %s parcelle(s) retirée(s) du secteur.", n))
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : ", n,
                        " parcelle(s) retirée(s) du secteur #", sid))
    })

    #' Surbrillance des parcelles du secteur sélectionnées : contour rouge épais,
    #' NON interactif, pour que le clic continue d'atteindre la parcelle du
    #' dessous et puisse la désélectionner. Même parti pris que l'onglet Sites.
    draw_selection_secteur <- function() {
      prx <- leafletProxy(ns("map"), session = session) %>%
        clearGroup("Secteur sélectionné")
      sel <- selection_secteur()
      d   <- parcelles_secteur()
      if (length(sel) > 0 && !is.null(d) && nrow(d) > 0) {
        dd <- d[as.character(d$pid) %in% sel, , drop = FALSE]
        if (nrow(dd) > 0) {
          prx %>% addPolygons(
            data = dd, group = "Secteur sélectionné",
            # Retour au rouge : les parcelles de secteur sont de nouveau
            # bleues, l'anneau rouge y est le plus lisible.
            fill = FALSE, color = "#dc2626", weight = 4,
            options = pathOptions(pane = "selection", interactive = FALSE)
          )
        }
      }
      session$sendCustomMessage("invalidate-map", list(id = ns("map")))
      invisible(NULL)
    }

    .vider_selection_secteur <- function() {
      # Pas de sortie anticipée sur « sélection déjà vide » : l'état et le
      # dessin peuvent diverger — c'est ce qui laissait les contours rouges de
      # l'ancien secteur après une promotion, qui vide l'état en amont.
      selection_secteur(character(0))
      draw_selection_secteur()
    }
    observeEvent(input$vider_selection_secteur, { .vider_selection_secteur() })

    # Changer de secteur invalide la sélection : elle désignait d'autres
    # parcelles.
    observeEvent(secteur_id(), { .vider_selection_secteur() }, ignoreNULL = FALSE)

    #' Fiche d'une parcelle, ouverte depuis le pied de carte quand une seule est
    #' sélectionnée — comme « Modifier » pour la continuité d'un site. Plusieurs
    #' sélectionnées : la modale d'édition par lot, juste en dessous.
    observeEvent(input$parc_modifier, {
      sel <- selection_secteur()
      if (length(sel) == 0 || !isTRUE(can_edit())) return(invisible(NULL))
      if (length(sel) > 1) return(.modale_modifier_lot(sel))
      d <- parcelles_secteur()
      if (is.null(d)) return(invisible(NULL))
      ligne <- sf::st_drop_geometry(d)[as.character(d$pid) == sel[1], , drop = FALSE]
      if (nrow(ligne) == 0) return(invisible(NULL))
      parcelle_editee(sel[1])
      parcelle_editee_lbl(as.character(ligne$idpar[1]))
      showModal(modalDialog(
        title = htmltools::HTML(glue::glue("{ligne$idpar[1]} — secteur")),
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("parc_retirer"), "🗑 Retirer du secteur", class = "btn btn-danger"),
          actionButton(ns("parc_enregistrer"), "💾 Enregistrer", class = "btn btn-primary")
        ),
        # Pas de valeur vide : une parcelle de secteur porte toujours une
        # priorité. Une ligne ancienne sans priorité retombe sur 1.
        selectInput(ns("parc_priorite"), "🎯 Priorité",
                    choices = c("Priorité 1" = "1", "Priorité 2" = "2"),
                    selected = if (is.na(ligne$priorite_id[1])) "1" else as.character(ligne$priorite_id[1])),
        # Une remarque absente arrive en NA, que `%||%` laisse passer — il ne
        # teste que NULL : la zone afficherait « NA », et l'enregistrement
        # l'écrirait en base.
        textAreaInput(ns("parc_remarque"), "📝 Remarque",
                      value = if (is.na(ligne$remarque[1])) "" else ligne$remarque[1],
                      rows = 4, width = "100%")
      ))
    })

    #' Édition par lot. Même convention que l'édition en masse de l'onglet
    #' Sites : chaque champ part sur « ne pas modifier », et seuls ceux qu'on
    #' renseigne sont écrits. Rien n'est pré-rempli : les parcelles du lot
    #' n'ont pas forcément la même priorité, ni la même remarque. Pas de
    #' bouton de retrait ici : le pied de carte le propose déjà pour le lot.
    .modale_modifier_lot <- function(sel) {
      d <- parcelles_secteur()
      if (is.null(d)) return(invisible(NULL))
      lot <- sf::st_drop_geometry(d)[as.character(d$pid) %in% sel, , drop = FALSE]
      if (nrow(lot) == 0) return(invisible(NULL))
      parcelles_a_modifier(as.character(lot$pid))
      # Une remarque saisie remplace celle de chaque parcelle du lot : on dit
      # combien en ont déjà une, pour que l'écrasement ne soit pas une surprise.
      n_rem <- sum(!is.na(lot$remarque) & nzchar(trimws(lot$remarque)))
      showModal(modalDialog(
        title = sprintf("✏️ Modifier %d parcelles du secteur", nrow(lot)),
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("lot_enregistrer"), "💾 Enregistrer", class = "btn btn-primary")
        ),
        selectInput(ns("lot_priorite"), "🎯 Priorité",
                    choices = c("— ne pas modifier —" = "",
                                "Priorité 1" = "1", "Priorité 2" = "2"),
                    selected = ""),
        textAreaInput(ns("lot_remarque"), "📝 Remarque", value = "", rows = 4,
                      width = "100%", placeholder = "— ne pas modifier —"),
        div(style = "color:var(--c-encre-douce);",
            "Chaque champ laissé sur « — ne pas modifier — » sera ignoré.",
            if (n_rem == 1) {
              sprintf("Une remarque saisie ici remplace celle de chaque parcelle : 1 des %d en a déjà une.",
                      nrow(lot))
            } else if (n_rem > 1) {
              sprintf("Une remarque saisie ici remplace celle de chaque parcelle : %d des %d en ont déjà une.",
                      n_rem, nrow(lot))
            })
      ))
    }

    #' Retrait du lot sélectionné, confirmation d'abord.
    observeEvent(input$retirer_selection_secteur, {
      sel <- selection_secteur()
      if (length(sel) == 0 || !isTRUE(can_edit())) return(invisible(NULL))
      parcelles_a_retirer(sel)
      showModal(modalDialog(
        title = "🗑 Retirer des parcelles du secteur",
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("retrait_lot_confirm"),
                       sprintf("🗑 Retirer les %d parcelle(s)", length(sel)),
                       class = "btn btn-danger")
        ),
        tags$p(htmltools::HTML(glue::glue(
          "<strong>{length(sel)}</strong> parcelle(s) vont être détachées du ",
          "secteur. Leur historique d'actions est supprimé avec elles."
        )))
      ))
    })

    #' -------------------------
    #' Promotion d'un secteur en site conservatoire
    #' -------------------------
    #' La conversion se fait SUR PLACE : le secteur est déjà une ligne de
    #' `sites`, et ses parcelles pointent déjà vers lui. Changer son type suffit
    #' à en faire un site ; les parcelles sélectionnées deviennent
    #' contractuelles, et celles qu'on ne sélectionne pas restent telles
    #' quelles — elles forment mécaniquement la continuité du nouveau site.
    #' Aucun objet créé, aucune parcelle déplacée, tous les identifiants
    #' conservés : l'historique d'actions de la prospection suit intégralement.
    observeEvent(input$promouvoir_secteur, {
      sid <- secteur_id()
      sel <- selection_secteur()
      req(sid, length(sel) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))

      # Garde-fou : l'index UNIQUE(parcellaire_id) WHERE NOT perimetre interdit
      # qu'une parcelle soit parcelle de deux sites. On le vérifie AVANT, pour
      # nommer les fautives plutôt que de laisser remonter une violation.
      in_vals <- .ids_sql(sel)
      # L'index UNIQUE(parcellaire_id) WHERE NOT perimetre ignore le TYPE de
      # parcellaire : on contrôle donc comme lui, en comparant les
      # `parcellaire_id` des parcelles visées à ceux déjà contractualisés.
      conflits <- safe_db_query(con, glue::glue("
        SELECT COALESCE(c.idpar, 'périmètre manuel n°' || sel.parcellaire_id) AS idpar,
               s.libelle
          FROM gestcons.parcelles_base sel
          JOIN gestcons.parcelles_base p
            ON p.parcellaire_id = sel.parcellaire_id AND NOT p.perimetre
          JOIN gestcons.sites s ON s.id = p.site_id
          LEFT JOIN gestcons.dico_cadastre c
            ON sel.type_parcelle_id = 1 AND c.id = sel.parcellaire_id
         WHERE sel.id IN ({in_vals})
      "))
      if (nrow(conflits) > 0) {
        showModal(modalDialog(
          title = "Promotion impossible", easyClose = TRUE,
          div(class = "alert alert-warning", style = "margin-bottom:0;",
              htmltools::HTML(glue::glue(
                "Ces parcelles sont déjà parcelles d'un site, elles ne peuvent ",
                "pas l'être deux fois :<br><em>",
                # Échappés : `libelle` est le nom d'un site, saisi à la main, et
                # cette modale s'affiche chez un AUTRE utilisateur que celui
                # qui l'a écrit — un XSS stocké sinon (audit du 2026-10-28).
                paste(sprintf("%s (%s)", htmltools::htmlEscape(conflits$idpar),
                              htmltools::htmlEscape(conflits$libelle)), collapse = ", "),
                "</em>")))
        ))
        return(invisible(NULL))
      }

      contrats <- safe_db_query(con, "
        SELECT id, nom FROM gestcons.contrats_fonciers WHERE actif ORDER BY nom")
      if (nrow(contrats) == 0) {
        showModal(modalDialog(
          title = "Aucun contrat", easyClose = TRUE,
          tags$p("Aucun contrat foncier actif n'existe. Créez-le d'abord dans l'onglet Contrats : une parcelle de site doit toujours être rattachée à un contrat.")
        ))
        return(invisible(NULL))
      }

      d <- infos()
      resp <- responsable()
      choix_statut <- c("— Aucun —" = "")
      if (nrow(dico_statut_site) > 0) {
        choix_statut <- c(choix_statut,
                          stats::setNames(as.character(dico_statut_site$id), dico_statut_site$libelle))
      }
      choix_users <- c("— Aucun —" = "")
      du <- dico_utilisateur_rv()
      if (!is.null(du) && nrow(du) > 0) {
        choix_users <- c(choix_users, stats::setNames(as.character(du$id), du$nom_complet))
      }
      # Le responsable du secteur est déjà posé : on pré-remplit le champ.
      if (!is.null(resp)) d$site_responsable_id <- resp$user_id

      showModal(modalDialog(
        title = htmltools::HTML(glue::glue(
          "⬆️ Promouvoir « {htmltools::htmlEscape(d$libelle %||% '')} » en site")),
        size = "l", easyClose = TRUE, footer = NULL,
        div(class = "alert alert-info",
            htmltools::HTML(glue::glue(
              "<strong>{length(sel)}</strong> parcelle(s) sélectionnée(s) deviendront ",
              "les parcelles du site, rattachées au contrat choisi. Les autres ",
              "deviendront la <strong>continuité du site conservatoire</strong>. ",
              "Les priorités sont effacées : la prospection laisse place à la gestion.<br>",
              "⚠️ Le site entrera dans l'export FCEN dès qu'il aura un statut actif ",
              "et un gestionnaire."))),
        selectInput(ns("promo_contrat_id"), "📜 Contrat foncier des parcelles acquises *",
                    choices = stats::setNames(as.character(contrats$id), contrats$nom)),
        tags$hr(),
        # Formulaire IDENTIQUE à la création d'un site : même fabrique.
        site_form_fields(
          ns = ns, infos = d, statut_actuel = NULL,
          dico_type_milieu = dico_type_milieu,
          dico_nature_perimetre = dico_nature_perimetre,
          dico_echelle = dico_echelle, dico_precision = dico_precision,
          dico_cen = dico_cen, dico_accessibilite = dico_accessibilite,
          current_dico_utilisateur = du,
          choices_statut = choix_statut, choices_users = choix_users,
          default_echelle = DEFAUT_ECHELLE, default_precision = DEFAUT_PRECISION,
          default_cen = dico_cen$id[1], default_nature_perimetre = DEFAUT_NATURE_PERIM,
          geol_ui = selectInput(ns("geol_id"), "Géologie *",
                                choices = geol_choices(),
                                selected = as.character(d$geol_id %||% DEFAUT_GEOL))
        ),
        tags$div(style = "margin-top:16px; text-align:right;",
                 modalButton("Annuler"),
                 actionButton(ns("promo_confirm"), "⬆️ Promouvoir en site",
                              class = "btn btn-success"))
      ))
    })

    observeEvent(input$promo_confirm, {
      sid <- secteur_id()
      sel <- selection_secteur()
      req(sid, length(sel) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      contrat <- suppressWarnings(as.integer(input$promo_contrat_id))
      if (is.na(contrat)) {
        showToast("warning", "Contrat manquant", "Choisissez le contrat des parcelles acquises.")
        return(invisible(NULL))
      }
      lib <- trimws(input$libelle %||% "")
      if (!nzchar(lib)) {
        showToast("warning", "Nom manquant", "Le nom du site est obligatoire.")
        return(invisible(NULL))
      }
      u <- dbQuoteLiteral(con, user_to_db())
      # `sel` porte des parcelles_base.id, pas des références cadastrales.
      in_vals <- .ids_sql(sel)
      precision <- input$precision_num_site_id %||% DEFAUT_PRECISION

      ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          # 1. Le secteur devient un site.
          safe_db_execute(conn, glue::glue("
            UPDATE gestcons.sites SET
              type_site_id          = {TYPE_SITE_CONSERVATOIRE},
              libelle               = {dbQuoteLiteral(conn, lib)},
              id_site_fcen          = NULLIF({dbQuoteLiteral(conn, input$id_site_fcen %||% '')}, ''),
              type_milieu_id        = {.ent(input$type_milieu_id, DEFAUT_TYPE_MILIEU)},
              geol_id               = {.ent(input$geol_id, DEFAUT_GEOL)},
              nature_perimetre_id   = {.ent(input$nature_perimetre_id, DEFAUT_NATURE_PERIM)},
              echelle_num_id        = {.ent(input$echelle_num_id, DEFAUT_ECHELLE)},
              precision_num_site_id = {dbQuoteLiteral(conn, as.character(precision))},
              gestionnaire_site     = NULLIF({dbQuoteLiteral(conn, as.character(input$gestionnaire_site %||% ''))}, ''),
              terrain_militaire_id  = {ifelse(isTRUE(input$terrain_militaire), 1L, 0L)},
              site_marin_id         = {ifelse(isTRUE(input$site_marin), 1L, 0L)},
              date_crea_site        = {sql_date(input$date_crea_site)},
              date_maj_site         = {sql_date(input$date_maj_site)},
              description_site      = {dbQuoteLiteral(conn, input$description_site %||% '')},
              -- Sensibilité et diffusion : la fabrique partagée les affiche
              -- désormais à la promotion, puisque le secteur DEVIENT un site.
              -- Les montrer sans les écrire les rendrait trompeuses.
              sensibilite           = {sql_bool(input$sensibilite)},
              non_diffusion         = {sql_bool(input$non_diffusion)},
              remq_sensibilite      = {sql_txt(remq_sensibilite_saisie(input$sensibilite, input$remq_sensibilite))},
              accessibilite_site    = {accessibilite_saisie(input$accessibilite_site)},
              accessibilite_pmr_site = {accessibilite_pmr_saisie(input$accessibilite_site, input$accessibilite_pmr_site)},
              modifie_par = {u}, date_modification = NOW()
            WHERE id = {sid} AND type_site_id = {TYPE_SITE_SECTEUR}
          "))

          # 2. Statut, s'il est renseigné — c'est lui qui ouvre l'export FCEN.
          st <- input$statut_site_id
          if (!is.null(st) && nzchar(st)) {
            safe_db_execute(conn, glue::glue("
              INSERT INTO gestcons.sites_statuts (site_id, statut_site_id, date_debut, remarque)
              VALUES ({sid}, {as.integer(st)}, {sql_date(input$statut_date_debut %||% Sys.Date())},
                      {dbQuoteLiteral(conn, input$statut_remarque %||% '')})
            "))
          }

          # 3. Les parcelles sélectionnées deviennent contractuelles.
          safe_db_execute(conn, glue::glue("
            UPDATE gestcons.parcelles_base
               SET perimetre = FALSE, modifie_par = {u}, date_modification = NOW()
             WHERE site_id = {sid} AND perimetre AND id IN ({in_vals})
          "))
          safe_db_execute(conn, glue::glue("
            INSERT INTO gestcons.contrats_foncier_parcelles (contrat_id, parcelle_id)
            SELECT {contrat}, p.id FROM gestcons.parcelles_base p
             WHERE p.site_id = {sid} AND NOT p.perimetre
            ON CONFLICT DO NOTHING
          "))

          # 4. Les priorités disparaissent — y compris sur la continuité.
          safe_db_execute(conn, glue::glue("
            UPDATE gestcons.parcelles_base SET priorite_id = NULL WHERE site_id = {sid}
          "))
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Erreur de promotion", conditionMessage(e)); FALSE
      })
      if (!isTRUE(ok)) return(invisible(NULL))

      .enregistrer_responsable(sid)
      removeModal()
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : secteur #", sid, " promu en site (",
                        length(sel), " parcelle(s) contractualisée(s))"))

      # Le secteur n'existe plus comme tel : on quitte l'onglet et on ouvre le
      # nouveau site là où il vit désormais.
      # Le secteur n'existe plus : on efface ses couches et on rend la carte à
      # sa vue par défaut. Sans ça, revenir sur cet onglet montre encore
      # l'emprise et les contours de l'ancien secteur.
      .vider_selection_secteur()
      leafletProxy(ns("map"), session = session) %>%
        clearGroup("Parcelles du secteur") %>%
        clearGroup("Parcelles cadastrales") %>%
        clearGroup("Parcelle sélectionnée") %>%
        clearGroup("Secteur sélectionné") %>%
        setView(lng = MAP_DEFAULT_LNG, lat = MAP_DEFAULT_LAT, zoom = MAP_DEFAULT_ZOOM)
      selection(character(0))
      parcelles_cache(sf::st_sf(geometry = sf::st_sfc(crs = 4326)))
      parcelles_cache_bbox(NULL)
      invalidate_cadastre_hash(ns("map"), session)
      secteur_id(NULL)
      refresh_secteurs(select = "")
      if (!is.null(contrats_update_trigger)) {
        contrats_update_trigger(isolate(contrats_update_trigger()) + 1L)
      }
      # La liste partagée des sites alimente les autres onglets (Actions,
      # Contrats) : sans ce rafraîchissement, le nouveau site n'y apparaîtrait
      # qu'au prochain démarrage de l'application.
      if (!is.null(sites_shared)) {
        sites_shared(safe_db_query(con, "SELECT id, libelle FROM gestcons.sites
                                          WHERE type_site_id = 1 ORDER BY libelle"))
      }
      selected_site_rv(as.integer(sid))
      # Au changement d'onglet, l'application réapplique à la nouvelle carte la
      # vue capturée sur la précédente, pour qu'on garde la même zone en
      # naviguant. Ici c'est l'inverse de ce qu'on veut : on vient montrer un
      # site précis. Et comme la carte de cet onglet n'alimente pas cette
      # capture, la vue réappliquée serait une ancienne vue départementale —
      # elle arriverait après le cadrage et l'écraserait. On l'efface donc :
      # l'onglet Sites se recadrera alors sur le site lui-même.
      if (!is.null(map_view_rv)) map_view_rv(NULL)
      updateTabsetPanel(session$rootScope(), "main_tabs", selected = "tab-sites")
      showToast("success", "Site créé",
                sprintf("⬆️ Le secteur est devenu un site : %d parcelle(s) contractualisée(s).",
                        length(sel)))
    })

    .vider_selection <- function() {
      if (length(isolate(selection())) == 0) return(invisible(NULL))
      selection(character(0))
      draw_parcelles_selectionnees(character(0), con = con, map_id = ns("map"),
                                   session = session, user_roles = user_roles())
    }
    observeEvent(input$vider_selection, { .vider_selection() })

    #' Ajout au secteur. Mêmes défauts de maîtrise que l'ajout à la zone
    #' d'intérêt d'un site, et la source géométrique est posée dans la foulée —
    #' la liaison est obligatoire depuis la v1.5.
    observeEvent(input$ajouter_au_secteur, {
      sid <- secteur_id()
      ids <- selection()
      req(sid, length(ids) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      prio <- input$ajout_priorite
      prio_sql <- if (is.null(prio) || !nzchar(prio)) "NULL" else as.character(as.integer(prio))
      u <- dbQuoteLiteral(con, user_to_db())
      in_vals <- paste(dbQuoteString(con, ids), collapse = ",")

      n <- tryCatch(safe_db_execute(con, glue::glue("
        WITH ins AS (
          INSERT INTO gestcons.parcelles_base (
            site_id, parcellaire_id, type_parcelle_id, perimetre, priorite_id,
            mesure_compens_id, echelle_numerisation_id, source_surf_parc_id,
            bnd_id, pour_part_id, surf_parc_maitrise_m2, domaine_public_id,
            proprietaire_id, zpf_id, chasse_id, actif,
            cree_par, date_creation, modifie_par, date_modification
          )
          SELECT {sid}, c.id, 1, true, {prio_sql},
                 0, 1, 1,
                 0, 0, c.dcntpa, 0,
                 '4', 0, 1, true,
                 {u}, NOW(), {u}, NOW()
          FROM gestcons.dico_cadastre c
          WHERE c.idpar IN ({in_vals})
            -- Invariant : une parcelle rattachée à un SITE — contractuelle ou
            -- en continuité — ne peut pas figurer dans un secteur. Le filtre
            -- est rejoué ICI et pas seulement à la sélection : entre les deux,
            -- la parcelle a pu être rattachée ailleurs.
            AND NOT EXISTS (
              SELECT 1 FROM gestcons.parcelles_base p
                LEFT JOIN gestcons.sites s ON s.id = p.site_id
               WHERE p.parcellaire_id = c.id AND s.type_site_id = 1)
          ON CONFLICT (site_id, parcellaire_id) WHERE perimetre DO NOTHING
          RETURNING id
        )
        INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
        SELECT id, {SOURCE_GEOM_PCI} FROM ins
        ON CONFLICT DO NOTHING
      ")), error = function(e) {
        showToast("error", "Erreur d'ajout", conditionMessage(e)); NULL
      })
      if (is.null(n)) return(invisible(NULL))

      # Acteurs « propriétaire » : même règle que l'ajout à un site ou à sa
      # continuité. Elle manquait ici, et c'est ce qui laissait 68
      # propriétaires de parcelles de secteur absents des acteurs
      # (rattrapés le 2026-10-26).
      #
      # On passe TOUTE la sélection, et non les seules lignes insérées : la
      # fonction dédoublonne, et le propriétaire d'une parcelle déjà rattachée
      # est de toute façon déjà acteur. L'échec de cette création ne doit pas
      # remettre en cause le rattachement, déjà écrit : on le signale, sans
      # plus.
      acteurs_ins <- tryCatch(
        pool::poolWithTransaction(con, function(conn) {
          creer_acteurs_proprietaires(conn, ids, type_acteur_proprio_id)
        }),
        error = function(e) {
          message("Acteurs (secteur) : ", conditionMessage(e))
          showToast("warning", "Acteurs non créés",
                    "Les parcelles sont rattachées, mais leurs propriétaires n'ont pas pu être ajoutés aux acteurs.")
          NULL
        }
      )
      if (!is.null(acteurs_ins) && nrow(acteurs_ins) > 0) {
        if (!is.null(acteurs_existants)) {
          try(acteurs_existants(fetch_acteurs_choices(con)), silent = TRUE)
        }
        showToast("success", "Acteurs ajoutés",
                  sprintf("%d acteur(s) inséré(s).", nrow(acteurs_ins)))
      }

      .vider_selection()
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("success", "Secteur",
                sprintf("✅ %s parcelle(s) rattachée(s) au secteur.", n))
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : ", n, " parcelle(s) ajoutée(s) au secteur #", sid))
    })

    #' Effacer les tracés en attente : l'ÉTAT et le DESSIN. Leaflet.Draw dépose
    #' sa forme dans ses propres calques en plus du groupe cible, d'où le
    #' triple nettoyage — même parade que pour le rectangle de sélection.
    .vider_polygones <- function() {
      polygones_temp(list())
      session$sendCustomMessage("clear-polygones", ns("map"))
      leafletProxy(ns("map"), session = session) %>%
        clearGroup("Polygones") %>%
        clearGroup("drawnItems") %>%
        clearGroup("drawn")
      invisible(NULL)
    }
    observeEvent(input$vider_polygones, { .vider_polygones() })

    # Les tracés en attente s'affichent DEPUIS L'ÉTAT : cf.
    # draw_traces_en_attente (helpers.R). Vider l'état les efface donc aussi.
    observe({ draw_traces_en_attente(polygones_temp(), ns("map"), session) })

    # Changer de secteur abandonne les tracés : ils visaient l'autre.
    observeEvent(secteur_id(), { .vider_polygones() }, ignoreNULL = FALSE)

    #' Enregistrement des périmètres tracés.
    #'
    #' Deux écritures par polygone, dans cet ordre : la géométrie d'abord, la
    #' parcelle qui la désigne ensuite. L'ordre n'est pas indifférent — c'est
    #' l'insertion dans `parcelles_base` qui déclenche le rattachement
    #' territorial (trigger `parcelle_base_communes`), et il n'aurait rien à
    #' rattacher si la géométrie n'existait pas encore.
    #'
    #' Pas de contrat, pas d'acteur : une parcelle de secteur n'en porte pas,
    #' et un polygone dessiné n'a aucun propriétaire connu.
    observeEvent(input$ajouter_perimetre_secteur, {
      sid   <- secteur_id()
      polys <- polygones_temp()
      req(sid, length(polys) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      prio <- input$ajout_priorite_poly
      prio_sql <- if (is.null(prio) || !nzchar(prio)) "NULL" else as.character(as.integer(prio))
      u <- dbQuoteLiteral(con, user_to_db())

      res <- tryCatch(pool::poolWithTransaction(con, function(conn) {
        poses <- 0L
        ignores <- 0L
        for (poly in polys) {
          coords <- tryCatch(poly$geometry$coordinates[[1]], error = function(e) NULL)
          if (is.null(coords) || length(coords) < 3) { ignores <- ignores + 1L; next }
          mat <- do.call(rbind, lapply(coords, function(pt) {
            c(as.numeric(pt[[1]]), as.numeric(pt[[2]]))
          }))
          # Leaflet ne referme pas toujours l'anneau ; sf l'exige.
          if (!all(mat[1, ] == mat[nrow(mat), ])) mat <- rbind(mat, mat[1, ])
          if (nrow(mat) < 4) { ignores <- ignores + 1L; next }

          sfc_2154 <- sf::st_transform(
            sf::st_sfc(sf::st_polygon(list(mat)), crs = 4326), 2154)
          surface_m2 <- as.numeric(sf::st_area(sfc_2154))
          # Un tracé dégénéré — double-clic malheureux — ne doit pas devenir
          # une parcelle de 0 m² qu'il faudrait ensuite retrouver et effacer.
          if (!is.finite(surface_m2) || surface_m2 < 1) { ignores <- ignores + 1L; next }
          wkt <- sf::st_as_text(sfc_2154)

          # ST_Multi explicite : la colonne est geometry(MultiPolygon, 2154).
          geom_id <- tx_insert(conn, glue::glue("
            INSERT INTO gestcons.perimetre_parcellaire_manuel
              (geometrie, actif, remarque,
               cree_par, date_creation, modifie_par, date_modification)
            VALUES (ST_Multi(ST_GeomFromText('{wkt}', 2154)), TRUE, ' ',
                    {u}, NOW(), {u}, NOW())
            RETURNING id
          "))
          if (is.null(geom_id)) stop("l'enregistrement d'un périmètre a échoué")

          # perimetre = TRUE : pour un SECTEUR, toutes les parcelles le portent.
          # Cf. l'inversion documentée dans helpers.R — le même drapeau désigne
          # la continuité d'un site.
          parcelle_id <- tx_insert(conn, glue::glue("
            INSERT INTO gestcons.parcelles_base (
              site_id, parcellaire_id, type_parcelle_id, perimetre, priorite_id,
              mesure_compens_id, echelle_numerisation_id, source_surf_parc_id,
              bnd_id, pour_part_id, surf_parc_maitrise_m2, domaine_public_id,
              proprietaire_id, zpf_id, chasse_id, actif,
              cree_par, date_creation, modifie_par, date_modification
            ) VALUES (
              {sid}, {geom_id}, 2, true, {prio_sql},
              0, 1, 1,
              0, 0, {round(surface_m2)}, 0,
              '4', 0, 1, true,
              {u}, NOW(), {u}, NOW()
            ) RETURNING id
          "))
          if (is.null(parcelle_id)) stop("le rattachement d'un périmètre a échoué")

          # Source géométrique : un polygone dessiné est une numérisation CEN,
          # pas du cadastre. La liaison est obligatoire depuis la v1.5.
          tx_execute(conn, glue::glue("
            INSERT INTO gestcons.parcelles_sources_geom (parcelle_id, source_geom_id)
            VALUES ({parcelle_id}, {SOURCE_GEOM_MANUELLE})
            ON CONFLICT DO NOTHING
          "))
          poses <- poses + 1L
        }
        if (poses == 0L) stop("aucun tracé exploitable")
        list(poses = poses, ignores = ignores)
      }), error = function(e) {
        showToast("error", "Erreur d'enregistrement", conditionMessage(e)); NULL
      })
      if (is.null(res)) return(invisible(NULL))

      .vider_polygones()
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("success", "Secteur",
                sprintf("✅ %d périmètre(s) rattaché(s) au secteur.", res$poses))
      if (res$ignores > 0) {
        showToast("warning", "Tracés ignorés",
                  sprintf("%d tracé(s) sans surface exploitable ont été écartés.", res$ignores))
      }
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : ", res$poses,
                        " périmètre(s) manuel(s) ajouté(s) au secteur #", sid))
    })

    #' Édition d'une parcelle du secteur : priorité et remarque.
    observeEvent(input$parc_enregistrer, {
      sid <- secteur_id(); pid <- parcelle_editee()
      req(sid, pid)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      lbl  <- parcelle_editee_lbl() %||% "La parcelle"
      prio <- input$parc_priorite
      prio_sql <- if (is.null(prio) || !nzchar(prio)) "NULL" else as.character(as.integer(prio))
      ok <- tryCatch({
        safe_db_execute(con, glue::glue("
          UPDATE gestcons.parcelles_base
             SET priorite_id = {prio_sql},
                 remarque    = {dbQuoteLiteral(con, input$parc_remarque %||% '')},
                 modifie_par = {dbQuoteLiteral(con, user_to_db())},
                 date_modification = NOW()
           WHERE site_id = {sid} AND perimetre AND id IN ({.ids_sql(pid)})
        "))
        TRUE
      }, error = function(e) { showToast("error", "Erreur", conditionMessage(e)); FALSE })
      if (!isTRUE(ok)) return(invisible(NULL))
      removeModal(); parcelle_editee(NULL); parcelle_editee_lbl(NULL)
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("success", "Parcelle enregistrée", paste0(lbl, " : enregistrée."))
    })

    #' Édition par lot : un seul ordre, limité aux champs renseignés. Il passe
    #' en transaction pour que l'erreur remonte : hors transaction,
    #' safe_db_execute la capture et renvoie 0, et le succès serait annoncé
    #' quand même.
    observeEvent(input$lot_enregistrer, {
      sid <- secteur_id(); ids <- parcelles_a_modifier()
      req(sid, length(ids) > 0)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      prio <- input$lot_priorite %||% ""
      rem  <- input$lot_remarque %||% ""
      setv <- c(
        if (prio %in% c("1", "2")) paste0("priorite_id = ", prio),
        if (nzchar(trimws(rem)))   paste0("remarque = ", dbQuoteLiteral(con, rem))
      )
      if (length(setv) == 0) {
        showToast("warning", "Rien à modifier",
                  "Choisissez une priorité ou saisissez une remarque, ou annulez.")
        return(invisible(NULL))
      }
      n <- tryCatch(pool::poolWithTransaction(con, function(conn) {
        safe_db_execute(conn, glue::glue("
          UPDATE gestcons.parcelles_base
             SET {paste(setv, collapse = ', ')},
                 modifie_par = {dbQuoteLiteral(conn, user_to_db())},
                 date_modification = NOW()
           WHERE site_id = {sid} AND perimetre AND id IN ({.ids_sql(ids)})
        "))
      }), error = function(e) {
        showToast("error", "Erreur d'enregistrement", conditionMessage(e)); NULL
      })
      if (is.null(n)) return(invisible(NULL))
      removeModal(); parcelles_a_modifier(NULL)
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("success", "Parcelles enregistrées",
                sprintf("%s parcelle(s) du secteur modifiée(s).", n))
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : ", n,
                        " parcelle(s) du secteur #", sid, " modifiée(s) par lot"))
    })

    #' Retrait. La liaison de source géométrique est en NO ACTION : il faut la
    #' purger avant, sous peine d'échec. Un seul ordre SQL.
    observeEvent(input$parc_retirer, {
      sid <- secteur_id(); pid <- parcelle_editee()
      req(sid, pid)
      if (!isTRUE(can_edit())) return(invisible(NULL))
      lbl <- parcelle_editee_lbl() %||% paste0("parcelle #", pid)
      in_vals <- .ids_sql(pid)
      n <- tryCatch(pool::poolWithTransaction(con, function(conn) {
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_sources_geom
           WHERE parcelle_id IN (
             SELECT p.id FROM gestcons.parcelles_base p
              WHERE p.site_id = {sid} AND p.perimetre AND p.id IN ({in_vals}))
        "))
        # Même ordre qu'au retrait en lot : le périmètre manuel d'abord, la
        # parcelle qui le désigne ensuite.
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.perimetre_parcellaire_manuel pm
           USING gestcons.parcelles_base p
           WHERE pm.id = p.parcellaire_id AND p.type_parcelle_id = 2
             AND p.site_id = {sid} AND p.perimetre AND p.id IN ({in_vals})
        "))
        safe_db_execute(conn, glue::glue("
          DELETE FROM gestcons.parcelles_base
           WHERE site_id = {sid} AND perimetre AND id IN ({in_vals})
        "))
      }), error = function(e) {
        showToast("error", "Erreur de retrait", conditionMessage(e)); NULL
      })
      if (is.null(n)) return(invisible(NULL))
      removeModal(); parcelle_editee(NULL); parcelle_editee_lbl(NULL)
      .vider_selection_secteur()
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("warning", "Parcelle retirée",
                paste0(lbl, " a été retirée du secteur."))
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : ", lbl, " retirée du secteur #", sid))
    })

    #' -------------------------
    #' Formulaire, en modale — comme pour un site
    #' -------------------------
    .modale_formulaire <- function(creation) {
      d    <- if (creation) NULL else infos()
      resp <- if (creation) NULL else responsable()
      # Valeur réellement posée dans le sélecteur : un responsable absent de la
      # liste des utilisateurs laisse le champ vide, et c'est ce vide qu'il faut
      # mémoriser pour ne pas le prendre ensuite pour un choix.
      resp_rendu({
        ids <- as.character(dico_utilisateur_rv()$id)
        if (!is.null(resp) && as.character(resp$user_id) %in% ids) {
          as.character(resp$user_id)
        } else ""
      })
      resp_date_rendue(if (is.null(resp)) Sys.Date() else as.Date(resp$date_debut))
      form_secteur_rendu(isolate(form_secteur_rendu()) + 1L)
      val  <- function(champ, defaut = "") {
        if (is.null(d) || is.null(d[[champ]]) || is.na(d[[champ]])) defaut else d[[champ]]
      }
      showModal(modalDialog(
        title = if (creation) "➕ Nouveau secteur d'intervention prioritaire"
                else paste("✏️ Modifier le secteur", val("libelle")),
        size = "l",
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          actionButton(ns("enregistrer"), if (creation) "💾 Créer" else "💾 Enregistrer",
                       class = "btn btn-primary"),
          if (!creation) {
            actionButton(ns("supprimer"), "🗑 Supprimer", class = "btn btn-danger")
          }
        ),
        fluidPage(
          div(
            style = "display:flex; gap:24px; flex-wrap:wrap;",
            div(
              style = "flex:1 1 45%; min-width:300px;",
              textInput(ns("libelle"), "Nom *", value = val("libelle")),
              selectInput(ns("type_milieu_id"), "Type de milieu *",
                          choices = stats::setNames(as.character(dico_type_milieu$id), dico_type_milieu$libelle),
                          selected = as.character(val("type_milieu_id", DEFAUT_TYPE_MILIEU))),
              selectInput(ns("geol_id"), "Géologie *",
                          choices = geol_choices(),
                          selected = as.character(val("geol_id", DEFAUT_GEOL))),
              selectInput(ns("nature_perimetre_id"), "Nature du périmètre *",
                          choices = stats::setNames(as.character(dico_nature_perimetre$id), dico_nature_perimetre$libelle),
                          selected = as.character(val("nature_perimetre_id", DEFAUT_NATURE_PERIM))),
              selectInput(ns("echelle_num_id"), "Échelle de numérisation *",
                          choices = stats::setNames(as.character(dico_echelle$id), dico_echelle$libelle),
                          selected = as.character(val("echelle_num_id", DEFAUT_ECHELLE))),
              selectInput(ns("precision_num_site_id"), "Précision *",
                          choices = stats::setNames(as.character(dico_precision$id), dico_precision$libelle),
                          selected = as.character(val("precision_num_site_id", DEFAUT_PRECISION)))
            ),
            div(
              style = "flex:1 1 45%; min-width:300px;",
              dateInput(ns("date_crea_site"), "📆 Date de création",
                        value = if (is.null(d)) Sys.Date() else as.Date(val("date_crea_site", Sys.Date()))),
              dateInput(ns("date_maj_site"), "📆 Date de mise à jour",
                        value = if (is.null(d)) Sys.Date() else as.Date(val("date_maj_site", Sys.Date()))),
              textAreaInput(ns("description_site"), "📝 Description",
                            value = val("description_site"), height = "90px"),
              # « Sensible ? » et « Non diffusable ? » ont quitté ce formulaire
              # le 2026-10-28 pour celui d'un SITE : elles sont proposées à la
              # promotion, quand le secteur en devient un.
              selectInput(ns("responsable_id"), "Responsable du secteur",
                          choices = c("— Aucun —" = "", stats::setNames(
                            as.character(dico_utilisateur_rv()$id), dico_utilisateur_rv()$nom_complet)),
                          selected = if (is.null(resp)) "" else as.character(resp$user_id)),
              conditionalPanel(
                condition = sprintf("input['%s'] != ''", ns("responsable_id")),
                dateInput(ns("responsable_date"), "📆 Début de responsabilité",
                          value = if (is.null(resp)) Sys.Date() else as.Date(resp$date_debut))
              )
            )
          )
        )
      ))
    }

    # Bouton « Créer » / « Enregistrer » inactif tant que les six champs
    # obligatoires (*) du formulaire de secteur ne sont pas renseignés — mêmes
    # champs que la fiche d'un site, le formulaire étant le même. Le bouton est
    # rendu ACTIF : l'envelopper dans shinyjs::disabled() crée une course, la
    # désactivation étant appliquée après le bind et écrasant la réactivation
    # (cf. mod_actions.R). C'est donc cet observateur qui le désactive.
    observe({
      form_secteur_rendu()
      toggle_submit_state(
        input, "enregistrer",
        c("libelle", "type_milieu_id", "geol_id",
          "nature_perimetre_id", "echelle_num_id", "precision_num_site_id")
      )
    })

    observeEvent(input$add_secteur, {
      if (!isTRUE(can_create())) {
        showToast("warning", "Lecture seule", "Seul un administrateur peut créer un secteur.")
        return(invisible(NULL))
      }
      updateSelectizeInput(session, "secteur_selector", selected = "")
      secteur_id(NA_integer_)
      .modale_formulaire(creation = TRUE)
    })

    observeEvent(input$edit_secteur, {
      if (is.null(secteur_id()) || is.na(secteur_id())) return(invisible(NULL))
      if (!isTRUE(can_edit())) {
        showToast("warning", "Lecture seule",
                  "Vous n'êtes ni administrateur ni responsable de ce secteur.")
        return(invisible(NULL))
      }
      .modale_formulaire(creation = FALSE)
    })

    #' -------------------------
    #' Enregistrement
    #' -------------------------
    # Les cinq champs étant NOT NULL en base, on substitue le repli plutôt que
    # d'émettre un NULL que PostgreSQL refuserait.
    .ent <- function(x, repli) {
      v <- suppressWarnings(as.integer(x))
      if (is.null(x) || !nzchar(x) || is.na(v)) as.character(repli) else as.character(v)
    }

    observeEvent(input$enregistrer, {
      creation <- is.null(secteur_id()) || is.na(secteur_id())
      if (creation && !isTRUE(can_create())) return(invisible(NULL))
      if (!creation && !isTRUE(can_edit()))  return(invisible(NULL))

      lib <- trimws(input$libelle %||% "")
      if (!nzchar(lib)) {
        showToast("warning", "Nom manquant", "Le nom est obligatoire.")
        return(invisible(NULL))
      }

      u <- user_to_db()
      precision <- input$precision_num_site_id
      if (is.null(precision) || !nzchar(precision)) precision <- DEFAUT_PRECISION

      champs <- glue::glue("
        libelle               = {dbQuoteLiteral(con, lib)},
        type_milieu_id        = {.ent(input$type_milieu_id, DEFAUT_TYPE_MILIEU)},
        geol_id               = {.ent(input$geol_id, DEFAUT_GEOL)},
        nature_perimetre_id   = {.ent(input$nature_perimetre_id, DEFAUT_NATURE_PERIM)},
        echelle_num_id        = {.ent(input$echelle_num_id, DEFAUT_ECHELLE)},
        precision_num_site_id = {dbQuoteLiteral(con, as.character(precision))},
        date_crea_site        = {sql_date(input$date_crea_site)},
        date_maj_site         = {sql_date(input$date_maj_site)},
        description_site      = {dbQuoteLiteral(con, input$description_site %||% '')}
      ")
      # ⚠️ Ni `sensibilite` ni `non_diffusion` ici : le formulaire du secteur
      # ne les porte plus, et `input$sensibilite` désigne désormais la case de
      # la MODALE DE PROMOTION, dans le même espace de noms. La relire ici
      # recopierait dans le secteur l'état d'une promotion ouverte puis
      # abandonnée. À la création, la valeur par défaut de la base (false)
      # s'applique, l'INSERT ne citant pas ces colonnes.

      nouvel_id <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          if (creation) {
            # type_site_id explicite plutôt que le DEFAULT : la valeur est le
            # sens même de ce module, elle ne doit pas dépendre du schéma.
            id <- safe_db_query(conn, glue::glue("
              INSERT INTO gestcons.sites
                     (type_site_id, actif, cree_par, date_creation,
                      modifie_par, date_modification, libelle,
                      type_milieu_id, geol_id, nature_perimetre_id,
                      echelle_num_id, precision_num_site_id)
              VALUES ({TYPE_SITE_SECTEUR}, TRUE, {dbQuoteLiteral(conn, u)}, NOW(),
                      {dbQuoteLiteral(conn, u)}, NOW(), {dbQuoteLiteral(conn, lib)},
                      {DEFAUT_TYPE_MILIEU}, {DEFAUT_GEOL}, {DEFAUT_NATURE_PERIM},
                      {DEFAUT_ECHELLE}, {dbQuoteLiteral(conn, as.character(DEFAUT_PRECISION))})
              RETURNING id
            "))$id[1]
            safe_db_execute(conn, glue::glue("
              UPDATE gestcons.sites SET {champs},
                     modifie_par = {dbQuoteLiteral(conn, u)}, date_modification = NOW()
               WHERE id = {id}
            "))
            id
          } else {
            id <- secteur_id()
            safe_db_execute(conn, glue::glue("
              UPDATE gestcons.sites SET {champs},
                     modifie_par = {dbQuoteLiteral(conn, u)}, date_modification = NOW()
               WHERE id = {id} AND type_site_id = {TYPE_SITE_SECTEUR}
            "))
            id
          }
        })
      }, error = function(e) {
        showToast("error", "Erreur d'enregistrement", conditionMessage(e))
        NULL
      })
      if (is.null(nouvel_id)) return(invisible(NULL))

      .enregistrer_responsable(nouvel_id)
      removeModal()
      refresh_secteurs(select = nouvel_id)
      secteur_id(as.integer(nouvel_id))
      refresh_trigger(isolate(refresh_trigger()) + 1)
      showToast("success", if (creation) "Secteur créé" else "Secteur enregistré", lib)
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : secteur #", nouvel_id,
                        if (creation) " créé" else " modifié"))
    })

    # --- Date de début : aujourd'hui quand on change de responsable ---------
    # Sans cela, choisir un nouveau responsable conservait la date affichée,
    # celle du titulaire précédent : la nouvelle période démarrait donc avant
    # la clôture de l'ancienne. Les sites font de même ; la comparaison avec la
    # valeur affichée évite de confondre un choix avec une reconstruction de la
    # modale, et revenir au titulaire d'origine rétablit sa date enregistrée.
    observeEvent(input$responsable_id, {
      sel <- input$responsable_id
      if (is.null(sel)) return()

      if (identical(sel, resp_rendu())) {
        if (!is.null(resp_date_rendue())) {
          shiny::updateDateInput(session, "responsable_date", value = resp_date_rendue())
        }
        return()
      }

      if (nzchar(sel)) {
        shiny::updateDateInput(session, "responsable_date", value = Sys.Date())
      }
    }, ignoreInit = FALSE)

    #' Responsable : une seule ligne active à la fois. On clôt l'ancienne plutôt
    #' que de la supprimer, l'historique des responsabilités a de la valeur.
    #'
    #' La logique est la même que pour les sites, et c'est la même fonction qui
    #' la porte : maj_role_site() distingue la correction d'une date de début —
    #' qui modifie la ligne en cours — du changement de titulaire, seul à ouvrir
    #' une période. Sans cette distinction, une tenure continue se retrouve
    #' découpée en tranches ; 37 lignes de responsable_sites ont dû être
    #' fusionnées pour cette raison.
    .enregistrer_responsable <- function(sid) {
      choisi  <- input$responsable_id
      actuel  <- responsable()
      nouveau <- if (is.null(choisi) || !nzchar(choisi)) NA_integer_ else as.integer(choisi)
      ancien  <- if (is.null(actuel)) NA_integer_ else as.integer(actuel$user_id)
      if (is.na(nouveau) && is.na(ancien)) return(invisible(NULL))

      jour_saisi  <- .jour_txt(input$responsable_date %||% Sys.Date())
      jour_actuel <- if (is.null(actuel)) NA_character_ else .jour_txt(actuel$date_debut)

      # La date seule ne déclenchait rien : on ne comparait que les personnes,
      # et la correction était silencieusement perdue, sans même un message.
      if (identical(nouveau, ancien) && identical(jour_saisi, jour_actuel)) {
        return(invisible(NULL))
      }

      tryCatch(
        pool::poolWithTransaction(con, function(conn) {
          maj_role_site(conn, "responsable_sites", sid, nouveau, jour_saisi,
                        user_to_db(), ancien)
        }),
        error = function(e) {
          showToast("error", "Responsable", conditionMessage(e))
        }
      )
    }

    #' -------------------------
    #' Suppression
    #' -------------------------
    observeEvent(input$supprimer, {
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid) || !isTRUE(can_edit())) return(invisible(NULL))
      n_parc <- safe_db_query(con, glue::glue("
        SELECT count(*)::int AS n FROM gestcons.parcelles_base WHERE site_id = {sid}
      "))$n[1]
      showModal(modalDialog(
        title = "Supprimer le secteur",
        easyClose = TRUE,
        footer = tagList(
          modalButton("Annuler"),
          if (n_parc == 0) {
            actionButton(ns("supprimer_confirm"), "🗑 Confirmer", class = "btn btn-danger")
          }
        ),
        if (n_parc > 0) {
          div(class = "alert alert-warning", style = "margin-bottom:0;",
              htmltools::HTML(glue::glue(
                "Ce secteur contient <strong>{n_parc}</strong> parcelle(s). ",
                "Retirez-les d'abord : la suppression d'un secteur ne doit pas ",
                "emporter silencieusement son parcellaire et l'historique ",
                "d'actions qui s'y rattache.")))
        } else {
          tags$p("Ce secteur ne contient aucune parcelle. Confirmer sa suppression ?")
        }
      ))
    })

    observeEvent(input$supprimer_confirm, {
      sid <- secteur_id()
      if (is.null(sid) || is.na(sid) || !isTRUE(can_edit())) return(invisible(NULL))
      ok <- tryCatch({
        pool::poolWithTransaction(con, function(conn) {
          safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.responsable_sites WHERE site_id = {sid}
          "))
          n <- safe_db_execute(conn, glue::glue("
            DELETE FROM gestcons.sites
             WHERE id = {sid} AND type_site_id = {TYPE_SITE_SECTEUR}
               AND NOT EXISTS (SELECT 1 FROM gestcons.parcelles_base p WHERE p.site_id = {sid})
          "))
          if (is.null(n) || n == 0) stop("Le secteur n'a pas pu être supprimé.")
        })
        TRUE
      }, error = function(e) {
        showToast("error", "Erreur de suppression", conditionMessage(e)); FALSE
      })
      if (!isTRUE(ok)) return(invisible(NULL))
      removeModal()
      log_action(session, current_user_rv,
                 paste0("Stratégie foncière : secteur #", sid, " supprimé"))
      secteur_id(NULL)
      refresh_secteurs(select = "")
      showToast("warning", "Secteur supprimé", "Le secteur a été supprimé.")
    })

    invisible(NULL)
  })
}
