/**
 * In-memory stand-in for @vercel/blob, used by the tests and the local dev
 * server. Two stores: 'public-token' and 'private-token'.
 *
 * Like the real list(), listed blobs carry uploadedAt (a Date). Tests can set
 * hooks.beforePut to an async function (pathname, opts) to hold a put back,
 * for example to pause one writer while others finish.
 */
function createMockBlob() {
  const hooks = { beforePut: null };
  const stores = {
    'public-token': { access: 'public', files: new Map() },
    'private-token': { access: 'private', files: new Map() },
  };
  function storeFor(opts) {
    const s = stores[opts && opts.token];
    if (!s) throw new Error('mock blob: unknown token');
    return s;
  }
  const sdk = {
    async put(pathname, body, opts) {
      if (hooks.beforePut) await hooks.beforePut(pathname, opts);
      const s = storeFor(opts);
      if (opts.access !== s.access) throw new Error('mock blob: access mismatch');
      if (s.files.has(pathname) && !opts.allowOverwrite) throw new Error('Vercel Blob: This blob already exists, use `allowOverwrite: true` if you want to overwrite it.');
      s.files.set(pathname, { body: Buffer.from(body), contentType: opts.contentType, uploadedAt: new Date() });
      return { url: `https://store.${s.access}.blob.vercel-storage.com/${pathname}`, pathname };
    },
    async list(opts) {
      const s = storeFor(opts);
      const prefix = opts.prefix || '';
      const names = [...s.files.keys()].filter((p) => p.startsWith(prefix)).sort();
      const start = opts.cursor ? Number(opts.cursor) : 0;
      const limit = opts.limit || 1000;
      if (opts.mode === 'folded') {
        const folders = [...new Set(names
          .map((p) => p.slice(prefix.length))
          .filter((r) => r.includes('/'))
          .map((r) => prefix + r.split('/')[0] + '/'))];
        const slice = folders.slice(start, start + limit);
        const more = start + limit < folders.length;
        return { blobs: [], folders: slice, hasMore: more, cursor: more ? String(start + limit) : undefined };
      }
      const slice = names.slice(start, start + limit);
      const more = start + limit < names.length;
      return {
        blobs: slice.map((p) => ({
          pathname: p,
          url: `https://store.${s.access}.blob.vercel-storage.com/${p}`,
          size: s.files.get(p).body.length,
          uploadedAt: s.files.get(p).uploadedAt,
        })),
        hasMore: more,
        cursor: more ? String(start + limit) : undefined,
      };
    },
    async get(pathname, opts) {
      const s = storeFor(opts);
      if (opts.access !== s.access) throw new Error('mock blob: access mismatch');
      const f = s.files.get(pathname);
      if (!f) return null;
      return {
        statusCode: 200,
        stream: new Response(f.body).body,
        headers: new Headers(),
        blob: { contentType: f.contentType, size: f.body.length, pathname },
      };
    },
    async del(list, opts) {
      const s = storeFor(opts);
      for (const p of [].concat(list)) s.files.delete(p);
    },
  };
  return { sdk, stores, hooks };
}

/** Make require('@vercel/blob') return the mock. Call before loading api/. */
function installMockBlob() {
  const mock = createMockBlob();
  require.cache[require.resolve('@vercel/blob')] = {
    id: '@vercel/blob', filename: '@vercel/blob', loaded: true, exports: mock.sdk,
  };
  return mock;
}

module.exports = { createMockBlob, installMockBlob };
