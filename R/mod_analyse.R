# mod_analyse.R
#
# Onglet « Analyses » : poser une question en français, obtenir une réponse
# tirée de la base.
#
# Marche à suivre : la question part chez Claude avec le schéma des vues
# gestcons.v_analyses_* ; Claude appelle l'outil `executer_sql` autant de fois
# qu'il en a besoin ; l'application exécute chaque requête sous un rôle
# PostgreSQL qui ne sait que lire ces vues, et lui rend les lignes ; Claude
# rédige la réponse. La requête est montrée à l'utilisateur, qui doit pouvoir
# juger sur quoi la réponse est fondée.
#
# La garde n'est PAS la relecture de la requête — ça se contourne — mais le
# rôle `terracen_analyse` : transaction en lecture seule, statement_timeout, et
# aucun droit sur gestcons (cf. scripts/analyse_role_lecture.sql). La
# vérification faite ici est un second verrou, plus faible, qui ne remplace pas
# le premier.
#
# R n'a pas de SDK Anthropic officiel : on appelle l'API en HTTP direct avec
# httr, déjà installé sur le serveur.

# Modèles proposés dans l'onglet, et ce qu'il faut savoir de chacun pour
# l'appeler correctement et chiffrer la question.
#
# `prix` est en dollars par million de jetons (barème du 2026-10-06). Les
# tarifs d'entrée, de sortie et de lecture de cache sont publiés ; l'ÉCRITURE
# de cache ne l'est pas, on applique le multiplicateur usuel de 1,25 sur
# l'entrée, pour un cache de cinq minutes. Pour Haiku, la lecture de cache
# n'est pas publiée non plus : rapport usuel d'un dixième de l'entrée. Ce
# sont les seules valeurs estimées, à corriger si le barème les publie.
#
# `fallback` dit si le repli serveur existe pour le modèle : Haiku 5.5 n'en a
# pas, et lui envoyer le paramètre ferait échouer l'appel.
#
# `reserve_admin` : le modèle n'est proposé — et accepté — qu'aux
# administrateurs. C'est le cas d'Opus et de Fable, les deux plus chers,
# depuis le 2026-10-30, sur décision de l'utilisateur ; un responsable de site
# garde Haiku et Sonnet. Cf. analyse_choix_modeles().
#
# Haiku 5.5 : les tarifs ci-dessous valent jusqu'à 100 000 jetons d'invite ;
# au-delà, 0,50 et 2,50. Le schéma envoyé ici est très en deçà.
ANALYSE_MODELES <- list(
  "claude-opus-5-5" = list(
    libelle  = "Opus 5.5",
    prix     = c(entree = 4.00, sortie = 20.00,
                 cache_lecture = 0.20, cache_ecriture = 5.00),
    fallback = TRUE,
    reserve_admin = TRUE),
  "claude-sonnet-5-5" = list(
    libelle  = "Sonnet 5.5",
    prix     = c(entree = 2.00, sortie = 10.00,
                 cache_lecture = 0.20, cache_ecriture = 2.50),
    fallback = TRUE),
  "claude-haiku-5-5" = list(
    libelle  = "Haiku 5.5",
    prix     = c(entree = 0.10, sortie = 0.50,
                 cache_lecture = 0.01, cache_ecriture = 0.125),
    fallback = FALSE),
  "claude-fable-5-1" = list(
    libelle  = "Fable 5.1",
    prix     = c(entree = 10.00, sortie = 50.00,
                 cache_lecture = 0.25, cache_ecriture = 12.50),
    fallback = TRUE,
    reserve_admin = TRUE)
)
# Haiku par défaut depuis le 2026-10-28, sur décision de l'utilisateur, et
# c'est une décision de COÛT : 0,10 $ le million de jetons d'entrée contre
# 4,00 pour Opus, soit quarante fois moins. Mesuré sur les 33 premières
# questions, la moyenne était de 6 centimes pour un utilisateur et de 24 pour
# l'autre, l'onglet venant de s'ouvrir aux responsables de site.
#
# ⚠️ Haiku n'a PAS de repli serveur — son `fallback` vaut FALSE, et lui
# envoyer le paramètre ferait échouer l'appel. Le reste du module le gère
# déjà par cfg$fallback ; ne pas l'oublier si on change encore de défaut.
#
# Le sélecteur reste là : une question qui demande du raisonnement se repose
# sur un autre modèle en un clic, au prix d'une conversation repartie de zéro.
ANALYSE_MODELE_DEFAUT <- "claude-haiku-5-5"
ANALYSE_API_VERSION   <- "2026-10-21"
ANALYSE_MAX_TOKENS    <- 16000L
# Garde-fou sur la boucle d'outils. Porté de 6 à 10 le 2026-10-28 : une
# question à trois critères — un milieu, un statut de contrat, un territoire —
# a épuisé les 6 tours sans répondre. Rejouée une fois la donnée présente,
# elle a demandé 4 requêtes ; les questions ordinaires en consomment 1 à 3.
# Six laissait donc une marge trop mince, et le plafond ne sert qu'à arrêter
# un emballement, pas à rationner un cheminement légitime.
ANALYSE_MAX_TOURS     <- 10L
ANALYSE_MAX_LIGNES    <- 200L   # lignes rendues au modèle pour une requête
ANALYSE_SCHEMA        <- "gestcons"
# Les vues exposées, nommément. La vue vit dans gestcons, aux côtés de 74
# tables que le rôle n'a pas le droit de lire : le second verrou ne peut donc
# plus se contenter de regarder le schéma, il lui faut cette liste. Chaque vue
# ajoutée à l'onglet s'ajoute ici ET reçoit son GRANT (analyse_role_lecture.sql).
ANALYSE_VUES          <- c("v_analyses_sites",
                           "v_analyses_secteurs",
                           "v_analyses_parcelles",
                           # Une ligne par couple (parcelle, commune) : un
                           # périmètre manuel peut en recouvrir plusieurs, et
                           # v_analyses_parcelles — qui garde une ligne par
                           # parcelle — ne peut donc pas porter la surface de
                           # chacune. C'est cette vue-ci qu'il faut pour SOMMER
                           # des hectares par commune ou par EPCI.
                           "v_analyses_parcelles_communes",
                           "v_analyses_proprietaires",
                           "v_analyses_roles_sites",
                           "v_analyses_contrats",
                           "v_analyses_parcelles_contrats",
                           # L'animation foncière, à deux grains : la
                           # démarche, et le couple démarche-parcelle par
                           # lequel elle se rattache à un site ou un secteur.
                           # Les personnes contactées n'y sont que comptées.
                           "v_analyses_animations",
                           "v_analyses_animations_parcelles",
                           # Une ligne par couple document de gestion - site ;
                           # en_vigueur y est calculé à la date du jour.
                           "v_analyses_documents_gestion",
                           # Les 327 communes de l'Ariège, y compris celles
                           # où le CEN n'a rien : c'est ce qui permet de
                           # demander lesquelles n'ont aucun site.
                           "v_analyses_communes",
                           # Les zonages réglementaires, croisés d'avance
                           # (gestcons.vm_analyses_zonages, rafraîchie par
                           # analyse_rafraichir_zonages) : QUELS zonages, une
                           # ligne par couple parcelle-zonage ; et COMBIEN,
                           # une ligne par parcelle, sans double compte.
                           "v_analyses_zonages",
                           "v_analyses_surfaces_zonees")

# Export d'une couche à partir d'une requête de l'onglet.
#
# ⚠️ La géométrie n'entre JAMAIS dans la conversation, et c'est pour ça
# qu'aucune vue d'analyse n'en porte. Mesuré le 2026-10-27 : une parcelle pèse
# 675 caractères en WKT, jusqu'à 36 805, soit ~37 500 jetons pour les 200
# lignes qu'une requête peut rendre — là où TOUT le schéma coûte ~1 300. Elle
# est donc recousue ICI, au moment de l'export, depuis les tables de base et
# sous le rôle de l'application, pas sous celui de l'onglet.
#
# Tout est stocké en Lambert-93 (EPSG:2154), cadastre et géométries manuelles.
# GPKG et Shapefile l'y laissent, c'est ce que QGIS attend ici ; GeoJSON et
# KML sont reprojetés en WGS84, leurs spécifications l'imposent.
ANALYSE_EXPORT_MAX <- 50000L   # garde-fou : au-delà, on refuse plutôt que de
                               # fabriquer un fichier démesuré
ANALYSE_EXPORT_FORMATS <- list(
  gpkg    = list(libelle = "GeoPackage (.gpkg)", pilote = "GPKG",
                 ext = "gpkg",    srid = 2154L, zip = FALSE),
  shp     = list(libelle = "Shapefile (.zip)",   pilote = "ESRI Shapefile",
                 ext = "shp",     srid = 2154L, zip = TRUE),
  geojson = list(libelle = "GeoJSON (.geojson)", pilote = "GeoJSON",
                 ext = "geojson", srid = 4326L, zip = FALSE),
  kml     = list(libelle = "KML (.kml)",         pilote = "KML",
                 ext = "kml",     srid = 4326L, zip = FALSE)
)

# Les colonnes qui portent une géométrie, DU GRAIN LE PLUS FIN AU PLUS LARGE.
# L'ordre compte : v_analyses_parcelles porte parcelle_id, site_id ET
# code_insee, et c'est la parcelle qu'il faut alors exporter. La commune vient
# en dernier parce que c'est le grain le plus large : une requête qui ne
# renvoie QUE des communes est une liste de communes.
#
# `type` dit comment écrire la clé dans un IN (...) : les identifiants sont
# des entiers, le code INSEE est du texte — et un texte doit être validé puis
# cité, jamais recopié tel quel dans une requête.
ANALYSE_EXPORT_CLES <- list(
  list(colonne = "parcelle_id", grain = "parcelles", libelle = "parcelles", type = "entier"),
  list(colonne = "secteur_id",  grain = "sites",     libelle = "secteurs",  type = "entier"),
  list(colonne = "site_id",     grain = "sites",     libelle = "sites",     type = "entier"),
  list(colonne = "id",          grain = "sites",     libelle = "sites",     type = "entier"),
  list(colonne = "code_insee",  grain = "communes",  libelle = "communes",  type = "insee"),
  list(colonne = "siren_epci",  grain = "epci",      libelle = "intercommunalités", type = "siren")
)

