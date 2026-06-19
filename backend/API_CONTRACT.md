# API Contract — Moldati Accounts Backend

> Source of truth for the **accounts-only** backend (Node / Express / MongoDB).
> All generator business data (boards, circuits, subscribers, monthly_prices,
> receipts, refunds, expenses, local staff users) lives **only** in the device
> SQLite DB and is **never** sent here. This backend owns: **accounts,
> authentication, subscription/plans, device binding, and cloud DB backups**.

- Base URL: configured in the app via `--dart-define=API_BASE_URL=...`
  (default `http://192.168.1.99:4000`). Backend listens on `PORT` (default `4000`).
- All bodies are JSON unless noted. All authed routes require
  `Authorization: Bearer <JWT>`.
- Error shape (every non-2xx): `{ "message": "human readable", "code": "OPTIONAL_CODE" }`.
- Timestamps are ISO-8601 strings.

---

## Auth — `/api/auth`

### POST `/api/auth/register`  (public)
Creates an owner account, binds the calling device, returns a JWT.
```jsonc
// request
{
  "name": "Owner Name",
  "phone": "0770...",            // optional
  "username": "owner1",          // unique
  "password": "secret",
  "device": {                    // device fingerprint, see Device object
    "installId": "uuid-generated-on-device",
    "deviceId": "android-ssaid-or-ios-vendorid",
    "platform": "android|ios",
    "model": "SM-G991B",
    "brand": "samsung",
    "osVersion": "Android 13 (SDK 33)",
    "imei": "optional, usually absent on modern OS",
    "mac": "optional best-effort wifi BSSID"
  }
}
// 201 response
{ "token": "<jwt>", "account": { /* Account */ } }
```
Errors: `409` username taken, `400` validation.

### POST `/api/auth/login`  (public)
Authenticates, binds/validates the device, returns a JWT.
```jsonc
// request
{ "username": "owner1", "password": "secret", "device": { /* Device */ } }
// 200 response
{ "token": "<jwt>", "account": { /* Account */ } }
```
Errors: `401` bad credentials, `403` account blocked, `403 code=DEVICE_LIMIT`
when the plan's `maxDevices` is exceeded by a new device. The `device` field is
**optional** — the browser admin/owner web panel logs in without one, so a
missing device does NOT fail; when a device IS sent (the mobile app always sends
it) it is bound and `maxDevices` is enforced. (Closing the "omit device to skip
the limit" bypass robustly requires per-device checks on the data routes — a
Phase-2 item.) `429 code=RATE_LIMITED` when too many login/register attempts
come from one IP (see **Rate limiting**).

**Accountant logins.** When the matched user has `role:"accountant"` (a
sub-account created via `POST /api/account/accountants`):
- the password is verified normally, and `device` is **optional** — device
  binding / `maxDevices` is **not** enforced or mutated (accountants are
  device-exempt — `DEVICE_LIMIT` never fires and no device is added);
- the returned `subscription` (incl. `features`) is **inherited from the OWNER
  account** (`ownerId`), so an accountant is never `subscriptionBlocked` on its
  own (empty) subscription;
- the returned account carries `role:"accountant"`, `ownerId`, `branchId`,
  `permissions`, `localId` (see the **Account** object).

`GET /api/auth/me` applies the same inheritance for an accountant token.

**Rate limiting.** `POST /api/auth/login` and `POST /api/auth/register` are
IP-rate-limited (~10 requests / minute / IP). Exceeding the limit returns
`429 { "code": "RATE_LIMITED", "message": "..." }`. (Disabled under the test env.)

### GET `/api/auth/me`  (auth)
Returns the current account (used for offline-first re-validation on launch /
reconnect). A `401`/`403` here is the **only** thing that ends the local session.
```jsonc
// 200 response
{ "account": { /* Account */ } }
```

---

## Subscription — `/api/subscription`

### GET `/api/subscription/plans`  (public)
```jsonc
{ "plans": [ { /* Plan */ } ] }   // only active plans
```

### GET `/api/subscription`  (auth)
```jsonc
{ "subscription": { /* Subscription */ } }
```

