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
const { sdk: fakeBlob, stores } = installMockBlob();

// ---------- capture sign-in emails ----------
const sentCodes = [];
global.fetch = async (url, init) => {
  if (String(url).includes('api.resend.com')) {
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
process.env.ADMIN_SECRET = 'admin-secret-admin-secret-1234';

const api = (p) => require(path.join(__dirname, '..', 'api', p));

// ---------- request helper ----------
async function call(route, { method = 'GET', token, body, query = {}, headers = {} } = {}) {
  const handler = api(route);
  const raw = body == null ? [] : [Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body))];
  const req = {
    method,
    query,
    headers: {
      ...(token ? { authorization: 'Bearer ' + token } : {}),
      ...(body != null && !Buffer.isBuffer(body) ? { 'content-type': 'application/json' } : {}),
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

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);
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
    assert.equal((await call('img.js', { query: { ...q, s: 'x' + q.s.slice(1) } })).status, 404);
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
  const admin = process.env.ADMIN_SECRET;
  assert.equal((await call('admin/adopt-images.js', { method: 'POST', token: 'wrong' })).status, 401);
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
