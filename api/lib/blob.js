const { Readable } = require('stream');
const sdk = require('@vercel/blob');

/**
 * One place that talks to Vercel Blob.
 *
 * Two stores can exist while we move data:
 *   - 'public'  : the original store (BLOB_READ_WRITE_TOKEN). Every file has a
 *                 permanent public URL.
 *   - 'private' : the new store (COINPURSE_PRIVATE_READ_WRITE_TOKEN). Files can
 *                 only be read with the server's token; pictures reach the apps
 *                 through short-lived signed links (see ./imageurl.js).
 * COINPURSE_STORE=private switches all reads and writes to the private store.
 */

function storeMode() {
  return process.env.COINPURSE_STORE === 'private' ? 'private' : 'public';
}

function tokenFor(mode) {
  return mode === 'private'
    ? process.env.COINPURSE_PRIVATE_READ_WRITE_TOKEN
    : process.env.BLOB_READ_WRITE_TOKEN;
}

function withToken(options, mode) {
  const token = tokenFor(mode);
  return token ? { ...options, token } : options;
}

async function putBlob(pathname, body, { contentType, allowOverwrite = false, mode = storeMode() } = {}) {
  return sdk.put(pathname, body, withToken({
    access: mode,
    addRandomSuffix: false,
    allowOverwrite,
    contentType,
  }, mode));
}

async function listBlobs(prefix, { mode = storeMode() } = {}) {
  const blobs = [];
  let cursor;
  do {
    const page = await sdk.list(withToken({ prefix, limit: 1000, cursor }, mode));
    blobs.push(...(page.blobs || []));
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return blobs;
}

/** One page of a listing, for long jobs that must stop and resume. */
async function listPage(prefix, cursor, { limit = 200, folded = false, mode = storeMode() } = {}) {
  return sdk.list(withToken({ prefix, limit, cursor, ...(folded ? { mode: 'folded' } : {}) }, mode));
}

/** Returns the get() result, or null when the blob does not exist. */
async function getBlob(pathname, { fresh = false, mode = storeMode() } = {}) {
  const result = await sdk.get(pathname, withToken({ access: mode, useCache: !fresh }, mode));
  if (!result || result.statusCode !== 200) return null;
  return result;
}

async function readBlobText(pathname, opts) {
  const result = await getBlob(pathname, opts);
  if (!result) return null;
  return new Response(result.stream).text();
}

async function readBlobBuffer(pathname, opts) {
  const result = await getBlob(pathname, opts);
  if (!result) return null;
  return {
    buffer: Buffer.from(await new Response(result.stream).arrayBuffer()),
    contentType: result.blob.contentType,
  };
}

function streamToResponse(result, res) {
  const stream = Readable.fromWeb(result.stream);
  stream.on('error', (e) => {
    console.error('streamToResponse', e);
    res.destroy(e);
  });
  stream.pipe(res);
}

async function deleteBlobs(pathnames, { mode = storeMode() } = {}) {
  const list = (Array.isArray(pathnames) ? pathnames : [pathnames]).filter(Boolean);
  // del() accepts many at once; keep batches modest.
  for (let i = 0; i < list.length; i += 500) {
    await sdk.del(list.slice(i, i + 500), withToken({}, mode));
  }
}

async function deleteBlobsQuiet(pathnames, opts) {
  try {
    await deleteBlobs(pathnames, opts);
  } catch (e) {
    console.warn('deleteBlobsQuiet', e);
  }
}

module.exports = {
  storeMode,
  putBlob,
  listBlobs,
  listPage,
  getBlob,
  readBlobText,
  readBlobBuffer,
  streamToResponse,
  deleteBlobs,
  deleteBlobsQuiet,
};