### POST `/api/subscription/request`  (auth)
Requests a plan; goes to `pending` until an admin approves.
```jsonc
// request
{ "planCode": "monthly" }
// 200 response
{ "subscription": { "planCode": "monthly", "status": "pending" } }
```

---

## Device — `/api/device`  (all auth)

### GET `/api/device`         → `{ "devices": [ { /* Device */ } ] }`
### POST `/api/device/bind`   → body `{ "device": { /* Device */ } }` → `{ "device": { /* Device */ } }`
### DELETE `/api/device/:deviceId` → `{ "ok": true }`  (unbind a device)

`maxDevices` (from the active plan) is enforced on bind.

---

## Backup — `/api/backup`  (all auth)

Cloud backup of the device's SQLite file (`moldati.db`). Binary upload/download.

### POST `/api/backup`  (multipart/form-data)
field `file` = the `.db` file; optional fields `note`, `appVersion`.
```jsonc
// 201 response
{ "backup": { "id": "...", "size": 12345, "note": "...", "createdAt": "..." } }
```
### GET `/api/backup`              → `{ "backups": [ { "id", "size", "note", "createdAt" } ] }`
### GET `/api/backup/:id/download` → raw bytes, `Content-Type: application/octet-stream`
### DELETE `/api/backup/:id`       → `{ "ok": true }`

Backups are stored per-account (quota: keep last N, default 10). Backups are
scoped by the **effective owner**, so an accountant uploads/lists/downloads/
deletes within the **owner's** backup namespace (matching `/api/sync` and
`/api/account/*`).

---

## Sync — `/api/sync`  (all auth; gated by the `sync` feature)

Device → server mirror (push-only) + server → device restore (pull). The device
stays the source of truth; the per-account mirror is keyed by
`(effectiveOwner, entity, localId)`.

### POST `/api/sync/push`
```jsonc
// request
{ "records": [ { "entity": "subscribers", "localId": "uuid", "deleted": false,
                 "updatedAt": "ISO", "data": { /* raw SQLite row */ } } ] }
// 200 response
{ "ok": true, "count": 2, "serverTime": "ISO" }
```
**Authorization (new in Phase-1 hardening):**
- `entity` is whitelisted against the synced tables (`subscribers`, `boards`,
  `circuits`, `receipts`, `refunds`, `expenses`, `monthly_prices`, `branches`,
  `accountants`); any other value → `400 code=BAD_ENTITY`.
- For an **accountant** caller the entity is permission-gated, mirroring the app
  (`lib/core/permissions.dart`): `subscribers→subscribers`, `boards`/`circuits→
  boards`, `monthly_prices→prices`, `expenses→expenses`; `receipts`/`refunds`
  are **always allowed**; `branches`/`accountants` are **owner-only**. A missing
  permission → `403 code=PERMISSION_DENIED`; an owner-only entity →
  `403 code=ENTITY_FORBIDDEN`.
- A **branch-confined** accountant (has a `branchId`) may only write rows in its
  own branch: a record whose `data.branch_id` is another branch →
  `403 code=BRANCH_FORBIDDEN`; otherwise the server **stamps** `data.branch_id =
  accountant.branchId` and `data.accountant_id = accountant.localId` (the
  app-side accountant UUID used for on-device attribution — falls back to the
  Mongo `_id` only when no `localId` exists; client-supplied branch/accountant
  values are not trusted).
- Owners/admins are unrestricted (whole account, all branches).

Other errors: `400 code=BAD_RECORDS` (records not an array),
`400 code=BAD_RECORD` (missing `entity`/`localId`), `403 code=FEATURE_DISABLED`
(plan has no sync).

### GET `/api/sync/pull?since=ISO`
```jsonc
// 200 response
{ "records": [ { "entity", "localId", "deleted", "updatedAt", "data" } ] }
```
Returns the account's mirror rows updated after `since` (omit for a full
restore). A **branch-confined accountant** receives only its own branch's rows
plus the branch-agnostic identity tables (`branches`, `accountants`) and any
legacy rows that carry no `branch_id`; owners/admins receive everything.
Errors: `400 code=BAD_SINCE` (invalid timestamp).

