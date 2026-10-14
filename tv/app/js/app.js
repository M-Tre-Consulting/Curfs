// Curfs TV: Libreria, Cerca (catalogo del server), scheda serie e player.
// DOM semplice, niente framework: sulla TV conta che sia leggero.

import { loadCatalog, allEpisodes } from './catalog.js';
import * as store from './store.js';
import { posterFor } from './posters.js';
import { focus, focusFirst, focused, move, setScope } from './focus.js';

const KEY = {
  LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, OK: 13, BACK: 8, ESC: 27, BACK_WEBOS: 461, BACK_TIZEN: 10009,
  PLAY: 415, PAUSE: 19, PLAY_PAUSE: 179, STOP: 413, FF: 417, RW: 412,
};

const app = document.getElementById('app');
// lastKey: l'ultimo elemento aperto, per ritrovarlo tornando indietro.
// playingKey: l'ultimo episodio/film aperto nel player (anche se ci si è arrivati
// passando al successivo), per selezionarlo tornando nella scheda.
const state = { catalog: null, tab: 'library', editing: false, error: null, lastKey: null, playingKey: null };
const stack = []; // schermate aperte sopra le schede: { render, onKey?, onClose? }

// ---------- utilità

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el[k.toLowerCase()] = v;
    else if (k === 'dataset') { for (const [dk, dv] of Object.entries(v)) if (dv != null && dv !== false) el.dataset[dk] = dv; }
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c.nodeType ? c : String(c));
  return el;
}

function fmt(seconds) {
  const s = Math.max(0, Math.floor(seconds || 0));
  const hh = Math.floor(s / 3600);
  const mm = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return hh ? `${hh}:${String(mm).padStart(2, '0')}:${ss}` : `${mm}:${ss}`;
}

const code = (season, number) => `S${String(season).padStart(2, '0')}E${String(number).padStart(2, '0')}`;
const titleById = (id) => state.catalog?.titles.find((t) => t.id === id) || null;

function posterArt(title, cls = 'poster') {
  const box = h('div', { class: cls }, h('div', { class: 'poster-fallback' }, title.name));
  const show = (url) => {
    if (!url) return;
    const img = h('img', { alt: '', decoding: 'async', loading: 'lazy' });
    img.onload = () => box.classList.add('loaded');
    img.src = url;
    box.append(img);
  };
  if (title.poster) show(title.poster);
  else posterFor(title.name, title.kind).then(show);
  return box;
}

// ---------- caricamento catalogo

async function refreshCatalog() {
  const firstLoad = !state.catalog;
  try {
    const catalog = await loadCatalog();
    state.catalog = catalog;
    state.error = null;
    store.cacheCatalog(catalog);
  } catch (e) {
    state.error = 'Il server non risponde. Controlla che la TV sia sulla rete di casa.';
  }
  if (stack.length) return;
  renderTabs();
  // Al primo avvio la selezione era rimasta sulle schede (il catalogo non
  // c'era ancora): ora va sul primo titolo.
  if (firstLoad && state.catalog) focusFirst(app.querySelector('main'));
}

// ---------- schede principali

function renderTabs() {
  const previous = focused()?.dataset.key || state.lastKey;
  app.replaceChildren(
    h('header', { class: 'top' },
      h('div', { class: 'brand' }, 'Curfs'),
      h('nav', { class: 'tabs' },
        tabButton('library', 'Libreria'),
        tabButton('search', 'Cerca')),
      state.tab === 'library' && libraryIdsWithTitles().length
        ? h('button', { class: `f pill ${state.editing ? 'danger' : ''}`, dataset: { key: 'edit' }, onclick: toggleEdit },
          state.editing ? 'Fine' : 'Modifica')
        : null),
    h('main', { class: 'scroll' }, state.tab === 'library' ? libraryView() : searchView()),
  );
  const again = previous && app.querySelector(`.f[data-key="${CSS.escape(previous)}"]`);
  if (again) focus(again);
  else focusFirst(app.querySelector('main'));
  if (!focused()) focusFirst(app);
}

function tabButton(tab, label) {
  return h('button', {
    class: `f tab ${state.tab === tab ? 'active' : ''}`, dataset: { key: 'tab-' + tab },
    onclick: () => { state.tab = tab; state.editing = false; renderTabs(); },
  }, label);
}

function toggleEdit() {
  state.editing = !state.editing;
  renderTabs();
}

