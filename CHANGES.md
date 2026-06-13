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

## 23. Session re-check on bottom-nav navigation
**Files:** `lib/views/screens/main_screen.dart`, `lib/controllers/auth_controller.dart`

- Switching bottom-nav tabs now triggers the **same online expire/block
  re-validation as pull-to-refresh** (§17.1 / §21): the tab change calls the
  guarded `recheckSession()` path, so a **blocked** account or an **inactive**
  subscription signs the user out to login with the matching warning banner,
  while offline/network errors keep the cached session (offline-first).
- **Throttled to once per 60s** — rapid tab switching does not spam `/auth/me`;
  within the window the tab just switches with no network call. The existing
  overlap guard (`_guardedRecheck()`) still prevents concurrent re-checks.

---

## 24. Dashboard banner — sync area restructured to two rows
**File:** `lib/views/screens/dashboard_screen.dart`

- The banner's sync area (§13: status + "مزامنة الآن" push + "تحديث" pull) is
  restructured into **two rows**, one per direction:
  - **Row 1 — push:** the **sync (push)** button + the **pending-changes**
    status ("محدّث" / N pending).
  - **Row 2 — pull:** the **update (pull)** button + the **last-update**
    (last pull) status.
- Behaviour is unchanged (same `SyncController` actions/observables); this is a
  layout change so each button sits beside the status it acts on.

---

## 25. Plan-approval auto-refresh on the plan-selection screen
**Files:** `lib/views/screens/plan_selection_screen.dart`, `lib/controllers/auth_controller.dart` (`refreshSubscription()`)

- While the plan-selection screen is showing (subscription pending / blocked),
  it **polls the subscription status ~every 12s, online-gated** (no polling
  while offline). When the admin approves the requested plan, the refreshed
  subscription clears `subscriptionBlocked` and the reactive root gate
  (`root_handler.dart`) routes into `MainScreen` automatically — **no manual
  refresh** needed.
- The poll timer is cancelled when the screen is disposed (no background
  polling once inside the app).

---

## 26. Dev time overrides for session checks (dart-defines)
**File:** `lib/controllers/auth_controller.dart`

- The two long session-check timings are now configurable via `--dart-define`
  so they can be tested in minutes instead of days; **production builds (no
  defines) keep the defaults**:
  - `RECHECK_SECONDS` (default **900** = 15 min) → the periodic re-check
    interval (`_recheckInterval`, §21).
  - `OFFLINE_LOGOUT_SECONDS` (default **259200** = 3 days) → the offline
    auto-logout grace window (`_offlineLogoutThreshold`, §21).
- Example (compressed testing):
  ```bash
  flutter run --dart-define=RECHECK_SECONDS=30 --dart-define=OFFLINE_LOGOUT_SECONDS=120
  ```

---

## 27. Owner self-service panel — owner login on the admin panel URL

An **owner** (the Flutter app account; phone + password) can now log into the
**same admin panel URL** and gets a **self-service dashboard of only their own
data** — like the app: stats cards + Subscribers / Boards / Circuits /
Receipts / Expenses / Monthly prices, plus the subscriber statement and
receipt-details views — all **read-only**. Admin features (Users list, Plans,
other accounts, the SSE feed, mirror deletes) are hidden from owners **and**
route-guarded.

### 27.1 Backend — JWT-scoped account data + stats
**Files (new):** `backend/src/controllers/accountController.js`, `backend/src/routes/account.js`
**Files (edited):** `backend/src/controllers/adminController.js`, `backend/src/server.js`, `backend/API_CONTRACT.md`

- The entity-listing logic (`entity`/`q`/`page`/`limit`/`relField`/`localId`
  over `SyncRecord`, see §2.1/§6.3) was **refactored out of
  `adminController.getUserData` into a shared `listUserData` helper**;
  `getUserData` (admin, any user id) now delegates to it — same behaviour as
  before for admins.
