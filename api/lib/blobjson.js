const crypto = require('crypto');
const { listBlobs, readBlobText, putBlob, deleteBlobs } = require('./blob');

/**
 * Read-your-writes JSON documents on Vercel Blob.
 *
 * Public blob URLs sit behind a CDN that keeps serving the old body for a
 * while after an overwrite, and the CDN cache cannot be bypassed for public
 * blobs (a ?t= query does not help). Reading an overwritten index right after
 * a write therefore returned stale data: a coin created a moment earlier was
 * "not found" when its image uploaded, so Save failed after Paste.
 *
 * Fix: every write goes to a brand new, never-overwritten pathname inside a
 * versions folder. Readers list that folder (the list API is not CDN cached)
 * and fetch the newest version, whose URL has never been cached anywhere.
 * Old versions are pruned after each write.
 */

const KEEP_VERSIONS = 5;

function versionsPrefix(basePath) {
  return basePath.replace(/\.json$/, '') + '.versions/';
}

function versionStamp(pathname) {
  const m = /\/(\d{15})-[0-9a-f]+\.json$/.exec(pathname || '');
  return m ? Number(m[1]) : 0;
}

/**
 * Strictly after the newest existing version, even if two writes land in the
 * same millisecond or this server's clock trails another instance's.
 */
function versionPathname(basePath, newestPathname) {
  const ts = Math.max(Date.now(), versionStamp(newestPathname) + 1);
  const rand = crypto.randomBytes(6).toString('hex');
  // Fixed-width timestamp keeps lexicographic order == write order.
  return `${versionsPrefix(basePath)}${String(ts).padStart(15, '0')}-${rand}.json`;
}

async function listVersions(basePath) {
  const blobs = await listBlobs(versionsPrefix(basePath));
  return blobs
    .filter((b) => b.pathname.endsWith('.json'))
    .sort((a, b) => (a.pathname < b.pathname ? 1 : a.pathname > b.pathname ? -1 : 0));
}

async function fetchJson(pathname) {
  const text = await readBlobText(pathname);
  if (text == null) {
    const err = new Error('Blob missing: ' + pathname);
    err.status = 404;
    throw err;
  }
  return JSON.parse(text);
}

/**
 * status: 'ok' | 'missing' | 'error'
 * Falls back to the legacy fixed-path blob (written before versioning) until
 * the first versioned write exists.
 */
async function readJsonDocument(basePath) {
  try {
    const versions = await listVersions(basePath);
    if (versions.length) {
      // Newest first. If a concurrent prune removed it, try the next one.
      let lastErr = null;
      for (const v of versions.slice(0, KEEP_VERSIONS)) {
        try {
          return { status: 'ok', data: await fetchJson(v.pathname) };
        } catch (e) {
          lastErr = e;
        }
      }
      console.error('readJsonDocument versions unreadable', basePath, lastErr);
      return { status: 'error', data: null };
    }

    // Legacy single file (pre-versioning). Exact-path prefix so a large
    // number of images can never push it past the list page limit.
    const text = await readBlobText(basePath, { fresh: true });
    if (text == null) return { status: 'missing', data: null };
    return { status: 'ok', data: JSON.parse(text) };
  } catch (e) {
    console.error('readJsonDocument', basePath, e);
    return { status: 'error', data: null };
  }
}

async function writeJsonDocument(basePath, data) {
  const existing = await listVersions(basePath);
  const pathname = versionPathname(basePath, existing[0] && existing[0].pathname);
  const result = await putBlob(pathname, JSON.stringify(data), {
    contentType: 'application/json',
  });
  // Best-effort prune (the new version plus KEEP_VERSIONS - 1 older ones stay).
  // Never fail the write because cleanup failed.
  try {
    const stale = existing.slice(KEEP_VERSIONS - 1).map((v) => v.pathname);
    if (stale.length) await deleteBlobs(stale);
  } catch (e) {
    console.warn('writeJsonDocument prune', basePath, e);
  }
  return result;
}

/** Remove every version (and the legacy fixed-path copy) of a document. */
async function deleteJsonDocument(basePath) {
  const versions = await listVersions(basePath);
  await deleteBlobs([...versions.map((v) => v.pathname), basePath]);
}

module.exports = {
  readJsonDocument,
  deleteJsonDocument,
  writeJsonDocument,
  versionsPrefix,
};
