import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mtbbs/core/utils/logger.dart';

/// MCP 运行状态常驻通知（**Android / 鸿蒙**，其他平台 no-op）。
///
/// Android 用普通"正在进行"通知而不是前台服务：MCP 只在本进程存活时才可用，
/// 进程结束通知本身也没意义，不值得为此引入前台服务、服务类型声明与额外权限。
///
/// 鸿蒙用 `notificationManager` 的常驻通知，原生实现由鸿蒙仓库提供
/// （`ohos/entry/src/main/ets/plugins/McpStatusNotice.ets`）。Dart 侧只维护
/// 以下通道契约，两端实现必须一致：
/// `show(endpoint)` / `hide` / `getPendingTap` / `onNotificationTap`。
///
/// ## 系统级悬浮球（Android 独有）
/// 同一通道还承载**真正浮在别的应用之上**的悬浮球（原生
/// `McpFloatingBall.kt` + `McpFloatingBallController.kt`，用
/// `TYPE_APPLICATION_OVERLAY` 加到 `WindowManager`）：
/// `showBall` / `hideBall` / `hasOverlayPermission` / `requestOverlayPermission`，
/// 以及原生回调 `onBallTap`（点球 → 打开快捷面板）和 `onBallDismissed`（长按关球）。
///
/// 悬浮球与常驻通知**互为补充**，不是替代关系：通知负责让系统把进程当"有活动的
/// 前台服务"看待，球负责让用户**在离开 App 后仍看得见、点得到**。两者都失败
/// MCP 依然能跑，只是失去可见性。
///
/// 鸿蒙没有对应实现，`_supportedBall` 为 false 时全部降级为 no-op。
class McpStatusNotice {
  McpStatusNotice._();

  static const MethodChannel _channel = MethodChannel('mtbbs/mcp_status');

  static bool get _supported =>
      Platform.isAndroid || Platform.operatingSystem == 'ohos';

  /// 悬浮球只在 Android 有原生实现，鸿蒙/桌面直接跳过。
  static bool get _supportedBall => Platform.isAndroid;

  static VoidCallback? _onTap;
  static VoidCallback? _onBallTap;
  static VoidCallback? _onBallDismissed;

  /// 注册"用户点开了常驻通知"的回调，并补取冷启动时暂存的那一次点击。
  ///
  /// 两个时机都要覆盖：App 在后台/前台时点通知走 [onNewIntent]（原生直接回调
  /// `onNotificationTap`）；App 未运行时点通知是冷启动，Dart 还没注册回调，
  /// 原生先暂存、这里用 `getPendingTap` 补取。
  ///
  /// 补取刻意等**首帧之后**再做：冷启动时根 Navigator 尚未挂载，
  /// 那时弹窗会因为没有 Overlay 而静默失败（见 `showMcpQuickDialog`）。
  static Future<void> init({
    required VoidCallback onNotificationTap,
    VoidCallback? onBallTap,
    VoidCallback? onBallDismissed,
  }) async {
    if (!_supported) return;
    _onTap = onNotificationTap;
    _onBallTap = onBallTap;
    _onBallDismissed = onBallDismissed;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onNotificationTap':
          _onTap?.call();
        case 'onBallTap':
          _onBallTap?.call();
        case 'onBallDismissed':
          _onBallDismissed?.call();
      }
    });
    // 注意：这里到 addPostFrameCallback 之间不能有 await——
    // 必须在调用方（main）交出事件循环前完成注册，才能挂上首帧回调
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final pending = await _channel.invokeMethod<bool>('getPendingTap');
        if (pending == true) _onTap?.call();
      } catch (e) {
        AppLogger.w('MCP', '读取通知点击失败: $e');
      }
    });
  }

  static Future<void> show(String endpoint) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('show', {'endpoint': endpoint});
    } catch (e) {
      AppLogger.w('MCP', '显示状态通知失败: $e');
    }
  }

  static Future<void> hide() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('hide');
    } catch (e) {
      AppLogger.w('MCP', '取消状态通知失败: $e');
    }
  }

  // ==================== 系统级悬浮球 ====================

  /// 显示浮在**其他应用之上**的 MCP 悬浮球（Android 独有）。
  ///
  /// 返回 false 表示没有「显示在其他应用上层」权限 —— Android 6.0 起必须由用户
  /// 在系统设置里手动授予，无法用运行时权限弹窗代替。调用方应引导用户：
  /// `if (!await showBall(url)) { if (await requestOverlayPermission()) { 提示用户授权后回来 } }`
  ///
  /// 幂等：已在屏幕上时直接返回 true，重复调用不会叠出第二个球。
  static Future<bool> showBall(String endpoint) async {
    if (!_supportedBall) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('showBall');
      return ok ?? false;
    } catch (e) {
      AppLogger.w('MCP', '显示悬浮球失败: $e');
      return false;
    }
  }

  /// 移除悬浮球。MCP 停止、用户关闭开关、或用户长按关球后都应调用。
  static Future<void> hideBall() async {
    if (!_supportedBall) return;
    try {
      await _channel.invokeMethod('hideBall');
    } catch (e) {
      AppLogger.w('MCP', '隐藏悬浮球失败: $e');
    }
  }

  /// 当前是否已获得悬浮窗权限。
  ///
  /// 从系统授权页返回时（`AppLifecycleState.resumed`）用它重新探测，
  /// 有权限就自动把球显示出来，省掉用户再点一次开关。
  static Future<bool> hasOverlayPermission() async {
    if (!_supportedBall) return false;
    try {
      return await _channel.invokeMethod<bool>('hasOverlayPermission') ?? false;
    } catch (e) {
      AppLogger.w('MCP', '查询悬浮窗权限失败: $e');
      return false;
    }
  }

  /// 跳转系统「显示在其他应用上层」设置页。
  /// 返回 false 表示这次跳转本身失败（少数 ROM 没有该页面），此时只能提示用户手动找。
  static Future<bool> requestOverlayPermission() async {
    if (!_supportedBall) return false;
    try {
      return await _channel.invokeMethod<bool>('requestOverlayPermission') ?? false;
    } catch (e) {
      AppLogger.w('MCP', '打开悬浮窗授权页失败: $e');
      return false;
    }
  }
}
