# Flash v41 — tasks

- [x] T1 BT sheet: isScrollControlled + 75% height + Expanded ListView
      (settings_screen `_showPrinterSelection`; fleet-verified root cause:
      GetX 9/16 cap + shrinkWrap zero-extent losing drags to sheet-dismiss).
- [x] T2 Bulk جوزة creation: dialog switch (off default, single path verbatim)
      + `CoreController.addCircuitsRange` (skip existing, cap 500).
- [x] T3 Circuit picker: form-local FULL list via getByBoardId (branch-scoped),
      bounded scrollable menu, Obx removed with its observable.
- [x] T4 Translations ×7 in BOTH maps; analyze baseline clean; 102 tests green.
- [x] T5 Mapping fleet (3 agents) — implementation confirmed on all 3 items.
- [x] T6 Adversarial review fleet (11 agents) — confirmed findings fixed:
      • bulk close via root navigator (Get.back-swallowed-by-snackbar gotcha)
      • synchronous picker clear on board change (stale cross-board window)
      • overflow-proof range cap in UI AND controller (int64 wrap bypass)
      • partial-creation refresh via try/finally; error snackbar after hide
      • duplicate check = ONE query (name set) instead of N roundtrips.
      Deferred (out of mandate): batch-transaction inserts; board picker's
      own 100-cap; USB sheet shares the old non-scrolling layout (1-2 devices).
- [x] T7 MILESTONES entry; commit+push; Flash-API release APK; change table.
