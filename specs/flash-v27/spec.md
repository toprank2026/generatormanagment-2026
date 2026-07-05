# Flash v27 (user "M22") — 7 additive enhancements

**Production safety (verbatim constraints):** additive only; 100% backward compatible;
no renames/removals of tables/columns/APIs/models/prefs keys; DB changes = safe
non-destructive migrations only; no reinstall/re-login required; offline+sync must keep
working; nothing outside the requested features changes.

1. **Board total-amps summary** — board-scoped subscriber list gets a summary card on
   top: ⚡ "إجمالي أمبيرات البورد: N أمبير", computed by ONE SQL SUM over the board's
   subscribers (new additive repo aggregate), branch-scoped, refreshed with the list.
2. **Expense amount input UX** — live thousands-separator formatting while typing
   (new reusable `ThousandsInputFormatter`) + quick buttons `+00 / +000 / +0000`
   (append zeros = ×100/×1000/×10000) beside the amount field. Parse sites strip
   separators. Expenses entry only — no other amount field changes.
3. **Third wallet: طلب تسوية راتب (salary)** — settlements.method gains value
   `'salary'` (TEXT column already free-form — NO schema change). Accountant requests
   a salary settlement with NO amount (amount=0, pending); admin approval REQUIRES
   entering the salary amount first (approve dialog with amount input → row amount +
   status update, syncs as a normal whole-row push). Wallet page gets the third card
   with the SAME workflow (request/status/history); all wallet cards get shorter +
   responsive (phone/tablet). Owner panel: settlement rows show a method label incl.
   راتب; its approve action prompts for the amount when method==='salary'.
4. **Report labels (again, everywhere in reports)** — collected-cash figure:
   "صافي الربح" → **"الوارد الكلي"**; net figure: "الإيرادات المحصلة" → **"صافي الربح"**.
   App keys `collected_revenue`/`net_profit` values swapped accordingly (both maps) +
   the owner-panel report bars/cards.
5. **Optional note for CARD payments** — collect dialog shows an optional "ملاحظة"
   field ONLY when payment method = بطاقة. Stored in a NEW nullable
   `receipts.payment_note` column (SQLite **v13 migration**: `_onCreate` + idempotent
   `_addColumn` upgrade branch — rides the whole-row sync with zero backend change).
   Shown in the payment-history rows and the admin-panel receipt detail (staff-facing
   surfaces only). **NEVER printed** on any receipt (BT/USB/LAN/PDF) and never in any
   subscriber-facing output.
6. **Monthly settlement improvements** —
   (a) Accountant wallet history: defaults to the CURRENT month + a month selector
   (chevron month nav, numeric yyyy-MM); (b) Admin settlements screen: month filter
   (default current) + accountant filter (all/each) — repo `listAllForOwner` gains
   additive optional `month`/`accountantId` params; (c) Responsive summary banner
   (icons, container, phone/tablet sizing, SafeArea list below) showing
   إجمالي الإيرادات المحصلة (collected sum for month+scope), حالة استلام الراتب
   (salary received status — per accountant, or x/y for all), and
   صافي الإيرادات = collected − received salary − uploaded expenses. Works for one
   or all accountants; existing records list stays below.
7. **Printed-receipt settings page** — new Settings page "إعدادات الوصل المطبوع":
   a checkbox per printable section (default ALL enabled) persisted via NEW
   SharedPreferences keys cached in `PrinterPrefs` (additive `showSection(key)`),
   applied equally to Bluetooth + USB + LAN (LAN inherits the USB renderer). Sections:
   station name, receipt no, date, subscriber name, month, **board name (NEW row)**,
   **circuit name (NEW row)**, amps, price/amp, tariff type, paid amount, payment
   method, discount, remaining, accountant, QR, footer. The two NEW rows (board +
   circuit names) are resolved by id at print time (tiny additive repo lookups) and
   added to BOTH the BT row list and the shared USB/LAN renderer. The v24 BT/USB
   freeze is explicitly lifted BY THIS REQUEST for receipt-content gating only;
   transports/timing/QR pipeline untouched. PDF untouched (spec lists BT/USB/LAN).

Meta: analyze 0/0; `flutter test` green (parity for every new key); backend `npm test`
green if backend touched; adversarial review; MILESTONES entry; change table; Flash API
default; release APK; commit HELD until user confirmation.
