import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:nekoproxy/services/app_update_service.dart';

const _tag = 'v1.10.0';
const _prefix = 'NekoProxy-1.10.0+abcdef1-';
const _data = [1, 2, 3, 4];

http.Response _release({bool prerelease = false, bool checksum = true}) {
  return http.Response(
    jsonEncode({
      'tag_name': _tag,
      'prerelease': prerelease,
      'assets': [
        for (final kind in UpdatePackageKind.values) ...[
          {'name': '$_prefix${kind.suffix}', 'size': _data.length},
          if (checksum) {'name': '$_prefix${kind.suffix}.sha256'},
        ],
      ],
    }),
    200,
  );
}

AppUpdateService _service(Future<http.Response> Function(http.Request) handle) {
  final service = AppUpdateService(() => MockClient(handle));
  addTearDown(service.close);
  return service;
}

void main() {
  test('checks a newer stable tag and selects the matching package', () async {
    final service = _service((request) async {
      expect(request.url.host, 'api.github.com');
      expect(request.url.path, '/repos/Sh1rokoDev/NekoProxy/releases/latest');
      return _release();
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
      final preview = _service((_) async => _release(prerelease: true));
      final empty = _service((_) async => http.Response('', 404));
      expect(await preview.check('1.0.0', UpdatePackageKind.android), isNull);
      expect(await empty.check('1.0.0', UpdatePackageKind.android), isNull);
    },
  );

  test('rejects a release without the selected package checksum', () async {
    final service = _service((_) async => _release(checksum: false));
    await expectLater(
      service.check('1.0.0', UpdatePackageKind.android),
      throwsA(isA<AppUpdateException>()),
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
      if (request.url.host == 'api.github.com') return _release();
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
      if (request.url.host == 'api.github.com') return _release();
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
      if (request.url.host == 'api.github.com') return _release();
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
