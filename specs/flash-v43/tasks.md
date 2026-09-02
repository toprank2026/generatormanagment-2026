# Flash v43 — tasks

Legend: ✅ done (all lanes landed and verified). Lanes own **disjoint** file sets so parallel edits cannot collide. Per `CLAUDE.md`, editing
agents run **git-free**.

## Lane A — backend entity registration (ships first, alone)

- ✅ A1 `backend/src/controllers/syncController.js` — `corrections` + `financial_adjustments`
  in `SYNCED_ENTITIES`; `ENTITY_PERMISSION`: accountants may write `corrections`,
  **`financial_adjustments` is owner/admin-only** (an accountant must never mint wallet credit).

## Lane B — schema (SQLite 15 → 16)

- ✅ B1 `lib/data/db_helper.dart` — `version: 16`; `_onUpgrade` v16 branch creating both tables
  + `_createSyncInfra(db)`; same DDL inline in `_onCreate`; both in `syncedTables`; idempotent
  indexes. **No existing table altered.**

## Lane C — models + repositories

- ✅ C1 `lib/data/models/correction_models.dart` — **new**: `Correction`, `FinancialAdjustment`.
- ✅ C2 `lib/data/repositories/correction_repository.dart` — **new**: create/list/byMonth/
  decide/markRefundPaid; `insertAdjustment` append-only (**no update/delete method exists**);
  `adjustmentTotal(month, {accountantId, branchId, method})`.
- ✅ C3 `lib/data/repositories/billing_repositories.dart` — `hasValidReceipt(...)`;
  `getCollectedSum` folds in adjustments; **append a `refunds` audit row on reversal**
  (the table is currently never written to).
- ✅ C4 `lib/data/repositories/settlement_repository.dart` — `monthHasActiveSettlement(...)`;
  adjustments folded into `walletForMonth`, `wallet`, `monthUnsettled`.
- ✅ C5 `lib/data/repositories/core_repositories.dart` — `MonthlyPriceRepository.setPrice`
  refuses an invoiced month (`price_locked_invoiced`). Paid/unpaid + coverage **unchanged**.

## Lane D — controllers

- ✅ D1 `lib/controllers/core_controller.dart` — `monthLockState`; `updateSubscriber` throws
  `edit_locked_invoiced` on a billing-relevant edit of an invoiced month. v37's
  `edit_blocked_settled` stays untouched.
- ✅ D2 `lib/controllers/correction_controller.dart` — **new**: request / approve / reject /
  recordRefundPaid; explicit role checks (**never `isAdmin`** — it is true for owner, admin
  *and* the `DEV_ADMIN` compile flag).
- ✅ D3 `lib/core/app_binding.dart` — register `CorrectionController`.

## Lane E — Flutter views + i18n

- ✅ E1 `lib/views/screens/subscriber_detail_screen.dart` — locked-month notice + "request a
  correction".
- ✅ E2 `lib/views/screens/corrections_screen.dart` — **new**: list + decide + record-cash-returned.
- ✅ E3 `lib/utils/translations.dart` — every new key in **both** maps.

## Lane F — backend logic

