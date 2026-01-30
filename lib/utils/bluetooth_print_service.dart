import 'package:blue_thermal_printer/blue_thermal_printer.dart';
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

    // Header - Render as image for better Arabic support if needed, but keeping English for now
    bluetooth.printCustom("MOLDATI GENERATOR", 3, 1); // Size 3, Center
    bluetooth.printNewLine();

    await printArabicText(
      "وصل استلام #:",
      receipt.receiptNo.toString(),
      fontSize: 20,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    await printArabicText(
      "التاريخ:",
      DateFormat('yyyy-MM-dd HH:mm').format(DateTime.parse(receipt.issuedAt)),
      fontSize: 20,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    bluetooth.printCustom("--------------------------------", 1, 1);

    // Body
    await printArabicText("المشترك: ${sub.name}", "", fontSize: 22);
    await Future.delayed(const Duration(milliseconds: 100));

    await printArabicText("الشهر: ${receipt.month}", "", fontSize: 20);
    await Future.delayed(const Duration(milliseconds: 100));

    await printArabicText(
      "الامبيرات: ${receipt.ampsSnapshot}",
      "",
      fontSize: 20,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    await printArabicText(
      "سعر الامبير: ${receipt.priceSnapshot}",
      "",
      fontSize: 20,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    bluetooth.printCustom("--------------------------------", 1, 1);

    // Financials
    await printArabicText(
      "المدفوع: ${receipt.paidAmount} دينار",
      "",
      fontSize: 26,
      textAlign: 1,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    await printArabicText(
      "المتبقي: ${receipt.remainingAfter} دينار",
      "",
      fontSize: 20,
      textAlign: 1,
    );
    await Future.delayed(const Duration(milliseconds: 100));

    bluetooth.printCustom("--------------------------------", 1, 1);

    // Accountant info
    if (accountantName.isNotEmpty) {
      await printArabicText(
        "المحاسب: $accountantName",
        "",
        fontSize: 18,
        textAlign: 0,
      );
      await Future.delayed(const Duration(milliseconds: 100));
      bluetooth.printCustom("--------------------------------", 1, 1);
    }

    // QR Code
    try {
      bluetooth.printQRcode(receipt.uuid, 200, 200, 1);
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
