/**
 * Local server for the iPhone app's UI tests (Coin Purse itself has no
 * server: every coin lives on the phone).
 *
 * - The seed scripts (scripts/ios-test/seed*.py) put sample coins here, and a
 *   debug build started with -uiTestReset copies them onto the phone as the
 *   test's starting purse.
 * - A debug build sends a copy of what it saved after every change, so a test
 *   can check it (/__test/state).
 * - It also serves the website files, for a local look at them.
 *
 *   node test/devserver.js            http://localhost:3000
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '..');
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.mp4': 'video/mp4', '.webmanifest': 'application/manifest+json' };

// The sample purse, front first, and its pictures (in memory only).
let coins = [];
const pictures = new Map();
// What the app last said it saved.
let appState = { number: 0, coins: [] };

async function body(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function json(res, value, status = 200) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify(value));
}

/** "Coin 3": one more than the highest such number, as the app names coins. */
function nextTitle() {
  const numbers = coins.map((c) => /^Coin (\d{1,9})$/.exec(c.title.trim())).filter(Boolean).map((m) => Number(m[1]));
  return `Coin ${Math.max(0, ...numbers) + 1}`;
}

function keepPicture(jpeg) {
  const key = crypto.randomUUID();
  pictures.set(key, jpeg);
  return `/img/${key}`;
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const parts = url.pathname.split('/').filter(Boolean);

  if (url.pathname === '/__test/state') {
    if (req.method === 'POST') {
      try {
        const sent = JSON.parse(await body(req));
        // A copy that arrives late never replaces a newer one.
        if (sent.number >= appState.number) appState = sent;
      } catch { res.statusCode = 400; }
      return json(res, {});
    }
    return json(res, { coins: appState.coins });
  }

  // The seed scripts sign in the way the old server needed; any answer will do.
  if (url.pathname === '/api/auth/verify-code') return json(res, { token: 'test', email: 'review@example.com' });

  if (url.pathname === '/api/coins' && req.method === 'GET') return json(res, { coins, email: 'review@example.com' });

  if (url.pathname === '/api/coins' && req.method === 'POST') {
    const { id, title, notes, accent, pin } = JSON.parse(await body(req));
    const now = Date.now();
    const coin = { id, title: title || nextTitle(), notes: notes || '', accent: accent || 0, attachments: [], createdAt: now, updatedAt: now };
    if (pin) coin.pin = pin;
    coins.unshift(coin);
    return json(res, { coin });
  }

  // POST /api/coins/<id>/image (the first picture) or /attachments (another).
  if (parts[0] === 'api' && parts[1] === 'coins' && parts.length === 4 && req.method === 'POST') {
    const coin = coins.find((c) => c.id === parts[2]);
    if (!coin) return json(res, { error: 'Not found' }, 404);
    const link = keepPicture(await body(req));
    if (parts[3] === 'image') {
      coin.imageUrl = link;
      coin.imagePath = link;
    } else {
      coin.attachments.push({ id: crypto.randomUUID(), imageUrl: link, imagePath: link });
    }
    return json(res, { coin });
  }

  if (parts[0] === 'img' && pictures.has(parts[1])) {
    res.setHeader('Content-Type', 'image/jpeg');
    return res.end(pictures.get(parts[1]));
  }

  // The website.
  let p = url.pathname === '/' ? '/index.html' : url.pathname;
  if (p === '/privacy' || p === '/support') p += '.html';
  const f = path.join(ROOT, path.normalize(p));
  if (!f.startsWith(ROOT) || !fs.existsSync(f) || fs.statSync(f).isDirectory()) { res.statusCode = 404; return res.end(); }
  res.setHeader('Content-Type', TYPES[path.extname(f)] || 'application/octet-stream');
  // Byte ranges, so a browser can jump around in the film as it does on Vercel.
  const size = fs.statSync(f).size;
  res.setHeader('Accept-Ranges', 'bytes');
  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  if (range) {
    const start = range[1] ? Number(range[1]) : size - Number(range[2]);
    const end = range[1] && range[2] ? Math.min(Number(range[2]), size - 1) : size - 1;
    res.statusCode = 206;
    res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
    res.setHeader('Content-Length', end - start + 1);
    return fs.createReadStream(f, { start, end }).pipe(res);
  }
  res.setHeader('Content-Length', size);
  fs.createReadStream(f).pipe(res);
}).listen(Number(process.env.PORT) || 3000, () => {
  console.log(`Coin Purse test server on http://localhost:${Number(process.env.PORT) || 3000}`);
});
