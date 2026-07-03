# Backend Scale — SaaS scalability / DB / traffic / caching (SPEC)

> Result of a review-only audit (5 finder angles × adversarial verification) of `backend/`
> at commit `25d5dcf`+v24. **18 distinct verified findings** (1 critical, 8 high, 5 medium,
> 4 low). This spec prescribes the fixes; NO code was changed by the review.
>
> Execution rules: the sync engine's push/pull SEMANTICS (last-edit-wins, tombstones,
> outbox drain contract) are UNTOUCHABLE — everything here is indexes, query shape,
> pagination, middleware, and ops guards around those semantics. Backend tests
> (`cd backend && npm test`) must stay green; every fix that changes an endpoint's
> contract updates `backend/API_CONTRACT.md` and stays backward-compatible with the
> currently-shipped Flutter clients (v22/v23/v24 are in the field).

## P0 — CRITICAL (do first, ~1 hour)

### 0.1 `USE_MEMORY_DB` defaults to TRUE → silent total data loss in prod
`backend/src/config/env.js:33` — `bool(process.env.USE_MEMORY_DB, true)`; `.env.example`
ships `true`; `validateSecrets()` never checks it; `/api/health` doesn't expose the mode.
A prod deploy with a missing/uncopied `.env` boots green on in-memory Mongo and **loses
every account on restart**.
- Flip the default: `bool(process.env.USE_MEMORY_DB, (process.env.NODE_ENV || 'development') !== 'production')`
  — and set `USE_MEMORY_DB=true` explicitly in the `dev` script + tests (tests already do).
- Fail-fast in production: extend `validateSecrets()` (env.js:73-110): when
  `NODE_ENV==='production'`, THROW if `USE_MEMORY_DB` is true or `MONGO_URI` is unset.
- Observability: `/api/health` (server.js:38) gains `db: 'memory'|'mongo'` so monitoring
  can alert. Update `.env.example` comment + CLAUDE.md backend note.
- Test: NODE_ENV=production + no MONGO_URI ⇒ process refuses to start.

## P1 — HIGH: SyncRecord indexes (unlocks everything else, ~1 hour)

