// Verifies that the en_US and ar_AR translation maps stay in sync.
//
// This catches the classic "raw key shows up in the UI" bug that happens
// when a key is added to one locale but forgotten in the other, and also
// guards against empty translation values.

import 'package:flutter_test/flutter_test.dart';
import 'package:generatormanagment/utils/translations.dart';

void main() {
  final keys = Messages().keys;

  test('both en_US and ar_AR locales are present', () {
    expect(keys.containsKey('en_US'), isTrue, reason: 'en_US locale missing');
    expect(keys.containsKey('ar_AR'), isTrue, reason: 'ar_AR locale missing');
  });

  test('en_US and ar_AR have the EXACT same set of keys', () {
    final en = keys['en_US']!.keys.toSet();
    final ar = keys['ar_AR']!.keys.toSet();

    final missingInAr = en.difference(ar);
    final missingInEn = ar.difference(en);

    expect(
      missingInAr,
      isEmpty,
      reason: 'Keys present in en_US but missing in ar_AR: $missingInAr',
    );
    expect(
      missingInEn,
      isEmpty,
      reason: 'Keys present in ar_AR but missing in en_US: $missingInEn',
    );
  });

  test('no translation value is empty in en_US', () {
    final empty = keys['en_US']!.entries
        .where((e) => e.value.trim().isEmpty)
        .map((e) => e.key)
        .toList();
    expect(empty, isEmpty, reason: 'Empty en_US values for keys: $empty');
  });

  test('no translation value is empty in ar_AR', () {
    final empty = keys['ar_AR']!.entries
        .where((e) => e.value.trim().isEmpty)
        .map((e) => e.key)
        .toList();
    expect(empty, isEmpty, reason: 'Empty ar_AR values for keys: $empty');
  });
}
