const { requireUser, json } = require('../../lib/auth');
const {
  readIndexDocument,
  patchCoinImage,
  userImagePath,
  isValidCoinId,
  deleteOwnedImage,
} = require('../../lib/store');
const { putBlob, deleteBlobsQuiet } = require('../../lib/blob');
const { presentCoin } = require('../../lib/imageurl');
const { readImageUpload } = require('../../lib/upload');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const id = req.query.id;
  if (!isValidCoinId(id)) return json(res, 400, { error: 'Missing id' });

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

  const upload = await readImageUpload(req, res);
  if (!upload) return;
  const pathname = userImagePath(user.id, id, upload.ext);
  const blob = await putBlob(pathname, upload.buf, { contentType: upload.contentType });

  try {
    const { coin, before } = await patchCoinImage(user.id, id, {
      imageUrl: blob.url,
      imagePath: pathname,
    });
    // Each upload has a unique path; drop the image it replaced (as it was at
    // the moment of saving, not when this request started).
    await deleteOwnedImage(user.id, before);
    const shown = presentCoin(coin, user.id);
    return json(res, 200, { coin: shown, url: shown.imageUrl });
  } catch (e) {
    // Avoid leaving an orphan blob if the coin disappeared mid-upload.
    await deleteBlobsQuiet(pathname);
    if (e.code === 'NOT_FOUND') {
      return json(res, 404, { error: 'Save the coin before uploading an image' });
    }
    if (e.code === 'TOMBSTONED') {
      return json(res, 410, { error: 'Coin was deleted' });
    }
    console.error('image upload patch', e);
    return json(res, 503, { error: 'Could not save image' });
  }
};
