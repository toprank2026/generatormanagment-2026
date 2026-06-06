// Backend (accounts-only) entities: the owner Account, its Subscription and
// bound Devices. These live on the server — distinct from the local SQLite
// business data and the local staff `users` table.

class Subscription {
  /// none | pending | active | rejected | expired
  final String status;
  final String? planCode;
  final String? startedAt;
  final String? expiresAt;

  Subscription({
    this.status = 'none',
    this.planCode,
    this.startedAt,
    this.expiresAt,
  });

  bool get isActive => status == 'active';
  bool get isPending => status == 'pending';

  factory Subscription.fromJson(Map<String, dynamic>? j) {
    if (j == null) return Subscription();
    return Subscription(
      status: (j['status'] ?? 'none').toString(),
      planCode: (j['planCode'] ?? j['plan'])?.toString(),
      startedAt: j['startedAt'] as String?,
      expiresAt: j['expiresAt'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status,
        'planCode': planCode,
        'startedAt': startedAt,
        'expiresAt': expiresAt,
      };
}

class DeviceBinding {
  final String deviceId;
  final String? installId;
  final String? platform;
  final String? model;
  final String? osVersion;
  final String? lastSeen;
  final bool current;

  DeviceBinding({
    required this.deviceId,
    this.installId,
    this.platform,
    this.model,
    this.osVersion,
    this.lastSeen,
    this.current = false,
  });

  factory DeviceBinding.fromJson(Map<String, dynamic> j) => DeviceBinding(
        deviceId: (j['deviceId'] ?? j['_id'] ?? '').toString(),
        installId: j['installId'] as String?,
        platform: j['platform'] as String?,
        model: j['model'] as String?,
        osVersion: j['osVersion'] as String?,
        lastSeen: j['lastSeen'] as String?,
        current: (j['current'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'installId': installId,
        'platform': platform,
        'model': model,
        'osVersion': osVersion,
        'lastSeen': lastSeen,
        'current': current,
      };
}

class Account {
  final String id;
  final String name;
  final String? phone;
  final String username;
  final String role; // owner | admin
  final bool blocked;
  final String? createdAt;
  final Subscription subscription;
  final List<DeviceBinding> devices;

  Account({
    required this.id,
    required this.name,
    this.phone,
    required this.username,
    this.role = 'owner',
    this.blocked = false,
    this.createdAt,
    Subscription? subscription,
    this.devices = const [],
  }) : subscription = subscription ?? Subscription();

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: (j['id'] ?? j['_id'] ?? '').toString(),
        name: (j['name'] ?? j['username'] ?? '').toString(),
        phone: j['phone'] as String?,
        username: (j['username'] ?? j['email'] ?? '').toString(),
        role: (j['role'] ?? 'owner').toString(),
        blocked: (j['blocked'] ?? false) as bool,
        createdAt: j['createdAt'] as String?,
        subscription: Subscription.fromJson(
          j['subscription'] is Map
              ? (j['subscription'] as Map).cast<String, dynamic>()
              : null,
        ),
        devices: (j['devices'] is List ? j['devices'] as List : const [])
            .whereType<Map<String, dynamic>>()
            .map(DeviceBinding.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'username': username,
        'role': role,
        'blocked': blocked,
        'createdAt': createdAt,
        'subscription': subscription.toJson(),
        'devices': devices.map((d) => d.toJson()).toList(),
      };
}

/// A cloud backup entry (metadata) returned by the backup endpoints.
class BackupEntry {
  final String id;
  final int size;
  final String? note;
  final String? createdAt;

  BackupEntry({required this.id, this.size = 0, this.note, this.createdAt});

  factory BackupEntry.fromJson(Map<String, dynamic> j) => BackupEntry(
        id: (j['id'] ?? j['_id'] ?? '').toString(),
        size: (j['size'] ?? 0) as int,
        note: j['note'] as String?,
        createdAt: j['createdAt'] as String?,
      );
}
