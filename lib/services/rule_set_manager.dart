import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../data/app_storage.dart';
import '../domain/models.dart';
import '../runtime/runtime_client.dart';

const _sources = {
  'geosite': (repo: 'domain-list-community', asset: 'dlc.dat'),
  'geoip': (repo: 'geoip', asset: 'geoip.dat'),
};
const _maxDatabaseSize = 64 * 1024 * 1024;
const _maxRuleSize = 8 * 1024 * 1024;
final _digestPattern = RegExp(r'^[a-f0-9]{64}$');
final _releasePattern = RegExp(r'^[A-Za-z0-9._-]+$');
final _filePattern = RegExp(
  r'^geo(?:site|ip)-[a-z0-9_!][a-z0-9_!.-]*(?:@[a-z0-9_!][a-z0-9_!.-]*)?\.srs$',
);
final _directoryPattern = RegExp(
  r'^(?:bundled-[a-f0-9]{64}|update-[a-zA-Z0-9]+)$',
);

typedef _Release = ({String tag, String sha256, int size});
typedef RuleSetConverter =
    Future<void> Function(String kind, String input, String output);

class RuleSetException implements Exception {
  RuleSetException(this.message);

  final String message;

  @override
  String toString() => message;
}

class RuleSetFileStatus {
  const RuleSetFileStatus({required this.size, required this.sha256});

  final int size;
  final String sha256;

  Map<String, Object> toJson() => {'size': size, 'sha256': sha256};
}

class RuleSetStatus {
  RuleSetStatus._({
    required this.source,
    required this.updatedAt,
    required this.checkedAt,
    required Map<String, RuleSetFileStatus> files,
    required Map<String, _Release> releases,
  }) : files = Map.unmodifiable(files),
       _releases = Map.unmodifiable(releases);

  final String source;
  final DateTime? updatedAt;
  final DateTime? checkedAt;
  final Map<String, RuleSetFileStatus> files;
  final Map<String, _Release> _releases;

  String get sourceLabel => source == 'network' ? '上游更新' : '内置规则';

  int count(String kind) =>
      files.keys.where((name) => name.startsWith('$kind-')).length;

  int size(String kind) => files.entries
      .where((entry) => entry.key.startsWith('$kind-'))
      .fold(0, (total, entry) => total + entry.value.size);

  String? releaseTag(String kind) => _releases[kind]?.tag;
}

class RuleSetUpdateResult {
  const RuleSetUpdateResult({required this.updated, required this.status});

  final bool updated;
  final RuleSetStatus status;
}

/// Publishes complete network snapshots and extracts bundled files on demand.
/// Existing core sessions retain the paths they started with.
class RuleSetManager {
  RuleSetManager({
    required this.paths,
    required HttpClient Function() clientFactory,
    RuleSetConverter? converter,
    AssetBundle? bundle,
    bool Function(String directory)? isSnapshotReferenced,
  }) : _clientFactory = clientFactory,
       _convert = converter ?? _convertOnPlatform,
       _bundle = bundle ?? rootBundle,
       _isSnapshotReferenced = isSnapshotReferenced;

  final AppPaths paths;
  final HttpClient Function() _clientFactory;
  final RuleSetConverter _convert;
  final AssetBundle _bundle;
  final bool Function(String directory)? _isSnapshotReferenced;
  RuleSetStatus? _status;
  ({String directory, RuleSetStatus status})? _bundled;
  String? _activeDirectory;
  String? _previousDirectory;
  String? _coreDirectory;
  Set<String> _tags = const {};
  Map<String, String> _pathsByTag = const {};

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  Directory get _directory => Directory(_join(paths.runtime.path, 'rules'));
  File get _manifest => File(_join(_directory.path, 'manifest.json'));

  Set<String> get tags => _tags;

  Map<String, String> get pathsByTag => _pathsByTag;

  void pinActiveSnapshotForCore() => _coreDirectory = _activeDirectory;

