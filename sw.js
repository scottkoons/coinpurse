/* The Coin Purse web app is retired; Coin Purse is now an iPhone app.
   This worker replaces the old one, clears its caches and removes itself,
   so phones that had the web app installed load the new information page. */
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) await caches.delete(key);
    await self.registration.unregister();
    const clients = await self.clients.matchAll({ type: 'window' });
    clients.forEach((c) => c.navigate(c.url));
  })());
});
