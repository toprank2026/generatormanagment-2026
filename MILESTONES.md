# MILESTONES

Living tracker for **Moldati Owner**. A milestone is added for **every new
feature**. Status: ✅ done · 🔄 in progress · ⬜ todo.

## Core platform
- ✅ Accounts-only **Node/Express/MongoDB backend** (`backend/`) + offline-first Flutter app (`STRUCTURE.md`, `CLAUDE.md`).
- ✅ App uses backend only for **sign-up / sign-in / backup / subscription**; everything else works offline.
- ✅ **Connections** — online/offline handling; only a 401/403 from `/auth/me` ends the session (verified live: 401 → logout, network error → keep cached session).
- ✅ **Device binding** — device fingerprint (install-id + SSAID/vendorId + model/OS, best-effort IMEI/MAC) sent on register; backend enforces plan `maxDevices` (verified: RMX3085 bound).
- ✅ **Same-device (reinstall-safe) login** — device identity keys off the OS-stable `deviceId` first (`backend/src/utils/devices.js` `sameDevice`), so a reinstall / data-clear on the same handset (new `installId`, same `deviceId`) refreshes the existing binding instead of tripping `DEVICE_LIMIT`; only a genuinely different `deviceId` counts as a new device.

## Plans & subscriptions (own backend + API)
- ✅ **Plans/subscriptions on the backend** — list plans, request (→ pending), admin approve/reject, active/expired; app gate enforces an active plan when online.
- ✅ **Current plan system** — Settings → الاشتراك والخطة shows plan, status, start/expiry (verified: trial active, expires 2026-06-20).
- ✅ **Upgrade plan flow** — request a different plan from the plan screen / subscription screen (linked to backend + API).
- ✅ **Plans UI = horizontal cards** (pro-app style carousel).
- ✅ **Plan-approval auto-refresh** — the plan-selection screen polls the subscription status (~12s, online-gated), so an admin approval is detected automatically and the app enters without a manual refresh.
- ✅ **Per-plan capability flags (sync / backup / owner-panel)** — when an admin creates/edits a plan they toggle whether that plan includes each capability (`syncEnabled`, `backupEnabled`, `ownerPanelEnabled`, all default **true** so existing plans keep everything). The account's **active** plan resolves the flags **live** (no User-schema change / no snapshot) and enables/disables each everywhere: the account JSON carries `subscription.features = {sync, backup, ownerPanel}` (attached by the auth controller via `featuresForUser` on login/register/me); the backend gates `/api/sync`, `/api/account`, `/api/backup` with `requireFeature(name)` (→ `403 FEATURE_DISABLED`); the app reads `canSync` / `canBackup` and switches to **offline-only** (hides the sync UI) / **hides the backup tile**; the owner panel shows **"not in your plan"** when its capability is off. Sync/backup/reports **DATA is unchanged** — only **gated**. Admin plan editor gains the three toggles + plan-list capability chips.
- ✅ **Plan cards show per-feature check/cross** — each plan card on the selection screen lists its three capabilities (online sync / cloud backup / owner dashboard) with a **green ✓** when included and a **dimmed red ✗ (strikethrough)** when not, driven by the per-plan flags now parsed into the Dart `Plan` model (`syncEnabled`/`backupEnabled`/`ownerPanelEnabled`, default true). Uses the app's own palette (green `0xFF2E7D32`, red `0xFFD32F2F`, Material icons) and is RTL-correct. Verified on-device: trial (sync✗ backup✗ owner✓), monthly/yearly (all ✓).
- ✅ **Backup offline-gating hardened (defense in depth)** — adversarial re-audit confirmed sync is fully gated when a plan disables it, but the backup **controller** methods (`uploadCloudBackup`/`deleteCloudBackup`/`restoreCloudBackup`/`_performCloudRestore`) only checked connectivity. Added `if (!auth.canBackup) return;` guards (silent — a disabled feature must never notify) plus a `canBackup` gate on the BackupScreen cloud section, so a no-backup plan can never fire a backup network call or surface a backup snackbar regardless of how the screen is reached.

