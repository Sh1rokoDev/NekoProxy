import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/data/app_storage.dart';
import 'package:nekoproxy/services/rule_set_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPaths paths;
  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('nekoproxy-rules-');
    addTearDown(() => temp.delete(recursive: true));
    paths = AppPaths.forDirectory(temp.path);
  });

  test(
    'indexes the full bundled catalog and extracts only requested rules',
    skip: File('assets/rules/manifest.json').existsSync()
        ? false
        : 'run scripts/sync-rules.ps1 first',
    () async {
      final manager = RuleSetManager(
        paths: paths,
        clientFactory: HttpClient.new,
      );
      await manager.initialize();
      final status = await manager.readStatus();

      expect(status.source, 'bundled');
      expect(status.count('geosite'), greaterThan(1000));
      expect(status.count('geoip'), greaterThan(200));
      expect(
        manager.tags,
        containsAll(['geosite-cn', 'geoip-us', 'geosite-google@ads']),
      );
      final requested = ['geosite-cn', 'geoip-us', 'geosite-google@ads'];
      final ruleDirectory = File(manager.pathsByTag[requested.first]!).parent;
      expect(await ruleDirectory.exists(), isFalse);
      await manager.prepareLocalFiles(
        requested.map((tag) => manager.pathsByTag[tag]!),
      );
      expect(await ruleDirectory.list().length, requested.length);
      for (final tag in requested) {
        final file = File(manager.pathsByTag[tag]!);
        final bytes = await file.readAsBytes();
        expect(bytes.take(3), [0x53, 0x52, 0x53], reason: tag);
        expect(
          sha256.convert(bytes).toString(),
          status.files['$tag.srs']!.sha256,
        );
      }
      expect(await manager.isUpdateDue(const Duration(hours: 24)), isTrue);
    },
  );

  test('repairs only requested bundled files after reopening', () async {
    final bundle = _FixtureBundle();
    RuleSetManager openManager() => RuleSetManager(
      paths: paths,
      clientFactory: HttpClient.new,
      bundle: bundle,
    );

    final manager = openManager();
    await manager.initialize();
    final first = File(manager.pathsByTag['geosite-cn']!);
    final second = File(manager.pathsByTag['geoip-us']!);
    await manager.prepareLocalFiles([first.path]);
    final corrupt = Uint8List(_rule.length);
    await first.writeAsBytes(corrupt);

    final reopened = openManager();
    await reopened.initialize();
    expect(await first.readAsBytes(), corrupt);
    expect(await second.exists(), isFalse);
    await reopened.prepareLocalFiles([first.path]);
    expect(await first.readAsBytes(), _rule);
    expect(await second.exists(), isFalse);
    await reopened.prepareLocalFiles([second.path]);
    expect(await second.readAsBytes(), _rule);
  });

  test('uses only GitHub Releases and verifies downloaded assets', () async {
    final requests = <(String, String)>[];
    var corruptDownload = true;
    final manager = RuleSetManager(
      paths: paths,
      bundle: _FixtureBundle(),
      clientFactory: () => _Client.responses((method, uri) {
        requests.add((method, '${uri.host}${uri.path}'));
        if (uri.host == 'release-assets.githubusercontent.com') {
          expect(method, 'HEAD');
          return _Response([], size: uri.path.endsWith('dlc.dat') ? 3 : 1);
        }
        expect(uri.host, 'github.com');
        final site = uri.path.contains('domain-list-community');
        final repo = site ? 'domain-list-community' : 'geoip';
        final file = site ? 'dlc.dat' : 'geoip.dat';
        final tag = site ? '2' : '1';
        final prefix = '/v2fly/$repo/releases';
        final path = '$prefix/download/$tag/$file';
        if (uri.path == '$prefix/latest') {
          return _Response(
            [],
            status: 302,
            headers: {'location': '$prefix/tag/$tag'},
          );
        }
        if (uri.path == '$prefix/expanded_assets/$tag') {
          final digest = sha256.convert(site ? [1, 2, 3] : [0]);
          return _Response(
            utf8.encode('''
<li><a href="$path.sha256sum">checksum</a><clipboard-copy value="sha256:$_ruleHash"></clipboard-copy></li>
<li><a href="$path">$file</a><clipboard-copy value="sha256:$digest"></clipboard-copy></li>
'''),
          );
        }
        expect(uri.path, path);
        if (method == 'HEAD') {
          return _Response(
            [],
            status: 302,
            headers: {
              'location': 'https://release-assets.githubusercontent.com/$file',
            },
          );
        }
        expect(file, 'dlc.dat');
        return _Response(corruptDownload ? [1, 2, 4] : [1, 2, 3]);
      }),
      converter: (kind, input, output) async {
        expect(kind, 'geosite');
        expect(await File(input).readAsBytes(), [1, 2, 3]);
        for (final tag in ['geosite-cn', 'geosite-category-ads-all']) {
          await File('$output/$tag.srs').writeAsBytes(_rule);
        }
      },
    );
    await manager.initialize();
    final original = manager.pathsByTag;

    await expectLater(
      manager.update(),
      throwsA(
        isA<RuleSetException>().having(
          (e) => e.message,
          'message',
          'dlc.dat 校验失败',
        ),
      ),
    );
    expect(manager.pathsByTag, original);
    expect((await manager.readStatus()).checkedAt, isNull);
    corruptDownload = false;

    final result = await manager.update();
    expect(result.updated, isTrue);
    expect(result.status.releaseTag('geosite'), '2');
    expect(result.status.releaseTag('geoip'), '1');
    expect(
      requests.where(
        (request) =>
            request.$1 == 'HEAD' &&
            request.$2.startsWith('release-assets.githubusercontent.com'),
      ),
      hasLength(4),
    );
  });

  test(
    'publishes a complete verified update and restores the offline snapshot',
    () async {
      final bundle = _FixtureBundle();
      var failChecksum = true;
      var failConversion = true;
      var downloads = 0;
      var conversions = 0;
      final manager = RuleSetManager(
        paths: paths,
        bundle: bundle,
        clientFactory: () => _Client.responses((method, uri) {
          expect(uri.host, 'github.com');
          final site = uri.path.contains('domain-list-community');
          final repo = site ? 'domain-list-community' : 'geoip';
          final tag = site ? '2' : '1';
          final file = site ? 'dlc.dat' : 'geoip.dat';
          final bytes = site ? [1, 2, 3] : [0];
          final path = '/v2fly/$repo/releases';
          if (uri.path == '$path/latest') {
            return _Response(
              [],
              status: 302,
              headers: {'location': '$path/tag/$tag'},
            );
          }
          final assetPath = '$path/download/$tag/$file';
          if (uri.path == '$path/expanded_assets/$tag') {
            return _Response(
              utf8.encode(
                '<li><a href="$assetPath">$file</a>'
                '<clipboard-copy value="sha256:${sha256.convert(bytes)}"></clipboard-copy></li>',
              ),
            );
          }
          expect(uri.path, assetPath);
          if (method == 'HEAD') return _Response([], size: bytes.length);
          expect(file, 'dlc.dat');
          downloads++;
          return _Response(failChecksum ? [1, 2, 4] : bytes);
        }),
        converter: (kind, input, output) async {
          conversions++;
          expect(kind, 'geosite');
          expect(await File(input).readAsBytes(), [1, 2, 3]);
          await File('$output/geosite-cn.srs').writeAsBytes(_rule);
          if (failConversion) throw RuleSetException('conversion failed');
          for (final name in [
            'geosite-category-ads-all.srs',
            'geosite-google.srs',
          ]) {
            await File('$output/$name').writeAsBytes(_rule);
          }
        },
      );
      final legacy = File('${paths.runtime.path}/rules/manifest.json');
      await legacy.create(recursive: true);
      await legacy.writeAsString('{"schema":1}');
      await manager.initialize();
      final bundledPath = manager.pathsByTag['geosite-cn']!;
      await manager.prepareLocalFiles([bundledPath]);
      expect(await File(manager.pathsByTag['geoip-us']!).exists(), isFalse);

      await expectLater(manager.update(), throwsA(isA<RuleSetException>()));
      expect(conversions, 0);
      failChecksum = false;
      await expectLater(manager.update(), throwsA(isA<RuleSetException>()));
      expect(manager.pathsByTag['geosite-cn'], bundledPath);
      expect((await manager.readStatus()).checkedAt, isNull);
      expect(manager.tags, isNot(contains('geosite-google')));

      failConversion = false;
      final updated = await manager.update();
      expect(updated.updated, isTrue);
      expect(updated.status.source, 'network');
      expect(updated.status.releaseTag('geosite'), '2');
      expect(
        manager.tags,
        containsAll(['geosite-google', 'geoip-cn', 'geoip-us']),
      );
      expect(manager.pathsByTag['geosite-cn'], isNot(bundledPath));
      expect(await File(bundledPath).exists(), isTrue);
      expect(await File(manager.pathsByTag['geoip-us']!).readAsBytes(), _rule);
      expect(await manager.isUpdateDue(const Duration(hours: 24)), isFalse);

      expect((await manager.update()).updated, isFalse);
      expect(downloads, 3);
      expect(conversions, 2);
      final reopened = RuleSetManager(
        paths: paths,
        clientFactory: HttpClient.new,
        bundle: bundle,
      );
      await reopened.initialize();
      expect(reopened.pathsByTag, manager.pathsByTag);
      final networkFile = File(reopened.pathsByTag['geosite-cn']!);
      await networkFile.writeAsBytes(Uint8List(_rule.length));
      await expectLater(
        reopened.prepareLocalFiles([networkFile.path]),
        throwsA(isA<RuleSetException>()),
      );
      expect((await reopened.resetToBundled()).source, 'bundled');
      expect(reopened.pathsByTag['geosite-cn'], bundledPath);
      expect(reopened.tags, isNot(contains('geosite-google')));
    },
  );
}

