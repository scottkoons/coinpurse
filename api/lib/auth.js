const { verifySigned, signPayload } = require('./crypto');
const { findUserById } = require('./users');

function readBearer(req) {
  const h = req.headers.authorization || req.headers.Authorization || '';
  const m = String(h).match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : '';
}

function json(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.setHeader('Cache-Control', 'no-store');
  res.end(JSON.stringify(body));
}

/**
 * Session tokens last a year from their last renewal, and the server renews
 * them as they are used (see requireUser), so an app in use is never signed
 * out. Bumping user.sessionVersion signs out every device.
 */
const RENEW_AFTER_MS = 1000 * 60 * 60 * 24 * 7;

function issueSession(user) {
  return signPayload({
    typ: 'session',
    uid: user.id,
    email: user.email,
    sv: user.sessionVersion || 0,
  });
}

async function requireUser(req, res) {
  const token = readBearer(req);
  let payload = null;
  let user = null;
  try {
    payload = verifySigned(token);
    if (payload && payload.typ === 'session' && payload.uid) {
      user = await findUserById(payload.uid);
    }
  } catch (e) {
    console.error('requireUser', e);
    json(res, 503, { error: 'Could not check sign-in' });
    return null;
  }
  // Tokens from before session versions existed carry no sv; treat as 0.
  if (!user || (payload.sv || 0) !== (user.sessionVersion || 0)) {
    json(res, 401, { error: 'Unauthorized' });
    return null;
  }
  // Hand back a fresh token once a week; the app stores it.
  if (!payload.iat || Date.now() - payload.iat > RENEW_AFTER_MS) {
    res.setHeader('X-Coinpurse-Token', issueSession(user));
  }
  return user;
}

// backward-compatible name used by coin routes
async function requireAuth(req, res) {
  return requireUser(req, res);
}

async function readJsonBody(req, res, limit = 64 * 1024) {
  // Collect raw bytes and decode once at the end: a character can be split
  // across two chunks, and the limit is in bytes, not string length.
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    const buf = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    size += buf.length;
    if (size > limit) {
      json(res, 413, { error: 'Request too large' });
      return null;
    }
    chunks.push(buf);
  }
  const body = Buffer.concat(chunks).toString('utf8');
  try {
    const data = JSON.parse(body || '{}');
    if (data && typeof data === 'object' && !Array.isArray(data)) return data;
  } catch {}
  json(res, 400, { error: 'Invalid JSON' });
  return null;
}

module.exports = { requireAuth, requireUser, issueSession, readJsonBody, json, readBearer };
