const { readJsonDocument, writeJsonDocument, deleteJsonDocument } = require('./blobjson');
const { putBlob, readBlobText, listBlobs, deleteBlobs } = require('./blob');
const { randomId, emailKey } = require('./crypto');

/**
 * Accounts live one per file so two people signing up at the same moment can
 * never overwrite each other:
 *   coinpurse/users/<uid>/account.json   the account (versioned JSON)
 *   coinpurse/emails/<emailKey>.json     { uid } lookup, written once
 *   coinpurse/logins/<emailKey>.json     pending sign-in code
 *   coinpurse/logins/<emailKey>.slots/   rate-limit slots (see claimSlot)
 *
 * The original single coinpurse/users.json is still read as a fallback so
 * existing accounts keep working; each one moves to its own file on first use.
 */

const LEGACY_USERS_PATH = 'coinpurse/users.json';

function normalizeEmail(email) {
  return String(email || '').trim().toLowerCase();
}

function accountPath(uid) {
  return `coinpurse/users/${uid}/account.json`;
}

function emailPath(email) {
  return `coinpurse/emails/${emailKey(normalizeEmail(email))}.json`;
}

function loginBase(email) {
  return `coinpurse/logins/${emailKey(normalizeEmail(email))}`;
}

function loginPath(email) {
  return loginBase(email) + '.json';
}

function slotPrefix(email) {
  return loginBase(email) + '.slots/';
}

function isValidUid(uid) {
  return typeof uid === 'string' && /^[A-Za-z0-9-]{8,64}$/.test(uid);
}

// ---------- legacy users.json ----------

async function readLegacyUsers() {
  const { status, data } = await readJsonDocument(LEGACY_USERS_PATH);
  if (status === 'error') throw new Error('Could not read users');
  if (status === 'missing') return null;
  return Array.isArray(data && data.users) ? data.users : [];
}

async function removeFromLegacyUsers(uid) {
  const users = await readLegacyUsers();
  if (!users || !users.some((u) => u.id === uid)) return;
  await writeJsonDocument(LEGACY_USERS_PATH, {
    users: users.filter((u) => u.id !== uid),
    updatedAt: Date.now(),
  });
}

/** Copy one legacy account into its own files. */
async function adoptLegacyUser(user) {
  const clean = { ...user, email: normalizeEmail(user.email) };
  // Sign-in codes now live in their own file.
  delete clean.loginCodeSalt;
  delete clean.loginCodeHash;
  delete clean.loginCodeExp;
  delete clean.loginCodeAttempts;
  await writeJsonDocument(accountPath(clean.id), clean);
  await writeEmailIndex(clean.email, clean.id);
  return clean;
}

// ---------- email lookup ----------

async function readEmailIndex(email) {
  const text = await readBlobText(emailPath(email), { fresh: true });
  if (text == null) return null;
  const data = JSON.parse(text);
  return isValidUid(data && data.uid) ? data.uid : null;
}

async function writeEmailIndex(email, uid, { allowOverwrite = true } = {}) {
  await putBlob(emailPath(email), JSON.stringify({ uid }), {
    contentType: 'application/json',
    allowOverwrite,
  });
}

// ---------- accounts ----------

async function findUserById(uid) {
  if (!isValidUid(uid)) return null;
  const { status, data } = await readJsonDocument(accountPath(uid));
  if (status === 'ok') return data && !data.deletedAt ? data : null;
  if (status === 'error') throw new Error('Could not read account');
  const legacy = await readLegacyUsers();
  const hit = legacy && legacy.find((u) => u.id === uid);
  return hit ? adoptLegacyUser(hit) : null;
}

async function findUserByEmail(email) {
  const norm = normalizeEmail(email);
  if (!norm) return null;
  const uid = await readEmailIndex(norm);
  if (uid) {
    const user = await findUserById(uid);
    if (user && user.email === norm) return user;
  }
  const legacy = await readLegacyUsers();
  const hit = legacy && legacy.find((u) => normalizeEmail(u.email) === norm);
  return hit ? adoptLegacyUser(hit) : null;
}

async function saveUser(user) {
  user.updatedAt = Date.now();
  await writeJsonDocument(accountPath(user.id), user);
  return user;
}

/**
 * Create an account for an email that has just proven ownership.
 * If two requests race, the first email-index write wins and both return it.
 */
async function createUser(email) {
  const norm = normalizeEmail(email);
  const now = Date.now();
  const user = {
    id: randomId(),
    email: norm,
    sessionVersion: 0,
    createdAt: now,
    updatedAt: now,
  };
  await writeJsonDocument(accountPath(user.id), user);
  try {
    await writeEmailIndex(norm, user.id, { allowOverwrite: false });
    return user;
  } catch (e) {
    // Someone else claimed this email a moment ago; use theirs.
    const existing = await findUserByEmail(norm);
    if (existing) {
      await deleteJsonDocument(accountPath(user.id)).catch(() => {});
      return existing;
    }
    // The lookup points at an account that no longer exists (for example a
    // half-finished delete). Take it over rather than lock the email out.
    await writeEmailIndex(norm, user.id, { allowOverwrite: true });
    return user;
  }
}

async function findOrCreateUser(email) {
  return (await findUserByEmail(email)) || createUser(email);
}

/** Remove every record that identifies the account (not its coins). */
async function deleteUserRecords(user) {
  await removeFromLegacyUsers(user.id);
  // Sign-in state and rate-limit slots all share this prefix.
  const login = await listBlobs(loginBase(user.email));
  await deleteBlobs(login.map((b) => b.pathname));
  await deleteBlobs(emailPath(user.email));
  await deleteJsonDocument(accountPath(user.id));
}

// ---------- pending sign-in codes ----------

async function readLogin(email) {
  const { status, data } = await readJsonDocument(loginPath(email));
  if (status === 'error') throw new Error('Could not read sign-in state');
  return status === 'ok' && data ? data : {};
}

async function writeLogin(email, data) {
  await writeJsonDocument(loginPath(email), { ...data, updatedAt: Date.now() });
}

function isAlreadyExists(e) {
  return /already exists/i.test(String(e && e.message)) || (e && e.name === 'BlobPreconditionFailedError');
}

/**
 * Rate limits that cannot be raced. Each use claims one of `count` numbered
 * slot files with a create-only write, which the store refuses if the file
 * exists. Many parallel requests still get at most `count` slots between
 * them. Returns false when every slot is taken.
 */
async function claimSlot(email, name, count) {
  for (let i = 0; i < count; i++) {
    try {
      await putBlob(`${slotPrefix(email)}${name}-${i}`, '1', { contentType: 'text/plain', allowOverwrite: false });
      return true;
    } catch (e) {
      if (!isAlreadyExists(e)) throw e;
    }
  }
  return false;
}

/** Best effort: remove slots whose names do not start with one of `keep`. */
async function pruneSlots(email, keep) {
  try {
    const blobs = await listBlobs(slotPrefix(email));
    const stale = blobs
      .map((b) => b.pathname)
      .filter((p) => !keep.some((k) => p.startsWith(slotPrefix(email) + k)));
    if (stale.length) await deleteBlobs(stale);
  } catch (e) {
    console.warn('pruneSlots', e);
  }
}

module.exports = {
  normalizeEmail,
  isValidUid,
  findUserById,
  findUserByEmail,
  findOrCreateUser,
  saveUser,
  deleteUserRecords,
  readLogin,
  writeLogin,
  claimSlot,
  pruneSlots,
  accountPath,
  LEGACY_USERS_PATH,
};
