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

module.exports = { cleanTitle, cleanNotes, validAccent, nextDefaultTitle };
