import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/models.dart';

void main() {
  test('旧版设置默认提供全部首页卡片，两个布局互不影响', () {
    final settings = AppSettings.fromJson({});
    expect(settings.homeDesktop.order, HomeCard.values);
    expect(settings.homeMobile.order, HomeCard.values);
    settings.homeDesktop.hidden.add(HomeCard.traffic);
    expect(settings.homeMobile.hidden, isEmpty);
  });

  test('首页布局往返序列化，忽略未知卡片并补齐缺项', () {
    final layout = HomeLayout.fromJson({
      'order': ['traffic', 'unknown', 'traffic', 'connection'],
      'hidden': ['connection', 'subscription', 42],
    });
    final restored = AppSettings.fromJson(
      AppSettings(homeDesktop: layout).toJson(),
    );
    expect(restored.homeDesktop.order, [
      HomeCard.traffic,
      HomeCard.connection,
      HomeCard.splitMode,
      HomeCard.subscription,
      HomeCard.activity,
      HomeCard.services,
    ]);
    expect(restored.homeDesktop.hidden, {HomeCard.subscription});
    expect(
      HomeLayout.fromJson({'order': 42, 'hidden': 'invalid'}).order,
      HomeCard.values,
    );
  });
}
