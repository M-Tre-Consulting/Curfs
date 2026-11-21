// Player di Curfs TV, pensato per il telecomando.
//
// - ← → vanno avanti/indietro: i tocchi ravvicinati si sommano e tenendo
//   premuto si accelera (10 s, poi 30, 60, 2 min a passo). Il salto si fa una
//   volta sola quando ci si ferma (ogni salto è una richiesta al server), nel
//   frattempo la barra mostra dove si arriverà. OK salta subito, Indietro annulla.
// - Tasti numerici: 1-9 = 10%-90%, 0 = dall'inizio.
// - ↑/↓ aprono la fila dei comandi: pausa, episodio precedente/successivo,
//   elenco episodi, lingua audio, opzioni (velocità, sigla saltata da sola).
// - "Salta intro" e "Prossimo episodio" ai titoli di coda: sigla e coda le
//   riconosce il server (tv/server/curfs-intro.py, stesso algoritmo di Curfs su
//   iPhone e Mac) e le scrive in /media/.curfs/intro.json.
//
// Sulla TV la GPU è debole: si muovono solo transform/opacity e la barra si
// aggiorna solo quando è visibile.

import * as store from './store.js';
import { MEDIA } from './catalog.js';
import { t, lang } from './i18n.js';
import { focus, focused, setScope } from './focus.js';

const KEY = {
  LEFT: 37, UP: 38, RIGHT: 39, DOWN: 40, OK: 13,
  PLAY: 415, PAUSE: 19, PLAY_PAUSE: 179, STOP: 413, FF: 417, RW: 412,
  NEXT: 425, PREV: 424, CH_UP: 427, CH_DOWN: 428, PAGE_UP: 33, PAGE_DOWN: 34,
};

const ICONS = {
  play: 'M8 5.5v13a1 1 0 0 0 1.5.86l10.5-6.5a1 1 0 0 0 0-1.72L9.5 4.64A1 1 0 0 0 8 5.5z',
  pause: 'M7 5h3.5v14H7zM13.5 5H17v14h-3.5z',
  prev: 'M6 5h2.5v14H6zM19 5.6v12.8a.8.8 0 0 1-1.2.7L9.5 12.7a.8.8 0 0 1 0-1.4l8.3-6.4a.8.8 0 0 1 1.2.7z',
  next: 'M15.5 5H18v14h-2.5zM5 5.6v12.8a.8.8 0 0 0 1.2.7l8.3-6.4a.8.8 0 0 0 0-1.4L6.2 4.9A.8.8 0 0 0 5 5.6z',
  list: 'M4 6h3v3H4zM9 6.5h11v2H9zM4 10.5h3v3H4zM9 11h11v2H9zM4 15h3v3H4zM9 15.5h11v2H9z',
  audio: 'M4 9h4l5-4v14l-5-4H4zM16 8.5a5 5 0 0 1 0 7l-1.4-1.4a3 3 0 0 0 0-4.2zM18.5 6a8.5 8.5 0 0 1 0 12l-1.4-1.4a6.5 6.5 0 0 0 0-9.2z',
  gear: 'M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7zm8.4 5-.1-3 2-1.6-2-3.4-2.4.9-2.6-1.5L15 2.5h-4l-.4 2.4L8 6.4l-2.4-.9-2 3.4 2 1.6-.1 1.5.1 1.5-2 1.6 2 3.4 2.4-.9 2.6 1.5.4 2.4h4l.4-2.4 2.6-1.5 2.4.9 2-3.4z',
  restart: 'M12 5V2L7 6l5 4V7a5 5 0 1 1-5 5H5a7 7 0 1 0 7-7z',
  skip: 'M5 5.6v12.8a.8.8 0 0 0 1.2.7L13 13.6v4.8a.8.8 0 0 0 1.2.7l8-6.4a.8.8 0 0 0 0-1.4l-8-6.4A.8.8 0 0 0 13 5.6v4.8L6.2 4.9A.8.8 0 0 0 5 5.6z',
};

// ---------- sigla e coda dal server

let introData = null;
let introAt = 0;

/** /media/.curfs/intro.json: { items: { "Serie/S1/S1E01.mp4": { intro: [a, b], credits: [a, b] } } } */
async function loadIntroData() {
  if (introData && Date.now() - introAt < 5 * 60 * 1000) return introData;
  try {
    const res = await fetch(MEDIA + '.curfs/intro.json', { cache: 'no-store' });
    if (res.ok) { introData = (await res.json()).items || {}; introAt = Date.now(); }
  } catch { /* niente sigla: il player funziona lo stesso */ }
  return introData || {};
}

