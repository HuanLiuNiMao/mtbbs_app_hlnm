import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// MCP 悬浮球的 Dart 侧封装（**Android / 鸿蒙**，其他平台 no-op）。
///
/// 原生实现见 `android/app/src/main/kotlin/.../McpFloatingBall.kt` 与
/// `McpFloatingBallBridge.kt`。**该功能的实现来自 Bin**（MT 论坛
/// `FloatingWindowButton`）：拖动跟手、二维惯性抛射贴边、闲置收起、位置按比例
/// 记忆都是他的设计与手感参数。本仓库只做了三处改动：改用不依赖 Material
/// 组件库的圆球、颜色可配、闲置收起时长可配。
///
/// 通道契约 `mtbbs/mcp_floating_ball`：
/// `isSupported` / `hasPermission` / `requestPermission` / `show` / `hide` /
/// `isShowing` / `setColor` / `setIdleSeconds`，以及原生 → Dart 的 `onClick`。
class McpFloatingBall {
  McpFloatingBall._();

  static const MethodChannel _channel = MethodChannel(
    'mtbbs/mcp_floating_ball',
  );

  /// 与原生 `McpFloatingBall.DEFAULT_COLOR` 保持一致
  static const Color defaultColor = Color(0xFF1E88E5);

  /// 与原生 `McpFloatingBall.DEFAULT_IDLE_SECONDS` 保持一致
  static const int defaultIdleSeconds = 3;

  /// 闲置收起秒数的可选上限：再久就不如直接关掉这个行为了
  static const int maxIdleSeconds = 60;

  static bool get _supported =>
      Platform.isAndroid || Platform.operatingSystem == 'ohos';

  static VoidCallback? _onTap;

  /// 订阅「用户点了悬浮球」，并把原生侧的点击转给 [onTap]。
  ///
  /// 只需要注册一次（`main.dart` 启动时）。原生在球被点击时直接回调，
  /// 不存在冷启动暂存问题：球本身就不可能在 App 未启动时存在。
  static void init({required VoidCallback onTap}) {
    if (!_supported) return;
    _onTap = onTap;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onClick') _onTap?.call();
    });
  }

  /// 系统是否已授予「显示在其他应用上层」。
  static Future<bool> hasPermission() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (e) {
      AppLogger.w('MCP', '查询悬浮窗权限失败: $e');
      return false;
    }
  }

  /// 跳系统授权页。返回当前状态（通常是 false，用户授权后需重新查）。
  static Future<bool> requestPermission() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } catch (e) {
      AppLogger.w('MCP', '申请悬浮窗权限失败: $e');
      return false;
    }
  }

  /// 显示悬浮球。没有权限时返回 false（不抛异常）。
  static Future<bool> show({Color? color, int? idleSeconds}) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('show', {
            'color': ?color?.toARGB32(),
            'idleSeconds': ?idleSeconds,
          }) ??
          false;
    } catch (e) {
      AppLogger.w('MCP', '显示悬浮球失败: $e');
      return false;
    }
  }

  static Future<void> hide() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('hide');
    } catch (e) {
      AppLogger.w('MCP', '隐藏悬浮球失败: $e');
    }
  }

  static Future<bool> isShowing() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 改球体颜色。球未显示时返回 false（但设置值仍会在下次显示时生效）。
  static Future<bool> setColor(Color color) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('setColor', {
            'color': color.toARGB32(),
          }) ??
          false;
    } catch (e) {
      AppLogger.w('MCP', '设置悬浮球颜色失败: $e');
      return false;
    }
  }

  /// 改闲置收起秒数（0 = 不自动收起）。
  static Future<bool> setIdleSeconds(int seconds) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('setIdleSeconds', {
            'seconds': seconds.clamp(0, maxIdleSeconds),
          }) ??
          false;
    } catch (e) {
      AppLogger.w('MCP', '设置悬浮球收起时长失败: $e');
      return false;
    }
  }
}
