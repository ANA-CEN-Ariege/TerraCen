// --- Uniformiser l’invalidation de taille des cartes ---
// 1) Handler utilisé par mod_sites.R et app.R
Shiny.addCustomMessageHandler('invalidate-map', function(m){
  var id = (m && m.id) ? m.id : m;  // accepte {id:"..."} ou juste "..."
  setTimeout(function(){
    var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + id) : null;
    if (w && w.getLeaflet) { try { w.getLeaflet().invalidateSize(); } catch(e){} }
    // Fallbacks bruts si nécessaire
    var el = document.getElementById(id);
    var map = null;
    if (el) {
      map = (el.htmlwidget_data && el.htmlwidget_data._map) ? el.htmlwidget_data._map : (el._leaflet_map || null);
    }
    if (map && map.invalidateSize) { try { map.invalidateSize(); } catch(e){} }

    // Optionnel : déclenche un resize global (⚠️ peut réveiller des observers R)
    window.dispatchEvent(new Event('resize'));
  }, 0);
});

// 2) Alias pour le module Actions (mod_animations.R)
// Ce nom était enregistré DEUX fois : ici, et dans un tags$script de
// mod_actions.R. Shiny garde le dernier venu, et le script du module,
// rendu dans le corps de la page, écrasait donc celui-ci : seul un
// événement resize partait, sans invalidateSize sur la carte visée. Les
// deux sont réunis ici, au délai du module (100 ms) : la carte d'une
// modale n'est pas encore dimensionnée à l'instant de l'envoi.
Shiny.addCustomMessageHandler('af-invalidate-size', function(id){
  var mapId = (id && id.id) ? id.id : id;
  setTimeout(function(){
    var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + mapId) : null;
    if (w && w.getLeaflet) { try { w.getLeaflet().invalidateSize(); } catch(e){} }
    window.dispatchEvent(new Event('resize'));
  }, 100);
});

// ------- Croix de fermeture dans l'en-tête de TOUTES les modales -------
// Shiny n'en met pas. Plutôt que d'ajouter le bouton dans les ~35 appels à
// modalDialog(), on l'injecte ici à l'affichage. Rien n'est ajouté si la
// modale n'a pas d'en-tête (pas de titre) ou en possède déjà un.
$(document).on('shown.bs.modal', function (e) {
  var $h = $(e.target).find('.modal-header').first();
  if (!$h.length || $h.find('button.close, button.btn-close').length) return;
  // Bootstrap 5 a renommé la croix et son attribut de fermeture, et dessine le
  // signe lui-même : un &times; à l'intérieur y ferait un doublon.
  // append et non prepend : l'en-tête est un conteneur flex en
  // justify-content: space-between, le titre reste donc à gauche et la croix
  // part à droite. En tête, elle se retrouvait au milieu, poussée par le
  // margin-left: auto que Bootstrap 5 donne à .btn-close.
  var bs5 = !!(window.bootstrap && window.bootstrap.Modal);
  $h.append(bs5
    ? '<button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Fermer"></button>'
    : '<button type="button" class="close" data-dismiss="modal" aria-label="Fermer">' +
      '<span aria-hidden="true">&times;</span></button>'
  );
});

// Cacher/afficher la section "Overlays" du controle Leaflet pour une carte donnée
Shiny.addCustomMessageHandler('toggle-layer-overlays', function (m) {
  var id = (m && m.id) ? m.id : null;
  var hide = !!(m && m.hide);
  if (!id) return;
  var el = document.getElementById(id);
  if (!el) return;
  if (hide) {
    el.classList.add('no-overlays');
  } else {
    el.classList.remove('no-overlays');
  }
  // On invalide la taille pour éviter un rendu partiel du controle
  setTimeout(function(){
    var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + id) : null;
    if (w && w.getLeaflet) { try { w.getLeaflet().invalidateSize(); } catch(e){} }
  }, 0);
});

// Indispensable pour vos fonctions reset() dans R
Shiny.addCustomMessageHandler('af-reset-click', function(mapId) {
  // Remet à null les inputs Shiny liés aux clics pour permettre de re-cliquer
  Shiny.setInputValue(mapId + '_shape_click', null, {priority: 'event'});
  Shiny.setInputValue(mapId + '_click', null, {priority: 'event'});
  Shiny.setInputValue(mapId + '_marker_click', null, {priority: 'event'});
  
  // Gestion spécifique pour le module Actions (draw toolbar)
  Shiny.setInputValue(mapId + '_draw_new_feature', null, {priority: 'event'});
});

// ------- Util: retrouver la map Leaflet d’un htmlwidget -------
function getLeafletMapById(mapId){
  var el = document.getElementById(mapId);
  if (!el) return null;
  var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + mapId) : null;
  if (w && (w.getLeaflet || w.getMap)) {
    try { return (w.getLeaflet && w.getLeaflet()) || (w.getMap && w.getMap()); } catch(e){}
  }
  if (el && el.htmlwidget_data && el.htmlwidget_data._map) return el.htmlwidget_data._map;
  if (el._leaflet_map) return el._leaflet_map;
  return null;
}

// ------- Appliquer une vue (centre + zoom) de façon FIABLE -------
// Attend que la carte existe ET que son conteneur soit visible/dimensionné,
// puis invalidateSize() PUIS setView() (sans animation), avec une 2e passe au
// frame suivant pour absorber un resize tardif. Évite le « fond monde » qui
// restait quand setView partait avant que l'onglet soit affiché.
Shiny.addCustomMessageHandler('set-map-view', function(m){
  if (!m || !m.id) return;
  var id = m.id, lat = +m.lat, lng = +m.lng, zoom = +m.zoom;
  var el = document.getElementById(id);
  if (!el) return;
  var tries = 0, applied = 0;
  (function step(){
    var map = getLeafletMapById(id);
    var visible = el.offsetWidth > 0 && el.offsetHeight > 0;
    if (map && visible) {
      try {
        map.invalidateSize(false);
        map.setView([lat, lng], zoom, { animate: false });
      } catch(e){}
      // Ré-applique quelques fois pour absorber un resize/rendu tardif (évite le
      // « fond monde » si la 1re passe arrive avant le dimensionnement final).
      if (applied++ < 3) { setTimeout(step, 120); }
      return;
    }
    // Carte pas encore visible/prête : on patiente (jusqu'à ~10 s) au lieu
    // d'abandonner après quelques frames (ce qui laissait la mappemonde).
    if (tries++ < 200) { setTimeout(step, 50); }
  })();
});

