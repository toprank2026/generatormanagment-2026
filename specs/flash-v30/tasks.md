# Flash v30 — Tasks

## F1 — accountant gauge
- [ ] reports_controller: `paidByMe` + branch-wide paid/unpaid + compute + atomic commit
- [ ] reports_screen: 3-segment donut (paid_by_others / paid_by_me / unpaid)
- [ ] translations: paid_by_me, paid_by_others

## F2 — receipt reversal
- [ ] billing_repositories: getByUuid, markRefunded
- [ ] billing_controller: reverseReceipt(r) + settlement guard + reloads
- [ ] payment_history_screen: reverse action + confirm (close-first) + refunded badge label
- [ ] translations: reverse_receipt, reverse_receipt_title, reverse_receipt_confirm, receipt_reversed, reverse_blocked_settled
- [ ] panel: receipts status column + localize refunded

## F3 — contact phone
- [ ] backend User.js: contactPhone
- [ ] backend accountController updateMyProfile: contactPhone
- [ ] backend serialize serializeAccount: contactPhone
- [ ] backend authController: inject owner.contactPhone (login + me)
- [ ] account.dart: contactPhone
- [ ] auth_repository.updateProfile: contactPhone
- [ ] auth_controller.updateProfile: contactPhone
- [ ] print_receipt_settings_screen: contact-phone input (admin edit / accountant read-only)
- [ ] bluetooth/usb(+lan)/pdf: print phone instead of footer
- [ ] translations: contact_phone, contact_phone_hint

## Verify
- [ ] flutter analyze 0/0
- [ ] flutter test (parity + repos)
- [ ] backend npm test
- [ ] adversarial review + fixes
- [ ] change table + Flash API + release APK
