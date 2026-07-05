import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';

/// v27 item 7 — "إعدادات الوصل المطبوع": toggle which sections appear on the
/// printed receipt. Applies EQUALLY to Bluetooth, USB and LAN (they share the
/// renderer). Every section defaults to ON. RTL/responsive via the app theme.
class PrintReceiptSettingsScreen extends StatefulWidget {
  const PrintReceiptSettingsScreen({super.key});

  @override
  State<PrintReceiptSettingsScreen> createState() =>
      _PrintReceiptSettingsScreenState();
}

class _PrintReceiptSettingsScreenState
    extends State<PrintReceiptSettingsScreen> {
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
