#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# check_missing_docs.R
#
# Liste les pièces jointes référencées en base mais ABSENTES du disque
# (liens cassés), avec pour chaque fichier manquant :
#   - le chemin attendu du fichier sur le disque,
#   - le(s) site(s) auquel/auxquels le document est lié,
#   - le(s) gestionnaire(s) de ce(s) site(s).
#
# Sortie : un fichier CSV (missing_docs_report.csv) + un récap à l'écran.
#
# Usage :
#   Rscript scripts/check_missing_docs.R              # docs_root = ./Docs
#   Rscript scripts/check_missing_docs.R /chemin/app  # docs_root = /chemin/app/Docs
#
# Identifiants DB lus depuis l'environnement (cf. app.R / ~shiny/.Renviron) :
#   DB_NAME, DB_HOST, DB_USER, DB_PASSWORD   (port 5432, sslmode=require)
#
# Code de sortie : 0 si aucun fichier manquant, 1 si au moins un lien cassé.
# ---------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  library(DBI)
  library(RPostgres)
}))

## --- Dossier de stockage des fichiers --------------------------------------
args <- commandArgs(trailingOnly = TRUE)
app_dir   <- if (length(args) >= 1 && nzchar(args[1])) args[1] else getwd()
docs_root <- normalizePath(file.path(app_dir, "Docs"), mustWork = FALSE)

if (!dir.exists(docs_root)) {
  stop(sprintf("Dossier Docs introuvable : %s", docs_root))
}
cat(sprintf("Dossier des fichiers : %s\n", docs_root))

## --- Connexion DB (mêmes paramètres que app.R) ------------------------------
con <- dbConnect(
  RPostgres::Postgres(),
  dbname   = Sys.getenv("DB_NAME"),
  host     = Sys.getenv("DB_HOST"),
  port     = 5432,
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD"),
  sslmode  = "require"
)
on.exit(dbDisconnect(con), add = TRUE)

## --- URL stockée (ex. "docs/2024/x.pdf", "/docs/...", ".\docs\...")
##     -> chemin absolu sur le disque ----------------------------------------
to_abs_path <- function(url) {
  rel <- gsub("\\\\", "/", url)                            # antislashs -> slash
  rel <- sub("^\\.?/?docs/?", "", rel, ignore.case = TRUE) # retire le préfixe docs/
  file.path(docs_root, rel)
}

## --- Requêtes : un fichier = (table, id, url, sites, gestionnaires) ---------
## Le lien document -> site -> gestionnaire diffère selon le type de document.
## On agrège les sites/gestionnaires (un doc peut concerner plusieurs sites).
## LEFT JOIN partout : un doc sans site rattaché apparaît quand même.
##
## Fragments communs :
##   sites.libelle                            = nom du site
##   dico_cen.libelle_long (via gestionnaire_site) = nom du gestionnaire

agg <- "
  string_agg(DISTINCT s.libelle,        ' | ') AS sites,
  string_agg(DISTINCT dc.libelle_long,  ' | ') AS gestionnaires"

