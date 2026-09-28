const { json } = require('../lib/auth');
const { signPayload, verifyPin } = require('../lib/crypto');
const { findUserByEmail, upsertUser } = require('../lib/users');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  let body = '';
  for await (const chunk of req) body += chunk;
  let data = {};
  try { data = JSON.parse(body || '{}'); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const email = String(data.email || '').trim().toLowerCase();
  const code = String(data.code || '').trim().replace(/\s+/g, '');
  if (!email || !/^\d{6}$/.test(code)) {
    return json(res, 400, { error: 'Enter the 6-digit code from your email' });
  }

  const user = await findUserByEmail(email);
  if (!user || !user.loginCodeHash || !user.loginCodeSalt || !user.loginCodeExp) {
    return json(res, 401, { error: 'Code expired — request a new one' });
  }
  if (Date.now() > user.loginCodeExp) {
    user.loginCodeHash = null;
    user.loginCodeSalt = null;
    user.loginCodeExp = null;
    user.loginCodeAttempts = 0;
    user.updatedAt = Date.now();
    await upsertUser(user);
    return json(res, 401, { error: 'Code expired — request a new one' });
  }

  const attempts = Number(user.loginCodeAttempts || 0);
  if (attempts >= 8) {
    return json(res, 429, { error: 'Too many tries — request a new code' });
  }

  if (!verifyPin(code, user.loginCodeSalt, user.loginCodeHash)) {
    user.loginCodeAttempts = attempts + 1;
    user.updatedAt = Date.now();
    await upsertUser(user);
    return json(res, 401, { error: 'Wrong code' });
  }

  user.loginCodeHash = null;
  user.loginCodeSalt = null;
  user.loginCodeExp = null;
  user.loginCodeAttempts = 0;
  user.updatedAt = Date.now();
  await upsertUser(user);

  const needsPinSetup = !user.pinHash;
  const setupToken = signPayload(
    { typ: 'setup', uid: user.id, email: user.email },
    1000 * 60 * 30
  );
  return json(res, 200, {
    email: user.email,
    needsPinSetup,
    setupToken,
  });
};
