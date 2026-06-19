# Plan — Audit Fixes

## Execution model
- **Backend** (disjoint from Flutter) → one dedicated agent, edits confined to `backend/`, kept `npm test` green.
- **Flutter** (heavily coupled controllers/repos/db) → edited directly in dependency order (NOT parallel agents — repo hazard: parallel editors have reverted tracked edits). One workstream at a time, `flutter analyze`+`flutter test` after each.
- **Verification** → adversarial review workflow (per-area reviewer → per-finding skeptic), read-only, before commit.
- Commit once both suites are green and the review is clean.

## Order (Phase 1)
1. Spec-Kit (this folder).
2. Backend agent: WS-SEC, WS-PUSHAUTHZ, WS-DASH, WS-PANEL (+tests, +API_CONTRACT).
3. Flutter: WS-DISCOUNT → WS-SYNCSAFE → WS-PERMS-UI → WS-SCALE(indexes).
4. Verify both suites + adversarial review; fix confirmed regressions.
5. Commit + push; short report.

## Risk controls
- Schema change is additive (indexes only) + version bump 7→8 with idempotent `IF NOT EXISTS` in both `_onCreate` and `_onUpgrade`. Indexes created **after** `_createSyncInfra` (one index is on `sync_outbox`).
- Behavior-changing/test-coupled fixes (no-price≠paid, pricing immutability, conflict-resolution, receipt renumbering) are **Phase 2** — they need design + product decisions and would otherwise flip established tests.
- No edits to the sync outbox/triggers/drain (CLAUDE.md).

## Phase 2 design notes (not yet built)
- **Conflict resolution:** add `updated_at` to each business row (maintained on edit / by triggers), push it as the sync timestamp, server upsert only when `incoming.updatedAt > stored.updatedAt`; tombstones sticky; pull must not overwrite a row with a pending outbox edit. Decision needed: LWW-by-edit-time vs field-level merge.
- **Receipt numbering:** server-assigned per-(account,branch) sequence on push, or device-namespaced display numbers + post-pull dedup. Decision needed.
- **Scale tail:** count-aggregate refactor (COUNT/SUM, no row hydration), paid/unpaid pagination, incremental `since` on routine pulls, periodic pull for multi-accountant convergence.
- **Branch-delete orphan cleanup** after pull; **maxDevices self-service recovery**.
