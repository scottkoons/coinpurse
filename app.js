(() => {
  'use strict';

  const DB_NAME = 'qr-locker';
  const DB_VERSION = 1;
  const STORE = 'passes';
  const MAX_WIDTH = 1200;
  const JPEG_QUALITY = 0.82;
  const MAX_ATTACHMENTS = 5; // extras beyond primary (total 6)

  /** @type {IDBDatabase|null} */
  let db = null;
  /** @type {Array<{id:string,title:string,notes:string,image:Blob|null,createdAt:number,updatedAt:number}>} */
  let passes = [];
  /** Stable cycle order for deck swipes (ids). */
  let passRing = [];
  /** @type {string|null} */
  let viewingId = null;
  /** Active image in viewer: 0 = primary, 1+ = attachments */
  let viewerImageIndex = 0;
  /** @type {string|null} */
  let editingId = null;
  /** Active image in editor preview: 0 = primary, 1+ = attachments */
  let editorImageIndex = 0;
  let editorAccent = 0;
  /** @type {Blob|null} */
  let draftImage = null;
  /** In-flight setDraftImage so Save waits for paste/compress to finish. */
  let draftImageTask = Promise.resolve();
  /** @type {string|null} */
  let draftPreviewUrl = null;
  /** @type {string|null} */
  let expandedId = null;
  let frontIndex = 0;
  const objectUrls = new Map();

  const $ = (sel, root = document) => root.querySelector(sel);


  // ---------- Cloud purse (Vercel Blob) ----------
  const SESSION_KEY = 'coinpurse_session_token';

  function getSessionToken() {
    return localStorage.getItem(SESSION_KEY) || '';
  }

  function setSessionToken(token) {
    localStorage.setItem(SESSION_KEY, token);
  }

  function clearSessionToken() {
    localStorage.removeItem(SESSION_KEY);
  }

  function getApiToken() {
    return getSessionToken();
  }


  async function api(path, opts = {}) {
    const headers = Object.assign({}, opts.headers || {});
    const tok = getApiToken();
    if (tok) headers.Authorization = 'Bearer ' + tok;
    if (opts.json) {
      headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(opts.json);
      delete opts.json;
    }
    const res = await fetch(path, { ...opts, headers });
    if (!res.ok) {
      let msg = 'Request failed';
      try {
        const j = await res.json();
        if (j.error) msg = j.error;
      } catch {}
      throw new Error(msg);
    }
    if (res.status === 204) return null;
    return res.json();
  }

  async function fetchCloudCoins() {
    const data = await api('/api/coins');
    return data.coins || [];
  }

  async function uploadCoinImage(id, blob) {
    if (!blob) return null;
    const res = await fetch('/api/coins/' + encodeURIComponent(id) + '/image', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + getApiToken(),
        'Content-Type': blob.type || 'image/jpeg',
      },
      body: blob,
    });
    if (!res.ok) {
      let msg = 'Image upload failed';
      try {
        const j = await res.json();
        if (j.error) msg = j.error;
      } catch {}
      throw new Error(msg);
    }
    return res.json();
  }


  async function uploadCoinAttachment(id, blob) {
    if (!blob) return null;
    const res = await fetch('/api/coins/' + encodeURIComponent(id) + '/attachments', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer ' + getApiToken(),
        'Content-Type': blob.type || 'image/jpeg',
      },
      body: blob,
    });
    if (!res.ok) {
      let msg = 'Attachment upload failed';
      try {
        const j = await res.json();
        if (j.error) msg = j.error;
      } catch {}
      throw new Error(msg);
    }
    return res.json();
  }

  /** Replace an existing attachment image in place (same attId). */
  async function replaceCoinAttachment(coinId, attId, blob) {
    if (!coinId || !attId || !blob) return null;
    const res = await fetch(
      '/api/coins/' +
        encodeURIComponent(coinId) +
        '/attachments?attId=' +
        encodeURIComponent(attId),
      {
        method: 'PUT',
        headers: {
          Authorization: 'Bearer ' + getApiToken(),
          'Content-Type': blob.type || 'image/jpeg',
        },
        body: blob,
      }
    );
    if (!res.ok) {
      let msg = 'Attachment update failed';
      try {
        const j = await res.json();
        if (j.error) msg = j.error;
      } catch {}
      throw new Error(msg);
    }
    return res.json();
  }

  async function deleteCoinAttachment(coinId, attId) {
    const res = await fetch(
      '/api/coins/' + encodeURIComponent(coinId) + '/attachments?attId=' + encodeURIComponent(attId),
      {
        method: 'DELETE',
        headers: { Authorization: 'Bearer ' + getApiToken() },
      }
    );
    if (!res.ok) {
      let msg = 'Could not remove image';
      try {
        const j = await res.json();
        if (j.error) msg = j.error;
      } catch {}
      throw new Error(msg);
    }
    return res.json();
  }

  /** Normalize attachments array on a pass. */
  function passAttachments(pass) {
    if (!pass) return [];
    if (!Array.isArray(pass.attachments)) pass.attachments = [];
    return pass.attachments;
  }

  /** Image list for viewer: primary first, then attachments. */
  function viewerImages(pass) {
    if (!pass) return [];
    const list = [];
    const primary = pass.imageUrl || (pass.image ? urlFor(pass) : null);
    if (primary || pass.image) {
      list.push({
        kind: 'primary',
        id: 'primary',
        url: pass.imageUrl || urlFor(pass),
      });
    }
    for (const att of passAttachments(pass)) {
      if (att && att.imageUrl) {
        list.push({ kind: 'attachment', id: att.id, url: att.imageUrl });
      }
    }
    return list;
  }

  async function saveCloudCoin(pass, imageBlob) {
    const payload = {
      id: pass.id,
      title: pass.title,
      notes: pass.notes || '',
      accent: pass.accent,
      imageUrl: pass.imageUrl || null,
      imagePath: pass.imagePath || null,
      attachments: passAttachments(pass),
      sortOrder: typeof pass.sortOrder === 'number' ? pass.sortOrder : undefined,
      createdAt: pass.createdAt,
      updatedAt: pass.updatedAt || Date.now(),
    };

    if (pass._isNew) {
      const created = await api('/api/coins', { method: 'POST', json: payload });
      Object.assign(pass, created.coin || {});
      delete pass._isNew;
    }

    if (imageBlob) {
      const up = await uploadCoinImage(pass.id, imageBlob);
      pass.imageUrl = up.url || up.coin?.imageUrl || pass.imageUrl;
      pass.imagePath = up.coin?.imagePath || pass.imagePath;
      // Refresh metadata with final image URL
      const updated = await api('/api/coins/' + encodeURIComponent(pass.id), {
        method: 'PUT',
        json: {
          title: pass.title,
          notes: pass.notes || '',
          accent: pass.accent,
          imageUrl: pass.imageUrl,
          imagePath: pass.imagePath,
          attachments: passAttachments(pass),
        },
      });
      if (updated?.coin) Object.assign(pass, updated.coin);
    } else if (!pass._isNew) {
      const updated = await api('/api/coins/' + encodeURIComponent(pass.id), {
        method: 'PUT',
        json: {
          title: pass.title,
          notes: pass.notes || '',
          accent: pass.accent,
          imageUrl: pass.imageUrl || null,
          imagePath: pass.imagePath || null,
          attachments: passAttachments(pass),
        },
      });
      if (updated?.coin) Object.assign(pass, updated.coin);
    }

    pass.image = null;
    return pass;
  }

  async function deleteCloudCoin(id) {
    await api('/api/coins/' + encodeURIComponent(id), { method: 'DELETE' });
  }


  // ---------- IndexedDB ----------
  function openDb() {
    return new Promise((resolve, reject) => {
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        const database = req.result;
        if (!database.objectStoreNames.contains(STORE)) {
          const store = database.createObjectStore(STORE, { keyPath: 'id' });
          store.createIndex('updatedAt', 'updatedAt', { unique: false });
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  }

  function txDone(tx) {
    return new Promise((resolve, reject) => {
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error || new Error('aborted'));
    });
  }

  async function getAllPasses() {
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, 'readonly');
      const req = tx.objectStore(STORE).getAll();
      req.onsuccess = () => {
        const list = req.result || [];
        resolve(sortPassesByOrder(list));
      };
      req.onerror = () => reject(req.error);
    });
  }

  async function putPass(pass) {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).put(pass);
    await txDone(tx);
  }

  async function deletePass(id) {
    const tx = db.transaction(STORE, 'readwrite');
    tx.objectStore(STORE).delete(id);
    await txDone(tx);
  }

  /** Mirror cloud purse into IDB so offline fallback cannot resurrect deleted coins. */
  async function replaceLocalPasses(list) {
    if (!db) return;
    const tx = db.transaction(STORE, 'readwrite');
    const store = tx.objectStore(STORE);
    store.clear();
    for (const p of list || []) {
      if (!p || !p.id) continue;
      const { image, ...rest } = p;
      store.put({ ...rest, image: null });
    }
    await txDone(tx);
  }

  function uid() {
    if (crypto.randomUUID) return crypto.randomUUID();
    return 'p-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
  }

  // ---------- Image compress ----------
  function loadImageFromBlob(blob) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(blob);
      const img = new Image();
      img.onload = () => {
        URL.revokeObjectURL(url);
        resolve(img);
      };
      img.onerror = () => {
        URL.revokeObjectURL(url);
        reject(new Error('Could not load image'));
      };
      img.src = url;
    });
  }

  async function compressImage(blob) {
    // iOS paste / clipboard often hands a File with an empty type.
    if (!blob) throw new Error('Not an image');
    const t = (blob.type || '').toLowerCase();
    if (t && !t.startsWith('image/') && t !== 'application/octet-stream') {
      throw new Error('Not an image');
    }
    // Skip tiny images / already small GIFs that might be animated — still rasterize for size
    const img = await loadImageFromBlob(blob);
    let { width, height } = img;
    if (width > MAX_WIDTH) {
      height = Math.round((height * MAX_WIDTH) / width);
      width = MAX_WIDTH;
    }
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, width, height);
    ctx.drawImage(img, 0, 0, width, height);

    const preferWebp = canvas.toDataURL('image/webp').startsWith('data:image/webp');
    const mime = preferWebp ? 'image/webp' : 'image/jpeg';
    const quality = preferWebp ? 0.8 : JPEG_QUALITY;

    return new Promise((resolve, reject) => {
      canvas.toBlob(
        (out) => {
          if (!out) reject(new Error('Compress failed'));
          else resolve(out);
        },
        mime,
        quality
      );
    });
  }

  async function setDraftImage(blob, { quiet } = {}) {
    const run = async () => {
      if (!blob) {
        clearDraftImage();
        return;
      }
      try {
        const compressed = await compressImage(blob);
        clearDraftImage();
        draftImage = compressed;
        draftPreviewUrl = URL.createObjectURL(compressed);
        editorImageIndex = 0;
        renderEditorThumbs();
        setEditorPreviewFromIndex(0, { resetSlide: true });
        if (!quiet) toast('Image ready');
      } catch (e) {
        console.error(e);
        toast('Couldn’t use that image');
        throw e;
      }
    };
    const task = run();
    // Save must await the latest paste/compress even if it fails
    draftImageTask = task.catch(() => {});
    await task;
  }

  function clearDraftImage() {
    draftImage = null;
    if (draftPreviewUrl) {
      URL.revokeObjectURL(draftPreviewUrl);
      draftPreviewUrl = null;
    }
    hideEditorSlidePeer();
    editorImageIndex = 0;
    const img = $('#image-preview');
    if (img) {
      img.removeAttribute('src');
      img.style.transition = '';
      img.style.transform = '';
    }
    $('#image-preview-wrap')?.classList.add('hidden');
    $('#btn-crop-image')?.classList.add('hidden');
    $('#btn-clear-image')?.classList.add('hidden');
    $('#image-edit-row')?.classList.add('hidden');
    renderEditorThumbs();
  }

  // ---------- Object URL cache for list ----------
  function urlFor(pass) {
    if (pass.imageUrl) return pass.imageUrl;
    if (!pass.image) return null;
    if (objectUrls.has(pass.id)) return objectUrls.get(pass.id);
    const u = URL.createObjectURL(pass.image);
    objectUrls.set(pass.id, u);
    return u;
  }

  function revokeAllUrls() {
    for (const u of objectUrls.values()) URL.revokeObjectURL(u);
    objectUrls.clear();
  }

  // ---------- UI helpers ----------
  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.remove('hidden');
    clearTimeout(toast._t);
    toast._t = setTimeout(() => el.classList.add('hidden'), 2200);
  }

  function show(el) {
    el.classList.remove('hidden');
    el.setAttribute('aria-hidden', 'false');
  }
  function hide(el) {
    el.classList.add('hidden');
    el.setAttribute('aria-hidden', 'true');
  }


  /** Ascending sortOrder; lower = closer to front of wallet. */
  function sortPassesByOrder(list) {
    const arr = (list || []).slice();
    const any = arr.some((c) => typeof c.sortOrder === 'number');
    if (!any) {
      arr.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
      arr.forEach((c, i) => { c.sortOrder = i; });
      return arr;
    }
    arr.sort((a, b) => {
      const ao = typeof a.sortOrder === 'number' ? a.sortOrder : Number.POSITIVE_INFINITY;
      const bo = typeof b.sortOrder === 'number' ? b.sortOrder : Number.POSITIVE_INFINITY;
      if (ao !== bo) return ao - bo;
      return (b.updatedAt || 0) - (a.updatedAt || 0);
    });
    return arr;
  }

  function nextFrontSortOrder() {
    let min = 0;
    let found = false;
    for (const p of passes) {
      if (typeof p.sortOrder === 'number') {
        if (!found || p.sortOrder < min) min = p.sortOrder;
        found = true;
      }
    }
    return found ? min - 1 : 0;
  }

  // ---------- Wallet deck (full under-card + scrollable stack) ----------
  const PEEK = 56;
  let deckDrag = null;
  // Continuous scroll through the stack (card units). frontIndex tracks focused card.
  let deckScroll = 0; // 0 = first card at front

  function renderStack() {
    const empty = $('#empty-state');
    const stack = $('#card-stack');
    const hint = $('#deck-hint');
    stack.innerHTML = '';

    if (!passes.length) {
      empty.classList.remove('hidden');
      if (hint) hint.hidden = true;
      stack.style.height = '';
      return;
    }
    empty.classList.add('hidden');
    if (hint) {
      hint.hidden = false;
      hint.textContent =
        passes.length < 2
          ? 'Tap card to open full screen'
          : 'Swipe to flip · tap to open · long-press to rearrange';
    }

    if (frontIndex < 0 || frontIndex >= passes.length) frontIndex = 0;
    deckScroll = frontIndex;

    passes.forEach((pass, i) => {
      const card = document.createElement('article');
      card.className = 'pass-card';
      card.dataset.id = pass.id;
      card.dataset.index = String(i);
      // Color is stored on the coin (pass.accent), not derived from stack index.
      card.style.setProperty('--coin-accent', accentColor(pass));
      card.setAttribute('role', 'listitem');
      card.tabIndex = 0;

      const thumbUrl = urlFor(pass);
      const peek = document.createElement('div');
      peek.className = 'pass-card-peek';

      if (thumbUrl) {
        const thumb = document.createElement('img');
        thumb.className = 'pass-card-thumb';
        thumb.src = thumbUrl;
        thumb.alt = '';
        thumb.draggable = false;
        peek.appendChild(thumb);
      } else {
        const ph = document.createElement('div');
        ph.className = 'pass-card-thumb placeholder';
        ph.textContent = '▢';
        peek.appendChild(ph);
      }

      const meta = document.createElement('div');
      meta.className = 'pass-card-meta';
      const title = document.createElement('h3');
      title.className = 'pass-card-title';
      title.textContent = pass.title || 'Untitled';
      const sub = document.createElement('p');
      sub.className = 'pass-card-sub';
      sub.textContent = pass.notes
        ? pass.notes.split('\n')[0]
        : formatDate(pass.updatedAt || pass.createdAt);
      meta.append(title, sub);
      peek.appendChild(meta);
      card.appendChild(peek);

      // Always build full body so under-card can show the whole pass
      const body = document.createElement('div');
      body.className = 'pass-card-body';
      if (thumbUrl) {
        const big = document.createElement('img');
        big.src = thumbUrl;
        big.alt = pass.title || 'Pass';
        big.draggable = false;
        body.appendChild(big);
      }
      const openHint = document.createElement('p');
      openHint.className = 'pass-card-open-hint';
      openHint.textContent = 'Tap to open full screen';
      body.appendChild(openHint);
      card.appendChild(body);

      // Click fallback (desktop). Primary open path is pointerup tap in bindDeckGestures.
      card.addEventListener('click', (e) => {
        // Avoid double-open right after pointerup handled it
        if (card.dataset.justOpened === '1') return;
        onCardTap(i);
      });
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          onCardTap(i);
        }
      });

      stack.appendChild(card);
    });

    layoutDeck(0);
    bindDeckGestures();
  }

  const ACCENT_COLORS = [
    '#6366f1', // indigo
    '#06b6d4', // cyan
    '#22c55e', // green
    '#eab308', // yellow
    '#f97316', // orange
    '#ec4899', // pink
  ];

  /** Fallback index from id (only used once, then stored on the coin). */
  function hueForId(id) {
    const s = String(id || '');
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    return (h >>> 0) % ACCENT_COLORS.length;
  }

  /** Least-used accent among current coins (unique when possible). */
  function pickUniqueAccent(exceptId) {
    const counts = ACCENT_COLORS.map(() => 0);
    for (const p of passes) {
      if (!p || p.id === exceptId) continue;
      if (Number.isInteger(p.accent) && p.accent >= 0 && p.accent < counts.length) {
        counts[p.accent] += 1;
      }
    }
    let best = 0;
    for (let i = 1; i < counts.length; i++) {
      if (counts[i] < counts[best]) best = i;
    }
    return best;
  }

  /** Accent lives on the coin record so it never follows stack position. */
  function ensureAccent(pass) {
    if (
      pass &&
      Number.isInteger(pass.accent) &&
      pass.accent >= 0 &&
      pass.accent < ACCENT_COLORS.length
    ) {
      return pass.accent;
    }
    const next = pickUniqueAccent(pass?.id);
    if (pass) pass.accent = next;
    return next;
  }

  function accentColor(pass) {
    return ACCENT_COLORS[ensureAccent(pass)];
  }

  /** If several coins share a color, reassign so each is distinct when possible. */
  async function rebalanceAccents() {
    const used = new Set();
    let changed = false;
    for (const p of passes) {
      let a = Number.isInteger(p.accent) ? p.accent : -1;
      if (a < 0 || a >= ACCENT_COLORS.length || used.has(a)) {
        a = pickUniqueAccent(p.id);
        // If still colliding (more coins than colors), allow reuse of least-used
        p.accent = a;
        changed = true;
        try {
          await api('/api/coins/' + encodeURIComponent(p.id), {
            method: 'PUT',
            json: { accent: p.accent, title: p.title, notes: p.notes || '', imageUrl: p.imageUrl || null, imagePath: p.imagePath || null, attachments: passAttachments(p) },
          });
        } catch (e) {
          console.warn('accent save failed', p.id, e);
        }
      }
      used.add(p.accent);
    }
    return changed;
  }

  function formatDate(ts) {
    try {
      return new Date(ts).toLocaleDateString(undefined, {
        month: 'short',
        day: 'numeric',
        year: 'numeric',
      });
    } catch {
      return '';
    }
  }

  function syncPassRing() {
    const ids = new Set(passes.map((p) => p.id));
    // Drop removed
    passRing = passRing.filter((id) => ids.has(id));
    // Append any new passes in current passes order
    for (const p of passes) {
      if (!passRing.includes(p.id)) passRing.push(p.id);
    }
  }

  function passById(id) {
    return passes.find((p) => p.id === id) || null;
  }

  /** Display-array index of the ring neighbor of the current front (±1). */
  function ringNeighborIndex(direction) {
    syncPassRing();
    const n = passRing.length;
    if (n < 2) return -1;
    const frontId = passes[frontIndex]?.id;
    if (!frontId) return -1;
    const ringIdx = passRing.indexOf(frontId);
    if (ringIdx < 0) return -1;
    const neighborId = passRing[(ringIdx + direction + n) % n];
    return passes.findIndex((p) => p.id === neighborId);
  }

  function layoutDeck(pullPx, { animate } = { animate: true }) {
    const stack = $('#card-stack');
    const cards = [...stack.querySelectorAll('.pass-card')];
    if (!cards.length) return;

    const n = cards.length;
    const pull = pullPx || 0; // +down (next), -up (previous)
    const pullDown = Math.max(0, pull);
    const pullUp = Math.max(0, -pull);
    const revealingDown = pullDown > 24;
    const revealingUp = pullUp > 24;

    // Display order after rotate: [front, furthestBack, ...mid].
    // Peeks from the TOP keep FIXED slots while dragging — never compact when
    // the under-card is lifted out of a peek, or mid cards jump to the back.
    const peekOrder = [];
    for (let step = 1; step < n; step++) {
      peekOrder.push((frontIndex + step) % n);
    }

    const underIndex = revealingDown
      ? ringNeighborIndex(1)
      : revealingUp
        ? ringNeighborIndex(-1)
        : -1;

    // Resting fan height uses every peek slot (stable), even while one is under.
    const peekFan = peekOrder.length * PEEK;

    cards.forEach((card) => {
      card.classList.remove('is-front', 'is-under', 'is-peek');
    });

    peekOrder.forEach((idx, slot) => {
      if (idx === underIndex) return; // positioned below as under
      const card = cards[idx];
      card.classList.add('is-peek');
      card.style.zIndex = String(1 + slot);
      // Keep original slot Y so neighbors do not slide into the vacated peek.
      card.style.transform = `translate3d(0, ${slot * PEEK}px, 0)`;
    });

    if (underIndex >= 0) {
      const under = cards[underIndex];
      const underSlot = peekOrder.indexOf(underIndex);
      under.classList.add('is-under');
      under.style.zIndex = '8';
      // Slide from this card's own peek slot toward the front band.
      const fromY = underSlot >= 0 ? underSlot * PEEK : peekFan;
      let underY = peekFan;
      if (revealingUp) {
        const t = Math.min(1, pullUp / 120);
        underY = fromY + (peekFan - fromY) * t;
      } else if (revealingDown) {
        const t = Math.min(1, pullDown / 120);
        underY = fromY + (peekFan - fromY) * t;
      }
      under.style.transform = `translate3d(0, ${underY}px, 0)`;
    }

    const front = cards[frontIndex];
    front.classList.add('is-front');
    front.style.zIndex = '10';
    let frontY = peekFan;
    if (revealingDown) frontY = peekFan + pullDown;
    else if (revealingUp) frontY = peekFan - pullUp;
    front.style.transform = `translate3d(0, ${frontY}px, 0)`;

    const dragging = !!(deckDrag && deckDrag.moved);
    cards.forEach((c) => {
      c.classList.toggle('is-dragging', dragging && !animate);
    });

    stack.style.height = Math.max(520, Math.max(frontY, peekFan) + 470) + 'px';
  }

  function clearDragging() {
    document.querySelectorAll('.pass-card.is-dragging').forEach((c) => {
      c.classList.remove('is-dragging');
    });
  }

  /**
   * Rebuild display order so:
   *   passes[0] = new front
   *   passes[1] = dismissed card (TOP peek = furthest back)
   *   passes[2..] = the rest in stable ring order
   * Ring order (passRing) never changes on swipe, so both directions cycle every card.
   */
  function rotateDeckBy(direction) {
    syncPassRing();
    const n = passRing.length;
    if (n < 2) return;

    const oldId = passes[frontIndex]?.id;
    if (!oldId) return;
    const oldRingIdx = passRing.indexOf(oldId);
    if (oldRingIdx < 0) return;

    const newRingIdx = (oldRingIdx + direction + n) % n;
    const newFrontId = passRing[newRingIdx];
    const dismissedId = oldId;

    const restIds = [];
    for (let s = 1; s < n; s++) {
      const id = passRing[(oldRingIdx + s) % n];
      if (id !== newFrontId && id !== dismissedId) restIds.push(id);
    }

    const nextIds = [newFrontId, dismissedId, ...restIds];
    passes = nextIds.map((id) => passById(id)).filter(Boolean);
    frontIndex = 0;
    deckScroll = 0;
    expandedId = newFrontId;
  }

  function settleAfterPull(dy) {
    const n = passes.length;
    clearDragging();

    if (n < 2) {
      layoutDeck(0);
      return;
    }

    const stack = $('#card-stack');
    const cards = [...stack.querySelectorAll('.pass-card')];
    const front = cards[frontIndex];
    const goNext = dy > 72; // swipe down → next in ring
    const goPrev = dy < -72; // swipe up → previous in ring

    if (!goNext && !goPrev) {
      layoutDeck(0, { animate: true });
      return;
    }

    front.classList.remove('is-dragging');
    void front.offsetWidth;
    const fling = goNext
      ? Math.min(window.innerHeight * 0.5, 380)
      : -Math.min(window.innerHeight * 0.5, 380);
    layoutDeck(fling, { animate: true });

    window.setTimeout(() => {
      rotateDeckBy(goNext ? 1 : -1);
      renderStack();
      layoutDeck(goNext ? 36 : -36, { animate: false });
      requestAnimationFrame(() => {
        clearDragging();
        layoutDeck(0, { animate: true });
      });
    }, 320);
  }

  function onCardTap(index) {
    if (index !== frontIndex) {
      syncPassRing();
      const targetId = passes[index]?.id;
      const oldId = passes[frontIndex]?.id;
      if (targetId && oldId && targetId !== oldId) {
        const n = passRing.length;
        const oldRingIdx = passRing.indexOf(oldId);
        const newRingIdx = passRing.indexOf(targetId);
        // Walk the shorter ring direction so the chosen card becomes front
        // and the old front goes to the furthest-back peek.
        let dir = 1;
        if (oldRingIdx >= 0 && newRingIdx >= 0) {
          const forward = (newRingIdx - oldRingIdx + n) % n;
          const backward = (oldRingIdx - newRingIdx + n) % n;
          dir = forward <= backward ? forward : -backward;
          // dir is steps; rotateDeckBy only accepts ±1, so rebuild directly
          const restIds = [];
          for (let s = 1; s < n; s++) {
            const id = passRing[(oldRingIdx + s) % n];
            if (id !== targetId && id !== oldId) restIds.push(id);
          }
          passes = [targetId, oldId, ...restIds].map((id) => passById(id)).filter(Boolean);
          frontIndex = 0;
          deckScroll = 0;
          expandedId = targetId;
          renderStack();
        } else {
          frontIndex = index;
          deckScroll = index;
          expandedId = targetId;
        }
      }
      clearDragging();
      layoutDeck(0, { animate: true });
      return;
    }
    const pass = passes[frontIndex];
    if (pass) openViewer(pass.id);
  }


  // ---------- Long-press reorder (does not fight peek: only lifts if held still) ----------
  const LONG_PRESS_MS = 450;
  const REORDER_MOVE_SLOP = 10; // px — cancel long-press if finger drifts
  let longPressTimer = null;
  let reorderDrag = null; // { pointerId, fromIndex, orderIds, slot, startY, lastY }

  function clearLongPressTimer() {
    if (longPressTimer) {
      clearTimeout(longPressTimer);
      longPressTimer = null;
    }
  }

  /** Visual fan indices top → bottom (peeks then front). */
  function visualIndexOrder() {
    const n = passes.length;
    const order = [];
    for (let step = 1; step < n; step++) order.push((frontIndex + step) % n);
    order.push(frontIndex);
    return order;
  }

  function layoutReorderFan(orderIds, liftId, liftY) {
    const stack = $('#card-stack');
    const cards = [...stack.querySelectorAll('.pass-card')];
    if (!cards.length) return;
    const n = orderIds.length;
    const byId = new Map(cards.map((c) => [c.dataset.id, c]));
    const peekCount = Math.max(0, n - 1);
    const peekFan = peekCount * PEEK;

    cards.forEach((c) => {
      c.classList.remove('is-front', 'is-under', 'is-peek', 'is-dragging');
      c.classList.toggle('is-lifting', c.dataset.id === liftId);
    });

    orderIds.forEach((id, slot) => {
      const card = byId.get(id);
      if (!card) return;
      const isFrontSlot = slot === n - 1;
      const isLift = id === liftId;
      if (isFrontSlot && !isLift) {
        card.classList.add('is-front');
        card.style.zIndex = '10';
        card.style.transform = `translate3d(0, ${peekFan}px, 0)`;
      } else if (!isLift) {
        card.classList.add('is-peek');
        card.style.zIndex = String(1 + slot);
        card.style.transform = `translate3d(0, ${slot * PEEK}px, 0)`;
      } else {
        // lifted card follows finger; high z
        card.style.zIndex = '20';
        const y = liftY != null ? liftY : (isFrontSlot ? peekFan : slot * PEEK);
        card.style.transform = `translate3d(0, ${y}px, 0) scale(1.04)`;
        if (isFrontSlot) card.classList.add('is-front');
        else card.classList.add('is-peek');
      }
    });
    stack.style.height = Math.max(520, peekFan + 470) + 'px';
  }

  function slotFromY(clientY, stackTop, n) {
    // Map Y into fan slots (0 = top peek … n-1 = front)
    const peekFan = Math.max(0, n - 1) * PEEK;
    const rel = clientY - stackTop;
    // Front band starts around peekFan; treat lower half of front as last slot
    if (rel >= peekFan - PEEK * 0.35) {
      // within / below front band
      const frontMid = peekFan + 180;
      if (rel >= frontMid) return n - 1;
      // between last peek and front — pick closer
      const lastPeekY = (n - 2) * PEEK;
      return rel - lastPeekY < frontMid - rel ? Math.max(0, n - 2) : n - 1;
    }
    const slot = Math.round(rel / PEEK);
    return Math.max(0, Math.min(n - 1, slot));
  }

  function applyVisualOrderToPasses(orderIds) {
    // orderIds = visual top→bottom = [next, …, last, front]
    // Canonical ring: [front, next, …, last]
    if (!orderIds.length) return;
    const frontId = orderIds[orderIds.length - 1];
    const rest = orderIds.slice(0, -1);
    const ring = [frontId, ...rest];
    const nextPasses = ring.map((id) => passById(id)).filter(Boolean);
    if (nextPasses.length !== passes.length) return;
    passes = nextPasses;
    passRing = ring.slice();
    frontIndex = 0;
    deckScroll = 0;
    expandedId = frontId;
    passes.forEach((p, i) => { p.sortOrder = i; });
  }

  async function persistCoinOrder() {
    const ids = passes.map((p) => p.id);
    try {
      await api('/api/coins/reorder', { method: 'POST', json: { ids } });
    } catch (e) {
      console.warn('reorder API failed, falling back to PUTs', e);
      for (let i = 0; i < passes.length; i++) {
        const p = passes[i];
        p.sortOrder = i;
        try {
          await api('/api/coins/' + encodeURIComponent(p.id), {
            method: 'PUT',
            json: {
              title: p.title,
              notes: p.notes || '',
              accent: p.accent,
              imageUrl: p.imageUrl || null,
              imagePath: p.imagePath || null,
              attachments: passAttachments(p),
              sortOrder: i,
            },
          });
        } catch (err) {
          console.warn('sortOrder PUT failed', p.id, err);
        }
      }
    }
    for (const p of passes) {
      try { await putPass({ ...p, image: null }); } catch {}
    }
  }

  function beginReorder(pointerId, cardIndex, clientY) {
    if (passes.length < 2) return;
    clearLongPressTimer();
    // Cancel any in-progress peek
    deckDrag = null;
    clearDragging();
    layoutDeck(0, { animate: false });

    const vis = visualIndexOrder();
    const orderIds = vis.map((i) => passes[i].id);
    const liftId = passes[cardIndex]?.id;
    if (!liftId) return;
    const slot = orderIds.indexOf(liftId);
    if (slot < 0) return;

    try { navigator.vibrate?.(12); } catch {}

    const stack = $('#card-stack');
    const rect = stack.getBoundingClientRect();
    const peekFan = Math.max(0, orderIds.length - 1) * PEEK;
    const restY = slot === orderIds.length - 1 ? peekFan : slot * PEEK;

    reorderDrag = {
      pointerId,
      liftId,
      orderIds,
      initialOrder: orderIds.slice(),
      slot,
      startY: clientY,
      lastY: clientY,
      stackTop: rect.top,
      grabOffset: clientY - rect.top - restY,
      committed: false,
    };
    layoutReorderFan(orderIds, liftId, restY);
  }

  function moveReorder(clientY) {
    if (!reorderDrag) return;
    reorderDrag.lastY = clientY;
    const n = reorderDrag.orderIds.length;
    const liftY = clientY - reorderDrag.stackTop - (reorderDrag.grabOffset || 0);
    const target = slotFromY(clientY, reorderDrag.stackTop, n);
    if (target !== reorderDrag.slot) {
      const ids = reorderDrag.orderIds.slice();
      const from = reorderDrag.slot;
      const [item] = ids.splice(from, 1);
      ids.splice(target, 0, item);
      reorderDrag.orderIds = ids;
      reorderDrag.slot = target;
    }
    layoutReorderFan(reorderDrag.orderIds, reorderDrag.liftId, liftY);
  }

  async function endReorder(cancel) {
    if (!reorderDrag) return;
    const state = reorderDrag;
    reorderDrag = null;
    document.querySelectorAll('.pass-card.is-lifting').forEach((c) => {
      c.classList.remove('is-lifting');
    });
    if (cancel) {
      layoutDeck(0, { animate: true });
      return;
    }
    const changed =
      state.initialOrder.length !== state.orderIds.length ||
      state.initialOrder.some((id, i) => id !== state.orderIds[i]);
    applyVisualOrderToPasses(state.orderIds);
    renderStack();
    if (!changed) return;
    try {
      await persistCoinOrder();
      toast('Order saved');
    } catch (e) {
      console.error(e);
      toast('Could not save order');
    }
  }

  function bindDeckGestures() {
    const stack = $('#card-stack');
    if (!stack || stack.dataset.gesturesBound === '1') return;
    stack.dataset.gesturesBound = '1';
    stack.addEventListener('contextmenu', (e) => e.preventDefault());

    const TAP_SLOP = 12; // px — finger jitter still counts as tap

    stack.addEventListener('pointerdown', (e) => {
      if (e.button != null && e.button !== 0) return;
      if (!passes.length) return;
      if (e.target.closest('button')) return;
      if (reorderDrag) return;

      stack.setPointerCapture(e.pointerId);
      const card = e.target.closest('.pass-card');
      const cardIndex = card ? Number(card.dataset.index) : frontIndex;
      deckDrag = {
        startY: e.clientY,
        startX: e.clientX,
        lastY: e.clientY,
        moved: false,
        pointerId: e.pointerId,
        startScroll: deckScroll,
        cardIndex,
        longPressArmed: passes.length >= 2,
      };

      clearLongPressTimer();
      if (passes.length >= 2 && Number.isFinite(cardIndex)) {
        longPressTimer = setTimeout(() => {
          longPressTimer = null;
          if (!deckDrag || deckDrag.pointerId !== e.pointerId) return;
          if (deckDrag.moved) return;
          // Held still → lift for reorder (peek never started)
          beginReorder(e.pointerId, deckDrag.cardIndex, deckDrag.lastY);
          deckDrag = null;
        }, LONG_PRESS_MS);
      }
    });

    stack.addEventListener('pointermove', (e) => {
      if (reorderDrag && reorderDrag.pointerId === e.pointerId) {
        e.preventDefault();
        moveReorder(e.clientY);
        return;
      }
      if (!deckDrag || deckDrag.pointerId !== e.pointerId) return;
      const dy = e.clientY - deckDrag.startY;
      const dx = e.clientX - deckDrag.startX;
      const dist = Math.hypot(dx, dy);
      if (dist > REORDER_MOVE_SLOP) {
        // Finger moved — this is peek/flip, not long-press
        clearLongPressTimer();
        deckDrag.longPressArmed = false;
      }
      if (dist > TAP_SLOP) deckDrag.moved = true;
      deckDrag.lastY = e.clientY;

      if (!deckDrag.moved) return;

      if (passes.length < 2) {
        layoutDeck(dy, { animate: false });
        return;
      }
      layoutDeck(dy, { animate: false });
    });

    const endDrag = (e) => {
      if (reorderDrag && (!e || reorderDrag.pointerId === e.pointerId)) {
        clearLongPressTimer();
        endReorder(false);
        return;
      }
      if (!deckDrag || (e && deckDrag.pointerId !== e.pointerId)) return;
      clearLongPressTimer();
      const dy = deckDrag.lastY - deckDrag.startY;
      const moved = deckDrag.moved;
      const tappedIndex = deckDrag.cardIndex;
      deckDrag = null;

      // TAP: open full screen from anywhere on the front tile
      if (!moved) {
        clearDragging();
        layoutDeck(0, { animate: true });
        if (Number.isFinite(tappedIndex)) {
          if (tappedIndex === frontIndex) {
            const pass = passes[frontIndex];
            if (pass) {
              const el = stack.querySelector(`.pass-card[data-index="${frontIndex}"]`);
              if (el) {
                el.dataset.justOpened = '1';
                setTimeout(() => { delete el.dataset.justOpened; }, 400);
              }
              openViewer(pass.id);
            }
          } else {
            onCardTap(tappedIndex);
          }
        }
        return;
      }

      settleAfterPull(dy);
    };

    stack.addEventListener('pointerup', endDrag);
    stack.addEventListener('pointercancel', () => {
      clearLongPressTimer();
      if (reorderDrag) {
        endReorder(true);
        return;
      }
      deckDrag = null;
      clearDragging();
      layoutDeck(0, { animate: true });
    });

    stack.addEventListener(
      'wheel',
      (e) => {
        if (reorderDrag) return;
        if (passes.length < 2) return;
        e.preventDefault();
        deckScroll += e.deltaY > 0 ? 0.25 : -0.25;
        deckScroll = Math.max(0, Math.min(passes.length - 1, deckScroll));
        frontIndex = Math.round(deckScroll);
        expandedId = passes[frontIndex]?.id || null;
        clearDragging();
        layoutDeck(0, { animate: true });
      },
      { passive: false }
    );
  }

  // ---------- Viewer zoom (pinch / pan / double-tap / wheel) ----------
  const zoomState = {
    scale: 1,
    x: 0,
    y: 0,
    min: 1,
    max: 5,
  };
  let zoomPointers = new Map();
  let pinchStartDist = 0;
  let pinchStartScale = 1;
  let panStartX = 0;
  let panStartY = 0;
  let panOriginX = 0;
  let panOriginY = 0;
  let lastTap = 0;
  let zoomBound = false;
  let swipeStartX = 0;
  let swipeStartY = 0;
  let swipeTracking = false;
  let swipeMoved = false;
  /** Horizontal image-change slide (scale ≈ 1 only). */
  let slideOffset = 0;
  let slideAnimating = false;
  let slideDir = 0; // 1 = next (content from right), -1 = previous
  let slidePeerReady = false;
  const SLIDE_MS = 300;
  const SLIDE_EASE = 'cubic-bezier(0.22, 1, 0.36, 1)';
  const SLIDE_THRESHOLD = 56;

  function applyZoom() {
    const img = $('#viewer-image');
    if (!img) return;
    if (slideOffset !== 0 || slideAnimating) return;
    img.style.transition = '';
    img.style.transform = `translate(${zoomState.x}px, ${zoomState.y}px) scale(${zoomState.scale})`;
  }

  function hideSlidePeer() {
    const peer = $('#viewer-image-peer');
    if (!peer) return;
    peer.classList.add('hidden');
    peer.removeAttribute('src');
    peer.style.transition = '';
    peer.style.transform = '';
    slidePeerReady = false;
  }

  function slideWrapWidth() {
    const wrap = $('#viewer-image-wrap');
    return (wrap && wrap.clientWidth) || window.innerWidth || 1;
  }

  function ensureSlidePeer(dir) {
    if (!viewingId || !dir) return false;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return false;
    const imgs = viewerImages(pass);
    if (imgs.length < 2) return false;
    const next = (viewerImageIndex + dir + imgs.length) % imgs.length;
    const entry = imgs[next];
    const peer = $('#viewer-image-peer');
    if (!peer || !entry || !entry.url) return false;
    if (!slidePeerReady || slideDir !== dir) {
      peer.src = entry.url;
      peer.classList.remove('hidden');
      slidePeerReady = true;
      slideDir = dir;
    }
    return true;
  }

  function prepareSlidePeerToIndex(index, dir) {
    if (!viewingId) return false;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return false;
    const imgs = viewerImages(pass);
    const entry = imgs[index];
    const peer = $('#viewer-image-peer');
    if (!peer || !entry || !entry.url) return false;
    peer.src = entry.url;
    peer.classList.remove('hidden');
    slidePeerReady = true;
    slideDir = dir;
    return true;
  }

  function slideFrame(dx, { animate = false } = {}) {
    const img = $('#viewer-image');
    const peer = $('#viewer-image-peer');
    const wrap = $('#viewer-image-wrap');
    if (!img || !wrap) return;
    const w = slideWrapWidth();
    const transition = animate ? `transform ${SLIDE_MS}ms ${SLIDE_EASE}` : 'none';
    img.style.transition = transition;
    img.style.transform = `translate(${dx}px, 0px) scale(1)`;
    if (peer && slidePeerReady) {
      peer.style.transition = transition;
      // dir=1 (next): peer enters from right → peerX = dx + w
      // dir=-1 (prev): peer enters from left → peerX = dx - w
      peer.style.transform = `translate(${dx + slideDir * w}px, 0px) scale(1)`;
    }
    slideOffset = dx;
    wrap.classList.toggle('is-sliding', dx !== 0 || slideAnimating);
  }

  function waitSlideTransition(el) {
    return new Promise((resolve) => {
      if (!el) {
        resolve();
        return;
      }
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        el.removeEventListener('transitionend', onEnd);
        resolve();
      };
      const onEnd = (e) => {
        if (e.target !== el || e.propertyName !== 'transform') return;
        done();
      };
      el.addEventListener('transitionend', onEnd);
      setTimeout(done, SLIDE_MS + 80);
    });
  }

  async function finishSlide(commit, targetIndex = null) {
    const img = $('#viewer-image');
    const wrap = $('#viewer-image-wrap');
    const w = slideWrapWidth();
    if (!img) return false;

    if (!commit || !slideDir) {
      slideAnimating = true;
      if (wrap) wrap.classList.add('is-sliding');
      slideFrame(0, { animate: true });
      await waitSlideTransition(img);
      slideAnimating = false;
      slideOffset = 0;
      hideSlidePeer();
      if (wrap) wrap.classList.remove('is-sliding');
      applyZoom();
      return false;
    }

    const destIndex =
      targetIndex != null
        ? targetIndex
        : (() => {
            const pass = passes.find((p) => p.id === viewingId);
            if (!pass) return viewerImageIndex;
            const imgs = viewerImages(pass);
            return (viewerImageIndex + slideDir + imgs.length) % imgs.length;
          })();

    slideAnimating = true;
    if (wrap) wrap.classList.add('is-sliding');
    slideFrame(-slideDir * w, { animate: true });
    await waitSlideTransition(img);

    // Promote peer → main WHILE peer still covers the settled frame (no size/src flash).
    const pass = passes.find((p) => p.id === viewingId);
    const imgs = pass ? viewerImages(pass) : [];
    const entry = imgs[destIndex];
    const peer = $('#viewer-image-peer');
    img.style.transition = 'none';
    if (entry && entry.url) {
      img.src = entry.url;
      img.classList.remove('hidden');
      const noImg = $('#viewer-no-image');
      if (noImg) noImg.classList.add('hidden');
    } else if (peer && (peer.currentSrc || peer.getAttribute('src'))) {
      img.src = peer.currentSrc || peer.getAttribute('src');
    }
    img.style.transform = 'translate(0px, 0px) scale(1)';
    zoomState.scale = 1;
    zoomState.x = 0;
    zoomState.y = 0;

    hideSlidePeer();
    slideOffset = 0;
    slideAnimating = false;
    if (wrap) wrap.classList.remove('is-sliding');

    if (pass) {
      viewerImageIndex = Math.max(0, Math.min(destIndex, imgs.length - 1));
      highlightActiveThumb();
      updateAttachBar(pass);
    }
    return true;
  }

  async function animateToViewerIndex(index) {
    if (!viewingId || slideAnimating) return;
    if (index === viewerImageIndex) return;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return;
    const imgs = viewerImages(pass);
    if (!imgs[index]) return;
    const dir = index > viewerImageIndex ? 1 : -1;
    // Cancel zoom so slide owns transforms
    zoomState.scale = 1;
    zoomState.x = 0;
    zoomState.y = 0;
    if (!prepareSlidePeerToIndex(index, dir)) {
      setViewerImageFromIndex(pass, index, { reset: true });
      return;
    }
    slideFrame(0);
    // Double rAF so the browser paints the peer at ±w before animating
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    await finishSlide(true, index);
  }

  function resetZoom() {
    zoomState.scale = 1;
    zoomState.x = 0;
    zoomState.y = 0;
    zoomPointers.clear();
    if (!slideAnimating) {
      slideOffset = 0;
      hideSlidePeer();
      const wrap = $('#viewer-image-wrap');
      if (wrap) wrap.classList.remove('is-sliding');
      applyZoom();
    }
    const hint = $('#viewer-zoom-hint');
    if (hint) hint.classList.remove('hidden');
  }

  function clampPan() {
    const wrap = $('#viewer-image-wrap');
    const img = $('#viewer-image');
    if (!wrap || !img || zoomState.scale <= 1) {
      zoomState.x = 0;
      zoomState.y = 0;
      return;
    }
    const rect = wrap.getBoundingClientRect();
    const iw = img.clientWidth * zoomState.scale;
    const ih = img.clientHeight * zoomState.scale;
    const maxX = Math.max(0, (iw - rect.width) / 2);
    const maxY = Math.max(0, (ih - rect.height) / 2);
    zoomState.x = Math.min(maxX, Math.max(-maxX, zoomState.x));
    zoomState.y = Math.min(maxY, Math.max(-maxY, zoomState.y));
  }

  function pointerDistance(a, b) {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return Math.hypot(dx, dy);
  }

  function pointOnViewerImage(x, y) {
    const img = $('#viewer-image');
    if (!img || img.classList.contains('hidden')) return false;
    const r = img.getBoundingClientRect();
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
  }

  function bindZoom() {
    if (zoomBound) return;
    const wrap = $('#viewer-image-wrap');
    if (!wrap) return;
    zoomBound = true;

    // Letterbox tap (black above/below the photo) → close like the back arrow
    let letterboxTap = null;

    wrap.addEventListener('pointerdown', (e) => {
      if ($('#viewer-image').classList.contains('hidden')) return;
      if (slideAnimating) return;
      e.preventDefault();
      wrap.setPointerCapture(e.pointerId);
      zoomPointers.set(e.pointerId, { x: e.clientX, y: e.clientY });

      const onPhoto = pointOnViewerImage(e.clientX, e.clientY);
      if (!onPhoto && zoomPointers.size === 1 && zoomState.scale <= 1.05) {
        letterboxTap = { x: e.clientX, y: e.clientY, id: e.pointerId, moved: false };
      } else {
        letterboxTap = null;
      }

      if (zoomPointers.size === 1) {
        panStartX = e.clientX;
        panStartY = e.clientY;
        panOriginX = zoomState.x;
        panOriginY = zoomState.y;
        swipeStartX = e.clientX;
        swipeStartY = e.clientY;
        swipeTracking = zoomState.scale <= 1.05 && onPhoto;
        swipeMoved = false;
        // Double-tap zoom only when tapping the photo itself
        if (onPhoto) {
          const now = Date.now();
          if (now - lastTap < 300) {
            if (zoomState.scale > 1.05) {
              resetZoom();
            } else {
              zoomState.scale = 2.5;
              const rect = wrap.getBoundingClientRect();
              const cx = rect.left + rect.width / 2;
              const cy = rect.top + rect.height / 2;
              zoomState.x = (cx - e.clientX) * (zoomState.scale - 1);
              zoomState.y = (cy - e.clientY) * (zoomState.scale - 1);
              clampPan();
              applyZoom();
              $('#viewer-zoom-hint')?.classList.add('hidden');
            }
            lastTap = 0;
          } else {
            lastTap = now;
          }
        } else {
          lastTap = 0;
        }
      } else if (zoomPointers.size === 2) {
        letterboxTap = null;
        swipeTracking = false;
        const pts = [...zoomPointers.values()];
        pinchStartDist = pointerDistance(pts[0], pts[1]);
        pinchStartScale = zoomState.scale;
      }
      wrap.classList.add('is-panning');
    });

    wrap.addEventListener('pointermove', (e) => {
      if (!zoomPointers.has(e.pointerId)) return;
      e.preventDefault();
      if (letterboxTap && letterboxTap.id === e.pointerId) {
        if (Math.hypot(e.clientX - letterboxTap.x, e.clientY - letterboxTap.y) > 10) {
          letterboxTap.moved = true;
        }
      }
      zoomPointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (zoomPointers.size === 2) {
        const pts = [...zoomPointers.values()];
        const dist = pointerDistance(pts[0], pts[1]);
        if (pinchStartDist > 0) {
          let next = pinchStartScale * (dist / pinchStartDist);
          next = Math.min(zoomState.max, Math.max(zoomState.min, next));
          zoomState.scale = next;
          if (next <= 1) {
            zoomState.x = 0;
            zoomState.y = 0;
          } else {
            clampPan();
          }
          applyZoom();
          $('#viewer-zoom-hint')?.classList.add('hidden');
        }
      } else if (zoomPointers.size === 1 && zoomState.scale > 1) {
        const dx = e.clientX - panStartX;
        const dy = e.clientY - panStartY;
        zoomState.x = panOriginX + dx;
        zoomState.y = panOriginY + dy;
        clampPan();
        applyZoom();
        swipeTracking = false;
      } else if (zoomPointers.size === 1 && swipeTracking) {
        const dx = e.clientX - swipeStartX;
        const dy = e.clientY - swipeStartY;
        if (Math.hypot(dx, dy) > 12) swipeMoved = true;
        // Finger-follow horizontal slide when not zoomed (ignore mostly-vertical drags)
        if (
          swipeMoved &&
          zoomState.scale <= 1.05 &&
          Math.abs(dx) > Math.abs(dy) * 0.85
        ) {
          const dir = dx < 0 ? 1 : dx > 0 ? -1 : slideDir;
          if (dir && ensureSlidePeer(dir)) {
            // Soft rubber-band feel near extremes is unnecessary (images wrap);
            // slight ease when peer missing already handled by ensureSlidePeer.
            slideFrame(dx);
          }
        }
      }
    });

    const endPointer = (e) => {
      const wasLetterbox =
        letterboxTap &&
        letterboxTap.id === e.pointerId &&
        !letterboxTap.moved &&
        zoomState.scale <= 1.05;
      if (letterboxTap && letterboxTap.id === e.pointerId) letterboxTap = null;

      zoomPointers.delete(e.pointerId);
      if (zoomPointers.size < 2) pinchStartDist = 0;
      if (zoomPointers.size === 0) wrap.classList.remove('is-panning');
      if (zoomState.scale <= 1.02) {
        zoomState.scale = 1;
        zoomState.x = 0;
        zoomState.y = 0;
        applyZoom();
      }

      if (wasLetterbox) {
        swipeTracking = false;
        dismissViewer();
        return;
      }

      // Horizontal swipe changes image when not zoomed (pan wins when zoomed)
      if (
        swipeTracking &&
        swipeMoved &&
        zoomState.scale <= 1.05 &&
        zoomPointers.size === 0 &&
        !slideAnimating
      ) {
        const dx = (e.clientX || swipeStartX) - swipeStartX;
        const dy = (e.clientY || swipeStartY) - swipeStartY;
        if (Math.abs(dx) > SLIDE_THRESHOLD && Math.abs(dx) > Math.abs(dy) * 1.25) {
          slideDir = dx < 0 ? 1 : -1;
          if (ensureSlidePeer(slideDir)) finishSlide(true);
          else if (slideOffset !== 0 || slidePeerReady) finishSlide(false);
        } else if (slideOffset !== 0 || slidePeerReady) {
          finishSlide(false);
        }
      } else if (slideOffset !== 0 && !slideAnimating) {
        finishSlide(false);
      }
      swipeTracking = false;
    };
    wrap.addEventListener('pointerup', endPointer);
    wrap.addEventListener('pointercancel', endPointer);

    // iOS Safari: block native page gestures so pinch reaches our handlers
    wrap.addEventListener('touchmove', (e) => {
      if (e.touches.length >= 1) e.preventDefault();
    }, { passive: false });

    wrap.addEventListener('wheel', (e) => {
      if ($('#viewer-image').classList.contains('hidden')) return;
      e.preventDefault();
      const delta = e.deltaY > 0 ? -0.15 : 0.15;
      zoomState.scale = Math.min(zoomState.max, Math.max(zoomState.min, zoomState.scale + delta));
      if (zoomState.scale <= 1) {
        zoomState.x = 0;
        zoomState.y = 0;
      } else {
        clampPan();
      }
      applyZoom();
      $('#viewer-zoom-hint')?.classList.add('hidden');
    }, { passive: false });
  }


  function setHomeVisible(visible) {
    const stack = $('#stack-view');
    const header = $('#home-header');
    if (visible) {
      if (stack) show(stack);
      if (header) show(header);
      document.body.classList.remove('mode-overlay');
    } else {
      if (stack) hide(stack);
      if (header) hide(header);
      document.body.classList.add('mode-overlay');
    }
  }

  // ---------- Viewer ----------
  function setViewerImageFromIndex(pass, index, { reset = true } = {}) {
    const imgs = viewerImages(pass);
    const img = $('#viewer-image');
    const noImg = $('#viewer-no-image');
    if (!slideAnimating) {
      hideSlidePeer();
      slideOffset = 0;
      const wrap = $('#viewer-image-wrap');
      if (wrap) wrap.classList.remove('is-sliding');
      if (img) {
        img.style.transition = '';
      }
    }
    if (!imgs.length) {
      viewerImageIndex = 0;
      img.removeAttribute('src');
      img.classList.add('hidden');
      noImg.classList.remove('hidden');
      if (reset) resetZoom();
      updateAttachBar(pass);
      return;
    }
    viewerImageIndex = Math.max(0, Math.min(index, imgs.length - 1));
    const entry = imgs[viewerImageIndex];
    if (entry.url) {
      img.src = entry.url;
      img.classList.remove('hidden');
      noImg.classList.add('hidden');
    } else {
      img.removeAttribute('src');
      img.classList.add('hidden');
      noImg.classList.remove('hidden');
    }
    if (reset) resetZoom();
    highlightActiveThumb();
    updateAttachBar(pass);
  }

  function updateAttachBar(pass) {
    const bar = $('#viewer-attach-bar');
    if (!bar) return;
    const imgs = viewerImages(pass);
    const cur = imgs[viewerImageIndex];
    if (cur && cur.kind === 'attachment') bar.classList.remove('hidden');
    else bar.classList.add('hidden');
  }

  function highlightActiveThumb() {
    const strip = $('#viewer-thumbs');
    if (!strip) return;
    strip.querySelectorAll('.viewer-thumb[data-index]').forEach((el) => {
      const i = Number(el.getAttribute('data-index'));
      el.classList.toggle('is-active', i === viewerImageIndex);
    });
  }

  function renderViewerThumbs(pass) {
    const strip = $('#viewer-thumbs');
    if (!strip) return;
    strip.innerHTML = '';
    const imgs = viewerImages(pass);
    const hasPrimary = imgs.some((i) => i.kind === 'primary');
    // Show strip when there is a main image (primary thumb + plus), or any extras
    if (!hasPrimary && !imgs.length) {
      strip.classList.add('hidden');
      return;
    }
    strip.classList.remove('hidden');

    imgs.forEach((entry, i) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'viewer-thumb' + (i === viewerImageIndex ? ' is-active' : '');
      btn.setAttribute('data-index', String(i));
      btn.setAttribute('aria-label', entry.kind === 'primary' ? 'Main image' : 'Attachment ' + i);
      const im = document.createElement('img');
      im.src = entry.url || '';
      im.alt = '';
      btn.appendChild(im);
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        if (i === viewerImageIndex && entry.kind === 'attachment') {
          removeActiveAttachment();
          return;
        }
        if (i === viewerImageIndex) return;
        animateToViewerIndex(i);
      });
      strip.appendChild(btn);
    });

    const plus = document.createElement('button');
    plus.type = 'button';
    plus.className = 'viewer-thumb viewer-thumb-plus';
    plus.setAttribute('aria-label', 'Add image');
    plus.textContent = '+';
    const extras = passAttachments(pass).length;
    if (extras >= MAX_ATTACHMENTS) {
      plus.classList.add('is-disabled');
      plus.disabled = true;
      plus.title = 'Max ' + (MAX_ATTACHMENTS + 1) + ' images';
    }
    plus.addEventListener('click', (e) => {
      e.stopPropagation();
      openAttachSheet();
    });
    strip.appendChild(plus);
  }

  function stepViewerImage(delta) {
    if (!viewingId || slideAnimating) return;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return;
    const imgs = viewerImages(pass);
    if (imgs.length < 2) return;
    const next = (viewerImageIndex + delta + imgs.length) % imgs.length;
    animateToViewerIndex(next);
  }

  function openViewer(id) {
    const pass = passes.find((p) => p.id === id);
    if (!pass) return;
    viewingId = id;
    viewerImageIndex = 0;
    passAttachments(pass);
    bindZoom();
    $('#viewer-title').textContent = pass.title || 'Untitled';
    $('#viewer-notes').textContent = pass.notes || '';
    setViewerImageFromIndex(pass, 0, { reset: true });
    renderViewerThumbs(pass);
    // Hide the wallet deck so cards cannot paint over the viewer (iOS stacking bug)
    setHomeVisible(false);
    show($('#viewer'));
    history.pushState({ view: 'viewer', id }, '');
  }

  function refreshViewerIfOpen() {
    if (!viewingId) return;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return;
    $('#viewer-title').textContent = pass.title || 'Untitled';
    $('#viewer-notes').textContent = pass.notes || '';
    const imgs = viewerImages(pass);
    if (viewerImageIndex >= imgs.length) viewerImageIndex = Math.max(0, imgs.length - 1);
    setViewerImageFromIndex(pass, viewerImageIndex, { reset: true });
    renderViewerThumbs(pass);
  }

  function closeViewer() {
    resetZoom();
    hide($('#viewer'));
    const strip = $('#viewer-thumbs');
    if (strip) {
      strip.innerHTML = '';
      strip.classList.add('hidden');
    }
    $('#viewer-attach-bar')?.classList.add('hidden');
    viewingId = null;
    viewerImageIndex = 0;
    const editor = $('#editor');
    if (!editor || editor.classList.contains('hidden')) {
      setHomeVisible(true);
      renderStack();
    }
  }

  function dismissViewer() {
    closeViewer();
    if (history.state?.view === 'viewer') history.back();
  }

  // ---------- Editor ----------
  function setEditorAccent(index) {
    const next = Number.isInteger(index) && index >= 0 && index < ACCENT_COLORS.length ? index : 0;
    editorAccent = next;
    document.querySelectorAll('#accent-picker .accent-swatch').forEach((swatch) => {
      const selected = Number(swatch.dataset.accent) === next;
      swatch.classList.toggle('is-selected', selected);
      swatch.setAttribute('aria-checked', selected ? 'true' : 'false');
    });
  }

  function openEditor(id = null) {
    editingId = id;
    clearDraftImage();
    editorImageIndex = 0;
    const heading = $('#editor-heading');
    // Hide crop/clear until we know there is an image
    $('#btn-crop-image')?.classList.add('hidden');
    $('#btn-clear-image')?.classList.add('hidden');
    $('#image-edit-row')?.classList.add('hidden');
    $('#image-preview-wrap').classList.add('hidden');
    if (id) {
      const pass = passes.find((p) => p.id === id);
      if (!pass) return;
      heading.textContent = 'Edit coin';
      $('#field-title').value = pass.title || '';
      $('#field-notes').value = pass.notes || '';
      setEditorAccent(ensureAccent(pass));
      if (pass.image) {
        draftImage = pass.image;
        draftPreviewUrl = URL.createObjectURL(pass.image);
      }
      // Preview + tools come from editorImages / setEditorPreviewFromIndex
    } else {
      heading.textContent = 'New coin';
      $('#field-title').value = '';
      $('#field-notes').value = '';
      setEditorAccent(pickUniqueAccent());
    }
    renderEditorThumbs();
    const list = editorImages();
    if (list.length) setEditorPreviewFromIndex(0, { resetSlide: true });
    // Don't let the full-screen viewer (or deck cards) sit under the sheet
    if (viewingId) hide($('#viewer'));
    setHomeVisible(false);
    show($('#editor'));
    const panel = $('#editor .sheet-panel');
    if (panel) panel.scrollTop = 0;
    // Desktop: focus title for typing. On iPhone, autofocusing an empty text
    // field immediately summons the native Paste|Scan Text edit menu, which
    // sits over our Paste button and looks like "native Paste" is still in use.
    if (!isCoarsePointerDevice()) {
      setTimeout(() => $('#field-title').focus(), 50);
    }
  }

  function closeEditor() {
    hide($('#editor'));
    editingId = null;
    editorImageIndex = 0;
    hideEditorSlidePeer();
    clearDraftImage();
    const strip = $('#editor-thumbs');
    if (strip) {
      strip.innerHTML = '';
      strip.classList.add('hidden');
    }
    $('#field-file').value = '';
    $('#field-camera').value = '';
    // Return to viewer if we came from Edit
    if (viewingId) {
      const pass = passes.find((p) => p.id === viewingId);
      if (pass) openViewer(pass.id);
      else {
        viewingId = null;
        setHomeVisible(true);
        renderStack();
      }
    } else {
      setHomeVisible(true);
      renderStack();
    }
  }

  async function saveEditor() {
    const title = $('#field-title').value.trim();
    if (!title) {
      toast('Title is required');
      $('#field-title').focus();
      return;
    }
    // Wait for in-flight paste/compress so Save after Paste keeps the image
    try { await draftImageTask; } catch {}
    const notes = $('#field-notes').value.trim();
    const accent = editorAccent;
    const now = Date.now();

    try {
      if (editingId) {
        const pass = passes.find((p) => p.id === editingId);
        if (!pass) return;
        if (objectUrls.has(pass.id)) {
          URL.revokeObjectURL(objectUrls.get(pass.id));
          objectUrls.delete(pass.id);
        }
        pass.title = title;
        pass.notes = notes;
        pass.accent = accent;
        pass.updatedAt = now;
        const imageBlob = draftImage; // may be null to keep existing cloud image
        if (imageBlob) pass.image = imageBlob;
        await saveCloudCoin(pass, imageBlob || null);
        // keep local IDB mirror best-effort
        try { await putPass({ ...pass, image: null }); } catch {}
        toast('Saved');
        closeEditor();
        if (!viewingId) renderStack();
      } else {
        const id = uid();
        const pass = {
          id,
          title,
          notes,
          image: draftImage,
          imageUrl: null,
          attachments: [],
          createdAt: now,
          updatedAt: now,
          accent,
          sortOrder: nextFrontSortOrder(),
          _isNew: true,
        };
        await saveCloudCoin(pass, draftImage || null);
        try { await putPass({ ...pass, image: null }); } catch {}
        passes.unshift(pass);
        passRing = [pass.id, ...passRing.filter((x) => x !== pass.id)];
        frontIndex = 0;
        deckScroll = 0;
        expandedId = pass.id;
        toast('Coin added');
        closeEditor();
        renderStack();
      }
    } catch (e) {
      console.error(e);
      toast(e.message || 'Save failed');
    }
  }

  // ---------- Delete confirm ----------
  let confirmResolve = null;

  function askConfirm(opts = {}) {
    const title = opts.title || 'Toss this coin?';
    const message =
      opts.message ||
      'This can’t be undone. The image stays only on this device until you delete it.';
    const okLabel = opts.okLabel || 'Delete';
    const t = $('#confirm-title');
    const p = $('#confirm .confirm-panel p');
    const ok = $('#btn-confirm-ok');
    if (t) t.textContent = title;
    if (p) p.textContent = message;
    if (ok) ok.textContent = okLabel;
    return new Promise((resolve) => {
      confirmResolve = resolve;
      show($('#confirm'));
    });
  }

  function closeConfirm(result) {
    hide($('#confirm'));
    if (confirmResolve) {
      confirmResolve(result);
      confirmResolve = null;
    }
    // Restore default coin-delete copy
    const t = $('#confirm-title');
    const p = $('#confirm .confirm-panel p');
    const ok = $('#btn-confirm-ok');
    if (t) t.textContent = 'Toss this coin?';
    if (p) p.textContent = 'This can’t be undone. The image stays only on this device until you delete it.';
    if (ok) ok.textContent = 'Delete';
  }

  async function doDelete() {
    if (!viewingId) return;
    const ok = await askConfirm();
    if (!ok) return;
    const id = viewingId;
    try { await deleteCloudCoin(id); } catch (e) { console.error(e); toast(e.message || "Delete failed"); return; }
    try { await deletePass(id); } catch {}
    if (objectUrls.has(id)) {
      URL.revokeObjectURL(objectUrls.get(id));
      objectUrls.delete(id);
    }
    passes = passes.filter((p) => p.id !== id);
    syncPassRing();
    if (expandedId === id) expandedId = null;
    closeViewer();
    if (history.state?.view === 'viewer') history.back();
    renderStack();
    toast('Deleted');
  }


  // ---------- Viewer / editor attachments ----------
  function attachmentCoinId() {
    return viewingId || editingId;
  }

  function openAttachSheet() {
    const id = attachmentCoinId();
    if (!id) return;
    const pass = passes.find((p) => p.id === id);
    if (!pass) return;
    if (passAttachments(pass).length >= MAX_ATTACHMENTS) {
      toast('Max ' + (MAX_ATTACHMENTS + 1) + ' images per coin');
      return;
    }
    if (!pass.imageUrl && !pass.image && !draftImage) {
      toast('Add a main image first');
      return;
    }
    show($('#attach-sheet'));
  }

  function closeAttachSheet() {
    hide($('#attach-sheet'));
    const f = $('#attach-file');
    const c = $('#attach-camera');
    if (f) f.value = '';
    if (c) c.value = '';
  }

  async function addAttachmentFromBlob(blob) {
    const id = attachmentCoinId();
    if (!id || !blob) return;
    const pass = passes.find((p) => p.id === id);
    if (!pass) return;
    if (passAttachments(pass).length >= MAX_ATTACHMENTS) {
      toast('Max ' + (MAX_ATTACHMENTS + 1) + ' images per coin');
      return;
    }
    closeAttachSheet();
    try {
      toast('Adding…');
      const compressed = await compressImage(blob);
      const up = await uploadCoinAttachment(pass.id, compressed);
      if (up?.coin) {
        Object.assign(pass, up.coin);
      } else if (up?.attachment) {
        passAttachments(pass).push(up.attachment);
      }
      passAttachments(pass);
      try { await putPass({ ...pass, image: null }); } catch {}
      const imgs = viewerImages(pass);
      viewerImageIndex = Math.max(0, imgs.length - 1);
      refreshViewerIfOpen();
      renderEditorThumbs();
      const edList = editorImages();
      if (edList.length) {
        editorImageIndex = Math.max(0, edList.length - 1);
        setEditorPreviewFromIndex(editorImageIndex, { resetSlide: true });
      }
      toast('Image added');
    } catch (e) {
      console.error(e);
      toast(e.message || 'Couldn’t add image');
    }
  }

  async function removeActiveAttachment() {
    if (!viewingId) return;
    const pass = passes.find((p) => p.id === viewingId);
    if (!pass) return;
    const imgs = viewerImages(pass);
    const cur = imgs[viewerImageIndex];
    if (!cur || cur.kind !== 'attachment') {
      toast('Main image: use Edit → Clear to replace');
      return;
    }
    const ok = await askConfirm({
      title: 'Remove this image?',
      message: 'Only this extra image is removed. The coin and main image stay.',
      okLabel: 'Remove',
    });
    if (!ok) return;
    try {
      const res = await deleteCoinAttachment(pass.id, cur.id);
      if (res?.coin) Object.assign(pass, res.coin);
      else pass.attachments = passAttachments(pass).filter((a) => a.id !== cur.id);
      try { await putPass({ ...pass, image: null }); } catch {}
      if (viewerImageIndex > 0) viewerImageIndex -= 1;
      refreshViewerIfOpen();
      renderEditorThumbs();
      toast('Image removed');
    } catch (e) {
      console.error(e);
      toast(e.message || 'Couldn’t remove image');
    }
  }

  async function removeEditorAttachment(attId) {
    // Never delete the main/primary image via the attachment × path
    if (!editingId || !attId || attId === 'primary') return;
    const pass = passes.find((p) => p.id === editingId);
    if (!pass) return;
    const wasCurrent =
      editorImages()[editorImageIndex]?.id === attId;
    const ok = await askConfirm({
      title: 'Remove this image?',
      message: 'Only this extra image is removed. The coin and main image stay.',
      okLabel: 'Remove',
    });
    if (!ok) return;
    try {
      const res = await deleteCoinAttachment(pass.id, attId);
      if (res?.coin) Object.assign(pass, res.coin);
      else pass.attachments = passAttachments(pass).filter((a) => a.id !== attId);
      try { await putPass({ ...pass, image: null }); } catch {}
      if (viewingId === pass.id) {
        const imgs = viewerImages(pass);
        if (viewerImageIndex >= imgs.length) viewerImageIndex = Math.max(0, imgs.length - 1);
        refreshViewerIfOpen();
      }
      const list = editorImages();
      if (wasCurrent || editorImageIndex >= list.length) {
        editorImageIndex = Math.max(0, Math.min(editorImageIndex, list.length - 1));
      }
      renderEditorThumbs();
      if (list.length) setEditorPreviewFromIndex(editorImageIndex, { resetSlide: true });
      else {
        $('#image-preview-wrap')?.classList.add('hidden');
      }
      toast('Image removed');
    } catch (e) {
      console.error(e);
      toast(e.message || 'Couldn’t remove image');
    }
  }

  /** Image list for editor preview (primary first, draft override). */
  function editorImages() {
    const pass = editingId ? passes.find((p) => p.id === editingId) : null;
    const list = [];
    if (pass) {
      for (const entry of viewerImages(pass)) {
        if (entry.kind === 'primary' && draftPreviewUrl) {
          list.push({ kind: 'primary', id: 'primary', url: draftPreviewUrl });
        } else {
          list.push(entry);
        }
      }
      if (!list.some((e) => e.kind === 'primary') && draftPreviewUrl) {
        list.unshift({ kind: 'primary', id: 'primary', url: draftPreviewUrl });
      }
    } else if (draftPreviewUrl) {
      list.push({ kind: 'primary', id: 'primary', url: draftPreviewUrl });
    }
    return list;
  }

  // ---------- Editor preview dual-image slide (mirrors viewer) ----------
  let edSlideOffset = 0;
  let edSlideAnimating = false;
  let edSlideDir = 0;
  let edSlidePeerReady = false;
  let edSwipeStartX = 0;
  let edSwipeStartY = 0;
  let edSwipeTracking = false;
  let edSwipeMoved = false;
  let edSlideBound = false;
  const ED_SLIDE_MS = 300;
  const ED_SLIDE_EASE = 'cubic-bezier(0.22, 1, 0.36, 1)';
  const ED_SLIDE_THRESHOLD = 48;

  function hideEditorSlidePeer() {
    const peer = $('#image-preview-peer');
    if (!peer) return;
    peer.classList.add('hidden');
    peer.removeAttribute('src');
    peer.style.transition = '';
    peer.style.transform = '';
    edSlidePeerReady = false;
  }

  function edSlideWrapWidth() {
    const stage = $('#image-preview-stage');
    return (stage && stage.clientWidth) || window.innerWidth || 1;
  }

  function ensureEditorSlidePeer(dir) {
    const list = editorImages();
    if (list.length < 2 || !dir) return false;
    const next = (editorImageIndex + dir + list.length) % list.length;
    const entry = list[next];
    const peer = $('#image-preview-peer');
    if (!peer || !entry || !entry.url) return false;
    if (!edSlidePeerReady || edSlideDir !== dir) {
      peer.src = entry.url;
      peer.classList.remove('hidden');
      edSlidePeerReady = true;
      edSlideDir = dir;
    }
    return true;
  }

  function prepareEditorSlidePeerToIndex(index, dir) {
    const list = editorImages();
    const entry = list[index];
    const peer = $('#image-preview-peer');
    if (!peer || !entry || !entry.url) return false;
    peer.src = entry.url;
    peer.classList.remove('hidden');
    edSlidePeerReady = true;
    edSlideDir = dir;
    return true;
  }

  function edSlideFrame(dx, { animate = false } = {}) {
    const img = $('#image-preview');
    const peer = $('#image-preview-peer');
    const stage = $('#image-preview-stage');
    if (!img || !stage) return;
    const w = edSlideWrapWidth();
    const transition = animate ? `transform ${ED_SLIDE_MS}ms ${ED_SLIDE_EASE}` : 'none';
    img.style.transition = transition;
    img.style.transform = `translate(${dx}px, 0px)`;
    if (peer && edSlidePeerReady) {
      peer.style.transition = transition;
      peer.style.transform = `translate(${dx + edSlideDir * w}px, 0px)`;
    }
    edSlideOffset = dx;
    stage.classList.toggle('is-sliding', dx !== 0 || edSlideAnimating);
  }

  function waitEditorSlideTransition(el) {
    return new Promise((resolve) => {
      if (!el) {
        resolve();
        return;
      }
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        el.removeEventListener('transitionend', onEnd);
        resolve();
      };
      const onEnd = (e) => {
        if (e.target !== el || e.propertyName !== 'transform') return;
        done();
      };
      el.addEventListener('transitionend', onEnd);
      setTimeout(done, ED_SLIDE_MS + 80);
    });
  }

  async function finishEditorSlide(commit, targetIndex = null) {
    const img = $('#image-preview');
    const stage = $('#image-preview-stage');
    const w = edSlideWrapWidth();
    if (!img) return false;

    if (!commit || !edSlideDir) {
      edSlideAnimating = true;
      if (stage) stage.classList.add('is-sliding');
      edSlideFrame(0, { animate: true });
      await waitEditorSlideTransition(img);
      edSlideAnimating = false;
      edSlideOffset = 0;
      hideEditorSlidePeer();
      if (stage) stage.classList.remove('is-sliding');
      return false;
    }

    const list = editorImages();
    const destIndex =
      targetIndex != null
        ? targetIndex
        : (editorImageIndex + edSlideDir + list.length) % list.length;

    edSlideAnimating = true;
    if (stage) stage.classList.add('is-sliding');
    edSlideFrame(-edSlideDir * w, { animate: true });
    await waitEditorSlideTransition(img);

    // Promote peer → main while peer still visible (same box, no letterbox snap).
    const entry = list[destIndex];
    img.style.transition = 'none';
    if (entry && entry.url) img.src = entry.url;
    img.style.transform = 'translate(0px, 0px)';

    hideEditorSlidePeer();
    edSlideOffset = 0;
    edSlideAnimating = false;
    if (stage) stage.classList.remove('is-sliding');

    setEditorPreviewFromIndex(destIndex, { resetSlide: false });
    return true;
  }

  async function animateToEditorIndex(index) {
    if (edSlideAnimating) return;
    if (index === editorImageIndex) {
      highlightEditorThumbs();
      return;
    }
    const list = editorImages();
    if (!list[index]) return;
    const dir = index > editorImageIndex ? 1 : -1;
    if (!prepareEditorSlidePeerToIndex(index, dir)) {
      setEditorPreviewFromIndex(index, { resetSlide: true });
      return;
    }
    edSlideFrame(0);
    await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
    await finishEditorSlide(true, index);
  }

  function updateEditorPrimaryTools() {
    const list = editorImages();
    const cur = list[editorImageIndex];
    const hasPrimary = list.some((e) => e.kind === 'primary');
    const row = $('#image-edit-row');
    // Crop + rotate for whichever image is highlighted (primary or attachment)
    if (row) {
      if (cur && cur.url) {
        row.classList.remove('hidden');
        $('#btn-crop-image')?.classList.remove('hidden');
      } else {
        row.classList.add('hidden');
        $('#btn-crop-image')?.classList.add('hidden');
      }
    }
    // Clear/replace is for the primary face only — never deletes attachments/coin
    if (hasPrimary) {
      $('#btn-clear-image')?.classList.remove('hidden');
    } else {
      $('#btn-clear-image')?.classList.add('hidden');
    }
  }

  function getEditorEditTarget() {
    const list = editorImages();
    const cur = list[editorImageIndex];
    if (!cur || !cur.url) return null;
    return cur;
  }

  async function blobForEditorTarget(target) {
    if (!target) return null;
    if (target.kind === 'primary' && draftImage) return draftImage;
    const res = await fetch(target.url, { mode: 'cors', cache: 'no-store' });
    if (!res.ok) throw new Error('Could not load image');
    return res.blob();
  }

  /** Persist a cropped/rotated blob to primary draft or attachment API. */
  async function commitEditorImageBlob(blob, { quiet } = {}) {
    const target = getEditorEditTarget();
    if (!target || !blob) return;
    if (target.kind === 'attachment') {
      if (!editingId) {
        toast('Save the coin first');
        return;
      }
      const pass = passes.find((p) => p.id === editingId);
      if (!pass) return;
      if (!quiet) toast('Saving…');
      const compressed = await compressImage(blob);
      const up = await replaceCoinAttachment(pass.id, target.id, compressed);
      const bust = (url) => {
        if (!url) return url;
        const base = url.split('?')[0];
        return base + '?v=' + Date.now();
      };
      if (up?.attachment?.imageUrl) up.attachment.imageUrl = bust(up.attachment.imageUrl);
      if (up?.coin) {
        Object.assign(pass, up.coin);
        const atts = passAttachments(pass);
        const hit = atts.find((a) => a.id === target.id);
        if (hit?.imageUrl) hit.imageUrl = bust(hit.imageUrl);
      } else if (up?.attachment) {
        const atts = passAttachments(pass);
        const i = atts.findIndex((a) => a.id === target.id);
        if (i >= 0) atts[i] = up.attachment;
        else atts.push(up.attachment);
      }
      try { await putPass({ ...pass, image: null }); } catch {}
      if (viewingId === pass.id) refreshViewerIfOpen();
      const keep = editorImageIndex;
      renderEditorThumbs();
      setEditorPreviewFromIndex(keep, { resetSlide: true });
      if (!quiet) toast('Image updated');
    } else {
      // Primary: keep as draft until Save (setDraftImage compresses)
      editorImageIndex = 0;
      await setDraftImage(blob, { quiet: true });
      if (!quiet) toast('Image ready');
    }
  }

  function setEditorPreviewFromIndex(index, { resetSlide = true } = {}) {
    const list = editorImages();
    const wrap = $('#image-preview-wrap');
    const img = $('#image-preview');
    const stage = $('#image-preview-stage');
    if (!list.length) {
      wrap?.classList.add('hidden');
      updateEditorPrimaryTools();
      highlightEditorThumbs();
      return;
    }
    editorImageIndex = Math.max(0, Math.min(index, list.length - 1));
    const entry = list[editorImageIndex];
    if (resetSlide) {
      hideEditorSlidePeer();
      edSlideOffset = 0;
      edSlideAnimating = false;
      if (img) {
        img.style.transition = '';
        img.style.transform = '';
      }
      if (stage) stage.classList.remove('is-sliding');
    }
    if (img && entry?.url) {
      img.src = entry.url;
      wrap?.classList.remove('hidden');
    } else {
      wrap?.classList.add('hidden');
    }
    updateEditorPrimaryTools();
    highlightEditorThumbs();
  }

  function highlightEditorThumbs() {
    const strip = $('#editor-thumbs');
    if (!strip) return;
    const list = editorImages();
    const cur = list[editorImageIndex];
    strip.querySelectorAll('.editor-thumb[data-editor-index]').forEach((el) => {
      const i = Number(el.getAttribute('data-editor-index'));
      el.classList.toggle('is-active', i === editorImageIndex);
    });
    // Scroll active thumb into view
    const active = strip.querySelector('.editor-thumb.is-active');
    if (active && typeof active.scrollIntoView === 'function') {
      try {
        active.scrollIntoView({ inline: 'nearest', block: 'nearest', behavior: 'smooth' });
      } catch {}
    }
  }

  function bindEditorPreviewSlide() {
    if (edSlideBound) return;
    const stage = $('#image-preview-stage');
    if (!stage) return;
    edSlideBound = true;

    stage.addEventListener('pointerdown', (e) => {
      const wrap = $('#image-preview-wrap');
      if (!wrap || wrap.classList.contains('hidden')) return;
      if (edSlideAnimating) return;
      if (editorImages().length < 2) return;
      // Ignore presses on controls inside wrap (none on stage)
      stage.setPointerCapture(e.pointerId);
      edSwipeStartX = e.clientX;
      edSwipeStartY = e.clientY;
      edSwipeTracking = true;
      edSwipeMoved = false;
    });

    stage.addEventListener('pointermove', (e) => {
      if (!edSwipeTracking) return;
      const dx = e.clientX - edSwipeStartX;
      const dy = e.clientY - edSwipeStartY;
      if (Math.hypot(dx, dy) > 10) edSwipeMoved = true;
      if (
        edSwipeMoved &&
        Math.abs(dx) > Math.abs(dy) * 0.85 &&
        editorImages().length >= 2
      ) {
        const dir = dx < 0 ? 1 : dx > 0 ? -1 : edSlideDir;
        if (dir && ensureEditorSlidePeer(dir)) {
          edSlideFrame(dx);
        }
      }
    });

    const endPointer = (e) => {
      if (!edSwipeTracking) return;
      const dx = (e.clientX || edSwipeStartX) - edSwipeStartX;
      const dy = (e.clientY || edSwipeStartY) - edSwipeStartY;
      if (
        edSwipeMoved &&
        !edSlideAnimating &&
        Math.abs(dx) > ED_SLIDE_THRESHOLD &&
        Math.abs(dx) > Math.abs(dy) * 1.25 &&
        editorImages().length >= 2
      ) {
        edSlideDir = dx < 0 ? 1 : -1;
        if (ensureEditorSlidePeer(edSlideDir)) finishEditorSlide(true);
        else if (edSlideOffset !== 0 || edSlidePeerReady) finishEditorSlide(false);
      } else if (edSlideOffset !== 0 && !edSlideAnimating) {
        finishEditorSlide(false);
      }
      edSwipeTracking = false;
    };
    stage.addEventListener('pointerup', endPointer);
    stage.addEventListener('pointercancel', endPointer);

    stage.addEventListener(
      'touchmove',
      (e) => {
        if (edSwipeTracking && edSwipeMoved && edSlideOffset !== 0) {
          e.preventDefault();
        }
      },
      { passive: false }
    );
  }

  function renderEditorThumbs() {
    const strip = $('#editor-thumbs');
    if (!strip) return;
    strip.innerHTML = '';
    const pass = editingId ? passes.find((p) => p.id === editingId) : null;
    const list = editorImages();

    const canAdd =
      !!pass &&
      (!!pass.imageUrl || !!pass.image || !!draftImage) &&
      passAttachments(pass).length < MAX_ATTACHMENTS;

    if (!list.length && !pass) {
      strip.classList.add('hidden');
      return;
    }
    if (!list.length && !canAdd) {
      strip.classList.add('hidden');
      return;
    }
    strip.classList.remove('hidden');

    if (editorImageIndex >= list.length) {
      editorImageIndex = Math.max(0, list.length - 1);
    }

    list.forEach((entry, i) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className =
        'editor-thumb' +
        (entry.kind === 'primary' ? ' is-primary' : '') +
        (i === editorImageIndex ? ' is-active' : '');
      btn.setAttribute('data-editor-index', String(i));
      btn.setAttribute(
        'aria-label',
        entry.kind === 'primary' ? 'Main image' : 'Attachment'
      );
      const im = document.createElement('img');
      im.src = entry.url || '';
      im.alt = '';
      btn.appendChild(im);
      if (entry.kind === 'primary') {
        const badge = document.createElement('span');
        badge.className = 'editor-thumb-badge';
        badge.textContent = 'Main';
        btn.appendChild(badge);
        // No × on main — Clear/replace via primary image tools only
      } else {
        const x = document.createElement('button');
        x.type = 'button';
        x.className = 'editor-thumb-x';
        x.setAttribute('aria-label', 'Remove image');
        x.textContent = '×';
        x.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          removeEditorAttachment(entry.id);
        });
        btn.appendChild(x);
      }
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        // Thumb tap slides large preview to this image (does not delete)
        animateToEditorIndex(i);
      });
      strip.appendChild(btn);
    });

    const plus = document.createElement('button');
    plus.type = 'button';
    plus.className = 'editor-thumb editor-thumb-plus';
    plus.setAttribute('aria-label', 'Add image');
    plus.textContent = '+';
    if (!canAdd) {
      plus.classList.add('is-disabled');
      plus.disabled = true;
      if (!pass) plus.title = 'Save the coin first';
      else if (passAttachments(pass).length >= MAX_ATTACHMENTS) {
        plus.title = 'Max ' + (MAX_ATTACHMENTS + 1) + ' images';
      } else {
        plus.title = 'Add a main image first';
      }
    } else {
      plus.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        openAttachSheet();
      });
    }
    strip.appendChild(plus);
  }


  function isCoarsePointerDevice() {
    try {
      if (window.matchMedia && window.matchMedia('(hover: none) and (pointer: coarse)').matches) {
        return true;
      }
    } catch {}
    return /iPhone|iPad|iPod/i.test(navigator.userAgent || '');
  }

  /** Blur inputs/textareas/contenteditable so iOS does not show Paste|Scan Text. */
  function blurActiveEditable() {
    const el = document.activeElement;
    if (!el || el === document.body || el === document.documentElement) return;
    const tag = (el.tagName || '').toLowerCase();
    if (tag === 'input' || tag === 'textarea' || el.isContentEditable) {
      try { el.blur(); } catch {}
    }
  }

  function isLikelyClipboardImage(type) {
    const t = (type || '').toLowerCase();
    // Safari often sends empty MIME or application/octet-stream for screenshots
    return !t || t.startsWith('image/') || t === 'application/octet-stream';
  }

  async function readClipboardImageBlob() {
    if (!(navigator.clipboard && navigator.clipboard.read)) {
      throw new Error('Clipboard API unavailable');
    }
    // Must be the first await in the click gesture — do not await blur/timers first.
    const items = await navigator.clipboard.read();
    let fallback = null;
    for (const item of items) {
      const types = item.types || [];
      const imageType = types.find((t) => (t || '').toLowerCase().startsWith('image/'));
      if (imageType) {
        const blob = await item.getType(imageType);
        if (blob && blob.size > 0) return blob;
      }
      for (const type of types) {
        const t = (type || '').toLowerCase();
        if (t.startsWith('text/')) continue;
        if (!isLikelyClipboardImage(t)) continue;
        try {
          const blob = await item.getType(type);
          if (blob && blob.size > 0 && !fallback) fallback = blob;
        } catch {}
      }
    }
    return fallback;
  }

  function clipboardReadErrorMessage(err) {
    const name = err && err.name ? String(err.name) : '';
    const msg = err && err.message ? String(err.message) : '';
    if (name === 'NotAllowedError' || /not allowed|permission|denied/i.test(msg)) {
      return 'Clipboard permission denied — tap Paste again and allow paste';
    }
    if (/unavailable|undefined|not a function/i.test(msg)) {
      return 'Clipboard not available here — use Choose file or Camera';
    }
    return 'Could not read clipboard — copy a screenshot and tap Paste again';
  }

  /**
   * Wire Paste so pointerdown blurs any focused field (kills Paste|Scan Text)
   * before click runs clipboard.read(). Never preventDefault on touchstart —
   * that suppresses click on iOS Safari.
   */
  function bindPasteButton(btn, handler) {
    if (!btn) return;
    btn.addEventListener('pointerdown', () => {
      blurActiveEditable();
    });
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      blurActiveEditable();
      // clipboard.read must stay in this synchronous gesture turn
      handler(e);
    });
  }

  async function pasteAttachmentImage() {
    // Clipboard API only — never focus editable or execCommand('paste').
    // Cross-origin screenshots: WebKit may show its own Allow Paste callout;
    // that is required by Safari and is not the text-field Paste|Scan Text menu.
    blurActiveEditable();
    try {
      const blob = await readClipboardImageBlob();
      if (blob) {
        await addAttachmentFromBlob(blob);
        return;
      }
      toast('No image on clipboard');
    } catch (e) {
      console.warn('clipboard.read failed', e);
      toast(clipboardReadErrorMessage(e));
    }
  }

  // ---------- Clipboard paste ----------
  async function pasteImage() {
    // Clipboard API only — never focus editable or execCommand('paste').
    // Cross-origin screenshots: WebKit may show its own Allow Paste callout;
    // that is required by Safari and is not the text-field Paste|Scan Text menu.
    blurActiveEditable();
    try {
      const blob = await readClipboardImageBlob();
      if (blob) {
        await setDraftImage(blob);
        return;
      }
      toast('No image on clipboard');
    } catch (e) {
      console.warn('clipboard.read failed', e);
      toast(clipboardReadErrorMessage(e));
    }
  }


  // ---------- Crop & rotate ----------
  const crop = {
    url: null,
    workingBlob: null,
    // image natural size
    imgW: 0,
    imgH: 0,
    // image transform in stage coords (top-left origin)
    scale: 1,
    minScale: 1,
    tx: 0,
    ty: 0,
    // selection box in stage coords
    box: { x: 0, y: 0, w: 0, h: 0 },
    // gesture
    mode: null, // 'pan' | 'move' | 'n'|'s'|'e'|'w'|'nw'|'ne'|'sw'|'se' | 'pinch'
    pointers: new Map(),
    lastDist: 0,
    lastMidX: 0,
    lastMidY: 0,
    startX: 0,
    startY: 0,
    startBox: null,
    startTx: 0,
    startTy: 0,
    startScale: 1,
    bound: false,
  };

  const MIN_BOX = 48;

  function stageRect() {
    return $('#cropper-stage').getBoundingClientRect();
  }

  function applyImageTransform() {
    const img = $('#cropper-image');
    if (!img) return;
    img.style.width = crop.imgW + 'px';
    img.style.height = crop.imgH + 'px';
    img.style.transform =
      'translate(' + crop.tx + 'px,' + crop.ty + 'px) scale(' + crop.scale + ')';
  }

  function applyBox() {
    const box = $('#cropper-box');
    const shade = $('#cropper-shade');
    if (!box) return;
    const b = crop.box;
    box.style.left = b.x + 'px';
    box.style.top = b.y + 'px';
    box.style.width = b.w + 'px';
    box.style.height = b.h + 'px';
    if (shade) {
      // Punch a hole in the dim overlay for the selection
      const s = stageRect();
      const x = b.x, y = b.y, w = b.w, h = b.h;
      shade.style.clipPath =
        `polygon(0% 0%, 100% 0%, 100% 100%, 0% 100%, 0% 0%, ${x}px ${y}px, ${x}px ${y + h}px, ${x + w}px ${y + h}px, ${x + w}px ${y}px, ${x}px ${y}px)`;
    }
  }

  function clampBoxToStage() {
    const stage = $('#cropper-stage');
    const sw = stage.clientWidth;
    const sh = stage.clientHeight;
    const b = crop.box;
    b.w = Math.max(MIN_BOX, Math.min(b.w, sw));
    b.h = Math.max(MIN_BOX, Math.min(b.h, sh));
    b.x = Math.min(Math.max(0, b.x), sw - b.w);
    b.y = Math.min(Math.max(0, b.y), sh - b.h);
  }

  function imageBoundsOnStage() {
    return {
      x: crop.tx,
      y: crop.ty,
      w: crop.imgW * crop.scale,
      h: crop.imgH * crop.scale,
    };
  }

  function fitImageToStage() {
    const stage = $('#cropper-stage');
    const sw = stage.clientWidth;
    const sh = stage.clientHeight;
    const contain = Math.min(sw / crop.imgW, sh / crop.imgH);
    crop.minScale = contain * 0.5;
    crop.scale = contain;
    crop.tx = (sw - crop.imgW * crop.scale) / 2;
    crop.ty = (sh - crop.imgH * crop.scale) / 2;
    applyImageTransform();

    // Default selection = inset over the visible image
    const ib = imageBoundsOnStage();
    const pad = 12;
    crop.box = {
      x: Math.max(0, ib.x + pad),
      y: Math.max(0, ib.y + pad),
      w: Math.max(MIN_BOX, ib.w - pad * 2),
      h: Math.max(MIN_BOX, ib.h - pad * 2),
    };
    clampBoxToStage();
    applyBox();
  }

  async function loadCropBlob(blob) {
    if (crop.url) {
      URL.revokeObjectURL(crop.url);
      crop.url = null;
    }
    crop.workingBlob = blob;
    crop.url = URL.createObjectURL(blob);
    const img = $('#cropper-image');
    await new Promise((resolve, reject) => {
      img.onload = () => resolve();
      img.onerror = () => reject(new Error('crop image load failed'));
      img.src = crop.url;
    });
    crop.imgW = img.naturalWidth;
    crop.imgH = img.naturalHeight;
    fitImageToStage();
  }

  async function openCropper() {
    const target = getEditorEditTarget();
    if (!target) {
      toast('Add an image first');
      return;
    }
    show($('#cropper'));
    try {
      const blob = await blobForEditorTarget(target);
      await loadCropBlob(blob);
    } catch (e) {
      console.error(e);
      toast('Couldn’t open cropper');
      closeCropper();
    }
  }

  function closeCropper() {
    hide($('#cropper'));
    crop.pointers.clear();
    crop.mode = null;
    if (crop.url) {
      URL.revokeObjectURL(crop.url);
      crop.url = null;
    }
    crop.workingBlob = null;
    const img = $('#cropper-image');
    if (img) img.removeAttribute('src');
  }

  function blobFromCanvas(canvas, mime = 'image/jpeg', quality = 0.9) {
    return new Promise((resolve, reject) => {
      canvas.toBlob(
        (b) => (b ? resolve(b) : reject(new Error('toBlob failed'))),
        mime,
        quality
      );
    });
  }

  /** Rotate blob 90°; dir 1 = clockwise, -1 = counter-clockwise */
  async function rotateBlob(blob, dir) {
    const bitmap = await loadImageFromBlob(blob);
    const w = bitmap.naturalWidth || bitmap.width;
    const h = bitmap.naturalHeight || bitmap.height;
    const canvas = document.createElement('canvas');
    canvas.width = h;
    canvas.height = w;
    const ctx = canvas.getContext('2d');
    if (dir === 1) {
      ctx.translate(canvas.width, 0);
      ctx.rotate(Math.PI / 2);
    } else {
      ctx.translate(0, canvas.height);
      ctx.rotate(-Math.PI / 2);
    }
    ctx.drawImage(bitmap, 0, 0);
    const preferWebp = canvas.toDataURL('image/webp').startsWith('data:image/webp');
    return blobFromCanvas(
      canvas,
      preferWebp ? 'image/webp' : 'image/jpeg',
      preferWebp ? 0.85 : JPEG_QUALITY
    );
  }

  async function rotateDraft(dir) {
    const target = getEditorEditTarget();
    if (!target) {
      toast('Add an image first');
      return;
    }
    try {
      const srcBlob = await blobForEditorTarget(target);
      const rotated = await rotateBlob(srcBlob, dir);
      await commitEditorImageBlob(rotated, { quiet: true });
      toast(dir === 1 ? 'Rotated right' : 'Rotated left');
    } catch (e) {
      console.error(e);
      toast('Rotate failed');
    }
  }

  async function rotateInCropper(dir) {
    let src = crop.workingBlob;
    if (!src) {
      try {
        src = await blobForEditorTarget(getEditorEditTarget());
      } catch {}
    }
    if (!src) return;
    try {
      const rotated = await rotateBlob(src, dir);
      await loadCropBlob(rotated);
    } catch (e) {
      console.error(e);
      toast('Rotate failed');
    }
  }

  async function applyCrop() {
    const target = getEditorEditTarget();
    if (!target && !crop.workingBlob && !draftImage) return;
    const imgEl = $('#cropper-image');
    if (!imgEl || !crop.imgW) return;

    // Map selection box → image pixel space
    let sx = (crop.box.x - crop.tx) / crop.scale;
    let sy = (crop.box.y - crop.ty) / crop.scale;
    let sw = crop.box.w / crop.scale;
    let sh = crop.box.h / crop.scale;

    if (sx < 0) { sw += sx; sx = 0; }
    if (sy < 0) { sh += sy; sy = 0; }
    if (sx + sw > crop.imgW) sw = crop.imgW - sx;
    if (sy + sh > crop.imgH) sh = crop.imgH - sy;
    if (sw < 2 || sh < 2) {
      toast('Crop area too small');
      return;
    }

    const outW = Math.min(MAX_WIDTH, Math.round(sw));
    const outH = Math.max(1, Math.round((outW * sh) / sw));
    const canvas = document.createElement('canvas');
    canvas.width = outW;
    canvas.height = outH;
    const ctx = canvas.getContext('2d');
    ctx.fillStyle = '#ffffff';
    ctx.fillRect(0, 0, outW, outH);
    ctx.drawImage(imgEl, sx, sy, sw, sh, 0, 0, outW, outH);

    try {
      const preferWebp = canvas.toDataURL('image/webp').startsWith('data:image/webp');
      const blob = await blobFromCanvas(
        canvas,
        preferWebp ? 'image/webp' : 'image/jpeg',
        preferWebp ? 0.85 : JPEG_QUALITY
      );
      closeCropper();
      await commitEditorImageBlob(blob, { quiet: true });
      toast('Crop applied');
    } catch (e) {
      console.error(e);
      toast('Crop failed');
    }
  }

  function cropPointersMid() {
    const pts = [...crop.pointers.values()];
    if (pts.length === 1) return { x: pts[0].x, y: pts[0].y };
    return { x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2 };
  }

  function cropPointersDist() {
    const pts = [...crop.pointers.values()];
    if (pts.length < 2) return 0;
    return Math.hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y);
  }

  function hitHandle(clientX, clientY) {
    const el = document.elementFromPoint(clientX, clientY);
    if (!el) return null;
    const handle = el.closest('[data-handle]');
    if (handle) return handle.getAttribute('data-handle');
    if (el.closest('#cropper-box')) return 'move';
    return 'pan';
  }

  function resizeBox(handle, dx, dy) {
    const b = { ...crop.startBox };
    const stage = $('#cropper-stage');
    const sw = stage.clientWidth;
    const sh = stage.clientHeight;

    if (handle.includes('n')) {
      const ny = Math.min(b.y + b.h - MIN_BOX, Math.max(0, b.y + dy));
      b.h -= ny - b.y;
      b.y = ny;
    }
    if (handle.includes('s')) {
      b.h = Math.min(sh - b.y, Math.max(MIN_BOX, b.h + dy));
    }
    if (handle.includes('w')) {
      const nx = Math.min(b.x + b.w - MIN_BOX, Math.max(0, b.x + dx));
      b.w -= nx - b.x;
      b.x = nx;
    }
    if (handle.includes('e')) {
      b.w = Math.min(sw - b.x, Math.max(MIN_BOX, b.w + dx));
    }
    crop.box = b;
    clampBoxToStage();
    applyBox();
  }

  function bindCropper() {
    if (crop.bound) return;
    crop.bound = true;
    const stage = $('#cropper-stage');
    if (!stage) return;

    const onTouchStart = (e) => {
      if ($('#cropper').classList.contains('hidden')) return;
      crop.pointers.clear();
      for (const t of e.touches) {
        crop.pointers.set(t.identifier, { x: t.clientX, y: t.clientY });
      }
      if (e.touches.length >= 2) {
        crop.mode = 'pinch';
        crop.lastDist = cropPointersDist();
        crop.pinchStartDist = crop.lastDist || 1;
        crop.startScale = crop.scale;
        crop.startTx = crop.tx;
        crop.startTy = crop.ty;
      } else if (e.touches.length === 1) {
        const t = e.touches[0];
        crop.mode = hitHandle(t.clientX, t.clientY);
        crop.startX = t.clientX;
        crop.startY = t.clientY;
        crop.startBox = { ...crop.box };
        crop.startTx = crop.tx;
        crop.startTy = crop.ty;
      }
    };

    const onTouchMove = (e) => {
      if ($('#cropper').classList.contains('hidden')) return;
      if (!e.touches.length) return;
      e.preventDefault();
      crop.pointers.clear();
      for (const t of e.touches) {
        crop.pointers.set(t.identifier, { x: t.clientX, y: t.clientY });
      }

      if (e.touches.length >= 2 || crop.mode === 'pinch') {
        crop.mode = 'pinch';
        const dist = cropPointersDist();
        if (!crop.pinchStartDist) crop.pinchStartDist = dist || 1;
        const totalFactor = dist / crop.pinchStartDist;
        const newScale = Math.min(8, Math.max(crop.minScale, crop.startScale * totalFactor));
        const mid = cropPointersMid();
        const stageR = stageRect();
        const mx = mid.x - stageR.left;
        const my = mid.y - stageR.top;
        const imgX = (mx - crop.startTx) / crop.startScale;
        const imgY = (my - crop.startTy) / crop.startScale;
        crop.scale = newScale;
        crop.tx = mx - imgX * crop.scale;
        crop.ty = my - imgY * crop.scale;
        applyImageTransform();
        return;
      }

      const t = e.touches[0];
      const dx = t.clientX - crop.startX;
      const dy = t.clientY - crop.startY;

      if (crop.mode === 'pan') {
        crop.tx = crop.startTx + dx;
        crop.ty = crop.startTy + dy;
        applyImageTransform();
      } else if (crop.mode === 'move') {
        crop.box = {
          x: crop.startBox.x + dx,
          y: crop.startBox.y + dy,
          w: crop.startBox.w,
          h: crop.startBox.h,
        };
        clampBoxToStage();
        applyBox();
      } else if (crop.mode && crop.mode !== 'pinch') {
        resizeBox(crop.mode, dx, dy);
      }
    };

    const onTouchEnd = (e) => {
      crop.pointers.clear();
      for (const t of e.touches) {
        crop.pointers.set(t.identifier, { x: t.clientX, y: t.clientY });
      }
      if (e.touches.length === 0) {
        crop.mode = null;
        crop.pinchStartDist = 0;
      } else if (e.touches.length === 1) {
        const t = e.touches[0];
        crop.mode = 'pan';
        crop.startX = t.clientX;
        crop.startY = t.clientY;
        crop.startTx = crop.tx;
        crop.startTy = crop.ty;
        crop.startBox = { ...crop.box };
        crop.pinchStartDist = 0;
      } else {
        crop.mode = 'pinch';
        crop.lastDist = cropPointersDist();
        crop.pinchStartDist = crop.lastDist;
        crop.startScale = crop.scale;
        crop.startTx = crop.tx;
        crop.startTy = crop.ty;
      }
    };

    stage.addEventListener('touchstart', onTouchStart, { passive: true });
    stage.addEventListener('touchmove', onTouchMove, { passive: false });
    stage.addEventListener('touchend', onTouchEnd);
    stage.addEventListener('touchcancel', onTouchEnd);

    // Mouse support for desktop
    stage.addEventListener('pointerdown', (e) => {
      if ($('#cropper').classList.contains('hidden')) return;
      if (e.pointerType === 'touch') return;
      if (e.button != null && e.button !== 0) return;
      stage.setPointerCapture(e.pointerId);
      crop.mode = hitHandle(e.clientX, e.clientY);
      crop.startX = e.clientX;
      crop.startY = e.clientY;
      crop.startBox = { ...crop.box };
      crop.startTx = crop.tx;
      crop.startTy = crop.ty;
    });
    stage.addEventListener('pointermove', (e) => {
      if (e.pointerType === 'touch') return;
      if (!crop.mode) return;
      e.preventDefault();
      const dx = e.clientX - crop.startX;
      const dy = e.clientY - crop.startY;
      if (crop.mode === 'pan') {
        crop.tx = crop.startTx + dx;
        crop.ty = crop.startTy + dy;
        applyImageTransform();
      } else if (crop.mode === 'move') {
        crop.box = {
          x: crop.startBox.x + dx,
          y: crop.startBox.y + dy,
          w: crop.startBox.w,
          h: crop.startBox.h,
        };
        clampBoxToStage();
        applyBox();
      } else {
        resizeBox(crop.mode, dx, dy);
      }
    });
    const endPtr = (e) => {
      if (e.pointerType === 'touch') return;
      crop.mode = null;
    };
    stage.addEventListener('pointerup', endPtr);
    stage.addEventListener('pointercancel', endPtr);

    stage.addEventListener(
      'wheel',
      (e) => {
        if ($('#cropper').classList.contains('hidden')) return;
        e.preventDefault();
        const stageR = stageRect();
        const mx = e.clientX - stageR.left;
        const my = e.clientY - stageR.top;
        const factor = e.deltaY > 0 ? 0.92 : 1.08;
        const next = Math.min(8, Math.max(crop.minScale, crop.scale * factor));
        const imgX = (mx - crop.tx) / crop.scale;
        const imgY = (my - crop.ty) / crop.scale;
        crop.scale = next;
        crop.tx = mx - imgX * crop.scale;
        crop.ty = my - imgY * crop.scale;
        applyImageTransform();
      },
      { passive: false }
    );

    window.addEventListener('resize', () => {
      if (!$('#cropper').classList.contains('hidden') && crop.imgW) {
        fitImageToStage();
      }
    });
  }

  // ---------- Events ----------
  function bindEvents() {
    bindEditorPreviewSlide();
    $('#btn-add').addEventListener('click', () => openEditor(null));
    $('#btn-empty-add').addEventListener('click', () => openEditor(null));
    $('#btn-editor-cancel').addEventListener('click', closeEditor);
    $('#editor-backdrop').addEventListener('click', closeEditor);
    $('#btn-editor-save').addEventListener('click', (e) => {
      e.preventDefault();
      saveEditor();
    });
    $('#accent-picker')?.addEventListener('click', (e) => {
      const swatch = e.target.closest('.accent-swatch');
      if (swatch) setEditorAccent(Number(swatch.dataset.accent));
    });
    $('#editor-form').addEventListener('submit', (e) => {
      e.preventDefault();
      saveEditor();
    });

    $('#field-file').addEventListener('change', async (e) => {
      const f = e.target.files?.[0];
      if (f) await setDraftImage(f);
    });
    $('#field-camera').addEventListener('change', async (e) => {
      const f = e.target.files?.[0];
      if (f) await setDraftImage(f);
    });
    bindPasteButton($('#btn-paste'), () => { pasteImage(); });

    $('#btn-crop-image')?.addEventListener('click', () => openCropper());
    $('#btn-crop-cancel')?.addEventListener('click', () => closeCropper());
    $('#btn-crop-apply')?.addEventListener('click', () => applyCrop());
    $('#btn-crop-rotate-cw')?.addEventListener('click', () => rotateInCropper(1));
    $('#btn-crop-rotate-ccw')?.addEventListener('click', () => rotateInCropper(-1));
    $('#btn-rotate-cw')?.addEventListener('click', () => rotateDraft(1));
    $('#btn-rotate-ccw')?.addEventListener('click', () => rotateDraft(-1));
    bindCropper();

    $('#btn-clear-image').addEventListener('click', () => {
      // Clears/replaces the primary face draft only — never deletes the coin
      // or attachments. Preview blanks until a new file is chosen (or a thumb
      // is tapped to preview an existing image again).
      clearDraftImage();
      $('#field-file').value = '';
      $('#field-camera').value = '';
    });

    // Paste into editor or as viewer attachment (keyboard / iOS)
    document.addEventListener('paste', async (e) => {
      const items = e.clipboardData?.items;
      if (!items || !items.length) return;
      const attachOpen = $('#attach-sheet') && !$('#attach-sheet').classList.contains('hidden');
      const editorOpen = $('#editor') && !$('#editor').classList.contains('hidden');
      let imageBlob = null;
      for (const item of items) {
        const t = (item.type || '').toLowerCase();
        // iOS often reports "" or application/octet-stream for screenshot pastes
        if (t.startsWith('image/') || t === 'application/octet-stream' || t === '') {
          const blob = item.getAsFile();
          if (blob && (blob.size > 0) && (!blob.type || blob.type.startsWith('image/') || blob.type === 'application/octet-stream' || !blob.type)) {
            // Prefer explicit image/* when several items exist
            if (t.startsWith('image/') || !imageBlob) imageBlob = blob;
            if (t.startsWith('image/')) break;
          }
        }
      }
      if (!imageBlob) return;
      if (editorOpen) {
        e.preventDefault();
        await setDraftImage(imageBlob);
        return;
      }
      if (attachOpen) {
        e.preventDefault();
        await addAttachmentFromBlob(imageBlob);
      }
    });

    $('#btn-viewer-back').addEventListener('click', () => dismissViewer());

    // Also dismiss when tapping empty viewer chrome outside the image wrap (title row stays put)
    $('#viewer').addEventListener('click', (e) => {
      if (e.target === $('#viewer') || e.target === $('#viewer-body') || e.target?.classList?.contains('viewer-body') || e.target?.id === 'viewer-zoom-hint') {
        if (zoomState.scale <= 1.05) dismissViewer();
      }
    });

    $('#btn-edit').addEventListener('click', () => {
      if (viewingId) openEditor(viewingId);
    });
    $('#btn-delete').addEventListener('click', doDelete);

    $('#btn-remove-attachment')?.addEventListener('click', (e) => {
      e.stopPropagation();
      removeActiveAttachment();
    });
    $('#attach-sheet-backdrop')?.addEventListener('click', () => closeAttachSheet());
    $('#btn-attach-cancel')?.addEventListener('click', () => closeAttachSheet());
    bindPasteButton($('#btn-attach-paste'), () => { pasteAttachmentImage(); });
    $('#attach-file')?.addEventListener('change', async (e) => {
      const file = e.target.files && e.target.files[0];
      if (file) await addAttachmentFromBlob(file);
    });
    $('#attach-camera')?.addEventListener('change', async (e) => {
      const file = e.target.files && e.target.files[0];
      if (file) await addAttachmentFromBlob(file);
    });

    $('#btn-confirm-cancel').addEventListener('click', () => closeConfirm(false));
    $('#confirm-backdrop').addEventListener('click', () => closeConfirm(false));
    $('#btn-confirm-ok').addEventListener('click', () => closeConfirm(true));

    window.addEventListener('popstate', () => {
      if (!$('#viewer').classList.contains('hidden')) {
        closeViewer();
        renderStack();
      }
    });
  }

  // ---------- SW ----------
  function registerSW() {
    if (!('serviceWorker' in navigator)) return;
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('./sw.js').catch((err) => {
        console.warn('SW register failed', err);
      });
    });
  }


  let pendingSetupToken = null;
  let pendingEmail = null;
    pendingEmail = null;
  let pinMode = 'setup'; // 'setup' | 'unlock'

  function showUnlockScreen() {
    const screen = $('#unlock-screen');
    if (!screen) return;
    screen.classList.remove('hidden');
    screen.setAttribute('aria-hidden', 'false');
    document.body.classList.add('is-locked');
  }

  function hideUnlockScreen() {
    const screen = $('#unlock-screen');
    if (!screen) return;
    screen.classList.add('hidden');
    screen.setAttribute('aria-hidden', 'true');
    document.body.classList.remove('is-locked');
  }

  function setUnlockError(msg) {
    const err = $('#unlock-error');
    if (!err) return;
    if (msg) {
      err.textContent = msg;
      err.classList.remove('hidden');
    } else {
      err.textContent = '';
      err.classList.add('hidden');
    }
  }

  function setUnlockStatus(msg) {
    const el = $('#unlock-status');
    if (!el) return;
    if (msg) {
      el.textContent = msg;
      el.classList.remove('hidden');
    } else {
      el.textContent = '';
      el.classList.add('hidden');
    }
  }

  function showEmailStep() {
    pendingSetupToken = null;
    pendingEmail = null;
    $('#email-form')?.classList.remove('hidden');
    $('#code-form')?.classList.add('hidden');
    $('#pin-form')?.classList.add('hidden');
    $('#btn-auth-reset')?.classList.add('hidden');
    $('#unlock-copy').textContent =
      "Sign in with email. We'll send a 6-digit code, then you set a PIN once on this device.";
    setUnlockStatus('');
    setUnlockError('');
    showUnlockScreen();
    setTimeout(() => $('#unlock-email')?.focus(), 50);
  }

  function showCodeStep(email) {
    pendingEmail = email;
    $('#email-form')?.classList.add('hidden');
    $('#code-form')?.classList.remove('hidden');
    $('#pin-form')?.classList.add('hidden');
    $('#btn-auth-reset')?.classList.remove('hidden');
    $('#unlock-copy').textContent =
      'Enter the 6-digit code we emailed to ' + email + '.';
    setUnlockStatus('Code expires in 15 minutes. You do not need to remember it after this.');
    setUnlockError('');
    if ($('#unlock-code')) $('#unlock-code').value = '';
    showUnlockScreen();
    setTimeout(() => $('#unlock-code')?.focus(), 50);
  }

  function showPinStep({ setupToken, needsPinSetup, email }) {
    pendingSetupToken = setupToken;
    pinMode = needsPinSetup ? 'setup' : 'unlock';
    $('#email-form')?.classList.add('hidden');
    $('#code-form')?.classList.add('hidden');
    $('#pin-form')?.classList.remove('hidden');
    $('#btn-auth-reset')?.classList.remove('hidden');
    $('#unlock-copy').textContent = needsPinSetup
      ? ('Choose a PIN for ' + email + '. This device will remember you.')
      : ('Welcome back, ' + email + '. Enter your PIN once on this device.');
    $('#btn-unlock').textContent = needsPinSetup ? 'Create PIN' : 'Unlock';
    setUnlockStatus('');
    setUnlockError('');
    showUnlockScreen();
    setTimeout(() => $('#unlock-pin')?.focus(), 50);
  }

  async function requestMagicLink(email) {
    const res = await fetch('/api/auth/request-link', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'Could not send email');
    return data;
  }

  async function verifyMagicToken(token) {
    const res = await fetch('/api/auth/verify-link', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'Link expired or invalid');
    return data;
  }

  async function verifySignInCode(email, code) {
    const res = await fetch('/api/auth/verify-code', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, code }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'Wrong or expired code');
    return data;
  }

  async function submitPin(pin) {
    const path = pinMode === 'setup' ? '/api/auth/set-pin' : '/api/auth/unlock';
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ setupToken: pendingSetupToken, pin }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'PIN failed');
    if (!data.token) throw new Error('No session returned');
    setSessionToken(data.token);
    return data;
  }

  function consumeAuthHash() {
    const hash = location.hash || '';
    const m = hash.match(/[#&?]auth=([^&]+)/);
    if (!m) return null;
    const token = decodeURIComponent(m[1]);
    history.replaceState(null, '', location.pathname + location.search);
    return token;
  }

  function bindUnlock() {
    const emailForm = $('#email-form');
    if (emailForm && emailForm.dataset.bound !== '1') {
      emailForm.dataset.bound = '1';
      emailForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const email = $('#unlock-email').value.trim();
        const btn = $('#btn-email');
        btn.disabled = true;
        setUnlockError('');
        try {
          await requestMagicLink(email);
          showCodeStep(email);
        } catch (err) {
          setUnlockError(err.message || 'Could not send email');
        } finally {
          btn.disabled = false;
        }
      });
    }

    const codeForm = $('#code-form');
    if (codeForm && codeForm.dataset.bound !== '1') {
      codeForm.dataset.bound = '1';
      codeForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const code = ($('#unlock-code')?.value || '').trim();
        const email = pendingEmail || ($('#unlock-email')?.value || '').trim();
        const btn = $('#btn-code');
        if (btn) btn.disabled = true;
        setUnlockError('');
        try {
          const data = await verifySignInCode(email, code);
          showPinStep({
            setupToken: data.setupToken,
            needsPinSetup: !!data.needsPinSetup,
            email: data.email || email,
          });
        } catch (err) {
          setUnlockError(err.message || 'Wrong code');
          $('#unlock-code')?.select();
        } finally {
          if (btn) btn.disabled = false;
        }
      });
    }

    const pinForm = $('#pin-form');
    if (pinForm && pinForm.dataset.bound !== '1') {
      pinForm.dataset.bound = '1';
      pinForm.addEventListener('submit', async (e) => {
        e.preventDefault();
        const pin = $('#unlock-pin').value;
        const btn = $('#btn-unlock');
        btn.disabled = true;
        setUnlockError('');
        try {
          await submitPin(pin);
          $('#unlock-pin').value = '';
          hideUnlockScreen();
          await bootPurse();
        } catch (err) {
          setUnlockError(err.message || 'Wrong PIN');
          $('#unlock-pin').select();
        } finally {
          btn.disabled = false;
        }
      });
    }

    const reset = $('#btn-auth-reset');
    if (reset && reset.dataset.bound !== '1') {
      reset.dataset.bound = '1';
      reset.addEventListener('click', () => showEmailStep());
    }
  }

  async function bootPurse() {
    try {
      db = await openDb();
    } catch (e) {
      console.warn('IDB unavailable', e);
      db = null;
    }

    try {
      // Cloud index (post-tombstone filter) is the intentional saved set.
      passes = sortPassesByOrder(await fetchCloudCoins());
      for (const p of passes) ensureAccent(p);
      await rebalanceAccents();
      // Cloud is source of truth: replace IDB so hard refresh / SW update /
      // offline fallback cannot resurrect drafts or deleted coins.
      try { await replaceLocalPasses(passes); } catch (err) {
        console.warn('IDB mirror failed', err);
      }
      passRing = passes.map((p) => p.id);
      syncPassRing();
      if (passes.length) {
        expandedId = passes[0].id;
        frontIndex = 0;
      }
      renderStack();
    } catch (e) {
      console.error(e);
      const msg = String(e.message || '');
      if (msg.includes('Unauthorized') || msg.includes('401')) {
        clearSessionToken();
        showEmailStep();
        setUnlockError('Session expired — sign in again');
        return;
      }
      try {
        if (db) passes = await getAllPasses();
      } catch {}
      passes = sortPassesByOrder(passes);
      for (const p of passes) ensureAccent(p);
      passRing = passes.map((p) => p.id);
      syncPassRing();
      if (passes.length) {
        expandedId = passes[0].id;
        frontIndex = 0;
      }
      toast('Cloud unavailable — showing local cache');
      renderStack();
    }
  }

  async function init() {
    bindEvents();
    bindUnlock();
    registerSW();

    const magic = consumeAuthHash();
    if (magic) {
      showUnlockScreen();
      setUnlockStatus('Confirming your email…');
      try {
        const data = await verifyMagicToken(magic);
        showPinStep({
          setupToken: data.setupToken,
          needsPinSetup: !!data.needsPinSetup,
          email: data.email,
        });
      } catch (err) {
        showEmailStep();
        setUnlockError(err.message || 'Link expired — request a new one');
      }
      return;
    }

    if (!getSessionToken()) {
      showEmailStep();
      return;
    }
    hideUnlockScreen();
    await bootPurse();
  }

  init();
})();
