const { json } = require('../lib/auth');
const { requireAdmin } = require('../lib/admin');
const { listPage, readBlobBuffer, putBlob } = require('../lib/blob');
const { readIndexDocument, mutateIndex } = require('../lib/store');
const { pathOfImage, ownsPath } = require('../lib/imageurl');

/**
 * One-time fix before the private-store move. Coins inherited from the old
 * single purse can point at pictures outside their owner's folder; the new
 * rules only show and delete pictures inside it. This copies each such
 * picture into the owner's folder and points the coin at the copy.
 *
 *   POST /api/admin/adopt-images[?cursor=..]   (signed in as an ADMIN_EMAILS account)
 */

// Only picture files may be adopted. Old index files could hold any path a
// client planted (for example coinpurse/users.json); those are left alone.
const SOURCE = /^coinpurse\/(images\/|users\/[A-Za-z0-9-]+\/images\/)[A-Za-z0-9._-]+\.(jpe?g|png|webp)$/i;

function pictureType(buf) {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return ['image/jpeg', 'jpg'];
  if (buf.length > 8 && buf.slice(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return ['image/png', 'png'];
  if (buf.length > 12 && buf.slice(0, 4).toString() === 'RIFF' && buf.slice(8, 12).toString() === 'WEBP') return ['image/webp', 'webp'];
  return null;
}

/** Returns 'moved', 'kept' (already in the owner's folder or no picture) or 'skipped'. */
async function adopt(uid, item, tag) {
  const from = pathOfImage(item);
  if (!from || ownsPath(uid, from)) return 'kept';
  if (!SOURCE.test(from) || from.includes('..')) return 'skipped';
  const file = await readBlobBuffer(from, { fresh: true });
  const type = file && pictureType(file.buffer);
  if (!type) return 'skipped';
  const safeTag = String(tag).replace(/[^A-Za-z0-9_-]/g, '').slice(0, 80) || 'pic';
  const to = `coinpurse/users/${uid}/images/adopted-${safeTag}-${Date.now().toString(36)}.${type[1]}`;
  const blob = await putBlob(to, file.buffer, { contentType: type[0] });
  item.imagePath = to;
  item.imageUrl = blob.url;
  return 'moved';
}

module.exports = async function handler(req, res) {
  if (!(await requireAdmin(req, res))) return;
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });

  const page = await listPage('coinpurse/users/', req.query.cursor || undefined, { limit: 50, folded: true });
  const report = [];
  for (const folder of page.folders || []) {
    const uid = folder.replace(/^coinpurse\/users\//, '').replace(/\/$/, '');
    const doc = await readIndexDocument(uid);
    if (doc.status !== 'ok') continue;
    let moved = 0;
    const skipped = [];
    // Old path -> new copy. Copies are made first (slow), then applied to the
    // purse as it is at that moment, so changes made meanwhile are kept.
    const copies = new Map();
    for (const coin of doc.coins) {
      const items = [[coin, coin.id], ...(Array.isArray(coin.attachments) ? coin.attachments : []).map((a) => [a, `${coin.id}-${a.id}`])];
      for (const [item, tag] of items) {
        const from = pathOfImage(item);
        const r = await adopt(uid, item, tag);
        if (r === 'moved') {
          moved++;
          copies.set(from, { imagePath: item.imagePath, imageUrl: item.imageUrl });
        }
        if (r === 'skipped') skipped.push({ coin: coin.id, path: pathOfImage(item) });
      }
    }
    if (moved) {
      await mutateIndex(uid, (latest) => {
        // Only where the coin still shows the original picture.
        const fix = (it) => {
          const copy = it && copies.get(pathOfImage(it));
          return copy ? { ...it, ...copy } : it;
        };
        const coins = latest.coins.map((c) => ({ ...fix(c), attachments: (c.attachments || []).map(fix) }));
        return { coins };
      });
    }
    if (moved || skipped.length) report.push({ uid, moved, skipped });
  }
  return json(res, 200, { report, done: !page.hasMore, cursor: page.hasMore ? page.cursor : null });
};
