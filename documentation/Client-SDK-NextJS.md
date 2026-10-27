# Building a Custom Next.js / React Client (`meowtxt` SDK)

`meowd` enables permissive CORS (`Access-Control-Allow-Origin: *`, `Access-Control-Allow-Private-Network: true`) and streams real-time state over Server-Sent Events (`GET /api/events`), so you can build a Next.js, React, Vite, or React Native client that talks directly to `http://<iphone-ip>:8737`.

---

## 1. Modular Web Client Architecture (Built-In)

The built-in web client in [`layout/usr/share/meowd/web/`](../layout/usr/share/meowd/web/) uses native ES Modules (`<script type="module" src="/app.js"></script>`) and dynamic `import()` lazy-loading to minimize the initial JavaScript payload:

| Module | Loaded When | Responsibility |
|---|---|---|
| [`app.js`](../layout/usr/share/meowd/web/app.js) | Initial boot | Entrypoint (`~130` lines): fetches `/api/status` + `/api/chats` in parallel, opens SSE stream, and defers secondary modules via `requestIdleCallback` |
| [`modules/state.js`](../layout/usr/share/meowd/web/modules/state.js) | Initial boot | Reactive singleton state (`state`), `TAPBACK_EMOJI`, and `$` DOM helper |
| [`modules/utils.js`](../layout/usr/share/meowd/web/modules/utils.js) | Initial boot | Escaping, relative/full timestamps, avatar/attachment URL builders, attachment MIME/UTI classifier |
| [`modules/api.js`](../layout/usr/share/meowd/web/modules/api.js) | Initial boot | Authenticated `fetch` wrapper (`api(path, opts)`) and token prompt |
| [`modules/ui.js`](../layout/usr/share/meowd/web/modules/ui.js) | Initial boot | Renders pinned conversation grid, chat list, message thread, inline typing bubble, and Focus/DND banner |
| [`modules/actions.js`](../layout/usr/share/meowd/web/modules/actions.js) | Lazy (`import()`) | Composer, file upload, tapbacks, iOS 16 Edit/Unsend, "Notify Anyway" DND override, pinning, search, lightbox |
| [`modules/notifications.js`](../layout/usr/share/meowd/web/modules/notifications.js) | Lazy (`import()`) | Service Worker registration, browser push notifications, and floating iOS-style toast banners |
| [`modules/settings.js`](../layout/usr/share/meowd/web/modules/settings.js) | On modal click | Lazy-loaded only when the user clicks the Settings or Notifications header button |

---

## 2. TypeScript Client SDK (`src/lib/meow.ts`)

Drop this file into any Next.js / TypeScript project:

```ts
export type TapbackType = 'love' | 'like' | 'dislike' | 'laugh' | 'emphasize' | 'question';
export type NotificationEventType = 'received' | 'sent' | 'delivered' | 'read';

export type MessageEffect =
  | 'slam' | 'loud' | 'gentle' | 'invisible'
  | 'echo' | 'spotlight' | 'balloons' | 'confetti' | 'love' | 'lasers' | 'fireworks' | 'celebration';

export interface MeowStatus {
  ok: boolean;
  enabled: boolean;
  requireAuth: boolean;
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
  attachments: MeowAttachment[];
  reaction?: {
    type: TapbackType;
    remove: boolean;
    target: string;
  };
}

export interface MeowChat {
  guid: string;
  identifier: string;
  displayName: string | null;
  title: string;
  isGroup: boolean;
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

export interface MeowNotificationPayload {
  id: string;
  type: NotificationEventType;
  title: string;
  body: string;
  chat: string | null;
  avatarUrl: string | null;
  icon: string;
  tag: string;
  message: MeowMessage | null;
  timestamp: number;
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
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
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

  mediaUrl(relativeOrAvatarUrl: string | null): string | null {
    if (!relativeOrAvatarUrl) return null;
    if (!this.token) return `${this.baseUrl}${relativeOrAvatarUrl}`;
    const sep = relativeOrAvatarUrl.includes('?') ? '&' : '?';
    return `${this.baseUrl}${relativeOrAvatarUrl}${sep}token=${encodeURIComponent(this.token)}`;
  }

  attachmentUrl(id: number, opts: { thumb?: boolean; raw?: boolean } = {}): string {
    const params = new URLSearchParams({ id: String(id) });
    if (this.token) params.set('token', this.token);
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

  getNotificationConfig() {
    return this.request<{
      ok: true;
      events: Record<NotificationEventType, boolean>;
      webhooks: string[];
    }>('/api/notifications');
  }

  updateNotificationConfig(params: {
    events?: Partial<Record<NotificationEventType, boolean>>;
    webhooks?: string[];
    addWebhook?: string;
    removeWebhook?: string;
  }) {
    return this.request<{
      ok: true;
      events: Record<NotificationEventType, boolean>;
      webhooks: string[];
    }>('/api/notifications', {
      method: 'POST',
      body: JSON.stringify(params),
    });
  }
}
```
