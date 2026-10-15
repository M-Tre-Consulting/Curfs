// Profili di Curfs sul server: si creano da iPhone/Mac (nome e foto), la TV
// può solo sceglierne uno. Il profilo porta con sé il minutaggio, condiviso
// con gli altri dispositivi. Struttura sul server (vedi ProfileModels.swift):
//
//   /media/.curfs/profiles/<id>/profile.json   { id, name, avatar?, created? }
//   /media/.curfs/profiles/<id>/avatar.jpg
//   /media/.curfs/profiles/<id>/progress.json  { version, entries: { <chiave>: voce } }
//   /media/.curfs/profiles/<id>/library.json   { version, items: { <chiave>: voce } }
//
// voce minutaggio = { pos, dur, done, at (ms), kind, title, show?, season?, episode?, path? }
// voce libreria   = { at (ms), removed?, kind, title, show?, season?, episode?, path? }
// La TV scrive solo progress.json e library.json (nginx non le permette altro).

import { MEDIA } from './catalog.js';

const ROOT = MEDIA + '.curfs/profiles/';

/** Stessa normalizzazione di SyncKey.normalized in Swift. */
export function normalized(name) {
  return String(name || '')
    .replace(/\s*\((19|20)\d{2}\)\s*$/, '')
    .normalize('NFD').replace(/\p{M}/gu, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, '');
}

export function episodeKey(show, season, episode) {
  return `e:${normalized(show)}:${season}:${episode}`;
}

export function movieKey(title) {
  return `m:${normalized(title)}`;
}

const folder = (id) => ROOT + encodeURIComponent(id) + '/';

export function avatarURL(profile) {
  return profile && profile.avatar != null ? `${folder(profile.id)}avatar.jpg?v=${profile.avatar}` : null;
}

export async function listProfiles() {
  const res = await fetch(ROOT, { headers: { Accept: 'application/json' }, cache: 'no-store' });
  if (res.status === 404) return [];
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const dirs = (await res.json()).filter((e) => e.type === 'directory').map((e) => e.name);
  const profiles = await Promise.all(dirs.map((id) => fetch(folder(id) + 'profile.json', { cache: 'no-store' })
    .then((r) => (r.ok ? r.json() : null))
    .catch(() => null)));
  return profiles.filter(Boolean)
    .sort((a, b) => (a.created || 0) - (b.created || 0) || String(a.name).localeCompare(b.name));
}

async function fetchEntries(id, file, field) {
  const res = await fetch(folder(id) + file, { cache: 'no-store' });
  if (res.status === 404) return {};
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  try {
    return (await res.json())[field] || {};
  } catch {
    return {};
  }
}

async function saveEntries(id, file, field, entries) {
  const res = await fetch(folder(id) + file, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ version: 1, [field]: entries }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
}

export const fetchProgress = (id) => fetchEntries(id, 'progress.json', 'entries');
export const saveProgress = (id, entries) => saveEntries(id, 'progress.json', 'entries', entries);
export const fetchLibrary = (id) => fetchEntries(id, 'library.json', 'items');
export const saveLibrary = (id, items) => saveEntries(id, 'library.json', 'items', items);

/** Unisce `incoming` a `base` (vince la voce più recente). Restituisce true se `base` è cambiato. */
export function merge(base, incoming) {
  let changed = false;
  for (const [key, entry] of Object.entries(incoming)) {
    const existing = base[key];
    if (!existing || entry.at > existing.at) {
      base[key] = existing && !entry.path && existing.path ? { ...entry, path: existing.path } : entry;
      changed = true;
    } else if (!existing.path && entry.path) {
      existing.path = entry.path;
      changed = true;
    }
  }
  return changed;
}
