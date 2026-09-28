const { json } = require('../lib/auth');
const { verifySigned, signPayload, hashPin } = require('../lib/crypto');
const { findUserById, upsertUser } = require('../lib/users');
const { migrateLegacyToUser } = require('../lib/store');

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
  const pin = String(data.pin || '');
  if (pin.length < 4 || pin.length > 12) {
    return json(res, 400, { error: 'PIN must be 4–12 characters' });
  }

  const user = await findUserById(payload.uid);
  if (!user) return json(res, 404, { error: 'User not found' });

  const { salt, hash } = hashPin(pin);
  user.pinSalt = salt;
  user.pinHash = hash;
  user.updatedAt = Date.now();
  await upsertUser(user);

  // First account to set a PIN inherits any legacy single-purse coins.
  try { await migrateLegacyToUser(user.id); } catch (e) { console.warn('migrate', e); }

  const session = signPayload({ typ: 'session', uid: user.id, email: user.email });
  return json(res, 200, { token: session, email: user.email });
};
