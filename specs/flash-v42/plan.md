# Flash v42 — implementation plan

Ordered so that every step is independently shippable and no step can leave the
tree in a state where existing production data reads differently than before.

## Phase 0 — the safety net first (must land before anything schema-touching)

| # | File | Change |
| --- | --- | --- |
| 0.1 | `lib/core/sync_service.dart` | `pull()` — filter each record's `data` map to the columns the local table actually has (cached `PRAGMA table_info` per table), and wrap each record write so a single bad record is skipped instead of aborting the whole transaction. Push/outbox/trigger logic untouched. |

Rationale: item 5 adds a column to a synced table. Without 0.1 an old-APK device
pulling a v42 subscriber row fails its **entire** pull (the documented v40
blast radius). 0.1 makes that degrade to "the one unknown column is ignored".

## Phase 1 — schema (additive only, SQLite 14 → 15)

| # | File | Change |
| --- | --- | --- |
| 1.1 | `lib/data/db_helper.dart` | `version: 15`; `_onUpgrade` branch `if (oldVersion < 15) { await _addColumn(db,'subscribers','billing_start_month','TEXT'); }`; the same column inline in `_onCreate`'s `subscribers` DDL. |
| 1.2 | `lib/data/db_helper.dart` | `static String creationOrder([String alias = ''])` — the canonical oldest→newest ordering (`COALESCE(NULLIF(REPLACE(created_at,'T',' '),''),'0000-00-00 00:00:00') ASC, id ASC`). |
| 1.3 | `lib/data/db_helper.dart` | idempotent index `idx_subscribers_billing_start` on `subscribers(billing_start_month)`, added in both `_onCreate` and `_onUpgrade`. |

No `UPDATE`, no backfill, no data movement.

## Phase 2 — item 5, subscriber month-onboarding

| # | File | Change |
| --- | --- | --- |
| 2.1 | `lib/data/models/core_models.dart` | `Subscriber.billingStartMonth` + `toMap`/`fromMap`. |
| 2.2 | `lib/controllers/core_controller.dart` | `addSubscriber` stamps `billingStartMonth ??= MonthController.selectedMonth`; `updateSubscriber` preserves it (`??= orig?.billingStartMonth`) — an edit can never move a subscriber's start month. |
| 2.3 | `lib/data/repositories/core_repositories.dart` | `_paymentStatusFrom` — append the activation predicate to `outerScopes` **after** the existing clauses so the positional-arg order stays valid, and document the new arg position. |
| 2.4 | same | `paymentCountsByBoard` — same predicate in its parallel SQL (its own arg order). |
| 2.5 | same | `countByBranch` / `ampsByCategory` (SubscriberRepository) gain an **optional** `month` param applying the predicate; omitted ⇒ today's behaviour. |
| 2.6 | `lib/controllers/dashboard_controller.dart` | pass the selected month to 2.5 so the month's subscriber count and Σ amps stop counting not-yet-active subscribers. |
| 2.7 | `lib/controllers/core_controller.dart` | `notYetActiveIds` for the selected month, so the directory list's payment dot is neutral grey instead of a false red. |
| 2.8 | `lib/views/screens/subscribers_screen.dart` | render the neutral dot. |

**The predicate (identical everywhere):**

```sql
AND ( COALESCE(s.billing_start_month,
               substr(REPLACE(s.created_at,'T',' '),1,7),
               '0000-00') <= ?
      OR r.subscriber_id IS NOT NULL )
```

## Phase 3 — item 1 + 2, per-month wallet

| # | File | Change |
| --- | --- | --- |
| 3.1 | `lib/data/repositories/settlement_repository.dart` | `walletForMonth(accountantId, month)`; `hasPending(..., {month})` optional. `wallet()` untouched. |
| 3.2 | `lib/controllers/settlement_controller.dart` | load / request / pending-guard all carry `_month.selectedMonth.value`. |
| 3.3 | `lib/views/screens/my_wallet_screen.dart` | month chip on each wallet card + on the history header. |
| 3.4 | `backend/src/controllers/accountController.js` | `getWallet` accepts optional `?month=YYYY-MM`; receipts filtered on `data.month`, settlements on `data.month` with `data.requested_at` prefix fallback (`$or` under `$and`, never clobbering the base filter — the v40 pattern). Absent ⇒ identical response to today. |
| 3.5 | `backend/API_CONTRACT.md` | document the optional param. |