#' Les clés, nettoyées et prêtes pour un IN (...).
#'
#' Rien de ce qui vient d'un résultat de requête n'est recopié tel quel : les
#' identifiants passent par as.integer, les codes INSEE ne sont retenus que
#' s'ils ont la forme d'un code INSEE — cinq caractères, chiffres plus les 2A
#' et 2B de la Corse — puis sont cités.
analyse_cles_sql <- function(cle, valeurs) {
  if (identical(cle$type, "insee")) {
    v <- toupper(trimws(as.character(valeurs)))
    v <- unique(v[!is.na(v) & grepl("^[0-9AB]{5}$", v)])
    if (!length(v)) return(NULL)
    return(paste(sprintf("'%s'", v), collapse = ","))
  }
  if (identical(cle$type, "siren")) {
    # Un SIREN fait neuf chiffres, sans exception.
    v <- trimws(as.character(valeurs))
    v <- unique(v[!is.na(v) & grepl("^[0-9]{9}$", v)])
    if (!length(v)) return(NULL)
    return(paste(sprintf("'%s'", v), collapse = ","))
  }
  # suppressWarnings : as.integer("abc") avertit avant de rendre NA, et c'est
  # précisément le cas qu'on veut traiter en silence — la valeur est écartée.
  v <- unique(stats::na.omit(suppressWarnings(as.integer(valeurs))))
  if (!length(v)) return(NULL)
  paste(v, collapse = ",")
}

#' La requête produit-elle une couche, et de quel grain ?
#'
#' Renvoie NULL quand elle n'en produit pas — une agrégation par commune, un
#' décompte, une liste de contrats. Le bouton d'export n'est alors pas
#' proposé du tout : mieux vaut pas de bouton qu'un bouton qui rend un
#' fichier vide.
analyse_couche_de <- function(colonnes) {
  if (!length(colonnes)) return(NULL)
  for (k in ANALYSE_EXPORT_CLES) if (k$colonne %in% colonnes) return(k)
  NULL
}

# Export des TABLEAUX d'une réponse.
#
# À ne pas confondre avec l'export de couche : celui-ci rejoue la requête et
# rend les données complètes ; celui-là rend EXACTEMENT le tableau affiché,
# qui peut n'en être qu'un extrait — « les dix premiers », « par commune ».
# C'est voulu : on exporte ce qu'on lit.
#
# Le séparateur par défaut est le point-virgule, et le fichier porte une
# marque d'ordre des octets : sans elle, Excel en français lit l'UTF-8 comme
# du latin-1 et affiche « AIGUES-JUNTES » correctement mais « Montégut » en
# « MontÃ©gut ». Le CSV à la virgule reste disponible pour les outils qui
# suivent la norme.
ANALYSE_TABLEAU_FORMATS <- list(
  csv_excel = list(libelle = "CSV pour Excel (point-virgule)", ext = "csv",
                   sep = ";",  bom = TRUE),
  csv       = list(libelle = "CSV standard (virgule)",         ext = "csv",
                   sep = ",",  bom = FALSE),
  txt       = list(libelle = "Texte tabulé (.txt)",            ext = "txt",
                   sep = "\t", bom = FALSE)
)

#' Les tableaux Markdown d'une réponse, rendus en data.frames.
#'
#' Un tableau Markdown, c'est une ligne d'en-tête commençant par `|`, une
#' ligne de séparation faite de tirets et de deux-points, puis des lignes de
#' corps. Tout le reste du texte est ignoré.
#'
#' Les cellules sont débarrassées de leur mise en forme — gras, italique,
#' code — parce qu'un tableur n'en fait rien : `**47**` doit arriver comme
#' `47`, sinon la colonne cesse d'être numérique.
#'
#' Renvoie une liste de data.frames, vide si la réponse n'a aucun tableau.
analyse_tableaux_markdown <- function(texte) {
  if (is.null(texte) || !nzchar(texte)) return(list())
  lignes <- strsplit(texte, "\n", fixed = TRUE)[[1]]
  est_ligne <- function(l) grepl("^\\s*\\|.*\\|\\s*$", l)
  est_sep   <- function(l) grepl("^\\s*\\|[\\s:|-]*-[\\s:|-]*\\|\\s*$", l, perl = TRUE)

  cellules <- function(l) {
    l <- sub("^\\s*\\|", "", sub("\\|\\s*$", "", trimws(l)))
    c_ <- strsplit(l, "|", fixed = TRUE)[[1]]
    c_ <- gsub("\\*\\*|__|`", "", c_)        # gras et code
    c_ <- gsub("(^|[^*])\\*([^*]+)\\*", "\\1\\2", c_)  # italique
    trimws(c_)
  }

  out <- list(); i <- 1L
  while (i < length(lignes)) {
    if (est_ligne(lignes[i]) && est_sep(lignes[i + 1L])) {
      entete <- cellules(lignes[i])
      j <- i + 2L; corps <- list()
      while (j <= length(lignes) && est_ligne(lignes[j])) {
        corps[[length(corps) + 1L]] <- cellules(lignes[j]); j <- j + 1L
      }
      if (length(corps)) {
        # Une ligne plus courte que l'en-tête est complétée, une plus longue
        # est tronquée : un tableau mal fermé par le modèle ne doit pas faire
        # échouer l'export de toute la réponse.
        n <- length(entete)
        corps <- lapply(corps, function(r) { length(r) <- n; r[is.na(r)] <- ""; r })
        d <- as.data.frame(do.call(rbind, corps), stringsAsFactors = FALSE)
        names(d) <- ifelse(nzchar(entete), entete, paste0("col", seq_len(n)))
        out[[length(out) + 1L]] <- d
      }
      i <- j
    } else i <- i + 1L
  }
  out
}

#' Un data.frame en lignes CSV, séparateur au choix.
#'
#' Guillemets doublés et cellule encadrée dès qu'elle contient le séparateur,
#' un guillemet ou un passage à la ligne — la règle du RFC 4180, suffisante
#' pour Excel comme pour R.
analyse_tableau_csv <- function(d, sep) {
  echap <- function(v) {
    v <- as.character(v); v[is.na(v)] <- ""
    besoin <- grepl(sep, v, fixed = TRUE) | grepl('"', v, fixed = TRUE) |
              grepl("\n", v, fixed = TRUE)
    v[besoin] <- paste0('"', gsub('"', '""', v[besoin], fixed = TRUE), '"')
    v
  }
  c(paste(echap(names(d)), collapse = sep),
    if (nrow(d)) apply(d, 1, function(r) paste(echap(r), collapse = sep)) else character(0))
}

# Les zonages réglementaires sont croisés d'avance avec les parcelles, dans
# la vue matérialisée gestcons.vm_analyses_zonages : le calcul prend ~5 s,
# trop près du délai de 8 s du rôle de lecture pour être refait à chaque
# requête. Avant chaque question, on demande à la base de le refaire SI une
# parcelle a changé depuis : c'est elle qui en juge, par le journal d'audit,
# et qui écarte un second calcul lancé en même temps.
#
# Appelée dans le processus séparé, AVANT la conversation : quand le calcul
# est à refaire, la question attend ces secondes-là, mais sa réponse porte
# sur les parcelles du moment. Sous le rôle de l'APPLICATION, celui
# d'Analyses étant en lecture seule — la base ne lui accorde que l'exécution
# de cette fonction. Ne lève jamais d'erreur : un échec laisse la question
# partir sur le dernier calcul, dont les vues donnent la date.
analyse_rafraichir_zonages <- function(db) {
  cnx <- tryCatch(
    DBI::dbConnect(RPostgres::Postgres(), host = db$host, port = db$port,
                   dbname = db$dbname, user = db$user,
                   password = db$password, sslmode = "require"),
    error = function(e) e
  )
  if (inherits(cnx, "error")) {
    message("[Analyses] zonages non rafraîchis, connexion impossible : ",
            conditionMessage(cnx))
    return(invisible(NULL))
  }
  on.exit(try(DBI::dbDisconnect(cnx), silent = TRUE), add = TRUE)
  etat <- tryCatch(
    DBI::dbGetQuery(cnx, "SELECT gestcons.rafraichir_zonages_analyses() AS etat")$etat,
    error = function(e) paste("échec :", conditionMessage(e))
  )
  # « a_jour » est le cas courant : on ne journalise que ce qui en sort.
  if (!identical(etat, "a_jour")) message("[Analyses] zonages : ", etat)
  invisible(etat)
}

