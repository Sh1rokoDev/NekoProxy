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
      HomeCard.connection,
      HomeCard.traffic,
      HomeCard.splitMode,
      HomeCard.subscription,
      HomeCard.services,
      HomeCard.activity,
    ]);
    expect(restored.homeDesktop.hidden, {HomeCard.subscription});
    expect(
      HomeLayout.fromJson({'order': 42, 'hidden': 'invalid'}).order,
      HomeCard.values,
    );
  });

  test('旧版默认排序迁移为服务状态在最近活动之前', () {
    final settings = AppSettings.fromJson({
      'homeMobile': {
        'order': [
          'connection',
          'splitMode',
          'traffic',
          'subscription',
          'activity',
          'services',
        ],
      },
    });

    expect(settings.homeMobile.order, HomeCard.values);
  });

  test('缺少规则模式的旧默认布局同样迁移，并保留隐藏卡片', () {
    final layout = HomeLayout.fromJson({
      'order': [
        'connection',
        'traffic',
        'subscription',
        'activity',
        'services',
      ],
      'hidden': ['subscription'],
    });

    expect(layout.order, HomeCard.values);
    expect(layout.hidden, {HomeCard.subscription});
  });

  test('旧版自定义布局将连接卡置顶，并保留其他卡片的相对顺序', () {
    const order = [
      'traffic',
      'subscription',
      'connection',
      'activity',
      'splitMode',
      'services',
    ];
    final layout = HomeLayout.fromJson({'order': order});

    expect(layout.order, [
      HomeCard.connection,
      HomeCard.traffic,
      HomeCard.subscription,
      HomeCard.activity,
      HomeCard.splitMode,
      HomeCard.services,
    ]);
    expect(HomeLayout.fromJson(layout.toJson()).order, layout.order);
  });
}
