# meowtxt (`dev.sillyangel.meowtxt`) — AI, REST API & Client SDK Reference

`meowtxt` is a rootless jailbreak daemon (`meowd`) and web client for iOS 15–16 (built on an iPhone 8, iOS 16.0.2, Dopamine rootless `/var/jb`). It exposes the iPhone's **iMessage** account over an HTTP REST + Server-Sent Events (SSE) API and serves a built-in web client directly from the phone on port **8737**, while providing full CORS, OpenAPI 3.1 (`GET /api/openapi.json`), and real-time event streaming so you can build external **Next.js, React, desktop, mobile, or AI agent clients**.

> **Important constraint on this device:** This iPhone has **no SIM / phone number** — it sends and receives exclusively over **iMessage** using email aliases (e.g. `angeljcedillo511@icloud.com`). All queries filter to `service_name = 'iMessage'`, and outgoing chats pin `lastAddressedHandleID` to the preferred `@icloud.com` email alias so messages never attempt to route through SMS or an unvetted phone number.

---

## 1. Quick Connection & Environment Info

| Item | Value |
|---|---|
| **Package ID / Name** | `dev.sillyangel.meowtxt` (`meowtxt`) |
| **Daemon binary** | `/var/jb/usr/bin/meowd` (runs as user `mobile`, UID `501`) |
| **LaunchDaemon plist** | `/var/jb/Library/LaunchDaemons/dev.sillyangel.meowtxt.plist` |
| **Web static root** | `/var/jb/usr/share/meowd/web/` (`index.html`, `style.css`, `app.js`, `sw.js`, `manifest.webmanifest`, `modules/*.js`) |
| **PreferenceLoader & Bundle** | `/var/jb/Library/PreferenceLoader/Preferences/meowtxtPrefs.plist` & `/var/jb/Library/PreferenceBundles/meowtxtPrefs.bundle` |
| **Config & token plist** | `/var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist` (`enabled`, `token`, `port`, `notifReceived`, `notifSent`, `notifDelivered`, `notifRead`) |
| **Daemon log** | `/var/mobile/Library/Logs/meowd.log` |
| **JPEG/PNG transcode cache** | `/var/mobile/Library/Caches/meowd/v2_<attachment_rowid>[_thumb].{jpg,png}` |
| **Default port** | `8737` (dual-stack IPv4/IPv6) |
| **OpenAPI 3.1 spec** | `http://<iphone-ip>:8737/api/openapi.json` |
| **Documentation folder** | `documentation/` (`REST-API.md`, `Web-Notifications.md`, `Client-SDK-NextJS.md`, `Isolated-Web-Apps-IWA.md`, `IMCore-Internals.md`) |
| **SSH aliases on dev box** | `ssh iphone` (`mobile@10.0.127.243`), `ssh iphone-root` (`root@10.0.127.243`) |
| **Theos path** | `/drives/storage/Projects/tweak-development/theos` |

### Retrieving the Token

From the development server:
```bash
make -C /drives/storage/Projects/tweak-development/meow token
```
Or directly on the iPhone:
```bash
grep -A1 "<key>token</key>" /var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist
```

---

## 2. REST API Reference (For Next.js / React Clients & AI Agents)

Base URL: `http://<iphone-ip>:8737` (e.g. `http://10.0.127.243:8737`)

### Authentication & CORS
Every `/api/*` endpoint (except `GET /api/openapi.json` and `OPTIONS` preflight) requires the access token via **any** of the following:
1. Header: `Authorization: Bearer <token>`
2. Header: `X-Meow-Token: <token>`
3. Query parameter: `?token=<token>` (required for browser `EventSource`, `<img>`, `<video>`, `<audio>`)

