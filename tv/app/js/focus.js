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

function center(r) {
  return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
}

export function move(direction) {
  const from = focused();
  if (!from) { focusFirst(); return; }
  const a = from.getBoundingClientRect();
  const ca = center(a);
  let best = null;
  let bestScore = Infinity;
  for (const el of scope.querySelectorAll('.f')) {
    if (el === from || el.offsetParent === null) continue;
    const b = el.getBoundingClientRect();
    const cb = center(b);
    let primary;
    let secondary;
    switch (direction) {
      case 'left': primary = a.left - b.right; secondary = Math.abs(ca.y - cb.y); if (cb.x >= ca.x) continue; break;
      case 'right': primary = b.left - a.right; secondary = Math.abs(ca.y - cb.y); if (cb.x <= ca.x) continue; break;
      case 'up': primary = a.top - b.bottom; secondary = Math.abs(ca.x - cb.x); if (cb.y >= ca.y) continue; break;
      default: primary = b.top - a.bottom; secondary = Math.abs(ca.x - cb.x); if (cb.y <= ca.y) continue;
    }
    // Sovrapposti sull'asse principale contano come vicinissimi; lo
    // scostamento laterale pesa di più così si resta "in colonna"/"in riga".
    const score = Math.max(primary, 0) + secondary * 2.5;
    if (score < bestScore) { bestScore = score; best = el; }
  }
  if (best) focus(best);
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
