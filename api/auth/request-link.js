const { json, readJsonBody } = require('../lib/auth');
const { hashPin, randomId } = require('../lib/crypto');
const { normalizeEmail, writeLogin, claimSlot, releaseSlots, pruneSlots } = require('../lib/users');
const { reviewCode } = require('../lib/review');
const { sendSignInCodeEmail } = require('../lib/mail');
const crypto = require('crypto');

const CODE_TTL_MS = 1000 * 60 * 15;
// Per email address: at most 3 codes per 15 minutes and 10 per day.
const SHORT_WINDOW_MS = 1000 * 60 * 15;
const SHORT_LIMIT = 3;
const DAY_MS = 1000 * 60 * 60 * 24;
const DAY_LIMIT = 10;

function sixDigitCode() {
  // 000000–999999, crypto-strong
  const n = crypto.randomInt(0, 1000000);
  return String(n).padStart(6, '0');
}

function isEmail(email) {
  return email.length <= 254 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const data = await readJsonBody(req, res);
  if (!data) return;

  const email = normalizeEmail(data.email);
  if (!isEmail(email)) return json(res, 400, { error: 'Valid email required' });

  const ok = { ok: true, message: 'Check your email for a 6-digit code.' };
  // The reviewer account never gets an email; it uses its fixed code.
  if (reviewCode(email)) return json(res, 200, ok);

  const now = Date.now();
  const window = `send-w${Math.floor(now / SHORT_WINDOW_MS)}`;
  const day = `send-d${Math.floor(now / DAY_MS)}`;
  const windowSlot = await claimSlot(email, window, SHORT_LIMIT);
  const daySlot = windowSlot && (await claimSlot(email, day, DAY_LIMIT));
  if (!windowSlot || !daySlot) {
    return json(res, 429, { error: 'Too many codes requested. Wait a few minutes and try again.' });
  }

  const code = sixDigitCode();
  const codeId = randomId();
  const { salt, hash } = hashPin(code);

  // Email first, save second. If the email fails, the code already in the
  // person's inbox keeps working and this attempt does not count against
  // their limit.
  try {
    await sendSignInCodeEmail({ to: email, code });
  } catch (e) {
    console.error('sendSignInCodeEmail', e);
    await releaseSlots([windowSlot, daySlot]);
    return json(res, 502, { error: 'Could not send email. Try again.' });
  }

  // No account is created here; that waits until the code is verified.
  // A new code replaces the old one, and its guesses are counted afresh.
  await writeLogin(email, {
    codeId,
    codeSalt: salt,
    codeHash: hash,
    codeExp: now + CODE_TTL_MS,
  });
  await pruneSlots(email, [window, day, `try-${codeId}`]);
  return json(res, 200, ok);
};
