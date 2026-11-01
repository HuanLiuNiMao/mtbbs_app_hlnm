import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/platform/optional/secure_store.dart';

/// Web 上传结果
class BackupUploadResult {
  const BackupUploadResult({
    required this.ok,
    required this.message,
    this.statusCode,
    this.bytes = 0,
  });

  final bool ok;
  final String message;
  final int? statusCode;
  final int bytes;

  /// 写进 `WebBackupConfig.lastResult` 的简述
  String get shortResult => ok ? 'ok' : 'failed: $message';
}

/// Web 备份客户端 —— 把备份包 POST/PUT 到**用户自备**的服务器。
///
/// 本应用不提供任何托管服务：地址、鉴权头、间隔全部由用户填写。
/// 约定：请求体就是备份包 JSON（`Content-Type: application/json`），
/// 服务器返回 2xx 即视为成功（不解析响应体，兼容任意自建实现）。
class BackupWebClient {
  BackupWebClient._();

  static final BackupWebClient instance = BackupWebClient._();

  /// 密钥库中鉴权头值的键（与 `WebBackupConfig.headerValue` 互补：
  /// 明文模式用字段，加密模式用这个键）
  static const String secretKey = 'web_backup_auth';

  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _sendTimeout = Duration(seconds: 60);

  /// 解析出真正用于请求的鉴权头值。
  ///
  /// 加密模式下从系统密钥库读；读不到返回空串（请求不带鉴权头），
  /// 由上层提示用户重填，而不是让上传悄悄失败在 401。
  static Future<String> resolveAuthValue(WebBackupConfig cfg) async {
    if (cfg.secretMode != SecretStoreMode.secure) return cfg.headerValue.trim();
    final value = await SecretStore.read(secretKey);
    if (value == null || value.isEmpty) {
      AppLogger.w('BACKUP', '加密模式下的鉴权头缺失（密钥库无值），本次请求不带鉴权头');
      return '';
    }
    return value.trim();
  }

  /// 把 URL 脱敏到 `scheme://host:port/path`，丢掉 query / fragment / userinfo。
  ///
  /// 用户完全可能把令牌塞进 query（`?token=xxx`），原样打日志等于把凭据写进
  /// 日志文件和用户可导出的运行日志里。无效地址回固定文案，避免把解析异常
  /// 原文（可能含输入串）带进日志。
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '（无效地址）';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}$path';
  }

  /// 上传备份包 JSON
  Future<BackupUploadResult> upload(String json, WebBackupConfig cfg) async {
    if (!cfg.usable) {
      return const BackupUploadResult(ok: false, message: '未配置有效的服务器地址');
    }
    if (cfg.wifiOnly && !await isOnWifi()) {
      return const BackupUploadResult(ok: false, message: '当前非 Wi-Fi 网络，已按设置跳过');
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: _connectTimeout,
        sendTimeout: _sendTimeout,
        receiveTimeout: _sendTimeout,
      ),
    );
    final authValue = await resolveAuthValue(cfg);
    final headers = <String, dynamic>{
      Headers.contentTypeHeader: 'application/json; charset=utf-8',
      if (cfg.headerName.trim().isNotEmpty && authValue.isNotEmpty)
        cfg.headerName.trim(): authValue,
    };
    final bytes = json.length;
    try {
      final response = cfg.method == 'PUT'
          ? await dio.put<void>(
              cfg.url.trim(),
              data: json,
              options: Options(headers: headers),
            )
          : await dio.post<void>(
              cfg.url.trim(),
              data: json,
              options: Options(headers: headers),
            );
      final code = response.statusCode ?? 0;
      final ok = code >= 200 && code < 300;
      AppLogger.i(
        'BACKUP',
        'Web 上传 ${cfg.method} ${redactUrl(cfg.url)} → HTTP $code（$bytes 字节）',
      );
      return BackupUploadResult(
        ok: ok,
        message: ok ? '已上传（HTTP $code）' : '服务器返回 HTTP $code',
        statusCode: code,
        bytes: bytes,
      );
    } on DioException catch (e) {
      // 只打类型名，不打 e.message：Dio 的 message 里可能带上完整 URL
      final reason = e.type.name;
      AppLogger.w(
        'BACKUP',
        'Web 上传失败（${redactUrl(cfg.url)}）: $reason'
        '${e.response?.statusCode == null ? '' : ' HTTP ${e.response!.statusCode}'}',
      );
      return BackupUploadResult(ok: false, message: '上传失败：$reason');
    } catch (e) {
      AppLogger.w('BACKUP', 'Web 上传异常（${redactUrl(cfg.url)}）: $e');
      return BackupUploadResult(ok: false, message: '上传失败：$e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 粗略判断当前是否在 Wi-Fi。
  ///
  /// 项目未引入 connectivity_plus（AGENTS.md 不鼓励为单一开关加依赖），
  /// 这里用网卡名启发式判断：命中 `wlan*` / `wifi*` / `wi-fi*`。
  /// 判断不出来时**放行**（宁可上传成功，也不因探测失败静默跳过备份）。
  ///
  /// 注：定时任务由 WorkManager 执行，真正的「仅 Wi-Fi」约束交给系统的
  /// `NetworkType.unmetered`；本方法是手动上传时的兜底判断。
  Future<bool> isOnWifi() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final i in interfaces) {
        final name = i.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('wifi') ||
            name.contains('wi-fi')) {
          return true;
        }
      }
      return false;
    } catch (e) {
      AppLogger.w('BACKUP', '网卡探测失败，按 Wi-Fi 放行: $e');
      return true;
    }
  }
}