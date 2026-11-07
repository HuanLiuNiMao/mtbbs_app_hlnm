import 'dart:io';

import 'package:mtbbs/core/app/app_paths.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:path/path.dart' as p;

/// 本地备份文件的落地与轮转。
///
/// 只负责「把一段 JSON 写成文件、按份数删旧的」，不关心备份内容怎么来 ——
/// 收集逻辑在 [BackupService]，这里只管文件系统。
///
/// 设计约束（都跟后台任务有关）：
/// - **不能碰 UI**：WorkManager 的独立 isolate 里没有 Activity，
///   任何 `FileSave` / SAF 选择器都会抛 `MissingPluginException`；
/// - **不能依赖主 isolate 的内存**：目录每次现算，不缓存；
/// - **文件名必须可排序**：轮转靠「按名字排序取最旧的删」，
///   所以时间戳用零填充的 `yyyyMMdd_HHmmss`，不用 `toIso8601String()`
///   （后者带 `-` 和 `:`，在部分平台是非法文件名字符）。
class BackupLocalStore {
  BackupLocalStore._();

  static final BackupLocalStore instance = BackupLocalStore._();

  /// 文件名前缀，用于把「本模块写的文件」和用户手动塞进来的文件区分开。
  ///
  /// 轮转只删带这个前缀的文件 —— 用户如果自己往 `backups/` 里放了东西，
  /// 不该被自动清理误删。
  static const String filePrefix = 'mtbbs_auto_';

  static const String fileSuffix = '.json';

  /// 把 [json] 写成一个新的备份文件，并按 [keepCount] 轮转。
  ///
  /// 返回写入的文件名（不含目录）。失败时抛异常，由调用方记录日志。
  Future<String> save(String json, {required int keepCount}) async {
    final dir = Directory(await AppPaths.backupsDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final name = '$filePrefix${_stamp(DateTime.now())}$fileSuffix';
    final file = File(p.join(dir.path, name));

    // 先写临时文件再 rename：中途被杀进程不会留下半截 JSON，
    // 而半截 JSON 在恢复列表里看起来像个正常备份，点进去才报解析失败。
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);

    AppLogger.i('BACKUP', '本地备份已写入 $name（${json.length} 字节）');
    await _rotate(dir: dir, keepCount: keepCount);
    return name;
  }

  /// 列出已有本地备份，**最新的在前**。
  Future<List<LocalBackupFile>> list() async {
    final dir = Directory(await AppPaths.backupsDir);
    if (!await dir.exists()) return const [];

    final files = <LocalBackupFile>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(filePrefix) || !name.endsWith(fileSuffix)) continue;
      final stat = await entity.stat();
      files.add(
        LocalBackupFile(
          name: name,
          path: entity.path,
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    // 名字里带零填充时间戳，字典序即时间序
    files.sort((a, b) => b.name.compareTo(a.name));
    return files;
  }

  /// 读回某个备份的文本内容
  Future<String> read(String name) =>
      File(p.join(File(await AppPaths.backupsDir).path, name)).readAsString();

  /// 删除指定备份
  Future<void> delete(String name) async {
    final file = File(p.join(File(await AppPaths.backupsDir).path, name));
    if (await file.exists()) await file.delete();
  }

  /// 备份目录总占用（字节）
  Future<int> totalSize() async {
    final files = await list();
    return files.fold<int>(0, (s, f) => s + f.sizeBytes);
  }

  /// 按份数轮转：只保留最新的 [keepCount] 份。
  ///
  /// [keepCount] <= 0 表示不清理（用户显式选择「全部保留」）。
  Future<void> _rotate({required Directory dir, required int keepCount}) async {
    if (keepCount <= 0) return;
    final files = await list();
    if (files.length <= keepCount) return;

    for (final f in files.skip(keepCount)) {
      try {
        await File(f.path).delete();
        AppLogger.i('BACKUP', '轮转删除旧备份 ${f.name}');
      } catch (e) {
        // 删不掉不影响本次备份已经成功这件事，记一条就够
        AppLogger.w('BACKUP', '删除旧备份 ${f.name} 失败: $e');
      }
    }
  }

  /// `yyyyMMdd_HHmmss`，零填充保证字典序 = 时间序
  String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}

/// 一个本地备份文件的元信息
class LocalBackupFile {
  const LocalBackupFile({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modifiedAt;

  /// 人类可读大小
  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}
