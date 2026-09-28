const { requireUser, json } = require('../lib/auth');
const { reorderCoins } = require('../lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  if (req.method !== 'POST') {
    return json(res, 405, { error: 'Method not allowed' });
  }

  let body = '';
  for await (const chunk of req) body += chunk;
  let data;
  try { data = JSON.parse(body || '{}'); } catch {
    return json(res, 400, { error: 'Invalid JSON' });
  }
  const ids = data.ids;
  if (!Array.isArray(ids) || !ids.length) {
    return json(res, 400, { error: 'ids array required' });
  }
  const coins = await reorderCoins(user.id, ids.map(String));
  return json(res, 200, { coins });
};