queries <- list(
  # 1. Pièces jointes contrats fonciers : contrat -> parcelles -> site
  list(table = "docs_contrat_foncier", sql = sprintf("
    SELECT d.id::text AS id, d.url AS url, %s
    FROM gestcons.docs_contrat_foncier d
    LEFT JOIN gestcons.contrats_foncier_parcelles cfp ON cfp.contrat_id = d.contrat_id
    LEFT JOIN gestcons.parcelles p ON p.id = cfp.parcelle_id
    LEFT JOIN gestcons.sites s   ON s.id = p.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url IS NOT NULL AND d.url <> '' AND d.url NOT ILIKE 'http%%'
    GROUP BY d.id, d.url", agg)),

  # 2. Pièces jointes contrats agricoles : contrat -> parcelles -> site
  list(table = "docs_contrat_agricole", sql = sprintf("
    SELECT d.id::text AS id, d.url AS url, %s
    FROM gestcons.docs_contrat_agricole d
    LEFT JOIN gestcons.contrats_agricoles_parcelles cap ON cap.contrat_agri_id = d.contrat_id
    LEFT JOIN gestcons.parcelles p ON p.id = cap.parcelle_id
    LEFT JOIN gestcons.sites s   ON s.id = p.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url IS NOT NULL AND d.url <> '' AND d.url NOT ILIKE 'http%%'
    GROUP BY d.id, d.url", agg)),

  # 3. Pièces jointes animations foncières : animation -> parcelles -> site
  list(table = "docs_animation_fonciere", sql = sprintf("
    SELECT d.id::text AS id, d.url AS url, %s
    FROM gestcons.docs_animation_fonciere d
    LEFT JOIN gestcons.animation_fonciere_parcelles afp ON afp.animation_id = d.animation_id
    LEFT JOIN gestcons.parcelles p ON p.id = afp.parcelle_id
    LEFT JOIN gestcons.sites s   ON s.id = p.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url IS NOT NULL AND d.url <> '' AND d.url NOT ILIKE 'http%%'
    GROUP BY d.id, d.url", agg)),

  # 4. Pièces jointes animations agricoles : animation -> parcelles -> site
  list(table = "docs_animation_agricole", sql = sprintf("
    SELECT d.id::text AS id, d.url AS url, %s
    FROM gestcons.docs_animation_agricole d
    LEFT JOIN gestcons.animation_contrat_agricole_parcelles ap ON ap.animation_id = d.animation_id
    LEFT JOIN gestcons.parcelles p ON p.id = ap.parcelle_id
    LEFT JOIN gestcons.sites s   ON s.id = p.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url IS NOT NULL AND d.url <> '' AND d.url NOT ILIKE 'http%%'
    GROUP BY d.id, d.url", agg)),

  # 5. Documents de gestion : doc_gestion -> docs_gestion_sites -> site
  list(table = "doc_gestion", sql = sprintf("
    SELECT d.id::text AS id, d.url_doc_gestion AS url, %s
    FROM gestcons.doc_gestion d
    LEFT JOIN gestcons.docs_gestion_sites dgs ON dgs.doc_gestion_id = d.id
    LEFT JOIN gestcons.sites s   ON s.id = dgs.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url_doc_gestion IS NOT NULL AND d.url_doc_gestion <> ''
      AND d.url_doc_gestion NOT ILIKE 'http%%'
    GROUP BY d.id, d.url_doc_gestion", agg)),

  # 6. Documents d'évaluation : -> doc_gestion -> docs_gestion_sites -> site
  list(table = "doc_evaluation_doc_gestion", sql = sprintf("
    SELECT d.doc_gestion_id::text AS id, d.url_doc_evaluation AS url, %s
    FROM gestcons.doc_evaluation_doc_gestion d
    LEFT JOIN gestcons.docs_gestion_sites dgs ON dgs.doc_gestion_id = d.doc_gestion_id
    LEFT JOIN gestcons.sites s   ON s.id = dgs.site_id
    LEFT JOIN gestcons.dico_cen dc ON dc.id::varchar = s.gestionnaire_site
    WHERE d.url_doc_evaluation IS NOT NULL AND d.url_doc_evaluation <> ''
      AND d.url_doc_evaluation NOT ILIKE 'http%%'
    GROUP BY d.doc_gestion_id, d.url_doc_evaluation", agg))
)

## --- Parcours + test d'existence sur disque ---------------------------------
missing   <- list()
n_checked <- 0L

for (q in queries) {
  rows <- tryCatch(dbGetQuery(con, q$sql), error = function(e) {
    cat(sprintf("  /!\\  %s : %s\n", q$table, conditionMessage(e))); NULL
  })
  if (is.null(rows) || nrow(rows) == 0) next

  for (i in seq_len(nrow(rows))) {
    url <- rows$url[i]
    n_checked <- n_checked + 1L
    abs_path <- to_abs_path(url)
    if (!file.exists(abs_path)) {
      missing[[length(missing) + 1L]] <- data.frame(
        chemin_disque = abs_path,
        site          = if (is.na(rows$sites[i]))         "(aucun site)"        else rows$sites[i],
        gestionnaire  = if (is.na(rows$gestionnaires[i])) "(aucun gestionnaire)" else rows$gestionnaires[i],
        table         = q$table,
        id            = rows$id[i],
        url_base      = url,
        stringsAsFactors = FALSE
      )
    }
  }
}

## --- Rapport ---------------------------------------------------------------
cat(sprintf("\n%d piece(s) jointe(s) locale(s) verifiee(s).\n", n_checked))

if (length(missing) == 0) {
  cat("OK : aucun lien casse, tous les fichiers references sont presents.\n")
  quit(status = 0)
}

res <- do.call(rbind, missing)
cat(sprintf("\n%d fichier(s) reference(s) en base mais ABSENT(s) du disque :\n\n",
            nrow(res)))
for (i in seq_len(nrow(res))) {
  cat(sprintf("  - %s\n      site         : %s\n      gestionnaire : %s\n      (%s id=%s)\n",
              res$chemin_disque[i], res$site[i], res$gestionnaire[i],
              res$table[i], res$id[i]))
}

out_csv <- file.path(app_dir, "missing_docs_report.csv")
tryCatch({
  write.csv(res, out_csv, row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("\nRapport CSV : %s\n", out_csv))
}, error = function(e) cat(sprintf("\n(/!\\ CSV non ecrit : %s)\n",
                                   conditionMessage(e))))

quit(status = 1)
