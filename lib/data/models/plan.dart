/// A subscription plan offered by the backend (accounts-only domain).
class Plan {
  final String code;
  final String name;
  final int durationDays;
  final int maxDevices;
  final num price;
  final String? description;
  final bool active;

  Plan({
    required this.code,
    required this.name,
    this.durationDays = 0,
    this.maxDevices = 1,
    this.price = 0,
    this.description,
    this.active = true,
  });

  factory Plan.fromJson(Map<String, dynamic> j) => Plan(
        code: (j['code'] ?? '').toString(),
        name: (j['name'] ?? j['code'] ?? '').toString(),
        durationDays: ((j['durationDays'] ?? 0) as num).toInt(),
        maxDevices: ((j['maxDevices'] ?? 1) as num).toInt(),
        price: (j['price'] ?? 0) as num,
        description: j['description'] as String?,
        active: (j['active'] ?? true) as bool,
      );
}
