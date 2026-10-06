const MAX_TITLE = 200;
const MAX_NOTES = 5000;
const ACCENT_COUNT = 6;

function cleanTitle(v) {
  return String(v == null ? '' : v).trim().slice(0, MAX_TITLE);
}

function cleanNotes(v) {
  return String(v == null ? '' : v).trim().slice(0, MAX_NOTES);
}

function validAccent(v) {
  return Number.isInteger(v) && v >= 0 && v < ACCENT_COUNT;
}

/**
 * Name for a coin saved without a title: "Coin 1", "Coin 2", ... One more
 * than the highest "Coin N" in the purse, so titled coins never use a number.
 */
function nextDefaultTitle(coins) {
  let max = 0;
  for (const c of coins || []) {
    const m = /^Coin (\d+)$/.exec(String((c && c.title) || '').trim());
    if (m) max = Math.max(max, Number(m[1]));
  }
  return 'Coin ' + (max + 1);
}

/**
 * A map pin: where the person was when they tapped Add Pin. Returns
 * { ok: true, value } with a clean pin (or null to remove it), or
 * { ok: false } for anything that is not a real place.
 */
function cleanPin(v) {
  if (v === null) return { ok: true, value: null };
  if (!v || typeof v !== 'object') return { ok: false };
  const num = (x) => (typeof x === 'number' && Number.isFinite(x) ? x : null);
  const lat = num(v.lat), lng = num(v.lng);
  if (lat == null || lng == null || Math.abs(lat) > 90 || Math.abs(lng) > 180) return { ok: false };
  const acc = num(v.acc);
  const at = num(v.at);
  return {
    ok: true,
    value: {
      // About 1 cm of precision is plenty; keeps stored values tidy.
      lat: Math.round(lat * 1e7) / 1e7,
      lng: Math.round(lng * 1e7) / 1e7,
      acc: acc != null && acc >= 0 ? Math.min(Math.round(acc), 100000) : null,
      at: at != null && at > 0 ? Math.round(at) : Date.now(),
    },
  };
}

module.exports = { cleanTitle, cleanNotes, validAccent, nextDefaultTitle, cleanPin };
