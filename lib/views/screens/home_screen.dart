import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/boards_screen.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/monthly_pricing_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController auth = Get.find();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Dashboard"),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("Welcome to Moldati Owner App"),
            const SizedBox(height: 20),
            Obx(
              () => Text(
                "Logged in as: ${auth.currentUser.value?.username ?? 'Unknown'}",
              ),
            ),
          ],
        ),
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            UserAccountsDrawerHeader(
              accountName: Obx(
                () => Text(auth.currentUser.value?.username ?? ""),
              ),
              accountEmail: Obx(() => Text(auth.currentUser.value?.role ?? "")),
            ),
            ListTile(
              leading: const Icon(Icons.dashboard),
              title: const Text("Home"),
              onTap: () => Get.back(),
            ),
            ListTile(
              leading: const Icon(Icons.grid_view),
              title: const Text("Boards"),
              onTap: () {
                Get.to(() => const BoardsScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.people),
              title: const Text("Users"),
              onTap: () {
                Get.to(() => const SubscribersScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.money),
              title: const Text("Payment"),
              onTap: () {
                Get.to(() => const MonthlyPricingScreen());
              },
            ),
            ListTile(
              leading: const Icon(Icons.receipt),
              title: const Text("Expenses"),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text("Settings"),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }
}
