#!/usr/bin/env Rscript
# =============================================================================
# delete_pj_reference_cassee.R
#
# Supprime PROPREMENT les références cassées détectées par check_pj_fichiers.R,
# c.-à-d. les lignes de la base pointant vers un fichier ABSENT du disque.
#
# Nettoyage adapté à la table :
#   - Table de PJ dédiée (la ligne n'existe QUE pour le fichier) -> DELETE ligne
#       docs_animation_fonciere / docs_animation_agricole
#       docs_contrat_foncier   / docs_contrat_agricole
#       doc_evaluation_doc_gestion
#   - URL simple colonne d'un enregistrement métier -> UPDATE ... SET col = NULL
#       doc_gestion.url_doc_gestion  (on NE supprime PAS la ligne doc_gestion)
#   - Toute autre table inconnue -> UPDATE ... SET col = NULL (jamais de DELETE)
#
# SÉCURITÉS :
#   - DRY-RUN par défaut : affiche ce qui serait fait, ne modifie RIEN.
#     Il faut APPLY=1 (ou APPLY=true) pour exécuter réellement.
#   - Re-vérifie que le fichier est TOUJOURS absent avant d'agir (sinon ignore).
#   - Cible la ligne par (clé + URL exacte) ; en mode APPLY, tout tourne dans
#     UNE transaction : si une commande touche != 1 ligne -> ROLLBACK complet.
#
# ENTRÉE : le CSV produit par check_pj_fichiers.R
#     BROKEN_CSV : chemin du CSV (défaut : pj_references_cassees.csv)
# Filtres optionnels pour ne traiter QU'UNE référence :
#     ONLY_TABLE  : ne garder que cette table
#     ONLY_ROW_ID : ne garder que cette clé de ligne
#
# À EXÉCUTER SUR LE SERVEUR, mêmes variables d'env que TerraCen :
#     DB_HOST / DB_NAME / DB_USER / DB_PASSWORD  (DB_PORT optionnel, défaut 5432)
#
# Exemples :
#     # 1) Aperçu (ne modifie rien) :
#     Rscript scripts/delete_pj_reference_cassee.R
#     # 2) Une seule référence, pour de vrai :
#     ONLY_TABLE=docs_contrat_foncier ONLY_ROW_ID=42 APPLY=1 \
#       Rscript scripts/delete_pj_reference_cassee.R
#     # 3) Toutes les références cassées du CSV, pour de vrai :
#     APPLY=1 Rscript scripts/delete_pj_reference_cassee.R
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(RPostgres)
})

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

## ---- Paramètres -------------------------------------------------------------
BROKEN_CSV  <- Sys.getenv("BROKEN_CSV", "pj_references_cassees.csv")
APPLY       <- tolower(Sys.getenv("APPLY", "0")) %in% c("1", "true", "yes", "oui")
ONLY_TABLE  <- Sys.getenv("ONLY_TABLE", "")
ONLY_ROW_ID <- Sys.getenv("ONLY_ROW_ID", "")
SCHEMA      <- "gestcons"

## Tables où la ligne entière représente la PJ -> on SUPPRIME la ligne.
## (Toute table hors de cette liste -> on met seulement la colonne URL à NULL.)
DELETE_ROW_TABLES <- c("docs_animation_fonciere", "docs_animation_agricole",
                       "docs_contrat_foncier",    "docs_contrat_agricole",
                       "doc_evaluation_doc_gestion")

if (!file.exists(BROKEN_CSV)) {
  stop("CSV introuvable : ", BROKEN_CSV,
       "\n(lancer d'abord check_pj_fichiers.R, ou définir BROKEN_CSV)")
}

## ---- Connexion --------------------------------------------------------------
need    <- c("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD")
missing <- need[Sys.getenv(need) == ""]
if (length(missing)) {
  stop("Variables d'environnement manquantes : ", paste(missing, collapse = ", "))
}
con <- dbConnect(
  RPostgres::Postgres(),
  host     = Sys.getenv("DB_HOST"),
  dbname   = Sys.getenv("DB_NAME"),
  port     = as.integer(Sys.getenv("DB_PORT", "5432")),
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD")
)
on.exit(dbDisconnect(con), add = TRUE)

qi <- function(x) as.character(DBI::dbQuoteIdentifier(con, x))
ql <- function(x) as.character(DBI::dbQuoteLiteral(con, x))

