# How to run — Moldati Owner

Two parts: the **backend** (Node/Express + MongoDB, also serves the admin web panel)
and the **frontend** (the Flutter app). You can run everything locally, or just run
the app against the live production server.

- **Production API / admin panel:** `https://generator.ecommerceflash.com`
- The Flutter app **defaults to production** — a plain `flutter run` / `flutter build`
  talks to the live server. Pass `--dart-define=API_BASE_URL=...` only to point it at a
  local backend (see §2).

---

## 1) Backend (Node/Express + MongoDB)

Prerequisites: **Node ≥ 18**.

```bash
cd backend
npm install
cp .env.example .env        # then edit secrets (JWT_SECRET, ADMIN_*)
npm run dev                 # dev mode (auto-reload) → http://localhost:4000
# or
npm start                   # plain node, same port
```

- **Database:** `.env` has `USE_MEMORY_DB=true` by default → an **in-memory MongoDB** is
  started automatically (no Mongo install needed), but **data is wiped on every restart**.
  For real persistence: set `USE_MEMORY_DB=false` and point `MONGO_URI` at a real MongoDB.
- **Seeding:** on every boot the server **auto-creates** the 3 default plans
  (`trial` 14d, `monthly` 30d, `yearly` 365d) and the **bootstrap admin** (from `ADMIN_*`).
  `npm run seed` seeds only the plans. Both are idempotent (never overwrite your edits).
- **Admin web panel:** open <http://localhost:4000/admin>.
- **Tests / syntax:** `npm test` (38 tests) · `node --check src/<file>.js`.

---

## 2) Frontend (Flutter app)

Prerequisites: **Flutter SDK** + an Android device or emulator.

```bash
flutter pub get

# A) Against PRODUCTION (default — no flag needed):
flutter run
flutter build apk --release        # release APK, points at generator.ecommerceflash.com

# B) Against a LOCAL backend (dev):
#   Android emulator → host machine:
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000
#   USB device → host machine (forward the port first):
adb reverse tcp:4000 tcp:4000
flutter run --dart-define=API_BASE_URL=http://localhost:4000
#   Device on the same Wi‑Fi/LAN as the PC:
flutter run --dart-define=API_BASE_URL=http://<PC-LAN-IP>:4000
```

- The base URL lives in `lib/core/api_config.dart` (`API_BASE_URL`, default = production).
- `flutter analyze` (0 errors) · `flutter test` (53 tests).
- The release APK currently installed on the connected device is build **B-from-production**
  (a plain release build, so it is already pointed at `generator.ecommerceflash.com`).

---

## 3) Login accounts

### Admin — runs the admin panel (and is an admin inside the app)
- **Where:** `https://generator.ecommerceflash.com/admin` (prod) or
  <http://localhost:4000/admin> (local).
- **Credentials:** the backend `.env` values `ADMIN_USERNAME` / `ADMIN_PASSWORD`.
  - **Local default** (from `.env.example`, no `.env` present): **`admin` / `admin123`**.
  - **Production:** whatever the production `.env` sets — change it from the example default.
- The admin can manage **users, plans, and each owner's synced data** (search / paginate /
  delete mirrored rows; the mirror is read‑only otherwise).

### Owner — the generator business owner (the main app user)
- **Create one** in the app: tap **«ليس لديك حساب؟ أنشئ حساباً»** (Create account) on the
  login screen → enter **phone number** (this is the username) + **password**.
- A brand‑new owner has **no active plan** → an admin approves a plan in the admin panel
  (**Users → approve plan**), then the owner is active.
- The **same owner credentials** also log into the **owner web panel**: open `/admin`,
  sign in as the owner → you land on **«لوحتي»** (`#/my`), a read‑only, app‑styled
  dashboard of that owner's own data.

### In‑app staff (device‑only)
- Inside the app: **Settings → Users** lets an admin add local **admin/staff** users
  (stored only in the device's SQLite — these never sync to the server).

---

## Quick start (everything local)

```bash
# terminal 1 — backend
cd backend && npm install && npm run dev      # http://localhost:4000

# open the admin panel, log in as admin / admin123
#   → http://localhost:4000/admin

# terminal 2 — app on a USB device, pointed at the local backend
adb reverse tcp:4000 tcp:4000
flutter pub get
flutter run --dart-define=API_BASE_URL=http://localhost:4000
# in the app: create an owner account → approve its plan in the admin panel → use the app
```
