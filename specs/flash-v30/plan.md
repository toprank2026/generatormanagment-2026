# Flash v30 — Plan (from 14-facet map + synthesis)

No SQLite version bump (stays v13). F2 reuses `receipts.status 'valid'|'refunded'`; F3 is a remote account field. All translation keys go into BOTH `en_US` and `ar_AR` last (parity tests).

## Decisions (locked)
- **F1 orange semantics:** accountant paid/unpaid become **branch-wide** (drop `receiptAccountantId`); add `paidByMe` (collector-scoped paid count). Donut = 3 mutually-exclusive segments: green `paid_by_others` (= paidCount − paidByMe), orange `paid_by_me` (= paidByMe, only when >0), red `unpaid_subscribers`. centerText = paid+unpaid (total). Money figures stay personal.
- **F2 mechanism:** soft void — flip `status` `valid`→`refunded` via full `Receipt.toMap()` (re-stamps `updated_at`; one clean sync upsert). No delete (preserves receipt_no sequence + audit). Every money/paid-unpaid/wallet/dashboard/report aggregate already filters `valid`, so a flip auto-restores.
- **F2 guard ("not yet settled"):** allow iff `r.accountantId != null` AND no PENDING settlement on the receipt's wallet method AND `wallet(r.accountantId).<method>Balance >= r.paidAmount` (method = `paymentMethod=='card'?'card':'cash'`). Accountant-only, own receipts. Silent no-op at the controller choke point for non-accountants; `reverse_blocked_settled` snackbar when the guard fails.
- **F3 storage:** account-synced owner-level `contactPhone` (new nullable `User` field, non-unique), injected into accountant sessions in login + me (like `generatorName`). Editable in Printed Receipt Settings (admin/owner only; read-only for accountants). Keep `sec_footer` as the master footer toggle; when `contactPhone` non-empty, print the phone line INSTEAD OF the footer at all print sites (empty → existing footer; backward compatible).
- **F2 audit row (refunds table):** deferred/severable — the status flip fully restores stats. Ship v1 with the flip.
- **F3 on public/QR receipt + panel:** deferred (print-only per the request). The synced field makes it trivial later.

## Edit list
### Feature 1 — accountant gauge
- `lib/controllers/reports_controller.dart` — add `paidByMe`; branch-wide paid/unpaid; compute paidByMe (collector-scoped); commit atomically.
- `lib/views/screens/reports_screen.dart` — 3-segment donut.
- `lib/utils/translations.dart` — `paid_by_me`, `paid_by_others`.

### Feature 2 — receipt reversal
- `lib/data/repositories/billing_repositories.dart` — `getByUuid`, `markRefunded`.
- `lib/controllers/billing_controller.dart` — `reverseReceipt(r)` with guard + reloads.
- `lib/views/screens/payment_history_screen.dart` — reverse action (accountant + valid only), confirm dialog (close-first), reload; localize the refunded badge.
- `lib/utils/translations.dart` — `reverse_receipt`, `reverse_receipt_title`, `reverse_receipt_confirm`, `receipt_reversed`, `reverse_blocked_settled`.
- `backend/public/admin/index.html` — receipts `status` column + localized badge (valid/refunded/deleted); localize raw `refunded` in receipt detail/statement/public views.

### Feature 3 — contact phone on receipt
- `backend/src/models/User.js` — `contactPhone` (nullable, non-unique).
- `backend/src/controllers/accountController.js` — `updateMyProfile` handles `contactPhone` (no uniqueness).
- `backend/src/utils/serialize.js` (serializeAccount) — emit `contactPhone`.
- `backend/src/controllers/authController.js` — inject `owner.contactPhone` in accountant login + me.
- `lib/data/models/account.dart` — `contactPhone` field (ctor/fromJson/toJson).
- `lib/data/repositories/auth_repository.dart` — `updateProfile(contactPhone)`.
- `lib/controllers/auth_controller.dart` — `updateProfile(contactPhone)` forward.
- `lib/views/screens/print_receipt_settings_screen.dart` — contact-phone input (admin editable / accountant read-only).
- `lib/utils/bluetooth_print_service.dart`, `lib/utils/usb_print_service.dart` (covers LAN), `lib/utils/pdf_service.dart` — print phone instead of footer.
- `lib/utils/translations.dart` — `contact_phone`, `contact_phone_hint`.

## Risks / gotchas
- Sync: F2 must write via `Receipt.toMap()` (re-stamps `updated_at`) or last-edit-wins may drop it. Don't touch sync triggers.
- Obx: reverse button + admin-gated phone field must read an observable inside the `Obx` (grey ErrorWidget otherwise).
- Dialog: close (rootNavigator pop) BEFORE the async reverse; snackbar AFTER.
- F3 propagation: MUST inject `owner.contactPhone` into accountant sessions or accountant-printed receipts show the footer.
- Test parity: all 9 new keys in BOTH maps.
- Panel: refunded receipts otherwise look live (add status column + Arabic label).
