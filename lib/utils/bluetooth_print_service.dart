import 'package:barcode/barcode.dart' as bc;
import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
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
    bool? isConnected = await bluetooth.isConnected;
    if (isConnected != true) return;

    // v11: print TWO copies in the same operation (one for the subscriber, one
    // to keep). Each iteration emits a full receipt with its own tear-off feed.
    for (int copy = 0; copy < 2; copy++) {
    bluetooth.write(" \n"); // Clear buffer / separate copies

    // Header: generator/business name (set at sign-up)
    await printArabicText(_generatorName(), "", fontSize: 30, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 100));
    await printArabicText("وصل استلام", "", fontSize: 20, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 120));

    // All receipt data inside a bordered table.
    final df = DateFormat('yyyy-MM-dd HH:mm');
    final rows = <List<String>>[
      ["رقم الوصل", receipt.receiptNo.toString()],
      ["التاريخ", df.format(DateTime.parse(receipt.issuedAt))],
      ["المشترك", sub.name],
      ["الشهر", receipt.month],
      ["الأمبيرات", receipt.ampsSnapshot.toString()],
      ["سعر الأمبير", receipt.priceSnapshot.toString()],
      // The tariff type the ampere price belongs to (gold / standard / commercial).
      [
        "نوع الاشتراك",
        SubscriberCategory.arabicLabel(receipt.categorySnapshot ?? sub.category)
      ],
      ["المدفوع", "${receipt.paidAmount} د.ع"],
      // v11: payment method (cash / card).
      ["طريقة الدفع", receiptPaymentMethodText(receipt)],
      // P5: Discount section — type + value, or "no discount".
      ["الخصم", receiptDiscountText(receipt)],
      ["المتبقي", "${receipt.remainingAfter} د.ع"],
    ];
    if (accountantName.isNotEmpty) rows.add(["المحاسب", accountantName]);
    await printArabicTable(rows);
    await Future.delayed(const Duration(milliseconds: 150));

    // QR Code → opens this receipt's details in the admin panel. Rendered as an
    // image (handles long URLs reliably, unlike the native QR command).
    try {
      await _printQrImage(_receiptQrUrl(receipt));
      await Future.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      bluetooth.printCustom("ID: ${receipt.uuid}", 1, 1);
    }

    bluetooth.printNewLine();
    await printArabicText("شكراً لكم!", "", fontSize: 20, textAlign: 1);
    await Future.delayed(const Duration(milliseconds: 100));

    bluetooth.printNewLine();
    bluetooth.printNewLine();
    bluetooth.printNewLine(); // Extra lines for tear-off
    } // end copy loop (two copies)
  }

  /// The header printed on the receipt: the ACTIVE BRANCH name (the generator's
  /// identity for that branch), falling back to the account generator name.
  String _generatorName() {
    try {
      final b = Get.find<BranchController>().currentBranch.value?.name;
      if (b != null && b.trim().isNotEmpty) return b.trim();
    } catch (_) {}
    try {
      final g = Get.find<AuthController>().account.value?.generatorName;
      if (g != null && g.trim().isNotEmpty) return g.trim();
    } catch (_) {}
    return 'TopRank';
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
    const double qr = 240;
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
