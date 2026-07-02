import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/utils/money.dart';

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
  String paymentMethod = 'cash'; // v11: 'cash' | 'card'
  // v22 item 8: busy latch — a double-tap on Confirm must not run
  // collectPayment twice (duplicate receipt) or call Get.back twice (the
  // second pop would close the UNDERLYING screen).
  bool busy = false;
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

  return Get.dialog<Receipt?>(
    // v22 item 8: barrier locked — dismissing mid-save would discard the saved
    // receipt (payment recorded but never printed/refreshed). Cancel is the
    // only way out, and it is gated while the save is in flight.
    barrierDismissible: false,
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
                    "${'billing_month'.tr}: ${controller.selectedMonth.value}\n${'remaining_fees'.tr}: ${fmtAmount(due)} ${'iqd'.tr}",
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
                // v11: payment method (Cash / Credit card).
                Text('payment_method'.tr,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ChoiceChip(
                        label: Center(child: Text('pay_cash'.tr)),
                        selected: paymentMethod == 'cash',
                        onSelected: (_) =>
                            setLocal(() => paymentMethod = 'cash'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ChoiceChip(
                        label: Center(child: Text('pay_card'.tr)),
                        selected: paymentMethod == 'card',
                        onSelected: (_) =>
                            setLocal(() => paymentMethod = 'card'),
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
                            '${'receipt_price_per_amp'.tr}: ${fmtAmount(pricePerAmp)}',
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
                    Text('${'discount'.tr}: ${fmtAmount(discount)} ${'iqd'.tr}',
                        style: const TextStyle(
                            color: Color(0xFF43A047),
                            fontWeight: FontWeight.bold)),
                  Text('${'amount_to_pay'.tr}: ${fmtAmount(toPay)} ${'iqd'.tr}',
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
              // v22 item 8: gated while saving, and popped via the dialog's OWN
              // route — Get.back would be swallowed by an open snackbar (GetX
              // closes the snackbar and returns without popping the dialog).
              onPressed: busy
                  ? null
                  : () => Navigator.of(context).pop<Receipt?>(null),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _kBlue),
              // v22 item 8: disabled while the save runs (double-tap guard).
              onPressed: busy
                  ? null
                  : () async {
                      setLocal(() => busy = true);
                      // Audit: a throw in collectPayment must not leave the
                      // dialog stuck open with no feedback — surface it and
                      // close. Navigator.pop targets THIS dialog's route, so it
                      // can never pop the underlying screen and is immune to
                      // the GetX snackbar-swallow (which would drop the saved
                      // receipt and strand the dialog in the busy state).
                      try {
                        final receipt = await controller.collectPayment(
                          subscriber,
                          double.tryParse(amountCtrl.text.trim()) ?? 0,
                          fullPayment: full,
                          discountType: full ? discountType : 'none',
                          discountAmps:
                              double.tryParse(discAmpsCtrl.text.trim()) ?? 0,
                          discountValueInput:
                              double.tryParse(discValCtrl.text.trim()) ?? 0,
                          paymentMethod: paymentMethod,
                        );
                        if (context.mounted) {
                          Navigator.of(context).pop<Receipt?>(receipt);
                        }
                      } catch (e) {
                        if (context.mounted) {
                          Navigator.of(context).pop<Receipt?>(null);
                        }
                        Get.snackbar('error'.tr, '$e',
                            backgroundColor: Colors.redAccent,
                            colorText: Colors.white);
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text('confirm_print'.tr),
            ),
          ],
        );
      },
    ),
  );
}