# Une conversation complète, dans un processus SÉPARÉ.
#
# shiny-server ne donne qu'UN processus R à toute l'application : un appel
# synchrone à l'API gelait l'écran de tous les utilisateurs pendant des
# dizaines de secondes. Cette fonction est donc appelée par future_promise()
# et s'exécute ailleurs.
#
# Conséquence sur son écriture : elle ne voit NI réactif, NI session, NI le
# pool de connexions — rien de tout cela ne traverse les processus. Tout ce
# dont elle a besoin arrive par `systeme` et `cfg`, et elle ouvre sa PROPRE
# connexion, qu'elle referme. Elle ne lève pas d'erreur : elle renvoie
# toujours une liste, que l'appelant affiche.
#
# `historique` est la conversation déjà échangée, rendue telle quelle par
# l'appel précédent. Elle est RENVOYÉE AUGMENTÉE, jamais réécrite : sur ces
# modèles, les blocs de raisonnement sont liés à la conversation qui les a
# produits, et modifier un tour déjà envoyé fait échouer la requête. Pour
# raccourcir, on repart de zéro ; on ne rogne pas.
#
# @return list(texte, journal, jetons, modele, messages, erreur)
analyse_conversation <- function(question, systeme, cfg, historique = list()) {
  # Redéfini localement : la fonction s'exécute dans un processus qui n'a pas
  # chargé helpers.R. Ne pas compter sur l'export automatique des globales.
  `%||%` <- function(a, b) if (!is.null(a)) a else b

  jetons  <- c(entree = 0, sortie = 0, cache_lecture = 0, cache_ecriture = 0)
  journal <- list()
  # Le modèle QUI A RÉPONDU, et non celui demandé : un repli serveur peut en
  # changer en cours d'appel, et la question se chiffre alors à son tarif.
  modele  <- cfg$modele
  # `suite` par défaut à l'historique reçu : une question qui échoue ne doit
  # pas laisser dans le fil un tour sans réponse, que le prochain appel
  # renverrait tel quel.
  sortir  <- function(texte = NULL, erreur = NULL, suite = historique)
    list(texte = texte, journal = journal, jetons = jetons,
         modele = modele, messages = suite, erreur = erreur)

  if (!nzchar(cfg$cle %||% "")) {
    return(sortir(erreur = "ANTHROPIC_API_KEY n'est pas renseignée sur le serveur."))
  }

  cnx <- tryCatch(
    DBI::dbConnect(RPostgres::Postgres(), host = cfg$db$host, port = cfg$db$port,
                   dbname = cfg$db$dbname, user = cfg$db$user,
                   password = cfg$db$password, sslmode = "require"),
    error = function(e) e
  )
  if (inherits(cnx, "error")) {
    return(sortir(erreur = paste("Connexion de lecture indisponible :", conditionMessage(cnx))))
  }
  on.exit(try(DBI::dbDisconnect(cnx), silent = TRUE), add = TRUE)

  .outils <- list(list(
    name = "executer_sql",
    description = paste(
      "Exécute une requête SELECT en lecture seule sur les vues listées",
      "ci-dessous et renvoie les lignes. Utilise-le pour toute question",
      "portant sur les données. Une seule requête par appel, sans point-virgule."),
    input_schema = list(
      type = "object",
      properties = list(
        sql = list(type = "string", description = "La requête SELECT à exécuter."),
        but = list(type = "string", description = "Ce que la requête cherche, en une phrase.")
      ),
      required = list("sql"),
      additionalProperties = FALSE
    ),
    strict = TRUE
  ))

  .requete_acceptable <- function(sql) {
    s <- tolower(trimws(sql))
    s <- sub(";\\s*$", "", s)
    if (!grepl("^(select|with)\\b", s))            return("la requête doit commencer par SELECT ou WITH")
    if (grepl(";", s, fixed = TRUE))               return("une seule requête à la fois")
    interdits <- c("insert", "update", "delete", "drop", "alter", "create",
                   "truncate", "grant", "revoke", "copy", "call", "do")
    trouve <- interdits[vapply(interdits, function(m)
      grepl(paste0("\\b", m, "\\b"), s), logical(1))]
    if (length(trouve)) return(sprintf("mot-clé interdit : %s", trouve[1]))
    # Tout nom qualifié doit viser une vue exposée. gestcons abritant aussi
    # les 74 tables interdites, regarder le seul schéma ne suffit plus : on
    # vérifie l'objet. « s. » dans « s.id » est un alias de table, pas un
    # schéma : seuls les préfixes qui nomment un schéma connu sont examinés.
    refs <- regmatches(s, gregexpr("\\b[a-z_][a-z0-9_]*\\.[a-z_][a-z0-9_]*", s))[[1]]
    for (r in refs) {
      morceaux <- strsplit(r, ".", fixed = TRUE)[[1]]
      sch <- morceaux[1]; obj <- morceaux[2]
      if (identical(sch, cfg$schema)) {
        if (!obj %in% cfg$vues)
          return(sprintf("objet hors périmètre : %s.%s", sch, obj))
      } else if (sch %in% c("public", "pr_zh", "pg_catalog",
                            "information_schema", "pg_temp")) {
        return(sprintf("schéma hors périmètre : %s", sch))
      }
    }
    NULL
  }

  .executer <- function(sql) {
    refus <- .requete_acceptable(sql)
    if (!is.null(refus)) {
      return(list(erreur = refus, df = NULL))
    }
    d <- tryCatch(
      DBI::dbGetQuery(cnx, sprintf("SELECT * FROM (%s) q LIMIT %d",
                                             sub(";\\s*$", "", sql), cfg$max_lignes)),
      error = function(e) e
    )
    if (inherits(d, "error")) return(list(erreur = conditionMessage(d), df = NULL))
    list(erreur = NULL, df = d)
  }

  .resultat_texte <- function(res) {
    if (!is.null(res$erreur)) return(paste("ERREUR :", res$erreur))
    d <- res$df
    if (is.null(d) || !nrow(d)) return("0 ligne.")
    txt <- utils::capture.output(print(utils::head(d, cfg$max_lignes), row.names = FALSE))
    paste0(nrow(d), " ligne(s).\n", paste(txt, collapse = "\n"))
  }

  .appel_api <- function(messages) {
    cle <- cfg$cle
    if (!nzchar(cle)) stop("ANTHROPIC_API_KEY n'est pas renseignée sur le serveur.")

    corps <- list(
      model      = cfg$modele,
      max_tokens = cfg$max_tokens,
      # Le système porte le schéma, stable d'une question à l'autre : mis en
      # cache, il n'est facturé plein tarif qu'une fois.
      system     = list(list(type = "text", text = systeme,
                             cache_control = list(type = "ephemeral"))),
      # La réflexion est toujours active sur les modèles proposés ; l'effort
      # est le seul réglage. « medium » est posé explicitement : c'est le
      # défaut d'Opus et de Haiku, mais Sonnet, lui, part de « high ».
      thinking      = list(type = "adaptive"),
      output_config = list(effort = "medium"),
      tools      = .outils,
      messages   = messages
    )

    # Repli serveur : si une classification de sûreté décline la demande,
    # l'API rejoue la requête sur un autre modèle dans le même appel. Haiku
    # 5.5 n'en dispose pas — lui envoyer le paramètre ferait échouer l'appel.
    entetes <- c("content-type" = "application/json",
                 "x-api-key" = cle,
                 "anthropic-version" = cfg$api_version)
    if (isTRUE(cfg$fallback)) {
      corps$fallbacks <- "default"
      entetes["anthropic-beta"] <- "server-side-fallback-2026-07-01"
    }

    r <- httr::POST(
      "https://api.anthropic.com/v1/messages",
      do.call(httr::add_headers, as.list(entetes)),
      body = jsonlite::toJSON(corps, auto_unbox = TRUE, null = "null"),
      encode = "raw",
      httr::timeout(180)
    )
    txt <- httr::content(r, as = "text", encoding = "UTF-8")
    if (httr::status_code(r) >= 400) {
      detail <- tryCatch(jsonlite::fromJSON(txt)$error$message, error = function(e) txt)
      stop(sprintf("API Claude (%d) : %s", httr::status_code(r), detail))
    }
    jsonlite::fromJSON(txt, simplifyVector = FALSE)
  }
  messages <- c(historique, list(list(role = "user", content = question)))

  for (tour in seq_len(cfg$max_tours)) {
    rep <- tryCatch(.appel_api(messages), error = function(e) e)
    if (inherits(rep, "error")) return(sortir(erreur = conditionMessage(rep)))

    modele <- rep$model %||% modele
    u <- rep$usage %||% list()
    jetons["entree"]         <- jetons["entree"]         + (u$input_tokens  %||% 0)
    jetons["sortie"]         <- jetons["sortie"]         + (u$output_tokens %||% 0)
    jetons["cache_lecture"]  <- jetons["cache_lecture"]  + (u$cache_read_input_tokens     %||% 0)
    jetons["cache_ecriture"] <- jetons["cache_ecriture"] + (u$cache_creation_input_tokens %||% 0)

    # Une classification de sûreté peut décliner : le contenu n'est alors pas
    # une réponse, il faut le dire plutôt que l'afficher.
    if (identical(rep$stop_reason, "refusal")) {
      return(sortir(erreur = "La demande a été déclinée par les garde-fous du modèle."))
    }

    blocs  <- rep$content %||% list()
    outils <- Filter(function(b) identical(b$type, "tool_use"), blocs)

    if (!length(outils)) {
      textes <- vapply(Filter(function(b) identical(b$type, "text"), blocs),
                       function(b) b$text %||% "", character(1))
      # Le tour de l'assistant rejoint le fil TEL QUEL, blocs de raisonnement
      # compris : c'est ce que le prochain appel devra renvoyer à l'identique.
      return(sortir(texte = paste(textes, collapse = "\n\n"),
                    suite = c(messages,
                              list(list(role = "assistant", content = blocs)))))
    }

    # Tous les tool_result d'un tour repartent dans UN seul message : les
    # répartir sur plusieurs apprend au modèle à ne plus paralléliser.
    resultats <- lapply(outils, function(b) {
      sql <- b$input$sql %||% ""
      res <- .executer(sql)
      journal[[length(journal) + 1]] <<- list(
        sql = sql, but = b$input$but %||% "",
        n = if (is.null(res$df)) NA_integer_ else nrow(res$df),
        # Les noms de colonnes décident si la requête peut devenir une couche.
        # Relevés ici parce que c'est le seul endroit où le résultat existe :
        # la fonction tourne dans un autre processus et ne rend que `journal`.
        colonnes = if (is.null(res$df)) character(0) else names(res$df),
        erreur = res$erreur
      )
      list(type = "tool_result", tool_use_id = b$id,
           content = .resultat_texte(res),
           is_error = !is.null(res$erreur))
    })

    messages <- c(messages,
                  list(list(role = "assistant", content = blocs)),
                  list(list(role = "user", content = resultats)))
  }

  sortir(erreur = sprintf("Pas de réponse après %d allers-retours.", cfg$max_tours))
}

# Les choix du sélecteur de modèle (identifiant nommé par son libellé) pour
# un utilisateur : tous pour un administrateur, sinon ceux qui ne sont pas
# `reserve_admin`. La même liste sert à afficher ET à accepter le modèle.
analyse_choix_modeles <- function(admin) {
  ms <- Filter(function(m) isTRUE(admin) || !isTRUE(m$reserve_admin),
               ANALYSE_MODELES)
  stats::setNames(names(ms), vapply(ms, function(m) m$libelle, ""))
}

analyse_ui <- function(id) {
  ns <- NS(id)

  tagList(
    div(class = "flex-container tc-analyse",
        div(class = "sidebar-left-custom",
            titre_page("Analyses"),
            textAreaInput(
              ns("question"), "Votre question",
              placeholder = "Combien de sites actifs dans les Pyrénées ?",
              height = "110px", resize = "vertical"
            ),
            # Liste restreinte au départ : on ne sait pas encore qui se
            # connecte. Le serveur l'élargit pour un administrateur.
            selectInput(
              ns("modele"), "Modèle",
              choices  = analyse_choix_modeles(admin = FALSE),
              selected = ANALYSE_MODELE_DEFAUT
            ),
            actionButton(ns("poser"), "Interroger", class = "btn btn-primary",
                         width = "100%"),
            uiOutput(ns("nouvelle")),
            uiOutput(ns("exemples")),
            hr(),
            uiOutput(ns("memoire")),
            uiOutput(ns("perimetre"))
        ),
        div(class = "right-rail",
            div(class = "right-rail-inner",
                h4("🔎 Conversation"),
                uiOutput(ns("fil"))
            )
        )
    )
  )
}

