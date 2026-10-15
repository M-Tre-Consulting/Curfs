// Libreria e progressi del profilo scelto (obbligatorio): stanno sul server
// insieme a quelli di iPhone e Mac (vedi profiles.js), con una copia qui per
// aprire tutto subito e per non perdere nulla se il server non risponde.
// Libreria e progressi salvati sulla TV prima dei profili si cancellano alla
// prima scelta di un profilo.

import * as profiles from './profiles.js';

const LIBRARY_KEY = 'curfs.library';
const PROGRESS_KEY = 'curfs.progress';
const CATALOG_KEY = 'curfs.catalog';
const PROFILE_KEY = 'curfs.profile';
const MIRROR_KEY = 'curfs.profileData';

function read(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function write(key, value) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* spazio pieno: pazienza */ }
}

// --- Chiavi condivise: dagli id del catalogo (percorsi sul server) alle
// chiavi per nome usate dai profili (serie + stagione + episodio, o film).

let meta = new Map();   // id episodio/film -> { key, titleId, kind, title, show?, season?, episode?, path }
let byKey = new Map();  // chiave -> id episodio/film

export function indexCatalog(catalog) {
  meta = new Map();
  byKey = new Map();
  for (const t of catalog?.titles || []) {
    if (t.kind === 'movie') {
      add(t.id, { key: profiles.movieKey(t.name), titleId: t.id, kind: 'movie', title: t.name, path: t.id.slice(2) });
    } else {
      for (const s of t.seasons || []) {
        for (const e of s.episodes) {
          add(e.id, {
            key: profiles.episodeKey(t.name, s.number, e.number), titleId: t.id, kind: 'episode',
            title: e.title, show: t.name, season: s.number, episode: e.number, path: e.id.slice(2),
          });
        }
      }
    }
  }
  libraryCache = null;
}

function add(id, m) {
  meta.set(id, m);
  if (!byKey.has(m.key)) byKey.set(m.key, id);
}

function describe(m, at) {
  const entry = { at, kind: m.kind, title: m.title, path: m.path };
  if (m.kind === 'episode') Object.assign(entry, { show: m.show, season: m.season, episode: m.episode });
  return entry;
}

// --- Profilo scelto su questa TV

// { id, progress: {chiave: voce}, library: {chiave: voce}, rev, progressDirty, libraryDirty }
let mirror = read(MIRROR_KEY, null);

// TV che aveva già scelto un profilo con la versione che sincronizzava solo
// il minutaggio: si riparte da lì, la libreria arriva dal server.
if (!mirror && activeProfile()) {
  const old = read('curfs.profileProgress', null);
  const same = old?.id === activeProfile().id;
  mirror = {
    id: activeProfile().id, progress: same ? old.entries : {}, library: {}, rev: 0,
    progressDirty: same && !!old.dirty, libraryDirty: false,
  };
  write(MIRROR_KEY, mirror);
}

export function activeProfile() {
  return read(PROFILE_KEY, null);
}

/** Nome/foto aggiornati da iPhone o Mac. */
export function refreshProfile(profile) {
  if (activeProfile()?.id === profile.id) write(PROFILE_KEY, profile);
}

/** `null` solo quando il profilo è stato cancellato da iPhone/Mac. */
export function setProfile(profile) {
  libraryCache = null;
  if (!profile) {
    write(PROFILE_KEY, null);
    mirror = null;
    write(MIRROR_KEY, null);
    return;
  }
  if (mirror?.id !== profile.id) {
    mirror = { id: profile.id, progress: {}, library: {}, rev: 0, progressDirty: false, libraryDirty: false };
    // Quello salvato solo sulla TV prima dei profili non passa al profilo
    // (che ha già quello di iPhone/Mac): si butta.
    write(PROGRESS_KEY, {});
    write(LIBRARY_KEY, []);
  }
  write(PROFILE_KEY, profile);
  write(MIRROR_KEY, mirror);
}

function usingProfile() {
  return mirror && activeProfile()?.id === mirror.id;
}

function changed(flag) {
  mirror.rev += 1;
  mirror[flag] = true;
  write(MIRROR_KEY, mirror);
}

// --- Libreria: titoli (film "m|…", serie "s|…") con almeno un episodio/film
// presente nella libreria del profilo, dal più recente.

let libraryCache = null;

export function libraryIds() {
  if (!usingProfile()) return read(LIBRARY_KEY, []).map((e) => e.id);
  if (libraryCache) return libraryCache;
  const latest = new Map();
  for (const [key, e] of Object.entries(mirror.library)) {
    if (e.removed) continue;
    const m = meta.get(byKey.get(key));
    if (m && !(latest.get(m.titleId) >= e.at)) latest.set(m.titleId, e.at);
  }
  libraryCache = [...latest.entries()].sort((a, b) => b[1] - a[1]).map(([id]) => id);
  return libraryCache;
}

export function inLibrary(id) {
  return libraryIds().includes(id);
}

