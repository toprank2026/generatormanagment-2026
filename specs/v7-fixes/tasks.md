# Tasks — v7 Fix Batch

## W-BACKEND (agent, backend/ only)
- [ ] B1 `User.js`: role enum += 'accountant'; add `owner` (ObjectId ref User), `branchId` (String), `permissions` ([String]), `localId` (String, indexed).
- [ ] B2 `serialize.js`: include role, ownerId, branchId, permissions, localId.
- [ ] B3 `authController.login`/`me`: accountant path (bcrypt, no device limit, subscription/features from owner).
- [ ] B4 New `accountantAccountController.js` + routes `POST/GET/PUT/DELETE /api/account/accountants` (owner-scoped, requireAuth).
- [ ] B5 Effective-owner scoping in `syncController` (push/pull) + `accountController` (getMyData/getMyStats/getMyRecent).
- [ ] B6 Panel `index.html`: category column on `SYNC_COLUMNS.monthly_prices`; category_snapshot on receipts; `adminController.SEARCH_FIELDS.monthly_prices += 'category'`.
- [ ] B7 `API_CONTRACT.md` update; CLAUDE.md "SQLite version 6" doc fix.
- [ ] B8 Backend tests: accountant create/login/scoping; keep suite green.

## W-FLUTTER (main session)
### R9 / R6 — global month
- [ ] F1 New `lib/controllers/month_controller.dart` (permanent): `Rx<String> selectedMonth`, `setMonth`.
- [ ] F2 Register in `app_binding.dart`.
- [ ] F3 `DashboardController`: drop `currentMonth`/`changeMonth`; read shared month; `ever(month.selectedMonth)` → loadStats.
- [ ] F4 `BillingController`: drop `selectedMonth`/`changeMonth`; read shared month; `ever` → loadMonthPrice; getDueAmount/collectPayment/setPrice use shared month.
- [ ] F5 `core_controller.loadFilteredSubscribers`: read shared month.
- [ ] F6 `dashboard_screen.dart`: banner month pill → read-only (no InkWell/picker); keep no-pricing notice.
- [ ] F7 `monthly_pricing_screen.dart`: month picker → `month.setMonth`.
- [ ] F8 `subscriber_detail_screen.dart`: remove now()-reset; read shared month; picker read-only/removed.
- [ ] F9 `payment_history_screen.dart`: remove now()-reset; read shared month.

### R4 — required categories
- [ ] F10 `monthly_pricing_screen.dart`: `Form` + `TextFormField` validators (non-empty, numeric, > 0); `_saveAll` validates then saves all three; no partial save.
- [ ] F11 `BillingController.setPrices(Map<String,double>)` atomic helper (single dashboard refresh).
- [ ] F12 translations: validation keys (en+ar).

### R5 / R3 — tabs + FAB gating
- [ ] F13 `core_repositories.getAll`: optional `category` (named where).
- [ ] F14 `core_repositories.getByPaymentStatus`: optional `category` (append clause + positional arg in matching order).
- [ ] F15 `core_controller`: thread `category` through loadSubscribers/loadFilteredSubscribers/loadMore; store alongside `_currentQuery`.
- [ ] F16 `subscribers_screen.dart`: TabBar (All/Gold/Regular/Commercial) + reload on tab change (reset to page 1); FAB hidden when `filter != null`.
- [ ] F17 translations: `all_categories` (en+ar).

### R1 — board/circuit name validation
- [ ] F18 `core_repositories`: `BoardRepository.nameExists`, `CircuitRepository.nameExists(name, boardId, ...)`.
- [ ] F19 `core_controller`: addBoard/updateBoard/addCircuit throw `ValidationException('duplicate_board_name'|'duplicate_circuit_name')`.
- [ ] F20 `boards_screen.dart` / `circuits_screen.dart`: try/catch on ValidationException (red snackbar, keep dialog open).
- [ ] F21 translations: `duplicate_board_name`, `duplicate_circuit_name` (en+ar).

### R7 / R7b — branch switch clear+pull + loading
- [ ] F22 `SyncController.switchBranch(branch)`: online+canSync ⇒ push pending → deleteLocalData → pull → reload branches → set currentBranch → reload all controllers; offline ⇒ local switch + snackbar.
- [ ] F23 Blocking progress overlay widget (non-dismissible, status text) used for switch + large push/pull; wire dashboard pull-latest + push to it.
- [ ] F24 `branch_selector.openBranchSheet`: await switchBranch with the overlay.
- [ ] F25 Ensure reactive loaders don't fire against an emptied DB mid-switch (set currentBranch after pull).

### R8 — accountant app integration
- [ ] F26 `Account` model: role/ownerId/branchId/permissions/localId.
- [ ] F27 `AuthController.login`: handle accountant account (acting user id=localId, permissions, set branch, trigger pull).
- [ ] F28 Accountant creation: `AccountantRepository`/`SettingsController` also POST `/api/account/accountants` (online-gated) tied to selected branch; keep local identity row.
- [ ] F29 `accountants_screen.dart`: branch selector in create; require online; surface backend errors.
- [ ] F30 De-emphasize/route accountant login to the Login screen (the offline profile switch is no longer the primary path).

## Verify
- [ ] V1 `flutter analyze` 0 errors; `dart format`.
- [ ] V2 `flutter test` green (+ R2 regression test, category-filter test, board-name test, month-sync test).
- [ ] V3 `cd backend && npm test` green.
- [ ] V4 Adversarial review workflow over the diff; fix findings.
- [ ] V5 Device smoke: month sync (pricing→home→subscriber), branch switch loading, accountant login.
- [ ] V6 Commit + push; MILESTONES.md + report table.
