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

---

## 12. Two-way sync — pull (server → device) + delete-local-data

Lets an account restore its server mirror onto a device (new device, or after
clearing local data), and wipe local business data on demand.

**Files:** `lib/core/sync_service.dart`, `lib/controllers/sync_controller.dart`, `lib/data/repositories/sync_repository.dart`, `lib/views/screens/settings_screen.dart`, `lib/utils/translations.dart`

- `SyncService.pull({since})`: fetches the account's mirror via
  `SyncRepository.pull`, writes each record into SQLite (insert/replace, or delete
  for tombstones) inside one transaction, and **clears the `sync_outbox` rows the
  pull itself generated** (`seq > seqBefore` snapshot) so a pull never re-pushes.
- `SyncService.deleteLocalData()`: wipes the 7 business tables + `sync_outbox` in a
  transaction. **The server mirror is untouched** (re-pullable).
- `SyncController`: `isPulling`, `lastPullAt`, `isUpToDate` (pendingCount==0);
  `pull({silent})` pushes pending first then pulls then reloads dashboard;
  `deleteLocalData()`.
- Settings: a red **"delete local data"** tile (confirm dialog →
  `deleteLocalData()`).
- New translation keys (both maps): `up_to_date, update_now, pull_latest, pulling,
  pulled_records, delete_local_data, delete_local_data_subtitle,
  delete_local_data_confirm, local_data_deleted`.

> Backend endpoint `GET /api/sync/pull` already existed (see §1.4); this is the
> device-side apply + the delete-local action.

---

## 13. Sync access points — pull/refresh buttons

**Files:** `lib/views/screens/dashboard_screen.dart`, `lib/views/screens/sync_screen.dart`

- Dashboard banner shows an up-to-date status ("محدّث" vs N pending) plus
  **"مزامنة الآن"** (push) and **"تحديث"** (pull) buttons.
- Sync screen (`sync_screen.dart`) gains a **"جلب أحدث البيانات"** (pull) button
  below "Sync now" (`OutlinedButton` → `syncController.pull()`).

---

## 14. Public receipt — invoice history, white background, no-login fix

Extends §7 (public scan-a-QR receipt page).

### 14.1 Backend — public subscriber history
**Files:** `backend/src/controllers/publicController.js`, `backend/src/routes/public.js`

- `GET /api/public/receipt/:uuid/history` — **PUBLIC, no auth**. Finds the receipt
  by uuid → its `user` + `subscriber_id` → returns that subscriber's other
  receipts, newest first: `{ found, subscriberName, generatorName,
  receipts:[{uuid,receipt_no,month,paid_amount,remaining_after,issued_at,status}] }`.

### 14.2 Admin SPA — history button + page + white bg + login-gate fix
**File:** `backend/public/admin/index.html`

- Public receipt page (`#/r/:uuid`) gains a **"عرض الفواتير السابقة"** button →
  new public route `#/r/:uuid/history` (`viewPublicReceiptHistory`) listing the
  subscriber's invoices, each linking to its own `#/r/<uuid>`.
- `.receipt-screen` background changed from the blue gradient to **white**
  (`background:#fff;`).
- **No-login fix (important):** a stale admin token in `localStorage` made `boot()`
  call `/api/auth/me`, get **401**, and `doLogout()` → redirect to `#/login`, even
  on a public receipt page. Added `currentRouteIsPublic()` and:
  1. `boot()` only validates the token (`API.me()`) when **not** on a public route;
  2. the `api()` 401 handler only `doLogout()`s when **not** on a public route.
  Now `#/r/:uuid` and `#/r/:uuid/history` always render without a login, regardless
  of any stored token.

---

## 15. Subscriber detail — removed inline receipt history
**File:** `lib/views/screens/subscriber_detail_screen.dart`

- Removed the inline **"السجل"** receipt-history list that sat under the green
  paid-card. The payment history (with record-payment + print, see §10) now lives
  only on the dedicated payment-history screen, reachable from the AppBar history
  icon. The detail screen keeps only the info card, billing month, and paid-card.

---

## 16. Running on a LAN IP (config, not code)

To let another device on the same Wi-Fi reach the backend and scan receipt QRs:

- Backend binds all interfaces (`app.listen(PORT)` in `backend/src/server.js`), so
  it is reachable at `http://<PC-LAN-IP>:4000` (allow it through the OS firewall).
