import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'github_releases.dart';

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
  Uri get _download => _releases.download(tag, fileName);
}

const repository = 'Sh1rokoDev/NekoProxy';
const _releases = GitHubReleases(repository);
const _maxPackageBytes = 512 * 1024 * 1024;
const _idleTimeout = Duration(seconds: 30);

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
      _releases.latest,
      hosts: const {'github.com'},
      followRedirects: false,
      accept: 'text/html',
    );
    if (response.statusCode == 404) return null;
    final redirected = githubRedirectCodes.contains(response.statusCode);
    if (!redirected) _requireSuccess(response);
    final location = githubReleaseRedirect(
      _releases.latest,
      response.headers['location'],
      const {'github.com'},
    );
    await response.stream.listen(null).cancel();
    if (redirected && location?.path == _releases.index.path) return null;
    final tag = redirected ? _releases.tagAt(location) : null;
    if (tag == null) {
      throw const AppUpdateException('更新服务器返回了无效的版本号。');
    }
    // GitHub's latest route excludes drafts and pre-releases; also require a stable tag.
    final latest = _parseVersion(tag, tag: true);
    if (latest == null) return null;
    if (!_newer(latest, current)) return null;
    final html = await _readText(
      await _get(
        client,
        _releases.assetsPage(tag),
        hosts: const {'github.com'},
        accept: 'text/html',
      ),
      maxGitHubReleaseMetadataSize,
    );
    final namePattern = RegExp(
      '^NekoProxy-${RegExp.escape(tag.substring(1))}\\+[0-9a-f]{7,40}-${RegExp.escape(kind.suffix)}\$',
    );
    final files = _releases.assets(tag, html);
    final matches = files
        .where((asset) => namePattern.hasMatch(asset.name))
        .toList();
    if (matches.length != 1) {
      throw const AppUpdateException('该版本没有适用于此安装方式的更新包。');
    }
    final name = matches.single.name;
    if (files.where((asset) => asset.name == '$name.sha256').length != 1) {
      throw const AppUpdateException('该版本的更新包缺少校验文件。');
    }
    final headers = await _get(
      client,
      _releases.download(tag, name),
      hosts: githubReleaseAssetHosts,
      method: 'HEAD',
    );
    _requireSuccess(headers);
    final size = headers.contentLength;
    await headers.stream.listen(null).cancel();
    if (size == null || size <= 0 || size > _maxPackageBytes) {
      throw const AppUpdateException('该版本的更新包大小无效。');
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
        hosts: githubReleaseAssetHosts,
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
      final response = await _get(
        client,
        update._download,
        hosts: githubReleaseAssetHosts,
      );
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
    } on TlsException {
      if (timedOut) throw const AppUpdateException('更新请求超时，请重试。');
      throw const AppUpdateException('无法与 GitHub 建立安全连接，请检查网络或系统时间后重试。');
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
    String method = 'GET',
    bool followRedirects = true,
  }) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (uri.scheme != 'https' ||
          uri.port != 443 ||
          uri.userInfo.isNotEmpty ||
          !hosts.contains(uri.host)) {
        throw const AppUpdateException('更新服务器返回了不受信任的下载地址。');
      }
      final request = http.Request(method, uri)
        ..followRedirects = false
        ..headers['Accept'] = accept
        ..headers['User-Agent'] = 'NekoProxy-Updater';
      final response = await client.send(request).timeout(_idleTimeout);
      if (!followRedirects ||
          !githubRedirectCodes.contains(response.statusCode)) {
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