  Future<void> initialize() async {
    await _directory.create(recursive: true);
    final bundled = await _readBundled();
    _bundled = bundled;
    try {
      final manifest = await _manifest.exists()
          ? _decodeObject(await _manifest.readAsString())
          : const <String, dynamic>{};
      final active = manifest['directory'];
      final status = _parseStatus(manifest);
      // Android's VPN service can outlive the Flutter activity.
      final core = manifest['coreDirectory'];
      if (core is String && _directoryPattern.hasMatch(core)) {
        _coreDirectory = core;
      }
      if (active is String &&
          _directoryPattern.hasMatch(active) &&
          (status.source == 'network' ||
              status.updatedAt == bundled.status.updatedAt)) {
        _activate(active, status);
        final previous = manifest['previousDirectory'];
        if (previous is String && _directoryPattern.hasMatch(previous)) {
          _previousDirectory = previous;
        }
        return;
      }
    } on FormatException {
      // Older and incomplete manifests are replaced by the bundled catalog.
    }
    await _activateBundled(bundled, checkedAt: null);
  }

  /// Prepares only local files from the final configuration. Paths supplied
  /// outside the managed catalog are resolved by sing-box.
  Future<void> prepareLocalFiles(Iterable<String> localPaths) async {
    final status = _status;
    final activePaths = _pathsByTag;
    final bundled = _bundled;
    for (final localPath in localPaths.toSet()) {
      final path = Platform.isWindows
          ? localPath.replaceAll('/', Platform.pathSeparator)
          : localPath;
      final name = _basename(path);
      if (!_filePattern.hasMatch(name)) continue;
      final tag = name.substring(0, name.length - '.srs'.length);
      final file = File(path);
      final activeEntry = status?.files[name];
      if (status != null && activeEntry != null && activePaths[tag] == path) {
        if (await _matches(file, activeEntry)) continue;
        if (status.source == 'network') {
          throw RuleSetException('规则集校验失败：$name，请恢复内置规则集后重试。');
        }
        await _extractBundledFile(file, name, activeEntry);
      } else if (bundled != null &&
          path == _join(_join(_directory.path, bundled.directory), name)) {
        final entry = bundled.status.files[name];
        if (entry != null && !await _matches(file, entry)) {
          await _extractBundledFile(file, name, entry);
        }
      }
    }
  }

  Future<RuleSetStatus> readStatus() async =>
      _status ?? (throw RuleSetException('规则集尚未初始化'));

  Future<bool> isUpdateDue(Duration interval) async {
    final checked = (await readStatus()).checkedAt;
    return checked == null || DateTime.now().difference(checked) >= interval;
  }