---

## Account (owner self-service) — `/api/account`  (all auth, any role)

Read-only view of the **caller's own** synced mirror — what an owner logged
into the panel uses for its self-service dashboard. Always scoped to the JWT
user (the `:id` is implicit); works for `owner` and `admin` roles alike. There
is **no** write/delete counterpart here — mirror deletes stay admin-only.

### GET `/api/account/data`  (auth)

Same query params and response shape as
`GET /api/admin/users/:id/data` (see Admin below), but over the JWT user's own
mirror:
- `entity` (required), `q`, `page`, `limit`, `includeDeleted=true`
- `localId` (exact single-record fetch)
- `relField`/`relValue` (relationship filter, whitelisted:
  `subscriber_id · board_id · circuit_id`)

```jsonc
// 200 response — identical shape to the admin variant
{
  "entity": "subscribers",
  "records": [ { "localId": "uuid", "data": { /* the row */ }, "deleted": false, "updatedAt": "ISO" } ],
  "total": 150,
  "page": 1,
  "limit": 25
}
```
Errors: `400` missing `entity`.

### GET `/api/account/stats`  (auth)

Per-entity counts of the caller's **non-deleted** mirrored rows, plus an
app-style `dashboard` object for one month that replicates the Flutter
dashboard. Entities with no rows are reported as `0`.

Query params:
- `month` (optional): `YYYY-MM` — the month the `dashboard` object describes
  (monthly reports). Validated against `/^\d{4}-\d{2}$/`; when absent or
  malformed it falls back to the **current month** (server time, UTC).
  `dashboard.month` always echoes the month actually used.

Paid/unpaid formula (same as the app): with `P[category] = monthly_prices[month]`
(`data.price_per_amp` per category, `0` if there is no row), a subscriber is
**paid** when its month **coverage** — `Σ paid_amount + Σ discount_value` over
that month's receipts — is `>= amps * P[category]`. The receipt **discount** is
WAIVED money: it folds into the DUE side (coverage + `totalDue`) but is **never**
added to `collected`/`monthlyRevenue`/`netProfit`. With `P = 0` every subscriber
counts as paid. `totalDue` is kept raw (`expected - collected - Σ discount_value`)
and may go negative, like the app.

Pricing is keyed by **`(branch, category)`**: each subscriber's due uses the
price of its **own** branch (`IFNULL(branch_id,'main')`) and category. In the
**consolidated** view (no `branchId`) branches with different per-branch tariffs
are no longer collapsed into one category map — each branch keeps its own price
(fixes a bug where consolidated `expected`/`paidCount`/`totalDue` used whichever
`monthly_prices` row was seen last). With an explicit `branchId` the behavior is
unchanged. The caller's explicit `month` is honored as-is; only an absent/malformed
month falls back to the current server-UTC month.
```jsonc
// 200 response
{
  "counts": {                  // unchanged — per-entity row counts
    "subscribers": 12,
    "boards": 3,
    "circuits": 9,
    "receipts": 240,
    "expenses": 31,
    "monthly_prices": 6
  },
  "dashboard": {
    "month": "2026-06",        // requested ?month, else current month ('YYYY-MM', server UTC)
    "pricePerAmp": 5000,       // back-compat single price (standard tariff, else first), 0 if absent
    "categoryPrices": {        // per-tariff ampere price map for that month/branch
      "gold": 7000,            // (keys present only for categories with a monthly_prices row)
      "standard": 5000,
      "commercial": 6000
    },
    "totalSubscribers": 12,
    "totalAmps": 180,          // sum of subscriber amps
    "paidCount": 9,            // coverage (paid_amount + discount_value) >= due
    "unpaidCount": 3,
    "totalDue": 200000,        // expected - collected - Σ discount_value (raw, discount waived)
    "collected": 700000,       // Σ paid_amount over that month's receipts (discount NOT included)
    "expensesTotal": 150000,   // sum of expenses' data.amount whose data.date starts with the month
    "netProfit": 550000,       // collected - expensesTotal (may go negative)
    "boards": 3,
    "circuits": 9,
    "lastUploadAt": "ISO"      // most recent sync activity of any kind, null if none
  }
}
```

