const { Readable } = require('stream');
const sdk = require('@vercel/blob');

/**
 * One place that talks to Vercel Blob.
 *
 * Everything lives in one private store, reached with
 * COINPURSE_PRIVATE_READ_WRITE_TOKEN. Files can only be read with that token;
 * pictures reach the apps through short-lived signed links (see ./imageurl.js).
 *
 * The original public store (BLOB_READ_WRITE_TOKEN) was retired after the
 * move to private on 2026-10-05. The token is always passed explicitly: the
 * SDK would otherwise fall back to BLOB_READ_WRITE_TOKEN on its own, so
 * without the private token every call fails instead of reaching any other
 * store.
 */

function token() {
  const t = process.env.COINPURSE_PRIVATE_READ_WRITE_TOKEN;
  if (!t) {
    const err = new Error('COINPURSE_PRIVATE_READ_WRITE_TOKEN is not set; the private Blob store is not connected');
    err.code = 'STORE_NOT_CONFIGURED';
    throw err;
  }
  return t;
}

async function putBlob(pathname, body, { contentType, allowOverwrite = false } = {}) {
  return sdk.put(pathname, body, {
    access: 'private',
    addRandomSuffix: false,
    allowOverwrite,
    contentType,
    token: token(),
  });
}

async function listBlobs(prefix) {
  const blobs = [];
  let cursor;
  do {
    const page = await sdk.list({ prefix, limit: 1000, cursor, token: token() });
    blobs.push(...(page.blobs || []));
    cursor = page.hasMore ? page.cursor : undefined;
  } while (cursor);
  return blobs;
}

/** One page of a listing, for long jobs that must stop and resume. */
async function listPage(prefix, cursor, { limit = 200, folded = false } = {}) {
  return sdk.list({ prefix, limit, cursor, ...(folded ? { mode: 'folded' } : {}), token: token() });
}

/** Returns the get() result, or null when the blob does not exist. */
async function getBlob(pathname, { fresh = false } = {}) {
  const result = await sdk.get(pathname, { access: 'private', useCache: !fresh, token: token() });
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

async function deleteBlobs(pathnames) {
  const list = (Array.isArray(pathnames) ? pathnames : [pathnames]).filter(Boolean);
  // del() accepts many at once; keep batches modest.
  for (let i = 0; i < list.length; i += 500) {
    await sdk.del(list.slice(i, i + 500), { token: token() });
  }
}

async function deleteBlobsQuiet(pathnames) {
  try {
    await deleteBlobs(pathnames);
  } catch (e) {
    console.warn('deleteBlobsQuiet', e);
  }
}

module.exports = {
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
