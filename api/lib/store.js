const { readJsonDocument, writeJsonDocument } = require('./blobjson');
const { listBlobs, deleteBlobs, deleteBlobsQuiet } = require('./blob');
const { pathOfImage, ownsPath } = require('./imageurl');

const MAX_ATTACHMENTS = 5;
const MAX_COINS = 500;
/** Keep tombstones so legacy remigration / stale reads cannot resurrect deletes. */
const MAX_TOMBSTONES = 500;

/** Coin ids become part of file names, so only plain ids are accepted. */
function isValidCoinId(id) {
  return typeof id === 'string' && /^[A-Za-z0-9_-]{8,64}$/.test(id);
}

function userFolder(userId) {
  return `coinpurse/users/${userId}/`;
}

function userIndexPath(userId) {
  return `coinpurse/users/${userId}/index.json`;
}

/**
 * Image paths carry a version stamp so replacing an image (crop, rotate,
 * new paste) gets a fresh URL instead of a stale CDN copy of the old one.
 */
function imageVersion() {
  return Date.now().toString(36);
}

function userImagePath(userId, coinId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}-${imageVersion()}.${ext}`;
}

function userAttachmentPath(userId, coinId, attId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}-att-${attId}-${imageVersion()}.${ext}`;
}

/**
 * Read a JSON document with explicit status so callers can tell missing vs empty vs error.
 * status: 'ok' | 'missing' | 'error'
 * Versioned (read-your-writes) storage: see ./blobjson.js.
 */
async function readJsonBlobStatus(pathname) {
  return readJsonDocument(pathname);
}

async function readJsonBlob(pathname) {
  const { status, data } = await readJsonBlobStatus(pathname);
  if (status !== 'ok') return null;
  return data;
}

async function writeJsonBlob(pathname, data) {
  return writeJsonDocument(pathname, data);
}

/** Ascending sortOrder (lower = closer to front). Migrate legacy updatedAt-desc if needed. */
function sortCoinsByOrder(coins) {
  if (!Array.isArray(coins) || !coins.length) return coins || [];
  const any = coins.some((c) => typeof c.sortOrder === 'number');
  if (!any) {
    coins.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
    coins.forEach((c, i) => {
      c.sortOrder = i;
    });
    return coins;
  }
  coins.sort((a, b) => {
    const ao = typeof a.sortOrder === 'number' ? a.sortOrder : Number.POSITIVE_INFINITY;
    const bo = typeof b.sortOrder === 'number' ? b.sortOrder : Number.POSITIVE_INFINITY;
    if (ao !== bo) return ao - bo;
    return (b.updatedAt || 0) - (a.updatedAt || 0);
  });
  return coins;
}

function nextFrontSortOrder(coins) {
  let min = 0;
  let found = false;
  for (const c of coins) {
    if (typeof c.sortOrder === 'number') {
      if (!found || c.sortOrder < min) min = c.sortOrder;
      found = true;
    }
  }
  return found ? min - 1 : 0;
}

function normalizeDeletedIds(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  const out = {};
  for (const [id, ts] of Object.entries(raw)) {
    if (!id) continue;
    const n = Number(ts);
    out[id] = Number.isFinite(n) ? n : Date.now();
  }
  return out;
}

function pruneDeletedIds(deletedIds) {
  const entries = Object.entries(deletedIds || {});
  if (entries.length <= MAX_TOMBSTONES) return deletedIds || {};
  entries.sort((a, b) => (a[1] || 0) - (b[1] || 0));
  const keep = entries.slice(entries.length - MAX_TOMBSTONES);
  return Object.fromEntries(keep);
}

function filterTombstoned(coins, deletedIds) {
  if (!deletedIds || !Object.keys(deletedIds).length) return coins || [];
  return (coins || []).filter((c) => c && c.id && !deletedIds[c.id]);
}

/**
 * Full index document. Distinguishes "file missing" from "empty purse".
 * { status, coins, deletedIds, raw }
 */
async function readIndexDocument(userId) {
  if (!userId) {
    return { status: 'missing', coins: [], deletedIds: {}, raw: null };
  }
  const { status, data } = await readJsonBlobStatus(userIndexPath(userId));
  if (status === 'missing') {
    return { status: 'missing', coins: [], deletedIds: {}, raw: null };
  }
  if (status === 'error') {
    return { status: 'error', coins: [], deletedIds: {}, raw: null };
  }
  const deletedIds = normalizeDeletedIds(data && data.deletedIds);
  let coins = Array.isArray(data && data.coins) ? data.coins : [];
  coins = filterTombstoned(sortCoinsByOrder(coins), deletedIds);
  return { status: 'ok', coins, deletedIds, raw: data };
}

async function readIndex(userId) {
  const doc = await readIndexDocument(userId);
  // On read error, return [] without claiming "empty" for migration purposes.
  // Callers that need migrate semantics must use readIndexDocument.
  return doc.coins;
}