// ------- Vider explicitement le groupe 'Polygones' (optionnel) -------
Shiny.addCustomMessageHandler('clear-polygones', function(mapId){
  var map = getLeafletMapById(mapId);
  if (!map) return;
  if (map.layerManager && typeof map.layerManager.clearGroup === 'function') {
    try { map.layerManager.clearGroup('Polygones'); } catch(e){}
  }
  var grp = map.layerManager && map.layerManager.getLayerGroup && map.layerManager.getLayerGroup('Polygones');
  if (grp && grp.clearLayers) { try { grp.clearLayers(); } catch(e){} }
});

// ------- Plein écran d'une page à carte -------
//
// Le greffon de Leaflet met en plein écran LA CARTE. Tout ce qui vit hors du
// conteneur devient alors inaccessible — dont la barre d'actions rendue sous
// la carte. Déplacer cette barre dans la carte, comme on l'a d'abord fait,
// revient à faire cohabiter un champ Shiny avec le gestionnaire d'événements
// de Leaflet et le cycle de rendu de Shiny : cinq défauts distincts en sont
// sortis, dont un champ qui refusait de transmettre son choix.
//
// On met donc en plein écran le BLOC QUI CONTIENT DÉJÀ LES DEUX,
// « .tc-page-carte » — carte, message et barre d'actions. Rien ne bouge dans
// le DOM, la barre reste un enfant ordinaire de la page, et Leaflet ne voit
// jamais ses événements. C'est le vrai plein écran du navigateur, pas celui
// du greffon.
//
// Les cartes qui ne sont pas dans une page à deux étages — l'accueil, celles
// des modales — gardent le comportement du greffon.
(function () {
  var pageCourante = null;

  function invalider(page) {
    if (!page) return;
    var carte = page.querySelector('.leaflet-container');
    if (!carte) return;
    var ide = carte.id ? carte : (carte.closest ? carte.closest('[id]') : null);
    var id = ide && ide.id;
    // 120 ms : le temps que le navigateur ait posé la nouvelle taille.
    setTimeout(function () {
      var w = (id && window.HTMLWidgets && HTMLWidgets.find)
        ? HTMLWidgets.find('#' + id) : null;
      if (w && w.getLeaflet) { try { w.getLeaflet().invalidateSize(); } catch (e) {} }
      window.dispatchEvent(new Event('resize'));
    }, 120);
  }

  // Capture : on intercepte le bouton du greffon AVANT qu'il n'agisse.
  // stopPropagation en capture arrête l'événement avant même sa cible.
  document.addEventListener('click', function (e) {
    var bouton = e.target.closest && e.target.closest('.leaflet-control-fullscreen-button');
    if (!bouton) return;
    var carte = bouton.closest('.leaflet-container');
    var page  = carte && carte.closest('.tc-page-carte');
    if (!page) return;                 // carte hors page à deux étages : greffon inchangé
    e.preventDefault();
    e.stopPropagation();
    if (document.fullscreenElement === page) {
      if (document.exitFullscreen) document.exitFullscreen();
    } else if (page.requestFullscreen) {
      pageCourante = page;
      page.requestFullscreen();
    }
  }, true);

  document.addEventListener('fullscreenchange', function () {
    var page = document.fullscreenElement || pageCourante;
    invalider(page);
    if (!document.fullscreenElement) pageCourante = null;
  });

  // Une modale s'affiche au niveau du document : en plein écran, seul
  // l'élément mis en plein écran et sa descendance sont rendus, donc elle
  // serait invisible. Plutôt que de sortir du plein écran — ce qu'on faisait
  // d'abord, et qui ramenait brutalement à la page dès qu'on ajoutait une
  // parcelle — on l'accueille DANS le bloc, et on la remet où elle était en
  // se fermant.
  //
  // Le déplacement est sans danger ici : le bloc est un div ordinaire, pas un
  // conteneur Leaflet, donc personne ne guette ses événements. Et la modale
  // est en position fixe, donc hors flux : elle ne devient pas un élément de
  // la colonne flexible qui l'accueille.
  function rapatrier(el) {
    if (el && el.__tcParent) { el.__tcParent.appendChild(el); el.__tcParent = null; }
  }

  // Le déplacement se fait à « shown » et NON à « show », et il est suivi
  // d'un bindAll. Mesuré : déplacée trop tôt, la modale quittait
  // #shiny-modal-wrapper AVANT que Shiny n'y attache ses liaisons — Shiny les
  // posait alors sur une enveloppe devenue vide, et les boutons de la modale
  // n'étaient liés à rien. Ils répondaient au clic sans rien transmettre :
  // shiny-bound-input absent, compteur indéfini, observateur jamais atteint.
  //
  // bindAll est de toute façon sans danger : il ignore ce qui est déjà lié.
  // Le voile arrive lui aussi après l'ouverture ; Bootstrap le retire
  // lui-même à la fermeture, où qu'il soit.
  // On déplace l'ENVELOPPE de Shiny, pas la modale elle-même. Shiny ferme ses
  // modales par $("#shiny-modal-wrapper").find(".modal") : une modale sortie
  // de cette enveloppe y devient introuvable, Shiny retire alors une
  // enveloppe vide, et la modale reste à l'écran — mesuré. L'enveloppe,
  // elle, reste intacte : Shiny la retrouve par son identifiant où qu'elle
  // soit, et le gestionnaire hidden.bs.modal qu'il y pose continue de
  // recevoir l'événement remonté de la modale.
  //
  // Et à « shown », pas à « show » : déplacée trop tôt, la modale quittait
  // l'enveloppe AVANT que Shiny n'y attache ses liaisons, qui tombaient alors
  // dans le vide — boutons sans shiny-bound-input, observateur jamais atteint.
  $(document).on('shown.bs.modal', function (e) {
    var fs = document.fullscreenElement;
    if (!fs || !e.target) return;
    var enveloppe = e.target.closest('#shiny-modal-wrapper') || e.target;
    if (enveloppe.parentNode !== fs) {
      enveloppe.__tcParent = enveloppe.parentNode;
      fs.appendChild(enveloppe);
      if (window.Shiny && Shiny.bindAll) Shiny.bindAll(enveloppe);
    }
    var voile = document.querySelector('body > .modal-backdrop');
    if (voile) { voile.__tcParent = voile.parentNode; fs.appendChild(voile); }
  });

  $(document).on('hidden.bs.modal', function (e) {
    rapatrier(e.target.closest ? (e.target.closest('#shiny-modal-wrapper') || e.target) : e.target);
  });

  // Les bandeaux d'avertissement (toastr) vivent eux aussi au niveau du
  // document : en plein écran, ils ne sont pas rendus. Un bouton qui refuse
  // d'agir et le dit par un bandeau paraît alors ne rien faire du tout —
  // c'est le cas d'« Enregistrer » dans la modale de contrat, qui exige un
  // contrat et le signale ainsi.
  //
  // toastr crée son conteneur à la VOLÉE, au premier bandeau : il faut donc
  // traiter les deux cas, celui où il existe déjà et celui où il naît pendant
  // le plein écran. L'observateur n'est actif que le temps du plein écran.
  var guetteurToasts = null;

  function accueillirToasts(fs) {
    var c = document.getElementById('toast-container');
    if (c && c.parentNode !== fs) { c.__tcParent = c.parentNode; fs.appendChild(c); }
  }

  document.addEventListener('fullscreenchange', function () {
    var fs = document.fullscreenElement;
    if (fs) {
      accueillirToasts(fs);
      guetteurToasts = new MutationObserver(function () { accueillirToasts(fs); });
      guetteurToasts.observe(document.body, { childList: true });
    } else {
      if (guetteurToasts) { guetteurToasts.disconnect(); guetteurToasts = null; }
      rapatrier(document.getElementById('toast-container'));
    }
  });

  // Si l'on quitte le plein écran alors qu'une modale est ouverte, elle doit
  // retrouver le document, sans quoi elle resterait dans un bloc redevenu
  // ordinaire et mal placée.
  document.addEventListener('fullscreenchange', function () {
    if (document.fullscreenElement) return;
    document.querySelectorAll('#shiny-modal-wrapper, .modal, .modal-backdrop')
      .forEach(rapatrier);
  });
})();

