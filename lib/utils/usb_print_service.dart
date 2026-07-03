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
      }
      bytes.addAll(gen.cut()); // auto-cut

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

  /// Builds the ordered list of receipt images (header → table rows → QR →
  /// footer), 1:1 with the rows the Bluetooth `printReceipt` emits.
  Future<List<img.Image>> _buildReceiptImages(
    Receipt receipt,
    Subscriber sub,
    String accountantName,
  ) async {
    final df = DateFormat('yyyy-MM-dd HH:mm');
    final List<img.Image> out = [];

    // Header.
    final String gName = _generatorName();
    if (gName.isNotEmpty) {
      out.add(await _textImage(gName, 30, center: true));
    }
    out.add(await _textImage('وصل استلام', 20, center: true));

    // Bordered table — the SAME rows (incl. payment method + discount).
    final List<List<String>> rows = [
      ['رقم الوصل', receipt.receiptNo.toString()],
      ['التاريخ', df.format(DateTime.parse(receipt.issuedAt))],
      ['المشترك', sub.name],
      ['الشهر', receipt.month],
      ['الأمبيرات', receipt.ampsSnapshot.toString()],
      ['سعر الأمبير', fmtAmount(receipt.priceSnapshot)],
      [
        'نوع الاشتراك',
        SubscriberCategory.arabicLabel(receipt.categorySnapshot ?? sub.category),
      ],
      ['المدفوع', '${fmtAmount(receipt.paidAmount)} د.ع'],
      ['طريقة الدفع', receiptPaymentMethodText(receipt)],
      ['الخصم', receiptDiscountText(receipt)],
      ['المتبقي', '${fmtAmount(receipt.remainingAfter)} د.ع'],
    ];
    if (accountantName.isNotEmpty) rows.add(['المحاسب', accountantName]);
    for (int i = 0; i < rows.length; i++) {
      out.add(await _tableRowImage(rows[i][0], rows[i][1], top: i == 0));
    }

    // QR (opens this receipt in the admin panel). Skipped only if it fails.
    try {
      out.add(await _qrImage(_receiptQrUrl(receipt)));
    } catch (_) {/* QR is best-effort, like the Bluetooth path */}

    // Footer.
    out.add(await _textImage('شكراً لكم!', 20, center: true));
    out.add(await _textImage('Powered by Flash', 18, center: true));
    return out;
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

  /// Renders one bordered 2-column row (label | value) — identical geometry to
  /// `BluetoothPrintService._printTableRow` so the table looks the same.
  Future<img.Image> _tableRowImage(
    String label,
    String value, {
    double fontSize = 22,
    bool top = false,
  }) async {
    final double width = PrinterPrefs.pixelWidth;
    const double pad = 10;
    const double rowGap = 8;
    final double divX = width * 0.45; // value column width

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
    final double rh =
        (lp.height > vp.height ? lp.height : vp.height) + rowGap * 2;
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
    final uiImage = await picture.toImage(width.toInt(), h);
    return _uiToImg(uiImage);
  }

  /// Renders [data] as a centered QR image — identical to the Bluetooth path.
  Future<img.Image> _qrImage(String data) async {
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
    final uiImage = await picture.toImage(paper.toInt(), (qr + 8).toInt());
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
}
