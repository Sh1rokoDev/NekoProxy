import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

class AppPaths {
  AppPaths({required this.base, required this.runtime, required this.logFile});

  final Directory base;
  final Directory runtime;
  final File logFile;

  File get stateFile => File(_join(base.path, 'state.json'));
  File get stateKeyFile => File(_join(base.path, 'state.key'));
  File get proxySnapshotFile => File(_join(runtime.path, 'system_proxy.json'));
  File get runtimeFile => File(_join(runtime.path, 'runtime.json'));

  /// Windows 以管理员权限启动，全部用户数据（包括状态密钥）都放在安装目录的
  /// `userdata` 里。Android 仍使用应用私有目录。
  static Future<AppPaths> resolve() async {
    // Windows 不读取或创建 AppData；Android 仍使用平台私有目录。
    if (Platform.isAndroid) {
      return _build(await _appSupportBase());
    }
    final installDir = File(Platform.resolvedExecutable).parent;
    final userdata = Directory(_join(installDir.path, 'userdata'));
    try {
      return await _build(userdata.path);
    } on FileSystemException catch (error) {
      throw FileSystemException(
        '无法在安装目录创建 userdata，请确认 NekoProxy 以管理员权限运行且安装目录可写。',
        userdata.path,
        error.osError,
      );
    }
  }

  static AppPaths forDirectory(String path) => _sync(path);

  static AppPaths _sync(String basePath) {
    final base = Directory(basePath);
    final runtime = Directory(_join(base.path, 'runtime'));
    return AppPaths(
      base: base,
      runtime: runtime,
      logFile: File(_join(runtime.path, 'core.log')),
    );
  }

  static Future<AppPaths> _build(String basePath) async {
    final paths = _sync(basePath);
    await paths.base.create(recursive: true);
    await paths.runtime.create(recursive: true);
    return paths;
  }

  static Future<String> _appSupportBase() async {
    final support = await getApplicationSupportDirectory();
    return _join(support.path, 'NekoProxy');
  }
}

String _join(String parent, String child) =>
    '$parent${Platform.pathSeparator}$child';

class LoadResult {
  const LoadResult(this.snapshot, {this.warning});
  final AppSnapshot snapshot;
  final String? warning;
}

class AppStorage {
  AppStorage(this.paths, {FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage();

  static const _keyName = 'nekoproxy_state_key_v1';
  static const _formatVersion = 2;
  final AppPaths paths;
  final FlutterSecureStorage _secureStorage;
  final _algorithm = AesGcm.with256bits();
  bool _stateAuthenticationFailed = false;
  bool _canBackupState = false;
  Future<void> _writeQueue = Future<void>.value();

  Future<LoadResult> load() async {
    final file = paths.stateFile;
    _canBackupState = false;
    if (!await file.exists()) {
      _stateAuthenticationFailed = false;
      return LoadResult(AppSnapshot.empty());
    }
    var failure = '读取本地数据失败';
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded['version'] != _formatVersion ||
          decoded['encrypted'] != true) {
        failure = '状态文件格式不受支持';
        throw FormatException(failure);
      }
      final key = await _readKey();
      if (key == null) {
        throw const FormatException('加密状态缺少本机密钥');
      }
      final nonce = base64Decode(decoded['nonce'] as String);
      final cipher = base64Decode(decoded['cipher'] as String);
      final mac = base64Decode(decoded['mac'] as String);
      final List<int> clear;
      try {
        clear = await _algorithm.decrypt(
          SecretBox(cipher, nonce: nonce, mac: Mac(mac)),
          secretKey: key,
        );
      } on SecretBoxAuthenticationError {
        _stateAuthenticationFailed = true;
        rethrow;
      }
      final snapshotJson = jsonDecode(utf8.decode(clear));
      if (snapshotJson is! Map) {
        throw const FormatException('state payload is not an object');
      }
      final snapshot = AppSnapshot.fromJson(
        Map<String, dynamic>.from(snapshotJson),
      );
      final duplicates = snapshot.pruneDuplicateNodeIds();
      _stateAuthenticationFailed = false;
      _canBackupState = true;
      return LoadResult(
        snapshot,
        warning: duplicates > 0 ? '检测到 $duplicates 个重复节点，已自动清理。' : null,
      );
    } catch (_) {
      final backup = File(
        '${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}',
      );
      String recovery;
      try {
        await file.copy(backup.path);
        recovery = '已保留副本';
      } on FileSystemException {
        recovery = '无法创建副本，原文件仍在原位置';
      }
      return LoadResult(
        AppSnapshot.empty(),
        warning: '$failure，$recovery。应用已启动为初始状态。',
      );
    }
  }

  Future<void> save(AppSnapshot snapshot) {
    final payload = snapshot.encode();
    final task = _writeQueue.then((_) => _saveEncoded(payload));
    _writeQueue = task.catchError((_) {});
    return task;
  }

  Future<File> writeBackup(String content) async {
    final directory = Directory(_join(paths.base.path, 'backups'));
    await directory.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File(_join(directory.path, 'nekoproxy-$stamp.json'));
    await file.create(exclusive: true);
    try {
      return await file.writeAsString(content, flush: true);
    } catch (_) {
      await file.delete();
      rethrow;
    }
  }

  Future<void> _saveEncoded(String payload) async {
    if (_stateAuthenticationFailed) {
      throw StateError('本地状态无法验证，请恢复原状态文件或密钥后重新读取');
    }
    await paths.base.create(recursive: true);
    final file = paths.stateFile;
    final key = await _ensureKey();
    if (_canBackupState && await file.exists()) {
      try {
        await file.copy('${file.path}.bak');
      } catch (_) {}
    }
    final box = await _algorithm.encrypt(utf8.encode(payload), secretKey: key);
    final content = jsonEncode({
      'encrypted': true,
      'version': _formatVersion,
      'nonce': base64Encode(box.nonce),
      'cipher': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    });
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(file.path);
    _canBackupState = true;
  }

  Future<SecretKey> _ensureKey() async {
    final existing = await _readKey();
    if (existing != null) return existing;
    // Never replace a missing key while state in the current format exists.
    for (final file in [paths.stateFile, File('${paths.stateFile.path}.bak')]) {
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] == _formatVersion) {
        throw StateError('本地状态缺少密钥，请先恢复原密钥再保存');
      }
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    if (Platform.isWindows) {
      await _writeLocalKey(bytes);
    } else {
      // Android 使用 Keystore 支持的 secure storage。
      await _secureStorage.write(key: _keyName, value: base64Encode(bytes));
    }
    return SecretKey(bytes);
  }

  Future<SecretKey?> _readKey() async {
    final String? value;
    if (Platform.isWindows) {
      final file = paths.stateKeyFile;
      if (!await file.exists()) return null;
      value = (await file.readAsString()).trim();
    } else {
      value = await _secureStorage.read(key: _keyName);
    }
    if (value == null) return null;
    final List<int> bytes;
    try {
      bytes = base64Decode(value);
    } on FormatException {
      throw const FormatException('本机状态密钥格式无效');
    }
    if (bytes.length != 32) throw const FormatException('本机状态密钥长度无效');
    return SecretKey(bytes);
  }

  Future<void> _writeLocalKey(List<int> bytes) async {
    final file = paths.stateKeyFile;
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(base64Encode(bytes), flush: true);
    await temp.rename(file.path);
  }
}
