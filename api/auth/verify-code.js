const { json, readJsonBody, issueSession } = require('../lib/auth');
const { verifyPin, safeEqual } = require('../lib/crypto');
const { normalizeEmail, readLogin, writeLogin, findOrCreateUser, claimSlot } = require('../lib/users');
const { reviewCode } = require('../lib/review');

const MAX_ATTEMPTS = 8;
const REVIEW_WINDOW_MS = 1000 * 60 * 15;

const tooMany = (res) => json(res, 429, { error: 'Too many tries. Request a new code.' });

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const data = await readJsonBody(req, res);
  if (!data) return;

  const email = normalizeEmail(data.email);
  const code = String(data.code || '').trim().replace(/\s+/g, '');
  if (!email || !/^\d{6}$/.test(code)) {
    return json(res, 400, { error: 'Enter the 6-digit code from your email' });
  }

  // Every guess first claims one of MAX_ATTEMPTS slots, so parallel guesses
  // cannot slip past the limit.
  const fixed = reviewCode(email);
  let valid = false;
  if (fixed) {
    // The reviewer code never changes, so its guesses are limited per
    // 15-minute window: a typo cannot lock the account for long.
    const window = `review-w${Math.floor(Date.now() / REVIEW_WINDOW_MS)}`;
    if (!(await claimSlot(email, window, MAX_ATTEMPTS))) return tooMany(res);
    valid = safeEqual(code, fixed);
  } else {
    const login = await readLogin(email);
    if (!login.codeHash || !login.codeId || !login.codeExp || Date.now() > login.codeExp) {
      return json(res, 401, { error: 'Code expired. Request a new one.' });
    }
    if (!(await claimSlot(email, `try-${login.codeId}`, MAX_ATTEMPTS))) return tooMany(res);
    valid = verifyPin(code, login.codeSalt, login.codeHash);
    // A code works once.
    if (valid) await writeLogin(email, {});
  }

  if (!valid) return json(res, 401, { error: 'Wrong code' });

  const user = await findOrCreateUser(email);

  return json(res, 200, { email: user.email, token: issueSession(user) });
};
