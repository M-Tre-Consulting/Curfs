#!/usr/bin/env python3
"""
Sigla e titoli di coda per Curfs TV, calcolati sul server.

La TV non può analizzare i video (web app, niente file locali), ma il server
li ha tutti: qui gira lo stesso riconoscimento di Curfs su iPhone/Mac
(Curfs/Support/AudioFingerprint.swift, VideoMatchVerifier.swift,
FrameHasher.swift, IntroCreditsAnalyzer.swift), portato in Python + ffmpeg:

- impronta audio stile Haitsma-Kalker (8 kHz mono, FFT 2048, 33 bande
  300-2000 Hz, 32 bit ogni 0,1 s) della finestra iniziale (≤ 10 min / 40%) e
  di quella finale (≤ 5 min / 35%), per ogni traccia audio (fino a 3);
- tratto in comune con fino a 3 episodi vicini della stessa serie, provando
  tutti gli sfalsamenti, poi conferma e bordi coi fotogrammi (dHash 8×8);
- consenso tra i vicini (mediana dei bordi).

Se cambiano le regole in Swift, allineare anche qui (e alzare VERSION).

Risultato in <cartella video>/.curfs/intro.json, letto dalla TV:
  {"v": 1, "items": {"Serie/S1/S1E01.mp4": {"intro": [a, b], "credits": [a, b], ...}}}
Impronte in cache in ~/.cache/curfs-intro: ogni volta si ricalcola solo ciò
che è nuovo o cambiato (file con dimensione/data diverse, vicini cambiati).

Risultati mandati da iPhone/Mac (che analizzano gli episodi scaricati, stesso
file del server) in <cartella video>/.curfs/intro-devices/*.json:
  {"v": 1, "path": "Serie/S1/S1E01.mp4", "size": 123, "intro": [a, b], "credits": [a, b]}
valgono al posto dell'analisi qui se la dimensione del file coincide.

Uso: curfs-intro.py CARTELLA_VIDEO [--force] [--merge-only] [--only "Serie/S1/S1E01.mp4"] [--tick]
  --merge-only: solo i risultati dei dispositivi, niente analisi (veloce, va bene ogni pochi minuti).
  --tick: da cron ogni minuto. Analisi notturna all'ora scelta nell'app (.curfs/intro-settings.json,
          prima il faststart), richieste "analizza ora" dell'app (.curfs/intro-requests/), ogni
          10 minuti i risultati dei dispositivi; stato in .curfs/intro-status.json.
Serve python3-numpy (≥ 2.0 per bitwise_count) e ffmpeg.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# numpy si carica solo quando c'è davvero da analizzare (load_numpy): il tick
# gira ogni minuto e quasi sempre non fa niente, così resta leggero.
np = None


def load_numpy():
    global np
    if np is None:
        import numpy
        np = numpy

VERSION = 1          # alzare quando cambia la logica: invalida i risultati
FP_VERSION = 1       # alzare quando cambia l'impronta: invalida la cache

SR = 8000
N = 2048
HOP = 800
RATE = SR / HOP      # codici al secondo
BANDS = 33
MAX_INTRO = 600.0
MAX_CREDITS = 300.0
MIN_DURATION = 90.0
MAX_TRACKS = 3
CLOSE_BITS = 10
MAX_ERROR = 0.38
SMOOTH = 20
MIN_MATCH = 10.0
MAX_SIBLINGS = 3

FRAME_STEP = 0.5
FRAME_MARGIN = 8.0
SAME_FRAME_BITS = 10
DECODE_FPS = 20
MIN_LUMA_RANGE = 14

VIDEO_EXT = {'.mp4', '.m4v', '.mov', '.mkv', '.avi', '.webm', '.ts', '.m2ts'}
BUCKETS = {'film', 'films', 'movie', 'movies', 'cinema', 'pellicole', 'lungometraggi',
           'serie', 'series', 'serie tv', 'serietv', 'tv', 'show', 'shows', 'telefilm', 'tvshows'}
SE_PATTERNS = [re.compile(r'[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})'),
               re.compile(r'(?<![0-9])(\d{1,2})[xX](\d{2,3})(?![0-9])')]
SEASON_FOLDER = [re.compile(r'(?:season|stagione|serie)\D{0,3}(\d{1,2})', re.I),
                 re.compile(r'(?:^|[^a-zA-Z0-9])[Ss](\d{1,2})(?:[^a-zA-Z0-9]|$)')]

CACHE = os.path.expanduser('~/.cache/curfs-intro')


def log(*args):
    print(time.strftime('%Y-%m-%d %H:%M:%S'), *args, flush=True)


# ---------------------------------------------------------------- episodi

def natural_key(s):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r'(\d+)', s)]


def find_episodes(root):
    """Episodi raggruppati per serie: {serie: [ {rel, season, episode} ]}.
    Un file è un episodio se sta in una cartella (i film sono nella radice o
    soli nella loro cartella senza numero di episodio)."""
    by_dir = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith('.')]
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == '.':
            continue
        videos = [f for f in filenames if not f.startswith('.') and '.faststart-tmp.' not in f
                  and os.path.splitext(f)[1].lower() in VIDEO_EXT]
        if videos:
            by_dir[rel_dir] = sorted(videos, key=natural_key)

    series = {}
    for rel_dir, files in by_dir.items():
        folders = rel_dir.split(os.sep)
        if folders[0].lower().strip() in BUCKETS:
            folders = folders[1:]
        if not folders:
            continue
        season_folder = None
        for f in folders:
            for pattern in SEASON_FOLDER:
                m = pattern.search(f)
                if m:
                    season_folder = int(m.group(1))
                    break
            if season_folder is not None:
                break
        show = os.path.join(*rel_dir.split(os.sep)[:len(rel_dir.split(os.sep)) - len(folders) + 1])
        numbered = []
        for i, name in enumerate(files):
            stem = os.path.splitext(name)[0]
            se = None
            for pattern in SE_PATTERNS:
                m = pattern.search(stem)
                if m:
                    se = (int(m.group(1)), int(m.group(2)))
                    break
            numbered.append((se, i, name))
        # Una cartella con un solo file senza numero: è un film.
        if len(files) == 1 and numbered[0][0] is None:
            continue
        for se, i, name in numbered:
            season, episode = se if se else (season_folder or 1, i + 1)
            series.setdefault(show, []).append({
                'rel': os.path.join(rel_dir, name), 'season': season, 'episode': episode,
            })
    return series


def siblings_of(ep, episodes):
    others = [e for e in episodes if e['rel'] != ep['rel']]
    others.sort(key=lambda e: abs(e['season'] - ep['season']) * 1000 + abs(e['episode'] - ep['episode']))
    return others[:MAX_SIBLINGS]


# ---------------------------------------------------------------- ffmpeg

def probe(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=index,codec_type:stream_tags=language',
         '-of', 'json', path], capture_output=True, text=True, check=True).stdout
    info = json.loads(out)
    duration = float(info.get('format', {}).get('duration') or 0)
    audio = []
    for s in info.get('streams', []):
        if s.get('codec_type') == 'audio':
            lang = (s.get('tags') or {}).get('language') or ''
            audio.append({'index': s['index'], 'language': lang if lang and lang != 'und' else f'track{len(audio)}'})
    return duration, audio[:MAX_TRACKS]


def decode_audio(path, tracks, start, end):
    """Audio mono a 8 kHz di [start, end) per ogni traccia, in una passata."""
    with tempfile.TemporaryDirectory() as tmp:
        cmd = ['ffmpeg', '-v', 'error', '-nostdin']
        if start > 0:
            cmd += ['-ss', f'{start:.3f}']
        cmd += ['-t', f'{end - start:.3f}', '-i', path]
        outs = []
        for i, t in enumerate(tracks):
            out = os.path.join(tmp, f'{i}.raw')
            cmd += ['-map', f'0:{t["index"]}', '-ac', '1', '-ar', str(SR), '-f', 'f32le', out]
            outs.append(out)
        subprocess.run(cmd, check=True, capture_output=True)
        return [np.fromfile(o, dtype='<f4') for o in outs]


def decode_frames(path, start, end):
    """Fotogrammi 9×9 in grigi di [start, end], DECODE_FPS al secondo."""
    start = max(0.0, start)
    cmd = ['ffmpeg', '-v', 'error', '-nostdin', '-ss', f'{start:.3f}', '-t', f'{end - start + 0.5:.3f}',
           '-i', path, '-an', '-sn', '-dn',
           '-vf', f'fps={DECODE_FPS},scale=9:9:flags=area,format=gray', '-f', 'rawvideo', '-']
    raw = subprocess.run(cmd, check=True, capture_output=True).stdout
    frames = np.frombuffer(raw, dtype=np.uint8)
    return start, frames[: len(frames) // 81 * 81].reshape(-1, 81)


# ---------------------------------------------------------------- impronta audio

EDGES = [int(300 * (2000 / 300) ** (i / BANDS) / SR * N) for i in range(BANDS + 1)]
_TABLES = None


def tables():
    """Finestra di Hann, bordi delle bande e pesi dei bit (servono numpy)."""
    global _TABLES
    if _TABLES is None:
        load_numpy()
        _TABLES = ((0.5 * (1 - np.cos(2 * np.pi * np.arange(N) / N))).astype(np.float32),
                   np.array(EDGES[:-1]),
                   np.array([max(EDGES[i + 1], EDGES[i] + 1) for i in range(BANDS)]),
                   np.uint64(1) << np.arange(BANDS - 1, dtype=np.uint64))
    return _TABLES


def codes(samples):
    WINDOW, LOWER, UPPER, BIT_VALUES = tables()
    if len(samples) < N:
        return np.zeros(0, dtype=np.uint32)
    frames = np.lib.stride_tricks.sliding_window_view(samples, N)[::HOP]
    energy = np.empty((len(frames), BANDS), dtype=np.float64)
    for c in range(0, len(frames), 512):
        spec = np.fft.rfft(frames[c:c + 512] * WINDOW, axis=1)[:, : N // 2]
        power = spec.real ** 2 + spec.imag ** 2
        cs = np.concatenate([np.zeros((len(power), 1)), np.cumsum(power, axis=1)], axis=1)
        energy[c:c + 512] = cs[:, UPPER] - cs[:, LOWER]
    d = energy[:, :-1] - energy[:, 1:]
    bits = (d[1:] - d[:-1]) > 0
    values = (bits.astype(np.uint64) * BIT_VALUES).sum(axis=1).astype(np.uint32)
    return np.concatenate([np.zeros(1, dtype=np.uint32), values])


def fingerprint(root, rel):
    """{duration, credits_start, tracks: [(lingua, intro, credits)]} o None; in cache."""
    path = os.path.join(root, rel)
    st = os.stat(path)
    key = hashlib.sha1(rel.encode()).hexdigest()
    cache = os.path.join(CACHE, 'fp', key + '.npz')
    stamp = f'{FP_VERSION}|{st.st_size}|{int(st.st_mtime)}'
    if os.path.exists(cache):
        try:
            z = np.load(cache, allow_pickle=False)
            if str(z['stamp']) == stamp:
                if float(z['duration']) < MIN_DURATION:
                    return None
                langs = [str(x) for x in z['langs']]
                return {'duration': float(z['duration']), 'credits_start': float(z['credits_start']),
                        'tracks': [(langs[i], z[f'i{i}'], z[f'c{i}']) for i in range(len(langs))]}
        except Exception:
            pass

    duration, tracks = probe(path)
    result = None
    arrays = {}
    langs = []
    credits_start = 0.0
    if duration >= MIN_DURATION and tracks:
        intro_window = min(MAX_INTRO, duration * 0.40)
        credits_start = max(duration - min(MAX_CREDITS, duration * 0.35), intro_window)
        intro = [codes(s) for s in decode_audio(path, tracks, 0, intro_window)]
        credits = [codes(s) for s in decode_audio(path, tracks, credits_start, duration)]
        langs = [t['language'] for t in tracks]
        for i in range(len(tracks)):
            arrays[f'i{i}'] = intro[i]
            arrays[f'c{i}'] = credits[i]
        result = {'duration': duration, 'credits_start': credits_start,
                  'tracks': [(langs[i], intro[i], credits[i]) for i in range(len(tracks))]}
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    tmp = cache + '.tmp.npz'
    np.savez(tmp, stamp=np.array(stamp), duration=np.array(duration if result else 0.0),
             credits_start=np.array(credits_start), langs=np.array(langs, dtype=str), **arrays)
    os.replace(tmp, cache)
    return result


# ---------------------------------------------------------------- confronto

def runs(a, b, offset, min_length):
    lower, upper = max(0, offset), min(len(a), len(b) + offset)
    if upper - lower <= SMOOTH:
        return []
    i = np.arange(lower, upper)
    best = np.full(len(i), 32, dtype=np.int64)
    for s in (-1, 0, 1):
        j = i - offset + s
        valid = (j >= 0) & (j < len(b))
        d = np.bitwise_count(a[i] ^ b[np.clip(j, 0, len(b) - 1)]).astype(np.int64)
        best = np.minimum(best, np.where(valid, d, 32))
    errors = best / 32.0
    smooth = np.ones(len(errors))
    cs = np.concatenate([[0.0], np.cumsum(errors)])
    k = np.arange(SMOOTH - 1, len(errors))
    smooth[k - SMOOTH // 2] = (cs[k + 1] - cs[k + 1 - SMOOTH]) / SMOOTH
    result = []
    k = 0
    n = len(smooth)
    while k < n:
        if smooth[k] >= MAX_ERROR:
            k += 1
            continue
        start = k
        while k < n and smooth[k] < MAX_ERROR:
            k += 1
        if k - start >= min_length:
            result.append(((start + lower, k + lower, offset), float(errors[start:k].mean())))
    return result


def longest_common(a, b, min_seconds):
    """Tratto in comune (anche a pezzi a sfalsamenti vicini): lista di
    (inizio, fine, sfalsamento) in codici di `a`, o None."""
    if len(a) <= SMOOTH or len(b) <= SMOOTH:
        return None
    nb = len(b)
    scores = np.zeros(len(a) + nb - 1, dtype=np.int64)
    for shift in range(len(scores)):
        offset = shift - (nb - 1)
        lower, upper = max(0, offset), min(len(a), nb + offset)
        if upper <= lower:
            continue
        scores[shift] = np.count_nonzero(np.bitwise_count(a[lower:upper] ^ b[lower - offset:upper - offset]) <= CLOSE_BITS)
    peak = int(np.argmax(scores))
    idx = np.arange(len(scores))
    others = np.sort(scores[np.abs(idx - peak) > 150])[::-1]
    background = float(max(1, others[len(others) // 100])) if len(others) else 1.0
    strength = scores[peak] / background
    if strength < 1.6 or scores[peak] - background < 8 * RATE:
        return None

    main_offset = peak - (nb - 1)
    offsets = [main_offset]
    for shift in range(max(0, peak - 100), min(len(scores) - 1, peak + 100) + 1):
        if shift == peak:
            continue
        window = scores[max(0, shift - 3):min(len(scores) - 1, shift + 3) + 1]
        if np.all(window <= scores[shift]) and scores[shift] >= background * 1.3:
            offsets.append(shift - (nb - 1))

    pieces = []
    for offset in offsets:
        pieces += runs(a, b, offset, int(3 * RATE))
    seeds = [p for p in pieces if p[0][2] == main_offset]
    if not seeds:
        return None
    seed = seeds[0]
    for p in seeds[1:]:
        if p[0][1] - p[0][0] > seed[0][1] - seed[0][0]:
            seed = p

    chosen = [seed[0]]
    gap = int(3 * RATE)
    by_error = sorted(pieces, key=lambda p: p[1])
    added = True
    while added:
        added = False
        lo = min(c[0] for c in chosen)
        hi = max(c[1] for c in chosen)
        for (start, end, offset), _ in by_error:
            if not (end + gap >= lo and start <= hi + gap):
                continue
            fresh = []
            if start < lo:
                fresh.append((start, min(end, lo)))
            if end > hi:
                fresh.append((max(start, hi), end))
            for s, e in fresh:
                if e - s >= int(RATE):
                    chosen.append((s, e, offset))
                    added = True
            if added:
                break

    chosen.sort()
    covered = sum(e - s for s, e, _ in chosen)
    if covered / RATE < min_seconds:
        return None
    return chosen


def best_match(mine, theirs, min_seconds):
    """mine/theirs: [(lingua, codici)]. Prima le coppie nella stessa lingua."""
    pairs = [(i, j) for i in range(len(mine)) for j in range(len(theirs))]
    same = [p for p in pairs if mine[p[0]][0] == theirs[p[1]][0]]
    different = [p for p in pairs if mine[p[0]][0] != theirs[p[1]][0]]
    best = None
    best_covered = 0
    for group in (same, different):
        for i, j in group:
            match = longest_common(mine[i][1], theirs[j][1], min_seconds)
            if not match:
                continue
            covered = sum(e - s for s, e, _ in match)
            if covered > best_covered:
                best, best_covered = match, covered
        if best:
            break
    return best


# ---------------------------------------------------------------- verifica coi fotogrammi

def frame_hash(px):
    if int(px.max()) - int(px.min()) < MIN_LUMA_RANGE:
        return None
    g = px.reshape(9, 9).astype(np.int16)
    bits = (g[:8, :8] < g[:8, 1:9]).reshape(-1)
    return int((bits.astype(np.uint64) << np.arange(64, dtype=np.uint64)).sum())


def hashes_at(path, times):
    start, frames = decode_frames(path, min(times), max(times))
    out = []
    for t in times:
        i = int(round((t - start) * DECODE_FPS))
        out.append(frame_hash(frames[i]) if 0 <= i < len(frames) else None)
    return out


def verify(mine_path, their_path, pieces):
    """pieces: [(inizio s, fine s, sfalsamento s)]. Tratto rifinito, quello
    dell'audio se le immagini non dicono niente, None se sono diverse."""
    lo, hi = pieces[0][0], pieces[-1][1]

    def offset_at(t):
        for s, e, o in pieces:
            if s <= t <= e:
                return o
        return min(pieces, key=lambda p: p[0] - t if t < p[0] else max(0.0, t - p[1]))[2]

    times = []
    t = max(0.0, lo - FRAME_MARGIN)
    while t <= hi + FRAME_MARGIN + 1e-9:
        if t - offset_at(t) >= 0:
            times.append(t)
        t += FRAME_STEP
    if not times:
        return (lo, hi)
    try:
        mine = hashes_at(mine_path, times)
        theirs = hashes_at(their_path, [x - offset_at(x) for x in times])
    except subprocess.CalledProcessError:
        return (lo, hi)

    frames = []
    for a, b in zip(mine, theirs):
        if a is None or b is None:
            frames.append('flat')
        else:
            frames.append('same' if bin(a ^ b).count('1') <= SAME_FRAME_BITS else 'different')

    inside = [i for i, x in enumerate(times) if lo <= x <= hi]
    same = sum(1 for i in inside if frames[i] == 'same')
    different = sum(1 for i in inside if frames[i] == 'different')
    if same + different < 6:
        return (lo, hi)
    if same < 4 or same / (same + different) < 0.25:
        return None

    first_same = next(times[i] for i in range(len(times)) if frames[i] == 'same')
    start = first_same if first_same <= lo + 10 else lo
    end = hi
    last = [i for i in range(len(times)) if frames[i] == 'same' and times[i] >= hi - 10]
    if last:
        i = last[-1]
        while i + 1 < len(times) and frames[i + 1] == 'flat':
            i += 1
        end = max(end, times[i] + FRAME_STEP)
    return (start, end)


