# meowtxt (`dev.sillyangel.meowtxt`)

**meowtxt** is a rootless iOS 15–16 jailbreak daemon (`meowd`), modular web app, and REST + Server-Sent Events (SSE) API for **iMessage**.

It runs directly on your iPhone on port **8737**, serving a native-feeling web client (PWA & Chrome Isolated Web App ready) while exposing a full HTTP API for custom Next.js, React, desktop, or AI agent clients.

---

## Features

- **Real-Time iMessage Web Client:** Modular ES-module web UI (`app.js` + `modules/*.js`) with lazy-loaded components, contact photos, two-way synced pinned conversations, live incoming/outgoing typing indicators, tapback reactions, inline replies, and bubble/screen effects.
- **Focus / Do Not Disturb & "Notify Anyway":** Detects when a recipient has Focus / DND enabled (`StatusKit` / `wasDeliveredQuietly`) and lets you manually trigger **Notify Anyway** (`POST /api/notify`).
- **iOS 16 Edit & Unsend:** Edit (`POST /api/edit`) or retract (`POST /api/unsend`) sent iMessages.
- **Web, Push & Webhook Notifications:** Live notifications when iMessages are **received**, **sent**, **delivered**, and **read** (`GET/POST /api/notifications`, Service Worker `sw.js`, and in-app toast banners).
- **Hardware-Accelerated HEIC / Sticker Conversion:** Automatically transcodes Apple `.heic` / `.heif` photos to JPEG and transparent stickers to PNG on-device.
- **Native iOS Settings Integration:** Configure `meowtxt` (enable/disable the server and view/copy your access token) directly in **Settings → meowtxt** (`PreferenceLoader`).

---

## Quick Start

```bash
# Build & install to the iPhone over SSH
make package install

# Print the access token
make token

# Push web UI changes only (no daemon restart required)
make web
```

Open `http://<iphone-ip>:8737` in any browser, or manage the daemon in **Settings → meowtxt** on your iPhone.

---

## Documentation

All detailed API, SDK, and architecture documentation lives in the [`documentation/`](./documentation/) directory:

- **[REST & SSE API Reference](./documentation/REST-API.md)** — Complete endpoint reference (`/api/chats`, `/api/messages`, `/api/send`, `/api/notify`, `/api/edit`, `/api/unsend`, `/api/notifications`, `/api/events`, OpenAPI 3.1).
- **[Web & Push Notifications](./documentation/Web-Notifications.md)** — Sent, delivered, read, and incoming notifications over SSE, Service Worker, and HTTP webhooks.
- **[Next.js / React Client SDK & Modular JS](./documentation/Client-SDK-NextJS.md)** — TypeScript SDK (`MeowClient`) and modular ES architecture.
- **[Chrome Isolated Web Apps (IWA) & PWA Guide](./documentation/Isolated-Web-Apps-IWA.md)** — Packaging and running `meowtxt` as a Signed Web Bundle (`.swbn`) under `isolated-app://`.
- **[iOS 16 `IMCore`, `ImageIO` HEIC & `PreferenceLoader` Internals](./documentation/IMCore-Internals.md)** — Private framework hooks, `AppleAVE2UserClient` HEIC entitlements, and Settings bundle architecture.
