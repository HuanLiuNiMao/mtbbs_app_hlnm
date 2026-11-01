import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mtbbs/core/app/app_capabilities.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// 凭据存储方式。
///
/// 由用户在 Web 备份设置里二选一：
/// - [plain]：随 `settings_app` 文档明文保存。零依赖、可被备份包带走；
///   代价是 root 设备或备份泄露即等于令牌泄露。
/// - [secure]：走系统密钥库（Android Keystore / iOS Keychain）。
///   安全性最好，但**不进备份包**——换机后需要重新填写。
enum SecretStoreMode {
  plain,
  secure;

  static SecretStoreMode fromName(String? name) => SecretStoreMode.values
      .firstWhere((e) => e.name == name, orElse: () => SecretStoreMode.plain);

  String get label => switch (this) {
    SecretStoreMode.plain => '明文（随设置保存）',
    SecretStoreMode.secure => '加密（系统密钥库）',
  };

  String get description => switch (this) {
    SecretStoreMode.plain => '零依赖，可随备份包迁移；令牌会写进设置文档，请勿在公共设备使用',
    SecretStoreMode.secure => '存进 Android Keystore / iOS Keychain，不随备份包迁移，换机需重填',
  };
}

/// 加密凭据存储适配器 —— **唯一** import `flutter_secure_storage` 的地方。
///
/// 约定（见 docs/23 可选能力）：
/// - 业务层只调本类，不直接问插件是否存在；
/// - 插件在当前平台没有实现（典型：鸿蒙、部分桌面）时返回 null 并关闭
///   [AppCapability.secureStore]，调用方回退明文并提示用户；
/// - 读写异常一律吞掉 + 记日志，凭据存储坏了不能让备份主流程崩溃。
abstract final class SecretStore {
  SecretStore._();

  /// 存储键前缀。用前缀而不是裸 key，避免将来与别的功能抢命名空间。
  static const String _prefix = 'mtbbs.backup.secret.';

  /// 复用单个实例：读到的是同一个 Keystore 条目，每次 new 没有收益。
  static FlutterSecureStorage? _storage;

  /// Android 侧显式指定 `encryptedSharedPreferences`：
  /// 旧版默认把值落在普通 SharedPreferences 里，只有打开这个选项才走
  /// Keystore 派生密钥加密。宁可明确写出来，也不依赖插件默认值随版本漂移。
  static const AndroidOptions _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  static FlutterSecureStorage? _ensure() {
    if (!AppCapabilities.isAvailable(AppCapability.secureStore)) return null;
    return _storage ??= const FlutterSecureStorage(aOptions: _androidOptions);
  }

  /// 读取凭据。不存在或不可用时返回 null（调用方按「未配置」处理）。
  static Future<String?> read(String key) async {
    final storage = _ensure();
    if (storage == null) return null;
    try {
      return await storage.read(key: '$_prefix$key');
    } on MissingPluginException {
      AppLogger.w('BACKUP', '密钥库无当前平台实现，回退明文');
      AppCapabilities.disable(AppCapability.secureStore);
      return null;
    } on PlatformException catch (e) {
      // 典型：Keystore 里的旧密钥损坏（恢复备份 / 降级 / 换 ROM）。
      // 读不出来按「未配置」处理，让用户重填；不要因此让备份流程抛异常。
      AppLogger.w('BACKUP', '读取加密凭据失败（${e.code}）：${e.message}');
      return null;
    } catch (e) {
      AppLogger.w('BACKUP', '读取加密凭据异常: $e');
      return null;
    }
  }

  /// 写入凭据。空值等价于删除。返回是否真的写成功。
  static Future<bool> write(String key, String value) async {
    final storage = _ensure();
    if (storage == null) return false;
    try {
      if (value.isEmpty) {
        await storage.delete(key: '$_prefix$key');
      } else {
        await storage.write(key: '$_prefix$key', value: value);
      }
      return true;
    } on MissingPluginException {
      AppLogger.w('BACKUP', '密钥库无当前平台实现，回退明文');
      AppCapabilities.disable(AppCapability.secureStore);
      return false;
    } catch (e) {
      AppLogger.w('BACKUP', '写入加密凭据失败: $e');
      return false;
    }
  }

  static Future<void> delete(String key) async {
    final storage = _ensure();
    if (storage == null) return;
    try {
      await storage.delete(key: '$_prefix$key');
    } catch (e) {
      AppLogger.w('BACKUP', '删除加密凭据失败: $e');
    }
  }

  /// 当前平台是否真的能用系统密钥库
  static bool get available =>
      AppCapabilities.isAvailable(AppCapability.secureStore);

  /// 便于测试：清掉缓存的插件实例（能力被 disable 后再启用时用）
  static void resetForTest() => _storage = null;
}
