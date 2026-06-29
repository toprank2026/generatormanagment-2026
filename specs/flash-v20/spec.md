# Flash v20 — ordering, receipt print, account editing, printer stability

Mandate: ONLY these 5 changes; no other behavior/logic/sync/subscription change.

## 1. Board ordering + smaller responsive cards
- Boards must ALWAYS show in creation order (oldest→newest), stable for Arabic
  names (current name-collation order is inconsistent for non-ASCII). Order by
  `created_at ASC` (id tiebreaker).
- Make board cards a bit smaller + responsive to screen dimensions.

## 2. Circuit (Jozة) ordering
- Circuits must show in creation order (oldest→newest), stable across languages.
  Same fix: order by `created_at ASC`.

## 3. Receipt printing improvements (Bluetooth + PDF)
- Remove the app LOGO from the printed receipt.
- Remove the PHONE NUMBER from the printed receipt.
- Remove unnecessary white space (shorter receipt).
- Slightly reduce the QR code size.
- New print setting: choose 1 or 2 COPIES per receipt (printer prefs + Settings UI
  + the print loop prints N copies).

## 4. Owner/Admin account editing
- Owner/admin can edit their account: username, password, (name/phone/generator).
  Backend self-update endpoint + Flutter edit screen in Settings. Keep auth rules.

## 5. Printer connection stability
- Before printing, ensure the Bluetooth printer is connected; auto-reconnect to
  the saved printer if dropped, with a short retry, so "sent to printer" always
  prints — no app restart needed.

## Delivery
Spec + read-only mapping + coupled edits (Flutter + backend) + adversarial review.
Then table, confirm Flash API, build APK.
