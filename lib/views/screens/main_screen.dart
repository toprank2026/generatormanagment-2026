import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:iconsax/iconsax.dart';

import 'package:generatormanagment/controllers/main_nav_controller.dart';
import 'package:generatormanagment/views/screens/dashboard_screen.dart';
import 'package:generatormanagment/views/screens/monthly_pricing_screen.dart'; // Using as Payments/Pricing tab for now
import 'package:generatormanagment/views/screens/expenses_screen.dart';
import 'package:generatormanagment/views/screens/reports_screen.dart';
import 'package:generatormanagment/views/screens/settings_screen.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  static const List<Widget> _pages = [
    DashboardScreen(),
    MonthlyPricingScreen(), // Payments
    ExpensesScreen(),
    ReportsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final MainNavController nav = Get.put(MainNavController());

    return Scaffold(
      body: Obx(
        () => IndexedStack(index: nav.currentIndex.value, children: _pages),
      ),
      bottomNavigationBar: Obx(
        () => BottomNavigationBar(
          currentIndex: nav.currentIndex.value,
          onTap: nav.setIndex,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Theme.of(context).primaryColor,
          unselectedItemColor: Colors.grey,
          items: [
            BottomNavigationBarItem(
              icon: const Icon(Iconsax.home),
              activeIcon: const Icon(Iconsax.home5),
              label: 'home'.tr,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Iconsax.money),
              activeIcon: const Icon(Iconsax.money5),
              label: 'payments'.tr,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Iconsax.receipt),
              activeIcon: const Icon(Iconsax.receipt5),
              label: 'expenses'.tr,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Iconsax.chart_2),
              activeIcon: const Icon(Iconsax.chart_26),
              label: 'reports'.tr,
            ),
            BottomNavigationBarItem(
              icon: const Icon(Iconsax.setting),
              activeIcon: const Icon(Iconsax.setting5),
              label: 'settings'.tr,
            ),
          ],
        ),
      ),
    );
  }
}