- `accountController` (new) reuses the same helper but **always scopes to
  `req.user._id`** (the JWT account — an owner can never reach another
  account's mirror):
  - `GET /api/account/data` (auth) — same query contract as the admin endpoint
    (`entity, q, page, limit, relField/relValue, localId`) and the same
    response shape `{ entity, records, total, page, limit }`.
  - `GET /api/account/stats` (auth) — dashboard counts over the account's own
    mirror (subscribers / boards / circuits / receipts / expenses /
    monthly prices) for the stats cards.
- `routes/account.js`: `router.use(requireAuth)` + the two GETs — **no admin
  middleware** (owners are the audience) and **no write routes** (the mirror
  stays push-only device→server; the owner panel is read-only).
- `server.js`: mount `app.use('/api/account', accountRoutes)`.
- `backend/API_CONTRACT.md`: documented the two new endpoints.

### 27.2 Admin SPA — owner mode (role-aware boot / sidebar / guards, `#/my` routes)
**File:** `backend/public/admin/index.html`

- **Role-aware boot:** after login / token validation the SPA keeps the
  account's `role`; `role === 'admin'` boots into the existing admin UI,
  `role === 'owner'` boots into **owner mode** (login itself is unchanged —
  `/api/auth/login` already works for both roles).
- **Owner sidebar:** only the owner items (dashboard + the six entity
  screens) — **no Users / Plans** nav — and the admin **SSE** subscription is
  never opened for owners.
- **Owner routes (`#/my…`):** `#/my` (dashboard with stats cards from
  `GET /api/account/stats`) and `#/my/data/:entity` per entity, plus the
  owner-scoped subscriber statement and receipt-details views — all fetching
  `GET /api/account/data` with the same search + server-side pagination as the
  admin screens (§2.2).
- **Read-only tables:** the owner entity screens render **without delete
  buttons** (mirror deletes stay admin-only; no create/edit either).
- **Route guards both ways:** an owner navigating to any admin route (e.g. a
  direct `#/users` URL) is **redirected to `#/my`**; an admin hitting `#/my…`
  is redirected to the admin dashboard. Admin behaviour is otherwise
  unchanged.

---

## 28. Owner panel — app-style dashboard stats (paid/unpaid, server-side)

**Files:** `backend/src/controllers/accountController.js`, `backend/public/admin/index.html`

- `GET /api/account/stats` (auth, JWT-scoped — §27.1) now **also returns a
  `dashboard` object**, computed **server-side from the account's mirror** with
  the **app's exact paid/unpaid formula**, so the owner panel's numbers always
  match the Flutter dashboard:
  - For the current month `M`, `P = monthly_prices[M].price_per_amp`
    (`0` when no price row exists for `M`).
  - A subscriber is **PAID** when
    `SUM(receipts.paid_amount WHERE subscriber_id = s.id AND month = M) >= s.amps * P`,
    else **UNPAID**. (With `P = 0` every subscriber counts as **paid** — same
    as the app.)
  - The object carries the dashboard counts: total subscribers, **paid**
    subscribers (المشتركين المسددين), **unpaid** subscribers
    (المشتركين غير المسددين), and total boards.
- The owner dashboard (`#/my`) renders these as its **نظرة عامة stat cards** —
  including the new green المشتركين المسددين / red المشتركين غير المسددين
  cards — instead of plain mirror row-counts.

---

## 29. Panel tables — human board/circuit names (no raw UUIDs)

**File:** `backend/public/admin/index.html`

- The **circuits** tables — owner (`#/my/data/circuits`) **and** admin
  (`#/users/:id/data/circuits`) — now resolve each circuit's `board_id` to the
  **board's name**.
- The **subscriber statement** views (owner + admin, §9/§27.2) resolve the
  subscriber's `board_id` / `circuit_id` to the board / circuit **names**.
- Raw UUIDs are **no longer shown** on these screens. Implementation: the
  screens fetch the relevant `boards` / `circuits` mirror entities, build an
  id → name lookup, and apply it at render time (an id with no matching parent
  record falls back gracefully instead of breaking the table).

---

## 30. Owner panel UI — Flutter-app look (banner, stat cards, bottom nav)

**File:** `backend/public/admin/index.html`

- Owner mode (§27.2) is restyled to **look like the Flutter app's dashboard**,
  clearly distinct from the admin UI (which is **unchanged** — RTL sidebar
  layout, §8):
  - **Blue gradient banner** (blue.shade800 → blue.shade400, rounded 16) with
    icon + data rows: ⚡ generator name (bold), 📱 phone, 🏅 plan with the
    remaining time as `plan_Ndays` (e.g. `MONTHLY_29days`), mirroring the app
    banner (§5.3 / §17.2).
  - "**نظرة عامة**" heading + a **2-column grid of white rounded-16 stat
    cards** — each a small colored icon chip + big bold number + grey label
    (إجمالي المشتركين blue · المشتركين المسددين green · المشتركين غير المسددين
    red · إجمالي البوردات indigo) — fed by `stats.dashboard` (§28).
  - A **fixed bottom navigation bar** with 5 tabs — الرئيسية / المشتركون /
    الوصولات / المصروفات / المزيد — replaces the sidebar **for owners only**;
    the active tab highlights blue (app-style), and المزيد reaches the
    remaining owner screens (boards, circuits, monthly prices, logout).
  - **Phone-like centered layout:** owner content renders in a centered
    max-width column so the panel reads like the app on any screen.
- No backend route changes; admin routes/screens keep the sidebar and all
  admin features exactly as before.

---

## 31. Monthly reports & statistics (التقارير) — app tab + owner-panel tab

A month-by-month report: the user picks a month (`YYYY-MM`) and gets **gauges and
charts + totals** — paid/unpaid subscribers, expected total
(`totalAmps × pricePerAmp`), collected (sum of that month's receipts
`paid_amount`), remaining (expected − collected), the month's expenses total, and
**NET PROFIT = collected − expenses** — plus the month's payments list. Paid/unpaid
uses the **app's exact formula** (subscriber paid for month `M` ⇔
`SUM(receipts.paid_amount WHERE subscriber_id = s.id AND month = M) >=
s.amps × pricePerAmp(M)`; no price row for `M` ⇒ everyone paid).

