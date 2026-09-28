const { requireUser, json } = require('../lib/auth');
const { readIndex, upsertCoin, removeCoin } = require('../lib/store');

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
    const coins = await readIndex(user.id);
    const existing = coins.find((c) => c.id === id);
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
    await upsertCoin(user.id, coin);
    return json(res, 200, { coin });
  }

  if (req.method === 'DELETE') {
    await removeCoin(user.id, id);
    return json(res, 200, { ok: true });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
