# Spec — Generator Management Enhancements (v6)

**Status:** Draft for approval · **Schema target:** SQLite v5 → **v6** · **Surfaces:** Flutter app · Backend (Node/Mongo mirror) · Admin panel · Owner panel

This Spec-Kit covers the 12 requested modifications. It is **additive** and follows the
established pattern (accountants → multi-branch): bump the SQLite version, migrate legacy
data forward with safe defaults, let whole-row sync carry new columns automatically, and
thread new optional params through repos → controllers → backend → panels.

References below are grounded in the read-only code map (`specs/enhancements/MAP.md` is the
raw agent output; key files are cited inline).

---

## Requirements & acceptance criteria

### R1 — Remove the 6-item display cap (show all)
Lists currently cap at 6 (subscribers, boards) / 10 (circuits, expenses) via
`core_controller.dart` (`itemsPerPage=6`, `boardsPerPage=6`, `circuitsPerPage=10`) and
`expense_controller.dart` (`expensesPerPage=10`).
**Accept:** every list screen shows **all** rows for the active scope; scrolling reaches the
last item. Pagination machinery is kept but the page size is effectively "all".

### R2 — Add-socket (جوزة) dialog must always close
`circuits_screen.dart` add dialog calls `controller.addCircuit(...)` then `Get.back()`
**without awaiting** — the dialog can close before/independently of the write, and on slow
writes appears stuck. Same shape in `boards_screen.dart`.
**Accept:** the dialog awaits the write, then closes exactly once; a failure surfaces an error
and keeps the dialog open.

### R3 — Boards screen scrolling
`boards_screen.dart` `GridView.builder` is wrapped in `GetBuilder` with no explicit physics →
scroll can be swallowed.
**Accept:** the boards grid scrolls smoothly to the last board on a full screen.

### R4 — Three subscriber categories with independent pricing
Add a **category** to every subscriber — **Commercial (shops)**, **Standard**, **Gold (24h)** —
each with its **own price per amp per month**. Today a subscriber has only `amps` and there is a
single `monthly_prices.price_per_amp` per (month, branch).
**Accept:** each subscriber has a category; the owner can set a separate price-per-amp for each
of the 3 categories per month (per branch); a subscriber's bill = `amps × price[category, month]`.

### R5 — Assigning a socket makes it unavailable
When a subscriber is assigned a socket (جوزة/circuit), that socket can no longer be picked for
another subscriber.
**Accept:** the circuit picker in add/edit subscriber hides (or disables) circuits already held
by an active subscriber.

### R6 — Monthly Revenue & Monthly Remaining Fees (per month)
Add two metrics, computed and shown **separately for each month**:
- **Monthly Revenue** = Σ paid_amount of `valid` receipts in the month (active branch).
- **Monthly Remaining Fees** = expected(month) − Monthly Revenue, where expected is
  **category-aware** (Σ over subscribers of `amps × price[category, month]`).
**Accept:** both values appear on the dashboard and reports, tied to the selected month.

### R7 — One socket ↔ one subscriber (no duplicates, even same board)
A circuit may belong to **at most one active subscriber**, including within the same board.
**Accept:** attempting to assign an already-held circuit is rejected with a clear message;
the data layer enforces it (validation + DB guard); existing duplicates are resolved by the
v6 migration.

### R8 — No duplicate subscriber names
**Accept:** creating/renaming a subscriber to a name that already exists (same scope, see D8) is
rejected with a clear message.

### R9 — Revenue & Remaining are month-linked
**Accept:** R6's two metrics recompute for whatever month is selected (no hard-coding to "now").

### R10 — Price change recalculates dashboard Collected/Remaining
Today `BillingController.setPrice()` reloads the price but does **not** refresh the dashboard.
**Accept:** after changing a price, the dashboard's Collected/Remaining update automatically
(no manual refresh) for the affected month/category.

### R11 — Month selector on the dashboard
`DashboardController.currentMonth` exists but is fixed at init; there's no picker.
**Accept:** the dashboard has a month picker; all pricing/revenue/remaining figures bind to it.

### R12 — Manual date entry alongside the picker
The 3 month selectors (expenses, monthly pricing, subscriber detail) and the add-expense dialog
use `showDatePicker` only.
**Accept:** the user can type a date (validated) in addition to using the picker.

---

## Decisions (D1–D12) — **need your confirmation**

