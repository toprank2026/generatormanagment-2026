import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/core/device_rebind.dart';
import 'package:generatormanagment/core/local_backup_service.dart';
import 'package:generatormanagment/core/session_cache.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/auth_repository.dart';
import 'package:generatormanagment/data/repositories/backup_repository.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

class SettingsController extends GetxController {
  final AccountantRepository _accountantRepo = AccountantRepository();
  final AuthRepository _authRepo = AuthRepository();
  final ConnectivityService _net = ConnectivityService();
  final DbHelper _dbHelper = DbHelper();
  final BackupRepository _backupRepo = BackupRepository();
  final AuthController auth = Get.find();

  /// Owner-managed accountant sub-users (synced identity rows).
  var accountants = <Accountant>[].obs;
  var isLoading = false.obs;

  // --- Cloud backup ---
  var cloudBackups = <BackupEntry>[].obs;
  var isCloudBusy = false.obs;
  var lastCloudBackupAt = Rxn<String>();

  // Printer Settings
  var printerName = "".obs;
  var printerAddress = "".obs;
  // Thermal paper width in mm (58 or 80); default 58.
  var paperWidthMm = PrinterPrefs.defaultWidthMm.obs;
  // v20 item 3: copies printed per receipt (1 or 2); default 2.
  var printCopies = 2.obs;
  // v21 item 1: printer transport ('bluetooth' | 'usb') + the selected USB
  // device. The Bluetooth printer fields above are untouched.
  var printerType = 'bluetooth'.obs;
  var usbDeviceName = ''.obs;
  var usbDeviceId = ''.obs;
  static const String _keyUsbName = 'usb_device_name';
  static const String _keyUsbId = 'usb_device_id';

  // Persistence Keys
  static const String _keyLang = 'lang_code';
  static const String _keyPrinterName = 'printer_name';
  static const String _keyPrinterAddress = 'printer_address';

