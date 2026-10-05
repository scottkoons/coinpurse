const crypto = require('crypto');
const { requireUser, json } = require('../../lib/auth');
const {
  readIndexDocument,
  upsertCoin,
  userAttachmentPath,
  isValidCoinId,
  deleteOwnedImage,
  MAX_ATTACHMENTS,
} = require('../../lib/store');
const { putBlob } = require('../../lib/blob');
const { presentCoin } = require('../../lib/imageurl');
const { readImageUpload } = require('../../lib/upload');

function respond(res, user, coin, att, extra = {}) {
  const shown = presentCoin(coin, user.id);
  const shownAtt = att ? shown.attachments.find((a) => a.id === att.id) : undefined;
  return json(res, 200, { coin: shown, ...(shownAtt ? { attachment: shownAtt } : {}), ...extra });
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;

  const id = req.query.id;
  if (!isValidCoinId(id)) return json(res, 400, { error: 'Missing id' });

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
    const upload = await readImageUpload(req, res);
    if (!upload) return;
    const attId = crypto.randomUUID();
    const pathname = userAttachmentPath(user.id, id, attId, upload.ext);
    const blob = await putBlob(pathname, upload.buf, { contentType: upload.contentType });

    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    coin.attachments.push(att);
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    return respond(res, user, coin, att);
  }

  if (req.method === 'PUT') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    const idx = coin.attachments.findIndex((a) => a.id === attId);
    if (idx < 0) return json(res, 404, { error: 'Attachment not found' });

    const upload = await readImageUpload(req, res);
    if (!upload) return;
    const pathname = userAttachmentPath(user.id, id, attId, upload.ext);
    const blob = await putBlob(pathname, upload.buf, { contentType: upload.contentType });

    const prev = coin.attachments[idx];
    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    coin.attachments[idx] = att;
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    // Each upload has a unique path; drop the image it replaced.
    await deleteOwnedImage(user.id, prev);
    return respond(res, user, coin, att);
  }

  if (req.method === 'DELETE') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    const idx = coin.attachments.findIndex((a) => a.id === attId);
    if (idx < 0) return json(res, 404, { error: 'Attachment not found' });
    const [removed] = coin.attachments.splice(idx, 1);
    coin.updatedAt = Date.now();
    await upsertCoin(user.id, coin);
    await deleteOwnedImage(user.id, removed);
    return respond(res, user, coin, null, { removed: removed.id });
  }

  return json(res, 405, { error: 'Method not allowed' });
};
