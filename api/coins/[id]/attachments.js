const crypto = require('crypto');
const { put, del } = require('@vercel/blob');
const { requireUser, json } = require('../../lib/auth');
const {
  readIndexDocument,
  upsertCoin,
  userAttachmentPath,
  MAX_ATTACHMENTS,
} = require('../../lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  const id = req.query.id;
  if (!id) return json(res, 400, { error: 'Missing id' });

  const doc = await readIndexDocument(user.id);
  if (doc.status === 'error') {
    return json(res, 503, { error: 'Could not read coin index' });
  }
  if (doc.deletedIds[id]) return json(res, 410, { error: 'Coin was deleted' });
  const coin = doc.coins.find((c) => c.id === id);
  if (!coin) return json(res, 404, { error: 'Save the coin before adding images' });
  if (!Array.isArray(coin.attachments)) coin.attachments = [];

  if (req.method === 'POST') {
    if (coin.attachments.length >= MAX_ATTACHMENTS) {
      return json(res, 400, { error: `Max ${MAX_ATTACHMENTS} extra images` });
    }

    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const buf = Buffer.concat(chunks);
    if (!buf.length) return json(res, 400, { error: 'Empty body' });

    const ctype = (req.headers['content-type'] || 'image/jpeg').split(';')[0];
    const ext = ctype.includes('png') ? 'png' : ctype.includes('webp') ? 'webp' : 'jpg';
    const attId = crypto.randomUUID();
    const pathname = userAttachmentPath(user.id, id, attId, ext);

    const blob = await put(pathname, buf, {
      access: 'public',
      addRandomSuffix: false,
      allowOverwrite: true,
      contentType: ctype,
    });

    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    coin.attachments.push(att);
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    return json(res, 200, { coin, attachment: att });
  }


  if (req.method === 'PUT') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    const idx = coin.attachments.findIndex((a) => a.id === attId);
    if (idx < 0) return json(res, 404, { error: 'Attachment not found' });

    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const buf = Buffer.concat(chunks);
    if (!buf.length) return json(res, 400, { error: 'Empty body' });

    const ctype = (req.headers['content-type'] || 'image/jpeg').split(';')[0];
    const ext = ctype.includes('png') ? 'png' : ctype.includes('webp') ? 'webp' : 'jpg';
    const pathname = userAttachmentPath(user.id, id, attId, ext);

    const blob = await put(pathname, buf, {
      access: 'public',
      addRandomSuffix: false,
      allowOverwrite: true,
      contentType: ctype,
    });

    const prev = coin.attachments[idx];
    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    coin.attachments[idx] = att;
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    // Each upload has a unique path; drop the image it replaced.
    if (prev?.imagePath && prev.imagePath !== pathname) {
      try { await del(prev.imagePath); } catch (_) {}
    } else if (prev?.imageUrl && prev.imageUrl !== blob.url) {
      try { await del(prev.imageUrl); } catch (_) {}
    }
    return json(res, 200, { coin, attachment: att });
  }

  if (req.method === 'DELETE') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    const idx = coin.attachments.findIndex((a) => a.id === attId);
    if (idx < 0) return json(res, 404, { error: 'Attachment not found' });
    const [removed] = coin.attachments.splice(idx, 1);
    if (removed?.imagePath) {
      try { await del(removed.imagePath); } catch (_) {}
    }
    if (removed?.imageUrl) {
      try { await del(removed.imageUrl); } catch (_) {}
    }
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    return json(res, 200, { coin, removed: removed.id });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