## Phase 4 — item 3, arrears notice

| # | File | Change |
| --- | --- | --- |
| 4.1 | `lib/data/repositories/core_repositories.dart` | `previousUnpaidMonths(subscriberId, {beforeMonth, branchId, limit})` — read-only; respects the item-5 activation rule so a subscriber is never told it owes a month it predates. |
| 4.2 | `lib/views/screens/subscriber_detail_screen.dart` | amber notice card between the month row and the due card; loaded in `_refresh()`; **no other value on the screen reads it**. |
| 4.3 | `lib/utils/translations.dart` | new keys in **both** maps. |

## Phase 5 — item 6, deterministic ordering

| # | File | Change |
| --- | --- | --- |
| 5.1 | `lib/data/repositories/core_repositories.dart` | boards / circuits / subscribers `getAll`, `getByBoard`, `getByCircuit`, `getByPaymentStatus` → `DbHelper.creationOrder(...)`. |
| 5.2 | `lib/controllers/core_controller.dart`, board/circuit pickers | no in-memory re-sort may override the SQL order. |
| 5.3 | `backend/src/controllers/adminController.js` | boards/circuits/subscribers synced-data lists sort oldest→newest by `data.created_at` then `localId`. |
| 5.4 | `backend/public/admin/index.html` | owner + admin entity grids follow the same order. |

## Phase 6 — item 4, password reset

| # | File | Change |
| --- | --- | --- |
| 6.1 | `backend/src/models/PasswordResetRequest.js` | **new** model. |
| 6.2 | `backend/src/controllers/authController.js` | `forgotPassword`, `forgotPasswordStatus`. |
| 6.3 | `backend/src/routes/auth.js` | two public rate-limited routes + validators. |
| 6.4 | `backend/src/controllers/adminController.js` | `listPasswordResets`, `approvePasswordReset`, `rejectPasswordReset` (approval writes the hash + bumps `tokenVersion`). |
| 6.5 | `backend/src/routes/admin.js` | three admin routes. |
| 6.6 | `backend/src/utils/events.js` usage | `password_reset_requested` SSE event. |
| 6.7 | `backend/public/admin/index.html` | `#/password-resets` section, nav item, table + search + pagination, approve/reject with confirm modal, dashboard pending badge. |
| 6.8 | `lib/core/api_config.dart` | two endpoint constants. |
| 6.9 | `lib/data/repositories/auth_repository.dart` | two methods. |
| 6.10 | `lib/views/auth/forgot_password_screen.dart` | **new** two-step screen. |
| 6.11 | `lib/views/screens/login_screen.dart` | "forgot password?" link. |
| 6.12 | `lib/utils/translations.dart` | new keys in **both** maps. |
| 6.13 | `backend/API_CONTRACT.md` | the five new endpoints. |

## Phase 7 — verification

* `flutter analyze` clean · `flutter test` green (+ new v42 tests)
* `cd backend && npm test` green (+ new v42 tests)
* adversarial review fleet over the diff
* `flutter build apk --release` (no `--dart-define` ⇒ Flash API
  `https://generator.ecommerceflash.com`)

## Risk register

| Risk | Mitigation |
| --- | --- |
| Positional-arg drift in `_paymentStatusFrom` | new clause appended **last** in `outerScopes`, arg pushed in the same order; asserted by test |
| A legacy subscriber disappearing from an old month | `COALESCE` fallback chain + `OR r.subscriber_id IS NOT NULL` safety valve; asserted by test |
| Old APK freezes on pull after the new column | Phase 0 forward-compatible pull lands first |
| GetX "improper use of Obx" grey screen | every new `Obx` reads an observable first; static conditions hoisted outside |
| Wallet shows 0 and alarms an accountant | month chip on the card states which month the figure belongs to |
| Password reset abused | phone must match the account, `authLimiter`, 24 h expiry, one pending request per account, hash-at-request, change only on super-admin approval |
