# Tasks — Audit Fixes

## Phase 1 — DONE (shipped this batch; suites green: Flutter 87, backend 100)

### Backend
- [x] WS-SEC: prod fail-fast on default/missing `JWT_SECRET` + `ADMIN_PASSWORD` (env.js `validateSecrets`, server.js boot, seed.js); helmet; auth rate-limit (rateLimit.js, 429 `RATE_LIMITED`).
- [x] WS-SEC: owner/admin login requires `device` (400 `DEVICE_REQUIRED`) → `maxDevices` actually enforced; accountants stay exempt.
- [x] WS-SEC: subscription `expiresAt` enforced — `isSubscriptionActive` in serialize + planFeatures (served as `expired`, stops gating features).
- [x] WS-PUSHAUTHZ: `/sync/push` entity whitelist (`BAD_ENTITY`), accountant entity→permission gate (`PERMISSION_DENIED`/`ENTITY_FORBIDDEN`), branch/accountant server-stamp + cross-branch reject (`BRANCH_FORBIDDEN`); `/sync/pull` branch-scoped for confined accountants.
- [x] WS-DASH: consolidated dashboard prices each subscriber by its own `(branch,category)`; backup handlers + multer dir keyed by `effectiveOwnerId`.
- [x] WS-PANEL: `fmtPrice/fmtDate*` stop double-escaping the textContent fallback.
- [x] +15 backend tests; API_CONTRACT updated.

### Flutter
- [x] WS-DISCOUNT: `ReceiptRepository.getDiscountSum`; Dashboard + Reports `remaining = expected − collected − discount` (+test).
- [x] WS-SYNCSAFE: `isPulling` guard in `maybeAutoSync`/`syncNow`; `_reloadAppData` refreshes BillingController price cache.
- [x] WS-SYNCSAFE: logout-wipe only when online + `canSync` + outbox drained (else keep data).
- [x] WS-SCALE: DB v7→v8 with 9 indexes (idempotent, both `_onCreate`/`_onUpgrade`).
- [x] WS-PERMS-UI: subscriber-detail edit/delete gate on `can(Perm.subscribers)`; subscribers list reload-on-return; collect dialog try/catch.

## Phase 2 — TODO (architectural / decision required)
- [x] Conflict resolution: per-row `updated_at` (v9, stamped in every toMap) + **server** last-EDIT-wins compare + sticky tombstones. _Residual:_ edit-vs-delete relies on edit-time vs delete push-time (clock-skew edge); pull doesn't yet skip locally-pending rows (push→pull window) — both need sync-engine changes (CLAUDE.md off-limits).
- [~] Receipt numbering: **local atomic alloc-in-txn DONE** (`insertWithAllocatedNumber`). Server-assigned / device-namespaced + post-pull dedup = HELD (per user) / cross-device still open.
- [x] no-price ≠ paid (a missing price → UNPAID, not "paid"; collect `no_price_set` snackbar).
- [ ] Pricing immutability/snapshot: block `setPrices` after receipts / historical due from snapshots / warn on category change. **Needs a product decision** (block edits vs snapshot-based due).
- [~] Scale tail: **COUNT(*)/Σamps aggregates DONE** (no full-table loads, no N+1). Paid/unpaid screen pagination + incremental `since` + periodic multi-accountant pull = still open (incremental-`since` deferred: risks silently missing rows if the cursor is wrong).
- [x] Restore flows clear `sync_outbox` (cloud + file import).
- [ ] Branch-delete orphan cleanup on pull; NULL-branch read uniformity; consolidated-create branch inheritance/block. (Risky — touches many reads.)
- [x] **token-version** on password change (TOKEN_STALE) + **maxDevices self-service recovery** (`/api/auth/recover-device`). Open: accountant device-exemption cap; device-limit enforcement on data routes (would break the app without a coordinated client change).

## Verification
- [x] `flutter analyze` clean; `flutter test` 87 pass.
- [x] `cd backend && npm test` 100 pass.
- [~] Adversarial review workflow over the diff (running) → fix confirmed regressions before commit.
