# Flash v11 — wallet / payment-method / load-scope / print / accountant-link

Surfaces: Flutter app, backend, admin panel, owner panel.

## Decisions (from owner)
- **Load scope (3):** post-login pull downloads **only the current billing month** for receipts + payment-history; all other entities pull fully. Older-month receipts download on demand when the month is switched online.
- **Settlement reset (1):** approving a settlement **subtracts the requested amount** (balance = Σ collected cash − Σ approved settlement amounts); cash collected after the request stays in the wallet.

## Requirements
1. **Accountant Wallet ("My Wallet")**
   - A receipt collected by an accountant adds its **cash** (`paid_amount`) to that accountant's wallet.
   - New **My Wallet** page under **Settings** (separate screen) showing the accountant's total collected (the current balance).
   - Wallet is per-accountant, synced like other accountant data.
   - **Request Settlement** button → creates a **pending** settlement for the current balance.
   - Owner approves it from the **Owner Panel** → settlement becomes **approved**; balance drops by the approved amount.
   - **Settlement history** (paginated), stored/synced like other accountant data.
   - **Design:** new synced entity `settlements` `{uuid, accountant_id, amount, status: pending|approved, requested_at, approved_at, branch_id}`. Balance = `Σ receipts.paid_amount (accountant_id=me, status=valid) − Σ settlements.amount (accountant_id=me, status=approved)`. Owner approval is a **server-side mirror write** (`POST /api/account/settlements/:id/approve`, owner-authed, ownership-checked) that the accountant **pulls** down.
2. **Payment Method** — `Cash` / `Credit Card` on every receipt: collect-dialog selector → `receipts.payment_method`; shown in reports, on printed receipts (Bluetooth + PDF), and in the QR/public receipt + SPA.
3. **Load scope** — see decision above (current-month receipts/history only after login).
4. **Print twice** — emit the receipt **two copies** in one print op (Bluetooth: repeat body + cut/feed; PDF: two pages).
5. **Accountant data association** — every accountant-created row (expenses, subscribers/boards/circuits if they create them, receipts, refunds, settlements) stamps `accountant_id`; synced, pulled after login, and wiped/kept on logout via the same mechanism. Audit + fix any entity that doesn't.
6. **Accountant creation = name + phone + password** — create accountants like branch/owner accounts (phone is the login username), instead of the current name+username+branch+permissions form.

## Non-goals / residual
- No partial-receipt settlement (a settlement clears against the running balance). No multi-currency.
