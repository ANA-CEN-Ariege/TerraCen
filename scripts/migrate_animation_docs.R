# ============================================================================
# migrate_animation_docs.R — Migration des PJ d'animations vers des dossiers
# typés : animation_<id>  ->  animation_F_<id> / animation_A_<id>
# ----------------------------------------------------------------------------
# Pourquoi : foncier et agricole ont des séquences d'id indépendantes ; le
# dossier partagé animation_<id> mélangeait les PJ de deux actions différentes
# (foncière n°5 ET agricole n°5). Depuis le correctif applicatif, les nouveaux
# uploads vont dans animation_F_/A_ ; ce script migre l'existant : déplace
# chaque fichier référencé et met à jour son url en base.
#
# Exécution — SUR LE SERVEUR, depuis le dossier de l'appli qui héberge les
# fichiers (le dossier Docs/) :
#   sudo -u shiny LANG=C.utf8 LC_ALL=C.utf8 Rscript scripts/migrate_animation_docs.R
#
# ⚠️ La base étant PARTAGÉE entre Test et prod, lancer le script UNE SEULE
#    fois, depuis l'instance dont le Docs/ contient réellement les fichiers
#    (vérifier si Docs/ est un lien symbolique partagé entre les instances).
# ⚠️ Idempotent : les urls déjà en animation_F_/A_ sont ignorées ; fichiers
#    introuvables listés (à recouper avec scripts/check_missing_docs.R),
#    leur url n'est PAS modifiée.
# ============================================================================

library(DBI)

con <- DBI::dbConnect(
  RPostgres::Postgres(),
  dbname   = Sys.getenv("DB_NAME"),
  host     = Sys.getenv("DB_HOST"),
  port     = 5432,
  user     = Sys.getenv("DB_USER"),
  password = Sys.getenv("DB_PASSWORD"),
  sslmode  = "require"
)

docs_root <- normalizePath(file.path(getwd(), "Docs"), mustWork = TRUE)
cat("docs_root :", docs_root, "\n\n")

migrate_table <- function(table, kind) {
  df <- DBI::dbGetQuery(con, sprintf(
    "SELECT id, animation_id, url FROM %s WHERE url IS NOT NULL", table))

  # Ancien schéma uniquement : docs/animation_<chiffres>/...
  old <- df[grepl("^\\.?/?docs/animation_[0-9]+/", df$url), , drop = FALSE]
  cat(sprintf("%s : %d document(s) a migrer\n", table, nrow(old)))

  n_ok <- 0L; n_manquant <- 0L; n_echec <- 0L
  for (i in seq_len(nrow(old))) {
    rel_old <- sub("^\\.?/?docs/", "", old$url[i])
    rel_new <- sub("^animation_", sprintf("animation_%s_", kind), rel_old)
    abs_old <- file.path(docs_root, rel_old)
    abs_new <- file.path(docs_root, rel_new)

    if (!file.exists(abs_old)) {
      cat(sprintf("  [manquant] id=%s : %s\n", old$id[i], abs_old))
      n_manquant <- n_manquant + 1L
      next
    }
    dir.create(dirname(abs_new), recursive = TRUE, showWarnings = FALSE)
    if (!file.rename(abs_old, abs_new)) {
      cat(sprintf("  [echec mv] id=%s : %s\n", old$id[i], abs_old))
      n_echec <- n_echec + 1L
      next
    }
    DBI::dbExecute(con,
                   sprintf("UPDATE %s SET url = $1 WHERE id = $2", table),
                   params = list(paste0("docs/", rel_new), old$id[i]))
    n_ok <- n_ok + 1L
  }
  cat(sprintf("  -> %d deplace(s), %d manquant(s), %d echec(s)\n\n",
              n_ok, n_manquant, n_echec))
}

migrate_table("gestcons.docs_animation_fonciere", "F")
migrate_table("gestcons.docs_animation_agricole", "A")

# Nettoyage : supprime les anciens dossiers animation_<id> devenus vides.
# Un dossier non vide est conservé (fichiers non référencés en base ->
# à recouper avec scripts/check_orphan_files.R).
old_dirs <- list.dirs(docs_root, recursive = FALSE)
old_dirs <- old_dirs[grepl("/animation_[0-9]+$", old_dirs)]
for (d in old_dirs) {
  if (length(list.files(d, all.files = TRUE, no.. = TRUE)) == 0) {
    unlink(d, recursive = TRUE)
    cat("dossier vide supprime :", d, "\n")
  } else {
    cat("dossier NON VIDE conserve (orphelins ?) :", d, "\n")
  }
}

DBI::dbDisconnect(con)
cat("\nMigration terminee.\n")