> **Sync/backup note (important):** reports are **DERIVED** from the existing
> synced tables (`receipts`, `expenses`, `subscribers`, `monthly_prices`) — **no
> new tables, no SQLite version bump, nothing new to sync**. The existing
> push/pull mirror and cloud/local backups already cover every report input.

### 31.1 App — التقارير bottom-nav tab → offline Reports screen
**Files (new):** `lib/controllers/reports_controller.dart`, `lib/views/widgets/report_charts.dart`, `lib/views/screens/reports_screen.dart`
**Files (edited):** `lib/views/screens/main_screen.dart` (new tab), `lib/core/app_binding.dart` (register controller), `lib/utils/translations.dart` (new keys, both maps)

- `ReportsController` (GetxController, registered `lazyPut(fenix: true)` in
  `AppBinding`; screens resolve with `Get.find<ReportsController>()`):
  - Rx state: `month` (RxString `'yyyy-MM'`, init = current month), `isLoading`,
    `totalSubscribers`, `paidCount`, `unpaidCount`, `totalAmps`, `pricePerAmp`,
    `expectedTotal`, `collectedTotal`, `remainingTotal`, `expensesTotal`,
    `netProfit`, and `receipts` (RxList<Receipt> — that month's receipts, newest
    first).
  - Methods: `loadReport()`, `setMonth(String m)` (sets month + reloads),
    `prevMonth()`, `nextMonth()`; initial load in `onReady()`.
  - **Everything is computed OFFLINE from local SQLite** via the existing
    repositories/DbHelper (receipts / expenses / subscribers / monthly_prices) —
    no network involved.
- `report_charts.dart` — **pure `CustomPainter` chart widgets, NO new pub
  dependencies:**
  - `GaugeChart({required double value /*0..1 clamped*/, required String label,
    String? centerText, Color color = Color(0xFF1565C0), double size = 160})` —
    semi-circular gauge: value arc over a grey track, big bold center text
    (defaults to the percent), label underneath.
  - `DonutChart({required List<DonutSegment> segments, double size = 150,
    String? centerText})` + `DonutSegment(label, value, color)` — donut with a
    legend row(s) under it (color dot + label + value).
  - `BarCompareChart({required List<BarItem> items, double height = 150})` +
    `BarItem(label, value, color)` — vertical bars scaled to `max(|value|)` with
    the signed value label on top (negative values clamp the bar at 0 but still
    show the signed number).
- `reports_screen.dart` — the التقارير screen: month picker (prev/next +
  current `yyyy-MM`), **gauge** = collection rate (`collected / expected`),
  **donut** = paid vs unpaid subscribers, **bars** = collected / expenses /
  net profit, a totals grid (expected, collected, remaining, expenses,
  net profit), and the month's payments list, all inside `Obx`.