// ---------- preferenze del player (solo su questa TV)

function pref(key, fallback) {
  try { const v = localStorage.getItem('curfs.player.' + key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
}
function setPref(key, value) {
  try { localStorage.setItem('curfs.player.' + key, JSON.stringify(value)); } catch { /* pazienza */ }
}

const SPEEDS = [0.75, 1, 1.25, 1.5, 2];

/**
 * Apre il player. `ui` passa le utilità di app.js:
 * { h, fmt, code, push, pop, isBack, state, episodes }.
 */
export function openPlayer(title, episode, ui) {
  const { h, fmt, code, push, pop, isBack, state } = ui;
  const episodes = ui.episodes || [];
  let current = episode;

  const icon = (name) => {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
    path.setAttribute('d', ICONS[name]);
    svg.append(path);
    return svg;
  };

  // ---------- struttura

  const video = h('video', { class: 'video', preload: 'auto' });
  const spinner = h('div', { class: 'spinner center' });

  const topTitle = h('div', { class: 'p-title' });
  const topSub = h('div', { class: 'p-sub' });
  const clock = h('div', { class: 'p-clock' });
  const top = h('div', { class: 'p-top' }, h('div', { class: 'p-heading' }, topTitle, topSub), clock);

  const played = h('div', { class: 'p-played' });
  const buffered = h('div', { class: 'p-buffered' });
  const introMark = h('div', { class: 'p-mark intro hidden' });
  const creditsMark = h('div', { class: 'p-mark credits hidden' });
  const thumb = h('div', { class: 'p-thumb' });
  const bubble = h('div', { class: 'p-bubble hidden' });
  const track = h('div', { class: 'p-track' }, buffered, introMark, creditsMark, played);
  const bar = h('div', { class: 'f p-bar', dataset: { key: 'bar' } }, track, thumb, bubble);
  const timeLeft = h('span', { class: 'p-time' });
  const timeRight = h('span', { class: 'p-time right' });
  const hint = h('div', { class: 'p-hint' });

  const playBtn = h('button', { class: 'f p-btn round', dataset: { key: 'play' } });
  const prevBtn = h('button', { class: 'f p-btn', dataset: { key: 'prev' } }, icon('prev'), h('span', {}, t('Precedente')));
  const nextBtn = h('button', { class: 'f p-btn', dataset: { key: 'next' } }, icon('next'), h('span', {}, t('Prossimo episodio')));
  const restartBtn = h('button', { class: 'f p-btn', dataset: { key: 'restart' } }, icon('restart'), h('span', {}, t('Dall’inizio')));
  const listBtn = h('button', { class: 'f p-btn', dataset: { key: 'list' } }, icon('list'), h('span', {}, t('Episodi')));
  const audioBtn = h('button', { class: 'f p-btn', dataset: { key: 'audio' } }, icon('audio'), h('span', {}, t('Audio')));
  const optionsBtn = h('button', { class: 'f p-btn', dataset: { key: 'options' } }, icon('gear'), h('span', {}, t('Opzioni')));
  const buttons = h('div', { class: 'p-buttons' });

  const bottom = h('div', { class: 'p-bottom' },
    bar, h('div', { class: 'p-times' }, timeLeft, hint, timeRight), buttons);

  const seekBadge = h('div', { class: 'p-seek hidden' });
  const skipPill = h('div', { class: 'p-skip hidden' }, icon('skip'), h('span', {}, t('Salta intro')), h('em', {}, 'OK'));
  const nextCard = h('div', { class: 'p-next hidden' });
  const panel = h('div', { class: 'p-panel hidden' });
  const toast = h('div', { class: 'p-toast hidden' });
  const shade = h('div', { class: 'p-shade' });

  const root = h('div', { class: 'player osd-off' },
    video, shade, spinner, top, bottom, seekBadge, skipPill, nextCard, panel, toast);

  // ---------- stato

  let osdVisible = false;
  let hideTimer = 0;
  let saveTimer = 0;
  let clockTimer = 0;
  let toastTimer = 0;
  let panelOpen = null;      // 'list' | 'audio' | 'options'
  let segments = null;       // { intro: [a, b], credits: [a, b] } dell'episodio corrente
  let introSkipped = false;  // sigla saltata in automatico (una volta per episodio)
  let nextDismissed = false; // "Prossimo episodio" chiuso con Indietro (finché non si esce dalla zona)
  let nextTimer = 0;
  let nextLeft = 0;
  let ended = false;
  let seek = null;           // { target, dir, burstStart, last, lastStep }
  let seekTimer = 0;
  let duration = 0;

  const id = () => (current ? current.id : title.id);
  const index = () => (current ? episodes.findIndex((e) => e.id === current.id) : -1);
  const nextEpisode = () => (index() >= 0 ? episodes[index() + 1] || null : null);
  const prevEpisode = () => (index() > 0 ? episodes[index() - 1] : null);
  const now = () => (seek ? seek.target : video.currentTime || 0);

  // ---------- comandi in basso

  function layoutButtons() {
    const list = [playBtn];
    if (current) {
      if (prevEpisode()) list.push(prevBtn);
      if (nextEpisode()) list.push(nextBtn);
    }
    list.push(restartBtn);
    if (current && episodes.length > 1) list.push(listBtn);
    list.push(audioBtn, optionsBtn);
    buttons.replaceChildren(...list);
  }

  function paintPlay() {
    playBtn.replaceChildren(icon(video.paused ? 'play' : 'pause'));
    root.classList.toggle('paused', video.paused);
  }

  function activate(btn) {
    switch (btn.dataset.key) {
      case 'play': togglePlay(); break;
      case 'prev': { const p = prevEpisode(); if (p) load(p); break; }
      case 'next': { const n = nextEpisode(); if (n) load(n); break; }
      case 'restart': cancelSeek(); video.currentTime = 0; introSkipped = true; video.play().catch(() => {}); showOSD(); break;
      case 'list': openList(); break;
      case 'audio': openAudio(); break;
      case 'options': openOptions(); break;
      default:
    }
  }

  // ---------- OSD

  function showOSD({ focusOn = null, stay = false } = {}) {
    if (!osdVisible) {
      osdVisible = true;
      root.classList.remove('osd-off');
      updateClock();
      clockTimer = setInterval(updateClock, 15000);
    }
    if (focusOn) focus(focusOn);
    else if (!focused() || !root.contains(focused())) focus(bar);
    paintHint();
    updateBar();
    scheduleHide(stay);
  }

  function scheduleHide(stay = false) {
    clearTimeout(hideTimer);
    if (stay || video.paused || panelOpen || seek) return;
    hideTimer = setTimeout(hideOSD, focused() === bar ? 3500 : 6000);
  }

  function hideOSD() {
    if (!osdVisible || panelOpen) return;
    osdVisible = false;
    clearTimeout(hideTimer);
    clearInterval(clockTimer);
    root.classList.add('osd-off');
    focus(bar);
  }

  function paintHint() {
    hint.textContent = focused() === bar
      ? t('← → avanti e indietro · tieni premuto per andare più veloce · ↓ comandi')
      : t('↑ torna alla barra');
  }

  function updateClock() {
    const d = new Date();
    clock.textContent = d.toLocaleTimeString(lang, { hour: '2-digit', minute: '2-digit' });
  }

  function pct(x) { return duration > 0 ? Math.max(0, Math.min(1, x / duration)) : 0; }

  function updateBar() {
    if (!osdVisible && !seek) return;
    const pos = now();
    played.style.transform = `scaleX(${pct(video.currentTime || 0)})`;
    thumb.style.transform = `translateX(${pct(pos) * 1728}px)`;
    try {
      const b = video.buffered;
      let end = 0;
      for (let i = 0; i < b.length; i++) if (b.start(i) <= video.currentTime + 1) end = Math.max(end, b.end(i));
      buffered.style.transform = `scaleX(${pct(end)})`;
    } catch { /* buffered non disponibile */ }
    timeLeft.textContent = fmt(pos);
    if (duration > 0) {
      const left = Math.max(0, duration - pos);
      const endsAt = new Date(Date.now() + left * 1000 / (video.playbackRate || 1));
      timeRight.textContent = `−${fmt(left)} · ${t('fine alle {h}', { h: endsAt.toLocaleTimeString(lang, { hour: '2-digit', minute: '2-digit' }) })}`;
    } else timeRight.textContent = '';
    if (seek) {
      bubble.textContent = fmt(seek.target);
      bubble.style.transform = `translateX(${pct(seek.target) * 1728}px)`;
    }
  }

  function paintSegments() {
    const mark = (el, range) => {
      if (!range || !duration) { el.classList.add('hidden'); return; }
      el.classList.remove('hidden');
      el.style.left = `${pct(range[0]) * 100}%`;
      el.style.width = `${(pct(range[1]) - pct(range[0])) * 100}%`;
    };
    mark(introMark, segments?.intro);
    mark(creditsMark, segments?.credits);
  }

  // ---------- avanti e indietro

  function nudge(dir, base) {
    const time = performance.now();
    if (!seek) seek = { target: video.currentTime || 0, dir, burstStart: time, last: 0, lastStep: 0 };
    // Nuova raffica (direzione cambiata o pausa tra i tocchi): si riparte dal passo piccolo.
    if (dir !== seek.dir || time - seek.last > 400) { seek.burstStart = time; seek.dir = dir; }
    else if (time - seek.lastStep < 110) { seek.last = time; armSeek(); return; } // tasto tenuto: al massimo ~9 passi al secondo
    const held = time - seek.burstStart;
    const step = held < 1500 ? base : held < 3500 ? base * 3 : held < 6000 ? base * 6 : base * 12;
    const max = duration > 0 ? duration - 2 : Infinity;
    seek.target = Math.max(0, Math.min(max, seek.target + dir * step));
    seek.last = seek.lastStep = time;
    const delta = seek.target - (video.currentTime || 0);
    seekBadge.replaceChildren(
      h('b', {}, `${delta < 0 ? '−' : '+'}${fmt(Math.abs(delta))}`),
      h('span', {}, fmt(seek.target)));
    seekBadge.classList.remove('hidden');
    bubble.classList.remove('hidden');
    root.classList.add('seeking');
    showOSD({ focusOn: bar, stay: true });
    armSeek();
  }

  function armSeek() {
    clearTimeout(seekTimer);
    seekTimer = setTimeout(applySeek, 700);
  }

  function applySeek() {
    if (!seek) return;
    clearTimeout(seekTimer);
    const target = seek.target;
    seek = null;
    seekBadge.classList.add('hidden');
    bubble.classList.add('hidden');
    root.classList.remove('seeking');
    video.currentTime = target;
    if (ended) { ended = false; video.play().catch(() => {}); }
    updateBar();
    scheduleHide();
  }

  function cancelSeek() {
    if (!seek) return false;
    clearTimeout(seekTimer);
    seek = null;
    seekBadge.classList.add('hidden');
    bubble.classList.add('hidden');
    root.classList.remove('seeking');
    updateBar();
    scheduleHide();
    return true;
  }

  function jumpTo(seconds) {
    cancelSeek();
    if (!(duration > 0)) return;
    video.currentTime = Math.max(0, Math.min(duration - 2, seconds));
    showOSD({ focusOn: bar });
  }

  function togglePlay() {
    if (seek) { applySeek(); return; }
    if (video.paused) video.play().catch(() => {}); else video.pause();
  }

  // ---------- sigla e titoli di coda

  function inIntro(time) {
    const r = segments?.intro;
    return !!r && time >= r[0] - 1 && time < r[1] - 2;
  }

  /** Da quando proporre l'episodio successivo: inizio della coda riconosciuta, sennò gli ultimi 20 s. */
  function nextZoneStart() {
    if (segments?.credits) return segments.credits[0];
    return duration > 0 ? duration - 20 : Infinity;
  }

  function skipIntro() {
    const r = segments?.intro;
    if (!r) return;
    cancelSeek();
    video.currentTime = r[1];
    skipPill.classList.add('hidden');
  }

  function onTime() {
    const time = video.currentTime || 0;
    // Salta intro
    const intro = inIntro(time) && !seek;
    if (intro && pref('autoSkip', false) && !introSkipped) {
      introSkipped = true;
      skipIntro();
      flash(t('Sigla saltata'));
    } else {
      skipPill.classList.toggle('hidden', !intro);
    }
    // Prossimo episodio ai titoli di coda
    const next = nextEpisode();
    const zone = next && duration > 0 && time >= nextZoneStart();
    if (!zone) {
      nextDismissed = false;
      if (!ended) hideNext();
    } else if (!nextDismissed && nextCard.classList.contains('hidden')) {
      offerNext(next);
    }
    updateBar();
  }

  function offerNext(next) {
    nextLeft = 10;
    const paint = () => nextCard.replaceChildren(
      h('div', { class: 'p-next-label' }, t('Prossimo episodio')),
      h('div', { class: 'p-next-title' }, `${code(next.season, next.number)} · ${next.title}`),
      h('div', { class: 'p-next-count' }, h('i', { style: `transform:scaleX(${nextLeft / 10})` })),
      h('div', { class: 'p-next-hint' }, ended
        ? t('Parte tra {n} s · OK per guardarlo ora · Indietro per uscire', { n: nextLeft })
        : t('Parte tra {n} s · OK per guardarlo ora · Indietro per vedere i titoli', { n: nextLeft })));
    paint();
    nextCard.classList.remove('hidden');
    clearInterval(nextTimer);
    // Il conto alla rovescia va avanti solo mentre il video va (o a video finito).
    nextTimer = setInterval(() => {
      if (video.paused && !ended) return;
      nextLeft -= 1;
      if (nextLeft <= 0) load(next); else paint();
    }, 1000);
  }

  function hideNext() {
    clearInterval(nextTimer);
    nextCard.classList.add('hidden');
  }

  function flash(text) {
    toast.textContent = text;
    toast.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.add('hidden'), 2500);
  }

  // ---------- pannelli a destra (episodi, audio, opzioni)

  function openPanel(kind, heading, rows, footer) {
    panelOpen = kind;
    panel.replaceChildren(h('div', { class: 'p-panel-title' }, heading),
      h('div', { class: 'p-panel-list' }, rows), footer ? h('div', { class: 'p-panel-hint' }, footer) : null);
    panel.classList.remove('hidden');
    root.classList.add('panel-on');
    setScope(panel);
    const first = panel.querySelector('.f[data-autofocus]') || panel.querySelector('.f');
    if (first) focus(first);
    showOSD({ focusOn: first || bar, stay: true });
  }

  function closePanel() {
    if (!panelOpen) return;
    const from = panelOpen;
    panelOpen = null;
    panel.classList.add('hidden');
    root.classList.remove('panel-on');
    setScope(null);
    const btn = { list: listBtn, audio: audioBtn, options: optionsBtn }[from];
    showOSD({ focusOn: btn && btn.isConnected ? btn : bar });
  }

  function openList() {
    let lastSeason = null;
    const rows = [];
    for (const e of episodes) {
      if (e.season !== lastSeason) {
        lastSeason = e.season;
        rows.push(h('div', { class: 'p-row-head' }, t('Stagione {n}', { n: e.season })));
      }
      const p = store.progressOf(e.id);
      const isCurrent = e.id === current?.id;
      rows.push(h('button', {
        class: `f p-row ${isCurrent ? 'active' : ''}`, dataset: { key: 'ep-' + e.id, autofocus: isCurrent || null },
        onclick: () => { closePanel(); if (!isCurrent) load(e); },
      },
      h('span', { class: 'p-row-code' }, code(e.season, e.number)),
      h('span', { class: 'p-row-text' }, e.title),
      isCurrent ? h('span', { class: 'p-row-tag' }, '▶')
        : p?.done ? h('span', { class: 'p-row-tag' }, '✓')
          : p?.dur ? h('span', { class: 'p-row-bar' }, h('i', { style: `transform:scaleX(${(p.pos / p.dur).toFixed(3)})` })) : null));
    }
    openPanel('list', t('Episodi'), rows, t('OK per guardarlo · Indietro per chiudere'));
  }

  function tracks() {
    const list = video.audioTracks;
    return list ? Array.from({ length: list.length }, (_, i) => list[i]) : null;
  }

  function applyPreferredAudio() {
    const list = tracks();
    const preferred = store.preferredAudio();
    if (!list || list.length < 2 || !preferred) return;
    const i = list.findIndex((tr) => ui.audioCode(tr.language) === preferred);
    if (i >= 0) list.forEach((tr, j) => { tr.enabled = j === i; });
  }

  function openAudio() {
    const list = tracks();
    let rows;
    if (!list) rows = [h('p', { class: 'p-panel-text' }, t('Questa TV non permette di scegliere la lingua audio.'))];
    else if (list.length < 2) rows = [h('p', { class: 'p-panel-text' }, t('Questo video ha una sola lingua audio: {l}.', { l: ui.trackName(list[0], 0) }))];
    else {
      rows = list.map((tr, i) => h('button', {
        class: `f p-row ${tr.enabled ? 'active' : ''}`, dataset: { key: 'a' + i, autofocus: tr.enabled || null },
        onclick: () => {
          list.forEach((x, j) => { x.enabled = j === i; });
          store.setPreferredAudio(ui.audioCode(tr.language));
          closePanel();
        },
      }, h('span', { class: 'p-row-text' }, ui.trackName(tr, i)), tr.enabled ? h('span', { class: 'p-row-tag' }, '✓') : null));
    }
    openPanel('audio', t('Lingua audio'), rows,
      list && list.length > 1 ? t('OK per scegliere · Indietro per chiudere') : t('Indietro per chiudere'));
  }

  function openOptions() {
    const auto = pref('autoSkip', false);
    const rows = [
      h('div', { class: 'p-row-head' }, t('Sigla')),
      h('button', {
        class: 'f p-row', dataset: { key: 'auto', autofocus: true },
        onclick: () => { setPref('autoSkip', !auto); introSkipped = true; openOptions(); },
      }, h('span', { class: 'p-row-text' }, t('Salta la sigla da sola')), h('span', { class: `p-switch ${auto ? 'on' : ''}` }, h('i'))),
      h('div', { class: 'p-row-head' }, t('Velocità')),
      ...SPEEDS.map((s) => h('button', {
        class: `f p-row ${video.playbackRate === s ? 'active' : ''}`, dataset: { key: 'speed' + s },
        onclick: () => { video.playbackRate = s; openOptions(); },
      }, h('span', { class: 'p-row-text' }, s === 1 ? t('Normale') : `${String(s).replace('.', lang === 'en' ? '.' : ',')}×`),
      video.playbackRate === s ? h('span', { class: 'p-row-tag' }, '✓') : null)),
    ];
    const keep = panelOpen === 'options' ? focused()?.dataset.key : null;
    openPanel('options', t('Opzioni'), rows, t('OK per scegliere · Indietro per chiudere'));
    const again = keep && panel.querySelector(`.f[data-key="${CSS.escape(keep)}"]`);
    if (again) focus(again);
  }

  function panelKey(k) {
    const f = focused();
    const rows = [...panel.querySelectorAll('.f')];
    const i = rows.indexOf(f);
    if (k === KEY.UP || k === KEY.DOWN) {
      const next = rows[i + (k === KEY.UP ? -1 : 1)];
      if (next) focus(next);
      return true;
    }
    if (k === KEY.OK) { if (f && panel.contains(f)) f.click(); return true; }
    if (k === KEY.LEFT || isBack(k)) { closePanel(); return true; }
    return true;
  }

  // ---------- caricamento

  function save() {
    if (duration > 0 && video.currentTime > 5) store.saveProgress(id(), video.currentTime, duration);
  }

  function load(ep) {
    if (current !== undefined && video.src) save();
    cancelSeek();
    hideNext();
    closePanel();
    current = ep;
    ended = false;
    introSkipped = false;
    nextDismissed = false;
    duration = 0;
    segments = null;
    state.playingKey = ep ? ep.id : title.id;
    topTitle.textContent = title.name;
    topSub.textContent = ep ? `${code(ep.season, ep.number)} · ${ep.title}` : '';
    skipPill.classList.add('hidden');
    paintSegments();
    layoutButtons();
    // Guardare qualcosa lo mette in libreria, come su iPhone: di una serie solo l'episodio.
    store.addToLibrary(title.id, ep ? ep.id : null);

    const p = store.progressOf(id());
    video.src = ep ? ep.url : title.url;
    video.onloadedmetadata = () => {
      duration = video.duration || 0;
      if (p && !p.done && p.pos > 10 && p.pos < duration - 30) video.currentTime = p.pos;
      applyPreferredAudio();
      paintSegments();
      updateBar();
    };
    video.play().catch(() => {});
    if (ep) {
      const forId = ep.id;
      loadIntroData().then((data) => {
        if (current?.id !== forId) return;
        const s = data[forId.slice(2)];
        segments = s && (s.intro || s.credits) ? { intro: s.intro || null, credits: s.credits || null } : null;
        paintSegments();
      });
    }
    showOSD({ focusOn: bar });
  }

  function close() {
    closePanel();
    cancelSeek();
    save();
    store.flush();
    clearInterval(saveTimer);
    clearInterval(nextTimer);
    clearInterval(clockTimer);
    clearTimeout(hideTimer);
    clearTimeout(toastTimer);
    video.pause();
    video.removeAttribute('src');
    video.load();
    pop();
  }

  video.onwaiting = () => spinner.classList.remove('hidden');
  video.onplaying = () => { spinner.classList.add('hidden'); paintPlay(); scheduleHide(); };
  video.onplay = paintPlay;
  video.ontimeupdate = onTime;
  video.onpause = () => { paintPlay(); if (!ended) showOSD({ stay: true }); save(); store.flush(); };
  video.ondurationchange = () => { duration = video.duration || duration; paintSegments(); };
  video.onended = () => {
    ended = true;
    store.saveProgress(id(), duration, duration);
    store.flush();
    const next = nextEpisode();
    if (!next) { close(); return; }
    nextDismissed = false;
    offerNext(next); // anche se era già aperta: ora dice "Indietro per uscire"
  };
  video.onerror = () => {
    spinner.classList.add('hidden');
    topSub.textContent = t('Questo video non si riesce a riprodurre sulla TV.');
    showOSD({ stay: true });
  };
  saveTimer = setInterval(save, 5000);

  // ---------- telecomando

  function onKey(k) {
    if (panelOpen) return panelKey(k);

    // Cartolina "Prossimo episodio": OK lo fa partire, Indietro la chiude.
    if (!nextCard.classList.contains('hidden') && !(osdVisible && focused() !== bar)) {
      if (k === KEY.OK) { const n = nextEpisode(); if (n) load(n); return true; }
      if (isBack(k)) {
        if (ended) { close(); return true; }
        nextDismissed = true;
        hideNext();
        return true;
      }
    }

    // Tasti numerici: 1-9 = 10%-90%, 0 = dall'inizio.
    if (k >= 48 && k <= 57) { jumpTo(duration * (k - 48) / 10); return true; }
    if (k >= 96 && k <= 105) { jumpTo(duration * (k - 96) / 10); return true; }

    switch (k) {
      case KEY.PLAY: if (video.paused) togglePlay(); return true;
      case KEY.PAUSE: if (!video.paused) video.pause(); return true;
      case KEY.PLAY_PAUSE: togglePlay(); return true;
      case KEY.FF: nudge(1, 30); return true;
      case KEY.RW: nudge(-1, 30); return true;
      case KEY.NEXT: case KEY.CH_UP: case KEY.PAGE_UP: { const n = nextEpisode(); if (n) load(n); return true; }
      case KEY.PREV: case KEY.CH_DOWN: case KEY.PAGE_DOWN: { const p = prevEpisode(); if (p) load(p); return true; }
      case KEY.STOP: close(); return true;
      default:
    }

    const f = focused();
    const onButtons = osdVisible && f && buttons.contains(f);

    if (onButtons) {
      const list = [...buttons.children];
      const i = list.indexOf(f);
      switch (k) {
        case KEY.LEFT: if (list[i - 1]) focus(list[i - 1]); scheduleHide(); return true;
        case KEY.RIGHT: if (list[i + 1]) focus(list[i + 1]); scheduleHide(); return true;
        case KEY.UP: focus(bar); paintHint(); scheduleHide(); return true;
        case KEY.DOWN: hideOSD(); return true;
        case KEY.OK: activate(f); return true;
        default:
          if (isBack(k)) { hideOSD(); return true; }
          return false;
      }
    }

    // Video da solo, o barra selezionata.
    switch (k) {
      case KEY.LEFT: nudge(-1, 10); return true;
      case KEY.RIGHT: nudge(1, 10); return true;
      case KEY.OK:
        if (seek) { applySeek(); return true; }
        if (!skipPill.classList.contains('hidden')) { skipIntro(); return true; }
        togglePlay();
        return true;
      case KEY.DOWN: case KEY.UP:
        if (seek) applySeek();
        if (osdVisible && k === KEY.UP) { hideOSD(); return true; }
        showOSD({ focusOn: playBtn });
        return true;
      default:
        if (isBack(k)) {
          if (cancelSeek()) return true;
          close();
          return true;
        }
        return false;
    }
  }

  push({ render: () => { app().replaceChildren(root); }, onKey });
  load(episode);

  function app() { return document.getElementById('app'); }
}