def median(values):
    v = sorted(values)
    m = len(v) // 2
    return v[m] if len(v) % 2 else (v[m - 1] + v[m]) / 2


def consensus(ranges):
    if not ranges:
        return None
    if len(ranges) == 1:
        return ranges[0]
    best = []
    for c in ranges:
        group = [r for r in ranges if r[0] <= c[1] and c[0] <= r[1]]
        if len(group) > len(best):
            best = group
    if len(best) < 2:
        return None
    lower = median([r[0] for r in best])
    upper = median([r[1] for r in best])
    return (lower, max(upper, lower))


def analyze(root, ep, siblings):
    mine = fingerprint(root, ep['rel'])
    if not mine:
        return None, None
    intro_candidates = []
    credits_candidates = []
    for sib in siblings:
        theirs = fingerprint(root, sib['rel'])
        if not theirs:
            continue
        match = best_match([(l, i) for l, i, _ in mine['tracks']], [(l, i) for l, i, _ in theirs['tracks']], MIN_MATCH)
        if match:
            pieces = [(s / RATE, e / RATE, o / RATE) for s, e, o in match]
            r = verify(os.path.join(root, ep['rel']), os.path.join(root, sib['rel']), pieces)
            if r:
                intro_candidates.append(r)
        match = best_match([(l, c) for l, _, c in mine['tracks']], [(l, c) for l, _, c in theirs['tracks']], MIN_MATCH)
        if match:
            start = mine['credits_start'] + match[0][0] / RATE
            credits_candidates.append((start, mine['duration']))
    return consensus(intro_candidates), consensus(credits_candidates)


