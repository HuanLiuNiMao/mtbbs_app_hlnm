import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/core/utils/history_filter.dart';
import 'package:mtbbs/models/browse_record.dart';

BrowseRecord _rec({
  required String type,
  required String title,
  String id = 'mt.example.com:thread_1',
  Map<String, dynamic> info = const {},
}) => BrowseRecord(
  id: id,
  type: type,
  routePath: '/thread/1',
  timestamp: DateTime(2024, 1, 1),
  info: {'title': title, ...info},
);

/// 与页面一致的标题渲染（默认模板 + typeLabel）
String _titleOf(BrowseRecord r) => r.displayTitle('{typeLabel} {title}');

void main() {
  final records = [
    _rec(
      type: 'thread',
      title: 'Flutter 打包踩坑',
      id: 'bbs.binmt.cc:thread_100',
      info: {'tid': '100', 'author': '张三'},
    ),
    _rec(
      type: 'thread',
      title: 'Kotlin 协程入门',
      id: 'bbs.binmt.cc:thread_200',
      info: {'tid': '200', 'author': '李四'},
    ),
    _rec(
      type: 'user',
      title: '王五',
      id: 'bbs.binmt.cc:user_300',
      info: {'uid': '300', 'nickname': '王五'},
    ),
  ];

  test('空关键词不过滤', () {
    expect(filterBrowseRecords(records, '', titleOf: _titleOf).length, 3);
    expect(filterBrowseRecords(records, '   ', titleOf: _titleOf).length, 3);
  });

  test('按标题子串匹配，大小写不敏感', () {
    final hit = filterBrowseRecords(records, 'flutter', titleOf: _titleOf);
    expect(hit.map((r) => r.id), ['bbs.binmt.cc:thread_100']);
    final upper = filterBrowseRecords(records, 'KOTLIN', titleOf: _titleOf);
    expect(upper.single.info['title'], 'Kotlin 协程入门');
  });

  test('命中 info 字段（作者 / uid）', () {
    expect(
      filterBrowseRecords(records, '李四', titleOf: _titleOf).single.id,
      'bbs.binmt.cc:thread_200',
    );
    expect(
      filterBrowseRecords(records, '300', titleOf: _titleOf).single.id,
      'bbs.binmt.cc:user_300',
    );
  });

  test('命中类型名与 ID', () {
    expect(filterBrowseRecords(records, '用户', titleOf: _titleOf).length, 1);
    expect(
      filterBrowseRecords(records, 'thread_200', titleOf: _titleOf).single.id,
      'bbs.binmt.cc:thread_200',
    );
  });

  test('多关键词按 AND 匹配', () {
    expect(
      filterBrowseRecords(records, 'flutter 打包', titleOf: _titleOf).length,
      1,
    );
    // 两个关键词分别属于不同记录 → 不匹配
    expect(
      filterBrowseRecords(records, 'flutter 王五', titleOf: _titleOf),
      isEmpty,
    );
  });

  test('无命中返回空列表', () {
    expect(filterBrowseRecords(records, '不存在的词', titleOf: _titleOf), isEmpty);
  });

  test('跨字段拼接不产生假匹配', () {
    // 标题以 "坑" 结尾、下一字段以 "B" 开头，不应匹配 "坑B"
    final r = _rec(type: 'thread', title: '踩坑', info: {'author': 'Bob'});
    expect(filterBrowseRecords([r], '坑b', titleOf: _titleOf), isEmpty);
  });

  test('typeLabel 与 displayTitle 共用同一份文案', () {
    expect(_rec(type: 'mythread', title: 't').typeLabel, '我的帖子');
    expect(_rec(type: 'reply', title: 't').typeLabel, '回复');
    expect(_rec(type: 'unknown', title: 't').typeLabel, 'unknown');
  });
}
