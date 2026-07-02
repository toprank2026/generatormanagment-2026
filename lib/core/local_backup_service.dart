import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/data/db_helper.dart';

/// v15 — secure LOCAL backup/restore of the structural business data
/// (**boards + circuits + subscribers**, no history) to a `<GeneratorName>.backup`
/// file, encrypted with the owner's password. Works fully offline.
///
/// Format (a small JSON envelope, written as the file body):
///   { v, alg:'sha256-ctr', mac:<hex>, ct:<base64> }
/// where the payload (boards/circuits/subscribers rows) is encrypted with a
/// CTR-style keystream `ks_i = sha256(key || i)` (key = sha256(password)) XORed
/// over the plaintext, and `mac = sha256(key || plaintext)` proves the password
/// is correct + the data is intact on import. Dependency-free (crypto only).
class LocalBackupService {
  final DbHelper _db = DbHelper();

  /// The ONLY tables exported (structure + subscriber data — never receipts /
  /// expenses / settlements / prices).
  static const List<String> tables = ['boards', 'circuits', 'subscribers'];

  // 32-bit big-endian counter bytes.
  List<int> _ctr(int n) => [(n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];

  /// CTR keystream XOR — encrypt and decrypt are the same operation.
  Uint8List _xor(Uint8List data, List<int> key) {
    final out = Uint8List(data.length);
    int produced = 0, counter = 0;
    while (produced < data.length) {
      final block = sha256.convert([...key, ..._ctr(counter)]).bytes;
      for (int i = 0; i < block.length && produced < data.length; i++, produced++) {
        out[produced] = data[produced] ^ block[i];
      }
      counter++;
    }
    return out;
  }

  String _safeName(String name) {
    final s = name
        .trim()
        .replaceAll(RegExp(r'[^\w؀-ۿ\- ]'), '')
        .replaceAll(RegExp(r'\s+'), '');
    return s.isEmpty ? 'Generator' : s;
  }

  /// Export boards+circuits+subscribers encrypted with [password]. Returns the
  /// path of a temp `<GeneratorName>.backup` file (caller shares it).
  Future<String> export({
    required String password,
    required String generatorName,
  }) async {
    final db = await _db.database;
    final Map<String, dynamic> data = {};
    for (final t in tables) {
      data[t] = await db.query(t);
    }
    final payload = <String, dynamic>{
      'v': 1,
      'app': 'flash',
      'generatorName': generatorName,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'tables': data,
    };
    final plain = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final key = sha256.convert(utf8.encode(password)).bytes;
    final ct = _xor(plain, key);
    final mac = sha256.convert([...key, ...plain]).toString();
    final envelope = jsonEncode({
      'v': 1,
      'alg': 'sha256-ctr',
      'mac': mac,
      'ct': base64Encode(ct),
    });
    final dir = await getTemporaryDirectory();
    // v23 (§3.1): stamp the date into the filename so multiple exports are
    // distinguishable (envelope format is unchanged — v:1 stays importable).
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final file =
        File(p.join(dir.path, '${_safeName(generatorName)}-$stamp.backup'));
    await file.writeAsString(envelope, flush: true);
    return file.path;
  }

  /// Import: decrypt with [password], verify integrity, then upsert the three
  /// tables (insert-or-replace by primary key). Returns per-table counts.
  /// Throws [FormatException] on a wrong password or a corrupted/foreign file.
  Future<Map<String, int>> import({
    required File file,
    required String password,
  }) async {
    Map<String, dynamic> envelope;
    try {
      envelope = (jsonDecode(await file.readAsString()) as Map).cast<String, dynamic>();
    } catch (_) {
      throw const FormatException('not_a_valid_backup');
    }
    final ctStr = envelope['ct'];
    final macStr = envelope['mac'];
    if (ctStr is! String || macStr is! String) {
      throw const FormatException('not_a_valid_backup');
    }
    final ct = base64Decode(ctStr);
    final key = sha256.convert(utf8.encode(password)).bytes;
    final plain = _xor(Uint8List.fromList(ct), key);
    final mac = sha256.convert([...key, ...plain]).toString();
    if (mac != macStr) {
      // Wrong password OR the file was tampered with / corrupted.
      throw const FormatException('wrong_password_or_corrupted');
    }
    final payload = (jsonDecode(utf8.decode(plain)) as Map).cast<String, dynamic>();
    final tablesData = (payload['tables'] as Map?)?.cast<String, dynamic>() ?? {};

    final db = await _db.database;
    final counts = <String, int>{};
    await db.transaction((txn) async {
      for (final t in tables) {
        final rows = (tablesData[t] as List?) ?? const [];
        int n = 0;
        for (final r in rows) {
          await txn.insert(
            t,
            (r as Map).cast<String, dynamic>(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          n++;
        }
        counts[t] = n;
      }
    });
    return counts;
  }
}
