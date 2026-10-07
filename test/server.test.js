/**
 * Server tests against an in-memory Vercel Blob. Run: npm test
 * Focus: one account can never see, change or delete another account's data.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('path');
const { Writable } = require('stream');

// ---------- in-memory @vercel/blob ----------
const { installMockBlob } = require('./mockblob');
const { sdk: fakeBlob, stores, hooks } = installMockBlob();

// ---------- capture sign-in emails ----------
const sentCodes = [];
// Set to true to make the email service refuse to send.
let failMail = false;
global.fetch = async (url, init) => {
  if (String(url).includes('api.resend.com')) {
    if (failMail) return new Response(JSON.stringify({ message: 'mail is down' }), { status: 500 });
    const body = JSON.parse(init.body);
    sentCodes.push({ to: body.to[0], code: body.text.match(/\d{6}/)[0] });
    return new Response(JSON.stringify({ id: 'x' }), { status: 200 });
  }
  throw new Error('unexpected fetch ' + url);
};

process.env.AUTH_SECRET = 'test-secret-that-is-long-enough';
process.env.BLOB_READ_WRITE_TOKEN = 'public-token';
process.env.COINPURSE_PRIVATE_READ_WRITE_TOKEN = 'private-token';
process.env.RESEND_API_KEY = 're_test';
process.env.ADMIN_EMAILS = 'boss@example.com';

const api = (p) => require(path.join(__dirname, '..', 'api', p));

// ---------- request helper ----------
// `bodyChunks` sends a JSON body as these exact pieces (to split a character).
async function call(route, { method = 'GET', token, body, bodyChunks, query = {}, headers = {} } = {}) {
  const handler = api(route);
  const raw = bodyChunks || (body == null ? [] : [Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body))]);
  const req = {
    method,
    query,
    headers: {
      ...(token ? { authorization: 'Bearer ' + token } : {}),
      ...(bodyChunks || (body != null && !Buffer.isBuffer(body)) ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    async *[Symbol.asyncIterator]() { for (const c of raw) yield c; },
  };
  const chunks = [];
  const res = new Writable({ write(c, _e, cb) { chunks.push(Buffer.from(c)); cb(); } });
  res.statusCode = 200;
  res.headers = {};
  res.setHeader = (k, v) => { res.headers[k.toLowerCase()] = v; };
  const done = new Promise((r) => res.on('finish', r));
  await handler(req, res);
  await done;
  const buf = Buffer.concat(chunks);
  let data = null;
  try { data = JSON.parse(buf.toString()); } catch {}
  return { status: res.statusCode, data, buf, headers: res.headers };
}

async function signIn(email) {
  const r = await call('auth/request-link.js', { method: 'POST', body: { email } });
  assert.equal(r.status, 200, JSON.stringify(r.data));
  const code = sentCodes.filter((s) => s.to === email).pop().code;
  const v = await call('auth/verify-code.js', { method: 'POST', body: { email, code } });
  assert.equal(v.status, 200, JSON.stringify(v.data));
  assert.ok(v.data.token);
  return v.data.token;
}

// Tiny but complete 1x1 pictures (the server checks both ends of the file).
const JPEG = Buffer.from('/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDABALDA4MChAODQ4SERATGCgaGBYWGDEjJR0oOjM9PDkzODdASFxOQERXRTc4UG1RV19iZ2hnPk1xeXBkeFxlZ2P/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAAAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AP//Z', 'base64');
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR42mM4UaEBAAN0AWn1BwN7AAAAAElFTkSuQmCC', 'base64');
const WEBP = Buffer.from('UklGRh4AAABXRUJQVlA4TBEAAAAvAAAAAAdQvCIXpf+BiOh/AAA=', 'base64');
const reset = () => { for (const s of Object.values(stores)) s.files.clear(); sentCodes.length = 0; };
const modes = ['public', 'private'];

for (const mode of modes) {
  test(`[${mode}] accounts are isolated from each other`, async () => {
    reset();
    process.env.COINPURSE_STORE = mode;
    // An old single-user purse exists; new accounts must NOT inherit it.
    await fakeBlob.put('coinpurse/index.json', JSON.stringify({ coins: [{ id: 'legacy-coin-1', title: 'Legacy' }] }), { access: mode, token: mode + '-token' });

    const alice = await signIn('alice@example.com');
    const bob = await signIn('bob@example.com');

    const created = await call('coins.js', { method: 'POST', token: alice, body: { title: 'Alice pass', notes: 'n', accent: 2 } });
    assert.equal(created.status, 201);
    const coinId = created.data.coin.id;
    const up = await call('coins/[id]/image.js', { method: 'POST', token: alice, query: { id: coinId }, body: JPEG, headers: { 'content-type': 'image/jpeg' } });
    assert.equal(up.status, 200, JSON.stringify(up.data));
    const att = await call('coins/[id]/attachments.js', { method: 'POST', token: alice, query: { id: coinId }, body: JPEG, headers: { 'content-type': 'image/jpeg' } });
    assert.equal(att.status, 200);

    const aliceCoins = (await call('coins.js', { token: alice })).data.coins;
    assert.equal(aliceCoins.length, 1);
    const aliceImagePath = aliceCoins[0].imagePath;
    assert.ok(aliceImagePath.startsWith('coinpurse/users/'));

    // Bob sees an empty purse, not Alice's coins and not the legacy purse.
    const bobCoins = await call('coins.js', { token: bob });
    assert.equal(bobCoins.status, 200);
    assert.deepEqual(bobCoins.data.coins, []);

    // Bob cannot edit, add pictures to, or delete Alice's coin.
    assert.equal((await call('coins/[id].js', { method: 'PUT', token: bob, query: { id: coinId }, body: { title: 'pwned' } })).status, 404);
    assert.equal((await call('coins/[id]/image.js', { method: 'POST', token: bob, query: { id: coinId }, body: JPEG, headers: { 'content-type': 'image/jpeg' } })).status, 404);
    assert.equal((await call('coins/[id]/attachments.js', { method: 'POST', token: bob, query: { id: coinId }, body: JPEG, headers: { 'content-type': 'image/jpeg' } })).status, 404);
    await call('coins/[id].js', { method: 'DELETE', token: bob, query: { id: coinId } });

    // Bob plants Alice's picture path on his own coin, then deletes it.
    const evil = await call('coins.js', { method: 'POST', token: bob, body: { title: 'evil', imagePath: aliceImagePath, imageUrl: 'x', attachments: [{ id: 'a', imagePath: aliceImagePath }] } });
    assert.equal(evil.status, 201);
    assert.equal(evil.data.coin.imageUrl, null);
    assert.deepEqual(evil.data.coin.attachments, []);
    await call('coins/[id].js', { method: 'PUT', token: bob, query: { id: evil.data.coin.id }, body: { title: 'evil', imagePath: aliceImagePath } });
    await call('coins/[id].js', { method: 'DELETE', token: bob, query: { id: evil.data.coin.id } });

    // Alice's coin and pictures are untouched.
    const after = (await call('coins.js', { token: alice })).data.coins;
    assert.equal(after.length, 1);
    assert.equal(after[0].title, 'Alice pass');
    assert.equal(after[0].attachments.length, 1);
    assert.ok(stores[mode + '-token'].files.has(aliceImagePath));

    // Path tricks in coin ids are refused.
    const weird = await call('coins.js', { method: 'POST', token: bob, body: { id: '../../x', title: 't' } });
    assert.match(weird.data.coin.id, /^[0-9a-f-]{36}$/);
    assert.equal((await call('coins/[id].js', { method: 'PUT', token: bob, query: { id: '../x' }, body: { title: 't' } })).status, 400);

    // Only real picture types are accepted.
    const html = await call('coins/[id]/image.js', { method: 'POST', token: alice, query: { id: coinId }, body: Buffer.from('<script>'), headers: { 'content-type': 'text/html' } });
    assert.equal(html.status, 415);

    // No token, or a forged one, gets nothing.
    assert.equal((await call('coins.js')).status, 401);
    assert.equal((await call('coins.js', { token: alice.slice(0, -2) + 'xx' })).status, 401);
  });

  test(`[${mode}] picture links`, async () => {
    reset();
    process.env.COINPURSE_STORE = mode;
    const alice = await signIn('alice@example.com');
    const c = await call('coins.js', { method: 'POST', token: alice, body: { title: 'A' } });
    const up = await call('coins/[id]/image.js', { method: 'POST', token: alice, query: { id: c.data.coin.id }, body: JPEG, headers: { 'content-type': 'image/jpeg' } });
    const url = up.data.coin.imageUrl;
    if (mode === 'public') {
      assert.match(url, /^https:\/\/store\.public\.blob/);
      return;
    }
    assert.match(url, /^\/api\/img\?p=/);
    const q = Object.fromEntries(new URL(url, 'https://x').searchParams);
    const img = await call('img.js', { query: q });
    assert.equal(img.status, 200);
    assert.equal(img.headers['content-type'], 'image/jpeg');
    assert.equal(img.headers['x-content-type-options'], 'nosniff');
    assert.deepEqual(img.buf, JPEG);
    // Tampered path, signature or expiry fail.
    assert.equal((await call('img.js', { query: { ...q, p: q.p.replace(/\.jpg$/, '.png') } })).status, 404);
    // (Change the first letter to one it is not, or roughly 1 run in 64 "tampers" nothing.)
    assert.equal((await call('img.js', { query: { ...q, s: (q.s[0] === 'x' ? 'y' : 'x') + q.s.slice(1) } })).status, 404);
    assert.equal((await call('img.js', { query: { ...q, e: String(Number(q.e) + 1) } })).status, 404);
    assert.equal((await call('img.js', { query: { ...q, e: '1' } })).status, 404);
  });

  test(`[${mode}] account deletion removes everything`, async () => {
    reset();
    process.env.COINPURSE_STORE = mode;
    const alice = await signIn('alice@example.com');
    const bob = await signIn('bob@example.com');
    const c = await call('coins.js', { method: 'POST', token: alice, body: { title: 'A' } });
    await call('coins/[id]/image.js', { method: 'POST', token: alice, query: { id: c.data.coin.id }, body: JPEG, headers: { 'content-type': 'image/jpeg' } });
    await call('coins.js', { method: 'POST', token: bob, body: { title: 'B' } });

    const aliceId = JSON.parse(Buffer.from(alice.split('.')[0], 'base64url')).uid;
    const files = stores[mode + '-token'].files;
    assert.ok([...files.keys()].some((p) => p.startsWith(`coinpurse/users/${aliceId}/`)));

    const del = await call('account.js', { method: 'DELETE', token: alice });
    assert.equal(del.status, 200);
    assert.ok(![...files.keys()].some((p) => p.startsWith(`coinpurse/users/${aliceId}/`)), 'alice files remain');
    assert.equal((await call('coins.js', { token: alice })).status, 401);

    // Bob is untouched.
    assert.equal((await call('coins.js', { token: bob })).data.coins.length, 1);

    // Signing up again with the same email gives a brand new, empty purse.
    const again = await signIn('alice@example.com');
    const fresh = await call('coins.js', { token: again });
    assert.deepEqual(fresh.data.coins, []);
  });
}

test('sign-in limits and reviewer account', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const email = 'carol@example.com';
  for (let i = 0; i < 3; i++) {
    assert.equal((await call('auth/request-link.js', { method: 'POST', body: { email } })).status, 200);
  }
  assert.equal((await call('auth/request-link.js', { method: 'POST', body: { email } })).status, 429);
  // No account exists until a code is verified.
  assert.ok(![...stores['private-token'].files.keys()].some((p) => p.includes('/account.')));

  for (let i = 0; i < 8; i++) {
    assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: '000000' === sentCodes.at(-1).code ? '111111' : '000000' } })).status, 401);
  }
  // Even the right code is refused after too many wrong ones.
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: sentCodes.at(-1).code } })).status, 429);

  process.env.REVIEW_EMAIL = 'appreview@example.com';
  process.env.REVIEW_CODE = '246810';
  const sentBefore = sentCodes.length;
  assert.equal((await call('auth/request-link.js', { method: 'POST', body: { email: 'AppReview@example.com' } })).status, 200);
  assert.equal(sentCodes.length, sentBefore, 'review account must not send email');
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: 'appreview@example.com', code: '135790' } })).status, 401);
  const ok = await call('auth/verify-code.js', { method: 'POST', body: { email: 'appreview@example.com', code: '246810' } });
  assert.equal(ok.status, 200);
  assert.equal((await call('coins.js', { token: ok.data.token })).status, 200);
  // The fixed code works for that one address only.
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: 'dave@example.com', code: '246810' } })).status, 401);
  delete process.env.REVIEW_EMAIL;
  delete process.env.REVIEW_CODE;
});

test('sign out of all devices', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t1 = await signIn('erin@example.com');
  const t2 = await signIn('erin@example.com');
  const r = await call('account/signout-all.js', { method: 'POST', token: t1 });
  assert.equal(r.status, 200);
  assert.equal((await call('coins.js', { token: t1 })).status, 401);
  assert.equal((await call('coins.js', { token: t2 })).status, 401);
  assert.equal((await call('coins.js', { token: r.data.token })).status, 200);
});

test('existing accounts in users.json keep working', async () => {
  reset();
  process.env.COINPURSE_STORE = 'public';
  const { signPayload } = require('../api/lib/crypto');
  const legacy = { id: '11111111-2222-3333-4444-555555555555', email: 'scott@example.com', pinSalt: null, pinHash: null, createdAt: 1 };
  await fakeBlob.put('coinpurse/users.json', JSON.stringify({ users: [legacy] }), { access: 'public', token: 'public-token' });
  await fakeBlob.put(`coinpurse/users/${legacy.id}/index.json`, JSON.stringify({ coins: [{ id: 'old-coin-1', title: 'Old', sortOrder: 0 }] }), { access: 'public', token: 'public-token' });
  // A token issued before session versions existed (no sv field).
  const oldToken = signPayload({ typ: 'session', uid: legacy.id, email: legacy.email });
  const r = await call('coins.js', { token: oldToken });
  assert.equal(r.status, 200);
  assert.equal(r.data.coins[0].title, 'Old');
  // Signing in by email finds the same account.
  const t = await signIn('scott@example.com');
  assert.equal(JSON.parse(Buffer.from(t.split('.')[0], 'base64url')).uid, legacy.id);
  // Deleting the account also removes it from users.json.
  assert.equal((await call('account.js', { method: 'DELETE', token: t })).status, 200);
  const users = JSON.parse(stores['public-token'].files.get([...stores['public-token'].files.keys()].filter((p) => p.startsWith('coinpurse/users.versions/')).sort().pop()).body);
  assert.deepEqual(users.users, []);
  assert.equal((await call('coins.js', { token: oldToken })).status, 401);
});

test('server refuses to run without a real secret', async () => {
  reset();
  const saved = process.env.AUTH_SECRET;
  process.env.AUTH_SECRET = '';
  const r = await call('coins.js', { token: 'a.b' });
  assert.equal(r.status, 503);
  process.env.AUTH_SECRET = saved;
});

test('store move: adopt stray pictures, then copy to private', async () => {
  reset();
  process.env.COINPURSE_STORE = 'public';
  const pub = { access: 'public', token: 'public-token' };
  const uid = '99999999-2222-3333-4444-555555555555';
  await fakeBlob.put('coinpurse/images/legacy-1.jpg', JPEG, { ...pub, contentType: 'image/jpeg' });
  // A planted path to a non-picture file must never be adopted.
  await fakeBlob.put('coinpurse/users.json', '{"users":[{"email":"secret@example.com"}]}', { ...pub, contentType: 'application/json' });
  await fakeBlob.put('coinpurse/images/fake.jpg', '<html>', { ...pub, contentType: 'image/jpeg' });
  const sneaky = '88888888-2222-3333-4444-555555555555';
  await fakeBlob.put(`coinpurse/users/${sneaky}/index.json`, JSON.stringify({
    coins: [
      { id: 'coin-sneaky-1', title: 'x', sortOrder: 0, imagePath: 'coinpurse/users.json' },
      { id: 'coin-sneaky-2', title: 'y', sortOrder: 1, imagePath: 'coinpurse/images/fake.jpg' },
    ],
  }), pub);
  await fakeBlob.put('coinpurse/index.json', '{"coins":[]}', pub);
  await fakeBlob.put(`coinpurse/users/${uid}/index.json`, JSON.stringify({
    coins: [{ id: 'coin-legacy-1', title: 'Old', sortOrder: 0, imagePath: 'coinpurse/images/legacy-1.jpg', imageUrl: 'https://store.public.blob.vercel-storage.com/coinpurse/images/legacy-1.jpg' }],
  }), pub);
  const admin = await signIn('boss@example.com');
  const notAdmin = await signIn('someone@example.com');
  assert.equal((await call('admin/adopt-images.js', { method: 'POST' })).status, 401);
  assert.equal((await call('admin/adopt-images.js', { method: 'POST', token: notAdmin })).status, 403);
  assert.equal((await call('admin/migrate-store.js', { method: 'POST', token: notAdmin })).status, 403);
  const a = await call('admin/adopt-images.js', { method: 'POST', token: admin });
  assert.equal(a.status, 200, JSON.stringify(a.data));
  const byUid = Object.fromEntries(a.data.report.map((r) => [r.uid, r]));
  assert.deepEqual(byUid[uid], { uid, moved: 1, skipped: [] });
  assert.equal(byUid[sneaky].moved, 0);
  assert.equal(byUid[sneaky].skipped.length, 2);
  assert.ok(![...stores['public-token'].files.keys()].some((p) => p.startsWith(`coinpurse/users/${sneaky}/images/`)));

  let cursor = null;
  do {
    const r = await call('admin/migrate-store.js', { method: 'POST', token: admin, query: cursor ? { cursor } : {} });
    assert.equal(r.status, 200, JSON.stringify(r.data));
    assert.deepEqual(r.data.failed, []);
    cursor = r.data.cursor;
  } while (cursor);
  const priv = stores['private-token'].files;
  assert.ok(!priv.has('coinpurse/index.json'), 'legacy purse must not be copied');

  process.env.COINPURSE_STORE = 'private';
  const { signPayload } = require('../api/lib/crypto');
  await fakeBlob.put('coinpurse/users.json', JSON.stringify({ users: [{ id: uid, email: 'f@example.com' }] }), { access: 'private', token: 'private-token', allowOverwrite: true });
  const tok = signPayload({ typ: 'session', uid, email: 'f@example.com' });
  const coins = (await call('coins.js', { token: tok })).data.coins;
  assert.match(coins[0].imageUrl, /^\/api\/img\?p=coinpurse%2Fusers%2F/);
  const q = Object.fromEntries(new URL(coins[0].imageUrl, 'https://x').searchParams);
  assert.deepEqual((await call('img.js', { query: q })).buf, JPEG);
});

test('rate limits hold under parallel requests', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const email = 'race@example.com';
  const sends = await Promise.all(Array.from({ length: 10 }, () => call('auth/request-link.js', { method: 'POST', body: { email } })));
  assert.equal(sends.filter((r) => r.status === 200).length, 3);
  assert.equal(sentCodes.filter((c) => c.to === email).length, 3);
  const right = sentCodes.filter((c) => c.to === email).pop().code;
  const wrong = right === '000000' ? '111111' : '000000';
  const guesses = await Promise.all(Array.from({ length: 30 }, () => call('auth/verify-code.js', { method: 'POST', body: { email, code: wrong } })));
  assert.equal(guesses.filter((r) => r.status === 401).length, 8);
  assert.equal(guesses.filter((r) => r.status === 429).length, 22);
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: right } })).status, 429);
});

test('reviewer account recovers after a lockout window', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  process.env.REVIEW_EMAIL = 'appreview@example.com';
  process.env.REVIEW_CODE = '246810';
  const realNow = Date.now;
  try {
    for (let i = 0; i < 8; i++) {
      assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: 'appreview@example.com', code: '000000' } })).status, 401);
    }
    assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: 'appreview@example.com', code: '246810' } })).status, 429);
    const later = realNow() + 16 * 60 * 1000;
    Date.now = () => later;
    assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: 'appreview@example.com', code: '246810' } })).status, 200);
  } finally {
    Date.now = realNow;
    delete process.env.REVIEW_EMAIL;
    delete process.env.REVIEW_CODE;
  }
});

test('a used code cannot be reused, and a new code resets guesses', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const email = 'once@example.com';
  await signIn(email);
  const used = sentCodes.filter((c) => c.to === email).pop().code;
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: used } })).status, 401);
  await call('auth/request-link.js', { method: 'POST', body: { email } });
  const fresh = sentCodes.filter((c) => c.to === email).pop().code;
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: fresh } })).status, 200);
});

test('a stale email lookup does not lock the email out', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const { emailKey } = require('../api/lib/crypto');
  await fakeBlob.put(`coinpurse/emails/${emailKey('ghost@example.com')}.json`, JSON.stringify({ uid: 'deadbeef-0000-0000-0000-000000000000' }), { access: 'private', token: 'private-token' });
  const t = await signIn('ghost@example.com');
  assert.equal((await call('coins.js', { token: t })).status, 200);
});

test('sessions renew themselves while in use', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const fresh = await signIn('renew@example.com');
  // A token used within a week is not reissued.
  assert.equal((await call('coins.js', { token: fresh })).headers['x-coinpurse-token'], undefined);
  // A token issued two weeks ago gets a fresh one, which works.
  const realNow = Date.now;
  let renewed;
  try {
    Date.now = () => realNow() + 14 * 24 * 60 * 60 * 1000;
    const r = await call('coins.js', { token: fresh });
    assert.equal(r.status, 200);
    renewed = r.headers['x-coinpurse-token'];
    assert.ok(renewed, 'no renewed token');
    // A year after the original sign-in, the renewed token still works.
    Date.now = () => realNow() + 370 * 24 * 60 * 60 * 1000;
    assert.equal((await call('coins.js', { token: fresh })).status, 401);
    assert.equal((await call('coins.js', { token: renewed })).status, 200);
  } finally {
    Date.now = realNow;
  }
});

test('untitled coins are named Coin 1, Coin 2, ...', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('quick@example.com');
  const make = async (title) => (await call('coins.js', { method: 'POST', token: t, body: title == null ? {} : { title } })).data.coin.title;
  assert.equal(await make(''), 'Coin 1');
  assert.equal(await make('Dev conference pass'), 'Dev conference pass');
  assert.equal(await make(null), 'Coin 2');
  assert.equal(await make('   '), 'Coin 3');
  // Another account counts on its own.
  const other = await signIn('other@example.com');
  assert.equal((await call('coins.js', { method: 'POST', token: other, body: {} })).data.coin.title, 'Coin 1');
  // Clearing a title on edit keeps the old name.
  const coins = (await call('coins.js', { token: t })).data.coins;
  const pass = coins.find((c) => c.title === 'Dev conference pass');
  const r = await call('coins/[id].js', { method: 'PUT', token: t, query: { id: pass.id }, body: { title: '' } });
  assert.equal(r.status, 200);
  assert.equal(r.data.coin.title, 'Dev conference pass');
});

test('a coin can hold a map pin, move it, and lose it', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('parker@example.com');
  const made = await call('coins.js', { method: 'POST', token: t, body: { title: 'Car', pin: { lat: 38.8339, lng: -104.8214, acc: 8, at: 1791000000000 } } });
  assert.equal(made.status, 201);
  assert.deepEqual(made.data.coin.pin, { lat: 38.8339, lng: -104.8214, acc: 8, at: 1791000000000 });
  const id = made.data.coin.id;
  const put = (body) => call('coins/[id].js', { method: 'PUT', token: t, query: { id }, body });
  // Editing the title leaves the pin alone.
  assert.equal((await put({ title: 'My car' })).data.coin.pin.lat, 38.8339);
  // Moving the pin.
  assert.equal((await put({ pin: { lat: 38.9, lng: -104.7 } })).data.coin.pin.lng, -104.7);
  // Nonsense is refused and changes nothing.
  for (const bad of [{ lat: 91, lng: 0 }, { lat: 'x', lng: 1 }, { lat: 1 }, 'here', 5]) {
    assert.equal((await put({ pin: bad })).status, 400, JSON.stringify(bad));
  }
  assert.equal((await call('coins.js', { token: t })).data.coins[0].pin.lat, 38.9);
  // Removing it.
  assert.equal((await put({ pin: null })).data.coin.pin, null);
  // Coins without a pin say so plainly.
  assert.equal((await call('coins.js', { method: 'POST', token: t, body: {} })).data.coin.pin, null);
  // Another account cannot touch it.
  const other = await signIn('snoop@example.com');
  assert.equal((await call('coins/[id].js', { method: 'PUT', token: other, query: { id }, body: { pin: { lat: 1, lng: 1 } } })).status, 404);
});

test('changes that happen at the same moment are never lost', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('busy@example.com');
  // Eight coins created at once (two phones, a share and the app...).
  const ids = Array.from({ length: 8 }, (_, i) => `00000000-0000-4000-8000-00000000000${i}`);
  await Promise.all(ids.map((id, i) => call('coins.js', { method: 'POST', token: t, body: { id, title: 'Coin ' + (i + 10) } })));
  let coins = (await call('coins.js', { token: t })).data.coins;
  assert.equal(coins.length, 8, 'a coin created at the same moment was lost');

  // Five extra pictures sent to one coin at once: all five are kept, and the
  // limit still holds when more arrive together.
  const id = ids[0];
  const pic = { method: 'POST', token: t, query: { id }, body: JPEG, headers: { 'content-type': 'image/jpeg' } };
  await call('coins/[id]/image.js', pic);
  const results = await Promise.all(Array.from({ length: 7 }, () => call('coins/[id]/attachments.js', pic)));
  coins = (await call('coins.js', { token: t })).data.coins;
  const coin = coins.find((c) => c.id === id);
  assert.equal(coin.attachments.length, 5, 'pictures sent together were lost or went over the limit');
  assert.equal(results.filter((r) => r.status === 200).length, 5);
  assert.ok(coin.imageUrl, 'the main picture was lost');

  // Editing text while pictures arrive keeps both.
  await Promise.all([
    call('coins/[id].js', { method: 'PUT', token: t, query: { id: ids[1] }, body: { title: 'Renamed' } }),
    call('coins/[id]/image.js', { ...pic, query: { id: ids[1] } }),
    call('coins/[id]/attachments.js', { ...pic, query: { id: ids[1] } }),
  ]);
  const second = (await call('coins.js', { token: t })).data.coins.find((c) => c.id === ids[1]);
  assert.equal(second.title, 'Renamed');
  assert.ok(second.imageUrl);
  assert.equal(second.attachments.length, 1);

  // Deleting one coin while another is created loses neither change.
  await Promise.all([
    call('coins/[id].js', { method: 'DELETE', token: t, query: { id: ids[2] } }),
    call('coins.js', { method: 'POST', token: t, body: { id: '00000000-0000-4000-8000-000000000099', title: 'New' } }),
  ]);
  coins = (await call('coins.js', { token: t })).data.coins;
  assert.ok(!coins.some((c) => c.id === ids[2]), 'deleted coin came back');
  assert.ok(coins.some((c) => c.title === 'New'), 'new coin was lost');
});

test('a burst of untitled coins gets unique numbers and none are lost', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('burst@example.com');
  const made = await Promise.all(Array.from({ length: 30 }, () => call('coins.js', { method: 'POST', token: t, body: {} })));
  assert.ok(made.every((r) => r.status === 201), 'some creates failed');
  const coins = (await call('coins.js', { token: t })).data.coins;
  assert.equal(coins.length, 30);
  const names = new Set(coins.map((c) => c.title));
  assert.equal(names.size, 30, 'two coins got the same Coin number');
  // A retried create (same id) during the burst still makes just one coin.
  const id = '00000000-0000-4000-8000-0000000000aa';
  await Promise.all([1, 2, 3].map(() => call('coins.js', { method: 'POST', token: t, body: { id, title: 'Once' } })));
  const after = (await call('coins.js', { token: t })).data.coins;
  assert.equal(after.filter((c) => c.title === 'Once').length, 1);
});

test('odd and oversized input is handled safely', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('odd@example.com');
  const made = await call('coins.js', { method: 'POST', token: t, body: { title: 'x'.repeat(5000), notes: 'n'.repeat(9000) } });
  assert.equal(made.status, 201);
  assert.equal(made.data.coin.title.length, 200, 'long title not trimmed');
  assert.equal(made.data.coin.notes.length, 5000, 'long notes not trimmed');
  const id = made.data.coin.id;
  const up = (body, type) => call('coins/[id]/image.js', { method: 'POST', token: t, query: { id }, body, headers: { 'content-type': type } });
  // Not a picture, whatever the label says.
  assert.equal((await up(Buffer.from('<html><script>alert(1)</script></html>'), 'image/jpeg')).status, 415);
  assert.equal((await up(Buffer.from('GIF89a....'), 'image/gif')).status, 415);
  assert.equal((await up(Buffer.alloc(0), 'image/jpeg')).status, 400);
  // Too big.
  const huge = Buffer.concat([JPEG, Buffer.alloc(4 * 1024 * 1024 + 10)]);
  assert.equal((await up(huge, 'image/jpeg')).status, 413);
  // Real PNG and WebP pictures pass.
  assert.equal((await up(PNG, 'image/png')).status, 200);
  assert.equal((await up(WEBP, 'image/webp')).status, 200);
  // Ids that try to reach other folders are refused.
  for (const bad of ['../../etc', 'a/b', 'short', '', 'x'.repeat(200), 'abc def ghi']) {
    assert.equal((await call('coins/[id].js', { method: 'PUT', token: t, query: { id: bad }, body: { title: 'y' } })).status, 400, bad);
  }
  // Reorder with duplicates and unknown ids keeps every coin exactly once.
  const second = (await call('coins.js', { method: 'POST', token: t, body: { title: 'Second' } })).data.coin.id;
  const r = await call('coins/reorder.js', { method: 'POST', token: t, body: { ids: [id, id, 'nope-nope-nope', second] } });
  assert.equal(r.status, 200);
  assert.deepEqual(r.data.coins.map((c) => c.id), [id, second]);
  assert.equal((await call('coins/reorder.js', { method: 'POST', token: t, body: { ids: [] } })).status, 400);
  // Bad JSON is refused politely.
  const raw = await call('coins.js', { method: 'POST', token: t, body: Buffer.from('{not json'), headers: { 'content-type': 'application/json' } });
  assert.ok(raw.status >= 400 && raw.status < 500, 'bad JSON should be a client error, got ' + raw.status);
});

test('a purse stops at 500 coins', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('full@example.com');
  for (let i = 0; i < 500; i += 50) {
    await Promise.all(Array.from({ length: 50 }, (_, k) => call('coins.js', { method: 'POST', token: t, body: { title: 'C' + (i + k) } })));
  }
  assert.equal((await call('coins.js', { token: t })).data.coins.length, 500);
  const extra = await call('coins.js', { method: 'POST', token: t, body: { title: 'One too many' } });
  assert.equal(extra.status, 400);
});

// ---------- regression tests ----------

const indexVersions = (mode = 'private') =>
  [...stores[mode + '-token'].files.keys()].filter((p) => p.includes('/index.versions/'));

test('a save held up while others land is never reported saved and then lost', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('slow@example.com');
  assert.equal((await call('coins.js', { method: 'POST', token: t, body: { title: 'First' } })).status, 201);

  // Pause the next index write (a slow phone's) between reading its base
  // version and claiming the one after it.
  let release;
  const gate = new Promise((r) => { release = r; });
  let held = false;
  hooks.beforePut = async (pathname) => {
    if (!held && pathname.includes('/index.versions/')) {
      held = true;
      await gate;
    }
  };
  let slow;
  try {
    slow = call('coins.js', { method: 'POST', token: t, body: { id: 'slow-coin-0001', title: 'Slow' } });
    while (!held) await new Promise((r) => setImmediate(r));
    // Seven other saves land meanwhile (more than the versions kept).
    for (let i = 0; i < 7; i++) {
      assert.equal((await call('coins.js', { method: 'POST', token: t, body: { title: 'Fast ' + i } })).status, 201);
    }
  } finally {
    hooks.beforePut = null;
    release();
  }
  const r = await slow;
  const coins = (await call('coins.js', { token: t })).data.coins;
  const present = coins.some((c) => c.id === 'slow-coin-0001');
  assert.ok(present || r.status !== 201, 'the server said the coin was saved, but it is gone');
  // It should in fact have been saved, on top of the others.
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.ok(present);
  assert.equal(coins.length, 9);

  // Young versions are kept; once they are older than the safety window a
  // write prunes down to the newest five.
  assert.ok(indexVersions().length > 5, 'versions were pruned while a writer could still want them');
  const files = stores['private-token'].files;
  for (const p of indexVersions()) files.get(p).uploadedAt = new Date(Date.now() - 11 * 60 * 1000);
  assert.equal((await call('coins.js', { method: 'POST', token: t, body: { title: 'Later' } })).status, 201);
  assert.equal(indexVersions().length, 5);
  assert.equal((await call('coins.js', { token: t })).data.coins.length, 10);
});

test('JSON bodies: a character split across chunks, and the limit in bytes', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('bytes@example.com');
  const title = 'Ticket \u{1F39F}️ stub';
  const raw = Buffer.from(JSON.stringify({ title }));
  const cut = raw.indexOf(Buffer.from('\u{1F39F}')) + 2; // inside the 4-byte emoji
  const r = await call('coins.js', { method: 'POST', token: t, bodyChunks: [raw.subarray(0, cut), raw.subarray(cut)] });
  assert.equal(r.status, 201, JSON.stringify(r.data));
  assert.equal(r.data.coin.title, title);

  // 80,000 bytes, but only about 40,000 characters.
  const big = Buffer.from(JSON.stringify({ notes: 'é'.repeat(39994) }));
  assert.equal(big.length, 80000);
  assert.ok(big.toString().length < 64 * 1024);
  const tooBig = await call('coins.js', { method: 'POST', token: t, bodyChunks: [big.subarray(0, 40001), big.subarray(40001)] });
  assert.equal(tooBig.status, 413);
});

test('deleting ids the purse never had does not push out real tombstones', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('tomb@example.com');
  const id = 'gone-coin-0001';
  assert.equal((await call('coins.js', { method: 'POST', token: t, body: { id, title: 'Gone' } })).status, 201);
  assert.equal((await call('coins/[id].js', { method: 'DELETE', token: t, query: { id } })).status, 200);
  const before = indexVersions().length;
  for (let i = 0; i < 500; i++) {
    const r = await call('coins/[id].js', { method: 'DELETE', token: t, query: { id: require('crypto').randomUUID() } });
    assert.equal(r.status, 200);
  }
  // Deleting the same coin again is also a quiet no-op.
  assert.equal((await call('coins/[id].js', { method: 'DELETE', token: t, query: { id } })).status, 200);
  assert.equal(indexVersions().length, before, 'a delete of an unknown id wrote the purse');
  assert.equal((await call('coins.js', { method: 'POST', token: t, body: { id, title: 'Back?' } })).status, 409);
});

test('coin ids named like built-in properties behave like any other id', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('proto@example.com');
  const ids = ['toString', 'constructor', '__proto__', 'hasOwnProperty', 'isPrototypeOf', '__defineGetter__'];
  for (const id of ids) {
    const r = await call('coins.js', { method: 'POST', token: t, body: { id, title: 'T ' + id } });
    assert.equal(r.status, 201, id + ' ' + JSON.stringify(r.data));
    assert.equal(r.data.coin.id, id);
    const pic = { method: 'POST', token: t, query: { id }, body: JPEG, headers: { 'content-type': 'image/jpeg' } };
    assert.equal((await call('coins/[id]/image.js', pic)).status, 200, id);
    assert.equal((await call('coins/[id]/attachments.js', pic)).status, 200, id);
    assert.equal((await call('coins/[id].js', { method: 'PUT', token: t, query: { id }, body: { title: 'U ' + id } })).status, 200, id);
  }
  let coins = (await call('coins.js', { token: t })).data.coins;
  assert.deepEqual(coins.map((c) => c.id).sort(), [...ids].sort());
  // Deleting them leaves real tombstones that hold.
  for (const id of ['__proto__', 'toString']) {
    assert.equal((await call('coins/[id].js', { method: 'DELETE', token: t, query: { id } })).status, 200);
    assert.equal((await call('coins.js', { method: 'POST', token: t, body: { id, title: 'again' } })).status, 409, id);
    assert.equal((await call('coins/[id].js', { method: 'PUT', token: t, query: { id }, body: { title: 'x' } })).status, 410, id);
  }
  coins = (await call('coins.js', { token: t })).data.coins;
  assert.deepEqual(coins.map((c) => c.id).sort(), ['__defineGetter__', 'constructor', 'hasOwnProperty', 'isPrototypeOf']);
});

test('a sortOrder that is not a finite number is ignored', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('order@example.com');
  const json = { 'content-type': 'application/json' };
  const made = await call('coins.js', { method: 'POST', token: t, body: Buffer.from('{"title":"Far","sortOrder":1e309}'), headers: json });
  assert.equal(made.status, 201);
  assert.ok(Number.isFinite(made.data.coin.sortOrder));
  const id = made.data.coin.id;
  const was = made.data.coin.sortOrder;
  const put = await call('coins/[id].js', { method: 'PUT', token: t, query: { id }, body: Buffer.from('{"sortOrder":-1e309}'), headers: json });
  assert.equal(put.status, 200);
  assert.equal(put.data.coin.sortOrder, was);
  assert.equal((await call('coins.js', { token: t })).data.coins[0].sortOrder, was);
});

test('two pictures saved in the same millisecond both succeed', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('samems@example.com');
  const id = (await call('coins.js', { method: 'POST', token: t, body: { title: 'Fast' } })).data.coin.id;
  const pic = { method: 'POST', token: t, query: { id }, body: JPEG, headers: { 'content-type': 'image/jpeg' } };
  const attId = (await call('coins/[id]/attachments.js', pic)).data.attachment.id;
  const realNow = Date.now;
  const frozen = realNow();
  const files = stores['private-token'].files;
  try {
    Date.now = () => frozen;
    const a = await call('coins/[id]/image.js', pic);
    const b = await call('coins/[id]/image.js', pic);
    assert.equal(a.status, 200);
    assert.equal(b.status, 200);
    assert.notEqual(a.data.coin.imagePath, b.data.coin.imagePath);
    assert.ok(files.has(b.data.coin.imagePath));
    assert.ok(!files.has(a.data.coin.imagePath), 'the replaced picture was not removed');
    // Replacing an extra picture twice in one millisecond works too.
    const replace = { ...pic, method: 'PUT', query: { id, attId } };
    assert.equal((await call('coins/[id]/attachments.js', replace)).status, 200);
    assert.equal((await call('coins/[id]/attachments.js', replace)).status, 200);
  } finally {
    Date.now = realNow;
  }
});

test('pictures cut off part way are refused', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('cutoff@example.com');
  const id = (await call('coins.js', { method: 'POST', token: t, body: { title: 'Pics' } })).data.coin.id;
  const up = (body, type) => call('coins/[id]/image.js', { method: 'POST', token: t, query: { id }, body, headers: { 'content-type': type } });
  const zeros = (n) => Buffer.alloc(n);
  // JPEG: must end with FF D9; zero padding after it is fine.
  assert.equal((await up(JPEG.subarray(0, JPEG.length - 2), 'image/jpeg')).status, 415);
  assert.equal((await up(JPEG.subarray(0, 100), 'image/jpeg')).status, 415);
  assert.equal((await up(Buffer.concat([JPEG.subarray(0, 100), zeros(8)]), 'image/jpeg')).status, 415);
  assert.equal((await up(Buffer.concat([JPEG, zeros(16)]), 'image/jpeg')).status, 200);
  // PNG: must end with the IEND chunk.
  assert.equal((await up(PNG.subarray(0, PNG.length - 12), 'image/png')).status, 415);
  assert.equal((await up(PNG.subarray(0, PNG.length - 1), 'image/png')).status, 415);
  assert.equal((await up(PNG, 'image/png')).status, 200);
  // WebP: the RIFF size must match the file (off by one allowed for padding).
  assert.equal((await up(WEBP.subarray(0, WEBP.length - 4), 'image/webp')).status, 415);
  assert.equal((await up(Buffer.concat([WEBP, zeros(8)]), 'image/webp')).status, 415);
  assert.equal((await up(Buffer.concat([WEBP, zeros(1)]), 'image/webp')).status, 200);
  assert.equal((await up(WEBP, 'image/webp')).status, 200);
});

test('a pin time outside 2000 to tomorrow becomes now', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('pintime@example.com');
  const day = 24 * 60 * 60 * 1000;
  const pinAt = async (at) => {
    const before = Date.now();
    const r = await call('coins.js', { method: 'POST', token: t, body: { pin: { lat: 1, lng: 2, at } } });
    assert.equal(r.status, 201);
    return { at: r.data.coin.pin.at, before, after: Date.now() };
  };
  for (const bad of [1e308, Date.now() + 2 * day, Date.UTC(1999, 11, 31), 5]) {
    const p = await pinAt(bad);
    assert.ok(p.at >= p.before && p.at <= p.after, `${bad} was kept as ${p.at}`);
  }
  const fine = Date.now() - day;
  assert.equal((await pinAt(fine)).at, fine);
  assert.equal((await pinAt(Date.UTC(2000, 0, 1))).at, Date.UTC(2000, 0, 1));
});

test('session tokens must be exactly payload.signature', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('shape@example.com');
  const [data, sig] = t.split('.');
  assert.equal((await call('coins.js', { token: t })).status, 200);
  for (const bad of [t + '.extra', t + '.', `${data}.${sig}.${sig}`, '.' + sig, data + '.', data]) {
    assert.equal((await call('coins.js', { token: bad })).status, 401, bad);
  }
  const { verifySigned } = require('../api/lib/crypto');
  assert.ok(verifySigned(t));
  assert.equal(verifySigned(t + '.extra'), null);
});

test('default names ignore "Coin N" titles with more than 9 digits', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('bignum@example.com');
  const make = async (title) => (await call('coins.js', { method: 'POST', token: t, body: title == null ? {} : { title } })).data.coin.title;
  await make('Coin 9007199254740992');
  await make('Coin ' + '9'.repeat(400));
  await make('Coin 1000000000');
  assert.equal(await make(null), 'Coin 1');
  await make('Coin 41');
  assert.equal(await make(null), 'Coin 42');
  await make('Coin 999999998');
  assert.equal(await make(null), 'Coin 999999999');
});

test('long titles and notes are never cut in the middle of a character', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('emoji@example.com');
  const coin = '\u{1FA99}';
  const r = await call('coins.js', { method: 'POST', token: t, body: { title: 'a'.repeat(199) + coin + 'tail', notes: 'n'.repeat(4999) + coin } });
  assert.equal(r.status, 201);
  assert.equal(r.data.coin.title, 'a'.repeat(199));
  assert.equal(r.data.coin.notes, 'n'.repeat(4999));
  assert.ok(r.data.coin.title.isWellFormed() && r.data.coin.notes.isWellFormed());
  // An emoji that fits whole is kept.
  const whole = await call('coins/[id].js', { method: 'PUT', token: t, query: { id: r.data.coin.id }, body: { title: 'a'.repeat(198) + coin + 'tail' } });
  assert.equal(whole.data.coin.title, 'a'.repeat(198) + coin);
});

test('a missing picture is told apart from a missing coin', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const t = await signIn('pictures@example.com');
  const id = (await call('coins.js', { method: 'POST', token: t, body: { title: 'Has pics' } })).data.coin.id;
  const pic = { token: t, body: JPEG, headers: { 'content-type': 'image/jpeg' } };
  const attId = (await call('coins/[id]/attachments.js', { ...pic, method: 'POST', query: { id } })).data.attachment.id;
  const gone = { error: 'Picture not found', code: 'PICTURE_GONE' };

  // Coin there, picture not.
  const put = await call('coins/[id]/attachments.js', { ...pic, method: 'PUT', query: { id, attId: 'no-such-picture' } });
  assert.equal(put.status, 404);
  assert.deepEqual(put.data, gone);
  const del = await call('coins/[id]/attachments.js', { method: 'DELETE', token: t, query: { id, attId: 'no-such-picture' } });
  assert.equal(del.status, 404);
  assert.deepEqual(del.data, gone);
  assert.equal((await call('coins/[id]/attachments.js', { method: 'DELETE', token: t, query: { id, attId } })).status, 200);
  assert.deepEqual((await call('coins/[id]/attachments.js', { method: 'DELETE', token: t, query: { id, attId } })).data, gone);

  // Coin missing or deleted: unchanged answers, without the picture code.
  const missing = await call('coins/[id]/attachments.js', { method: 'DELETE', token: t, query: { id: 'never-there-01', attId } });
  assert.equal(missing.status, 404);
  assert.equal(missing.data.code, undefined);
  await call('coins/[id].js', { method: 'DELETE', token: t, query: { id } });
  const deleted = await call('coins/[id]/attachments.js', { ...pic, method: 'PUT', query: { id, attId } });
  assert.equal(deleted.status, 410);
  assert.equal(deleted.data.code, undefined);
});

test('a failed email keeps the code already sent and does not use up the limit', async () => {
  reset();
  process.env.COINPURSE_STORE = 'private';
  const email = 'mailfail@example.com';
  const request = () => call('auth/request-link.js', { method: 'POST', body: { email } });
  assert.equal((await request()).status, 200);
  const first = sentCodes.filter((c) => c.to === email).pop().code;
  failMail = true;
  try {
    assert.equal((await request()).status, 502);
  } finally {
    failMail = false;
  }
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email, code: first } })).status, 200);

  const other = 'mailfail2@example.com';
  const requestOther = () => call('auth/request-link.js', { method: 'POST', body: { email: other } });
  failMail = true;
  try {
    for (let i = 0; i < 3; i++) assert.equal((await requestOther()).status, 502);
  } finally {
    failMail = false;
  }
  // The three failures gave their slots back: three real sends still fit,
  // and the limit holds after them.
  for (let i = 0; i < 3; i++) assert.equal((await requestOther()).status, 200);
  assert.equal((await requestOther()).status, 429);
  const code = sentCodes.filter((c) => c.to === other).pop().code;
  assert.equal((await call('auth/verify-code.js', { method: 'POST', body: { email: other, code } })).status, 200);
});