// ------- Active les tooltips Bootstrap (BS3 ou BS5)
$(document).on('shiny:connected', function(){
    var init = function(){
      if (window.bootstrap && bootstrap.Tooltip) {
        // Bootstrap 5. getOrCreateInstance et non new : la fonction est
        // rejouée à chaque modale ouverte, et un second `new` remplacerait
        // l'instance en laissant les écouteurs de la première derrière lui.
        var t = [].slice.call(document.querySelectorAll('[data-bs-toggle=\"tooltip\"]'));
        t.forEach(function(el){
          bootstrap.Tooltip.getOrCreateInstance(el, {container: 'body'});
        });
      } else if ($ && $.fn.tooltip) {
        // Bootstrap 3
        $('[data-toggle=\"tooltip\"]').tooltip({container: 'body'});
      }
    };
    init();
    // Ré-initialise après chaque update dynamique potentielle
    $(document).on('shown.bs.modal shown.bs.collapse', init);
});

// Invalide la carte quand un onglet devient visible
// Déjà présent :
$(document).on('shown.bs.tab', 'a[data-toggle="tab"], a[data-bs-toggle="tab"]', function (e) {
  var pane = $($(e.target).attr('href'));
  pane.find('.leaflet').each(function(){
    try {
      var id = this.id || $(this).closest('.html-widget').attr('id');
      if (id) {
        var w = (window.HTMLWidgets && HTMLWidgets.find) ? HTMLWidgets.find('#' + id) : null;
        if (w && w.getLeaflet) { w.getLeaflet().invalidateSize(); }

        // ⬇️ AJOUTE CES 2 LIGNES :
        var baseId = id.replace(/-map$/, '');
        Shiny.setInputValue(baseId + '-map_shown', Date.now(), {priority:'event'});
      }
    } catch(err){}
  });
});

// --- Overlay de chargement carte : signal "sites dessinés" venant de R ----
Shiny.addCustomMessageHandler('tc-sites-ready', function (id) {
  var mapId = (id && id.id) ? id.id : id;
  var el = document.getElementById(mapId);
  if (!el) return;
  el._tcSitesReadyFlag = true;                 // mémorise même si le module n'est pas prêt
  if (typeof el._tcSitesReady === 'function') {
    el._tcSitesReady();
  }
});

// Fin de (re)chargement complet de la vue côté serveur (cadastre, périmètres…)
Shiny.addCustomMessageHandler('tc-map-idle', function (id) {
  var mapId = (id && id.id) ? id.id : id;
  var el = document.getElementById(mapId);
  if (el && typeof el._tcIdle === 'function') {
    el._tcIdle();
  }
});

// --- Détection de relance d'appli / perte de session ---------------------
// Le serveur envoie un "boot id" unique par processus R. Si à une reconnexion
// il a changé -> l'appli a été relancée -> bandeau bloquant. Une coupure brève
// qui se rétablit sur le même processus (même boot id) ne déclenche rien.
(function () {
  var TC = { bootId: null, graceTimer: null, shown: false };

  function showRestartBanner() {
    if (TC.shown || document.getElementById('tc-disconnected')) return;
    TC.shown = true;
    var d = document.createElement('div');
    d.id = 'tc-disconnected';
    d.style.cssText = 'position:fixed;inset:0;z-index:99999;' +
      'background:rgba(20,20,20,.88);color:#fff;display:flex;flex-direction:column;' +
      'align-items:center;justify-content:center;text-align:center;padding:24px;' +
      'font-size:18px;font-family:sans-serif;';
    d.innerHTML =
      '<div style="font-size:42px;margin-bottom:12px;">⚠️</div>' +
      '<div style="max-width:520px;line-height:1.5;">La session a été ' +
      "interrompue (l'application a été relancée ou la connexion au " +
      'serveur est perdue).<br><br>Vous devez recharger la page pour continuer.</div>' +
      '<button id="tc-reload-btn" style="margin-top:22px;padding:10px 20px;' +
      'font-size:16px;cursor:pointer;border:0;border-radius:6px;' +
      'background:#3963aa;color:#fff;">🔄 Recharger</button>';
    document.body.appendChild(d);
    var b = document.getElementById('tc-reload-btn');
    if (b) b.addEventListener('click', function () { location.reload(); });
  }

  Shiny.addCustomMessageHandler('tc_boot', function (id) {
    if (TC.bootId === null) {
      TC.bootId = id;                 // premier chargement : on mémorise
    } else if (id !== TC.bootId) {
      showRestartBanner();            // processus différent = appli relancée
    }
    // même boot id => même processus (coupure brève rétablie) : rien
  });

  $(document).on('shiny:disconnected', function () {
    // Fenêtre de reconnexion : si rien ne revient -> session perdue.
    if (TC.graceTimer) return;
    TC.graceTimer = setTimeout(function () { showRestartBanner(); }, 6000);
  });

  $(document).on('shiny:connected', function () {
    // Reconnecté : on annule l'alerte ; tc_boot décidera si c'est une relance.
    if (TC.graceTimer) { clearTimeout(TC.graceTimer); TC.graceTimer = null; }
  });
})();



