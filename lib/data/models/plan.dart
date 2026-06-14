/// A subscription plan offered by the backend (accounts-only domain).
class Plan {
  final String code;
  final String name;
  final int durationDays;
  final int maxDevices;
  final num price;
  final String? description;
  final bool active;

  // Per-plan capability flags (what THIS plan offers). The backend serializes
  // them with `!== false` semantics, so they default to true when absent —
  // keeping plans that predate the flags fully featured. These drive the
  // per-feature check/cross marks on the plan card; do not confuse them with
  // AuthController.canSync/canBackup (which reflect the CURRENT account's
  // active plan, not the plan being browsed).
  final bool syncEnabled;
  final bool backupEnabled;
  final bool ownerPanelEnabled;

  Plan({
    required this.code,
    required this.name,
    this.durationDays = 0,
    this.maxDevices = 1,
    this.price = 0,
    this.description,
    this.active = true,
    this.syncEnabled = true,
    this.backupEnabled = true,
    this.ownerPanelEnabled = true,
  });

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        code: (j['code'] ?? '').toString(),
        name: (j['name'] ?? j['code'] ?? '').toString(),
        durationDays: ((j['durationDays'] ?? 0) as num).toInt(),
        maxDevices: ((j['maxDevices'] ?? 1) as num).toInt(),
        price: (j['price'] ?? 0) as num,
        description: j['description'] as String?,
        active: (j['active'] ?? true) as bool,
        syncEnabled: (j['syncEnabled'] ?? true) as bool,
        backupEnabled: (j['backupEnabled'] ?? true) as bool,
        ownerPanelEnabled: (j['ownerPanelEnabled'] ?? true) as bool,
      );
}
