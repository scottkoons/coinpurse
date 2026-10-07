const crypto = require('crypto');
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
 * The random part keeps two uploads in the same millisecond from wanting the
 * same (create-only) path. Nothing parses these names; only the
 * "users/<uid>/" prefix matters (see ownsPath).
 */
function imageVersion() {
  return Date.now().toString(36) + '-' + crypto.randomBytes(4).toString('hex');
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

async function writeJsonBlob(pathname, data, opts) {
  return writeJsonDocument(pathname, data, opts);
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

/**
 * Tombstone lookup. Ids such as "toString" or "constructor" are valid coin ids,
 * so membership must never fall through to Object.prototype.
 */
function isTombstoned(deletedIds, id) {
  return !!deletedIds && Object.hasOwn(deletedIds, id);
}

function normalizeDeletedIds(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return {};
  // No prototype, so an id named "__proto__" is stored like any other.
  const out = Object.create(null);
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
  return (coins || []).filter((c) => c && c.id && !isTombstoned(deletedIds, c.id));
}

/**
 * Full index document. Distinguishes "file missing" from "empty purse".
 * { status, coins, deletedIds, raw }
 */
async function readIndexDocument(userId) {
  if (!userId) {
    return { status: 'missing', coins: [], deletedIds: {}, raw: null };
  }
  const { status, data, version } = await readJsonBlobStatus(userIndexPath(userId));
  if (status === 'missing') {
    return { status: 'missing', coins: [], deletedIds: {}, raw: null, version: null };
  }
  if (status === 'error') {
    return { status: 'error', coins: [], deletedIds: {}, raw: null };
  }
  const deletedIds = normalizeDeletedIds(data && data.deletedIds);
  let coins = Array.isArray(data && data.coins) ? data.coins : [];
  coins = filterTombstoned(sortCoinsByOrder(coins), deletedIds);
  return { status: 'ok', coins, deletedIds, raw: data, version: version || null };
}

async function readIndex(userId) {
  const doc = await readIndexDocument(userId);
  // On read error, return [] without claiming "empty" for migration purposes.
  // Callers that need migrate semantics must use readIndexDocument.
  return doc.coins;
}

async function writeIndexDocument(userId, { coins, deletedIds, extra } = {}, opts) {
  const payload = {
    coins: Array.isArray(coins) ? coins : [],
    deletedIds: pruneDeletedIds(normalizeDeletedIds(deletedIds)),
    updatedAt: Date.now(),
    ...(extra && typeof extra === 'object' ? extra : {}),
  };
  await writeJsonBlob(userIndexPath(userId), payload, opts);
  return payload;
}

function codedError(message, code) {
  const err = new Error(message);
  err.code = code;
  return err;
}

/**
 * Change the purse safely when several changes arrive at once (two phones,
 * a share while the app saves, several pictures uploading together).
 * `change(doc)` gets the latest purse and returns { coins, deletedIds, result },
 * or { result } alone when nothing needs saving. If someone else saved first,
 * it reads the purse again and runs `change` again on top of theirs.
 * Errors thrown by `change` (not found, deleted, full) go straight to the caller.
 */
async function mutateIndex(userId, change) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const doc = await readIndexDocument(userId);
    if (doc.status === 'error') throw new Error('Could not read coin index');
    const out = await change(doc);
    if (!out || !out.coins) return out ? out.result : undefined;
    try {
      await writeIndexDocument(userId, { coins: out.coins, deletedIds: out.deletedIds || doc.deletedIds },
        { after: doc.version });
      return out.result;
    } catch (e) {
      if (e.code !== 'CONFLICT') throw e;
      // Someone else saved first: wait a moment (a little longer each time) and redo.
      await new Promise((r) => setTimeout(r, 15 + Math.random() * 40 * (attempt + 1)));
    }
  }
  throw new Error('Too many changes at once; try again');
}

/**
 * Change one coin in the latest purse. `edit(coin, doc)` returns the new coin
 * (it may throw with a code). Throws NOT_FOUND or TOMBSTONED.
 */
