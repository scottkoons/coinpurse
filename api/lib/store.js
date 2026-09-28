const { list, put, del } = require('@vercel/blob');

const LEGACY_INDEX = 'coinpurse/index.json';
const MAX_ATTACHMENTS = 5;
/** Keep tombstones so legacy remigration / stale reads cannot resurrect deletes. */
const MAX_TOMBSTONES = 500;

function userIndexPath(userId) {
  return `coinpurse/users/${userId}/index.json`;
}

function userImagePath(userId, coinId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}.${ext}`;
}

function userAttachmentPath(userId, coinId, attId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}-att-${attId}.${ext}`;
}

/**
 * Read a JSON blob with explicit status so callers can tell missing vs empty vs error.
 * status: 'ok' | 'missing' | 'error'
 */
async function readJsonBlobStatus(pathname) {
  try {
    const result = await list({ prefix: pathname.replace(/\/[^/]+$/, '/'), limit: 1000 });
    const hit = (result.blobs || []).find((b) => b.pathname === pathname);
    if (!hit) return { status: 'missing', data: null };
    const r = await fetch(hit.url, { cache: 'no-store' });
    if (!r.ok) return { status: 'error', data: null };
    return { status: 'ok', data: await r.json() };
  } catch (e) {
    console.error('readJsonBlobStatus', pathname, e);
    return { status: 'error', data: null };
  }
}

async function readJsonBlob(pathname) {
  const { status, data } = await readJsonBlobStatus(pathname);
  if (status !== 'ok') return null;
  return data;
}

async function writeJsonBlob(pathname, data) {
  return put(pathname, JSON.stringify(data), {
    access: 'public',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: 'application/json',
  });
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

async function readLegacyIndex() {
  const data = await readJsonBlob(LEGACY_INDEX);
  if (data && Array.isArray(data.coins)) return sortCoinsByOrder(data.coins);
  return [];
}

/**
 * One-time inheritance of pre-account legacy purse.
 * ONLY when the user index blob is missing — never when it exists with [].
 * Empty purse after deletes must stay empty (ghost-coin fix).
 */
async function migrateLegacyToUser(userId) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'ok') {
    return doc.coins;
  }
  if (doc.status === 'error') {
    // Do not overwrite a possibly-valid index with legacy on a transient failure.
    throw new Error('Could not read coin index');
  }
  // missing
  const legacy = await readLegacyIndex();
  const deletedIds = {};
  const coins = filterTombstoned(legacy, deletedIds);
  await writeIndexDocument(userId, {
    coins,
    deletedIds,
    extra: { migratedFromLegacyAt: Date.now() },
  });
  return coins;
}

async function upsertCoin(userId, coin) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  const deletedIds = { ...doc.deletedIds };
  // Creating/updating a coin clears its tombstone (explicit re-add wins).
  if (coin && coin.id && deletedIds[coin.id]) delete deletedIds[coin.id];

  const coins = doc.coins.slice();
  const i = coins.findIndex((c) => c.id === coin.id);
  if (i >= 0) {
    if (typeof coin.sortOrder !== 'number') {
      coin.sortOrder = coins[i].sortOrder;
    }
    coins[i] = coin;
  } else {
    if (typeof coin.sortOrder !== 'number') {
      coin.sortOrder = nextFrontSortOrder(coins);
    }
    coins.push(coin);
  }
  sortCoinsByOrder(coins);
  await writeIndexDocument(userId, { coins, deletedIds });
  return coin;
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

async function deleteBlobQuiet(pathOrUrl) {
  if (!pathOrUrl) return;
  try { await del(pathOrUrl); } catch (_) {}
}

async function removeCoin(userId, id) {
  const doc = await readIndexDocument(userId);
  if (doc.status === 'error') throw new Error('Could not read coin index');
  const coin = doc.coins.find((c) => c.id === id);
  const next = doc.coins.filter((c) => c.id !== id);
  const deletedIds = { ...doc.deletedIds, [id]: Date.now() };
  await writeIndexDocument(userId, { coins: next, deletedIds });
  if (coin?.imagePath) await deleteBlobQuiet(coin.imagePath);
  if (coin?.imageUrl) await deleteBlobQuiet(coin.imageUrl);
  const atts = Array.isArray(coin?.attachments) ? coin.attachments : [];
  for (const att of atts) {
    if (att?.imagePath) await deleteBlobQuiet(att.imagePath);
    if (att?.imageUrl) await deleteBlobQuiet(att.imageUrl);
  }
  return true;
}

module.exports = {
  readIndex,
  readIndexDocument,
  writeIndex,
  writeIndexDocument,
  upsertCoin,
  removeCoin,
  reorderCoins,
  sortCoinsByOrder,
  nextFrontSortOrder,
  migrateLegacyToUser,
  readLegacyIndex,
  userImagePath,
  userAttachmentPath,
  MAX_ATTACHMENTS,
  LEGACY_INDEX,
};
