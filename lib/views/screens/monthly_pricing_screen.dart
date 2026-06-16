import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:intl/intl.dart';

class MonthlyPricingScreen extends StatefulWidget {
  const MonthlyPricingScreen({super.key});

  @override
  State<MonthlyPricingScreen> createState() => _MonthlyPricingScreenState();
}

class _MonthlyPricingScreenState extends State<MonthlyPricingScreen> {
  final BillingController controller = Get.find<BillingController>();
  final AuthController auth = Get.find<AuthController>();

  // One price input per category (R4): commercial / standard / gold.
  late final Map<String, TextEditingController> _priceCtrls = {
    for (final cat in SubscriberCategory.all) cat: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    _seedFields(controller.currentPrices);
    // Re-seed the three fields whenever the selected month's prices change
    // (e.g. after picking a different month or saving).
    ever(controller.currentPrices, _seedFields);
  }

  /// Pre-fill each category field from [prices] (blank when no price is set).
  void _seedFields(Map<String, double> prices) {
    for (final cat in SubscriberCategory.all) {
      final v = prices[cat];
      _priceCtrls[cat]!.text = v == null ? '' : _fmt(v);
    }
  }

  /// Trim a trailing `.0` so whole numbers show without a decimal point.
  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  String _catLabel(String cat) {
    switch (cat) {
      case SubscriberCategory.commercial:
        return 'cat_commercial'.tr;
      case SubscriberCategory.gold:
        return 'cat_gold'.tr;
      default:
        return 'cat_standard'.tr;
    }
  }

  /// Save every category whose field holds a non-empty, valid number (R4).
  Future<void> _saveAll() async {
    bool any = false;
    for (final cat in SubscriberCategory.all) {
      final text = _priceCtrls[cat]!.text.trim();
      if (text.isEmpty) continue;
      final p = double.tryParse(text);
      if (p == null) continue;
      await controller.setPrice(p, category: cat);
      any = true;
    }
    if (any) {
      Get.snackbar(
        'success'.tr,
        'price_updated'.tr,
        backgroundColor: Colors.green,
        colorText: Colors.white,
      );
    }
  }

  @override
  void dispose() {
    for (final c in _priceCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD), // Light blue background
      appBar: AppBar(
        title: Text(
          'monthly_pricing'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            // Month Selector Card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'billing_month'.tr,
                    style: const TextStyle(color: Colors.grey),
                  ),
                  Row(
                    children: [
                      Obx(
                        () => Text(
                          controller.selectedMonth.value,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1565C0),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(
                          Icons.calendar_month,
                          color: Color(0xFF1565C0),
                        ),
                        onPressed: () async {
                          DateTime? picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2020),
                            lastDate: DateTime(2030),
                          );
                          if (picked != null) {
                            String m = DateFormat('yyyy-MM').format(picked);
                            controller.changeMonth(m);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Price Content
            Obx(() {
              if (controller.isLoading.value) {
                return const Center(child: CircularProgressIndicator());
              }
              final price = controller.currentPrice.value;
              return Column(
                children: [
                  // Current Price Display (standard, back-compat headline)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.blue.withOpacity(0.1),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Text(
                          'current_price_per_amp'.tr,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          price?.pricePerAmp.toString() ?? 'not_set'.tr,
                          style: TextStyle(
                            fontSize: 48,
                            fontWeight: FontWeight.bold,
                            color: (price?.pricePerAmp != null)
                                ? const Color(0xFF43A047)
                                : Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (price?.locked == 1)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEBEE),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.lock,
                                  size: 14,
                                  color: Color(0xFFD32F2F),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  'price_locked_badge'.tr,
                                  style: const TextStyle(
                                    color: Color(0xFFD32F2F),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Text(
                            'iqd_per_ampere'.tr,
                            style: const TextStyle(color: Colors.grey),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Set New Prices Input — one field per category (R4).
                  if (price?.locked != 1 && auth.can(Perm.prices)) ...[
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.blue.withOpacity(0.05),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'update_price'.tr,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1565C0),
                            ),
                          ),
                          const SizedBox(height: 16),
                          for (final cat in SubscriberCategory.all) ...[
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Text(
                                '${_catLabel(cat)} — ${'price_per_amp'.tr}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1565C0),
                                ),
                              ),
                            ),
                            TextField(
                              controller: _priceCtrls[cat],
                              keyboardType: TextInputType.number,
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              decoration: InputDecoration(
                                hintText: 'enter_new_price'.tr,
                                prefixText: "IQD ",
                                filled: true,
                                fillColor: Colors.grey[50],
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 16,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                          const SizedBox(height: 4),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: _saveAll,
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1565C0),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 16,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              child: Text(
                                'save_price'.tr,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else if (price?.locked == 1)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.orange.withOpacity(0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.orange),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'pricing_locked_message'.tr,
                              style: const TextStyle(
                                color: Colors.orangeAccent,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}