# ---------------------------------------------------------------- main

def signature(root, rels):
    parts = []
    for rel in rels:
        st = os.stat(os.path.join(root, rel))
        parts.append(f'{rel}:{st.st_size}:{int(st.st_mtime)}')
    return hashlib.sha1('|'.join(parts).encode()).hexdigest()[:16]


def device_results(root):
    """{percorso: voce} dai dispositivi, solo se il file ha ancora quella dimensione."""
    folder = os.path.join(root, '.curfs', 'intro-devices')
    result = {}
    try:
        names = os.listdir(folder)
    except OSError:
        return result
    for name in names:
        if not name.endswith('.json'):
            continue
        try:
            with open(os.path.join(folder, name)) as f:
                d = json.load(f)
            rel = d['path']
            if os.path.getsize(os.path.join(root, rel)) != int(d['size']):
                continue
        except (OSError, ValueError, KeyError, TypeError):
            continue
        entry = {}
        for k in ('intro', 'credits'):
            v = d.get(k)
            if isinstance(v, list) and len(v) == 2 and all(isinstance(x, (int, float)) for x in v) and v[0] <= v[1]:
                entry[k] = [round(float(v[0]), 1), round(float(v[1]), 1)]
        if entry:
            result[rel] = (entry, d.get('at', 0))
    return result


