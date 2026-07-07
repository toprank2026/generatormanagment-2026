import 'dart:async';
import 'dart:ui' as ui;

import 'package:barcode/barcode.dart' as bc;
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:intl/intl.dart';

import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';

/// v21 item 1 — direct USB thermal printing (a sibling of
/// `BluetoothPrintService`, fully independent of it).
///
/// The whole receipt is rendered to ONE tall raster image (so Arabic/RTL prints
/// reliably on printers without native Arabic support — same technique as the
/// Bluetooth service), then sent as ESC/POS `imageRaster` bytes to the printer
/// over a NATIVE USB channel (`moldati/usb`, implemented in MainActivity.kt):
/// raw bulk transfer to a printer-CLASS device with the FLAG_IMMUTABLE
/// permission flow Android 12+ requires. The receipt CONTENT mirrors the
/// Bluetooth printer's rows.
class UsbPrintService {
  /// Native USB channel (enumerate + permission + bulk transfer in Kotlin).
  static const MethodChannel _channel = MethodChannel('moldati/usb');

  /// Lists the attached USB devices (each map has vendorId/productId as ints +
  /// productName/manufacturer/deviceName — see MainActivity.listUsbDevices).
  Future<List<Map<String, dynamic>>> listDevices() async {
    final List<dynamic> raw =
        (await _channel.invokeMethod('listUsbDevices')) as List<dynamic>? ?? [];
    return raw
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
  }

  /// Stable id for a USB device map: "vendorId:productId".
  static String idOf(Map<String, dynamic> d) =>
      '${d['vendorId']}:${d['productId']}';

  /// Guards against overlapping USB prints (double-tap / collect-then-print):
  /// the native permission + bulk-transfer path must not run twice at once on
  /// one device, so a second print is rejected while one is in flight.
  static bool _busy = false;

