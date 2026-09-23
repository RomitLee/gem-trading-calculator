const CACHE_NAME = 'gem-calculator-v24';
const APP_SHELL = [
  './index.html',
  './GemTradingCalculator.webmanifest',
  './icons/gem-calculator-icon-180.png',
  './icons/gem-calculator-icon-192.png',
  './icons/gem-calculator-icon-512.png',
  './icons/gem-normal.png',
  './icons/gem-star.png',
  './icons/gem-dust.png',
  './icons/app-logo.png'
];
const OFFLINE_PAGE = new URL('./index.html', self.location.href).href;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(CACHE_NAME).then(cache => cache.addAll(APP_SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === 'navigate') {
    event.respondWith((async () => {
      try {
        const response = await fetch(request);
        if (response.ok) {
          const cache = await caches.open(CACHE_NAME);
          await cache.put(OFFLINE_PAGE, response.clone());
        }
        return response;
      } catch {
        return (await caches.match(request, { ignoreSearch: true })) || caches.match(OFFLINE_PAGE);
      }
    })());
    return;
  }

  event.respondWith((async () => {
    const cached = await caches.match(request, { ignoreSearch: true });
    if (cached) return cached;

    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      await cache.put(request, response.clone());
    }
    return response;
  })());
});
