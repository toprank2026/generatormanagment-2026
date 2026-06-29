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
- ✅ **Accountant sub-users (multi-user) + full per-accountant isolation** — the owner (admin) creates **accountant sub-accounts** that sign in **offline** (local credential) and become the *acting user*. Every business entity is attributed (`accountant_id`); an accountant sees ONLY their own subscribers/boards/circuits/receipts/expenses/reports, the owner sees all (with an accountant **filter** + **count** on app reports and the owner web panel). Schema v2→v4 (accountant_id columns; users gain name/active/permissions; new **synced** `accountants` identity table — no passwords). Receipts attributed to the subscriber's accountant; printed invoice shows the **المحاسب** line resolved from `receipt.accountant_id` (Bluetooth + PDF). Profile-switch UI (owner⇄accountant, password-checked, persisted) + reactive re-scoping of all controllers on switch. Carried through sync (whole-row) + backup (whole-DB) with **no new flow**. Super-admin panel gains a browsable `accountants` data tab. See `ACCOUNTANTS_TEST_REPORT.md`.
- ✅ **Per-accountant permissions** — when creating/editing an accountant the owner grants any of: manage subscribers / boards & circuits / expenses / prices (default none; **collect payments + print are always allowed**). `AuthController.can(perm)` gates create/edit/delete on each screen; an accountant's new record auto-assigns to themselves; assigning a record to a specific accountant stays owner-only. Debug seeder (`--dart-define=SEED_TEST_DATA=true`) seeds an accountant + data + receipt for testing.
- ✅ **Multi-Branch (full isolation) + per-plan gating** — one owner account can run **multiple fully-isolated branches** (each its own ERP instance: subscribers, boards, circuits, receipts, expenses, prices, reports). **Additive** layer (no engine/business-logic refactor): every business row gains a `branch_id`; reads scope to the **active branch** and creates **stamp** it (`BranchController.scopeBranchId`/`writeBranchId`); legacy data is mapped into a fixed **Main Branch** (`id='main'`) by the schema **v4→v5** migration (backfill + `monthly_prices` reshaped to a synthetic per-branch PK `"<month>|<branchId>"`). **Per-branch** receipt numbering (D-3) and pricing (D-4). Owner UI: a **Branches** management screen (create/edit/delete-with-cascade; Main protected) + a dashboard **active-branch selector** with an "All branches (consolidated)" reporting view — both gated on `auth.canMultiBranch`. Gated as a **per-plan upgrade** (`multiBranchEnabled`, default **false** — opt-in, unlike the default-true flags): admin plan editor toggle + plan-card check/cross. Carried through **sync (whole-row)** + **backup (whole-DB)** with no new flow; the `branches` entity + a `?branchId` dashboard filter are added to the admin/owner panels. See `specs/multi-branch/IMPLEMENTATION_REPORT.md`. Verified: 73 Flutter + 70 backend tests (incl. branch isolation, per-branch numbering/pricing, cascade delete, v4→v5 migration backfill, and branch-scoped `/api/account/stats?branchId`).

## v7 fix batch (global month, categories everywhere, accountant accounts, branch-switch sync)
- ✅ **Global selected-month (single source of truth)** — new permanent `MonthController` owns the billing month; the **Monthly Pricing screen is the ONLY place that changes it**, and the dashboard banner, subscriber detail, payment history, billing **and expenses** all read it read-only and re-bind via `ever()`. Opening a subscriber from Home now uses the Home month (no more reset-to-now). (R6/R9)
- ✅ **Three required category prices** — Monthly Pricing is a validated `Form`; Gold / Regular / Commercial per-amp prices are all required (no partial save) and saved atomically (`BillingController.setPrices`). The upper price card shows **all three** current per-amp prices. (R4)
- ✅ **Category filter tab bar** on All / Paid / Unpaid subscriber screens (All · Gold · Regular · Commercial), rendered **under the search field**; threaded through `CoreController` + the repositories (incl. the positional-arg `getByPaymentStatus` SQL). Add-Subscriber FAB now shows **only on All Subscribers**. (R3/R5)
- ✅ **Duplicate board/feed names rejected** — `BoardRepository`/`CircuitRepository.nameExists` (per branch / per board) + `ValidationException` surfaced in the board/circuit dialogs. (R1)
- ✅ **Branch switch clears + pulls from server** — switching a branch pushes pending, wipes local data, pulls the account mirror fresh and re-activates the branch behind a **blocking progress overlay**; offline falls back to a local-only switch. Large push/pull show the overlay so big transfers can't crash the UI. (R7 + loading)
- ✅ **Accountant = real backend sub-account** — accountants are created as backend accounts (role `accountant`, owner ref, branch, permissions, `localId`) via `POST /api/account/accountants`, tied to a branch, and **log in through the normal Login screen**; they inherit the owner's subscription, are device-limit-exempt, and operate on the **owner's mirror** (effective-owner scoping). Blocking/deleting/disabling an accountant (or **blocking the owner**) is enforced server-side; the owner's plan-feature gates apply to accountants. After login the accountant pulls the owner's data and is confined to its branch. (R8)
- ✅ **Seeded test account for manual data testing** — `cd backend && npm run seed:demo` provisions `07701234567 / 1234` (owner, active multi-branch plan) + two accountant logins, and a full mirror dataset: 3 branches, 9 boards, 27 circuits, 100 subscribers across the three categories, per-category monthly prices (current + previous month), ~50 paid receipts, 12 expenses. Verified: backend dashboard reports 100 subs / 50 paid / 50 unpaid.
- ✅ **Adversarial multi-agent review** of the batch (10 findings) → fixed (incl. a critical branch-switch data-loss race and the accountant authorization holes) with backend regression tests. Suites: **83 Flutter + 82 backend** green. Spec-Kit under `specs/v7-fixes/`.

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