// ------- Fermer tous les tooltips Leaflet d'une carte -------
// (wrapper R : close_map_tooltips, helpers.R — migré depuis app.R)
Shiny.addCustomMessageHandler('closeLeafletTooltips', function(mapId) {
  var el = document.getElementById(mapId);
  if (el && el._leaflet_map) {
    el._leaflet_map.eachLayer(function(layer) {
      if (typeof layer.closeTooltip === 'function') layer.closeTooltip();
    });
  }
});

// ------- Keep-alive : maintient la connexion WebSocket active -------
// Signal toutes les 50 s (migré depuis app.R)
var socket_timeout_interval;
$(document).on('shiny:connected', function(event) {
  socket_timeout_interval = setInterval(function() {
    var n = Math.random();
    Shiny.setInputValue('keep_alive', n);
  }, 50000);
});
$(document).on('shiny:disconnected', function(event) {
  clearInterval(socket_timeout_interval);
});

// --- Hachures légères : parcelles de la continuité du site conservatoire ----------------------
// Leaflet ne gère pas les motifs de remplissage : on applique fill=url(#...)
// en STYLE INLINE aux polygones .pp-hachures, avec un <pattern> SVG injecté
// dans le SVG PROPRIÉTAIRE de chaque polygone (p.ownerSVGElement) — crucial :
// avec des panes personnalisés (cartes des Actions : af_sel, af_site...),
// Leaflet crée UN SVG PAR PANE, et le SVG du pane par défaut peut ne pas
// exister du tout. Id de pattern unique par SVG (compteur global).
// Leaflet recrée les <path> dans de nombreux cas (showGroup, re-render...) :
// un MutationObserver posé UNE FOIS par carte re-hachure tout polygone
// .pp-hachures qui apparaît. Le message R ne sert qu'à amorcer.
var tcHatchSeq = 0;
// Un pattern par (SVG, couleur) : orange par défaut (cartes des Actions),
// bleu via la classe additionnelle pp-hachures-bleu (Sites/Parcelles, même
// bleu que les parcelles du site à contrat actif).
function tcHatchPatternFor(svg, stroke) {
  if (!svg.__tcHatchIds) svg.__tcHatchIds = {};
  var pid = svg.__tcHatchIds[stroke];
  if (pid && svg.querySelector('pattern[id="' + pid + '"]')) return pid;
  var ns  = 'http://www.w3.org/2000/svg';
  pid = 'tc-hatch-' + (++tcHatchSeq);
  var defs = svg.querySelector('defs');
  if (!defs) { defs = document.createElementNS(ns, 'defs'); svg.insertBefore(defs, svg.firstChild); }
  var pat = document.createElementNS(ns, 'pattern');
  pat.setAttribute('id', pid);
  pat.setAttribute('patternUnits', 'userSpaceOnUse');
  pat.setAttribute('width', '8');
  pat.setAttribute('height', '8');
  pat.setAttribute('patternTransform', 'rotate(45)');
  var line = document.createElementNS(ns, 'line');
  line.setAttribute('x1', '0'); line.setAttribute('y1', '0');
  line.setAttribute('x2', '0'); line.setAttribute('y2', '8');
  line.setAttribute('stroke', stroke);
  line.setAttribute('stroke-width', '1.5');
  line.setAttribute('opacity', '0.6');
  pat.appendChild(line);
  defs.appendChild(pat);
  svg.__tcHatchIds[stroke] = pid;
  return pid;
}
function tcHatchStyleAll(el) {
  el.querySelectorAll('path.pp-hachures').forEach(function (p) {
    var svg = p.ownerSVGElement;
    if (!svg) return;
    // Teinte des diagonales. L'ordre compte : la classe la plus précise
    // d'abord. tcHatchPatternFor met en cache un motif par teinte, en ajouter
    // ne coûte rien.
    //   voisins  : la continuité d'un site voisin, en ardoise
    //   secteurs : les périmètres de la stratégie foncière, dans le jaune des
    //              sites voisins — ce sont les hachures qui les en distinguent
    //              (COLOR_SECTEURS_VOISINS, helpers.R)
    //   selection : la continuité RETENUE dans Sites, dans la teinte de son
    //              contour épais — sans quoi une parcelle sélectionnée
    //              garderait des diagonales bleues dans un cadre rouge.
    //              Pendant R : COULEUR_SEL_CONTINUITE (mod_sites.R).
    var stroke = '#ea580c';
    if (p.classList.contains('pp-hachures-voisins'))         stroke = '#475569';
    else if (p.classList.contains('pp-hachures-secteurs'))   stroke = '#a16207';
    else if (p.classList.contains('pp-hachures-selection'))  stroke = '#dc2626';
    else if (p.classList.contains('pp-hachures-bleu'))       stroke = '#0b5ed7';
    var want = 'url(#' + tcHatchPatternFor(svg, stroke) + ')';
    if (p.style.fill !== want) {
      p.style.fill = want;
      p.style.fillOpacity = '1';
    }
  });
}
Shiny.addCustomMessageHandler('tc-hatch', function (m) {
  var mapId = (typeof m === 'string') ? m : m.id;
  var tries = 0;
  (function boot() {
    tries++;
    var el = document.getElementById(mapId);
    if (!el) { if (tries < 30) setTimeout(boot, 100); return; }
    tcHatchStyleAll(el);
    if (!el.__tcHatchObs) {
      el.__tcHatchObs = new MutationObserver(function () { tcHatchStyleAll(el); });
      el.__tcHatchObs.observe(el, { childList: true, subtree: true });
    }
  })();
});

