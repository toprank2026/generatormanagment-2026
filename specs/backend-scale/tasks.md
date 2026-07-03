# Backend Scale — TASKS (granular checklist)

> Execute in `plan.md` phase order (A→H). Tags: `[BE]` backend code, `[APP]` Flutter,
> `[OPS]` deploy/env, `[T]` test. Anchors verified at the review commit.
> **Live-users rule: finish a phase, verify, deploy, observe — then start the next.**

## Phase A — Config guards (spec §0.1) — zero user impact
- [ ] [BE] `config/env.js:33`: `USE_MEMORY_DB: bool(process.env.USE_MEMORY_DB, (process.env.NODE_ENV || 'development') !== 'production')`.
- [ ] [BE] `package.json` dev script + any test helpers: set `USE_MEMORY_DB=true` explicitly
      (tests already do — verify with grep, fix stragglers).
- [ ] [BE] `validateSecrets()` (env.js:73-110): in production, push fail-fast problems when
      `USE_MEMORY_DB` is true or `MONGO_URI` is unset/blank.
- [ ] [BE] `config/db.js` connectDb(): defense-in-depth throw for memory-mode + production.
- [ ] [BE] `/api/health` (server.js:38): add `db: 'memory' | 'mongo'`.
- [ ] [BE] `.env.example`: `USE_MEMORY_DB=false` with a comment; CLAUDE.md backend note updated.
- [ ] [T] Test: prod env without MONGO_URI refuses to start; health reports db mode.
- [ ] [OPS] Deploy; `curl /api/health` → `db: "mongo"`.

## Phase B — SyncRecord indexes (spec §1.1) — zero user impact
- [ ] [BE] `models/SyncRecord.js`: add
      `{user:1, updatedAt:1}`, `{user:1, entity:1, 'data.month':1}`,
      `{user:1, entity:1, 'data.date':1}`, `{user:1, entity:1, updatedAt:-1}`,
      optional `{user:1, entity:1, 'data.branch_id':1}`; drop the lone `index: true`
      on `user` (line 17) — covered by the new compounds.
- [ ] [T] Explain-plan test on a seeded 10k-row mirror: pull filter+sort and the stats
      month filters use IXSCAN with bounded `totalDocsExamined`.
- [ ] [OPS] Deploy; first boot builds indexes in background — watch Mongo CPU briefly.

## Phase C — Push bulkWrite + record cap + compression (spec §2.2, §2.4)
- [ ] [BE] `syncController.js` push: ONE grouped `find({user, ...})` → Map, then apply the
      EXISTING conflict rules **copied verbatim** (:154-191 logic), then ONE `bulkWrite`
      of upserts. Response `{count, ...}` byte-identical.
- [ ] [BE] Cap `records[]` at 500 → `413 {code:'BATCH_TOO_LARGE'}` (clients send 200 —
      no deployed client can hit it).
- [ ] [BE] `server.js`: add `compression()` after helmet; exclude `/api/admin/events`
      (SSE) via filter; add `compression` to package.json.
- [ ] [T] Existing push/conflict tests pass UNCHANGED; new test: 200-record mixed
      insert/update/tombstone batch produces identical mirror state vs the old code path
      (fixture comparison); 501-record batch → 413; SSE still streams.
- [ ] [BE] `API_CONTRACT.md`: record cap documented.
- [ ] [OPS] Deploy; observe sync latencies + any 413s (expect none).

## Phase D — Pull: lean + OPT-IN pagination (spec §2.1)
- [ ] [BE] `syncController.js:254`: add `.lean()`; sort `{updatedAt:1, _id:1}`.
- [ ] [BE] When `?limit=` present (clamped ≤1000): keyset pagination via
      `?after=<updatedAt>|<id>` cursor; respond `{records, nextCursor, hasMore}`.
      **Without `limit`: EXACT current behavior (full dump)** — deployed clients
      unaffected.
- [ ] [T] Paged loop returns every row exactly once (incl. equal-updatedAt ties);
      legacy no-limit call byte-equivalent to before; month-scoped receipts filter
      still applies within pages.
- [ ] [BE] `API_CONTRACT.md`: pagination params.
- [ ] [OPS] Deploy; deployed apps keep full-dump behavior (now compressed via Phase C).

