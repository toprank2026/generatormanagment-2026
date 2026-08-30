# Flash v42 — tasks

Legend: ✅ done (all lanes landed and verified). Owner column = which fleet lane edits the file
(lanes own **disjoint** file sets so parallel edits cannot collide; per
`CLAUDE.md`, editing agents run **git-free**).

## Lane A — sync hardening + schema (must land first)

- ✅ A1 `lib/core/sync_service.dart` — `pull()` filters each record's `data` to
  the local table's real columns (cached `PRAGMA table_info`) and isolates a
  failing record instead of aborting the transaction. Push/outbox/triggers
  untouched.
- ✅ A2 `lib/data/db_helper.dart` — `version: 15`; `_onUpgrade` v15 branch adding
  `subscribers.billing_start_month TEXT` via `_addColumn`; the same column in
  `_onCreate`'s `subscribers` DDL.
- ✅ A3 `lib/data/db_helper.dart` — `static String creationOrder([String alias])`
  canonical ordering helper + `idx_subscribers_billing_start` (idempotent, in
  both `_onCreate` and `_onUpgrade`).

## Lane B — item 5 (subscriber month-onboarding) + item 6 (ordering), data layer

- ✅ B1 `lib/data/models/core_models.dart` — `Subscriber.billingStartMonth`
  (+ `toMap`/`fromMap`).
- ✅ B2 `lib/data/repositories/core_repositories.dart` — activation predicate in
  `_paymentStatusFrom` (appended **last** in `outerScopes`; arg order documented).
- ✅ B3 same — activation predicate in `paymentCountsByBoard`.
- ✅ B4 same — optional `month` on `SubscriberRepository.countByBranch` and
  `ampsByCategory`.
- ✅ B5 same — `previousUnpaidMonths(subscriberId, {beforeMonth, branchId, limit})`.
- ✅ B6 same — every board / circuit / subscriber list query switched to
  `DbHelper.creationOrder(...)`.

## Lane C — controllers

- ✅ C1 `lib/controllers/core_controller.dart` — stamp `billingStartMonth` from
  the global tariff month on add; preserve it on edit; expose `notYetActiveIds`.
- ✅ C2 `lib/controllers/dashboard_controller.dart` — month-scoped subscriber
  count and Σ amps.
- ✅ C3 `lib/controllers/settlement_controller.dart` — month-scoped wallet load,
  per-month pending guard, month-scoped settlement request.

## Lane D — wallet repository + backend wallet

- ✅ D1 `lib/data/repositories/settlement_repository.dart` — `walletForMonth`,
  optional `month` on `hasPending`; `wallet()` left intact.
- ✅ D2 `backend/src/controllers/accountController.js` — optional `?month=` on
  `GET /api/account/wallet` (v40 `$or`-under-`$and` fallback pattern).

## Lane E — Flutter views

- ✅ E1 `lib/views/screens/my_wallet_screen.dart` — accounting-month chip on both
  wallet cards + history header.
- ✅ E2 `lib/views/screens/subscriber_detail_screen.dart` — amber previous-months
  notice between the month row and the due card; read by nothing else.
- ✅ E3 `lib/views/screens/subscribers_screen.dart` — neutral dot for a
  not-yet-active subscriber.
- ✅ E4 `lib/views/auth/forgot_password_screen.dart` — **new** two-step screen.
- ✅ E5 `lib/views/screens/login_screen.dart` — "forgot password?" entry point.

## Lane F — Flutter auth plumbing + i18n

- ✅ F1 `lib/core/api_config.dart` — `forgotPassword`, `forgotPasswordStatus`.
- ✅ F2 `lib/data/repositories/auth_repository.dart` — request + status methods.
- ✅ F3 `lib/utils/translations.dart` — every new key in **both** `en_US` and
  `ar_AR` (the parity test fails otherwise).

## Lane G — backend password reset

- ✅ G1 `backend/src/models/PasswordResetRequest.js` — **new** model.
- ✅ G2 `backend/src/controllers/authController.js` — `forgotPassword`,
  `forgotPasswordStatus`.
- ✅ G3 `backend/src/routes/auth.js` — two public rate-limited routes.
- ✅ G4 `backend/src/controllers/adminController.js` — list / approve / reject
  (+ oldest→newest ordering for the boards/circuits/subscribers synced lists).
- ✅ G5 `backend/src/routes/admin.js` — three admin routes.
- ✅ G6 `backend/API_CONTRACT.md` — five endpoints + the wallet `month` param.

## Lane H — admin + owner panel SPA

- ✅ H1 `backend/public/admin/index.html` — `#/password-resets` route, nav item,
  table with search + pagination, Approve / Reject via the confirm modal,
  dashboard pending badge.
- ✅ H2 same — owner/admin entity grids ordered oldest→newest.

## Lane I — tests + docs

