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
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
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

    // Header: generator/business name (set at sign-up). v15: never "TopRank";
    // print nothing when there is no generator name.
    final gName = _generatorName();
    if (PrinterPrefs.showSection('sec_station') && gName.isNotEmpty) {
      await printArabicText(gName, "", fontSize: 30, textAlign: 1);
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await printArabicText("وصل استلام", "", fontSize: 20, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 120));

    // All receipt data inside a bordered table — each row gated by its section.
    final df = DateFormat('yyyy-MM-dd HH:mm');
    final rows = <List<String>>[];
    void add(String key, String label, String value) {
      if (PrinterPrefs.showSection(key)) rows.add([label, value]);
    }
    add('sec_receipt_no', "رقم الوصل", receipt.receiptNo.toString());
    add('sec_date', "التاريخ", df.format(DateTime.parse(receipt.issuedAt)));
    add('sec_subscriber', "المشترك", sub.name);
    add('sec_month', "الشهر", receipt.month);
    // v27 item 7: NEW printed rows — board + circuit names.
    if (boardName.isNotEmpty) rows.add(["البورد", boardName]);
    if (circuitName.isNotEmpty) rows.add(["الجوزة", circuitName]);
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
      rows.add(["المحاسب", accountantName]);
    }
    await printArabicTable(rows);
    await Future.delayed(const Duration(milliseconds: 150));

    // QR Code → opens this receipt's details in the admin panel. Rendered as an
    // image (handles long URLs reliably, unlike the native QR command).
    if (PrinterPrefs.showSection('sec_qr')) {
      try {
        await _printQrImage(_receiptQrUrl(receipt));
        await Future.delayed(const Duration(milliseconds: 100));
      } catch (e) {
        bluetooth.printCustom("ID: ${receipt.uuid}", 1, 1);
      }
    }

    if (PrinterPrefs.showSection('sec_footer')) {
      bluetooth.printNewLine();
      await printArabicText("شكراً لكم!", "", fontSize: 20, textAlign: 1);
      await Future.delayed(const Duration(milliseconds: 100));
      // v20 item 3: footer branding trimmed — "Powered by Flash" only.
      await printArabicText("Powered by Flash", "", fontSize: 18, textAlign: 1);
      await Future.delayed(const Duration(milliseconds: 80));
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

  /// Renders [data] as a QR code image (centred on the paper) and prints it.
  /// Image path is reliable for long URLs where the native QR command garbles.
  Future<void> _printQrImage(String data) async {
    final double paper = PrinterPrefs.pixelWidth;
    const double qr = 160; // v23 item 5: QR reduced slightly (was 190)
    final double off = (paper - qr) / 2;
    final code = bc.Barcode.qrCode(
      errorCorrectLevel: bc.BarcodeQRCorrectionLevel.medium,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, paper, qr + 8),
      Paint()..color = Colors.white,
    );
    final black = Paint()..color = Colors.black;
    for (final el in code.make(data, width: qr, height: qr)) {
      if (el is bc.BarcodeBar && el.black) {
        canvas.drawRect(
          Rect.fromLTWH(off + el.left, 4 + el.top, el.width, el.height),
          black,
        );
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(paper.toInt(), (qr + 8).toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }

  /// Prints rows of [label, value] as a 2-column table. Each ROW is rendered as
  /// its own small image (same size class as [printArabicText], which prints
  /// reliably) — a single large image was corrupting output on some printers.
  Future<void> printArabicTable(
    List<List<String>> rows, {
    double fontSize = 22,
  }) async {
    for (int i = 0; i < rows.length; i++) {
      await _printTableRow(
        rows[i][0],
        rows[i].length > 1 ? rows[i][1] : '',
        fontSize: fontSize,
        top: i == 0,
      );
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  /// Renders one bordered 2-column row (label | value) to a small image.
  Future<void> _printTableRow(
    String label,
    String value, {
    double fontSize = 22,
    bool top = false,
  }) async {
    final double width = PrinterPrefs.pixelWidth;
    const double pad = 10;
    const double rowGap = 8;
    final double divX = width * 0.45; // left column (value) width

    TextPainter mk(String t, TextAlign align, double maxW) {
      return TextPainter(
        text: TextSpan(
          text: t,
          style: TextStyle(
            color: Colors.black,
            fontSize: fontSize,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: ui.TextDirection.rtl,
        textAlign: align,
      )..layout(maxWidth: maxW);
    }

    final lp = mk(label, TextAlign.right, width - divX - pad * 2);
    final vp = mk(value, TextAlign.left, divX - pad * 2);
    final double rh = (lp.height > vp.height ? lp.height : vp.height) + rowGap * 2;
    final int h = rh.ceil() + 1;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, h.toDouble()),
      Paint()..color = Colors.white,
    );
    final line = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final double hh = h.toDouble();
    canvas.drawLine(const Offset(1, 0), Offset(1, hh), line); // left
    canvas.drawLine(Offset(width - 1, 0), Offset(width - 1, hh), line); // right
    canvas.drawLine(Offset(0, hh - 1), Offset(width, hh - 1), line); // bottom
    canvas.drawLine(Offset(divX, 0), Offset(divX, hh), line); // divider
    if (top) canvas.drawLine(const Offset(0, 1), Offset(width, 1), line);

    lp.paint(canvas, Offset(divX + pad, rowGap));
    vp.paint(canvas, Offset(pad, rowGap));

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
