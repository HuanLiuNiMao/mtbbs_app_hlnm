import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:mtbbs/core/app/app_paths.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/services/error_log/error_log_entry.dart';

/// 错误日志的落盘与读取。
///
/// **形式与实现思路借鉴 bggRGjQaUbCoE/PiliPlus 的日志页**
/// （https://github.com/bggRGjQaUbCoE/PiliPlus）。
///
/// 与 PiliPlus 的差异（都是本仓库环境决定的，不是偷懒）：
/// - PiliPlus 用 `catcher_2` 同时接管 `FlutterError.onError`、`PlatformDispatcher.onError`
///   与 `Isolate` 错误，并自带文件 handler；本仓库依赖锁得很死（见 docs/09），
///   所以这里自己实现采集，但**装钩子的位置与时机一致**（见 [install]）。
/// - 落盘用 JSON Lines 而不是一个 JSON 数组：追加写只追加一行，不用读出整份再写回；
///   单行损坏也只影响那一条。
///
/// 文件位置：`{appDataDir}/error_logs.json`（应用私有目录，卸载即清）。
/// 不写 `getApplicationDocumentsDirectory`：Windows 上那是用户的**文档**目录。
class ErrorLogStore {
  ErrorLogStore._();

  static final ErrorLogStore instance = ErrorLogStore._();

  /// 最多保留多少条（超出后从最旧的开始丢）
  static const int maxEntries = 200;

  /// 单条日志的最大字符数（堆栈异常长时截断，避免一条就把文件撑爆）
  static const int maxFieldLength = 20000;

  /// 缓存的文件句柄，避免每次写都做路径解析
  File? _file;

  /// 写入串行化：错误可能在同一帧内连续触发，并发 append 会互相插断行
  Future<void> _writeQueue = Future<void>.value();

  Future<File> _resolveFile() async {
    final cached = _file;
    if (cached != null) return cached;
    final dir = await AppPaths.appDataDir;
    final file = File(p.join(dir, 'error_logs.json'));
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    return _file = file;
  }

  /// 追加一条。**永不抛异常**：日志组件自己出错不该把主流程带下去。
  void add(ErrorLogEntry entry) {
    _writeQueue = _writeQueue.then((_) async {
      try {
        final file = await _resolveFile();
        await file.writeAsString(
          '${jsonEncode(entry.toMap())}\n',
          mode: FileMode.append,
          flush: true,
        );
        await _trimIfNeeded(file);
      } catch (e) {
        // release 下 AppLogger 本身静默，这里只影响开发期排查
        AppLogger.w('ERROR', '写入错误日志失败：$e');
      }
    });
  }

  /// 超过 [maxEntries] 时重写为最近 N 条。
  ///
  /// 只在「行数明显超标」时做：每次写都数一遍行数没必要，代价与收益不匹配。
  Future<void> _trimIfNeeded(File file) async {
    final lines = await file.readAsLines();
    if (lines.length <= maxEntries) return;
    final keep = lines.sublist(lines.length - maxEntries);
    await file.writeAsString('${keep.join('\n')}\n', flush: true);
  }

  /// 读取全部，**最新的在前**（与 PiliPlus 的展示顺序一致）。
  Future<List<ErrorLogEntry>> all() async {
    List<String> lines;
    try {
      // 路径解析也包在 try 里：`path_provider` 在某些平台/时机不可用
      // （插件未就绪、鸿蒙缺少实现），这时页面应该显示“暂无日志”，而不是崩掉。
      // 日志是排障入口，它自己不能成为新的崩溃点。
      final file = await _resolveFile();
      lines = await file.readAsLines();
    } catch (e) {
      AppLogger.w('ERROR', '读取错误日志失败：$e');
      return const [];
    }
    final out = <ErrorLogEntry>[];
    for (final line in lines.reversed) {
      final t = line.trim();
      if (t.isEmpty) continue;
      try {
        final decoded = jsonDecode(t);
        if (decoded is Map<String, dynamic>) {
          out.add(ErrorLogEntry.fromMap(decoded));
        } else if (decoded is Map) {
          out.add(ErrorLogEntry.fromMap(Map<String, dynamic>.from(decoded)));
        }
      } catch (_) {
        // 单行解析失败：当成一条「解析失败」记录展示，不静默丢掉
        out.add(
          ErrorLogEntry(
            at: DateTime.now(),
            error: '解析该行日志失败：$t',
            source: '日志文件',
          ),
        );
      }
    }
    return out;
  }

  /// 清空。返回是否成功。
  Future<bool> clear() async {
    try {
      final file = await _resolveFile();
      await file.writeAsString('', flush: true);
      return true;
    } catch (e) {
      AppLogger.w('ERROR', '清空错误日志失败：$e');
      return false;
    }
  }

  /// 导出的纯文本（最新在前，条与条之间空一行）。
  Future<String> exportText() async {
    final list = await all();
    if (list.isEmpty) return '（暂无错误日志）';
    return list.map((e) => e.format()).join('\n\n${'-' * 40}\n\n');
  }

  // ==================== 采集 ====================

  static bool _installed = false;

  /// 装全局钩子。**必须在 `runApp` 之前调用**，否则首帧的错误抓不到。
  ///
  /// 保留了原有的处理链：先记日志，再执行 [FlutterError.presentError]（release 下
  /// 它什么都不做，debug 下打印红屏信息），不会把错误「吞掉」。
  static void install() {
    if (_installed) return;
    _installed = true;

    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      instance._record(
        details.exception,
        details.stack,
        source: 'Flutter 框架',
        context: {
          if (details.library != null) '库': details.library!,
          if (details.context != null) '上下文': details.context.toString(),
        },
      );
      // 交回原处理链：debug 下红屏 / 打印，release 下由默认实现上报
      (previousOnError ?? FlutterError.presentError)(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      instance._record(error, stack, source: '异步未捕获');
      // 返回 true = 已处理：框架不再把异常交给平台（否则 release 包会直接终止进程）。
      // 错误本身已写盘，用户下次进错误日志页就能看到并复制，符合本功能的目的。
      return true;
    };
  }

  /// 手动上报（UI 里的「上报一条测试错误」也走这里）。
  static void report(
    Object error, {
    StackTrace? stack,
    String source = '手动上报',
    Map<String, String> context = const {},
  }) {
    instance._record(error, stack, source: source, context: context);
  }

  void _record(
    Object error,
    StackTrace? stack, {
    required String source,
    Map<String, String> context = const {},
  }) {
    final message = _clip(error.toString());
    final trace = stack == null ? null : _clip(stack.toString());
    add(
      ErrorLogEntry(
        at: DateTime.now(),
        error: message,
        stackTrace: (trace == null || trace.trim().isEmpty || trace == 'null')
            ? null
            : trace,
        source: source,
        context: context,
      ),
    );
  }

  static String _clip(String s) =>
      s.length <= maxFieldLength ? s : '${s.substring(0, maxFieldLength)}\n…（已截断）';
}
