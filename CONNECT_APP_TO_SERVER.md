# Connecting the Moldati Flutter app to the live server

This document explains how to point the **Moldati Owner** Flutter app at the
backend now running on the production server.

## 1. The API base URL

| | Value |
| --- | --- |
| **API base URL** (set this in the app) | `https://generator.tikritstore.shop` |
| API root | `https://generator.tikritstore.shop/api` |
| Health check | `https://generator.tikritstore.shop/api/health` |
| Admin panel (browser) | `https://generator.tikritstore.shop/admin` |

> ⚠️ Use **scheme + host only** — **no** trailing slash and **no** `/api`.
> The app appends the `/api/...` paths itself (see `lib/core/api_config.dart`).
> So the correct value is `https://generator.tikritstore.shop`, **not**
> `https://generator.tikritstore.shop/` or `.../api`.

Quick sanity check from any machine/browser:

```bash
curl https://generator.tikritstore.shop/api/health
# -> {"ok":true,"ts":"..."}
```

## 2. How the app reads the URL

`lib/core/api_config.dart`:

```dart
static const String baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://generator.tikritstore.shop',
);
```

`baseUrl` is a **compile-time constant** (`String.fromEnvironment`). It is *not*
read from a runtime file or settings screen — it is baked into the build. You
therefore set it in one of two ways:

- **(A) Per build/run**, with `--dart-define=API_BASE_URL=...` (use this to point
  a build at a local/dev server without changing code).
- **(B) Change the default** in `api_config.dart` (already done — the default is
  the live server, so every build uses it unless overridden).

## 3. Option A — set the URL at build/run time

### Run on a connected device / emulator (debug)

```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=https://generator.tikritstore.shop
```

### Build a release APK (Android)

```bash
flutter build apk --release \
  --dart-define=API_BASE_URL=https://generator.tikritstore.shop
# output: build/app/outputs/flutter-apk/app-release.apk
```

### Build an Android App Bundle (for Play Store)

```bash
flutter build appbundle --release \
  --dart-define=API_BASE_URL=https://generator.tikritstore.shop
```

### iOS

```bash
flutter build ipa --release \
  --dart-define=API_BASE_URL=https://generator.tikritstore.shop
```

### Web (if you ship the Flutter web build)

```bash
flutter build web --release \
  --dart-define=API_BASE_URL=https://generator.tikritstore.shop
```

### Tip: a dart-define file (avoid retyping)

Create `env.prod.json`:

```json
{ "API_BASE_URL": "https://generator.tikritstore.shop" }
```

Then:

```bash
flutter build apk --release --dart-define-from-file=env.prod.json
```

## 4. Verify the connection

1. **Backend reachable:** open `https://generator.tikritstore.shop/api/health`
   in a browser — you should see `{"ok":true,...}`.
2. **In the app:** launch it, then **Register** a new owner account (or sign in).
   - Successful register/login = the app is talking to the server.
   - The bound device counts against the plan's `maxDevices`; a 2nd device on a
     1-device plan returns `403 DEVICE_LIMIT` (expected).
3. **Admin view:** log in to `https://generator.tikritstore.shop/admin` to see
   the account and its synced data.

## 5. Option B — bake the URL into the app as the default (done)

The default in `lib/core/api_config.dart` is set to the live server:

```dart
static const String baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://generator.tikritstore.shop',   // live default
);
```

So a plain `flutter run` / `flutter build apk --release` uses the live server,
and `--dart-define=API_BASE_URL=...` still overrides it for local dev.

## 6. Notes & gotchas

- **HTTPS is good news for Android:** because the URL is `https://`, you do
  **not** need Android cleartext-HTTP permission for it. (The old
  `http://192.168.1.99:4000` dev URL required `usesCleartextTraffic`; that flag
  can stay for LAN dev but is irrelevant for the live HTTPS URL.)
- **iOS ATS:** HTTPS with a valid Let's Encrypt cert satisfies App Transport
  Security out of the box — no `NSAllowsArbitraryLoads` needed.
- **Offline-first still applies:** the network is only used for register/sign-in,
  subscription checks, cloud backup, and pushing local changes to the sync
  mirror. All business data stays in the device's SQLite DB.
- **Request timeout** is 20s (`ApiConfig.timeout`).
- **Don't hardcode a trailing `/api`** — endpoint constants in `api_config.dart`
  already include it (e.g. `login = '/api/auth/login'`).

## 7. Endpoint reference (paths the app calls)

All are relative to `https://generator.tikritstore.shop`:

| Area | Method | Path |
| --- | --- | --- |
| Health | GET | `/api/health` |
| Register | POST | `/api/auth/register` |
| Login | POST | `/api/auth/login` |
| Me | GET | `/api/auth/me` |
| Plans | GET | `/api/subscription/plans` |
| Subscription | GET | `/api/subscription` |
| Request plan | POST | `/api/subscription/request` |
| Devices | GET | `/api/device` |
| Bind device | POST | `/api/device/bind` |
| Cloud backup | GET/POST | `/api/backup` (+ `/{id}`, `/{id}/download`) |
| Sync push | POST | `/api/sync/push` |
| Sync pull | POST | `/api/sync/pull` |

The authoritative endpoint spec is [`backend/API_CONTRACT.md`](backend/API_CONTRACT.md).