- Run the app pointing at the LAN IP so its receipt QRs encode it:
  `flutter run --dart-define=API_BASE_URL=http://<PC-LAN-IP>:4000`.
- A scanned QR opens `http://<PC-LAN-IP>:4000/admin/#/r/<uuid>` — the public page
  (§7/§14), no login.

---

## 17. Session re-check on pull-to-refresh + plan time remaining on the banner

### 17.1 App — pull-to-refresh re-validates the session
**Files:** `lib/controllers/auth_controller.dart`, `lib/views/screens/login_screen.dart`, `lib/views/screens/dashboard_screen.dart`, `lib/utils/translations.dart`

- `AuthController.recheckSession()` — online-only re-fetch of `/auth/me`. If the
  account is **blocked**, or the subscription is **not active** (expired /
  rejected / pending / none), it signs the user out (`logout(reason:)`) with a
  translation-key warning; a still-active plan change just refreshes the account.
  A 401/403 ends the session; offline/network errors keep it. Returns whether the
  session is still valid.
- `_sessionProblemReason(acc)` maps the refreshed account to a key:
  `blocked → account_disabled`, `expired → subscription_expired`,
  `rejected → subscription_rejected`, `pending → subscription_pending`,
  else `subscription_required`.
- New `logoutReason` Rx; `logout({reason})` sets it; `login()` clears it.
- Login screen: an **orange warning banner** at the top when `logoutReason` is set
  (`session_ended` title + the specific reason).
- Dashboard `RefreshIndicator.onRefresh` now calls `recheckSession()` first; only
  reloads stats if still valid.
- New keys (both maps): `session_ended`, `session_expired`.

### 17.2 App — plan time remaining on the dashboard banner
**Files:** `lib/views/screens/dashboard_screen.dart`, `lib/utils/translations.dart`

- The banner's plan row now appends the remaining plan time computed from
  `subscription.expiresAt` as `plan_Ndays` (e.g. `MONTHLY_29days`), or
  `plan_expired` once past the expiry. Helper `_planWithDaysLeft(base, expiresAt)`.

---

## 18. Same-device (reinstall-safe) login
**File:** `backend/src/utils/devices.js`

- Device identity now keys off the **OS-stable `deviceId` first**. `sameDevice(existing, incoming)`
  matches on `deviceId` when both sides have one (ignoring `installId`), and only
  falls back to `installId` when one side has no `deviceId`.
