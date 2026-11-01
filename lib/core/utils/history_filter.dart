import 'package:mtbbs/models/browse_record.dart';

/// 浏览记录本地过滤（纯函数，供浏览记录页与单测共用）。
///
/// 匹配口径：**以用户能看到的文本为准**——标题按当前设置模板渲染后参与匹配
/// （`titleOf` 由调用方传入），再加上类型名、路由、ID 与 `info` 里的原始字段
/// （tid / uid / 作者 / 昵称等）。
///
/// 查询串按空白切分为多个关键词，**全部命中**才算匹配（AND），便于
/// 「帖子 关键词」这类组合查询；大小写不敏感，不引入正则（避免用户输入
/// 非法正则导致运行时崩溃，与 `content_filter.dart` 的口径一致）。
List<BrowseRecord> filterBrowseRecords(
  List<BrowseRecord> records,
  String query, {
  required String Function(BrowseRecord record) titleOf,
}) {
  final tokens = query
      .trim()
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return records;

  return records.where((record) {
    final haystack = _haystack(record, titleOf(record));
    return tokens.every(haystack.contains);
  }).toList();
}

/// 单条记录的匹配文本（小写），字段间用换行分隔避免跨字段拼接出假匹配。
String _haystack(BrowseRecord record, String title) {
  final buffer = StringBuffer()
    ..write(title.toLowerCase())
    ..write('\n')
    ..write(record.typeLabel.toLowerCase())
    ..write('\n')
    ..write(record.type.toLowerCase())
    ..write('\n')
    ..write(record.routePath.toLowerCase())
    ..write('\n')
    ..write(record.id.toLowerCase());
  for (final entry in record.info.entries) {
    final value = entry.value;
    if (value == null) continue;
    buffer
      ..write('\n')
      ..write(value.toString().toLowerCase());
  }
  return buffer.toString();
}
