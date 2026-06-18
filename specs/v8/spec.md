# Spec — v8 batch (Moldati Owner)

Owner requirements (verbatim, formulated in English; nothing added/removed/changed):

1. **Stop adding boards from the circuit screen.**
2. **In the reports screen the ampere price appears only for the normal tariff — make it appear for the commercial and golden tariffs as well.**
3. **Fix the update and data upload problem.**
4. **When logging out, local data is deleted first; when logging in, data is automatically fetched from the backend.**
5. **Discount feature** — add a discount inside the subscriber payment interface. The discount is applied **only when full payment is selected** (not for partial). No existing system behavior is changed; only this condition is added.
   - **Ampere-based discount:** enter the number of amperes to discount; the value is computed automatically from the ampere price (e.g. subscriber has 5 A, 2 A discounted → pays for 3 A, considered fully paid).
   - **Value-based discount:** enter the discount amount directly; it is deducted from the total invoice; the subscriber pays the remaining amount and is considered fully paid.
   - **Printed receipt:** add a "Discount" section — if a discount is applied show its type and value; if none, show "No discount".

Also: make the suitable modifications to the **backend, admin panel, and owner panel**.

## Decisions

### P1
`BoardsScreen` is reused with `forCircuits: true` for the circuit flow; the add-board FAB (`boards_screen.dart:65-80`) is gated only by `auth.can(Perm.boards)`. Change the gate to `!widget.forCircuits && auth.can(Perm.boards)` so a board can no longer be added from the circuit screen, while normal board creation elsewhere is unaffected. Circuits screen unchanged.

### P2
`pricesForMonth(month, branchId)` already returns `{category: price}` and is already fetched in `reports_controller.loadReport`. Keep `pricePerAmp` (standard) for the existing "no price" banner + expected-total math; add `goldPrice`/`commercialPrice` Rx populated from the same map. In `reports_screen.dart` replace the single price card with **three** cards (Gold / Regular / Commercial) via `_buildStatCard` using existing `cat_gold`/`cat_standard`/`cat_commercial` labels.

### P3 (do NOT change the sync engine — outbox/triggers/drain/seq logic stays)
Stuck "N pending" is caused by failures that strand the outbox with no recovery, and a latch bug. Fixes (wrapper-level only):
- **`_askOpen` latch:** if the >100 large-upload dialog is back-dismissed, `_askOpen` never resets and ALL future auto-syncs are blocked. Reset `_askOpen=false` on any dialog close (`.then`).
- **Surface push failures meaningfully:** in `syncNow`, catch typed `ApiException` — a plan/feature/auth rejection (403/`FEATURE_DISABLED`) shows a clear, non-transient message instead of silently retrying forever; transient network errors stay quiet-with-retry (offline-first).
- Keep `push()`/`pull()`/`deleteLocalData()` engine code unchanged.

### P4
Add `logout({String? reason, bool wipeLocal = false})`. **User-initiated** logout buttons (home, settings) call `wipeLocal: true`: push pending first (best-effort, online), then `SyncService.deleteLocalData()`, then clear the session. Involuntary logouts (offline-too-long, session-expired, recheck) and the **settings restore flows** keep `wipeLocal:false` (they must not erase freshly-restored data / can't re-pull offline). On successful **owner/admin login**, auto-pull (mirror the accountant path: `SyncController.pull(silent:true)` + `BranchController.reloadAndActivate`). Login already requires network, so the pull always has connectivity.

### P5 — discount (storage model)
"Fully paid" today = `SUM(paid_amount) >= amps×price`. A discount lets the subscriber pay less but still be fully paid, so the waived amount must be counted as **coverage**, not as cash.
- **DB v6→v7** on `receipts`: `discount_type TEXT` (`none`|`ampere`|`value`), `discount_value REAL DEFAULT 0` (IQD waived), `discount_amps REAL` (nullable, ampere-type audit). `_onCreate` + `_onUpgrade(<7)` branch (idempotent `_addColumn`).
- **Receipt model:** `discountType`/`discountValue`/`discountAmps` + toMap/fromMap.
- **collectPayment:** discount applies only on **full payment**. ampere: `discountValue = discountAmps × pricePerAmp`; value: entered amount. Cash paid = `due − discountValue`; `remainingAfter = 0`; record the discount fields. Partial payment forces `discount_type='none'` (enforced in the controller, not just UI). Relax the overpay guard to `amount + discountValue <= due`.
- **Coverage (two places, kept in lockstep):**
  - `getDueAmount`: `paid = Σ(paidAmount + discountValue)` → discounted-full shows due 0.
  - `getByPaymentStatus`: inner sum adds `discount_value`; predicate compares `paid + discount` vs expected. Non-discount rows (`discount_value=0`) are unchanged.
- **Cash unaffected:** `getCollectedSum` (dashboard Collected/Revenue) stays `Σ paid_amount` — a discount is waived, not collected.
- **UI (both collect dialogs):** a Full/Partial selector; on Full reveal a discount type toggle (None / Ampere / Value) + input, with a live "to pay" amount; on Partial, discount hidden. Pass discount through only on Full.
- **Print (Bluetooth + PDF):** add a "Discount" row — type + value, or "No discount".

### Backend / panels
- Mirror is whole-row push-only → `discount_*` columns ride along automatically (no SyncRecord change).
- `accountController.buildDashboard`: keep `collected = Σ paid_amount` (do **not** add discount). Fold discount into the **due side** so the panel matches the app: a subscriber is paid when `Σ(paid_amount + discount_value) >= due`, and `remaining = expected − collected − Σ discount_value`. Add `categoryPrices` (the per-category price map, already computed) to the dashboard payload for P2.
- `index.html`: add a **Discount** column to `SYNC_COLUMNS.receipts` + a discount row in `receiptDetailContent` (covers admin + owner). Reports view: render **3 tariff price** cards from `categoryPrices` (fallback to `pricePerAmp`).

## Verification
`flutter analyze` (0 errors/new warnings), `flutter test` (+ new tests: discount coverage in getByPaymentStatus, discount in getDueAmount, v7 migration smoke), `cd backend && npm test`. Adversarial review of the diff. Device smoke on Tikrit: reports 3 prices, discount full-payment flow + printed receipt, logout-clears/login-pulls, pending uploads.
