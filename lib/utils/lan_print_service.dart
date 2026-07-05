import 'dart:async';
import 'dart:io';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;
import 'package:multicast_dns/multicast_dns.dart';

import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:generatormanagment/utils/usb_print_service.dart';

/// v24 — LAN/Ethernet thermal printing over a raw TCP socket (port 9100).
///
/// A THIRD transport beside Bluetooth and USB. It deliberately reuses the USB
/// service's receipt renderer (via the public [UsbPrintService.buildReceiptImages]
/// delegate) and builds the ESC/POS stream with the SAME Generator + per-copy
/// imageRaster loop + feed(2) + cut — so the printed output (header, Arabic
/// table, QR, footer, copies, auto-cut) is identical to the USB/Bluetooth
/// receipts by construction. Only the last hop (the wire) differs.
///
/// TRANSPORT POLICY (review-hardened): [_send] only speaks RAW ESC/POS, which
/// is the 9100 "JetDirect" protocol — so discovery ONLY ever saves port-9100
/// endpoints. Ports 515 (LPD) and 631 (IPP) are used as locate-hints during the
/// subnet sweep: a host answering there is re-probed on 9100 and skipped if
/// 9100 doesn't answer (an LPD/IPP daemon would silently discard our bytes —
/// "successful" prints that never print).
class LanPrintService {
  /// One LAN job at a time (mirrors the USB `_busy` latch).
  static bool _busy = false;

  /// The only port [_send]'s raw ESC/POS stream is valid for.
  static const int rawPort = 9100;

  /// Ports swept during the FULL discovery. 515/631 are locate-hints only —
  /// hits there are re-validated on [rawPort] before being accepted.
  static const List<int> discoveryPorts = [9100, 515, 631];

  /// mDNS service types printers advertise.
  static const List<String> _mdnsServices = [
    '_pdl-datastream._tcp.local', // RAW 9100
    '_printer._tcp.local', // LPD
    '_ipp._tcp.local', // IPP
  ];

  // ------------------------------------------------------------------ print

  /// Prints [receipt] on the saved LAN printer. When none is saved, discovers
  /// one (and persists it). If the SAVED endpoint is unreachable, runs ONE
  /// quick (9100-only) re-discovery WITHOUT persisting — covering a DHCP IP
  /// change for this job while never letting an unattended mid-print sweep
  /// overwrite the user's saved printer. [onStatus] fires when a network
  /// search starts, so callers can show progress (discovery can take ~10-20s).
  /// Throws a clear [Exception] on failure so the callers surface
  /// `print_failed` exactly like the other transports.
  Future<void> printReceipt(
    Receipt receipt,
    Subscriber sub,
    String accountantName, {
    void Function(String status)? onStatus,
  }) async {
    if (_busy) throw Exception('lan_busy');
    _busy = true;
    try {
      // 1) Render the receipt through the SHARED pipeline (identical to USB).
      final List<img.Image> images = await UsbPrintService()
          .buildReceiptImages(receipt, sub, accountantName);
      final List<int> bytes = await _escPosBytes(images, withCut: true);

      // 2) Resolve the endpoint: saved first, else discover (and persist).
      String ip = PrinterPrefs.lanIp;
      int port = PrinterPrefs.lanPort;
      if (ip.isEmpty) {
        onStatus?.call('searching');
        final found = await _discover(onStatus: onStatus);
        if (found == null) throw Exception('lan_printer_not_found');
        ip = found.ip;
        port = found.port;
      }

      // 3) Send; on connection failure re-discover once (IP change) and retry.
      //    Quick sweep (9100 only) + NON-persisting: the saved endpoint stays
      //    the user's choice; only an explicit Search/manual entry rewrites it.
      try {
        await _send(ip, port, bytes);
      } on SocketException {
        onStatus?.call('searching');
        final found = await _discover(
            skipSaved: true, quick: true, persist: false, onStatus: onStatus);
        if (found == null) throw Exception('lan_printer_offline');
        await _send(found.ip, found.port, bytes);
      }
    } finally {
      _busy = false;
    }
  }

