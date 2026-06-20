# Tasks — Flash v10

## Backend (agent, disjoint)
- [ ] (8) Branch sub-account: `User.parentOwner`; `POST/GET /api/account/branches`; branch login works; effectiveOwner/scoping for branch mirror; +tests; API_CONTRACT.
- [ ] (7) Owner-panel per-branch backend: list parent's branches + per-branch data/stats endpoints (parent-authed, ownership-checked).

## Flutter — contained (me, committed each)
- [ ] (1) Reports: 3 per-category PAID-count cards (replace price cards); keep donut.
- [ ] (4) Collection %: audit formula (app + backend), fix div-by-zero / discount coverage / >100% clamp.
- [ ] (10) Pricing confirm dialog on save.
- [ ] (5) Monthly pricing day picker → `monthly_prices.start_date` (schema v10), set via DatePicker (day within the month), displayed; billing unchanged.
- [ ] (9) Auto-sync after every write when online; offline AppBar status unchanged.
- [ ] (2) Logout: online → push then always wipe local; offline → confirm dialog (wipe / cancel).
- [ ] (3) Rebrand → Flash: AndroidManifest `android:label`, iOS `CFBundleDisplayName`, SPA brand strings incl. English "Owner Panel" → "Flash Owner Panel"; keep current icon.

## Flutter — branch model wiring (me, after backend)
- [ ] (8) Owner UI to create a branch account (generator name + phone + password).
- [ ] (6) Branch login / switch lifecycle: online wipe-all + pull branch; offline confirm dialog.
- [ ] (7) Owner-panel branch switcher (frontend) consuming the per-branch endpoints.

## Verify
- [ ] flutter analyze + flutter test; backend npm test.
- [ ] adversarial review of the diff; on-device test (RMX3085); build release.
