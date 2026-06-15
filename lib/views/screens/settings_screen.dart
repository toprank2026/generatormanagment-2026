import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/views/screens/subscription_screen.dart';
import 'package:generatormanagment/views/screens/backup_screen.dart';
import 'package:generatormanagment/views/screens/sync_screen.dart';
import 'package:generatormanagment/views/screens/user_switch_screen.dart';
import 'package:generatormanagment/views/screens/accountants_screen.dart';
import 'package:generatormanagment/views/screens/branches_screen.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/repositories/device_repository.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
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
      body: SingleChildScrollView(
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

            // Switch user (owner <-> accountant). Always visible so an
            // accountant can hand the device back to the owner.
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: ListTile(
                leading: const Icon(Icons.switch_account,
                    color: Color(0xFF1565C0)),
                title: Text('switch_user'.tr),
                subtitle: Obx(() => Text(auth.actingUserName)),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => Get.to(() => const UserSwitchScreen()),
              ),
            ),
            const SizedBox(height: 24),

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
                  Obx(() {
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
                ],
              ),
            ),

            // Backup section: owner-only, and only shown when the active plan
            // enables cloud backup (Obx so it reacts if the plan changes).
            Obx(() {
              if (!auth.isAdmin) return const SizedBox.shrink();
              if (!auth.canBackup) return const SizedBox.shrink();
              return Column(
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, bottom: 8),
                      child: Text(
                        'backup'.tr,
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
                      leading:
                          const Icon(Icons.backup, color: Color(0xFF1565C0)),
                      title: Text('backup'.tr),
                      subtitle: Text('backup_subtitle'.tr),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Get.to(() => const BackupScreen()),
                    ),
                  ),
                ],
              );
            }),

            // Sync + Manage Devices (online account features)
            if (auth.isLoggedIn.value) ...[
              // Sync tile: owner-only, and only shown when the active plan
              // enables sync. Hidden in "offline-only" mode (Obx so it reacts
              // to plan changes). Manage Devices / delete-local stay regardless.
              Obx(() {
                if (!auth.isAdmin) return const SizedBox.shrink();
                if (!auth.canSync) return const SizedBox.shrink();
                return Column(
                  children: [
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, bottom: 8),
                        child: Text(
                          'sync'.tr,
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
                        leading:
                            const Icon(Icons.sync, color: Color(0xFF1565C0)),
                        title: Text('sync'.tr),
                        subtitle: Text('sync_subtitle'.tr),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Get.to(() => const SyncScreen()),
                      ),
                    ),
                  ],
                );
              }),
              // Manage devices + delete-local are owner-only (an accountant
              // must not unbind devices or wipe the shared local data). Obx so
              // it reacts to a profile switch.
              Obx(() {
                if (!auth.isAdmin) return const SizedBox.shrink();
                return Column(
                  children: [
                    const SizedBox(height: 24),
                    _buildManageDevicesSection(),
                    const SizedBox(height: 24),
                    // Delete local data
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8, bottom: 8),
                        child: Text(
                          'delete_local_data'.tr,
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
                          Icons.delete_forever,
                          color: Colors.redAccent,
                        ),
                        title: Text('delete_local_data'.tr),
                        subtitle: Text('delete_local_data_subtitle'.tr),
                        onTap: _confirmDeleteLocalData,
                      ),
                    ),
                  ],
                );
              }),
            ],

            const SizedBox(height: 32),

            // Logout
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => auth.logout(),
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
      ),
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
                        onPressed: () => _confirmUnbind(deviceRepo, d.deviceId),
                      ),
                    );
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmUnbind(DeviceRepository repo, String deviceId) {
    Get.defaultDialog(
      title: 'unbind'.tr,
      middleText: 'unbind_confirm'.tr,
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

  void _confirmDeleteLocalData() {
    Get.defaultDialog(
      title: 'delete_local_data'.tr,
      middleText: 'delete_local_data_confirm'.tr,
      textConfirm: 'delete'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        Get.find<SyncController>().deleteLocalData();
      },
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
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (ctx, i) {
                    final d = devices[i];
                    return ListTile(
                      leading: const Icon(Icons.print, color: Colors.blue),
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
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
