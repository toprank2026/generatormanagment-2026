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

> 🚨 **DEPLOY ORDER — Flash v43 (hard constraint, not advice).**
> **The backend MUST be deployed BEFORE a single v43 APK is installed** — not the
> other way round, and not simultaneously. v43 adds two synced entities
> (`corrections`, `financial_adjustments`). `POST /api/sync/push` throws
> `400 code=BAD_ENTITY` **for the whole batch** on an unknown entity, so a v43 app
> pushing one of them at a backend that does not know them makes **every** push of
> that device fail — forever, for every entity — and because `SyncService.pull()`
> **pushes first**, that device's synchronisation stops completely (dashboard
> zeros, "N pending" that never clears). The registration is inert until an app
> actually pushes such a row, so shipping the backend early is safe; shipping it
> late is unrecoverable without clearing app data.

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
- the returned `generatorName` is **inherited from the OWNER account** (an
  accountant has none of its own), so receipts an accountant prints carry the
  owner's generator name in the header;
- the returned account carries `role:"accountant"`, `ownerId`, `branchId`,
  `permissions`, `localId` (see the **Account** object).

`GET /api/auth/me` applies the same inheritance for an accountant token.

**Branch logins.** When the matched user has `role:"owner"` but `parentOwner`
set (a branch sub-account created via `POST /api/account/branches`):
- the password is verified normally and the `device` is bound / `maxDevices`
  enforced **like a normal owner** (a branch is a real owner of its own mirror —
  NOT device-exempt, unlike accountants);
- a **blocked/missing parent** → `403 code=BLOCKED` (cascade), at login and on
  every authed request (`requireAuth`) — **always**, regardless of plan mode;
- the returned account carries `parentOwnerId` and `independentPlan` (see the
  **Account** object).

Subscription/feature reporting splits on the `independentPlan` flag (Flash v13
Phase D):
- **Independent branch** (`independentPlan:true` — every branch created on/after
  Phase D): the returned `subscription` (incl. `features`) is the branch's **OWN**
  subscription. A new branch starts `status:"none"` with the chosen `planCode`
  pending the **super-admin's own approval** (`PUT /api/admin/users/:branchId/plan`),
  so it is `subscriptionBlocked` until activated, exactly like a freshly-registered
  owner. It does **NOT** inherit the parent's plan.
- **Legacy branch** (`independentPlan` falsy — branch docs created before Phase D):
  the returned `subscription` (incl. `features`) is **inherited from the parent
  top-level owner** (`parentOwnerId`), so the branch is never `subscriptionBlocked`
  on its own (empty) subscription — unchanged from the previous contract.

`GET /api/auth/me` applies the same split for a branch token.

**Rate limiting.** `POST /api/auth/login`, `POST /api/auth/register`,
`POST /api/auth/recover-device` and (Flash v42) `POST /api/auth/forgot-password`
+ `GET /api/auth/forgot-password/status` are IP-rate-limited (~10 requests /
minute / IP). Exceeding the limit returns
`429 { "code": "RATE_LIMITED", "message": "..." }`. (Disabled under the test env.)

