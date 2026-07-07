import 'package:barcode/barcode.dart' as bc;
import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:generatormanagment/utils/usb_print_service.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui' as ui;

class BluetoothPrintService {
  BlueThermalPrinter bluetooth = BlueThermalPrinter.instance;

  Future<bool?> get isConnected => bluetooth.isConnected;

  Future<List<BluetoothDevice>> getPairedDevices() async {
    return await bluetooth.getBondedDevices();
  }

  Future<void> connect(BluetoothDevice device) async {
    try {
      if (!(await bluetooth.isConnected ?? false)) {
        await bluetooth.connect(device);
      }
    } catch (e) {
      print("Error connecting to printer: $e");
    }
  }

  Future<void> connectByAddress(String address) async {
    try {
      if (!(await bluetooth.isConnected ?? false)) {
        List<BluetoothDevice> devices = await bluetooth.getBondedDevices();
        BluetoothDevice? device;
        try {
          device = devices.firstWhere((d) => d.address == address);
        } catch (e) {
          device = null;
        }

        if (device != null && device.address != null) {
          await bluetooth.connect(device);
        }
      }
    } catch (e) {
      print("Error connecting by address: $e");
    }
  }

  Future<void> disconnect() async {
    await bluetooth.disconnect();
  }

  Future<void> printReceipt(
    Receipt receipt,
    Subscriber sub,
    String accountantName,
  ) async {
    // v20 item 5: ENSURE the saved printer is connected before sending — if the
    // link dropped, reconnect to the saved address (short retry) so we never
    // report a false "sent". Throws when it truly can't connect; the caller
    // (subscriber_detail / payment_history) catches it and shows "print_failed".
    if (!await _ensureConnected()) {
      throw Exception('printer_not_connected');
    }

    // v27 item 7: resolve the board + circuit display names once (additive
    // lookups; empty when the row is disabled or the id isn't found). Each
    // receipt SECTION is gated by PrinterPrefs.showSection — applies equally to
    // Bluetooth, USB and LAN (they share these gates).
    final String boardName = PrinterPrefs.showSection('sec_board')
        ? (await BoardRepository().nameById(sub.boardId) ?? '')
        : '';
    final String circuitName = PrinterPrefs.showSection('sec_circuit')
        ? (await CircuitRepository().nameById(sub.circuitId) ?? '')
        : '';

    // v20 item 3: print 1 OR 2 copies, from the printer settings (was hard-coded
    // 2). Each iteration emits a full receipt with its own tear-off feed.
    final int copies = PrinterPrefs.copies;
    for (int copy = 0; copy < copies; copy++) {
    bluetooth.write(" \n"); // Clear buffer / separate copies

    // Header (v28 items A1-A3): the app logo + "تطبيق / flash" column at the TOP
    // beside the generator (station) name. v15: never "TopRank" — the generator
    // name is empty when unset / the station section is hidden.
    final gName =
        PrinterPrefs.showSection('sec_station') ? _generatorName() : '';
    await _printHeaderBlock(gName);
    await Future.delayed(const Duration(milliseconds: 100));
    await printArabicText("وصل استلام", "", fontSize: 20, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 120));

    // All receipt data inside a bordered ROUNDED table — each row gated by its
    // section + an expressive icon (v28 items 9/12). A row = (key,label,value).
    final df = DateFormat('yyyy-MM-dd HH:mm');
    final rows = <({String key, String label, String value})>[];
    void add(String key, String label, String value) {
      if (PrinterPrefs.showSection(key)) {
        rows.add((key: key, label: label, value: value));
      }
    }
    add('sec_receipt_no', "رقم الوصل", receipt.receiptNo.toString());
    add('sec_date', "التاريخ", df.format(DateTime.parse(receipt.issuedAt)));
    add('sec_subscriber', "المشترك", sub.name);
    add('sec_month', "الشهر", receipt.month);
    // v27 item 7: NEW printed rows — board + circuit names.
    if (boardName.isNotEmpty) {
      rows.add((key: 'sec_board', label: "البورد", value: boardName));
    }
    if (circuitName.isNotEmpty) {
      rows.add((key: 'sec_circuit', label: "الجوزة", value: circuitName));
    }
    add('sec_amps', "الأمبيرات", receipt.ampsSnapshot.toString());
    add('sec_price', "سعر الأمبير", fmtAmount(receipt.priceSnapshot));
    add('sec_category', "نوع الاشتراك",
        SubscriberCategory.arabicLabel(receipt.categorySnapshot ?? sub.category));
    add('sec_paid', "المدفوع", "${fmtAmount(receipt.paidAmount)} د.ع");
    add('sec_method', "طريقة الدفع", receiptPaymentMethodText(receipt));
    add('sec_discount', "الخصم", receiptDiscountText(receipt));
    add('sec_remaining', "المتبقي", "${fmtAmount(receipt.remainingAfter)} د.ع");
    if (accountantName.isNotEmpty &&
        PrinterPrefs.showSection('sec_accountant')) {
      rows.add((key: 'sec_accountant', label: "المحاسب", value: accountantName));
    }
    for (int i = 0; i < rows.length; i++) {
      await _printTableRow(rows[i].label, rows[i].value,
          iconKey: rows[i].key, top: i == 0, bottom: i == rows.length - 1);
      await Future.delayed(const Duration(milliseconds: 80));
    }
    await Future.delayed(const Duration(milliseconds: 150));

    if (PrinterPrefs.showSection('sec_footer')) {
      bluetooth.printNewLine();
      final contact = _contactPhone();
      if (contact.isNotEmpty) {
        // v30 F3: print the owner's contact phone INSTEAD OF the footer.
        await printArabicText("للتواصل: $contact", "", fontSize: 20, textAlign: 1);
        await Future.delayed(const Duration(milliseconds: 100));
      } else {
        await printArabicText("شكراً لكم!", "", fontSize: 20, textAlign: 1);
        await Future.delayed(const Duration(milliseconds: 100));
        // v20 item 3: footer branding trimmed — "Powered by Flash" only.
        await printArabicText("Powered by Flash", "", fontSize: 18, textAlign: 1);
        await Future.delayed(const Duration(milliseconds: 80));
      }
    }

    // v28 (revised A4-A5): the MANDATORY QR sits at the BOTTOM CENTER, framed +
    // rounded, at a clearly-scannable size (separated by a blank line).
    bluetooth.printNewLine();
    try {
      await _printQrBlock(_receiptQrUrl(receipt));
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      bluetooth.printCustom("ID: ${receipt.uuid}", 1, 1);
    }
    bluetooth.printNewLine(); // single tear-off feed
    } // end copy loop
  }

  /// v23 item 5: print a tiny TEST slip to prove the Bluetooth link works after
  /// pairing (no real receipt/payment needed). Throws on connection failure so
  /// the caller can surface it.
  Future<void> printTest() async {
    if (!await _ensureConnected()) {
      throw Exception('printer_not_connected');
    }
    bluetooth.write(" \n");
    await printArabicText('Flash', '', fontSize: 30, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 100));
    await printArabicText('اختبار الطباعة — Test print', '',
        fontSize: 22, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 100));
    bluetooth.printNewLine();
    bluetooth.printNewLine();
  }

  /// v20 item 5: guarantee a live connection to the SAVED printer before
  /// printing. Returns true only when actually connected; reconnects (1 retry)
  /// to the persisted address if the link dropped. Never reports a false "sent".
  Future<bool> _ensureConnected() async {
    if (await bluetooth.isConnected == true) return true;
    final prefs = await SharedPreferences.getInstance();
    final address = prefs.getString('printer_address') ?? '';
    if (address.isEmpty) return false;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final devices = await bluetooth.getBondedDevices();
        BluetoothDevice? device;
        try {
          device = devices.firstWhere((d) => d.address == address);
        } catch (_) {
          device = null;
        }
        if (device != null && device.address != null) {
          await bluetooth.connect(device);
          await Future.delayed(const Duration(milliseconds: 600));
        }
      } catch (_) {/* retry below */}
      if (await bluetooth.isConnected == true) return true;
      await Future.delayed(const Duration(milliseconds: 400));
    }
    return await bluetooth.isConnected == true;
  }

  /// The header printed on the receipt: the ACTIVE BRANCH name (the generator's
  /// identity for that branch), falling back to the account generator name.
  String _generatorName() {
    try {
      final b = Get.find<BranchController>().currentBranch.value;
      final g = Get.find<AuthController>().account.value?.generatorName;
      // v14: the MAIN branch prints the registration generator name, never the
      // stored "main branch" literal; other branches keep their own name.
      if (b != null && b.isMainBranch && g != null && g.trim().isNotEmpty) {
        return g.trim();
      }
      // Only a NON-main branch falls back to its stored name (the main branch's
      // stored name is the "main branch" literal, which must never be printed).
      if (b != null && !b.isMainBranch && b.name.trim().isNotEmpty) {
        return b.name.trim();
      }
      if (g != null && g.trim().isNotEmpty) return g.trim();
    } catch (_) {}
    // v15: never print the "TopRank" literal — generator name only.
    return '';
  }

  /// v30 F3: the owner-set contact phone printed on receipts (in place of the
  /// footer), or '' when none is configured. For an accountant this is the
  /// owner's number, injected into the session by the backend.
  String _contactPhone() {
    try {
      return Get.find<AuthController>().account.value?.contactPhone?.trim() ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// URL the receipt QR encodes: opens the public receipt page (no login) in the
  /// admin panel. Falls back to the raw uuid if the account isn't available.
  String _receiptQrUrl(Receipt receipt) {
    try {
      final id = Get.find<AuthController>().account.value?.id;
      if (id != null && id.isNotEmpty) {
        return '${ApiConfig.baseUrl}/admin/#/r/${receipt.uuid}';
      }
    } catch (_) {}
    return receipt.uuid;
  }

  /// Loads the app logo (`images/blue.png`) as a ui.Image sized to [target]px.
  Future<ui.Image?> _loadLogo(int target) async {
    try {
      final d = await rootBundle.load('images/blue.png');
      final codec = await ui.instantiateImageCodec(d.buffer.asUint8List(),
          targetWidth: target);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  /// v28 (revised A1-A3): prints the TOP header block — the app logo + a
  /// "تطبيق / flash" column beside the generator (station) name, centered.
  /// Geometry matches `UsbPrintService._headerBlockImage`.
  Future<void> _printHeaderBlock(String gName) async {
    final double paper = PrinterPrefs.pixelWidth;
    const double logoSz = 64; // v28: slightly larger for visibility
    const double gap = 12;
    final ui.Image? logo = await _loadLogo(logoSz.toInt());

    TextPainter mkText(String t, double fs,
        {double? maxW, bool center = false}) {
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

    final tApp = mkText('تطبيق', 16);
    final tFlash = mkText('flash', 16);
    final double appW = tApp.width > tFlash.width ? tApp.width : tFlash.width;
    final double appH = tApp.height + tFlash.height + 2;

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
    final double groupW = leftGroupW + (namePainter != null ? gap + nameW : 0);
    final double startX = ((paper - groupW) / 2).clamp(0, paper).toDouble();

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, paper, blockH), Paint()..color = Colors.white);

    final double logoY = (blockH - logoSz) / 2;
    if (logo != null) {
      canvas.drawImageRect(
        logo,
        Rect.fromLTWH(0, 0, logo.width.toDouble(), logo.height.toDouble()),
        Rect.fromLTWH(startX, logoY, logoSz, logoSz),
        Paint(),
      );
    }
    final double appX = startX + logoSz + gap;
    final double appY = (blockH - appH) / 2;
    tApp.paint(canvas, Offset(appX, appY));
    tFlash.paint(canvas, Offset(appX, appY + tApp.height + 2));
    if (namePainter != null) {
      namePainter.paint(
          canvas, Offset(appX + appW + gap, (blockH - nameH) / 2));
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(paper.toInt(), blockH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }

  /// v28 (revised A4-A5): prints the QR BLOCK — a clearly-scannable QR in a
  /// rounded square frame, CENTERED at the bottom. Geometry matches
  /// `UsbPrintService._qrBlockImage` so all transports look identical.
  Future<void> _printQrBlock(String data) async {
    final double paper = PrinterPrefs.pixelWidth;
    // v28: reduced QR (58mm → 148px ≈ 18.5mm, 80mm → 156px) — clearly smaller
    // than the old 200/260 but kept at ~4 printer-dots per module so the
    // near-capacity V5 receipt-URL QR stays reliably scannable under thermal
    // dot-gain (120px = 3.24 dots/module risked intermittent scans on 58mm).
    final double qr = PrinterPrefs.is80mm ? 156 : 148;
    const double framePad = 12;
    final double frame = qr + framePad * 2;
    final double blockH = frame + 16;
    final double startX = ((paper - frame) / 2).clamp(0, paper).toDouble();
    final double frameY = (blockH - frame) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
        Rect.fromLTWH(0, 0, paper, blockH), Paint()..color = Colors.white);

    canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(startX, frameY, frame, frame),
            const Radius.circular(14)),
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

    final picture = recorder.endRecording();
    final image = await picture.toImage(paper.toInt(), blockH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }

  /// Renders one bordered 2-column row (label | value) with a section ICON and
  /// ROUNDED outer corners (v28 items 9/12), then prints it. Geometry matches
  /// `UsbPrintService._tableRowImage` so BT and USB/LAN look identical.
  Future<void> _printTableRow(
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
    final double divX = width * 0.45; // left column (value) width

    // v28 (RTL): the section ICON is anchored at the FAR RIGHT and the label is
    // right-aligned flush to its left, painted as SEPARATE runs so BiDi never
    // moves the Material glyph to the wrong side. Values are right-aligned in the
    // left column too, so ALL table data reads right-to-left. Geometry matches
    // `UsbPrintService._tableRowImage`.
    const double iconGap = 6;
    final IconData? ic =
        iconKey == null ? null : UsbPrintService.sectionIcons[iconKey];
    TextPainter? iconTp;
    if (ic != null) {
      iconTp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(ic.codePoint),
          style: TextStyle(
              fontFamily: ic.fontFamily,
              package: ic.fontPackage,
              color: Colors.black,
              fontSize: fontSize),
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

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), h);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }

  /// Helper to print Arabic text by rendering it to an image first.
  /// This is necessary because most thermal printers do not support Arabic/RTL natively.
  Future<void> printArabicText(
    String label,
    String value, {
    double fontSize = 24,
    int textAlign = 0,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);

    // Combine label and value for a single line if needed, or just print the text
    String fullText = value.isEmpty ? label : "$label $value";

    final textPainter = TextPainter(
      text: TextSpan(
        text: fullText,
        style: TextStyle(
          color: Colors.black,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: ui.TextDirection.rtl,
      textAlign: textAlign == 1
          ? TextAlign.center
          : (textAlign == 2 ? TextAlign.left : TextAlign.right),
    );

    // Paper pixel width depends on the selected setting: ~384px for a 58mm
    // roll, ~576px for an 80mm roll.
    final double width = PrinterPrefs.pixelWidth;
    textPainter.layout(maxWidth: width);

    // Fill background with white (some printers need this to avoid black blocks)
    final paint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, width, textPainter.height), paint);

    textPainter.paint(canvas, Offset.zero);

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), textPainter.height.toInt() + 4);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }
}
