// Catalogo del server: cammina gli elenchi JSON di nginx (autoindex) e
// ricostruisce film / serie / stagioni / episodi con le stesse regole di
// Curfs (FileNameParser + HTTPTreeProvider.classify, portate qui).

export const MEDIA = '/media/';

const VIDEO_EXT = new Set(['mp4', 'm4v', 'mov', 'mkv', 'avi', 'webm', 'ts', 'm2ts']);
const POSTER_EXT = new Set(['jpg', 'jpeg', 'png']);
const MOVIE_BUCKETS = new Set(['film', 'films', 'movie', 'movies', 'cinema', 'pellicole', 'lungometraggi']);
const SERIES_BUCKETS = new Set(['serie', 'series', 'serie tv', 'serietv', 'tv', 'show', 'shows', 'telefilm', 'tvshows']);
const SE_PATTERNS = [/[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})/, /(?<![0-9])(\d{1,2})[xX](\d{2,3})(?![0-9])/];
const RELEASE_TAGS = /\b(1080p|720p|2160p|480p|4k|x264|x265|h264|h265|hevc|web[- ]?dl|webrip|bluray|brrip|bdrip|hdrip|dvdrip|remux|proper|repack|extended|uncut|multi|dl|ita|eng|aac\d*|ac3|dts)\b/gi;

const ext = (name) => (name.includes('.') ? name.split('.').pop().toLowerCase() : '');
const stripExt = (name) => name.replace(/\.[^.]+$/, '');

export function mediaURL(components) {
  return MEDIA + components.map(encodeURIComponent).join('/');
}

function cleanTitle(raw) {
  let s = raw.replace(/[._]/g, ' ')
    .replace(/\[[^\]]*\]/g, '')
    .replace(/\([^)]*\)/g, '')
    .replace(RELEASE_TAGS, '')
    .replace(/-{2,}/g, ' ')
    .replace(/\s{2,}/g, ' ')
    .trim()
    .replace(/^[-_. ]+|[-_. ]+$/g, '');
  return s || raw.trim();
}

function prettify(raw) {
  const s = raw.replace(/[-_]/g, ' ').replace(/\s{2,}/g, ' ').trim();
  if (!s) return raw;
  return s.split(' ').map((w) => (w ? w[0].toLocaleUpperCase() + w.slice(1).toLocaleLowerCase() : w)).join(' ');
}

function seasonEpisode(text) {
  for (const re of SE_PATTERNS) {
    const m = text.match(re);
    if (m) return { season: +m[1], episode: +m[2], index: m.index };
  }
  return null;
}

function seasonInFolder(name) {
  const m = name.match(/(?:season|stagione|serie)\D{0,3}(\d{1,2})/i) || name.match(/(?:^|[^a-zA-Z0-9])[Ss](\d{1,2})(?:[^a-zA-Z0-9]|$)/);
  return m ? +m[1] : null;
}

function bestShowName(folders, seasonIndex) {
  if (seasonIndex != null) return cleanTitle(seasonIndex > 0 ? folders[seasonIndex - 1] : 'Serie');
  return cleanTitle(folders[folders.length - 1] || 'Serie');
}

/** "Oceania (2026).mp4" → "Oceania (2026)": l'anno aiuta a trovare la locandina giusta. */
function movieTitle(nameNoExt) {
  const base = prettify(cleanTitle(nameNoExt));
  const m = nameNoExt.match(/(?<=.)(?:^|[\s.([_-])((?:19|20)\d{2})(?=$|[\s.)\]_-])/);
  if (!m) return base;
  const year = m[1];
  if (base.endsWith(year) && !nameNoExt.includes(`(${year})`) && !nameNoExt.includes(`.${year}.`)) return base;
  let title = base.endsWith(' ' + year) ? base.slice(0, -(year.length + 1)) : base;
  return title ? `${title} (${year})` : base;
}

function classify(node) {
  let folders = node.folders;
  const first = (folders[0] || '').toLowerCase().trim();
  if (MOVIE_BUCKETS.has(first) || SERIES_BUCKETS.has(first)) folders = folders.slice(1);
  const nameNoExt = stripExt(node.name);
  const se = seasonEpisode(nameNoExt);
  if (se) {
    const sIdx = folders.findIndex((f) => seasonInFolder(f) != null);
    const fromFolder = folders.length ? bestShowName(folders, sIdx >= 0 ? sIdx : null) : null;
    const fromName = cleanTitle(nameNoExt.slice(0, se.index));
    let epTitle = nameNoExt;
    for (const re of SE_PATTERNS) epTitle = epTitle.replace(new RegExp(re.source, 'g'), '');
    epTitle = cleanTitle(epTitle);
    return {
      node, kind: 'episode',
      title: epTitle ? prettify(epTitle) : `Episodio ${se.episode}`,
      show: prettify(fromFolder || fromName || 'Serie'),
      season: se.season, episode: se.episode,
    };
  }
  if (folders.length) {
    const sIdx = folders.findIndex((f) => seasonInFolder(f) != null);
    return {
      node, kind: 'episode',
      title: prettify(cleanTitle(nameNoExt)),
      show: prettify(bestShowName(folders, sIdx >= 0 ? sIdx : null)),
      season: sIdx >= 0 ? seasonInFolder(folders[sIdx]) : 1,
      episode: null,
    };
  }
  return { node, kind: 'movie', title: movieTitle(nameNoExt) };
}

