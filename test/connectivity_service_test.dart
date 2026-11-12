import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/services/connectivity_service.dart';

void main() {
  test('service catalog is unique and uses https endpoints', () {
    final ids = <String>{};
    for (final service in connectivityServices) {
      expect(ids.add(service.id), isTrue, reason: 'duplicate id ${service.id}');
      final uri = Uri.parse(service.url);
      expect(uri.scheme, 'https', reason: service.name);
      expect(uri.host, isNotEmpty, reason: service.name);
    }
    expect(connectivityServices.where((service) => service.featured), hasLength(4));
  });

  test('failed results carry a short error', () {
    final result = ServiceCheckResult(
      status: ServiceCheckStatus.failed,
      error: '超时',
      checkedAt: DateTime(2026),
    );
    expect(result.isFailed, isTrue);
    expect(result.isAvailable, isFalse);
    expect(result.error, '超时');
  });
}