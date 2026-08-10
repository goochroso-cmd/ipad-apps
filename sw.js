// ipad-apps 共通 Service Worker
// さいせい君・まるち君・ポータルの3つをまとめてオフラインキャッシュします。
// ※ アプリごとに sw.js を分けると同じスコープで競合し、片方しか動かなくなるため
//    意図的に「1つの共通 sw.js」に統合しています。

const CACHE_NAME = 'ipad-apps-cache-v7';

const ASSETS = [
  './',
  './index.html',
  './さいせい君_standalone.html',
  './まるち君_standalone.html',
  './さいせい君_standalone_改良版.html',
  './まるち君_standalone_改良版.html',
  './saisei-manifest.json',
  './maruchi-manifest.json',
  './saisei-manifest-改良版.json',
  './maruchi-manifest-改良版.json',
  './saisei-icon.png',
  './maruchi-icon.png'
];

// install: 1件ずつ入れる。1つ失敗しても install 全体は止めない
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(
        ASSETS.map((url) =>
          cache.add(new Request(url, { cache: 'reload' })).catch((err) => {
            console.warn('[sw] キャッシュ失敗:', url, err);
          })
        )
      )
    )
  );
  self.skipWaiting();
});

// activate: 古いキャッシュを掃除
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.map((key) => (key !== CACHE_NAME ? caches.delete(key) : null)))
    )
  );
  self.clients.claim();
});

// fetch: Stale-While-Revalidate（キャッシュを即返し、裏で更新）
self.addEventListener('fetch', (event) => {
  const req = event.request;

  if (req.method !== 'GET') return;
  if (!req.url.startsWith(self.location.origin)) return;

  event.respondWith(
    caches.match(req).then((cached) => {
      const network = fetch(req)
        .then((res) => {
          if (res && res.status === 200 && res.type === 'basic') {
            const copy = res.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
          }
          return res;
        })
        .catch(() => cached);

      return cached || network;
    })
  );
});
