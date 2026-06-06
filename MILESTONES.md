# MILESTONES

Living tracker for **Moldati Owner**. A milestone is added for **every new
feature**. Status: ✅ done · 🔄 in progress · ⬜ todo.

## Core platform
- ✅ Accounts-only **Node/Express/MongoDB backend** (`backend/`) + offline-first Flutter app (`STRUCTURE.md`, `CLAUDE.md`).
- ✅ App uses backend only for **sign-up / sign-in / backup / subscription**; everything else works offline.
- ✅ **Connections** — online/offline handling; only a 401/403 from `/auth/me` ends the session (verified live: 401 → logout, network error → keep cached session).
- ✅ **Device binding** — device fingerprint (install-id + SSAID/vendorId + model/OS, best-effort IMEI/MAC) sent on register; backend enforces plan `maxDevices` (verified: RMX3085 bound).

## Plans & subscriptions (own backend + API)
- ✅ **Plans/subscriptions on the backend** — list plans, request (→ pending), admin approve/reject, active/expired; app gate enforces an active plan when online.
- ✅ **Current plan system** — Settings → الاشتراك والخطة shows plan, status, start/expiry (verified: trial active, expires 2026-06-20).
- ✅ **Upgrade plan flow** — request a different plan from the plan screen / subscription screen (linked to backend + API).
- ✅ **Plans UI = horizontal cards** (pro-app style carousel).

## Auth & accounts
- ✅ **Sign-up = name + phone + password only** (phone is the login identifier; login is by phone).
- ✅ Login / sign-up / subscription gate flow.
- ✅ Owner has full in-app **CRUD** (create/edit/delete board, circuit, subscriber).

## Data & features
- ✅ **GetX + pagination on every list screen** (subscribers, boards, circuits, expenses, users, receipt history, payment history).
- ✅ **Separate paginated Paid-Bills History** screen per subscriber.
- ✅ **Backup feature** — cloud upload/list/restore/delete (verified: upload 201, 92 KB, timestamp) + local export/import.
- ✅ **Offline sync** — local SQLite source of truth, changes pushed to server mirror (`sync_outbox` triggers → `SyncService` → `/api/sync`); admin views synced data; ask-before-large-upload.
- ✅ Billing (per-amp monthly price, receipts, Bluetooth print), expenses, dashboard.
- ✅ **Arabic everywhere** (default Arabic RTL; all text via `.tr`).
- ✅ App launcher icon = `spark.png`.

## Quality, docs & ops
- ✅ **Testing system** — 64 automated tests: Flutter (`flutter test`) + backend (`cd backend && npm test`).
- ✅ Multi-agent scenario audit → bug fixes (cascade deletes, paid-filter, parsing, backend edge cases).
- ✅ On-device verification (Realme RMX3085) of the flows above.
- ✅ `RUN.md` (run steps + creds/env) · `CUSTOMER_WORKFLOW.md` (customer guide) · removed stale `readme.html`.
- ✅ Committed & pushed to GitHub (`toprank2026/generatormanagment-2026`, `main`).

## Backlog
- ⬜ Localize backend plan names/descriptions (currently English server data).
- ⬜ DB migration path (schema v1, `onCreate` only); index on `expenses.date`.