/** Senza `episodeId` tutta la serie; con, solo quell'episodio (quello che si guarda). */
export function addToLibrary(titleId, episodeId = null) {
  if (!usingProfile()) {
    const list = read(LIBRARY_KEY, []);
    if (!list.some((e) => e.id === titleId)) { list.unshift({ id: titleId, added: Date.now() }); write(LIBRARY_KEY, list); }
    return;
  }
  const ids = episodeId ? [episodeId] : [...meta.entries()].filter(([, m]) => m.titleId === titleId).map(([id]) => id);
  const now = Date.now();
  let any = false;
  for (const id of ids) {
    const m = meta.get(id);
    const e = m && mirror.library[m.key];
    if (!m || (e && !e.removed)) continue;
    mirror.library[m.key] = describe(m, now);
    any = true;
  }
  if (!any) return;
  libraryCache = null;
  changed('libraryDirty');
  flush();
}

export function removeFromLibrary(title) {
  if (!usingProfile()) {
    write(LIBRARY_KEY, read(LIBRARY_KEY, []).filter((e) => e.id !== title.id));
    return;
  }
  // Si toglie dalla libreria del profilo: anche da iPhone e Mac (i file
  // scaricati lì restano). Il minutaggio resta.
  const now = Date.now();
  for (const [key, e] of Object.entries(mirror.library)) {
    const m = meta.get(byKey.get(key));
    if (!e.removed && m?.titleId === title.id) mirror.library[key] = { ...e, at: now, removed: true };
  }
  libraryCache = null;
  changed('libraryDirty');
  flush();
}

// --- Progressi: { pos, dur, at, done } per episodio o film.

export function progressOf(id) {
  if (usingProfile()) {
    const m = meta.get(id);
    const e = m && mirror.progress[m.key];
    return e ? { pos: e.pos, dur: e.dur, at: e.at, done: e.done } : null;
  }
  return read(PROGRESS_KEY, {})[id] || null;
}

export function saveProgress(id, pos, dur) {
  // Negli ultimi 2 minuti (o 95%) conta come visto e si riparte da capo.
  const done = dur > 0 && (dur - pos < 120 || pos / dur > 0.95);
  const p = { pos: done ? 0 : Math.floor(pos), dur: Math.floor(dur), at: Date.now(), done };
  if (usingProfile()) {
    const m = meta.get(id);
    if (!m) return;
    mirror.progress[m.key] = { ...describe(m, p.at), pos: p.pos, dur: p.dur, done: p.done };
    changed('progressDirty');
    schedulePush();
    return;
  }
  const progress = read(PROGRESS_KEY, {});
  progress[id] = p;
  write(PROGRESS_KEY, progress);
}

/** L'ultimo episodio/film toccato tra questi id (per "Riprendi"). */
export function lastPlayed(ids) {
  let best = null;
  for (const id of ids) {
    const p = progressOf(id);
    if (p && (!best || p.at > best.at)) best = { id, ...p };
  }
  return best;
}

// --- Sincronizzazione col server

let pushTimer = 0;
let pushing = null;

/** Durante la riproduzione: al massimo una volta ogni 30 secondi. */
function schedulePush() {
  if (!pushTimer) pushTimer = setTimeout(() => { pushTimer = 0; flush(); }, 30000);
}

/** Manda subito al server quello che manca (pausa, chiusura del player, libreria). */
export async function flush() {
  if (pushing) await pushing.catch(() => {});
  if (!usingProfile() || !(mirror.progressDirty || mirror.libraryDirty)) return;
  pushing = (async () => {
    const id = mirror.id;
    const rev = mirror.rev;
    let progress = null;
    let library = null;
    if (mirror.libraryDirty) {
      library = await profiles.fetchLibrary(id);
      profiles.merge(library, mirror.library);
      await profiles.saveLibrary(id, library);
    }
    if (mirror.progressDirty) {
      progress = await profiles.fetchProgress(id);
      profiles.merge(progress, mirror.progress);
      await profiles.saveProgress(id, progress);
    }
    if (mirror?.id !== id) return;
    if (library) profiles.merge(mirror.library, library);
    if (progress) profiles.merge(mirror.progress, progress);
    if (mirror.rev === rev) { mirror.progressDirty = false; mirror.libraryDirty = false; }
    libraryCache = null;
    write(MIRROR_KEY, mirror);
  })();
  try { await pushing; } catch { /* riprova al prossimo cambiamento */ } finally { pushing = null; }
}

const newerThan = (mine, theirs) => Object.entries(mine).some(([k, e]) => !theirs[k] || e.at > theirs[k].at);

/** Legge libreria e minutaggio del profilo dal server (cambiati su iPhone, Mac o un'altra TV). */
export async function pull() {
  if (!usingProfile()) return;
  const id = mirror.id;
  const [library, progress] = await Promise.all([profiles.fetchLibrary(id), profiles.fetchProgress(id)]);
  if (mirror?.id !== id) return;
  if (newerThan(mirror.library, library)) mirror.libraryDirty = true;
  if (newerThan(mirror.progress, progress)) mirror.progressDirty = true;
  profiles.merge(mirror.library, library);
  profiles.merge(mirror.progress, progress);
  libraryCache = null;
  write(MIRROR_KEY, mirror);
  if (mirror.libraryDirty || mirror.progressDirty) await flush();
}

// --- Catalogo in cache: l'app si apre subito, poi si aggiorna dal server.

export function cachedCatalog() {
  return read(CATALOG_KEY, null);
}

export function cacheCatalog(catalog) {
  write(CATALOG_KEY, catalog);
}
