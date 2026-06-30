# Flash v21 — USB thermal printing, circuit grid, import/export, test data

Mandate: ONLY these changes. Keep ALL existing Bluetooth printer behaviour/UI
unchanged — only ADD a USB option alongside it.

## 1. USB thermal printer (direct, no external app)
- Add USB thermal printing: connect to a USB thermal printer, print the receipt
  directly (ESC/POS raster image for Arabic), with AUTO-CUT and the existing
  paper-size (58/80mm). Use `usb_serial` + the existing `esc_pos_utils_plus`.
- Add a printer-TYPE selector in Settings: **Bluetooth | USB** (2 options). The
  Bluetooth path + its settings stay EXACTLY as they are; USB is parallel.
- The print call sites dispatch by the selected type.

## 2. Circuit (Jozة) list → grid
- Convert the circuits screen from a ListView to a GRID (same style as the board
  grid: responsive max-extent). KEEP the current creation-order sort (stable for
  Arabic — the v20 fix). Do not change ordering.

## 3. Import / export
- Verify the local Export/Import (boards+circuits+subscribers, encrypted
  `<name>.backup`) works end-to-end; refresh the UI after a successful import.

## 4. Test data file
- Generate a `.backup` file (the import format) with ~1000 subscribers + their
  boards + circuits, importable via the Import feature with a known password.

## Delivery
Spec + mapping + coupled edits (USB/printer dispatch, settings) + disjoint agents
(circuit grid) + adversarial review. Then table, confirm Flash API, build APK.