# ---------------------------------------------------------------- impostazioni, richieste, stato
#
# Scritti dall'app (iPhone/Mac) con il WebDAV già aperto su .curfs/:
#   .curfs/intro-settings.json        {"time": "HH:MM", "nightly": true}
#   .curfs/intro-requests/<id>.json   {"paths": ["Serie/S1/S1E01.mp4"], "force": false}
#                                     oppure {"all": true}: tutto ciò che è nuovo o cambiato, subito
# Scritto da qui, letto dall'app:
#   .curfs/intro-status.json          {"time", "nightly", "running", "current", "queue", "lastNightly"}

DEFAULT_TIME = '00:00'
CATCH_UP = 6 * 3600   # se all'ora giusta era occupato, recupera entro 6 ore
LOCK_PATH = '/tmp/curfs-intro.lock'


def read_settings(root):
    s = {'time': DEFAULT_TIME, 'nightly': True}
    try:
        with open(os.path.join(root, '.curfs', 'intro-settings.json')) as f:
            d = json.load(f)
        t = str(d.get('time', DEFAULT_TIME))
        h, m = t.split(':')
        if 0 <= int(h) < 24 and 0 <= int(m) < 60:
            s['time'] = f'{int(h):02d}:{int(m):02d}'
        if isinstance(d.get('nightly'), bool):
            s['nightly'] = d['nightly']
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    return s


