import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/login_screen.dart';

import 'package:generatormanagment/views/screens/main_screen.dart';

class RootHandler extends StatelessWidget {
  const RootHandler({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController authController = Get.find();

    return Obx(() {
      if (authController.isLoading.value) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }

      if (authController.isLoggedIn.value) {
        return const MainScreen();
      } else {
        return const LoginScreen();
      }
    });
  }
}
