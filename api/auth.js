const { json } = require('./lib/auth');

// Legacy single-PIN unlock removed. Use /api/auth/request-link.
module.exports = async function handler(req, res) {
  return json(res, 410, {
    error: 'Use email sign-in',
    requestLink: '/api/auth/request-link',
  });
};
