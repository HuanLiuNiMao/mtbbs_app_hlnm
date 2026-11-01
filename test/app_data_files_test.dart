import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/core/app/app_data_files.dart';

/// 「注入文件提供器」Dart 侧开关的单测。
///
/// 单测跑在 Linux 上，`Platform.isAndroid` 恒为 false，所以这里覆盖的是
/// **降级路径**：平台不支持时必须直接返回 false 且不碰通道。通道协议本身
/// （方法名 / 参数）由 `AppDataFilesBridge.kt` 与真机测试保证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mtbbs/app_data_files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    // 故意挂一个会抛异常的 handler：代码若在不该调用的平台上发了通道调用，
    // 会因为异常或 calls 非空而暴露出来
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'unexpected');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('非 Android 平台报告不支持', () {
    expect(AppDataFiles.isSupported, isFalse);
  });

  test('不支持的平台上 isEnabled 直接返回 false，且不发通道调用', () async {
    expect(await AppDataFiles.isEnabled(), isFalse);
    expect(calls, isEmpty);
  });

  test('不支持的平台上 setEnabled 直接返回 false，且不发通道调用', () async {
    expect(await AppDataFiles.setEnabled(true), isFalse);
    expect(await AppDataFiles.setEnabled(false), isFalse);
    expect(calls, isEmpty);
  });

  test('不支持的平台上 sync 是空操作', () async {
    await AppDataFiles.sync(true);
    expect(calls, isEmpty);
  });
}