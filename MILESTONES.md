# MILESTONES

Tracker for everything requested for **Moldati Owner** (generator-management app
+ accounts-only backend). Status: ✅ done · 🔄 in progress · ⬜ todo.

> The app is offline-first: all business data (boards, circuits, subscribers,
> monthly prices, receipts, expenses) lives in local SQLite; the Node backend is
> accounts-only (auth, subscription/plans, device binding, cloud backup).
> See `STRUCTURE.md` (architecture) and `CLAUDE.md` (dev guide).

## Architecture & backend
- ✅ **M1** — Apply the `STRUCTURE.md` architecture to this project (without changing its idea/flow): GetX layered frontend + accounts-only backend.
- ✅ **M2** — App talks to the backend **only** for sign-up / sign-in / backup; everything else works **offline** (cached session; only a 401/403 ends it).
- ✅ **M3** — **Check subscription/plan when online** (root gate → PlanSelection when inactive; never blocks a purely-offline user).
- ✅ **M4** — On **register, send device info** (install-id + Android SSAID/iOS vendorId + model/brand/OS, best-effort IMEI/MAC via native channel) for anti-abuse **device binding**; backend enforces the plan's `maxDevices`.
- ✅ **M5** — New **Node/Express/MongoDB** backend (`backend/`): `/auth`, `/subscription`, `/device`, `/backup`, `/admin`; JWT + bcrypt; in-memory Mongo for dev; seed (plans + bootstrap admin). Contract in `backend/API_CONTRACT.md`.
- ✅ **M6** — **Admin panel** (single-file web SPA at `/admin`) for users / plans / devices / approvals.
- ✅ **M7** — **Cloud backup** of the local DB via the backend (upload / list / restore / delete), online-gated.

## Frontend (GetX) & UX
- ✅ **M8** — **GetX everywhere** with a central `AppBinding` (screens use `Get.find`, no per-screen `Get.put`).
- ✅ **M9** — **Pagination on every list screen**: subscribers, boards, circuits, expenses, users (settings), receipt history, and the dedicated payment-history screen.
- ✅ **M10** — Auth flow: Login / Sign-up screens + subscription gate (`root_handler`).
- ✅ **M11** — **Default language = Arabic** (full RTL).
- ✅ **M12** — **Every text in the app is Arabic** (all hardcoded English replaced with `.tr` keys; en + ar maps in parity; 0 leak keys, verified by audit + test).
- ✅ **M13** — **App launcher icon** = `spark.png` (Android adaptive + iOS), default was `bolt.png`.
- ✅ **M14** — **CRUD buttons available to the owner** (create/edit/delete board, circuit, subscriber) — the account `owner` role now has full in-app management rights.
- ✅ **M15** — **Separate Paid-Bills History screen** per subscriber, **paginated** (opened from the subscriber detail).
- ✅ **M16** — **Settings → Subscription section + screen**: shows current plan, status, start/expiry, refresh status, and **upgrade / change plan**.

## Quality, testing & ops
- ✅ **M17** — **Multi-agent scenario audit** (60 read-only agents over every flow) → triaged → **repaired the real bugs** (cascade deletes, paid-filter `valid`-only, parsing hardening, backend edge cases, UI fixes).
- ✅ **M18** — **Automated test suite (64 tests)**: Flutter (`flutter test`) — models, repositories (cascade/pagination via `sqflite_common_ffi`), translations parity, widget; Backend (`cd backend && npm test`) — full API integration. Replaced the broken default counter test.
- ✅ **M19** — **On-device verification (Realme RMX3085)**: offline-first session, **1000 subscribers + receipts** seed (scale/perf), dashboard aggregates, list pagination, **cascade delete at scale** (1014→14), Arabic RTL, spark icon, payment-history screen, admin panel in Chrome.
- ✅ **M20** — **Committed & pushed** to GitHub (`toprank2026/generatormanagment-2026`, branch `main`).
- ✅ **M21** — This `MILESTONES.md` tracking every ordered point.

## How to run
- Backend: `cd backend && npm install && npm run dev` (→ `http://localhost:4000`, admin panel `/admin`, default `admin` / `admin123`).
- App: `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000` (emulator) or the LAN IP for a device.
- Tests: `flutter test` and `cd backend && npm test`.
- Dev helpers (compile-time flags, off by default): `--dart-define=DEV_SEED=true --dart-define=DEV_SEED_COUNT=1000` (seed local data), `--dart-define=DEV_ADMIN=true` (force management UI).

## Possible follow-ups (not requested)
- ⬜ Localize the admin web SPA (currently English; it's the operator tool).
- ⬜ Wrap receipt-number generation in a transaction (single-user race is near-impossible today).
- ⬜ Add an index on `expenses.date`; schema migration path (DB is v1, `onCreate` only).
