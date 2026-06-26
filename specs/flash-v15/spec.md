# Flash v15 — minimal feature additions (system is stable)

Mandate: MINIMAL edits, no refactors, no logic/security/DB changes unless required,
fully backward compatible.

## Locked decisions
- Backup: **password = the admin/owner account password**, **admin/owner-only** (not
  accountants), contents = **boards + circuits + subscribers** (data only, NO history).
- Banners: admin **uploads an image file** (stored server-side).
- Subscription remaining: **server-computed** remainingDays (clock-manipulation-proof).

## Items
1. **Remaining subscription days** — banner shows server-computed `remainingDays`
   (not total duration), refreshed on each online validation; never from local
   device clock. Backend `serializeSubscription` adds `remainingDays`; Subscription
   model carries it; dashboard banner renders it; remove the local-time math.
   Preserve offline-too-long logout.
2. **Receipt header** — remove the "TopRank" fallback; print only the generator
   name (never "Main Branch"). (v14 already prefers generatorName.)
3. **Auto-sync after payment + expense** — already poke() on write; verify; offline
   keeps local + increments the pending counter (existing mechanism).
4. **Logout warning** — if pendingCount>0, warn that logout permanently deletes the
   unsynced local records; require explicit confirm.
6. **Local backup/restore** — export boards+circuits+subscribers to
   `<GeneratorName>.backup`, **encrypted with the owner password** (entered to
   export AND import), offline, integrity-checked; **owner/admin-only**; from
   Settings. share_plus to save, file_picker to import.
7. **Receipt footer** — "Powered by Flash" + blue.png logo (PDF; BT if image
   supported else text) + phone +964 770 821 6878.
8. **Admin banners** — admin CRUD (create/edit/delete/enable) with image UPLOAD +
   ratio 1:1/2:1/3:1; landing shows enabled banners at the top.
9. **Admin promo video** — admin add/edit/delete url + enable (YouTube/Vimeo/direct);
   landing shows it near the footer.

## Delivery
Spec + mapping (done) + disjoint backend/admin/landing agent + coupled Flutter (me)
+ adversarial review. Then table, confirm Flash API, build APK.
