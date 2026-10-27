# Chrome Isolated Web Apps (IWA) & PWA Guide for `meowtxt`

Reference: [Chrome Isolated Web Apps — Introduction](https://developer.chrome.com/docs/iwa/introduction)

---

## 1. What Are Chrome Isolated Web Apps (IWAs)?

**Isolated Web Apps (IWAs)** are an evolution of Progressive Web Apps (PWAs) in Chromium that package a web application into a cryptographically signed **Signed Web Bundle (`.swbn`)** served under its own `isolated-app://<ed25519-public-key-id>` origin instead of `http://` or `https://`.

### Why IWAs Matter for `meowtxt`
Because `meowd` runs on your iPhone over a local LAN IP (`http://10.0.127.243:8737`), standard browsers treat `http://10.0.127.243:8737` as an **insecure context**, which restricts:
- Native `Notification.requestPermission()` / Web Push notifications
- Service Worker background sync
- Direct Private Network Access (PNA) from `https://` hosted apps
- Direct Socket (`DirectSockets`) APIs

When `meowtxt` is packaged or accessed as an **Isolated Web App (`isolated-app://...`)** (or installed PWA):
1. **`isolated-app://` is a Secure & Cross-Origin Isolated Context:** Native desktop/mobile OS notifications (`new Notification(...)` and Service Worker notifications) work without needing a public TLS certificate on the iPhone.
2. **Signed Offline Shell:** All HTML, CSS, SVG/PNG icons, and ES Modules (`/app.js` and `/modules/*.js`) are bundled inside the `.swbn` archive and verified against an Ed25519 or ECDSA P-256 public key.
3. **Private Network Access (PNA) & CORP Ready:** `meowd` responds with the required IWA headers on every HTTP response (`src/MWHTTPServer.m`):
   - `Cross-Origin-Opener-Policy: same-origin`
   - `Cross-Origin-Embedder-Policy: credentialless`
   - `Cross-Origin-Resource-Policy: cross-origin`
   - `Access-Control-Allow-Private-Network: true`
   - `Service-Worker-Allowed: /`

---

## 2. Built-in IWA & PWA Assets in `meowtxt`

`meowtxt` ships with all required manifest and icon assets out of the box in [`layout/usr/share/meowd/web/`](../layout/usr/share/meowd/web/):

| Path | Purpose |
|---|---|
| `/manifest.webmanifest` | Standard Web App Manifest (`display: standalone`, `display_override: ["window-controls-overlay", "standalone"]`) |
| `/.well-known/manifest.webmanifest` | Required canonical manifest path for Chrome Isolated Web Apps (`isolated_storage`, `permissions_policy`) |
| `/sw.js` | Service Worker caching the modular ES shell and handling `push` / `notificationclick` events |
| `/icon.svg`, `/icon-maskable.svg` | Vector app icons (`any` and `maskable`) |
| `/icon-192.png`, `/icon-512.png`, `/icon-maskable-512.png` | Raster PNG icons required by Chrome PWA/IWA validation |
| `/apple-touch-icon.png` | `180x180` iOS Home Screen Web Clip icon |
| `/favicon.svg`, `/favicon.ico` | Browser tab vector + multi-resolution ICO favicons |

---

## 3. Packaging `meowtxt` as a Signed Web Bundle (`.swbn`)

You can package `layout/usr/share/meowd/web/` into a Chrome `.swbn` bundle using Google's [`wbn-sign`](https://github.com/GoogleChromeLabs/wbn-sign) CLI:

```bash
# 1. Install wbn-sign and wbn tools
npm install -g wbn wbn-sign

# 2. Generate an Ed25519 signing key
openssl genpkey -algorithm Ed25519 -out meowtxt-iwa-key.pem

# 3. Derive your isolated-app://<bundle-id> origin
IWA_ORIGIN=$(npx wbn-dump-id -k meowtxt-iwa-key.pem)
echo "Your IWA Origin: $IWA_ORIGIN"

# 4. Build the unsigned Web Bundle from layout/usr/share/meowd/web
npx wbn \
  --dir layout/usr/share/meowd/web \
  --baseURL "$IWA_ORIGIN" \
  --output meowtxt-unsigned.wbn

# 5. Sign the bundle into a .swbn file
npx wbn-sign \
  -i meowtxt-unsigned.wbn \
  -k meowtxt-iwa-key.pem \
  -o meowtxt.swbn
```

### Installing in Chrome
1. Open `chrome://flags/#enable-isolated-web-apps-in-renderer` and `chrome://flags/#enable-isolated-web-app-dev-mode` and set both to **Enabled**.
2. Open `chrome://web-app-internals`.
3. Under **Install IWA from Signed Web Bundle**, select `meowtxt.swbn`.
4. Launch **meowtxt** as a standalone desktop app with full OS notification support talking directly to `http://<iphone-ip>:8737`.
