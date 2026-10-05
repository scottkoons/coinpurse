const { requireUser, json } = require('./auth');
const { normalizeEmail } = require('./users');

/**
 * The one-time admin jobs run only for a signed-in account listed in
 * ADMIN_EMAILS (comma separated). Without ADMIN_EMAILS the routes do not exist.
 */
async function requireAdmin(req, res) {
  const admins = String(process.env.ADMIN_EMAILS || '')
    .split(',')
    .map(normalizeEmail)
    .filter(Boolean);
  if (!admins.length) {
    json(res, 404, { error: 'Not found' });
    return null;
  }
  const user = await requireUser(req, res);
  if (!user) return null;
  if (!admins.includes(normalizeEmail(user.email))) {
    json(res, 403, { error: 'Forbidden' });
    return null;
  }
  return user;
}

module.exports = { requireAdmin };
