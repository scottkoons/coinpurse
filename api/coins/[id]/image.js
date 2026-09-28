const { put } = require('@vercel/blob');
const { requireUser, json } = require('../../lib/auth');
const { readIndex, upsertCoin, userImagePath } = require('../../lib/store');

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') { res.statusCode = 204; res.end(); return; }
  const user = await requireUser(req, res);
  if (!user) return;
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const id = req.query.id;
  if (!id) return json(res, 400, { error: 'Missing id' });

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

  const coins = await readIndex(user.id);
  let coin = coins.find((c) => c.id === id);
  if (!coin) {
    coin = {
      id,
      title: 'Untitled',
      notes: '',
      accent: 0,
      createdAt: Date.now(),
      updatedAt: Date.now(),
    };
  }
  coin.imageUrl = blob.url;
  coin.imagePath = pathname;
  coin.updatedAt = Date.now();
  await upsertCoin(user.id, coin);
  return json(res, 200, { coin, url: blob.url });
};