def pull_requests(root, keep=False):
    """Richieste dell'app: (percorsi, percorsi da rifare anche se già fatti,
    tutta la libreria). Le toglie, a meno di keep."""
    global _last_request
    folder = os.path.join(root, '.curfs', 'intro-requests')
    paths, forced, everything = [], set(), False
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return paths, forced, everything
    for name in names:
        if not name.endswith('.json'):
            continue
        full = os.path.join(folder, name)
        try:
            with open(full) as f:
                d = json.load(f)
            if d.get('all') is True:
                everything = True
            for rel in d.get('paths', []):
                if isinstance(rel, str) and rel not in paths:
                    paths.append(rel)
                    if d.get('force') is True:
                        forced.add(rel)
        except (OSError, ValueError, AttributeError):
            pass
        if not keep:
            try:
                os.remove(full)
            except OSError:
                pass
            _last_request = int(time.time())
    return paths, forced, everything


def tick_state_path():
    return os.path.join(CACHE, 'tick.json')


def load_tick_state():
    try:
        with open(tick_state_path()) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def save_tick_state(state):
    os.makedirs(CACHE, exist_ok=True)
    with open(tick_state_path(), 'w') as f:
        json.dump(state, f)


_last_request = None   # quando questo processo ha preso l'ultima richiesta dell'app