Receipt **discount** fields (`discount_type` `'none'|'ampere'|'value'`,
`discount_value` IQD waived, `discount_amps` nullable) ride through the
push-only mirror like any other receipt column (`SyncRecord.data` is whole-row
`Mixed` — no validation), so legacy receipts without them default to no discount
and behave exactly as before.

### Accountants — `/api/account/accountants`  (auth; role owner|admin)

Manage **accountant sub-accounts** of the caller. An accountant is a `User` with
`role:"accountant"`, `owner` = the caller, scoped to a `branchId`, with a set of
`permissions`. Accountants log in via `/api/auth/login` (device-exempt) and read/
write the **owner's** data mirror (effective-owner scoping — their `/api/sync`
push/pull and `/api/account/stats|data|recent` all resolve to the owner's mirror).

A non-owner/non-admin caller hitting any of these → `403 code=FORBIDDEN`.

The Accountant object returned here (compact, not the full Account):
```jsonc
{ "id": "mongoid", "localId": "uuid|null", "name": "...", "username": "...",
  "branchId": "...|null", "permissions": ["..."], "active": true }
```
`active` is the inverse of the underlying `blocked` flag.

#### POST `/api/account/accountants`  (owner|admin)
Creates an accountant owned by the caller. `username` is lowercased/trimmed and
must be unique across all accounts.
```jsonc
// request
{ "name": "Acct Name", "username": "acct1", "password": "secret",
  "branchId": "branch-uuid|null", "permissions": ["receipts","expenses"],
  "localId": "app-side-uuid|null" }
// 201 response
{ "accountant": { "id": "...", "localId": "...", "name": "Acct Name",
  "username": "acct1", "branchId": "...", "permissions": [...], "active": true } }
```
Errors: `409 code=USERNAME_TAKEN`, `400 code=VALIDATION` (missing name/username
or password < 4 chars).

#### GET `/api/account/accountants`  (owner|admin)
```jsonc
{ "accountants": [ { /* Accountant */ } ] }   // the caller's sub-accounts only
```

