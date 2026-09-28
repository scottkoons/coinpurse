const crypto = require('crypto');

function secret() {
  return process.env.AUTH_SECRET || process.env.COINPURSE_TOKEN || 'dev-insecure';
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
  const body = {
    ...payload,
    exp: Date.now() + (maxAgeMs || 1000 * 60 * 60 * 24 * 365),
  };
  const data = b64url(JSON.stringify(body));
  const sig = crypto.createHmac('sha256', secret()).update(data).digest('base64url');
  return data + '.' + sig;
}

function verifySigned(token) {
  if (!token || typeof token !== 'string' || !token.includes('.')) return null;
  const [data, sig] = token.split('.');
  const expect = crypto.createHmac('sha256', secret()).update(data).digest('base64url');
  const a = Buffer.from(sig);
  const b = Buffer.from(expect);
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
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
};
