import 'package:flutter_test/flutter_test.dart';
import 'package:nekoproxy/domain/models.dart';

void main() {
  test('每个订阅独立保存自动更新开关和周期', () {
    final snapshot = AppSnapshot(
      settings: AppSettings(),
      subscriptions: [
        Subscription(
          id: 'daily',
          name: '每日订阅',
          url: 'https://example.com/daily',
          autoUpdate: true,
          updateIntervalMinutes: 24 * 60,
        ),
        Subscription(
          id: 'manual',
          name: '手动订阅',
          url: 'https://example.com/manual',
          autoUpdate: false,
          updateIntervalMinutes: 6 * 60,
        ),
      ],
    );

    final restored = AppSnapshot.fromJson(snapshot.toJson());
    expect(restored.subscriptions[0].autoUpdate, isTrue);
    expect(restored.subscriptions[0].effectiveUpdateIntervalMinutes, 24 * 60);
    expect(restored.subscriptions[1].autoUpdate, isFalse);
    expect(restored.subscriptions[1].effectiveUpdateIntervalMinutes, 6 * 60);
  });

  test('旧版统一开关迁移到各订阅并且不再写回设置', () {
    final restored = AppSnapshot.fromJson({
      'version': AppSnapshot.formatVersion,
      'settings': {'subscriptionAutoUpdate': false},
      'subscriptions': [
        {'id': 'legacy', 'name': '旧订阅', 'url': 'https://example.com/legacy'},
        {
          'id': 'custom',
          'name': '已有独立设置',
          'url': 'https://example.com/custom',
          'autoUpdate': true,
          'updateIntervalMinutes': 120,
        },
      ],
      'rules': [],
      'advancedJson': {},
    });

    expect(restored.subscriptions[0].autoUpdate, isFalse);
    expect(restored.subscriptions[1].autoUpdate, isTrue);
    expect(
      restored.settings.toJson().containsKey('subscriptionAutoUpdate'),
      isFalse,
    );
  });

  test('自动更新到期判断使用各订阅自己的周期', () {
    final now = DateTime(2026, 11, 12, 16);
    final hourly = Subscription(
      id: 'hourly',
      name: '每小时',
      url: 'https://example.com/hourly',
      autoUpdate: true,
      updateIntervalMinutes: 60,
      lastUpdated: now.subtract(const Duration(minutes: 59)),
    );
    final daily = Subscription(
      id: 'daily',
      name: '每日',
      url: 'https://example.com/daily',
      autoUpdate: true,
      updateIntervalMinutes: 24 * 60,
      lastUpdated: now.subtract(const Duration(hours: 23)),
    );
    final disabled = Subscription(
      id: 'disabled',
      name: '已关闭',
      url: 'https://example.com/disabled',
      autoUpdate: false,
      updateIntervalMinutes: 60,
      lastUpdated: now.subtract(const Duration(days: 2)),
    );

    expect(hourly.isAutoUpdateDue(now), isFalse);
    expect(
      hourly
          .copyWith(lastUpdated: now.subtract(const Duration(hours: 1)))
          .isAutoUpdateDue(now),
      isTrue,
    );
    expect(daily.isAutoUpdateDue(now), isFalse);
    expect(disabled.isAutoUpdateDue(now), isFalse);
  });

  test('缺少周期时使用 24 小时默认值而不是显示未提供周期', () {
    final subscription = Subscription(
      id: 'default',
      name: '默认周期',
      url: 'https://example.com/default',
      autoUpdate: true,
      updateIntervalMinutes: 0,
    );

    expect(
      subscription.effectiveUpdateIntervalMinutes,
      Subscription.defaultUpdateIntervalMinutes,
    );
    expect(
      subscription
          .copyWith(updateIntervalMinutes: 1)
          .effectiveUpdateIntervalMinutes,
      Subscription.minimumUpdateIntervalMinutes,
    );
    expect(
      subscription
          .copyWith(
            updateIntervalMinutes:
                Subscription.maximumUpdateIntervalMinutes + 1,
          )
          .effectiveUpdateIntervalMinutes,
      Subscription.maximumUpdateIntervalMinutes,
    );
  });
}
