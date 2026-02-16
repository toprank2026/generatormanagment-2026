import 'dart:convert';
import 'package:http/http.dart' as http;
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

  Future<Map<String, dynamic>> login(String username, String password) async {
    final String apiUrl = 'http://192.168.1.99:8000/api/login';

    try {
      print(
        "Sending Login Request: ${jsonEncode({'username': username, 'password': password})}",
      );

      final response = await http.post(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({'username': username, 'password': password}),
      );

      print("Login Response Status: ${response.statusCode}");
      print("Login Response Body: ${response.body}");

      final data = jsonDecode(response.body);

      if (response.statusCode == 200) {
        String token = data['token'];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', token);
        await prefs.setString(
          'user_id',
          username,
        ); // Using username as ID for now or from response

        // Mock user for now since we rely on local DB user model
        currentUser.value = User(
          id: "remote",
          username: username,
          passwordHash: "",
          role: "admin", // TODO: Fetch role from API if available
        );
        isLoggedIn.value = true;
        update();
        return {'success': true};
      } else {
        return {
          'success': false,
          'statusCode': response.statusCode,
          'message': data['message'] ?? 'Login failed',
        };
      }
    } catch (e) {
      print("Network Error: $e");
      return {'success': false, 'message': 'Network Error: $e'};
    }
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
