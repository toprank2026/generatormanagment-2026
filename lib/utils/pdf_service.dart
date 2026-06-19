import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';

class PdfService {
  Future<Uint8List> generateReceipt(Receipt receipt, Subscriber sub,
      {String accountantName = ''}) async {
    final pdf = pw.Document();

    // Load bundled Cairo so Arabic renders correctly in the PDF.
    pw.Font? cairo;
    try {
      cairo = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo.ttf'));
    } catch (_) {}

    final gName = _generatorName();
    final qrData = _receiptQrUrl(receipt);

    final rows = <List<String>>[
      ['رقم الوصل', '${receipt.receiptNo}'],
      ['التاريخ', receipt.issuedAt],
      ['المشترك', sub.name],
      ['الشهر', receipt.month],
      ['الأمبيرات', '${receipt.ampsSnapshot}'],
      ['سعر الأمبير', '${receipt.priceSnapshot}'],
      // The tariff type the ampere price belongs to (gold / standard / commercial).
      [
        'نوع التعرفة',
        SubscriberCategory.arabicLabel(receipt.categorySnapshot ?? sub.category)
      ],
      ['المدفوع', '${receipt.paidAmount} د.ع'],
      // P5: Discount section — type + value, or "no discount".
      ['الخصم', receiptDiscountText(receipt)],
      ['المتبقي', '${receipt.remainingAfter} د.ع'],
      // The accountant this invoice belongs to (omitted for owner-owned).
      if (accountantName.trim().isNotEmpty) ['المحاسب', accountantName.trim()],
    ];

    pw.Widget cell(String t, {bool bold = false}) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: pw.Text(
            t,
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        );

    pdf.addPage(
      pw.Page(
        // Thermal printer width — roll57 for 58mm, roll80 for 80mm (setting).
        pageFormat: PrinterPrefs.pdfPageFormat,
        theme: cairo != null
            ? pw.ThemeData.withFont(base: cairo, bold: cairo)
            : null,
        build: (pw.Context context) {
          return pw.Directionality(
            textDirection: pw.TextDirection.rtl,
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Center(
                  child: pw.Text(
                    gName,
                    style: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Center(
                  child: pw.Text('وصل استلام',
                      style: const pw.TextStyle(fontSize: 11)),
                ),
                pw.SizedBox(height: 8),
                // All receipt data inside a table.
                pw.Table(
                  border: pw.TableBorder.all(width: 0.6),
                  columnWidths: const {
                    0: pw.FlexColumnWidth(1.2),
                    1: pw.FlexColumnWidth(1),
                  },
                  children: rows
                      .map(
                        (r) => pw.TableRow(
                          children: [cell(r[0], bold: true), cell(r[1])],
                        ),
                      )
                      .toList(),
                ),
                pw.SizedBox(height: 12),
                pw.Center(
                  child: pw.BarcodeWidget(
                    data: qrData,
                    width: 95,
                    height: 95,
                    barcode: pw.Barcode.qrCode(),
                  ),
                ),
                pw.SizedBox(height: 8),
                pw.Center(child: pw.Text('شكراً لكم')),
              ],
            ),
          );
        },
      ),
    );

    return pdf.save();
  }

  Future<void> printReceipt(Receipt receipt, Subscriber sub,
      {String accountantName = ''}) async {
    final pdfBytes =
        await generateReceipt(receipt, sub, accountantName: accountantName);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
      name: 'Receipt_${receipt.receiptNo}',
    );
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
  /// admin panel. Falls back to a compact id token if the account isn't available.
  String _receiptQrUrl(Receipt receipt) {
    try {
      final id = Get.find<AuthController>().account.value?.id;
      if (id != null && id.isNotEmpty) {
        return '${ApiConfig.baseUrl}/admin/#/r/${receipt.uuid}';
      }
    } catch (_) {}
    return receipt.qrToken ?? '${receipt.uuid}|${receipt.receiptNo}';
  }
}
