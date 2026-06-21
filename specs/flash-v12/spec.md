# Flash v12 — card wallet / wallet refresh / broad sync / hard logout

Extends the v11 accountant wallet. Surfaces: Flutter, backend, owner panel.

## Requirements
1. **Credit-Card wallet** — a SECOND wallet (alongside Cash) for receipts paid by
   **card**. Same behavior as cash: linked to the accountant, synced, Request
   Settlement → owner-approved → history (paginated).
   - **Design:** `settlements.method` ('cash'|'card'). Per-method balance:
     `cash = Σ cash receipts − Σ approved cash settlements`,
     `card = Σ card receipts − Σ approved card settlements`. The server wallet
     endpoint returns BOTH `{cash:{collected,settled,balance}, card:{...}}`.
     Request Settlement is per method; history shows the method.
2. **Wallet page refresh** — opening My Wallet does a **pull update** first
   (latest receipts + owner settlement decisions) before showing balances.
3. **Sync after (nearly) every operation** — `SyncController.poke()` already
   fires after writes; audit + fill any gaps so every mutation triggers an
   upload when online.
4. **Hard logout** — after the confirm dialog is accepted, delete **ALL** local
   data (every SQLite table, not just the synced business ones) behind a
   **loading indicator**, and only finish the logout (clear session) **after**
   the wipe completes. (The persistent install-id — device identity, not data —
   is kept so re-login device binding still works.)

## Notes
- Push uploads everything (unchanged). Pull stays current-month-scoped for
  receipts (v11). The wallet remains server-authoritative (all-time), now split
  by method.
