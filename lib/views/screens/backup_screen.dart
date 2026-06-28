import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/account.dart';

/// All backup-related features in one place: local export/import and cloud
/// backup (upload/list/restore/delete). Reached from a single "Backup" tile in
/// Settings.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final SettingsController controller = Get.find<SettingsController>();
  final AuthController auth = Get.find<AuthController>();

  @override
  void initState() {
    super.initState();
    // Refresh the cloud backup list for logged-in owners (online only).
    if (auth.isLoggedIn.value) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (await ConnectivityService().isOnline()) {
          controller.refreshCloudBackups();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        title: Text(
          'backup'.tr,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Local export / import
            _sectionLabel('data_management'.tr),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.download, color: Color(0xFF43A047)),
                    title: Text('backup_data'.tr),
                    subtitle: Text('backup_data_subtitle'.tr),
                    onTap: () => controller.exportData(),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.upload, color: Color(0xFFEF5350)),
                    title: Text('restore_data'.tr),
                    subtitle: Text('restore_warning'.tr),
                    onTap: _confirmRestore,
                  ),
                ],
              ),
            ),

            // Cloud backup (online account feature). Hidden when the active
            // plan has no backup capability — the local export/import above is
            // device-only and always available. The controller methods are
            // also canBackup-guarded, so this is the UI half of that gate.
            if (auth.isLoggedIn.value && auth.canBackup) ...[
              const SizedBox(height: 24),
              _buildCloudBackupSection(),
            ],
          ],
        ),
      )),
    );
  }

  Widget _sectionLabel(String text) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.blueGrey,
            ),
          ),
        ),
      );

  Widget _buildCloudBackupSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('cloud_backup'.tr),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              // Last backup timestamp + online-only hint
              Obx(() {
                final last = controller.lastCloudBackupAt.value;
                return ListTile(
                  leading: const Icon(
                    Icons.cloud_outlined,
                    color: Color(0xFF1565C0),
                  ),
                  title: Text(
                    '${'last_backup'.tr}: ${_formatTimestamp(last)}',
                  ),
                  subtitle: Text(
                    'online_only'.tr,
                    style: const TextStyle(fontSize: 12),
                  ),
                );
              }),
              const Divider(height: 1),
              // Backup now button
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Obx(
                  () => SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: controller.isCloudBusy.value
                          ? null
                          : () => controller.uploadCloudBackup(),
                      icon: controller.isCloudBusy.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.backup, color: Colors.white),
                      label: Text(
                        'backup_now'.tr,
                        style: const TextStyle(color: Colors.white),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1565C0),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const Divider(height: 1),
              // Cloud backup list
              Obx(() {
                if (controller.isCloudBusy.value &&
                    controller.cloudBackups.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (controller.cloudBackups.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      'no_backups'.tr,
                      style: const TextStyle(color: Colors.grey),
                    ),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: controller.cloudBackups.length,
                  separatorBuilder: (c, i) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final BackupEntry b = controller.cloudBackups[index];
                    return ListTile(
                      leading: const Icon(
                        Icons.cloud_done,
                        color: Color(0xFF43A047),
                      ),
                      title: Text(_formatTimestamp(b.createdAt)),
                      subtitle: Text(
                        '${_formatSize(b.size)}'
                        '${(b.note != null && b.note!.isNotEmpty) ? ' · ${b.note}' : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.restore,
                              color: Color(0xFF1565C0),
                            ),
                            tooltip: 'restore'.tr,
                            onPressed: () =>
                                controller.restoreCloudBackup(b.id),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.redAccent,
                            ),
                            onPressed: () => _confirmDeleteCloudBackup(b.id),
                          ),
                        ],
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  void _confirmDeleteCloudBackup(String id) {
    Get.defaultDialog(
      title: 'cloud_backup'.tr,
      middleText: 'delete_backup_confirm'.tr,
      textConfirm: 'delete'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        controller.deleteCloudBackup(id);
      },
    );
  }

  void _confirmRestore() {
    Get.defaultDialog(
      title: 'restore_create_backup_first'.tr,
      middleText: 'restore_import_warning'.tr,
      textConfirm: 'restore'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        controller.importData();
      },
    );
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'never'.tr;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return DateFormat('yyyy-MM-dd HH:mm').format(dt.toLocal());
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0 KB';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