- `main_screen.dart`: a **التقارير** tab added to the bottom nav alongside
  Dashboard / Monthly pricing / Expenses / Settings.
- Strings via `'key'.tr`; reuses existing keys (`net_profit`, `total_expenses`,
  `collected_revenue`, `remaining_fees`, `paid_subscribers`,
  `unpaid_subscribers`, `total_subscribers`) and adds the new report keys to
  **both** maps (e.g. `reports`, `collection_rate`, `expected_total`,
  `month_payments`).

### 31.2 Backend — month-scoped stats + expenses/net-profit on the dashboard
**File:** `backend/src/controllers/accountController.js` (the endpoint contract lives in `backend/API_CONTRACT.md`)

- `GET /api/account/stats?month=YYYY-MM` (auth, JWT-scoped — §27.1/§28): new
  **optional `month` query param** (validated `/^\d{4}-\d{2}$/`, default =
  **current UTC month**) that selects which month the `dashboard` object
  describes (price, paid/unpaid, totals — same formula as §28, now for the
  requested month).
- The `dashboard` object additionally returns:
  - `expensesTotal` — sum of the mirror's `expenses` `data.amount` whose
    `data.date` **starts with** the month (numbers coerced).
  - `netProfit` — `collected − expensesTotal`.

### 31.3 Owner panel — التقارير tab → `#/my/reports` (SVG charts from the mirror)
**File:** `backend/public/admin/index.html`

- A **التقارير** tab added to the owner bottom nav (§30) → new owner route
  **`#/my/reports`**: the same month picker + **gauge / donut / bars rendered as
  inline SVG** + totals + the month's payments list, fed by
  `GET /api/account/stats?month=…` (and the receipts mirror for the list) — so
  the panel's report for a month shows the **same numbers as the app**.
- Owner-mode only; the admin UI is unchanged.

---

## 32. Per-plan capability flags — gate sync / backup / owner-panel by the active plan

When an admin creates/edits a **plan** they choose whether that plan includes each
of three capabilities; the account's **active** plan then enables/disables that
capability **everywhere**:

  1. **sync** — online data sync (push/pull to the server mirror). Off ⇒ the app
     works **offline-only** (local SQLite only) and the backend rejects sync.
  2. **backup** — cloud backup (upload/list/restore/delete). Off ⇒ backup hidden
     in the app + the backend rejects.
  3. **ownerPanel** — the owner self-service dashboard in the admin panel (`#/my…`,
     `/api/account/*`). Off ⇒ those endpoints 403 and the panel shows "not in your
     plan".

> **Data note (important):** the sync / backup / reports **DATA and behaviour are
> unchanged** — these flags only **gate** the feature on/off; nothing about the
> records, the mirror, the schema, or the report math changes. **No SQLite version
> bump** (the flags live on the backend `Plan` + the account JSON, resolved **live**
> from the active plan — no User-schema change, no snapshot). Defaults are **all
> true**, so every existing plan keeps every capability.

### 32.1 Backend — Plan flags + serializer

**Files:** `backend/src/models/Plan.js`, `backend/src/utils/serialize.js`, `backend/src/scripts/seedPlans.js` (or wherever plans are seeded — supporting)

- `Plan` model gains three `Boolean` fields, **default `true`**: `syncEnabled`,
  `backupEnabled`, `ownerPanelEnabled`.
- `serializePlan()` adds the three **flat booleans** using `p.x !== false`
  (so a missing/legacy field serializes as `true`):
  ```js
  syncEnabled: p.syncEnabled !== false,
  backupEnabled: p.backupEnabled !== false,
  ownerPanelEnabled: p.ownerPanelEnabled !== false,
  ```

### 32.2 Backend — `planFeatures` util (resolve live from the active plan)

**File (new):** `backend/src/utils/planFeatures.js`

- `async function planFeaturesByCode(code) → { sync, backup, ownerPanel }` — looks
  up the plan by `code`; each flag = `plan.<x>Enabled !== false`; **a missing plan
  ⇒ all `true`**.
