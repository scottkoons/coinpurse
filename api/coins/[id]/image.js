const { put, del } = require('@vercel/blob');
const { requireUser, json } = require('../../lib/auth');
const {
  readIndexDocument,
  patchCoinImage,
  userImagePath,
} = require('../../lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const id = req.query.id;
  if (!id) return json(res, 400, { error: 'Missing id' });

  // Require an intentional saved coin first — never invent "Untitled" drafts.
  const doc = await readIndexDocument(user.id);
  if (doc.status === 'error') {
    return json(res, 503, { error: 'Could not read coin index' });
  }
  if (doc.deletedIds[id]) {
    return json(res, 410, { error: 'Coin was deleted' });
  }
  const existing = doc.coins.find((c) => c.id === id);
  if (!existing) {
    return json(res, 404, { error: 'Save the coin before uploading an image' });
  }

  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const buf = Buffer.concat(chunks);
  if (!buf.length) return json(res, 400, { error: 'Empty body' });

  const ctype = (req.headers['content-type'] || 'image/jpeg').split(';')[0];
  const ext = ctype.includes('png') ? 'png' : ctype.includes('webp') ? 'webp' : 'jpg';
  const pathname = userImagePath(user.id, id, ext);

  const blob = await put(pathname, buf, {
    access: 'public',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: ctype,
  });

  try {
    const coin = await patchCoinImage(user.id, id, {
      imageUrl: blob.url,
      imagePath: pathname,
    });
    // Each upload has a unique path; drop the image it replaced.
    if (existing.imagePath && existing.imagePath !== pathname) {
      try { await del(existing.imagePath); } catch (_) {}
    } else if (existing.imageUrl && existing.imageUrl !== blob.url) {
      try { await del(existing.imageUrl); } catch (_) {}
    }
    return json(res, 200, { coin, url: blob.url });
  } catch (e) {
    // Avoid leaving an orphan blob if the coin disappeared mid-upload.
    try { await del(pathname); } catch (_) {}
    if (e.code === 'NOT_FOUND') {
      return json(res, 404, { error: 'Save the coin before uploading an image' });
    }
    if (e.code === 'TOMBSTONED') {
      return json(res, 410, { error: 'Coin was deleted' });
    }
    console.error('image upload patch', e);
    return json(res, 503, { error: e.message || 'Could not save image' });
  }
};
