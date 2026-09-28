const { verifySigned } = require('./crypto');
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

async function requireUser(req, res) {
  const token = readBearer(req);
  const payload = verifySigned(token);
  if (!payload || payload.typ !== 'session' || !payload.uid) {
    json(res, 401, { error: 'Unauthorized' });
    return null;
  }
  const user = await findUserById(payload.uid);
  if (!user) {
    json(res, 401, { error: 'Unauthorized' });
    return null;
  }
  return user;
}

// backward-compatible name used by coin routes
async function requireAuth(req, res) {
  return requireUser(req, res);
}

module.exports = { requireAuth, requireUser, json, readBearer };
