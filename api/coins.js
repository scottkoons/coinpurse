const crypto = require('crypto');
const { requireUser, json } = require('./lib/auth');
const {
  readIndexDocument,
  upsertCoin,
  migrateLegacyToUser,
  nextFrontSortOrder,
} = require('./lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  if (req.method === 'GET') {
    try {
      const doc = await readIndexDocument(user.id);
      if (doc.status === 'ok') {
        return json(res, 200, { coins: doc.coins, email: user.email });
      }
      if (doc.status === 'error') {
        return json(res, 503, { error: 'Could not read coin index' });
      }
      // Index blob missing → one-time legacy migrate (or claim empty purse).
      const coins = await migrateLegacyToUser(user.id);
      return json(res, 200, { coins, email: user.email });
    } catch (e) {
      console.error('GET /api/coins', e);
      return json(res, 503, { error: e.message || 'Could not load coins' });
    }
  }

  if (req.method === 'POST') {
    let body = '';
    for await (const chunk of req) body += chunk;
    let data;
    try { data = JSON.parse(body || '{}'); } catch {
      return json(res, 400, { error: 'Invalid JSON' });
    }
    const title = String(data.title || '').trim();
    if (!title) return json(res, 400, { error: 'Title required' });
    const now = Date.now();
    const doc = await readIndexDocument(user.id);
    if (doc.status === 'error') {
      return json(res, 503, { error: 'Could not read coin index' });
    }
    const existing = doc.coins;
    const sortOrder =
      typeof data.sortOrder === 'number'
        ? data.sortOrder
        : nextFrontSortOrder(existing);
    const coin = {
      id: data.id || crypto.randomUUID(),
      title,
      notes: String(data.notes || '').trim(),
      accent: Number.isInteger(data.accent) ? data.accent : Math.floor(Math.random() * 6),
      imageUrl: data.imageUrl || null,
      imagePath: data.imagePath || null,
      attachments: Array.isArray(data.attachments) ? data.attachments : [],
      sortOrder,
      createdAt: data.createdAt || now,
      updatedAt: now,
    };
    await upsertCoin(user.id, coin);
    return json(res, 201, { coin });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
