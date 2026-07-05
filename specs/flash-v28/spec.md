# Flash v28 — receipt redesign, salary-once-per-month, panel parity, expenses collapse, per-receipt cut

Production-safe / additive. Do not change anything outside these items.

## A. Printed-receipt redesign (ALL thermal transports: Bluetooth + USB + LAN)
1. **QR mandatory** — always print the QR; remove the `sec_qr` toggle from the print-settings
   page and drop its gate in both renderers (QR always emitted).
2. QR size reduced slightly (USB/LAN 160→140; BT 160→140).
3. QR inside a **rounded-corner square frame** (drawn border with rounded corners).
4. QR **separated from the table** by a blank feed / spacing.
5. **App logo** (`images/blue.png`) rendered next to the QR.
6. Beside the logo, a vertical column: **"تطبيق"** over **"flash"**.
7. Logo small + reasonable.
8. Clear spacing between QR, logo and text.
9. **Expressive icon per section** — prepend a Material-icon glyph to each printed table
   row label (station/receipt/date/subscriber/month/board/circuit/amps/price/category/
   paid/method/discount/remaining/accountant), rendered via TextPainter with the icon
   font (works on both the BT image-rows and the USB/LAN raster rows).
10. Applied to BT + USB + LAN identically (shared visual construction; PDF untouched —
    spec names the thermal transports).
11. **Rounded-corner table** — the receipt data table (the bordered 2-column rows) gets
    rounded outer corners (draw the outer border as a rounded rect instead of straight
    row borders) on both the BT `_printTableRow` and USB/LAN `_tableRowImage` renderers.

## B. Salary settlement — once per accountant per month
11. An accountant may request a **salary** settlement at most ONCE per calendar month.
12. After the owner APPROVES it, the salary card's button for that accountant shows
    **"تم استلام الراتب"** (disabled) for the current month.
13. Enforced in the controller + repo: block a new salary request when a
    pending-OR-approved salary settlement already exists for the accountant this month
    (`requested_at` prefix). New repo `salaryStatusForMonth(accountantId, month)`.

## C. Owner panel parity (settlements + recent features)
14. `backend/public/admin/index.html` settlement views: show the **salary** method label,
    approve salary with an **amount prompt** (owner enters the salary on approval), and
    reflect the app's month/accountant filtering + the collected/salary/net summary where
    the panel already renders settlements. Additive display; the backend mirror stays the
    source of truth (no sync-engine change).

## D. Expenses screen — collapsing header (Sliver)
15. Convert the "إضافة المصاريف"/expenses header (blue total container) to a
    `SliverAppBar` that shrinks its height (total + month) as the list scrolls, then the
    accountant filter + quick-add + list follow as slivers. Same data/behavior.

## E. USB/LAN AutoCut per receipt
16. When printing 2 copies over USB or LAN, emit `cut()` after EACH copy (currently one
    cut at the very end) so each receipt is cut separately. (BT has no programmatic cut —
    unchanged.)

Meta: analyze 0/0; flutter test green (parity for new keys); backend npm test green if
touched; adversarial review; MILESTONES; change table; Flash API; release APK; commit HELD.