## Phase E — Per-request costs (spec §3.1–3.4)
- [ ] [BE] `middleware/auth.js`: projections excluding `passwordHash` where handlers
      don't `save()` (AUDIT call sites first — some mutate user); 15-30s in-process TTL
      cache for the OWNER/parent cascade lookups ONLY (primary user always fresh);
      invalidate on the accountant-update/blocked admin paths.
- [ ] [BE] Swap `bcryptjs` → native `bcrypt` (same hash format); if the server can't
      build native modules, keep bcryptjs and note it in the change table.
- [ ] [BE] `server.js`: keep the listen handle; SIGTERM/SIGINT → `server.close()` →
      `mongoose.disconnect()`; set `requestTimeout`/`headersTimeout`/`keepAliveTimeout`.
- [ ] [BE] `middleware/rateLimit.js`: generous global limiter on `/api/` (e.g.
      300/min/IP) + moderate on `/api/sync/push` and `/api/backup` (e.g. 60/min) —
      ceilings sized so the 1000-sub import (~6 batches) and panel polling never trip;
      document the single-instance MemoryStore assumption (or add rate-limit-mongo).
- [ ] [T] Login still works (hash compat); accountant request does ≤1 owner lookup per
      TTL window; graceful shutdown test (SIGTERM completes in-flight request).
- [ ] [OPS] Deploy; watch for 429s from REAL clients for 24h (expect zero).

## Phase F — Flutter opt-in paged pull (NEXT app release, after D is live)
- [ ] [APP] `lib/core/sync_service.dart pull()` WRAPPER: send `limit=1000` and loop
      `nextCursor` pages until `hasMore=false`, applying each page through the existing
      per-record apply path (drain/outbox logic untouched — R-ENGINE).
- [ ] [APP] Note in code: batches >2MB would 413 forever (poison batch) — keep client
      batchSize 200 and add a size guard comment only (no behavior change).
- [ ] [T] `flutter analyze` 0/0, `flutter test` green; new-device restore against a
      seeded big mirror pulls all pages correctly.

## Phase G — Panel + caching polish (spec §4.1–4.3)
- [ ] [BE] `accountController.js` buildDashboard: aggregation pipelines behind
      `STATS_AGGREGATION` env flag (default false initially); golden-fixture parity test
      (mixed tariffs + unpriced month + discounts + branch/accountant filters) asserting
      numeric equality old-vs-new, THEN flip default true.
- [ ] [BE] `adminController.js` listUserData: `.lean()` + projection; merge
      count+page+totalAmount into one `$facet`; clamp `limit ≤100`, `page ≥1`.
- [ ] [BE] Cache headers: `/api/account/stats` → `Cache-Control: private, max-age=15`;
      `express.static(adminDir, {maxAge:'1h'})` with index.html forced no-cache;
      Plan lookup TTL cache 60s in `utils/planFeatures.js`.
- [ ] [T] Stats parity fixtures; panel lists identical rows/totals; index.html always
      revalidated.
- [ ] [OPS] Deploy with flag off → verify → flip flag → verify parity in prod numbers.

## Phase H — Tombstone retention (spec §2.3) — LAST, observed
- [ ] [BE] Daily sweep in server.js: `deleteMany({deleted:true, updatedAt:{$lt: now − TOMBSTONE_RETENTION_DAYS}})`
      gated by env, **default 0 = disabled**; scope month-pull deleted-receipts clause
      (:236) to `updatedAt > since` when since present.
- [ ] [T] Sweep deletes only expired tombstones; a device pulling after the sweep still
      converges (fresh full pull path).
- [ ] [BE] `API_CONTRACT.md`: retention semantics + the >retention-offline caveat.
- [ ] [OPS] Deploy disabled → after 1-2 weeks of stable pull sizes, set
      `TOMBSTONE_RETENTION_DAYS=90` → monitor pull payload shrink.

## Wrap-up
- [ ] `cd backend && npm test` fully green; `flutter analyze`/`flutter test` untouched-green.
- [ ] Change table for the owner (finding → fix → phase deployed), incl. "reviewed OK"
      list (backups, JWT statelessness, pool size).
- [ ] HOLD commits per phase until the owner confirms each deploy window.
