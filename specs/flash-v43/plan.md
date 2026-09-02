# Flash v43 — implementation plan

Ordered so no step can leave the tree in a state where an existing figure reads differently
than it does today.

## Phase 0 — backend entity registration (MUST ship before any v43 APK)

| # | File | Change |
| --- | --- | --- |
| 0.1 | `backend/src/controllers/syncController.js` | add `corrections` + `financial_adjustments` to `SYNCED_ENTITIES`, and to `ENTITY_PERMISSION` (accountants may write `corrections`; `financial_adjustments` is **owner/admin-only** — an accountant must never be able to mint their own wallet credit). |

Rationale in `spec.md` §4: an unknown entity throws **400 for the whole batch**, which wedges
the device's outbox permanently. Registration is inert until the app pushes such rows, so it is
safe to deploy on its own, ahead of everything else.

## Phase 1 — schema (SQLite 15 → 16, additive only)

| # | File | Change |
| --- | --- | --- |
| 1.1 | `lib/data/db_helper.dart` | `version: 16`; `_onUpgrade` v16 branch creating `corrections` + `financial_adjustments`, then `_createSyncInfra(db)` so the two get outbox triggers (the v11 settlements branch is the exact precedent). |
| 1.2 | same | the identical DDL inline in `_onCreate`, or installs diverge. |
| 1.3 | same | register both in `syncedTables` so they push to the mirror. |
| 1.4 | same | idempotent indexes: `corrections(subscriber_id, month)`, `corrections(status)`, `financial_adjustments(month, accountant_id)`, `financial_adjustments(subscriber_id, month)`. |

**No existing table is altered.** No column is added to `subscribers`, `receipts`,
`monthly_prices` or `settlements` — see `spec.md` §3.1 for why that would be destructive.

## Phase 2 — the lock predicate (one place, reused everywhere)

| # | File | Change |
| --- | --- | --- |
| 2.1 | `lib/data/repositories/billing_repositories.dart` | `ReceiptRepository.hasValidReceipt(subscriberId, month, {branchId})`. |
| 2.2 | `lib/data/repositories/settlement_repository.dart` | `monthHasActiveSettlement(month, {accountantId, branchId})`, bucketed by `COALESCE(month, substr(requested_at,1,7))` — the same expression the rest of the system already uses. |
| 2.3 | `lib/controllers/core_controller.dart` | `monthLockState(subscriber, month)` → `(invoiceLocked, settlementLocked)`, consulted by the edit path. |

## Phase 3 — the guard (business logic, not UI)

| # | File | Change |
| --- | --- | --- |
| 3.1 | `lib/controllers/core_controller.dart` | in `updateSubscriber`, when a **billing-relevant** field changed (`amps`, `category`, `branch_id`) and the subscriber is invoice-locked for the selected month, throw `ValidationException('edit_locked_invoiced')`. The existing v37 `edit_blocked_settled` guard stays exactly as it is — this is a second, earlier gate, not a replacement. |
| 3.2 | `lib/data/repositories/core_repositories.dart` | `MonthlyPriceRepository.setPrice` refuses a month that already has receipts, with `price_locked_invoiced` — a tariff edit silently re-prices **every** subscriber in that month. |

## Phase 4 — the correction lifecycle

| # | File | Change |
| --- | --- | --- |
| 4.1 | `lib/data/models/correction_models.dart` | **new** — `Correction`, `FinancialAdjustment` (hand-written `toMap`/`fromMap`, `updated_at` stamped, matching every other model). |
| 4.2 | `lib/data/repositories/correction_repository.dart` | **new** — create / list / byMonth / decide / markRefundPaid; `insertAdjustment` is **append-only** (no update, no delete method exists at all). |
| 4.3 | `lib/controllers/correction_controller.dart` | **new** — request (accountant), approve/reject (owner/admin), recordRefundPaid (owner/admin). Registered in `lib/core/app_binding.dart`. |

**Approval writes an adjustment; it never touches the original receipt or settlement.**

**Increase** → `financial_adjustments(kind: correction_increase, +Δ)` → that month's wallet
rises → an additional settlement for the month becomes possible.
**Decrease** → correction goes to `refund_due`; **the wallet is not reduced** → admin returns
the cash → `refund_return` adjustment → `completed`.

