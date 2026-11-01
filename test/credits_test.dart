import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/credits.dart';

/// `assets/config/credits.json` 是手工维护的配置，字段写错/漏逗号都会让
/// [Credits.load] 静默返回空列表（致谢页只剩「名单为空」，不报错）。
/// 这里守住「资产已声明 + JSON 合法 + 分组与条目字段齐全 + 上游项目置顶」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('credits.json 能加载，分组与条目字段齐全', () async {
    final sections = await Credits.load();
    expect(sections, isNotEmpty, reason: '为空说明 asset 未声明或 JSON 解析失败');

    for (final s in sections) {
      expect(s.title, isNotEmpty, reason: '分组标题不能为空');
      expect(s.entries, isNotEmpty, reason: '分组 ${s.title} 没有条目');
      for (final e in s.entries) {
        expect(e.name, isNotEmpty, reason: '条目名称不能为空');
        expect(e.desc, isNotEmpty, reason: '${e.name} 缺少说明');
        expect(e.link, startsWith('http'), reason: '${e.name} 的链接不是 http');
      }
    }
  });

  test('上游项目排在第一位（置顶但不特意说明）', () async {
    final sections = await Credits.load();
    final first = sections.first.entries.first;
    expect(first.link, contains('qcxs/mtbbs_app'), reason: '首个分组首条应为上游仓库');
  });

  test('技术栈覆盖语言/框架与依赖分层', () async {
    final sections = await Credits.load();
    final titles = sections.map((s) => s.title).toList();
    // 至少包含「项目与上游」和两组技术类分组
    expect(titles.first, '项目与上游');
    expect(titles.length, greaterThanOrEqualTo(5), reason: '致谢分组过少，技术栈覆盖不足');
    // 特别鸣谢已从关于页合并进本名单，必须在
    expect(titles, contains('特别鸣谢'), reason: '特别鸣谢分组缺失');
  });

  test('特别鸣谢条目带 uid 与论坛帖子链接（可渲染头像、可点击打开）', () async {
    final sections = await Credits.load();
    final thanks = sections.firstWhere((s) => s.title == '特别鸣谢');
    expect(thanks.entries, isNotEmpty);
    for (final e in thanks.entries) {
      expect(e.uid, isNotEmpty, reason: '${e.name} 缺少 uid，头像无法渲染');
      expect(e.siteHost, contains('binmt.cc'));
      expect(e.link, contains('thread-'), reason: '${e.name} 的链接不是论坛帖子');
    }
  });
}
