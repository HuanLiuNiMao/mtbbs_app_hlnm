import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/platform/optional/secure_store.dart';

/// 一次 WebDAV 操作的结果。
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

/// Web 备份客户端 —— 标准 WebDAV 协议（PROPFIND / MKCOL / PUT / GET）。
///
/// 形式与逻辑借鉴 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
/// 的 `lib/pages/webdav/webdav.dart`：
/// - 连接参数只有「地址 / 用户 / 密码 / 路径」；
/// - 连接时先 `mkdirAll`，把目录一次性建好，后续读写直接落文件；
/// - 备份 = 先删旧文件再写（`remove` 失败忽略），恢复 = 读回同一路径。
///
/// **为什么不用 `webdav_client` 包**：它锁定 `xml ^6.2.2`，本仓库是
/// `xml ^7.0.1`，`pub get` 直接版本求解失败（已实测）。本仓库只需要
/// 「建目录 + 写文件 + 读文件」三个动作，用已有 dio 手写不到 300 行，
/// 比为此降级 xml 影响 RSS 解析划算。
///
/// **与 PiliPlus 的实现差异（有意为之）**：
/// - 超时 60s 而非 12s：本应用的备份包可能含 Cookie 与帖子缓存，体积远大于
///   PiliPlus 的设置 JSON，12s 在弱网下会稳定超时；
/// - 文件名固定 `mtbbs_backup.json`，不带平台后缀：换机（Windows → 手机）
///   是最常见场景，带后缀会让另一台设备找不到文件；
/// - 不缓存 client：本应用的上传是低频操作（手动 / 定时），缓存收益接近零，
///   而缓存会让「改了密码但没生效」变成难以排查的幽灵问题。
class BackupWebClient {
  BackupWebClient._();

  static final BackupWebClient instance = BackupWebClient._();

  /// 密钥库中密码的键（与 `WebBackupConfig.password` 互补：
  /// 明文模式用字段，加密模式用这个键）
  static const String secretKey = 'web_backup_password';

  static const Duration _connectTimeout = Duration(seconds: 15);
  static const Duration _ioTimeout = Duration(seconds: 60);

  /// 解析出真正用于认证的密码。
  ///
  /// 加密模式下从系统密钥库读；读不到返回空串，由上层提示用户重填，
  /// 而不是让上传悄悄失败在 401。
  static Future<String> resolvePassword(WebBackupConfig cfg) async {
    if (cfg.secretMode != SecretStoreMode.secure) return cfg.password.trim();
    final value = await SecretStore.read(secretKey);
    if (value == null || value.isEmpty) {
      AppLogger.w('BACKUP', '加密模式下的 WebDAV 密码缺失（密钥库无值），本次请求不带密码');
      return '';
    }
    return value.trim();
  }

