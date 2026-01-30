import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:iconsax/iconsax.dart';

import 'package:generatormanagment/views/screens/dashboard_screen.dart';
import 'package:generatormanagment/views/screens/monthly_pricing_screen.dart'; // Using as Payments/Pricing tab for now
import 'package:generatormanagment/views/screens/expenses_screen.dart';
import 'package:generatormanagment/views/screens/settings_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _pages = [
    const DashboardScreen(),
    const MonthlyPricingScreen(), // Payments
    const ExpensesScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
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
            icon: const Icon(Iconsax.setting),
            activeIcon: const Icon(Iconsax.setting5),
            label: 'settings'.tr,
          ),
        ],
      ),
    );
  }
}
