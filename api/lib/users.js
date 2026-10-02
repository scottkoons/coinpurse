const { readJsonDocument, writeJsonDocument } = require('./blobjson');

const USERS_PATH = 'coinpurse/users.json';

/** Read-your-writes user list. Throws on storage errors (never pretend empty). */
async function readUsersStrict() {
  const { status, data } = await readJsonDocument(USERS_PATH);
  if (status === 'error') throw new Error('Could not read users');
  if (status === 'missing') return { users: [] };
  return { users: Array.isArray(data && data.users) ? data.users : [] };
}

async function readUsers() {
  try {
    return await readUsersStrict();
  } catch (e) {
    console.error('readUsers', e);
    return { users: [] };
  }
}

async function writeUsers(users) {
  await writeJsonDocument(USERS_PATH, { users, updatedAt: Date.now() });
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
  // Strict read: a transient read failure must not rewrite the list as [user].
  const { users } = await readUsersStrict();
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
