const { requireUser, json } = require('./lib/auth');
const { deleteAllUserData } = require('./lib/store');
const { deleteUserRecords } = require('./lib/users');

/**
 * GET    /api/account  who is signed in
 * DELETE /api/account  permanently delete the account, every coin and every picture
 */
module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  if (req.method === 'GET') {
    return json(res, 200, { email: user.email, createdAt: user.createdAt || null });
  }

  if (req.method === 'DELETE') {
    try {
      // Coins and pictures first: if this fails part way, the account still
      // exists and the user can simply try again.
      await deleteAllUserData(user.id);
      await deleteUserRecords(user);
      // Catch anything written while the delete was running.
      await deleteAllUserData(user.id).catch(() => {});
    } catch (e) {
      console.error('DELETE /api/account', e);
      return json(res, 503, { error: 'Could not delete the account. Try again.' });
    }
    return json(res, 200, { ok: true });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