// --- Icônes d'action des tableaux (👁 fiche, ✏️ édition, 🗺️ carte) ----------
// Une seule implémentation pour toute l'application, en remplacement des cinq
// scripts quasi identiques que portaient les modules. Convention : l'élément
// porte la classe `tc-act`, l'input Shiny visé dans `data-input`, et tous ses
// autres attributs `data-*` deviennent les champs du message (`data-id`,
// `data-type`, `data-mode`…).
//
// `nonce` : sans lui, deux clics successifs sur la même icône enverraient la
// même valeur et Shiny n'invaliderait pas — le second clic serait ignoré.
// --- Cases à cocher de sélection dans les tableaux --------------------------
// Même convention que `tc-act` : la classe `tc-check`, l'input Shiny visé dans
// `data-input`, la clé de la ligne dans `data-key`.
//
// L'événement porte UNE clé et son état, jamais la liste des cases cochées :
// DT ne garde dans le DOM que la page affichée, une collecte globale perdrait
// donc les sélections des autres pages. C'est le serveur qui tient l'ensemble.
$(document).on('change', '.tc-check', function () {
  var input = this.getAttribute('data-input');
  if (!input) return;
  Shiny.setInputValue(input, {
    key: this.getAttribute('data-key'),
    checked: this.checked,
    nonce: Date.now()
  }, { priority: 'event' });
});

$(document).on('click', '.tc-act', function (e) {
  e.preventDefault();
  e.stopImmediatePropagation();
  var input = this.getAttribute('data-input');
  if (!input) return;
  var payload = { nonce: Date.now() };
  var data = $(this).data();
  for (var key in data) {
    if (key !== 'input') payload[key] = data[key];
  }
  Shiny.setInputValue(input, payload, { priority: 'event' });
});

// ------- Infobulle d'un périmètre manuel : y ajouter la parcelle cadastrale
// survolée -------
// Le périmètre manuel est dessiné sur un pane au-dessus du cadastre (zIndex 450
// contre 410) : c'est donc lui qui reçoit le survol, et la parcelle du dessous
// n'en sait rien. Plutôt que de rendre le périmètre transparent à la souris (on
// perdrait son infobulle et son clic), on résout la parcelle géométriquement à
// la position du curseur, dans les données déjà chargées — aucun aller-retour
// serveur — et on complète le contenu de l'infobulle ouverte.
(function () {
  var GROUPE_PERIM    = 'Périmètres manuels';
  var GROUPE_CADASTRE = 'Parcelles cadastrales';
  var THROTTLE_MS     = 50;   // le curseur bouge bien plus vite que l'œil ne lit

  // Point dans un anneau, par lancer de rayon.
  function ringContains(ring, pt) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      var yi = ring[i].lat, xi = ring[i].lng;
      var yj = ring[j].lat, xj = ring[j].lng;
      if (((yi > pt.lat) !== (yj > pt.lat)) &&
          (pt.lng < (xj - xi) * (pt.lat - yi) / (yj - yi) + xi)) {
        inside = !inside;
      }
    }
    return inside;
  }

  // getLatLngs() renvoie [anneau] pour un polygone simple, [anneau, trou…]
  // quand il a des trous, et [[anneau…]…] pour un multipolygone. On normalise
  // en liste de polygones, chacun étant une liste d'anneaux.
  function asPolygons(lls) {
    if (!lls || !lls.length) return [];
    if (lls[0] && lls[0].lat !== undefined) return [[lls]];
    if (lls[0] && lls[0][0] && lls[0][0].lat !== undefined) return [lls];
    return lls;
  }

  function contains(layer, pt) {
    if (!layer || !layer.getLatLngs) return false;
    try {
      // Rejet rapide : l'immense majorité des parcelles est hors cadre.
      if (layer.getBounds && !layer.getBounds().contains(pt)) return false;
      var polys = asPolygons(layer.getLatLngs());
      for (var p = 0; p < polys.length; p++) {
        var rings = polys[p];
        if (!rings || !rings.length || !ringContains(rings[0], pt)) continue;
        var inHole = false;
        for (var h = 1; h < rings.length; h++) {
          if (ringContains(rings[h], pt)) { inHole = true; break; }
        }
        if (!inHole) return true;
      }
    } catch (e) {}
    return false;
  }

  function tooltipHtml(layer) {
    var tt = layer.getTooltip && layer.getTooltip();
    if (!tt) return null;
    var c = tt.getContent();
    if (typeof c === 'string') return c;
    return (c && c.outerHTML) || null;
  }

  // Le groupe n'est retenu que s'il est réellement affiché : si l'utilisateur a
  // décoché le cadastre dans le contrôle des couches, on ne le lui remet pas
  // dans l'infobulle.
  function groupeVisible(map, nom) {
    var g = map.layerManager && map.layerManager.getLayerGroup &&
            map.layerManager.getLayerGroup(nom);
    if (!g || !g.eachLayer) return null;
    return (map.hasLayer && map.hasLayer(g)) ? g : null;
  }

  function cadastreSous(map, pt) {
    var g = groupeVisible(map, GROUPE_CADASTRE);
    if (!g) return null;
    var html = null;
    g.eachLayer(function (l) {
      if (html === null && contains(l, pt)) html = tooltipHtml(l);
    });
    return html;
  }

  function wire(map) {
    if (!map || map._tcPerimHover) return;
    map._tcPerimHover = true;
    var last = 0;
    map.on('mousemove', function (e) {
      var now = Date.now();
      if (now - last < THROTTLE_MS) return;
      last = now;
      var g = map.layerManager && map.layerManager.getLayerGroup &&
              map.layerManager.getLayerGroup(GROUPE_PERIM);
      if (!g || !g.eachLayer) return;
      g.eachLayer(function (l) {
        if (!l.getLatLngs || !l.getTooltip || !l.getTooltip()) return;
        // Contenu d'origine mémorisé au premier survol, avant toute retouche :
        // les couches sont recréées à chaque redessin, le cache repart avec.
        if (l._tcBase === undefined) l._tcBase = tooltipHtml(l) || '';
        var html = l._tcBase;
        if (contains(l, e.latlng)) {
          var cad = cadastreSous(map, e.latlng);
          if (cad) html = l._tcBase + '<hr class="tc-tt-sep">' + cad;
        }
        // Hors du polygone on revient au contenu d'origine, sinon la bulle
        // rouvrirait sur la dernière parcelle survolée.
        if (l._tcLast !== html) {
          l._tcLast = html;
          try { l.setTooltipContent(html); } catch (err) {}
        }
      });
    });
  }

  // Câblage demandé par R après chaque dessin des périmètres manuels : la carte
  // existe forcément à ce moment-là, et wire() est idempotent.
  Shiny.addCustomMessageHandler('tc-perim-hover', function (id) {
    var mapId = (id && id.id) ? id.id : id;
    if (!mapId) return;
    setTimeout(function () { wire(getLeafletMapById(mapId)); }, 0);
  });
})();

