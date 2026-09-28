const { json } = require('../lib/auth');
const { randomId, hashPin } = require('../lib/crypto');
const { findUserByEmail, upsertUser } = require('../lib/users');
const { sendSignInCodeEmail } = require('../lib/mail');
const crypto = require('crypto');

function sixDigitCode() {
  // 000000–999999, crypto-strong
  const n = crypto.randomInt(0, 1000000);
  return String(n).padStart(6, '0');
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  let body = '';
  for await (const chunk of req) body += chunk;
  let data = {};
  try { data = JSON.parse(body || '{}'); } catch { return json(res, 400, { error: 'Invalid JSON' }); }

  const email = String(data.email || '').trim().toLowerCase();
  if (!email || !email.includes('@')) return json(res, 400, { error: 'Valid email required' });

  let user = await findUserByEmail(email);
  if (!user) {
    user = {
      id: randomId(),
      email,
      pinSalt: null,
      pinHash: null,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
  }

  const code = sixDigitCode();
  const { salt, hash } = hashPin(code);
  user.loginCodeSalt = salt;
  user.loginCodeHash = hash;
  user.loginCodeExp = Date.now() + 1000 * 60 * 15;
  user.loginCodeAttempts = 0;
  user.updatedAt = Date.now();
  await upsertUser(user);

  try {
    await sendSignInCodeEmail({ to: email, code });
  } catch (e) {
    console.error('sendSignInCodeEmail', e);
    return json(res, 502, { error: e.message || 'Could not send email' });
  }

  const payload = { ok: true, message: 'Check your email for a 6-digit code.' };
  // Dev/debug only — never put the code in the email client path for prod UX.
  if (process.env.COINPURSE_RETURN_CODE === '1') payload.code = code;
  return json(res, 200, payload);
};
