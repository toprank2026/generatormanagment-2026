# Backend Scale — PLAN (safe rollout for a LIVE system)

> Companion to `spec.md`. **Hard constraint from the owner: the current version must not
> be affected — there are working users and subscribers in production.** Every phase
> below is therefore (a) backward-compatible with the ALREADY-SHIPPED Flutter clients
> (v22/v23/v24 are in the field and will not update in lockstep), (b) independently
> deployable, and (c) independently rollback-able by redeploying the previous commit.
> No phase requires an app update; the only Flutter change in this whole spec is an
> OPT-IN client improvement shipped later (Phase F).

## A. Compatibility contract (applies to every task)

1. **No response-shape changes** on existing endpoints — new fields may be ADDED
   (`hasMore`, `nextCursor`, `db` in health), existing fields never renamed/removed/
   retyped. Deployed clients ignore unknown fields (verified: ApiClient decodes maps
   by key).
2. **No request-shape requirements added** — new query params/body fields are optional;
   an endpoint called exactly as today returns exactly what it returns today
   (same rows, same order guarantees, same status codes).
3. **Sync SEMANTICS untouchable** — last-edit-wins + sticky tombstones + drain contract
   (`syncController.js` conflict rules are copied verbatim in refactors, never edited;
   the existing backend conflict tests are the guard).
4. **No destructive data operations at deploy time** — index creation is additive
   (background build); the tombstone sweep ships DISABLED by default
   (`TOMBSTONE_RETENTION_DAYS=0` = off) and is enabled manually AFTER observation.
5. **Caps must clear the shipped clients**: push record cap = 500 (clients send 200);
   rate limits sized so a 1000-subscriber import (~6 rapid push batches) and normal
   panel polling never trip them.
6. Every endpoint change lands in `backend/API_CONTRACT.md` in the same commit.
7. `cd backend && npm test` green after EVERY phase; new tests accompany each change.

## B. Phase order (each phase = one deployable unit)

| Phase | Scope | Spec § | Risk to live users | Rollback |
|---|---|---|---|---|
| A | P0 config guards: USE_MEMORY_DB default flip + prod fail-fast + health `db` field | 0.1 | None — prod already sets the var correctly or is already broken; fail-fast only blocks MISconfigured boots | Redeploy previous |
| B | P1 indexes on SyncRecord (5 compound, background build) | 1.1 | None — additive; brief background build I/O on first boot | Leave indexes (harmless) |
| C | P2.2 push bulkWrite (semantics-identical) + record cap 500 + P2.4 compression | 2.2, 2.4 | Low — response shapes identical; golden conflict tests guard semantics; compression is transparent content-negotiation (SSE excluded) | Redeploy previous |
| D | P2.1 pull: `.lean()` + OPT-IN pagination (`?limit=` only) — no-limit callers get today's exact full dump | 2.1 | None for deployed clients (they never send `limit`) | Redeploy previous |
| E | P3: auth projections + owner-cascade TTL cache, bcrypt swap, graceful shutdown/timeouts, broader rate limits (generous ceilings) | 3.1–3.4 | Low — behavior-preserving; cache TTL 15-30s only on the owner cascade (primary user stays fresh for tokenVersion/blocked checks) | Redeploy previous |
| F | Flutter client (LATER app release): paged pull loop in `SyncService.pull()` wrapper (drain/outbox untouched) + size-aware push batching note | 2.1 client | None — opt-in param against a backend that already supports it (deploy AFTER Phase D is live) | Ship without it |
| G | P4 panel/caching polish: buildDashboard aggregation behind env flag with golden-fixture parity, listUserData $facet, stats/static cache headers, plan cache | 4.1–4.3 | Low — `STATS_AGGREGATION=false` env kills the new path instantly; figures guarded by fixture parity tests | Flip env flag |
| H | Enable tombstone retention (`TOMBSTONE_RETENTION_DAYS=90`) after 1–2 weeks of observation; monitor pull sizes | 2.3 | Controlled — sweep only deletes tombstones older than retention; any device offline >90 days does a full restore path anyway (login auto-pull) | Set back to 0 |

Order rationale: A is the data-loss guard (do first, zero risk). B unlocks every query
win with zero API surface. C+D are the hot-path wins, still invisible to old clients.
E–H are progressive and each has an independent kill switch.

## C. Deployment & verification recipe (per phase)

```bash
# before deploy (local)
cd backend && npm test                     # all green, incl. the phase's new tests
node --check src/<changed files>

# staging-style smoke against a local prod-mode boot
NODE_ENV=production USE_MEMORY_DB=false MONGO_URI=... npm start   # must boot (Phase A: must FAIL without MONGO_URI)
BASE_URL=http://localhost:4000 npm run seed:demo                  # seeds 100 subs + receipts
# curl checks: /api/health shows db:mongo; pull with and WITHOUT ?limit; push a 200-record batch

# after deploy (production)
curl https://generator.ecommerceflash.com/api/health              # db: "mongo", ok: true
# watch logs for 15 min: no 413s, no 429s from real clients, sync push/pull latencies
```

Golden-parity rule for Phase G: run OLD and NEW stats implementations side-by-side in a
test against the seeded mixed-tariff fixture and assert numeric equality BEFORE the flag
defaults to on.

## D. Explicit DO-NOT list (protects the live fleet)

- Do NOT make `since`/`limit` required on pull; do NOT change the no-param pull's output.
- Do NOT edit the conflict-resolution branches in syncController (copy verbatim into the
  bulk version; diff-review them side-by-side).
- Do NOT add per-device checks to data routes (documented Phase-2 gap — out of scope).
- Do NOT enable the tombstone sweep in the same deploy that introduces it.
- Do NOT cache the PRIMARY user in requireAuth (tokenVersion/blocked must apply within
  one request of an admin action); only the owner/parent cascade is cacheable.
- Do NOT touch `lib/core/sync_service.dart` drain/outbox logic in Phase F — the paging
  loop wraps the existing per-page apply path only.
- Do NOT change SPA index.html caching to anything but no-cache (owners must get panel
  fixes immediately).
