// Libreria e progressi, salvati nella TV (localStorage). Piccoli JSON: la TV
// non scarica video, tiene solo cosa hai aggiunto e dove eri arrivato.

const LIBRARY_KEY = 'curfs.library';
const PROGRESS_KEY = 'curfs.progress';
const CATALOG_KEY = 'curfs.catalog';

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
  // Via anche i progressi: tolto dalla libreria = visto, non serve più.
  const progress = read(PROGRESS_KEY, {});
  const ids = title.kind === 'series'
    ? (title.seasons || []).flatMap((s) => s.episodes.map((e) => e.id))
    : [title.id];
  ids.forEach((id) => delete progress[id]);
  write(PROGRESS_KEY, progress);
}

// --- Progressi: { [id]: { pos, dur, at, done } } per episodio o film.

export function progressOf(id) {
  return read(PROGRESS_KEY, {})[id] || null;
}

export function saveProgress(id, pos, dur) {
  const progress = read(PROGRESS_KEY, {});
  // Negli ultimi 2 minuti (o 95%) conta come visto e si riparte da capo.
  const done = dur > 0 && (dur - pos < 120 || pos / dur > 0.95);
  progress[id] = { pos: done ? 0 : Math.floor(pos), dur: Math.floor(dur), at: Date.now(), done };
  write(PROGRESS_KEY, progress);
}

/** L'ultimo episodio/film toccato tra questi id (per "Riprendi"). */
export function lastPlayed(ids) {
  const progress = read(PROGRESS_KEY, {});
  let best = null;
  for (const id of ids) {
    const p = progress[id];
    if (p && (!best || p.at > best.at)) best = { id, ...p };
  }
  return best;
}

// --- Catalogo in cache: l'app si apre subito, poi si aggiorna dal server.

export function cachedCatalog() {
  return read(CATALOG_KEY, null);
}

export function cacheCatalog(catalog) {
  write(CATALOG_KEY, catalog);
}
