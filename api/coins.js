const crypto = require('crypto');
const { requireUser, json, readJsonBody } = require('./lib/auth');
const {
  readIndexDocument,
  upsertCoin,
  nextFrontSortOrder,
  isValidCoinId,
  MAX_COINS,
} = require('./lib/store');
const { presentCoin } = require('./lib/imageurl');
const { cleanTitle, cleanNotes, validAccent } = require('./lib/coinfields');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  if (req.method === 'GET') {
    const doc = await readIndexDocument(user.id);
    if (doc.status === 'error') {
      return json(res, 503, { error: 'Could not read coin index' });
    }
    // A missing index simply means an empty purse. Nothing is ever copied in
    // from anyone else's data.
    return json(res, 200, {
      coins: doc.coins.map((c) => presentCoin(c, user.id)),
      email: user.email,
    });
  }

  if (req.method === 'POST') {
    const data = await readJsonBody(req, res);
    if (!data) return;
    const title = cleanTitle(data.title);
    if (!title) return json(res, 400, { error: 'Title required' });
    const doc = await readIndexDocument(user.id);
    if (doc.status === 'error') {
      return json(res, 503, { error: 'Could not read coin index' });
    }
    const existing = doc.coins;
    // Clients may pick the id (so a retried Save does not duplicate the coin),
    // but only a plain one.
    const id = isValidCoinId(data.id) ? data.id : crypto.randomUUID();
    // Never revive a deleted id (stale client / retry after toss).
    if (doc.deletedIds[id]) {
      return json(res, 409, { error: 'Coin was deleted — create a new coin' });
    }
    const already = existing.find((c) => c.id === id);
    if (already) return json(res, 200, { coin: presentCoin(already, user.id) });
    if (existing.length >= MAX_COINS) {
      return json(res, 400, { error: `A purse holds at most ${MAX_COINS} coins` });
    }
    const now = Date.now();
    const coin = {
      id,
      title,
      notes: cleanNotes(data.notes),
      accent: validAccent(data.accent) ? data.accent : Math.floor(Math.random() * 6),
      // Pictures are only ever set by the upload endpoints, never by the client.
      imageUrl: null,
      imagePath: null,
      attachments: [],
      sortOrder: typeof data.sortOrder === 'number' ? data.sortOrder : nextFrontSortOrder(existing),
      createdAt: now,
      updatedAt: now,
    };
    const saved = await upsertCoin(user.id, coin);
    return json(res, 201, { coin: presentCoin(saved, user.id) });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
