const { requireUser, json, readJsonBody } = require('../lib/auth');
const { readIndexDocument, upsertCoin, removeCoin, isValidCoinId } = require('../lib/store');
const { presentCoin } = require('../lib/imageurl');
const { cleanTitle, cleanNotes, validAccent } = require('../lib/coinfields');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  const id = req.query.id;
  if (!isValidCoinId(id)) return json(res, 400, { error: 'Missing id' });

  if (req.method === 'PUT') {
    const data = await readJsonBody(req, res);
    if (!data) return;
    const doc = await readIndexDocument(user.id);
    if (doc.status === 'error') {
      return json(res, 503, { error: 'Could not read coin index' });
    }
    if (doc.deletedIds[id]) {
      return json(res, 410, { error: 'Coin was deleted' });
    }
    const existing = doc.coins.find((c) => c.id === id);
    if (!existing) return json(res, 404, { error: 'Not found' });
    // Only text, color and order can change here. Picture fields sent by a
    // client are ignored; pictures change only through the upload endpoints.
    const coin = {
      ...existing,
      // Clearing the title keeps the old one (every coin has a name).
      title: cleanTitle(data.title) || existing.title,
      notes: data.notes != null ? cleanNotes(data.notes) : existing.notes,
      accent: validAccent(data.accent) ? data.accent : existing.accent,
      sortOrder: typeof data.sortOrder === 'number' ? data.sortOrder : existing.sortOrder,
      updatedAt: Date.now(),
    };
    try {
      const saved = await upsertCoin(user.id, coin);
      return json(res, 200, { coin: presentCoin(saved, user.id) });
    } catch (e) {
      if (e.code === 'TOMBSTONED') {
        return json(res, 410, { error: 'Coin was deleted' });
      }
      throw e;
    }
  }

  if (req.method === 'DELETE') {
    await removeCoin(user.id, id);
    return json(res, 200, { ok: true });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
