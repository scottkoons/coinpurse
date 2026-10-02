const { json, issueSession, readJsonBody } = require('../lib/auth');
const { verifySigned, verifyPin } = require('../lib/crypto');
const { findUserById } = require('../lib/users');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const data = await readJsonBody(req, res);
  if (!data) return;

  const payload = verifySigned(String(data.setupToken || ''));
  if (!payload || payload.typ !== 'setup' || !payload.uid) {
    return json(res, 401, { error: 'Session expired — request a new link' });
  }
  const user = await findUserById(payload.uid);
  if (user && (payload.sv || 0) !== (user.sessionVersion || 0)) {
    return json(res, 401, { error: 'Session expired. Sign in again.' });
  }
  if (!user || !user.pinHash) {
    return json(res, 400, { error: 'Set a PIN first' });
  }
  // PINs remain only for older web app builds; the email code alone now signs in.
  if (!verifyPin(String(data.pin || ''), user.pinSalt, user.pinHash)) {
    return json(res, 401, { error: 'Wrong PIN' });
  }
  const session = issueSession(user);
  return json(res, 200, { token: session, email: user.email });
};
