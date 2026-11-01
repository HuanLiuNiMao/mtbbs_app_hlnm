import 'dart:io';

import 'package:flutter/services.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// 「注入文件提供器」的 Dart 侧开关（原生实现见 `AppDataFilesBridge.kt`）。
///
/// 作用：把本应用的私有目录通过系统 SAF（DocumentsProvider）暴露出来，让 MT 管理器
/// 或系统「文件」在**无需 ROOT** 的情况下浏览 / 修改应用数据（数据库、Cookie、
/// 缓存、导出文件），便于排查线上问题。
///
/// 设计要点：
/// - **默认关闭**。原生侧两个组件都是 `android:enabled="false"`，只有用户在
///   「设置 → 存储与工具 → 注入文件提供器」里主动打开才会被注册。理由是私有目录里有
///   登录 Cookie，常驻等于给所有能拉起系统文件选择器的应用多开一扇门。
/// - 设置里落的是**意图值**（`StorageSettings.docProviderEnabled`），真正的事实来源
///   仍是原生组件状态（`isEnabled`）。用户在系统设置里「停用组件」、或写入失败时，
///   `sync()` 会把两者重新对齐，Dart 侧不会出现「界面显示开着但实际没开」的假象。
/// - 非 Android（Windows / 鸿蒙等）恒为不可用，调用方据此隐藏入口。
abstract final class AppDataFiles {
  AppDataFiles._();

  static const MethodChannel _channel = MethodChannel('mtbbs/app_data_files');

  /// 当前平台是否可能支持（只有 Android 有 DocumentsProvider）。
  static bool get isSupported => Platform.isAndroid;

  /// 读取组件当前启用状态。平台不支持或通道异常时返回 false（不抛给 UI）。
  static Future<bool> isEnabled() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (e) {
      AppLogger.w('DATA_FILES', '读取文件提供器状态失败: $e');
      return false;
    }
  }

  /// 写入启用状态，返回原生回读到的实际值。
  ///
  /// 返回 false 有两种含义：本来就想关；或者想开但没开成。调用方用
  /// `enabled == false || result == true` 判断是否成功。
  static Future<bool> setEnabled(bool enabled) async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('setEnabled', {
            'enabled': enabled,
          }) ??
          false;
    } catch (e) {
      AppLogger.w('DATA_FILES', '切换文件提供器状态失败: $e');
      return false;
    }
  }

  /// 把原生组件状态**对齐**到 [enabled]（幂等）。
  ///
  /// 与 [setEnabled] 的区别：先读一次，已是目标值就不写。启动时每次都会调用它，
  /// 不做这个判断等于每次冷启动都往 PackageManager 里写一遍组件状态。
  static Future<void> sync(bool enabled) async {
    if (!isSupported) return;
    if (await isEnabled() == enabled) return;
    final actual = await setEnabled(enabled);
    if (actual != enabled) {
      AppLogger.w('DATA_FILES', '同步文件提供器状态失败（期望 $enabled）');
    }
  }
}
