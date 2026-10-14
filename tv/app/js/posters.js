// Locandine per i titoli senza una copertina sul server, come in Curfs:
// 1. Wikipedia riconosce il titolo (anche italiano: "Oceania" → "Moana") e
//    dà il titolo inglese;
// 2. IMDb dà la locandina grande cercando quel titolo — passa dal server
//    (`/imdb/`, proxy di nginx) perché IMDb non accetta richieste dal browser
//    della TV; se il proxy non c'è si salta;
// 3. iTunes come ultima riserva.
// Risultati (anche "non trovata") in cache nella TV.

const CACHE_KEY = 'curfs.posters.v1';
let cache = null;

function load() {
  if (!cache) {
    try { cache = JSON.parse(localStorage.getItem(CACHE_KEY) || '{}'); } catch { cache = {}; }
  }
  return cache;
}

function persist() {
  try { localStorage.setItem(CACHE_KEY, JSON.stringify(cache)); } catch { /* ignora */ }
}

const normalize = (s) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]/g, '');

async function getJSON(url, ms = 8000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    const res = await fetch(url, { signal: ctrl.signal });
    if (!res.ok) throw new Error(String(res.status));
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

function splitYear(name) {
  const m = name.match(/^(.*?)\s*\((\d{4})\)\s*$/);
  return m ? { title: m[1], year: m[2] } : { title: name, year: null };
}

/** Titolo inglese (e anno) della voce Wikipedia che corrisponde al titolo. */
async function englishTitle(title, year, kind) {
  const wanted = normalize(title);
  const hint = kind === 'movie' ? 'film' : 'serie televisiva';
  const search = await getJSON(`https://it.wikipedia.org/w/api.php?action=query&list=search&srlimit=8&format=json&origin=*&srsearch=${encodeURIComponent(`${title} ${hint}`)}`);
  const pages = (search.query?.search || []).map((p) => p.title);
  const matching = pages.filter((t) => normalize(t.replace(/\s*\([^)]*\)\s*$/, '')) === wanted);
  const page = (year && matching.find((t) => t.includes(year))) || matching.find((t) => !/\(/.test(t))
    || matching.find((t) => /\((film|serie|miniserie)/i.test(t));
  if (!page) return null;
  const links = await getJSON(`https://it.wikipedia.org/w/api.php?action=query&prop=langlinks&lllang=en&format=json&origin=*&titles=${encodeURIComponent(page)}`);
  const first = Object.values(links.query?.pages || {})[0];
  const en = first?.langlinks?.[0]?.['*'];
  if (!en) return null;
  const enYear = en.match(/\b((?:19|20)\d{2})\b/);
  return { title: en.replace(/\s*\([^)]*\)\s*$/, ''), year: year || (enYear && enYear[1]) };
}

async function imdb(title, year, kind) {
  const q = title.toLowerCase().replace(/\//g, ' ');
  const first = (q.match(/[a-z0-9]/) || ['x'])[0];
  const data = await getJSON(`/imdb/${/[a-z]/.test(first) ? first : 'x'}/${encodeURIComponent(q)}.json`);
  const types = kind === 'movie' ? ['movie', 'tvMovie'] : ['tvSeries', 'tvMiniSeries'];
  const wanted = normalize(title);
  const candidates = (data.d || []).filter((d) => d.i && d.i.width > 0 && types.includes(d.qid)
    && normalize(d.l || '') === wanted && d.i.height >= d.i.width * 1.2);
  const y = year ? +year : null;
  const hit = y ? (candidates.find((d) => d.y === y) || candidates.find((d) => Math.abs((d.y || 0) - y) === 1)) : candidates[0];
  return hit ? hit.i.imageUrl.replace('._V1_.jpg', '._V1_UX600_.jpg') : null;
}

async function itunes(title, kind) {
  const data = await getJSON(`https://itunes.apple.com/search?country=it&limit=25&term=${encodeURIComponent(title)}`);
  const wanted = normalize(title);
  const hit = (data.results || []).find((r) => {
    if (kind === 'movie') return r.kind === 'feature-movie' && normalize(r.trackName || '') === wanted;
    const names = [r.artistName, (r.collectionName || '').replace(/,\s*(season|stagione).*$/i, '')];
    return (r.kind === 'tv-episode' || r.kind === 'tv-season' || r.wrapperType === 'collection') && names.some((n) => normalize(n || '') === wanted);
  });
  return hit?.artworkUrl100 ? hit.artworkUrl100.replace('100x100bb', '600x900bb') : null;
}

async function resolve(name, kind) {
  const { title, year } = splitYear(name);
  let failed = false;
  const attempt = async (fn) => {
    try { return await fn(); } catch { failed = true; return null; }
  };
  const en = await attempt(() => englishTitle(title, year, kind));
  const names = [...new Set([en?.title, title].filter(Boolean))];
  for (const n of names) {
    const url = await attempt(() => imdb(n, en?.title === n ? en.year : year, kind));
    if (url) return { url, keep: true };
  }
  const url = await attempt(() => itunes(title, kind));
  // Una riserva trovata mentre una fonte migliore era irraggiungibile non
  // si fissa in cache: si riprova la prossima volta (stesso bug di Curfs 2.3.5).
  return { url, keep: !failed };
}

const pending = new Map();

/** URL della locandina (o null), dalla cache o cercandola. */
export function posterFor(name, kind) {
  const key = `${kind}|${name.toLowerCase()}`;
  const cached = load()[key];
  if (cached !== undefined) return Promise.resolve(cached);
  if (!pending.has(key)) {
    pending.set(key, resolve(name, kind).then(({ url, keep }) => {
      if (keep) { load()[key] = url; persist(); }
      pending.delete(key);
      return url;
    }));
  }
  return pending.get(key);
}