| # | Decision | Recommended default |
|---|----------|---------------------|
| **D1** (R1) | Show-all vs larger paged | **CONFIRMED: Large pages + infinite scroll** — raise page sizes to ~100 and keep the fetch-+1/`loadMore` machinery so scrolling loads the rest. Safe at scale; effectively "all" for normal data sizes. |
| **D2** (R4) | Category storage + pricing key | **CONFIRMED (per-amp per category).** `subscriber.category` = enum string `commercial\|standard\|gold` (default **standard**). `monthly_prices` PK becomes `"<month>\|<branchId>\|<category>"` (3 price-per-amp rows per month/branch). Bill = `amps × price[category]`. |
| **D3** (R4) | Historical accuracy | Add `receipts.category_snapshot` so past receipts keep the category in force at payment time (reports stay correct if a subscriber's category later changes). |
| **D4** (R7/R5) | Socket exclusivity scope | **At most one *active* subscriber per circuit, scoped to the branch**. `inactive`/deleted subscribers free the circuit. |
| **D5** (R7) | Edit onto an occupied circuit | **Block** with "هذه الجوزة مستخدمة من قبل <name>" (no silent reassignment). |
| **D6** (R7) | Legacy duplicates at migration | Keep the **most-recently-created** active subscriber on each over-subscribed circuit; set the others `status='inactive'` (logged). |
| **D7** (R8) | Duplicate-name enforcement | App + repo validation (case-insensitive, trimmed). **No hard DB UNIQUE** (would break whole-row pull/REPLACE sync); use a fast index + reject-before-insert. |
| **D8** (R8) | Name uniqueness scope | **CONFIRMED: Per branch** (matches full-isolation). Case-insensitive, whitespace-trimmed. |
| **D9** (R11) | Dashboard month default | Defaults to **current month** on each open; picker lets you move; independent of BillingController's month. |
| **D10** (R10) | Recalc trigger | `setPrice()` calls `DashboardController.loadStats()` if registered → instant recalc. |
| **D11** (R6/R9) | "Category-aware expected" | Expected = Σ `amps × price[subscriber.category, month]` (uses the real R4 categories — not boards). |
| **D12** (R12) | Date formats | Reusable `DateField` widget: month selectors accept `yyyy-MM`; add-expense accepts `yyyy-MM-dd`; numeric only (bilingual-safe); picker icon retained. |

---

## Data model — v5 → v6 (one migration)

`lib/data/db_helper.dart`: bump `version` 5 → 6; add `if (oldVersion < 6)` branch.

1. **subscribers**: `ADD COLUMN category TEXT` (default `'standard'`). Backfill existing rows to
   `'standard'`. (Models: `Subscriber` gains `category`.)
2. **monthly_prices**: reshape synthetic PK `"<month>|<branchId>"` → `"<month>|<branchId>|<category>"`;
   `ADD COLUMN category TEXT`. Backfill: existing price row → `category='standard'`
   (`id = month|branch|standard`). Commercial/Gold prices start unset until the owner enters them.
   (Model: `MonthlyPrice.buildId(month, branchId, category)`.)
3. **receipts**: `ADD COLUMN category_snapshot TEXT` (nullable; stamped at collection time).
4. **circuit exclusivity (R7)**: no new column — enforced by `BEFORE INSERT/UPDATE` triggers on
   `subscribers` (ABORT when another `status='active'` subscriber in the same `branch_id` holds the
   `circuit_id`). Migration first **deactivates legacy duplicates** (D6) so the trigger can be added.
5. **duplicate names (R8)**: no hard constraint (D7); keep the existing name index; migration leaves
   legacy duplicate names as-is (validation only blocks *new* collisions) — flagged in MAP.

Sync: `sync_outbox` triggers + `syncedTables` already push whole rows, so the new columns ride
along automatically. The reshaped `monthly_prices` rows re-enqueue on migration (accepted flood,
same as v5). No sync-engine change.

---

## Surfaces affected (summary)

- **Flutter:** `core_controller`, `billing_controller`, `dashboard_controller`, `reports_controller`,
  `expense_controller`; repos `core_repositories`, `billing_repositories`; models `core_models`,
  `billing_models`; screens `subscribers/boards/circuits/expenses/dashboard/reports/add_subscriber/
  subscriber_detail/monthly_pricing`; new `DateField` widget; `db_helper`; `translations`.
- **Backend:** `accountController.buildDashboard/getMyStats` (category-aware expected + the two
  monthly metrics), `serialize`, `adminController` (`SEARCH_FIELDS`/`labelFor` + category).
- **Admin panel & Owner panel** (`backend/public/admin/index.html`): subscribers table gains a
  **category** column; monthly-pricing surfaces 3 category prices; reports/home show Monthly Revenue
  & Remaining for the selected month.

## Out of scope / non-goals
- No per-category *pricing UI redesign* beyond 3 inputs per month.
- No expense-categories or districts tables (those were agent over-reach, not requested).
- Search debouncing, App Bundle, and release signing are tracked separately.
