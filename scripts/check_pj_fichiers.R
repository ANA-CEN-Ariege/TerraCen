#!/usr/bin/env Rscript
# =============================================================================
# check_pj_fichiers.R
#
# Audit de cohérence entre les fichiers PJ stockés sur le disque (dossier Docs/)
# et les références enregistrées en base (schéma gestcons).
#
# Produit DEUX listes (avec le SITE concerné) :
#   1. Fichiers ORPHELINS  : présents sur le disque mais référencés par AUCUNE
#                            ligne de la base (candidats à la suppression).
#                            Site déduit du nom de dossier (animation_/contrat_).
#   2. Références CASSÉES   : lignes de la base pointant vers un fichier
#                            ABSENT du disque (lien "🔗 ouvrir" mort).
#                            Site résolu par jointure depuis la base.
#
# Le script est en LECTURE SEULE : il ne supprime ni ne modifie rien.
#
# À EXÉCUTER SUR LE SERVEUR (accès simultané à la base ET au dossier Docs/),
# depuis le répertoire de l'appli (ou en fixant DOCS_ROOT), avec les mêmes
# variables d'environnement que TerraCen :
#     DB_HOST / DB_NAME / DB_USER / DB_PASSWORD  (DB_PORT optionnel, défaut 5432)
#     DOCS_ROOT  : chemin du dossier Docs/  (défaut : <cwd>/Docs)
#     OUT_DIR    : dossier de sortie des CSV (défaut : répertoire courant)
#
# Exemple :
#     cd /srv/shiny-server/TerraCEN
#     DOCS_ROOT=/srv/shiny-server/TerraCEN/Docs Rscript scripts/check_pj_fichiers.R
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(RPostgres)
})

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

## ---- Paramètres -------------------------------------------------------------
DOCS_ROOT <- normalizePath(Sys.getenv("DOCS_ROOT", file.path(getwd(), "Docs")),
                           mustWork = FALSE)
OUT_DIR   <- Sys.getenv("OUT_DIR", ".")
SCHEMA    <- "gestcons"

if (!dir.exists(DOCS_ROOT)) {
  stop("Dossier Docs introuvable : ", DOCS_ROOT,
       "\n(définir DOCS_ROOT ou lancer depuis le répertoire de l'appli)")
}
message("Dossier Docs analysé : ", DOCS_ROOT)

## ---- Connexion (mêmes variables d'env que TerraCen) -------------------------
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
message("Connecté à ", Sys.getenv("DB_NAME"), "@", Sys.getenv("DB_HOST"), "\n")

## ---- Résolution du site concerné --------------------------------------------
## Pour chaque table de PJ, chemin de jointure vers gestcons.sites (libellé).
## Les animations/contrats passent par une table de jonction parcelles
## (une PJ peut concerner plusieurs parcelles -> plusieurs sites possibles).
SITE_JOINS <- list(
  docs_animation_fonciere    = list(j = "gestcons.animation_fonciere_parcelles",        jfk = "animation_id",    tfk = "animation_id",    via_parc = TRUE),
  docs_animation_agricole    = list(j = "gestcons.animation_contrat_agricole_parcelles", jfk = "animation_id",    tfk = "animation_id",    via_parc = TRUE),
  docs_contrat_foncier       = list(j = "gestcons.contrats_foncier_parcelles",           jfk = "contrat_id",      tfk = "contrat_id",      via_parc = TRUE),
  docs_contrat_agricole      = list(j = "gestcons.contrats_agricoles_parcelles",         jfk = "contrat_agri_id", tfk = "contrat_id",      via_parc = TRUE),
  doc_gestion                = list(j = "gestcons.docs_gestion_sites",                    jfk = "doc_gestion_id",  tfk = "id",              via_parc = FALSE),
  doc_evaluation_doc_gestion = list(j = "gestcons.docs_gestion_sites",                    jfk = "doc_gestion_id",  tfk = "doc_gestion_id",  via_parc = FALSE)
)

