import 'dart:convert';
import 'package:get/get.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:generatormanagment/data/repositories/user_repository.dart';

class AuthController extends GetxController {
  final UserRepository _userRepo = UserRepository();
  var isLoggedIn = false.obs;
  var currentUser = Rxn<User>();
  var isLoading = true.obs;

  bool get isAdmin => currentUser.value?.role == 'admin';

  @override
  void onInit() {
    super.onInit();
    checkLoginStatus();
  }

  Future<void> checkLoginStatus() async {
    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? userId = prefs.getString('user_id');
      if (userId != null) {
        User? user = await _userRepo.getUserById(userId);
        if (user != null) {
          currentUser.value = user;
          isLoggedIn.value = true;
        } else {
          // User ID exists in prefs but not in DB (maybe deleted)
          await logout();
        }
      }
    } catch (e) {
      print("Error checking login: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<bool> login(String username, String password) async {
    String hash = sha256.convert(utf8.encode(password)).toString();
    User? user = await _userRepo.getUserByUsername(username);

    if (user != null && user.passwordHash == hash) {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', user.id);
      await prefs.setString('role', user.role);

      currentUser.value = user;
      isLoggedIn.value = true;
      update();
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    isLoggedIn.value = false;
    currentUser.value = null;
    update();
    // Get.offAllNamed('/login'); // We handle navigation in binding/middleware usually
  }

  Future<void> createInitialAdmin(String username, String password) async {
    String hash = sha256.convert(utf8.encode(password)).toString();
    User admin = User(
      id: const Uuid().v4(),
      username: username,
      passwordHash: hash,
      role: 'admin',
    );
    await _userRepo.insertUser(admin);
    await login(username, password);
    update();
  }

  Future<bool> hasAnyUser() async {
    int count = await _userRepo.countUsers();
    return count > 0;
  }
}