  /// 把 URL 脱敏到 `scheme://host:port/path`，丢掉 query / fragment / userinfo。
  ///
  /// WebDAV 地址本身不含凭据，但用户可能图省事写成
  /// `https://user:pass@host/dav/`，原样打日志等于把密码写进可导出的运行日志。
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '（无效地址）';
    final path = uri.path.isEmpty ? '/' : uri.path;
    return '${uri.scheme}://${uri.host}'
        '${uri.hasPort ? ':${uri.port}' : ''}$path';
  }

  /// 完整的上传目标地址（含目录与文件名），仅用于请求与脱敏日志。
  ///
  /// 逐段 `Uri.encodeComponent`：目录名可能含中文或空格（坚果云允许），
  /// 直接字符串拼接会得到非法 URI，dio 会在发送前抛 `FormatException`。
  static Uri resolveFileUri(WebBackupConfig cfg) {
    final base = Uri.parse(cfg.uri.trim());
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    final segments = [
      ...cfg.effectiveSegments,
      WebBackupConfig.defaultFileName,
    ];
    // 用 Uri(...) 重建而不是 base.replace(...)：Dart 里 `replace(query: null)`
    // 表示「保持原值」，并不会清空。而地址上带的 query / fragment 一旦混进
    // 请求就变成了「WebDAV 地址 + 令牌」，既不该发给服务器也不该进日志。
    //
    // 同时丢弃 userInfo：凭据统一走 Authorization 头，URL 里再带一份
    // `user:pass@` 只会让日志脱敏多一个漏点（dio 也可能优先用它）。
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '$basePath${segments.map(Uri.encodeComponent).join('/')}',
    );
  }

  /// 目录地址（不含文件名），`mkdirAll` 用
  static Uri resolveFolderUri(WebBackupConfig cfg) {
    final file = resolveFileUri(cfg);
    final path = file.path;
    return file.replace(path: path.substring(0, path.lastIndexOf('/') + 1));
  }

  /// 构造一个已带 Basic 认证的 Dio。
  ///
  /// 手写 `Authorization` 而不是用 dio 的拦截器：只需要这一处，
  /// 拦截器还会在重定向时重复加头，反而容易出错。
  Dio _buildDio(WebBackupConfig cfg, String password) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: _connectTimeout,
        sendTimeout: _ioTimeout,
        receiveTimeout: _ioTimeout,
        // WebDAV 的 207 / 404 都要自己判断语义，不能让 dio 把非 2xx 抛成异常
        validateStatus: (_) => true,
        followRedirects: true,
      ),
    );
    final user = cfg.username.trim();
    if (user.isNotEmpty || password.isNotEmpty) {
      final token = base64.encode(utf8.encode('$user:$password'));
      dio.options.headers['Authorization'] = 'Basic $token';
    }
    // 部分服务端（坚果云）在非 UTF-8 路径下会返回乱码，显式声明
    dio.options.headers['accept-charset'] = 'utf-8';
    return dio;
  }

  /// 建目录（等价于 PiliPlus 的 `client.mkdirAll`）。
  ///
  /// 逐级 MKCOL：WebDAV 的 MKCOL 不递归，父目录不存在时子目录会 409。
  /// 每级先 PROPFIND 探测，已存在就跳过 —— 这样重复上传不会因为
  /// 「目录已存在」的 405 而误判失败。
  Future<void> _ensureFolder(Dio dio, Uri folder) async {
    final segments = folder.path.split('/').where((s) => s.isNotEmpty).toList();
    var current = folder.replace(path: '/');
    for (final segment in segments) {
      current = current.replace(path: '${current.path}$segment/');
      final probe = await dio.request<void>(
        current.toString(),
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
      );
      final code = probe.statusCode ?? 0;
      if (code == 207 || code == 200) continue;
      if (code == 401 || code == 403) {
        throw const _WebDavException('认证失败，请检查用户名与应用授权码');
      }
      if (code != 404 && code != 409) {
        throw _WebDavException('探测目录失败（HTTP $code）');
      }
      final created = await dio.request<void>(
        current.toString(),
        options: Options(method: 'MKCOL'),
      );
      final mkcol = created.statusCode ?? 0;
      // 405 = 已存在（并发 / 服务端不返回 207 的情况），视为成功
      if (mkcol != 201 && mkcol != 200 && mkcol != 405) {
        throw _WebDavException('创建目录失败（HTTP $mkcol）');
      }
    }
  }

  /// 验证配置是否可用：能连上、能建目录。
  ///
  /// 对应 PiliPlus 的 `init()` —— 保存配置时调用，让用户当场知道
  /// 「地址 / 账号 / 授权码」这套组合对不对，而不是等到真正备份才发现。
  Future<BackupUploadResult> test(WebBackupConfig cfg) async {
    if (!cfg.usable) {
      return const BackupUploadResult(ok: false, message: '未填写有效的 WebDAV 地址');
    }
    final password = await resolvePassword(cfg);
    final dio = _buildDio(cfg, password);
    try {
      await _ensureFolder(dio, resolveFolderUri(cfg));
      AppLogger.i('BACKUP', 'WebDAV 连接成功：${redactUrl(cfg.uri)}');
      return const BackupUploadResult(ok: true, message: '连接成功');
    } on _WebDavException catch (e) {
      AppLogger.w('BACKUP', 'WebDAV 连接失败（${redactUrl(cfg.uri)}）：${e.message}');
      return BackupUploadResult(ok: false, message: e.message);
    } on DioException catch (e) {
      // 只打类型名，不打 e.message：Dio 的 message 里可能带上完整 URL
      AppLogger.w(
        'BACKUP',
        'WebDAV 连接异常（${redactUrl(cfg.uri)}）：${e.type.name}',
      );
      return BackupUploadResult(ok: false, message: _friendly(e));
    } catch (e) {
      AppLogger.w('BACKUP', 'WebDAV 连接异常（${redactUrl(cfg.uri)}）：$e');
      return BackupUploadResult(ok: false, message: '$e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 上传备份包 JSON（PUT 覆盖写）。
  ///
  /// 先删再写是 PiliPlus 的做法，这里保留：部分 WebDAV 实现（含坚果云）
  /// 对「已存在文件 PUT」偶发返回 412，删掉再写最稳；删除失败一律忽略，
  /// 因为文件本来就可能不存在。
  Future<BackupUploadResult> upload(String json, WebBackupConfig cfg) async {
    if (!cfg.usable) {
      return const BackupUploadResult(ok: false, message: '未填写有效的 WebDAV 地址');
    }
    if (!cfg.hasUsername) {
      return const BackupUploadResult(ok: false, message: '未填写用户名');
    }
    if (cfg.wifiOnly && !await isOnWifi()) {
      return const BackupUploadResult(
        ok: false,
        message: '当前非 Wi-Fi 网络，已按设置跳过',
      );
    }

    final password = await resolvePassword(cfg);
    final dio = _buildDio(cfg, password);
    final folder = resolveFolderUri(cfg);
    final file = resolveFileUri(cfg);
    final bytes = utf8.encode(json).length;
    try {
      await _ensureFolder(dio, folder);
      // 旧文件先删，忽略失败（不存在 / 服务端不支持 DELETE 都继续走 PUT）
      try {
        await dio.delete<void>(file.toString());
      } catch (_) {}
      final response = await dio.put<void>(
        file.toString(),
        data: json,
        options: Options(
          headers: {
            Headers.contentTypeHeader: 'application/json; charset=utf-8',
          },
        ),
      );
      final code = response.statusCode ?? 0;
      final ok = code >= 200 && code < 300;
      AppLogger.i(
        'BACKUP',
        'WebDAV 上传 ${redactUrl(cfg.uri)}${cfg.remoteFileLabel}'
            ' → HTTP $code（$bytes 字节）',
      );
      return BackupUploadResult(
        ok: ok,
        message: ok ? '已上传（HTTP $code）' : '服务器返回 HTTP $code',
        statusCode: code,
        bytes: bytes,
      );
    } on _WebDavException catch (e) {
      AppLogger.w('BACKUP', 'WebDAV 上传失败（${redactUrl(cfg.uri)}）：${e.message}');
      return BackupUploadResult(ok: false, message: e.message);
    } on DioException catch (e) {
      AppLogger.w(
        'BACKUP',
        'WebDAV 上传失败（${redactUrl(cfg.uri)}）：${e.type.name}'
            '${e.response?.statusCode == null ? '' : ' HTTP ${e.response!.statusCode}'}',
      );
      return BackupUploadResult(ok: false, message: _friendly(e));
    } catch (e) {
      AppLogger.w('BACKUP', 'WebDAV 上传异常（${redactUrl(cfg.uri)}）：$e');
      return BackupUploadResult(ok: false, message: '$e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 从云端读回备份包 JSON 文本（失败时 [BackupDownloadResult.text] 为 null）。
  Future<BackupDownloadResult> download(WebBackupConfig cfg) async {
    if (!cfg.usable) {
      return const BackupDownloadResult(ok: false, message: '未填写有效的 WebDAV 地址');
    }
    final password = await resolvePassword(cfg);
    final dio = _buildDio(cfg, password);
    final file = resolveFileUri(cfg);
    try {
      final response = await dio.get<List<int>>(
        file.toString(),
        options: Options(responseType: ResponseType.bytes),
      );
      final code = response.statusCode ?? 0;
      if (code == 404) {
        return const BackupDownloadResult(ok: false, message: '云端还没有备份文件');
      }
      if (code == 401 || code == 403) {
        return BackupDownloadResult(
          ok: false,
          message: '认证失败（HTTP $code），请检查用户名与应用授权码',
        );
      }
      if (code < 200 || code >= 300) {
        return BackupDownloadResult(ok: false, message: '服务器返回 HTTP $code');
      }
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) {
        return const BackupDownloadResult(ok: false, message: '云端文件为空');
      }
      AppLogger.i(
        'BACKUP',
        'WebDAV 下载 ${redactUrl(cfg.uri)}${cfg.remoteFileLabel}'
            ' → HTTP $code（${bytes.length} 字节）',
      );
      return BackupDownloadResult(
        ok: true,
        message: '已下载',
        text: utf8.decode(bytes),
        bytes: bytes.length,
      );
    } on DioException catch (e) {
      AppLogger.w(
        'BACKUP',
        'WebDAV 下载失败（${redactUrl(cfg.uri)}）：${e.type.name}',
      );
      return BackupDownloadResult(ok: false, message: _friendly(e));
    } catch (e) {
      AppLogger.w('BACKUP', 'WebDAV 下载异常（${redactUrl(cfg.uri)}）：$e');
      return BackupDownloadResult(ok: false, message: '$e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 把 DioException 翻译成用户能看懂的一句话。
  ///
  /// 不回显 `e.message`：它可能带完整 URL（含 query 里的令牌）。
  static String _friendly(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => '连接超时，请检查网络或服务器地址',
    DioExceptionType.connectionError => '无法连接服务器，请检查地址与网络',
    DioExceptionType.badCertificate => '服务器证书校验失败',
    DioExceptionType.cancel => '已取消',
    _ => '请求失败（${e.type.name}）',
  };

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

/// 下载结果（与上传分开：恢复要拿正文，上传只看状态码）
class BackupDownloadResult {
  const BackupDownloadResult({
    required this.ok,
    required this.message,
    this.text,
    this.bytes = 0,
  });

  final bool ok;
  final String message;
  final String? text;
  final int bytes;
}

/// 协议层错误（由本类主动抛，带用户可读文案）
class _WebDavException implements Exception {
  const _WebDavException(this.message);

  final String message;

  @override
  String toString() => message;
}