analyse_server <- function(id, con, pool_analyses, current_user_rv, user_roles) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    user_to_db <- make_user_to_db(current_user_rv)

    # L'onglet n'est montré qu'aux administrateurs (app.R,
    # set_tab_visible("tab-analyses", is_admin)), mais un onglet masqué n'est
    # pas une garde : rien n'empêche d'envoyer l'input à la main. La règle est
    # donc rejouée ici, comme dans Acteurs et Utilisateurs. Elle protège aussi
    # la dépense : chaque question est facturée.
    .est_admin <- function() isTRUE(user_roles()$global_role == "AD")

    # L'onglet s'ouvre aux responsables de SITE CONSERVATOIRE, pas seulement
    # aux administrateurs. Le type compte : être responsable d'un secteur
    # d'intervention n'ouvre pas davantage ici qu'il n'ouvre Contrats ou
    # Activité — c'est la règle déjà posée pour ces deux onglets.
    #
    # ⚠️ Ce qui s'ouvre, et ce qui ne s'ouvre PAS. Poser une question,
    # repartir d'une conversation vierge et exporter : oui. Écrire, modifier
    # ou supprimer une CONSIGNE : non, cela reste aux administrateurs. Une
    # consigne est jointe à CHAQUE question de CHAQUE utilisateur : elle
    # façonne les réponses de tout le monde, ce n'est pas une préférence
    # personnelle.
    .peut_interroger <- function() {
      if (.est_admin()) return(TRUE)
      sr <- user_roles()$site_roles
      if (is.null(sr) || !nrow(sr)) return(FALSE)
      isTRUE(any(sr$role == "RS" & sr$type_site_id %in% 1L))
    }

    # Le sélecteur suit le profil : Opus et Fable s'ajoutent pour un
    # administrateur. Rejoué à chaque changement de rôles ; le modèle choisi
    # est gardé s'il reste permis.
    observe({
      choix  <- analyse_choix_modeles(.est_admin())
      actuel <- isolate(input$modele)
      updateSelectInput(session, "modele", choices = choix,
                        selected = if (isTRUE(actuel %in% choix)) actuel
                                   else ANALYSE_MODELE_DEFAUT)
    })

    .refus_admin <- function() {
      showToast("warning", "Réservé aux administrateurs",
                "Les consignes de l'onglet Analyses ne sont modifiables que par un administrateur.")
      invisible(NULL)
    }

    .refus_interroger <- function() {
      showToast("warning", "Profil insuffisant",
                "L'onglet Analyses est réservé aux administrateurs et aux responsables de site.")
      invisible(NULL)
    }

    # Mémoire : les consignes durables données à Claude. Ce ne sont pas des
    # questions mémorisées — c'est ce qu'il doit savoir une fois pour toutes,
    # le vocabulaire maison et les pièges du modèle de données. Elles sont
    # écrites par des administrateurs, l'onglet leur étant réservé : ce sont
    # des consignes d'exploitation, pas des données venues d'ailleurs.
    notes_rv <- reactiveVal(NULL)
    .charger_notes <- function() {
      notes_rv(safe_db_query(con, "
        SELECT id, note, actif, ordre
        FROM gestcons.analyses_notes
        ORDER BY ordre, id"))
    }
    .charger_notes()

    etat_rv    <- reactiveVal(NULL)   # "en cours" / "erreur" / NULL
    # Le fil tel qu'il s'affiche : une entrée par question posée.
    echanges_rv <- reactiveVal(list())
    # La conversation telle que l'API la rejouera, blocs de raisonnement
    # compris. On l'empile sans jamais la réécrire (cf. analyse_conversation).
    historique_rv <- reactiveVal(list())
    # Le prompt système et le modèle sont FIGÉS pour la durée d'une
    # conversation : changer l'un ou l'autre en cours de route reviendrait à
    # modifier ce qui a déjà été envoyé, et les blocs de raisonnement y sont
    # liés. Une consigne de mémoire modifiée prend donc effet à la
    # conversation suivante.
    systeme_fige_rv <- reactiveVal(NULL)
    modele_fige_rv  <- reactiveVal(NULL)

    .remise_a_zero <- function() {
      echanges_rv(list()); historique_rv(list())
      systeme_fige_rv(NULL); modele_fige_rv(NULL); etat_rv(NULL)
    }

    # ---- Schéma exposé ----------------------------------------------------
    # Lu dans le catalogue plutôt que recopié ici : une colonne ajoutée à la
    # vue arrive dans le prompt sans qu'on y pense, et une colonne retirée en
    # disparaît — un schéma recopié mentirait tôt ou tard.
    schema_txt <- reactive({
      if (is.null(pool_analyses)) return(NULL)
      d <- safe_db_query(pool_analyses, glue::glue_sql("
        SELECT c.table_name, c.column_name, c.data_type,
               col_description(format('%I.%I', c.table_schema, c.table_name)::regclass::oid,
                               c.ordinal_position) AS commentaire,
               obj_description(format('%I.%I', c.table_schema, c.table_name)::regclass::oid,
                               'pg_class') AS commentaire_vue
        FROM information_schema.columns c
        WHERE c.table_schema = {ANALYSE_SCHEMA}
          AND c.table_name IN ({ANALYSE_VUES*})
        ORDER BY c.table_name, c.ordinal_position", .con = pool_analyses))
      if (is.null(d) || !nrow(d)) return(NULL)
      par_table <- split(d, d$table_name)
      paste(vapply(names(par_table), function(t) {
        tt <- par_table[[t]]
        lignes <- sprintf("  %s (%s)%s", tt$column_name, tt$data_type,
                          ifelse(is.na(tt$commentaire) | !nzchar(tt$commentaire),
                                 "", paste0(" — ", tt$commentaire)))
        # Le commentaire de la vue dit son GRAIN — une ligne par site, par
        # parcelle, par couple parcelle-contrat. C'est ce qui évite les
        # doubles comptages, donc il vaut au moins autant que ceux des
        # colonnes et doit figurer dans le prompt.
        entete <- paste0(ANALYSE_SCHEMA, ".", t)
        cv <- tt$commentaire_vue[1]
        if (!is.na(cv) && nzchar(cv)) entete <- paste0(entete, " — ", cv)
        paste0(entete, "\n", paste(lignes, collapse = "\n"))
      }, character(1)), collapse = "\n\n")
    })

    # ---- Mémoire : affichage et édition -----------------------------------
    #
    # Réservée aux administrateurs, eux seuls pouvant l'écrire. Une version
    # antérieure en montrait la LISTE à tous, par transparence sur ce qui est
    # joint à chaque question ; l'utilisateur a tranché pour le masquage
    # complet. Les observateurs gardent leur propre contrôle : ce masquage est
    # un confort d'interface, pas la sûreté.
    output$memoire <- renderUI({
      if (!.est_admin()) return(NULL)
      d <- notes_rv()
      n <- if (is.null(d)) 0L else sum(d$actif %in% TRUE)
      tagList(
        tags$details(
          tags$summary(style = "cursor:pointer;font-size:12px;font-weight:600;",
                       sprintf("🧠 Mémoire (%d consigne%s)", n, if (n > 1) "s" else "")),
          tags$p(class = "text-muted", style = "font-size:11px;margin-top:6px;",
                 "Ce que Claude doit savoir une fois pour toutes : vocabulaire ",
                 "maison, colonne à prendre par défaut, pièges du modèle de ",
                 "données. Ajouté à chaque question."),
          if (!is.null(d) && nrow(d)) tags$ul(
            class = "tc-analyse-notes",
            lapply(seq_len(nrow(d)), function(i)
              tags$li(class = if (!isTRUE(d$actif[i])) "tc-note-off",
                      htmltools::htmlEscape(d$note[i])))
          ) else tags$p(class = "text-muted", style = "font-size:11px;", "Aucune consigne."),
          tagList(
            selectInput(ns("note_choix"), NULL, width = "100%",
                        choices = .choix_notes(d), selected = ""),
            div(class = "tc-analyse-boutons",
                actionButton(ns("note_nouvelle"), "➕", title = "Ajouter",
                             class = "btn btn-xs btn-sm btn-success"),
                actionButton(ns("note_editer"), "✏️", title = "Modifier",
                             class = "btn btn-xs btn-sm btn-default btn-secondary"),
                actionButton(ns("note_basculer"), "👁", title = "Activer / désactiver",
                             class = "btn btn-xs btn-sm btn-default btn-secondary"),
                actionButton(ns("note_supprimer"), "🗑", title = "Supprimer",
                             class = "btn btn-xs btn-sm btn-danger")))
        ),
        hr()
      )
    })

    .choix_notes <- function(d) {
      if (is.null(d) || !nrow(d)) return(c("Aucune consigne" = ""))
      lbl <- paste0(ifelse(d$actif %in% TRUE, "", "(inactive) "),
                    substr(d$note, 1, 70), ifelse(nchar(d$note) > 70, "…", ""))
      stats::setNames(as.character(d$id), lbl)
    }

    .note_courante <- function() {
      d <- notes_rv(); id <- input$note_choix
      if (is.null(d) || is.null(id) || !nzchar(id)) return(NULL)
      r <- d[as.character(d$id) == id, , drop = FALSE]
      if (!nrow(r)) NULL else r[1, ]
    }

    .modale_note <- function(titre, valeur, bouton) {
      showModal(modalDialog(
        title = titre, size = "l", easyClose = TRUE,
        textAreaInput(ns("note_texte"), "Consigne", value = valeur,
                      height = "140px", width = "100%"),
        tags$p(class = "text-muted", style = "font-size:12px;",
               "Une phrase claire, à l'impératif. Elle part telle quelle dans ",
               "le prompt système, avant chaque question."),
        footer = tagList(modalButton("Annuler"),
                         actionButton(ns(bouton), "💾 Enregistrer",
                                      class = "btn-primary"))
      ))
    }

    observeEvent(input$note_nouvelle, {
      if (!.est_admin()) return(.refus_admin())
      .modale_note("Nouvelle consigne", "", "note_creer")
    })

    observeEvent(input$note_editer, {
      if (!.est_admin()) return(.refus_admin())
      r <- .note_courante()
      if (is.null(r)) return(showToast("warning", "Aucune consigne", "Choisissez-en une d'abord."))
      .modale_note("Modifier la consigne", r$note, "note_maj")
    })

    observeEvent(input$note_creer, {
      if (!.est_admin()) return(.refus_admin())
      txt <- trimws(input$note_texte %||% "")
      if (!nzchar(txt)) return(showToast("warning", "Consigne vide", "Écrivez la consigne."))
      ok <- safe_db_execute(con, glue::glue_sql("
        INSERT INTO gestcons.analyses_notes (note, ordre, cree_par)
        VALUES ({txt}, COALESCE((SELECT max(ordre) FROM gestcons.analyses_notes), 0) + 10,
                {user_to_db()})", .con = con))
      removeModal(); .charger_notes()
      showToast("success", "Consigne ajoutée", "Elle sera jointe à la prochaine question.")
      log_action(session, current_user_rv, "Analyses : ajout d'une consigne")
    })

    observeEvent(input$note_maj, {
      if (!.est_admin()) return(.refus_admin())
      r <- .note_courante(); req(!is.null(r))
      txt <- trimws(input$note_texte %||% "")
      if (!nzchar(txt)) return(showToast("warning", "Consigne vide", "Écrivez la consigne."))
      safe_db_execute(con, glue::glue_sql("
        UPDATE gestcons.analyses_notes
        SET note = {txt}, modifie_par = {user_to_db()}, date_modification = now()
        WHERE id = {as.integer(r$id)}", .con = con))
      removeModal(); .charger_notes()
      showToast("success", "Consigne modifiée", "")
      log_action(session, current_user_rv, "Analyses : modification d'une consigne")
    })

    observeEvent(input$note_basculer, {
      if (!.est_admin()) return(.refus_admin())
      r <- .note_courante()
      if (is.null(r)) return(showToast("warning", "Aucune consigne", "Choisissez-en une d'abord."))
      safe_db_execute(con, glue::glue_sql("
        UPDATE gestcons.analyses_notes
        SET actif = NOT actif, modifie_par = {user_to_db()}, date_modification = now()
        WHERE id = {as.integer(r$id)}", .con = con))
      .charger_notes()
      showToast("success", if (isTRUE(r$actif)) "Consigne désactivée" else "Consigne réactivée", "")
    })

    observeEvent(input$note_supprimer, {
      if (!.est_admin()) return(.refus_admin())
      r <- .note_courante()
      if (is.null(r)) return(showToast("warning", "Aucune consigne", "Choisissez-en une d'abord."))
      # confirm_suppression() rend `quoi` et chaque `details` en HTML BRUT,
      # pour que les appelants puissent y mettre du <strong>. La consigne est
      # saisie à la main : elle doit donc être échappée ici, comme le font les
      # quatre autres appelants.
      confirm_suppression(ns, "cette consigne", "note_supprimer_ok",
                          details = htmltools::htmlEscape(substr(r$note, 1, 160)))
    })

    observeEvent(input$note_supprimer_ok, {
      if (!.est_admin()) return(.refus_admin())
      r <- .note_courante(); req(!is.null(r))
      safe_db_execute(con, glue::glue_sql(
        "DELETE FROM gestcons.analyses_notes WHERE id = {as.integer(r$id)}", .con = con))
      removeModal(); .charger_notes()
      showToast("success", "Consigne supprimée", "")
      log_action(session, current_user_rv, "Analyses : suppression d'une consigne")
    })

    output$perimetre <- renderUI({
      s <- schema_txt()
      tagList(
        tags$p(class = "text-muted", style = "font-size:12px;",
               "La question et les résultats des requêtes sont envoyés à ",
               "l'API Claude. Un PROPRIÉTAIRE n'y figure jamais par son ",
               "identité, seulement par son type — personne physique, ",
               "commune, SCI… Les salariés et bénévoles du CEN, eux, sont ",
               "nommés dans la vue des rôles de site, sans leur adresse. ",
               "Les personnes contactées lors de l'animation foncière ne ",
               "sont que comptées."),
        # Le schéma des vues n'est dépliable que par un administrateur : il
        # nomme colonne par colonne ce que le périmètre expose, ce qui relève
        # de l'exploitation et non de l'usage courant. L'avertissement
        # ci-dessus, lui, reste visible de TOUS — savoir ce qui part vers
        # l'API concerne quiconque pose une question.
        if (!is.null(s) && .est_admin())
          tags$details(
            tags$summary(style = "cursor:pointer;font-size:12px;",
                         "Données interrogeables"),
            tags$pre(style = "font-size:11px;white-space:pre-wrap;", s)
          )
      )
    })

    output$exemples <- renderUI({
      ex <- c("Quels sites ont le plus de parcelles ?",
              "Surface totale maîtrisée, par type de milieu",
              "Combien de sites en préfiguration n'ont aucun contrat foncier ?")
      tagList(
        tags$p(class = "text-muted", style = "font-size:12px;margin-top:10px;",
               "Par exemple :"),
        tags$ul(class = "tc-analyse-ex",
                lapply(seq_along(ex), function(i)
                  tags$li(actionLink(ns(paste0("ex", i)), ex[i]))))
      )
    })
    for (.i in 1:3) local({
      i <- .i
      observeEvent(input[[paste0("ex", i)]], {
        updateTextAreaInput(session, "question",
                            value = c("Quels sites ont le plus de parcelles ?",
                                      "Surface totale maîtrisée, par type de milieu",
                                      "Combien de sites en préfiguration n'ont aucun contrat foncier ?")[i])
      })
    })

    # ---- Exécution d'une requête proposée ---------------------------------
    # Second verrou, derrière le rôle PostgreSQL : on refuse ce qui n'est pas
    # une seule lecture, et ce qui nomme un autre schéma. Un modèle qui
    # passerait outre se heurterait de toute façon aux droits du rôle.
    # Le résultat part dans le prompt : on le rend compact et borné.
    # ---- Appel de l'API ---------------------------------------------------
    .systeme <- function() {
      paste0(
        "Tu réponds à des questions sur la base de données de TerraCen, ",
        "l'application de gestion foncière du Conservatoire d'espaces naturels ",
        "de l'Ariège. Réponds en français, brièvement, en citant les chiffres.\n\n",
        "Tu n'as accès qu'aux vues ci-dessous, en lecture seule — nomme-les ",
        "toujours en entier, schéma compris. Toute autre table est refusée. ",
        "Deux sortes de personnes, à ne pas confondre. Les PROPRIÉTAIRES ne ",
        "sont JAMAIS nommés : seulement leur type et une référence opaque. Si ",
        "la question demande qui possède une parcelle, dis que leur identité ",
        "n'est pas accessible ici — mais que leur nombre et leur type le ",
        "sont. Pour les compter, compte les proprietaire_ref DISTINCTS : une ",
        "même personne peut posséder plusieurs parcelles, et une parcelle ",
        "démembrée a une ligne par droit réel.\n",
        "Les SALARIÉS ET BÉNÉVOLES du CEN, eux, sont nommés dans ",
        "v_analyses_roles_sites — responsables, conservateurs bénévoles et ",
        "animateurs. Cette vue porte l'HISTORIQUE : filtre sur actif pour ",
        "n'avoir que les rôles en cours. Les salariés qui ont mené une ",
        "démarche d'animation foncière sont nommés dans v_analyses_animations ; ",
        "les personnes CONTACTÉES lors de ces démarches, propriétaires ou ",
        "exploitants, ne le sont jamais — seulement comptées.\n\n",
        "Deux objets à ne pas confondre : un SITE CONSERVATOIRE est géré par ",
        "le CEN, avec au moins une parcelle et un contrat ; un SECTEUR ",
        "D'INTERVENTION PRIORITAIRE est une zone de prospection, des parcelles ",
        "sans aucun contrat, repérées comme futur site possible. Les deux ",
        "vivent dans des vues distinctes. Une question posée sur « les sites » ",
        "ne porte pas sur les secteurs, sauf si elle le dit.\n\n",
        "Quand la question porte sur une LISTE de sites, de secteurs ou de ",
        "parcelles, inclus toujours leur identifiant dans le SELECT ",
        "(site_id, secteur_id, id ou parcelle_id selon la vue) : c'est lui ",
        "qui permet d'exporter le résultat en couche cartographique. De même ",
        "pour une liste de COMMUNES : renvoie code_insee à côté du libellé, ",
        "et pour une liste d'INTERCOMMUNALITÉS — communautés de communes ou ",
        "d'agglomération : renvoie siren_epci à côté du nom. ",
        "Une agrégation qui ne désigne ni parcelle, ni site, ni commune n'en ",
        "a pas besoin.\n\n",
        "Appelle l'outil executer_sql pour obtenir les données ; ne devine ",
        "jamais un chiffre. Les surfaces sont en m² : convertis en hectares ",
        "quand c'est plus lisible, en le disant. Si la question est ambiguë, ",
        "pose UNE question de précision au lieu de deviner.\n\n",
        "Schéma disponible :\n\n", schema_txt() %||% "(schéma indisponible)",
        .consignes_txt()
      )
    }

    # Les consignes entrent dans le bloc système, donc dans ce qui est mis en
    # cache : les modifier invalide le cache, et la question suivante repaiera
    # le prompt plein tarif. C'est voulu — elles changent rarement, et une
    # consigne périmée coûterait bien plus cher qu'un cache perdu.
    .consignes_txt <- function() {
      d <- notes_rv()
      if (is.null(d) || !nrow(d)) return("")
      d <- d[d$actif %in% TRUE, , drop = FALSE]
      if (!nrow(d)) return("")
      paste0("\n\nConsignes de l'équipe, à respecter :\n",
             paste0("- ", d$note, collapse = "\n"))
    }

    # ---- Boucle d'outils --------------------------------------------------
    observeEvent(input$poser, {
      if (!.peut_interroger()) return(.refus_interroger())
      q <- trimws(input$question %||% "")
      if (!nzchar(q)) {
        showToast("warning", "Question vide", "Écrivez une question d'abord.")
        return(invisible(NULL))
      }
      if (is.null(pool_analyses)) {
        showToast("error", "Analyses indisponibles",
                  "La connexion de lecture n'est pas configurée sur le serveur.")
        return(invisible(NULL))
      }

      # TOUT ce qui est réactif se lit ICI, avant de partir : le processus
      # séparé n'a accès ni aux réactifs, ni à la session, ni au pool.
      # Sur la première question d'une conversation, le prompt système et le
      # modèle sont lus puis figés ; ensuite on rejoue les mêmes.
      historique <- historique_rv()
      if (!length(historique)) {
        # Un input se forge à la main : seuls les modèles proposés à
        # l'utilisateur passent — Opus et Fable aux seuls administrateurs.
        m <- input$modele
        if (!isTRUE(m %in% analyse_choix_modeles(.est_admin())))
          m <- ANALYSE_MODELE_DEFAUT
        systeme_fige_rv(.systeme()); modele_fige_rv(m)
      }
      systeme <- systeme_fige_rv()
      modele  <- modele_fige_rv()
      cfg <- list(
        cle         = Sys.getenv("ANTHROPIC_API_KEY"),
        modele      = modele,
        fallback    = isTRUE(ANALYSE_MODELES[[modele]]$fallback),
        api_version = ANALYSE_API_VERSION,
        max_tokens  = ANALYSE_MAX_TOKENS,
        max_tours   = ANALYSE_MAX_TOURS,
        max_lignes  = ANALYSE_MAX_LIGNES,
        schema      = ANALYSE_SCHEMA,
        vues        = ANALYSE_VUES,
        db = list(host = Sys.getenv("DB_HOST"),
                  port = as.integer(Sys.getenv("DB_PORT")),
                  dbname = Sys.getenv("DB_NAME"),
                  user = "terracen_analyse",
                  password = Sys.getenv("ANALYSE_DB_PASSWORD")),
        # Le rôle de l'application, pour le seul rafraîchissement des zonages
        # (cf. analyse_rafraichir_zonages) : même base, autre compte.
        db_app = list(user = Sys.getenv("DB_USER"),
                      password = Sys.getenv("DB_PASSWORD"))
      )

      etat_rv("en cours")
      shinyjs::disable("poser")

      # L'appel à l'API dure des dizaines de secondes, et shiny-server ne donne
      # qu'UN processus R à toute l'application : un appel synchrone gelait
      # l'écran de tous les utilisateurs pendant ce temps. La conversation part
      # donc dans un processus séparé, et la réponse revient par une promesse.
      # promises::then() et non les opérateurs %...>% / %...!% : shiny ne les
      # ré-exporte PAS (vérifié), et le fichier parserait quand même — l'erreur
      # ne serait apparue qu'au premier clic sur « Interroger ».
      promises::then(
        promises::future_promise({
          analyse_rafraichir_zonages(utils::modifyList(cfg$db, cfg$db_app))
          analyse_conversation(q, systeme, cfg, historique)
        }, seed = TRUE),
        onFulfilled = function(res) {
          shinyjs::enable("poser")
          # La conversation rendue par le processus remplace la nôtre : elle
          # porte le tour qui vient de se jouer, inchangé. En cas d'erreur,
          # elle vaut l'ancienne — le tour raté n'entre pas dans le fil.
          historique_rv(res$messages)
          e <- list(question = q, texte = res$texte, erreur = res$erreur,
                    jetons = res$jetons, modele = res$modele, journal = res$journal)
          echanges_rv(c(echanges_rv(), list(e)))
          .consigner_question(e)
          etat_rv(if (is.null(res$erreur)) NULL else "erreur")
          if (is.null(res$erreur)) updateTextAreaInput(session, "question", value = "")
          invisible(NULL)
        },
        onRejected = function(e) {
          shinyjs::enable("poser")
          ech <- list(question = q,
                      erreur = paste("Échec de l'interrogation :", conditionMessage(e)),
                      jetons = NULL, modele = NULL, journal = list())
          echanges_rv(c(echanges_rv(), list(ech)))
          .consigner_question(ech)
          etat_rv("erreur")
          invisible(NULL)
        }
      )

      # On ne renvoie PAS la promesse : l'observateur rendrait la main à Shiny
      # en l'attendant, ce qui est inutile ici et masquerait les erreurs.
      invisible(NULL)
    })

    # ---- Rendu ------------------------------------------------------------
    # ---- Nouvelle conversation --------------------------------------------
    output$nouvelle <- renderUI({
      n <- length(echanges_rv())
      if (!n) return(NULL)
      actionButton(session$ns("nouvelle_conv"),
                   sprintf("🔄 Nouvelle conversation (%d échange%s)",
                           n, if (n > 1) "s" else ""),
                   class = "btn-default btn-secondary", width = "100%")
    })

    observeEvent(input$nouvelle_conv, {
      if (!.peut_interroger()) return(.refus_interroger())
      .remise_a_zero()
    })

    # Changer de modèle en cours de conversation reviendrait à renvoyer à un
    # modèle des blocs de raisonnement qu'un autre a écrits : ils seraient
    # silencieusement écartés, et la conversation perdrait son fil sans que
    # rien ne le dise. On repart donc de zéro, en le disant.
    observeEvent(input$modele, {
      if (!length(echanges_rv())) return(invisible(NULL))
      if (identical(input$modele, modele_fige_rv())) return(invisible(NULL))
      .remise_a_zero()
      showToast("info", "Nouvelle conversation",
                "Changer de modèle repart d'une conversation vide.")
    }, ignoreInit = TRUE)

    # ---- Rendu du fil -------------------------------------------------------
    # Le coût d'un échange, au tarif du modèle qui a RÉPONDU : un repli serveur
    # peut en changer en cours d'appel.
    .cout_usd <- function(e) {
      def <- ANALYSE_MODELES[[e$modele %||% ""]]
      if (is.null(def) || is.null(e$jetons)) return(NA_real_)
      sum(e$jetons * def$prix[names(e$jetons)]) / 1e6
    }

    .bloc_cout <- function(e) {
      if (is.null(e$jetons)) return(NULL)
      usd <- .cout_usd(e); j <- e$jetons
      div(class = "tc-analyse-cout",
          sprintf("%s jetons — %s — %s", format(sum(j), big.mark = " "),
                  e$modele %||% "modèle inconnu",
                  if (is.na(usd)) "tarif inconnu"
                  else paste0(formatC(usd, format = "f", digits = 4), "$ US")),
          tags$span(class = "tc-analyse-cout-detail",
                    sprintf(" (entrée %s, sortie %s, cache lu %s, cache écrit %s)",
                            format(j[["entree"]], big.mark = " "),
                            format(j[["sortie"]], big.mark = " "),
                            format(j[["cache_lecture"]], big.mark = " "),
                            format(j[["cache_ecriture"]], big.mark = " "))))
    }

    #' Le bouton d'export d'une requête — ou rien.
    #'
    #' Rien, c'est le cas normal pour une agrégation : « combien de parcelles
    #' par commune » ne désigne aucune entité géographique. Proposer l'export
    #' là serait promettre un fichier qu'on ne peut pas produire.
    #'
    #' Le clic passe par Shiny.setInputValue plutôt que par un actionButton :
    #' les boutons sont créés dans un renderUI, donc en nombre variable, et
    #' il faudrait sinon enregistrer un observateur par bouton. Ici un seul
    #' observateur reçoit les coordonnées (échange, requête).
    .bouton_export <- function(x, i, k, plusieurs = FALSE) {
      if (!is.null(x$erreur)) return(NULL)
      if (!isTRUE(x$n > 0)) return(NULL)
      couche <- analyse_couche_de(x$colonnes)
      if (is.null(couche)) return(NULL)
      # Quand l'échange a lancé plusieurs requêtes, le libellé seul ne dit pas
      # laquelle on exporte : on y accroche le but annoncé par le modèle.
      titre <- sprintf("\u2b07 Exporter la couche (%s)", couche$libelle)
      if (plusieurs && nzchar(x$but %||% ""))
        titre <- paste0(titre, " \u2014 ", substr(x$but, 1, 60))
      tags$button(
        type = "button", class = "btn btn-primary btn-sm",
        style = "margin:0 6px 6px 0;",
        onclick = sprintf(
          "Shiny.setInputValue('%s', {i:%d, k:%d}, {priority:'event'})",
          session$ns("exporter"), i, k),
        titre)
    }

    #' Quelle requête exporter, pour chaque type de couche.
    #'
    #' Une question large fait lancer plusieurs requêtes au modèle, et
    #' plusieurs peuvent désigner le MÊME grain — l'une étant souvent une
    #' étape intermédiaire, moins complète que l'autre. Proposer les deux,
    #' c'est demander de choisir sans donner de quoi choisir. On n'en garde
    #' donc qu'une par type de couche :
    #'   - celle qui désigne le plus d'entités ;
    #'   - à égalité, celle qui porte le plus de colonnes — « toutes les
    #'     infos » se lit là ;
    #'   - à égalité encore, la dernière, le modèle affinant au fil de ses
    #'     appels.
    #'
    #' ⚠️ `n` est le nombre de lignes RENDUES au modèle, donc plafonné à
    #' ANALYSE_MAX_LIGNES. Deux requêtes qui dépassent ce plafond sont donc
    #' départagées par leurs colonnes, pas par leur volume réel. C'est sans
    #' conséquence : l'export, lui, rejoue la requête sans plafond.
    .exports_retenus <- function(j) {
      cand <- list()
      for (k in seq_along(j)) {
        x <- j[[k]]
        if (!is.null(x$erreur) || !isTRUE(x$n > 0)) next
        couche <- analyse_couche_de(x$colonnes)
        if (is.null(couche)) next
        g <- couche$libelle
        vieux <- cand[[g]]
        if (is.null(vieux) || x$n > vieux$n ||
            (x$n == vieux$n && length(x$colonnes) >= length(vieux$cols)))
          cand[[g]] <- list(k = k, n = x$n, cols = x$colonnes)
      }
      cand
    }

    #' Les boutons d'export de l'échange, EN DEHORS du bloc repliable.
    #'
    #' Première version : ils étaient placés sous chaque requête, donc dans le
    #' <details> « Requêtes exécutées », fermé par défaut — invisibles tant
    #' qu'on ne le dépliait pas. Un bouton qu'il faut chercher n'existe pas.
    #' Ils vivent donc ici, juste sous la réponse.
    .bloc_exports <- function(e, i) {
      j <- e$journal
      if (!length(j)) return(NULL)
      ret <- .exports_retenus(j)
      if (!length(ret)) return(NULL)
      # Ordre d'affichage : celui de ANALYSE_EXPORT_CLES, du grain le plus fin
      # au plus large — et non l'ordre d'exécution des requêtes, qui dépend de
      # la façon dont le modèle a cheminé.
      ordre <- unique(vapply(ANALYSE_EXPORT_CLES, function(c) c$libelle, ""))
      ret <- ret[intersect(ordre, names(ret))]
      lapply(ret, function(r)
        .bouton_export(j[[r$k]], i, r$k, plusieurs = length(ret) > 1))
    }

    #' Le bouton d'export des tableaux de la RÉPONSE.
    #'
    #' Distinct de l'export de couche, et volontairement : celui-ci rend ce
    #' qui est affiché, l'autre rejoue la requête et rend tout. Une réponse
    #' peut très bien porter un tableau sans qu'aucune couche soit possible —
    #' « combien de parcelles par commune » en est l'exemple même.
    .bloc_tableau <- function(e, i) {
      if (!is.null(e$erreur)) return(NULL)
      n <- length(analyse_tableaux_markdown(e$texte))
      if (!n) return(NULL)
      tags$button(
        type = "button", class = "btn btn-secondary btn-sm",
        style = "margin:0 6px 6px 0;",
        onclick = sprintf("Shiny.setInputValue('%s', {i:%d}, {priority:'event'})",
                          session$ns("exporter_tableau"), i),
        if (n > 1) sprintf("\u2b07 Exporter les tableaux (%d)", n)
        else "\u2b07 Exporter le tableau")
    }

    .bloc_requetes <- function(e, i) {
      j <- e$journal
      if (!length(j)) return(NULL)
      retenus <- .exports_retenus(j)
      tags$details(
        tags$summary(style = "cursor:pointer;",
                     sprintf("Requêtes exécutées (%d)", length(j))),
        lapply(seq_along(j), function(k) { x <- j[[k]]; tagList(
          if (nzchar(x$but %||% "")) tags$p(class = "text-muted",
                                            htmltools::htmlEscape(x$but)),
          tags$pre(class = "tc-analyse-sql", htmltools::htmlEscape(x$sql)),
          tags$p(class = "text-muted", style = "font-size:12px;",
                 if (!is.null(x$erreur)) paste("Refusée :", x$erreur)
                 else sprintf("%s ligne(s)", x$n)),
          # Dire POURQUOI il n'y a pas de bouton — qu'aucune couche ne soit
          # possible, ou qu'une autre requête ait été retenue pour ce grain.
          # Sans ces lignes, « pas de couche possible », « requête écartée »
          # et « bouton que je n'ai pas trouvé » se ressemblent tous les trois.
          if (is.null(x$erreur) && isTRUE(x$n > 0)) {
            couche <- analyse_couche_de(x$colonnes)
            if (is.null(couche))
              tags$p(class = "text-muted", style = "font-size:12px;font-style:italic;",
                     "Pas de couche exportable : la requête ne renvoie ni parcelle_id, ",
                     "ni site_id, ni secteur_id, ni code_insee.")
            else if (!identical(retenus[[couche$libelle]]$k, k))
              tags$p(class = "text-muted", style = "font-size:12px;font-style:italic;",
                     sprintf("Couche %s possible ici aussi, mais une autre requête en désigne davantage : c'est elle que le bouton exporte.",
                             couche$libelle))
          }
        )})
      )
    }

    .bloc_echange <- function(e, i, separe) {
      div(
        class = "tc-analyse-echange",
        if (separe) hr(),
        div(class = "tc-analyse-question", htmltools::htmlEscape(e$question)),
        if (!is.null(e$erreur))
          div(class = "alert alert-danger",
              HTML(gsub("\n", "<br>", htmltools::htmlEscape(e$erreur), fixed = TRUE)))
        else
          # Le modèle répond en Markdown — tableaux, listes, gras. On le
          # convertit, PUIS on assainit : le HTML produit porte des données de
          # la base, dont des descriptions de site saisies librement, et tout
          # ce qui n'est pas une balise de mise en forme tombe (assainir_html).
          div(class = "tc-analyse-rep",
              HTML(assainir_html(commonmark::markdown_html(
                e$texte %||% "", extensions = TRUE, smart = TRUE)))),
        # Une seule rangée pour tous les exports — couches et tableaux —, et
        # rien du tout si l'échange n'en propose aucun.
        local({
          b <- c(.bloc_exports(e, i), list(.bloc_tableau(e, i)))
          b <- Filter(Negate(is.null), b)
          if (length(b)) div(style = "margin:6px 0 10px;", b)
        }),
        .bloc_cout(e),
        .bloc_requetes(e, i)
      )
    }

    #' Consigner la question posée, pour l'onglet Activité.
    #'
    #' log_action() n'écrit que dans le journal texte du serveur : rien d'y
    #' interrogeable. D'où cette table, dont c'est la seule raison d'être.
    #'
    #' Écrite dans TOUS les cas, succès comme échec : un compte qui ne
    #' retiendrait que les questions abouties dirait l'usage réussi, pas
    #' l'usage. Et l'écriture ne doit jamais faire échouer la réponse déjà
    #' obtenue — d'où le tryCatch, qui se contente de laisser une trace.
    .consigner_question <- function(e) {
      tryCatch({
        u <- tryCatch(current_user_rv(), error = function(z) NULL)
        qui <- if (!is.null(u) && nrow(u) > 0 && !is.na(u$email[1])) u$email[1] else NA_character_
        j <- e$jetons
        usd <- .cout_usd(e)
        DBI::dbExecute(con, glue::glue_sql("
          INSERT INTO gestcons.analyses_questions
            (pose_par, modele, nb_requetes, jetons_entree, jetons_sortie, cout_usd, erreur,
             message_erreur)
          VALUES ({qui}, {e$modele %||% NA_character_}, {length(e$journal)},
                  {if (is.null(j)) NA_integer_ else as.integer(j[['entree']])},
                  {if (is.null(j)) NA_integer_ else as.integer(j[['sortie']])},
                  {if (is.na(usd)) NA_real_ else as.numeric(usd)},
                  {!is.null(e$erreur)},
                  {if (is.null(e$erreur)) NA_character_ else substr(e$erreur, 1, 500)})", .con = con))
      }, error = function(err)
        message("Analyses : question non consignée — ", conditionMessage(err)))
      invisible(NULL)
    }

    # -------------------------------------------------------------------
    # Export d'une couche
    # -------------------------------------------------------------------
    # Ce que l'onglet rend au modèle est plafonné à 200 lignes ; l'export, lui,
    # ne doit pas en hériter, sinon « la liste des sites de zones humides »
    # s'exporterait tronquée sans que rien ne le signale. La requête est donc
    # REJOUÉE sans ce plafond — même rôle, même garde, rien de plus n'est
    # ouvert : c'est la chaîne exacte qui avait déjà été acceptée.
    export_rv <- reactiveVal(NULL)

    .relire_sans_plafond <- function(sql) {
      safe_db_query(pool_analyses, sprintf(
        "SELECT * FROM (%s) q LIMIT %d",
        sub(";\\s*$", "", sql), ANALYSE_EXPORT_MAX + 1L))
    }

    #' La requête de géométrie, prise dans les tables de base sous le rôle de
    #' l'application — jamais sous celui de l'onglet, qui n'y a pas accès.
    #'
    #' COALESCE(cadastre, manuel) : sans lui, les parcelles à géométrie
    #' dessinée manqueraient à l'appel, et elles sont 41 au 2026-10-27.
    #' La géométrie d'un site n'existe pas en colonne : c'est l'union de
    #' celle de ses parcelles, comme pour le cadrage de carte.
    #'
    #' `compte = TRUE` rend le NOMBRE d'entités réellement géométrables, pour
    #' que la modale l'annonce AVANT le téléchargement. Mesuré le 2026-10-27 :
    #' sur les 113 secteurs, 77 seulement ont une géométrie — les 36 autres
    #' n'ont aucune parcelle. Les écarter en silence serait livrer une couche
    #' amputée sans le dire.
    .sql_geometries <- function(cle, lst, srid = 2154L, compte = FALSE) {
      geom <- "COALESCE(c.geompar, pm.geometrie)"
      # La commune ne se reconstruit pas depuis les parcelles : sa géométrie
      # existe en propre dans gestcons.communes (IGN ADMIN-EXPRESS). La table
      # n'est PAS accordée au rôle de l'onglet — c'est l'application qui la
      # lit, au moment de l'export.
      if (identical(cle$grain, "communes"))
        return(sprintf("SELECT %s FROM gestcons.communes co WHERE co.insee_com IN (%s)",
                       if (compte) "count(*)::int AS n"
                       else sprintf("co.insee_com AS %s, ST_Transform(co.geometry, %d) AS geom",
                                    cle$colonne, srid),
                       lst))
      # Une intercommunalité n'a pas de géométrie en propre : c'est l'union de
      # celle de ses communes. Mesuré le 2026-10-28 : les 8 EPCI d'Ariège,
      # 327 communes, s'unissent en moins d'une seconde.
      if (identical(cle$grain, "epci"))
        return(sprintf("SELECT %s FROM gestcons.communes co
                         WHERE co.siren_epci IN (%s)%s",
                       if (compte) "count(DISTINCT co.siren_epci)::int AS n"
                       else sprintf("co.siren_epci AS %s, ST_Transform(ST_Union(co.geometry), %d) AS geom",
                                    cle$colonne, srid),
                       lst, if (compte) "" else " GROUP BY co.siren_epci"))
      jt <- "
        LEFT JOIN gestcons.dico_cadastre c
          ON pb.type_parcelle_id = 1 AND c.id = pb.parcellaire_id
        LEFT JOIN gestcons.perimetre_parcellaire_manuel pm
          ON pb.type_parcelle_id = 2 AND pm.id = pb.parcellaire_id"
      if (identical(cle$grain, "parcelles"))
        sprintf("SELECT %s FROM gestcons.parcelles_base pb %s
                 WHERE pb.id IN (%s) AND %s IS NOT NULL",
                if (compte) "count(*)::int AS n"
                else sprintf("pb.id AS %s, ST_Transform(ST_Multi(%s), %d) AS geom",
                             cle$colonne, geom, srid),
                jt, lst, geom)
      else
        sprintf("SELECT %s FROM gestcons.sites s
                 JOIN gestcons.parcelles_base pb ON pb.site_id = s.id AND pb.actif %s
                 WHERE s.id IN (%s) AND %s IS NOT NULL %s",
                if (compte) "count(DISTINCT s.id)::int AS n"
                else sprintf("s.id AS %s, ST_Transform(ST_Multi(ST_Union(%s)), %d) AS geom",
                             cle$colonne, geom, srid),
                jt, lst, geom, if (compte) "" else "GROUP BY s.id")
    }

    .geometries <- function(cle, ids, srid) {
      lst <- analyse_cles_sql(cle, ids)
      if (is.null(lst)) return(NULL)
      tryCatch(sf::st_read(con, query = .sql_geometries(cle, lst, srid),
                           quiet = TRUE), error = function(e) NULL)
    }

    .compte_geometries <- function(cle, ids) {
      lst <- analyse_cles_sql(cle, ids)
      if (is.null(lst)) return(0L)
      d <- safe_db_query(con, .sql_geometries(cle, lst, compte = TRUE))
      if (is.null(d) || !nrow(d)) 0L else as.integer(d$n[1])
    }

    observeEvent(input$exporter, {
      if (!.peut_interroger()) return(.refus_interroger())
      co  <- input$exporter
      ech <- echanges_rv()
      e   <- tryCatch(ech[[as.integer(co$i)]], error = function(z) NULL)
      x   <- tryCatch(e$journal[[as.integer(co$k)]], error = function(z) NULL)
      if (is.null(x)) return(invisible(NULL))
      cle <- analyse_couche_de(x$colonnes)
      if (is.null(cle)) return(invisible(NULL))

      d <- .relire_sans_plafond(x$sql)
      if (is.null(d) || !nrow(d)) {
        showToast("warning", "Rien à exporter",
                  "La requête ne renvoie aucune ligne.")
        return(invisible(NULL))
      }
      ids <- unique(d[[cle$colonne]][!is.na(d[[cle$colonne]])])
      if (length(ids) > ANALYSE_EXPORT_MAX) {
        showToast("warning", "Couche trop volumineuse",
                  sprintf("%s entités, au-delà du plafond de %s. Affine la question.",
                          format(length(ids), big.mark = " "),
                          format(ANALYSE_EXPORT_MAX, big.mark = " ")))
        return(invisible(NULL))
      }
      avec_geom <- .compte_geometries(cle, ids)
      if (avec_geom == 0L) {
        showToast("warning", "Aucune géométrie",
                  sprintf("Les %s désignés par cette requête n'ont aucune parcelle localisée.",
                          cle$libelle))
        return(invisible(NULL))
      }
      export_rv(list(cle = cle, donnees = d, ids = ids))

      showModal(modalDialog(
        title = "Exporter la couche", easyClose = TRUE,
        div(class = "tc-bloc-lecture",
            tags$p(sprintf("%s %s, pour %s ligne(s) renvoyée(s) par la requête.",
                           format(length(ids), big.mark = " "), cle$libelle,
                           format(nrow(d), big.mark = " "))),
            if (avec_geom < length(ids))
              tags$p(class = "text-warning",
                     sprintf("La couche en contiendra %s : %s n'ont aucune parcelle localisée, donc aucune géométrie.",
                             format(avec_geom, big.mark = " "),
                             format(length(ids) - avec_geom, big.mark = " "))),
            if (nrow(d) > length(ids))
              tags$p(class = "text-muted",
                     "La requête renvoie plusieurs lignes par entité ; la couche",
                     " en comptera une seule par entité, attributs de la",
                     " première ligne rencontrée.")),
        selectInput(session$ns("export_format"), "Format",
                    choices = stats::setNames(
                      names(ANALYSE_EXPORT_FORMATS),
                      vapply(ANALYSE_EXPORT_FORMATS, function(f) f$libelle, "")),
                    selected = "gpkg"),
        uiOutput(session$ns("export_note")),
        footer = tagList(
          modalButton("Annuler"),
          downloadButton(session$ns("telecharger"), "Télécharger",
                         class = "btn-primary"))
      ))
    })

    output$export_note <- renderUI({
      f <- ANALYSE_EXPORT_FORMATS[[input$export_format %||% "gpkg"]]
      tags$p(class = "text-muted", style = "font-size:12px;",
             sprintf("Projection : %s.",
                     if (f$srid == 2154L) "Lambert-93 (EPSG:2154)"
                     else "WGS84 (EPSG:4326), imposé par le format"),
             if (isTRUE(f$zip))
               " Le Shapefile tient en plusieurs fichiers, livrés dans un .zip ; ses noms de colonnes sont tronqués à 10 caractères par le format lui-même.")
    })

    output$telecharger <- downloadHandler(
      filename = function() {
        f  <- ANALYSE_EXPORT_FORMATS[[input$export_format %||% "gpkg"]]
        ex <- export_rv()
        sprintf("terracen_%s_%s.%s",
                if (is.null(ex)) "couche" else ex$cle$libelle,
                format(Sys.Date(), "%Y%m%d"),
                if (isTRUE(f$zip)) "zip" else f$ext)
      },
      content = function(file) {
        ex <- export_rv()
        f  <- ANALYSE_EXPORT_FORMATS[[input$export_format %||% "gpkg"]]
        if (is.null(ex)) stop("Rien à exporter.")
        geo <- .geometries(ex$cle, ex$ids, f$srid)
        if (is.null(geo) || !nrow(geo))
          stop("Aucune géométrie trouvée pour ces entités.")

        # Les attributs sont les colonnes de la requête. Une entité ne peut
        # porter qu'un jeu d'attributs : on garde la première ligne de chaque
        # clé, ce qui est annoncé dans la modale quand le cas se présente.
        att <- ex$donnees
        att <- att[!duplicated(att[[ex$cle$colonne]]), , drop = FALSE]
        att <- att[, setdiff(names(att), c("geom", "geometry")), drop = FALSE]
        # La clé doit avoir le MÊME type des deux côtés du merge : la
        # géométrie la rend telle que PostgreSQL la typte, les attributs
        # viennent de l'autre connexion. Le texte est le dénominateur commun.
        att[[ex$cle$colonne]] <- as.character(att[[ex$cle$colonne]])
        geo[[ex$cle$colonne]] <- as.character(geo[[ex$cle$colonne]])
        couche <- merge(geo, att, by = ex$cle$colonne, all.x = TRUE)

        dossier <- file.path(tempdir(), paste0("tc_export_", as.integer(Sys.time())))
        dir.create(dossier, showWarnings = FALSE, recursive = TRUE)
        on.exit(unlink(dossier, recursive = TRUE), add = TRUE)
        cible <- file.path(dossier, paste0("terracen_", ex$cle$libelle, ".", f$ext))
        # Pas de delete_dsn : le dossier est créé neuf juste au-dessus, et
        # GDAL émet une erreur « does not appear to be a file or directory »
        # quand on lui demande d'effacer un fichier qui n'existe pas.
        sf::st_write(couche, cible, driver = f$pilote, quiet = TRUE)

        if (isTRUE(f$zip)) {
          # utils::zip s'appuie sur /usr/bin/zip, présent sur le serveur
          # (vérifié) ; -j pour ne pas embarquer l'arborescence temporaire.
          morceaux <- list.files(dossier, full.names = TRUE)
          utils::zip(file, morceaux, flags = "-j -q")
        } else {
          file.copy(cible, file, overwrite = TRUE)
        }
        log_action(session, current_user_rv,
                   sprintf("Analyses : export %s (%d entités, %s)",
                           ex$cle$libelle, nrow(couche), f$pilote))
      }
    )

    # -------------------------------------------------------------------
    # Export des tableaux d'une réponse
    # -------------------------------------------------------------------
    tableaux_rv <- reactiveVal(NULL)

    observeEvent(input$exporter_tableau, {
      if (!.peut_interroger()) return(.refus_interroger())
      ech <- echanges_rv()
      e <- tryCatch(ech[[as.integer(input$exporter_tableau$i)]], error = function(z) NULL)
      tx <- analyse_tableaux_markdown(e$texte)
      if (!length(tx)) {
        showToast("warning", "Aucun tableau",
                  "Cette réponse ne contient pas de tableau.")
        return(invisible(NULL))
      }
      tableaux_rv(tx)

      # Un tableau se reconnaît à ses colonnes bien mieux qu'à son rang :
      # « Tableau 2 » ne dit rien, « Milieu, Sites » se retrouve d'un coup d'œil.
      choix <- stats::setNames(
        as.character(seq_along(tx)),
        vapply(seq_along(tx), function(k)
          sprintf("%d. %s (%d lignes)", k,
                  substr(paste(names(tx[[k]]), collapse = ", "), 1, 60),
                  nrow(tx[[k]])), ""))

      showModal(modalDialog(
        title = if (length(tx) > 1) "Exporter un tableau" else "Exporter le tableau",
        easyClose = TRUE,
        if (length(tx) > 1)
          selectInput(session$ns("tableau_choisi"), "Tableau", choices = choix)
        else
          div(class = "tc-bloc-lecture",
              tags$p(sprintf("%d lignes, %d colonnes : %s", nrow(tx[[1]]), ncol(tx[[1]]),
                             paste(names(tx[[1]]), collapse = ", ")))),
        selectInput(session$ns("tableau_format"), "Format",
                    choices = stats::setNames(
                      names(ANALYSE_TABLEAU_FORMATS),
                      vapply(ANALYSE_TABLEAU_FORMATS, function(f) f$libelle, "")),
                    selected = "csv_excel"),
        tags$p(class = "text-muted", style = "font-size:12px;",
               "Le tableau est exporté tel qu'il s'affiche, mise en forme retirée. ",
               "Pour les données complètes derrière la réponse, c'est l'export de ",
               "couche qu'il faut, quand il est proposé."),
        footer = tagList(
          modalButton("Annuler"),
          downloadButton(session$ns("telecharger_tableau"), "Télécharger",
                         class = "btn-primary"))
      ))
    })

    output$telecharger_tableau <- downloadHandler(
      filename = function() {
        f <- ANALYSE_TABLEAU_FORMATS[[input$tableau_format %||% "csv_excel"]]
        sprintf("terracen_tableau_%s.%s", format(Sys.Date(), "%Y%m%d"), f$ext)
      },
      content = function(file) {
        tx <- tableaux_rv()
        if (is.null(tx) || !length(tx)) stop("Aucun tableau à exporter.")
        k <- suppressWarnings(as.integer(input$tableau_choisi %||% "1"))
        if (is.na(k) || k < 1 || k > length(tx)) k <- 1L
        f <- ANALYSE_TABLEAU_FORMATS[[input$tableau_format %||% "csv_excel"]]
        lignes <- analyse_tableau_csv(tx[[k]], f$sep)
        # Écriture en binaire : c'est le seul moyen de poser la marque d'ordre
        # des octets avant la première ligne, et useBytes empêche R de
        # retranscoder ce qui est déjà de l'UTF-8.
        cx <- file(file, open = "wb")
        on.exit(close(cx), add = TRUE)
        if (isTRUE(f$bom)) writeBin(as.raw(c(0xEF, 0xBB, 0xBF)), cx)
        writeLines(enc2utf8(lignes), cx, useBytes = TRUE)
        log_action(session, current_user_rv,
                   sprintf("Analyses : export d'un tableau (%d lignes, %s)",
                           nrow(tx[[k]]), f$libelle))
      }
    )

    output$fil <- renderUI({
      ech <- echanges_rv()
      encours <- identical(etat_rv(), "en cours")
      if (!length(ech) && !encours)
        return(div(class = "text-muted",
                   "Posez une question dans la colonne de gauche."))

      total <- sum(vapply(ech, function(e) {
        u <- .cout_usd(e); if (is.na(u)) 0 else u
      }, numeric(1)))

      # La dernière réponse en premier : c'est elle qu'on vient lire. Seul
      # l'affichage est inversé — `i` reste l'indice chronologique, celui par
      # lequel les exports retrouvent leur échange (input$exporter$i).
      ordre <- rev(seq_along(ech))

      tagList(
        if (encours) div(class = "text-muted", style = "margin-bottom:10px;",
                         "Interrogation en cours…"),
        lapply(ordre, function(i)
          .bloc_echange(ech[[i]], i, separe = encours || i != ordre[1])),
        if (length(ech) > 1)
          div(class = "tc-analyse-cout", style = "margin-top:12px;",
              sprintf("Conversation : %d échanges — %s$ US au total",
                      length(ech), formatC(total, format = "f", digits = 4)))
      )
    })

  })
}