- Why: the app-generated `installId` changes on every reinstall / data-clear, but
  the same physical handset keeps the same OS `deviceId`. Matching on `deviceId`
  first means a reinstall on the same phone is recognised as the **same device**
  (the existing binding's fields + `lastSeen` are refreshed) instead of being
  treated as a brand-new device that would trip `DEVICE_LIMIT`.
- `upsertDevice` is unchanged in shape: an existing (same) device is refreshed;
  only a genuinely new `deviceId` is counted against the active plan's
  `maxDevices` (default 1 when there is no active plan).

**Test:** `backend/test/device_and_events.test.mjs` (new) — register on `dev-A`,
re-login same `deviceId` + new `installId` → 200, still 1 device; login from a
different `deviceId` → 403 `DEVICE_LIMIT`.

---

## 19. Real-time new-account notification — SSE + admin pop-up
**Files:** `backend/src/controllers/authController.js` / register flow, an SSE
stream route (`backend/src/routes/*` + controller), `backend/public/admin/index.html`

- The backend emits a **Server-Sent Event** when a new account registers and
  exposes an admin-only SSE stream endpoint. The admin SPA subscribes to that
  stream and shows a **live pop-up** when a new account signs up, so admins see
  registrations in real time without reloading the Users screen.

---

## 20. Thermal printer paper-width setting (58mm / 80mm)
**Files:** `lib/views/screens/settings_screen.dart`, `lib/utils/bluetooth_print_service.dart`, `lib/utils/translations.dart`

- Added a **printer paper-width** setting (58mm / 80mm) in Settings. The selected
  width is persisted and read by `bluetooth_print_service.dart`, which lays out
  the receipt (line width / row-image widths) for the chosen paper so receipts
  print correctly on both common thermal printer sizes.
- New user-facing strings added to **both** language maps in
  `lib/utils/translations.dart` (printer width label + the 58mm/80mm options).

---

## 21. Periodic expiry/block re-check + auto-logout after long offline
**Files:** `lib/controllers/auth_controller.dart`, related app lifecycle wiring, `lib/utils/translations.dart`

- Extends §17.1 (pull-to-refresh `recheckSession`) with a **periodic / foreground**
  re-validation: while online the app re-checks `/auth/me` on a timer (and on
  resume), and a **blocked** account or an **inactive** subscription signs the user
  out to login with the matching warning banner.
- **Auto-logout after long offline:** a device that stays offline past a grace
  window is signed out, so a revoked / expired account cannot keep running
  indefinitely on a stale cached offline session. (A short offline period still
  keeps the cached session per the offline-first rule.)
- Any new strings added to **both** language maps in `lib/utils/translations.dart`.

---

## 22. Expenses — sync + pagination
**Files:** `lib/data/db_helper.dart` (`syncedTables`), expenses controller/repository, `lib/views/screens/*expense*`

- **Expenses are part of the per-account synced tables** (`expenses: 'id'` in
  `DbHelper.syncedTables`), so every expense change is captured by the
  `sync_outbox` triggers and pushed device→server like the other business
  entities; admins view them on the **Expenses** synced-data screen.
- The **expenses list paginates** via the canonical pattern (fetch
  `itemsPerPage + 1`, trim, page-1 `assignAll` + later `addAll`, reset on filter
  change, `ScrollController` `loadMore` near the bottom).

> Note: this documents existing behaviour (expenses were already in the synced
> tables); no schema-version bump is involved.

---

## Test steps — verify each feature (step by step)

> Setup: backend `cd backend && npm run dev` (in-memory Mongo); app
> `flutter run --dart-define=API_BASE_URL=http://<host>:4000`; admin SPA at
> `http://<host>:4000/admin` (admin/admin123 by default). Seeds available via
> `--dart-define=DEV_SEED=true --dart-define=DEV_SEED_COUNT=N`.

### A. Offline sync — push (device → server mirror)
1. Sign in on the app (online), add a board/subscriber/receipt while online or
   offline.
2. Open the admin panel → Users → that owner → Subscribers/Boards/Receipts.
3. Confirm the new rows appear in the admin mirror (auto-synced when online).

### B. Ask-before-large-upload
1. Seed/accumulate **> 100** pending changes (e.g. `DEV_SEED_COUNT=200`).
2. Let auto-sync run (or open Sync screen).
3. Confirm a dialog "**N changes pending — upload now?**" appears; the upload only
   happens after you confirm.

### C. Two-way pull + delete-local
1. With data synced to the server, go **Settings → delete local data → confirm**.
2. Confirm the dashboard counts drop to **0** and lists are empty.
3. Go **Settings → Sync (المزامنة) → "جلب أحدث البيانات"** (or dashboard
   **"تحديث"**).
4. Confirm the data is **restored** from the server and the status returns to
   "محدّث" (up to date) with **0 pending** (pull does not re-queue a push).

### D. Per-account isolation
1. Register two accounts; sync different data from each.
2. In admin, open each owner's synced-data screens.
3. Confirm each owner sees **only their own** records.

### E. Admin synced-data — search / paginate / delete
1. Admin → Users → owner → Subscribers.
2. Type in the search box → confirm server-side filtering; page with Prev/Next.
3. Delete one row → confirm it disappears (mirror-only delete; the app is
   unaffected).

### F. Admin panel — Arabic (RTL) + sidebar
1. Open the admin panel.
2. Confirm the whole UI is **Arabic, right-to-left**, with a **sidebar** (لوحة
   التحكم / المستخدمون / الخطط + تسجيل الخروج), not a top nav.

### G. Admin subscriber statement (كشف الحساب)
1. Admin → Users → owner → Subscribers → a subscriber's **"كشف الحساب"**.
2. Confirm a subscriber info card + a **payment-history table** (receipt #, month,
   paid, remaining, date, status); each row opens the receipt details.

### H. Public receipt page (scan QR, no login)
1. Print/preview a receipt in the app (QR encodes `…/admin/#/r/<uuid>`).
2. On **another device** (same Wi-Fi), scan the QR.
3. Confirm the **Arabic receipt page** opens **without any login** — generator
   name, receipt #, subscriber, month, amps, price, paid, remaining, date, status.
4. Confirm it still opens even on a device that previously logged into the admin
   (stale token must **not** bounce to login).

### I. Public invoice history
1. On the public receipt page, tap **"عرض الفواتير السابقة"**.
2. Confirm the subscriber's other invoices list (newest first), each opening its
   own public receipt, with a "‹ رجوع للوصل" back button — all without login.

### J. Generator name
1. Sign up with a **Generator name** (اسم المولدة).
2. Confirm it shows on the dashboard banner and as the **header** of printed
   receipts and the public receipt page.

### K. Receipt layout + QR
1. Collect a payment and print/preview the receipt.
2. Confirm all fields render in a **bordered table** and the **QR** prints as a
   crisp image (not garbled).

### L. Record payment + print from the history screen
1. Open a subscriber → AppBar **history icon** → payment-history screen.
2. Use **record payment** to log a payment; confirm a receipt is created.
3. Use the per-receipt **print** action; confirm it prints/previews.
4. Confirm the subscriber **detail** screen no longer shows an inline history list
   under the green card (§15).

### M. Run on LAN + scan from another phone
1. Start the backend; note the PC LAN IP; run the app with
   `--dart-define=API_BASE_URL=http://<PC-LAN-IP>:4000`.
2. From another phone on the same Wi-Fi, open/scan a receipt URL
   `http://<PC-LAN-IP>:4000/admin/#/r/<uuid>`.
3. Confirm the public receipt page loads (firewall must allow port 4000).

### N. Pull-to-refresh session re-check (blocked / expired / plan changed)
1. Sign in (active plan) and reach the dashboard.
2. **Pull down to refresh** → confirm it stays on the dashboard (a `/auth/me`
   re-check fired).
3. In the admin panel, **block** that account
   (`PUT /api/admin/users/:id/blocked {blocked:true}`).
4. Pull-to-refresh again → confirm the app **signs out to the login screen** with
   an orange banner: "You have been signed out" + **"Your account is disabled…"**.
5. Unblock, sign back in, then set the plan **expired**
   (`PUT /api/admin/users/:id/plan {status:"expired"}`).
6. Pull-to-refresh → confirm sign-out with **"Your subscription has expired."**
7. (Offline) Turn off internet and pull-to-refresh → confirm the session is
   **kept** (no sign-out).

### O. Plan time remaining on the banner
1. Sign in with an active subscription that has an expiry date.
2. Confirm the dashboard banner's plan row shows e.g. **`MONTHLY_29days`**
   (or `MONTHLY_expired` once past the expiry).

### P. Same-device (reinstall-safe) login
1. Register/sign in on a phone (it binds that handset; no active plan => limit 1).
2. On the **same** phone, clear the app data / reinstall and sign in again.
3. Confirm sign-in **succeeds** (no `DEVICE_LIMIT`) and the account still shows
   **one** device (the binding was refreshed, not duplicated).
4. Sign in from a **different** phone → confirm it is **rejected**
   (`403 DEVICE_LIMIT`) until a device is unbound / the plan allows more.
5. Automated: `cd backend && npm test` → `device_and_events.test.mjs` passes.

### Q. Real-time new-account notification (SSE + admin pop-up)
1. Open the admin panel and stay on it (Users screen).
2. From the app (or another browser), **register a new account**.
3. Confirm a **live pop-up** appears in the admin panel announcing the new
   account, without manually refreshing.

### R. Thermal printer paper-width (58mm / 80mm)
1. Go to **Settings** → printer paper-width and select **58mm**.
2. Print a receipt → confirm it fits the 58mm paper.
3. Switch to **80mm**, print again → confirm the layout widens to the 80mm paper.

### S. Periodic expiry/block re-check + auto-logout after long offline
1. Sign in (active plan) and leave the app open (online).
2. In the admin panel **block** the account (or set the plan **expired**).
3. Wait for the periodic re-check (or background→foreground the app) → confirm
   the app **signs out to login** with the matching warning banner.
4. Sign back in, go **offline**, and leave the app offline past the grace window
   → confirm it **auto-logs-out** (a short offline period must still keep the
   session, per offline-first).

### T. Expenses — sync + pagination
1. Add several expenses in the app (online or offline).
2. When online, open the admin panel → that owner → **Expenses** → confirm the
   rows appear in the mirror (auto-synced).
3. Scroll the in-app expenses list → confirm it **paginates** (loads more near the
   bottom; the count grows page by page) and resets when a filter changes.
