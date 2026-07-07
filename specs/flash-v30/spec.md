# Flash v30 — Spec

Three features across the Flutter app, with suitable modifications to the owner/admin panel and backend. **Production-safe & additive**: no renamed/removed tables, columns, APIs, models, or SharedPreferences keys; safe non-destructive migrations only; no forced re-login/reinstall; offline + sync keep working; nothing outside these features changes.

## Feature 1 — Accountant Reports gauge (parity with Admin)

In the **Reports** screen of an **accountant** account, the top **gauge** must show the same three figures the admin/owner report shows:

- **Paid subscribers** — green.
- **Unpaid subscribers** — red.
- **Subscribers paid by the CURRENT accountant** — orange.

### Acceptance
- An accountant opening Reports sees a gauge/donut with the three segments (green paid, red unpaid, orange "paid by me this month").
- The orange figure counts DISTINCT subscribers the signed-in accountant collected from in the selected month (its own attribution).
- Paid/unpaid totals match the account-wide derived paid/unpaid for the month (same source as the owner report).
- Owner/admin reports are unchanged (they already show paid/unpaid; the orange "paid-by-accountant" only applies to the accountant view — or is 0/hidden for owner).
- No new stored status; figures derived from receipts + `accountant_id` attribution.

## Feature 2 — Receipt reversal (cancel a mistaken payment)

Allow **reversing/cancelling a receipt** for a subscriber marked paid by mistake (or any reason the accountant chooses).

### Behaviour
- Restores the subscriber to **unpaid** for that month (derived status flips back).
- Restores **all** related figures: collected sums, dashboard paid/unpaid counts, reports, per-accountant wallet collected, receipt history, and the mirror.
- Allowed **ONLY if the accountant's account has not yet been settled** (the collected cash backing that receipt hasn't been locked into an approved/pending settlement). Blocked with a clear message otherwise.

### Acceptance
- A "reverse/cancel receipt" action appears on a receipt (accountant-only, permission-gated), with a confirm dialog.
- After reversal: the subscriber shows unpaid for that month; paid count −1 / unpaid count +1; collected − receipt amount; wallet collected − receipt amount; the receipt no longer counts anywhere (voided/refunded/tombstoned per the chosen mechanism).
- Reversal is refused (snackbar) when the accountant is already settled per the agreed rule.
- The reversal syncs to the mirror; the panel reflects it.
- Reuses the existing refund/void mechanism if one exists (see plan.md after mapping).

## Feature 3 — Contact phone printed on receipt (instead of the footer)

In the **Admin** account **Settings**, add a **contact phone number** field. When set, the printed receipt prints this contact phone **instead of the footer** ("شكراً لكم!/Powered by Flash").

### Behaviour
- A settings input for the contact phone (admin/owner).
- All thermal transports (Bluetooth, USB, LAN — shared renderer) and the PDF receipt print the contact phone in place of the footer section when a phone is set; when empty, the existing footer prints (backward compatible).
- Surfaced in the **Printed Receipt Settings** screen, replacing the **footer** option there.

### Acceptance
- Setting a phone → receipts print the contact phone line instead of the footer; clearing it → footer prints as before.
- The Printed Receipt Settings screen exposes the phone (replacing the footer toggle/section).
- Owner/admin panel + backend get suitable modifications only if the phone must surface there (decided in plan.md).
- New strings added to BOTH `en_US` and `ar_AR` (translation-parity test stays green).

## Non-goals
- No change to the sync engine, existing schema semantics, or unrelated screens.
- No change to how the QR/public receipt works beyond what these features require.

## Verification
- `flutter analyze` 0 errors/0 warnings; `flutter test` green (incl. translation parity + any new tests); `cd backend && npm test` green if backend touched.
- Adversarial multi-agent review of the diff; fix confirmed findings.
- Live check of the reversal + gauge where feasible.
- Reconnect app to Flash API (default) + build release APK.
