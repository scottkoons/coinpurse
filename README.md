# CoinPurse

Phone-first PWA for Scott: a wallet-like stack of temporary passes — conference QR screenshots, haircut cards, loyalty barcodes, etc.

**Not for secrets.** Data never leaves the device. No login, no sync, no Apple Wallet signing.

## Features

- Vertical wallet-style card stack (tap to expand / bring forward, tap again for full screen)
- Add pass: required title, optional notes, optional image (file, camera, or clipboard paste)
- Full-screen viewer optimized for scanning QRs
- Edit & delete (delete asks for confirmation)
- IndexedDB storage (images as blobs), compressed before save (~1200px, JPEG/WebP)
- Installable PWA with offline shell (saved cards work offline)

## Local preview

From this folder:

```bash
cd /workspace/qr-locker
npx --yes serve -l 4173
```

Then open `http://localhost:4173` (or the URL `serve` prints).

Any static server works (`python3 -m http.server 4173`, etc.). Prefer HTTPS or localhost so clipboard paste and camera work as expected.

## Add to Home Screen (iPhone)

1. Open the site in **Safari** (not Chrome/in-app browsers).
2. Tap the **Share** button.
3. Tap **Add to Home Screen**.
4. Confirm the name (**CoinPurse**) and tap **Add**.

The app opens fullscreen. Passes you save live in Safari’s IndexedDB for that origin on **this iPhone**. Clearing website data or removing the home-screen app can wipe them.

## Data is device-local

- Everything is stored in **IndexedDB** in your browser / PWA container.
- Images are resized and compressed client-side before save.
- There is **no backend**, auth, or cloud backup. Moving phones means re-adding passes (or exporting later if you build that yourself).

## Deploy (Vercel)

```bash
cd /workspace/qr-locker
npx vercel@latest --yes --prod
```

Log in with `npx vercel login` first if auth fails.

## Project layout

```
qr-locker/
  index.html
  styles.css
  app.js
  sw.js
  manifest.webmanifest
  icons/icon-180.png
  icons/icon-192.png
  icons/icon-512.png
  README.md
  generate-icons.mjs   # optional; icons already generated
```
