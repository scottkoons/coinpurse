const { list, put, del } = require('@vercel/blob');

const LEGACY_INDEX = 'coinpurse/index.json';
const MAX_ATTACHMENTS = 5;

function userIndexPath(userId) {
  return `coinpurse/users/${userId}/index.json`;
}

function userImagePath(userId, coinId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}.${ext}`;
}

function userAttachmentPath(userId, coinId, attId, ext) {
  return `coinpurse/users/${userId}/images/${coinId}-att-${attId}.${ext}`;
}

async function readJsonBlob(pathname) {
  try {
    const result = await list({ prefix: pathname.replace(/\/[^/]+$/, '/'), limit: 1000 });
    const hit = (result.blobs || []).find((b) => b.pathname === pathname);
    if (!hit) return null;
    const r = await fetch(hit.url, { cache: 'no-store' });
    if (!r.ok) return null;
    return await r.json();
  } catch (e) {
    console.error('readJsonBlob', pathname, e);
    return null;
  }
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

async function readIndex(userId) {
  if (!userId) return [];
  const data = await readJsonBlob(userIndexPath(userId));
  if (data && Array.isArray(data.coins)) return sortCoinsByOrder(data.coins);
  return [];
}

async function writeIndex(userId, coins) {
  await writeJsonBlob(userIndexPath(userId), { coins, updatedAt: Date.now() });
}

async function readLegacyIndex() {
  const data = await readJsonBlob(LEGACY_INDEX);
  if (data && Array.isArray(data.coins)) return sortCoinsByOrder(data.coins);
  return [];
}

async function migrateLegacyToUser(userId) {
  const existing = await readIndex(userId);
  if (existing.length) return existing;
  const legacy = await readLegacyIndex();
  if (!legacy.length) return [];
  await writeIndex(userId, legacy);
  // leave legacy in place as backup
  return legacy;
}

async function upsertCoin(userId, coin) {
  const coins = await readIndex(userId);
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
  await writeIndex(userId, coins);
  return coin;
}

/** Rewrite sortOrder 0..n-1 from ordered id list. Unknown ids ignored. */
async function reorderCoins(userId, orderedIds) {
  if (!Array.isArray(orderedIds)) throw new Error('ids required');
  const coins = await readIndex(userId);
  const byId = new Map(coins.map((c) => [c.id, c]));
  const next = [];
  const seen = new Set();
  for (const id of orderedIds) {
    const c = byId.get(id);
    if (!c || seen.has(id)) continue;
    seen.add(id);
    next.push(c);
  }
  // Append any coins not mentioned (shouldn't happen) at end
  for (const c of coins) {
    if (!seen.has(c.id)) next.push(c);
  }
  next.forEach((c, i) => {
    c.sortOrder = i;
  });
  await writeIndex(userId, next);
  return next;
}

async function deleteBlobQuiet(pathOrUrl) {
  if (!pathOrUrl) return;
  try { await del(pathOrUrl); } catch (_) {}
}

async function removeCoin(userId, id) {
  const coins = await readIndex(userId);
  const coin = coins.find((c) => c.id === id);
  const next = coins.filter((c) => c.id !== id);
  await writeIndex(userId, next);
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
  writeIndex,
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
