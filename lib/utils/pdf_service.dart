import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';

class PdfService {
  Future<Uint8List> generateReceipt(Receipt receipt, Subscriber sub) async {
    final pdf = pw.Document();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80, // Thermal printer width
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                "MOLDATI GENERATOR",
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Text("Receipt #: ${receipt.receiptNo}"),
              pw.Text("Date: ${receipt.issuedAt}"),
              pw.Divider(),
              pw.Text("Customer: ${sub.name}"),
              pw.Text("Month: ${receipt.month}"),
              pw.Text("Amps: ${receipt.ampsSnapshot}"),
              pw.Text("Price/Amp: ${receipt.priceSnapshot}"),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    "PAID:",
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                  pw.Text(
                    "${receipt.paidAmount}",
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text("Remaining:"),
                  pw.Text("${receipt.remainingAfter}"),
                ],
              ),
              pw.Divider(),
              pw.Center(
                child: pw.BarcodeWidget(
                  data:
                      receipt.qrToken ?? "${receipt.uuid}|${receipt.receiptNo}",
                  width: 100,
                  height: 100,
                  barcode: pw.Barcode.qrCode(),
                ),
              ),
              pw.SizedBox(height: 10),
              pw.Center(child: pw.Text("Thank you!")),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  Future<void> printReceipt(Receipt receipt, Subscriber sub) async {
    final pdfBytes = await generateReceipt(receipt, sub);
    await Printing.layoutPdf(
      onLayout: (PdfPageFormat format) async => pdfBytes,
      name: 'Receipt_${receipt.receiptNo}',
    );
  }
}
