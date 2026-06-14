/// Per-accountant permission keys.
///
/// An accountant ALWAYS can record payments + print receipts (their core job).
/// Beyond that, the owner grants any of these when creating/editing the
/// accountant. The owner/admin implicitly has all permissions.
class Perm {
  Perm._();

  /// Add / edit / delete subscribers (accountant's own, auto-assigned to them).
  static const String subscribers = 'subscribers';

  /// Add / edit / delete boards & circuits.
  static const String boards = 'boards';

  /// Add / edit / delete expenses.
  static const String expenses = 'expenses';

  /// Set / edit monthly prices.
  static const String prices = 'prices';

  /// All grantable permissions, in display order. Each maps to a translation
  /// key `perm_<value>` for its label.
  static const List<String> all = [subscribers, boards, expenses, prices];

  /// Parse a stored comma-separated string into a set of keys.
  static Set<String> parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>{};
    return raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// Serialize a set of keys to the stored comma-separated string.
  static String encode(Iterable<String> perms) => perms.join(',');
}