Full CORS headers are enabled on all responses so a Next.js / Vite / React app running on `localhost:3000` or any domain can call the iPhone directly:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Authorization, Content-Type, X-Meow-Token, Accept, Range, Cache-Control`
- `Access-Control-Expose-Headers: Content-Length, Content-Range, Content-Type`

---

### `GET /api/openapi.json`
Returns the OpenAPI 3.1.0 specification for all endpoints (no authentication required, suitable for `openapi-typescript` or Swagger UI).

---

### `GET /api/status`
Returns the health of the `imagent` connection and the active iMessage account.

**Response:**
```json
{
  "ok": true,
  "connected": true,
  "iMessageActive": true,
  "account": "angeljcedillo511@icloud.com",
  "aliases": [
    "angeljcedillo511@icloud.com",
    "angel@sillyangel.fyi"
  ],
  "sendingFrom": "angeljcedillo511@icloud.com",
  "loadedChats": 118
}
```

---

### `GET /api/chats`
Lists iMessage conversations ordered by most recent message descending, enriched with contact names, avatar URLs, two-way synced pin state, and Focus / Do Not Disturb (`dnd`) state.

| Query Param | Default | Description |
|---|---|---|
| `limit` | `50` | Max conversations to return (`1`–`500`) |
| `offset` | `0` | Pagination offset |

**Response:**
```json
{
  "ok": true,
  "pinnedIdentifiers": [
    "+13466771046",
    "angeljcedillo511@icloud.com"
  ],
  "chats": [
    {
      "guid": "iMessage;-;+13466771046",
      "identifier": "+13466771046",
      "displayName": null,
      "title": "cielo",
      "isGroup": false,
      "groupID": "15C2133E-7F00-450F-A020-5C42049FA259",
      "originalGroupID": "15C2133E-7F00-450F-A020-5C42049FA259",
      "groupPhotoAttachmentID": null,
      "avatarUrl": "/api/avatar?handle=%2B13466771046",
      "service": "iMessage",
      "participants": ["+13466771046"],
      "names": { "+13466771046": "cielo" },
      "avatars": { "+13466771046": true },
      "pinned": true,
      "pinIndex": 0,
      "dnd": true,
      "unread": 0,
      "lastMessage": {
        "guid": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6",
        "text": "Hello!",
        "date": 1793107817391,
        "fromMe": true,
        "sender": "+13466771046",
        "isReaction": false,
        "wasDeliveredQuietly": true,
        "didNotifyRecipient": false
      }
    }
  ]
}
```
- **Chat GUID format:**
  - 1-on-1 chat: `iMessage;-;<handle>` (e.g. `iMessage;-;friend@icloud.com` or `iMessage;-;+15551234567`)
  - Group chat: `iMessage;+;chat<numeric_id>`
- **`dnd` field:** `true` when the recipient currently has Focus / Do Not Disturb active (via `IMHandleAvailabilityManager` / `StatusKit` or a recent quietly-delivered message).

---

### `GET /api/chat?guid=<chat_guid>`
Returns a single decorated chat object by its GUID (`404` if not found).

---

### `GET /api/messages`
Returns messages for a chat, ordered **newest first** (`DESC`), and automatically subscribes the daemon to live Focus / Do Not Disturb updates for the conversation's recipient.

| Query Param | Required | Default | Description |
|---|---|---|---|
| `chat` | **Yes** | — | Chat GUID (must start with `iMessage;`) |
| `before` | No | `0` | Unix timestamp in **milliseconds** (`date` of oldest loaded message) for cursor pagination |
| `limit` | No | `50` | Number of messages (`1`–`500`) |

**Response:**
```json
{
  "ok": true,
  "dnd": true,
  "names": {
    "+13466771046": "cielo"
  },
  "avatars": {
    "+13466771046": true
  },
  "messages": [
    {
      "id": 49498,
      "guid": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6",
      "chat": "iMessage;-;+13466771046",
      "text": "hey there",
      "subject": null,
      "date": 1793107817391,
      "dateRead": 0,
      "dateDelivered": 1793107818922,
      "fromMe": true,
      "delivered": true,
      "read": false,
      "sent": true,
      "error": 0,
      "service": "iMessage",
      "sender": "+13466771046",
      "itemType": 0,
      "effect": null,
      "replyTo": null,
      "dateEdited": 0,
      "dateRetracted": 0,
      "wasDeliveredQuietly": true,
      "didNotifyRecipient": false,
      "groupTitle": null,
      "balloon": null,
      "audio": false,
      "groupAction": 0,
      "otherHandle": null,
      "attachments": [
        {
          "id": 812,
          "guid": "at_0_...",
          "name": "IMG_1234.HEIC",
          "mime": "image/heic",
          "uti": "public.heic",
          "size": 1420912,
          "sticker": false,
          "ready": true
        }
      ],
      "reaction": {
        "type": "love",
        "remove": false,
        "target": "09A1B2C3-..."
      }
    }
  ]
}
```
Notes on message fields:
- `wasDeliveredQuietly`: `true` (`1`) when the message was delivered silently because the recipient had Focus / Do Not Disturb enabled.
- `didNotifyRecipient`: `true` (`1`) when the sender used **Notify Anyway** (`POST /api/notify` or `notifyAnyway: true` on `POST /api/send`) to break through Focus / DND.
- `reaction`: only present when the row is a tapback (`associated_message_type` in `2000..3999`). `target` is the GUID of the message being reacted to.
- `date`, `dateRead`, `dateDelivered`, `dateEdited`, `dateRetracted` are **Unix timestamps in milliseconds** (`0` if unset).
- `dateRetracted > 0` means the message was unsent (iOS 16 Unsend).
- `dateEdited > 0` means the message was edited (iOS 16 Edit).

---

### `GET /api/message?guid=<message_guid>`
Fetches a single message by GUID.

---

### `GET /api/dnd?chat=<chat_guid>`
Subscribes to and queries the live Focus / Do Not Disturb status of a conversation's recipient via `IMHandleAvailabilityManager` (`StatusKit`).

**Response:**
```json
{
  "ok": true,
  "chat": "iMessage;-;+13466771046",
  "dnd": true
}
```

---

### `POST /api/notify` (Manual DND Override — "Notify Anyway")
Manually overrides a recipient's Focus / Do Not Disturb mode for a sent message (equivalent to tapping **"Notify Anyway"** in the native iOS Messages app). Invokes `-[IMChat markChatItemAsNotifyRecipient:]` and `-[IMChatRegistry _chat:sendNotifyRecipientCommandForMessage:]` and broadcasts an `updated` SSE event with `didNotifyRecipient: true`.

**Request JSON:**
```json
{
  "chat": "iMessage;-;+13466771046",
  "message": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6"
}
```

**Response:**
```json
{
  "ok": true,
  "chat": "iMessage;-;+13466771046",
  "message": "A3DBC0B7-EF6C-4EB7-B8DC-7460FB926AD6",
  "notified": true
}
```

---

### `POST /api/send`
Sends a text iMessage (optionally with a subject, bubble/screen effect, inline reply thread, or immediate `notifyAnyway` DND override).

Provide **either** `chat` (an existing `iMessage;...` chat GUID) **or** `to` (an array or comma-separated string of recipient emails/handles).

**Request JSON:**
```json
{
  "chat": "iMessage;-;friend@icloud.com",
  "to": ["friend@icloud.com"],
  "text": "Hello from meowtxt!",
  "subject": "Optional bold subject",
  "effect": "confetti",
  "replyTo": "OPTIONAL-TARGET-MESSAGE-GUID",
  "notifyAnyway": false
}
```
- When `"notifyAnyway": true` is passed, `meowd` sends the message and automatically triggers the Focus / DND override command so the recipient is notified immediately even if they have Focus / DND active.
- Supported `effect` shorthands (or pass a full `com.apple.*` bundle ID):
  - **Bubble effects:** `slam`, `loud`, `gentle`, `invisible`
  - **Screen effects:** `echo`, `spotlight`, `balloons`, `confetti`, `love`, `lasers`, `fireworks`, `celebration`

**Response:**
```json
{
  "ok": true,
  "guid": "5F89B3B2-...",
  "chat": "iMessage;-;friend@icloud.com",
  "notifyAnyway": false
}
```

---

### `POST /api/edit` (iOS 16 Edit Message)
Edits the text of a recently sent outbound iMessage via `-[IMChat editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:]`.

**Request JSON:**
```json
{
  "chat": "iMessage;-;friend@icloud.com",
  "message": "TARGET-MESSAGE-GUID",
  "text": "Updated message text"
}
```

---

### `POST /api/unsend` (iOS 16 Unsend / Retract Message)
Unsends (retracts) a recently sent outbound iMessage via `+[IMMessage editedMessageWithOriginalMessage:retractedPartIndex:shouldRetractSubject:]` and `-[IMChatRegistry _chat:sendEditedMessage:previousMessage:partIndex:editType:backwardCompatabilityText:]`.

**Request JSON:**
```json
{
  "chat": "iMessage;-;friend@icloud.com",
  "message": "TARGET-MESSAGE-GUID"
}
```

---

### `POST /api/send-file`
Sends an attachment (image, video, audio, or arbitrary file) with optional caption text.
- **Query parameters:**
  - `filename` (required, e.g. `photo.jpg`)
  - `chat` (existing chat GUID) **or** `to` (comma-separated recipients)
  - `text` (optional caption sent in the same message)
- **Request body:** Raw binary file contents (`application/octet-stream` or file MIME type; up to 200 MB).

---

### `GET /api/attachment?id=<attachment_rowid>[&thumb=1][&raw=1]`
Streams an attachment file from `/var/mobile/Library/SMS/Attachments/...`.
- **Automatic HEIC/HEIF/TIFF transcoding & thumbnails:** Unless `&raw=1` is passed, `.heic`, `.heif`, `.tif`, and `.tiff` images are automatically converted on-device via `ImageIO` to a browser-friendly JPEG (`1800px` max, or `640px` when `&thumb=1` is passed for fast inline chat previews) and cached under `/var/mobile/Library/Caches/meowd/<id>[_thumb].jpg`.
- **Byte-Range support:** Supports `Range: bytes=start-end` (`206 Partial Content`) so `<video>` and `<audio>` elements can seek in Safari/Chrome.

---

### `GET /api/avatar?handle=<handle>`
Streams a contact's avatar image (`image/jpeg` or `image/png`) directly from `/var/mobile/Library/AddressBook/AddressBookImages.sqlitedb` (`ABThumbnailImage` / `ABFullSizeImage`), with `Cache-Control: private, max-age=3600`.
- Remember to URL-encode `+` as `%2B` in phone numbers (e.g. `/api/avatar?handle=%2B13466771046`).

---

### `POST /api/pin`
Pins or unpins an iMessage conversation and syncs two-way with the native iOS Messages app (`IMPinnedConversationsController` + `/var/mobile/Library/Preferences/com.apple.messages.pinning.plist` + iCloud Ubiquity KV store).

```json
{
  "chat": "iMessage;-;+13466771046",
  "pinned": true
}
```

---

### `POST /api/react`
Sends or removes a tapback reaction on a message (`love`, `like`, `dislike`, `laugh`, `emphasize`, `question`).

```json
{
  "chat": "iMessage;-;friend@icloud.com",
  "message": "TARGET-MESSAGE-GUID",
  "type": "love",
  "remove": false
}
```

---

### `POST /api/read` & `POST /api/typing`
- `POST /api/read`: `{ "chat": "iMessage;-;friend@icloud.com" }` — marks conversation read & sends read receipt.
- `POST /api/typing`: `{ "chat": "iMessage;-;friend@icloud.com", "typing": true }` — starts or stops outgoing typing bubble.

---

### `GET /api/search?q=<query>&limit=50` & `GET /api/contacts?q=<query>`
- `GET /api/search`: full-text search across iMessage history.
- `GET /api/contacts`: searches iOS `AddressBook.sqlitedb` and returns `{ name, handles, hasAvatar }`.

---

### `GET /api/notifications`, `POST /api/notifications` & `POST /api/notifications/test`
Configures and tests real-time web/push/webhook notifications for `received`, `sent`, `delivered`, and `read` iMessage events:
- `GET /api/notifications`: returns `{ ok: true, events: { received, sent, delivered, read }, webhooks: string[] }`.
- `POST /api/notifications`: `{ "events": { "received": true, "sent": true, "delivered": true, "read": true }, "addWebhook": "https://..." }`.
- `POST /api/notifications/test`: `{ "type": "read", "title": "Read by cielo", "body": "..." }` — emits a test `event: notification` over SSE and webhooks.

---

### `GET /api/events` (Server-Sent Events)
Long-lived `text/event-stream` connection that pushes real-time updates whenever `sms.db`, `imagent`, or `StatusKit` state changes.

| Event Name | Payload Schema | When Emitted |
|---|---|---|
| `hello` | `{}` | Initial handshake when stream opens |
| `message` | `{ message: MeowMessage, names: Record<string,string>, avatars: Record<string,boolean> }` | New incoming or outgoing iMessage |
| `updated` | `{ message: MeowMessage, names: Record<string,string>, avatars: Record<string,boolean> }` | Delivery/read change, DND `didNotifyRecipient` override, Edit, or Unsend |
| `chat` | `MeowChat` | Updated chat summary (unread count, `lastMessage`, `pinned`, `dnd`, `avatarUrl`) |
| `typing` | `{ chat: string, sender: string \| null, name: string \| null, typing: boolean }` | Live incoming typing indicator started or stopped |
| `pinned` | `{ pinnedIdentifiers: string[] }` | Pinned chats changed on the iPhone or via API |
| `dnd` | `{ handle: string, chat: string, dnd: boolean }` | Recipient's Focus / Do Not Disturb status changed |
| `notification` | `{ id: string, type: 'received'\|'sent'\|'delivered'\|'read', title: string, body: string, chat: string\|null, avatarUrl: string\|null, icon: string, tag: string, message: MeowMessage\|null, timestamp: number }` | Web notification emitted when a message is received, sent, delivered, or read |

---

## 3. Building a Custom Next.js / React / TypeScript Client

Because `meowd` sends permissive CORS headers and streams state over SSE, you can build a full Next.js (App Router or Pages Router), Vite, Remix, or React Native client that talks directly to `http://<iphone-ip>:8737` (or through a Next.js Route Handler proxy).