## Auth & accounts
- ✅ **Sign-up = name + phone + password only** (phone is the login identifier; login is by phone).
- ✅ Login / sign-up / subscription gate flow.
- ✅ **Pull-to-refresh session re-check** — pulling to refresh the dashboard (when online) re-validates the account with the server; if the account is **blocked**, the **subscription expired**, or the **plan changed** to a non-active state, the user is signed out to the login screen with a suitable warning banner. Verified live (RMX3085): active → stays; blocked → "account disabled"; expired → "subscription expired".
- ✅ **Plan time remaining on the dashboard banner** — the plan row shows e.g. `MONTHLY_29days` (or `MONTHLY_expired`), computed from the subscription expiry date.
- ✅ Owner has full in-app **CRUD** (create/edit/delete board, circuit, subscriber).
- ✅ **Periodic expiry/block re-check + auto-logout after long offline** — the app re-validates the session on a timer/foreground (online-gated `/auth/me`); a blocked account or inactive subscription signs out to login with a warning, and a device that stays offline past a grace window is auto-logged-out so a revoked account cannot keep running indefinitely on a stale cached session.
- ✅ **Session re-check on bottom-nav navigation** — switching bottom-nav tabs triggers the same online expire/block re-validation as pull-to-refresh (throttled to once per 60s).
- ✅ **Dev time overrides for session checks** — dart-defines `RECHECK_SECONDS` (default 900) and `OFFLINE_LOGOUT_SECONDS` (default 259200 = 3 days) make the periodic re-check and offline auto-logout testable; production builds (no defines) keep the defaults.