function libraryIdsWithTitles() {
  return store.libraryIds().map(titleById).filter(Boolean);
}

/** Libreria: prima i titoli guardati di recente, poi quelli aggiunti. */
function libraryView() {
  if (!state.catalog) return loadingView();
  const titles = libraryIdsWithTitles();
  if (!titles.length) {
    return h('div', { class: 'empty' },
      h('h2', {}, 'La libreria è vuota'),
      h('p', {}, 'Vai su Cerca e aggiungi film e serie dal tuo server.'),
      state.error && h('p', { class: 'error' }, state.error));
  }
  const recency = (t) => store.lastPlayed(t.kind === 'series' ? allEpisodes(t).map((e) => e.id) : [t.id])?.at || 0;
  const order = store.libraryIds();
  titles.sort((a, b) => recency(b) - recency(a) || order.indexOf(a.id) - order.indexOf(b.id));
  if (state.editing) {
    return h('div', {},
      h('p', { class: 'hint' }, 'Premi OK su un titolo per toglierlo dalla libreria.'),
      h('div', { class: 'grid' }, titles.map((t) => card(t, { library: true }))));
  }
  const resume = continueTarget();
  const suggestions = suggestedTitles(7);
  return h('div', {},
    resume && continueHero(resume),
    h('h2', { class: 'section' }, 'La tua libreria'),
    h('div', { class: 'grid' }, titles.map((t) => card(t, { library: true }))),
    suggestions.length && h('h2', { class: 'section' }, 'Da scoprire sul server'),
    suggestions.length && h('div', { class: 'grid' }, suggestions.map((t) => card(t))));
}

/**
 * Cosa riprendere all'apertura: l'episodio o il film lasciato a metà più di
 * recente; se l'ultimo episodio era finito, il successivo della serie.
 */
function continueTarget() {
  let best = null;
  for (const title of libraryIdsWithTitles()) {
    const eps = title.kind === 'series' ? allEpisodes(title) : null;
    const last = store.lastPlayed(eps ? eps.map((e) => e.id) : [title.id]);
    if (!last || (best && last.at <= best.last.at)) continue;
    if (eps) {
      const i = eps.findIndex((e) => e.id === last.id);
      const ep = last.done ? eps[i + 1] : eps[i];
      if (ep) best = { title, ep, last, next: last.done };
    } else if (!last.done) {
      best = { title, ep: null, last, next: false };
    }
  }
  return best;
}

function continueHero(c) {
  const p = c.next ? null : c.last;
  const left = p && p.dur ? Math.max(1, Math.round((p.dur - p.pos) / 60)) : 0;
  return h('button', {
    class: 'f hero-card', dataset: { key: 'continue', autofocus: true },
    onclick: () => { state.lastKey = 'continue'; play(c.title, c.ep); },
  },
  posterArt(c.title, 'poster hero-poster'),
  h('div', { class: 'hero-info' },
    h('div', { class: 'hero-label' }, c.next ? 'Prossimo episodio' : 'Continua a guardare'),
    h('div', { class: 'hero-title' }, c.title.name),
    c.ep && h('div', { class: 'hero-sub' }, `${code(c.ep.season, c.ep.number)} · ${c.ep.title}`),
    p?.dur ? h('div', { class: 'hero-bar' }, h('i', { style: `width:${(p.pos / p.dur * 100).toFixed(1)}%` })) : null,
    h('div', { class: 'hero-hint' }, left ? `▶  OK per riprendere · mancano ${left} min` : '▶  OK per guardarlo')));
}

/** Titoli del catalogo mai iniziati e non in libreria; l'ordine cambia una volta al giorno. */
function suggestedTitles(count) {
  const day = Math.floor(Date.now() / 86400000);
  const score = (id) => {
    let x = day;
    for (let i = 0; i < id.length; i++) x = (x * 31 + id.charCodeAt(i)) >>> 0;
    return x;
  };
  return (state.catalog?.titles || [])
    .filter((t) => !store.inLibrary(t.id)
      && !store.lastPlayed(t.kind === 'series' ? allEpisodes(t).map((e) => e.id) : [t.id]))
    .sort((a, b) => score(a.id) - score(b.id))
    .slice(0, count);
}

