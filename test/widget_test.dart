// A plugin-free widget test.
//
// We deliberately do NOT pump the real MyApp/RootHandler, because that boots
// AuthController which depends on SharedPreferences / secure_storage /
// connectivity plugins that are unavailable in the test environment.
//
// Instead we pump a tiny self-contained GetMaterialApp wired with the real
// Messages() translations and assert that '.tr' keys render their translated
// values for both locales. The translated subtree is built inside a Builder so
// that '.tr' is evaluated during the widget build (after GetMaterialApp has
// installed the translations/locale) rather than eagerly at construction time.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:generatormanagment/utils/translations.dart';

Widget _buildApp(Locale locale) {
  return GetMaterialApp(
    translations: Messages(),
    locale: locale,
    fallbackLocale: const Locale('en', 'US'),
    home: Builder(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('app_name'.tr)),
        body: Column(
          children: [
            Text('settings'.tr),
            Text('dashboard'.tr),
          ],
        ),
      ),
    ),
  );
}

void main() {
  test('Messages exposes en_US and ar_AR keys', () {
    final keys = Messages().keys;
    expect(keys.keys, containsAll(<String>['en_US', 'ar_AR']));
    expect(keys['en_US'], isNotEmpty);
    expect(keys['ar_AR'], isNotEmpty);
  });

  testWidgets('renders English translations via .tr', (tester) async {
    await tester.pumpWidget(_buildApp(const Locale('en', 'US')));
    await tester.pumpAndSettle();

    expect(find.text('Flash'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);

    // The raw key must never leak into the UI.
    expect(find.text('app_name'), findsNothing);
  });

  testWidgets('renders Arabic translations via .tr', (tester) async {
    await tester.pumpWidget(_buildApp(const Locale('ar', 'AR')));
    await tester.pumpAndSettle();

    expect(find.text('فلاش'), findsOneWidget);
    expect(find.text('الإعدادات'), findsOneWidget);
    expect(find.text('لوحة التحكم'), findsOneWidget);

    expect(find.text('app_name'), findsNothing);
  });
}
