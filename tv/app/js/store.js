// Libreria e progressi. La libreria sta nella TV (localStorage); i progressi
// sono del profilo (obbligatorio) e stanno sul server insieme a quelli di
// iPhone e Mac (vedi profiles.js), con una copia qui per aprire tutto subito
// e per non perdere nulla se il server non risponde. I progressi "locali"
// (di prima dei profili) si cancellano alla prima scelta di un profilo.

import * as profiles from './profiles.js';

const LIBRARY_KEY = 'curfs.library';
const PROGRESS_KEY = 'curfs.progress';
const CATALOG_KEY = 'curfs.catalog';
const PROFILE_KEY = 'curfs.profile';
const MIRROR_KEY = 'curfs.profileProgress';
const APPLIED_KEY = 'curfs.profileApplied';

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

// --- Libreria: id dei titoli (film "m|…", serie "s|…") con la data di aggiunta.

export function libraryIds() {
  return read(LIBRARY_KEY, []).map((e) => e.id);
}

export function inLibrary(id) {
  return libraryIds().includes(id);
}

export function addToLibrary(id) {
  const list = read(LIBRARY_KEY, []);
  if (!list.some((e) => e.id === id)) {
    list.unshift({ id, added: Date.now() });
    write(LIBRARY_KEY, list);
  }
}

export function removeFromLibrary(title) {
  write(LIBRARY_KEY, read(LIBRARY_KEY, []).filter((e) => e.id !== title.id));
  // Senza profilo via anche i progressi: tolto dalla libreria = visto, non
  // serve più. Con un profilo restano: sono anche degli altri dispositivi.
  if (activeProfile()) return;
  const progress = read(PROGRESS_KEY, {});
  const ids = title.kind === 'series'
    ? (title.seasons || []).flatMap((s) => s.episodes.map((e) => e.id))
    : [title.id];
  ids.forEach((id) => delete progress[id]);
  write(PROGRESS_KEY, progress);
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
}

function add(id, m) {
  meta.set(id, m);
  if (!byKey.has(m.key)) byKey.set(m.key, id);
}

// --- Profilo scelto su questa TV

let mirror = read(MIRROR_KEY, null); // { id, entries, rev, dirty }

export function activeProfile() {
  return read(PROFILE_KEY, null);
}

/** Nome/foto aggiornati da iPhone o Mac. */
export function refreshProfile(profile) {
  if (activeProfile()?.id === profile.id) write(PROFILE_KEY, profile);
}

/** `null` solo quando il profilo è stato cancellato da iPhone/Mac. */
export function setProfile(profile) {
  if (!profile) {
    write(PROFILE_KEY, null);
    mirror = null;
    write(MIRROR_KEY, null);
    return;
  }
  if (mirror?.id === profile.id) { write(PROFILE_KEY, profile); return; }
  mirror = { id: profile.id, entries: {}, rev: 0, dirty: false };
  // Il minutaggio di prima dei profili, salvato solo sulla TV, non passa al
  // profilo (che ha già quello di iPhone/Mac): si butta.
  write(PROGRESS_KEY, {});
  write(PROFILE_KEY, profile);
  write(MIRROR_KEY, mirror);
}

function entryFor(m, pos, dur, done, at) {
  const entry = { pos, dur, done, at, kind: m.kind, title: m.title, path: m.path };
  if (m.kind === 'episode') Object.assign(entry, { show: m.show, season: m.season, episode: m.episode });
  return entry;
}

function usingProfile() {
  return mirror && activeProfile()?.id === mirror.id;
}

// --- Progressi: { pos, dur, at, done } per episodio o film.

export function progressOf(id) {
  if (usingProfile()) {
    const m = meta.get(id);
    const e = m && mirror.entries[m.key];
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
    mirror.entries[m.key] = entryFor(m, p.pos, p.dur, p.done, p.at);
    mirror.rev += 1;
    mirror.dirty = true;
    write(MIRROR_KEY, mirror);
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

/** Manda subito al server quello che manca (pausa, chiusura del player). */
export async function flush() {
  if (pushing) await pushing.catch(() => {});
  if (!usingProfile() || !mirror.dirty) return;
  pushing = (async () => {
    const id = mirror.id;
    const rev = mirror.rev;
    const remote = await profiles.fetchProgress(id);
    profiles.merge(remote, mirror.entries);
    await profiles.saveProgress(id, remote);
    if (mirror?.id !== id) return;
    profiles.merge(mirror.entries, remote);
    if (mirror.rev === rev) mirror.dirty = false;
    write(MIRROR_KEY, mirror);
  })();
  try { await pushing; } catch { /* riprova al prossimo salvataggio */ } finally { pushing = null; }
}

/**
 * Legge il minutaggio del profilo dal server. I titoli guardati altrove dopo
 * l'ultima lettura entrano in libreria, come se li avessi guardati qui.
 */
export async function pull() {
  if (!usingProfile()) return;
  const id = mirror.id;
  const remote = await profiles.fetchProgress(id);
  if (mirror?.id !== id) return;
  const localNewer = Object.entries(mirror.entries).some(([k, e]) => !remote[k] || e.at > remote[k].at);
  // Le voci che questa TV conosce già (magari le ha scritte lei) non
  // rimettono in libreria un titolo tolto.
  const known = new Set(Object.entries(remote).filter(([k, e]) => mirror.entries[k]?.at >= e.at).map(([k]) => k));
  profiles.merge(mirror.entries, remote);
  if (localNewer) mirror.dirty = true;
  write(MIRROR_KEY, mirror);

  const applied = read(APPLIED_KEY, {});
  const since = applied[id] || 0;
  let newest = since;
  for (const [key, e] of Object.entries(remote)) {
    newest = Math.max(newest, e.at);
    if (e.at <= since || known.has(key)) continue;
    const m = meta.get(byKey.get(key));
    if (m) addToLibrary(m.titleId);
  }
  applied[id] = newest;
  write(APPLIED_KEY, applied);
  if (mirror.dirty) await flush();
}

// --- Catalogo in cache: l'app si apre subito, poi si aggiorna dal server.

export function cachedCatalog() {
  return read(CATALOG_KEY, null);
}

export function cacheCatalog(catalog) {
  write(CATALOG_KEY, catalog);
}
