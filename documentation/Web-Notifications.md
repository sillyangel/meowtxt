# Web, Push & Webhook Notifications (`meowtxt`)

`meowtxt` includes a built-in real-time notification engine that pushes alerts when iMessages are:
- **`received`** — A new incoming iMessage arrives
- **`sent`** — An outbound iMessage is sent from the web app, API, or iPhone
- **`delivered`** — An outbound iMessage transitions to delivered (`date_delivered > 0`)
- **`read`** — A recipient reads your outbound iMessage (`date_read > 0`)

---

## 1. How Notifications Are Delivered

1. **SSE `event: notification` Stream (`GET /api/events`)**:
   Every connected web client or external agent receives structured `event: notification` frames in real time.
2. **Browser Push & Service Worker (`/sw.js`)**:
   The web client's modular [`notifications.js`](../layout/usr/share/meowd/web/modules/notifications.js) dispatches notifications to [`sw.js`](../layout/usr/share/meowd/web/sw.js) via `ServiceWorkerRegistration.showNotification()` (with automatic fallback to `new Notification()`), clicking a notification focuses the app and opens that conversation.
3. **In-App Floating Toast Banners (`#toast-container`)**:
   Even on plain HTTP LAN connections where browsers restrict the native `Notification` API, `meowtxt` displays iOS-style glassmorphic floating toast banners with contact avatars and status badges (`iMessage`, `Sent`, `Delivered`, `Read`).
4. **Outgoing HTTP Webhooks**:
   Any webhook URL registered via `POST /api/notifications` receives an HTTP `POST` request with header `X-Meow-Event: meowtxt-<type>` and the JSON notification payload.

---

## 2. Notification Payload Schema

```json
{
  "id": "notif-A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6-read",
  "type": "read",
  "title": "Read by cielo",
  "body": "hey there",
  "chat": "iMessage;-;+13466771046",
  "avatarUrl": "/api/avatar?handle=%2B13466771046",
  "icon": "/api/avatar?handle=%2B13466771046",
  "tag": "meow-iMessage;-;+13466771046-read",
  "message": {
    "id": 49498,
    "guid": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6",
    "chat": "iMessage;-;+13466771046",
    "text": "hey there",
    "fromMe": true,
    "delivered": true,
    "read": true
  },
  "timestamp": 1793113555719
}
```

---

## 3. REST Endpoints for Notifications

### `GET /api/notifications`
Returns the current notification event toggles and registered webhook URLs.
```json
{
  "ok": true,
  "events": {
    "received": true,
    "sent": true,
    "delivered": true,
    "read": true
  },
  "webhooks": []
}
```

### `POST /api/notifications`
Enable or disable specific notification types or add/remove webhook URLs. Settings are persisted in `/var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist`.
```json
{
  "events": {
    "received": true,
    "sent": true,
    "delivered": true,
    "read": true
  },
  "addWebhook": "https://my-nextjs-app.local/api/meow-webhook"
}
```

### `POST /api/notifications/test`
Triggers a test notification immediately across SSE (`event: notification`) and all configured webhooks.
```json
{
  "type": "read",
  "title": "Read by cielo",
  "body": "Web notifications are working!",
  "chat": "iMessage;-;+13466771046"
}
```
