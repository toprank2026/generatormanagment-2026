# Flash v44 — tasks

Legend: ✅ done (landed and verified). Coupled money-rule work was edited directly
(per `CLAUDE.md`: agents/workflows are for read-only mapping + adversarial review).

## Lane A — models + shared SQL

- ✅ A1 `lib/data/models/correction_models.dart` — `CorrectionStatus.carriedForward`,
  `AdjustmentKind.creditApplied`, **both added to `.all`** (the `normalize()` whitelist —
  see the gotcha in `CLAUDE.md`), `isCarriedForward`; v43-era doc on `increase` corrected.
- ✅ A2 `lib/data/db_helper.dart` — `correctionDueDelta()` (+ increases − credits applied,
  reads `mp.month`, no bind parameter). **No schema change; SQLite stays at 16.**

## Lane B — repositories

- ✅ B1 `correction_repository.dart` — `adjustmentTotal` folds ONLY `refund_return`;
  `dueDeltaFor` (Dart twin); `carryForward` (guarded `refund_due → carried_forward`);
  `correctedInMonth` (tab query). `netDueDeltaFor` **removed** (would double-compensate now
  that approval applies the amps).
- ✅ B2 `core_repositories.dart` — `correctionDueDelta` folded into all six
  `effectiveAmps × price` sites; month-scoped `ampsByCategory`/`ampsByBranchCategory`
  use the parameterised twin (month bound FIRST).

## Lane C — controllers

- ✅ C1 `billing_controller.dart` — `getDueAmount` = frozen amps × price + due delta.
- ✅ C2 `correction_controller.dart` — `carryForward()` (transition first, then ONE
  `credit_applied` on month+1, year-wrap safe, `accountant_id` null); request path no
  longer adds the removed compensation.

## Lane D — Flutter views + i18n

- ✅ D1 `views/widgets/corrections_month_tab.dart` — **new** Corrections tab (derived
  settlement status, canonical pagination, `ever()` on the global month).
- ✅ D2 `subscribers_screen.dart` — 5th tab; sentinel never reaches `loadSubscribers`;
  body swapped BEFORE the existing `GetBuilder`.
- ✅ D3 `corrections_screen.dart` — Carry-forward beside Record-cash-returned.
- ✅ D4 `subscriber_detail_screen.dart` — both amber notices → collapsible `_NoticeShell`.
- ✅ D5 `translations.dart` — 17 keys in **both** maps (apostrophe-free).

## Lane E — backend + panel + contract

- ✅ E1 `accountController.js` — wallet + dashboard collected fold only `refund_return`;
  dashboard per-subscriber due folds `dueDeltaBySubscriber`.
- ✅ E2 `adminController.js` — `carried_forward` in both status sets; `ADJ_CREDIT_APPLIED`;
  `nextMonthOf`; `carryForwardCorrection` (guarded/reverting, mirrors refund-paid);
  `settlementStatus` on `listCorrections` (batched valid receipts vs `new_due`).
- ✅ E3 `routes/admin.js` — `POST /corrections/:id/carry-forward`.
- ✅ E4 `public/admin/index.html` — status label/badge/filter, `carryForward()` action,
  `settlementBadge` column.
- ✅ E5 `API_CONTRACT.md` — v44 money-rule table, new endpoint, `settlementStatus`.

## Lane F — tests + docs

- ✅ F1 `test/v43_corrections_test.dart` — rewritten to v44 semantics (increase → owed,
  paid via receipt; wallets unchanged) + carry-forward test; helpers mirror the controller.
- ✅ F2 `backend/test/v43_corrections.test.mjs` — four tests rewritten; `priceSeededMonth`
  helper (prices the month off MIRRORED amps — the fixture's far-future `updated_at`
  beats a re-push); carry-forward endpoint + settlementStatus tests.
- ✅ F3 `MILESTONES.md`, `CLAUDE.md`, `specs/flash-v44/`.

## Lane R — adversarial review (`wf_57808204-6ef`: 10 dimensions, 55 raw findings)

