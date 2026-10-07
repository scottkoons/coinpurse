const crypto = require('crypto');
const { requireUser, json, readJsonBody } = require('./lib/auth');
const {
  readIndexDocument,
  mutateIndex,
  sortCoinsByOrder,
  nextFrontSortOrder,
  isValidCoinId,
  isTombstoned,
  MAX_COINS,
} = require('./lib/store');
const { presentCoin } = require('./lib/imageurl');
const { cleanTitle, cleanNotes, validAccent, nextDefaultTitle, cleanPin } = require('./lib/coinfields');

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
    // Clients may pick the id (so a retried Save does not duplicate the coin),
    // but only a plain one.
    const id = isValidCoinId(data.id) ? data.id : crypto.randomUUID();
    const pin = data.pin === undefined ? { ok: true, value: null } : cleanPin(data.pin);
    if (!pin.ok) return json(res, 400, { error: 'That map pin is not a real place' });
    let outcome;
    try {
      // Decided against the latest purse, so coins created at the same moment
      // are all kept and never share a "Coin N" name.
      outcome = await mutateIndex(user.id, (doc) => {
        // Never revive a deleted id (stale client / retry after toss).
        if (isTombstoned(doc.deletedIds, id)) return { result: { status: 409 } };
        const already = doc.coins.find((c) => c.id === id);
        if (already) return { result: { status: 200, coin: already } };
        if (doc.coins.length >= MAX_COINS) return { result: { status: 400 } };
        const now = Date.now();
        const coin = {
          id,
          // A title is optional: untitled coins are named Coin 1, Coin 2, ...
          title: cleanTitle(data.title) || nextDefaultTitle(doc.coins),
          notes: cleanNotes(data.notes),
          accent: validAccent(data.accent) ? data.accent : Math.floor(Math.random() * 6),
          // Pictures are only ever set by the upload endpoints, never by the client.
          imageUrl: null,
          imagePath: null,
          attachments: [],
          pin: pin.value,
          // JSON such as 1e309 parses to Infinity, which would be saved as null.
          sortOrder: Number.isFinite(data.sortOrder) ? data.sortOrder : nextFrontSortOrder(doc.coins),
          createdAt: now,
          updatedAt: now,
        };
        const coins = sortCoinsByOrder([...doc.coins, coin]);
        return { coins, result: { status: 201, coin } };
      });
    } catch (e) {
      console.error('create coin', e);
      return json(res, 503, { error: 'Could not save the coin; try again' });
    }
    if (outcome.status === 409) return json(res, 409, { error: 'Coin was deleted — create a new coin' });
    if (outcome.status === 400) return json(res, 400, { error: `A purse holds at most ${MAX_COINS} coins` });
    return json(res, outcome.status, { coin: presentCoin(outcome.coin, user.id) });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
