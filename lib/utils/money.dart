import 'package:intl/intl.dart';

/// v19 — app-wide monetary amount formatter.
///
/// Formats an IQD amount with thousands separators and no decimals, e.g.
///   1000000  -> "1,000,000"
///   12500000 -> "12,500,000"
/// The 'en_US' locale forces a comma grouping separator (matching the spec),
/// independent of the app's Arabic locale. Callers append the currency unit
/// themselves (`'iqd'.tr` -> "د.ع " / "IQD ") so RTL placement stays as-is.
final NumberFormat _kAmountFormat = NumberFormat('#,##0', 'en_US');

/// Thousands-separated integer string for a monetary [value] (IQD).
String fmtAmount(num value) => _kAmountFormat.format(value);
