import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/boards_screen.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/monthly_pricing_screen.dart';
import 'package:iconsax/iconsax.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final AuthController auth = Get.find();

    return Scaffold(
      appBar: AppBar(
        title: Text('dashboard'.tr),
        actions: [
          IconButton(
            icon: const Icon(Iconsax.logout),
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('home_welcome'.tr),
            const SizedBox(height: 20),
            Obx(
              () => Text(
                "${'home_logged_in_as'.tr} ${auth.currentUser.value?.username ?? 'Unknown'}",
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
              leading: const Icon(Iconsax.home),
              title: Text('home'.tr),
              onTap: () => Get.back(),
            ),
            ListTile(
              leading: const Icon(Iconsax.box),
              title: Text('boards'.tr),
              onTap: () {
                Get.to(() => const BoardsScreen());
              },
            ),
            ListTile(
              leading: const Icon(Iconsax.people),
              title: Text('users'.tr),
              onTap: () {
                Get.to(() => const SubscribersScreen());
              },
            ),
            ListTile(
              leading: const Icon(Iconsax.money),
              title: Text('payments'.tr),
              onTap: () {
                Get.to(() => const MonthlyPricingScreen());
              },
            ),
            ListTile(
              leading: const Icon(Iconsax.receipt),
              title: Text('expenses'.tr),
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Iconsax.setting),
              title: Text('settings'.tr),
              onTap: () {},
            ),
          ],
        ),
      ),
    );
  }
}
