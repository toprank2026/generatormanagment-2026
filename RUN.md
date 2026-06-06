# RUN — How to run Moldati Owner

Two parts: the **backend** (Node/Express/Mongo, accounts-only) and the **Flutter
app**. The app works offline after first sign-in; the backend is only needed for
sign-up / sign-in, subscription checks and cloud backup.

## Prerequisites
- Flutter SDK (Dart ≥ 3.9) · Android Studio / a device or emulator
- Node.js ≥ 18 (works on 20/24)

---

## 1) Backend (≈3 steps)

```bash
cd backend
cp .env.example .env          # then edit .env (see below)
npm install
npm run dev                   # http://localhost:4000  (nodemon, auto-reload)
```

`.env` keys (the important ones):

| Key | Default | Notes |
|---|---|---|
| `PORT` | `4000` | API + admin panel port |
| `USE_MEMORY_DB` | `true` | in-memory Mongo (no install needed). **Data is wiped on restart.** Set `false` + `MONGO_URI` to persist |
| `MONGO_URI` | `mongodb://127.0.0.1:27017/moldati` | used only when `USE_MEMORY_DB=false` |
| `JWT_SECRET` | `change-me...` | **change for production** |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | `admin` / `admin123` | seeded admin login |
| `BACKUP_DIR` / `MAX_BACKUPS` | `./backups` / `10` | cloud backup storage |

- **Admin panel:** open `http://localhost:4000/admin` → log in with **`admin` / `admin123`**.
- Seeded plans: `trial` (14d), `monthly` (30d), `yearly` (365d).
- Backend tests: `npm test`.

---

## 2) Flutter app (≈3 steps)

```bash
flutter pub get
# point the app at your backend with --dart-define=API_BASE_URL=...
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000     # Android emulator → host
# physical device on the same Wi-Fi:
#   flutter run --dart-define=API_BASE_URL=http://<your-PC-LAN-IP>:4000
# physical device over USB (no LAN needed):
#   adb reverse tcp:4000 tcp:4000
#   flutter run --dart-define=API_BASE_URL=http://localhost:4000
```

If `API_BASE_URL` is omitted it defaults to `http://192.168.1.99:4000`.

- **First user:** on the login screen tap **“ليس لديك حساب؟ أنشئ حساباً”** (Sign up) and create the owner account. The device is bound automatically (anti-abuse).
- New accounts need an **active plan**: the app shows the plan screen → choose a plan → an admin approves it in the admin panel → pull-to-refresh in the app to enter.
- App tests: `flutter test`.

### Dev helpers (compile-time, off by default)
```bash
flutter run \
  --dart-define=DEV_SEED=true --dart-define=DEV_SEED_COUNT=1000 \  # seed local data
  --dart-define=DEV_ADMIN=true                                     # force management UI
```

---

## Quick end-to-end (local)
1. `cd backend && npm run dev`
2. `adb reverse tcp:4000 tcp:4000` (USB device) then `flutter run --dart-define=API_BASE_URL=http://localhost:4000`
3. Sign up in the app → choose a plan.
4. Open `http://localhost:4000/admin` (`admin`/`admin123`) → Users → approve the plan.
5. Back in the app → pull to refresh → you're in.