### 3.1 Environment Variables (`.env.local`)
```env
NEXT_PUBLIC_MEOW_URL=http://10.0.127.243:8737
NEXT_PUBLIC_MEOW_TOKEN=your_token_from_make_token
```

### 3.2 Complete TypeScript SDK (`src/lib/meow.ts`)
Drop this file into any Next.js / TypeScript project for full type safety across all endpoints and media helpers:

```ts
export type TapbackType = 'love' | 'like' | 'dislike' | 'laugh' | 'emphasize' | 'question';

export type MessageEffect =
  | 'slam' | 'loud' | 'gentle' | 'invisible'
  | 'echo' | 'spotlight' | 'balloons' | 'confetti' | 'love' | 'lasers' | 'fireworks' | 'celebration';

export interface MeowStatus {
  ok: boolean;
  connected: boolean;
  iMessageActive: boolean;
  account: string;
  aliases: string[];
  sendingFrom: string;
  loadedChats: number;
}

export interface MeowAttachment {
  id: number;
  guid: string;
  name: string | null;
  mime: string | null;
  uti: string | null;
  size: number;
  sticker: boolean;
  ready: boolean;
}

export interface MeowReaction {
  type: TapbackType;
  remove: boolean;
  target: string;
}

export interface MeowMessage {
  id: number;
  guid: string;
  chat: string;
  text: string | null;
  subject: string | null;
  date: number;
  dateRead: number;
  dateDelivered: number;
  dateEdited: number;
  dateRetracted: number;
  fromMe: boolean;
  delivered: boolean;
  read: boolean;
  sent: boolean;
  wasDeliveredQuietly: boolean;
  didNotifyRecipient: boolean;
  error: number;
  service: 'iMessage';
  sender: string | null;
  itemType: number;
  effect: string | null;
  replyTo: string | null;
  groupTitle: string | null;
  balloon: string | null;
  audio: boolean;
  groupAction: number;
  otherHandle: string | null;
  attachments: MeowAttachment[];
  reaction?: MeowReaction;
}

export interface MeowChat {
  guid: string;
  identifier: string;
  displayName: string | null;
  title: string;
  isGroup: boolean;
  groupID: string | null;
  originalGroupID: string | null;
  groupPhotoAttachmentID: number | null;
  avatarUrl: string | null;
  service: 'iMessage';
  participants: string[];
  names: Record<string, string>;
  avatars: Record<string, boolean>;
  pinned: boolean;
  pinIndex: number | null;
  dnd: boolean;
  unread: number;
  lastMessage: {
    guid: string;
    text: string;
    date: number;
    fromMe: boolean;
    sender: string | null;
    isReaction: boolean;
    wasDeliveredQuietly: boolean;
    didNotifyRecipient: boolean;
  } | null;
}

export interface MeowContact {
  name: string;
  handles: string[];
  hasAvatar: boolean;
}

export class MeowClient {
  constructor(
    public baseUrl: string = process.env.NEXT_PUBLIC_MEOW_URL || 'http://10.0.127.243:8737',
    public token: string = process.env.NEXT_PUBLIC_MEOW_TOKEN || ''
  ) {
    this.baseUrl = this.baseUrl.replace(/\/+$/, '');
  }

  private async request<T>(path: string, init: RequestInit = {}): Promise<T> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${this.token}`,
        ...(init.body && !(init.body instanceof Blob) && !(init.body instanceof ArrayBuffer)
          ? { 'Content-Type': 'application/json' }
          : {}),
        ...init.headers,
      },
      cache: 'no-store',
    });
    const data = await res.json();
    if (!res.ok || data.ok === false) {
      throw new Error(data.error || `HTTP ${res.status}`);
    }
    return data as T;
  }

  /** Media URL helper for <img src={client.avatarUrl(chat.avatarUrl)} /> */
  mediaUrl(relativeOrAvatarUrl: string | null): string | null {
    if (!relativeOrAvatarUrl) return null;
    const sep = relativeOrAvatarUrl.includes('?') ? '&' : '?';
    return `${this.baseUrl}${relativeOrAvatarUrl}${sep}token=${encodeURIComponent(this.token)}`;
  }

  /** Attachment URL helper (supports fast 640px ?thumb=1 previews and ?raw=1 original files) */
  attachmentUrl(id: number, opts: { thumb?: boolean; raw?: boolean } = {}): string {
    const params = new URLSearchParams({ id: String(id), token: this.token });
    if (opts.thumb) params.set('thumb', '1');
    if (opts.raw) params.set('raw', '1');
    return `${this.baseUrl}/api/attachment?${params.toString()}`;
  }

  getStatus() {
    return this.request<MeowStatus>('/api/status');
  }

  getChats(limit = 100, offset = 0) {
    return this.request<{ ok: true; chats: MeowChat[]; pinnedIdentifiers: string[] }>(
      `/api/chats?limit=${limit}&offset=${offset}`
    );
  }

  getChat(guid: string) {
    return this.request<{ ok: true; chat: MeowChat }>(`/api/chat?guid=${encodeURIComponent(guid)}`);
  }

  getMessages(chatGuid: string, opts: { before?: number; limit?: number } = {}) {
    const q = new URLSearchParams({ chat: chatGuid, limit: String(opts.limit ?? 60) });
    if (opts.before) q.set('before', String(opts.before));
    return this.request<{
      ok: true;
      dnd: boolean;
      messages: MeowMessage[];
      names: Record<string, string>;
      avatars: Record<string, boolean>;
    }>(`/api/messages?${q.toString()}`);
  }

  getDND(chatGuid: string) {
    return this.request<{ ok: true; chat: string; dnd: boolean }>(
      `/api/dnd?chat=${encodeURIComponent(chatGuid)}`
    );
  }

  sendMessage(params: {
    chat?: string;
    to?: string[];
    text: string;
    subject?: string;
    effect?: MessageEffect;
    replyTo?: string;
    notifyAnyway?: boolean;
  }) {
    return this.request<{ ok: true; guid: string; chat: string; notifyAnyway: boolean }>('/api/send', {
      method: 'POST',
      body: JSON.stringify(params),
    });
  }

  sendFile(file: Blob | File, params: { filename: string; chat?: string; to?: string[]; text?: string }) {
    const q = new URLSearchParams({ filename: params.filename });
    if (params.chat) q.set('chat', params.chat);
    if (params.to?.length) q.set('to', params.to.join(','));
    if (params.text) q.set('text', params.text);
    return this.request<{ ok: true; guid: string; transfer: string; chat: string }>(
      `/api/send-file?${q.toString()}`,
      { method: 'POST', body: file }
    );
  }

  /** Manually override Focus / Do Not Disturb ("Notify Anyway") for an already-sent message */
  notifyAnyway(chatGuid: string, messageGuid: string) {
    return this.request<{ ok: true; chat: string; message: string; notified: true }>('/api/notify', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, message: messageGuid }),
    });
  }

  editMessage(chatGuid: string, messageGuid: string, text: string) {
    return this.request<{ ok: true; guid: string }>('/api/edit', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, message: messageGuid, text }),
    });
  }

  unsendMessage(chatGuid: string, messageGuid: string) {
    return this.request<{ ok: true; guid: string }>('/api/unsend', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, message: messageGuid }),
    });
  }

  react(chatGuid: string, messageGuid: string, type: TapbackType, remove = false) {
    return this.request<{ ok: true; guid: string }>('/api/react', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, message: messageGuid, type, remove }),
    });
  }

  setPinned(chatGuid: string, pinned: boolean) {
    return this.request<{ ok: true; pinned: boolean; pinnedIdentifiers: string[] }>('/api/pin', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, pinned }),
    });
  }

  markRead(chatGuid: string) {
    return this.request<{ ok: true }>('/api/read', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid }),
    });
  }

  setTyping(chatGuid: string, typing: boolean) {
    return this.request<{ ok: true }>('/api/typing', {
      method: 'POST',
      body: JSON.stringify({ chat: chatGuid, typing }),
    });
  }

  searchMessages(query: string, limit = 50) {
    return this.request<{ ok: true; messages: MeowMessage[]; names: Record<string, string> }>(
      `/api/search?q=${encodeURIComponent(query)}&limit=${limit}`
    );
  }

  searchContacts(query: string) {
    return this.request<{ ok: true; contacts: MeowContact[] }>(
      `/api/contacts?q=${encodeURIComponent(query)}`
    );
  }
}
```

### 3.3 React Real-Time SSE Hook (`src/hooks/useMeowStream.ts`)
Use this hook in a Next.js `"use client"` component to subscribe to live messages, read receipts, edits, unsends, typing indicators, pinned conversation changes, and Focus/DND changes:

```ts
'use client';

