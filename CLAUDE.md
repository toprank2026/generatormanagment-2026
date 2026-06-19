# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"Moldati Owner" (`generatormanagment`) — a Flutter app for managing a private **electricity generator** business: subscribers, electrical **boards** and **circuits** (جوزة), monthly per-amp **billing**, **expenses**, and **receipts** printed on Bluetooth thermal printers. UI is bilingual (Arabic `ar_AR` / English `en_US`).

The system is offline-first with a server mirror (see `STRUCTURE.md`, which is accurate):
- **All business data** (boards, circuits, subscribers, monthly prices, receipts, refunds, expenses) has the device's local SQLite DB (`moldati.db`) as its **source of truth** — the app works fully offline. Those changes are now also **pushed (synced) to a per-account server mirror** via `/api/sync` so the **admin panel can view each owner's data**. **Accountants** are now real backend sub-accounts (own login, scoped to the owner's mirror — see Architecture), not device-only.
- The **backend** (`backend/`, Node/Express/MongoDB) owns authentication, subscription/plans, device binding, opaque **cloud DB backups**, and the **sync mirror** (a read-only copy for admins — the app never reads business data back from it in normal use).
- The **admin per-entity synced-data screens** (Subscribers/Boards/Circuits/Receipts/Expenses/Monthly prices) support **search + server-side pagination + delete**; the mirror stays push-only (device→server) — admins can only delete a mirrored record, never create/edit it.
- **Sync engine** (already built — do not change it): SQLite triggers write every change to a local `sync_outbox` table; `lib/core/sync_service.dart` (`SyncService`) drains it and POSTs to `/api/sync/push`; `lib/controllers/sync_controller.dart` (`SyncController`) auto-syncs on connectivity/timer and asks before large uploads. Sync is now **two-way and strictly per-account** (scoped to the JWT user): besides push (device→server), `SyncService.pull({since})` restores the account's mirror back onto a device (new device, or after clearing local data) by writing into SQLite and clearing the outbox rows that pull generates so a pull never re-pushes. Settings exposes **delete-local-data** (`SyncService.deleteLocalData()` wipes the 7 business tables + outbox; the server mirror is untouched), and the dashboard shows an **up-to-date status + pull-latest button**.
- The app is **offline-first**: the network is only needed for register / sign-in, subscription checks, cloud backup, and pushing pending changes to the mirror.

## Commands

### Flutter app
```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000   # emulator → host backend
flutter run --dart-define=API_BASE_URL=http://192.168.1.99:4000 # physical device on LAN
flutter analyze                       # lint (flutter_lints); 0 errors/warnings, ~45 info (mostly withOpacity deprecations)
dart format .
flutter test                          # run all; single file: flutter test test/v8_discount_test.dart
flutter build apk --release
```
`API_BASE_URL` defaults to the **live production server** `https://generator.tikritstore.shop` (see `lib/core/api_config.dart`) when no `--dart-define` is given — so a plain `flutter build apk --release` ships pointed at production. Pass `--dart-define=API_BASE_URL=...` only to point at a local/LAN backend for dev.

### Backend (`backend/`)
```bash
cd backend && npm install
npm run dev      # nodemon, http://localhost:4000, in-memory Mongo by default (USE_MEMORY_DB=true)
npm start        # node src/server.js
npm run seed     # seed default plans
npm run seed:demo # seed a full TEST ACCOUNT (07701234567 / 1234) into the running backend over HTTP: 3 branches, 100 subscribers across categories, prices, ~50 paid receipts, expenses, 2 accountant logins. Run against any backend via BASE_URL=...
npm test         # node --test, in-memory Mongo (currently 100 tests)
```
Copy `.env.example` → `.env` and set `JWT_SECRET`, `ADMIN_USERNAME/PASSWORD`; set `USE_MEMORY_DB=false` + `MONGO_URI` for persistence. Admin SPA: `http://localhost:4000/admin`. The endpoint contract is `backend/API_CONTRACT.md` (source of truth). `node --check <file>` is the quick JS syntax check (no JS lint pipeline in this repo). NOTE: `npm test`/`seed:demo` and `seed` each connect their own DB; with the default in-memory Mongo, a separate seed script process can't share data with a running `npm run dev` — `seed:demo` avoids this by talking to the running server over HTTP.

## Architecture

GetX-based MVC, strictly layered, one direction:

```
View (Obx/GetBuilder)  →  Controller (GetxController, Rx)  →  Repository  →  DbHelper (SQLite)
                                                            ↘  auth/subscription/device/backup repo → core/api_client → backend
```

- **Views never touch the DB or backend directly.** Only repositories do. Local-data repos return typed models; the four online repos (`auth_`, `subscription_`, `device_`, `backup_repository`) talk to the backend via `core/api_client`.
- **Dependency injection is centralized** in `lib/core/app_binding.dart` (set as `GetMaterialApp.initialBinding`). `AuthController` is `permanent`; feature controllers are `lazyPut(fenix:true)`. **Screens resolve controllers with `Get.find<X>()` — never `Get.put`** (the one exception is the screen-local `MainNavController` in `main_screen.dart`). When adding a controller, register it in `AppBinding`.
- **Models** (`lib/data/models/`) are hand-written `toMap`/`fromMap` (local) or `fromJson`/`toJson` (remote: `account.dart`, `plan.dart`). No codegen. Local IDs are UUID strings; `receipts.receipt_no` is a sequential int.

### `lib/core/` — the accounts/online layer
- `api_config.dart` — base URL (`--dart-define=API_BASE_URL`) + endpoint paths.
- `api_client.dart` — single REST client; injects Bearer JWT, normalizes errors to `ApiException` (`.isAuthError`, `.isNetworkError` where `statusCode==0` means offline); supports multipart upload + byte download (cloud backup).
- `secure_store.dart` — JWT + a persistent **install-id** (survives logout) in `flutter_secure_storage`.
- `session_cache.dart` — caches the account for offline-first launch (SharedPreferences); `clear()` on logout also clears the per-account backup timestamp.
- `connectivity_service.dart` — `isOnline()` gate for the online-only actions.
- `device_info_service.dart` — device fingerprint for binding; **attempts IMEI/MAC** via a native MethodChannel (`moldati/device`, implemented in `android/.../MainActivity.kt`) but these return null on Android 10+/iOS, so binding keys off `installId` + SSAID/identifierForVendor.
- `app_binding.dart` — central DI.

### Auth / session / gate (offline-first)
- `AuthController.bootstrap()` restores the cached account on launch, then (only if online) calls `/auth/me`. **Only a 401/403 ends the session**; network errors keep the cached offline session.
- `subscriptionBlocked` is set true **only when the server (while online)** says the subscription is inactive or the account is blocked — never blocks a purely-offline user on stale state.
- `root_handler.dart` gate: loading → spinner; not signed in → `LoginScreen`; `subscriptionBlocked` → `PlanSelectionScreen`; else → `MainScreen`.
- `AuthController.currentUser` is a backward-compatible `User` view of the account (so existing `auth.currentUser.value?.id/.role` calls keep working); `account`/`subscription` hold the full server objects. The local `users` table remains for in-app staff management (settings).
- Register/login send the device fingerprint; the backend enforces the plan's `maxDevices` (403 `DEVICE_LIMIT`).

### Global selected-month (single source of truth)
`MonthController` (`lib/controllers/month_controller.dart`, `permanent`) holds the one billing month (`RxString selectedMonth`). It is **mutated ONLY from the Monthly Pricing screen** (`setMonth`); the dashboard banner, subscriber detail, payment history, and expenses show it **read-only** and re-bind via `ever(month.selectedMonth, ...)`. `DashboardController.currentMonth` and `BillingController.selectedMonth` are getters onto this shared `RxString` (so existing `.value` reads stay reactive). Changing the month re-runs dashboard stats + billing in lockstep, and a subscriber opened from Home uses that month.

### Branch context (multi-branch, full isolation)
`BranchController` (`permanent`) holds the active branch; every business row carries `branch_id`; reads scope to it and writes stamp it. `monthly_prices` PK is the synthetic `"<month>|<branchId>|<category>"`. Switching a branch (`SyncController.switchBranch`) does **push pending → clear local → pull account mirror → re-activate the branch** behind a blocking overlay when online; offline falls back to a local-only switch. Gated by the plan's `multiBranchEnabled` (default off). Accountants are confined to their assigned branch.

### Subscriber categories + per-category pricing (gold / standard / commercial)
`SubscriberCategory` (`commercial`|`standard`|`gold`). Each subscriber has a `category`; `monthly_prices` is per `(month, branch, category)`. Due = `amps × price[category]`; paid/unpaid is **derived** (no stored status) by `SubscriberRepository.getByPaymentStatus` (a raw, positional-arg SQL LEFT JOIN — when editing, keep the `args` order matching the `?` placeholders) and the category-aware `BillingController.getDueAmount`. Subscriber list screens have a category tab bar.

### Accountants = real backend sub-accounts
An accountant is a backend `User` (`role: accountant`, `owner` ref, `branchId`, `permissions[]`, `localId`) created by the owner via `POST /api/account/accountants`, **logging in through the normal Login screen**. Backend scopes their sync/data to an **effective owner** (`role==='accountant' ? owner : _id`) so they operate on the owner's mirror; they're device-limit-exempt and inherit the owner's subscription/features. A blocked/missing owner blocks the accountant (`authController` login/me + `requireAuth`); `requireFeature` resolves features via the owner. The local `users`/`accountants` tables still exist (offline profile-switch + synced identity for attribution by `localId`).

### Discount on collection (full payment only)
`collectPayment(sub, amount, {fullPayment, discountType, discountAmps, discountValueInput})` — a discount applies ONLY on a full payment (enforced in the controller, not just the UI). ampere: value = `amps × pricePerAmp`; value: entered IQD. The subscriber pays `due − discountValue` cash and is **fully paid**: coverage = `paid_amount + discount_value` is added in BOTH `getDueAmount` and `getByPaymentStatus`. `paid_amount` is cash only, so collected/revenue exclude the waived discount; the backend dashboard mirrors this (folds discount into the due side, not collected). Shared UI: `lib/views/widgets/collect_payment_dialog.dart`. Printed receipts (Bluetooth + PDF) get a "Discount" section via `receiptDiscountText`.

### Logout / login data lifecycle
`AuthController.logout({wipeLocal})`: user-initiated logout buttons pass `wipeLocal:true` → push pending, then `deleteLocalData()`. Involuntary logouts (offline-too-long, session-expired) and the settings restore flows keep `wipeLocal:false`. Owner/admin **login auto-pulls** the account's data (accountants already do via `_onAccountantLoggedIn`).

### Spec-Kit
Feature batches are specced under `specs/<batch>/` (`spec.md`/`plan.md`/`tasks.md`). See `specs/v8/`, `specs/v7-fixes/`, `specs/multi-branch/`.

### Pagination
Every scrollable list screen paginates via the canonical pattern (reference: `CoreController.loadSubscribers`/`loadMore`): fetch `itemsPerPage + 1` to detect the next page, trim to `itemsPerPage`, page-1 `assignAll` + later pages `addAll`, reset to page 1 when a filter (month/board/query) changes, and a `ScrollController` (disposed in the State) calls `loadMore` ~200px from the bottom. Paginated: subscribers, boards, circuits, expenses, receipt-history (subscriber detail), users (settings).

### Cloud backup
`SettingsController` + `BackupRepository` upload/list/delete/restore the raw `moldati.db` via the backend (online-gated). Restore overwrites the local DB then forces logout so the new data is picked up. Local file export/import (share_plus / file_picker) still exists alongside it.

## Conventions
- File names `lowercase_with_underscores`; load initial data in `onReady()`; controllers expose `.obs` + call `update()` after mutations (mixed `Obx`/`GetBuilder` in use — keep both when editing).
- New user-facing strings go in **both** language maps in `lib/utils/translations.dart`, used via `'key'.tr`.

## Gotchas
- The suite is green: `flutter test` (90) + `cd backend && npm test` (110). `test/widget_test.dart` holds real translation-parity tests — **every new string must be added to BOTH `en_US` and `ar_AR` maps** in `lib/utils/translations.dart` or the suite fails.
- ⚠️ **SQLite is `version: 9`** (`lib/data/db_helper.dart`); `_onCreate` builds the schema and `_onUpgrade` walks the migration branches: v1→v2 adds the sync change-capture (`sync_outbox` + AFTER INSERT/UPDATE/DELETE triggers), later branches add **multi-branch**, **subscriber categories** + **per-category monthly pricing**, **v7 adds `receipts.discount_type`/`discount_value`/`discount_amps`**, **v8 adds scale indexes on the hot scope/join columns** (`_createV8Indexes`, idempotent `CREATE INDEX IF NOT EXISTS`, run in both `_onCreate` — after `_createSyncInfra`, since one index is on `sync_outbox` — and `_onUpgrade`), and **v9 adds `updated_at` to the 7 business tables** (`_addUpdatedAtColumns`) — a per-row edit timestamp stamped by every model `toMap()` and sent as `data.updated_at` so the backend `/api/sync/push` applies **last-EDIT-wins + sticky tombstones** (conflict resolution). Any schema change needs a version bump + an idempotent `_addColumn` `onUpgrade` branch AND the matching column in `_onCreate`, or installs diverge. **Do not change the sync triggers/outbox/drain logic** (the sync engine is built; only wrapper-level error/latch handling in `SyncController` is fair game).
- ⚠️ **GetX "improper use of Obx"** — an `Obx(() => cond ? W : X)` whose `cond` short-circuits BEFORE reading any observable (e.g. `widget.filter == null && auth.can(...)` on a screen where `filter != null`) throws at build; in **release** this renders the whole screen as a grey `ErrorWidget` (debug shows a red box). Always make the `Obx` builder read an observable, or move the static condition OUTSIDE the `Obx` (e.g. `floatingActionButton: cond ? Obx(() => auth.can(...) ? FAB : SizedBox()) : null`). This bit the subscribers and boards screens.
- ⚠️ **Blocking progress overlay** (`SyncProgress`, `lib/views/widgets/sync_progress_overlay.dart`) — do NOT wrap a `Get.dialog` in `PopScope(canPop:false)`: that also blocks the programmatic `Get.back()` used to close it, leaving the dialog stuck (greys the app). Use `barrierDismissible:false` + `Get.back()`; show any result snackbar AFTER closing (a snackbar before close makes `Get.isDialogOpen` read false and blocks the close).
- ⚠️ **Sync captures only changes made after the v2 migration** — rows that pre-existed an upgrade aren't in `sync_outbox`, so they don't appear in the admin mirror until next edited (no backfill yet). Likewise, mirror rows that fail to push leave `pendingCount` showing "N pending" until a successful push.
- ⚠️ **When running parallel file-editing agents, forbid `git` commands** — a prior multi-agent run executed `git reset/stash` during cleanup and reverted uncommitted edits. Keep editing agents read-only on git, or commit a checkpoint first. For coupled work (shared controllers/repos), edit directly and reserve agents/workflows for read-only mapping + adversarial review.
- The mirror is **whole-row push-only** (`SyncRecord.data` = Mixed): new SQLite columns ride to the server automatically with no backend schema change — but the admin/owner panel (`backend/public/admin/index.html`, shared `SYNC_COLUMNS`/`receiptDetailContent`) must be edited to display them.
- Android needs cleartext HTTP (already set) for the dev backend; permissions for the device-id attempt are in `AndroidManifest.xml`.
