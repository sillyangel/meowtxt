# meowtxt REST & Server-Sent Events (SSE) API Reference

Base URL: `http://<iphone-ip>:8737` (e.g. `http://10.0.127.243:8737`)  
OpenAPI 3.1 Specification: `GET /api/openapi.json`

> **Device Constraint:** This iPhone operates exclusively over **iMessage** (`service_name = 'iMessage'`) using vetted `@icloud.com` / custom domain email aliases (`angeljcedillo511@icloud.com`).

---

## 1. Authentication & CORS

All `/api/*` endpoints (except `GET /api/openapi.json` and `OPTIONS` preflight) require the access token when token authentication is enabled, passed via any of:
1. `Authorization: Bearer <token>`
2. `X-Meow-Token: <token>`
3. Query parameter `?token=<token>` (used for browser `EventSource`, `<img>`, `<video>`, `<audio>`)

Retrieve the token from the iPhone Settings app (**Settings → meowtxt**) or via CLI:
```bash
make token
# or on the iPhone:
grep -A1 "<key>token</key>" /var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist
```

Full CORS, Private Network Access (PNA), and Cross-Origin Resource Policy headers are enabled on all responses:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Authorization, Content-Type, X-Meow-Token, Accept, Range, Cache-Control`
- `Access-Control-Allow-Private-Network: true`
- `Cross-Origin-Resource-Policy: cross-origin`

---

## 2. Core Endpoints

### `GET /api/status`
Returns daemon health, `imagent` connection state, active iMessage account, and vetted aliases.
```json
{
  "ok": true,
  "enabled": true,
  "requireAuth": true,
  "connected": true,
  "iMessageActive": true,
  "account": "angeljcedillo511@icloud.com",
  "aliases": ["angeljcedillo511@icloud.com", "angel@sillyangel.fyi"],
  "sendingFrom": "angeljcedillo511@icloud.com",
  "loadedChats": 118
}
```

### `GET /api/chats?limit=50&offset=0`
Lists iMessage conversations ordered by most recent message descending, enriched with contact names, contact photo URLs (`avatarUrl`), two-way synced pin state (`pinned`, `pinIndex`), and live Focus / Do Not Disturb status (`dnd`).

### `GET /api/chat?guid=<chat_guid>`
Fetches a single decorated conversation object by GUID.

### `GET /api/messages?chat=<chat_guid>[&before=<ms>][&limit=60]`
Returns messages for a conversation ordered newest first (`DESC`), subscribes to live Focus / Do Not Disturb status updates for the recipient, and returns `{ ok, dnd, messages, names, avatars }`.

### `GET /api/message?guid=<message_guid>`
Fetches a single message by GUID.

### `GET /api/dnd?chat=<chat_guid>`
Queries and subscribes to live Focus / Do Not Disturb (`StatusKit` / `IMHandleAvailabilityManager`) status for a conversation's recipient.

---

## 3. Sending, Editing, Unsending & Reactions

### `POST /api/send`
Sends an iMessage with optional bold `subject`, bubble/screen `effect`, inline `replyTo` message GUID, or immediate `notifyAnyway` Focus/DND breakthrough.
```json
{
  "chat": "iMessage;-;+13466771046",
  "text": "Hello from meowtxt!",
  "subject": "Optional subject",
  "effect": "confetti",
  "replyTo": "OPTIONAL-MESSAGE-GUID",
  "notifyAnyway": false
}
```
Supported `effect` shorthands:
- **Bubble:** `slam`, `loud`, `gentle`, `invisible`
- **Screen:** `echo`, `spotlight`, `balloons`, `confetti`, `love`, `lasers`, `fireworks`, `celebration`

### `POST /api/notify` ("Notify Anyway" — Manual DND Override)
Manually breaks through a recipient's Focus / Do Not Disturb mode for a quietly-delivered message (invokes `-[IMChat markChatItemAsNotifyRecipient:]` and `-[IMChatRegistry _chat:sendNotifyRecipientCommandForMessage:]`).
```json
{
  "chat": "iMessage;-;+13466771046",
  "message": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6"
}
```

### `POST /api/edit` (iOS 16+ Edit Message)
```json
{
  "chat": "iMessage;-;+13466771046",
  "message": "TARGET-MESSAGE-GUID",
  "text": "Updated message text"
}
```

### `POST /api/unsend` (iOS 16+ Unsend / Retract Message)
```json
{
  "chat": "iMessage;-;+13466771046",
  "message": "TARGET-MESSAGE-GUID"
}
```

### `POST /api/react`
Sends or removes a tapback reaction (`love`, `like`, `dislike`, `laugh`, `emphasize`, `question`).
```json
{
  "chat": "iMessage;-;+13466771046",
  "message": "TARGET-MESSAGE-GUID",
  "type": "love",
  "remove": false
}
```

### `POST /api/pin`
Pins or unpins a conversation and two-way syncs with native iOS Messages (`IMPinnedConversationsController` + `com.apple.messages.pinning.plist`).
```json
{
  "chat": "iMessage;-;+13466771046",
  "pinned": true
}
```

### `POST /api/read` & `POST /api/typing`
- `POST /api/read`: `{ "chat": "iMessage;-;+13466771046" }`
- `POST /api/typing`: `{ "chat": "iMessage;-;+13466771046", "typing": true }`

---

## 4. Media, Avatars & Search

### `POST /api/send-file?filename=photo.jpg&chat=<chat_guid>[&text=<caption>]`
Uploads raw binary file contents in the POST body (`application/octet-stream` or file MIME type; up to 200 MB) and sends it as an iMessage attachment.

### `GET /api/attachment?id=<rowid>[&thumb=1][&raw=1]`
Streams an attachment from `/var/mobile/Library/SMS/Attachments/...`.
- **Hardware-Accelerated Apple HEIC / HEIF / AVCI / Sticker Transcoding:** Unless `&raw=1` is passed, `.heic`, `.heif`, `.avci`, `.tiff`, and `.bmp` images are automatically decoded on-device via `ImageIO` + `AppleAVE2UserClient` and transcoded to browser-compatible **JPEG** (`image/jpeg`) or **PNG** (`image/png` when the image has an alpha channel, such as iMessage stickers), cached under `/var/mobile/Library/Caches/meowd/v2_<id>[_thumb].{jpg,png}`.
- Pass `&thumb=1` for fast `640px` inline previews, or omit for `1800px` full-resolution viewing.
- Supports HTTP `Range: bytes=start-end` (`206 Partial Content`) for video/audio scrubbing.

### `GET /api/avatar?handle=<url_encoded_handle>`
Streams a contact's avatar image (`image/jpeg` or `image/png`) from `AddressBookImages.sqlitedb`.

### `GET /api/search?q=<query>&limit=50` & `GET /api/contacts?q=<query>`
- `GET /api/search`: Full-text search across iMessage history.
- `GET /api/contacts`: Searches iOS `AddressBook.sqlitedb` contacts and handles.

---

## 5. Web & Webhook Notifications API

See [Web-Notifications.md](./Web-Notifications.md) for full details.

- `GET /api/notifications` — Returns `{ ok, events: { received, sent, delivered, read }, webhooks: string[] }`.
- `POST /api/notifications` — Updates notification event toggles (`received`, `sent`, `delivered`, `read`) and registers/removes outgoing webhook URLs (`webhooks`, `addWebhook`, `removeWebhook`).
- `POST /api/notifications/test` — Emits a live test notification over SSE (`event: notification`) and all registered webhooks.

---

## 6. Real-Time Server-Sent Events (`GET /api/events`)

Connect with `EventSource('/api/events?token=<token>')` or `Authorization: Bearer <token>`.

| Event Name | Payload Schema | When Emitted |
|---|---|---|
| `hello` | `{}` | Initial handshake when stream opens |
| `message` | `{ message, names, avatars }` | New incoming or outgoing iMessage |
| `updated` | `{ message, names, avatars }` | Delivery, read receipt, DND `didNotifyRecipient` override, Edit, or Unsend |
| `chat` | `MeowChat` | Updated conversation summary (`lastMessage`, `unread`, `pinned`, `dnd`, `avatarUrl`) |
| `typing` | `{ chat, sender, name, typing }` | Incoming typing bubble started or stopped |
| `pinned` | `{ pinnedIdentifiers }` | Pinned conversations changed on iPhone or via API |
| `dnd` | `{ handle, chat, dnd }` | Recipient's Focus / Do Not Disturb status changed |
| `notification` | `{ id, type, title, body, chat, avatarUrl, icon, tag, message, timestamp }` | Push notification event (`received`, `sent`, `delivered`, `read`) |
