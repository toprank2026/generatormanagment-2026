# Flash v17 — Block logout when unsynced data exists (data-loss guard)

Mandate: ONLY this change; do not touch anything else; no workflow/data/security
regressions; fully backward compatible. Flutter app only.

## Problem
A user-initiated logout wipes ALL local SQLite data (then re-pulls on next
login). If there are still **unsynced** records (rows in the `sync_outbox`,
i.e. the app's `is_synced = 0` / `pending_sync`), wiping loses them permanently
when the device can't reach the server (offline / push failing). v15 only
*warned*; the requirement is to **prevent** logout entirely in that case.

## Behaviour (all roles: owner / admin / accountant)
The guard lives in `AuthController.logout({wipeLocal:true})` — the only path that
wipes — so it covers every user-initiated logout (Home + Settings buttons).
Involuntary logouts (`wipeLocal:false`: session-expired / offline-too-long /
restore flows) keep local data and are unaffected.

Order of checks, BEFORE any delete or session teardown:
1. **Sync running** (`isSyncing` || `isPulling`) → disable logout, show
   `logout_sync_running`, return.
2. **Online + sync-enabled** → best-effort `syncNow` (upload only; never
   deletes) so a normal online logout still completes with no manual step.
3. **Re-check the real outbox** (`refreshPending`).
4. **Still unsynced** (`pendingCount > 0`) → **BLOCK**: show
   `logout_blocked_unsynced` ("Logout is not allowed because there are
   unsynchronized data waiting to be uploaded. Please connect to the internet
   and complete synchronization first to avoid data loss."), **do NOT delete
   local data**, return.
5. **No unsynced data** → the existing confirm → `deleteAllLocalData` → clear
   session → login redirect (unchanged).

## Out of scope
No backend / admin-panel / owner-panel change — this is a client-side logout
guard. The sync engine, outbox, and triggers are untouched.

## Delivery
Spec + direct edit of `auth_controller.dart` (+ 3 translation keys in BOTH maps)
+ adversarial review. Then table, confirm Flash API, build APK.
