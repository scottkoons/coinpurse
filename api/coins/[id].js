const { requireUser, json } = require('../lib/auth');
const { readIndexDocument, upsertCoin, removeCoin } = require('../lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  const id = req.query.id;
  if (!id) return json(res, 400, { error: 'Missing id' });

  if (req.method === 'PUT') {
    let body = '';
    for await (const chunk of req) body += chunk;
    let data;
    try { data = JSON.parse(body || '{}'); } catch {
      return json(res, 400, { error: 'Invalid JSON' });
    }
    const doc = await readIndexDocument(user.id);
    if (doc.status === 'error') {
      return json(res, 503, { error: 'Could not read coin index' });
    }
    if (doc.deletedIds[id]) {
      return json(res, 410, { error: 'Coin was deleted' });
    }
    const existing = doc.coins.find((c) => c.id === id);
    if (!existing) return json(res, 404, { error: 'Not found' });
    const coin = {
      ...existing,
      title: data.title != null ? String(data.title).trim() : existing.title,
      notes: data.notes != null ? String(data.notes).trim() : existing.notes,
      accent: Number.isInteger(data.accent) ? data.accent : existing.accent,
      imageUrl: data.imageUrl !== undefined ? data.imageUrl : existing.imageUrl,
      imagePath: data.imagePath !== undefined ? data.imagePath : existing.imagePath,
      attachments: data.attachments !== undefined
        ? (Array.isArray(data.attachments) ? data.attachments : existing.attachments || [])
        : (existing.attachments || []),
      sortOrder: typeof data.sortOrder === 'number' ? data.sortOrder : existing.sortOrder,
      updatedAt: Date.now(),
    };
    if (!coin.title) return json(res, 400, { error: 'Title required' });
    try {
      const saved = await upsertCoin(user.id, coin);
      return json(res, 200, { coin: saved });
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
