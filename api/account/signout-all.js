const { requireUser, json, issueSession } = require('../lib/auth');
const { saveUser } = require('../lib/users');

/** Sign out every device (lost phone). Returns a fresh token for this device. */
module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });
  const user = await requireUser(req, res);
  if (!user) return;
  user.sessionVersion = (user.sessionVersion || 0) + 1;
  await saveUser(user);
  return json(res, 200, { ok: true, token: issueSession(user) });
};
