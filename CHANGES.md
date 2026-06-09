# CHANGES — Moldati Owner

An ordered, reproducible changelog of the recent work on **Moldati Owner**
(`generatormanagment`) — the Flutter (GetX) app + Node/Express/MongoDB backend +
single-file admin SPA. Each entry says **what changed**, **which files**, and any
**migration/config notes** so a developer can apply the same change to a different
copy of the app.

Entries are grouped by area and ordered oldest → newest, matching the order they
were committed. Areas: **App** (Flutter), **Backend** (Node), **Admin panel**
(SPA), **DB** (schema/migrations). Cross-cutting features (e.g. sync) list every
file they touch under whichever area is primary.

> Reproduction note: the app is offline-first. Local SQLite (`moldati.db`) is the
> source of truth for all business data; the backend owns accounts / auth /
> subscriptions / device-binding / cloud backups / and the per-account sync
> mirror. New user-facing strings must be added to **both** language maps in
> `lib/utils/translations.dart`.

---

## 1. Offline sync — device → server mirror (push)

Adds a change-capture + push pipeline so every local business change is mirrored
to a per-account copy on the server (so admins can view each owner's data). The
device DB stays the source of truth and is never written by push.

### 1.1 DB — change-capture schema (SQLite `version: 1` → `version: 2`)
**File:** `lib/data/db_helper.dart`

- Bumped `openDatabase(... version: 2 ...)` and added an `onUpgrade` callback.
- Added `_createSyncInfra(db)` (idempotent, `IF NOT EXISTS`) which creates:
  - a `sync_outbox` table:
    ```sql
    CREATE TABLE IF NOT EXISTS sync_outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,
      entity TEXT NOT NULL,
      op TEXT NOT NULL,          -- 'upsert' | 'delete'
      local_id TEXT NOT NULL,
      ts TEXT NOT NULL DEFAULT (datetime('now'))
    );
    ```
  - For each synced table: `AFTER INSERT`, `AFTER UPDATE`, and `AFTER DELETE`
    triggers (`<table>_sync_ai/_au/_ad`) that insert a row into `sync_outbox`
    (`upsert` for insert/update using `NEW.<pk>`, `delete` using `OLD.<pk>`).
- Added the canonical map of synced tables → primary keys (single source of truth
  used by triggers, push, and pull):
  ```dart
  static const Map<String, String> syncedTables = {
    'boards': 'id', 'circuits': 'id', 'subscribers': 'id',
    'monthly_prices': 'month', 'receipts': 'uuid', 'refunds': 'uuid',
    'expenses': 'id',
  };
  ```
- `_onCreate` calls `_createSyncInfra(db)` at the end (fresh installs get it too);
  `_onUpgrade` calls it only when `oldVersion < 2`.

**Migration notes (critical):**
- This is the only schema-version bump. **Any further schema change needs another
  `version` bump + a matching `onUpgrade` branch**, or installs diverge.
- ⚠️ Triggers capture only changes made **after** the v2 migration. Rows that
  already existed on a device when it upgraded are **not** in `sync_outbox` and
  won't appear in the admin mirror until next edited. (A one-time backfill that
  enqueues existing rows is not built.)
- Local staff `users` rows are intentionally **not** synced (no trigger).

### 1.2 App — sync engine (drain + push)
**Files (new):** `lib/core/sync_service.dart`, `lib/data/repositories/sync_repository.dart`
**File (edited):** `lib/core/api_config.dart`

- `lib/core/api_config.dart`: added endpoint constants
  ```dart
  static const String syncPush = '/api/sync/push';
  static const String syncPull = '/api/sync/pull';
  ```
- `SyncRepository` (new): wraps `ApiClient`.
  - `push(List<Map> records)` → `POST /api/sync/push` body `{ records }`.
  - `pull({since})` → `GET /api/sync/pull` (optional `?since=ISO`), returns the
    raw record maps from `res['records']`.
- `SyncService` (new, singleton):
  - `pendingCount()` → `COUNT(DISTINCT entity, local_id)` from `sync_outbox`.
  - `push()`: snapshots `MAX(seq)` first (so concurrent writes during the push are
    not lost), collapses the outbox to the **latest op per (entity, local_id)**
    within that window, reads the current SQLite row as `data` (omits `data` /
    sets `deleted:true` for deletes), POSTs in batches of `batchSize = 200`, and
    only `DELETE`s the drained outbox rows (`seq <= maxSeq`) after all batches
    succeed. Each record is `{ entity, localId, deleted, updatedAt, data? }`.

