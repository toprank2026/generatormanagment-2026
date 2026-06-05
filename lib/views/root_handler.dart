import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/login_screen.dart';
import 'package:generatormanagment/views/screens/main_screen.dart';
import 'package:generatormanagment/views/screens/plan_selection_screen.dart';

/// Root gate (offline-first):
///   loading        → spinner
///   not signed in  → LoginScreen
///   no active plan  → PlanSelectionScreen  (only enforced when the server,
///                     while online, said the subscription is inactive/blocked)
///   otherwise      → MainScreen
class RootHandler extends StatelessWidget {
  const RootHandler({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController authController = Get.find();

    return Obx(() {
      if (authController.isLoading.value) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (!authController.isLoggedIn.value) {
        return const LoginScreen();
      }
      if (authController.subscriptionBlocked.value) {
        return const PlanSelectionScreen();
      }
      return const MainScreen();
    });
  }
}