## Flash v12
- ✅ **Credit-card wallet** — a second accountant wallet (alongside Cash) for card-paid receipts: `settlements.method` ('cash'|'card', schema v11→v12), per-method balance (collected − approved settlements), server-authoritative `GET /api/account/wallet` returns `{cash,card}`, owner-panel settlements show the method.
- ✅ **Wallet pull-on-open** — My Wallet pulls latest receipts + owner decisions before showing balances.
- ✅ **Broader auto-sync** — `poke()` now also fires on accountant creation (all writes covered).
- ✅ **Hard logout** — confirm → loading overlay → wipe **ALL** local tables (`DbHelper.wipeAllTables`, outbox cleared last to avoid tombstone data-loss) → only then clear session.
- ✅ **Payments-of-month** moved out of Reports into its own `PaymentsScreen`.
- ✅ Adversarial review (1 HIGH + 1 MED + 1 LOW) fixed; Tikrit release APK built; pushed to `main`.

## Flash v13
- ✅ **Role separation** — billing is ACCOUNTANT-only (owner/admin can't bill: collectPayment no-ops + collect/record UI hidden); pricing is OWNER/admin-only (accountants can't edit: setPrice/setPrices no-op + pricing editor hidden).
- ✅ **Independent branch generators** — a new branch is a full generator with its OWN plan (plan picker on create) + its own **super-admin approval** (`User.independentPlan`; gated on its own subscription via `effectiveOwner`/auth). LEGACY branches still inherit the parent (backward-compat). Complete data isolation (separate mirrors).
- ✅ **Accountant inherits the owner** (plan/approval/features) → logs in directly + syncs immediately; fixed "password incorrect after logout" (offline profile-switch falls back to a real online login when the wiped local credential is gone).
- ✅ **Main branch shown** in the owner-panel switcher as the first NAMED entry (original generator name); banner shows the selected branch (الفرع: name + branch phone).
- ✅ **Switch accountant/branch** → confirm → wipe ALL local + clear wallet → load new identity.
- ✅ **Settlement decision fix** — approving/rejecting a NON-main-branch settlement now targets the branch mirror (was "Settlement not found").
- ✅ **Reports** — owner-panel reports match the app (gauge/donut/bars/cards/prices + per-tariff PAID counts) and now re-scope to the selected accountant.
- ✅ Spec-kit + read-only mapping + adversarial review; Flutter 90, backend 131; Tikrit release APK.

## Flash v16 (Home UI polish + in-app settlement + accountant receipt name)
- ✅ **Home cards standardized & overflow-safe** — card numbers slightly larger and wrapped in `FittedBox(scaleDown)` so big amounts never clip on small phones; card **height is responsive** (screen-width-based aspect ratio, not the old fixed `1.3`).
- ✅ **Responsive Home-card icons** — icon size scales by screen width (tablet 30 / phone 24).
- ✅ **Full-width money cards** — only **Collected** (إيراد الشهر) and **Remaining** (المتبقي) span the full row for large-number clarity (bigger value font 30/36); the other six cards stay in the 2-up grid.
- ✅ **Fixed app-wide fonts** — `GetMaterialApp.builder` clamps `MediaQuery.textScaler` to `TextScaler.noScaling`, so text never changes with the device font-size setting.
- ✅ **SafeArea on every list screen** — ~21 screens' Scaffold bodies wrapped in `SafeArea` (lists no longer clipped by notches/gesture bars); FAB/bottom-nav slots untouched.
- ✅ **In-app accountant settlement (Admin-only)** — a new `AccountantSettlementsScreen` in Settings lists settlement requests (pending first) with approve/reject; offline-first decision updates the local `settlements` row (`SettlementRepository.decide`) → `poke()` → mirror → accountant pulls it (mirrors the Owner Panel; no new endpoint).
- ✅ **Account-switch wipe made explicit** — switching to an owner/accountant already deletes ALL local SQLite data like logout (then re-pulls); the confirm popup now spells that out (subscribers/boards/circuits/receipts/expenses/wallet).
- ✅ **Accountant receipt header** — an accountant's serialized account now inherits the **owner's `generatorName`** (backend `authController` login + `/me`), so a receipt printed under an accountant shows the generator name at the top (Bluetooth + PDF).
- ✅ Spec-kit + read-only mapping + adversarial review (0 findings); Flutter 90, backend 146; analyze 0 errors/0 warnings; Flash-API release APK.

