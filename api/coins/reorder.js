const { requireUser, json, readJsonBody } = require('../lib/auth');
const { reorderCoins } = require('../lib/store');
const { presentCoin } = require('../lib/imageurl');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  if (req.method !== 'POST') {
    return json(res, 405, { error: 'Method not allowed' });
  }

  const data = await readJsonBody(req, res);
  if (!data) return;
  const ids = data.ids;
  if (!Array.isArray(ids) || !ids.length || ids.length > 1000) {
    return json(res, 400, { error: 'ids array required' });
  }
  const coins = await reorderCoins(user.id, ids.map(String));
  return json(res, 200, { coins: coins.map((c) => presentCoin(c, user.id)) });
};