## Colonne servant de clé de ligne (identique à check_pj_fichiers.R :
## `id` si présente, sinon 1re colonne en *_id).
all_cols <- dbGetQuery(con, sprintf(
  "SELECT table_name, column_name FROM information_schema.columns
   WHERE table_schema = '%s';", SCHEMA))
cols_by_table <- split(all_cols$column_name, all_cols$table_name)
id_col_for <- function(tbl) {
  cs <- cols_by_table[[tbl]] %||% character(0)
  if ("id" %in% cs) return("id")
  fk <- cs[grepl("_id$", cs)]
  if (length(fk)) return(fk[1])
  NA_character_
}

## ---- Lecture et filtrage du CSV ---------------------------------------------
df <- read.csv(BROKEN_CSV, colClasses = "character",
               stringsAsFactors = FALSE, encoding = "UTF-8")
req <- c("table", "column", "row_id", "url", "full_path")
if (!all(req %in% names(df))) {
  stop("Colonnes attendues manquantes dans le CSV : ",
       paste(setdiff(req, names(df)), collapse = ", "))
}
if (nzchar(ONLY_TABLE))  df <- df[df$table  == ONLY_TABLE, , drop = FALSE]
if (nzchar(ONLY_ROW_ID)) df <- df[df$row_id == ONLY_ROW_ID, , drop = FALSE]

cat(sprintf("Mode : %s\n", if (APPLY) "APPLY (modifications réelles)" else "DRY-RUN (aucune modification)"))
cat(sprintf("Base : %s@%s\n", Sys.getenv("DB_NAME"), Sys.getenv("DB_HOST")))
cat(sprintf("Références cassées à traiter (CSV filtré) : %d\n\n", nrow(df)))
if (nrow(df) == 0) { cat("Rien à faire.\n"); quit(save = "no") }

## ---- Construction des ordres SQL --------------------------------------------
plans <- list()
skipped <- 0L
for (i in seq_len(nrow(df))) {
  tbl <- df$table[i]; col <- df$column[i]
  rid <- df$row_id[i]; url <- df$url[i]; fp <- df$full_path[i]

  # Sécurité 1 : le fichier est-il réellement toujours absent ?
  if (nzchar(fp) && file.exists(fp)) {
    cat(sprintf("  IGNORÉ  %s#%s : le fichier existe (%s)\n", tbl, rid, fp)); skipped <- skipped + 1L; next
  }
  # Sécurité 2 : clé de ligne identifiable ?
  idcol <- id_col_for(tbl)
  if (is.na(idcol) || is.na(rid) || !nzchar(rid)) {
    cat(sprintf("  IGNORÉ  %s : clé de ligne indéterminée\n", tbl)); skipped <- skipped + 1L; next
  }

  tbl_ref <- paste0(SCHEMA, ".", qi(tbl))
  where   <- sprintf('%s::text = %s AND %s = %s',
                     qi(idcol), ql(rid), qi(col), ql(url))
  if (tbl %in% DELETE_ROW_TABLES) {
    action <- "DELETE ligne"
    sql    <- sprintf("DELETE FROM %s WHERE %s;", tbl_ref, where)
  } else {
    action <- sprintf("UPDATE %s -> NULL", col)
    sql    <- sprintf("UPDATE %s SET %s = NULL WHERE %s;", tbl_ref, qi(col), where)
  }
  plans[[length(plans) + 1]] <- list(tbl = tbl, rid = rid, action = action, sql = sql)
}

if (length(plans) == 0) { cat(sprintf("\nAucune action (ignorés : %d).\n", skipped)); quit(save = "no") }

cat("Actions prévues :\n")
for (p in plans) cat(sprintf("  [%s]  %s#%s\n      %s\n", p$action, p$tbl, p$rid, p$sql))
cat("\n")

## ---- Exécution --------------------------------------------------------------
if (!APPLY) {
  cat("DRY-RUN : rien n'a été modifié.\n")
  cat("Pour exécuter : relancer avec APPLY=1 (idéalement après une sauvegarde).\n")
  quit(save = "no")
}

dbBegin(con)
ok <- TRUE
done <- 0L
tryCatch({
  for (p in plans) {
    n <- dbExecute(con, p$sql)
    if (n == 1L) {
      cat(sprintf("  OK     %s#%s (%s)\n", p$tbl, p$rid, p$action)); done <- done + 1L
    } else if (n == 0L) {
      cat(sprintf("  0 ligne %s#%s : la clé/URL ne correspond plus, ignoré.\n", p$tbl, p$rid))
    } else {
      stop(sprintf("ANORMAL : %d lignes touchées pour %s#%s -> ROLLBACK.", n, p$tbl, p$rid))
    }
  }
}, error = function(e) { ok <<- FALSE; cat("\nERREUR : ", conditionMessage(e), "\n") })

if (ok) {
  dbCommit(con)
  cat(sprintf("\nTerminé. Références nettoyées : %d | ignorées : %d.\n", done, skipped))
} else {
  dbRollback(con)
  cat("\nAucune modification appliquée (transaction annulée).\n")
}