### 1.3 App — sync orchestration
**File (new):** `lib/controllers/sync_controller.dart`
**File (edited):** `lib/core/app_binding.dart` (register the controller)

- `SyncController` (GetxController, registered **permanent** in `AppBinding`;
  resolve with `Get.find<SyncController>()`):
  - Reactive: `pendingCount` (RxInt), `isSyncing` (RxBool), `lastSyncAt` (RxnString).
  - On `onReady`: `refreshPending()`, subscribe to `ConnectivityService.onStatusChange`
    (auto-sync when online regained), and a 30s `Timer.periodic` heartbeat.
  - `maybeAutoSync()`: online-gated; if `pendingCount > largeThreshold` (**100**)
    it shows an "X changes pending — upload now?" confirm dialog, else syncs
    silently.
  - `syncNow()`: manual/auto push; snackbars `online_only` when offline.

**Config note:** register `SyncController(... permanent: true)` in
`lib/core/app_binding.dart` so it lives for the app's lifetime and the heartbeat
runs.

### 1.4 Backend — sync mirror model + endpoints
**Files (new):** `backend/src/models/SyncRecord.js`, `backend/src/controllers/syncController.js`, `backend/src/routes/sync.js`
**File (edited):** `backend/src/server.js`

- `SyncRecord` model (Mongo): `{ user(ref User, indexed), entity, localId,
  data(Mixed,null), deleted(Bool,false), updatedAt(Date) }`. `updatedAt` is
  **device-controlled** (`timestamps: { createdAt: true, updatedAt: false }`).
  Unique compound index `{ user, entity, localId }`.
- `syncController.push` (`POST /api/sync/push`, auth): body `{ records:[...] }`.
  Upserts each record keyed by `(user, entity, localId)`; tombstones may omit
  `data`. Validates each record has string `entity` + `localId` (400 otherwise).
  Returns `{ ok, count, serverTime }`. **Strictly per-account** — scoped to
  `req.user._id`.
- `syncController.pull` (`GET /api/sync/pull?since=ISO`, auth): returns
  `{ records:[{entity,localId,deleted,updatedAt,data}] }` for the JWT's account,
  filtered by `updatedAt > since` when given, sorted `updatedAt` asc.
- `routes/sync.js`: `router.use(requireAuth)`, `POST /push`, `GET /pull`.
- `server.js`: `const syncRoutes = require('./routes/sync')` and
  `app.use('/api/sync', syncRoutes)` (mounted between `/api/backup` and
  `/api/admin`).

---

## 2. Admin panel — per-entity synced-data screens (read-only mirror)

### 2.1 Backend — read the mirror for admins
**File:** `backend/src/controllers/adminController.js` · routes `backend/src/routes/admin.js`

- `GET /api/admin/users/:id/data` (`getUserData`, admin): lists one owner's
  mirrored rows for one `entity`, newest first (`updatedAt` desc).
  - Query: `entity` (required; one of `subscribers, boards, circuits, receipts,
    expenses, monthly_prices, refunds`), `q` (case-insensitive substring, applied
    **before** pagination, regex-escaped), `page` (1-based, default 1), `limit`
    (default 25, clamped 1..200), `includeDeleted=true` (default excludes
    tombstones).
  - Per-entity search fields (`SEARCH_FIELDS`): `subscribers→name,phone ·
    boards→name,code · circuits→name,phase · receipts→receipt_no,month ·
    expenses→category,note · monthly_prices→month`; unknown entity falls back to
    matching `localId`.
  - Returns `{ entity, records:[{localId,data,deleted,updatedAt}], total, page, limit }`.
- `DELETE /api/admin/users/:id/data/:entity/:localId` (`deleteUserData`, admin):
  hard-deletes **one** mirrored `SyncRecord`. This is the **only** admin write to
  the mirror (the mirror is otherwise push-only device→server). 404 if not found.
- Register both in `backend/src/routes/admin.js`.

### 2.2 Admin panel — separate screen per entity + search/paginate/delete
**File:** `backend/public/admin/index.html` (single-file hash-routed SPA)

- Added a screen per synced entity at hash route `#/users/:id/data/:entity`
  (Subscribers / Boards / Circuits / Receipts / Expenses / Monthly prices), each
  with the correct columns for that entity.
