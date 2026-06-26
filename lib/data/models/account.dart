// Backend (accounts-only) entities: the owner Account, its Subscription and
// bound Devices. These live on the server — distinct from the local SQLite
// business data and the local staff `users` table.

class Subscription {
  /// none | pending | active | rejected | expired
  final String status;
  final String? planCode;
  final String? startedAt;
  final String? expiresAt;

  /// v15: SERVER-computed remaining days (expiresAt − server now), refreshed on
  /// each online validation. Displayed instead of the total duration; never
  /// recomputed from the local device clock (manipulation-proof). null = no
  /// expiry / open-ended plan.
  final int? remainingDays;

  /// Per-plan capability flags resolved from the account's active plan
  /// (sync / backup / ownerPanel). Each capability is enabled unless the map
  /// explicitly says `false`, so an absent/unknown flag stays TRUE for
  /// backward compatibility with accounts whose plan predates the feature.
  final Map<String, dynamic> features;

  Subscription({
    this.status = 'none',
    this.planCode,
    this.startedAt,
    this.expiresAt,
    this.remainingDays,
    Map<String, dynamic>? features,
  }) : features = features ?? const {};

  bool get isActive => status == 'active';
  bool get isPending => status == 'pending';

  /// TRUE unless [features] explicitly disables [k] (absent/unknown => true).
  bool _feat(String k) => features[k] != false;
  bool get syncEnabled => _feat('sync');
  bool get backupEnabled => _feat('backup');
  bool get ownerPanelEnabled => _feat('ownerPanel');
  // Multi-Branch is an opt-in upgrade → enabled ONLY when explicitly true
  // (absent/unknown => false), unlike the default-on capabilities above.
  bool get multiBranchEnabled => features['multiBranch'] == true;

  factory Subscription.fromJson(Map<String, dynamic>? j) {
    if (j == null) return Subscription();
    return Subscription(
      status: (j['status'] ?? 'none').toString(),
      planCode: (j['planCode'] ?? j['plan'])?.toString(),
      startedAt: j['startedAt'] as String?,
      expiresAt: j['expiresAt'] as String?,
      remainingDays: (j['remainingDays'] as num?)?.toInt(),
      features: j['features'] is Map
          ? (j['features'] as Map).cast<String, dynamic>()
          : const {},
    );
  }

  Map<String, dynamic> toJson() => {
        'status': status,
        'planCode': planCode,
        'startedAt': startedAt,
        'expiresAt': expiresAt,
        'remainingDays': remainingDays,
        'features': features,
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
  final String? generatorName;
  final String? phone;
  final String username;
  final String role; // owner | admin | accountant
  final bool blocked;
  final String? createdAt;
  final Subscription subscription;
  final List<DeviceBinding> devices;

  // --- Accountant sub-account fields (R8) — present only when role ==
  //     'accountant'. The backend inherits the subscription from the owner. ---
  /// The parent owner account id (accountant only).
  final String? ownerId;
  /// The branch this accountant is tied to (accountant only).
  final String? branchId;
  /// Granted permission keys (accountant only); owners/admins do everything.
  final List<String> permissions;
  /// The app-side accountant UUID, round-tripped so business rows the
  /// accountant creates carry the same `accountant_id` the owner already sees.
  final String? localId;

  Account({
    required this.id,
    required this.name,
    this.generatorName,
    this.phone,
    required this.username,
    this.role = 'owner',
    this.blocked = false,
    this.createdAt,
    Subscription? subscription,
    this.devices = const [],
    this.ownerId,
    this.branchId,
    this.permissions = const [],
    this.localId,
  }) : subscription = subscription ?? Subscription();

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: (j['id'] ?? j['_id'] ?? '').toString(),
        name: (j['name'] ?? j['username'] ?? j['email'] ?? '').toString(),
        generatorName: j['generatorName'] as String?,
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
        ownerId: j['ownerId']?.toString(),
        branchId: j['branchId']?.toString(),
        permissions: (j['permissions'] is List
            ? (j['permissions'] as List).map((e) => e.toString()).toList()
            : const <String>[]),
        localId: j['localId']?.toString(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'generatorName': generatorName,
        'phone': phone,
        'username': username,
        'role': role,
        'blocked': blocked,
        'createdAt': createdAt,
        'subscription': subscription.toJson(),
        'devices': devices.map((d) => d.toJson()).toList(),
        'ownerId': ownerId,
        'branchId': branchId,
        'permissions': permissions,
        'localId': localId,
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
