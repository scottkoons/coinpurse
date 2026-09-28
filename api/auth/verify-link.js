const { json } = require('../lib/auth');
const { verifySigned, signPayload } = require('../lib/crypto');
const { findUserById } = require('../lib/users');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  let body = '';
  for await (const chunk of req) body += chunk;
  let data = {};
  try { data = JSON.parse(body || '{}'); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const payload = verifySigned(String(data.token || ''));
  if (!payload || payload.typ !== 'magic' || !payload.uid) {
    return json(res, 401, { error: 'Link expired or invalid' });
  }
  const user = await findUserById(payload.uid);
  if (!user || user.email !== payload.email) {
    return json(res, 401, { error: 'Link expired or invalid' });
  }

  const needsPinSetup = !user.pinHash;
  const setupToken = signPayload({ typ: 'setup', uid: user.id, email: user.email }, 1000 * 60 * 30);
  return json(res, 200, {
    email: user.email,
    needsPinSetup,
    setupToken,
  });
};