def write_status(root, settings, running, current=None, queue=(), last_nightly=None):
    """Riscrive lo stato solo se è cambiato (il tick gira ogni minuto: niente
    scritture inutili sul disco). `lastRequest` cambia a ogni richiesta presa,
    così l'app sa che il server l'ha vista anche se non c'era niente da fare."""
    path = os.path.join(root, '.curfs', 'intro-status.json')
    try:
        with open(path) as f:
            old = json.load(f)
    except (OSError, ValueError):
        old = {}
    status = {'v': 1, 'time': settings['time'], 'nightly': settings['nightly'],
              'running': running, 'current': current, 'queue': list(queue)[:200],
              'lastNightly': last_nightly,
              'lastRequest': _last_request if _last_request is not None else old.get('lastRequest')}
    if all(old.get(k) == v for k, v in status.items()):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(dict(status, updated=int(time.time())), f, ensure_ascii=False)
    os.replace(tmp, path)


def last_occurrence(hhmm, now):
    """L'ultimo istante <= now in cui è stato HH:MM (oggi o ieri)."""
    h, m = map(int, hhmm.split(':'))
    t = time.localtime(now)
    today = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, h, m, 0, 0, 0, -1))
    if today > now:
        t = time.localtime(now - 86400)
        today = time.mktime((t.tm_year, t.tm_mon, t.tm_mday, h, m, 0, 0, 0, -1))
    return today


