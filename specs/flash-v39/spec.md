# Flash v39 — Settlement month isolation + 3-card summary + 12-hour time display

## Owner request (verbatim summary)
Settlement Module Fixes (do not modify anything else):
1. **Settlement history** (Admin + Accountant) must display ONLY the settlements of
   the currently selected pricing month — completely isolated by month, exactly
   like the rest of the financial system.
2. **Total Settlement bug** — wrong display when selecting a month other than the
   current month in the Admin account.
3. **Unsettled Balance bug** — must be calculated for the selected month only.
4. **Monthly isolation of Total Settlement** — currently accumulates settlements
   from all months into the selected month.
5. **Admin settlement page UI** — top summary cards become exactly three:
   Total Settlement · Net Expenses · Net Profit. Keep the month + accountant
   filters. Change nothing else on the page.
6. **Time display format** — ALL displayed timestamps app-wide switch to the
   12-hour clock (AM/PM; ص/م in Arabic). Display-only: storage stays ISO.

Suitable modifications allowed in the owner panel + backend. Production users —
every change must be safe and backward-compatible.

## Root causes found (read-only mapping fleet, 5 agents)
- **App admin list "accumulates all months"**: `listAllForOwner`'s month clause is
  `(requested_at LIKE 'YYYY-MM%' OR status='pending')` — the v27 rule surfaces
  PENDING rows from EVERY month in every month view. The pending banner is also
  all-time (`pendingCount()`), reinforcing the impression.
- **Unsettled balance not month-scoped**: the `pending_settlement_balance` card and
  each per-accountant breakdown row use `wallet()` — an ALL-TIME balance — so any
  selected month shows today's holdings.
- **Per-accountant "last settlement" chip**: `history(limit:1)` all-time.
- **Owner panel Total Settlement drift**: `viewMySettlements` month-filters
  CLIENT-side with the browser's LOCAL timezone month (`new Date(...).getMonth()`)
  while the app buckets by the UTC `requested_at` prefix → boundary settlements
  land in different months panel-vs-app; plus rows are fetched unfiltered
  (25×200-row page cap) because the backend month param only works for expenses.
- **Already correct**: the app's Total Settlement card (`approvedSumForMonth`,
  requested_at UTC prefix) and Expenses card (date prefix) are month-scoped.

## Decisions
- **Strict isolation** (owner override of the v27 rule): pending settlements now
  appear ONLY in their request month, in both the app admin list and the panel.
  A pending request from an older month is decided by browsing to that month
  (banner + list are month-scoped consistently).
- **Month bucket for settlements** = UTC `requested_at` prefix `YYYY-MM` —
  the existing app convention; the panel is aligned to it.
- **Unsettled for month M** (per accountant, and Σ) =
  `max(0, Σ valid receipts cash of month M − Σ approved cash+card settlements requested in M)`
  — both sides month-scoped; clamped ≥ 0 (a settlement in M+1 covering M's cash
  shows M unsettled until then — stated trade-off of strict month isolation).
- **3 cards**: Total Settlement = Σ approved cash+card settlements of the selected
  month (the previous total_revenue figure, relabeled `total_settlements`);
  Net Expenses = month expenses (`net_expenses`, new key); Net Profit =
  Total Settlement − Net Expenses (`net_profit`, existing key). Panel cards
  relabeled to match (إجمالي التسويات / صافي المصروفات / صافي الربح).
- **Wallet balances stay ALL-TIME** (they are balances, not monthly totals) —
  My Wallet cards, `requestSettlement`, reversal locks, `hasPending` untouched.
- **12-hour display** via new `lib/utils/date_fmt.dart` (`fmtDateTime12`/
  `fmtTime12`), localized ص/م (`time_am`/`time_pm` keys); printed receipts use
  hardcoded ص/م (receipts are always Arabic). Panel `fmtDate` gets `hour12:true`.

## Out of scope / explicitly unchanged
Sync engine, decide(), lastActiveRequestAt + all settlement locks, hasPending,
wallet(), server wallet endpoint, My Wallet balance cards, pagination patterns,
every other screen. No schema changes; all new query params optional.