The verify phase lost 101 of 175 agents to a session limit, so 33 findings were
UNVERIFIED (not refuted) and were triaged by hand. 18 confirmed + 33 unverified
collapsed into the distinct defects below — every one fixed and regression-tested.

- ✅ R1 **`carried_forward` missing from the `effectiveAmps` freeze** (9 reports; 3/3 votes,
  reproduced) — a carry-forward re-priced every earlier month on the LOWER amps and granted
  the credit twice. Added to all three twins + a shared-constant note in `CLAUDE.md`.
- ✅ R2 **Same-month chain tie-break on a random UUID** — a paid customer flipped UNPAID on a
  coin flip. Freeze lookup now orders by `(month, requested_at, id)`.
- ✅ R3 **Ledger folds are STATUS-AWARE** (double-close race: refund on one surface +
  carry-forward on another booked both) — every fold joins `corrections.status`, so the
  correction's last-edit-wins status is the single arbiter (app SQL + Dart twins + backend).
- ✅ R4 **Backend dashboard double-counted an increase** (live applied amps + delta) — new
  mirror-side twin `utils/frozenAmps.js` (`buildFrozenAmps`) used by the dashboard, the
  wallet and the admin list; moved to its own module after a controller-to-controller
  `require` proved circular.
- ✅ R5 **Carry-forward could destroy surplus credit** (target unpriced / already covered /
  credit larger than the target due → derived due negative, "paid" with no receipt) —
  refused on BOTH the app (`correction_carry_forward_unpriced|covered|too_large`) and the
  backend (`409 CORRECTION_CARRY_TARGET_UNPRICED|COVERED|TOO_LARGE`), pointing to the cash
  refund; nothing is written.
- ✅ R6 **List row "amount due" used bare `amps × price`** and contradicted its own paid dot
  — new `dueBySubscriber` (frozen amps + delta) wired into `CoreController.dueFor`.
- ✅ R7 **App "expected" omitted the delta** while `remaining` and the backend include it —
  new `dueDeltaTotal` folded into the reports controller.
- ✅ R8 **Backend `settlementStatus` compared to the stored `new_due`** — now derived exactly
  like the app tab (frozen amps × price + delta − coverage).
- ✅ R9 **`carried_forward` rendered as "Awaiting approval"** in the corrections screen and
  the detail chip, and had no filter chip — all three fixed.
- ✅ R10 **Accountant could push an already-decided `corrections` row** (forgery re-pricing
  every device on a forged `old_amps`) — skip-and-counted + reported, mirroring the v43
  settlement guard; never a batch 4xx.
- ✅ R11 App carry-forward was not atomic (flip then insert) — compensating
  `reopenRefundDue` on insert failure, like the backend's revert.
- ✅ R12 UI: keyed the two `_NoticeShell`s (state no longer swaps when the arrears card
  appears), search box no longer reloads the hidden list on the Corrections tab, dropped an
  unused param.
- ✅ R13 **Mixed-fleet truth**: the spec's "v42+ clients are fail-open" claim was FALSE for
  v43 APKs (they book `credit_applied` as +cash and show `carried_forward` as pending).
  Corrected in the spec, `CLAUDE.md` and `MILESTONES.md`: **update every device before the
  first carry-forward.** No retroactive fix is possible for shipped binaries.
- ✅ R14 `API_CONTRACT.md` enumerations updated (`carried_forward`, `credit_applied`, the
  three carry-forward 409s).
- ✳ Truly refuted (4): left as-is.

## Gate

- ✅ `flutter analyze` 0 errors / 0 warnings (55 pre-existing infos)
- ✅ `flutter test` — **136** (+3 review regressions: frozen July after carry-forward,
  same-month chain order, double-close arbiter)
- ✅ `cd backend && npm test` — **216** (+2: too-large carry-forward refused, accountant
  decided-correction forgery skipped)
- ✅ panel inline JS `node --check`
- ✅ adversarial review fleet — all confirmed + hand-triaged findings fixed
- ✅ `flutter build apk --release` against the Flash API default

> 🚨 Deploy order unchanged: backend first, then the APK. Production is still **v42**
> (verified: the deployed panel has no `corrections` markers).