- `async function featuresForUser(user) → { sync, backup, ownerPanel }` — if the
  user has `subscription.status === 'active'` **and** `subscription.planCode`, it
  returns `planFeaturesByCode(that code)`; **otherwise `{ sync:true, backup:true,
  ownerPanel:true }`** (no active plan ⇒ everything on, matching the
  no-active-plan default elsewhere).

### 32.3 Backend — `account.subscription.features` on the account JSON

**File:** `backend/src/controllers/authController.js`

- On **login / register / `/auth/me`**, after building the account JSON via
  `serializeAccount`, the controller attaches
  `account.subscription.features = await featuresForUser(user)` — i.e.
  `{ sync, backup, ownerPanel }` resolved live from the active plan. This is the
  single source the app reads (it never recomputes flags).

### 32.4 Backend — `requireFeature` middleware on the gated routers

**File (new):** `backend/src/middleware/requireFeature.js`
**Files (edited):** `backend/src/routes/sync.js`, `backend/src/routes/account.js`, `backend/src/routes/backup.js`

- `requireFeature(name)` → `async (req, res, next)`:
  ```js
  const f = await featuresForUser(req.user);
  if (!f[name]) return res.status(403).json({
    message: 'هذه الميزة غير متوفرة في خطتك',
    code: 'FEATURE_DISABLED',
    feature: name,
  });
  next();
  ```
- Mounted **after** `requireAuth` on each router:
  - `routes/sync.js` → `requireFeature('sync')` (push **and** pull rejected when
    the active plan has sync off).
  - `routes/account.js` → `requireFeature('ownerPanel')` (the owner-panel data +
    stats endpoints 403 when owner-panel is off).
  - `routes/backup.js` → `requireFeature('backup')` (upload/list/restore/delete
    all 403 when backup is off).
- The 403 body is the **fixed contract** (`code:'FEATURE_DISABLED'`, `feature:<name>`)
  so the app/panel can detect it precisely and the message is the Arabic
  "هذه الميزة غير متوفرة في خطتك".

### 32.5 App — `Subscription` features + `AuthController` getters

**Files:** `lib/data/models/account.dart` (the `Subscription` model), `lib/controllers/auth_controller.dart`

- `Subscription` gains three `bool` getters read from `json['features']`, each
  **defaulting to `true` when the key/object is absent** (so an older
  server / cached session keeps everything on):
  `syncEnabled`, `backupEnabled`, `ownerPanelEnabled`.
- `AuthController` exposes the convenience getters
  `bool get canSync` / `bool get canBackup` / `bool get canOwnerPanel`
  (each `=> account.value?.subscription.<x> ?? true`).

### 32.6 App — switch to offline-only when sync is off; hide backup when off

**Files:** `lib/controllers/sync_controller.dart`, `lib/views/screens/sync_screen.dart`, `lib/views/screens/dashboard_screen.dart`, `lib/views/screens/settings_screen.dart`, `lib/views/screens/backup_screen.dart`

- **Sync off (`canSync == false`):** the app runs **offline-only** — `SyncController`
  short-circuits push/pull (no `/api/sync` calls), and the **sync UI is hidden**
  (the dashboard sync row(s) and the Settings → المزامنة tile/screen) so there is no
  control to invoke a disabled capability. Local SQLite remains the source of truth;
  nothing in the offline experience changes.
- **Backup off (`canBackup == false`):** the **backup tile is hidden** in Settings
  (the cloud upload/list/restore/delete UI is not reachable); the backend would also
  reject it (32.4). Local file export/import is unaffected.
- Reads the new getters from `AuthController` (32.5); reactive (`Obx`) so the UI
  reflects a plan change after the next `/auth/me` refresh.

### 32.7 Admin panel — plan editor toggles + plan-list capability chips; owner "not in your plan"

**File:** `backend/public/admin/index.html`

- **Plan editor (create/edit):** three **toggles** — sync / backup / owner-panel —
  bound to `syncEnabled` / `backupEnabled` / `ownerPanelEnabled` (default **on**),
  sent in the plan create/update payload.
- **Plans list:** each plan row shows **capability chips** for the enabled
  capabilities (so an admin sees at a glance which plan includes sync / backup /
  owner-panel).
- **Owner panel — "not in your plan":** when the owner's active plan has
  **owner-panel off**, `/api/account/*` returns `403 FEATURE_DISABLED` (32.4); the
  owner mode detects this and renders a **"not in your plan" (هذه الميزة غير متوفرة
  في خطتك)** message instead of the dashboard/screens.

