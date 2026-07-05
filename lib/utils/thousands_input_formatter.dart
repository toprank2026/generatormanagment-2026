import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// v27 item 2 — live thousands-separator formatting for integer amount fields
/// (e.g. 1500000 → "1,500,000") while typing. Strips existing separators, keeps
/// digits only, and re-groups; the cursor is placed at the end. Parse the field
/// value with `text.replaceAll(',', '')` before `double.tryParse`.
class ThousandsInputFormatter extends TextInputFormatter {
  static final NumberFormat _fmt = NumberFormat.decimalPattern('en_US');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) {
      return const TextEditingValue(text: '');
    }
    // Guard against absurdly long inputs (int overflow) — cap at 15 digits.
    final trimmed = digits.length > 15 ? digits.substring(0, 15) : digits;
    final formatted = _fmt.format(int.parse(trimmed));
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

/// Parse a possibly comma-grouped amount string to a double (null if empty).
double? parseGroupedAmount(String s) {
  final clean = s.replaceAll(',', '').trim();
  if (clean.isEmpty) return null;
  return double.tryParse(clean);
}
