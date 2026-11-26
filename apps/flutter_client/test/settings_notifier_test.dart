// 问题 6：TUN 默认开启的回归测试。
//
// 不碰真偏好文件：SharedPreferences 用 mock 初始值。
// 注意：`SharedPreferences.getInstance()` 在同一 isolate 里缓存实例，
// `setMockInitialValues` 在第一次 getInstance 之后再调不会生效；
// 所以“明确关过/开过”的用例不用换 mock 值，改走 `setTun` 真持久化
// 再建新容器读回（读到的是同一份 mock 偏好里的新值）。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhexuexi_client/services/settings_notifier.dart';

void main() {
  test('TUN 默认开启：从未存过时同步默认值与读回值都是 true', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // build() 先给默认值（同步），异步读回后再覆盖一次。
    expect(container.read(settingsProvider).tun, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(settingsProvider).tun, isTrue);
  });

  test('明确关过的用户保持关，不强行改回开', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(settingsProvider.notifier).setTun(false);
    expect(first.read(settingsProvider).tun, isFalse);
    first.dispose();

    // 新容器（模拟 App 重启）：读回持久化的 false，不回落默认 true。
    // 先读一次触发 build（同步给默认值），再等异步读回覆盖。
    final second = ProviderContainer();
    addTearDown(second.dispose);
    expect(second.read(settingsProvider).tun, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(second.read(settingsProvider).tun, isFalse);
  });

  test('明确开过的用户保持开', () async {
    SharedPreferences.setMockInitialValues({});
    final first = ProviderContainer();
    addTearDown(first.dispose);
    await first.read(settingsProvider.notifier).setTun(false);
    await first.read(settingsProvider.notifier).setTun(true);
    first.dispose();

    final second = ProviderContainer();
    addTearDown(second.dispose);
    expect(second.read(settingsProvider).tun, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(second.read(settingsProvider).tun, isTrue);
  });
}
