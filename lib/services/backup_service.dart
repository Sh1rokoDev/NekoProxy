import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import '../domain/models.dart';

class BackupException implements Exception {
  const BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupPasswordException extends BackupException {
  const BackupPasswordException(super.message);
}

class BackupService {
  BackupService._();

  static const _formatVersion = 2;
  static const _kdf = 'pbkdf2-hmac-sha256';
  static const _iterationCount = 210000;

  static Future<String> export(AppSnapshot snapshot, {String? password}) async {
    if (snapshot.wireGuardProfiles.isNotEmpty &&
        (password == null || password.isEmpty)) {
      throw const BackupPasswordException('备份含 WireGuard 密钥，请设置备份密码');
    }
    final payload = jsonEncode({
      'app': 'nekoproxy',
      'version': _formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'data': snapshot.toJson(),
    });
    if (password == null || password.isEmpty) return payload;

    final salt = _randomBytes(16);
    final key = await _deriveKey(password, salt);
    final algorithm = AesGcm.with256bits();
    final box = await algorithm.encrypt(utf8.encode(payload), secretKey: key);
    return jsonEncode({
      'app': 'nekoproxy-backup',
      'version': _formatVersion,
      'kdf': _kdf,
      'iterations': _iterationCount,
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'cipher': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
  }

  static Future<AppSnapshot> import(String content, {String? password}) async {
    final map = _decodeEnvelope(content);
    if (map['app'] == 'nekoproxy-backup') {
      if (map['kdf'] != _kdf || map['iterations'] != _iterationCount) {
        throw const BackupException('备份的密钥派生参数不受支持');
      }
      final salt = _decodeBytes(map['salt']);
      final nonce = _decodeBytes(map['nonce']);
      final cipher = _decodeBytes(map['cipher']);
      final mac = _decodeBytes(map['mac']);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          mac.length != 16 ||
          cipher.isEmpty) {
        throw const BackupException('备份文件内容损坏');
      }
      if (password == null || password.isEmpty) {
        throw const BackupPasswordException('该备份已加密，请输入密码');
      }
      final key = await _deriveKey(password, salt);
      final algorithm = AesGcm.with256bits();
      final List<int> clear;
      try {
        clear = await algorithm.decrypt(
          SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
          secretKey: key,
        );
      } on SecretBoxAuthenticationError {
        throw const BackupPasswordException('密码错误或备份已损坏');
      }
      final String inner;
      try {
        inner = utf8.decode(clear);
      } on FormatException {
        throw const BackupException('备份内容无效');
      }
      return _snapshotFrom(_decodeEnvelope(inner));
    }
    return _snapshotFrom(map);
  }

  static Map<String, dynamic> _decodeEnvelope(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const BackupException('备份文件不是有效 JSON');
    }
    if (decoded is! Map ||
        (decoded['app'] != 'nekoproxy' &&
            decoded['app'] != 'nekoproxy-backup') ||
        decoded['version'] != _formatVersion) {
      throw const BackupException('不支持的 NekoProxy 备份格式');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static AppSnapshot _snapshotFrom(Map<String, dynamic> map) {
    final data = map['data'];
    if (map['app'] != 'nekoproxy' || data is! Map) {
      throw const BackupException('备份内容无效');
    }
    try {
      return AppSnapshot.fromJson(Map<String, dynamic>.from(data));
    } on FormatException catch (error) {
      throw BackupException(error.message);
    } on TypeError {
      throw const BackupException('备份数据字段类型无效');
    }
  }

  static List<int> _decodeBytes(Object? value) {
    if (value is String) {
      try {
        return base64Decode(value);
      } on FormatException {
        throw const BackupException('备份文件内容损坏');
      }
    }
    throw const BackupException('备份数据字段类型无效');
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterationCount,
      bits: 256,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }
}
