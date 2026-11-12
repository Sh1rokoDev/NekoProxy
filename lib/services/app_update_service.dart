import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

enum UpdatePackageKind {
  android('android-arm64.apk'),
  windowsInstaller('windows-x64-setup.exe'),
  windowsPortable('windows-x64.zip');

  const UpdatePackageKind(this.suffix);
  final String suffix;
}

typedef AppVersion = (int major, int minor, int patch);

AppVersion? _parseVersion(String value, {bool tag = false}) {
  final pattern = tag
      ? r'^v(\d+)\.(\d+)\.(\d+)$'
      : r'^(\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?$';
  final match = RegExp(pattern).firstMatch(value);
  if (match == null) return null;
  final major = int.tryParse(match[1]!);
  final minor = int.tryParse(match[2]!);
  final patch = int.tryParse(match[3]!);
  if (major == null || minor == null || patch == null) return null;
  return (major, minor, patch);
}

bool _newer(AppVersion candidate, AppVersion current) {
  if (candidate.$1 != current.$1) return candidate.$1 > current.$1;
  if (candidate.$2 != current.$2) return candidate.$2 > current.$2;
  return candidate.$3 > current.$3;
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AppUpdate {
  const AppUpdate._({
    required this.tag,
    required this.kind,
    required this.fileName,
    required this.size,
  });

  final String tag;
  final UpdatePackageKind kind;
  final String fileName;
  final int size;

  Uri get releasePage =>
      Uri.https('github.com', '/$repository/releases/tag/$tag');
  Uri get _download =>
      Uri.https('github.com', '/$repository/releases/download/$tag/$fileName');
}

const repository = 'Sh1rokoDev/NekoProxy';
const _maxPackageBytes = 512 * 1024 * 1024;
const _idleTimeout = Duration(seconds: 30);
const _assetHosts = {
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};

class AppUpdateService {
  AppUpdateService(this._createClient);

  final http.Client Function() _createClient;
  http.Client? _activeClient;
  bool _closed = false;

  Future<AppUpdate?> check(
    String currentVersion,
    UpdatePackageKind kind,
  ) => _withClient(const Duration(seconds: 45), (client) async {
    final current = _parseVersion(currentVersion);
    if (current == null) {
      throw const AppUpdateException('无法识别当前应用的版本号。');
    }
    final response = await _get(
      client,
      Uri.https('api.github.com', '/repos/$repository/releases/latest'),
      hosts: const {'api.github.com'},
      accept: 'application/vnd.github+json',
    );
    if (response.statusCode == 404) return null;
    final body = await _readText(response, 1024 * 1024);
    final Object? release;
    try {
      release = jsonDecode(body);
    } on FormatException {
      throw const AppUpdateException('更新服务器返回了无效的版本信息。');
    }
    if (release is! Map) {
      throw const AppUpdateException('更新服务器返回了无效的版本信息。');
    }
    if (release['prerelease'] == true || release['draft'] == true) return null;
    final tag = release['tag_name'];
    final latest = tag is String ? _parseVersion(tag, tag: true) : null;
    if (tag is! String || latest == null) {
      throw const AppUpdateException('更新服务器返回了无效的版本号。');
    }
    if (!_newer(latest, current)) return null;
    final assets = release['assets'];
    if (assets is! List) {
      throw const AppUpdateException('该版本没有可用的更新包。');
    }
    final namePattern = RegExp(
      '^NekoProxy-${RegExp.escape(tag.substring(1))}\\+[0-9a-f]{7,40}-${RegExp.escape(kind.suffix)}\$',
    );
    final files = assets.whereType<Map>().toList();
    final matches = files.where((asset) {
      final name = asset['name'];
      return name is String && namePattern.hasMatch(name);
    }).toList();
    if (matches.length != 1) {
      throw const AppUpdateException('该版本没有适用于此安装方式的更新包。');
    }
    final file = matches.single;
    final name = file['name'] as String;
    final size = file['size'];
    if (size is! int ||
        size <= 0 ||
        size > _maxPackageBytes ||
        files.where((asset) => asset['name'] == '$name.sha256').length != 1) {
      throw const AppUpdateException('该版本的更新包大小或校验文件无效。');
    }
    return AppUpdate._(tag: tag, kind: kind, fileName: name, size: size);
  });

  Future<File> download(
    AppUpdate update,
    Directory directory, {
    required void Function(double) onProgress,
  }) => _withClient(const Duration(minutes: 20), (client) async {
    final checksum = await _readText(
      await _get(
        client,
        update._download.replace(path: '${update._download.path}.sha256'),
        hosts: _assetHosts,
      ),
      4096,
    );
    final entry = RegExp(
      r'^([0-9a-fA-F]{64}) [ *](.+)$',
    ).firstMatch(checksum.trim());
    if (entry == null || entry[2] != update.fileName) {
      throw const AppUpdateException('更新包的校验文件格式无效。');
    }
    final expected = entry[1]!.toLowerCase();

    await directory.create(recursive: true);
    final target = File.fromUri(directory.uri.resolve(update.fileName));
    if (await target.exists() &&
        await target.length() == update.size &&
        (await sha256.bind(target.openRead()).first).toString() == expected) {
      onProgress(1);
      return target;
    }

    final scratch = await directory.createTemp('download-');
    final partial = File.fromUri(scratch.uri.resolve(update.fileName));
    try {
      final response = await _get(client, update._download, hosts: _assetHosts);
      _requireSuccess(response);
      if (response.contentLength != null &&
          response.contentLength != update.size) {
        throw const AppUpdateException('下载的更新包大小与发布信息不符。');
      }
      final output = await partial.open(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(_idleTimeout)) {
          received += chunk.length;
          if (received > update.size) {
            throw const AppUpdateException('下载的更新包超出发布大小。');
          }
          await output.writeFrom(chunk);
          onProgress(received / update.size);
        }
      } finally {
        await output.close();
      }
      if (received != update.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              expected) {
        throw const AppUpdateException('更新包未通过 SHA-256 校验，请重新下载。');
      }
      if (_closed) throw const AppUpdateException('更新操作已取消。');
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } finally {
      if (await partial.exists()) await partial.delete();
      await scratch.delete();
    }
  });

  Future<T> _withClient<T>(
    Duration deadline,
    Future<T> Function(http.Client) operation,
  ) async {
    if (_closed || _activeClient != null) {
      throw const AppUpdateException('更新操作不可用或正在进行。');
    }
    final client = _createClient();
    _activeClient = client;
    var timedOut = false;
    final timer = Timer(deadline, () {
      timedOut = true;
      client.close();
    });
    try {
      final result = await operation(client);
      if (timedOut) throw const AppUpdateException('更新请求超时，请重试。');
      return result;
    } on TimeoutException {
      throw const AppUpdateException('更新请求超时，请重试。');
    } on http.ClientException {
      if (timedOut) throw const AppUpdateException('更新请求超时，请重试。');
      throw const AppUpdateException('无法连接到 GitHub，请检查网络后重试。');
    } on SocketException {
      if (timedOut) throw const AppUpdateException('更新请求超时，请重试。');
      throw const AppUpdateException('与 GitHub 的连接中断，请检查网络后重试。');
    } finally {
      timer.cancel();
      client.close();
      _activeClient = null;
    }
  }

  void close() {
    _closed = true;
    _activeClient?.close();
  }

  Future<http.StreamedResponse> _get(
    http.Client client,
    Uri uri, {
    required Set<String> hosts,
    String accept = 'application/octet-stream',
  }) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !hosts.contains(uri.host)) {
        throw const AppUpdateException('更新服务器返回了不受信任的下载地址。');
      }
      final request = http.Request('GET', uri)
        ..followRedirects = false
        ..headers['Accept'] = accept
        ..headers['User-Agent'] = 'NekoProxy-Updater';
      final response = await client.send(request).timeout(_idleTimeout);
      if (!const {301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      await response.stream.listen(null).cancel();
      final next = location == null ? null : Uri.tryParse(location);
      if (next == null) break;
      uri = uri.resolveUri(next);
    }
    throw const AppUpdateException('下载链接重定向无效或次数过多。');
  }

  static void _requireSuccess(http.StreamedResponse response) {
    if (response.statusCode == 403 || response.statusCode == 429) {
      throw const AppUpdateException('GitHub 限制了更新请求，请稍后重试。');
    }
    if (response.statusCode != 200) {
      throw AppUpdateException('更新请求失败（HTTP ${response.statusCode}）。');
    }
  }

  static Future<String> _readText(
    http.StreamedResponse response,
    int limit,
  ) async {
    _requireSuccess(response);
    final bytes = <int>[];
    await for (final chunk in response.stream.timeout(_idleTimeout)) {
      if (bytes.length + chunk.length > limit) {
        throw const AppUpdateException('更新服务器的响应过大。');
      }
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const AppUpdateException('更新服务器的响应编码无效。');
    }
  }
}
