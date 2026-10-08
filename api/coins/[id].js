const { requireUser, json, readJsonBody } = require('../lib/auth');
const { updateCoin, removeCoin, isValidCoinId } = require('../lib/store');
const { presentCoin } = require('../lib/imageurl');
const { cleanTitle, cleanNotes, validAccent, cleanPin } = require('../lib/coinfields');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  const id = req.query.id;
  if (!isValidCoinId(id)) return json(res, 400, { error: 'Missing id' });

  if (req.method === 'PUT') {
    const data = await readJsonBody(req, res);
    if (!data) return;
    // A pin is only changed when the request includes one (null removes it).
    const pin = data.pin === undefined ? null : cleanPin(data.pin);
    if (pin && !pin.ok) return json(res, 400, { error: 'That map pin is not a real place' });
    try {
      // Applied to the latest copy of the coin, so pictures arriving at the
      // same moment are kept.
      const { coin } = await updateCoin(user.id, id, (existing) => ({
        // Only text, color, pin, order, archived and hidden can change here. Picture fields sent
        // by a client are ignored; pictures change only through the upload endpoints.
        ...existing,
        // Clearing the title keeps the old one (every coin has a name).
        title: cleanTitle(data.title) || existing.title,
        notes: data.notes != null ? cleanNotes(data.notes) : existing.notes,
        accent: validAccent(data.accent) ? data.accent : existing.accent,
        pin: pin ? pin.value : existing.pin || null,
        // Archived coins stay in the purse data but out of the stack; hidden
        // ones ask for Face ID in the apps. Changed only when a client says so.
        archived: typeof data.archived === 'boolean' ? data.archived : existing.archived === true,
        hidden: typeof data.hidden === 'boolean' ? data.hidden : existing.hidden === true,
        // JSON such as 1e309 parses to Infinity, which would be saved as null.
        sortOrder: Number.isFinite(data.sortOrder) ? data.sortOrder : existing.sortOrder,
        updatedAt: Date.now(),
      }));
      return json(res, 200, { coin: presentCoin(coin, user.id) });
    } catch (e) {
      if (e.code === 'TOMBSTONED') return json(res, 410, { error: 'Coin was deleted' });
      if (e.code === 'NOT_FOUND') return json(res, 404, { error: 'Not found' });
      console.error('update coin', e);
      return json(res, 503, { error: 'Could not save the coin; try again' });
    }
  }

  if (req.method === 'DELETE') {
    try {
      await removeCoin(user.id, id);
    } catch (e) {
      console.error('delete coin', e);
      return json(res, 503, { error: 'Could not delete the coin; try again' });
    }
    return json(res, 200, { ok: true });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