> Translation keys (added via `'key'.tr` in both maps — see `translationKeys`),
> not raw strings, for any new app/panel-facing copy (offline-only notice,
> feature-disabled / not-in-your-plan message, plan-editor toggle labels).

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

### U. Session re-check on bottom-nav navigation
1. Sign in (active plan) and reach the main screen (online).
2. In the admin panel, **block** the account
   (`PUT /api/admin/users/:id/blocked {blocked:true}`).
3. **Switch a bottom-nav tab** → confirm the app **signs out to the login
   screen** with the warning banner ("Your account is disabled…").
4. Sign back in (unblocked) and switch tabs rapidly → confirm the re-check fires
   at most **once per 60s** (tabs still switch instantly; no `/auth/me` spam).
5. Go offline and switch tabs → confirm the session is **kept** (no sign-out).

### V. Dashboard banner — two-row sync area
1. Sign in and open the dashboard.
2. Confirm the banner's sync area shows **two rows**:
   **row 1** = the **sync (push)** button beside the **pending-changes** status
   ("محدّث" / N pending); **row 2** = the **update (pull)** button beside the
   **last-update** status.
3. Make a local change → row 1 shows pending; push → back to "محدّث". Tap the
   pull button → row 2's last-update timestamp refreshes.

### W. Plan-approval auto-refresh
1. **Register** a new account → **request a plan** → the app sits on the
   plan-selection screen (pending).
2. In the admin panel, **approve** the plan request.
3. **Without touching the app**, confirm that within ~12s it detects the
   approval and **enters the main screen on its own** (no manual refresh /
   re-login).

### X. Compressed long-time session tests (dart-defines)
1. **Periodic expire/block:** run with `--dart-define=RECHECK_SECONDS=30`;
   sign in, leave the app open online, **block** the account in admin → within
   ~30s the periodic re-check **signs out to login** with the warning banner.
2. **Offline auto-logout:** run with `--dart-define=OFFLINE_LOGOUT_SECONDS=120`;
   sign in, enable **airplane mode**, keep the app offline > 2 min → confirm it
   **auto-logs-out**; staying offline *less* than the window must **keep** the
   session (offline-first).
3. Run without the defines → confirm the defaults apply (15-min re-check,
   3-day offline window) — production behaviour unchanged.

### Y. Owner self-service panel
1. Open `http://<host>:4000/admin` and log in with an **app (owner) account**
   (phone + password — the same credentials as the Flutter app).
2. Confirm the **owner dashboard** (`#/my`) opens with that account's **stats
   cards**, and the sidebar shows only the owner items — **no Users / Plans**.
3. Open each entity screen (Subscribers / Boards / Circuits / Receipts /
   Expenses / Monthly prices) → confirm only **this account's** rows appear
   (search + pagination work), the **subscriber statement** and **receipt
   details** open owner-scoped, and there are **no delete buttons** anywhere
   (read-only).
4. Type a direct admin URL (`#/users`) in the address bar → confirm it
   **redirects to `#/my`**.
5. Log out and log in as **admin** → confirm the admin panel is unchanged
   (Users / Plans / SSE pop-up / mirror deletes all present).

### Z. Owner panel — app-look dashboard + bottom nav
1. Open `http://<host>:4000/admin` and log in with an **owner** (app) account.
2. Confirm the dashboard **looks like the Flutter app**: blue gradient banner
   (⚡ generator name, 📱 phone, 🏅 plan as `plan_Ndays`), the **نظرة عامة**
   2-column stat cards, and a **fixed bottom navigation bar**
   (الرئيسية / المشتركون / الوصولات / المصروفات / المزيد) — **no sidebar**,
   content centered phone-style.
3. Confirm the **المشتركين المسددين / غير المسددين** card numbers **match the
   app's dashboard** for the same account and month (same formula; with no
   monthly price set for the month, **all** subscribers count as paid in both).
4. Tap each bottom-nav tab → confirm it navigates to the matching owner screen
   and the active tab highlights **blue**.
5. Log out and log in as **admin** → confirm the admin UI is **unchanged**
   (RTL sidebar, same screens, no bottom nav, no gradient banner).

