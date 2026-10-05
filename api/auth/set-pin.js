const { json, issueSession, readJsonBody } = require('../lib/auth');
const { verifySigned, hashPin } = require('../lib/crypto');
const { findUserById, saveUser } = require('../lib/users');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const data = await readJsonBody(req, res);
  if (!data) return;

  const payload = verifySigned(String(data.setupToken || ''));
  if (!payload || payload.typ !== 'setup' || !payload.uid) {
    return json(res, 401, { error: 'Session expired — request a new link' });
  }
  const pin = String(data.pin || '');
  if (pin.length < 4 || pin.length > 12) {
    return json(res, 400, { error: 'PIN must be 4–12 characters' });
  }

  const user = await findUserById(payload.uid);
  // Signing out of all devices also cancels pending setup tokens.
  if (!user || (payload.sv || 0) !== (user.sessionVersion || 0)) {
    return json(res, 401, { error: 'Session expired. Sign in again.' });
  }

  const { salt, hash } = hashPin(pin);
  user.pinSalt = salt;
  user.pinHash = hash;
  await saveUser(user);

  const session = issueSession(user);
  return json(res, 200, { token: session, email: user.email });
};
