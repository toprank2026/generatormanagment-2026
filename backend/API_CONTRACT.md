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
when the plan's `maxDevices` is exceeded by a new device.

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

Backups are stored per-account (quota: keep last N, default 10).

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
  "role": "owner|admin",
  "blocked": false,
  "createdAt": "ISO",
  "subscription": { /* Subscription */ },
  "devices": [ { /* Device */ } ]
}
```
### Subscription
```jsonc
{
  "planCode": "monthly|null",
  "status": "none|pending|active|rejected|expired",
  "startedAt": "ISO|null",
  "expiresAt": "ISO|null"
}
```
### Plan
```jsonc
{ "code": "monthly", "name": "Monthly", "durationDays": 30, "maxDevices": 1, "price": 0, "description": "...", "active": true }
```
### Device
```jsonc
{ "deviceId": "...", "installId": "...", "platform": "android", "model": "...", "brand": "...", "osVersion": "...", "imei": null, "mac": null, "boundAt": "ISO", "lastSeen": "ISO", "current": true }
```
