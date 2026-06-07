import 'package:blue_thermal_printer/blue_thermal_printer.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
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

    bluetooth.write(" \n"); // Clear buffer

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
      ["المدفوع", "${receipt.paidAmount} د.ع"],
      ["المتبقي", "${receipt.remainingAfter} د.ع"],
    ];
    if (accountantName.isNotEmpty) rows.add(["المحاسب", accountantName]);
    await printArabicTable(rows);
    await Future.delayed(const Duration(milliseconds: 150));

    // QR Code → opens this receipt's details in the admin panel.
    try {
      bluetooth.printQRcode(_receiptQrUrl(receipt), 220, 220, 1);
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
  }

  /// The owner's generator/business name (header), with a safe fallback.
  String _generatorName() {
    try {
      final g = Get.find<AuthController>().account.value?.generatorName;
      if (g != null && g.trim().isNotEmpty) return g.trim();
    } catch (_) {}
    return 'TopRank';
  }

  /// URL the receipt QR encodes: opens the receipt-details screen in the admin
  /// panel. Falls back to the raw uuid if the account id isn't available.
  String _receiptQrUrl(Receipt receipt) {
    try {
      final id = Get.find<AuthController>().account.value?.id;
      if (id != null && id.isNotEmpty) {
        return '${ApiConfig.baseUrl}/admin/#/users/$id/data/receipts/detail/${receipt.uuid}';
      }
    } catch (_) {}
    return receipt.uuid;
  }

  /// Renders rows of [label, value] as a bordered 2-column table image and
  /// prints it (Arabic-safe, like [printArabicText]).
  Future<void> printArabicTable(
    List<List<String>> rows, {
    double fontSize = 22,
  }) async {
    const double width = 380;
    const double pad = 10;
    const double rowGap = 8;
    final double divX = width * 0.45; // left column (value) width

    TextPainter mk(String t, TextAlign align, double maxW) {
      final tp = TextPainter(
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
      return tp;
    }

    final List<TextPainter> labels = [];
    final List<TextPainter> values = [];
    final List<double> heights = [];
    for (final r in rows) {
      final lp = mk(r[0], TextAlign.right, width - divX - pad * 2);
      final vp = mk(r.length > 1 ? r[1] : '', TextAlign.left, divX - pad * 2);
      labels.add(lp);
      values.add(vp);
      heights.add((lp.height > vp.height ? lp.height : vp.height) + rowGap * 2);
    }
    double total = 0;
    for (final h in heights) {
      total += h;
    }
    final int imgH = total.ceil() + 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, imgH.toDouble()),
      Paint()..color = Colors.white,
    );
    final line = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawRect(Rect.fromLTWH(1, 1, width - 2, imgH - 2.0), line);

    double y = 1;
    for (int i = 0; i < rows.length; i++) {
      final rh = heights[i];
      canvas.drawLine(Offset(divX, y), Offset(divX, y + rh), line);
      // label cell (right), value cell (left)
      labels[i].paint(canvas, Offset(divX + pad, y + rowGap));
      values[i].paint(canvas, Offset(pad, y + rowGap));
      y += rh;
      if (i < rows.length - 1) {
        canvas.drawLine(Offset(0, y), Offset(width, y), line);
      }
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), imgH);
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

    // Standard 58mm printer is ~384 pixels wide. 80mm is ~576.
    // We'll assume 380 for safety.
    textPainter.layout(maxWidth: 380);

    // Fill background with white (some printers need this to avoid black blocks)
    final paint = Paint()..color = Colors.white;
    canvas.drawRect(Rect.fromLTWH(0, 0, 380, textPainter.height), paint);

    textPainter.paint(canvas, Offset.zero);

    final picture = recorder.endRecording();
    final img = await picture.toImage(380, textPainter.height.toInt() + 4);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

    if (byteData != null) {
      await bluetooth.printImageBytes(byteData.buffer.asUint8List());
    }
  }
}
