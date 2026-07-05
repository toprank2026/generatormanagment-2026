import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/views/screens/subscription_screen.dart';
import 'package:generatormanagment/views/screens/accountant_settlements_screen.dart';
import 'package:generatormanagment/views/screens/accountants_screen.dart';
import 'package:generatormanagment/views/screens/edit_account_screen.dart';
import 'package:generatormanagment/views/screens/print_receipt_settings_screen.dart';
import 'package:generatormanagment/views/screens/my_wallet_screen.dart';
import 'package:generatormanagment/views/screens/branches_screen.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/repositories/device_repository.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
import 'package:generatormanagment/utils/lan_print_service.dart';
import 'package:generatormanagment/utils/usb_print_service.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final SettingsController controller = Get.find<SettingsController>();
  final AuthController auth = Get.find<AuthController>();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // v24: re-read printer prefs (idempotent) — a LAN endpoint auto-discovered
    // during a print is persisted in PrinterPrefs but the controller obs only
    // refresh here, so opening Settings always shows the real saved printer.
    controller.loadPrinterSettings();
    // Refresh cloud backups for logged-in owners.
    if (auth.isLoggedIn.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        controller.refreshCloudBackups();
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Accountants are a small owner-managed set (no pagination); nothing to do.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'settings'.tr,
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
      body: SafeArea(
          child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Profile Card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withOpacity(0.05),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.blue[100],
                    child: Icon(
                      Icons.person,
                      size: 32,
                      color: Colors.blue[800],
                    ),
                  ),
                  const SizedBox(width: 16),
                  // Reactive so it reflects the ACTING user after a profile
                  // switch (owner <-> accountant), not the cloud account.
                  Obx(() {
                    final bool acting = auth.isAdmin;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.currentUser.value?.displayName ??
                              'user_default'.tr,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        Container(
                          margin: const EdgeInsets.only(top: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color:
                                acting ? Colors.purple[50] : Colors.green[50],
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            (auth.currentUser.value?.role ?? "").toUpperCase(),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: acting ? Colors.purple : Colors.green,
                            ),
                          ),
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // v16: the in-app account SWITCH (owner <-> accountant) was removed
            // here — it left the session in a flaky state (token/secure-storage)
            // so sync could be rejected. Use logout + login to change accounts,
            // which establishes a clean session every time.

            // Subscription Section (owner-only). Obx so it reacts to a
            // user switch (an accountant acting on this device must not see it).
            Obx(() {
              if (!auth.isAdmin) return const SizedBox.shrink();
              return Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 8),
                      child: Text(
                        'subscription'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.blueGrey,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: const Icon(
                        Icons.workspace_premium,
                        color: Color(0xFF1565C0),
                      ),
                      title: Text('manage_subscription'.tr),
                      subtitle: Text(
                        auth.subscription?.planCode ?? 'no_active_plan'.tr,
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () => Get.to(() => const SubscriptionScreen()),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            }),

            // My Wallet (accountant-only) — collected total + settlement requests.
            Obx(() {
              if (!auth.isAccountant) return const SizedBox.shrink();
              return Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.account_balance_wallet,
                          color: Color(0xFF1565C0)),
                      title: Text('my_wallet'.tr),
                      subtitle: Text('settlement_history'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const MyWalletScreen()),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            }),

            // v20 item 4: edit OWN account (owner/admin only — accountants edit
            // via the owner). Opens the self-edit screen.
            Obx(() {
              if (!auth.isAdmin) return const SizedBox.shrink();
              return Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.manage_accounts,
                          color: Color(0xFF1565C0)),
                      title: Text('edit_account'.tr),
                      subtitle: Text('edit_account_subtitle'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const EditAccountScreen()),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            }),

            // Accountants (owner-only). Opens the dedicated management screen.
            // Obx so it reacts to a user switch (hidden while an accountant
            // is acting on this device).
            Obx(() {
              if (!auth.isAdmin) return const SizedBox.shrink();
              return Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading:
                          const Icon(Icons.badge, color: Color(0xFF1565C0)),
                      title: Text('accountants'.tr),
                      subtitle: Text('manage_accountants_subtitle'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const AccountantsScreen()),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // v16 item 7: in-app accountant settlement approval (Admin-only).
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.fact_check,
                          color: Color(0xFF1565C0)),
                      title: Text('accountant_settlements'.tr),
                      subtitle: Text('accountant_settlements_subtitle'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Get.to(() => const AccountantSettlementsScreen()),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            }),

            // Branches (owner-only + plan-gated on Multi-Branch). Opens the
            // dedicated management screen. Obx so it reacts to a user switch
            // or a plan change.
            Obx(() {
              if (!auth.isAdmin || !auth.canMultiBranch) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.account_tree,
                          color: Color(0xFF1565C0)),
                      title: Text('branches'.tr),
                      subtitle: Text('manage_branches_subtitle'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const BranchesScreen()),
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              );
            }),

            // Language Selection
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: ListTile(
                leading: const Icon(Icons.language, color: Colors.indigo),
                title: Text('language'.tr),
                trailing: DropdownButton<String>(
                  value: Get.locale?.languageCode == 'ar' ? 'ar' : 'en',
                  underline: const SizedBox(),
                  items: const [
                    DropdownMenuItem(value: 'en', child: Text("English")),
                    DropdownMenuItem(value: 'ar', child: Text("العربية")),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      controller.changeLanguage(val);
                    }
                  },
                ),
              ),
            ),

            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  'printer_settings'.tr,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey,
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.only(bottom: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  // v21 item 1 / v24: choose the printer transport
                  // (Bluetooth | USB | LAN).
                  ListTile(
                    leading:
                        const Icon(Icons.cable, color: Color(0xFF1565C0)),
                    title: Text('printer_type'.tr),
                    trailing: Obx(
                      () => ToggleButtons(
                        borderRadius: BorderRadius.circular(8),
                        constraints: const BoxConstraints(
                            minHeight: 36, minWidth: 48),
                        isSelected: [
                          controller.printerType.value != 'usb' &&
                              controller.printerType.value != 'lan',
                          controller.printerType.value == 'usb',
                          controller.printerType.value == 'lan',
                        ],
                        onPressed: (i) => controller.savePrinterType(
                            i == 0 ? 'bluetooth' : (i == 1 ? 'usb' : 'lan')),
                        children: const [
                          Icon(Icons.bluetooth, size: 20),
                          Icon(Icons.usb, size: 20),
                          Icon(Icons.lan, size: 20),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // v24: LAN printer section (only when LAN is selected) —
                  // endpoint + status, Search, and Forget.
                  Obx(() {
                    if (controller.printerType.value != 'lan') {
                      return const SizedBox.shrink();
                    }
                    final bool has = controller.lanIp.value.isNotEmpty;
                    final bool searching = controller.lanSearching.value;
                    return Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.lan,
                              color: has ? Colors.green : Colors.grey),
                          title: Text(has
                              ? '${controller.lanIp.value}:${controller.lanPort.value}'
                              : 'no_lan_printer'.tr),
                          subtitle: Text(searching
                              ? (controller.lanStatus.value.isEmpty
                                  ? 'lan_searching'.tr
                                  : controller.lanStatus.value)
                              : (has
                                  ? 'lan_printer_saved'.tr
                                  : 'lan_search_hint'.tr)),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (searching)
                                const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              else ...[
                                IconButton(
                                  tooltip: 'lan_search'.tr,
                                  icon: const Icon(Icons.search,
                                      color: Colors.blue),
                                  onPressed: () =>
                                      _searchLanPrinter(controller),
                                ),
                                // v24: manual ip:port entry — the escape hatch
                                // when the scan can't reach the printer
                                // (VLAN / >/24 subnet / AP isolation).
                                IconButton(
                                  tooltip: 'lan_manual'.tr,
                                  icon: const Icon(Icons.edit,
                                      color: Colors.blueGrey),
                                  onPressed: () =>
                                      _manualLanDialog(controller),
                                ),
                              ],
                              if (has && !searching)
                                IconButton(
                                  tooltip: 'lan_forget'.tr,
                                  icon: const Icon(Icons.link_off,
                                      color: Colors.redAccent),
                                  onPressed: () =>
                                      controller.forgetLanPrinter(),
                                ),
                            ],
                          ),
                          onTap: searching
                              ? null
                              : () => _searchLanPrinter(controller),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  }),
                  // USB printer picker (only when USB is selected).
                  Obx(() {
                    if (controller.printerType.value != 'usb') {
                      return const SizedBox.shrink();
                    }
                    final has = controller.usbDeviceName.value.isNotEmpty;
                    return Column(
                      children: [
                        ListTile(
                          leading: Icon(Icons.usb,
                              color: has ? Colors.green : Colors.grey),
                          title: Text(has
                              ? controller.usbDeviceName.value
                              : 'select_usb_printer'.tr),
                          trailing: const Icon(Icons.search, color: Colors.blue),
                          onTap: () => _showUsbSelection(controller),
                        ),
                        const Divider(height: 1),
                      ],
                    );
                  }),
                  // Bluetooth printer tile (hidden when USB or LAN is selected
                  // — the Bluetooth flow itself is unchanged).
                  Obx(() {
                    if (controller.printerType.value == 'usb' ||
                        controller.printerType.value == 'lan') {
                      return const SizedBox.shrink();
                    }
                    final hasPrinter =
                        controller.printerAddress.value.isNotEmpty;
                    return ListTile(
                      leading: Icon(
                        Icons.print,
                        color: hasPrinter ? Colors.green : Colors.grey,
                      ),
                      title: Text(
                        hasPrinter
                            ? controller.printerName.value
                            : 'no_printer_selected'.tr,
                      ),
                      subtitle: Text(
                        hasPrinter
                            ? controller.printerAddress.value
                            : 'select_bluetooth_printer'.tr,
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.settings_bluetooth,
                          color: Colors.blue,
                        ),
                        onPressed: () => _showPrinterSelection(controller),
                      ),
                      onTap: () => _showPrinterSelection(controller),
                    );
                  }),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.straighten,
                      color: Color(0xFF1565C0),
                    ),
                    title: Text('printer_width'.tr),
                    trailing: Obx(
                      () => ToggleButtons(
                        borderRadius: BorderRadius.circular(8),
                        constraints: const BoxConstraints(
                          minHeight: 36,
                          minWidth: 64,
                        ),
                        isSelected: [
                          controller.paperWidthMm.value == 58,
                          controller.paperWidthMm.value == 80,
                        ],
                        onPressed: (index) =>
                            controller.savePaperWidth(index == 0 ? 58 : 80),
                        children: [
                          Text('paper_58'.tr),
                          Text('paper_80'.tr),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  // v20 item 3: copies-per-receipt (1 or 2).
                  ListTile(
                    leading: const Icon(
                      Icons.copy_all,
                      color: Color(0xFF1565C0),
                    ),
                    title: Text('print_copies'.tr),
                    trailing: Obx(
                      () => ToggleButtons(
                        borderRadius: BorderRadius.circular(8),
                        constraints: const BoxConstraints(
                          minHeight: 36,
                          minWidth: 64,
                        ),
                        isSelected: [
                          controller.printCopies.value == 1,
                          controller.printCopies.value == 2,
                        ],
                        onPressed: (index) =>
                            controller.savePrintCopies(index == 0 ? 1 : 2),
                        children: const [
                          Text('1'),
                          Text('2'),
                        ],
                      ),
                    ),
                  ),
                  // v23 item 5: prove the printer works after pairing/selecting,
                  // without collecting a real payment.
                  ListTile(
                    leading: const Icon(Icons.print_outlined,
                        color: Color(0xFF1565C0)),
                    title: Text('test_print'.tr),
                    subtitle: Text('test_print_subtitle'.tr),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _testPrint(controller),
                  ),
                  const Divider(height: 1),
                  // v27 item 7: choose which sections print (all transports).
                  ListTile(
                    leading: const Icon(Icons.receipt_long,
                        color: Color(0xFF1565C0)),
                    title: Text('print_settings'.tr),
                    subtitle: Text('print_settings_subtitle'.tr),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () =>
                        Get.to(() => const PrintReceiptSettingsScreen()),
                  ),
                ],
              ),
            ),

            // v18 item 4: the cloud Backup tile was removed from Settings — the
            // sync section now exposes ONLY the local Export/Import below.

            // v15 item 6: secure LOCAL backup (boards+circuits+subscribers,
            // owner-password-encrypted). Owner/admin-only; works fully offline
            // (no plan requirement). Tap -> export or import.
            Obx(() {
              if (!auth.isAdmin) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.only(top: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: ListTile(
                  leading: const Icon(Icons.shield_outlined,
                      color: Color(0xFF1565C0)),
                  title: Text('local_backup'.tr),
                  subtitle: Text('local_backup_subtitle'.tr),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Get.bottomSheet(
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        borderRadius:
                            BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      // v23 item 5: SafeArea so the sheet clears the phone's
                      // bottom navigation bar.
                      child: SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.upload_file,
                                  color: Color(0xFF1565C0)),
                              title: Text('backup_export'.tr),
                              onTap: () {
                                Get.back();
                                controller.exportSubscriberBackup();
                              },
                            ),
                            ListTile(
                              leading: const Icon(Icons.download,
                                  color: Color(0xFF1565C0)),
                              title: Text('backup_import'.tr),
                              onTap: () {
                                Get.back();
                                controller.importSubscriberBackup();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),

            // Sync + Manage Devices (online account features)
            if (auth.isLoggedIn.value) ...[
              // v18 item 4: the Sync screen tile (sync status / sync-now /
              // pull-latest) was removed from Settings — auto-sync still runs in
              // the background; the only sync UI here is local Export/Import.

              // Manage devices is owner-only (an accountant
              // must not unbind devices or wipe the shared local data). Obx so
              // it reacts to a profile switch.
              Obx(() {
                if (!auth.isAdmin) return const SizedBox.shrink();
                return Column(
                  children: [
                    const SizedBox(height: 24),
                    _buildManageDevicesSection(),
                    // v18 item 4: the "delete local data" tile was removed from
                    // Settings (a sync-data action); local Export/Import remains.
                  ],
                );
              }),
            ],

            const SizedBox(height: 32),

            // Logout
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                // P4: user-initiated logout wipes local data (login re-pulls).
                onPressed: () => auth.logout(wipeLocal: true),
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                label: Text(
                  'logout'.tr,
                  style: const TextStyle(color: Colors.redAccent),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  side: const BorderSide(color: Colors.redAccent),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  backgroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '${'version'.tr} 1.0.0',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      )),
    );
  }

  // --------------------------------------------------------------------------
  // SYNC
  // --------------------------------------------------------------------------
  // --------------------------------------------------------------------------
  // MANAGE DEVICES
  // --------------------------------------------------------------------------
  Widget _buildManageDevicesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(
            'manage_devices'.tr,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: ListTile(
            leading: const Icon(Icons.devices, color: Color(0xFF1565C0)),
            title: Text('manage_devices'.tr),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: _showDevicesSheet,
          ),
        ),
      ],
    );
  }

  void _showDevicesSheet() {
    final DeviceRepository deviceRepo = DeviceRepository();

    Get.bottomSheet(
      Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // v23 item 5: SafeArea so the sheet clears the bottom navigation bar.
        child: SafeArea(
          top: false,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'manage_devices'.tr,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<DeviceBinding>>(
              future: deviceRepo.list(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snapshot.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text("${'manage_devices'.tr}: ${snapshot.error}"),
                  );
                }
                final devices = snapshot.data ?? [];
                if (devices.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text('no_devices'.tr),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  separatorBuilder: (c, i) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final d = devices[i];
                    final title = d.model ?? d.platform ?? d.deviceId;
                    return ListTile(
                      leading: Icon(
                        d.current ? Icons.smartphone : Icons.devices_other,
                        color: d.current
                            ? const Color(0xFF43A047)
                            : Colors.grey,
                      ),
                      title: Text(
                        d.current ? '$title (${'this_device'.tr})' : title,
                      ),
                      subtitle: Text(
                        [
                          if (d.platform != null) d.platform!,
                          if (d.osVersion != null) d.osVersion!,
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.link_off,
                          color: Colors.redAccent,
                        ),
                        tooltip: 'unbind'.tr,
                        onPressed: () => _confirmUnbind(deviceRepo, d.deviceId,
                            isCurrent: d.current),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
        ),
      ),
    );
  }

  void _confirmUnbind(DeviceRepository repo, String deviceId,
      {bool isCurrent = false}) {
    Get.defaultDialog(
      title: 'unbind'.tr,
      // v23 (§4.3): unbinding the CURRENT device gets an extra warning line.
      middleText: isCurrent
          ? '${'unbind_confirm'.tr}\n\n${'unbind_current_warn'.tr}'
          : 'unbind_confirm'.tr,
      textConfirm: 'unbind'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () async {
        if (!await ConnectivityService().isOnline()) {
          Get.back(); // close dialog
          Get.snackbar('manage_devices'.tr, 'online_only'.tr);
          return;
        }
        try {
          await repo.unbind(deviceId);
          Get.back(); // close dialog
          Get.back(); // close bottom sheet
          Get.snackbar('manage_devices'.tr, 'device_unbound'.tr);
        } catch (e) {
          Get.back(); // close dialog
          Get.snackbar('error'.tr, "${'manage_devices'.tr}: $e");
        }
      },
    );
  }

  /// v24: run LAN discovery from the settings tile with result snackbars.
  Future<void> _searchLanPrinter(SettingsController controller) async {
    final found = await controller.searchLanPrinter();
    if (found) {
      Get.snackbar('success'.tr,
          '${'lan_printer_found'.tr}: ${controller.lanIp.value}:${controller.lanPort.value}',
          backgroundColor: Colors.green,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    } else {
      Get.snackbar('error'.tr, 'lan_printer_not_found'.tr,
          backgroundColor: Colors.redAccent,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  /// v24: manual LAN endpoint entry ("192.168.1.100" or "192.168.1.100:9100")
  /// — the escape hatch when discovery can't reach the printer. Validates the
  /// IPv4 shape, saves regardless of reachability (a transient probe failure
  /// must not block configuration), and closes via the dialog's own route.
  void _manualLanDialog(SettingsController controller) {
    final ctrl = TextEditingController(
      text: controller.lanIp.value.isEmpty
          ? ''
          : '${controller.lanIp.value}:${controller.lanPort.value}',
    );
    Get.dialog(
      Builder(builder: (context) {
        return AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('lan_manual'.tr),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              hintText: '192.168.1.100:9100',
              helperText: 'lan_ip_hint'.tr,
              border: const OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('cancel'.tr),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: const Color(0xFF1565C0)),
              onPressed: () async {
                final raw = ctrl.text.trim();
                final parts = raw.split(':');
                final ip = parts[0].trim();
                final int port = parts.length > 1
                    ? (int.tryParse(parts[1].trim()) ?? 9100)
                    : 9100;
                final ipOk = RegExp(
                        r'^(25[0-5]|2[0-4]\d|1?\d{1,2})(\.(25[0-5]|2[0-4]\d|1?\d{1,2})){3}$')
                    .hasMatch(ip);
                if (!ipOk || port < 1 || port > 65535) {
                  Get.snackbar('error'.tr, 'lan_invalid_ip'.tr,
                      backgroundColor: Colors.redAccent,
                      colorText: Colors.white,
                      snackPosition: SnackPosition.BOTTOM);
                  return; // keep the dialog open for correction
                }
                await controller.setManualLan(ip, port);
                if (context.mounted) Navigator.of(context).pop();
                Get.snackbar('success'.tr, '${'lan_printer_found'.tr}: $ip:$port',
                    backgroundColor: Colors.green,
                    colorText: Colors.white,
                    snackPosition: SnackPosition.BOTTOM);
              },
              child: Text('save'.tr),
            ),
          ],
        );
      }),
    );
  }

  /// v23 item 5 / v24: print a test slip on the ACTIVE transport (USB,
  /// LAN or Bluetooth), so the user can confirm the printer works right
  /// after pairing/selecting.
  Future<void> _testPrint(SettingsController controller) async {
    Get.snackbar('test_print'.tr, 'printing'.tr,
        snackPosition: SnackPosition.BOTTOM,
        duration: const Duration(seconds: 1));
    try {
      if (PrinterPrefs.isUsb) {
        await UsbPrintService().printTest(
          deviceId: controller.usbDeviceId.value.isEmpty
              ? null
              : controller.usbDeviceId.value,
        );
      } else if (PrinterPrefs.isLan) {
        await LanPrintService().printTest();
      } else {
        await BluetoothPrintService().printTest();
      }
      Get.snackbar('success'.tr, 'test_print_sent'.tr,
          backgroundColor: Colors.green,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    } catch (e) {
      Get.snackbar('error'.tr, 'print_failed'.tr,
          backgroundColor: Colors.redAccent,
          colorText: Colors.white,
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  /// v21 item 1: pick a connected USB thermal printer.
  void _showUsbSelection(SettingsController controller) async {
    List<Map<String, dynamic>> devices = const [];
    try {
      devices = await UsbPrintService().listDevices();
    } catch (_) {}
    Get.bottomSheet(
      Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // v23 item 5: SafeArea so the sheet clears the bottom navigation bar.
        child: SafeArea(
          top: false,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('select_usb_printer'.tr,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('no_usb_printer'.tr,
                    style: TextStyle(color: Colors.grey.shade600)),
              )
            else
              ...devices.map((d) {
                final name =
                    (d['productName'] ?? d['manufacturer'] ?? 'USB').toString();
                return ListTile(
                  leading: const Icon(Icons.usb, color: Color(0xFF1565C0)),
                  title: Text(name),
                  subtitle: Text('${d['vendorId']}:${d['productId']}'),
                  onTap: () {
                    controller.saveUsbDevice(name, UsbPrintService.idOf(d));
                    Get.back();
                  },
                );
              }),
          ],
        ),
        ),
      ),
    );
  }

  void _showPrinterSelection(SettingsController controller) async {
    final BluetoothPrintService printService = BluetoothPrintService();

    Get.bottomSheet(
      Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        // v23 item 5: SafeArea so the sheet clears the bottom navigation bar.
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'select_bluetooth_printer_title'.tr,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              FutureBuilder<List<BluetoothDevice>>(
                future: printService.getPairedDevices(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Text("${'error'.tr}: ${snapshot.error}");
                  }
                  final devices = snapshot.data ?? [];
                  if (devices.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text('no_paired_devices'.tr),
                    );
                  }
                  // v23 item 5: bound the paired-device list so a long list
                  // scrolls instead of overflowing the sheet.
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: Get.height * 0.5),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: devices.length,
                      itemBuilder: (ctx, i) {
                        final d = devices[i];
                        return ListTile(
                          leading:
                              const Icon(Icons.print, color: Colors.blue),
                          title: Text(d.name ?? 'unknown_device'.tr),
                          subtitle: Text(d.address ?? ""),
                          onTap: () {
                            controller.savePrinterSettings(
                              d.name ?? 'printer'.tr,
                              d.address ?? "",
                            );
                            Get.back();
                            Get.snackbar(
                              'printer_selected'.tr,
                              '${d.name} ${'printer_selected_message'.tr}',
                            );
                          },
                        );
                      },
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
