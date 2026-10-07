const { json } = require('./auth');

const IMAGE_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
// Vercel caps request bodies near 4.5 MB; stop reading well before that.
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;

/**
 * Read an uploaded picture. Only JPEG, PNG and WebP are accepted so nobody
 * can store a web page or script and have it served back from our domain.
 * Returns { buf, contentType, ext } or null after sending an error.
 */
const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
// The last chunk of every PNG: length 0, type IEND, fixed CRC.
const PNG_IEND = Buffer.from([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]);

/**
 * Both ends of the file are checked, not just the start, so an upload cut off
 * part way (a dropped connection, a phone that ran out of memory) is refused
 * instead of being saved as a half-gray picture.
 */
function looksLike(contentType, buf) {
  if (contentType === 'image/jpeg') {
    if (!(buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff)) return false;
    // Ends with the EOI marker FF D9. Some cameras pad the file with zero bytes after it.
    let end = buf.length;
    while (end > 3 && buf[end - 1] === 0) end--;
    return end > 4 && buf[end - 2] === 0xff && buf[end - 1] === 0xd9;
  }
  if (contentType === 'image/png') {
    return buf.length >= PNG_SIGNATURE.length + PNG_IEND.length &&
      buf.subarray(0, 8).equals(PNG_SIGNATURE) &&
      buf.subarray(buf.length - PNG_IEND.length).equals(PNG_IEND);
  }
  if (contentType === 'image/webp') {
    if (!(buf.length > 12 && buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP')) return false;
    // The RIFF size counts every byte after the first 8. Off by one is allowed
    // because writers disagree about counting the final padding byte.
    const declared = buf.readUInt32LE(4) + 8;
    return Math.abs(buf.length - declared) <= 1;
  }
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
