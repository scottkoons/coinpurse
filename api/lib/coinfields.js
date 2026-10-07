const MAX_TITLE = 200;
const MAX_NOTES = 5000;
const ACCENT_COUNT = 6;
// A pin's time must be after this and no later than a day from now (clock drift).
const EARLIEST_PIN_AT = Date.UTC(2000, 0, 1);
const PIN_AT_SLACK_MS = 24 * 60 * 60 * 1000;

/**
 * Trim to at most `max` UTF-16 units without cutting a character in half: an
 * emoji is two units, and keeping only its first half would store a broken
 * character.
 */
function clip(v, max) {
  let s = String(v == null ? '' : v).trim().slice(0, max);
  const last = s.charCodeAt(s.length - 1);
  if (last >= 0xd800 && last <= 0xdbff) s = s.slice(0, -1);
  return s;
}

function cleanTitle(v) {
  return clip(v, MAX_TITLE);
}

function cleanNotes(v) {
  return clip(v, MAX_NOTES);
}

function validAccent(v) {
  return Number.isInteger(v) && v >= 0 && v < ACCENT_COUNT;
}

/**
 * Name for a coin saved without a title: "Coin 1", "Coin 2", ... One more
 * than the highest "Coin N" in the purse, so titled coins never use a number.
 * Only N of at most 9 digits counts (the iOS app uses the same rule), so a
 * title like "Coin 9007199254740992" cannot push the next name past what a
 * number can hold exactly.
 */
function nextDefaultTitle(coins) {
  let max = 0;
  for (const c of coins || []) {
    const m = /^Coin (\d{1,9})$/.exec(String((c && c.title) || '').trim());
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
  const now = Date.now();
  const atOk = at != null && at >= EARLIEST_PIN_AT && at <= now + PIN_AT_SLACK_MS;
  return {
    ok: true,
    value: {
      // About 1 cm of precision is plenty; keeps stored values tidy.
      lat: Math.round(lat * 1e7) / 1e7,
      lng: Math.round(lng * 1e7) / 1e7,
      acc: acc != null && acc >= 0 ? Math.min(Math.round(acc), 100000) : null,
      at: atOk ? Math.round(at) : now,
    },
  };
}

module.exports = { cleanTitle, cleanNotes, validAccent, nextDefaultTitle, cleanPin };