  Future<RuleSetUpdateResult> update() async {
    final current = await readStatus();
    final client = _clientFactory();
    Directory? stage;
    try {
      final releases = <String, _Release>{};
      for (final entry in _sources.entries) {
        releases[entry.key] = await _latestRelease(client, entry.value);
      }
      final changed = releases.keys
          .where(
            (kind) => current._releases[kind]?.sha256 != releases[kind]?.sha256,
          )
          .toSet();
      final checkedAt = DateTime.now();
      if (changed.isEmpty) {
        await _publish(
          _activeDirectory!,
          RuleSetStatus._(
            source: current.source,
            updatedAt: current.updatedAt,
            checkedAt: checkedAt,
            files: current.files,
            releases: releases,
          ),
        );
        return RuleSetUpdateResult(updated: false, status: _status!);
      }

      stage = await _directory.createTemp('update-');
      final files = <String, RuleSetFileStatus>{};
      for (final entry in _sources.entries) {
        final kind = entry.key;
        if (!changed.contains(kind)) {
          for (final file in current.files.entries) {
            if (!file.key.startsWith('$kind-')) continue;
            final target = File(_join(stage.path, file.key));
            if (current.source == 'bundled') {
              await target.writeAsBytes(
                await _readBundledFile(file.key, file.value),
              );
            } else {
              final oldPath = _join(
                _join(_directory.path, _activeDirectory!),
                file.key,
              );
              await File(oldPath).copy(target.path);
              if (await _inspect(target) != file.value.sha256) {
                throw RuleSetException('规则集校验失败：${file.key}');
              }
            }
            files[file.key] = file.value;
          }
          continue;
        }
        final release = releases[kind]!;
        final source = entry.value;
        final url = Uri.https(
          'github.com',
          '/v2fly/${source.repo}/releases/download/${release.tag}/${source.asset}',
        );
        final input = File(_join(stage.path, source.asset));
        final sink = input.openWrite();
        try {
          await sink.addStream(_download(client, url, release.size));
        } finally {
          await sink.close();
        }
        if (await input.length() != release.size ||
            (await sha256.bind(input.openRead()).first).toString() !=
                release.sha256) {
          throw RuleSetException('${source.asset} 校验失败');
        }
        await _convert(kind, input.path, stage.path);
        await input.delete();
        await for (final file in stage.list(followLinks: false)) {
          final name = _basename(file.path);
          if (file is! File || !name.startsWith('$kind-')) continue;
          if (!_filePattern.hasMatch(name)) {
            throw RuleSetException('无效的规则集文件名：$name');
          }
          files[name] = RuleSetFileStatus(
            size: await file.length(),
            sha256: await _inspect(file),
          );
        }
      }
      if (!files.keys.toSet().containsAll(_requiredFiles)) {
        throw RuleSetException('上游规则集缺少默认分流类别');
      }
      await _publish(
        _basename(stage.path),
        RuleSetStatus._(
          source: 'network',
          updatedAt: DateTime.now(),
          checkedAt: checkedAt,
          files: files,
          releases: releases,
        ),
      );
      return RuleSetUpdateResult(updated: true, status: _status!);
    } finally {
      client.close(force: true);
      if (stage != null && _activeDirectory != _basename(stage.path)) {
        await _discard(stage);
      }
    }
  }

  Future<RuleSetStatus> resetToBundled() async {
    final bundled = _bundled ??= await _readBundled();
    await _activateBundled(bundled, checkedAt: DateTime.now());
    return readStatus();
  }

  Future<({String directory, RuleSetStatus status})> _readBundled() async {
    final raw = await _bundle.loadString('assets/rules/manifest.json');
    final manifest = _decodeObject(raw);
    final status = _parseStatus({
      ...manifest,
      'source': 'bundled',
      'updatedAt': manifest['generatedAt'],
    });
    return (
      directory: 'bundled-${sha256.convert(utf8.encode(raw))}',
      status: status,
    );
  }

  Future<void> _activateBundled(
    ({String directory, RuleSetStatus status}) bundled, {
    required DateTime? checkedAt,
  }) async {
    await _publish(
      bundled.directory,
      RuleSetStatus._(
        source: 'bundled',
        updatedAt: bundled.status.updatedAt,
        checkedAt: checkedAt,
        files: bundled.status.files,
        releases: bundled.status._releases,
      ),
    );
  }