  /// Prints the tiny test slip (same content as the USB test print).
  Future<void> printTest() async {
    if (_busy) throw Exception('lan_busy');
    _busy = true;
    try {
      final usb = UsbPrintService();
      final img.Image line1 = await usb.buildTextImage('Flash', 30, center: true);
      final img.Image line2 = await usb.buildTextImage(
          'اختبار الطباعة — Test print', 22,
          center: true);
      final profile = await CapabilityProfile.load();
      final gen = Generator(
          PrinterPrefs.is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
      final List<int> bytes = [];
      bytes.addAll(gen.imageRaster(line1));
      bytes.addAll(gen.imageRaster(line2));
      bytes.addAll(gen.feed(2));
      bytes.addAll(gen.cut());

      String ip = PrinterPrefs.lanIp;
      int port = PrinterPrefs.lanPort;
      if (ip.isEmpty) {
        final found = await _discover();
        if (found == null) throw Exception('lan_printer_not_found');
        ip = found.ip;
        port = found.port;
      }
      await _send(ip, port, bytes);
    } finally {
      _busy = false;
    }
  }

  /// Explicit user-driven discovery (Settings → Search). Latched against the
  /// print jobs via the same `_busy` flag so a search can never race a print's
  /// own discovery/transfer (two concurrent subnet sweeps + double setLan).
  /// Always sweeps FRESH (skips the saved endpoint) and persists the result.
  Future<({String ip, int port})?> search(
      {void Function(String status)? onStatus}) async {
    if (_busy) throw Exception('lan_busy');
    _busy = true;
    try {
      return await _discover(skipSaved: true, onStatus: onStatus);
    } finally {
      _busy = false;
    }
  }

  /// Builds the receipt ESC/POS stream EXACTLY like the USB path (step 3 of
  /// UsbPrintService.printReceipt): per copy every image as imageRaster + a
  /// feed(2), then one cut at the end.
  Future<List<int>> _escPosBytes(List<img.Image> images,
      {required bool withCut}) async {
    final CapabilityProfile profile = await CapabilityProfile.load();
    final Generator gen = Generator(
      PrinterPrefs.is80mm ? PaperSize.mm80 : PaperSize.mm58,
      profile,
    );
    final List<int> bytes = [];
    final int copies = PrinterPrefs.copies;
    for (int copy = 0; copy < copies; copy++) {
      for (final im in images) {
        bytes.addAll(gen.imageRaster(im));
      }
      bytes.addAll(gen.feed(2));
      // v28 item 16: auto-cut EACH receipt separately (was one cut at the end).
      if (withCut) bytes.addAll(gen.cut());
    }
    return bytes;
  }

  /// Opens a TCP socket to the printer, writes [bytes], and closes GRACEFULLY.
  ///
  /// Review-hardened (v24): `flush()` only hands the bytes to the OS — a
  /// receipt raster (often 100KB+ at 2 copies) drains to the printer over
  /// several seconds of TCP flow control. The old fixed-delay + `destroy()`
  /// could RST the connection with unsent data still queued (truncated
  /// receipt, no cut) — especially because printers that push unsolicited
  /// status bytes leave unread inbound data, which turns close() into RST.
  /// So: (1) drain the read side, (2) propagate errors only up to flush()
  /// (the caller's re-discover retry runs ONLY when nothing was delivered),
  /// (3) close gracefully with a size-proportional wait, then destroy.
  Future<void> _send(String ip, int port, List<int> bytes) async {
    final Socket socket =
        await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
    // Consume anything the printer pushes back (ASB/status bytes): unread
    // inbound data would turn our close into a TCP RST that discards the
    // un-transmitted tail of the raster stream.
    socket.listen((_) {}, onError: (_) {});
    try {
      socket.add(bytes);
      await socket.flush(); // Dart buffer -> kernel; NOT yet delivered.
    } catch (_) {
      socket.destroy();
      rethrow; // genuine connect/write failure -> caller may retry safely
    }
    // Job handed to the OS: close gracefully (FIN after the kernel finishes
    // sending). `close()`'s future often never completes on raw-9100 printers
    // (they hold the connection open), so bound the wait by a drain estimate
    // (~50 KB/s raster throughput, 700ms floor, 10s cap). Everything past a
    // successful flush is swallowed — propagating a late error would trip the
    // caller's retry and print a DUPLICATE receipt.
    final int drainMs = (bytes.length ~/ 50).clamp(700, 10000);
    try {
      await socket.close().timeout(Duration(milliseconds: drainMs));
    } catch (_) {
      // Printer kept the connection open (normal) or reset after printing.
    } finally {
      socket.destroy();
    }
  }

  // -------------------------------------------------------------- discovery

  /// Finds a LAN printer. Order: saved endpoint (unless [skipSaved]) → mDNS
  /// (skipped when [quick]) → subnet scan ([quick] = port 9100 only).
  /// Only RAW-9100-capable endpoints are ever returned/persisted (see the
  /// class doc). Persists via [PrinterPrefs.setLan] when [persist].
  Future<({String ip, int port})?> _discover({
    bool skipSaved = false,
    bool quick = false,
    bool persist = true,
    void Function(String status)? onStatus,
  }) async {
    // 1) Saved endpoint.
    if (!skipSaved && PrinterPrefs.lanIp.isNotEmpty) {
      if (await _probe(PrinterPrefs.lanIp, PrinterPrefs.lanPort)) {
        return (ip: PrinterPrefs.lanIp, port: PrinterPrefs.lanPort);
      }
    }

    // 2) mDNS (best-effort: Android needs a multicast lock we don't hold —
    //    when it yields nothing the subnet scan still finds the printer).
    if (!quick) {
      try {
        final viaMdns =
            await _discoverMdns().timeout(const Duration(seconds: 6));
        if (viaMdns != null) {
          if (persist) await PrinterPrefs.setLan(viaMdns.ip, viaMdns.port);
          return viaMdns;
        }
      } catch (_) {/* fall through to the scan */}
    }

    // 3) Subnet scan.
    final viaScan = await _scanSubnet(quick: quick, onStatus: onStatus);
    if (viaScan != null) {
      if (persist) await PrinterPrefs.setLan(viaScan.ip, viaScan.port);
      return viaScan;
    }
    return null;
  }

  /// mDNS lookup across the common printer service types. Every lookup is
  /// individually time-bounded and the whole pass respects a ~5s deadline, so
  /// the abandoned-future window of the outer `.timeout` stays tiny.
  Future<({String ip, int port})?> _discoverMdns() async {
    final MDnsClient client = MDnsClient();
    final deadline = Stopwatch()..start();
    const budget = Duration(seconds: 5);
    try {
      await client.start();
      for (final service in _mdnsServices) {
        if (deadline.elapsed >= budget) break;
        await for (final PtrResourceRecord ptr in client.lookup<PtrResourceRecord>(
          ResourceRecordQuery.serverPointer(service),
          timeout: const Duration(milliseconds: 1500),
        )) {
          if (deadline.elapsed >= budget) break;
          await for (final SrvResourceRecord srv
              in client.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(ptr.domainName),
            timeout: const Duration(milliseconds: 1000),
          )) {
            if (deadline.elapsed >= budget) break;
            await for (final IPAddressResourceRecord a
                in client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: const Duration(milliseconds: 1000),
            )) {
              final ip = a.address.address;
              // RAW-only policy: whatever port the service advertises, we can
              // only PRINT to 9100 — accept the host iff its 9100 answers.
              if (await _probe(ip, rawPort)) return (ip: ip, port: rawPort);
            }
          }
        }
      }
      return null;
    } finally {
      client.stop();
    }
  }

  /// Scans the local /24 for printers. [quick] sweeps port 9100 only (used by
  /// the mid-print retry); the full sweep also uses 515/631 as locate-hints,
  /// re-validating every hit on 9100 before accepting it.
  Future<({String ip, int port})?> _scanSubnet(
      {bool quick = false, void Function(String status)? onStatus}) async {
    final String? base = await _localSubnetBase();
    if (base == null) return null;
    final ports = quick ? const [rawPort] : discoveryPorts;
    for (final port in ports) {
      onStatus?.call('$base.* :$port');
      const int concurrency = 32;
      for (int start = 1; start <= 254; start += concurrency) {
        final futures = <Future<String?>>[];
        for (int h = start; h < start + concurrency && h <= 254; h++) {
          final ip = '$base.$h';
          futures.add(_probe(ip, port, timeout: const Duration(milliseconds: 400))
              .then((ok) => ok ? ip : null));
        }
        final results = await Future.wait(futures);
        for (final hit in results) {
          if (hit == null) continue;
          if (port == rawPort) return (ip: hit, port: rawPort);
          // 515/631 hit = locate-hint only; accept iff RAW 9100 answers too.
          if (await _probe(hit, rawPort)) return (ip: hit, port: rawPort);
        }
      }
    }
    return null;
  }

  /// The device's own IPv4 /24 prefix (e.g. '192.168.1'), Wi-Fi/Ethernet
  /// interfaces ONLY — scanning a cellular/VPN interface (rmnet/tun/ppp) would
  /// waste ~10s sweeping carrier space that cannot contain the printer.
  Future<String?> _localSubnetBase() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      NetworkInterface? pick;
      for (final i in interfaces) {
        final n = i.name.toLowerCase();
        if (n.startsWith('wlan') ||
            n.startsWith('eth') ||
            n.startsWith('en') ||
            n.startsWith('ap')) {
          pick = i;
          break;
        }
      }
      if (pick == null) return null; // no LAN-capable interface — skip scan
      final addr = pick.addresses.firstWhere(
        (a) => !a.isLoopback && a.type == InternetAddressType.IPv4,
        orElse: () => pick!.addresses.first,
      );
      final parts = addr.address.split('.');
      if (parts.length != 4) return null;
      return '${parts[0]}.${parts[1]}.${parts[2]}';
    } catch (_) {
      return null;
    }
  }

  /// Validates a candidate endpoint: TCP connect + an ESC/POS initialize
  /// (ESC @) write must succeed. Most printers don't answer, so a successful
  /// connect+write is the accepted proof.
  Future<bool> _probe(String ip, int port,
      {Duration timeout = const Duration(milliseconds: 800)}) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: timeout);
      socket.add(const [0x1B, 0x40]); // ESC @ — initialize printer
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }
}
