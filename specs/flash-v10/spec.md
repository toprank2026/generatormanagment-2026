# Flash v10 — feature batch (10 items)

Rebrand + reports + branch-as-account + lifecycle. Surfaces: Flutter app, backend, admin panel, owner panel.

## Decisions (from owner)
- **Branch model (6/7/8):** a branch is its own **backend login account** (generator name + phone + password) **created by the business owner** from inside the app, fully isolated data, logs in from the normal login screen. The owner's panel aggregates + switches across its branches. (Like the accountant sub-account model, but a full owner-scoped branch account linked to the parent owner.)
- **Pricing date (5):** each pricing still belongs to its **month**; the owner picks any **day within that month** via a DatePicker (stored as metadata + displayed). Billing stays month-based — **no proration**.
- **Logo (3):** rename everything to **Flash** now, **keep the current fuse icon**; swap the logo image when the owner supplies one.

## Requirements
1. **Reports — per-tariff paid counts:** replace the 3 tariff *price* cards with the **count of PAID subscribers** per category (gold/standard/commercial). Keep the aggregate paid/unpaid donut.
2. **Logout wipe policy:** online → push pending then **always delete local SQLite**; offline → **confirm dialog** (delete local / cancel).
3. **Rebrand → Flash:** app display name, in-app titles, brand strings, and the SPA — English "Owner Panel" → **"Flash Owner Panel"**; keep current icon.
4. **Collection % audit:** find the collection-percentage formula in reports (app + backend/owner panel), verify (discount coverage, div-by-zero, >100% clamp), fix bugs.
5. **Monthly pricing start day:** DatePicker to pick the pricing's start day within its month; store + display; billing unchanged.
6. **Branch switch lifecycle:** switching/creating a branch → online: wipe ALL local data (incl. accountants) then pull only the new branch's data; offline → confirm dialog (delete / cancel). Requires internet.
7. **Owner-panel branch separation:** separate ALL owner-panel data by branch + a branch switcher.
8. **Branch creation = owner-created sub-account:** owner creates a branch account (generator name + phone + password); linked to the owner; branch logs in directly from the login screen; enforces the §6 wipe lifecycle.
9. **Auto-sync after every op:** when online, sync+poll runs automatically after each write; offline keeps the AppBar offline status.
10. **Pricing confirm dialog:** changing monthly pricing shows a confirm pop-up (create / cancel).

## Non-goals / residual
- No price proration (5). No new logo art (3). Conflict-resolution edge cases from v9 unchanged.
