#!/usr/bin/env Rscript
# ---------------------------------------------------------------------------
# check_orphan_files.R
#
# Liste (et, en option, supprime) les fichiers présents dans Docs/ qui ne sont
# référencés par AUCUNE URL en base — typiquement des pièces jointes devenues
# orphelines après suppression de contrats / animations / documents de gestion.
#
# C'est l'inverse de check_missing_docs.R (qui cherche les références sans
# fichier ; ici on cherche les fichiers sans référence).
#
# Usage :
#   Rscript scripts/check_orphan_files.R              # liste seulement (dry-run)
#   Rscript scripts/check_orphan_files.R /chemin/app  # docs_root = /chemin/app/Docs
#   Rscript scripts/check_orphan_files.R . --delete   # SUPPRIME réellement les orphelins
#
# Identifiants DB : DB_NAME, DB_HOST, DB_USER, DB_PASSWORD (port 5432, ssl require)
# ---------------------------------------------------------------------------

suppressWarnings(suppressMessages({
  library(DBI)
  library(RPostgres)
}))

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

args     <- commandArgs(trailingOnly = TRUE)
app_dir  <- if (length(args) >= 1 && nzchar(args[1]) && args[1] != "--delete") args[1] else getwd()
do_delete <- "--delete" %in% args
docs_root <- normalizePath(file.path(app_dir, "Docs"), mustWork = FALSE)

if (!dir.exists(docs_root)) stop(sprintf("Dossier Docs introuvable : %s", docs_root))
cat(sprintf("Dossier des fichiers : %s\n", docs_root))
cat(sprintf("Mode : %s\n", if (do_delete) "SUPPRESSION" else "liste seulement (dry-run)"))

con <- dbConnect(
  RPostgres::Postgres(),
  dbname = Sys.getenv("DB_NAME"), host = Sys.getenv("DB_HOST"), port = 5432,
  user = Sys.getenv("DB_USER"), password = Sys.getenv("DB_PASSWORD"), sslmode = "require"
)
on.exit(dbDisconnect(con), add = TRUE)

## --- 1) Tous les chemins relatifs RÉFÉRENCÉS en base ------------------------
ref_queries <- c(
  "SELECT url AS u FROM gestcons.docs_contrat_foncier",
  "SELECT url AS u FROM gestcons.docs_contrat_agricole",
  "SELECT url AS u FROM gestcons.docs_animation_fonciere",
  "SELECT url AS u FROM gestcons.docs_animation_agricole",
  "SELECT url_doc_gestion AS u FROM gestcons.doc_gestion",
  "SELECT url_doc_evaluation AS u FROM gestcons.doc_evaluation_doc_gestion"
)
to_rel <- function(url) {
  rel <- gsub("\\\\", "/", url)
  sub("^\\.?/?docs/?", "", rel, ignore.case = TRUE)
}
referenced <- character(0)
for (q in ref_queries) {
  rows <- tryCatch(dbGetQuery(con, q)$u, error = function(e) character(0))
  rows <- rows[!is.na(rows) & nzchar(rows) & !grepl("^https?://", rows, ignore.case = TRUE)]
  referenced <- c(referenced, to_rel(rows))
}
referenced <- unique(normalizePath(file.path(docs_root, referenced), mustWork = FALSE))

## --- 2) Tous les fichiers PRÉSENTS sur le disque ----------------------------
on_disk <- list.files(docs_root, recursive = TRUE, full.names = TRUE, all.files = FALSE)
on_disk <- normalizePath(on_disk, mustWork = FALSE)

## --- 3) Orphelins = sur le disque mais non référencés -----------------------
orphans <- setdiff(on_disk, referenced)

cat(sprintf("\n%d fichier(s) sur le disque, %d référence(s) en base.\n",
            length(on_disk), length(referenced)))

if (length(orphans) == 0) {
  cat("OK : aucun fichier orphelin.\n")
  quit(status = 0)
}

cat(sprintf("\n%d fichier(s) ORPHELIN(s) (présents mais non référencés) :\n\n",
            length(orphans)))
total_size <- 0
for (f in orphans) {
  sz <- tryCatch(file.info(f)$size, error = function(e) NA)
  total_size <- total_size + (sz %||% 0)
  cat(sprintf("  - %s (%s)\n", f,
              if (is.na(sz)) "?" else sprintf("%.1f Ko", sz / 1024)))
}
cat(sprintf("\nTaille totale : %.1f Mo\n", total_size / 1024^2))

if (do_delete) {
  ok <- vapply(orphans, function(f) isTRUE(tryCatch(file.remove(f), error = function(e) FALSE)),
               logical(1))
  cat(sprintf("\n%d/%d fichier(s) supprimé(s).\n", sum(ok), length(orphans)))
} else {
  cat("\n(Dry-run : rien supprimé. Relancez avec --delete pour supprimer.)\n")
}