- Each screen wires the search box + server-side pagination (`q`, `page`, `limit`)
  to `GET /api/admin/users/:id/data` and a per-row **delete** to
  `DELETE /api/admin/users/:id/data/:entity/:localId`. The mirror stays read-only
  otherwise (no create/edit).
- Added relationship **drill-down** (admin-only): the backend `getUserData` also
  accepts a whitelisted relationship filter `relField`∈`{subscriber_id, board_id,
  circuit_id}` + `relValue` to list child records of a parent.

### 2.3 App — dashboard sync panel
**File:** `lib/views/screens/dashboard_screen.dart`

- Added a sync status/control panel on the dashboard driven by `SyncController`
  (pending count + manual sync), alongside the verified live flow.

---

## 3. Settings — Backup & Sync moved to dedicated screens
**Files:** `lib/views/screens/sync_screen.dart` (new), `lib/views/screens/backup_screen.dart` (new), `lib/views/screens/settings_screen.dart` (edited)

- Extracted the inline Backup and Sync sections out of Settings into their own
  screens (`SyncScreen`, `BackupScreen`); Settings now shows a button/tile that
  navigates to each.
- `SyncScreen` resolves `Get.find<SyncController>()` and shows: sync status +
  pending count (`syncing` / `all_synced` / `N sync_pending`), last-sync timestamp
  (`never` fallback), and a "Sync now" button (`syncNow()`), all online-gated.

---

## 4. Cairo font — bundled offline Arabic font
**Files:** `pubspec.yaml`, `assets/fonts/Cairo.ttf` (new), `assets/fonts/OFL.txt` (new), `lib/main.dart`

- Bundled the Cairo variable font (OFL) for offline Arabic rendering. Added the
  asset files and the `OFL.txt` license.
- `pubspec.yaml`: declared the font under `flutter:`
  ```yaml
  fonts:
    - family: Cairo
      fonts:
        - asset: assets/fonts/Cairo.ttf
  ```
- `lib/main.dart`: set `ThemeData(fontFamily: 'Cairo', ...)` so the whole app uses
  Cairo (replaces any prior Google-Fonts/network dependency — fully offline).
- Docs refreshed: `RUN.md`, `CUSTOMER_WORKFLOW.md`.

**Config note:** the PDF receipt loads the same TTF via
`rootBundle.load('assets/fonts/Cairo.ttf')` (see §6), so keep the asset path
exactly `assets/fonts/Cairo.ttf`.

---

## 5. Generator name — business identity on register / banner / receipt

A per-owner "generator name" (the business identity printed on receipts and shown
on the dashboard). Plumbed end-to-end: signup form → app model/controller/repo →
backend model/serializer/auth → dashboard banner → printed receipts.

### 5.1 Backend
**Files:** `backend/src/models/User.js`, `backend/src/controllers/authController.js`, `backend/src/utils/serialize.js`, `backend/src/controllers/adminController.js`

- `User` model: added `generatorName: { type: String, default: null, trim: true }`.
- `authController.register`: reads `generatorName` from the body and stores
  `generatorName: generatorName || null` on the new user.
- `utils/serialize.js` (`serializeAccount`): returns `generatorName:
  user.generatorName || null`.
- `adminController`: includes the field where account data is returned.

### 5.2 App
**Files:** `lib/data/models/account.dart`, `lib/data/repositories/auth_repository.dart`, `lib/controllers/auth_controller.dart`, `lib/views/auth/signup_screen.dart`, `lib/utils/translations.dart`

- `Account` model: added nullable `String? generatorName` to the constructor,
  `fromJson` (`j['generatorName']`), and `toJson`.
- `AuthRepository.register(...)` and `AuthController.register(...)`: added an
  optional `String? generatorName` parameter, forwarded into the request body as
  `'generatorName'`.
- `signup_screen.dart`: added a "Generator name" text field
  (`_generatorName`, icon `Icons.bolt`, required validator) between Full name and
  Phone; passed into `_auth.register(generatorName: ...)`. (Phone remains the
  unique login `username`.)
- `translations.dart`: added key `generator_name` in **both** maps
  (`en: 'Generator name'`, `ar: 'اسم المولدة'`).

### 5.3 Dashboard banner
**File:** `lib/views/screens/dashboard_screen.dart`

