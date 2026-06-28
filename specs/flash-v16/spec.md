# Flash v16 — Home UI polish + in-app settlement + accountant receipt name

Mandate: ONLY these changes; do not touch anything else; no workflow/data/security
regressions; fully backward compatible.

## Items
1. **Home card fonts** — standardize + slightly enlarge the card NUMBERS; make them
   overflow-safe (FittedBox/auto-size) so big numbers don't get cut on small phones.
2. **Fixed app-wide font size** — text must NOT scale with the device font setting
   (global `MediaQuery.textScaler = TextScaler.noScaling` via GetMaterialApp builder).
3. **SafeArea on every list screen** — wrap list bodies so content isn't clipped by
   notches/system bars.
4. **Responsive Home-card icon sizes** — scale icon size by screen width (tablet vs
   phone) so they render properly on both.
5. **Full-width "Collected" + "Remaining" cards ONLY** — these two span the full row
   for large-number clarity; every other card unchanged.
6. **Remove dispose-loading after add accountant** — already done; verify only.
7. **In-app accountant SETTLEMENT (Admin/owner-only)** — a NEW Settings screen
   listing accountant settlement requests with approve/reject (like the Owner Panel).
   Uses the local synced `settlements` table + sync (offline-first): approve updates
   the local row (status/decided_*/updated_at) → push → accountant pulls it.
8. **Verify account switching wipes SQLite (like logout)** — the v13 switch already
   wipes all local data; ensure it works + the confirm popup explicitly says ALL
   local data is deleted.
9. **Accountant receipt generator name** — when an ACCOUNTANT prints, the OWNER's
   generator name must print at the top. Backend: the accountant's serialized
   account exposes the owner's `generatorName`; the receipt header already reads it.

## Delivery
Spec + read-only mapping + tiny backend agent (item 9) + coupled Flutter (me) +
adversarial review. Then table, confirm Flash API, build APK.