function searchView() {
  if (!state.catalog) return loadingView();
  if (!state.catalog.titles.length) return h('div', { class: 'empty' }, h('h2', {}, 'Nessun video sul server'));
  const series = state.catalog.titles.filter((t) => t.kind === 'series');
  const movies = state.catalog.titles.filter((t) => t.kind === 'movie');
  return h('div', {},
    state.error && h('p', { class: 'error' }, state.error),
    series.length && h('h2', { class: 'section' }, 'Serie TV'),
    series.length && h('div', { class: 'grid' }, series.map((t) => card(t))),
    movies.length && h('h2', { class: 'section' }, 'Film'),
    movies.length && h('div', { class: 'grid' }, movies.map((t) => card(t))));
}

function loadingView() {
  return h('div', { class: 'empty' },
    state.error ? h('p', { class: 'error' }, state.error) : h('div', { class: 'spinner' }));
}

function card(title, { library = false } = {}) {
  const ids = title.kind === 'series' ? allEpisodes(title).map((e) => e.id) : [title.id];
  const last = store.lastPlayed(ids);
  const progress = title.kind === 'movie' && last && !last.done && last.dur ? last.pos / last.dur : 0;
  return h('button', {
    class: `f card ${library && state.editing ? 'editing' : ''}`, dataset: { key: title.id },
    onclick: () => {
      state.lastKey = title.id;
      if (library && state.editing) return confirmRemove(title);
      if (title.kind === 'series') openSeries(title);
      else play(title, null);
    },
  },
  posterArt(title),
  progress > 0 && h('div', { class: 'bar' }, h('i', { style: `width:${(progress * 100).toFixed(1)}%` })),
  !library && store.inLibrary(title.id) && h('span', { class: 'badge' }, '✓'),
  library && state.editing && h('span', { class: 'remove' }, '✕'),
  h('div', { class: 'card-title' }, title.name));
}

function confirmRemove(title) {
  dialog(`Togliere "${title.name}" dalla libreria?`, 'Si toglie solo dalla TV: sul server resta tutto.', [
    { label: 'Rimuovi', danger: true, action: () => { store.removeFromLibrary(title); if (!libraryIdsWithTitles().length) state.editing = false; renderTabs(); } },
    { label: 'Annulla', action: () => renderTabs() },
  ]);
}

// ---------- finestra di conferma

function dialog(text, detail, buttons) {
  const layer = h('div', { class: 'dialog-layer' },
    h('div', { class: 'dialog' },
      h('h2', {}, text),
      detail && h('p', {}, detail),
      h('div', { class: 'row' }, buttons.map((b, i) => h('button', {
        class: `f pill ${b.danger ? 'danger' : ''}`, dataset: { autofocus: i === buttons.length - 1 || null },
        onclick: () => { close(); b.action(); },
      }, b.label)))));
  const close = () => { layer.remove(); setScope(null); stack.pop(); };
  stack.push({ onKey: (k) => { if (isBack(k)) { close(); buttons[buttons.length - 1].action(); return true; } return false; } });
  document.body.append(layer);
  setScope(layer);
  focusFirst(layer);
}

// ---------- scheda serie