final _rule = Uint8List.fromList([0x53, 0x52, 0x53, 5, ...List.filled(20, 0)]);
final _ruleHash = sha256.convert(_rule).toString();

class _FixtureBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key.endsWith('.srs')) return ByteData.sublistView(_rule);
    return ByteData.sublistView(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'schema': 2,
            'generatedAt': '2026-01-01T00:00:00Z',
            'releases': {
              for (final kind in ['geosite', 'geoip'])
                kind: {
                  'tag': '1',
                  'sha256': sha256.convert([0]).toString(),
                  'size': 1,
                },
            },
            'files': {
              for (final tag in [
                'geosite-cn',
                'geosite-category-ads-all',
                'geoip-cn',
                'geoip-us',
              ])
                '$tag.srs': {'size': _rule.length, 'sha256': _ruleHash},
            },
          }),
        ),
      ),
    );
  }
}

class _Client extends Fake implements HttpClient {
  _Client.responses(this._reply);
  final HttpClientResponse Function(String, Uri) _reply;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _Request(_reply('GET', url));

  @override
  Future<HttpClientRequest> headUrl(Uri url) async =>
      _Request(_reply('HEAD', url));

  @override
  void close({bool force = false}) {}
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.response);
  final HttpClientResponse response;

  @override
  final HttpHeaders headers = _Headers(const {});

  @override
  bool followRedirects = true;

  @override
  Future<HttpClientResponse> close() async => response;
}

class _Headers extends Fake implements HttpHeaders {
  _Headers(this.values);
  final Map<String, String> values;

  @override
  String? value(String name) => values[name];

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
}

class _Response extends StreamView<List<int>> implements HttpClientResponse {
  _Response(
    List<int> bytes, {
    int? size,
    int status = HttpStatus.ok,
    Map<String, String> headers = const {},
  }) : contentLength = size ?? bytes.length,
       statusCode = status,
       headers = _Headers(headers),
       super(Stream.value(bytes));

  @override
  final int contentLength;

  @override
  final int statusCode;

  @override
  final HttpHeaders headers;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
