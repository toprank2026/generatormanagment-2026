# Flash v41 — three scoped UI fixes (production constraint: nothing else)

1. **Bluetooth printer sheet fully scrollable** — the sheet opened
   non-scroll-controlled, so GetX capped it ~half-screen and squeezed the
   paired-device list (few visible, drag fought the sheet). Now
   `isScrollControlled: true`, fixed 75% height, `Expanded` ListView — every
   paired device reachable. (`settings_screen.dart _showPrinterSelection`;
   the service's `getBondedDevices()` was never limited.)
2. **Optional bulk circuit creation** — the Add-جوزة dialog gains an off-by-
   default switch: "bulk add (number range)" swaps the name field for from/to
   number fields (phase applies to both). `CoreController.addCircuitsRange`
   creates names `from..to` sequentially, SKIPS numbers already existing on
   the board (safe to re-run), caps 500/call, one list refresh at the end.
   The single-add path is byte-for-byte unchanged (verbatim branch).
3. **Circuit picker shows ALL circuits** — the add/edit-subscriber dropdown
   read the PAGINATED shared list (first 100 only; the form never loads more).
   It now has its own full list via `CircuitRepository.getByBoardId` (no
   limit, same branch scope + creation order), `menuMaxHeight` bounded
   scrollable menu. The Obx wrapper was REMOVED with the observable (the
   documented Obx gotcha); the paginated circuits screen is untouched.

New translation keys (both maps): bulk_add_circuits, bulk_from, bulk_to,
bulk_invalid_range, bulk_range_too_large, circuits_added, circuits_skipped.

Out of scope (untouched): board picker pagination, USB/LAN printer pickers,
circuits screen list, all controllers/repos beyond `addCircuitsRange`.