function openSeries(title) {
  const screen = { title, season: null, lastKey: null };
  const episodes = allEpisodes(title);
  const resumeTarget = () => {
    const last = store.lastPlayed(episodes.map((e) => e.id));
    if (!last) return { ep: episodes[0], label: `Guarda ${code(episodes[0].season, episodes[0].number)}` };
    const i = episodes.findIndex((e) => e.id === last.id);
    if (last.done && episodes[i + 1]) return { ep: episodes[i + 1], label: `Guarda ${code(episodes[i + 1].season, episodes[i + 1].number)}` };
    return { ep: episodes[i], label: `${last.done ? 'Rivedi' : 'Riprendi'} ${code(episodes[i].season, episodes[i].number)}` };
  };

  const render = () => {
    const fromEpisode = screen.lastKey && screen.lastKey !== 'resume';
    const previous = (fromEpisode && state.playingKey) || screen.lastKey || focused()?.dataset.key;
    screen.lastKey = null;
    const target = resumeTarget();
    if (screen.season == null) screen.season = target.ep.season;
    // Tornando dal player su un episodio di un'altra stagione, mostra quella.
    const playing = fromEpisode && episodes.find((e) => e.id === state.playingKey);
    if (playing) screen.season = playing.season;
    const season = title.seasons.find((s) => s.number === screen.season) || title.seasons[0];
    const added = store.inLibrary(title.id);
    app.replaceChildren(h('div', { class: 'detail scroll' },
      h('div', { class: 'hero' },
        posterArt(title, 'poster big'),
        h('div', { class: 'hero-text' },
          h('h1', {}, title.name),
          h('p', { class: 'meta' }, `${title.seasons.length} ${title.seasons.length === 1 ? 'stagione' : 'stagioni'} · ${episodes.length} episodi`),
          h('div', { class: 'row' },
            h('button', { class: 'f pill primary', dataset: { key: 'resume', autofocus: true }, onclick: () => { screen.lastKey = 'resume'; play(title, target.ep); } }, '▶  ' + target.label),
            h('button', {
              class: 'f pill', dataset: { key: 'add' },
              onclick: () => { added ? store.removeFromLibrary(title) : store.addToLibrary(title.id); render(); },
            }, added ? '✓  In libreria' : '+  Aggiungi alla libreria')))),
      title.seasons.length > 1 && h('div', { class: 'seasons' }, title.seasons.map((s) => h('button', {
        class: `f tab ${s.number === season.number ? 'active' : ''}`, dataset: { key: 'season-' + s.number },
        onclick: () => { screen.season = s.number; render(); },
      }, `Stagione ${s.number}`))),
      h('div', { class: 'episodes' }, season.episodes.map((e) => {
        const p = store.progressOf(e.id);
        return h('button', { class: 'f episode', dataset: { key: e.id }, onclick: () => { screen.lastKey = e.id; play(title, { ...e, season: season.number }); } },
          h('span', { class: 'ep-code' }, code(season.number, e.number)),
          h('span', { class: 'ep-title' }, e.title),
          p?.done ? h('span', { class: 'ep-done' }, '✓')
            : p?.dur ? h('span', { class: 'ep-bar' }, h('i', { style: `width:${(p.pos / p.dur * 100).toFixed(1)}%` })) : null);
      }))));
    const again = previous && app.querySelector(`.f[data-key="${CSS.escape(previous)}"]`);
    again ? focus(again) : focusFirst(app);
  };

  push({ render });
}

// ---------- player

