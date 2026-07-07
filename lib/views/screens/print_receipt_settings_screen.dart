import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';

/// v27 item 7 — "إعدادات الوصل المطبوع": toggle which sections appear on the
/// printed receipt. Applies EQUALLY to Bluetooth, USB and LAN (they share the
/// renderer). Every section defaults to ON. RTL/responsive via the app theme.
/// v30 F3: also hosts the owner-set CONTACT PHONE printed in place of the footer.
class PrintReceiptSettingsScreen extends StatefulWidget {
  const PrintReceiptSettingsScreen({super.key});

  @override
  State<PrintReceiptSettingsScreen> createState() =>
      _PrintReceiptSettingsScreenState();
}

class _PrintReceiptSettingsScreenState
    extends State<PrintReceiptSettingsScreen> {
  final AuthController _auth = Get.find<AuthController>();
  final TextEditingController _phoneCtrl = TextEditingController();
  bool _savingPhone = false;

  @override
  void initState() {
    super.initState();
    _phoneCtrl.text = _auth.account.value?.contactPhone ?? '';
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    super.dispose();
  }

  /// v30 F3: save the contact phone (owner/admin only). Sends "" to clear.
  Future<void> _saveContactPhone() async {
    if (_savingPhone) return;
    setState(() => _savingPhone = true);
    final res = await _auth.updateProfile(contactPhone: _phoneCtrl.text.trim());
    if (!mounted) return;
    setState(() => _savingPhone = false);
    final bool ok = res['success'] != false;
    Get.snackbar(
      ok ? 'success'.tr : 'error'.tr,
      ok ? 'contact_phone_saved'.tr : (res['message']?.toString() ?? 'error'.tr),
      backgroundColor: ok ? Colors.green : Colors.redAccent,
      colorText: Colors.white,
      snackPosition: SnackPosition.BOTTOM,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text('print_settings'.tr,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8, left: 4, right: 4),
              child: Text('print_settings_subtitle'.tr,
                  style: const TextStyle(color: Colors.blueGrey)),
            ),
            // v30 F3: contact phone printed on the receipt instead of the footer.
            // Owner/admin can edit it; an accountant sees it read-only.
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.phone, color: Color(0xFF1565C0)),
                      const SizedBox(width: 8),
                      Text('contact_phone'.tr,
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('contact_phone_hint'.tr,
                      style: const TextStyle(
                          color: Colors.blueGrey, fontSize: 12)),
                  const SizedBox(height: 12),
                  if (_auth.isAdmin)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: InputDecoration(
                              hintText: 'contact_phone'.tr,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF1565C0),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: _savingPhone ? null : _saveContactPhone,
                          child: _savingPhone
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white))
                              : Text('save'.tr),
                        ),
                      ],
                    )
                  else
                    Text(
                      (_auth.account.value?.contactPhone?.trim().isNotEmpty ??
                              false)
                          ? _auth.account.value!.contactPhone!.trim()
                          : '—',
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (final key in PrinterPrefs.sectionKeys)
                    SwitchListTile(
                      activeThumbColor: const Color(0xFF1565C0),
                      title: Text(key.tr),
                      value: PrinterPrefs.showSection(key),
                      onChanged: (v) async {
                        await PrinterPrefs.setSection(key, v);
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
