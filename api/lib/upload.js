const { json } = require('./auth');

const IMAGE_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
// Vercel caps request bodies near 4.5 MB; stop reading well before that.
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/**
 * Read an uploaded picture. Only JPEG, PNG and WebP are accepted so nobody
 * can store a web page or script and have it served back from our domain.
 * Returns { buf, contentType, ext } or null after sending an error.
 */
async function readImageUpload(req, res) {
  const contentType = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  const ext = IMAGE_TYPES[contentType];
  if (!ext) {
    json(res, 415, { error: 'Pictures must be JPEG, PNG or WebP' });
    return null;
  }
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_IMAGE_BYTES) {
      json(res, 413, { error: 'Picture is too large' });
      return null;
    }
    chunks.push(chunk);
  }
  const buf = Buffer.concat(chunks);
  if (!buf.length) {
    json(res, 400, { error: 'Empty body' });
    return null;
  }
  return { buf, contentType, ext };
}

module.exports = { readImageUpload };
