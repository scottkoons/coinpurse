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

module.exports = { cleanTitle, cleanNotes, validAccent };