# ---------------------------------------------------------------- analisi

def run(root, mode='full', only=None, force=False, settings=None, last_nightly=None):
    """mode: 'full' (tutto ciò che è nuovo o cambiato + richieste),
    'requests' (solo le richieste dell'app), 'merge' (solo i risultati dei dispositivi)."""
    settings = settings or read_settings(root)
    out_path = os.path.join(root, '.curfs', 'intro.json')
    try:
        with open(out_path) as f:
            data = json.load(f)
        if data.get('v') != VERSION:
            data = {'v': VERSION, 'items': {}}
    except Exception:
        data = {'v': VERSION, 'items': {}}
    items = data['items']

    series = find_episodes(root)
    known = {}        # rel -> (ep, sibs, sig)
    todo = []
    for show, episodes in sorted(series.items()):
        for ep in sorted(episodes, key=lambda e: (e['season'], e['episode'])):
            sibs = siblings_of(ep, episodes)
            sig = signature(root, [ep['rel']] + [s['rel'] for s in sibs])
            known[ep['rel']] = (ep, sibs, sig)
            if mode != 'full' or (only and ep['rel'] not in only):
                continue
            if not force and items.get(ep['rel'], {}).get('sig') == sig:
                continue
            todo.append((ep, sibs, sig))

    removed = [k for k in items if k not in known]
    for k in removed:
        del items[k]

    forced = set(known) if force and mode == 'full' else set()

    def save():
        data['updated'] = int(time.time())
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        tmp = out_path + '.tmp'
        with open(tmp, 'w') as f:
            json.dump(data, f, ensure_ascii=False, separators=(',', ':'), sort_keys=True)
        os.replace(tmp, out_path)

    def done(rel, sig):
        return rel not in forced and items.get(rel, {}).get('sig') == sig

    def take_from_devices():
        """Risultati dei dispositivi per gli episodi ancora da fare: niente analisi qui."""
        taken = 0
        devices = device_results(root)
        for ep, sibs, sig in todo:
            hit = devices.get(ep['rel'])
            if not hit or ep['rel'] in forced or (items.get(ep['rel'], {}).get('sig') == sig and items[ep['rel']].get('at') == hit[1]):
                continue
            items[ep['rel']] = dict(hit[0], sig=sig, src='device', at=hit[1])
            taken += 1
        return taken

    def take_requests():
        """Le richieste dell'app passano in testa."""
        if mode == 'merge':
            return 0
        paths, force_paths, _ = pull_requests(root)
        added = 0
        front = []
        for rel in paths:
            if rel not in known:
                continue
            ep, sibs, sig = known[rel]
            if rel in force_paths:
                forced.add(rel)
            elif items.get(rel, {}).get('sig') == sig:
                continue   # già fatto, niente da rifare
            todo[:] = [x for x in todo if x[0]['rel'] != rel]
            front.append((ep, sibs, sig))
            added += 1
        todo[:0] = front
        if added:
            log(f'{added} episodi chiesti dall\'app')
        return added

    take_requests()
    changed = take_from_devices()
    todo[:] = [x for x in todo if not done(x[0]['rel'], x[2])]
    if changed or removed:
        save()
        if changed:
            log(f'{changed} episodi dai dispositivi')
    if mode == 'merge' or not todo:
        return
    load_numpy()
    log(f'{len(todo)} episodi da analizzare')
    n = 0
    while todo:
        take_requests()
        # Nel frattempo un dispositivo può averlo già analizzato.
        if take_from_devices():
            save()
        ep, sibs, sig = todo.pop(0)
        if done(ep['rel'], sig):
            continue
        n += 1
        write_status(root, settings, True, ep['rel'], [x[0]['rel'] for x in todo], last_nightly)
        started = time.time()
        try:
            intro, credits = analyze(root, ep, sibs)
        except (subprocess.CalledProcessError, OSError, ValueError) as e:
            log(f'[{n}] {ep["rel"]}: errore {e}')
            forced.discard(ep['rel'])
            continue
        entry = {'sig': sig}
        if intro:
            entry['intro'] = [round(intro[0], 1), round(intro[1], 1)]
        if credits:
            entry['credits'] = [round(credits[0], 1), round(credits[1], 1)]
        items[ep['rel']] = entry
        forced.discard(ep['rel'])
        save()  # un episodio alla volta: la TV vede subito quelli pronti
        log(f'[{n}, {len(todo)} in coda] {ep["rel"]}: sigla {entry.get("intro")} coda {entry.get("credits")}'
            f' ({time.time() - started:.0f} s)')


