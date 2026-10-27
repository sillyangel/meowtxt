const CACHE_NAME = 'meowtxt-shell-v3';
const SHELL_ASSETS = [
  '/',
  '/index.html',
  '/style.css',
  '/app.js',
  '/modules/state.js',
  '/modules/utils.js',
  '/modules/api.js',
  '/modules/ui.js',
  '/modules/actions.js',
  '/modules/notifications.js',
  '/modules/settings.js',
  '/manifest.webmanifest',
  '/icon.svg',
  '/icon-maskable.svg',
  '/icon-192.png',
  '/icon-512.png',
  '/favicon.svg',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.pathname.startsWith('/api/') || event.request.method !== 'GET') {
    return;
  }
  event.respondWith(
    fetch(event.request)
      .then((res) => {
        if (res && res.status === 200) {
          const clone = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = { title: 'meowtxt', body: event.data ? event.data.text() : 'New iMessage activity' };
  }
  const title = payload.title || 'meowtxt';
  const options = {
    body: payload.body || '',
    icon: payload.icon || '/icon-192.png',
    badge: '/icon-192.png',
    tag: payload.tag || payload.id || 'meowtxt-notification',
    data: {
      chat: payload.chat || null,
      guid: payload.message?.guid || null,
      type: payload.type || 'received',
    },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetChat = event.notification.data?.chat || null;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if ('focus' in client) {
          client.focus();
          if (targetChat) {
            client.postMessage({ type: 'meow:open-chat', chat: targetChat });
          }
          return;
        }
      }
      if (self.clients.openWindow) {
        const url = targetChat ? `/?chat=${encodeURIComponent(targetChat)}` : '/';
        return self.clients.openWindow(url);
      }
    })
  );
});