async function updateCoin(userId, id, edit) {
  return mutateIndex(userId, async (doc) => {
    if (isTombstoned(doc.deletedIds, id)) throw codedError('Coin was deleted', 'TOMBSTONED');
    const i = doc.coins.findIndex((c) => c.id === id);
    if (i < 0) throw codedError('Coin not found', 'NOT_FOUND');
    const before = doc.coins[i];
    const after = await edit({ ...before, attachments: [...(before.attachments || [])] }, doc);
    const coins = doc.coins.slice();
    coins[i] = { ...after, id: before.id };
    sortCoinsByOrder(coins);
    return { coins, result: { coin: coins.find((c) => c.id === id), before } };
  });
}

async function writeIndex(userId, coins) {
  // Preserve existing tombstones when rewriting coin list only.
  await mutateIndex(userId, (doc) => ({ coins: filterTombstoned(coins, doc.deletedIds) }));
}

async function upsertCoin(userId, coin) {
  return mutateIndex(userId, (doc) => {
    // Tombstones win: never revive a deleted id via image upload, accent PUT,
    // or stale-client sync. New coins always use fresh UUIDs.
    if (coin && coin.id && isTombstoned(doc.deletedIds, coin.id)) throw codedError('Coin was deleted', 'TOMBSTONED');
    const coins = doc.coins.slice();
    const next = { ...coin };
    const i = coins.findIndex((c) => c.id === next.id);
    if (i >= 0) {
      if (typeof next.sortOrder !== 'number') next.sortOrder = coins[i].sortOrder;
      // Merge into existing so a partial payload cannot wipe title/notes/image.
      coins[i] = { ...coins[i], ...next, id: coins[i].id };
    } else {
      if (typeof next.sortOrder !== 'number') next.sortOrder = nextFrontSortOrder(coins);
      coins.push(next);
    }
    sortCoinsByOrder(coins);
    return { coins, result: coins.find((c) => c.id === next.id) || next };
  });
}

/**
 * Patch image fields on an existing non-tombstoned coin only.
 * Never creates an index entry (prevents Untitled draft ghosts).
 * Returns { coin, before } so the caller can delete the picture it replaced.
 */
async function patchCoinImage(userId, id, { imageUrl, imagePath }) {
  return updateCoin(userId, id, (coin) => ({
    ...coin,
    imageUrl: imageUrl != null ? imageUrl : coin.imageUrl,
    imagePath: imagePath != null ? imagePath : coin.imagePath,
    updatedAt: Date.now(),
  }));
}

/** Rewrite sortOrder 0..n-1 from ordered id list. Unknown ids ignored. */
async function reorderCoins(userId, orderedIds) {
  if (!Array.isArray(orderedIds)) throw new Error('ids required');
  return mutateIndex(userId, (doc) => {
    const byId = new Map(doc.coins.map((c) => [c.id, c]));
    const next = [];
    const seen = new Set();
    for (const id of orderedIds) {
      const c = byId.get(id);
      if (!c || seen.has(id)) continue;
      seen.add(id);
      next.push({ ...c });
    }
    for (const c of doc.coins) {
      if (!seen.has(c.id)) next.push({ ...c });
    }
    next.forEach((c, i) => {
      c.sortOrder = i;
    });
    return { coins: next, result: next };
  });
}

/** Delete a stored picture, but only if it sits in this user's own folder. */
async function deleteOwnedImage(userId, item) {
  const p = pathOfImage(item);
  if (ownsPath(userId, p)) await deleteBlobsQuiet(p);
}

async function removeCoin(userId, id) {
  const coin = await mutateIndex(userId, (doc) => {
    const found = doc.coins.find((c) => c.id === id);
    // Only a coin that exists gets a tombstone. Deleting an id that is already
    // tombstoned, or one this purse never had, changes nothing and writes
    // nothing; otherwise a flood of made-up ids would push real tombstones
    // out (MAX_TOMBSTONES) and let deleted coins come back.
    if (!found) return { result: undefined };
    const deletedIds = { ...doc.deletedIds, [id]: Date.now() };
    return { coins: doc.coins.filter((c) => c.id !== id), deletedIds, result: found };
  });
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
  mutateIndex,
  updateCoin,
  patchCoinImage,
  removeCoin,
  reorderCoins,
  sortCoinsByOrder,
  nextFrontSortOrder,
  deleteOwnedImage,
  deleteAllUserData,
  isValidCoinId,
  isTombstoned,
  userImagePath,
  userAttachmentPath,
  MAX_ATTACHMENTS,
  MAX_COINS,
};