def tick(root, faststart):
    """Da cron ogni minuto: analisi notturna all'ora scelta nell'app, richieste
    "analizza ora", e ogni 10 minuti i risultati dei dispositivi."""
    import fcntl
    lock = open(LOCK_PATH, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # c'è già un'analisi: le richieste le prende lei
    settings = read_settings(root)
    now = time.time()
    state = load_tick_state()
    if state is None:
        state = {'lastNightly': now}
        save_tick_state(state)
    last = state.get('lastNightly')
    scheduled = last_occurrence(settings['time'], now)
    due = settings['nightly'] and (last or 0) < scheduled and now - scheduled < CATCH_UP
    try:
        if due:
            state['lastNightly'] = now
            save_tick_state(state)
            write_status(root, settings, True, None, [], now)
            log(f'analisi notturna delle {settings["time"]}')
            if faststart and os.path.exists(faststart):
                with open(os.path.expanduser('~/curfs-faststart.log'), 'a') as out:
                    subprocess.run(['bash', faststart, root], stdout=out, stderr=out)
            run(root, 'full', settings=settings, last_nightly=now)
        else:
            paths, _, everything = pull_requests(root, keep=True)
            if everything:
                log('analisi di tutta la libreria chiesta dall\'app')
                run(root, 'full', settings=settings, last_nightly=last)
            elif paths:
                run(root, 'requests', settings=settings, last_nightly=last)
            elif time.localtime(now).tm_min % 10 == 0:
                run(root, 'merge', settings=settings, last_nightly=last)
    finally:
        write_status(root, settings, False, None, [], state.get('lastNightly'))


def main():
    ap = argparse.ArgumentParser(description='Sigla e titoli di coda per Curfs TV')
    ap.add_argument('root')
    ap.add_argument('--force', action='store_true', help='ricalcola tutto (le impronte restano in cache)')
    ap.add_argument('--only', action='append', help='solo questi episodi (percorso relativo)')
    ap.add_argument('--merge-only', action='store_true', help='solo i risultati dei dispositivi')
    ap.add_argument('--tick', action='store_true', help='da cron ogni minuto: orario e richieste dall\'app')
    ap.add_argument('--faststart', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'curfs-faststart.sh'),
                    help='script faststart da lanciare prima dell\'analisi notturna (--tick)')
    args = ap.parse_args()
    root = os.path.abspath(args.root)
    if args.tick:
        return tick(root, args.faststart)
    run(root, 'merge' if args.merge_only else 'full', only=args.only, force=args.force)


if __name__ == '__main__':
    sys.exit(main())