### POST `/api/auth/recover-device`  (public, rate-limited) — new in Phase-2
Password-authenticated self-service for an **owner** locked out by `maxDevices`
(lost / replaced their device). Validates the credentials, then **evicts the
least-recently-seen device** (by `lastSeen`) to free a slot, binds the supplied
`device`, and returns a normal login response.
```jsonc
// request
{ "username": "owner1", "password": "secret", "device": { /* Device */ } }
// 200 response
{ "token": "<jwt>", "account": { /* Account */ } }   // new device bound, current:true
```
Errors: `400 code=VALIDATION` (`device.deviceId` missing), `401` bad
credentials, `403 code=BLOCKED` account blocked, `403 code=RECOVERY_NOT_ALLOWED`
(role is not `owner` — accountants are device-exempt and admins unrestricted,
so neither needs recovery), `429 code=RATE_LIMITED`. Re-binding an
already-known device just refreshes it (no eviction). **v23:** the Flutter app
now calls this after a `403 code=DEVICE_LIMIT` login (the user opts to "move the
account to this device").

### POST `/api/auth/forgot-password`  (public, rate-limited) — new in Flash v42
Owner/admin password recovery whose identity **verification and approval happen
in the super-admin panel**, never automatically. The account is matched on
`username` and the supplied `phone` must equal that account's **registered
phone** (the identity check) — a phone mismatch is reported exactly like an
unknown username, so the endpoint cannot be used to probe which usernames exist.
```jsonc
// request
{ "username": "owner1", "phone": "0770...", "newPassword": "newsecret" }
// 201 response
{
  "requestId": "mongoid",     // + `code` are the keys of the status endpoint
  "code": "482913",           // 6-digit reference the owner reads back to the super admin
  "status": "pending",
  "expiresAt": "ISO"          // createdAt + 24h
}
```
- `newPassword` is stored on the pending request **already bcrypt-hashed**; the
  plaintext never leaves the request payload and is never written to the account.
- **Nothing on the account changes here** — password, `tokenVersion` and every
  live session are untouched until a super admin approves (see
  `POST /api/admin/password-resets/:id/approve`, the only thing that changes a
  password).
- **One active pending request per account:** a new request **supersedes** any
  still-pending request of that account, so an owner who retries always has
  exactly one live code.
- The request **expires 24 h** after creation; an expired request can never be
  approved.

Errors: `400 code=VALIDATION` (missing `username`/`phone`, or `newPassword`
shorter than 4 chars), `404 code=ACCOUNT_NOT_FOUND` (no account whose username
**and** registered phone both match), `429 code=RATE_LIMITED`.

### GET `/api/auth/forgot-password/status?requestId=…&code=…`  (public, rate-limited)
Polled by the app while the owner waits for the super admin's decision.
`requestId` + the 6-digit `code` are the **only** keys (no session exists yet),
and the pair rides `authLimiter` so the code cannot be brute-forced.
```jsonc
// 200 response
{
  "status": "pending",     // 'pending' | 'approved' | 'rejected' | 'expired'
  "decidedAt": null,       // ISO once approved/rejected, else null
  "expiresAt": "ISO"       // createdAt + 24h
}
```
A stored-`pending` request whose `expiresAt` has passed reports `expired`. On
`approved` the new password is already live on the account (and every older JWT
is dead — see the approve endpoint), so the app just sends the owner back to the
login screen. Errors: `400 code=VALIDATION` (missing `requestId`/`code`), `404`
when no request matches that `requestId`+`code` pair (a wrong code never
discloses another request's status), `429 code=RATE_LIMITED`.

### GET `/api/auth/me`  (auth)
Returns the current account (used for offline-first re-validation on launch /
reconnect). A `401`/`403` here is the **only** thing that ends the local session.
```jsonc
// 200 response
{ "account": { /* Account */ } }
```
**Token invalidation on password change (new in Phase-2).** The JWT embeds the
account's `tokenVersion` (`tv` claim). Any password change (e.g. an owner
resetting an accountant's password via `PUT /api/account/accountants/:id`) bumps
`tokenVersion`, so every token minted before the change is rejected by ALL
authenticated routes with `401 code=TOKEN_STALE` (the client must sign in again).
A legacy token with no `tv` claim is treated as `tv=0`. **Flash v42:** a
super-admin **approved** password-reset request
(`POST /api/admin/password-resets/:id/approve`) is a password change like any
other and bumps `tokenVersion` the same way.

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
Optional `?current=<deviceId>` (v23) flags the caller's own row `current:true`
(so the app can label "(this device)" + warn before unbinding it); omitted → all
`current:false` (prior behavior).
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
{ "ok": true, "count": 2, "rejected": [], "serverTime": "ISO" }
```
**Authorization (new in Phase-1 hardening):**
- `entity` is whitelisted against the synced tables (`subscribers`, `boards`,
  `circuits`, `receipts`, `refunds`, `expenses`, `monthly_prices`, `branches`,
  `accountants`, `settlements`, and — **new in Flash v43** — `corrections`,
  `financial_adjustments`); any other value → `400 code=BAD_ENTITY`. **This 400
  fails the WHOLE batch**, which is why the two v43 entities must be registered
  on the backend before any v43 APK ships (see the deploy-order callout at the
  top of this document).
- For an **accountant** caller the entity is permission-gated, mirroring the app
  (`lib/core/permissions.dart`): `subscribers→subscribers`, `boards`/`circuits→
  boards`, `monthly_prices→prices`, `expenses→expenses`; `receipts`/`refunds`/
  `settlements`/`corrections` are **always allowed** (core accountant work) —
  except that an accountant may only push a `settlements` row with
  `status:'pending'` (see `SETTLEMENT_DECISION_FORBIDDEN` below);
  `branches`/`accountants`/`financial_adjustments` are **owner-only**. A missing
  permission → `403 code=PERMISSION_DENIED`; an owner-only entity →
  `403 code=ENTITY_FORBIDDEN`.
- A **branch-confined** accountant (has a `branchId`) may only write rows in its
  own branch: a record whose `data.branch_id` is another branch →
  `403 code=BRANCH_FORBIDDEN`; otherwise the server **stamps** `data.branch_id =
  accountant.branchId` and `data.accountant_id = accountant.localId` — **except
  on `corrections`/`financial_adjustments`, where `accountant_id` is a WALLET
  TARGET the app resolves to whoever collected that month (often not the
  filer), so it is left exactly as sent** (the
  app-side accountant UUID used for on-device attribution — falls back to the
  Mongo `_id` only when no `localId` exists; client-supplied branch/accountant
  values are not trusted).
- Owners/admins are unrestricted (whole account, all branches).

**Conflict resolution (new in Phase-2 hardening): last-EDIT-wins + sticky
tombstones.** Each business row may carry its REAL modification time in
`data.updated_at` (ISO string); the envelope `updatedAt` is the upload time
(pull cursor only). The server reads the existing mirror doc first, then:
- **Upsert (`deleted:false`)** — if BOTH the incoming `data.updated_at` and the
  stored row's `data.updated_at` are present and the incoming one is OLDER, the
  write is **SKIPPED** (a stale device cannot clobber a newer edit).
- **Sticky tombstone** — when the stored row is a tombstone (`deleted:true`), an
  upsert only revives it when the incoming edit time is present AND strictly
  newer than the recorded delete time (`stored data.updated_at`, else the
  tombstone's envelope `updatedAt`); otherwise it is **SKIPPED** (a stale edit
  never resurrects a deleted row).
- **Delete (`deleted:true`)** — always tombstones (never un-delete-protected).
- **Backward compatible** — if the per-row edit time is absent on either side,
  the old apply-always behavior is kept, so today's clients are unaffected.
- A SKIPPED record is still **counted** in the `count` response (treated as
  accepted) so the device drains its outbox and does not loop re-pushing it.
- **v25 — unauthorized records are SKIPPED, not batch-fatal:** when an
  accountant pushes a record its authorization forbids (owner-only identity
  entities `branches`/`accountants` → was `ENTITY_FORBIDDEN`; a missing entity
  permission → was `PERMISSION_DENIED`; a cross-branch row → was
  `BRANCH_FORBIDDEN`), the record is skipped-and-counted exactly like a stale
  upsert and NEVER enters the mirror. Previously these threw a 403 that failed
  the WHOLE batch — one device-auto-created row (the boot-time Main-branch
  `ensureMain` insert) permanently wedged an accountant device's sync (push
  always failed → pull never ran → only clearing app data recovered).

**Flash v43 — why there is NO business-rule lock on this endpoint, and the
additive `rejected[]`.** v43 first re-evaluated the app's invoice/settlement
lock here, against the owner mirror, so a hand-crafted push could not slip a
locked-month change past the app. **That gate was removed after adversarial
review showed it is net-destructive on this architecture.** The reasoning is
recorded here so it is not reintroduced:

- The mirror is **push-only** and the **device is the source of truth**.
  `pull()` is a **full restore** (`INSERT OR REPLACE`) run on a new device,
  after delete-local-data, and on **every branch switch**. So any row the server
  refuses becomes a permanent divergence, and that divergence materialises as
  **silent data loss** at the next restore: the device's real value is
  overwritten by the stale mirror value.
- The server **cannot reproduce the app's rules**. A `subscribers` row carries
  no month, so a server lock could only ask "was this subscriber *ever*
  invoiced" — strictly stricter than the app's month-scoped rule, so it refused
  ordinary amps/category edits aimed at an **open** month. Likewise the app's
  receipt-reversal rule is per-accountant, per-method and issue-time-based,
  while the server could only see "does this month carry any active settlement"
  — so it refused reversals the app itself permits.
- Decisively, this is a **live, mixed-version fleet**. A v42 device has no
  client-side v43 guard at all, so a new server-side refusal breaks a workflow
  that works today and costs that account real data. Accepting the row is never
  worse than yesterday's behaviour; refusing it is.

v43 therefore enforces its rules where enforcement **cannot diverge**:
1. **the app** — `MonthlyPriceRepository.insertGuarded` (tariff),
   `CoreController.updateSubscriber` (billing basis), and the correction flow;
2. **the direct admin REST surface** — `DELETE /api/admin/users/:id/data/...`
   refuses a settled receipt/settlement (`409`) and refuses an append-only
   `corrections`/`financial_adjustments` row outright, and the correction
   decision routes below are admin-authenticated. That is where a "manual API
   request" actually reaches, and where a refusal has no device counterpart to
   desynchronise.

**The one refusal kept on this path** is forgery no app version can produce: an
**accountant** pushing an already-decided `settlements` row (`status` other than
`pending`) → skipped with reason `SETTLEMENT_DECISION_FORBIDDEN`. An accountant
may *request* a settlement; only an owner/admin may *decide* one. The server
also blanks `decided_by`/`decided_at` on any accountant-pushed settlement.

**A refused row NEVER fails the batch.** It is logged, **counted in `count`**,
skipped (it never enters the mirror), and reported in the additive `rejected[]`:
```jsonc
// 200 response — the batch still SUCCEEDED
{
  "ok": true,
  "count": 3,          // includes the rejected row: the device DRAINS its outbox
  "rejected": [
    { "entity": "settlements", "localId": "uuid", "reason": "SETTLEMENT_DECISION_FORBIDDEN" }
  ],
  "serverTime": "ISO"
}
```
`rejected[]` also carries the pre-existing accountant permission skips
(`ENTITY_FORBIDDEN`, `PERMISSION_DENIED`, `BRANCH_FORBIDDEN`), which were
previously logged but not reported.

🚨 **Never a 4xx here.** A 4xx raised inside the push loop fails the WHOLE batch:
every unrelated row behind the offending one is refused, the outbox never drains,
and because `SyncService.pull()` **pushes first**, that device's synchronisation
stops permanently. That is a real production incident on this system — it is why
v25 downgraded the accountant `403` path to skip-and-count.

**Older clients are unaffected.** `rejected` is purely additive — the response
always carries it (an empty array when nothing was refused), alongside the
unchanged `ok` / `count` / `serverTime`. A client that never reads the field
still gets the same `200`, the same `count`, and drains its outbox exactly as
before.

Other errors: `400 code=BAD_RECORDS` (records not an array),
`400 code=BAD_RECORD` (missing `entity`/`localId`), `403 code=FEATURE_DISABLED`
(plan has no sync).

### GET `/api/sync/pull?since=ISO[&receiptsMonth=YYYY-MM]`
```jsonc
// 200 response
{ "records": [ { "entity", "localId", "deleted", "updatedAt", "data" } ] }
```
Returns the account's mirror rows updated after `since` (omit for a full
restore). A **branch-confined accountant** receives only its own branch's rows
plus the branch-agnostic identity tables (`branches`, `accountants`) and any
legacy rows that carry no `branch_id`; owners/admins receive everything.

Optional **`receiptsMonth=YYYY-MM`** (new in Flash v11): when present, ONLY the
`receipts` entity is restricted to rows whose `data.month` equals it — **every
other entity is unaffected**. Used by the post-login pull to restore just the
current month's receipts (the device passes its own selected month). `since`
still applies to all entities; combine freely with the branch-confined filter.

Errors: `400 code=BAD_SINCE` (invalid timestamp).

### Synced entities `corrections` + `financial_adjustments`  (new in Flash v43)

Two **new tables** (SQLite `version: 16`) that let an already-invoiced or
already-settled month be corrected **without editing a single existing row**.
They are deliberately new tables and never new columns on `subscribers`,
`receipts`, `monthly_prices` or `settlements`: `SyncService.pull` writes with
`ConflictAlgorithm.replace` (`INSERT OR REPLACE` = delete + insert), so a column
an older device does not know about is reset **account-wide** on every device's
next pull. They push and pull through `/api/sync` like any other business row —
`data` is Mixed, so there is no backend schema change.

**`corrections`** — the request and its lifecycle (an audit document):
```jsonc
{
  "id": "uuid",                    // == the record's localId
  "subscriber_id": "uuid",
  "month": "2026-08",              // TARIFF/accounting month being corrected
  "branch_id": "uuid",
  "accountant_id": "uuid",         // whose wallet an approved delta lands in
  "receipt_uuid": "uuid|null",     // the invoice that locked the month
  "settlement_id": "uuid|null",    // the settlement that locked the month
  "reason": "meter was misread",
  "old_amps": 5, "new_amps": 6,    // what the month WAS billed on / should be
  "old_due": 50000, "new_due": 60000,
  "difference": 10000,             // new_due − old_due; >0 increase, <0 decrease
  "status": "pending",             // pending|approved|rejected|refund_due|completed
  "requested_by": "user id", "requested_at": "ISO",
  "decided_by": "user id", "decided_at": "ISO", "decision_note": "...",
  "refund_paid_at": "ISO", "refund_paid_by": "user id",
  "created_at": "ISO", "updated_at": "ISO"
}
```
Lifecycle: `pending → approved | rejected`, and for a **decrease**
`pending → refund_due → completed` (the cash return is its own step).
Golden rule: *invoice month = accounting month = settlement month = correction
month* — a correction can never affect another month.

**`financial_adjustments`** — the immutable signed money delta:
```jsonc
{
  "id": "uuid",                    // UUIDv5 derived from (correction_id, kind)
  "correction_id": "uuid",
  "subscriber_id": "uuid",
  "month": "2026-08",              // the same tariff bucket as receipts/settlements
  "branch_id": "uuid",
  "accountant_id": "uuid|null",    // null on refund_return — see the money rule
  "kind": "correction_increase",   // correction_increase|correction_decrease|refund_return
  "amount": 10000,
  "method": "cash",                // 'cash'|'card' — which wallet, like settlements
  "created_at": "ISO", "created_by": "user id", "updated_at": "ISO"
}
```
- **APPEND-ONLY.** A row is written once — at approval, or when the physical
  cash return is recorded — and is **never updated and never deleted**, by any
  code path, repository method or admin action. Correcting a mistake means
  appending another adjustment, never rewriting one.
- The `id` is a **deterministic UUIDv5 of `(correction_id, kind)`** and the
  insert is ignore-on-conflict, so a retried approval, a re-delivered command or
  the same decision arriving from a second device can only ever re-write the row
  that is already there — never a double credit to the wallet.
- **Push permission.** `corrections` is *always allowed* for an accountant (like
  `receipts`/`settlements`): the correction request is precisely the escape
  hatch for an accountant who may **not** edit a locked month, so gating it on
  the `subscribers` permission would silently drop the request of the only
  accountant who needs it. `financial_adjustments` is **owner/admin-only** — an
  accountant able to push one could mint their own wallet credit; an accountant's
  push of it is refused (`ENTITY_FORBIDDEN`) and then skipped-and-counted by the
  push loop, so it can never wedge a device. Branch-confined accountants get
  their `branch_id`/`accountant_id` server-stamped on both entities, exactly as
  on every other entity.
- Both are browsable through `GET /api/admin/users/:id/data?entity=…` (and the
  owner's `/api/account/data`); neither has per-field search, so `q` falls back
  to matching `localId`.

**The money rule.** An adjustment is folded into **exactly** these figures and
nothing else: the accountant wallet (`GET /api/account/wallet`, both the
`?month=` and the all-time branch; on the device `walletForMonth`, `wallet()`
and `monthUnsettled`) and the collected/revenue sum. It is **never** folded into
the paid/unpaid derivation or coverage (coverage is what the subscriber *paid*;
a correction changes the *due*), never into a printed receipt or PDF (an invoice
is a historical document), and it never consumes a `receipt_no`.

| `kind` | written when | `amount` | wallet effect |
| --- | --- | --- | --- |
| `correction_increase` | an increase is approved | `+abs(difference)` | that month's wallet **rises** → an additional settlement for the month becomes possible |
| `correction_decrease` | a decrease is approved | `+abs(difference)` (audit only) | **exactly 0** — a decrease must never reduce the wallet, which may never be driven negative by a historical correction |
| `refund_return` | the physical cash return is recorded | `−abs(difference)` | the cash left the business, so the month's collected/revenue falls by it. `accountant_id` is deliberately **null**: every accountant-wallet query filters on `accountant_id`, so the return is invisible to them and can never push an accountant's wallet negative |

Approving a decrease and handing the money back are **two separate,
separately-recorded operations** — approval alone never asserts that cash moved.

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
  `subscriber_id · board_id · circuit_id · branch_id · accountant_id`).
  **v23:** `relValue=__none__` matches rows with a NULL value for the field
  (e.g. owner-created expenses have `accountant_id: null`).
- `month=YYYY-MM` (**v23**, expenses only) — prefix-filters `data.date`.
- **v23:** for `entity=expenses` the response also includes
  `totalAmount` = Σ `data.amount` over the SAME filter (not just the page).

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
added to `collected`/`monthlyRevenue`/`netProfit`. **v23:** a subscriber whose
category has **no `monthly_prices` row** for the month counts **UNPAID** (like the
app — subscribers start unpaid until a price is set); an explicit price of `0`
still counts paid. `totalDue` is kept raw (`expected - collected - Σ discount_value`)
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
    "monthly_prices": 6,
    "accountants": 2,
    "branches": 1,
    "settlements": 4          // Flash v11 wallet settlement requests
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
    "expected": 200000,        // v23: category-aware Σ amps × price[category]
    "paidCount": 9,            // coverage (paid_amount + discount_value) >= due (unpriced category => unpaid)
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
caller's accountants (ownership guarded). A provided `password` is re-hashed and
**bumps the accountant's `tokenVersion`**, so its previously-issued tokens become
`401 code=TOKEN_STALE` (see `GET /api/auth/me`); `active:false` blocks the
accountant (cannot log in). **v23 (§3.3):** setting `password` REQUIRES the
caller's OWN password in `ownerPassword` (`bcrypt.compare` vs the owner) → wrong/
absent = `401 code=WRONG_PASSWORD`, and the new password must be ≥ 4 chars
(`400 code=WEAK_PASSWORD`); nothing is mutated when the check fails. Non-password
edits need no `ownerPassword`.
```jsonc
// request (any subset; ownerPassword required only when setting password)
{ "name": "...", "permissions": ["..."], "branchId": "...", "active": false, "password": "newpass", "ownerPassword": "my-own-pass" }
// 200 response
{ "accountant": { /* Accountant */ } }
```
Errors: `404 code=ACCOUNTANT_NOT_FOUND` (not the caller's accountant);
`401 code=WRONG_PASSWORD`, `400 code=WEAK_PASSWORD` (password reset).

#### DELETE `/api/account/accountants/:id`  (owner|admin)
Deletes one of the caller's accountants (ownership guarded).
```jsonc
// 200 response
{ "ok": true }
```
Errors: `404 code=ACCOUNTANT_NOT_FOUND`.

#### PUT `/api/account/profile`  (owner|admin — accountants 403)
Self-edit of the caller's OWN `{ name, phone, generatorName, username, password }`.
A `password` change bumps `tokenVersion` (old JWTs → `TOKEN_STALE`) and the
response returns a FRESH `token` so the editing device stays signed in. **v23
(§3.2):** setting `password` REQUIRES the caller's `currentPassword` (`bcrypt.compare`)
→ wrong/absent = `401 code=WRONG_PASSWORD`; new password must be ≥ 4 chars
(`400 code=WEAK_PASSWORD`); nothing is mutated when the check fails.
```jsonc
// request (any subset; currentPassword required only when setting password)
{ "name": "...", "phone": "...", "generatorName": "...", "username": "...", "password": "newpass", "currentPassword": "old-pass" }
// 200 response
{ "token": "<fresh jwt>", "account": { /* Account */ } }
```
Errors: `409 code=USERNAME_TAKEN`/`PHONE_TAKEN`; `401 code=WRONG_PASSWORD`;
`400 code=WEAK_PASSWORD`; `403 code=FORBIDDEN` (accountant).

**Accountant creation by phone (Flash v11).** `POST /api/account/accountants`
now takes the accountant's **phone** (the login identifier): the body is
`{ name, phone, password, branchId?, permissions?, localId? }`. The `username` is
**derived** as `phone.toLowerCase()` (exactly like register), and both the phone
and the derived username must be unique → `409 code=PHONE_TAKEN` (phone in use)
or `409 code=USERNAME_TAKEN` (derived username in use). The accountant then logs
in via `POST /api/auth/login` with that **phone** + password.
**Backward-compat:** an old client that still sends `username` (and no `phone`)
is accepted — the username is used directly and `phone` stays `null`. Missing
both phone and username, or a password `< 4` chars → `400 code=VALIDATION`.

### Settlements — `/api/account/settlements`  (auth)

A **settlement** is an accountant **wallet** record — the cash an accountant owes
the owner — synced as a normal business entity (`entity:"settlements"`, device is
the source of truth). Each row:
`{ id, accountant_id, branch_id, amount, method:'cash'|'card', status:'pending'|'approved'|'rejected',
month, requested_at, decided_at, decided_by, note, updated_at }`. `method` is the payment
method the settlement is for (Flash v12; absent = `'cash'`); `month` is the
**tariff/accounting** month the settlement belongs to (`YYYY-MM`, Flash v40 —
stamped from the device's global pricing month at request time, so it can differ
from `requested_at`'s calendar month; absent on pre-v40 rows, for which
`requested_at`'s `YYYY-MM` prefix is the fallback). `data` is Mixed so it
rides through `/api/sync` with no schema change. An accountant CREATES a
**pending** settlement by pushing it via `/api/sync/push` (always allowed; a
branch-confined accountant's `branch_id`/`accountant_id` are server-stamped, so a
request cannot be forged for another branch/accountant). The owner then approves
or rejects it.

#### POST `/api/account/settlements/:localId/decision`  (owner|admin)
The owner records a decision on one of its accountants' settlement requests. It
mutates the **owner mirror** `SyncRecord` (`entity:"settlements"`, `localId`) in
place — setting `data.status`, `data.decided_at` (now, ISO), `data.decided_by`
(`req.user._id`), an optional `data.note`, and bumping `data.updated_at` to now so
**last-EDIT-wins** applies this decision over the accountant's older pending row
on its next pull (the accountant pulls the decision; there is no separate push).
```jsonc
// request
{ "status": "approved", "note": "optional" }   // status: 'approved' | 'rejected'
// 200 response
{ "settlement": { /* the updated row data, incl. status, decided_at, decided_by */ } }
```
**Flash v43 — the decision is IDEMPOTENT (pre-existing defect, fixed).** The
update filter used to be `{user, entity, localId}` with **no status condition**,
so an already-decided settlement could be re-approved, flipped
`approved → rejected` or re-amounted at any time — by a stale panel tab, a
double-click or two owners at once — silently moving the derived wallet
(`balance = collected − Σ approved settlements`) with no record that it happened.
Only an **undecided** request may be decided now; a second decision returns
`409 code=SETTLEMENT_NOT_PENDING` (`"Settlement already approved"`) and **changes
nothing**. This matches the device twin (`SettlementRepository.decide`), which
re-reads the row and no-ops unless it is still pending.
*Backward-compatible:* a row whose `data.status` is absent/null (never written by
the app, but possible on a hand-crafted or legacy mirror row) still counts as
undecided and stays decidable — only an explicit `approved`/`rejected` is
refused, so no settlement that can be decided today loses that ability.

Errors: `400 code=BAD_STATUS` (status not `approved`/`rejected`),
`404 code=SETTLEMENT_NOT_FOUND` (no such settlement in the caller's mirror),
`409 code=SETTLEMENT_NOT_PENDING` (already decided — see above),
`403 code=FORBIDDEN` (caller is not an owner/admin).

#### GET `/api/account/wallet[?month=YYYY-MM]`  (auth)
The accountant **wallet**, computed SERVER-SIDE from the full mirror (authoritative
across all months by default, unaffected by the device's current-month receipt
scope; see the optional `month` scope below). For an
**accountant** it reports their own figures (receipts/settlements with
`data.accountant_id == localId`); for an **owner** the owner-collected figures
(`accountant_id` null). Flash v12 returns a **per-method** breakdown: for each
method `M ∈ {cash, card}` —
- `collected(M)` = Σ `data.paid_amount` over valid receipts
  (`entity:"receipts"`, `deleted:false`, `data.status=='valid'`) whose
  `(data.payment_method||'cash')==M`;
- `settled(M)` = Σ `data.amount` over approved settlements
  (`entity:"settlements"`, `deleted:false`, `data.status=='approved'`) whose
  `(data.method||'cash')==M`;
- `balance(M)` = `collected(M) − settled(M)`.

The top-level `{ collected, settled, balance }` mirror the **cash** wallet for
backward-compat with pre-v12 clients.
```jsonc
// 200 response
{
  "cash": { "collected": 5000, "settled": 3000, "balance": 2000 },
  "card": { "collected": 8000, "settled": 0,    "balance": 8000 },
  // back-compat: top-level == the cash wallet
  "collected": 5000, "settled": 3000, "balance": 2000
}
```

**Flash v42 — optional accounting-month scope.** Query param `month=YYYY-MM`
(validated against `/^\d{4}-\d{2}$/`) restricts **both** sides of **both**
wallets to that one accounting month, so an accountant's August money never
carries into September:
- `collected(M)` counts only receipts whose `data.month == month`;
- `settled(M)` counts only approved settlements whose **tariff month** matches —
  `data.month == month`, falling back to `data.requested_at` starting with the
  month for pre-v40 rows that carry no `data.month` (an `$or` nested under
  `$and`, so the base user/entity/status filter is never clobbered).

The param is **optional and additive**: when it is absent (or does not match
`YYYY-MM`) the endpoint computes the all-time figures and returns **exactly
today's response, byte-for-byte** — every not-yet-updated device keeps working
unchanged. With the param the response carries the same
`{ cash, card, collected, settled, balance }` shape, scoped to the month. The
device's local fallback (`SettlementRepository.walletForMonth`) buckets by the
same rule, so the online and offline figures agree.

**Flash v43 — approved corrections are included.** `collected(M)` additionally
folds in the append-only **`financial_adjustments`** ledger over the same scope
(the same accountant scoping as the receipts side, the same `deleted:false`
convention, and the same `(method||'cash')` bucketing). With `?month=` only that
month's adjustments count — they carry the tariff month directly, like receipts,
so no legacy fallback is needed; **without** it every adjustment counts, or the
lifetime figure would disagree with the app's `wallet()`. Contribution by
`kind`: `correction_increase` and `refund_return` add their **stored amount**
(the writer stamps the sign — a `refund_return` is stored negative, and carries
`accountant_id: null` because the OWNER returns the cash, so it never reduces an
accountant's wallet); `correction_decrease` contributes **exactly 0** — a
decrease must never reduce the wallet, it becomes a `refund_due` obligation on
the correction instead, discharged only by the separately-recorded physical
return. Any other/unknown `kind` is ignored rather than guessed at.
The **response shape is unchanged**, and an account with no adjustments returns
figures byte-identical to v42.

### Branches — `/api/account/branches`  (auth; role **owner only**)

Manage **branch sub-accounts** of the caller ("branch = owner-created
sub-account"). A BRANCH is itself a `User` with `role:"owner"` whose
`parentOwner` is the caller; it behaves owner-like for its **OWN** data mirror
(its effective owner is itself, so its `/api/sync` push/pull and
`/api/account/stats|data|recent` all resolve to its **own** mirror — fully
isolated from the parent's and from sibling branches). A branch **logs in through
the normal `/api/auth/login`** (its `phone` as `username`, its own password), and:
- has its own **plan mode** keyed off the boolean `independentPlan` flag (Flash
  v13 Phase D):
  - **Independent** (`independentPlan:true`, every branch created on/after Phase
    D): gated on **its OWN** subscription/features — a separate generator with its
    own plan and its own super-admin approval. Created `status:"none"` (+ optional
    chosen `planCode`) pending approval, so it is `subscriptionBlocked` like a new
    owner until the super-admin activates it via
    `PUT /api/admin/users/:branchId/plan`. Does **NOT** inherit the parent's plan.
  - **Legacy** (`independentPlan` falsy, branch docs predating Phase D):
    **INHERITS** the parent owner's subscription/features (its own subscription
    stays `none` and is never used — resolved via `parentOwner`, just like an
    accountant resolves via `owner`). Login / `me` report the **parent's**
    `subscription` (incl. `features`). Unchanged from before.
- is **cascade-blocked** by the parent (ALWAYS, both modes): a blocked/missing parent top-level owner
  → `403 code=BLOCKED` on the branch's login and on any authed request
  (`requireAuth`), mirroring the accountant rule;
- is a real owner of its own mirror, so its login **does** bind a device /
  enforce `maxDevices` (unlike accountants, which are device-exempt);
- **cannot create sub-branches** — a branch caller (its own `parentOwner` set)
  hitting `POST /api/account/branches` → `403 code=SUB_BRANCH_FORBIDDEN`.

A non-owner caller (accountant, admin) hitting any of these → `403 code=FORBIDDEN`.

The Branch object returned here (compact, no secrets):
```jsonc
{ "id": "mongoid", "generatorName": "...", "name": "...", "phone": "...",
  "username": "...", "parentOwnerId": "owner-mongoid",
  "independentPlan": true,                 // Flash v13 Phase D: own plan vs. legacy inherit
  "subscription": { "planCode": "monthly", "status": "none",
                    "startedAt": null, "expiresAt": null },
  "blocked": false, "createdAt": "ISO" }
```

#### POST `/api/account/branches`  (owner only)
Creates a branch owned by the caller. `username` = `phone.toLowerCase()` and must
be unique; `phone` must be unique (same checks as register). The branch is created
**independent** (`independentPlan:true`) with its own pending subscription
(`status:"none"`, `planCode` = the optional `planCode` body field or `null`).
```jsonc
// request — planCode is OPTIONAL (a known, existing plan code; omitted/null = no plan chosen yet)
{ "generatorName": "North Gen", "phone": "07710000000", "password": "secret",
  "planCode": "monthly" }
// 201 response
{ "branch": { /* Branch */ } }
```
Errors: `400 code=VALIDATION` (missing generatorName/phone or password < 4
chars), `404 code=PLAN_NOT_FOUND` (a non-empty `planCode` that is not a known
plan), `409 code=PHONE_TAKEN` (phone/username already in use),
`403 code=SUB_BRANCH_FORBIDDEN` (caller is itself a branch),
`403 code=FORBIDDEN` (caller is not an owner). The super-admin later activates the
branch's own plan via `PUT /api/admin/users/:branchId/plan` (the branch is a
`User`, so the existing endpoint works unchanged).

#### GET `/api/account/branches`  (owner only)
```jsonc
{ "branches": [ { /* Branch */ } ] }   // the caller's branches only (newest first)
```

#### GET `/api/account/branches/:branchId/stats[?month=YYYY-MM]`  (owner only)
The parent panel views ONE of its branches' dashboards, scoped to that branch
user's **own** mirror. Same `counts` + `dashboard` shape as
`GET /api/account/stats` (the dashboard covers the whole branch account — no
inner accountant/branch filter). Ownership-checked: the `:branchId` User must
have `parentOwner === caller`.
Errors: `404 code=BRANCH_NOT_FOUND` (not the caller's branch),
`403 code=FORBIDDEN` (caller is not an owner).

#### GET `/api/account/branches/:branchId/data?entity=&...`  (owner only)
The parent panel reads ONE of its branches' synced mirror — same query params +
response shape as `GET /api/account/data`, scoped to that branch user's **own**
mirror. Ownership-checked like the stats endpoint.
Errors: `400` missing `entity`, `404 code=BRANCH_NOT_FOUND`, `403 code=FORBIDDEN`.

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
- `DELETE /api/admin/users/:id/data/:entity/:localId` tombstone one mirrored record
  (v23: sets `deleted:true` + a fresh `data.updated_at` rather than hard-deleting,
  so a pulling device removes its local row and a stale local edit loses under
  last-edit-wins). **v43 refusals:**
  `409 code=RECEIPT_MONTH_LOCKED` / `409 code=SETTLEMENT_MONTH_LOCKED` when the
  row's accounting month is closed by a `pending|approved` settlement, and
  `409 code=ADJUSTMENT_IMMUTABLE` / `409 code=CORRECTION_IMMUTABLE` for the
  append-only correction ledger, which may **never** be deleted through this
  route (a tombstone here propagates to every device and silently moves the
  accountant's wallet). Every other entity, and every open month, deletes
  exactly as before.
- `GET    /api/admin/password-resets`                 list owner password-reset requests (search + paginate, see below)
- `POST   /api/admin/password-resets/:id/approve`     approve — **this is what changes the password**
- `POST   /api/admin/password-resets/:id/reject`      reject — body `{ "note": "..." }`; changes nothing
- `GET    /api/admin/corrections`                     list correction requests from the mirrors (search + paginate, see below)
- `POST   /api/admin/corrections/:id/approve`         approve — **this is what appends the money adjustment**
- `POST   /api/admin/corrections/:id/reject`          reject — body `{ "note": "..." }`; moves no money
- `POST   /api/admin/corrections/:id/refund-paid`     record the physical cash return that closes a decrease
- `GET    /api/admin/plans`                          list all plans
- `PUT    /api/admin/plans`                          upsert a plan (body = Plan)
- `DELETE /api/admin/plans/:code`                    delete a plan
- `GET    /api/admin/banners`                         list all landing banners (see below)
- `POST   /api/admin/banners`                         create a banner (multipart: `image` file + `ratio` + `enabled` + `order`)
- `PUT    /api/admin/banners/:id`                     edit `ratio`/`enabled`/`order` (+ optional new `image` file)
- `DELETE /api/admin/banners/:id`                     delete a banner (+ its image file)
- `GET    /api/admin/landing-video`                   current promo-video setting
- `PUT    /api/admin/landing-video`                   body `{ "url": "...", "enabled": true|false }` (empty `url` disables)
- `GET    /api/admin/events`                         Server-Sent Events stream (admin via `?token=`, see below)

### Landing banners & promo video  (admin)

Drive the public landing page (`/admin/landing.html`). **Banner images** are
uploaded as `multipart/form-data` (field name `image`, images only, ≤10 MB),
stored on disk under `UPLOADS_DIR` (default `backend/uploads/`), and served
publicly at `/uploads/<file>`. `imageUrl` is that public path.

```jsonc
// Banner (admin shape)
{ "id":"mongoid", "imagePath":"banner-….jpg", "imageUrl":"/uploads/banner-….jpg",
  "ratio":"1:1|2:1|3:1", "enabled":true, "order":0, "createdAt":"ISO" }

// GET  /api/admin/banners            -> { "banners": [ Banner, … ] }   // sorted by order, then createdAt
// POST /api/admin/banners            (multipart) -> 201 { "banner": Banner }    // 400 NO_FILE / NOT_AN_IMAGE
// PUT  /api/admin/banners/:id        (multipart, all fields optional) -> 200 { "banner": Banner }  // 404 BANNER_NOT_FOUND
// DELETE /api/admin/banners/:id      -> 200 { "ok": true }             // 404 BANNER_NOT_FOUND

// GET  /api/admin/landing-video      -> { "video": { "url":"", "enabled":false } }
// PUT  /api/admin/landing-video      body { "url":"https://youtu.be/…", "enabled":true }
//                                    -> { "video": { "url":"…", "enabled":true } }   // empty url => enabled forced false
```

The admin SPA (`backend/public/admin/index.html`) is a hash-routed single-file
app driving exactly these endpoints with a Bearer JWT.

### GET `/api/admin/users/:id/data`  (admin) — synced-data mirror, read-only

Lists the business rows an owner pushed for one entity. The mirror is **push-only**
(device → server via `/api/sync`); admins can search/paginate and **delete**, but
never create or edit.

Query params:
- `entity` (required): one of `subscribers · boards · circuits · receipts · expenses · monthly_prices · refunds`
  — plus, from Flash v43, `corrections · financial_adjustments` (no per-field
  search fields, so `q` falls back to matching `localId`).
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

### Password-reset requests — `/api/admin/password-resets`  (admin) — new in Flash v42

The super-admin side of `POST /api/auth/forgot-password`. An owner phones the
super admin and reads back the 6-digit `code`; the admin finds the request here,
verifies the caller against the account's `name` / `generatorName` / `phone`, and
approves or rejects it. **No password ever changes without an approval here.**

#### GET `/api/admin/password-resets`  (admin)
Query params (all optional): `q` — case-insensitive substring over the account's
`name`, `generatorName`, `username`, `phone` and the request `code`; `status` —
one of `pending · approved · rejected · expired`; `page` (1-based, default `1`);
`limit` (default `25`, clamped to `1..200`). Filtering is applied **before**
pagination; requests come back newest first (`createdAt` desc).
```jsonc
// 200 response
{
  "items": [
    {
      "id": "mongoid",
      "userId": "mongoid",            // the account the request targets
      "name": "Owner Name",
      "generatorName": "Moldati",     // null when the account has none
      "username": "owner1",
      "phone": "0770...",             // the registered phone the requester had to match
      "code": "482913",               // 6-digit reference, read back to verify the caller
      "status": "pending",            // 'pending' | 'approved' | 'rejected' | 'expired'
      "note": null,                   // the reject reason, when rejected
      "createdAt": "ISO",
      "expiresAt": "ISO",             // createdAt + 24h
      "decidedAt": null               // ISO once approved/rejected
    }
  ],
  "total": 7,   // matching requests after `q`/`status`, before the page slice
  "page": 1,
  "limit": 25
}
```
The bcrypt hash of the requested password is stored on the request but is
**never** returned by this (or any) endpoint.

#### POST `/api/admin/password-resets/:id/approve`  (admin)
**The approval is the moment the password changes.** It writes the request's
stored bcrypt hash onto the target `User.passwordHash` (stored as-is — it is
already a hash, so it is never re-hashed), bumps that user's `tokenVersion` so
**every JWT minted before the approval dies** (`401 code=TOKEN_STALE` on every
authed route — the owner and all their devices must sign in again with the new
password), stamps `decidedAt` / `decidedBy` and moves the request to `approved`.
```jsonc
// 200 response
{ "ok": true, "request": { /* the updated request, status:"approved" */ } }
```
Errors:
- `404 code=RESET_NOT_FOUND` — no such request id.
- `409 code=RESET_NOT_PENDING` — already decided, or superseded by a newer
  request. **Approving twice is a no-op error, never a double-apply.**
- `409 code=RESET_EXPIRED` — past the 24 h `expiresAt`. The request is persisted
  as `expired` at that moment and can **never** be approved; the owner must file
  a fresh one.
- `409 code=RESET_INVALID` — the request carries no stored hash (defensive: an
  owner's `passwordHash` is never blanked).
- `404 code=USER_NOT_FOUND` — the target account no longer exists.

#### POST `/api/admin/password-resets/:id/reject`  (admin)
```jsonc
// request
{ "note": "could not verify the caller" }   // optional
// 200 response
{ "ok": true, "request": { /* status:"rejected", note, decidedAt */ } }
```
**A rejection changes nothing on the account** — the current password stands,
`tokenVersion` is untouched and every live session keeps working. Errors:
`404 code=RESET_NOT_FOUND` and `409 code=RESET_NOT_PENDING` (only a `pending`
request can be rejected).

### Corrections — `/api/admin/corrections`  (admin) — new in Flash v43

The super-admin side of the **correction after invoicing** flow. An accountant
blocked from editing an invoiced/settled month files a `corrections` row on the
device; it reaches the mirror through `/api/sync/push` like any other business
row (see **Synced entities `corrections` + `financial_adjustments`** for the row
shape and the money rule). These four endpoints are where it is decided.

Two rules the endpoints are built around:
- **Nothing existing is ever edited.** A decision never touches the original
  receipt, settlement, subscriber or tariff row — it appends one immutable
  `financial_adjustments` row and moves the correction's `status` on. No receipt
  number is consumed and no printed document changes.
- **Approval and the physical cash return are two separate operations**, each
  separately recorded. Approving a decrease never asserts that money moved.

`:id` is the **mirror record's Mongo `_id`** — globally unique across owners,
which is why these routes are not nested under `/users/:id`. The device's own
UUID comes back as `localId` and cross-references
`GET /api/admin/users/:id/data?entity=corrections`.

A decision **bumps `data.updated_at`** on the correction, so **last-EDIT-wins**
carries it over the device's older pending row on that device's next pull (the
admin decides in the mirror; there is no separate push). The same three
transitions exist on the device (`CorrectionController.approve` / `reject` /
`recordRefundPaid`) with identical guards, and both sides write into the same
mirror, so a decision made in either place converges.

#### GET `/api/admin/corrections`  (admin)
Query params (all optional): `userId` — scope to one owner's mirror; `status` —
one of `pending · approved · rejected · refund_due · completed` (`refund_due` is
the panel's *Refund Due* filter); `month` — `YYYY-MM`; `q` — case-insensitive
substring over the row's `subscriber_id`, `month`, `reason` and `localId`;
`page` (1-based, default `1`); `limit` (default `25`, clamped to `1..200`).
Filtering is applied **before** pagination; rows come back newest first.
```jsonc
// 200 response
{
  "items": [
    {
      "id": "mongoid",           // the mirror record id — what `:id` below takes
      "localId": "uuid",         // corrections.id on the device
      "userId": "mongoid",       // the owner whose mirror holds it
      "ownerName": "Owner Name",
      "ownerUsername": "owner1",
      "data": { /* the corrections row — see the Sync section */ },
      "updatedAt": "ISO"
    }
  ],
  "total": 7,   // matching rows after the filters, before the page slice
  "page": 1,
  "limit": 25
}
```

#### POST `/api/admin/corrections/:id/approve`  (admin)
**The approval is the moment the money is booked.** It stamps `data.status`,
`data.decided_at` (now, ISO), `data.decided_by` (`req.user._id`), the optional
`data.decision_note`, bumps `data.updated_at`, and appends **one**
`financial_adjustments` row to the same owner's mirror:

| `difference` | new `status` | adjustment appended |
| --- | --- | --- |
| `> 0` (increase) | `approved` | `correction_increase` for `+abs(difference)` → that month's wallet rises → an additional settlement for the month becomes possible |
| `< 0` (decrease) | `refund_due` | `correction_decrease` for `+abs(difference)` — **audit only, wallet effect 0**. The wallet is never reduced; the money becomes an obligation until the cash is physically returned |
| `== 0` | `approved` | **none** — there is nothing to book |

The adjustment's `localId` is the deterministic **UUIDv5 of
`(correction_id, kind)`** and it is written only if absent, so a retried
approval, a re-delivered request or the same decision arriving from a second
device can never double-credit the wallet.
```jsonc
// request
{ "note": "verified against the meter log" }   // optional
// 200 response
{
  "ok": true,
  "correction": { /* the updated row: status, decided_at, decided_by, decision_note */ },
  "adjustment": { /* the appended financial_adjustments row, or null when difference == 0 */ }
}
```
Errors:
- `404 code=CORRECTION_NOT_FOUND` — no such correction in any mirror.
- `409 code=CORRECTION_NOT_PENDING` (`"Correction already approved"`) — already
  decided. **Approving twice is a no-op error, never a double credit.**

#### POST `/api/admin/corrections/:id/reject`  (admin)
```jsonc
// request
{ "note": "the meter reading was right" }   // optional
// 200 response
{ "ok": true, "correction": { /* status:"rejected", decision_note, decided_at */ } }
```
**A rejection moves no money at all** — no adjustment is written, no wallet,
revenue or settlement figure changes, and the original receipt, subscriber and
tariff rows are untouched. Only a `pending` correction can be rejected. Errors:
`404 code=CORRECTION_NOT_FOUND`, `409 code=CORRECTION_NOT_PENDING`.

#### POST `/api/admin/corrections/:id/refund-paid`  (admin)
Records the **physical cash return** that closes a decrease: `refund_due →
completed`, stamping `data.refund_paid_at` (now, ISO), `data.refund_paid_by`
(`req.user._id`) and bumping `data.updated_at`. It appends one `refund_return`
adjustment for **`−abs(difference)`** with `accountant_id: null` — the owner
returns the cash, not the accountant, so no accountant's derived wallet may be
reduced by it (every accountant-wallet query filters on `accountant_id`, which
is what keeps a wallet from ever going negative); the audit link survives via
`correction_id` / `subscriber_id` / `month` / `branch_id`.
```jsonc
// request  — no body (the correction already carries the amount and the note)
{}
// 200 response
{ "ok": true,
  "correction": { /* status:"completed", refund_paid_at, refund_paid_by */ },
  "adjustment": { /* the appended refund_return row */ } }
```
Allowed **only** from `refund_due` — a correction that was never approved as a
decrease, or one already `completed`, is refused, so a double-tap can never
append a second return for the same obligation. Errors:
`404 code=CORRECTION_NOT_FOUND`,
`409 code=CORRECTION_NOT_REFUND_DUE` (`"Correction is completed"`).

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
- `password_reset_requested` (Flash v42) — fired right after
  `POST /api/auth/forgot-password` stores a pending request, so an open panel
  sees it live exactly like `user_registered`. Payload: the same request shape a
  `GET /api/admin/password-resets` item carries.

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
`category_snapshot`, `discount_type`, `discount_value`, `discount_amps`,
`payment_method` (Flash v11: `'cash'`/`'card'`), `paid_amount`,
`remaining_after`, `issued_at`, `status`).

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

### GET `/api/public/landing`  (public)

Landing-page content for `/admin/landing.html`: the **enabled** advertisement
banners (sorted by `order`, then `createdAt`) and the **enabled** promo video.
Always `200`.

```jsonc
{
  "banners": [
    { "id":"mongoid", "imageUrl":"/uploads/banner-….jpg", "ratio":"2:1", "order":0 }
  ],
  "video": { "url":"https://youtu.be/abc", "provider":"youtube" }  // null when disabled/empty
}
```
`provider` is auto-detected from the video URL: `youtube`
(`youtube.com`/`youtu.be`), `vimeo` (`vimeo.com`), else `direct`.

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
  "parentOwnerId": null,    // BRANCH only: the parent top-level owner id (string); null for a top-level owner/admin/accountant
  "independentPlan": false, // BRANCH only: true => gated on its OWN plan (Flash v13 Phase D); false => top-level owner OR legacy inheriting branch
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
`parentOwnerId` is set only for a **branch** sub-account (a `role:"owner"` User
that is a child of the creating owner — see **Account → Branches**); it is `null`
for top-level owners, admins, and accountants.
### Subscription
```jsonc
{
  "planCode": "monthly|null",
  "status": "none|pending|active|rejected|expired",
  "startedAt": "ISO|null",
  "expiresAt": "ISO|null",
  "remainingDays": 12,         // server-computed days left until expiry (clamped >=0); null when no expiresAt
  "features": {                // resolved LIVE from the active plan's flags
    "sync": true,              // online data sync (push/pull)
    "backup": true,            // cloud backup
    "ownerPanel": true         // owner self-service panel (#/my*, /api/account/*)
  }
}
```
`remainingDays` is computed by `serializeSubscription` from the **server clock**
and `expiresAt` (`Math.ceil((expiresAt - now)/86400000)`, floored at 0). It is
`null` when no `expiresAt` is set, and `0` once expired (matching the downgraded
`"expired"` status). It flows through every subscription-bearing response
(`/auth/login`, `/auth/me`, `register`, `/api/subscription`, and accountant /
branch inheritance).

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
