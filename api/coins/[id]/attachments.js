const crypto = require('crypto');
const { requireUser, json } = require('../../lib/auth');
const {
  readIndexDocument,
  updateCoin,
  userAttachmentPath,
  isValidCoinId,
  deleteOwnedImage,
  MAX_ATTACHMENTS,
} = require('../../lib/store');
const { putBlob, deleteBlobsQuiet } = require('../../lib/blob');
const { presentCoin } = require('../../lib/imageurl');
const { readImageUpload } = require('../../lib/upload');

function full() {
  const err = new Error('Full');
  err.code = 'FULL';
  return err;
}

function gone() {
  const err = new Error('Attachment not found');
  err.code = 'ATT_NOT_FOUND';
  return err;
}

function failed(res, e) {
  if (e.code === 'FULL') return json(res, 400, { error: `Max ${MAX_ATTACHMENTS} extra images` });
  if (e.code === 'ATT_NOT_FOUND') return json(res, 404, { error: 'Attachment not found' });
  if (e.code === 'TOMBSTONED') return json(res, 410, { error: 'Coin was deleted' });
  if (e.code === 'NOT_FOUND') return json(res, 404, { error: 'Not found' });
  console.error('attachments', e);
  return json(res, 503, { error: 'Could not save the picture; try again' });
}

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
    // Quick early answer when the coin is already full; checked again when saving.
    if (coin.attachments.length >= MAX_ATTACHMENTS) {
      return json(res, 400, { error: `Max ${MAX_ATTACHMENTS} extra images` });
    }
    const upload = await readImageUpload(req, res);
    if (!upload) return;
    const attId = crypto.randomUUID();
    const pathname = userAttachmentPath(user.id, id, attId, upload.ext);
    const blob = await putBlob(pathname, upload.buf, { contentType: upload.contentType });
    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    try {
      // Added to the latest copy of the coin, so pictures sent together are all kept.
      const { coin: saved } = await updateCoin(user.id, id, (latest) => {
        if (latest.attachments.length >= MAX_ATTACHMENTS) throw full();
        return { ...latest, attachments: [...latest.attachments, att], updatedAt: Date.now() };
      });
      return respond(res, user, saved, att);
    } catch (e) {
      await deleteBlobsQuiet(pathname);
      return failed(res, e);
    }
  }

  if (req.method === 'PUT') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    if (!coin.attachments.some((a) => a.id === attId)) return json(res, 404, { error: 'Attachment not found' });

    const upload = await readImageUpload(req, res);
    if (!upload) return;
    const pathname = userAttachmentPath(user.id, id, attId, upload.ext);
    const blob = await putBlob(pathname, upload.buf, { contentType: upload.contentType });
    const att = { id: attId, imageUrl: blob.url, imagePath: pathname };
    let prev = null;
    try {
      const { coin: saved } = await updateCoin(user.id, id, (latest) => {
        const idx = latest.attachments.findIndex((a) => a.id === attId);
        if (idx < 0) throw gone();
        prev = latest.attachments[idx];
        const attachments = latest.attachments.slice();
        attachments[idx] = att;
        return { ...latest, attachments, updatedAt: Date.now() };
      });
      // Each upload has a unique path; drop the image it replaced.
      await deleteOwnedImage(user.id, prev);
      return respond(res, user, saved, att);
    } catch (e) {
      await deleteBlobsQuiet(pathname);
      return failed(res, e);
    }
  }

  if (req.method === 'DELETE') {
    const attId = req.query.attId || req.query.attachmentId;
    if (!attId) return json(res, 400, { error: 'Missing attId' });
    let removed = null;
    try {
      const { coin: saved } = await updateCoin(user.id, id, (latest) => {
        const idx = latest.attachments.findIndex((a) => a.id === attId);
        if (idx < 0) throw gone();
        removed = latest.attachments[idx];
        return { ...latest, attachments: latest.attachments.filter((a) => a.id !== attId), updatedAt: Date.now() };
      });
      await deleteOwnedImage(user.id, removed);
      return respond(res, user, saved, null, { removed: removed.id });
    } catch (e) {
      return failed(res, e);
    }
  }

  return json(res, 405, { error: 'Method not allowed' });
};
