// Navigazione col telecomando: gli elementi selezionabili hanno la classe
// `f`. A ogni freccia si sceglie il più vicino in quella direzione, guardando
// le posizioni reali sullo schermo (funziona per griglie, liste, pulsanti).

let current = null;
let scope = document;

export function focused() {
  return current && current.isConnected ? current : null;
}

/** Limita la navigazione a un contenitore (es. una finestra di conferma). */
export function setScope(element) {
  scope = element || document;
}

export function focus(element) {
  if (!element) return;
  if (current) current.classList.remove('focus');
  current = element;
  current.classList.add('focus');
  reveal(current);
}

/** Primo elemento selezionabile dentro `root` (o quello con `data-autofocus`). */
export function focusFirst(root = scope) {
  const preferred = root.querySelector('.f[data-autofocus]');
  focus(preferred || root.querySelector('.f'));
}

/**
 * Sposta la selezione nella direzione data, restando nella stessa zona
 * (`data-zone`: la barra in alto, il contenuto): passare da una zona
 * all'altra lo decide app.js. Restituisce false se in quella direzione non
 * c'è niente.
 */
export function move(direction) {
  const from = focused();
  if (!from) { focusFirst(); return true; }
  const zone = from.closest('[data-zone]') || scope;
  const a = from.getBoundingClientRect();
  const vertical = direction === 'up' || direction === 'down';
  let best = null;
  let bestScore = Infinity;
  for (const el of zone.querySelectorAll('.f')) {
    if (el === from || el.offsetParent === null) continue;
    const b = el.getBoundingClientRect();
    // Quanto è lontano nella direzione (0 se si tocca) e se è "in linea".
    let gap;
    switch (direction) {
      case 'left': if (b.right > a.left + a.width / 2) continue; gap = a.left - b.right; break;
      case 'right': if (b.left < a.right - a.width / 2) continue; gap = b.left - a.right; break;
      case 'up': if (b.bottom > a.top + a.height / 2) continue; gap = a.top - b.bottom; break;
      default: if (b.top < a.bottom - a.height / 2) continue; gap = b.top - a.bottom;
    }
    const overlap = vertical
      ? Math.min(a.right, b.right) - Math.max(a.left, b.left)
      : Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
    // Destra/sinistra solo nella stessa riga: niente salti in diagonale.
    if (!vertical && overlap <= 0) continue;
    // Prima la riga (o colonna) più vicina, poi l'elemento più "in linea":
    // se si sovrappone conta quanto, sennò quanto è distante di lato.
    const side = overlap > 0 ? -Math.min(overlap, 400) / 400 : (vertical
      ? Math.max(b.left - a.right, a.left - b.right)
      : Math.max(b.top - a.bottom, a.top - b.bottom));
    const score = Math.max(gap, 0) * 4 + side;
    if (score < bestScore - 0.001) { bestScore = score; best = el; }
  }
  // Entrando in un gruppo di schede (stagioni, Libreria/Cerca) si va su
  // quella aperta, non sulla più vicina.
  if (best && best.parentElement !== from.parentElement) {
    const active = best.parentElement.querySelector(':scope > .f.active');
    if (active) best = active;
  }
  if (best) focus(best);
  return !!best;
}

/** Porta l'elemento in vista nel suo contenitore scorrevole, senza animazioni (pesanti sulla TV). */
function reveal(el) {
  let box = el.parentElement;
  while (box && box !== document.body) {
    const style = getComputedStyle(box);
    if (/(auto|scroll)/.test(style.overflowY + style.overflowX)) break;
    box = box.parentElement;
  }
  if (!box || box === document.body) return;
  const r = el.getBoundingClientRect();
  const c = box.getBoundingClientRect();
  const margin = 70;
  if (r.top < c.top + margin) box.scrollTop -= c.top + margin - r.top;
  else if (r.bottom > c.bottom - margin) box.scrollTop += r.bottom - (c.bottom - margin);
  if (r.left < c.left + margin) box.scrollLeft -= c.left + margin - r.left;
  else if (r.right > c.right - margin) box.scrollLeft += r.right - (c.right - margin);
}