#### PUT `/api/account/accountants/:id`  (owner|admin)
Updates any of `{ name, permissions, branchId, active, password }` of one of the
caller's accountants (ownership guarded). A provided `password` is re-hashed;
`active:false` blocks the accountant (cannot log in).
```jsonc
// request (any subset)
{ "name": "...", "permissions": ["..."], "branchId": "...", "active": false, "password": "newpass" }
// 200 response
{ "accountant": { /* Accountant */ } }
```
Errors: `404 code=ACCOUNTANT_NOT_FOUND` (not the caller's accountant).

#### DELETE `/api/account/accountants/:id`  (owner|admin)
Deletes one of the caller's accountants (ownership guarded).
```jsonc
// 200 response
{ "ok": true }
```
Errors: `404 code=ACCOUNTANT_NOT_FOUND`.

---

## Admin — `/api/admin`  (auth + role=admin)

- `GET    /api/admin/users`                         list accounts
- `POST   /api/admin/users`                         create account
- `GET    /api/admin/users/:id`                     account detail
- `DELETE /api/admin/users/:id`                     delete account
- `PUT    /api/admin/users/:id/blocked`             body `{ "blocked": true|false }`
- `PUT    /api/admin/users/:id/plan`                body `{ "planCode": "...", "status": "active" }`
- `POST   /api/admin/users/:id/approve-plan`        approve pending request
- `POST   /api/admin/users/:id/reject-plan`         reject pending request
- `DELETE /api/admin/users/:id/devices/:deviceId`   unbind a device
- `GET    /api/admin/users/:id/data`                 list an owner's synced mirror rows (search + paginate, see below)
- `DELETE /api/admin/users/:id/data/:entity/:localId` hard-delete one mirrored record
- `GET    /api/admin/plans`                          list all plans
- `PUT    /api/admin/plans`                          upsert a plan (body = Plan)
- `DELETE /api/admin/plans/:code`                    delete a plan
- `GET    /api/admin/events`                         Server-Sent Events stream (admin via `?token=`, see below)

The admin SPA (`backend/public/admin/index.html`) is a hash-routed single-file
app driving exactly these endpoints with a Bearer JWT.

### GET `/api/admin/users/:id/data`  (admin) — synced-data mirror, read-only

Lists the business rows an owner pushed for one entity. The mirror is **push-only**
(device → server via `/api/sync`); admins can search/paginate and **delete**, but
never create or edit.

Query params:
- `entity` (required): one of `subscribers · boards · circuits · receipts · expenses · monthly_prices · refunds`.
- `q` (optional): case-insensitive substring filter over per-entity search fields,
  applied **before** pagination. Search fields:
  `subscribers→name,phone · boards→name,code · circuits→name,phase ·
  receipts→receipt_no,month · expenses→category,note · monthly_prices→month`
  (unknown entity falls back to matching `localId`).
- `page` (optional, 1-based, default `1`).
- `limit` (optional, default `25`, clamped to `1..200`).
- `includeDeleted=true` (optional): include deleted tombstones (excluded by default).

Records are sorted `updatedAt` **desc** (newest first).
```jsonc
// 200 response
{
  "entity": "subscribers",
  "records": [ { "localId": "uuid", "data": { /* the row */ }, "deleted": false, "updatedAt": "ISO" } ],
  "total": 150,   // matching records after `q`, before the page slice
  "page": 1,
  "limit": 25
}
```
Errors: `400` missing `entity`, `404` user not found.

### DELETE `/api/admin/users/:id/data/:entity/:localId`  (admin)
Hard-deletes that one mirrored `SyncRecord` for the user (the only admin write to
the mirror). Does not touch the device's local SQLite source of truth.
```jsonc
// 200 response
{ "ok": true }
```
Errors: `404` record not found.

### GET `/api/admin/events`  (admin, real-time SSE)

A long-lived **Server-Sent Events** stream the admin panel subscribes to so it
can react live to backend activity (e.g. a new account just registered).

Auth: the JWT is passed as a **`?token=<jwt>` query param** (not the
`Authorization` header) because the browser `EventSource` API cannot set custom
headers. The token must belong to a `role=admin` user. Errors: `401` missing /
invalid token, `403` not an admin.

Response: `Content-Type: text/event-stream` (keep-alive). The server sends a
`: connected` comment on open and a `:hb` heartbeat comment every ~25s. Each
real event is framed as:
```
event: user_registered
data: {"id":"...","name":"...","username":"...","phone":null,"generatorName":null,"createdAt":"ISO"}
```
Emitted events:
- `user_registered` — fired right after a new owner account is saved by
  `POST /api/auth/register`. Payload:
  `{ id, name, username, phone, generatorName, createdAt }`.

Client example:
```js
const es = new EventSource(`${API}/api/admin/events?token=${jwt}`);
es.addEventListener('user_registered', (e) => {
  const acct = JSON.parse(e.data);
  // refresh the users list / show a toast
});
```

---

## Public — `/api/public`  (no auth)

Open endpoints reachable without a JWT. Backs the scan-a-QR receipt view.

### GET `/api/public/receipt/:uuid`  (public)

Resolves a receipt by its device UUID (`receipts.localId`) across **all** accounts'
mirrors so a scanned QR can be viewed without logging in. Looks up the receipt
`SyncRecord` (`entity: receipts`, not deleted); the subscriber name comes from the
same owner's `subscribers` mirror (matched on `data.subscriber_id`) and the
generator name from the owning `User.generatorName`. Receipt fields are
whitelisted (`receipt_no`, `month`, `amps_snapshot`, `price_snapshot`,
`paid_amount`, `remaining_after`, `issued_at`, `status`).

Always responds `200`; `found` is `false` when no matching (non-deleted) receipt
exists.
```jsonc
// 200 response (found)
{
  "found": true,
  "receipt": {
    "receipt_no": 42,
    "month": "2026-06",
    "amps_snapshot": 5,
    "price_snapshot": 15000,
    "paid_amount": 75000,
    "remaining_after": 0,
    "issued_at": "ISO",
    "status": "paid"
  },
  "subscriberName": "Subscriber Name",   // null if missing
  "generatorName": "Generator Name"      // null if missing
}
// 200 response (not found)
{ "found": false, "receipt": null, "subscriberName": null, "generatorName": null }
```

The Flutter receipt QR encodes `${API_BASE_URL}/admin/#/r/<uuid>`; the admin SPA's
`#/r/:uuid` route renders this standalone (no login / no nav).

---

## Objects

### Account
```jsonc
{
  "id": "mongoid",
  "name": "Owner Name",
  "phone": "0770...",
  "username": "owner1",
  "role": "owner|admin|accountant",
  "ownerId": null,          // accountant only: the parent owner/admin account id (string); null for owner/admin
  "branchId": null,         // accountant only: the branch the accountant is scoped to; null otherwise
  "permissions": [],        // accountant only: granted permission keys; [] for owner/admin
  "localId": null,          // accountant only: the app-side accountant UUID (attribution round-trip); null otherwise
  "blocked": false,
  "createdAt": "ISO",
  "subscription": { /* Subscription */ },
  "devices": [ { /* Device */ } ]
}
```
`ownerId`/`branchId`/`permissions`/`localId` are always present; they carry
values only for `role:"accountant"` sub-accounts (see **Accountant logins** and
**Account → Accountants** below) and are `null`/`[]` for owners and admins.
### Subscription
```jsonc
{
  "planCode": "monthly|null",
  "status": "none|pending|active|rejected|expired",
  "startedAt": "ISO|null",
  "expiresAt": "ISO|null",
  "features": {                // resolved LIVE from the active plan's flags
    "sync": true,              // online data sync (push/pull)
    "backup": true,            // cloud backup
    "ownerPanel": true         // owner self-service panel (#/my*, /api/account/*)
  }
}
```
**Expiry enforcement.** A subscription is *effectively active* only when its
stored `status` is `active` **and** it has not passed `expiresAt` (a null
`expiresAt` means no expiry). Once the expiry passes, the served `status` is
**downgraded to `"expired"`** (clients key off the status string) and the plan
stops being treated as active: `features` then fall back to the all-`true`
no-active-plan defaults, so an expired restricted plan no longer blocks
sync/backup/ownerPanel. This is applied uniformly by `serializeSubscription` and
`planFeatures.featuresForUser`.

`features` is attached on the **Account** returned by
`/api/auth/register`, `/api/auth/login`, and `/api/auth/me`. It mirrors the
**active** plan's capability flags (each `= plan.<x>Enabled !== false`). With no
active subscription (or no plan / an **expired** plan), every flag defaults to
`true`. The backend enforces these via `requireFeature(name)` (403
`code=FEATURE_DISABLED`, `message:'هذه الميزة غير متوفرة في خطتك'`,
`feature:name`).

### Plan
```jsonc
{
  "code": "monthly", "name": "Monthly", "durationDays": 30, "maxDevices": 1,
  "price": 0, "description": "...", "active": true,
  "syncEnabled": true,         // plan includes online data sync
  "backupEnabled": true,       // plan includes cloud backup
  "ownerPanelEnabled": true    // plan includes the owner self-service panel
}
```
The three capability flags are Booleans that **default `true`** (existing plans
keep all capabilities). Admins set them per-plan via
`PUT /api/admin/plans` (each `optional().isBoolean()`); an edit that omits a flag
leaves it unchanged. An account's **active** plan drives
`subscription.features` (above) everywhere.
### Device
```jsonc
{ "deviceId": "...", "installId": "...", "platform": "android", "model": "...", "brand": "...", "osVersion": "...", "imei": null, "mac": null, "boundAt": "ISO", "lastSeen": "ISO", "current": true }
```
