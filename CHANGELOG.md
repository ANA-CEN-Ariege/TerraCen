# Changelog

Toutes les modifications notables sont consignées ici.

Le format est inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/),
et le projet adhère à un schéma [SemVer light](CONTRIBUTING.md#versioning-et-releases) (`MAJEUR.MINEUR[.PATCH]`).

## [3.11] — 2026-10-30

Les sites disent s'ils sont accessibles au public, et aux personnes à
mobilité réduite.

**Une migration, déjà passée en base** : `migration_accessibilite_sites.sql`,
dans `scripts/`. La base étant partagée par la prod et le test, elle vaut
déjà pour les deux. Aucune contrainte existante n'est modifiée.

### Ajouté
- **L'accessibilité d'un site.** Le formulaire d'un site porte deux champs :
  « Accessible au public », Oui, Non ou Partielle, et « Accessible aux
  PMR ? ». La case PMR disparaît quand le site n'est pas accessible au
  public ; il est alors enregistré comme non accessible aux PMR, même si la
  case avait été cochée avant. Par défaut, un site est accessible au public
  et ne l'est pas aux PMR : c'est la valeur de départ des 63 sites et des
  113 secteurs existants, comme de tout nouveau site. Les deux champs servent
  aussi à la promotion d'un secteur en site, qui partage le même formulaire.
  Ils ne s'affichent pas encore dans le résumé du site, et ni Analyses, ni
  MapCen, ni l'export FCEN ne les lisent.

### Technique
- **En base** : un dictionnaire `gestcons.dico_accessibilite` (0 Non, 1 Oui,
  2 Partielle, numérotés comme `dico_binaire`), et deux colonnes NOT NULL sur
  `gestcons.sites` : `accessibilite_site`, Oui par défaut, et
  `accessibilite_pmr_site`, 0 ou 1, à 0 par défaut, sur le modèle de
  `terrain_militaire_id` et `site_marin_id`.
- **Le dictionnaire est passé aux modules Sites et Stratégie foncière par son
  nom, en dernier paramètre** : `app.R` passe les précédents par position, et
  un paramètre inséré au milieu les aurait tous décalés.

## [3.10] — 2026-10-30

### Modifié
- **Opus et Fable réservés aux administrateurs dans Analyses.** Le sélecteur
  de modèle ne les propose plus qu'aux administrateurs ; un responsable de
  site garde Haiku, le modèle par défaut, et Sonnet. Ce sont les deux
  modèles les plus chers : 4 et 10 $ le million de jetons d'entrée, contre
  0,10 pour Haiku. La règle est rejouée à l'envoi de la question : un modèle
  réservé, demandé par un autre profil, retombe sur Haiku, comme un modèle
  inconnu.

## [3.9] — 2026-10-30

Analyses voit plus loin : l'animation foncière, les documents de gestion,
les communes de l'Ariège et les zonages réglementaires entrent dans le champ
des questions. Et dans une conversation, la dernière réponse s'affiche
désormais en tête.

**Quatre migrations, déjà passées en base** :
`migration_analyses_animations.sql`, `migration_analyses_documents_gestion.sql`,
`migration_analyses_communes_ariege.sql` et `migration_analyses_zonages.sql`,
dans `scripts/`. La base étant partagée par la prod et le test, elles valent
déjà pour les deux. Aucune contrainte existante n'est modifiée.

### Ajouté
- **L'animation foncière dans Analyses.** `v_analyses_animations` donne une
  ligne par démarche — 123, de février 2013 à octobre 2026 — avec sa date, son
  type, les salariés qui l'ont menée, ses parcelles, ses sites, et le nombre
  de propriétaires et d'exploitants contactés. `v_analyses_animations_parcelles`
  la détaille parcelle par parcelle — 644 couples, 389 parcelles, 19 sites —,
  en disant si la parcelle est dans un site, dans sa continuité ou dans un
  secteur. Les personnes contactées ne sont jamais nommées, seulement
  comptées. La description des démarches n'est pas exposée : 2 000 caractères
  en moyenne, des courriels collés, et les noms des personnes contactées.
- **Les documents de gestion dans Analyses.** `v_analyses_documents_gestion`
  donne une ligne par document et par site — 15 documents, 17 sites — et dit
  s'il est **en vigueur à la date du jour**. Le statut ne suffit pas : deux
  documents « Actif » sont échus. Quatre autres, « Actif » mais sans date de
  fin, ont une validité **inconnue**, laissée vide plutôt que comptée en
  vigueur ; parmi eux « PDG 2017-2022 » et « Plan de gestion 2018-2022 »,
  dont la saisie est à compléter. Mesuré : 48 des 57 sites n'ont aucun
  document en vigueur, dont 6 un document de validité inconnue.
- **Les communes de l'Ariège dans Analyses.** `v_analyses_communes` : les 327
  communes — 153 287 habitants, 8 intercommunalités, 3 arrondissements — avec
  leur population, leur surface, leur intercommunalité et leur
  arrondissement. De quoi rapporter des sites ou des hectares à une population
  ou à un territoire, ou trouver les communes sans aucun site.
- **Les zonages réglementaires dans Analyses.** Le croisement des parcelles
  avec les 92 zonages — Natura 2000 (ZSC, ZPS), ZNIEFF de type 1 et 2, APPB,
  RNR, RNCFS — est calculé d'avance, en 5 secondes environ. Il est refait
  avant une question si des parcelles ont changé depuis, ou s'il date de plus
  d'une semaine ; la question attend alors ces quelques secondes.
  `v_analyses_zonages` dit quels zonages touchent quelle parcelle — 14 754
  couples, 6 029 parcelles. `v_analyses_surfaces_zonees` dit combien, par
  parcelle, **sans double compte** : les zonages d'une même famille se
  recouvrent, et les additionner donnerait 5 501 ha de Natura 2000 au lieu
  des 3 620 réels, 15 741 ha de ZNIEFF au lieu de 8 193. Les parcelles des
  sites couvrent 4 301 ha, dont 1 872 en Natura 2000 et 3 968 en ZNIEFF ;
  92,3 % de leur surface est dans au moins un zonage.

### Modifié
- **La dernière réponse en premier.** Le fil d'une conversation d'Analyses
  s'affiche du plus récent au plus ancien : la réponse qu'on vient d'obtenir
  est en haut, sans avoir à descendre la chercher. « Interrogation en cours… »
  passe en tête, là où la réponse va s'afficher ; le coût total reste en pied.
- **Analyses sait qui a mené l'animation foncière.** La consigne « il n'y a
  pas d'acteurs » devient : les salariés d'une démarche sont nommés, les
  personnes contactées seulement comptées.

### Technique
- **La description de la base envoyée avec chaque question passe de 8 à 14
  vues**, soit 18 600 caractères environ. Elle est mise en cache, et pèse
  donc peu sur le coût.
- **Les issues et les PR du dépôt sont annoncées dans le salon Matrix
  « github »** de l'espace ANA-CEN Numérique (PR #28). Sans le jeton du bot,
  secret du dépôt, rien n'est envoyé.

## [3.8] — 2026-10-29

Les parcelles d'un secteur se modifient désormais par lot, et les fiches
qui affichaient « NA » pour un champ vide — puis l'enregistraient — sont
corrigées, leurs données avec.

**Données corrigées en base, déjà faites** : les 10 remarques de parcelles
et les 6 commentaires de documents qui valaient « NA » sont redevenus vides.
La base étant partagée, la correction vaut pour la prod comme pour le test ;
mais la prod, tant qu'elle reste en v3.5, peut en écrire de nouveaux.

### Ajouté
- **Stratégie foncière : modifier plusieurs parcelles du secteur d'un
  coup.** Le bouton « ✏️ Modifier » du pied de carte n'apparaissait que
  pour une seule parcelle sélectionnée. Il reste affiché pour plusieurs —
  sélectionnées au clic, ou au rectangle en maintenant Maj ⇧ — et en donne
  le nombre. Une parcelle ouvre sa fiche, comme avant ; plusieurs ouvrent
  une modale d'édition par lot, priorité et remarque. Comme dans l'édition
  en masse de l'onglet Sites, chaque champ part sur « — ne pas modifier — »
  et seuls ceux qu'on renseigne sont écrits. Une remarque saisie remplace
  celle de chaque parcelle du lot, et la modale dit combien en ont déjà
  une. Les périmètres tracés sont compris. Seule limite : on ne peut pas
  effacer les remarques par lot, un champ vide voulant dire « ne pas
  modifier ». L'aide de l'onglet le mentionne.

### Corrigé
- **Une remarque de parcelle absente ne s'affiche plus « NA », et ne
  s'enregistre plus.** Les fiches d'une parcelle de secteur (Stratégie) et
  d'une parcelle de continuité (Sites) affichaient « NA » dans la remarque
  d'une parcelle qui n'en avait pas, et le premier enregistrement — pour
  changer la priorité, typiquement — l'écrivait en base. 10 parcelles en
  portaient, écrites du 15 au 28 octobre, depuis l'arrivée de ces deux
  fiches ; elles sont remises à vide. Cause : `%||%` ne teste que `NULL`,
  et un champ vide arrive de la base en `NA` — le défaut déjà corrigé dans
  Contrats le 26 octobre.
- **Documents de gestion : le même défaut.** Le formulaire de modification
  affichait « NA » dans le commentaire d'un document qui n'en avait pas, et
  l'enregistrement l'écrivait : 6 des 15 documents en portaient, écrits du
  30 juin au 3 septembre ; ils sont remis à vide. La fiche d'un document
  affichait aussi « NA » au lieu de « Aucun commentaire. » (8 documents) et,
  pour la surface, au lieu de « — » (6).

## [3.7.1] — 2026-10-28

Version corrective : la suppression d'une action ne peut plus rester à
moitié faite, Analyses trouve les communes de tous les secteurs, et la base
comme ses scripts d'exploitation sont remis d'aplomb après l'audit du jour.

**Deux migrations, déjà passées en base** :
`migration_analyses_secteurs_communes.sql` et
`migration_proprietaires_adminsig.sql`, dans `scripts/`. La base étant
partagée par la prod et le test, elles valent déjà pour les deux.

### Corrigé
- **Supprimer une action ne peut plus la laisser à moitié supprimée.** Les
  trois suppressions partaient chacune de leur côté, après l'effacement des
  fichiers joints, et une erreur en route était avalée sous un toast de
  succès : l'action pouvait rester en base, ses documents déjà perdus. Tout
  passe désormais par une seule transaction — documents, parcelles, acteurs,
  utilisateurs, puis l'action —, et les fichiers ne sont effacés qu'une fois
  la suppression validée. Un échec annule tout et le dit ; la liste est
  rafraîchie dans les deux cas. Aucun cas n'avait été constaté : c'était une
  fragilité, pas une panne.
- **Analyses trouve les communes de tous les secteurs.**
  `v_analyses_secteurs` ne lisait que le cadastre : 31 des 77 secteurs qui
  ont des parcelles, faits de périmètres tracés, n'y avaient aucune commune,
  et une question comme « quels secteurs sur Seix ? » les manquait. Les noms
  sont désormais ceux de la couche IGN (Léran plutôt que LERAN), d'où une
  liste qui se cherche d'un seul ILIKE. Comptes, surfaces et priorités sont
  inchangés pour les 113 secteurs.
- **Deux parcelles étaient à la fois dans un site et dans un secteur** : la
  continuité du site 169 et le secteur 182, où elles avaient été rattachées
  quand il était encore un site. Retirées du secteur, en base ; seule leur
  priorité 1 est perdue.

### Technique
- **Tous les objets de `gestcons` appartiennent à `adminsig`.** Huit
  relations — dont les journaux d'audit et de connexion, et les vues de
  MapCen — et deux fonctions de déclencheur étaient encore à `claudeg`. Rien
  ne change au fonctionnement. Seul le propriétaire d'un objet pouvant le
  remplacer, une migration passée sous un autre compte n'aurait pas pu les
  reprendre.
- **`parcelles_perimetre_old` n'attend plus que MapCen.** Cette copie
  périmée de la fusion d'août est encore lue par `v_mapcen_parcelles`, qui
  publie ainsi 41 parcelles de continuité que TerraCEN n'a plus. Le script de
  propriété la supprime dès que plus aucune vue ne la lit : il suffira de le
  rejouer.
- **`scripts/delete_site.sql` est restauré**, après avoir été écrasé une
  seconde fois par un script de contrats enregistré sous son nom. Il signale
  désormais les contrats et les actions qui se retrouveraient sans aucune
  parcelle — c'est ainsi que se sont accumulés les contrats vides relevés
  cette semaine —, et ne cassera pas le jour où `parcelles_perimetre_old`
  disparaîtra.

## [3.7] — 2026-10-28

Cette version donne leur place aux périmètres tracés à la main — dans les
secteurs, sur la carte, dans les communes — et corrige les quatre constats
moyens de l'audit du jour (`scripts/audit_2026-10-28.md`).

**Trois migrations, déjà passées en base** : `migration_parcelles_communes.sql`,
puis `migration_analyses_communes_multiples.sql` et
`migration_analyses_tout_voir.sql`, dans `scripts/`. La base étant partagée
par la prod et le test, elles valent déjà pour les deux. Aucune contrainte
existante n'est modifiée.

### Ajouté
- **Les périmètres manuels sont rattachés à toutes leurs communes.** Une
  parcelle cadastrale tient sa commune de sa référence ; un périmètre tracé
  n'a qu'une forme. Les 41 de la base — 1 594 ha, plus que cinq des huit EPCI
  réunis — échappaient donc à tout regroupement territorial.
  `gestcons.parcelles_communes` porte désormais une ligne par couple
  (parcelle, commune) avec la surface dans chacune : 49 couples, 34 communes,
  6 parcelles à cheval sur deux ou trois communes. Tenue à jour par deux
  déclencheurs, l'application écrivant la géométrie avant la parcelle.
  Les 3 géométries qui se recoupaient sont réparées, à surface inchangée.
  Dans Analyses, `v_analyses_parcelles` garde une ligne par parcelle et gagne
  `communes` et `nb_communes` ; la nouvelle `v_analyses_parcelles_communes`
  répartit la surface au prorata, pour sommer des hectares par commune ou par
  EPCI — les deux vues donnent le même total, à 0 m² près. Les infobulles
  affichent toutes les communes : « Seix, Sentenac-d'Oust, Bethmale ».
- **Tracer un périmètre manuel dans un secteur.** L'outil polygone arrive sur
  la carte de Stratégie foncière, qui ne savait jusqu'ici que rattacher du
  cadastre. Tracer n'enregistre pas : un bloc à part du pied de carte propose
  d'ajouter les tracés au secteur, avec leur priorité. Un tracé dégénéré, de
  moins d'un mètre carré, est écarté.
- **Les limites communales sur les cartes de Sites et de Stratégie**, dans
  « Autour du site ». La couche IGN couvre toute la France — 34 955 communes,
  400 Mo — et se charge donc à l'emprise : 3 communes en 32 ms à l'échelle
  d'une parcelle, 665 en 520 ms sur le département entier. Le trait passe
  au-dessus du cadastre, sans intercepter le clic.
- **Les communes dans la fiche d'un secteur.** La liste est tronquée au-delà
  de quatre, l'intégralité restant au survol : un secteur en compte seize.
- **« Sensible ? » et « Non diffusable ? » dans le formulaire d'un site.**
  Cocher « Sensible ? » fait apparaître une remarque, enregistrée seulement si
  la case l'est, et effacée quand on la décoche. Les deux cases sont aussi
  proposées à la promotion d'un secteur, quand il devient site.
- **Le type de milieu des secteurs dans Analyses**, dans la même nomenclature
  que celui des sites : les 113 secteurs en ont un.

### Modifié
- **La carte de Stratégie a les mêmes familles de couches que celle de
  Sites** : Le secteur, Cadastre, Autour du site, Zones de protection. Le
  fourre-tout « Autres couches » disparaît ; il ne contenait que « Secteurs »,
  qu'aucun groupe ne déclarait.
- **Tracer un périmètre et sélectionner des parcelles s'excluent**, dans
  Sites comme dans Stratégie. Dans Sites, tracés et parcelles candidates
  s'enregistraient ensemble, sous un même contrat.
- **« Sensible ? » et « Non diffusable ? » quittent le formulaire d'un
  secteur**, au profit de celui d'un site.
- **Analyses voit tout.** C'est un outil interne : le filtre qui écartait les
  sites sensibles ou non diffusables est retiré. Il retirait aussi toutes
  leurs parcelles — mesuré, un seul site coché faisait disparaître 302
  parcelles des sommes, sans le moindre signe. Les deux indicateurs et la
  remarque sont désormais exposés. Les vues de MapCen gardent leur filtre.

### Corrigé
- **Les secteurs à géométrie manuelle s'affichent et se cadrent.** Les 31
  dont toutes les parcelles sont des périmètres tracés s'ouvraient vides, la
  carte restant sur l'Ariège : leur emprise était lue dans une vue qui exclut
  les parcelles de secteur, et leurs parcelles n'étaient cherchées que dans
  le cadastre. Deux défauts sont corrigés en chemin : retirer un périmètre
  manuel d'un secteur ne supprimait rien, et le contrôle d'avant promotion ne
  comparait pas la même chose que l'index qu'il protège.
- **La fiche d'une parcelle relit la bonne table des sources géométriques.**
  Elle interrogeait une table inexistante depuis la v2.2 : la liste
  « Source géométrique » sortait vide, et la source ne pouvait plus être
  modifiée. Aucune donnée abîmée.
- **Les tracés en attente ne s'effacent plus au rectangle de sélection.** Ils
  disparaissaient de l'écran tout en restant prêts à l'enregistrement ;
  l'affichage suit désormais l'état, au même style.

### Sécurité
- **Deux vecteurs d'injection SQL fermés.** `shQuote`, une quotation pour le
  shell, servait de quotation SQL à l'enregistrement d'une sélection de
  parcelles ; et l'emprise de la carte, envoyée par le navigateur, entrait
  telle quelle dans quatre requêtes. Les exploiter supposait un utilisateur
  authentifié forgeant ses messages, mais l'effet était du SQL arbitraire. Un
  audit précédent les avait manqués : il ne cherchait que les valeurs `input$`
  interpolées directement.
- **Le nom d'un site est échappé dans la modale « Promotion impossible »**,
  où il pouvait porter du code exécuté chez un autre utilisateur.

## [3.6] — 2026-10-28

### Modifié
- **Haiku devient le modèle par défaut des Analyses.** Décision de coût :
  0,10 $ le million de jetons d'entrée contre 4,00 pour Opus, quarante fois
  moins. Les 33 premières questions revenaient en moyenne à 6 centimes pour
  un utilisateur et à 24 pour l'autre, l'onglet venant de s'ouvrir aux
  responsables de site.
  Éprouvé **avant** de basculer : sur une question simple, 2 requêtes et
  moins d'un dixième de centime ; sur la question à trois critères — milieu,
  statut de contrat, intercommunalité — qui avait échoué en production,
  6 requêtes pour **0,4 centime**, là où Opus demandait 0,10 $.
  Le sélecteur reste : une question qui demande du raisonnement se repose sur
  un autre modèle en un clic.

### Ajouté
- **Une consigne définit ce qu'est une zone humide.** Opus et Haiku ne
  donnaient pas le même compte sur la même question — 4 sites et 55 parcelles
  contre 5 et 60. Vérifié en SQL : l'arithmétique des deux était exacte, ils
  ne retenaient simplement pas les mêmes milieux, la base n'ayant aucune
  valeur « zones humides ». La mémoire de l'onglet fixe désormais la lecture
  — « tourbières et marais », « écosystèmes aquatiques », « écosystèmes
  alluviaux » — et demande au modèle de **dire quels milieux il a retenus**,
  pour qu'on puisse le contredire.

## [3.5] — 2026-10-28

### Ajouté
- **Interroger et exporter par intercommunalité.** La base savait déjà à quel
  EPCI appartient chaque commune — `gestcons.communes` porte un `siren_epci`
  entièrement renseigné, 327 communes d'Ariège sur 327, 8 EPCI distincts —
  mais pas son **nom**. `gestcons.dico_epci` l'apporte, et `siren_epci` comme
  `epci` rejoignent les trois vues qui portaient déjà la commune.
  S'y ajoute un **quatrième grain d'export** : la couche des
  intercommunalités, par union des géométries communales — 8 entités à partir
  de 327 communes en 0,5 s.
  ⚠️ À savoir avant d'analyser par territoire : les **41 parcelles à
  géométrie manuelle pèsent 1 594 ha** — plus que cinq des huit EPCI — et
  n'appartiennent à aucune commune, donc à aucune intercommunalité.
- **Le motif d'un échec est conservé.** `analyses_questions` enregistrait
  qu'une question avait échoué, jamais pourquoi : une question restée sans
  réponse en production n'a pas pu être diagnostiquée depuis les traces, il a
  fallu la rejouer contre l'API. La colonne `message_erreur` garde désormais
  le texte même que l'onglet affiche.

### Modifié
- **Le plafond de la boucle d'outils passe de 6 à 10.** Mesuré sur les 32
  questions posées : les 30 abouties n'ont jamais dépassé **5 requêtes**, et
  les 2 échecs en ont consommé **7 et 8** — ils butaient donc sur le plafond,
  pas sur une impasse. Celui-ci ne sert qu'à arrêter un emballement, pas à
  rationner un cheminement légitime.

## [3.4.1] — 2026-10-28

### Corrigé
- **L'aide affirmait qu'un site a « au moins une parcelle associée et un
  contrat ».** C'est une vocation, pas un invariant : on crée couramment un
  site puis on lui affecte ses parcelles ensuite, et six sites actifs sont
  aujourd'hui dans ce cas. La formulation vaut mieux qu'une nuance — lue
  comme une contrainte, elle avait fait signaler ces six sites comme des
  anomalies lors de l'audit de cohérence. L'aide de Stratégie foncière garde
  son rôle, expliquer ce qu'un secteur n'est pas, en s'appuyant sur le
  **contrat** : c'est lui qui est absent d'un secteur par construction, là où
  la parcelle peut n'être qu'à venir des deux côtés.

## [3.4] — 2026-10-28

### Modifié
- **L'onglet Analyses s'ouvre aux responsables de site**, et non plus aux
  seuls administrateurs. Même règle que Contrats et Activité : être
  responsable d'un *secteur* d'intervention n'y donne pas accès.
  Les onze gardes du module ne protégeaient pas la même chose, et **seules
  quatre s'ouvrent** — poser une question, repartir d'une conversation
  vierge, exporter une couche, exporter un tableau. Les sept autres portent
  sur les **consignes** et restent aux administrateurs : une consigne est
  jointe à chaque question de chaque utilisateur, elle façonne les réponses
  de tout le monde.
- **La mémoire et le schéma des vues ne s'affichent plus qu'aux
  administrateurs.** L'avertissement qui les précède, lui, reste visible de
  tous : savoir que la question et les résultats partent vers l'API, et ce
  qu'ils contiennent, concerne quiconque pose une question. Ces masquages
  sont un confort d'interface, pas la sûreté — les gardes serveur tiennent
  indépendamment.

### Corrigé
- **La pastille des rôles plantait pour un responsable de secteur**
  (« Error in `[[` : indice hors limites »). Deux défauts se combinaient :
  `sites_list` est un **vecteur nommé**, où `v[["absent"]]` lève une erreur
  au lieu de rendre `NULL` — le garde-fou écrit pour une liste ne protégeait
  donc rien —, et la liste des sites filtre `type_site_id = 1`, si bien que
  depuis la bascule un responsable de secteur y cherchait un identifiant
  absent. La pastille **nomme** désormais le secteur plutôt que de se
  contenter de ne plus planter.

## [3.3] — 2026-10-28

Les premiers contrôles de cohérence de l'application, les secteurs sur la
carte de Stratégie foncière, et les rôles de site dans les Analyses.

### Ajouté
- **Contrôles de cohérence sur les contrats**, aux quatre points
  d'enregistrement — création et édition, foncier et agricole. Début
  postérieur à la fin, statut « Résilié » sans date de rupture, rupture hors
  de la période, et **durée en contradiction avec le type de maîtrise
  déclaré** (« contrats de gestion ≥ 18 ans » ou « < 18 ans »). Le message
  s'affiche **sous le champ fautif** et la modale reste ouverte.
  Jusqu'ici l'application n'avait aucune validation de champ : tout se jouait
  au refus d'enregistrement par un toast. Mesuré avant de poser quoi que ce
  soit : sur 176 contrats fonciers, 8 agricoles, 230 lignes de responsabilité
  et 6 698 parcelles, **33 lignes incohérentes**, toutes corrigées le même
  jour. Aucun de ces contrôles n'a donc de faux positif.
  Deux contrôles sont **volontairement absents** des blocages : la signature
  postérieure au début, légitime pour un bail prenant effet avant d'être
  signé, et le statut « Actif » dont la fin est passée, qui est une
  péremption et non une erreur de saisie.
- **Les secteurs apparaissent en pastilles orange** sur la carte de Stratégie
  foncière, et un clic en sélectionne un. La carte se comporte désormais
  comme celle de Sites : les pastilles disparaissent dès qu'un secteur est
  choisi, et l'emprise revient sur l'Ariège quand on le désélectionne.
- **Responsables, conservateurs bénévoles et animateurs** dans les Analyses,
  avec leur historique. C'est le premier endroit du périmètre interrogeable
  qui nomme des personnes : 31 salariés et bénévoles du CEN, sans leur
  adresse. Les **propriétaires** restent réduits à un type et une empreinte.

### Corrigé
- **Les périodes de responsabilité ne se chevauchent plus**, par ses deux
  sources : une période ouverte ne peut plus commencer avant une période déjà
  enregistrée, qu'elle engloberait ; et un changement de titulaire clôt la
  période en cours **à la date saisie** et non à `NOW()`, ce qui créait un
  recouvrement par construction dès que la nouvelle commençait plus tôt.
- **Les pastilles de sites n'apparaissent plus là où elles n'ont rien à
  faire.** `get_sites_coords()` ne filtrait aucun type : depuis la bascule
  des 111 sites en secteurs, les cartes de Sites, d'Accueil et d'Actions
  affichaient aussi les 113 secteurs. Sa source lisait par ailleurs la vue de
  compatibilité `gestcons.parcelles`, qui vaut `WHERE NOT perimetre` — donc
  aucune parcelle de secteur.
- **Les hachures d'une parcelle de continuité sélectionnée** prennent la
  teinte de son contour, au lieu de rester bleues dans un cadre rouge.
- **L'export FCEN exclut explicitement les secteurs.** Le code affirmait
  qu'un secteur en restait dehors « parce qu'il n'a ni statut ni
  gestionnaire » : c'était faux depuis la bascule, les 111 ayant gardé les
  deux. Ce qui les tenait dehors n'était que la valeur de leur statut.

## [3.2.2] — 2026-10-27

### Ajouté
- **Verrue temporaire, assumée comme telle** : un utilisateur nommément
  désigné voit les parcelles de priorité 2 en rose vif plutôt qu'en bleu
  clair, dans Stratégie foncière. C'est la **seule** règle d'affichage de
  l'application qui dépende de qui regarde. Elle tient en un bloc signé en
  tête de `mod_strategie.R` et un point unique de décision, par lequel
  passent la carte, la légende et le panneau de détail — faute de quoi la
  légende annoncerait une couleur que la carte ne dessine pas. Elle suit le
  changement de profil : la couleur est portée par l'**événement** des deux
  observateurs qui peignent, pas seulement par leur corps, qu'un observeEvent
  isole et que les réactifs lus dedans ne redéclenchent pas.
  La teinte est choisie sur mesure parmi quatre : `#ff2d95` se tient à 171 sur
  255 de la priorité 1, contre 54 pour le bleu clair, tout en restant loin du
  rouge de la sélection cadastrale et de l'anneau du secteur sélectionné.

## [3.2.1] — 2026-10-27

### Modifié
- **L'écran d'attente montre le papillon en grand**, la bienvenue dessous, le
  tout centré dans la fenêtre. Le bloc est en position fixe sur toute
  l'étendue de la vue : il ignore ainsi les marges du conteneur qui
  l'héberge, qui auraient décalé le centrage. Il portait jusqu'ici
  `min-height: 70vh`, soit à peu près la hauteur de son propre contenu — donc
  aucun jeu pour centrer quoi que ce soit, et un bloc posé en haut.
  `logo_terracen.png` étant en RVB **sans canal alpha**, avec un fond blanc
  opaque mesuré à (253, 254, 254), il aurait formé un carré blanc franc sur
  fond sombre : il est donc assumé en médaillon — fond déclaré, coins
  arrondis, marge intérieure — délibéré dans les deux modes plutôt
  qu'accidentel dans l'un.
  La largeur du logo est bornée par `38vh` en plus de `52vw` : en position
  fixe, un contenu trop grand est rogné sans qu'aucun ascenseur ne le
  rattrape. Mesuré de 553 à 993 px de hauteur de vue, marges haute et basse
  égales partout et jamais d'ascenseur.

## [3.2] — 2026-10-27

Deux ajouts qui prolongent le précédent : ce qu'on lit dans Analyses peut
maintenant sortir en tableur, et l'usage de l'onglet se compte.

### Ajouté
- **Export des tableaux d'une réponse d'Analyses**, en CSV point-virgule pour
  Excel, CSV virgule standard ou texte tabulé. Le bouton n'apparaît que si la
  réponse contient un tableau ; s'il y en a plusieurs, ils sont proposés
  nommés par leurs colonnes, « Tableau 2 » ne disant rien. Distinct de
  l'export de couche, et volontairement : celui-ci rend **exactement le
  tableau affiché**, qui peut n'être qu'un extrait, là où l'autre rejoue la
  requête et rend tout. Une réponse peut d'ailleurs porter un tableau sans
  qu'aucune couche soit possible — « combien de parcelles par commune » en est
  l'exemple même.
  Le CSV pour Excel porte une marque d'ordre des octets : sans elle, Excel en
  français lit l'UTF-8 comme du latin-1 et « Montégut » devient « MontÃ©gut ».
  La mise en forme des cellules est retirée, `**47**` devant arriver comme
  `47` sous peine de voir la colonne cesser d'être numérique.
- **Le nombre de questions posées dans Analyses**, sixième métrique de
  l'onglet Activité. Globale comme les connexions : une question ne porte sur
  aucun site, elle disparaît donc dès qu'un site est sélectionné.
  Il a fallu une table pour ça — `log_action()` n'écrit que dans le journal
  texte de shiny-server, où rien n'est interrogeable. `analyses_questions`
  retient la date, l'auteur, le modèle, le nombre de requêtes SQL, les jetons
  et le coût ; pas le texte des questions. Une ligne est écrite dans **tous**
  les cas, échecs compris : un compte qui ne retiendrait que les questions
  abouties dirait l'usage réussi, pas l'usage.
  ⚠️ Le compte démarre à la mise en service : les mois antérieurs valent 0, et
  c'est un défaut d'historique, pas une absence d'usage.

## [3.1] — 2026-10-27

L'onglet Analyses cesse de ne savoir que répondre : il sait maintenant
produire une couche SIG. Et il voit enfin les secteurs et les propriétaires.

### Ajouté
- **Export d'une couche SIG depuis une requête d'Analyses** — GeoPackage,
  Shapefile zippé, GeoJSON ou KML, depuis un bouton placé sous la réponse.
  La géométrie n'entre jamais dans la conversation : une parcelle pèse
  675 caractères en WKT, jusqu'à 36 805, soit ~37 500 jetons pour les
  200 lignes qu'une requête peut rendre, là où tout le schéma en coûte
  ~1 300. Elle est donc recousue au moment de l'export, depuis les tables de
  base et sous le rôle de l'application. La requête est rejouée **sans** le
  plafond de 200 lignes, sinon l'export hériterait d'un résultat tronqué sans
  que rien ne le dise ; plafond explicite à 50 000 entités. Mesuré : les
  6 698 parcelles de tous les sites et secteurs en 3,6 Mo de GeoPackage, en
  moins d'une seconde.
- **Trois grains de couche** : parcelles, sites ou secteurs, communes. Le
  bouton n'apparaît que si la requête désigne vraiment des entités — une
  agrégation par commune n'en propose aucun, et le bloc des requêtes écrit
  alors pourquoi. Un seul bouton par type de couche : la requête retenue est
  celle qui désigne le plus d'entités, à égalité celle qui porte le plus de
  colonnes.
- **La couche des communes** se raccorde à `gestcons.communes` (IGN
  ADMIN-EXPRESS), qui dormait déjà dans la base. Les vues gagnent
  `code_insee` partout où elles portaient déjà `commune` : apparié sans
  perte, 102 communes concernées, 102 retrouvées.
- **Les propriétaires entrent dans le périmètre interrogeable, par leur TYPE
  seulement.** `v_analyses_proprietaires` rend la catégorie juridique
  — personne physique, commune, structure agricole, SCI, État… —, le groupe,
  le droit réel et un booléen « public ». Aucun nom, aucune adresse, aucune
  date de naissance ; `dico_proprietaire` reste refusée au rôle de l'onglet.
  `proprietaire_ref`, empreinte salée de l'identifiant cadastral, existe
  parce que compter sans clé d'identité donne un résultat faux : 262
  personnes tiennent plus d'un compte cadastral. `v_analyses_parcelles`
  gagne `nb_proprietaires` et `en_indivision`.
- **Les secteurs d'intervention prioritaire sont interrogeables** :
  `v_analyses_secteurs`, une ligne par secteur, et la colonne `type_site` sur
  les parcelles.

### Modifié
- **Les vues d'analyse appartiennent désormais à `adminsig`**, comme tout le
  reste du schéma. Elles avaient été créées sous un autre compte, ce qui les
  rendait impossibles à reprendre par une migration ordinaire. Transfert
  sans effet sur ce qu'elles renvoient : aucune des 74 tables de `gestcons`
  ne porte de RLS.
- **La priorité 2 de Stratégie foncière** prend la teinte de la priorité 1 en
  plus clair, et les deux degrés partagent une seule opacité. Les polygones
  n'ont pas de bordure : ce qui tenait lieu de contour était le trait du
  cadastre transparaissant sous un remplissage moins opaque, d'où deux
  épaisseurs apparentes.

### Corrigé
- **L'onglet Analyses présentait 111 secteurs comme des sites en
  préfiguration**, à 0 parcelle, leurs parcelles comptées en continuité et
  absentes du détail. Les vues de gestion amont ne filtrent pas le type de
  site, alors que le périmètre des vues de détail le filtrait.
- **Les 3 963 parcelles des 111 sites basculés en secteurs** portaient
  `perimetre = false`, donc n'apparaissaient dans aucun secteur à l'écran,
  alors que la carte se cadrait correctement — le cadrage ignore ce drapeau.
  Ce booléen a un sens **inverse** entre un site et un secteur.
- **Les outils de dessin et l'icône de plein écran** en mode sombre.
- **`gestcons.dico_priorite`**, seule table du schéma hors `adminsig` et
  illisible par l'application.

## [3.0] — 2026-10-27

Refonte de l'interface, en six étapes, plus le socle qui la porte. Le numéro
majeur n'est pas une convenance : le framework change, la palette change, et
l'application gagne un mode sombre.

### Ajouté
- **Mode clair / sombre**, au choix depuis la barre du haut, par défaut sur le
  réglage du système. Les huit teintes basculent sur le second jeu de la
  maquette. Cinq choses ne suivaient pas le thème toutes seules et ont dû être
  forcées : les couleurs de boutons, que Bootstrap compile en dur ; Selectize,
  qui écrit son blanc ; la couleur des liens, calculée à partir des composantes
  et non du jeton ; la zébrure des tableaux, un noir à 2,4 % invisible sur fond
  sombre ; et les trois graphiques, rendus en SVG.
- **Analyses : un sélecteur de modèle** — Opus 5.5 par défaut, Sonnet 5.5,
  Haiku 5.5, Fable 5.1. Le tarif suit le modèle, et le coût affiché est celui
  du modèle qui a RÉPONDU : un repli serveur peut en changer en cours d'appel.
  Haiku n'a pas de repli serveur, les en-têtes se montent donc selon le choix.
- **Analyses : la conversation**, le temps de la session. Les questions
  s'enchaînent, le fil s'affiche avec le coût de chaque échange, et un bouton
  repart de zéro. Le prompt système et le modèle sont figés pour la durée
  d'une conversation : les blocs de raisonnement y sont liés, et modifier un
  tour déjà envoyé ferait échouer la requête.
- **Un titre de page sur les dix onglets** ; quatre n'en avaient aucun.

### Modifié
- **Bootstrap 5, via bslib.** Fin d'un framework sans maintenance depuis 2019.
  Le shim `bs3compat` de bslib fait vivre l'ancien balisage, ce qui a rendu la
  bascule bien moins risquée que prévu. Summernote passe à sa version « lite »,
  ses déroulants s'ouvrant par un attribut renommé en 5.
- **La palette de la maquette.** Les 32 jetons hérités de deux systèmes
  superposés se réduisent aux **huit** de la maquette, nommés par rôle : des
  gris biaisés vers le vert, un accent de pin. L'ancien accent était très
  exactement le bleu des parcelles sous contrat sur la carte — l'interface et
  la donnée parlaient la même couleur.
- **Le rail vertical devient une barre du haut**, et ses 92 px de largeur
  reviennent à la carte.
- **Une couleur par nature d'action sur tous les boutons.** « Enregistrer »
  était vert ici et bleu là, « Mettre à jour ce site » orange quand les autres
  étaient bleus, « Réinitialiser » rouge alors qu'il ne détruit rien.
- **Hauteur de travail mesurée au rendu réel.** Les pages à carte réservaient
  `min-height:100vh` dans une zone qui n'en fait pas 100 : **160 px d'ascenseur
  permanent**, carte vide comprise. Il tombe à zéro sans que la carte rétrécisse.
- **Plein écran : c'est le bloc qui s'agrandit, pas la carte.** Carte, message
  et barre d'actions passent ensemble en vrai plein écran du navigateur, donc
  les boutons restent utilisables. Modales, voile et bandeaux d'avertissement
  sont accueillis dans le bloc, faute de quoi ils ne seraient pas rendus.
- **Tableaux, champs et modales** alignés sur les jetons, variables de
  DataTables comprises.

### Corrigé
- **Un bouton Bootstrap 5 dans une application Bootstrap 3.** Le
  « Réinitialiser » d'Activité portait `btn-outline-secondary`, qui n'existe
  pas dans le thème : il sortait sans aucune couleur.
- **Un gestionnaire de message enregistré deux fois**, l'un écrasant l'autre :
  la version complète, qui invalidait la taille de la carte visée, n'a jamais
  servi.
- **Un observateur qu'aucun événement ne pouvait déclencher** dans Actions —
  un tiret contre un souligné dans la construction de l'identifiant.
- **La légende et le contrôle des couches** gardaient des couleurs de texte
  écrites en dur par Leaflet, illisibles sur fond sombre.
- **Deux « commentaires » CSS écrits avec un `#`** : le navigateur y lit un
  sélecteur invalide et jette la règle qui suit. Les deux règles concernées
  étaient perdues depuis toujours.

### Retiré
- **Le mode démo**, doublement neutralisé et jamais activable. La censure des
  invités, elle, reste.
- **Du code mort** : 47 lignes de CSS que rien ne produit, un gestionnaire JS
  orphelin, la branche `rectangle_meta` de Sites que rien n'alimentait, deux
  valeurs calculées jamais lues, l'écriture d'un `signataire_user_id` dont la
  colonne n'existe pas. Mesuré après coup : aucune des 111 fonctions de niveau
  fichier n'est sans appel.
- **`shinythemes`** du lockfile.

## [2.3] — 2026-10-26

### Ajouté
- **Contrats : les pièces jointes s'ouvrent depuis la fiche 👁.** Elle en
  annonçait le nombre sans permettre d'en ouvrir une seule : il fallait passer
  par le formulaire d'édition, donc en avoir le droit — ce qui, depuis que le
  crayon ✏️ est réservé aux responsables du site concerné, fermait l'accès aux
  documents à tous les autres. Chaque pièce est désormais un lien, avec son
  type et sa remarque.

### Modifié
- **Tableaux : le champ de recherche passe au-dessus de la navigation.** Les
  deux partageaient la même ligne.

## [2.2] — 2026-10-26

### Ajouté
- **Onglet « Analyses » : poser une question en français.** La question part à
  l'API Claude avec le schéma des vues interrogeables ; Claude écrit lui-même
  les requêtes, l'application les exécute et il rédige la réponse. Les requêtes
  exécutées sont montrées, pour qu'on puisse juger sur quoi la réponse repose.

  Réservé aux administrateurs. La garde n'est pas la relecture de la requête,
  qui se contourne, mais un rôle PostgreSQL dédié : transaction en lecture
  seule, `statement_timeout`, et droit de lecture sur les SEULES vues
  `gestcons.v_analyses_*`, qui ne contiennent ni propriétaires, ni acteurs, ni
  utilisateurs, et excluent les sites marqués non diffusables ou sensibles.

  Quatre vues sont exposées : les sites, les parcelles, les contrats avec leur
  statut, et le lien entre parcelles et contrats. Les trois dernières ont été
  ajoutées après qu'une question est restée sans réponse — « combien de
  parcelles ont un contrat en élaboration ? » — faute de pouvoir relier un
  statut de contrat à une parcelle.

  L'onglet garde une **mémoire** : des consignes durables que l'on écrit soi-même
  — vocabulaire maison, colonne à prendre par défaut, pièges du modèle de
  données — jointes à chaque question. Les réponses sont rendues en Markdown,
  tableaux compris, et le coût en jetons de chaque question est affiché.

- **Accueil : l'infobulle d'un site donne communes, surface et contrats.** Au
  survol d'un cercle sur la carte, en plus du responsable et du statut. Les
  onglets de travail gardent l'infobulle courte.

- **Sites : le formulaire d'une parcelle revient quand une seule est retenue.**
  L'édition en masse reste l'outil de plusieurs parcelles ; avec une seule, le
  formulaire s'ouvre pré-rempli, comme dans l'ancien onglet Parcelles. Les
  périmètres manuels y ont droit aussi, avec les seuls champs qui les
  concernent.

- **Tableaux : pagination aussi en haut à droite.** Contrats, Docs de gestion,
  Acteurs et Utilisateurs affichent dix lignes par page ; changer de page
  obligeait à descendre en pied de tableau puis à remonter.

### Modifié
- **Sites : la sélection de parcelles est un aplat orange.** Le contour rouge
  se confondait avec le remplissage des parcelles sans maîtrise, et il était
  posé sous les autres couches — un aplat y aurait été invisible. Le
  surlignage a désormais son propre plan, au-dessus de tout le reste.

- **Sites : une seule nature de parcelle par sélection.** On ne mélange plus
  parcelles cadastrales et périmètres manuels : ce n'est pas le même geste, ni
  le même formulaire d'édition. L'infobulle de l'outil rectangle annonce enfin
  ses deux usages, avec et sans ⇧.

- **La barre d'onglets place Stratégie foncière juste après le menu Sites.**

### Corrigé
- **Stratégie : rattacher une parcelle à un secteur crée son propriétaire dans
  les acteurs**, comme le fait déjà l'ajout à un site. L'oubli laissait 68
  propriétaires de parcelles de secteur absents de la liste des acteurs ; ils
  ont été rattrapés, avec 232 autres, par un script de reprise.

- **Sites : les périmètres manuels retenus n'étaient pas surlignés.** Le
  dessin de la sélection ne lisait que les parcelles cadastrales : cliquer un
  polygone dessiné ne produisait aucun retour à l'écran.

## [2.1] — 2026-10-26

### Ajouté

- **L'application s'ouvre sur une page d'accueil.** Plus d'entrée directe dans
  un onglet de travail : à droite la carte des sites, dont les cercles
  n'ouvrent rien au clic et se contentent d'une infobulle au survol (nom,
  responsable, statut) ; à gauche les chiffres clés — nombre de sites, surface
  en gestion, courbe d'évolution, graphique d'activité et répartition des
  contrats fonciers actifs entre conventions de gestion, ORE et acquisitions.

  Les définitions retenues sont affichées sous chaque chiffre : la surface en
  gestion ne compte que les parcelles couvertes par un contrat foncier
  **actif**, rapportées aux seuls sites qui en ont un. La courbe est datée du
  début du plus ancien contrat actif de chaque parcelle, et non de
  `date_crea_site` : 100 des 174 sites y portent la même journée, trace d'une
  reprise de données qui aurait écrasé toute la courbe sur une année.

  Le graphique d'activité est celui de l'onglet Activité, en vue globale sur
  douze mois — les deux appellent la même fonction.

- **La couche « Sites voisins » montre aussi leur continuité et les secteurs
  d'intervention.** Elle ne dessinait que les parcelles maîtrisées des sites
  voisins. Elle y ajoute désormais leur continuité, **hachurée dans la même
  couleur** — ce qu'un voisin convoite, par opposition à ce qu'il maîtrise —
  et les parcelles des secteurs d'intervention prioritaire, **hachurées dans
  une teinte distincte**. L'infobulle nomme la nature de chaque entité.

- **Les onglets du domaine « Sites » sont regroupés sous une entrée
  déroulante.** « Sites », « Actions », « Contrats » et « Docs Gestion »
  quittent la barre d'onglets au profit d'un menu « 📍 Sites » proposant
  Création / modification sites et parcelles, Actions (animation foncière,
  réunion, etc.), Contrats et Docs de gestion. Les écrans et leur
  fonctionnement sont inchangés : seul le chemin pour y arriver change.

  Les droits portent désormais sur les **items du menu** et non sur les
  onglets : Contrats reste réservé aux administrateurs et responsables de
  site, et l'entrée disparaît entièrement si aucun item n'est permis.

- **Le contrôle des couches de la carte Sites est rangé en groupes
  repliables.** Onze entrées y étaient empilées à plat. Elles se répartissent
  désormais en « Fond de carte », « Le site », « Cadastre », « Autour du
  site » et « Zones de protection », un seul groupe ouvert à la fois. Un
  groupe replié affiche une pastille comptant ses couches actives, et la
  largeur du contrôle ne change pas d'un groupe à l'autre.

  Les contrôles de moins de six entrées sont laissés à plat : grouper deux
  couches n'apporte rien.

  Les groupes sont repliés à l'arrivée, et entrer dans un onglet referme les
  siens : on y retrouve un contrôle compact plutôt que celui qu'on avait
  laissé ouvert la fois d'avant.

- **Les sites voisins passent au jaune, périmètres de stratégie compris.** Les
  parcelles des sites voisins deviennent un aplat jaune, et celles des secteurs
  d'intervention prioritaire — les périmètres de la stratégie foncière — le
  même jaune hachuré. La continuité d'un site voisin garde l'ardoise hachurée :
  en jaune elle deviendrait indiscernable des secteurs. Le jaune retenu évite
  volontairement l'ambre des parcelles sous contrat en élaboration.

- **Les zones de protection se choisissent par type.** Les 140 zones étaient
  un interrupteur unique, tout ou rien. Chacun des huit types — APPB, Natura
  2000 ZPS et ZSC, RBD, RNCFS, RNR, ZNIEFF1, ZNIEFF2 — a désormais le sien, et
  la légende ne décrit plus que les types cochés.

- **Chaque page du menu affiche son nom en tête de colonne gauche.** Une fois
  dans le déroulant, la barre d'onglets ne dit plus où l'on se trouve : le
  titre prend ce rôle, avec le libellé exact de l'item qui y mène.

- **Sites : les parcelles du site se sélectionnent avant d'agir.** Cliquer une
  parcelle du site, ou la viser au ⇧ + rectangle, la met désormais dans une
  sélection au lieu d'ouvrir aussitôt une modale. Le pied de carte propose
  alors de les **retirer du site**, de **modifier leurs informations** et, quand
  toutes y sont éligibles, de les **basculer en continuité**. Le geste vaut pour
  une parcelle comme pour vingt.

  La règle de la bascule est conservée telle quelle : elle n'est offerte que si
  la maîtrise n'est acquise sur aucune des parcelles retenues, c'est-à-dire si
  toutes leurs liaisons de contrat sont en élaboration.

- **Une seule nature de parcelle sélectionnable à la fois.** L'onglet Sites
  compte désormais trois sélections — parcelles candidates, continuité,
  parcelles du site — et les gardes, posées une à une au fil du temps, ne
  couvraient qu'une partie des paires possibles. Elles passent par un contrôle
  unique : commencer une sélection alors qu'une autre est en cours est refusé,
  en nommant celle à vider et le nombre d'éléments qu'elle contient. Le ⇧ +
  rectangle, qui n'avait aucune garde, est couvert lui aussi.

- **L'édition en masse des parcelles écrasait toutes les liaisons de contrat.**
  Elle portait le même `UPDATE` non borné que la fiche d'une parcelle : sur
  une parcelle qui porte plusieurs liaisons, il posait deux fois la même valeur
  et violait la clé primaire. L'erreur étant avalée, le changement ne
  s'écrivait pas et l'application annonçait un succès.

  Elle retire désormais les liaisons vers un contrat **actif**, puis pose celui
  choisi — les liaisons vers des contrats terminés ou résiliés restent en place
  comme trace, conformément à la règle « un contrat actif par type et par
  parcelle ». L'option « Retirer tout contrat » suit la même logique. Les deux
  types, foncier et agricole, passent par le même code au lieu d'en être deux
  copies.

- **Sites : « Modifier les infos » applique l'édition en masse des parcelles.**
  Le formulaire que portait l'onglet Parcelles — douze champs, chacun laissé
  sur « ne pas modifier » étant ignoré — et son écriture sont repris tels
  quels dans l'onglet Sites, appliqués à sa propre sélection.

  Les périmètres manuels en sont écartés : le formulaire ne décrit que des
  parcelles cadastrales.

### Modifié

- **Les cercles des sites sur les cartes d'ensemble sont deux fois plus
  petits.** Leur rayon est exprimé en mètres : le facteur d'échelle et le
  plancher ont été divisés par deux, de sorte que la réduction vaille à tous
  les niveaux de zoom. Au zoom par défaut, le rayon passe de 4 427 à 2 214 m.

- **Les légendes des cartes passent en bas à gauche.** Toutes héritaient d'un
  même défaut, un seul point a donc suffi. Elles rejoignent la légende des zones de protection,
  déjà dans ce coin ; Leaflet empile les contrôles d'un même coin plutôt que de
  les superposer.

### Retiré

- **Actions : la couche « Parcelles (Actions) » n'est plus masquable.** La
  décocher ne laissait qu'une carte vide, alors que c'est la raison d'être de
  l'onglet. Elle quitte le contrôle des couches et reste affichée en
  permanence, comme « Parcelle sélectionnée » ailleurs.

- **Le module Parcelles est supprimé.** Ses fonctions — sélection, édition
  parcelle par parcelle et en masse, continuité — sont désormais dans l'onglet
  Sites. 2 492 lignes en moins.

### Corrigé

- **Le rectangle de sélection ne prenait plus les parcelles cadastrales.** Dans
  l'onglet Sites, le rectangle sans ⇧ ne sélectionnait plus rien et restait
  dessiné sur la carte. Régression introduite par la mise en place de la
  sélection au ⇧ : la branche « sans ⇧ » avait été emportée avec l'autre.

- **Contrats : le crayon ✏️ ne promet plus que ce qu'il tient.** Il s'affichait
  sur toutes les lignes, sans condition, et le formulaire s'ouvrait sans la
  moindre garde — un responsable du site A pouvait enregistrer une
  modification sur un contrat du site B. Le crayon est désormais réservé aux
  administrateurs et aux responsables d'un des sites concernés ; un contrat
  sans aucune parcelle, donc sans site, reste ouvert à tout responsable de
  site. La règle est rejouée côté serveur, sur les deux chemins d'édition.

  **Acteurs et Utilisateurs** suivent la même logique : les acteurs sont
  gérables par les administrateurs et tous les responsables de site (l'onglet
  reste consultable par les animateurs et conservateurs bénévoles, sans ➕ ni
  ✏️), les utilisateurs par les seuls administrateurs.

- **Rupture de contrat : « NA » s'écrivait en base.** La zone « Remarque
  rupture » du contrat agricole affichait littéralement `NA` quand la remarque
  était vide, et cette chaîne repartait en base au premier enregistrement.
  Deux contrats agricoles en portaient la trace, corrigés. La branche foncière
  n'a jamais eu le défaut : les deux étaient écrites séparément, elles ne font
  désormais plus qu'une.

- **Les onglets masqués ne rechargent plus leurs données.** Une écriture de
  parcelle réveillait les trois onglets à carte, affichés ou non — au moins
  0,4 s de traitement gelé par enregistrement pour redessiner des couches
  invisibles. Hors écran, les données sont marquées périmées et rechargées une
  seule fois au retour sur l'onglet.

## [2.0.1] — 2026-10-16

### Modifié
- **Stratégie foncière : les parcelles de secteur reviennent au bleu, en aplat
  sans contour.** La priorité 1 reprend exactement le bleu des parcelles sous
  contrat actif de l'onglet Sites, la priorité 2 un bleu plus clair de la même
  famille. La bordure n'avait été posée que pour les distinguer de la sélection
  cadastrale pendant la parenthèse en rouge ; les calques de sélection étant
  rouges, elle n'a plus rien à distinguer. Au survol, le surlignage en pose une.
  L'anneau du secteur sélectionné repasse au rouge, le plus lisible sur du bleu.

- **Les deux priorités se ressemblaient trop pour être distinguées sur la
  carte.** Les deux bleus retenus sont voisins : mélangés à 35 % sur le fond de
  carte, ils ne différaient plus que de 16 sur 255, soit 6 % d'un canal. La
  légende, qui affiche ses pastilles en aplat, montrait bien l'écart — d'où une
  carte qui semblait n'avoir qu'une seule couleur. Le degré est désormais porté
  par l'intensité autant que par la teinte, ce qui porte l'écart à 112 sur 255,
  et les pastilles de la légende reprennent la couleur telle qu'elle apparaît
  sur la carte.

## [2.0] — 2026-10-16

Cette version solde l'audit complet du 15 octobre : **les 4 constats critiques
et 19 des 22 majeurs** sont corrigés. L'essentiel touche l'intégrité des
écritures — plusieurs chemins perdaient des données en annonçant un succès.

**Deux prérequis de déploiement**, tous deux déjà appliqués sur le serveur :
la clé primaire de `gestcons.conservateur_benevole` passe à
`(site_id, user_id, date_debut)` — cf.
`scripts/migration_cle_conservateur_benevole.sql` — et le paquet R `xml2` doit
être installé, faute de quoi les descriptions d'action s'affichent en texte
brut au lieu d'être mises en forme.

### Corrigé
- **Enregistrer la carte d'association d'un contrat effaçait les liaisons des
  autres contrats.** L'étape 2 du rattachement parcelles ↔ contrat supprimait
  toutes les liaisons des parcelles retenues, sans filtrer sur le contrat
  édité. Ouvrir la carte d'un contrat, ne rien changer et cliquer
  « Enregistrer » suffisait à détruire les liaisons d'un autre contrat sur ces
  mêmes parcelles. La table ne porte pas de trigger d'audit : la perte était
  intraçable.

  Rejoué sur les données réelles, en transaction annulée : en sauvegardant le
  contrat 68 du site 43, les sept liaisons du contrat 11 passaient de 7 à 0.
  Neuf parcelles portent aujourd'hui deux contrats, le cas était donc
  atteignable.

  Ce `DELETE` était inutile : l'étape 1 retire déjà toutes les liaisons du
  contrat édité sur les sites éditables, et les parcelles retenues y sont
  elles aussi restreintes — la désélection d'une parcelle reste donc bien
  prise en compte, vérifié. L'insertion devient idempotente. Les contrats
  fonciers et agricoles passent par le même code, les deux sont corrigés.

- **Les listes « Acteurs » des formulaires de contrat se vidaient en silence.**
  Le `reactiveVal` partagé entre Sites, Acteurs et Contrats a cinq points
  d'écriture. Quatre y poussaient `(id, acteur_label)` ; celui de `mod_sites.R`
  un tout autre schéma. Il suffisait donc de valider une sélection de parcelles
  sur un site — ce qui crée les acteurs propriétaires — pour que les quatre
  listes d'acteurs des formulaires de contrat deviennent vides, sans message,
  et le restent jusqu'à la fin de la session.

  Les cinq points passent désormais par une fabrique unique,
  `fetch_acteurs_choices()`, qui porte le contrat de ce `reactiveVal` et
  remplace quatre copies de la même requête. Les colonnes supplémentaires que
  poussait `mod_sites.R` ne servaient à personne.

  La liste ne se fige plus non plus sur sa première évaluation : elle est lue
  à chaque construction de formulaire, et un formulaire déjà ouvert reçoit les
  nouveaux choix sans être reconstruit — sa saisie en cours est préservée.

- **Quatre tableaux rendaient du texte saisi en HTML brut.** Acteurs, Contrats,
  Documents de gestion et la liste des pièces jointes sont rendus en
  `escape = FALSE`, nécessaire pour leurs colonnes d'icônes et de liens — mais
  toutes les autres colonnes y arrivaient donc sans échappement, dont des noms
  d'acteurs, de contrats, de sites et de fichiers. Le défaut était déjà visible
  sans malveillance : un acteur se nomme « Fiona & Floriane », un document
  « … Le Pla & Mijanès ». Huit lignes en base contiennent aujourd'hui un
  caractère à échapper.

  Les colonnes qui portent vraiment du HTML sont désormais nommées une à une,
  et **tout le reste est échappé par défaut** — une colonne ajoutée plus tard
  est ainsi protégée sans qu'on ait à y penser. L'infobulle des périmètres
  manuels, qui concaténait les noms de contrats sans échappement, suit la même
  règle que la fabrique d'étiquettes centrale.

- **Le type des fichiers téléversés n'était jamais vérifié côté serveur.** La
  liste des formats ne servait que d'attribut `accept` sur le champ de
  téléversement : un filtre de boîte de dialogue, qu'un envoi direct contourne.
  Or les documents sont publiés sous la même origine que l'application et
  ouverts dans un onglet — un `.html` ou un `.svg` s'y serait exécuté avec la
  session de la personne qui clique.

  Les trois chemins de téléversement contrôlent désormais l'extension avant
  toute écriture, sur la liste qui servait déjà d'`accept`. L'extension retenue
  est la dernière, donc `note.pdf.html` est refusé. Les 103 fichiers déjà
  stockés sont tous des PDF, un `.docx` et un `.jpg` : rien à reprendre.

- **La description d'une action était réinjectée en HTML brut.** Elle se saisit
  dans Summernote, dont la barre d'outils offre un bouton « codeview » : on y
  tape donc du HTML directement. Une balise `<img src=x onerror=…>` s'exécutait
  dans la session de quiconque ouvrait la fiche, à la même origine — soit
  l'élévation d'un utilisateur authentifié vers un autre.

  Le rendu passe désormais par un assainisseur à liste blanche : les balises
  sans contenu utile partent avec leur contenu, et tous les attributs tombent
  sauf un `href` de schéma sûr sur un lien. Assaini **au rendu** et non à
  l'écriture : la base garde ses descriptions, et les gabarits du rapport PDF
  continuent d'être alimentés comme avant.

  Passé sur les 104 descriptions réelles : le texte visible est identique pour
  les 104, aucune perte. Et 17 893 octets de balisage Word disparaissent au
  passage — l'une d'elles tombe de 12 206 à 1 133 octets à texte inchangé.

  Nouvelle dépendance : `xml2`. Sans elle, la description s'affiche en texte
  brut plutôt qu'avec sa mise en forme — jamais exécutée.

- **Trois enregistrements se faisaient hors transaction.** La mise à jour d'un
  contrat **agricole** validait le `DELETE` de ses agriculteurs avant
  l'`INSERT` : un acteur supprimé entre-temps fait échouer la réinsertion — la
  clé étrangère n'est pas couverte par le `ON CONFLICT` — et le contrat se
  retrouvait sans aucun acteur, alors que la règle métier en exige un. Même
  schéma à l'enregistrement d'une action, foncière comme agricole, où l'action
  était modifiée et ses liaisons à moitié réécrites. Les trois sont désormais
  atomiques, et le message de succès est conditionné à leur réussite.

- **L'ajout d'une pièce jointe annonçait un succès sans vérifier l'écriture.**
  `docs_add()` renvoyait `TRUE` sans regarder le résultat de son insertion :
  hors transaction, l'erreur est capturée et renvoie zéro ligne. Le fichier
  était donc copié sur le disque, la ligne absente de la base, et la pièce
  jointe n'apparaissait nulle part. L'insertion est testée, et le fichier
  retiré du disque si elle échoue.

- **Changer le contrat d'une parcelle écrasait toutes ses liaisons.** Les
  sélecteurs de l'édition n'affichent qu'un contrat — le premier trouvé — alors
  qu'une parcelle peut en porter plusieurs. L'enregistrement remplaçait pourtant
  « le » contrat par un `UPDATE` portant sur la seule parcelle : sur les neuf
  parcelles qui en portent deux, il posait deux fois la même valeur et violait
  la clé primaire. L'erreur étant avalée, le changement ne s'écrivait pas et
  l'application annonçait un succès. De même, choisir « Aucun contrat »
  supprimait **toutes** les liaisons, pas seulement celle affichée.

  La liaison remplacée est désormais nommée : celle qui était à l'écran,
  retenue à la construction du formulaire. Les autres ne sont plus touchées, et
  les deux types de contrat sont enregistrés dans une seule transaction.

- **Quatre suppressions définitives partaient au premier clic.** Supprimer un
  contrat — et avec lui toutes ses liaisons de parcelles —, un acteur, un
  document de gestion avec son fichier sur le serveur, ou retirer une parcelle
  depuis l'onglet Parcelles ne demandait aucune confirmation. L'onglet Activité
  était le seul du dépôt à en demander une ; sa modale devient la fabrique
  partagée des quatre autres.

  Chaque confirmation annonce ce que la suppression entraîne, compté en base :
  nombre de parcelles et d'acteurs d'un contrat, de sites et de fichiers d'un
  document, de liaisons de contrat et d'action d'une parcelle.

  Pour un acteur, la modale distingue les deux cas : la base **refuse** la
  suppression tant qu'il figure sur un contrat, tandis que ses liaisons
  d'action partent silencieusement avec lui. Et le refus est désormais
  signalé — « Acteur supprimé » s'affichait même quand rien n'avait été
  supprimé.

- **L'enregistrement d'un site faisait neuf écritures sur cinq tables, hors
  transaction.** Chacune était validée seule : un échec en cours de route
  laissait le site à moitié enregistré — la fiche modifiée mais le statut non
  clôturé, ou le responsable changé et les animateurs non. Elles tiennent
  désormais dans une seule transaction, et les deux mises à jour de rôle y
  partagent la même connexion au lieu d'ouvrir chacune la sienne.

- **Le module Sites rechargeait toutes les zones de protection à chaque
  ouverture de session, pour jeter le résultat.** Elles sont déjà calculées une
  fois au démarrage de l'application et passées au module en paramètre ;
  l'appel qui se trouvait là rangeait sa copie dans une variable que rien ne
  relisait. Mesuré sur la base : 469, 490 et 468 ms sur trois exécutions à
  chaud, plus le parsage de 1,37 Mo de géométrie côté R. Shiny étant
  mono-thread par processus, cette attente bloquait aussi les autres
  utilisateurs connectés au même processus.

- **La carte d'association d'un contrat laissait rattacher une parcelle déjà
  sous contrat.** Une parcelle ne peut avoir qu'un contrat actif par type —
  au plus un foncier et au plus un agricole — mais cette carte ne le gardait
  pas : le clic était une simple bascule, et la requête charge toutes les
  parcelles des sites, y compris celles déjà engagées. C'est par là que sept
  parcelles de Pech Saint-Sauveur ont acquis un second contrat actif.

  Le clic et le rectangle refusent désormais ces parcelles, en nommant le
  contrat qui les détient. Retirer une parcelle de la sélection reste toujours
  possible. L'édition d'une parcelle, elle, n'avait pas ce défaut : son
  sélecteur remplace le contrat affiché.

### Corrigé
- **Une écriture qui échouait dans une transaction était annulée en silence,
  pendant que l'application annonçait un succès.** Les fonctions `safe_db_*`
  capturent l'erreur SQL et renvoient une valeur neutre. Or PostgreSQL met une
  transaction en état « avorté » dès la première erreur : tous les ordres
  suivants échouent, et le `COMMIT` final renvoie un `ROLLBACK` **sans lever
  d'erreur**. Le `tryCatch` censé déclencher le rollback ne se déclenchait donc
  jamais, et la notification de succès s'affichait alors que rien n'était écrit.

  Le cas se produit réellement : neuf parcelles des sites 43 et 125 portent deux
  liaisons de contrat, et une édition en masse les ramène sur la même clé
  primaire. Reproduit de bout en bout sur ces données, en transaction annulée.

  Les trois fonctions détectent désormais qu'une transaction est ouverte et
  laissent remonter l'erreur, de sorte que le rollback s'opère et que la cause
  réelle s'affiche. Hors transaction, leur comportement est inchangé — vérifié.
  La correction tient en un seul endroit et couvre les 61 appels concernés dans
  sept modules, ainsi que tout appel futur.

- **Contrats : une erreur SQL en transaction rompait la session au lieu de
  s'afficher.** Conséquence directe du correctif précédent : les cinq blocs
  transactionnels de `mod_contrats.R` — création foncière, création agricole,
  mise à jour foncière, suppression, enregistrement des liaisons parcelles —
  n'avaient aucun `tryCatch` englobant. L'erreur, désormais remontée, aurait
  déconnecté l'utilisateur. Chacun est encadré : la transaction est annulée,
  la cause s'affiche dans un bandeau, et le code de succès qui suivait —
  notification, journalisation, rechargement — ne s'exécute plus à tort.

- **Utilisateurs : même traitement pour la modification et la suppression.**
  La modification écrivait déjà avec `DBI::dbExecute`, dont l'erreur remontait
  sans être interceptée : ce chemin pouvait rompre la session avant même le
  correctif précédent. La suppression passe par `delete_utilisateur()`, encadrée
  à l'appel pour que la fonction garde son rôle. Dans les deux cas, le message
  de succès et la journalisation ne partent plus si l'écriture a échoué.

- **Documents de gestion et parcelles : derniers blocs transactionnels nus.**
  À la suppression d'un document, l'échec de la transaction est désormais
  bloquant : le nettoyage qui suit effaçait du disque des fichiers encore
  référencés en base. Même traitement à la création d'un document et à
  l'enregistrement de la source géométrique d'une parcelle.

  Les 27 blocs transactionnels du dépôt sont maintenant couverts : 25 sur
  place, et 2 — `delete_utilisateur()` et `.af_insert_animation()` — à leur
  appel, puisque ce sont des fonctions utilitaires hors observateur.

- **Corriger la date de début d'un bénévole conservateur le retirait du site.**
  La clé de `conservateur_benevole` est `(site_id, user_id)` et ne contient pas
  `date_debut`, contrairement à `responsable_sites`. L'enregistrement
  désactivait la ligne en cours puis la réinsérait avec `ON CONFLICT DO
  NOTHING` : la réinsertion était avalée en silence, la désactivation restait,
  et l'application affichait « ✅ Le site a été modifié ». Le même effet se
  produisait en resélectionnant un bénévole ayant déjà tenu le rôle sur ce
  site : l'ancien était clôturé, le revenant jamais réactivé.

  La réinsertion utilise désormais `ON CONFLICT (site_id, user_id) DO UPDATE`,
  la forme déjà retenue pour `animateur_sites`, et les deux ordres sont dans
  une transaction pour que la désactivation ne survive jamais seule. Les trois
  cas — correction de date, changement de bénévole, bénévole nouveau — ont été
  rejoués sur données réelles en transaction annulée.

  **Huit sites ont déjà perdu leur bénévole de cette façon** et demandent une
  reprise en base, distincte de ce correctif.

- **Rôles de site : l'historique des périodes est conservé sans être découpé.**
  Les deux tables de rôles ont la même forme, et le code les traitait de la
  même façon : clore la période en cours, en insérer une nouvelle. Appliqué à
  une simple correction de date de début, cela découpait une tenure continue en
  tranches. Mesuré sur `responsable_sites` : 37 de ses 87 périodes closes
  s'enchaînent exactement sur une période suivante de la **même** personne —
  le site 103 a le même responsable depuis 2021, en quatre morceaux.

  Les deux blocs passent par une fonction commune, `maj_role_site()`, qui
  distingue trois situations : corriger la date du titulaire en place modifie
  la ligne en cours, changer de titulaire clôt une période et en ouvre une
  autre, retirer le titulaire clôt seulement. Remettre une personne qui a déjà
  tenu le rôle à cette même date rouvre sa ligne au lieu de la perdre.

  La comparaison des dates passe par le jour et non par le `timestamptz` brut :
  minuit UTC n'est pas minuit à Paris, et toute sauvegarde pouvait passer pour
  un changement de date selon le fuseau de la session R.

  `scripts/migration_cle_conservateur_benevole.sql` aligne la clé de
  `conservateur_benevole` sur celle de `responsable_sites`, condition pour
  qu'un ancien bénévole puisse revenir avec une nouvelle date de début.

- **Stratégie foncière : corriger la date de début du responsable d'un secteur
  ne faisait rien.** Ce module a son propre chemin d'écriture, qui ne comparait
  que les personnes : une modification de la seule date était abandonnée en
  silence, sans même un message. Il passe désormais par la même
  `maj_role_site()` que les sites, ce qui corrige la perte et lui apporte au
  passage la réouverture d'une période déjà tenue.

  Tous les chemins d'écriture de ces deux tables sont maintenant couverts : les
  deux blocs de `mod_sites.R`, celui de `mod_strategie.R`, la création d'un site
  — simple insertion sur une table vierge — et la désactivation d'un
  utilisateur, qui ne fait que clôturer.

- **Rouvrir la fiche d'un site réaffichait la date du jour comme début de
  responsabilité.** Les observateurs qui remettent la date à aujourd'hui quand
  on change de titulaire se protégeaient d'un simple drapeau « première
  exécution », armé une seule fois pour toute la session. Dès la deuxième
  construction du formulaire, le sélecteur réémettait sa valeur et la date
  était écrasée — sans que rien ne soit enregistré, mais la fiche affichait
  une date fausse, et un enregistrement l'aurait entérinée.

  Les observateurs comparent désormais la valeur reçue à celle que le
  formulaire vient d'afficher. Revenir au titulaire d'origine rétablit aussi sa
  date enregistrée, au lieu de garder celle du jour posée par le détour.

- **« Mettre à jour ce site » restait parfois grisé.** Les deux boutons du
  formulaire de site naissaient désactivés, et seul l'observateur de validation
  les réactivait — or il ne dépend que des six champs obligatoires. Rouvrir la
  fiche sans en modifier aucun ne le rejouait pas, et le bouton fraîchement
  créé restait inerte. S'y ajoutait la course déjà documentée dans
  `mod_actions.R` : `shinyjs::disabled()` applique sa désactivation après le
  bind et écrase la réactivation envoyée juste avant.

  Les boutons sont désormais rendus actifs, comme ceux de l'onglet Activité,
  et l'observateur — rejoué à chaque construction du formulaire — les désactive
  si un champ obligatoire manque. Les deux enregistrements valident de toute
  façon le nom et la géologie côté serveur.

- **Secteurs : changer de responsable gardait la date du précédent.** Le
  formulaire de secteur n'avait pas l'équivalent de l'observateur des sites :
  la date affichée restait celle du titulaire sortant, et la nouvelle période
  démarrait donc avant la clôture de l'ancienne. Elle passe maintenant au jour
  du changement, et revenir au titulaire d'origine rétablit sa date.

  En revanche, les boutons des secteurs ne sont jamais créés désactivés : le
  défaut du bouton grisé ne les concerne pas.

- **Secteurs : le bouton d'enregistrement vérifie les champs obligatoires.**
  « Créer » et « Enregistrer » étaient toujours actifs, alors que le formulaire
  marque six champs d'une étoile. Seul le libellé était contrôlé, et seulement
  après le clic. Le bouton est désormais gouverné par les six, via le même
  `toggle_submit_state()` que les contrats, les documents, les acteurs, les
  utilisateurs et les actions — et rejoué à chaque construction du formulaire,
  sans quoi il ne s'appliquerait pas à une réouverture sans changement.

- **Stratégie foncière : les parcelles de secteur passent au rouge.** Deux
  intensités pour les deux priorités, un rouge sombre et un rouge clair. La
  sélection cadastrale étant elle aussi un aplat rouge, c'est la **bordure**
  qui distingue les deux calques : les parcelles de secteur en portent une,
  la sélection non. L'anneau de sélection d'un secteur passe au jaune, un
  anneau rouge se perdrait sur des parcelles rouges.

- **L'exclusivité des deux sélections valait pour le clic seulement.** On ne
  peut pas sélectionner des parcelles du secteur et des parcelles cadastrales
  en même temps — les actions du pied de carte seraient ambiguës. La règle
  était posée sur le clic, mais ni le rectangle ni le filtre par propriétaire
  ne la vérifiaient : on la contournait sans le vouloir. Les cinq chemins
  passent désormais par la même garde.

- **La légende de priorité ne propose plus « Non renseignée ».** Aucune
  parcelle de secteur ne peut l'être : les deux sélecteurs de priorité —
  l'ajout au secteur et la fiche d'une parcelle — n'offrent plus de valeur
  vide. Le résumé de la colonne de gauche suit.

### Ajouté
- **La priorité se lit enfin sur la carte et dans le résumé d'un secteur.** Une
  légende rappelle à quoi correspondent les bleus des parcelles, qui n'étaient
  interprétables par personne, et le résumé de la colonne de gauche ventile le
  parcellaire par priorité — nombre de parcelles et surface pour chacune, puis
  le total — au lieu d'un total unique. « 45 parcelles » ne disait rien de
  l'effort à fournir ; « 12 prioritaires pour 8,4 ha » répond à la question
  qu'on se pose devant un secteur. Les catégories vides ne s'affichent pas.

## [1.9] — 2026-10-15

### Ajouté
- **Un secteur d'intervention prioritaire peut être promu en site
  conservatoire.** On sélectionne sur la carte les parcelles effectivement
  acquises, puis « ⬆️ Promouvoir en site » ouvre **le formulaire de création
  d'un site**, pré-rempli avec tout ce que le secteur savait déjà, auquel
  s'ajoute le choix du contrat foncier.

  La conversion se fait **sur place** : le secteur étant déjà un site d'un
  autre type, il change de type ; les parcelles choisies deviennent
  contractuelles ; celles qu'on n'a pas choisies ne bougent pas et forment la
  **continuité du nouveau site**. Aucune parcelle n'est déplacée, aucun objet
  créé, tous les identifiants sont conservés — l'historique d'actions de la
  prospection suit donc intégralement. Les priorités sont effacées partout, la
  prospection laissant place à la gestion. Le secteur disparaît de la Stratégie
  foncière, et l'application ouvre le nouveau site dans l'onglet Sites.

  Si une parcelle sélectionnée appartient déjà à un autre site, la promotion
  est refusée en nommant les parcelles fautives, plutôt que d'échouer sur une
  violation d'index.
- **Maj + rectangle retire des parcelles d'un secteur**, dans l'onglet
  Stratégie foncière. Sans la touche, le rectangle sélectionne des parcelles
  cadastrales libres à rattacher ; avec elle, il vise celles qui sont **déjà
  dans le secteur** et propose de les en retirer après confirmation. C'est la
  convention de l'onglet Sites, où Maj cible de la même façon ce qui est déjà
  rattaché.

### Modifié
- **« Zone d'intérêt » devient « Continuité du site conservatoire ».** Le
  libellé change partout dans l'interface — contrôle des couches, boutons,
  messages, infobulles — soit une centaine d'occurrences. Les messages qui
  parlaient encore de « périmètre » pour désigner cette même notion sont
  alignés ; ceux qui visent un **périmètre manuel**, c'est-à-dire un polygone
  tracé à la main, gardent leur mot.
- **Les trois notions sont désormais définies dans l'aide.** « En savoir
  plus » de l'onglet Sites distingue le **site conservatoire** — au moins une
  parcelle et un contrat —, la **continuité du site conservatoire** — des
  parcelles proches rattachées à ce site, sans contrat — et le **secteur
  d'intervention prioritaire** — des parcelles sans contrat, rattachées à
  aucun site, repérées comme futur site possible. L'onglet Stratégie foncière
  reçoit sa propre aide, qui dit aussi ce qu'un secteur n'est pas, et la
  signification des couleurs de sa carte.

### Corrigé
- **Une parcelle rattachée à un site ne peut plus rejoindre un secteur.** La
  règle vaut pour une parcelle contractuelle comme pour une parcelle de la
  continuité du site. Les trois modes de sélection de la Stratégie foncière —
  clic, propriétaire, rectangle — l'écartent désormais, et l'ajout lui-même
  rejoue le filtre : entre la sélection et la validation, la parcelle a pu être
  rattachée ailleurs. Aucune parcelle n'était dans ce cas en base.
- **La carte de l'onglet Sites reste vide quand on y arrive depuis un autre
  onglet.** Les couches étaient dessinées alors que l'onglet était encore
  masqué : Leaflet ne rend rien dans un conteneur de taille nulle, et le
  court-circuit par empreinte croyait ensuite la couche à jour, si bien que la
  carte restait vide jusqu'au changement de site. Les couches sont désormais
  redessinées quand l'onglet devient visible, et recadrées une fois que le
  conteneur a sa taille réelle. Le défaut se voyait surtout après la promotion
  d'un secteur en site, qui bascule d'onglet.
- **La carte ne repart plus brutalement sur l'Ariège après avoir cadré un
  site.** Remplacer les choix d'un sélecteur fait transiter sa valeur par du
  vide avant que la sélection demandée ne s'applique ; ce vide passager était
  pris pour une désélection, ce qui effaçait les couches et reposait la vue par
  défaut.
- **La promotion d'un secteur ouvre le nouveau site cadré sur lui.** En changeant
  d'onglet, l'application réapplique à la nouvelle carte la vue de la
  précédente, pour qu'on garde la même zone en naviguant. Après une promotion
  c'est l'inverse qu'on veut, et la vue réappliquée était départementale : elle
  écrasait le cadrage. Elle est désormais effacée avant la bascule.
- **L'onglet Stratégie foncière suit ce qu'on y fait.** Trois décalages entre
  l'état enregistré et ce qui restait à l'écran : le résumé de la colonne de
  gauche gardait les anciennes valeurs après une modification, le secteur qu'on
  venait de créer n'apparaissait pas dans le sélecteur bien qu'il fût chargé, et
  la carte conservait l'emprise et les contours d'un secteur promu en site. Tous
  trois venaient d'un état client en retard d'un aller-retour sur l'état serveur.

## [1.8] — 2026-10-15

### Ajouté
- **Nouvel onglet « 🎯 Stratégie foncière »**, placé avant « Activité ». Il
  permet de créer, modifier et supprimer des **secteurs d'intervention
  prioritaire** : des zones de prospection faites de parcelles sans contrat,
  repérées comme pouvant devenir un futur site conservatoire. Un secteur est
  stocké comme un site d'un type distinct ; il reprend les champs descriptifs
  d'un site conservatoire — libellé, description, milieu, géologie, nature du
  périmètre, échelle et précision, sensibilité, non-diffusion, dates et
  responsable — mais ni les identifiants nationaux, ni le gestionnaire, ni le
  statut, ni les contrats. Sa suppression est refusée tant qu'il contient des
  parcelles, pour ne pas emporter silencieusement un parcellaire et son
  historique d'actions.

  Les secteurs **n'apparaissent pas** dans le sélecteur de l'onglet Sites, qui
  ne liste plus que les sites conservatoires, et sont absents de l'export FCEN
  — faute de statut comme de gestionnaire.

  L'écran reprend la disposition de l'onglet Sites : colonne de gauche avec le
  sélecteur, les boutons et le résumé du secteur, carte à droite, et formulaire
  en modale. Les parcelles du secteur y sont colorées selon leur priorité.

  **Le parcellaire d'un secteur se gère depuis la carte.** Au-delà du zoom 16,
  la couche cadastrale s'affiche comme dans l'onglet Sites ; un clic
  sélectionne ou désélectionne une parcelle, et le pied de carte propose de
  rattacher la sélection au secteur en choisissant sa priorité. Un clic sur une
  parcelle déjà rattachée ouvre une modale où l'on modifie sa priorité et sa
  remarque, ou on la retire du secteur. Le pied de carte reprend la disposition
  de celui de l'onglet Sites — sélecteur à gauche, boutons à droite, compte en
  dessous — et les parcelles du secteur sont dessinées dans des bleus plus
  clairs que celui des parcelles de site : la parenté de teinte dit qu'il s'agit
  de parcelles, la clarté qu'elles ne sont pas maîtrisées. Ni l'un ni l'autre ne
  se confond avec le rouge de la sélection ou le brun du cadastre.
- **La Stratégie foncière reprend les trois modes de sélection de l'onglet
  Sites.** Sous la carte, le même message rappelle qu'on associe des parcelles
  en cliquant, via un propriétaire ou en traçant un rectangle, et le pied de
  carte accueille le filtre « 🔍 Filtrer par propriétaire ». La **sélection par
  rectangle** et la **sélection par propriétaire** sont en place : toutes deux
  écartent les parcelles déjà rattachées au secteur, et la liste des
  propriétaires ne propose que ceux visibles à l'écran.
- **Un bouton « ✏️ Modifier » pour une parcelle de la zone d'intérêt**, dans
  l'onglet Sites. Il apparaît quand une seule parcelle est sélectionnée et
  ouvre une fiche où se règlent les deux champs qui lui sont propres : sa
  **remarque** — pourquoi elle intéresse — et sa **priorité**, la même notion
  que dans l'onglet Stratégie foncière, puisque c'est la même colonne. Les
  caractéristiques de maîtrise n'y figurent pas : une parcelle de zone
  d'intérêt n'est pas maîtrisée.

### Modifié
- **L'infobulle d'une parcelle de périmètre donne les mêmes informations que
  celle d'une parcelle cadastrale** — propriétaire, commune, surface — et y
  ajoute les deux champs qui lui sont propres, la **priorité** et la
  **remarque**. Vaut pour la zone d'intérêt d'un site comme pour les parcelles
  d'un secteur, dont l'infobulle était jusqu'ici réduite au numéro de parcelle.
  Les contrats restent exclus : une parcelle de périmètre n'en porte jamais.

### Corrigé
- **L'onglet « Stratégie foncière » n'est visible que des administrateurs et des
  responsables de site.** Il s'affichait pour tout le monde, invités compris —
  or une zone de prospection dit quelles parcelles le CEN convoite, ce qui n'a
  pas à circuler.
- **Être responsable d'un secteur n'ouvre plus la gestion des contrats.** Les
  rôles par site sont lus sans distinction de type : un responsable de secteur
  recevait donc un rôle « RS », lequel ouvre les onglets Contrats et Activité.
  Ces deux onglets ne comptent désormais que les responsabilités portant sur un
  **site conservatoire** ; l'accès à la Stratégie foncière, lui, reconnaît les
  deux. Un responsable était déjà dans ce cas en base.

## [1.7.1] — 2026-10-15

### Modifié
- **La modale d'une parcelle en élaboration avertit quand elle est la dernière
  de son contrat.** Basculer ou supprimer une telle parcelle laisse le contrat
  sans aucune parcelle rattachée ; l'encart le dit avant la confirmation, et
  précise que le contrat n'est pas supprimé pour autant. Ce n'est pas une
  anomalie — 92 des 250 contrats fonciers sont déjà dans ce cas — mais mieux
  vaut l'annoncer que le laisser découvrir.
- **Le journal des connexions enregistre la vraie adresse du client.** La
  colonne `ip` de `connexion_log` contenait `127.0.0.1` pour *toutes* les
  connexions : avec shiny-server, l'adresse vue côté Shiny est celle de la
  socket locale, pas celle du poste. Elle lit désormais l'en-tête
  `X-Forwarded-For` posé par le proxy, en n'en gardant que la première valeur —
  le client d'origine — avec repli sur l'ancien comportement. Sans effet sur
  l'instance de test, qui ne passe pas par le proxy.

## [1.7] — 2026-10-14

### Ajouté
- **Couche « Sites voisins » sur la carte des Sites.** Quand un site est
  sélectionné, on peut afficher les autres sites alentour, dessinés en ardoise
  tiretée : une couleur et un style qui ne ressemblent à rien de ce qui désigne
  le site courant — bleu pour ses parcelles, violet tireté pour son contour,
  orange pour sa zone d'intérêt. Le survol donne le nom du voisin. Chaque site
  voisin est représenté par l'union de ses parcelles cadastrales présentes à
  l'écran ; leur zone d'intérêt est exclue, un voisin étant montré pour ce
  qu'il maîtrise et non pour ce qu'il convoite. La couche est décochée par
  défaut, suit l'emprise visible avec la même marge que les zones humides, et
  se redessine au changement de site. Elle est placée sous le cadastre et sous
  le site courant, pour rester un repère de contexte.
- **Une parcelle du site dont les contrats sont encore en élaboration peut être
  basculée en zone d'intérêt**, au lieu d'être seulement supprimée. Le clic sur
  une telle parcelle propose désormais les deux issues ; la bascule conserve la
  ligne et son identifiant, donc **son historique d'actions la suit**, là où la
  suppression l'emporte avec elle. C'est le sens inverse de la bascule
  existante, qui n'avait jamais été traité. Les liens de contrat sont supprimés
  au passage — une parcelle de la zone d'intérêt n'en porte pas — et la modale
  nomme les contrats concernés avant de demander confirmation. L'option
  n'apparaît que si *tous* les contrats fonciers de la parcelle sont en cours
  d'élaboration : une maîtrise acquise, suspendue ou terminée interdit la
  rétrogradation, et seule la suppression reste offerte.

### Modifié
- **Le bouton « 📝 Remarque » disparaît des actions de la zone d'intérêt**, dans
  l'onglet Sites. La remarque d'une parcelle se modifie depuis l'onglet
  Parcelles, qui édite déjà l'ensemble de ses champs. Les deux observers qui
  servaient ce bouton sont retirés avec lui, plutôt que laissés inertes.

## [1.6] — 2026-10-12

### Ajouté
- **L'ajout d'une parcelle à la zone d'intérêt crée les acteurs
  « propriétaire » manquants**, comme le fait depuis toujours l'association
  d'une parcelle au site. Les deux chemins appliquent désormais la même règle :
  personnes physiques uniquement, dédoublonnage sur la clé normalisée
  nom/prénom/adresse. La logique, jusque-là écrite au seul endroit de
  l'association au site, est devenue une fonction partagée plutôt que d'être
  recopiée.
- **Couche « Zones humides » sur la carte des Sites.** Les 3 907 zones humides
  de l'ANA sont affichables depuis le contrôle des couches. Elle est **décochée
  par défaut** et n'interroge la base que si on la coche, puis suit l'emprise
  visible, avec une marge d'environ 2 km : tant que la carte reste dans la zone
  déjà chargée, aucune requête n'est relancée au déplacement. Elle est dessinée
  sous toutes les autres couches, de sorte qu'elle ne masque jamais une
  parcelle, et le survol donne le nom usuel du site. Elle ne dépend pas du site
  sélectionné et s'affiche même sans site actif.

  La donnée appartient à une autre application et sa table est protégée par une
  politique de sécurité au niveau ligne ; la lecture passe donc par une vue
  dédiée, `gestcons.v_zones_humides_ana`, à créer en base — sans elle, la couche
  reste vide et l'erreur est consignée dans les logs.

## [1.5.1] — 2026-10-12

### Modifié
- **Légende des cartes : « Autres / Non contractualisé » devient « Résilié /
  Suspendu / Terminé ».** L'entrée nomme maintenant les trois statuts qu'elle
  recouvre réellement, les deux autres du dictionnaire ayant leur propre ligne.
  La mention « Non contractualisé » désignait un cas qui n'existe plus : aucune
  parcelle de site n'est sans contrat foncier.

## [1.5] — 2026-10-12

### Ajouté
- **La source géométrique est modifiable dans la fiche d'une parcelle.** Un
  sélecteur « Source géométrique » accompagne désormais « Source de la surface »
  dans la modale d'édition d'une parcelle, qu'on l'ouvre depuis la carte ou
  depuis le tableau, et la valeur enregistrée apparaît dans la fiche de
  consultation. Le dictionnaire propose les onze sources de
  `dico_source_geom_parcelle` : la valeur posée à la création reste la règle,
  elle n'est plus qu'un défaut auquel on peut déroger. La table acceptant
  plusieurs sources par parcelle mais l'export FCEN n'en retenant qu'une, le
  sélecteur est à valeur unique et remplace ce qui s'y trouve. Le champ est
  présent dans les quatre formulaires qui éditent une parcelle : les deux
  modales d'une parcelle de site (depuis la carte et depuis le tableau), celle
  d'un polygone manuel, et l'édition en lot — où il suit la sémantique « ne pas
  modifier » des autres champs de masse.
- **La source géométrique d'une parcelle est enregistrée à sa création.** La
  table de liaison `parcelles_sources_geom` n'était alimentée par aucun chemin
  du code, alors que la vue d'export FCEN `v_fcen_parcelle_cen_04` la lit pour
  sa colonne `source_geom_parc_nature` : les 1 264 lignes de l'export sortaient
  donc sans source déclarée. La valeur découle du type de parcelle — plan
  cadastral informatisé pour une parcelle cadastrale, numérisation manuelle CEN
  pour un polygone dessiné — et est posée par les trois chemins de création
  (association au site, polygone manuel, ajout à la zone d'intérêt).

### Corrigé
- Les quatre chemins de suppression de parcelle purgent la nouvelle liaison
  avant de supprimer la parcelle. Sa clé étrangère est en `NO ACTION` : sans
  cette purge, toute suppression de parcelle aurait échoué dès la première
  source enregistrée.
- Le seuil d'affichage du cadastre annoncé dans les notes de la 1.4 était le
  zoom 17 ; c'est le zoom 16 (`ZOOM_CADASTRE_MIN`).

## [1.4] — 2026-10-12

### Ajouté
- **L'infobulle d'un périmètre manuel montre aussi la parcelle cadastrale
  survolée.** Le périmètre est dessiné au-dessus du cadastre et interceptait
  seul le survol : on ne pouvait pas savoir sur quelle parcelle on se trouvait
  sans le masquer. Les deux blocs s'affichent désormais dans la même bulle,
  séparés d'un filet, et la partie cadastrale suit le curseur de parcelle en
  parcelle. La résolution se fait dans les données déjà chargées par le
  navigateur, sans requête supplémentaire. Elle suppose donc que le cadastre
  soit affiché : en dessous du zoom 16, où la couche n'est pas chargée, ou si
  elle est décochée dans le contrôle des couches, l'infobulle reste celle du
  périmètre seul.

### Documentation
- La création de la **Release GitHub** entre dans la procédure de release de
  `CONTRIBUTING.md`. Un tag git et une Release GitHub sont deux objets
  distincts : faute de cette étape, le panneau « Releases » du dépôt affichait
  encore v0.89 alors que les tags allaient jusqu'à v1.3. Les notes sont reprises
  du CHANGELOG plutôt que générées depuis les messages de commit.

## [1.3] — 2026-09-04

### Modifié
- **Le sélecteur de propriétaire suit l'emprise de la carte.** À la création
  d'une action, il proposait tous les propriétaires du site et de la zone
  d'intérêt, quelle que soit la zone regardée ; il ne garde plus que ceux dont
  une parcelle est à l'écran, et se met à jour au déplacement comme au zoom.
  Le dictionnaire filtré sert aussi à la sélection : choisir un propriétaire ne
  prend que ses parcelles visibles, jamais des parcelles hors champ que
  personne n'a vues.

### Corrigé
- **Un propriétaire en zone d'intérêt était refusé en bloc.** Le message
  « Aucune des parcelles de ce propriétaire n'a de contrat commun avec les
  autres » s'affichait pour des propriétaires parfaitement sélectionnables au
  clic : la règle exigeait un contrat commun à toutes leurs parcelles, zone
  d'intérêt comprise, alors que celles-ci n'ont aucun contrat — c'est leur
  objet même, la pré-acquisition — et que le clic parcelle par parcelle les
  exempte déjà. Une seule suffisait donc à vider l'intersection. Le cas suit
  maintenant la même règle que le clic : les parcelles de la zone d'intérêt
  sont toujours prises, celles du site restent soumises au contrat commun entre
  elles. Sur les cinq sites concernés, les 47 refus mesurés tombent à zéro,
  tandis que les refus légitimes des sites sans zone d'intérêt sont inchangés.

## [1.2.1] — 2026-09-03

### Modifié
- **Tableau des actions : plus de boîte de recherche globale.** Les filtres par
  colonne, sous les en-têtes, couvrent déjà le besoin. Pagination et compteur
  de lignes sont conservés.


## [1.2] — 2026-09-03

L'onglet Actions travaille désormais depuis la carte : le tableau des actions
l'accompagne et suit ce qu'on regarde, la sélection se fait au clic sur une
parcelle ou par des cases à cocher, et la création d'une action tient en deux
étapes au lieu de trois.

### Ajouté
- **Tableau des actions sous la carte.** Il liste les actions dont au moins une
  parcelle se trouve dans l'emprise affichée, et se met à jour au déplacement
  comme au zoom. Il reprend les colonnes, les icônes et les filtres de la vue
  liste, qui disparaît dans cette même version. Le filtre spatial travaille sur
  les géométries déjà chargées pour le dessin, si bien qu'un déplacement ne
  coûte aucune requête ; l'emprise est débouncée à 500 ms comme l'est le zoom.
- **Sélection d'actions par cases à cocher.** Cocher une ou plusieurs actions
  cercle leurs parcelles d'un trait rouge, non interactif pour ne masquer ni
  les infobulles ni les clics dessous. La sélection est tenue côté serveur — DT
  ne garde dans le DOM que la page affichée — et un lien « Tout décocher » sous
  le titre la vide d'un coup. Une action cochée le reste si elle sort de
  l'emprise, ses parcelles restant en évidence pendant qu'on se déplace.
- **Confirmation avant la suppression d'une action.** Elle annonce le numéro de
  l'action et le nombre de documents joints qui partiront avec elle, fichiers
  compris. « Annuler » rouvre le formulaire d'édition, sans quoi l'annulation
  ramenait à la liste — indistinguable d'une suppression réussie.

### Modifié
- **Le clic sur une parcelle filtre le tableau** au lieu d'ouvrir une modale :
  il ne montre plus que les actions de cette parcelle, cerclée en violet, et le
  tableau cesse alors de suivre l'emprise — un déplacement viderait sinon la
  liste qu'on vient d'ouvrir. On revient à l'emprise en recliquant la même
  parcelle ou par le lien du titre. Les deux filtrages sont exclusifs dans les
  deux sens : cocher une action relâche la parcelle, cliquer une parcelle
  décoche les actions.
- **Création d'une action en deux étapes.** La section « 📎 Documents » rejoint
  la modale des détails, comme elle l'est déjà en édition : la pièce jointe
  choisie est enregistrée par « Créer l'action », qui insère l'action puis lui
  rattache le fichier. La troisième modale disparaît. L'uploader est remis à
  zéro à l'ouverture, sans quoi un fichier resté sélectionné lors d'une édition
  précédente aurait été joint à la nouvelle action.

### Supprimé
- **Sélecteur Carte/Liste.** Le mode liste ne montrait plus rien de plus depuis
  que le tableau accompagne la carte : dézoomer sur le site entier redonne la
  liste complète de ses actions. Les cinq dépendances serveur au mode ont été
  retirées avec lui — laissées en place, elles auraient comparé `NULL` à
  `"map"`, et plus rien ne se serait dessiné sur la carte.

### Corrigé
- **Un clic sur la carte était avalé après avoir fait défiler la page.** Le
  handler clavier de Leaflet rend le conteneur focusable et, au `mousedown`,
  lui donne le focus avant de rattraper le défilement par `window.scrollTo`. Or
  le défilement appartient ici à `.right-rail-inner`, pas à la fenêtre : le
  conteneur sautait pour rendre la carte visible, le contenu se déplaçait entre
  `mousedown` et `mouseup`, et aucun clic n'était émis — il fallait cliquer
  deux fois. Le handler est désactivé sur les trois cartes d'onglet.
- **La fiche 👁 d'une action n'affichait jamais les « Utilisateurs (CEN) ».**
  Elle lisait une colonne `label` que le dictionnaire des utilisateurs nomme
  `nom_complet` ; le filtre renvoyait donc toujours un vecteur vide. Les
  libellés sont maintenant fabriqués comme dans le tableau et le rapport PDF,
  par une jointure externe qui montre aussi les utilisateurs devenus inactifs.
- **`ns()` en trop dans cinq mises à jour d'input** (Actions, Contrats) :
  `session` étant déjà celle du module, elles visaient des inputs inexistants.
  Après l'ajout d'une pièce jointe, « Type de document » et « Remarque »
  gardaient leurs valeurs ; effacer une date de rupture laissait en place la
  remarque associée, dont le champ est pourtant masqué sans date. Aucune trace
  en base : les chemins d'écriture forcent déjà `NULL` dans ce cas.

## [1.1.2] — 2026-08-18

### Corrigé
- **Statut des documents de gestion : mauvais dictionnaire.**
  `doc_gestion.statut_id` a pour cible `dico_statut_doc_gestion` (1 Actif,
  2 Archivé, 3 En cours d'élaboration), mais le module travaillait avec
  `dico_type_statut_contrat` (1 En cours d'élaboration, 3 Actif, 4 Suspendu,
  5 Terminé, 6 Résilié), qui donne un sens différent aux mêmes identifiants.
  Deux conséquences : « Suspendu », « Terminé » et « Résilié » n'existent pas
  dans la table cible, les choisir violait la clé étrangère — aucun document
  n'a donc jamais pu être clos depuis l'interface ; et les deux autres valeurs
  passaient en s'inversant, si bien qu'un document saisi « Actif » était lu
  « En cours d'élaboration » par tout consommateur suivant la clé étrangère.
  Le statut était lu à trois endroits — menu du formulaire, fiche, tableau —
  tous corrigés. **La migration des données est indissociable de ce
  correctif** : voir `scripts/fix_statut_doc_gestion.sql`, à exécuter dans la
  même fenêtre que le déploiement.

### Supprimé
- **`pipeline/`**, qui alimentait TerraCEN-view. MapCen l'a remplacé et
  versionne ses propres scripts. Le dossier reste présent sur le serveur
  interne, où MapCen dépose les siens pour trouver le `.Renviron` — c'est du
  déploiement, pas de l'appartenance. Il passe au `.gitignore`, ce qui
  supprime la cause du blocage récurrent de `deploy.sh`.

## [1.1.1] — 2026-08-03

### Modifié
- **« Périmètre élargi » devient « Zone d'intérêt »** dans toute l'interface :
  couche cartographique et sa légende, boutons d'ajout et de retrait, compteur
  de sélection, fiches, modales, messages et résumé du site. Les libellés qui
  désignaient le même objet en disant seulement « périmètre » suivent.
  Restent inchangés « Nature du périmètre », attribut administratif du site, et
  les « Périmètres manuels », qui sont les polygones dessinés à la main — une
  couche distincte.

## [1.1] — 2026-08-03

Le résumé d'un site chiffre désormais son parcellaire, et la bascule d'une
parcelle du périmètre vers le site réclame un contrat comme le fait déjà
l'ajout de parcelles.

### Ajouté
- **Parcellaire dans le résumé du site** : nombre de parcelles du site et leur
  surface, en regard de celles du périmètre élargi, et une ligne de surface
  totale. Les trois surfaces reposent sur la même base — surface cadastrale, ou
  surface de la géométrie pour une parcelle dessinée à la main — et non sur la
  part maîtrisée, pour que le total ait un sens.

### Modifié
- **Bascule du périmètre élargi vers les parcelles du site** : la modale
  présente le sélecteur de contrat de l'ajout de parcelles, avec la même
  pré-sélection du contrat de préfiguration. Le rattachement se fait dans la
  même transaction que la bascule. Auparavant l'opération produisait des
  parcelles de site sans contrat, ce que l'ajout de parcelles interdit.
- **Icônes d'action des tableaux** : les cinq scripts de clic des modules sont
  remplacés par un gestionnaire unique dans `www/app.js`. L'élément porte
  l'input visé dans `data-input`, ses autres `data-*` deviennent les champs du
  message.

### Corrigé
- **Résumé du site figé** : il ne se recalculait pas après une écriture de
  parcelle — ajouter une parcelle laissait les chiffres inchangés jusqu'au
  changement de site. Trois causes distinctes, dans Sites, Parcelles et
  Actions ; les trois sorties suivent maintenant le canal commun déjà notifié
  par tous les chemins d'écriture.
- **Surface du périmètre avec une parcelle manuelle** : elle n'était comptée
  que par le cadastre, donc omise du total. `parcellaire_id` désigne deux
  tables selon `type_parcelle_id`, ce que les jointures ignoraient — un site
  dont l'unique parcelle est manuelle affichait « 0 parcelle ».

## [1.0.2] — 2026-08-02

Deux corrections : l'affichage d'un site n'ayant que du périmètre élargi, et
l'accumulation de processus R qui a saturé le serveur.

### Corrigé
- **Parcelles d'un site sans aucune parcelle de site** : elles n'apparaissaient
  pas. Le calcul du cadrage ne connaissait que deux jeux de données, les
  parcelles du site et les périmètres manuels ; les parcelles du périmètre
  élargi, troisième jeu depuis la fusion de 0.98, n'y avaient pas été ajoutées.
  Faute d'emprise, la carte effaçait la couche et revenait à la vue par défaut —
  la couche était bien redessinée ensuite, mais loin du cadrage. L'arrivée
  depuis un autre onglet et le chargement des parcelles cadastrales sur
  l'emprise du site sont réparés du même coup.
- **`deploy.sh` termine les processus R rendus obsolètes** par le déploiement.
  Combiné à `app_idle_timeout 0` — qui garde l'application chaude mais empêche
  shiny-server de récupérer un processus même sans connexion — chaque
  déploiement laissait un processus de ~400 Mo à demeure. Huit s'étaient
  accumulés le 2026-08-02 et ont saturé la mémoire du serveur, jusqu'à bloquer
  PID 1 et SSH. Les processus sont recensés *avant* le `touch restart.txt`,
  pour ne jamais viser celui qui démarrera ensuite, et distingués par leur
  répertoire de travail — la ligne de commande est identique pour test et prod.
  `DEPLOY_KILL_STALE=0` désactive le comportement.

## [1.0.1] — 2026-08-02

Complète l'uniformisation des tableaux livrée en 1.0 : les deux derniers,
Acteurs et Utilisateurs, y étaient restés au clic sur la ligne.

### Ajouté
- **Fiches de consultation** 👁 pour les acteurs et les utilisateurs, avec le
  même bouton « ✏️ Modifier » que les trois autres. Elles montrent les
  coordonnées, le type et les contrats associés pour un acteur ; l'état du
  compte, les droits d'administrateur et les rôles par site pour un
  utilisateur.

### Modifié
- **Tableaux Acteurs et Utilisateurs** : deux colonnes d'action en tête de
  ligne (👁 puis ✏️, 24 px), le clic sur la ligne n'ouvre plus rien. Les deux
  onglets étant déjà réservés — Utilisateurs aux administrateurs, Acteurs aux
  AD/RS/AN — le crayon est visible par tous ceux qui voient le tableau.
- **Tableau Acteurs** : les colonnes Adresse, Téléphone et Contrats sont
  retirées de la grille, où elles tenaient mal ; l'information reste entière
  dans la fiche, où les contrats s'affichent désormais en liste à puces.

### Corrigé
- **Mise à jour et suppression d'un utilisateur**, qui lisaient encore la ligne
  sélectionnée du tableau : sans sélection possible, elles n'auraient plus rien
  visé. L'enregistrement vient maintenant de l'identifiant porté par l'icône.

## [1.0] — 2026-08-02

Première version stable. Uniformisation des tableaux et de leurs modales,
remise en service de l'export PDF des actions.

### Ajouté
- **Fiches de consultation** ouvertes par une icône 👁, dans les trois tableaux
  (Contrats, Documents de gestion, Actions). Elles rassemblent toutes les
  informations de l'enregistrement et proposent un bouton « ✏️ Modifier » qui
  bascule directement vers le formulaire. Pour les contrats : statut, type,
  sites concernés avec leur nombre de parcelles, acteurs, pièces jointes, URL
  cliquable, dates, auteur et date de dernière modification, remarques.
- **Croix de fermeture** dans l'en-tête de toutes les modales, injectée par
  `www/app.js` — une seule implémentation pour l'application entière.
- **Parcelles du périmètre élargi** : la modale affiche la commune, la surface
  cadastrale et le ou les propriétaires (masqués pour les invités, comme
  partout ailleurs).

### Modifié
- **Tableaux Contrats, Docs de gestion et Actions** : deux colonnes d'action en
  tête de ligne (👁 puis ✏️, 24 px), le crayon n'apparaissant qu'aux
  utilisateurs habilités. Le clic sur la ligne n'ouvre plus rien : les actions
  sont explicites. Colonnes de dates retirées de Contrats et Docs de gestion,
  elles restent visibles dans la fiche et le formulaire.
- **Modales** : fermeture au clic à l'extérieur, sauf pour les deux étapes de
  l'assistant de création d'action, où une saisie serait perdue. Les boutons
  « Fermer » et « Annuler » redondants avec la croix sont supprimés ; ceux qui
  font face à une suppression ou une confirmation sont conservés, pour que la
  sortie sûre reste aussi visible que l'action risquée.
- **Parcelles du périmètre élargi** : la modale ne permet plus de modifier que
  la remarque. Les caractéristiques de maîtrise (BND, source, échelle,
  propriétaire, ZPF, chasse) n'ont de sens qu'à la bascule vers le site.
- **Actions** : l'export PDF ne figure plus que dans la fiche de consultation.

### Corrigé
- **Export PDF des actions**, hors service : quatre causes distinctes,
  diagnostiquées en compilant à la main le `.tex` conservé dans
  `Docs/_debug_rapports/`.
  - le paquet LaTeX `enumitem` est défaillant sur le serveur (ses internes sont
    introuvables à l'exécution alors que le fichier est complet et unique) : la
    dépendance est retirée du modèle ;
  - le découpage de la description sur les balises `<table>` pouvait couper une
    liste à puces en deux : chaque fragment est désormais équilibré ;
  - le modèle écrit du LaTeX dans du Markdown que Pandoc reconvertit ; faute de
    lignes vides délimitant les blocs bruts, Pandoc déplaçait les fermetures.
    Le groupe fautif est supprimé et les tableaux sont émis d'un seul bloc ;
  - les descriptions collées depuis Word ou Outlook portent des attributs
    `lang="FR"` que Pandoc traduit en `\foreignlanguage{french}`, refusé par
    babel : ces attributs sont retirés avant conversion.
- **Erreurs client Shiny** sur les tableaux Contrats et Docs de gestion
  (« unexpected state of: running / idle ») : le chargement paresseux écrivait
  un réactif pendant le rendu, ce qui invalidait le rendu en cours. Remplacé
  par un `reactive()` mémoïsé.
- **Déploiements bloqués** : `www/rapport_action.log`, réécrit à chaque export,
  était versionné et faisait échouer `deploy.sh`. Les journaux LaTeX sortent du
  suivi git.

### Supprimé
- `www/rapport_animation.Rmd.save`, sauvegarde d'éditeur sans usage.

## [0.99] — 2026-08-02

Corrections issues d'un audit du code, appliquées une par une et vérifiées
individuellement (une première tentative de livraison en bloc a été annulée).

### Ajouté
- **Contrats fonciers : champ URL** — il n'avait jamais existé dans le
  formulaire, alors que le code d'écriture le lisait depuis l'origine ; la
  colonne était donc remplie de chaînes vides. Saisie en création et en
  édition, valeur pré-remplie depuis la base, `NULL` si le champ est vide.
- **Contrats : colonne 🔗** dans le tableau, lien cliquable vers le document
  associé (nouvel onglet), à côté des icônes carte et pièces jointes.

### Corrigé
- **Contrats — perte silencieuse de liaisons multi-sites** : le modal 🗺️
  n'initialisait la sélection qu'avec les parcelles des sites éditables mais
  supprimait les liaisons du contrat sur TOUS les sites. Un responsable d'un
  seul site détruisait celles des autres en cliquant « Enregistrer ».
- **Cartes : couches invisibles au retour sur un site** — désélectionner puis
  re-sélectionner le même site laissait la carte vide (le court-circuit par
  empreinte croyait la couche encore affichée). Vérifié : 268 parcelles
  perdues puis retrouvées.
- **Traçabilité** : Contrats et Docs de gestion enregistraient le compte
  système du serveur dans `cree_par`/`modifie_par` au lieu de l'utilisateur.
- **Parcelles : fuite de données personnelles** — le popup Maj-clic affichait
  le nom du propriétaire cadastral aux invités, que les infobulles masquent.
- **Docs de gestion** : les liaisons aux sites étaient réécrites à chaque
  enregistrement (comparaison portant sur une colonne inexistante), ce qui
  redatait le document et faussait l'onglet Activité.
- **Contrats : url effacée** à chaque édition (champ de formulaire absent).
- **Formulaires d'édition : bouton « Mettre à jour » bloqué** — il restait
  désactivé à la réouverture d'un même enregistrement, empêchant d'enregistrer
  une modification portant sur un champ non obligatoire.
- **Rafraîchissements après création d'un site** : sélecteur de sites de
  l'onglet Parcelles, et contrat de préfiguration absent des listes.
- **Actions** : l'enregistrement des parcelles n'était pas transactionnel — un
  échec pouvait vider l'action de ses parcelles en annonçant un succès.

### Performance
Chaque point mesuré avant et après ; trois recommandations de l'audit ont été
écartées parce que les mesures les ont infirmées.
- Parcelles d'une action : 87 requêtes → 3 (résolution groupée + transaction).
- Contrats : la requête d'union du tableau ne part plus deux fois par action.
- Actions : la requête la plus lourde du module ne repart plus à chaque
  écriture pour repeindre un modal fermé ; géométries simplifiées (−28 %).
- Contrats et Docs de gestion : chargement au premier affichage de l'onglet,
  et non plus à l'ouverture de chaque session.
- Périmètre élargi : plus redessiné à chaque déplacement de carte (48
  polygones par pan) — il a désormais son propre calque, l'empilement est
  inchangé.
- Carte du modal Contrats : elle n'était plus invalidée à chaque cycle
  réactif de la session (−1/3 des redimensionnements globaux par déplacement).

## [0.98.2] — 2026-08-01

### Corrigé
- **Infobulles orphelines** : une infobulle de parcelle pouvait rester
  affichée quand la couche était redessinée pendant le survol (le polygone
  recréé ne reçoit jamais le « mouseout » de son prédécesseur). Les redraws
  ajoutés en v0.98 — périmètre élargi (Sites, Parcelles) et carte de l'onglet
  Actions — ferment désormais les infobulles au préalable, comme les dessins
  historiques.

## [0.98.1] — 2026-08-01

### Corrigé
- **Sites : re-sélection invisible après « Vider la sélection »** — le bouton
  vidait l'état et les couches sans invalider le cache incrémental de la
  couche « Parcelle sélectionnée » : re-sélectionner la même parcelle passait
  en fast-path « déjà dessinée » (compteur juste, aucune parcelle en rouge).

### Modifié
- **Sites/Parcelles : périmètre élargi en hachures bleues** — même bleu que
  les parcelles du site (bordure, diagonales, légende) ; la distinction
  site/périmètre est portée par le motif (plein vs hachuré). Les cartes des
  Actions conservent les hachures oranges.
- **Actions : légende détaillée à 4 entrées** — parcelle du site / périmètre
  élargi × avec / sans action, avec pastilles hachurées à bordure colorée
  reflétant le rendu de la carte.

## [0.98] — 2026-08-01

### Modifié
- **Fusion du modèle de parcelles** : `parcelles_perimetre` est fusionnée dans
  la table physique `parcelles_base` (colonne `perimetre`), avec une **vue de
  compatibilité `gestcons.parcelles`** (filtrée) préservant à l'identique tout
  le code existant, les 5 vues SQL (dont les exports FCEN, recréées) et la
  prod pendant la transition. Migration par script SQL local (transaction
  unique, dry-run, vérifications par comptes ; trigger d'audit adapté).
  Unicité : index partiels reproduisant les règles des deux anciennes tables.
- **L'onglet Stratégie est supprimé** ; ses fonctionnalités sont intégrées à
  l'onglet **Sites** : couches « Périmètre élargi » et « Contour » (masqué par
  défaut) visibles par tous, actions réservées AD/RS du site — la sélection
  cadastrale alimente deux boutons (« 💾 Ajouter au site », « 🎯 Ajouter au
  périmètre »), clic sur une parcelle orange → Basculer en parcelles du site /
  Retirer / Remarque. La **bascule** est un simple UPDATE : la parcelle garde
  son id, son historique (actions...) la suit automatiquement. Résumé du site
  avec ligne « Périmètre élargi » (nb + surface).

### Ajouté
- **Actions sur les parcelles du périmètre élargi** (foncier ET agricole) :
  elles apparaissent sur les trois cartes des Actions et sont **exemptées de
  la règle « contrat requis »** (animation pré-acquisition). Les listes,
  compteurs, filtres par site, rapport PDF et l'onglet Activité en tiennent
  compte.
- **Édition des parcelles du périmètre dans l'onglet Parcelles** : clic sur
  une parcelle orange → modale avec les mêmes champs que les parcelles du
  site + remarque ; les valeurs saisies sont conservées à la bascule.
- **Distinction visuelle du périmètre** : remplissage en **hachures** oranges
  (motif SVG, toutes cartes) avec légendes assorties, et infobulles indiquant
  le type (📍 Parcelle du site / 🎯 Périmètre élargi) et la commune.

### Corrigé / Ergonomie
- Sélections de l'onglet Sites : exclusivité entre sélection de candidates,
  sélection du périmètre et actions sur les parcelles du site ; le clic sur le
  cadastre refuse les parcelles déjà site/périmètre (couches masquées
  comprises) ; garde de zoom sur le rectangle et nettoyage systématique de la
  forme dessinée ; boutons du périmètre alignés à droite.
- Rafraîchissement inter-onglets : toute écriture sur le périmètre notifie le
  canal commun (`contrats_update_trigger`) — Sites, Parcelles et Actions
  restent synchrones sans recharger la page.
- Résumé du site : plantage `integer64` (count/sum bigint) corrigé.

### Technique
- Cache des assets : `app.js`/`app.css` versionnés par version **et** date de
  modification — les déploiements test livrent du JS/CSS frais sans release.

## [0.97] — 2026-07-18

### Modifié
- **Gestion des pièces jointes intégrée à la modale (Actions et Contrats).**
  Plus de lien 📎 séparé dans les tableaux (la colonne devient un simple
  compteur) : on ouvre la modale de l'action / du contrat, qui regroupe les
  infos **et** les documents. Le bouton unique (« Enregistrer » / « Mettre à
  jour ») enregistre les infos **et** la pièce jointe éventuellement chargée.
  La suppression d'une PJ — et la mise à jour — laissent désormais la modale
  ouverte (retrait des spinners modaux qui la refermaient).

### Ajouté
- **`pipeline/`** — briques d'un futur export de données pour une appli de
  visualisation publique (extraction curée depuis `gestcons` → GeoJSON, push
  par rsync ; le viewer public ne touche jamais la base). Non branché à
  l'appli TerraCEN.

## [0.96.1] — 2026-07-13

### Technique
- Retire la trace « Sites : fin du traitement » émise à chaque changement de
  calques de la carte — bruit qui polluait les nouvelles lignes de
  connexion/action dans les logs.

## [0.96] — 2026-07-13

### Ajouté
- **Traçabilité des modifications dans les logs serveur** : chaque action
  (création/modification/suppression de sites, parcelles — dont édition en
  masse —, actions foncières/agricoles, contrats, docs de gestion, acteurs,
  utilisateurs, périmètre élargi, pièces jointes, liaisons) écrit une ligne
  horodatée avec l'utilisateur, son adresse IP et une description :
  `2026-07-13 10:22:33 - [email @ ip] Création du site « X » (id 123)`.
  Identité effective (profil emprunté en impersonation, comme `modifie_par`).
  Complète la table `audit_log` (détail structuré par table/ligne/site) et le
  journal des connexions.

## [0.95.3] — 2026-07-13

### Technique
- **Logs serveur : une ligne horodatée par connexion utilisateur**
  (`2026-07-13 09:15:32 - Connexion : email (ip)`), émise une seule fois par
  session, sur l'identité réelle — en cohérence avec la table `connexion_log`.
  Remplace l'ancienne trace « Utilisateur : … » écrite à chaque évaluation et
  sans horodatage.

## [0.95.2] — 2026-07-13

### Corrigé
- **Sites : la sélection par rectangle affichait parfois des parcelles hors
  de l'emprise.** Une sélection antérieure, vidée à l'écran mais conservée en
  mémoire par certains chemins de nettoyage incomplets, ressurgissait au
  rectangle suivant (ou au déplacement de carte). Tous les chemins passent
  désormais par le vidage complet (état + affichage + cache). Le toast affiche
  en outre le cumul (« n ajoutée(s) — m sélectionnée(s) au total »), la
  sélection s'additionnant volontairement d'un rectangle à l'autre.

## [0.95.1] — 2026-07-12

### Ajouté
- **Stratégie : message « 🔍 Zoomez davantage pour afficher les parcelles
  cadastrales »** quand un site est sélectionné mais le zoom insuffisant —
  même rendu que dans l'onglet Sites (mécanisme factorisé dans les helpers,
  Sites inchangé visuellement).

## [0.95] — 2026-07-12

### Corrigé
- **Actions : bouton « Créer l'action » / « Enregistrer » grisé à tort** dès la
  deuxième ouverture d'une modale dans la session, malgré des champs valides.
  Les boutons naissent désormais actifs (les champs obligatoires ont toujours
  une valeur par défaut) et se grisent si un champ est vidé.
- **Suppression d'une action agricole : les pièces jointes n'étaient jamais
  purgées** (lignes en base et fichiers orphelins).
- **Suppression d'une action foncière : le dossier `animation_<id>` entier
  était supprimé**, détruisant les PJ d'une action agricole de même id
  numérique (séquences distinctes). Suppression fichier par fichier désormais.
- **Création d'une action agricole : la modale des pièces jointes (étape 3)
  ne s'ouvrait pas** (foncier uniquement). Elle s'ouvre pour les deux domaines,
  et le type est correctement positionné (une PJ ajoutée après création
  pouvait partir dans la table de l'autre domaine).

### Modifié
- **Modales de pièces jointes** (Actions, Contrats) : bouton « 📤 Enregistrer »
  déplacé dans le pied de modale à côté de « Fermer » ; « 🗑 Supprimer le
  document sélectionné » désactivé tant qu'aucune ligne n'est sélectionnée.
- **PJ d'actions : sous-dossiers typés `animation_F_<id>` / `animation_A_<id>`**
  (comme les contrats) — fini le dossier partagé entre foncier et agricole.
  Migration de l'existant : `scripts/migrate_animation_docs.R` (à lancer une
  fois sur le serveur, depuis l'instance hébergeant `Docs/`).

### Technique
- **Audit phases 3-4** : composant « documents joints » commun Actions/Contrats
  (fetch/upload/suppression/tableau paramétrés, helpers.R) ; fusion des paires
  foncier/agricole — requêtes jumelles des parcelles de contrat, transactions
  de création d'animation, réécriture des tables de liaison (~220 lignes en
  moins, comportement identique).

## [0.94.1] — 2026-07-12

### Technique
- **Nettoyage suite à l'audit code propre** (aucun changement fonctionnel,
  −224 lignes) :
  - code mort supprimé (6 reactiveVal jamais lues, blocs commentés obsolètes,
    redéfinitions locales de `.is_blank`/`%||%`) ;
  - traces de développement retirées (`print()`/`message()` bruts) ou
    converties en `debug_print` (visibles seulement avec `TERRACEN_DEBUG`) ;
  - constantes partagées : vue carte par défaut (`MAP_DEFAULT_*`, en dur 10×
    auparavant), plafond de sélection rectangle (`MAX_PARCELLES_RECTANGLE`) ;
  - micro-helpers `clear_groups()` et `reset_dt_selection()` ;
  - **CSS/JS inline d'`app.R` migrés vers `www/app.css`/`www/app.js`**
    (~190 lignes : styles barre utilisateur/impersonation/écrans, handler
    tooltips, keep-alive). Le bump de version force le rechargement des
    assets par les navigateurs.

## [0.94] — 2026-07-11

### Ajouté
- **Onglet Stratégie : légende sur la carte** (même style que Sites/Parcelles) :
  statuts du contrat foncier des parcelles du site + calques propres à
  l'onglet (périmètre élargi orange, contour violet). Affichée à la sélection
  d'un site, retirée à la désélection.

### Technique
- **Grande passe de factorisation** (~350 lignes en moins, rendu identique) :
  - `add_map_legend` : moteur unique des légendes de carte (Sites, Parcelles,
    Actions, Stratégie deviennent de simples déclarations titre + couleurs) ;
  - `sql_proprio_label()` : l'expression SQL du libellé propriétaire, recopiée
    dans 11 requêtes, canonisée sur la variante la plus robuste (btrim) ;
  - `set_tab_visible()` : remplace les 6 blocs jQuery de masquage d'onglet
    selon les rôles ;
  - `make_user_to_db()` et `make_refresh_sites_choices()` : reactives/fonctions
    dupliqués dans 4 et 2 modules ;
  - `get_bbox_4326()` / `site_bbox_4326()` : emprises calculées côté PostGIS —
    corrige au passage l'emprise partagée inter-onglets, qui passait par une
    requête lourde et ignorait les périmètres manuels ;
  - `add_std_draw_toolbar()` : les 6 configurations de barre de dessin.

## [0.93.1] — 2026-07-11

### Ajouté
- **Bouton plein écran (⛶) sur toutes les cartes d'onglet** (Sites, Parcelles,
  Actions, Stratégie), via `init_map_base`. Mode « pseudo plein écran » : la
  carte remplit la fenêtre du navigateur ; les modales et toasts restent
  utilisables par-dessus (z-index relevé). Sortie par Échap ou re-clic. Les
  cartes des modales d'Actions ne sont volontairement pas concernées.

## [0.93] — 2026-07-11

### Ajouté
- **Nouvel onglet « 🎯 Stratégie foncière »**, réservé aux administrateurs :
  gestion du **périmètre élargi** d'un site — parcelles cadastrales ne faisant
  pas partie du site mais présentant un intérêt. Interface calquée sur
  l'onglet Parcelles :
  - sélection d'un site (sélecteur partagé), affichage de ses parcelles et du
    périmètre élargi (orange), cadastre à partir du même zoom que Sites ;
  - sélection des parcelles candidates par **clic**, par **rectangle** ou par
    **propriétaire** (parcelles du site et déjà au périmètre exclues) ;
  - ajout en lot au périmètre, **remarque** et retrait par modal au clic sur
    une parcelle orange (infobulle au survol : parcelle, propriétaire,
    surface) ;
  - **contour englobant** (violet tireté) : union PostGIS exacte des parcelles
    du site + périmètre élargi, sans jamais englober une parcelle étrangère ;
  - résumé en colonne de gauche : blocs **Site** et **Périmètre** (nombre de
    parcelles et surface, le second cumulant site + élargi).
- Stockage dans la nouvelle table `gestcons.parcelles_perimetre` (site_id,
  parcellaire_id, remarque, type, traçabilité ; unique par site ; auditée),
  créée hors dépôt.

### Technique
- **Infobulles de parcelles factorisées** dans `.cf_make_labels` (paramètre
  `fields`, normalisation des alias de colonnes `dcntpa`/`idcomtxt`) : sortie
  historique inchangée pour les appelants existants, censure des propriétaires
  (démo/invité) désormais appliquée partout mécaniquement.

## [0.92.1] — 2026-07-10

### Technique
- **Démarrage** : les ~25 chargements globaux (dictionnaires, zones de
  protection, valeurs par défaut, liste des sites, communes) sont regroupés
  dans une fonction `load_referentiels()` (`R/helpers.R`), réinjectés sous
  leurs noms historiques via `list2env` — aucun changement fonctionnel. La
  durée totale des chargements est désormais loguée à chaque démarrage.
- Retrait de `library(ggplot2)`, chargé mais utilisé nulle part (les graphes
  de l'onglet Activité utilisent plotly) : démarrage du process plus léger.
- Pour mémoire, côté serveur (hors dépôt) : `app_idle_timeout 0` recommandé
  pour l'instance de prod dans `shiny-server.conf`, afin que le process R
  reste chaud et que les utilisateurs ne subissent plus le démarrage.

## [0.92] — 2026-07-06

### Modifié
- **Onglet Activité : barre « Modifications » unique** (remplace « Modifs de
  parcelles »). Elle est désormais alimentée par un **journal d'audit**
  (`gestcons.audit_log`, action `UPDATE`) au lieu de `parcelles.date_modification` :
  comptage **exact de chaque modification** (l'ancienne ne voyait que la dernière
  modif de chaque parcelle) et couverture de **toutes les tables auditées**
  (sites, parcelles, docs de gestion, responsables, animateurs, statuts).
  Filtrable et détaillée **par site**. Non rétroactive : se remplit à partir de
  la pose des triggers d'audit en base ; dégradation propre (0) si le journal est
  vide ou non lisible.

## [0.91] — 2026-07-06

### Ajouté
- **Onglet Activité : nombre de connexions à l'application** ajouté comme 5ᵉ
  métrique de l'histogramme mensuel (et dans les totaux), comptée depuis
  `gestcons.connexion_log`. C'est une métrique **globale** : les connexions
  n'ayant pas de rattachement à un site, elle n'apparaît qu'en vue globale et
  disparaît (barre et total) dès qu'un site est sélectionné. Dégradation propre
  (affiche 0) si la table est vide ou non lisible par l'utilisateur applicatif.

## [0.90] — 2026-07-06

### Ajouté
- **Journalisation des connexions à l'application** : à chaque session, une ligne
  est enregistrée dans `gestcons.connexion_log` (user_id, email, ip,
  date_connexion) dès que le vrai utilisateur est identifié — une seule fois par
  session, toujours sur l'identité réelle (jamais l'identité empruntée en
  impersonation). Permet de comptabiliser l'usage (total, par jour, par
  utilisateur, utilisateurs uniques) par simples requêtes SQL. L'insert est en
  échec silencieux pour ne jamais bloquer l'accès. Note : Test et Prod partageant
  la base, leurs connexions ne sont pas distinguées (pas de colonne d'instance).

## [0.89.3] — 2026-06-30

### Corrigé
- **Onglet Parcelles : la sélection de parcelles est désormais vidée** lors d'un
  changement d'onglet, d'un changement de site, ou d'une réinitialisation.
  Auparavant seules la dé-sélection et la réinitialisation vidaient la
  sélection ; un changement de site (A→B) ou de simple onglet la conservait.
  Factorisé dans une fonction `clear_selection()` (état + calque carte + cache),
  exposée au niveau applicatif comme pour l'onglet Sites.

## [0.89.2] — 2026-06-30

### Corrigé
- **Onglet Sites : carte très lente à s'afficher (>6 s) à chaque entrée.**
  L'overlay « Chargement de la carte… » (propre à cet onglet) ne se levait qu'à
  son filet de sécurité de 12 s : `tcOnViewChange` ré-armait l'attente serveur à
  chaque mouvement de carte, y compris les `setView` programmatiques (changement
  d'onglet) et les `resize` déclenchés par `invalidate-map` — ses conditions de
  masquage ne se stabilisaient jamais. Désormais le cycle n'est ré-armé que sur
  un **geste utilisateur** réel (pan/zoom souris/molette/tactile/clavier) ; les
  mouvements programmatiques sont ignorés, donc l'overlay se lève dès que les
  tuiles sont chargées (~1 s). Filet de sécurité `TC_MAX_MS` ramené de 12 s à
  2,5 s. La carte de fond (OSM/IGN) était déjà dessinée sous le voile pendant
  l'attente ; les cartes Parcelles et Actions n'étaient pas concernées (pas
  d'overlay).

## [0.89.1] — 2026-06-29

### Corrigé
- **Rattachement de parcelle à un site** : `domaine_public_id` était codé en dur
  à `1` dans les deux insertions (parcelle cadastrale et polygone dessiné),
  marquant à tort toutes les parcelles rattachées en « domaine public ». Aligné
  sur le défaut PostgreSQL (`DEFAULT 0`). La case « Domaine public ? » reste
  disponible pour le cocher au cas par cas.

### Technique
- Ajout de `scripts/fix_domaine_public_id.sql` pour corriger les lignes déjà
  en base (diagnostic, sauvegarde réversible, `UPDATE` en transaction,
  vérification).

## [0.89] — 2026-06-21

### Modifié
- Onglet **« Activité »** désormais visible pour les **administrateurs (AD)**,
  les **responsables de sites (RS)** et les **animateurs (AN)** — auparavant
  réservé aux seuls administrateurs. La vue reste **globale (tous sites)** ;
  aucun filtrage par site selon le rôle n'est appliqué. Note : le rôle « AN »
  englobe aussi les conservateurs bénévoles.

## [0.88] — 2026-06-10

### Modifié
- Onglet **« Monitoring » renommé en « Activité »** (libellé uniquement ;
  l'identifiant interne `tab-monitoring` est inchangé).
- **Graphe d'activité rendu interactif** (plotly) : au survol d'une barre, un
  popup affiche le **total** et le **détail par site concerné** (top 8 sites +
  « autres »). Pour les Actions et Contrats, un élément touchant plusieurs sites
  est compté sous chaque site concerné, donc la somme par site peut dépasser le
  total (qui compte l'élément une seule fois).

### Technique
- Ajout de la dépendance **plotly** (`renv.lock`, snapshot réalisé sous R 4.2.2).

## [0.87] — 2026-06-10

### Ajouté
- **Changement de profil (impersonation)**, réservé aux administrateurs : un clic
  sur la pastille de rôle ouvre un menu listant les utilisateurs avec leur niveau
  de droits (AD/RS/AN/IN). L'administrateur agit alors avec les **droits complets
  (lecture et écriture)** de l'utilisateur choisi ; les modifications sont
  enregistrées en son nom. L'option « Mon profil » revient à l'identité réelle,
  avec un indicateur visuel « profil emprunté ». Seul un administrateur réel voit
  le menu (l'identité réelle reste le garde-fou même pendant l'emprunt).

### Corrigé
- Favicon : la référence pointait vers un fichier renommé/inexistant
  (`Ana-Cen-ariège-1.png`). Alignée sur `Ana-Cen-Ariège.png`, noms en forme NFC
  identiques (important sur le serveur Linux, sensible à la casse).

## [0.86] — 2026-06-09

### Ajouté
- **Onglet Monitoring** : visualisation de l'activité des sites sous forme de
  barres groupées. Accès réservé aux administrateurs (AD). Gère proprement le
  cas d'un site sans aucune activité.
- Script de déploiement `deploy.sh` : à lancer en tant qu'utilisateur `shiny`,
  avec deux modes (test = suit `main` HEAD, prod = checkout d'un tag), auto-détectés
  depuis le nom du dossier. Restaure les dépendances via `renv::restore()`,
  recharge l'app via `restart.txt`, locale `C.utf8` imposée et rollback
  automatique en cas d'erreur.

### Documentation
- Ajout d'un `README.md` (présentation, stack technique, configuration,
  déploiement et procédure de release).

## [0.83.1] — 2026-05-26

### Corrigé
- Sélection multiple de parcelles cadastrales dans l'onglet Sites : seule la
  dernière parcelle cliquée restait colorée, les précédentes disparaissaient.
  Régression introduite par le cache incrémental de `draw_parcelles_selectionnees`
  (v0.83) : des `clearGroup("Parcelle sélectionnée")` appelés directement sur le
  `leafletProxy` désynchronisaient le cache, qui croyait ensuite que les anciennes
  parcelles étaient toujours dessinées et ne les redessinait pas. Retrait des
  deux `clearGroup` qui précédaient immédiatement un `draw_parcelles_selectionnees`
  (la fonction gère elle-même les retraits via son cache). Ajout d'un helper
  `clear_selection_cache(map_id, session)` appelé après les 5 resets de carte
  restants, pour garder cache et état Leaflet cohérents.

### Documentation
- `CONTRIBUTING.md` : section *Déploiement sur le serveur* refondue pour
  distinguer la procédure prod (`/srv/shiny-server/TerraCEN`, checkout de tag,
  jamais `git pull`) de la procédure test (`/srv/shiny-server/TerraCEN-Test`,
  `git pull` sur `main`). Ajout de `LANG=C.utf8` (obligatoire avec `sudo -u shiny`
  sinon erreurs d'encodage R) et du `touch restart.txt` explicite.

## [0.83] — 2026-05-25

### Performance
- Tolérance `ST_SimplifyPreserveTopology` adaptée au niveau de zoom Leaflet
  dans `refresh_parcelles_cadastrales`. Nouveau helper `simplify_tolerance(zoom)`
  qui retourne 8m à zoom 14-, 4m à zoom 15, 2m à zoom 16, 1m à zoom 17,
  0.5m à zoom 18, 0.25m à zoom 19+. La bbox du cache porte un attribut `tol`
  pour invalider automatiquement le cache quand on change de palier de
  simplification. Réduit nettement le volume de polygones envoyés au
  navigateur sur les zooms 15-16 (vue large), sans perte visuelle perçue.
- Court-circuit "data inchangée" pour `refresh_parcelles_cadastrales` :
  cette fonction faisait un `clearGroup + addPolygons` à chaque appel
  (pan, zoom dans le même palier), même quand la donnée affichée était
  strictement identique. Application du même pattern que `draw_parcelles_site`
  / `draw_perimetres_manuels` : hash session-scoped sur
  `(sort(idpar), tol_current)` via `digest::digest()` ; si identique au
  dernier rendu → return immédiat, aucun appel à Leaflet. Le clearGroup
  inconditionnel en début de fonction a été déplacé après le hash check.
  Élimine le clignotement visible lors de pan/zoom dans un même palier
  de simplification.

## [0.82] — 2026-05-23

### Modifié
- Factorisation du setup Leaflet des 3 cartes principales (`mod_sites`,
  `mod_parcelles`, `mod_actions::af_map`) dans une nouvelle fonction
  `init_map_base()` de `helpers.R`. Les 4 panes standard (cadastre/site/
  selection/manuels), les 3 fonds de carte (OSM + IGN Cartes + IGN
  Satellites) et la vue par défaut centrée Ariège sont désormais définis
  une seule fois. Les URLs IGN passent par des constantes `IGN_CARTES_URL`
  et `IGN_SATELLITES_URL`. Aucun impact fonctionnel, mais un changement
  de clé API IGN ou de fond ne se fait plus qu'à un endroit.

### Performance
- Cache mémoire pour `draw_circles` (épingles des sites sur la carte) :
  nouvelle fonction `get_sites_coords(con)` dans `helpers.R` qui mémorise
  le résultat de la requête lourde (ST_Union + ST_PointOnSurface +
  subqueries responsable/statut) pendant 30 min par process R. Évite la
  ré-exécution de la requête à chaque changement de zoom (gain attendu
  significatif sur les onglets Sites, Parcelles et Actions, où le re-fetch
  était systématique).
- Invalidation explicite via `invalidate_sites_coords_cache()` ajoutée
  aux 6 points de sauvegarde principaux (création de site, update de
  site, sauvegarde valider_contrat_global, suppression de parcelle ×2,
  suppression de périmètre) pour que les modifications soient visibles
  immédiatement sans attendre l'expiration du TTL.
- Limite connue : le cache est par process R, donc partagé entre les
  sessions d'un même fork mais pas entre forks distincts. Un user A qui
  ajoute un site sera visible pour A immédiatement, et pour les autres
  users d'ici 30 min max (ou plus tôt si l'un d'eux fait une action
  invalidante).
- Cache incrémental session-scoped pour `draw_parcelles_selectionnees`
  (parcelles sélectionnées dessinées en rouge). Au lieu de
  `clearGroup + addPolygons(toutes)` et d'une requête SQL pour toutes
  les parcelles à chaque clic, on calcule désormais le delta vs l'état
  précédent (stocké dans `session$userData$sel_cache`) :
  - Si rien n'a changé (cas typique du pan/zoom) → return immédiat,
    aucune requête, aucune MAJ Leaflet.
  - Sinon, requête DB uniquement pour les nouveaux idpars, puis
    `removeShape` pour les retirés + `addPolygons` pour les ajoutés.
  Gain principal : sessions où l'utilisateur sélectionne 10-50 parcelles
  d'affilée (avant : N requêtes cumulatives, après : 1 requête par
  parcelle ajoutée).
- Ajout d'un flag global `CACHE_DEBUG` (FALSE par défaut) dans
  `helpers.R` pour gater les messages `[cache]` de diagnostic des deux
  caches ci-dessus. Passer à `TRUE` temporairement pour observer
  hit/miss/invalidation dans les logs Shiny Server.
- Court-circuit "data inchangée" pour `draw_parcelles_site` et
  `draw_perimetres_manuels` : ces deux fonctions étaient appelées à
  chaque pan/zoom (via `debounced_bounds()`) et faisaient un
  `clearGroup + addPolygons(toutes)` même si la donnée n'avait pas
  bougé. Comparaison par `digest::digest()` du sf entrant vs hash
  stocké dans `session$userData` ; si identique, return immédiat sans
  toucher à Leaflet. Gain perceptible lors de la navigation sur une
  carte avec beaucoup de parcelles, où chaque déplacement déclenchait
  un re-rendu inutile de plusieurs dizaines/centaines de polygones.

## [0.81.1] — 2026-05-23

### Corrigé
- **Hotfix v0.81** : l'ajout de parcelle à un site échouait avec l'erreur
  `constraint "dico_acteurs_dedupe_idx" for table "dico_acteurs_fonciers_agricoles"
  does not exist`. La cause : `ON CONFLICT ON CONSTRAINT <nom>` ne fonctionne
  qu'avec une vraie CONSTRAINT (UNIQUE, PRIMARY KEY), pas avec un UNIQUE INDEX
  fonctionnel. Remplacé par la forme inférée `ON CONFLICT (colonnes...)` qui
  fonctionne avec les unique indexes (fonctionnels ou non).

## [0.81] — 2026-05-23

### Ajouté
- Gestion des dépendances avec `renv` : fichiers `renv.lock`, `.Rprofile`,
  `renv/activate.R` versionnés ; section dédiée dans `CONTRIBUTING.md` avec
  procédure de restore (dev) et déploiement (serveur). Lockfile régénéré
  depuis le serveur prod (R 4.2.2, 90 packages) pour s'aligner sur la version
  de R réellement déployée.

### Modifié
- Helpers SQL `sql_int`/`sql_bool`/`sql_date`/`sql_txt` centralisés dans
  `helpers.R` au lieu d'être redéfinis localement dans 2 modules ; `sql_bool`
  standardisé sur `"TRUE"`/`"FALSE"` (corrige une divergence avec `"1"`/`"0"`)
  (commit `15757a2`).
- Dédup des acteurs propriétaires dans `mod_sites.R` (auto-création lors de
  l'association de parcelles cadastrales à un site) renforcée : la CTE `deja`
  normalise désormais nom/prénom/adresse via `LOWER(public.f_unaccent(TRIM(…)))`
  et l'INSERT final ajoute `ON CONFLICT ON CONSTRAINT dico_acteurs_dedupe_idx
  DO NOTHING` — aligné sur l'index unique fonctionnel créé côté DB.

### Côté base de données (à appliquer hors versionning git)
- Création d'un wrapper `public.f_unaccent(text)` marqué `IMMUTABLE` (forme
  à 2 arguments d'`unaccent`) pour pouvoir l'utiliser dans un index.
- Création de l'index unique fonctionnel `dico_acteurs_dedupe_idx` sur
  `gestcons.dico_acteurs_fonciers_agricoles` couvrant
  `(type_acteur_id, LOWER(f_unaccent(TRIM(COALESCE(nom,'')))), idem prenom, idem adresse)`.
  Bloque structurellement la création de doublons.
- Nettoyage manuel préalable : suppression de 26 acteurs orphelins sans liaison
  (clusters de doublons dont aucune entrée n'était référencée par les 4 tables
  `contrats_acteurs_fonciers`, `contrats_agriculteurs`, `animation_fonciere_acteurs`,
  `animation_contrat_agricole_acteurs`).

## [0.80] — 2026-05-22

### Sécurité
- Passe 1 : migration `glue()` → `glue_sql()` sur 14 requêtes 1-ligne (SELECT/DELETE
  avec paramètre numérique unique) dans 6 modules + `helpers.R` (commit `e4323c9`).
- Passe 2 : migration de 15 requêtes INSERT/UPDATE/DELETE interpolant directement
  `input$*` — vraie surface d'injection SQL — avec `glue_sql()` et `as.integer()`
  sur les IDs (commit `13df85b`).

### Corrigé
- Couleur des périmètres manuels alignée sur la légende du site : palette
  `COLORS_PARCELLES` avec priorité actif (bleu) > draft (jaune-orange) > other
  (rouge), au lieu d'un jaune uniforme à 2 opacités (commit `a3adf1b`).

### Modifié
- Cache-buster CSS (`app.css?v=…`) lié à `APP_VERSION` au lieu d'une valeur en dur
  (commit `645bc55`).
- `APP_VERSION` externalisé dans un fichier `VERSION` à la racine, lu au démarrage
  par `app.R` (commit `c66816c`).

### Supprimé
- Module orphelin `mod_oauth.R` (non sourcé dans `app.R`) (commit `9803098`).

### Ajouté
- `.RData` ajouté au `.gitignore` (commit `888c60d`).
- `CHANGELOG.md` et `CONTRIBUTING.md` à la racine du repo (commit `7ced166`).

## [0.79] — 2026-03-26

### Ajouté
- Infrastructure de versioning : constante `APP_VERSION` dans `app.R`, affichage
  de la version dans l'UI, organisation des branches (commit `838756e`).

## [0.78] — 2026-03-26

### Ajouté
- Première release publique de Gestcons (commit `50364f2`).

### Corrigé
- Gestion des cartes Leaflet dans les modules Shiny (commit `b3b13d6`).