  Future<Uint8List> _readBundledFile(
    String name,
    RuleSetFileStatus entry,
  ) async {
    final data = await _bundle.load('assets/rules/$name');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.length != entry.size ||
        sha256.convert(bytes).toString() != entry.sha256) {
      throw RuleSetException('内置规则集校验失败：$name');
    }
    return bytes;
  }

  Future<void> _extractBundledFile(
    File file,
    String name,
    RuleSetFileStatus entry,
  ) async {
    final bytes = await _readBundledFile(name, entry);
    final directory = await file.parent.create(recursive: true);
    final stage = await directory.createTemp('.srs-');
    try {
      final temp = await File(_join(stage.path, name)).writeAsBytes(bytes);
      await temp.rename(file.path);
    } finally {
      await _discard(stage);
    }
  }

  Future<bool> _matches(File file, RuleSetFileStatus entry) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file || stat.size != entry.size) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == entry.sha256;
  }

  Future<void> _publish(String directory, RuleSetStatus status) async {
    final previous = directory == _activeDirectory
        ? _previousDirectory
        : _activeDirectory;
    final raw = jsonEncode({
      'schema': 2,
      'directory': directory,
      'previousDirectory': ?previous,
      'coreDirectory': ?_coreDirectory,
      'source': status.source,
      'updatedAt': status.updatedAt?.toUtc().toIso8601String(),
      'checkedAt': status.checkedAt?.toUtc().toIso8601String(),
      'releases': {
        for (final entry in status._releases.entries)
          entry.key: {
            'tag': entry.value.tag,
            'sha256': entry.value.sha256,
            'size': entry.value.size,
          },
      },
      'files': {
        for (final entry in status.files.entries)
          entry.key: entry.value.toJson(),
      },
    });
    final temp = File('${_manifest.path}.tmp');
    await temp.writeAsString(raw, flush: true);
    await temp.rename(_manifest.path);
    final changed = _activeDirectory != directory;
    _previousDirectory = previous;
    _activate(directory, status);
    if (changed) {
      try {
        await for (final entry in _directory.list(followLinks: false)) {
          final name = _basename(entry.path);
          if (entry is Directory &&
              _directoryPattern.hasMatch(name) &&
              name != directory &&
              name != previous &&
              name != _coreDirectory &&
              name != _bundled?.directory &&
              !(_isSnapshotReferenced?.call(name) ?? false)) {
            await entry.delete(recursive: true);
          }
        }
      } on FileSystemException catch (error) {
        // Activation has already succeeded. Reclaim the old directory later.
        developer.log('规则集目录清理失败', name: 'rules', error: error);
      }
    }
  }

  Future<void> _discard(Directory stage) async {
    try {
      if (await stage.exists()) await stage.delete(recursive: true);
    } on FileSystemException catch (error) {
      developer.log('规则集临时目录清理失败', name: 'rules', error: error);
    }
  }

  void _activate(String directory, RuleSetStatus status) {
    _activeDirectory = directory;
    _status = status;
    _pathsByTag = Map.unmodifiable({
      for (final name in status.files.keys)
        name.substring(0, name.length - '.srs'.length): _join(
          _join(_directory.path, directory),
          name,
        ),
    });
    _tags = Set.unmodifiable(_pathsByTag.keys);
  }

  Future<_Release> _latestRelease(
    HttpClient client,
    ({String repo, String asset}) source,
  ) async {
    final raw = await _download(
      client,
      Uri.https(
        'api.github.com',
        '/repos/v2fly/${source.repo}/releases/latest',
      ),
      1024 * 1024,
    ).transform(utf8.decoder).join();
    final release = _decodeObject(raw);
    final tag = release['tag_name'];
    final assets = release['assets'];
    if (assets is List) {
      for (final asset in assets) {
        if (asset is! Map || asset['name'] != source.asset) continue;
        final digest = asset['digest'];
        if (digest is String && digest.startsWith('sha256:')) {
          return _parseRelease(tag, digest.substring(7), asset['size']);
        }
      }
    }
    throw RuleSetException('${source.repo} 发布信息缺少规则集或 SHA-256');
  }

  Stream<List<int>> _download(HttpClient client, Uri uri, int limit) async* {
    const timeout = Duration(seconds: 30);
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'NekoProxy (rules)');
    if (uri.host == 'api.github.com') {
      request.headers.set(
        HttpHeaders.acceptHeader,
        'application/vnd.github+json',
      );
    }
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw RuleSetException('${uri.host} 返回 HTTP ${response.statusCode}');
    }
    if (response.contentLength > limit) {
      throw RuleSetException('规则集下载大小超过上限');
    }
    var received = 0;
    final stopwatch = Stopwatch()..start();
    await for (final chunk in response.timeout(timeout)) {
      if (stopwatch.elapsed > const Duration(minutes: 3)) {
        throw TimeoutException('规则集下载超时');
      }
      received += chunk.length;
      if (received > limit) {
        throw RuleSetException('规则集下载大小超过上限');
      }
      yield chunk;
    }
  }

  Future<String> _inspect(File file) async {
    final size = await file.length();
    if (size < 16 || size > _maxRuleSize) {
      throw RuleSetException('规则集大小无效：${_basename(file.path)}');
    }
    final handle = await file.open();
    try {
      final header = await handle.read(4);
      if (header.length != 4 ||
          header[0] != 0x53 ||
          header[1] != 0x52 ||
          header[2] != 0x53 ||
          header[3] < 1 ||
          header[3] > 5) {
        throw RuleSetException('规则集格式无效：${_basename(file.path)}');
      }
    } finally {
      await handle.close();
    }
    return (await sha256.bind(file.openRead()).first).toString();
  }

  static String _basename(String path) =>
      path.split(Platform.pathSeparator).last;

  static final _requiredFiles = {
    for (final tag in builtInRuleSetTags) '$tag.srs',
  };

  static Map<String, dynamic> _decodeObject(String raw) {
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('规则集清单格式无效');
    }
    return value;
  }

  static _Release _parseRelease(Object? tag, Object? digest, Object? size) {
    if (tag is! String ||
        !_releasePattern.hasMatch(tag) ||
        tag == '.' ||
        tag == '..' ||
        digest is! String ||
        !_digestPattern.hasMatch(digest) ||
        size is! int ||
        size < 1 ||
        size > _maxDatabaseSize) {
      throw const FormatException('规则集发布信息格式无效');
    }
    return (tag: tag, sha256: digest, size: size);
  }

  static RuleSetStatus _parseStatus(Map<String, dynamic> manifest) {
    final rawFiles = manifest['files'];
    final rawReleases = manifest['releases'];
    final source = manifest['source'];
    if (manifest['schema'] != 2 ||
        (source != 'bundled' && source != 'network') ||
        rawFiles is! Map ||
        rawReleases is! Map) {
      throw const FormatException('规则集清单版本或格式无效');
    }
    final files = <String, RuleSetFileStatus>{};
    for (final entry in rawFiles.entries) {
      final name = entry.key;
      final value = entry.value;
      if (name is! String || !_filePattern.hasMatch(name) || value is! Map) {
        throw const FormatException('规则集清单文件名无效');
      }
      final size = value['size'];
      final digest = value['sha256'];
      if (size is! int ||
          size < 16 ||
          size > _maxRuleSize ||
          digest is! String ||
          !_digestPattern.hasMatch(digest)) {
        throw const FormatException('规则集清单文件信息无效');
      }
      files[name] = RuleSetFileStatus(size: size, sha256: digest);
    }
    if (!files.keys.toSet().containsAll(_requiredFiles)) {
      throw const FormatException('规则集清单缺少默认分流类别');
    }
    final releases = <String, _Release>{};
    for (final kind in _sources.keys) {
      final value = rawReleases[kind];
      if (value is! Map) throw const FormatException('规则集清单缺少上游版本');
      releases[kind] = _parseRelease(
        value['tag'],
        value['sha256'],
        value['size'],
      );
    }
    return RuleSetStatus._(
      source: source as String,
      updatedAt: DateTime.tryParse('${manifest['updatedAt']}'),
      checkedAt: DateTime.tryParse('${manifest['checkedAt']}'),
      files: files,
      releases: releases,
    );
  }

  static Future<void> _convertOnPlatform(
    String kind,
    String input,
    String output,
  ) async {
    if (Platform.isAndroid) {
      await const MethodChannel('nekoproxy/runtime').invokeMethod<void>(
        'convertRules',
        {'kind': kind, 'input': input, 'output': output},
      );
      return;
    }
    final worker = locateRuntimeBinary('nekoproxy-worker.exe');
    if (worker == null) throw RuleSetException('未找到规则集转换所需的运行组件');
    final result = await Process.run(worker, [
      'convert-rules',
      kind,
      input,
      output,
    ]);
    if (result.exitCode != 0) {
      throw RuleSetException('转换 $kind 失败：${result.stderr.toString().trim()}');
    }
  }
}