// --- Menu déroulant « Sites » dans la barre d'onglets -----------------------
// Quatre onglets — Sites, Parcelles, Contrats, Docs de gestion — sont retirés
// de la barre et regroupés sous une seule entrée déroulante.
//
// Construit à la main, sans le déroulant de Bootstrap : le thème est en
// Bootstrap 3, dont le balisage et les attributs diffèrent des versions
// suivantes. Tout passe ici par `#main_tabs a[data-value=…]` et `.closest('li')`,
// qui valent dans toutes les versions — c'est déjà ce que fait la fonction R
// qui masque un onglet selon les droits.
//
// La navigation réutilise le même mécanisme que cette fonction :
// Shiny.setInputValue('main_tabs', …), éprouvé dans cette application.
(function () {
  var MENU_ID = 'tc-sites-menu';

  // Le <li> de la BARRE portant cette valeur.
  //
  // Les items du menu portent les mêmes data-value et vivent eux aussi dans
  // #main_tabs : un querySelector simple renvoyait le premier du document,
  // c'est-à-dire l'item du menu, puisque le menu est inséré AVANT les onglets
  // d'origine. La boucle qui masque les onglets masquait donc les items, et
  // le déroulant s'ouvrait réduit à ses marges. On écarte explicitement ce qui
  // se trouve dans la liste déroulante.
  function liDe(valeur) {
    var as = document.querySelectorAll('#main_tabs a[data-value="' + valeur + '"]');
    for (var i = 0; i < as.length; i++) {
      if (!as[i].closest('.tc-menu-list')) return as[i].closest('li');
    }
    return null;
  }

  // L'onglet actif : Bootstrap 3 marque le <li>, les versions suivantes le <a>.
  // On accepte les deux plutôt que de parier sur l'une.
  function valeurActive() {
    var a = document.querySelector('#main_tabs li.active > a[data-value]') ||
            document.querySelector('#main_tabs a[data-value].active');
    return a ? a.getAttribute('data-value') : null;
  }

  // Bascule vers un onglet replié.
  //
  // Shiny.setInputValue('main_tabs', …) ne suffit PAS : il renseigne la valeur
  // côté serveur, mais rien ne change à l'écran — c'est le greffon d'onglets de
  // Bootstrap qui bascule l'affichage, et Shiny met alors son input à jour de
  // lui-même. On déclenche donc le lien d'origine, resté dans le DOM derrière
  // un display:none ; un clic programmé fonctionne sur un élément masqué.
  function naviguer(valeur) {
    var li = liDe(valeur);
    var lien = li ? li.querySelector('a[data-value]') : null;
    if (lien) {
      if (window.jQuery && window.jQuery(lien).tab) {
        window.jQuery(lien).tab('show');
      } else {
        lien.click();
      }
      return true;
    }
    // Repli : sans lien d'origine, au moins informer le serveur.
    if (window.Shiny && Shiny.setInputValue) {
      Shiny.setInputValue('main_tabs', valeur, { priority: 'event' });
    }
    return false;
  }

  // Exposés : app.R s'en sert pour rediriger quand l'onglet courant est
  // masqué, au lieu de redire le même JS avec les sélecteurs d'une seule
  // version de Bootstrap.
  window.tcOngletActif     = valeurActive;
  window.tcNaviguerOnglet  = naviguer;

  function majEtatActif(menu, items) {
    var actif = valeurActive();
    var dedans = items.some(function (it) { return it.value === actif; });
    menu.classList.toggle('tc-menu-active', dedans);
    menu.querySelectorAll('.tc-menu-list > li > a').forEach(function (a) {
      a.classList.toggle('tc-item-active', a.getAttribute('data-value') === actif);
    });
  }

  function construire(m) {
    var items = (m && m.items) || [];
    var nav = document.querySelector('#main_tabs');
    if (!nav) return;

    var ancien = document.getElementById(MENU_ID);
    if (ancien) ancien.remove();

    // Sans aucun item permis, on ne laisse pas une entrée vide dans la barre.
    if (items.length === 0) return;

    // Point d'insertion : la place du premier item, pour garder l'ordre
    // d'origine de la barre d'onglets.
    var ancre = null;
    for (var i = 0; i < items.length && !ancre; i++) ancre = liDe(items[i].value);
    if (!ancre) return;

    var menu = document.createElement('li');
    menu.id = MENU_ID;
    // nav-item : Bootstrap 5 le demande sur le <li>, Bootstrap 3 l'ignore.
    menu.className = 'tc-menu nav-item';

    var bouton = document.createElement('a');
    bouton.className = 'tc-menu-toggle nav-link';
    bouton.href = '#';
    bouton.textContent = m.label || 'Sites';
    menu.appendChild(bouton);

    var liste = document.createElement('ul');
    liste.className = 'tc-menu-list';
    items.forEach(function (it) {
      var li = document.createElement('li');
      var a = document.createElement('a');
      a.href = '#';
      a.textContent = it.label;
      a.setAttribute('data-value', it.value);
      a.addEventListener('click', function (e) {
        e.preventDefault();
        menu.classList.remove('tc-open');
        naviguer(it.value);
      });
      li.appendChild(a);
      liste.appendChild(li);
    });
    menu.appendChild(liste);

    ancre.parentNode.insertBefore(menu, ancre);
    items.forEach(function (it) {
      var li = liDe(it.value);
      if (li) li.style.display = 'none';
    });

    // La liste est en position fixed pour échapper à l'overflow:hidden du
    // conteneur d'onglets : ses coordonnées doivent donc être posées à
    // l'ouverture, depuis la position réelle du bouton.
    function placer() {
      var r = bouton.getBoundingClientRect();
      liste.style.top  = Math.round(r.bottom + 2) + 'px';
      liste.style.left = Math.round(r.left) + 'px';
      // Ne pas déborder à droite sur un écran étroit.
      var trop = r.left + liste.offsetWidth - window.innerWidth + 8;
      if (trop > 0) liste.style.left = Math.max(8, Math.round(r.left - trop)) + 'px';
    }

    bouton.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      var ouvre = !menu.classList.contains('tc-open');
      menu.classList.toggle('tc-open', ouvre);
      if (ouvre) placer();
    });

    // Un élément fixé ne suit pas son ancre : plutôt que de le repositionner
    // en continu, on referme.
    window.addEventListener('resize', function () { menu.classList.remove('tc-open'); });
    window.addEventListener('scroll', function () { menu.classList.remove('tc-open'); }, true);
    document.addEventListener('click', function (e) {
      if (!menu.contains(e.target)) menu.classList.remove('tc-open');
    });
    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') menu.classList.remove('tc-open');
    });

    // L'onglet actif change sans qu'aucun événement ne nous soit adressé —
    // par un clic ailleurs dans la barre, ou par navigation depuis le code.
    // On observe donc la barre plutôt que de parier sur un signal.
    if (!nav.__tcMenuObs) {
      nav.__tcMenuObs = new MutationObserver(function () {
        var m2 = document.getElementById(MENU_ID);
        if (m2) majEtatActif(m2, items);
      });
      nav.__tcMenuObs.observe(nav, {
        subtree: true, attributes: true, attributeFilter: ['class']
      });
    }
    majEtatActif(menu, items);
  }

  // Le message part d'un observateur qui suit les rôles : il peut précéder le
  // rendu de la barre d'onglets. Sans attente, le menu ne serait tout
  // simplement pas construit. Même parade que le gestionnaire des hachures.
  Shiny.addCustomMessageHandler('tc-sites-menu', function (m) {
    var essais = 0;
    (function attendre() {
      essais++;
      if (document.querySelector('#main_tabs')) { construire(m); return; }
      if (essais < 30) setTimeout(attendre, 100);
    })();
  });
})();


