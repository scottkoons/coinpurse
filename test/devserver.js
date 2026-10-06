/**
 * Local CoinPurse server for Simulator testing. Runs the real api/ handlers
 * against an in-memory Blob store (nothing touches production), serves the
 * web app files, and prints sign-in codes here instead of emailing them.
 *
 *   node test/devserver.js            http://localhost:3000
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const { installMockBlob } = require('./mockblob');

installMockBlob();
process.env.AUTH_SECRET = process.env.AUTH_SECRET || 'local-dev-secret-not-for-production';
process.env.BLOB_READ_WRITE_TOKEN = 'public-token';
process.env.COINPURSE_PRIVATE_READ_WRITE_TOKEN = 'private-token';
process.env.COINPURSE_STORE = process.env.COINPURSE_STORE || 'private';
process.env.RESEND_API_KEY = 're_local';
process.env.REVIEW_EMAIL = process.env.REVIEW_EMAIL || 'review@example.com';
process.env.REVIEW_CODE = process.env.REVIEW_CODE || '123456';

const realFetch = global.fetch;
global.fetch = async (url, init) => {
  if (String(url).includes('api.resend.com')) {
    const body = JSON.parse(init.body);
    console.log(`\n  sign-in code for ${body.to[0]}: ${body.text.match(/\d{6}/)[0]}\n`);
    return new Response(JSON.stringify({ id: 'local' }), { status: 200 });
  }
  return realFetch(url, init);
};

const ROOT = path.join(__dirname, '..');
const API = path.join(ROOT, 'api');

/** Map a URL path to an api/ file the way Vercel does ([id] segments too). */
function route(pathname) {
  const parts = pathname.replace(/^\/api\/?/, '').split('/').filter(Boolean);
  const query = {};
  function walk(dir, i) {
    if (i === parts.length) return null;
    const last = i === parts.length - 1;
    const entries = fs.readdirSync(dir);
    const exact = parts[i];
    if (last && entries.includes(exact + '.js')) return path.join(dir, exact + '.js');
    if (entries.includes(exact) && fs.statSync(path.join(dir, exact)).isDirectory()) {
      const r = walk(path.join(dir, exact), i + 1);
      if (r) return r;
    }
    for (const e of entries) {
      const m = /^\[(\w+)\](\.js)?$/.exec(e);
      if (!m) continue;
      if (m[2] && last) { query[m[1]] = decodeURIComponent(exact); return path.join(dir, e); }
      if (!m[2]) {
        query[m[1]] = decodeURIComponent(exact);
        const r = walk(path.join(dir, e), i + 1);
        if (r) return r;
      }
    }
    return null;
  }
  return { file: walk(API, 0), query };
}

const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };

// Test-only switch: GET /__test/offline?on=1 makes every API call fail like a
// dropped connection, so the app's offline behavior can be tested.
let offline = false;

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/__test/offline') {
    offline = url.searchParams.get('on') === '1';
    console.log('offline mode', offline);
    res.end(offline ? 'offline' : 'online');
    return;
  }
  if (offline && url.pathname.startsWith('/api/')) {
    req.socket.destroy();
    return;
  }
  if (url.pathname.startsWith('/api/')) {
    const { file, query } = route(url.pathname);
    if (!file) { res.statusCode = 404; return res.end('{"error":"Not found"}'); }
    req.query = { ...Object.fromEntries(url.searchParams), ...query };
    try {
      await require(file)(req, res);
    } catch (e) {
      console.error(e);
      if (!res.headersSent) { res.statusCode = 500; res.end('{"error":"Server error"}'); }
    }
    console.log(req.method, url.pathname, res.statusCode);
    return;
  }
  let p = url.pathname === '/' ? '/index.html' : url.pathname;
  if (p === '/privacy' || p === '/support') p += '.html';
  const f = path.join(ROOT, path.normalize(p));
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.statusCode = 404; return res.end(); }
  res.setHeader('Content-Type', TYPES[path.extname(f)] || 'application/octet-stream');
  fs.createReadStream(f).pipe(res);
}).listen(Number(process.env.PORT) || 3000, () => {
  console.log(`CoinPurse local server on http://localhost:${Number(process.env.PORT) || 3000} (store: ${process.env.COINPURSE_STORE})`);
  console.log(`Reviewer sign-in: ${process.env.REVIEW_EMAIL} / ${process.env.REVIEW_CODE}`);
});
