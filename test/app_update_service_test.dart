import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nekoproxy/services/app_update_service.dart';

const _tag = 'v1.10.0';
const _prefix = 'NekoProxy-1.10.0+abcdef1-';
const _data = [1, 2, 3, 4];

http.Response? _release(
  http.Request request, {
  bool prerelease = false,
  bool checksum = true,
}) {
  if (request.url.host != 'github.com') return null;
  const releases = '/Sh1rokoDev/NekoProxy/releases';
  if (request.url.path == '$releases/latest') {
    expect(request.followRedirects, isFalse);
    return http.Response(
      '',
      302,
      headers: {
        'location': '$releases/tag/${prerelease ? 'v1.10.0-beta' : _tag}',
      },
    );
  }
  if (request.url.path == '$releases/expanded_assets/$_tag') {
    String row(String name) =>
        '<li><a href="$releases/download/$_tag/${Uri.encodeComponent(name)}">$name</a></li>';
    return http.Response(
      [
        for (final kind in UpdatePackageKind.values) ...[
          row('$_prefix${kind.suffix}'),
          if (checksum) row('$_prefix${kind.suffix}.sha256'),
        ],
      ].join(),
      200,
    );
  }
  if (request.method == 'HEAD') return http.Response.bytes(_data, 200);
  return null;
}

AppUpdateService _service(Future<http.Response> Function(http.Request) handle) {
  final service = AppUpdateService(() => MockClient(handle));
  addTearDown(service.close);
  return service;
}

void main() {
  test('checks a newer stable tag and selects the matching package', () async {
    final service = _service((request) async {
      expect(request.url.host, 'github.com');
      return _release(request)!;
    });
    for (final kind in UpdatePackageKind.values) {
      final update = await service.check('1.9.99+0123456', kind);
      expect(update?.tag, _tag);
      expect(update?.fileName, '$_prefix${kind.suffix}');
    }
    expect(
      await service.check('1.10.0+0123456', UpdatePackageKind.android),
      isNull,
    );
    expect(await service.check('1.11.0', UpdatePackageKind.android), isNull);
  });

  test(
    'ignores pre-releases and handles the repository with no release',
    () async {
      final preview = _service(
        (request) async => _release(request, prerelease: true)!,
      );
      final empty = _service(
        (_) async => http.Response(
          '',
          302,
          headers: {'location': '/Sh1rokoDev/NekoProxy/releases'},
        ),
      );
      expect(await preview.check('1.0.0', UpdatePackageKind.android), isNull);
      expect(await empty.check('1.0.0', UpdatePackageKind.android), isNull);
    },
  );

  test('rejects a release without the selected package checksum', () async {
    final service = _service(
      (request) async => _release(request, checksum: false)!,
    );
    await expectLater(
      service.check('1.0.0', UpdatePackageKind.android),
      throwsA(isA<AppUpdateException>()),
    );
  });

  test('reports TLS failures as update errors', () async {
    final service = _service(
      (_) async => throw HandshakeException('certificate verify failed'),
    );
    await expectLater(
      service.check('1.0.0', UpdatePackageKind.android),
      throwsA(
        isA<AppUpdateException>().having(
          (error) => error.message,
          'message',
          contains('安全连接'),
        ),
      ),
    );
  });

  test('only saves verified bytes and reuses a valid cached update', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    const fileName = '${_prefix}android-arm64.apk';
    var downloads = 0;
    final service = _service((request) async {
      if (_release(request) case final metadata?) return metadata;
      if (request.url.path.endsWith('.sha256')) {
        return http.Response('${sha256.convert(_data)} *$fileName\n', 200);
      }
      if (request.url.host == 'github.com') {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {
            'location': 'https://release-assets.githubusercontent.com/package',
          },
        );
      }
      expect(request.url.host, 'release-assets.githubusercontent.com');
      downloads++;
      return http.Response.bytes(_data, 200);
    });
    final update = (await service.check('1.0.0', UpdatePackageKind.android))!;
    final progress = <double>[];
    final file = await service.download(
      update,
      directory,
      onProgress: progress.add,
    );
    expect(await file.readAsBytes(), _data);
    expect(progress.last, 1);
    expect((await directory.list().toList()).single.path, file.path);
    await service.download(update, directory, onProgress: (_) {});
    expect(downloads, 1);
  });

  test('rejects a foreign redirect and removes any temporary files', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = _service((request) async {
      if (_release(request) case final metadata?) return metadata;
      expect(request.url.host, 'github.com');
      return http.Response(
        '',
        302,
        headers: {'location': 'https://example.invalid/package'},
      );
    });
    final update = (await service.check('1.0.0', UpdatePackageKind.android))!;
    await expectLater(
      service.download(update, directory, onProgress: (_) {}),
      throwsA(isA<AppUpdateException>()),
    );
    expect(await directory.list().isEmpty, isTrue);
  });

  test('discards a download whose hash does not match', () async {
    final directory = await Directory.systemTemp.createTemp(
      'neko-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final service = _service((request) async {
      if (_release(request) case final metadata?) return metadata;
      if (request.url.path.endsWith('.sha256')) {
        return http.Response(
          '${sha256.convert(_data)} *${_prefix}android-arm64.apk\n',
          200,
        );
      }
      return http.Response.bytes([0, 0, 0, 0], 200);
    });
    final update = (await service.check('1.0.0', UpdatePackageKind.android))!;
    await expectLater(
      service.download(update, directory, onProgress: (_) {}),
      throwsA(isA<AppUpdateException>()),
    );
    expect(await directory.list().isEmpty, isTrue);
  });
}