  /// Prints [receipt] (for [sub], collected by [accountantName]) to a USB
  /// printer-CLASS thermal printer via raw bulk transfer. [deviceId] is the
  /// "vendorId:productId" string saved from the picker; when it is empty/absent
  /// (or that printer is no longer attached) the first attached device is used.
  /// Throws a clear [Exception] on any failure so the caller can surface
  /// `print_failed`.
  Future<void> printReceipt(
    Receipt receipt,
    Subscriber sub,
    String accountantName, {
    String? deviceId,
  }) async {
    if (_busy) throw Exception('usb_busy');
    _busy = true;
    try {
      // 1) Resolve the vendorId/productId. Enumerate once so we can BOTH honour
      //    a saved printer AND fall back when it is unplugged / never picked.
      int? vid;
      int? pid;
      if (deviceId != null && deviceId.contains(':')) {
        final parts = deviceId.split(':');
        vid = int.tryParse(parts[0]);
        pid = int.tryParse(parts[1]);
      }
      final devices = await listDevices();
      if (devices.isEmpty) throw Exception('usb_printer_not_found');
      final bool savedPresent = vid != null &&
          pid != null &&
          devices.any((d) =>
              int.tryParse(d['vendorId']?.toString() ?? '') == vid &&
              int.tryParse(d['productId']?.toString() ?? '') == pid);
      if (!savedPresent) {
        final d = devices.first;
        vid = int.tryParse(d['vendorId']?.toString() ?? '');
        pid = int.tryParse(d['productId']?.toString() ?? '');
      }
      if (vid == null || pid == null) throw Exception('usb_printer_not_found');

      // 2) Render the receipt as the SAME ordered components the Bluetooth
      //    service prints (centered header, bordered 2-column table, QR, footer)
      //    so the USB printout has an identical shape.
      final List<img.Image> images =
          await _buildReceiptImages(receipt, sub, accountantName);

      // 3) Build the ESC/POS byte stream: each component as its own raster
      //    (mirrors the Bluetooth per-image printing), feed per copy, auto-cut.
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
        bytes.addAll(gen.cut());
      }

      // 4) Send the bytes over USB (native handles permission + bulk write).
      //    The .timeout is a backstop so a never-returning native call (e.g. the
      //    activity torn down while the permission dialog is up) can't hang the
      //    print UI forever — the native side also has its own 60s watchdog.
      final bool ok = (await _channel.invokeMethod('printBytes', {
            'vendorId': vid,
            'productId': pid,
            'bytes': Uint8List.fromList(bytes),
          }).timeout(const Duration(seconds: 75))) ==
          true;
      if (!ok) throw Exception('usb_write_failed');
    } on PlatformException catch (e) {
      throw Exception('print_failed: ${e.code} ${e.message}');
    } on TimeoutException {
      throw Exception('print_failed: usb_timeout');
    } finally {
      _busy = false;
    }
  }

  /// v23 item 5: print a tiny TEST slip to prove the USB link works after the
  /// device is selected (no real receipt needed). Same transport as a receipt.
  Future<void> printTest({String? deviceId}) async {
    if (_busy) throw Exception('usb_busy');
    _busy = true;
    try {
      int? vid;
      int? pid;
      if (deviceId != null && deviceId.contains(':')) {
        final parts = deviceId.split(':');
        vid = int.tryParse(parts[0]);
        pid = int.tryParse(parts[1]);
      }
      final devices = await listDevices();
      if (devices.isEmpty) throw Exception('usb_printer_not_found');
      final bool savedPresent = vid != null &&
          pid != null &&
          devices.any((d) =>
              int.tryParse(d['vendorId']?.toString() ?? '') == vid &&
              int.tryParse(d['productId']?.toString() ?? '') == pid);
      if (!savedPresent) {
        final d = devices.first;
        vid = int.tryParse(d['vendorId']?.toString() ?? '');
        pid = int.tryParse(d['productId']?.toString() ?? '');
      }
      if (vid == null || pid == null) throw Exception('usb_printer_not_found');

      final img.Image line1 = await _textImage('Flash', 30, center: true);
      final img.Image line2 =
          await _textImage('اختبار الطباعة — Test print', 22, center: true);
      final profile = await CapabilityProfile.load();
      final gen = Generator(
          PrinterPrefs.is80mm ? PaperSize.mm80 : PaperSize.mm58, profile);
      final List<int> bytes = [];
      bytes.addAll(gen.imageRaster(line1));
      bytes.addAll(gen.imageRaster(line2));
      bytes.addAll(gen.feed(2));
      bytes.addAll(gen.cut());

      final bool ok = (await _channel.invokeMethod('printBytes', {
            'vendorId': vid,
            'productId': pid,
            'bytes': Uint8List.fromList(bytes),
          }).timeout(const Duration(seconds: 75))) ==
          true;
      if (!ok) throw Exception('usb_write_failed');
    } on PlatformException catch (e) {
      throw Exception('print_failed: ${e.code} ${e.message}');
    } on TimeoutException {
      throw Exception('print_failed: usb_timeout');
    } finally {
      _busy = false;
    }
  }

  // ----------------------------------------------------------------------
  // v24: PUBLIC render delegates for the LAN transport. LanPrintService reuses
  // this exact renderer so the LAN receipt is pixel-identical to USB — these
  // are pure pass-throughs; nothing about the USB pipeline itself changes.
  // ----------------------------------------------------------------------

  /// v24: exposes the shared receipt renderer (header → table → QR → footer)
  /// for other transports. Delegates to the private [_buildReceiptImages].
  Future<List<img.Image>> buildReceiptImages(
    Receipt receipt,
    Subscriber sub,
    String accountantName,
  ) =>
      _buildReceiptImages(receipt, sub, accountantName);

  /// v24: exposes the single-line text renderer (used for test slips).
  Future<img.Image> buildTextImage(
    String text,
    double fontSize, {
    bool center = false,
  }) =>
      _textImage(text, fontSize, center: center);

  // ----------------------------------------------------------------------
  // Rendering — mirrors BluetoothPrintService so the USB receipt has the SAME
  // shape (centered header, bordered 2-column table, QR, footer). Each piece is
  // rendered to its own image, exactly like the Bluetooth service.
  // ----------------------------------------------------------------------

  /// v28 item 9: expressive icon per receipt section (shared by BT + USB/LAN).
  /// Referenced as const IconData so the icon tree-shaker keeps the glyphs.
  static const Map<String, IconData> sectionIcons = {
    'sec_station': Icons.bolt,
    'sec_receipt_no': Icons.confirmation_number,
    'sec_date': Icons.event,
    'sec_subscriber': Icons.person,
    'sec_month': Icons.calendar_month,
    'sec_board': Icons.dashboard,
    'sec_circuit': Icons.settings_input_component,
    'sec_amps': Icons.electric_bolt,
    'sec_price': Icons.sell,
    'sec_category': Icons.category,
    'sec_paid': Icons.payments,
    'sec_method': Icons.credit_card,
    'sec_discount': Icons.discount,
    'sec_remaining': Icons.account_balance_wallet,
    'sec_accountant': Icons.badge,
  };

  static String _iconGlyph(IconData i) => String.fromCharCode(i.codePoint);

  /// Loads the app logo (`images/blue.png`) as a ui.Image sized to [target]px.
  Future<ui.Image?> _loadLogo(int target) async {
    try {
      final data = await rootBundle.load('images/blue.png');
      final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(), targetWidth: target);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (_) {
      return null;
    }
  }

  /// Builds the ordered list of receipt images (header → table rows → QR block →
  /// footer), 1:1 with the rows the Bluetooth `printReceipt` emits.
  Future<List<img.Image>> _buildReceiptImages(
    Receipt receipt,
    Subscriber sub,
    String accountantName,
  ) async {
    final df = DateFormat('yyyy-MM-dd HH:mm');
    final List<img.Image> out = [];

    // v27 item 7: board + circuit names (additive lookups) + per-section gates
    // (PrinterPrefs.showSection) — IDENTICAL to the Bluetooth path so USB & LAN
    // honour the same "printed receipt settings".
    final String boardName = PrinterPrefs.showSection('sec_board')
        ? (await BoardRepository().nameById(sub.boardId) ?? '')
        : '';
    final String circuitName = PrinterPrefs.showSection('sec_circuit')
        ? (await CircuitRepository().nameById(sub.circuitId) ?? '')
        : '';

    // Header (v28 items A1-A3): the app logo + "تطبيق / flash" column at the TOP
    // beside the generator (station) name.
    final String gName =
        PrinterPrefs.showSection('sec_station') ? _generatorName() : '';
    out.add(await _headerBlockImage(gName));
    out.add(await _textImage('وصل استلام', 20, center: true));

    // Bordered ROUNDED table — each row gated by its section + an expressive
    // icon (v28 items 9/12). A row = (sectionKey, label, value).
    final List<({String key, String label, String value})> rows = [];
    void add(String key, String label, String value) {
      if (PrinterPrefs.showSection(key)) {
        rows.add((key: key, label: label, value: value));
      }
    }
    add('sec_receipt_no', 'رقم الوصل', receipt.receiptNo.toString());
    add('sec_date', 'التاريخ', df.format(DateTime.parse(receipt.issuedAt)));
    add('sec_subscriber', 'المشترك', sub.name);
    add('sec_month', 'الشهر', receipt.month);
    if (boardName.isNotEmpty) {
      rows.add((key: 'sec_board', label: 'البورد', value: boardName));
    }
    if (circuitName.isNotEmpty) {
      rows.add((key: 'sec_circuit', label: 'الجوزة', value: circuitName));
    }
    add('sec_amps', 'الأمبيرات', receipt.ampsSnapshot.toString());
    add('sec_price', 'سعر الأمبير', fmtAmount(receipt.priceSnapshot));
    add('sec_category', 'نوع الاشتراك',
        SubscriberCategory.arabicLabel(receipt.categorySnapshot ?? sub.category));
    add('sec_paid', 'المدفوع', '${fmtAmount(receipt.paidAmount)} د.ع');
    add('sec_method', 'طريقة الدفع', receiptPaymentMethodText(receipt));
    add('sec_discount', 'الخصم', receiptDiscountText(receipt));
    add('sec_remaining', 'المتبقي', '${fmtAmount(receipt.remainingAfter)} د.ع');
    if (accountantName.isNotEmpty &&
        PrinterPrefs.showSection('sec_accountant')) {
      rows.add((key: 'sec_accountant', label: 'المحاسب', value: accountantName));
    }
    for (int i = 0; i < rows.length; i++) {
      out.add(await _tableRowImage(rows[i].label, rows[i].value,
          iconKey: rows[i].key, top: i == 0, bottom: i == rows.length - 1));
    }

    // Footer — v30 F3: the owner's contact phone prints INSTEAD OF the footer
    // when one is set (empty → the existing thank-you footer).
    if (PrinterPrefs.showSection('sec_footer')) {
      out.add(await _spacerImage(8));
      final contact = _contactPhone();
      if (contact.isNotEmpty) {
        out.add(await _textImage('للتواصل: $contact', 20, center: true));
      } else {
        out.add(await _textImage('شكراً لكم!', 20, center: true));
        out.add(await _textImage('Powered by Flash', 18, center: true));
      }
    }

    // v28 (revised): QR is MANDATORY and sits at the BOTTOM CENTER, framed +
    // rounded, at a clearly-scannable size (separated from the table + footer).
    out.add(await _spacerImage(14));
    try {
      out.add(await _qrBlockImage(_receiptQrUrl(receipt)));
    } catch (_) {/* best-effort, like the Bluetooth path */}
    return out;
  }

  /// A blank [h]px-tall white strip — visual spacing between raster blocks.
  Future<img.Image> _spacerImage(int h) async {
    final double width = PrinterPrefs.pixelWidth;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, width, h.toDouble()), Paint()..color = Colors.white);
    final uiImage =
        await recorder.endRecording().toImage(width.toInt(), h);
    return _uiToImg(uiImage);
  }

  /// Renders one centered/right-aligned Arabic text line to an image.
  Future<img.Image> _textImage(
    String text,
    double fontSize, {
    bool center = false,
  }) async {
    final double width = PrinterPrefs.pixelWidth;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.rtl,
      textAlign: center ? TextAlign.center : TextAlign.right,
    )..layout(maxWidth: width);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, tp.height + 4),
      Paint()..color = Colors.white,
    );
    tp.paint(canvas, const Offset(0, 2));
    final picture = recorder.endRecording();
    final uiImage = await picture.toImage(width.toInt(), tp.height.toInt() + 4);
    return _uiToImg(uiImage);
  }

  /// Renders one bordered 2-column row (label | value) with a section ICON and
  /// ROUNDED outer corners (v28 items 9/12) — identical geometry to
  /// `BluetoothPrintService._printTableRow` so BT and USB/LAN match.
  Future<img.Image> _tableRowImage(
    String label,
    String value, {
    double fontSize = 22,
    String? iconKey,
    bool top = false,
    bool bottom = false,
  }) async {
    final double width = PrinterPrefs.pixelWidth;
    const double pad = 10;
    const double rowGap = 8;
    const double radius = 14;
    final double divX = width * 0.45; // value column width

    // v28 (RTL): the section ICON is anchored at the FAR RIGHT of the row and the
    // label is right-aligned immediately to its left — painted as SEPARATE runs
    // so the BiDi algorithm can never reorder the Material glyph to the wrong
    // side of the Arabic label. Every row shares the same icon x so the icons
    // line up in a clean right-hand column.
    const double iconGap = 6;
    final IconData? ic = iconKey == null ? null : sectionIcons[iconKey];
    TextPainter? iconTp;
    if (ic != null) {
      iconTp = TextPainter(
        text: TextSpan(
          text: _iconGlyph(ic),
          style: TextStyle(
            fontFamily: ic.fontFamily,
            package: ic.fontPackage,
            color: Colors.black,
            fontSize: fontSize,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
    }
    final double iconW = iconTp?.width ?? 0;
    final double iconSlot = iconTp != null ? iconW + iconGap : 0;

    final lp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
            color: Colors.black,
            fontSize: fontSize,
            fontWeight: FontWeight.bold),
      ),
      textDirection: ui.TextDirection.rtl,
      textAlign: TextAlign.right,
    )..layout(maxWidth: width - divX - pad * 2 - iconSlot);
    final vp = TextPainter(
      text: TextSpan(
          text: value,
          style: TextStyle(
              color: Colors.black,
              fontSize: fontSize,
              fontWeight: FontWeight.bold)),
      textDirection: ui.TextDirection.rtl,
      // v28 (RTL): values start from the RIGHT of their column too (hug the
      // divider) so ALL table data reads right-to-left.
      textAlign: TextAlign.right,
    )..layout(maxWidth: divX - pad * 2);
    final double rh = [lp.height, vp.height, iconTp?.height ?? 0]
            .reduce((a, b) => a > b ? a : b) +
        rowGap * 2;
    final int h = rh.ceil() + 1;
    final double hh = h.toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, width, hh), Paint()..color = Colors.white);
    final border = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    // Outer border as an RRect: round ONLY the table's outer corners (top row =
    // top corners, bottom row = bottom corners), straight elsewhere.
    final rrect = RRect.fromRectAndCorners(
      Rect.fromLTWH(1, top ? 1 : 0, width - 2, hh - (top ? 1 : 0) - (bottom ? 1 : 0)),
      topLeft: top ? const Radius.circular(radius) : Radius.zero,
      topRight: top ? const Radius.circular(radius) : Radius.zero,
      bottomLeft: bottom ? const Radius.circular(radius) : Radius.zero,
      bottomRight: bottom ? const Radius.circular(radius) : Radius.zero,
    );
    canvas.drawRRect(rrect, border);
    canvas.drawLine(Offset(divX, 2), Offset(divX, hh - 2), border); // divider

    // Icon at the far right, label right-aligned flush to its left, value
    // right-aligned against the divider — all vertically centered. A TextPainter
    // laid out with minWidth 0 collapses to its NATURAL width, so textAlign.right
    // is a no-op; we position each run by its painted width to actually
    // right-anchor it (this is what makes the row read right-to-left).
    if (iconTp != null) {
      iconTp.paint(
          canvas, Offset(width - pad - iconW, (hh - iconTp.height) / 2));
    }
    lp.paint(canvas,
        Offset(width - pad - iconSlot - lp.width, (hh - lp.height) / 2));
    vp.paint(canvas, Offset(divX - pad - vp.width, (hh - vp.height) / 2));

    final uiImage = await recorder.endRecording().toImage(width.toInt(), h);
    return _uiToImg(uiImage);
  }

  /// v28 (revised A1-A3): the TOP header block — the app logo + a "تطبيق / flash"
  /// column beside the generator (station) name, centered on the paper. When
  /// [gName] is empty (station section hidden / no name) it is just the branded
  /// logo + app name.
  Future<img.Image> _headerBlockImage(String gName) async {
    final double paper = PrinterPrefs.pixelWidth;
    const double logoSz = 64; // v28: slightly larger for visibility
    const double gap = 12;
    final ui.Image? logo = await _loadLogo(logoSz.toInt());

    TextPainter mkText(String t, double fs, {double? maxW, bool center = false}) {
      final tp = TextPainter(
        text: TextSpan(
            text: t,
            style: TextStyle(
                color: Colors.black, fontSize: fs, fontWeight: FontWeight.bold)),
        textDirection: ui.TextDirection.rtl,
        textAlign: center ? TextAlign.center : TextAlign.right,
      );
      tp.layout(maxWidth: maxW ?? double.infinity);
      return tp;
    }

    // "تطبيق" over "flash" column.
    final tApp = mkText('تطبيق', 16);
    final tFlash = mkText('flash', 16);
    final double appW = tApp.width > tFlash.width ? tApp.width : tFlash.width;
    final double appH = tApp.height + tFlash.height + 2;

    // Generator/station name wraps within the width left of the branding.
    final double leftGroupW = logoSz + gap + appW;
    final double nameMaxW =
        (paper - leftGroupW - gap * 2 - 8).clamp(60.0, paper).toDouble();
    final TextPainter? namePainter =
        gName.isEmpty ? null : mkText(gName, 26, maxW: nameMaxW, center: true);
    final double nameW = namePainter?.width ?? 0;
    final double nameH = namePainter?.height ?? 0;

    final double contentH =
        [logoSz, appH, nameH].reduce((a, b) => a > b ? a : b);
    final double blockH = contentH + 18;
    final double groupW =
        leftGroupW + (namePainter != null ? gap + nameW : 0);
    final double startX = ((paper - groupW) / 2).clamp(0, paper).toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, paper, blockH), Paint()..color = Colors.white);

    // 1) Logo.
    final double logoY = (blockH - logoSz) / 2;
    if (logo != null) {
      canvas.drawImageRect(
        logo,
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        Rect.fromLTWH(startX, logoY, logoSz, logoSz),
        Paint(),
      );
    }
    // 2) تطبيق / flash column.
    final double appX = startX + logoSz + gap;
    final double appY = (blockH - appH) / 2;
    tApp.paint(canvas, Offset(appX, appY));
    tFlash.paint(canvas, Offset(appX, appY + tApp.height + 2));
    // 3) Generator name beside the branding.
    if (namePainter != null) {
      namePainter.paint(
          canvas, Offset(appX + appW + gap, (blockH - nameH) / 2));
    }

    final uiImage =
        await recorder.endRecording().toImage(paper.toInt(), blockH.toInt());
    return _uiToImg(uiImage);
  }

  /// v28 (revised A4-A5): the QR BLOCK — a clearly-scannable QR in a rounded
  /// square frame, CENTERED at the bottom of the receipt. Mandatory.
  Future<img.Image> _qrBlockImage(String data) async {
    final double paper = PrinterPrefs.pixelWidth;
    // v28: reduced QR (58mm → 148px ≈ 18.5mm, 80mm → 156px) — clearly smaller
    // than the old 200/260 but kept at ~4 printer-dots per module so the
    // near-capacity V5 receipt-URL QR stays reliably scannable under thermal
    // dot-gain (120px = 3.24 dots/module risked intermittent scans on 58mm).
    final double qr = PrinterPrefs.is80mm ? 156 : 148;
    const double framePad = 12; // padding between QR and its frame
    final double frame = qr + framePad * 2;
    final double blockH = frame + 16;
    final double startX = ((paper - frame) / 2).clamp(0, paper).toDouble();
    final double frameY = (blockH - frame) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, paper, blockH), Paint()..color = Colors.white);

    // Rounded square frame around the centered QR.
    final rframe = RRect.fromRectAndRadius(
        Rect.fromLTWH(startX, frameY, frame, frame),
        const Radius.circular(14));
    canvas.drawRRect(
        rframe,
        Paint()
          ..color = Colors.black
          ..strokeWidth = 1.8
          ..style = PaintingStyle.stroke);
    final code = bc.Barcode.qrCode(
        errorCorrectLevel: bc.BarcodeQRCorrectionLevel.medium);
    final black = Paint()..color = Colors.black;
    for (final el in code.make(data, width: qr, height: qr)) {
      if (el is bc.BarcodeBar && el.black) {
        canvas.drawRect(
          Rect.fromLTWH(startX + framePad + el.left, frameY + framePad + el.top,
              el.width, el.height),
          black,
        );
      }
    }

    final uiImage =
        await recorder.endRecording().toImage(paper.toInt(), blockH.toInt());
    return _uiToImg(uiImage);
  }

  /// Encodes a [ui.Image] to PNG and decodes it to an [img.Image] for the
  /// ESC/POS rasterizer.
  Future<img.Image> _uiToImg(ui.Image uiImage) async {
    final byteData = await uiImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) throw Exception('render_failed');
    final decoded = img.decodeImage(byteData.buffer.asUint8List());
    if (decoded == null) throw Exception('render_failed');
    return decoded;
  }

  /// URL the receipt QR encodes (same as the Bluetooth service).
  String _receiptQrUrl(Receipt receipt) {
    try {
      final id = Get.find<AuthController>().account.value?.id;
      if (id != null && id.isNotEmpty) {
        return '${ApiConfig.baseUrl}/admin/#/r/${receipt.uuid}';
      }
    } catch (_) {}
    return receipt.uuid;
  }

  /// The header printed on the receipt: the ACTIVE BRANCH name (the generator's
  /// identity for that branch), falling back to the account generator name.
  /// Mirrors the Bluetooth service so both transports print the same header.
  String _generatorName() {
    try {
      final b = Get.find<BranchController>().currentBranch.value;
      final g = Get.find<AuthController>().account.value?.generatorName;
      if (b != null && b.isMainBranch && g != null && g.trim().isNotEmpty) {
        return g.trim();
      }
      if (b != null && !b.isMainBranch && b.name.trim().isNotEmpty) {
        return b.name.trim();
      }
      if (g != null && g.trim().isNotEmpty) return g.trim();
    } catch (_) {}
    return '';
  }

  /// v30 F3: the owner-set contact phone printed on receipts (in place of the
  /// footer), or '' when none is configured. Shared by USB + LAN (LAN reuses
  /// this renderer).
  String _contactPhone() {
    try {
      return Get.find<AuthController>().account.value?.contactPhone?.trim() ??
          '';
    } catch (_) {
      return '';
    }
  }
}
