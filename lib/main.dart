import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/core/app_binding.dart';
import 'package:generatormanagment/core/dev_seed.dart';
import 'package:generatormanagment/views/auth/signup_screen.dart';
import 'package:generatormanagment/views/screens/login_screen.dart';
import 'package:generatormanagment/views/screens/home_screen.dart';
import 'package:generatormanagment/views/screens/setup_screen.dart';
import 'package:generatormanagment/views/screens/plan_selection_screen.dart';
import 'package:generatormanagment/views/root_handler.dart';
import 'package:generatormanagment/utils/translations.dart';
import 'package:generatormanagment/utils/printer_prefs.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();

  // DEBUG-ONLY scale seeder (off unless --dart-define=DEV_SEED=true).
  if (const bool.fromEnvironment('DEV_SEED')) {
    await DevSeed.run(
      count: const int.fromEnvironment('DEV_SEED_COUNT', defaultValue: 1000),
    );
  }

  // Load saved language; default to Arabic when the user hasn't chosen one.
  final prefs = await SharedPreferences.getInstance();
  final langCode = prefs.getString('lang_code');
  final locale = langCode == 'en'
      ? const Locale('en', 'US')
      : const Locale('ar', 'AR');

  // Prime the cached thermal-printer paper width for the print services.
  await PrinterPrefs.load();

  runApp(MyApp(initialLocale: locale));
}

class MyApp extends StatelessWidget {
  final Locale initialLocale;
  const MyApp({super.key, required this.initialLocale});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Moldati Owner',
      translations: Messages(), // your translations class
      locale: initialLocale, // default locale, or use Get.deviceLocale
      fallbackLocale: const Locale('en', 'US'),
      theme: ThemeData(
        fontFamily: 'Cairo',
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2196F3), // Blue
          primary: const Color(0xFF2196F3),
          secondary: const Color(0xFF64B5F6),
          surface: Colors.white,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(
          0xFFF5F5F5,
        ), // Light grey background
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black, // Dark text on white app bar
          elevation: 0,
        ),
      ),
      initialBinding: AppBinding(),
      home: const RootHandler(),
      getPages: [
        GetPage(name: '/login', page: () => const LoginScreen()),
        GetPage(name: '/signup', page: () => const SignupScreen()),
        GetPage(name: '/setup', page: () => const SetupScreen()),
        GetPage(name: '/plan', page: () => const PlanSelectionScreen()),
        GetPage(name: '/home', page: () => const HomeScreen()),
      ],
    );
  }
}