// ---------------------------------------------------------------------------
// Contrôle des couches en accordéon
//
// Sur la carte de l'onglet Sites, le contrôle de Leaflet empile onze entrées à
// plat : trois fonds et huit couches. On les répartit en groupes repliables,
// un seul ouvert à la fois.
//
// On ne remplace PAS le contrôle de Leaflet : on déplace ses <label> dans des
// groupes. Les écouteurs sont posés par Leaflet sur les <input>, pas sur leur
// place dans le DOM, donc ils survivent au déplacement — et le gestionnaire
// 'change' de mod_sites.R, qui remonte par closest('label'), aussi.
//
// Leaflet reconstruit sa liste à CHAQUE ajout ou retrait de couche sur la
// carte : L.Control.Layers._onLayerChange() appelle _update(), qui vide puis
// repeuple les conteneurs. Notre structure est donc effacée très souvent, et
// un MutationObserver la repose. Le test « .tc-lc est déjà là » évite que nos
// propres écritures ne rebouclent dans l'observateur.
(function () {
  var TITRE_FOND   = 'Fond de carte';
  var TITRE_AUTRES = 'Autres couches';

  // En deçà de ce nombre d'entrées, grouper n'apporte rien : les cartes des
  // modales d'Actions ou celle de l'accueil restent telles quelles.
  var SEUIL = 6;

  // Les zones de protection arrivent une par TYPE, sous un préfixe commun posé
  // côté R (PROTECTION_PREFIXE, helpers.R). On les rassemble sur ce préfixe
  // plutôt que de lister les huit types ici : la base peut en gagner un.
  var PROTECTION_PREFIXE = 'Protection : ';
  var TITRE_PROTECTION   = 'Zones de protection';

  // Un groupe vide n'est pas rendu (cf. reorganiser) : « Le site » et « Le
  // secteur » peuvent donc coexister ici, seul celui qui a des entrées
  // apparaîtra sur une carte donnée. C'est ce qui permet à la carte de
  // Stratégie d'avoir la même structure que celle de Sites sans qu'un
  // en-tête parle de « site » au-dessus de couches de secteur.
  var GROUPES = [
    { titre: 'Le site', items: [
      'Parcelles du site', 'Continuité du site conservatoire', 'Contour',
      'Périmètres manuels'
    ]},
    { titre: 'Le secteur', items: ['Secteurs', 'Parcelles du secteur'] },
    { titre: 'Cadastre', items: ['Parcelles cadastrales'] },
    { titre: 'Autour du site', items: [
      'Sites voisins', 'Zones humides', 'Limites communales'
    ]},
    { titre: TITRE_PROTECTION, items: [] }
  ];

  function texteDe(label) {
    return (label.textContent || '').trim();
  }

  function groupeDe(texte) {
    if (texte.indexOf(PROTECTION_PREFIXE) === 0) return TITRE_PROTECTION;
    for (var i = 0; i < GROUPES.length; i++) {
      if (GROUPES[i].items.indexOf(texte) !== -1) return GROUPES[i].titre;
    }
    return TITRE_AUTRES;
  }

  // Le préfixe a servi à regrouper : il n'a plus rien à dire sous un en-tête
  // qui le répète. Leaflet réécrit le libellé complet à chaque reconstruction,
  // on le raccourcit donc à chaque fois.
  function abreger(label) {
    var t = texteDe(label);
    if (t.indexOf(PROTECTION_PREFIXE) !== 0) return;
    var sp = label.querySelector('span');
    if (sp) sp.textContent = ' ' + t.slice(PROTECTION_PREFIXE.length);
  }

  // Nombre de couches cochées dans un groupe : affiché sur l'en-tête, pour
  // qu'un groupe replié ne cache pas qu'il contient quelque chose d'actif.
  function majCompteur(groupe) {
    var pastille = groupe.querySelector('.tc-lc-n');
    if (!pastille) return;
    // Pas de pastille sur les fonds : il y en a toujours exactement un de
    // coché, le compte n'apprendrait rien.
    var coches = groupe.getAttribute('data-titre') === TITRE_FOND
      ? 0
      : groupe.querySelectorAll('.tc-lc-body input:checked').length;
    pastille.textContent = coches ? String(coches) : '';
    pastille.style.display = coches ? '' : 'none';
  }

  function ouvrir(conteneur, titre) {
    conteneur.querySelectorAll('.tc-lc-grp').forEach(function (g) {
      var ouvert = g.getAttribute('data-titre') === titre;
      g.classList.toggle('tc-open', ouvert);
    });
    // Mémorisé sur le contrôle : Leaflet reconstruira la liste, on doit
    // pouvoir rouvrir le même groupe sans que l'utilisateur le redemande.
    var ctrl = conteneur.closest('.leaflet-control-layers');
    if (ctrl) ctrl.__tcGroupeOuvert = titre;
  }

  function labelsDe(conteneur) {
    if (!conteneur) return [];
    return Array.prototype.filter.call(conteneur.children, function (n) {
      return n.tagName === 'LABEL';
    });
  }

  function reorganiser(ctrl) {
    var liste = ctrl.querySelector('.leaflet-control-layers-list');
    if (!liste) return;

    var fonds    = liste.querySelector('.leaflet-control-layers-base');
    var couches  = liste.querySelector('.leaflet-control-layers-overlays');
    var labFonds = labelsDe(fonds);
    var labCouch = labelsDe(couches);

    // Les conteneurs d'origine sont vides : soit le contrôle n'a rien à
    // montrer, soit nos groupes sont déjà en place et Leaflet n'a pas
    // reconstruit depuis. C'est ce test, et non la présence de .tc-lc, qui
    // empêche l'observateur de reboucler sur nos propres écritures.
    if (!labFonds.length && !labCouch.length) return;
    if (labFonds.length + labCouch.length < SEUIL) return;

    // Leaflet vient de repeupler : nos anciens groupes pointent sur des
    // <input> qu'il a cessé de suivre, on les jette et on repart des neufs.
    var ancien = liste.querySelector('.tc-lc');
    if (ancien) ancien.remove();

    // Ordre des groupes : les fonds d'abord, puis l'ordre déclaré, puis le
    // fourre-tout — et uniquement ceux qui ont au moins une entrée.
    var paquets = [];
    if (labFonds.length) paquets.push({ titre: TITRE_FOND, labels: labFonds });
    GROUPES.concat([{ titre: TITRE_AUTRES, items: [] }]).forEach(function (g) {
      var dedans = labCouch.filter(function (l) { return groupeDe(texteDe(l)) === g.titre; });
      if (dedans.length) paquets.push({ titre: g.titre, labels: dedans });
    });
    if (paquets.length < 2) return;

    var conteneur = document.createElement('div');
    conteneur.className = 'tc-lc';

    paquets.forEach(function (p) {
      var grp = document.createElement('div');
      grp.className = 'tc-lc-grp';
      grp.setAttribute('data-titre', p.titre);

      var hdr = document.createElement('button');
      hdr.type = 'button';
      hdr.className = 'tc-lc-hdr';
      var nom = document.createElement('span');
      nom.className = 'tc-lc-titre';
      nom.textContent = p.titre;
      var pastille = document.createElement('span');
      pastille.className = 'tc-lc-n';
      hdr.appendChild(nom);
      hdr.appendChild(pastille);

      var corps = document.createElement('div');
      corps.className = 'tc-lc-body';
      p.labels.forEach(function (l) { corps.appendChild(l); abreger(l); });

      hdr.addEventListener('click', function (e) {
        e.preventDefault();
        e.stopPropagation();
        var deja = grp.classList.contains('tc-open');
        ouvrir(conteneur, deja ? null : p.titre);
      });

      grp.appendChild(hdr);
      grp.appendChild(corps);
      conteneur.appendChild(grp);
      majCompteur(grp);
    });

    // Les conteneurs d'origine sont vidés mais conservés : Leaflet les
    // réutilise tels quels au prochain _update(). Le séparateur, lui, est
    // remis à '' par Leaflet à chaque reconstruction : on le remasque ici.
    var sep = liste.querySelector('.leaflet-control-layers-separator');
    if (sep) sep.style.display = 'none';
    liste.appendChild(conteneur);

    // Tout est replié tant que l'utilisateur n'a rien ouvert : on arrive sur
    // un contrôle compact, pas sur un groupe déplié d'office. Son choix est
    // ensuite respecté à travers les reconstructions de Leaflet.
    var voulu = ctrl.__tcGroupeOuvert;
    ouvrir(conteneur,
           voulu && conteneur.querySelector('[data-titre="' + voulu + '"]') ? voulu : null);

    conteneur.addEventListener('change', function () {
      conteneur.querySelectorAll('.tc-lc-grp').forEach(majCompteur);
    });
  }

  // Revenir sur un onglet remet son contrôle au repos : app.R envoie ce
  // message en entrant dans l'onglet, pour qu'on y retrouve toujours des
  // groupes fermés plutôt que celui qu'on avait laissé ouvert la fois d'avant.
  Shiny.addCustomMessageHandler('tc-lc-fermer', function (m) {
    var el = document.getElementById(m && m.id);
    if (!el) return;
    el.querySelectorAll('.leaflet-control-layers').forEach(function (ctrl) {
      ctrl.__tcGroupeOuvert = null;
      var c = ctrl.querySelector('.tc-lc');
      if (c) ouvrir(c, null);
    });
  });

  function surveiller(ctrl) {
    if (ctrl.__tcObs) return;
    reorganiser(ctrl);
    ctrl.__tcObs = new MutationObserver(function () { reorganiser(ctrl); });
    ctrl.__tcObs.observe(ctrl, { childList: true, subtree: true });
  }

  // Les cartes apparaissent au fil des rendus Shiny : on surveille le document
  // plutôt que de parier sur un instant précis.
  function balayer() {
    document.querySelectorAll('.leaflet-control-layers').forEach(surveiller);
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', balayer);
  } else {
    balayer();
  }
  new MutationObserver(balayer).observe(document.documentElement, {
    childList: true, subtree: true
  });
})();
