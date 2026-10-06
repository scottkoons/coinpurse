const { json } = require('./auth');

const IMAGE_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
// Vercel caps request bodies near 4.5 MB; stop reading well before that.
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/**
 * Read an uploaded picture. Only JPEG, PNG and WebP are accepted so nobody
 * can store a web page or script and have it served back from our domain.
 * Returns { buf, contentType, ext } or null after sending an error.
 */
function looksLike(contentType, buf) {
  if (contentType === 'image/jpeg') return buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff;
  if (contentType === 'image/png') return buf.length > 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  if (contentType === 'image/webp') return buf.length > 12 && buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP';
  return false;
}

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
  // The bytes must really be that kind of picture, whatever the label says.
  if (!looksLike(contentType, buf)) {
    json(res, 415, { error: 'That file is not a JPEG, PNG or WebP picture' });
    return null;
  }
  return { buf, contentType, ext };
}

module.exports = { readImageUpload };
