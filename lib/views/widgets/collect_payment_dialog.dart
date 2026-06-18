import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';

const Color _kBlue = Color(0xFF1565C0);

/// Collect-payment dialog with a FULL / PARTIAL selector and an optional
/// DISCOUNT (P5). The discount is offered ONLY on a full payment (per the
/// requirement); on a partial payment the discount controls are hidden and no
/// discount is sent. Shared by the subscriber-detail and payment-history
/// screens so the logic can't drift.
///
/// Returns the created [Receipt] (the caller prints + refreshes), or null when
/// cancelled / failed.
Future<Receipt?> showCollectPaymentDialog({
  required Subscriber subscriber,
  required double due,
}) {
  final controller = Get.find<BillingController>();
  // Per-amp price for THIS subscriber's category (live discount preview only —
  // collectPayment recomputes the authoritative value from the DB).
  final double pricePerAmp = controller.currentPrices[subscriber.category] ?? 0.0;

  bool full = true; // default to full payment
  String discountType = 'none'; // 'none' | 'ampere' | 'value'
  final amountCtrl = TextEditingController(text: due.toStringAsFixed(0));
  final discAmpsCtrl = TextEditingController();
  final discValCtrl = TextEditingController();

  double computeDiscount() {
    if (!full || discountType == 'none') return 0;
    double d;
    if (discountType == 'ampere') {
      d = (double.tryParse(discAmpsCtrl.text.trim()) ?? 0) * pricePerAmp;
    } else {
      d = double.tryParse(discValCtrl.text.trim()) ?? 0;
    }
    if (d < 0) d = 0;
    if (d > due) d = due;
    return d;
  }

  String money(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(0);

  return Get.dialog<Receipt?>(
    StatefulBuilder(
      builder: (context, setLocal) {
        final double discount = computeDiscount();
        final double toPay = full
            ? (due - discount)
            : (double.tryParse(amountCtrl.text.trim()) ?? 0);

        Widget typeChip(String label, String value) => ChoiceChip(
              label: Text(label),
              selected: discountType == value,
              onSelected: (_) => setLocal(() => discountType = value),
            );

        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('collect_payment'.tr),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "${'billing_month'.tr}: ${controller.selectedMonth.value}\n${'remaining_fees'.tr}: ${money(due)} ${'iqd'.tr}",
                    style: const TextStyle(
                        color: _kBlue, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 16),
                // Full / Partial selector.
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: Center(child: Text('full_payment'.tr)),
                        selected: full,
                        onSelected: (_) => setLocal(() => full = true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: Center(child: Text('partial_payment'.tr)),
                        selected: !full,
                        onSelected: (_) => setLocal(() {
                          full = false;
                          discountType = 'none'; // no discount on partial
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (!full) ...[
                  // Partial: editable amount, no discount.
                  TextField(
                    controller: amountCtrl,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: _kBlue),
                    decoration: InputDecoration(
                      labelText: 'amount_to_pay'.tr,
                      prefixText: '${'iqd'.tr} ',
                      filled: true,
                      fillColor: Colors.grey[50],
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ] else ...[
                  // Full: optional discount.
                  Text('discount'.tr,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      typeChip('no_discount'.tr, 'none'),
                      typeChip('discount_by_amps'.tr, 'ampere'),
                      typeChip('discount_by_value'.tr, 'value'),
                    ],
                  ),
                  if (discountType == 'ampere') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: discAmpsCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'amps_to_discount'.tr,
                        helperText:
                            '${'receipt_price_per_amp'.tr}: ${money(pricePerAmp)}',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ] else if (discountType == 'value') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: discValCtrl,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'discount_amount'.tr,
                        prefixText: '${'iqd'.tr} ',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (_) => setLocal(() {}),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (discount > 0)
                    Text('${'discount'.tr}: ${money(discount)} ${'iqd'.tr}',
                        style: const TextStyle(
                            color: Color(0xFF43A047),
                            fontWeight: FontWeight.bold)),
                  Text('${'amount_to_pay'.tr}: ${money(toPay)} ${'iqd'.tr}',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: _kBlue)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: null),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kBlue),
              onPressed: () async {
                final receipt = await controller.collectPayment(
                  subscriber,
                  double.tryParse(amountCtrl.text.trim()) ?? 0,
                  fullPayment: full,
                  discountType: full ? discountType : 'none',
                  discountAmps:
                      double.tryParse(discAmpsCtrl.text.trim()) ?? 0,
                  discountValueInput:
                      double.tryParse(discValCtrl.text.trim()) ?? 0,
                );
                Get.back(result: receipt);
              },
              child: Text('confirm_print'.tr),
            ),
          ],
        );
      },
    ),
  );
}