async function writeIndexDocument(userId, { coins, deletedIds, extra } = {}) {
  const payload = {
    coins: Array.isArray(coins) ? coins : [],
    deletedIds: pruneDeletedIds(normalizeDeletedIds(deletedIds)),
    updatedAt: Date.now(),
    ...(extra && typeof extra === 'object' ? extra : {}),
  };
  await writeJsonBlob(userIndexPath(userId), payload);
  return payload;
}

async function writeIndex(userId, coins) {
  // Preserve existing tombstones when rewriting coin list only.
  const doc = await readIndexDocument(userId);
  const deletedIds = doc.status === 'ok' ? doc.deletedIds : {};
  const cleaned = filterTombstoned(coins, deletedIds);
  await writeIndexDocument(userId, { coins: cleaned, deletedIds });
}

async function upsertCoin(userId, coin) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  const deletedIds = { ...doc.deletedIds };
  // Tombstones win: never revive a deleted id via image upload, accent PUT,
  // or stale-client sync. New coins always use fresh UUIDs.
  if (coin && coin.id && deletedIds[coin.id]) {
    const err = new Error('Coin was deleted');
    err.code = 'TOMBSTONED';
    throw err;
  }

  const coins = doc.coins.slice();
  const i = coins.findIndex((c) => c.id === coin.id);
  if (i >= 0) {
    if (typeof coin.sortOrder !== 'number') {
      coin.sortOrder = coins[i].sortOrder;
    }
    // Merge into existing so a partial payload cannot wipe title/notes/image.
    coins[i] = { ...coins[i], ...coin, id: coins[i].id };
  } else {
    if (typeof coin.sortOrder !== 'number') {
      coin.sortOrder = nextFrontSortOrder(coins);
    }
    coins.push(coin);
  }
  sortCoinsByOrder(coins);
  await writeIndexDocument(userId, { coins, deletedIds });
  return coins.find((c) => c.id === coin.id) || coin;
}

/**
 * Patch image fields on an existing non-tombstoned coin only.
 * Never creates an index entry (prevents Untitled draft ghosts).
 */
async function patchCoinImage(userId, id, { imageUrl, imagePath }) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  if (doc.deletedIds[id]) {
    const err = new Error('Coin was deleted');
    err.code = 'TOMBSTONED';
    throw err;
  }
  const coins = doc.coins.slice();
  const i = coins.findIndex((c) => c.id === id);
  if (i < 0) {
    const err = new Error('Coin not found');
    err.code = 'NOT_FOUND';
    throw err;
  }
  coins[i] = {
    ...coins[i],
    imageUrl: imageUrl != null ? imageUrl : coins[i].imageUrl,
    imagePath: imagePath != null ? imagePath : coins[i].imagePath,
    updatedAt: Date.now(),
  };
  await writeIndexDocument(userId, { coins, deletedIds: doc.deletedIds });
  return coins[i];
}

/** Rewrite sortOrder 0..n-1 from ordered id list. Unknown ids ignored. */
async function reorderCoins(userId, orderedIds) {
  if (!Array.isArray(orderedIds)) throw new Error('ids required');
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  const byId = new Map(doc.coins.map((c) => [c.id, c]));
  const next = [];
  const seen = new Set();
  for (const id of orderedIds) {
    const c = byId.get(id);
    if (!c || seen.has(id)) continue;
    seen.add(id);
    next.push(c);
  }
  for (const c of doc.coins) {
    if (!seen.has(c.id)) next.push(c);
  }
  next.forEach((c, i) => {
    c.sortOrder = i;
  });
  await writeIndexDocument(userId, { coins: next, deletedIds: doc.deletedIds });
  return next;
}

/** Delete a stored picture, but only if it sits in this user's own folder. */
async function deleteOwnedImage(userId, item) {
  const p = pathOfImage(item);
  if (ownsPath(userId, p)) await deleteBlobsQuiet(p);
}

async function removeCoin(userId, id) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  const coin = doc.coins.find((c) => c.id === id);
  const next = doc.coins.filter((c) => c.id !== id);
  const deletedIds = { ...doc.deletedIds, [id]: Date.now() };
  await writeIndexDocument(userId, { coins: next, deletedIds });
  if (coin) {
    await deleteOwnedImage(userId, coin);
    for (const att of Array.isArray(coin.attachments) ? coin.attachments : []) {
      await deleteOwnedImage(userId, att);
    }
  }
  return true;
}

/** Delete every coin, picture and index version in the user's folder (not the account). */
async function deleteAllUserData(userId) {
  const keep = `${userFolder(userId)}account.`;
  const blobs = await listBlobs(userFolder(userId));
  const doomed = blobs.map((b) => b.pathname).filter((p) => !p.startsWith(keep));
  await deleteBlobs(doomed);
  return doomed.length;
}

module.exports = {
  readIndex,
  readIndexDocument,
  writeIndex,
  writeIndexDocument,
  upsertCoin,
  patchCoinImage,
  removeCoin,
  reorderCoins,
  sortCoinsByOrder,
  nextFrontSortOrder,
  deleteOwnedImage,
  deleteAllUserData,
  isValidCoinId,
  userImagePath,
  userAttachmentPath,
  MAX_ATTACHMENTS,
  MAX_COINS,
};
