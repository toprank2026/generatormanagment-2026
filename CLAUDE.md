# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

"Moldati Owner" (`generatormanagment`) — a Flutter app for managing a private **electricity generator** business: subscribers, electrical **boards** and **circuits** (جوزة), monthly per-amp **billing**, **expenses**, and **receipts** printed on Bluetooth thermal printers. UI is bilingual (Arabic `ar_AR` / English `en_US`).

The system is split by a hard boundary (see `STRUCTURE.md`, which is accurate):
- **All business data** (boards, circuits, subscribers, monthly prices, receipts, refunds, expenses, local staff users) lives **only** in the device's local SQLite DB (`moldati.db`) and never leaves the phone.
- A separate **accounts-only backend** (`backend/`, Node/Express/MongoDB) owns authentication, subscription/plans, device binding, and opaque **cloud DB backups**. There is intentionally **no server API for business data**.
- The app is **offline-first**: the network is only needed for register / sign-in, subscription checks, and cloud backup.

## Commands

### Flutter app
```bash
flutter pub get
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:4000   # emulator → host backend
flutter run --dart-define=API_BASE_URL=http://192.168.1.99:4000 # physical device on LAN
flutter analyze                       # lint (flutter_lints); currently 0 errors, ~39 info/warn
dart format .
flutter test                          # NOTE: default counter test fails (see gotcha)
flutter build apk --release
```
`API_BASE_URL` defaults to `http://192.168.1.99:4000` (see `lib/core/api_config.dart`) if no `--dart-define` is given.

### Backend (`backend/`)
```bash
cd backend && npm install
npm run dev      # nodemon, http://localhost:4000, in-memory Mongo by default (USE_MEMORY_DB=true)
npm start        # node src/server.js
npm run seed     # seed default plans
```
Copy `.env.example` → `.env` and set `JWT_SECRET`, `ADMIN_USERNAME/PASSWORD`; set `USE_MEMORY_DB=false` + `MONGO_URI` for persistence. Admin SPA: `http://localhost:4000/admin`. The endpoint contract is `backend/API_CONTRACT.md` (source of truth). `node --check <file>` is the quick JS syntax check (no JS lint pipeline in this repo).

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

### Pagination
Every scrollable list screen paginates via the canonical pattern (reference: `CoreController.loadSubscribers`/`loadMore`): fetch `itemsPerPage + 1` to detect the next page, trim to `itemsPerPage`, page-1 `assignAll` + later pages `addAll`, reset to page 1 when a filter (month/board/query) changes, and a `ScrollController` (disposed in the State) calls `loadMore` ~200px from the bottom. Paginated: subscribers, boards, circuits, expenses, receipt-history (subscriber detail), users (settings).

### Cloud backup
`SettingsController` + `BackupRepository` upload/list/delete/restore the raw `moldati.db` via the backend (online-gated). Restore overwrites the local DB then forces logout so the new data is picked up. Local file export/import (share_plus / file_picker) still exists alongside it.

## Conventions
- File names `lowercase_with_underscores`; load initial data in `onReady()`; controllers expose `.obs` + call `update()` after mutations (mixed `Obx`/`GetBuilder` in use — keep both when editing).
- New user-facing strings go in **both** language maps in `lib/utils/translations.dart`, used via `'key'.tr`.

## Gotchas
- ⚠️ **`test/widget_test.dart` is still the default counter template and fails** (`flutter test` is red out of the box) — replace it before relying on the suite.
- ⚠️ **SQLite is `version: 1` with `_onCreate` only — no `onUpgrade` migration path** (`lib/data/db_helper.dart`). Any schema change needs a version bump + `onUpgrade`, or it diverges across installs.
- ⚠️ **When running parallel file-editing agents, forbid `git` commands** — a prior multi-agent run executed `git reset/stash` during lint cleanup and reverted uncommitted edits to tracked files. Keep editing agents read-only on git, or commit a checkpoint first.
- Android needs cleartext HTTP (already set) for the dev backend; permissions for the device-id attempt are in `AndroidManifest.xml`.