  Future<void> changeLanguage(String langCode) async {
    final locale = langCode == 'ar'
        ? const Locale('ar', 'AR')
        : const Locale('en', 'US');

    Get.updateLocale(locale);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLang, langCode);
    update();
  }

  Future<Locale> loadLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final String? langCode = prefs.getString(_keyLang);

    // Default to Arabic when no language has been chosen yet.
    if (langCode == 'en') {
      return const Locale('en', 'US');
    }
    return const Locale('ar', 'AR');
  }

  @override
  void onInit() {
    super.onInit();
    // Reload the accountant list whenever the acting user changes, so the
    // owner always sees the current set (and the count) after a switch.
    ever(auth.currentUser, (_) {
      if (auth.isAdmin) {
        loadAccountants();
      } else {
        accountants.clear();
      }
    });
  }

  @override
  void onReady() {
    super.onReady();
    loadPrinterSettings();
    _loadLastBackupAt();
    if (auth.isAdmin) {
      loadAccountants();
    }
  }

  Future<void> _loadLastBackupAt() async {
    lastCloudBackupAt.value = await SessionCache().getLastBackupAt();
  }

  Future<void> loadPrinterSettings() async {
    final prefs = await SharedPreferences.getInstance();
    printerName.value = prefs.getString(_keyPrinterName) ?? "";
    printerAddress.value = prefs.getString(_keyPrinterAddress) ?? "";
    paperWidthMm.value = await PrinterPrefs.load(); // also loads copies + type
    printCopies.value = PrinterPrefs.copies;
    printerType.value = PrinterPrefs.printerType;
    usbDeviceName.value = prefs.getString(_keyUsbName) ?? "";
    usbDeviceId.value = prefs.getString(_keyUsbId) ?? "";
    update();
  }

  /// v21: persist the printer transport ('bluetooth' | 'usb').
  Future<void> savePrinterType(String t) async {
    await PrinterPrefs.setPrinterType(t);
    printerType.value = PrinterPrefs.printerType;
    update();
  }

  /// v21: persist the selected USB printer device.
  Future<void> saveUsbDevice(String name, String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUsbName, name);
    await prefs.setString(_keyUsbId, id);
    usbDeviceName.value = name;
    usbDeviceId.value = id;
    update();
  }

  Future<void> savePrinterSettings(String name, String address) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrinterName, name);
    await prefs.setString(_keyPrinterAddress, address);
    printerName.value = name;
    printerAddress.value = address;
    update();
  }

  /// Persists the thermal paper width (58 or 80 mm) and refreshes the cache
  /// read by the print services.
  Future<void> savePaperWidth(int mm) async {
    await PrinterPrefs.setWidth(mm);
    paperWidthMm.value = PrinterPrefs.widthMm;
    update();
  }

  /// v20 item 3: persists copies-per-receipt (1 or 2).
  Future<void> savePrintCopies(int n) async {
    await PrinterPrefs.setCopies(n);
    printCopies.value = PrinterPrefs.copies;
    update();
  }

  // --------------------------------------------------------------------------
  // ACCOUNTANTS (owner-managed sub-users). Creating an accountant writes BOTH
  // the local credential row (for offline login) and the synced identity row
  // (visible to the admin panel) via AccountantRepository.
  // --------------------------------------------------------------------------

  /// Load the full accountant list (small, owner-managed set — no pagination).
  Future<void> loadAccountants() async {
    isLoading.value = true;
    try {
      accountants.assignAll(await _accountantRepo.getAll());
    } catch (e) {
      Get.snackbar('error'.tr, "${'accountants'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }

  /// Create a new accountant (R8). The accountant is a REAL backend sub-account
  /// (so it can log in via the Login screen), tied to a branch — so creation
  /// REQUIRES the network. We register the backend account first (source of
  /// truth for login), then mirror the local identity/credential rows (same id)
  /// for the synced admin-panel identity and the offline owner profile-switch.
  /// Returns true on success. NOTE: this intentionally does NOT show the
  /// success snackbar — the caller dialog must CLOSE first, then snackbar
  /// (a snackbar shown before close flips Get.isDialogOpen to false and blocks
  /// the dialog's Get.back(), which left the add spinner stuck — see gotchas).
  Future<bool> createAccountant(
      String name, String username, String password,
      {Iterable<String> permissions = const [], String? branchId}) async {
    if (!await _net.isOnline()) {
      Get.snackbar('error'.tr, 'accountant_needs_internet'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return false;
    }
    // v18 item 1: confirm + unbind/rebind THIS device before linking a new
    // accountant so it can use the device without tripping DEVICE_LIMIT. Cancel
    // aborts the creation (no rows written).
    if (!await DeviceRebind.confirmAndApply(rebind: true)) return false;
    final id = const Uuid().v4();
    final branch = (branchId != null && branchId.isNotEmpty)
        ? branchId
        : Get.find<BranchController>().writeBranchId;
    try {
      // 1. Register the backend account first (login source of truth).
      await _authRepo.createAccountant(
        localId: id,
        name: name,
        username: username,
        password: password,
        branchId: branch,
        permissions: permissions,
      );
      // 2. Mirror the synced identity + offline credential rows (same id). If
      //    this local write fails AFTER the backend created the account, roll
      //    the backend account back so the username isn't permanently consumed
      //    by an orphan the owner can't see (keeps the two sides consistent).
      try {
        await _accountantRepo.create(
          id: id,
          username: username,
          name: name,
          password: password,
          permissions: permissions,
        );
      } catch (localErr) {
        try {
          await _authRepo.deleteAccountant(id);
        } catch (_) {/* best-effort rollback */}
        rethrow;
      }
      SyncController.poke(); // item 3: sync the new accountant identity row
      await loadAccountants();
      update();
      return true; // caller closes the dialog, THEN shows the success snackbar
    } on ApiException catch (e) {
      final msg = e.statusCode == 409
          ? 'username_taken'.tr
          : (e.isNetworkError ? 'online_only'.tr : e.message);
      Get.snackbar('error'.tr, msg,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('error'.tr, "${'add_accountant'.tr}: $e");
    }
    update();
    return false;
  }

  /// Update an accountant (R8). A disable (active:false), password reset, or
  /// rename MUST reach the BACKEND or it doesn't take effect (the accountant is
  /// a real backend login) — so this is online-required and backend-first, then
  /// mirrors locally. The backend resolves the accountant by its local id.
  Future<void> updateAccountant(
    String id, {
    String? name,
    bool? active,
    String? newPassword,
    Iterable<String>? permissions,
  }) async {
    if (!await _net.isOnline()) {
      Get.snackbar('error'.tr, 'accountant_needs_internet'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return;
    }
    try {
      await _authRepo.updateAccountant(
        id,
        name: name,
        active: active,
        permissions: permissions,
        password: newPassword,
      );
      await _accountantRepo.update(
        id: id,
        name: name,
        active: active,
        newPassword: newPassword,
        permissions: permissions,
      );
      await loadAccountants();
      Get.snackbar('success'.tr, 'edit_accountant'.tr);
    } on ApiException catch (e) {
      Get.snackbar('error'.tr, e.isNetworkError ? 'online_only'.tr : e.message,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('error'.tr, "${'edit_accountant'.tr}: $e");
    }
    update();
  }

  /// Delete an accountant (R8). Must delete the BACKEND account first (so the
  /// accountant can no longer log in / push into the owner's mirror), then the
  /// local rows. Online-required for the same reason as update.
  Future<void> deleteAccountant(String id) async {
    if (id == auth.currentUser.value?.id) {
      Get.snackbar('error'.tr, 'cannot_delete_self'.tr);
      return;
    }
    if (!await _net.isOnline()) {
      Get.snackbar('error'.tr, 'accountant_needs_internet'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return;
    }
    try {
      await _authRepo.deleteAccountant(id);
      await _accountantRepo.delete(id);
      accountants.removeWhere((a) => a.id == id);
    } on ApiException catch (e) {
      Get.snackbar('error'.tr, e.isNetworkError ? 'online_only'.tr : e.message,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('error'.tr, "${'delete'.tr}: $e");
    }
    update();
  }

  Future<void> exportData() async {
    isLoading.value = true;
    try {
      String dbPath = await _dbHelper.getDbPath();
      File dbFile = File(dbPath);

      if (!dbFile.existsSync()) {
        Get.snackbar('error'.tr, 'db_file_not_found'.tr);
        return;
      }

      // Create a temporary file with a timestamped name
      final tempDir = await getTemporaryDirectory();
      String fileName =
          'flash_backup_${DateTime.now().year}${DateTime.now().month}${DateTime.now().day}_${DateTime.now().hour}${DateTime.now().minute}.db';
      final tempFile = File(p.join(tempDir.path, fileName));

      // Copy db to temp file
      await dbFile.copy(tempFile.path);

      // Share the file
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'Flash Database Backup ${DateTime.now().toString().split('.')[0]}',
      );
    } catch (e) {
      Get.snackbar('error'.tr, "${'export_failed'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> importData() async {
    try {
      // Pick a file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        dialogTitle: 'select_backup_file'.tr,
      ); // Any extension, as we can't strictly enforce .db on all android versions reliably or user might have renamed it

      if (result != null && result.files.single.path != null) {
        String path = result.files.single.path!;
        File file = File(path);

        // Basic check if it likely is a db file or just try to open it
        if (!path.toLowerCase().endsWith('.db') &&
            !path.toLowerCase().endsWith('.sqlite')) {
          // We can warn but maybe proceed if user insists? For now let's just warn
          Get.defaultDialog(
            title: 'warning'.tr,
            middleText: 'not_db_file_warning'.tr,
            textConfirm: 'yes_try'.tr,
            textCancel: 'cancel'.tr,
            onConfirm: () {
              Get.back();
              _confirmImportProcess(file);
            },
          );
          return;
        }

        _confirmImportProcess(file);
      }
    } catch (e) {
      Get.snackbar('error'.tr, "${'import_failed'.tr}: $e");
    }
  }

  // ==========================================================================
  // v15 item 6 — SECURE local backup/restore of boards+circuits+subscribers
  // (no history), encrypted with the OWNER PASSWORD, OWNER/ADMIN-ONLY, offline.
  // ==========================================================================

  /// Password prompt dialog (returns the entered password, or null on cancel).
  Future<String?> _askBackupPassword(String titleKey) async {
    final ctrl = TextEditingController();
    return Get.dialog<String>(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(titleKey.tr),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'password'.tr,
            prefixIcon: const Icon(Icons.lock_outline),
          ),
          onSubmitted: (v) => Get.back(result: v),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(), child: Text('cancel'.tr)),
          ElevatedButton(
            onPressed: () => Get.back(result: ctrl.text),
            child: Text('confirm'.tr),
          ),
        ],
      ),
    );
  }

  /// Export boards+circuits+subscribers to `<GeneratorName>.backup` (encrypted
  /// with the owner password) and share it. Owner/admin only.
  Future<void> exportSubscriberBackup() async {
    if (auth.isAccountant) {
      Get.snackbar('error'.tr, 'no_permission'.tr);
      return;
    }
    final pwd = await _askBackupPassword('backup_export');
    if (pwd == null || pwd.isEmpty) return;
    // The backup is encrypted with the OWNER password — verify it.
    if (!await auth.verifyOwnerPassword(pwd)) {
      Get.snackbar('error'.tr, 'wrong_password'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
      return;
    }
    isLoading.value = true;
    try {
      final gName = auth.account.value?.generatorName ?? 'Generator';
      final path = await LocalBackupService()
          .export(password: pwd, generatorName: gName);
      await Share.shareXFiles([XFile(path)], text: 'Flash backup — $gName');
    } catch (e) {
      Get.snackbar('error'.tr, "${'export_failed'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
  }

  /// Pick a `.backup` file + password and restore boards+circuits+subscribers.
  /// Owner/admin only.
  Future<void> importSubscriberBackup() async {
    if (auth.isAccountant) {
      Get.snackbar('error'.tr, 'no_permission'.tr);
      return;
    }
    final res =
        await FilePicker.platform.pickFiles(dialogTitle: 'select_backup_file'.tr);
    final path = res?.files.single.path;
    if (path == null) return;
    final pwd = await _askBackupPassword('backup_import');
    if (pwd == null || pwd.isEmpty) return;
    isLoading.value = true;
    try {
      final counts = await LocalBackupService()
          .import(file: File(path), password: pwd);
      final total = counts.values.fold<int>(0, (a, b) => a + b);
      SyncController.poke(); // the restore writes queue an upload
      // v21 item 3: refresh the in-app lists + dashboard so the imported
      // boards/circuits/subscribers appear immediately (no app restart).
      try {
        if (Get.isRegistered<SyncController>()) {
          await Get.find<SyncController>().reloadAppData();
        }
      } catch (_) {}
      Get.snackbar('success'.tr, '${'backup_imported'.tr}: $total',
          backgroundColor: Colors.green, colorText: Colors.white);
    } on FormatException {
      Get.snackbar('error'.tr, 'backup_wrong_password'.tr,
          backgroundColor: Colors.redAccent, colorText: Colors.white);
    } catch (e) {
      Get.snackbar('error'.tr, "${'import_failed'.tr}: $e");
    } finally {
      isLoading.value = false;
    }
  }

  void _confirmImportProcess(File file) {
    Get.defaultDialog(
      title: 'confirm_restore'.tr,
      middleText: 'import_overwrite_warning'.tr,
      textConfirm: 'restore'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        _performImport(file);
      },
    );
  }

  Future<void> _performImport(File sourceFile) async {
    try {
      isLoading.value = true;
      String dbPath = await _dbHelper.getDbPath();

      // Close DB connection first to release lock
      await _dbHelper.close();

      // Overwrite file
      await sourceFile.copy(dbPath);

      // Clear the restored snapshot's PENDING outbox so its stale rows aren't
      // re-pushed (and resurrect old data) on the next login's push-before-pull
      // (audit fix). Opening here also runs any migrations on the restored file.
      final db = await _dbHelper.database;
      await db.delete('sync_outbox');
      await _dbHelper.close();

      Get.defaultDialog(
        title: 'success'.tr,
        middleText: 'import_success_restart'.tr,
        textConfirm: 'logout_restart'.tr,
        barrierDismissible: false,
        onConfirm: () {
          auth.logout();
          Get.back();
          // Optionally exit(0) or just let logout handle it.
          // Logout usually redirects to login, which is fine.
        },
      );
    } catch (e) {
      Get.snackbar('error'.tr, "${'import_execution_failed'.tr}: $e");
      // Try to reopen db if failed?
    } finally {
      isLoading.value = false;
    }
  }

  // --------------------------------------------------------------------------
  // CLOUD BACKUP (server-side DB snapshots) — distinct from local export/import
  // --------------------------------------------------------------------------

  Future<void> refreshCloudBackups() async {
    // Backup is a per-plan capability — never hit the (gated) backup API when
    // the active plan disables it (the backend would 403 FEATURE_DISABLED).
    if (!auth.canBackup) return;
    // Silent no-op when offline (this runs on screen open; the UI shows an
    // 'online_only' hint instead of nagging with a snackbar each time).
    if (!await ConnectivityService().isOnline()) return;
    isCloudBusy.value = true;
    try {
      cloudBackups.assignAll(await _backupRepo.list());
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  Future<void> uploadCloudBackup({String? note}) async {
    // Backup is a per-plan capability. The Settings tile reaching this screen is
    // already hidden when backup is off, but guard here too (defense in depth)
    // so NO path can fire a backup network call or show a backup toast on a plan
    // without backup — matching refreshCloudBackups + the sync side. Silent
    // return: a disabled feature must never notify.
    if (!auth.canBackup) return;
    final online = await ConnectivityService().isOnline();
    if (!online) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }

    isCloudBusy.value = true;
    try {
      await _backupRepo.upload(note: note);
      final iso = DateTime.now().toIso8601String();
      await SessionCache().setLastBackupAt(iso);
      lastCloudBackupAt.value = iso;
      Get.snackbar('cloud_backup'.tr, 'backup_uploaded'.tr);
      await refreshCloudBackups();
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  Future<void> deleteCloudBackup(String id) async {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    if (!await ConnectivityService().isOnline()) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }
    isCloudBusy.value = true;
    try {
      await _backupRepo.delete(id);
      cloudBackups.removeWhere((b) => b.id == id);
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }

  void restoreCloudBackup(String id) {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    Get.defaultDialog(
      title: 'cloud_backup'.tr,
      middleText: 'restore_overwrite_warning'.tr,
      textConfirm: 'restore'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: Colors.red,
      onConfirm: () {
        Get.back();
        _performCloudRestore(id);
      },
    );
  }

  Future<void> _performCloudRestore(String id) async {
    if (!auth.canBackup) return; // per-plan capability guard (see uploadCloudBackup)
    if (!await ConnectivityService().isOnline()) {
      Get.snackbar('cloud_backup'.tr, 'online_only'.tr);
      return;
    }
    isCloudBusy.value = true;
    try {
      await _backupRepo.restore(id);
      Get.snackbar('cloud_backup'.tr, 'backup_restored'.tr);
      // Force a restart-like reload so the freshly restored DB is picked up.
      Get.find<AuthController>().logout();
    } catch (e) {
      Get.snackbar('error'.tr, "${'cloud_backup'.tr}: $e");
    } finally {
      isCloudBusy.value = false;
    }
    update();
  }
}