function play(title, episode) {
  store.addToLibrary(title.id); // guardare qualcosa lo mette in libreria, come su iPhone
  const episodes = title.kind === 'series' ? allEpisodes(title) : [];
  let current = episode;
  const video = h('video', { class: 'video', preload: 'auto' });
  const label = h('div', { class: 'osd-title' });
  const bar = h('i');
  const time = h('div', { class: 'osd-time' });
  const osd = h('div', { class: 'osd' }, label, h('div', { class: 'osd-bar' }, bar), time);
  const spinner = h('div', { class: 'spinner center' });
  const nextBox = h('div', { class: 'next hidden' });
  const root = h('div', { class: 'player' }, video, spinner, osd, nextBox);

  let hideTimer = 0;
  let saveTimer = 0;
  let pendingSeek = 0;
  let seekTimer = 0;
  let countdown = 0;

  const id = () => (current ? current.id : title.id);
  const name = () => (current ? `${title.name} · ${code(current.season, current.number)} · ${current.title}` : title.name);

  function showOSD(stay = false) {
    osd.classList.remove('hidden');
    clearTimeout(hideTimer);
    if (!stay && !video.paused) hideTimer = setTimeout(() => osd.classList.add('hidden'), 3500);
  }

  function updateOSD() {
    const t = video.currentTime + pendingSeek;
    bar.style.width = video.duration ? `${Math.min(100, (t / video.duration) * 100)}%` : '0';
    time.textContent = `${fmt(t)} / ${fmt(video.duration)}${video.paused ? '   ❚❚' : ''}`;
  }

  function save() {
    if (video.duration > 0 && video.currentTime > 5) store.saveProgress(id(), video.currentTime, video.duration);
  }

  function load(ep) {
    current = ep;
    state.playingKey = ep ? ep.id : title.id;
    label.textContent = name();
    nextBox.classList.add('hidden');
    clearInterval(countdown);
    const p = store.progressOf(id());
    video.src = ep ? ep.url : title.url;
    video.onloadedmetadata = () => {
      if (p && !p.done && p.pos > 10 && p.pos < video.duration - 30) video.currentTime = p.pos;
      updateOSD();
    };
    video.play().catch(() => {});
    showOSD();
  }

  function nextEpisode() {
    if (!current) return null;
    const i = episodes.findIndex((e) => e.id === current.id);
    return i >= 0 ? episodes[i + 1] || null : null;
  }

  function offerNext() {
    const next = nextEpisode();
    if (!next) { close(); return; }
    let left = 8;
    const paint = () => {
      nextBox.replaceChildren(
        h('div', { class: 'next-label' }, 'Prossimo episodio'),
        h('div', { class: 'next-title' }, `${code(next.season, next.number)} · ${next.title}`),
        h('div', { class: 'next-hint' }, `Parte tra ${left} s · OK per guardarlo ora · Indietro per uscire`));
    };
    paint();
    nextBox.classList.remove('hidden');
    countdown = setInterval(() => { left -= 1; if (left <= 0) load(next); else paint(); }, 1000);
  }

  function seekBy(delta) {
    pendingSeek += delta;
    showOSD();
    updateOSD();
    clearTimeout(seekTimer);
    // I salti ravvicinati si sommano e si applicano una volta sola: ogni
    // salto sulla TV costa una nuova richiesta al server.
    seekTimer = setTimeout(() => {
      const target = Math.max(0, Math.min((video.duration || 0) - 2, video.currentTime + pendingSeek));
      pendingSeek = 0;
      video.currentTime = target;
    }, 450);
  }

  function close() {
    save();
    clearInterval(saveTimer);
    clearInterval(countdown);
    clearTimeout(hideTimer);
    video.pause();
    video.removeAttribute('src');
    video.load();
    pop();
  }

  video.onwaiting = () => spinner.classList.remove('hidden');
  video.onplaying = () => { spinner.classList.add('hidden'); showOSD(); };
  video.ontimeupdate = () => { if (!osd.classList.contains('hidden')) updateOSD(); };
  video.onpause = () => { showOSD(true); updateOSD(); save(); };
  video.onended = () => { save(); store.saveProgress(id(), video.duration, video.duration); offerNext(); };
  video.onerror = () => {
    spinner.classList.add('hidden');
    label.textContent = 'Questo video non si riesce a riprodurre sulla TV.';
    showOSD(true);
  };
  saveTimer = setInterval(save, 5000);

  push({
    render: () => { app.replaceChildren(root); },
    onKey: (k) => {
      if (!nextBox.classList.contains('hidden')) {
        if (k === KEY.OK) { const n = nextEpisode(); if (n) load(n); return true; }
        if (isBack(k)) { close(); return true; }
        return true;
      }
      switch (k) {
        case KEY.OK: case KEY.PLAY_PAUSE:
          video.paused ? video.play() : video.pause(); return true;
        case KEY.PLAY: video.play(); return true;
        case KEY.PAUSE: video.pause(); return true;
        case KEY.LEFT: case KEY.RW: seekBy(-10); return true;
        case KEY.RIGHT: case KEY.FF: seekBy(10); return true;
        case KEY.UP: case KEY.DOWN: showOSD(); updateOSD(); return true;
        case KEY.STOP: close(); return true;
        default:
          if (isBack(k)) { close(); return true; }
          return false;
      }
    },
  });
  load(episode);
}

// ---------- pila delle schermate

function push(screen) {
  stack.push(screen);
  screen.render();
}

function pop() {
  stack.pop();
  const top = stack[stack.length - 1];
  if (top?.render) top.render();
  else renderTabs();
}

function isBack(k) {
  return k === KEY.BACK || k === KEY.ESC || k === KEY.BACK_WEBOS || k === KEY.BACK_TIZEN;
}

document.addEventListener('keydown', (e) => {
  const k = e.keyCode;
  const top = stack[stack.length - 1];
  if (top?.onKey && top.onKey(k)) { e.preventDefault(); return; }
  switch (k) {
    case KEY.LEFT: move('left'); break;
    case KEY.RIGHT: move('right'); break;
    case KEY.UP: move('up'); break;
    case KEY.DOWN: move('down'); break;
    case KEY.OK: focused()?.click(); break;
    default:
      if (!isBack(k)) return;
      if (stack.length) pop();
      else if (state.editing) toggleEdit();
      else if (state.tab !== 'library') { state.tab = 'library'; renderTabs(); }
      else window.close(); // VIDAA: Indietro dalla Libreria chiude l'app
  }
  e.preventDefault();
});

// ---------- avvio

state.catalog = store.cachedCatalog();
if (!store.libraryIds().length) state.tab = 'search';
renderTabs();
refreshCatalog();
