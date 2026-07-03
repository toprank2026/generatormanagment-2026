# Flash v24 — LAN/Ethernet thermal printing (third transport)

## Mandate
Add a THIRD printer transport — LAN/Ethernet over raw TCP — with **zero changes to the
existing Bluetooth and USB printing behavior, layout, timing, QR, or business logic**.
No separate receipt renderer: the LAN path must produce byte-identical output to USB.

## Design
- **Rendering reuse:** `UsbPrintService` gains two ADDITIVE public delegates only —
  `buildReceiptImages(...)` → existing private `_buildReceiptImages` and
  `buildTextImage(...)` → existing private `_textImage`. Every existing USB method is
  byte-for-byte untouched. `LanPrintService` renders through these delegates and builds
  the ESC/POS stream with the SAME `Generator(PrinterPrefs.is80mm ? mm80 : mm58)` +
  per-copy `imageRaster` loop + `feed(2)` + one `cut()` — mirroring USB's step 3 exactly
  (same copies count from `PrinterPrefs.copies`, same paper size, same auto-cut).
- **Transport:** `Socket.connect(ip, port, timeout)` → `add(bytes)` → `flush()` → short
  drain delay → destroy. Default port 9100. Static `_busy` latch like USB
  (`Exception('lan_busy')`).
- **Discovery (async, in order):**
  1. Saved IP/port from `PrinterPrefs` — probe first.
  2. mDNS (`multicast_dns` package, pure Dart): PTR lookup of `_pdl-datastream._tcp`,
     `_printer._tcp`, `_ipp._tcp` → SRV → A record; best-effort try/catch (Android may
     lack a multicast lock — the subnet scan below covers that).
  3. Subnet scan: local IPv4 /24 (via `NetworkInterface.list`), hosts 1..254, ports
     9100 → 515 → 631, connect timeout ~400ms, bounded concurrency.
  - Probe/validation = TCP connect + ESC/POS init (`ESC @` = 0x1B 0x40) write succeeds.
  - On found: persist via `PrinterPrefs.setLan(ip, port)` and reuse automatically.
  - At print time, if the saved printer is unreachable → one automatic re-discovery,
    then retry once; otherwise `lan_printer_offline`.
- **Prefs:** `PrinterPrefs` extends `printer_type` to `'lan'` (+ `isLan`) and adds
  cached `printer_lan_ip` / `printer_lan_port` keys with `setLan`/`clearLan`.
  BT/USB semantics preserved (anything not usb/lan still normalizes to bluetooth).
- **UI (settings printer section):** the type toggle becomes 3-way
  (Bluetooth | USB | LAN). When LAN is selected: a status tile (IP:port + green/grey
  icon), a **Search printer** action (spinner + status text while discovering), and a
  **Forget printer** action. The existing v23 **Test print** tile gains a LAN branch
  (same tiny slip as the USB test). All strings in BOTH translation maps.
- **Dispatch:** both print sites (`subscriber_detail_screen`, `payment_history_screen`)
  and the settings test-print add an `else if (PrinterPrefs.isLan)` branch AFTER the USB
  check and BEFORE the Bluetooth check — the BT/USB branches are untouched.
- **Android:** add `CHANGE_WIFI_MULTICAST_STATE` permission (mDNS best-effort);
  raw TCP needs no cleartext config; works API 26–35 (dart:io sockets).

## Acceptance
- BT + USB printing code untouched (except the two additive delegates in the USB file).
- LAN receipt output identical (same images, copies, cut) — guaranteed by construction.
- `flutter analyze` 0/0; `flutter test` green (translation parity).
- Adversarial review of the diff; release APK built (Flash API default); commit HELD.
