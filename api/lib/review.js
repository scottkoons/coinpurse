const { normalizeEmail } = require('./users');

/**
 * App Store reviewer sign-in. Apple's reviewer cannot read a code from our
 * email, so one account (REVIEW_EMAIL) accepts a fixed code (REVIEW_CODE)
 * instead of an emailed one. Both are set in Vercel, never in the repo.
 */
function reviewCode(email) {
  const reviewEmail = normalizeEmail(process.env.REVIEW_EMAIL);
  const code = String(process.env.REVIEW_CODE || '');
  if (!reviewEmail || !/^\d{6}$/.test(code)) return null;
  return normalizeEmail(email) === reviewEmail ? code : null;
}

module.exports = { reviewCode };
