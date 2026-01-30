import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:generatormanagment/data/repositories/user_repository.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

class SettingsController extends GetxController {
  final UserRepository _userRepo = UserRepository();
  final DbHelper _dbHelper = DbHelper();
  final AuthController auth = Get.find();

  var users = <User>[].obs;
  var isLoading = false.obs;

  // Printer Settings
  var printerName = "".obs;
  var printerAddress = "".obs;

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

    if (langCode == 'ar') {
      return const Locale('ar', 'AR');
    }
    return const Locale('en', 'US');
  }

  @override
  void onReady() {
    super.onReady();
    loadPrinterSettings();
    if (auth.currentUser.value?.role == 'admin') {
      loadUsers();
    }
  }

  Future<void> loadPrinterSettings() async {
    final prefs = await SharedPreferences.getInstance();
    printerName.value = prefs.getString(_keyPrinterName) ?? "";
    printerAddress.value = prefs.getString(_keyPrinterAddress) ?? "";
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

  Future<void> loadUsers() async {
    isLoading.value = true;
    users.value = await _userRepo.getAllUsers();
    isLoading.value = false;
    update();
  }

  Future<void> addUser(String username, String password, String role) async {
    String hash = sha256.convert(utf8.encode(password)).toString();
    User u = User(
      id: const Uuid().v4(),
      username: username,
      passwordHash: hash,
      role: role,
    );
    await _userRepo.insertUser(u);
    loadUsers();
    Get.back();
    Get.snackbar("Success", "User added");
    update();
  }

  Future<void> deleteUser(String id) async {
    if (id == auth.currentUser.value?.id) {
      Get.snackbar("Error", "Cannot delete yourself");
      return;
    }
    await _userRepo.deleteUser(id);
    loadUsers();
    update();
  }

  Future<void> exportData() async {
    isLoading.value = true;
    try {
      String dbPath = await _dbHelper.getDbPath();
      File dbFile = File(dbPath);

      if (!dbFile.existsSync()) {
        Get.snackbar("Error", "Database file not found");
        return;
      }

      // Create a temporary file with a timestamped name
      final tempDir = await getTemporaryDirectory();
      String fileName =
          'moldati_backup_${DateTime.now().year}${DateTime.now().month}${DateTime.now().day}_${DateTime.now().hour}${DateTime.now().minute}.db';
      final tempFile = File(p.join(tempDir.path, fileName));

      // Copy db to temp file
      await dbFile.copy(tempFile.path);

      // Share the file
      await Share.shareXFiles(
        [XFile(tempFile.path)],
        text:
            'Moldati Database Backup ${DateTime.now().toString().split('.')[0]}',
      );
    } catch (e) {
      Get.snackbar("Error", "Export failed: $e");
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> importData() async {
    try {
      // Pick a file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        dialogTitle: 'Select Backup File',
      ); // Any extension, as we can't strictly enforce .db on all android versions reliably or user might have renamed it

      if (result != null && result.files.single.path != null) {
        String path = result.files.single.path!;
        File file = File(path);

        // Basic check if it likely is a db file or just try to open it
        if (!path.toLowerCase().endsWith('.db') &&
            !path.toLowerCase().endsWith('.sqlite')) {
          // We can warn but maybe proceed if user insists? For now let's just warn
          Get.defaultDialog(
            title: "Warning",
            middleText:
                "The selected file does not look like a database file (.db). Try anyway?",
            textConfirm: "Yes, Try",
            textCancel: "Cancel",
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
      Get.snackbar("Error", "Import failed: $e");
    }
  }

  void _confirmImportProcess(File file) {
    Get.defaultDialog(
      title: "Confirm Restore",
      middleText:
          "Warning: This will OVERWRITE all current data with the backup.\nThe app will restart/logout after import.",
      textConfirm: "Restore",
      textCancel: "Cancel",
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

      Get.defaultDialog(
        title: "Success",
        middleText:
            "Data imported successfully.\nPlease restart the app to ensure data consistency.",
        textConfirm: "Logout & Restart",
        barrierDismissible: false,
        onConfirm: () {
          auth.logout();
          Get.back();
          // Optionally exit(0) or just let logout handle it.
          // Logout usually redirects to login, which is fine.
        },
      );
    } catch (e) {
      Get.snackbar("Error", "Import execution failed: $e");
      // Try to reopen db if failed?
    } finally {
      isLoading.value = false;
    }
  }
}
