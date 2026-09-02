# Flash v44 — Correction settlement rules (the customer owes the difference)

## 0. The decision you asked me to make

You gave two candidate workflows and asked which is better for the current
structure and the future. **The new rules are better than v43's, and I am
adopting them.** Here is why, and how the two candidates actually fit together.

### Why the new model is better

v43 treated an approved **increase** as cash the accountant had collected — it
added the difference straight to the accountant's wallet. But nobody had
handed over any money. The adversarial review flagged exactly this ("a due
difference booked as cash: credits a wallet with cash nobody received"). The
new rule fixes it at the root: an increase makes the **customer owe the
difference**, and money enters the wallet only when a **real receipt** is
issued for it. No phantom cash, no parallel money path.

### "New tab" vs "edit the status" — it is not either/or

- **Paid/unpaid is DERIVED in this system, never stored** (coverage >= due).
  That is a core architectural invariant and it must stay that way. So the
  "status" half is not something anyone *edits* — once the approved increase
  is folded into that month's DUE, the customer becomes unpaid for the
  difference **automatically**, and becomes paid again the moment a receipt
  covers it. This is the accounting core and it is mandatory.
- **The tab is the visibility layer**, not the mechanism. Without it a
  correction is only visible from Settings. It belongs on the existing
  **Subscribers screen** as one more tab beside the category tabs (the pattern
  already there), **not** a new Home tab — Home is the dashboard.
- **Wallet settlement needs no new mechanism for increases.** The difference is
  collected with an ordinary receipt for that month, which flows into the
  accountant's wallet exactly as every receipt does today. That REMOVES v43's
  special-case credit path rather than adding one.

So: **status behaviour (mandatory, automatic) + a Corrections tab on the
Subscribers screen (visibility) + the existing receipt/wallet flow (money)**.

## 1. Rules

After an admin approves a correction for a customer's month:

| Case | Customer | Money |
|---|---|---|
| **Increase** | becomes **unpaid** for the difference; it is added to that month's outstanding balance | enters the wallet only when a **receipt** is issued for it (ordinary cashier flow) |
| **Decrease** | **remains paid**; the difference is recorded and displayed as a **credit** | settled by a physical **refund** (existing `refund_due -> completed`) **or carried forward** to reduce the next month's due |
| any | the original receipt and accounting record are **never** altered | corrections are tracked separately, linked to the same customer + month |

## 2. What changes in the money rule (app + backend, kept in lockstep)

`financial_adjustments.kind` contributions:

| kind | v43 (wallet) | **v44 wallet/collected** | **v44 customer DUE** |
|---|---|---|---|
| `correction_increase` | + amount | **0** | **+ amount** for the corrected month |
| `correction_decrease` | 0 | 0 | 0 (customer stays paid at the invoiced due) |
| `refund_return` (negative) | + amount | + amount (owner cash out) | 0 |
| **`credit_applied`** (new) | — | 0 | **− amount** for its `month` (the target month) |

Consequence: an accountant's wallet is again exactly **receipts − settlements**.
The correction's cash arrives as a real receipt. `getCollectedSum` and the
owner dashboard fold only `refund_return`.

**No schema change.** `credit_applied` rides in the existing
`financial_adjustments` table (`month` = the month the credit is applied to);
`carried_forward` is a new value in the existing TEXT `status` column of
`corrections`. SQLite stays at **version 16**.

🚨 **Mixed-fleet rollout rule (found by the adversarial review — the earlier
"fail-open" claim was wrong).** A **v43** APK is NOT fail-open for the new
values: its `adjustmentTotal` treats every kind except `correction_decrease` as
positive cash (so it books a pulled `credit_applied` row as **collected**), and
its `normalize()` maps `carried_forward` to **pending** (so it shows a closed
correction with Approve/Reject buttons). Nothing retroactive can fix shipped
binaries. **Update every device of an account to v44 BEFORE the first
carry-forward on that account.** v42 APKs (no corrections tables at all) are
unaffected.

## 3. Due derivation

`DbHelper.correctionDueDelta()` — one shared SQL expression, like
`effectiveAmps`: Σ approved increases − Σ credits applied, for `(s.id,
mp.month)`. Takes no bind parameter (reads `mp.month`), so it drops into every
raw money query without disturbing positional args. Folded into: paid/unpaid,
remaining, board summary, arrears (`previousUnpaidMonths`), and the Dart
`getDueAmount` twin. The corrected month keeps `effectiveAmps` (frozen basis)
**plus** the delta.

## 4. Surfaces

- **App / Subscribers screen**: new **Corrections** tab (this month): name,
  old → new amps, difference, settlement status
  (`awaiting approval` / `unpaid difference` / `paid` / `credit` / `refunded` /
  `carried forward` / `rejected`).
- **App / Corrections screen**: at `refund_due`, a second action **Carry
  forward** beside **Record cash returned**.
- **Backend**: `POST /api/admin/corrections/:id/carry-forward`; wallet +
  dashboard mirror the new rule; list returns `settlementStatus`.
- **Panel**: carry-forward button, new status, settlement-status column.

## 5. Backward compatibility

Production runs v42 (verified: the deployed panel has no `corrections`
markers), so **no approved correction exists in any production mirror**. The
money-rule change therefore rewrites nothing real. A device that tested v43
locally holds test rows only.