- Banner headline now shows `authController.account.value?.generatorName` (falls
  back to the `generator_name` label when empty), inside an `Obx`.

---

## 6. Receipts — table layout + QR that opens the admin receipt-details screen

Receipts (both the `pdf` PDF and the Bluetooth thermal print) now render all
fields inside a bordered table, with a QR code that links to the receipt's details
in the admin panel. The QR is rendered as an **image** for reliable thermal
printing.

### 6.1 App — PDF receipt
**File:** `lib/utils/pdf_service.dart`

- Loads bundled Cairo via `pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo.ttf'))`
  so Arabic renders in the PDF (wrapped in try/catch; theme applied when present).
- Header = the owner's generator name (`_generatorName()`, falls back to
  `'TopRank'`), then "وصل استلام".
- All receipt fields are emitted as a 2-column `pw.Table` (`TableBorder.all`).
- QR via `pw.BarcodeWidget(barcode: pw.Barcode.qrCode())` encoding
  `_receiptQrUrl(receipt)` =
  `'{ApiConfig.baseUrl}/admin/#/users/{accountId}/data/receipts/detail/{receipt.uuid}'`
  (falls back to `receipt.qrToken` / `uuid|receiptNo` when account id is absent).

### 6.2 App — Bluetooth thermal receipt
**File:** `lib/utils/bluetooth_print_service.dart`

- Header = generator name (`_generatorName()`), then "وصل استلام".
- All fields printed via `printArabicTable(rows)` — **each row is rendered as its
  own small image** (`_printTableRow`), because a single large table image was
  corrupting output on some printers.
- QR printed as an image via `_printQrImage(_receiptQrUrl(receipt))` using the
  `barcode` package (`bc.Barcode.qrCode(...)`) drawn to a `PictureRecorder`
  canvas → PNG → `bluetooth.printImageBytes(...)`. The native QR command was
  garbling long URLs; the image path is reliable. Falls back to printing the raw
  `uuid` text on error.

**Dependency note:** added `barcode: ^2.2.9` to `pubspec.yaml` dependencies
(used to render the QR to an image). `pdf` / `printing` were already present.

### 6.3 Admin panel — single receipt-details screen + QR target
**File:** `backend/public/admin/index.html`
**File (supporting):** `backend/src/controllers/adminController.js`

- New hash route `#/users/:id/data/receipts/detail/:localId`:
  `viewReceiptDetail(id, localId)` fetches the user + the one receipt record (via
  `GET /api/admin/users/:id/data?entity=receipts&localId=...`), resolves the
  subscriber name (best-effort), and `renderReceiptDetail(...)` shows a key/value
  card (receipt #, status badge, subscriber, month, amps, price/amp, paid,
  remaining, issued-at, synced time, receipt id).
- The Receipts list gets a per-row **Details** drill button linking to that route.
- `adminController.getUserData`: added an **exact single-record fetch by
  `localId`** — when `?localId=` is present it filters `filter.localId = localId`
  (used by the receipt-details screen). Reproduce by adding the `localId` branch
  before the search/pagination logic.

---

## 7. Public receipt verification — scan QR without login

Anyone can scan a printed receipt's QR to verify it on a public, login-free page.
The QR target changed from the per-account admin detail route to the new public
route `/admin/#/r/<uuid>`.

### 7.1 Backend — public lookup endpoint
**Files:** `backend/src/controllers/publicController.js` (new) · `backend/src/routes/public.js` (new) · `backend/src/server.js` (edited)

- `GET /api/public/receipt/:uuid` — **PUBLIC, no auth middleware**. Looks up the
  receipt across **all** accounts:
  `SyncRecord.findOne({ entity:'receipts', localId: uuid, deleted:false })`; if
  found, resolves `subscriberName` from the owner's `subscribers` mirror
  (`{ user: rec.user, entity:'subscribers', localId: rec.data.subscriber_id }`)
  and `generatorName` from `User.findById(rec.user).generatorName`.
- Response JSON: `{ found, receipt: { receipt_no, month, amps_snapshot,
  price_snapshot, paid_amount, remaining_after, issued_at, status } | null,
  subscriberName: string|null, generatorName: string|null }`.
- `server.js`: mount `app.use('/api/public', publicRoutes)` **without**
  `requireAuth`.

### 7.2 Admin panel — public route `#/r/:uuid`
**File:** `backend/public/admin/index.html`