## Sous-requête scalaire (corrélée à l'alias `t`) renvoyant les sites d'une ligne.
site_subquery_for <- function(tbl) {
  sp <- SITE_JOINS[[tbl]]
  if (is.null(sp)) return("NULL::text")
  if (sp$via_parc) {
    sprintf("(SELECT string_agg(DISTINCT s.libelle, ', ' ORDER BY s.libelle)
              FROM %s j
              JOIN gestcons.parcelles p ON p.id = j.parcelle_id
              JOIN gestcons.sites s ON s.id = p.site_id
              WHERE j.%s = t.%s)", sp$j, sp$jfk, sp$tfk)
  } else {
    sprintf("(SELECT string_agg(DISTINCT s.libelle, ', ' ORDER BY s.libelle)
              FROM %s j
              JOIN gestcons.sites s ON s.id = j.site_id
              WHERE j.%s = t.%s)", sp$j, sp$jfk, sp$tfk)
  }
}

## Pour les fichiers ORPHELINS : site déduit du dossier (préfixe -> jonction).
FOLDER_JOINS <- list(
  "animation_F" = list(j = "gestcons.animation_fonciere_parcelles",         jfk = "animation_id"),
  "animation_A" = list(j = "gestcons.animation_contrat_agricole_parcelles", jfk = "animation_id"),
  "contrat_F"   = list(j = "gestcons.contrats_foncier_parcelles",           jfk = "contrat_id"),
  "contrat_A"   = list(j = "gestcons.contrats_agricoles_parcelles",         jfk = "contrat_agri_id")
)

orphan_site_lookup <- function(rel_paths) {
  out  <- rep(NA_character_, length(rel_paths))
  seg1 <- sub("/.*$", "", rel_paths)                       # 1er segment = dossier
  m    <- regmatches(seg1, regexec("^(animation|contrat)_(F|A)_([0-9]+)$", seg1))
  key  <- vapply(m, function(g) if (length(g) == 4) paste(g[2], g[3], sep = "_") else NA_character_, character(1))
  id   <- vapply(m, function(g) if (length(g) == 4) g[4] else NA_character_, character(1))
  for (kk in unique(key[!is.na(key)])) {
    sp  <- FOLDER_JOINS[[kk]]; if (is.null(sp)) next
    idx <- which(key == kk)
    ids <- unique(id[idx]); ids <- ids[!is.na(ids)]
    if (!length(ids)) next
    q <- sprintf("SELECT j.%s::text AS eid,
                         string_agg(DISTINCT s.libelle, ', ' ORDER BY s.libelle) AS site
                  FROM %s j
                  JOIN gestcons.parcelles p ON p.id = j.parcelle_id
                  JOIN gestcons.sites s ON s.id = p.site_id
                  WHERE j.%s IN (%s) GROUP BY j.%s",
                 sp$jfk, sp$j, sp$jfk, paste(ids, collapse = ","), sp$jfk)
    d   <- dbGetQuery(con, q)
    map <- setNames(d$site, d$eid)
    out[idx] <- unname(map[id[idx]])
  }
  out
}

