# Code Map — current state per requirement

Grounding for [spec.md](spec.md), from the read-only mapping pass. File:line refs are where each
change lands. (Two agent over-reaches — "expense_categories" and "districts" tables — are **not**
part of this spec; #4 is about *subscriber* categories.)

## R1 — show all
- `lib/controllers/core_controller.dart` — `itemsPerPage=6` (L35), `boardsPerPage=6` (L43), `circuitsPerPage=10` (L49); `loadMore*`.
- `lib/controllers/expense_controller.dart` — `expensesPerPage=10` (L26).
- List screens with scroll listeners: `subscribers_screen` (L46-52), `boards_screen` (L39-44), `circuits_screen` (L35-40), `expenses_screen` (L33-38).
- Repos already support `limit/offset` (`core_repositories.dart`); no schema change.

## R2 / R3 — dialog close + boards scroll
- `circuits_screen.dart` L124-140 — `onConfirm` calls `addCircuit(...)` then `Get.back()` **without await**.
- `boards_screen.dart` L255-277 — same; `GridView.builder` L100-108 inside `GetBuilder`, **no physics**.
- `core_controller.addCircuit` L213-227 is `Future<void>` (must be awaited).

## R4 — subscriber categories + pricing
- `core_models.dart` `Subscriber` L89-143 (no category).
- `billing_models.dart` `MonthlyPrice` L1-43 (PK `month|branchId`); `Receipt` (no category snapshot).
- `db_helper.dart` v5; subscribers + monthly_prices schemas.
- `billing_repositories.dart` `MonthlyPriceRepository.getByMonth` L20-33, `getCollectedSum` L152-173.
- `billing_controller.dart` `getDueAmount` L120-141, `collectPayment` L143-201, `setPrice` L55-66.
- `add_subscriber_screen.dart` (no category picker); `subscriber_detail_screen.dart`; `monthly_pricing_screen.dart`.

## R5 / R7 — socket exclusivity
- `core_models.dart` `Subscriber.circuitId`; `db_helper.dart` subscribers `_onCreate` L296-312 (no UNIQUE).
- `core_repositories.dart` `SubscriberRepository.getByCircuit` L262-278, `insert` L189-196, `update` L198-206.
- `core_controller.dart` `addSubscriber` L285-293, `updateSubscriber` L295-300.
- `add_subscriber_screen.dart` circuit dropdown L167-194, `_save` L264-306.
- Enforce: app validation + branch-scoped active-uniqueness triggers; migration deactivates dupes.

## R6 / R9 — monthly metrics
- `dashboard_controller.dart` L9-110 (`totalCollected`, `totalDue` for fixed `currentMonth`).
- `reports_controller.dart` L15-188 (expected/collected/remaining; has month nav).
- `billing_repositories.dart` `ReceiptRepository.getCollectedSum` L152-173 (month+branch scoped → Monthly Revenue).
- Cards: `dashboard_screen.dart` L291-375; `reports_screen.dart` L184-232. Labels: `translations.dart`.

## R10 / R11 — dashboard month + recalc
- `dashboard_controller.dart` `currentMonth` fixed at init; no `changeMonth`.
- `dashboard_screen.dart` L291-375 (no month picker).
- `billing_controller.dart` `setPrice` L55-66 (reloads price, **does not** refresh dashboard).
- Month-picker pattern to copy: `monthly_pricing_screen.dart` L36-92.

## R12 — manual date entry
- `showDatePicker` usages: `expenses_screen` L85-96, `monthly_pricing_screen` L75-86, `subscriber_detail_screen` L198-210.
- add-expense dialog `expenses_screen` L335-453 (no date field; uses `DateTime.now()`).
- `expense_controller.addExpense` L106-126; `expense_model.dart` date ISO8601.
- New widget under `lib/views/widgets/` (style base: `app_form_field.dart`).

## Backend + panels
- `backend/src/controllers/accountController.js` `buildDashboard` L55-145, `getMyStats` L156-178.
- `backend/src/controllers/adminController.js` `SEARCH_FIELDS` L170-179, `labelFor` L297-310.
- `backend/public/admin/index.html` `SYNC_COLUMNS.subscribers` L~1417-1421, `viewMyDashboard`, `viewMyReports`, `viewMyEntity`.
- `backend/src/utils/serialize.js`.
