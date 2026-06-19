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
- [ ] Conflict resolution: per-row `updated_at` + server compare-on-apply; sticky tombstones; pull skips locally-pending rows. (Critical/High: lost-update, edit-vs-delete, pull-overwrite, push-time-LWW.)
- [ ] Receipt numbering: server-assigned or device-namespaced + post-pull dedup. (Critical/High duplicate `receipt_no`.) + local atomic alloc-in-txn.
- [ ] no-price ≠ paid (require `mp.price_per_amp IS NOT NULL` for paid; collect snackbar) — flips established tests, needs care.
- [ ] Pricing immutability/snapshot: block `setPrices` after receipts (wire the dead `locked`); historical due from `price_snapshot`/`category_snapshot`; warn on category change.
- [ ] Scale tail: count via `COUNT(*)` (no hydration); paid/unpaid pagination; incremental `since`; periodic pull for multi-accountant.
- [ ] Restore flows clear `sync_outbox` (cloud + file import) to stop stale re-push.
- [ ] Branch-delete orphan cleanup on pull; NULL-branch read uniformity (`IFNULL(branch_id,'main')`); consolidated-create branch inheritance/block.
- [ ] maxDevices self-service recovery; token-version on accountant password change; accountant device-exemption cap.

## Verification
- [x] `flutter analyze` clean; `flutter test` 87 pass.
- [x] `cd backend && npm test` 100 pass.
- [~] Adversarial review workflow over the diff (running) → fix confirmed regressions before commit.