## ---- 1. Découverte des colonnes d'URL du schéma -----------------------------
## Toute colonne texte nommée `url` ou `url_...` dans le schéma gestcons.
url_cols <- dbGetQuery(con, sprintf("
  SELECT table_name, column_name
  FROM information_schema.columns
  WHERE table_schema = '%s'
    AND data_type IN ('character varying', 'text', 'character')
    AND (column_name = 'url' OR column_name LIKE 'url\\_%%' ESCAPE '\\')
  ORDER BY table_name, column_name;", SCHEMA))

if (nrow(url_cols) == 0) stop("Aucune colonne d'URL trouvée dans le schéma ", SCHEMA)

## Colonnes existantes par table (pour choisir un identifiant de ligne lisible)
all_cols <- dbGetQuery(con, sprintf("
  SELECT table_name, column_name
  FROM information_schema.columns
  WHERE table_schema = '%s';", SCHEMA))
cols_by_table <- split(all_cols$column_name, all_cols$table_name)

id_expr_for <- function(tbl) {
  cs <- cols_by_table[[tbl]] %||% character(0)
  if ("id" %in% cs) return("t.id::text")
  fk <- cs[grepl("_id$", cs)]
  if (length(fk)) return(paste0("t.", fk[1], "::text"))
  "NULL::text"
}

message("Colonnes d'URL scannées :")
for (i in seq_len(nrow(url_cols))) {
  tbl <- url_cols$table_name[i]
  flag <- if (is.null(SITE_JOINS[[tbl]])) "  (site : non résolu)" else ""
  message("  - ", SCHEMA, ".", tbl, ".", url_cols$column_name[i], flag)
}
message("")

## ---- 2. Collecte des références de fichiers en base -------------------------
## On ne garde que les valeurs pointant vers le dépôt local ("docs/...").
norm_rel <- function(u) {
  u <- gsub("\\\\", "/", u)          # antislashs éventuels -> /
  sub("^/?docs/", "", u)             # retire le préfixe docs/ (ou /docs/)
}

refs <- do.call(rbind, lapply(seq_len(nrow(url_cols)), function(i) {
  tbl <- url_cols$table_name[i]
  col <- url_cols$column_name[i]
  q <- sprintf('SELECT %s AS row_id, %s AS site, t."%s" AS url
                FROM %s."%s" t
                WHERE t."%s" LIKE %s OR t."%s" LIKE %s',
               id_expr_for(tbl), site_subquery_for(tbl), col,
               SCHEMA, tbl,
               col, dbQuoteLiteral(con, "docs/%"),
               col, dbQuoteLiteral(con, "/docs/%"))
  d <- dbGetQuery(con, q)
  if (nrow(d) == 0) return(NULL)
  data.frame(table = tbl, column = col, row_id = d$row_id, site = d$site,
             url = d$url, stringsAsFactors = FALSE)
}))

if (is.null(refs)) refs <- data.frame(table = character(), column = character(),
                                      row_id = character(), site = character(),
                                      url = character(), stringsAsFactors = FALSE)

refs$rel_path  <- norm_rel(refs$url)
refs$full_path <- file.path(DOCS_ROOT, refs$rel_path)
refs$existe    <- file.exists(refs$full_path)

referenced <- unique(refs$rel_path)          # ensemble des fichiers attendus

## ---- 3. Scan du disque ------------------------------------------------------
disk <- list.files(DOCS_ROOT, recursive = TRUE, all.files = FALSE, no.. = TRUE)
disk <- gsub("\\\\", "/", disk)              # chemins relatifs à DOCS_ROOT

## ---- 4. Croisement ----------------------------------------------------------
# a) Fichiers orphelins : sur le disque mais dans aucune ligne de la base
orphans_rel <- setdiff(disk, referenced)
orphans <- data.frame(fichier = orphans_rel, stringsAsFactors = FALSE)
if (nrow(orphans)) {
  orphans$site <- orphan_site_lookup(orphans$fichier)
  fp <- file.path(DOCS_ROOT, orphans$fichier)
  info <- file.info(fp)
  orphans$taille_octets     <- info$size
  orphans$date_modification <- format(info$mtime, "%Y-%m-%d %H:%M:%S")
} else {
  orphans$site <- character(0)
  orphans$taille_octets <- numeric(0)
  orphans$date_modification <- character(0)
}

# b) Références cassées : en base mais fichier absent du disque
broken <- refs[!refs$existe, c("table", "column", "row_id", "site", "url", "full_path")]

## ---- 5. Rapports ------------------------------------------------------------
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)
f_orphans <- file.path(OUT_DIR, "pj_fichiers_orphelins.csv")
f_broken  <- file.path(OUT_DIR, "pj_references_cassees.csv")
write.csv(orphans, f_orphans, row.names = FALSE, fileEncoding = "UTF-8")
write.csv(broken,  f_broken,  row.names = FALSE, fileEncoding = "UTF-8")

cat("\n=======================================================================\n")
cat(sprintf("Fichiers sur le disque .............. %d\n", length(disk)))
cat(sprintf("Références de fichiers en base ...... %d (fichiers distincts : %d)\n",
            nrow(refs), length(referenced)))
cat("-----------------------------------------------------------------------\n")
cat(sprintf("ORPHELINS  (disque, non référencés) . %d   -> %s\n", nrow(orphans), f_orphans))
cat(sprintf("CASSÉES    (base -> fichier absent) . %d   -> %s\n", nrow(broken),  f_broken))
cat("=======================================================================\n\n")

show_head <- function(df, n = 20L, cols = names(df)) {
  if (nrow(df) == 0) { cat("  (aucun)\n\n"); return(invisible()) }
  print(utils::head(df[, cols, drop = FALSE], n), row.names = FALSE)
  if (nrow(df) > n) cat(sprintf("  ... et %d de plus (voir le CSV)\n", nrow(df) - n))
  cat("\n")
}

cat(">> Fichiers ORPHELINS (extrait) :\n")
show_head(orphans, cols = c("fichier", "site", "taille_octets", "date_modification"))

cat(">> Références CASSÉES (extrait) :\n")
show_head(broken, cols = c("table", "column", "row_id", "site", "url"))