## Phase 5 — folding adjustments into the money (the blast radius)

Adjustments must be added to **exactly** these, and to nothing else:

| Figure | File | Include? |
| --- | --- | --- |
| `walletForMonth` collected | `settlement_repository.dart` | **yes** — that is the point |
| `wallet()` lifetime | same | **yes**, or the v42 lifetime cap under-reports |
| `monthUnsettled` | same | **yes** |
| backend `getWallet` (± `?month=`) | `accountController.js` | **yes**, both branches |
| `getCollectedSum` (revenue) | `billing_repositories.dart` | **yes** |
| paid/unpaid derivation, `coverageBySubscriber` | `core_repositories.dart` | **no** — coverage is what the subscriber paid; a correction changes the *due*, and mixing them would flip paid/unpaid on historical rows |
| printed receipt / PDF | `pdf_service`, print services | **no** — an invoice is a historical document |
| `receipt_no` allocation | `billing_repositories.dart` | **no** — never consumes a number |

Any figure not in this table keeps today's behaviour **exactly**.

## Phase 6 — backend

| # | File | Change |
| --- | --- | --- |
| 6.1 | `syncController.js` | in the push loop, evaluate the lock for `subscribers` / `monthly_prices` / `receipts` rows. A violation is **skipped, counted, and reported** in a new additive `rejected[]` on the response. **Never throw** — that wedges every device (see `spec.md` §2.1). |
| 6.2 | `adminController.js` | the synced-data DELETE refuses a receipt/settlement of a locked month → real `409`. |
| 6.3 | `settlementController.js` | **idempotency fix**: add `'data.status': 'pending'` to the decide filter. |
| 6.4 | `accountController.js` | wallet includes adjustments (Phase 5). |
| 6.5 | new admin endpoints | `GET /api/admin/corrections` (search + paging), `POST .../:id/approve`, `.../:id/reject`, `.../:id/refund-paid`. |
| 6.6 | `API_CONTRACT.md` | document all of it, including `rejected[]`. |

## Phase 7 — panel + app UI

| # | File | Change |
| --- | --- | --- |
| 7.1 | `backend/public/admin/index.html` | `#/corrections` section: table + search + paging, Approve / Reject / **Record cash returned** behind the confirm modal; a *Refund Due* filter; month-locked indicator on the receipts grid. ES5-style vanilla JS, matching the file. |
| 7.2 | `lib/views/screens/subscriber_detail_screen.dart` | "Request a correction" affordance when the month is locked. |
| 7.3 | `lib/views/screens/corrections_screen.dart` | **new** — list + decide, mirroring `accountant_settlements_screen.dart`. |
| 7.4 | `lib/utils/translations.dart` | every new key in **both** maps. |

Every new `Obx` must read an observable **first** — the documented release-mode grey-screen trap.

## Phase 8 — tests (the owner's 14 scenarios)

Dart (`test/v43_corrections_test.dart`, `v43_locking_test.dart`): correction before settlement ·
after settlement · increase · decrease · refund-due → cash returned → completed · wallet never
negative · direct edit blocked after invoice · after settlement · one month never affects
another · originals intact.

Backend (`backend/test/v43_corrections.test.mjs`, `v43_sync_lock.test.mjs`): admin
approve/reject/refund-paid · **API-level bypass attempts rejected** · a locked row pushed
through `/api/sync/push` is not mirrored and comes back in `rejected[]` **while the batch still
succeeds and the outbox drains** · decide idempotency.

## Risk register

| Risk | Mitigation |
| --- | --- |
| **Device wedge from an unknown entity (400 whole batch)** | Phase 0 ships first; documented as a hard deploy order |
| **Device wedge from a rejecting push** | skip + `rejected[]`, never throw |
| **Lock state reset account-wide** | derived, never a column (pull is `INSERT OR REPLACE`) |
| Adjustment corrupting invoices | own table; never touches `receipt_no`/printing |
| A figure silently ignoring adjustments | Phase 5 table is exhaustive and test-asserted |
| `isAdmin` is true for owner **and** admin **and** `DEV_ADMIN` | approval checks the explicit role, never `isAdmin` |
| Grey screen in release | every new `Obx` reads an observable first |
