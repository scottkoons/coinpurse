const { list, put } = require('@vercel/blob');

const USERS_PATH = 'coinpurse/users.json';

async function readUsers() {
  try {
    const result = await list({ prefix: 'coinpurse/', limit: 1000 });
    const hit = (result.blobs || []).find((b) => b.pathname === USERS_PATH);
    if (!hit) return { users: [] };
    const r = await fetch(hit.url, { cache: 'no-store' });
    if (!r.ok) return { users: [] };
    const data = await r.json();
    return { users: Array.isArray(data.users) ? data.users : [] };
  } catch (e) {
    console.error('readUsers', e);
    return { users: [] };
  }
}

async function writeUsers(users) {
  await put(USERS_PATH, JSON.stringify({ users, updatedAt: Date.now() }), {
    access: 'public',
    addRandomSuffix: false,
    allowOverwrite: true,
    contentType: 'application/json',
  });
}

async function findUserByEmail(email) {
  const norm = String(email || '').trim().toLowerCase();
  const { users } = await readUsers();
  return users.find((u) => u.email === norm) || null;
}

async function findUserById(id) {
  const { users } = await readUsers();
  return users.find((u) => u.id === id) || null;
}

async function upsertUser(user) {
  const { users } = await readUsers();
  const i = users.findIndex((u) => u.id === user.id);
  if (i >= 0) users[i] = user;
  else users.push(user);
  await writeUsers(users);
  return user;
}

module.exports = {
  readUsers,
  writeUsers,
  findUserByEmail,
  findUserById,
  upsertUser,
  USERS_PATH,
};
