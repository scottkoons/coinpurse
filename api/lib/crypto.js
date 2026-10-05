const crypto = require('crypto');

function secret() {
  const s = process.env.AUTH_SECRET || process.env.COINPURSE_TOKEN;
  // Fail closed: a guessable default would let anyone forge a session.
  if (!s || s.length < 16) throw new Error('AUTH_SECRET is not configured');
  return s;
}

function hmac(data) {
  return crypto.createHmac('sha256', secret()).update(String(data)).digest('base64url');
}

function safeEqual(a, b) {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
}

/** Stable storage key for an email address (keeps addresses out of file names). */
function emailKey(email) {
  return crypto.createHash('sha256').update('coinpurse-email:' + email).digest('hex').slice(0, 40);
}

function hashPin(pin, salt) {
  const s = salt || crypto.randomBytes(16).toString('hex');
  const hash = crypto.scryptSync(String(pin), s, 32).toString('hex');
  return { salt: s, hash };
}

function verifyPin(pin, salt, hash) {
  try {
    const h = crypto.scryptSync(String(pin), String(salt), 32);
    const a = Buffer.from(String(hash), 'hex');
    if (a.length !== h.length) return false;
    return crypto.timingSafeEqual(a, h);
  } catch {
    return false;
  }
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64url');
}

function signPayload(payload, maxAgeMs) {
  const now = Date.now();
  const body = {
    ...payload,
    iat: now,
    exp: now + (maxAgeMs || 1000 * 60 * 60 * 24 * 365),
  };
  const data = b64url(JSON.stringify(body));
  return data + '.' + hmac(data);
}

function verifySigned(token) {
  if (!token || typeof token !== 'string' || !token.includes('.')) return null;
  const [data, sig] = token.split('.');
  if (!safeEqual(sig, hmac(data))) return null;
  try {
    const body = JSON.parse(Buffer.from(data, 'base64url').toString('utf8'));
    if (!body || !body.exp || body.exp < Date.now()) return null;
    return body;
  } catch {
    return null;
  }
}

function randomId() {
  return crypto.randomUUID ? crypto.randomUUID() : crypto.randomBytes(16).toString('hex');
}

module.exports = {
  hashPin,
  verifyPin,
  signPayload,
  verifySigned,
  randomId,
  secret,
  hmac,
  safeEqual,
  emailKey,
};