### AA. Human board/circuit names (no raw UUIDs)
1. As an **owner**, open `#/my/data/circuits` → confirm the board column shows
   the **board NAME**, not a UUID.
2. Open a **subscriber statement** (كشف الحساب) → confirm the subscriber's
   board / circuit appear as **names**.
3. As **admin**, open the same screens (`#/users/:id/data/circuits` + a
   statement) → confirm names there too; raw `board_id`/`circuit_id` UUIDs no
   longer appear on these screens.

### AB. Monthly reports & statistics (التقارير)
1. Prepare known data: a monthly price for month `M`, a few subscribers with
   known amps, some receipts in `M` (at least one subscriber fully paid, one
   not), and a few expenses dated in `M`.
2. In the app, open the **التقارير** bottom-nav tab and pick month `M`
   (prev/next arrows or picker) → confirm the numbers match the data:
   **paid/unpaid** counts per the formula (`sum(paid_amount) >= amps × price`),
   **expected** = totalAmps × pricePerAmp, **collected** = sum of `M`'s receipts
   `paid_amount`, **remaining** = expected − collected, **expenses** = sum of
   `M`'s expenses, **net profit** = collected − expenses.
3. Confirm the charts agree: the **gauge** shows collected/expected, the
   **donut** splits paid vs unpaid, the **bars** show collected / expenses /
   net profit (a negative net profit shows its signed label), and the **month
   payments list** shows exactly `M`'s receipts, newest first.
4. Switch to a month with **no monthly price** → confirm everyone counts as
   **paid** and expected is 0 (formula edge case, same as the dashboard).
5. Open the **owner panel** (`/admin`, owner login) → **التقارير** bottom-nav
   tab (`#/my/reports`) → pick the **same month `M`** → confirm the SVG
   gauges/charts and totals show the **same numbers as the app** (data fully
   synced first).
6. **Offline:** enable airplane mode and open the app's التقارير tab → confirm
   the report still renders fully and the numbers are unchanged (computed from
   local SQLite — no network needed).

### AC. Per-plan capability flags (sync / backup / owner-panel)

> Reminder: the flags only **gate** the feature; the data/behaviour of sync,
> backup, and reports is unchanged. Defaults are all **on**, so a plan keeps every
> capability unless a flag is explicitly turned off.

1. **Create a plan with a flag off (admin):** in the admin panel → Plans →
   create/edit a plan and turn **off** one capability — e.g. **sync off** — leaving
   backup + owner-panel on. Save and confirm the plan-list **capability chips**
   reflect only the enabled capabilities (no sync chip).
2. **Assign it:** make an owner account's **active** plan that new plan (approve a
   request for it / set its `planCode` active). Have the app re-fetch `/auth/me`
   (pull-to-refresh / re-login) so `subscription.features` updates.
3. **Verify the SYNC gate (app offline-only + sync UI hidden):**
   - Confirm the app's **sync UI is hidden** — no sync row on the dashboard, no
     المزامنة tile/screen in Settings — and the app behaves **offline-only**:
     local edits still save to SQLite, but **no** `/api/sync` push/pull fires.
   - Hit `POST /api/sync/push` (or `GET /api/sync/pull`) directly with that
     account's token → confirm **`403`** with
     `{ code:'FEATURE_DISABLED', feature:'sync', message:'هذه الميزة غير متوفرة في خطتك' }`.
4. **Verify the BACKUP gate (tile hidden + backend 403):** create/assign a plan with
   **backup off** → confirm the **backup tile is hidden** in Settings, and a direct
   call to a `/api/backup/*` endpoint returns **`403 FEATURE_DISABLED`**
   (`feature:'backup'`). (Local export/import still works.)
5. **Verify the OWNER-PANEL gate (panel "not in your plan"):** create/assign a plan
   with **owner-panel off** → log into `/admin` as that owner → confirm the panel
   shows **"هذه الميزة غير متوفرة في خطتك" / "not in your plan"** instead of the
   dashboard, and `GET /api/account/data` / `GET /api/account/stats` return
   **`403 FEATURE_DISABLED`** (`feature:'ownerPanel'`).
6. **Defaults / no active plan:** confirm an account on an **all-flags-on** plan
   (or with **no active plan**) keeps **all three** capabilities — sync UI present
   and working, backup tile present, owner panel opens — i.e. nothing regressed for
   existing plans.
