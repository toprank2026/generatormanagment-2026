import 'package:get/get.dart';
import 'package:intl/intl.dart';

/// v39 item 6 — 12-hour clock for every DISPLAYED timestamp (AM/PM instead of
/// 24-hour), localized as ص/م in Arabic. DISPLAY-ONLY: storage (ISO strings in
/// SQLite / the mirror) is untouched; callers keep their own toLocal()
/// decisions and pass the DateTime they used to render before.

/// `yyyy-MM-dd hh:mm AM|PM` — the app-wide replacement for the old
/// `yyyy-MM-dd HH:mm`. [amText]/[pmText] override the localized marker for
/// surfaces that are always Arabic (the printed receipts).
String fmtDateTime12(DateTime d, {String? amText, String? pmText}) =>
    '${DateFormat('yyyy-MM-dd').format(d)} '
    '${fmtTime12(d, amText: amText, pmText: pmText)}';

/// `hh:mm AM|PM` (zero-padded 12-hour, matching the old zero-padded look).
String fmtTime12(DateTime d, {String? amText, String? pmText}) {
  final int h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final String hh = h.toString().padLeft(2, '0');
  final String mm = d.minute.toString().padLeft(2, '0');
  final String marker =
      d.hour < 12 ? (amText ?? 'time_am'.tr) : (pmText ?? 'time_pm'.tr);
  return '$hh:$mm $marker';
}