## Data & features
- ✅ **GetX + pagination on every list screen** (subscribers, boards, circuits, expenses, users, receipt history, payment history).
- ✅ **Expenses — sync + pagination** — expenses are part of the per-account synced tables (mirrored device→server like the other business entities) and the expenses list paginates via the canonical pattern; admins see them on the Expenses synced-data screen.
- ✅ **Separate paginated Paid-Bills History** screen per subscriber.
- ✅ **Backup feature** — cloud upload/list/restore/delete (verified: upload 201, 92 KB, timestamp) + local export/import.
- ✅ **Offline sync** — local SQLite source of truth, changes pushed to server mirror (`sync_outbox` triggers → `SyncService` → `/api/sync`); auto-sync on connectivity + 30s heartbeat; **ask-before-large-upload** (>100 pending) else silent.
- ✅ **Two-way sync** — pull (server→device) restores a per-account mirror onto a device; outbox-suppressed so a pull never re-pushes.
- ✅ **Delete local data (Settings)** + dashboard up-to-date status & pull-latest button.
- ✅ **Dashboard banner sync area = two rows** — row 1: sync (push) button + pending-changes status; row 2: update (pull) button + last-update status.
- ✅ **Admin panel: separate screen per synced entity** (Subscribers / Boards / Circuits / Receipts / Expenses / Monthly prices) at `#/users/:id/data/:entity`.
- ✅ **Admin synced-data screens: search + server-side pagination + delete on all 6 entity screens** (read-only mirror; sync stays push-only). `GET /api/admin/users/:id/data` takes `q,page,limit` and returns `total,page,limit`; `DELETE /api/admin/users/:id/data/:entity/:localId` hard-deletes one mirrored record.
- ✅ **Public receipt verification page** — scan the receipt QR (no login) to open `/admin/#/r/:uuid`, a standalone Arabic receipt page rendered without the sidebar/auth gate; backed by public `GET /api/public/receipt/:uuid` (no auth) that looks up the receipt by uuid across all accounts and returns receipt + subscriber name + generator name.
- ✅ **Admin panel fully Arabic (RTL)** — sidebar layout; all admin screens/labels in Arabic, right-to-left.
- ✅ **Real-time new-account notification (SSE)** — the backend streams a Server-Sent Event when a new account registers; the admin panel subscribes and shows a live pop-up so admins see sign-ups in real time without refreshing.
- ✅ **Admin subscriber statement** — per-subscriber payment history (kashf hesab) view in the admin panel.
- ✅ **Owner self-service panel** — an owner (app account) can log into the admin panel URL with their app credentials and sees **only their own** dashboard + data (stats cards, Subscribers/Boards/Circuits/Receipts/Expenses/Monthly prices, subscriber statement, receipt details — read-only); admin features (Users/Plans/SSE/mirror deletes) are hidden and route-guarded. Backed by `GET /api/account/data` + `GET /api/account/stats` (auth, JWT-scoped).
- ✅ **Owner panel: app-style dashboard with paid/unpaid stats** — the owner dashboard shows المشتركين المسددين / المشتركين غير المسددين cards plus totals, computed **server-side from the mirror with the app's exact formula** (subscriber paid ⇔ sum of `paid_amount` for the current month ≥ `amps × price_per_amp`; price absent ⇒ everyone paid, matching the app); `GET /api/account/stats` gained a `dashboard` object.
- ✅ **Owner panel UI = Flutter-app look** — blue gradient banner (generator name / phone / plan as `plan_Ndays`), "نظرة عامة" 2-column stat cards, and a **fixed bottom navigation bar** (الرئيسية / المشتركون / الوصولات / المصروفات / المزيد) in a phone-like centered layout — clearly distinct from the admin UI, which is unchanged (sidebar).
- ✅ **Human board/circuit names in panel tables** — circuits tables and subscriber statements (owner **and** admin screens) resolve `board_id`/`circuit_id` to the actual board/circuit **names**; raw UUIDs are no longer shown.
- ✅ **Monthly reports & statistics (التقارير) — app tab** — new bottom-nav tab → Reports screen with a month picker (prev/next), a **gauge** (collection rate), a **donut** (paid/unpaid subscribers), **bars** (collected / expenses / net profit), a totals grid (expected, collected, remaining, expenses, **net profit = collected − expenses**), and the month's payments list. Computed **fully offline** from local SQLite (receipts / expenses / subscribers / monthly_prices) by the new `ReportsController` + pure-`CustomPainter` chart widgets (`lib/views/widgets/report_charts.dart`) — **no new dependencies**, paid/unpaid uses the app's exact formula.
- ✅ **Backend: month-scoped owner stats** — `GET /api/account/stats?month=YYYY-MM` (optional; validated, default = current UTC month) selects which month the `dashboard` object describes; `dashboard` gains `expensesTotal` (that month's expenses) and `netProfit` (= collected − expensesTotal).
- ✅ **Owner panel: التقارير tab** — bottom-nav tab → `#/my/reports` rendering the **same gauges/charts (SVG)** + totals + payments list from the mirror via the month-scoped stats endpoint, so panel numbers match the app for the same month.
- ✅ **Reports need no sync/schema change** — reports are **derived** from the already-synced & already-backed-up tables; existing push/pull/backup cover all report inputs (nothing new to sync, no DB version bump).
- ✅ **App: record payment + print invoice from the payment-history screen** — log a payment and print its receipt directly from a subscriber's payment-history screen.
- ✅ **Verified live (RMX3085 + Chrome MCP):** small change auto-synced (board → admin Boards screen); 150-record seed → confirm dialog "253 changes pending — upload now?" → uploaded only on confirm → admin Subscribers (150).
- ✅ Billing (per-amp monthly price, receipts, Bluetooth print), expenses, dashboard.
- ✅ **Thermal printer paper-width setting (58mm / 80mm)** — a Settings option selects the printer paper width; the Bluetooth receipt renders at the chosen width so receipts print correctly on both 58mm and 80mm thermal printers.
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