- Added a hash route `#/r/:uuid` that **bypasses the router's auth/login gate for
  this route only**, fetches `GET /api/public/receipt/:uuid`, and renders a
  standalone Arabic receipt page (**no sidebar/nav**) showing the receipt fields +
  subscriber name + generator name (or a "not found" message).

### 7.3 App — QR now encodes the public route
**Files:** `lib/utils/pdf_service.dart`, `lib/utils/bluetooth_print_service.dart`

- `_receiptQrUrl(receipt)` now returns exactly
  `'${ApiConfig.baseUrl}/admin/#/r/${receipt.uuid}'` (replaces the old
  `/admin/#/users/<accountId>/data/receipts/detail/<uuid>` target from §6).

---

## 8. Admin panel — fully Arabic (RTL) + sidebar layout
**File:** `backend/public/admin/index.html`

- Rewrote the admin SPA to be **fully Arabic, right-to-left** (`dir="rtl"`, Arabic
  labels/columns/buttons throughout) with a **sidebar navigation layout** (nav on
  the side, content pane beside it) replacing the prior top-nav English UI.

---

## 9. Admin subscriber statement — payment history per subscriber
**Files:** `backend/public/admin/index.html` · `backend/src/controllers/adminController.js` (supporting)

- Added an admin **subscriber statement (كشف حساب)** screen: a per-subscriber
  payment history listing that owner's receipts for one subscriber. Uses the
  existing `GET /api/admin/users/:id/data` mirror endpoint scoped to
  `entity=receipts` filtered by the subscriber (`relField=subscriber_id` +
  `relValue`), newest first.

---

## 10. App — record payment + print invoice from the payment-history screen
**Files:** `lib/views/screens/*payment_history*` , related controller/repository, `lib/utils/translations.dart`

- The subscriber **payment-history** screen can now **record a payment** (log a
  paid amount, create the receipt) and **print its invoice** directly from that
  screen — no separate navigation. New user-facing strings added to **both**
  language maps in `lib/utils/translations.dart`.

---

## 11. Earlier supporting changes (context)

These predate the work above but are part of the same recent line and are
referenced by it.

- **Dashboard:** removed the circular profile avatar from the upper panel
  (`lib/views/screens/dashboard_screen.dart`).
- **Docs:** refreshed `CLAUDE.md` gotchas to note DB is now `version: 2` with
  `onUpgrade`, tests green, and the sync-backfill gap.

---

## Reproduction checklist (apply to a fresh copy)

1. **Backend:** add `models/SyncRecord.js`, `controllers/syncController.js`,
   `routes/sync.js`; mount `app.use('/api/sync', syncRoutes)` in `server.js`. Add
   `generatorName` to `User` + `serializeAccount` + `register`. Add
   `getUserData` (+ `localId`/`q`/`page`/`limit`/`relField` handling) and
   `deleteUserData` to `adminController` and register their routes.
2. **DB:** bump `db_helper.dart` to `version: 2`, add `syncedTables`,
   `_createSyncInfra` (outbox + triggers), call it from `_onCreate` and the
   `_onUpgrade (oldVersion < 2)` branch.
3. **App core/controllers:** add `sync` endpoints to `api_config.dart`, add
   `sync_repository.dart`, `sync_service.dart`, `sync_controller.dart`; register
   `SyncController` (permanent) in `app_binding.dart`.
4. **App UI:** add `sync_screen.dart` + `backup_screen.dart`, link from
   `settings_screen.dart`; add the dashboard sync panel + generator-name banner;
   add the generator-name field to `signup_screen.dart` and thread it through
   `auth_controller`/`auth_repository`/`account.dart`; add the `generator_name`
   translation key to both maps.
5. **Assets:** add `assets/fonts/Cairo.ttf` (+ `OFL.txt`), declare it in
   `pubspec.yaml` `flutter.fonts`, set `fontFamily: 'Cairo'` in `main.dart`. Add
   `barcode: ^2.2.9` to dependencies.
6. **Receipts:** rewrite `pdf_service.dart` + `bluetooth_print_service.dart` to
   the table + image-QR layout with the `/admin/#/.../receipts/detail/<uuid>` URL.
7. **Admin SPA:** add the per-entity screens + the receipt-details route to
   `public/admin/index.html`.
8. Run `flutter pub get` (and `cd backend && npm install` if deps changed); a
   device upgrading an existing install runs the v2 migration automatically on
   next launch.