- ✅ F1 `backend/src/controllers/syncController.js` — **REVISED after adversarial review**: the
  push-loop business lock was **removed** (see spec §2.2 — a server refusal stricter than the
  client silently reverts real data at the next full restore, and old APKs have no client
  guard at all). What remains: the settlement-forgery refusal, skip-and-counted and now
  reported in `rejected[]`, plus `accountant_id` left unstamped on the correction entities
  (it is a wallet target, not the writer's identity).
- ✅ F2 `backend/src/controllers/adminController.js` — synced-data DELETE refuses a locked
  receipt/settlement (409); correction list/approve/reject/refund-paid handlers.
- ✅ F3 `backend/src/routes/admin.js` — four correction routes.
- ✅ F4 `backend/src/controllers/settlementController.js` — **idempotency fix**:
  `'data.status': 'pending'` in the decide filter.
- ✅ F5 `backend/src/controllers/accountController.js` — wallet includes adjustments (both the
  `?month=` and the all-time branch).
- ✅ F6 `backend/API_CONTRACT.md` — new endpoints + `rejected[]` + the wallet change.

## Lane G — panel

- ✅ G1 `backend/public/admin/index.html` — `#/corrections` section (table + search + paging +
  Approve/Reject/Record-cash-returned + Refund-Due filter); month-locked indicator.

## Lane H — tests + docs

- ✅ H1 `test/v43_locking_test.dart` — direct edit blocked after invoice / after settlement;
  price edit blocked; name/phone still editable; **one month never affects another**.
- ✅ H2 `test/v43_corrections_test.dart` — before/after settlement; increase; decrease;
  refund-due → cash returned → completed; **wallet never negative**; originals intact.
- ✅ H3 `backend/test/v43_sync_lock.test.mjs` — a locked row pushed to `/api/sync/push` is not
  mirrored, comes back in `rejected[]`, **the batch still 200s and the outbox drains**;
  hand-crafted bypass rejected.
- ✅ H4 `backend/test/v43_corrections.test.mjs` — admin approve/reject/refund-paid; decide
  idempotency; API-level bypass.
- ✅ H5 `MILESTONES.md` + `CLAUDE.md` — v43 entry, schema-16 note, **deploy order**.

## Lane R — adversarial-review fixes (10 dimensions, 53 findings)

- ✅ R1 push-path lock removed; `rejected[]` now carries the forgery skips (F1 above).
- ✅ R2 `BillingController.setPrice`/`setPrices` call `insertGuarded` — the tariff lock was
  **dead code** (no production caller); `setPrices` validates every category before writing
  any, so a refusal cannot leave a partial re-price.
- ✅ R3 `CorrectionController.approve` + `recordRefundPaid` — the **guarded status transition
  runs FIRST**; the append-only adjustment is written only after it succeeds (a lost race
  previously left an unremovable wallet credit for a REJECTED correction).
- ✅ R4 `CorrectionRepository.netDueDeltaFor` — a **second** correction for the same
  subscriber-month is now strictly incremental (approval leaves the subscriber row untouched,
  so the old basis was being re-measured and the delta re-booked: unbounded double credit).
- ✅ R5 `canRequest` widened to owner/admin — they are subject to `edit_locked_invoiced` but
  had **no correction route**, i.e. a capability removed with no substitute.
- ✅ R6 `CorrectionsScreen` routed from Settings — it had **no importer anywhere**, so the
  queue was unreachable dead code.
- ✅ R7 `CorrectionController.onReady` no longer pulls — opening an invoiced subscriber's
  detail screen instantiated the controller (`fenix`) and fired a full push+pull nobody asked
  for.
- ✅ R8 `adminController` — `ADJUSTMENT_IMMUTABLE` / `CORRECTION_IMMUTABLE`: the append-only
  ledger can no longer be tombstoned through the generic synced-data DELETE (the tombstone
  propagated to every device and silently moved the wallet).
- ✅ R9 `buildDashboard` folds adjustments into `collected` — `/api/account/stats` and the
  owner panel disagreed with the app about the same month's revenue and net profit.
- ✅ R10 `listCorrections` resolves `receiptNo` — the panel column read a field no handler,
  contract or column ever supplied.
- ✅ R11 15 refusal/status translation keys added to **both** maps (parity passed while users
  saw raw `snake_case` tokens) + `correction_requests_subtitle`.
- ✅ R12 `API_CONTRACT.md` reconciled with the handlers (push section rewritten, delete refusal
  codes, the settlement-status caveat, the attribution exception).

## Gate

- ✅ `flutter analyze` 0 errors / 0 warnings (55 pre-existing infos)
- ✅ `flutter test` green — **130 tests** (112 baseline + 18)
- ✅ `cd backend && npm test` green — **212 tests** (188 baseline + 24)
- ✅ adversarial review fleet; all confirmed findings fixed
- ✅ `flutter build apk --release` against the Flash API default

> 🚨 **DEPLOY ORDER — not advice.** An unknown sync entity throws **400 for the whole batch**,
> so a v43 APK on a device whose backend lacks the new entities makes **every** push fail
> forever (and `pull()` pushes first, so sync stops entirely). **Backend first, then the APK.**
