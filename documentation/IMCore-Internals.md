# iOS 16 `IMCore`, `ImageIO` HEIC & `PreferenceLoader` Internals (`meowtxt`)

This document explains how `meowd` (`dev.sillyangel.meowtxt`) interfaces with Apple's private frameworks on iOS 15–16 (`Dopamine` rootless `/var/jb`).

---

## 1. Connecting to `imagent` (`IMCore.framework`)

In `src/MWIMBridge.m`, `meowd` swizzles `+[IMDaemonController _ capabilities]` and `-[IMDaemonController processCapabilities]` to return `4485895` (`0x447367`), which grants full iMessage read, send, tapback, typing indicator, pin sync, Edit/Unsend, and `StatusKit` Focus/DND inspection privileges:

```objc
IMDaemonController *dc = [IMDaemonController sharedInstance];
[dc connectToDaemonWithLaunch:YES capabilities:0x447367 blockUntilConnected:YES];
[[IMChatRegistry sharedInstance] _blockUntilQueriesComplete];
```

### Outgoing Handle Pinning (iMessage-Only Device)
Because this iPhone has no SIM card or phone number, `ensureLastAddressedHandleOnChat:` inspects `-[IMAccount vettedAliases]` and sets `-[IMChat setLastAddressedHandleID:@"angeljcedillo511@icloud.com"]` prior to sending any message, tapback, or typing indicator.

---

## 2. Why HEIC / Apple Photos Require IOKit Hardware Entitlements

On iOS 16 (`iPhone10,1` / A11 Bionic), `.heic` and `.heif` images in `/var/mobile/Library/SMS/Attachments/` use **HEVC Main 10 Profile** (`AppleAVE2UserClient` hardware video/image decoder) and `IOSurfaceRootUserClient`.

If a standalone LaunchDaemon calls `CGImageSourceCreateThumbnailAtIndex` without IOKit hardware decoder entitlements, `AppleAVE2UserClient` denies the connection and `ImageIO` silently outputs a solid-black (`RGB 0,0,0`) image buffer.

To enable hardware-accelerated HEIC/HEIF/AVCI/Sticker decoding in `meowd`, [`src/entitlements.plist`](../src/entitlements.plist) includes:
- `com.apple.private.security.no-sandbox = true`
- `com.apple.imageio.allowabletypes` (`public.heic`, `public.heif`, `public.avci`, `public.jpeg`, `public.png`, `com.compuserve.gif`, `org.webmproject.webp`, `public.tiff`)
- `com.apple.security.exception.iokit-user-client-class`:
  - `AppleAVE2UserClient`
  - `IOSurfaceRootUserClient`
  - `AppleJPEGDriverUserClient`
  - `AGXDeviceUserClient`, `IOAccelDevice2`, `IOAccelContext2`, `IOAccelSharedUserClient2`

In `MWBrowserFriendlyImage` (`src/main.m`), `meowd` inspects `CGImageGetAlphaInfo(img)`:
- Opaque photos (`.heic`, `.heif`, `.tif`) are transcoded to **JPEG** (`public.jpeg`, `image/jpeg`).
- Transparent images/stickers (`.heic` stickers with alpha channels) are transcoded to **PNG** (`public.png`, `image/png`) to preserve transparency.

---

## 3. Native iOS Settings (`PreferenceLoader` + `meowtxtPrefs.bundle`)

`meowtxt` includes a native iOS Settings bundle in [`prefs/`](../prefs/):
- **PreferenceLoader entry:** `/var/jb/Library/PreferenceLoader/Preferences/meowtxtPrefs.plist`
- **PreferenceBundle:** `/var/jb/Library/PreferenceBundles/meowtxtPrefs.bundle` (`MWRootListController`)
- **Backing plist:** `/var/mobile/Library/Preferences/dev.sillyangel.meowtxt.plist`

From **Settings → meowtxt** on the iPhone, you can:
1. Toggle **Enabled** (`enabled = YES / NO`) to immediately enable or disable the `meowtxt` web & REST API server (notifies `meowd` instantly via Darwin notification `dev.sillyangel.meowtxt/ReloadPrefs`).
2. View and copy the **Access Token** (`token`) to the clipboard.
