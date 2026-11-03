#!/usr/bin/env Rscript
# Markdown -> PDF, sans pandoc ni LaTeX.
#
# Le poste de développement n'a ni pandoc ni distribution TeX, et le serveur a
# une installation LaTeX fragile (cf. les gabarits de rapport). On passe donc
# par commonmark, qui est déjà dans le lockfile, puis par l'impression de
# Chrome en mode sans interface — présent sur le poste.
#
#   Rscript scripts/doc_to_pdf.R FICHIER.md [SORTIE.pdf]

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) stop("usage : doc_to_pdf.R FICHIER.md [SORTIE.pdf]")
src <- args[1]
out <- if (length(args) >= 2) args[2] else sub("[.]md$", ".pdf", src)
if (!file.exists(src)) stop("fichier introuvable : ", src)

md   <- paste(readLines(src, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
# Le premier titre de niveau 1 devient le titre du document.
titre <- sub("^#\\s+", "", grep("^#\\s+", strsplit(md, "\n")[[1]], value = TRUE)[1])
if (is.na(titre)) titre <- basename(src)

corps <- commonmark::markdown_html(md, extensions = TRUE, smart = TRUE)

css <- '
@page { size: A4; margin: 18mm 16mm 20mm 16mm; }
body { font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;
       font-size: 10.5pt; line-height: 1.45; color: #1f2937; }
h1 { font-size: 20pt; margin: 0 0 4pt; color: #0b5ed7; }
h2 { font-size: 14pt; margin: 20pt 0 6pt; padding-bottom: 3pt;
     border-bottom: 1.5px solid #0b5ed7; color: #0b5ed7;
     break-after: avoid; page-break-after: avoid; }
h3 { font-size: 11.5pt; margin: 13pt 0 4pt; color: #374151;
     break-after: avoid; page-break-after: avoid; }
p, ul, ol, table { break-inside: avoid-page; }
table { border-collapse: collapse; width: 100%; margin: 7pt 0; font-size: 9.5pt; }
th { background: #eef2ff; text-align: left; }
th, td { border: 1px solid #c7d2fe; padding: 3.5pt 6pt; vertical-align: top; }
blockquote { margin: 8pt 0; padding: 5pt 10pt; border-left: 3px solid #f59e0b;
             background: #fffbeb; font-size: 10pt; }
blockquote p { margin: 0 0 4pt; }
blockquote p:last-child { margin-bottom: 0; }
code { font-family: "SF Mono", Menlo, monospace; font-size: 9pt;
       background: #f3f4f6; padding: 1pt 3pt; border-radius: 2px; }
hr { border: 0; border-top: 1px solid #e5e7eb; margin: 16pt 0; }
li { margin: 2pt 0; }
.pied { margin-top: 4pt; color: #6b7280; font-size: 9pt; }
'

html <- sprintf(
  '<!doctype html><html lang="fr"><head><meta charset="utf-8">
<title>%s</title><style>%s</style></head><body>%s
<p class="pied">TerraCen v%s — document généré le %s depuis %s</p>
</body></html>',
  titre, css, corps,
  trimws(readLines("VERSION", n = 1, warn = FALSE)),
  format(Sys.Date(), "%d/%m/%Y"), basename(src))

tmp <- tempfile(fileext = ".html")
writeLines(html, tmp, useBytes = TRUE)

chrome <- "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if (!file.exists(chrome)) stop("Chrome introuvable : ", chrome)

profil <- tempfile("chrome-pdf-")
ok <- system2(chrome, c("--headless", "--disable-gpu", "--no-pdf-header-footer",
                        paste0("--user-data-dir=", shQuote(profil)),
                        paste0("--print-to-pdf=", shQuote(normalizePath(out, mustWork = FALSE))),
                        shQuote(paste0("file://", tmp))),
              stdout = FALSE, stderr = FALSE)
unlink(profil, recursive = TRUE, force = TRUE)

if (!file.exists(out)) stop("Chrome n'a pas produit de PDF (code ", ok, ")")
cat(sprintf("%s — %.0f ko\n", out, file.size(out) / 1024))