### 1.1 Missing indexes (`backend/src/models/SyncRecord.js:17,31` — only `{user}` + unique `{user,entity,localId}` exist)
Add:
- `{ user: 1, updatedAt: 1 }` — serves pull's `{user, updatedAt:{$gt:since}}` filter AND
  its `sort({updatedAt:1})` (today: full per-account collection scan + in-memory sort,
  aborts at Mongo's 100MB sort limit on big mirrors). Drop the now-redundant lone
  `index: true` on `user`.
- `{ user: 1, entity: 1, 'data.month': 1 }` — receipts/monthly_prices month filters
  (buildDashboard, receiptsMonth pull scope).
- `{ user: 1, entity: 1, 'data.date': 1 }` — expenses `^YYYY-MM` anchored regex
  (index-range capable) used by buildDashboard + the v23 owner-panel month filter.
- `{ user: 1, entity: 1, updatedAt: -1 }` — listUserData/getMyRecent/recent-data sorted
  pages.
- Optional: `{ user: 1, entity: 1, 'data.branch_id': 1 }` for branch-scoped panel views.
Mongoose builds these in background on boot; verify with `explain()` on a seeded account
that pull + stats use IXSCAN (add a test asserting `executionStats.totalDocsExamined`
is bounded).

## P2 — HIGH: the sync hot paths (~1 day)

### 2.1 `GET /api/sync/pull` unbounded full-mirror dump (`syncController.js:254-263`)
No `.lean()`, no limit, one giant JSON buffer; the Flutter client never sends `since`;
runs on every login auto-pull / new-device restore / branch switch.
- `.lean()` the query (plain objects; the map at :255-261 keeps working).
- Keyset pagination: accept `?limit=` (default+cap 1000) + cursor (`updatedAt`,`_id`
  tiebreak, sort `{updatedAt:1,_id:1}`); respond `{ records, nextCursor, hasMore }`.
  Old clients that ignore the new fields still work: an un-cursored request returns the
  FIRST page — **breaking for old full-pull clients**, so gate it: only paginate when the
  client sends `?limit=` (new clients opt in); without `limit` keep today's full dump
  (bounded by compression, 2.4) until the fleet updates.
- Flutter client (`lib/core/sync_service.dart pull()` — WRAPPER level, drain logic
  untouched): send `limit=1000` and loop pages until `hasMore=false`, applying each page
  inside its existing transaction flow.
- Tests: paged pull returns all rows exactly once across pages; legacy no-limit call
  unchanged.

### 2.2 `POST /api/sync/push` 2N sequential round-trips (`syncController.js:135-197`)
Per record: awaited `findOne` (:154) + awaited `findOneAndUpdate` (:192).
- Batch: ONE `find({user, entity:{$in}, localId:{$in}})` (or per-entity grouped `$or`)
  to load all existing docs into a Map, run the EXISTING conflict rules (last-edit-wins +
  sticky tombstones — logic copied verbatim, do not alter semantics), then ONE
  `bulkWrite` of upserts. Response counts identical.
- Cap `records[]` length (e.g. 500) server-side → 413 with a clear code so a
  misbehaving client can't post unbounded batches (client sends 200/batch today).
- Tests: existing push/conflict tests must pass unchanged; add one asserting equal
  behavior for a 200-record mixed insert/update/tombstone batch.

### 2.3 Tombstone retention (`SyncRecord.js:21` + `syncController.js:236`)
Tombstones live forever and the receiptsMonth pull scope re-includes ALL deleted
receipts of every month.
- Add a retention sweep: on push completion (cheap, per-account), or a daily interval in
  server.js, `deleteMany({ user, deleted: true, updatedAt: { $lt: now − RETENTION } })`
  with `TOMBSTONE_RETENTION_DAYS` env (default 90). 90 days ≫ any device's realistic
  offline window, so the sticky-tombstone conflict guarantee is preserved in practice;
  document the tradeoff in API_CONTRACT.md.
- Scope the deleted-receipts clause in the month-scoped pull (:236) to
  `updatedAt > since` when `since` is present (it already ships every tombstone on every
  month-change pull today).

### 2.4 No response compression (`server.js:31-35`)
Add `compression()` (npm `compression`) right after helmet — JSON mirrors compress
5-10×; the multi-MB pull and panel pages shrink accordingly. Skip for SSE
(`/api/admin/events` sets its own headers; compression module respects `no-transform`
— verify SSE still streams, or exclude the route with a filter).

## P3 — HIGH/MEDIUM: per-request costs (~half day)

### 3.1 Rate limiter is per-process + login-only (`middleware/rateLimit.js:13`)
- Document the single-instance assumption (it is real today) OR add a Mongo-backed store
  (`rate-limit-mongo`) so counters survive restarts/scale-out.
- Extend coverage: a lenient global limiter (e.g. 300 req/min/IP) on `/api/`, and a
  moderate one on `/api/sync/push` + `/api/backup` (they do real work per call).

### 3.2 requireAuth: up to 3 unprojected `User.findById` per request (`middleware/auth.js:27,47,59`)
- Add projections (exclude `passwordHash`; keep what serializers need) and `.lean()`
  where the handlers don't `save()` the user (audit call sites first — some do mutate).
- Add a tiny in-process TTL cache (Map, 15-30s, keyed by user id, invalidated on
  tokenVersion bump paths) for the OWNER cascade lookups only (accountant→owner,
  branch→parent) — the hot multiplier — while the primary user stays fresh for
  blocked/tokenVersion checks. (Single-instance today, so in-process is correct; note
  the multi-instance caveat next to the SSE one.)

### 3.3 bcryptjs (pure JS) on the request path (`authController.js:74` + v23 verifies)
Swap `bcryptjs` → native `bcrypt` (same API, ~20-30× faster, off the event loop's main
thread via its own thread pool). Keep hash compatibility (same `$2a/$2b` format).
If native build is a deploy problem, at least drop cost to 10 (already) and note it.

### 3.4 No graceful shutdown / server timeouts (`server.js:99`)
Keep the `app.listen` handle; on SIGTERM/SIGINT: `server.close()` → `mongoose.disconnect()`
→ exit. Set `server.requestTimeout` (e.g. 120s) and `headersTimeout`/`keepAliveTimeout`
sanely so slow-loris and hung uploads can't pin sockets.

## P4 — MEDIUM/LOW: panel + caching polish (~half day)

### 4.1 buildDashboard → Mongo aggregation (`accountController.js:79-217`)
Replace the five full-doc loads + JS loops with pipelines (after P1 indexes):
receipts `$match {user,entity:'receipts',deleted:false,'data.month':m,...}` +
`$group` per subscriber (coverage) and totals; expenses `$match`+`$group` sum;
subscribers stay a projected `.lean()` find (needed per-category amps — or a `$group`
by category/branch). Preserve EXACT figures (the v23 unpriced-month=UNPAID rule and
category-aware expected) — assert with the existing stats tests + a new mixed-tariff
fixture comparison.

### 4.2 listUserData triple pass + regex search (`adminController.js:217-298`)
- Reuse P1 indexes; add `.lean()` + projection.
- Merge count+page (+expenses totalAmount) into ONE `$facet` aggregation.
- Keep `/i` contains-search but document it as bounded by the `{user,entity}` prefix
  (per-account scan, acceptable at current scale); anchor searches where the SPA can
  (localId exact already exists).
- Clamp `limit` (≤100) and `page` server-side.

### 4.3 HTTP caching
- `/api/sync/pull`: when the (already computed) result is empty and `since` was sent,
  respond `304`-style cheaply — simplest correct: keep 200 but the payload is tiny once
  2.3 trims tombstones; optional `ETag` on the stats endpoint instead.
- `/api/account/stats`: `Cache-Control: private, max-age=15` — the SPA polls it;
  15s staleness is invisible to the owner and collapses refresh storms.
- Static SPA: `express.static(adminDir, { maxAge: '1h', setHeaders: index.html → no-cache })`
  (hashed assets don't exist — the single index.html must stay revalidated, so:
  `maxAge 0` for index.html, `1h` for everything else in the dir).
- Plan lookups (`utils/planFeatures.js:15`): in-process TTL cache (60s) — plans change
  rarely and only via the admin panel.

### 4.4 SSE bus is in-process (`utils/events.js:14`)
Document as a single-instance feature (admin-panel nicety). If multi-instance ever
happens: replace with Mongo change streams or drop SSE for polling. No work now.

## Reviewed and OK (no action)
- Cloud backups: multer **diskStorage** (not RAM), 200MB cap, `MAX_BACKUPS` retention
  pruning per user (`backupController.js:28-30`, `routes/backup.js:22-35`).
- JWT auth is stateless (scale-ready); Mongo pool default (100) is fine at this size.
- `express.json` 2MB cap vs client 200-record batches: works today because rows are
  small; P2.2's server-side record cap + (optional) client size-aware batching removes
  the theoretical poison-batch stall (a batch >2MB would 413 forever and block the
  outbox — note added to sync_service wrapper docs).

## Acceptance
1. `cd backend && npm test` green, including the new tests named above.
2. `explain()` checks: pull + stats + listUserData use IXSCAN on a 10k-row seeded mirror.
3. Manual: seeded 1000-sub account — `/api/account/stats` < 100ms warm; full pull
   compressed; paged pull loop restores a device correctly.
4. `API_CONTRACT.md` updated (pull pagination params, push record cap, health `db` field).
5. No Flutter behavior change required except the OPT-IN paged pull in
   `sync_service.dart pull()` (wrapper level; drain/outbox logic untouched).
