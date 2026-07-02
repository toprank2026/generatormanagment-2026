# Flash v23 — TASKS (granular checklist)

> Check off in `plan.md` phase order. Anchors verified at commit `0ec2670`.
> `[APP]` = Flutter, `[BE]` = backend, `[SPA]` = backend/public/admin/index.html, `[T]` = test.

## Phase 1 — Repo/SQL (spec §8.1, §8.2, §2.3)
- [ ] [APP] `core_repositories.dart` `getByBoard`: add `int? limit, int? offset` named params
      (apply only when non-null — existing callers unchanged).
- [ ] [APP] `core_repositories.dart`: NEW `ampsByBranchCategory({accountantId})` →
      `SELECT IFNULL(branch_id,'<main>') b, IFNULL(category,'standard') c, SUM(amps) FROM subscribers GROUP BY b, c`
      (mirror `ampsByCategory`'s normalization; use `DbHelper.kMainBranchId` for the NULL branch key).
- [ ] [APP] `billing_repositories.dart`: NEW `MonthlyPriceRepository.pricesForMonthByBranch(month)` →
      `Map<String branchKey, Map<String category, double price>>` keyed with the SAME
      NULL-branch normalization as above. Do NOT touch `pricesForMonth`.
- [ ] [APP] Fix the stale doc comment at `core_repositories.dart:527-529` to list the v22/v23
      arg order (inner month[,branch][,receiptAccountant]; mp month; outer [accountant][branch][category][query×2]).

## Phase 2 — Pagination UI (spec §8)
- [ ] [APP] `core_controller.dart` `loadFilteredSubscribers`: canonical fetch-101 pattern
      (page param, `_filteredPage` state, assignAll/addAll, preserve `query`+`category`,
      `hasNextPage`-style flag for the filtered variant) using getByPaymentStatus's existing
      `limit`/`offset`.
- [ ] [APP] `core_controller.dart` `loadBoardSubscribers`: same pattern via the new
      getByBoard limit/offset.
- [ ] [APP] `subscribers_screen.dart` `_onScroll` (:78-86): remove the
      `filter == null && boardId == null` exclusion; route to the correct loadMore per variant.
- [ ] [APP] `accountant_settlements_screen.dart`: ScrollController + loadMore paging on
      `listAllForOwner(limit, offset)` (canonical pattern; dispose the controller).
- [ ] [T] `flutter analyze` 0/0; `flutter test` green.

## Phase 3 — Reports app-side (spec §2.2-app-text, §2.3–§2.6)
- [ ] [APP] `reports_controller.dart` `loadReport`: compute into locals, single atomic assign
      at the end; on catch keep old values + `Get.snackbar('error'.tr, 'report_failed'.tr)`.
      NEW key `report_failed` (both maps).
- [ ] [APP] `reports_controller.dart`: consolidated (`_branchScope == null`) `expectedTotal`
      via `ampsByBranchCategory` × `pricesForMonthByBranch` (Σ per branch per category);
      single-branch math untouched. Check `DashboardController` for the same consolidated
      expected math — fix identically ONLY if present.
- [ ] [APP] `payments_screen.dart` receipt card: refunded rows styled grey + marker (copy
      `payment_history_screen.dart:275,318-323` style). Verify a `refunded` key exists
      (grep); add to both maps if not.
- [ ] [APP] `reports_screen.dart:144-146`: donut center = `paidCount + unpaidCount`.
- [ ] [APP] Delete dead `GaugeChart` (`report_charts.dart:22-140`) after re-verifying zero refs.
- [ ] [APP] Reword `'no_price_for_month'` in BOTH maps ("subscribers count as unpaid until a
      price is set" semantics) + fix the stale comments at `reports_screen.dart:96-98` and
      `reports_controller.dart:51`.

## Phase 4 — Reports backend+SPA (spec §2.1, §2.2)
- [ ] [BE] `accountController.js` `buildDashboard`: include `expected` in the payload (:213-237).
- [ ] [BE] `buildDashboard`: unpriced category ⇒ subscriber counts UNPAID (align with app rule,
      :190-198); fix stale comment :52-53.
- [ ] [SPA] `index.html:2473`: use `dash.expected` with fallback to the old computation.
- [ ] [T] Backend tests: mixed-tariff `expected` correctness; unpriced month ⇒ `paidCount === 0`.
- [ ] [BE] Update `API_CONTRACT.md` (stats payload gains `expected`).

## Phase 5 — Password flows (spec §3.2, §3.3)
- [ ] [APP] `edit_account_screen.dart`: add required-when-password-set `current_password`
      field (obscured; trim both password fields); local pre-check via `verifyOwnerPassword`
      when a hash exists; min length 4 for the new password. NEW key `current_password`
      (both maps — grep first).
- [ ] [APP] `auth_controller.dart` `updateProfile` + `auth_repository.dart updateProfile`:
      pass `currentPassword` through; map 401 `WRONG_PASSWORD` → `'wrong_password'.tr`.
- [ ] [BE] `accountController.js` `updateMyProfile`: when `password` set, require + bcrypt-verify
      `currentPassword` else 401 `{code:'WRONG_PASSWORD'}`.
- [ ] [APP] `accountants_screen._showEditDialog`: owner-password prompt when the accountant
      password field is non-empty (NEW key `confirm_identity`, both maps); abort on cancel;
      keep v22 busy/Navigator.pop patterns; pass `ownerPassword` down.
- [ ] [APP] `settings_controller.updateAccountant` + `auth_repository.updateAccountant`:
      thread `ownerPassword`; map 401 → `'wrong_password'.tr`.
- [ ] [BE] `accountantAccountController.js updateAccountant`: `password` present ⇒ require +
      verify `ownerPassword` (bcrypt vs req.user) else 401 WRONG_PASSWORD; enforce new
      password ≥ 4 chars.
- [ ] [T] Backend tests ×4 (profile right/wrong old pwd; accountant reset right/wrong owner pwd).
- [ ] [BE] Update `API_CONTRACT.md` for both endpoints.

## Phase 6 — Import/export polish (spec §3.1)
- [ ] [APP] `settings_controller.importSubscriberBackup`: FilePicker `type: FileType.custom,
      allowedExtensions: ['backup']`.
- [ ] [APP] Split FormatException handling: `not_a_valid_backup` (NEW key, both maps) vs
      existing `backup_wrong_password`.
- [ ] [APP] `_askBackupPassword`: confirm disabled until non-empty (StatefulBuilder); trim result.
- [ ] [APP] Import success snackbar: per-table counts using existing label keys.
- [ ] [APP] `local_backup_service.dart` export filename: `<safeName>-yyyyMMdd.backup`
      (envelope format untouched).

## Phase 7 — Numeric month picker (spec §5)
- [ ] [APP] `monthly_pricing_screen.dart:185-207`: replace showDatePicker with the custom
      year-stepper + 4×3 numeric month grid dialog (1..12, numerals only); selected highlight;
      `setMonth(DateFormat('yyyy-MM')...)` + `Navigator.pop`. Years 2020–2030. NEW key
      `select_month` if absent (both maps).
- [ ] [APP] `expenses_screen.dart:315`: `DateFormat('MMM d')` → `DateFormat('yyyy-MM-dd')`.

## Phase 8 — Printers (spec §6)
- [ ] [APP] QR: `bluetooth_print_service.dart:201` 190→160; `usb_print_service.dart:284`
      190→160; `pdf_service.dart:109-114` 75→65.
- [ ] [APP] SafeArea on all four settings bottom sheets (USB :756, BT :803, backup :514,
      devices :646); BT device list in `ConstrainedBox(maxHeight: Get.height * .5)`.
- [ ] [APP] `payment_history_screen.dart:137`: await `_handlePrint` post-collect (align with
      subscriber_detail).
- [ ] [APP] Settings test-print tile (NEW key `test_print`, both maps): active-transport tiny
      slip; handles `usb_busy`/failures with post-close snackbars.

## Phase 9 — Device binding (spec §4)
- [ ] [APP] Thread ApiException `code` into `AuthController.login` failure map; login screen:
      DEVICE_LIMIT → `device_limit_msg` (NEW key both maps) instead of `account_disabled`.
- [ ] [APP] Recovery flow: dialog `device_limit_recover_q` (NEW key both maps) →
      `AuthRepository.recoverDevice(username, password)` (new method, POST /api/auth/recover-device
      with device object) → shared post-login tail (factor the tail of `login()` into a private
      helper used by both paths — includes residue guard + pulls, preserving v22 ordering).
- [ ] [BE] `deviceController.list` + route: accept `?current=<deviceId>` and serialize `current`
      accordingly. [APP] `device_repository.list()` sends it; settings sheet shows
      `(this_device)`; stronger warn on unbinding the current device (NEW key
      `unbind_current_warn`, both maps).
- [ ] [APP] Residue-guard cancel path: best-effort `DeviceRebind.apply(rebind:false)` before
      `logout()` (auth_controller ~:325).
- [ ] [T] Backend test: `GET /api/device?current=` marks the right row. (recover-device tests
      already exist.)
- [ ] [BE] `API_CONTRACT.md`: device list `current` param; recover-device now used by the app.

## Phase 10 — Owner panel (spec §7, §9)
- [ ] [BE] `adminController.listUserData`: optional `month=YYYY-MM` (expenses `data.date`
      prefix regex; validate format); `relValue=__none__` ⇒ `{'data.accountant_id': null}`;
      `entity==='expenses'` ⇒ include `totalAmount` (aggregate over same filter).
- [ ] [SPA] `viewMyEntity('expenses')`: accountant dropdown (accountants mirror; الكل /
      المالك options) + month input + total row (`totalAmount`).
- [ ] [SPA] `SYNC_COLUMNS.expenses`: add المحاسب column (accountants map, null → المالك);
      Arabic labels for expense categories (raw fallback).
- [ ] [SPA] Generic `entityDetailContent` + route `#/my/data/:entity/detail/:localId` for
      subscribers/boards/circuits/expenses/monthly_prices/settlements; FK/name resolution;
      no raw JSON fallback for known entities; subscriber detail links to `#/my/sub/:subId`.
- [ ] [SPA] Verify admin-panel routes still render (shared renderers).
- [ ] [T] Backend tests: month filter, `__none__`, totalAmount.
- [ ] [BE] `API_CONTRACT.md` updates.

## Phase 11 — Conflict hardening (spec §10)
- [ ] [APP] `user_switch_screen._switchWithWipe`: v17-style guard (busy-refuse → online push →
      refreshPending → pending>0 blocking dialog + ABORT) before the wipe; R-GETX ordering.
- [ ] [BE] `adminController.deleteUserData`: hard delete → tombstone (`deleted:true`,
      `updatedAt`, `data.updated_at` ISO now).
- [ ] [T] Backend test: tombstoned record is pulled + a stale re-push is skipped.

## Phase 12 — Wrap-up (spec §11)
- [ ] `flutter analyze` 0/0; `flutter test` green; `cd backend && npm test` green.
- [ ] Manual 1000-sub smoke (import TestData.backup, pw 1234; let the push settle).
- [ ] Adversarial review pass over the full diff (read-only agents; verify findings before fixing).
- [ ] `MILESTONES.md` v23 entry.
- [ ] `flutter build apk --release` (Flash API default).
- [ ] Change table for the user incl. the "reviewed, by design" list (spec §2.7, §4.5, §10).
- [ ] HOLD commit until user confirms → then commit + push (established message style).

## New translation keys introduced by this batch (add each to BOTH maps — grep before adding)
`report_failed`, `not_a_valid_backup`(?exists), `current_password`, `confirm_identity`,
`select_month`(?), `test_print`, `device_limit_msg`, `device_limit_recover_q`,
`unbind_current_warn`, `refunded`(?exists).
