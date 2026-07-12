import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/utils/date_fmt.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';

/// Offline-sync status + manual control on its own screen. Reached from a single
/// "Sync" tile in Settings. The app keeps auto-syncing in the background; this
/// screen shows the state (pending count, last sync) and a manual "Sync now".
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SyncController syncController = Get.find<SyncController>();
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6FA),
      appBar: AppBar(
        title: Text(
          'sync'.tr,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              // Sync status + pending count
              Obx(() {
                final String subtitle;
                if (syncController.isSyncing.value) {
                  subtitle = 'syncing'.tr;
                } else if (syncController.pendingCount.value == 0) {
                  subtitle = 'all_synced'.tr;
                } else {
                  subtitle =
                      '${syncController.pendingCount.value} ${'sync_pending'.tr}';
                }
                return ListTile(
                  leading: const Icon(Icons.sync, color: Color(0xFF1565C0)),
                  title: Text('sync'.tr),
                  subtitle: Text(subtitle),
                );
              }),
              const Divider(height: 1),
              // Last sync timestamp
              Obx(
                () => ListTile(
                  leading: const Icon(Icons.schedule, color: Color(0xFF1565C0)),
                  title: Text(
                    '${'last_sync'.tr}: '
                    '${_formatTimestamp(syncController.lastSyncAt.value)}',
                  ),
                  subtitle: Text(
                    'online_only'.tr,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const Divider(height: 1),
              // Sync now button
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Obx(
                  () => SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: syncController.isSyncing.value
                          ? null
                          : () => syncController.syncNow(),
                      icon: syncController.isSyncing.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.sync, color: Colors.white),
                      label: Text(
                        'sync_now'.tr,
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
              // Pull latest data (server -> device)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Obx(
                  () => SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: syncController.isPulling.value
                          ? null
                          : () => syncController.pull(),
                      icon: syncController.isPulling.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF1565C0),
                              ),
                            )
                          : const Icon(Icons.cloud_download,
                              color: Color(0xFF1565C0)),
                      label: Text(
                        'pull_latest'.tr,
                        style: const TextStyle(color: Color(0xFF1565C0)),
                      ),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: Color(0xFF1565C0)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'never'.tr;
    final dt = DateTime.tryParse(iso);
    if (dt == null) return iso;
    return fmtDateTime12(dt.toLocal());
  }
}
