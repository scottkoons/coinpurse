const { json } = require('../lib/auth');
const { requireAdmin } = require('../lib/admin');
const { listPage, readBlobBuffer, putBlob, getBlob } = require('../lib/blob');

/**
 * One-time move from the public Blob store to the private one.
 *
 *   POST /api/admin/migrate-store            copy one page; repeat with the
 *   POST /api/admin/migrate-store?cursor=..  returned cursor until done=true
 *
 * Runs only for a signed-in account listed in ADMIN_EMAILS. Safe to re-run: files already in the private store are
 * skipped. The old single-purse files (coinpurse/index.*) are not copied;
 * they belonged to no account and nobody should inherit them.
 */

function skip(pathname) {
  return (
    !pathname.startsWith('coinpurse/') ||
    pathname === 'coinpurse/index.json' ||
    pathname.startsWith('coinpurse/index.versions/')
  );
}

module.exports = async function handler(req, res) {
  if (!(await requireAdmin(req, res))) return;
  if (req.method !== 'POST') return json(res, 405, { error: 'Method not allowed' });
  if (!process.env.COINPURSE_PRIVATE_READ_WRITE_TOKEN) {
    return json(res, 400, { error: 'Private store is not connected' });
  }

  const cursor = req.query.cursor || undefined;
  const page = await listPage('coinpurse/', cursor, { limit: 100, mode: 'public' });
  let copied = 0;
  let skipped = 0;
  const failed = [];
  for (const b of page.blobs || []) {
    if (skip(b.pathname)) { skipped++; continue; }
    try {
      if (await getBlob(b.pathname, { mode: 'private', fresh: true })) { skipped++; continue; }
      const file = await readBlobBuffer(b.pathname, { mode: 'public', fresh: true });
      if (!file) { skipped++; continue; }
      await putBlob(b.pathname, file.buffer, {
        contentType: file.contentType || 'application/octet-stream',
        allowOverwrite: false,
        mode: 'private',
      });
      copied++;
    } catch (e) {
      console.error('migrate-store', b.pathname, e);
      failed.push(b.pathname);
    }
  }
  return json(res, 200, {
    copied,
    skipped,
    failed,
    done: !page.hasMore,
    cursor: page.hasMore ? page.cursor : null,
  });
};