- ✅ I1 `test/v42_month_isolation_test.dart` — per-month wallet arithmetic;
  August money never appears in September and vice-versa.
- ✅ I2 `test/v42_subscriber_onboarding_test.dart` — a month-9 subscriber is
  absent from month-8 unpaid lists/counts; a legacy NULL-stamp subscriber is
  unaffected; the receipt safety valve keeps a receipted subscriber visible.
- ✅ I3 `test/v42_ordering_test.dart` — mixed NULL / space-format / ISO-format
  `created_at` rows sort oldest→newest deterministically, unchanged after a
  simulated pull re-inserts them in a different order.
- ✅ I4 `backend/test/v42_password_reset.test.mjs` — request → pending → password
  unchanged; approve → password changed + old token invalid; reject → unchanged;
  wrong phone rejected; expiry.
- ✅ I5 `backend/test/v42_wallet_month.test.mjs` — `?month=` isolation + no-param
  back-compat.
- ✅ I6 `MILESTONES.md` + `CLAUDE.md` — v42 entry and the schema-15 note.

> **Backend test naming (found by the mapping fleet):** `backend/package.json`
> runs `node --test "test/**/*.test.mjs"` and declares `"type": "commonjs"`.
> A `.js` test is **never collected** — it would look green by not running at
> all. Every backend test must be `snake_case.test.mjs` using ESM `import`.

## Gate

- ✅ `flutter analyze` 0 errors / 0 warnings (55 pre-existing infos)
- ✅ `flutter test` green — **111 tests** (102 baseline + 9 new)
- ✅ `cd backend && npm test` green — **185 tests** (170 baseline + 15 new)
- ✅ adversarial review fleet over the full diff; all actionable findings fixed
- ✅ `flutter build apk --release` against the Flash API default

## Adversarial review (10 dimensions × 3-lens refutation, 133 agents)

**41 raw findings → 5 confirmed, 36 refuted.** Several of the refutations are
findings the lead had already fixed while the fleet was running, so the
verifiers read the corrected code. Every confirmed finding was fixed and
covered by a test.

| # | Confirmed finding | Fix |
| --- | --- | --- |
| 1 | `countByBranch`/`ampsByCategory`/`ampsByBranchCategory` applied the activation rule **without** the receipts safety valve, so a subscriber who PAID in the month was dropped from the count / Σ amps / **expected** while their cash stayed in **collected** — `paid + unpaid` could exceed the total on one dashboard | `_activeInMonthSql` gained the valve as an `EXISTS` sub-query; all three callers push the month twice. Test updated to assert the consistent contract. |
| 2 | Month-scoping `hasPending` dropped the duplicate guard for **pre-v40 pending rows** (`month IS NULL`): browsing to another month hid them, letting an accountant file a second request while the owner still held the first | an unstamped pending request now blocks **every** month until decided (`month = ? OR month IS NULL`); regression test added. |
| 3 | `previousUnpaidMonths` read coverage from a receipts table that **sync deliberately keeps month-scoped**, so a freshly-pulled device would report a fully paid-up subscriber as owing *every* earlier month | the notice now only claims a month this device actually holds receipt data for (`EXISTS` evidence check). A false "owes nothing" is far safer than a false "owes 12 months" for a notification; both halves asserted by test. |
| 4 | The reversal/delete lock is all-time while a settlement now covers one month | **pre-existing** (`lastActiveRequestAt` is untouched by v42); left as-is deliberately — the lock keys on timestamps, not months. |
| 5 | The panel's 200-row board/circuit name map covered the **oldest** 200 after the sort flip, so recent جوزة rendered as "—" | `loadNameMaps` now paginates (200/page, bounded) and merges, so names resolve regardless of sort order. |

Lead-initiated fixes made during the same pass (all test-covered):

- **Settlement double-payout cap** — a settlement is an *amount*, not a link to
  receipts, so one bucketed to another month (a legacy `requested_at` row, or a
  v40 row stamped elsewhere) could pay out August's cash while August's month
  wallet still showed it as a fresh balance. Requests are now capped at the
  **lifetime** unsettled balance, which is conserved; per-month display is
  unchanged and the cap is a no-op in the normal case.
- **Lifetime "still in hand" card** on My Wallet, so month-scoping can never
  hide cash collected in a month nobody reopens.
- **`GET /api/account/stats`** month-scoped for subscribers, so the owner panel
  and the app agree about the same month.
- **`password_reset_requested` SSE forwarder** — the event was emitted but never
  written to the stream, so the panel's live handler could never fire.
- **`serializeResetRequest` read `doc.verificationCode`**, a field the schema
  does not have — every verification code would have rendered as "—", breaking
  the entire identity check.
- **Rollout rule restored** to `CLAUDE.md`/`MILESTONES.md`: the pull hardening is
  **not retroactive**, so v42 itself still needs the v40 all-devices-together
  rule; the benefit lands on the next schema addition.