## Flash v17 (logout data-loss guard)
- ✅ **Block logout when unsynced data exists** — a user-initiated logout (`wipeLocal:true`, Home + Settings) now REFUSES to wipe local SQLite + end the session while there are unsynced records (`sync_outbox` / `pendingCount>0`). Order (before any delete/teardown, all roles): sync running → disable logout (`logout_sync_running`); online → best-effort push first; re-check outbox; still unsynced → BLOCK with `logout_blocked_unsynced` and keep ALL data; only `pendingCount==0` → confirm + wipe + clear session (unchanged).
- ✅ **Sync-disabled-plan safe** — the guard only applies when the plan enables sync (`canSync`); offline-only plans (whose outbox can never reach the server) fall through to the existing offline confirm+wipe instead of being locked out of logout forever (adversarial-review HIGH fix).
- ✅ Removed the in-app account SWITCH from Settings (owner/admin + accountant) — it left a flaky token/secure-storage state; logout+login is the reliable path.
- ✅ Spec + direct edit + adversarial review (1 HIGH fixed); analyze 0/0; Flutter 90; no backend/panel change needed; Flash-API release APK.

## Flash v18 (device rebind confirm + dialog dispose + branch count + sync settings)
- ✅ **Device unbind/rebind confirmation** — before Logout / Create branch / Create accountant the user confirms that THIS device's binding will be removed + recreated so another account can use it (avoids DEVICE_LIMIT). Reuses the existing self endpoints (`DeviceRepository.unbind`+`bindCurrent`, new `rebindCurrent`) + `SecureStore.clearInstallId`; logout integrates the note into its existing confirm and unbinds (rebind on next login), create-branch/accountant confirm-then-rebind before creating. Best-effort + online-gated + never throws.
- ✅ **Loading-dialog dispose audit** — verified create-circuit/board/branch/accountant/logout/sync all close overlays on success AND failure (try/finally, snackbar AFTER close, no stacking — SyncProgress is latch-guarded); new device dialogs follow the same pattern. No leak found.
- ✅ **Owner-panel branch count fix** — `getMyStats.counts.branches` now counts branch SUB-ACCOUNTS (`User.countDocuments({parentOwner})`, the authoritative source the branch switcher uses) instead of the synced `branches` mirror rows (which stuck at ~1).
- ✅ **Simplified Settings sync section** — removed the cloud Backup tile, the Sync screen tile, and the delete-local-data tile; kept only the local **Export/Import** (subscriber backup) + Manage Devices.
- ✅ Spec + read-only mapping (4 agents) + coupled edits + adversarial review (clean); analyze 0/0; Flutter 90; backend 146; Flash-API release APK.

## Flash v19 (responsive Home cards + app-wide IQD money formatting)
- ✅ **Responsive Home cards** — phones (<600px) keep the EXACT prior sizing; tablets/landscape now adapt: columns 2→3 (≥600) → 4 (≥1000), bigger icon/value/label fonts + padding, and the grid aspect ratio derived from a TARGET card height so cards never balloon. Money cards stay full-width with a larger responsive value font.
- ✅ **Thousands-separator IQD formatting app-wide** — new `lib/utils/money.dart` `fmtAmount(num)` ('#,##0', en_US → "1,000,000"); applied to every displayed monetary value (dashboard Collected/Remaining, reports, payments, payment history, subscriber due, collect-payment dialog, expenses, wallet, settlements, printed Bluetooth + PDF receipts, report bars). Editable amount fields left raw (parse-safe); amps/counts/dates untouched. Currency unit ('iqd'.tr) append preserved for RTL.
- ✅ Read-only mapping + per-file format workflow + adversarial review (clean); analyze 0/0; Flutter 90; Flash-API release APK.

## Backlog
- ⬜ Localize backend plan names/descriptions (currently English server data).
- ⬜ DB migration path (schema v1, `onCreate` only); index on `expenses.date`.
