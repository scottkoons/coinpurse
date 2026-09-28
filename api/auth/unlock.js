const { json } = require('../lib/auth');
const { verifySigned, signPayload, verifyPin } = require('../lib/crypto');
const { findUserById } = require('../lib/users');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  let body = '';
  for await (const chunk of req) body += chunk;
  let data = {};
  try { data = JSON.parse(body || '{}'); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const payload = verifySigned(String(data.setupToken || ''));
  if (!payload || (payload.typ !== 'setup' && payload.typ !== 'magic') || !payload.uid) {
    return json(res, 401, { error: 'Session expired — request a new link' });
  }
  const user = await findUserById(payload.uid);
  if (!user || !user.pinHash) {
    return json(res, 400, { error: 'Set a PIN first' });
  }
  if (!verifyPin(String(data.pin || ''), user.pinSalt, user.pinHash)) {
    return json(res, 401, { error: 'Wrong PIN' });
  }
  const session = signPayload({ typ: 'session', uid: user.id, email: user.email });
  return json(res, 200, { token: session, email: user.email });
};