/** Una stagione con un solo file senza numero non è una serie; agli altri numeri dall'ordine dei nomi. */
function resolveGroups(items) {
  const groups = new Map();
  items.forEach((item, i) => {
    if (item.kind !== 'episode' || item.episode != null) return;
    const key = `${item.show}|${item.season}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(i);
  });
  for (const indices of groups.values()) {
    if (indices.length === 1) {
      const item = items[indices[0]];
      Object.assign(item, { kind: 'movie', title: movieTitle(stripExt(item.node.name)), show: null, season: null, episode: null });
    } else {
      indices.sort((a, b) => collator.compare(items[a].node.name, items[b].node.name))
        .forEach((idx, n) => { items[idx].episode = n + 1; });
    }
  }
}

const collator = new Intl.Collator('it', { numeric: true, sensitivity: 'base' });

async function list(components) {
  const res = await fetch(mediaURL(components) + (components.length ? '/' : ''), { headers: { Accept: 'application/json' } });
  if (!res.ok) throw new Error(`Il server ha risposto ${res.status}`);
  return res.json();
}

async function walk() {
  const files = [];
  const posters = new Map();
  let queue = [[]];
  let root = true;
  while (queue.length) {
    const batch = queue;
    queue = [];
    const results = await Promise.all(batch.map((c) => list(c).then((entries) => [c, entries], (err) => {
      if (root) throw err;
      return [c, []];
    })));
    root = false;
    for (const [components, entries] of results) {
      for (const entry of entries) {
        if (entry.name.startsWith('.')) continue;
        const child = [...components, entry.name];
        if (entry.type === 'directory') {
          if (child.length <= 8) queue.push(child);
        } else if (VIDEO_EXT.has(ext(entry.name)) && !entry.name.includes('.faststart-tmp.')) {
          files.push({ name: entry.name, folders: components, components: child, path: child.join('/') });
        } else if (POSTER_EXT.has(ext(entry.name))) {
          const base = stripExt(entry.name).toLowerCase();
          if (base === 'poster' || base.endsWith('-poster')) {
            posters.set(child.join('/').toLowerCase(), mediaURL(child) + '?v=' + encodeURIComponent(entry.mtime || ''));
          }
        }
      }
    }
  }
  return { files, posters };
}

function findPoster(posters, folder, baseName) {
  for (const e of POSTER_EXT) {
    const hit = posters.get([...folder, `${baseName}.${e}`].join('/').toLowerCase());
    if (hit) return hit;
  }
  return null;
}

/**
 * Catalogo: { titles: [{ id, kind, name, poster, url?, seasons? }] }.
 * Serie: seasons = [{ number, episodes: [{ id, number, title, url }] }].
 * Gli id sono il percorso del file (episodi/film) o "s|<nome>" (serie): stabili
 * finché non si rinominano i file, e servono a libreria e progressi.
 */
export async function loadCatalog() {
  const { files, posters } = await walk();
  const items = files.map(classify);
  resolveGroups(items);

  const titles = [];
  for (const item of items.filter((i) => i.kind === 'movie')) {
    titles.push({
      id: 'm|' + item.node.path, kind: 'movie', name: item.title, url: mediaURL(item.node.components),
      poster: findPoster(posters, item.node.folders, stripExt(item.node.name) + '-poster'),
    });
  }

  const byShow = new Map();
  for (const item of items.filter((i) => i.kind === 'episode')) {
    if (!byShow.has(item.show)) byShow.set(item.show, []);
    byShow.get(item.show).push(item);
  }
  for (const [show, eps] of byShow) {
    // Copertina della serie: poster.jpg nella cartella comune, o <serie>-poster.jpg.
    let common = eps[0].node.folders;
    for (const e of eps) {
      let n = 0;
      while (n < common.length && n < e.node.folders.length && common[n] === e.node.folders[n]) n++;
      common = common.slice(0, n);
    }
    const poster = (common.length && findPoster(posters, common, 'poster')) || findPoster(posters, common, show + '-poster');

    const bySeason = new Map();
    for (const e of eps) {
      if (!bySeason.has(e.season)) bySeason.set(e.season, []);
      bySeason.get(e.season).push(e);
    }
    const seasons = [...bySeason.entries()].sort((a, b) => a[0] - b[0]).map(([number, list]) => ({
      number,
      episodes: list
        .sort((a, b) => (a.episode ?? 1e9) - (b.episode ?? 1e9) || collator.compare(a.node.name, b.node.name))
        .map((e, i) => ({ id: 'e|' + e.node.path, number: e.episode ?? i + 1, title: e.title, url: mediaURL(e.node.components) })),
    }));
    titles.push({ id: 's|' + show, kind: 'series', name: show, poster, seasons });
  }

  titles.sort((a, b) => collator.compare(a.name, b.name));
  return { titles, loadedAt: Date.now() };
}

/** Tutti gli episodi di una serie in ordine, per l'episodio successivo. */
export function allEpisodes(title) {
  return (title.seasons || []).flatMap((s) => s.episodes.map((e) => ({ ...e, season: s.number })));
}