import { useEffect, useState } from 'react';
import type { MeowChat, MeowClient, MeowMessage } from '@/lib/meow';

export interface MeowStreamCallbacks {
  onMessage?: (payload: { message: MeowMessage; names: Record<string, string>; avatars: Record<string, boolean> }) => void;
  onUpdated?: (payload: { message: MeowMessage; names: Record<string, string>; avatars: Record<string, boolean> }) => void;
  onChat?: (chat: MeowChat) => void;
  onTyping?: (payload: { chat: string; sender: string | null; name: string | null; typing: boolean }) => void;
  onPinned?: (payload: { pinnedIdentifiers: string[] }) => void;
  onDND?: (payload: { handle: string; chat: string; dnd: boolean }) => void;
}

export function useMeowStream(client: MeowClient, callbacks: MeowStreamCallbacks) {
  const [connected, setConnected] = useState(false);

  useEffect(() => {
    if (!client.token) return;
    const url = `${client.baseUrl}/api/events?token=${encodeURIComponent(client.token)}`;
    const es = new EventSource(url);

    es.addEventListener('hello', () => setConnected(true));
    es.onerror = () => setConnected(false);

    es.addEventListener('message', (e) => callbacks.onMessage?.(JSON.parse(e.data)));
    es.addEventListener('updated', (e) => callbacks.onUpdated?.(JSON.parse(e.data)));
    es.addEventListener('chat', (e) => callbacks.onChat?.(JSON.parse(e.data)));
    es.addEventListener('typing', (e) => callbacks.onTyping?.(JSON.parse(e.data)));
    es.addEventListener('pinned', (e) => callbacks.onPinned?.(JSON.parse(e.data)));
    es.addEventListener('dnd', (e) => callbacks.onDND?.(JSON.parse(e.data)));

    return () => {
      es.close();
      setConnected(false);
    };
  }, [client.baseUrl, client.token]);

  return { connected };
}
```

---

## 4. Codebase Architecture & iOS 16 `IMCore` Internals

### Directory Structure
```text
/drives/storage/Projects/tweak-development/meow/
├── Makefile                    # Theos rootless build + helper targets (web, log, token)
├── control                     # Debian package metadata (dev.sillyangel.meowtxt)
├── src/
│   ├── main.m                  # Config/token loader, HTTP router, OpenAPI spec, SSE hub, 400ms DB poller
│   ├── MWHTTPServer.{h,m}      # Dual-stack IPv6/IPv4 socket HTTP/1.1 server + CORS + SSE streaming
│   ├── MWDatabase.{h,m}        # Read-only SQLite wrapper for /var/mobile/Library/SMS/sms.db
│   ├── MWContacts.{h,m}        # Read-only SQLite wrapper for AddressBook.sqlitedb & AddressBookImages.sqlitedb
│   ├── MWIMBridge.{h,m}        # IMCore / imagent / StatusKit private framework bridge (main thread)
│   ├── MWLog.{h,m}             # Timestamped stderr logger
│   └── entitlements.plist      # Required IMCore, IDS, StatusKit, TCC, and storage entitlements
├── layout/
│   ├── DEBIAN/{postinst,prerm} # Package lifecycle scripts (loads/unloads LaunchDaemon)
│   ├── Library/LaunchDaemons/dev.sillyangel.meowtxt.plist
│   └── usr/share/meowd/web/    # Built-in single-page web app (index.html, style.css, app.js)
└── tools/probe/                # Standalone Objective-C runtime class/method dumper
```

### Critical iOS 16 `IMCore`, `StatusKit` & `sms.db` Gotchas (Learned on Device)

1. **`imagent` Capability Bitmask (`17159` + Incoming Typing Listener)**
   - Calling `[IMDaemonController connectToDaemonWithLaunch:YES capabilities:0xFFFFFFFF blockUntilConnected:YES]` reports `isConnected = YES`, **but `imagent` silently refuses to populate `IMChatRegistry` or `IMAccountController`**.
   - Passing capability mask **`17159`** (`kFZListenerCapManageStatus | Notifications | Chats | Transfers | Accounts | MessageHistory`) causes `imagent` to vend all accounts and chats properly, and adding a listener with `17159 | (1 << 19)` (`0x84307`) enables live incoming typing indicator `account:chat:...` XPC callbacks.

2. **Focus / Do Not Disturb (`StatusKit` + `IMHandleAvailabilityManager`) & "Notify Anyway"**
   - `meowd` includes `com.apple.StatusKit.subscribe.types` and `com.apple.StatusKit.publish.types` (`["com.apple.availability", "com.apple.focus.status"]`) in `src/entitlements.plist` and swizzles `-[IMChat isMessagesAuthorizedToAccessFocusStatus]` to return `YES`.
   - Calling `[chat beginObservingHandleAvailability]` and `[[IMHandleAvailabilityManager sharedInstance] beginObservingAvailabilityForHandle:recipient]` subscribes to Focus status. `availabilityForHandle:` returns `2` when the user has Focus / DND active.
   - In `sms.db`, quietly delivered messages have `message.was_delivered_quietly = 1` and `message.did_notify_recipient = 0`.
   - To manually override DND ("Notify Anyway"), `MWIMBridge` loads the `IMMessage` via `[chat loadMessagesUpToGUID:guid date:nil limit:0 loadImmediately:YES]` + `[chat messageForGUID:guid]` and calls `[[IMChatRegistry sharedInstance] _chat:chat sendNotifyRecipientCommandForMessage:[imMsg _imMessageItem]]` (as well as `[chat markChatItemAsNotifyRecipient:]` if the chat item is instantiated).

3. **Main-Thread Requirement for `IMCore`**
   - `IMDaemonController`, `IMChatRegistry`, `IMAccountController`, `IMChat`, `IMHandleAvailabilityManager`, and `IMFileTransferCenter` are **not thread-safe** and rely on the main `NSRunLoop` for XPC replies from `imagent`.
   - Always dispatch `IMCore` calls onto `dispatch_get_main_queue()` (see `MWOnMain(...)` in [`src/MWIMBridge.m`](file:///drives/storage/Projects/tweak-development/meow/src/MWIMBridge.m)) while `[[NSRunLoop mainRunLoop] run]` spins in `main()`.

4. **iOS 16 `message.text` is Often `NULL` (`attributedBody` Typedstream)**
   - On iOS 16+, `imagent` frequently stores outgoing and incoming message text only inside `message.attributedBody` (an `NSArchiver` legacy **typedstream** blob, *not* an `NSKeyedArchiver` plist) and leaves `message.text` as `NULL`.
   - `MWTextFromAttributedBody(NSData *blob)` in [`src/MWDatabase.m`](file:///drives/storage/Projects/tweak-development/meow/src/MWDatabase.m) parses the typedstream directly.

5. **Forcing iCloud Email Alias (No Phone Number / No SMS)**
   - Before calling `[chat sendMessage:msg]`, `MWIMBridge` inspects `[account vettedAliases]`, picks the first `@` email alias (`angeljcedillo511@icloud.com`), and calls `[chat setLastAddressedHandleID:alias]`.

6. **Avoiding `SIGKILL` (Exit 137) When Replacing Binaries Over SSH**
   - XNU caches code-signing pages per vnode. Overwriting a running or previously executed binary in-place via `scp` corrupts its cached pages and triggers `SIGKILL` (`exit 137`). Always `rm -f` the old binary on the device before copying a new one, or install via `dpkg -i`.

---

## 5. Building, Deploying & Debugging

Run all commands from `/drives/storage/Projects/tweak-development/meow`:

```bash
# Build rootless .deb package into ./packages/
make package

# Install package onto the iPhone and restart the LaunchDaemon
DEB=$(ls -t packages/*.deb | head -1)
scp -q "$DEB" iphone-root:/tmp/meowtxt.deb
ssh iphone-root 'dpkg -i /tmp/meowtxt.deb && rm -f /tmp/meowtxt.deb'

# Push only web UI changes (instant — no recompile or daemon restart needed)
make web

# Tail live daemon logs from the iPhone
make log

# Print the current access token
make token
```
