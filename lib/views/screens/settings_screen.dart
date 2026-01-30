import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:generatormanagment/utils/bluetooth_print_service.dart';
import 'package:blue_thermal_printer/blue_thermal_printer.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Put controller
    final SettingsController controller = Get.put(SettingsController());
    final AuthController auth = Get.find();
    final bool isAdmin = auth.currentUser.value?.role == 'admin';

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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        auth.currentUser.value?.username ?? "User",
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
                          color: isAdmin ? Colors.purple[50] : Colors.green[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          (auth.currentUser.value?.role ?? "").toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isAdmin ? Colors.purple : Colors.green,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // User Management Section (Admin Only)
            if (isAdmin) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(left: 8, bottom: 8),
                  child: Text(
                    'user_management'.tr,
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
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(
                        Icons.person_add,
                        color: Color(0xFF1565C0),
                      ),
                      title: const Text("Create New User"),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () => _showAddUserDialog(controller),
                    ),
                    const Divider(height: 1),
                    Obx(() {
                      if (controller.isLoading.value) return const SizedBox();
                      return ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: controller.users.length,
                        separatorBuilder: (c, i) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final user = controller.users[index];
                          final isMe = user.id == auth.currentUser.value?.id;
                          return ListTile(
                            leading: Icon(
                              user.role == 'admin'
                                  ? Icons.admin_panel_settings
                                  : Icons.person,
                              color: user.role == 'admin'
                                  ? Colors.orange
                                  : Colors.grey,
                            ),
                            title: Text(user.username),
                            subtitle: Text(user.role),
                            trailing: isMe
                                ? const SizedBox()
                                : IconButton(
                                    icon: const Icon(
                                      Icons.delete,
                                      color: Colors.redAccent,
                                    ),
                                    onPressed: () =>
                                        _confirmDelete(controller, user.id),
                                  ),
                          );
                        },
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],

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

            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  "Printer Settings",
                  style: TextStyle(
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
              child: Obx(() {
                final hasPrinter = controller.printerAddress.value.isNotEmpty;
                return ListTile(
                  leading: Icon(
                    Icons.print,
                    color: hasPrinter ? Colors.green : Colors.grey,
                  ),
                  title: Text(
                    hasPrinter
                        ? controller.printerName.value
                        : "No Printer Selected",
                  ),
                  subtitle: Text(
                    hasPrinter
                        ? controller.printerAddress.value
                        : "Select a Bluetooth printer",
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
            ),

            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.only(left: 8, bottom: 8),
                child: Text(
                  "Data Management",
                  style: TextStyle(
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
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.download,
                      color: Color(0xFF43A047),
                    ),
                    title: const Text("Backup Data (Export)"),
                    subtitle: const Text("Save a copy of your database"),
                    onTap: () => controller.exportData(),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.upload, color: Color(0xFFEF5350)),
                    title: const Text("Restore Data (Import)"),
                    subtitle: const Text("Warning: Overwrites current data"),
                    onTap: () => _confirmRestore(controller),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 32),

            // Logout
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => auth.logout(),
                icon: const Icon(Icons.logout, color: Colors.redAccent),
                label: const Text(
                  "Log Out",
                  style: TextStyle(color: Colors.redAccent),
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
            const Text("Version 1.0.0", style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }

  void _showAddUserDialog(SettingsController controller) {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    String role = 'accountant';

    Get.defaultDialog(
      title: "Add User",
      content: Column(
        children: [
          TextField(
            controller: userCtrl,
            decoration: const InputDecoration(
              labelText: "Username",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passCtrl,
            decoration: const InputDecoration(
              labelText: "Password",
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: role,
            items: const [
              DropdownMenuItem(value: 'accountant', child: Text("Accountant")),
              DropdownMenuItem(value: 'admin', child: Text("Admin")),
            ],
            onChanged: (v) => role = v!,
            decoration: const InputDecoration(
              labelText: "Role",
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      textConfirm: "Create",
      textCancel: "Cancel",
      onConfirm: () {
        if (userCtrl.text.trim().isEmpty || passCtrl.text.trim().isEmpty) {
          Get.snackbar(
            "Error",
            "Please fill all fields",
            backgroundColor: Colors.redAccent,
            colorText: Colors.white,
          );
          return;
        }
        controller.addUser(userCtrl.text.trim(), passCtrl.text, role);
        Get.back(); // manually close dialog if successful
      },
    );
  }

  void _confirmDelete(SettingsController controller, String userId) {
    Get.defaultDialog(
      title: "Delete User",
      middleText: "Are you sure you want to delete this user?",
      textConfirm: "Yes, Delete",
      textCancel: "Cancel",
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        controller.deleteUser(userId);
        Get.back();
      },
    );
  }

  void _confirmRestore(SettingsController controller) {
    Get.defaultDialog(
      title: "Create Backup First!",
      middleText:
          "Importing will DELETE all current data and replace it with the backup file. Are you sure?",
      textConfirm: "Yes, Restore",
      textCancel: "Cancel",
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        controller.importData();
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
            const Text(
              "Select Bluetooth Printer",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<BluetoothDevice>>(
              future: printService.getPairedDevices(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Text("Error: ${snapshot.error}");
                }
                final devices = snapshot.data ?? [];
                if (devices.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      "No paired devices found. Please pair your printer in phone settings first.",
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (ctx, i) {
                    final d = devices[i];
                    return ListTile(
                      leading: const Icon(Icons.print, color: Colors.blue),
                      title: Text(d.name ?? "Unknown Device"),
                      subtitle: Text(d.address ?? ""),
                      onTap: () {
                        controller.savePrinterSettings(
                          d.name ?? "Printer",
                          d.address ?? "",
                        );
                        Get.back();
                        Get.snackbar(
                          "Printer Selected",
                          "${d.name} is now your default printer.",
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
