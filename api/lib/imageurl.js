const { hmac, safeEqual } = require('./crypto');

const DAY_MS = 1000 * 60 * 60 * 24;

/**
 * The Blob store is private, so a picture can only be read through /api/img
 * with a link the server signed. Links expire at the end of the next day, so
 * a link stays the same all day (the phone can cache it) and a leaked link
 * dies soon.
 */
function signImagePath(pathname, now = Date.now()) {
  const exp = (Math.floor(now / DAY_MS) + 2) * DAY_MS;
  const sig = hmac('img:' + pathname + ':' + exp);
  return '/api/img?p=' + encodeURIComponent(pathname) + '&e=' + exp + '&s=' + sig;
}

function verifyImageLink(pathname, exp, sig, now = Date.now()) {
  const e = Number(exp);
  if (!pathname || !Number.isFinite(e) || e < now) return false;
  return safeEqual(String(sig || ''), hmac('img:' + pathname + ':' + e));
}

/**
 * Blob pathname for a stored picture. Older coins may only have a URL from the
 * retired public store; its path is the same in the private store.
 */
function pathOfImage(item) {
  if (!item) return null;
  if (typeof item.imagePath === 'string' && item.imagePath) return item.imagePath;
  if (typeof item.imageUrl === 'string' && /\.blob\.vercel-storage\.com\//.test(item.imageUrl)) {
    try { return decodeURIComponent(new URL(item.imageUrl).pathname.replace(/^\//, '')); } catch {}
  }
  return null;
}

/** A signed /api/img link, or null when there is no picture of this user's. */
function presentImage(item, uid) {
  const p = pathOfImage(item);
  return p && ownsPath(uid, p) ? signImagePath(p) : null;
}

/** True only for files inside this user's own folder. */
function ownsPath(uid, pathname) {
  return (
    typeof pathname === 'string' &&
    !!uid &&
    pathname.startsWith(`coinpurse/users/${uid}/`) &&
    !pathname.includes('..')
  );
}

/** The coin as the apps see it: picture links are made fresh for each response. */
function presentCoin(coin, uid) {
  if (!coin) return coin;
  const atts = Array.isArray(coin.attachments) ? coin.attachments : [];
  return {
    ...coin,
    imageUrl: presentImage(coin, uid),
    attachments: atts.map((a) => ({ ...a, imageUrl: presentImage(a, uid) })),
  };
}

module.exports = { signImagePath, verifyImageLink, pathOfImage, ownsPath, presentCoin };
