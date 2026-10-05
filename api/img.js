const { getBlob, streamToResponse, storeMode } = require('./lib/blob');
const { verifyImageLink } = require('./lib/imageurl');

const SAFE_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);

/** Serves one private picture to anyone holding a valid signed link. */
module.exports = async function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.statusCode = 405;
    res.end();
    return;
  }
  const { p, e, s } = req.query || {};
  if (storeMode() !== 'private' || !verifyImageLink(p, e, s)) {
    res.statusCode = 404;
    res.end();
    return;
  }
  let result;
  try {
    result = await getBlob(String(p));
  } catch (err) {
    console.error('img', err);
    res.statusCode = 503;
    res.end();
    return;
  }
  if (!result) {
    res.statusCode = 404;
    res.end();
    return;
  }
  const type = String(result.blob.contentType || '').split(';')[0];
  res.statusCode = 200;
  res.setHeader('Content-Type', SAFE_TYPES.has(type) ? type : 'application/octet-stream');
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
  // Picture files never change (a new picture gets a new path).
  res.setHeader('Cache-Control', 'private, max-age=86400');
  if (req.method === 'HEAD') {
    res.end();
    return;
  }
  streamToResponse(result, res);
};
