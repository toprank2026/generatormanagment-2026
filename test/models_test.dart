// Pure-Dart unit tests for the accounts-domain models:
//   lib/data/models/plan.dart
//   lib/data/models/account.dart
//
// These are hermetic: no DB, no network, no Flutter widget bindings.
// They exercise the JSON (de)serialization edge cases the real factories
// are written to defend against (doubles where ints are expected, missing
// fields, malformed shapes, round-tripping).

import 'package:flutter_test/flutter_test.dart';
import 'package:generatormanagment/data/models/plan.dart';
import 'package:generatormanagment/data/models/account.dart';

void main() {
  group('Plan.fromJson', () {
    test('parses normal integer fields', () {
      final p = Plan.fromJson({
        'code': 'pro',
        'name': 'Pro Plan',
        'durationDays': 30,
        'maxDevices': 3,
        'price': 10000,
        'description': 'best',
        'active': true,
      });

      expect(p.code, 'pro');
      expect(p.name, 'Pro Plan');
      expect(p.durationDays, 30);
      expect(p.maxDevices, 3);
      expect(p.price, 10000);
      expect(p.description, 'best');
      expect(p.active, true);
    });

    test('numbers given as doubles do not throw and are coerced via toInt()',
        () {
      // This is the regression that the `(... as num).toInt()` guard protects:
      // JSON decoders sometimes hand back doubles even for whole numbers.
      final p = Plan.fromJson({
        'code': 'pro',
        'durationDays': 30.0,
        'maxDevices': 1.0,
        'price': 10000.0,
      });

      expect(p.durationDays, isA<int>());
      expect(p.durationDays, 30);
      expect(p.maxDevices, isA<int>());
      expect(p.maxDevices, 1);
      // price is declared `num`, so the double is preserved as-is.
      expect(p.price, 10000.0);
    });

    test('truncates fractional doubles for int fields via toInt()', () {
      final p = Plan.fromJson({
        'code': 'x',
        'durationDays': 29.9,
        'maxDevices': 2.7,
      });

      expect(p.durationDays, 29);
      expect(p.maxDevices, 2);
    });

    test('missing fields fall back to defaults', () {
      final p = Plan.fromJson({'code': 'basic'});

      expect(p.code, 'basic');
      expect(p.durationDays, 0);
      expect(p.maxDevices, 1);
      expect(p.price, 0);
      expect(p.description, isNull);
      expect(p.active, true);
    });

    test('name falls back to code when name is absent', () {
      final p = Plan.fromJson({'code': 'fallback-code'});
      expect(p.name, 'fallback-code');
    });

    test('empty json yields empty code and empty name', () {
      final p = Plan.fromJson({});
      expect(p.code, '');
      expect(p.name, '');
    });
  });

  group('Subscription.fromJson', () {
    test('null json returns defaults', () {
      final s = Subscription.fromJson(null);
      expect(s.status, 'none');
      expect(s.planCode, isNull);
      expect(s.startedAt, isNull);
      expect(s.expiresAt, isNull);
      expect(s.isActive, false);
      expect(s.isPending, false);
    });

    test('default constructor matches "none" defaults', () {
      final s = Subscription();
      expect(s.status, 'none');
      expect(s.isActive, false);
      expect(s.isPending, false);
    });

    test('maps status and full fields', () {
      final s = Subscription.fromJson({
        'status': 'active',
        'planCode': 'pro',
        'startedAt': '2026-01-01',
        'expiresAt': '2026-02-01',
      });
      expect(s.status, 'active');
      expect(s.planCode, 'pro');
      expect(s.startedAt, '2026-01-01');
      expect(s.expiresAt, '2026-02-01');
    });

    test('isActive is true only when status == "active"', () {
      expect(Subscription.fromJson({'status': 'active'}).isActive, true);
      expect(Subscription.fromJson({'status': 'pending'}).isActive, false);
      expect(Subscription.fromJson({'status': 'expired'}).isActive, false);
      expect(Subscription.fromJson({'status': 'rejected'}).isActive, false);
    });

    test('isPending is true only when status == "pending"', () {
      expect(Subscription.fromJson({'status': 'pending'}).isPending, true);
      expect(Subscription.fromJson({'status': 'active'}).isPending, false);
    });

    test('planCode falls back to "plan" key', () {
      final s = Subscription.fromJson({'plan': 'legacy-plan'});
      expect(s.planCode, 'legacy-plan');
    });

    test('toJson exposes all fields', () {
      final s = Subscription.fromJson({
        'status': 'active',
        'planCode': 'pro',
        'startedAt': 'a',
        'expiresAt': 'b',
      });
      final j = s.toJson();
      expect(j['status'], 'active');
      expect(j['planCode'], 'pro');
      expect(j['startedAt'], 'a');
      expect(j['expiresAt'], 'b');
    });
  });

  group('DeviceBinding.fromJson', () {
    test('parses full object', () {
      final d = DeviceBinding.fromJson({
        'deviceId': 'dev-1',
        'installId': 'inst-1',
        'platform': 'android',
        'model': 'Pixel',
        'osVersion': '14',
        'lastSeen': '2026-06-06',
        'current': true,
      });
      expect(d.deviceId, 'dev-1');
      expect(d.installId, 'inst-1');
      expect(d.platform, 'android');
      expect(d.model, 'Pixel');
      expect(d.osVersion, '14');
      expect(d.lastSeen, '2026-06-06');
      expect(d.current, true);
    });

    test('deviceId falls back to _id, current defaults to false', () {
      final d = DeviceBinding.fromJson({'_id': 'mongo-id'});
      expect(d.deviceId, 'mongo-id');
      expect(d.current, false);
      expect(d.installId, isNull);
    });

    test('toJson round-trips through fromJson', () {
      final original = DeviceBinding.fromJson({
        'deviceId': 'dev-9',
        'installId': 'i9',
        'platform': 'ios',
        'model': 'iPhone',
        'osVersion': '17',
        'lastSeen': 'x',
        'current': true,
      });
      final reparsed = DeviceBinding.fromJson(original.toJson());
      expect(reparsed.deviceId, original.deviceId);
      expect(reparsed.installId, original.installId);
      expect(reparsed.platform, original.platform);
      expect(reparsed.model, original.model);
      expect(reparsed.osVersion, original.osVersion);
      expect(reparsed.lastSeen, original.lastSeen);
      expect(reparsed.current, original.current);
    });
  });

  group('BackupEntry.fromJson', () {
    test('parses full object', () {
      final b = BackupEntry.fromJson({
        'id': 'b1',
        'size': 2048,
        'note': 'nightly',
        'createdAt': '2026-06-06',
      });
      expect(b.id, 'b1');
      expect(b.size, 2048);
      expect(b.note, 'nightly');
      expect(b.createdAt, '2026-06-06');
    });

    test('id falls back to _id and size/note default', () {
      final b = BackupEntry.fromJson({'_id': 'mongo-backup'});
      expect(b.id, 'mongo-backup');
      expect(b.size, 0);
      expect(b.note, isNull);
      expect(b.createdAt, isNull);
    });
  });

  group('Account.fromJson', () {
    test('parses a full object', () {
      final a = Account.fromJson({
        'id': 'acc-1',
        'name': 'Owner',
        'phone': '+1000',
        'username': 'owner1',
        'role': 'admin',
        'blocked': true,
        'createdAt': '2026-01-01',
        'subscription': {
          'status': 'active',
          'planCode': 'pro',
        },
        'devices': [
          {'deviceId': 'd1', 'current': true},
          {'deviceId': 'd2'},
        ],
      });

      expect(a.id, 'acc-1');
      expect(a.name, 'Owner');
      expect(a.phone, '+1000');
      expect(a.username, 'owner1');
      expect(a.role, 'admin');
      expect(a.blocked, true);
      expect(a.createdAt, '2026-01-01');
      expect(a.subscription.isActive, true);
      expect(a.subscription.planCode, 'pro');
      expect(a.devices.length, 2);
      expect(a.devices.first.deviceId, 'd1');
      expect(a.devices.first.current, true);
      expect(a.devices[1].deviceId, 'd2');
    });

    test('id is sourced from _id when id is absent', () {
      final a = Account.fromJson({'_id': 'mongo-acc', 'username': 'u'});
      expect(a.id, 'mongo-acc');
    });

    test('name and username fall back (username/email)', () {
      final a = Account.fromJson({'email': 'me@example.com'});
      // username falls back to email; name falls back to username (email).
      expect(a.username, 'me@example.com');
      expect(a.name, 'me@example.com');
    });

    test('missing subscription yields default Subscription()', () {
      final a = Account.fromJson({'username': 'u'});
      expect(a.subscription.status, 'none');
      expect(a.subscription.isActive, false);
      expect(a.subscription.isPending, false);
    });

    test('subscription given as a non-map (String) does not throw -> defaults',
        () {
      // Defensive guard: `j['subscription'] is Map ? ... : null`.
      late Account a;
      expect(
        () => a = Account.fromJson({
          'username': 'u',
          'subscription': 'not-a-map',
        }),
        returnsNormally,
      );
      expect(a.subscription.status, 'none');
    });

    test('devices given as a non-list (String) does not throw -> empty', () {
      late Account a;
      expect(
        () => a = Account.fromJson({
          'username': 'u',
          'devices': 'not-a-list',
        }),
        returnsNormally,
      );
      expect(a.devices, isEmpty);
    });

    test('devices list with non-map entries skips them defensively', () {
      final a = Account.fromJson({
        'username': 'u',
        'devices': [
          {'deviceId': 'good'},
          'garbage',
          42,
          {'deviceId': 'good2'},
        ],
      });
      expect(a.devices.length, 2);
      expect(a.devices.map((d) => d.deviceId), ['good', 'good2']);
    });

    test('role defaults to owner and blocked defaults to false', () {
      final a = Account.fromJson({'username': 'u'});
      expect(a.role, 'owner');
      expect(a.blocked, false);
    });

    test('default constructor assigns a non-null Subscription', () {
      final a = Account(id: 'x', name: 'n', username: 'u');
      expect(a.subscription, isNotNull);
      expect(a.subscription.status, 'none');
      expect(a.devices, isEmpty);
    });

    test('toJson round-trips and is re-parseable by fromJson', () {
      final original = Account.fromJson({
        'id': 'acc-rt',
        'name': 'Round Trip',
        'phone': '+1234',
        'username': 'rt',
        'role': 'owner',
        'blocked': false,
        'createdAt': '2026-03-03',
        'subscription': {
          'status': 'pending',
          'planCode': 'basic',
          'startedAt': 's',
          'expiresAt': 'e',
        },
        'devices': [
          {'deviceId': 'd1', 'platform': 'android', 'current': true},
        ],
      });

      final json = original.toJson();
      final reparsed = Account.fromJson(json);

      expect(reparsed.id, original.id);
      expect(reparsed.name, original.name);
      expect(reparsed.phone, original.phone);
      expect(reparsed.username, original.username);
      expect(reparsed.role, original.role);
      expect(reparsed.blocked, original.blocked);
      expect(reparsed.createdAt, original.createdAt);

      expect(reparsed.subscription.status, original.subscription.status);
      expect(reparsed.subscription.planCode, original.subscription.planCode);
      expect(reparsed.subscription.startedAt, original.subscription.startedAt);
      expect(reparsed.subscription.expiresAt, original.subscription.expiresAt);
      expect(reparsed.subscription.isPending, true);

      expect(reparsed.devices.length, original.devices.length);
      expect(reparsed.devices.first.deviceId, original.devices.first.deviceId);
      expect(reparsed.devices.first.platform, original.devices.first.platform);
      expect(reparsed.devices.first.current, original.devices.first.current);
    });
  });
}
