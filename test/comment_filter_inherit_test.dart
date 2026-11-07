import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/models/thread_detail.dart';

/// 评论屏蔽词「继承」回归测试。
///
/// 背景 bug：更新版本后屏蔽词消失。
/// 根因是旧版裸词表（`commentFilterKeywords`）的迁移只在
/// `commentFilter` 键**完全不存在**时才跑；只要该键被写过一次
/// （哪怕内容为空），旧词就再也读不到，随后旧键被删除 → 数据丢失。
///
/// 修复后迁移改成幂等合并，核心逻辑抽成本文件的 [mergeLegacyKeywords]。
void main() {
  group('mergeLegacyKeywords — 旧屏蔽词继承', () {
    test('旧键已删除（空列表）时原样保留当前词', () {
      expect(
        mergeLegacyKeywords(const [], const ['a', 'b']),
        ['a', 'b'],
      );
    });

    test('旧键已删除且当前也为空 → 仍为空', () {
      expect(mergeLegacyKeywords(const [], const []), isEmpty);
    });

    test('旧词并入当前配置，旧词在前', () {
      expect(
        mergeLegacyKeywords(const ['旧1', '旧2'], const ['新1']),
        ['旧1', '旧2', '新1'],
      );
    });

    test('重复词去重（旧词与当前词重叠）', () {
      expect(
        mergeLegacyKeywords(const ['a', 'b'], const ['b', 'c']),
        ['a', 'b', 'c'],
      );
    });

    test('旧词内部重复也去重', () {
      expect(
        mergeLegacyKeywords(const ['a', 'a', 'b'], const []),
        ['a', 'b'],
      );
    });

    test('剔除旧版内置词（康康看下| 前缀）', () {
      expect(
        mergeLegacyKeywords(
          const ['康康看下|内置词1|内置词2', '我自己加的'],
          const [],
        ),
        ['我自己加的'],
      );
    });

    test('只有内置词时等于没继承', () {
      expect(
        mergeLegacyKeywords(
          const ['康康看下|内置词'],
          const ['现有词'],
        ),
        ['现有词'],
      );
    });

    test('逐条 trim 并丢弃空串', () {
      expect(
        mergeLegacyKeywords(const ['  a  ', '', '   ', 'b'], const []),
        ['a', 'b'],
      );
    });

    test('幂等：连续合并两次结果不变', () {
      final once = mergeLegacyKeywords(const ['旧1', '旧2'], const ['新1']);
      final twice = mergeLegacyKeywords(const [], once);
      expect(twice, once);
    });

    test('不修改入参列表', () {
      final legacy = ['旧'];
      final current = ['新'];
      mergeLegacyKeywords(legacy, current);
      expect(legacy, ['旧']);
      expect(current, ['新']);
    });
  });

  group('CommentFilterConfig — 与继承相关的默认值', () {
    test('默认无屏蔽词（不预填内置词）', () {
      expect(const CommentFilterConfig().keywords, isEmpty);
    });

    test('copyWith 只改 keywords 不动其它字段', () {
      const base = CommentFilterConfig(
        enabled: false,
        onlyHiddenThread: true,
        boards: ['水区'],
      );
      final next = base.copyWith(keywords: const ['x']);
      expect(next.keywords, ['x']);
      expect(next.enabled, isFalse);
      expect(next.onlyHiddenThread, isTrue);
      expect(next.boards, ['水区']);
    });
  });

  group('CommentFilterConfig — 命中占位提示开关', () {
    test('默认不留占位（showBlockedPlaceholder = false）', () {
      expect(const CommentFilterConfig().showBlockedPlaceholder, isFalse);
    });

    test('copyWith 可以把开关打开，且不影响其它字段', () {
      const base = CommentFilterConfig(keywords: ['广告'], boards: ['水区']);
      final next = base.copyWith(showBlockedPlaceholder: true);
      expect(next.showBlockedPlaceholder, isTrue);
      expect(next.keywords, ['广告']);
      expect(next.boards, ['水区']);
      expect(next.enabled, isTrue);
    });

    test('copyWith 不传该参数时保持原值', () {
      const on = CommentFilterConfig(showBlockedPlaceholder: true);
      expect(on.copyWith(keywords: const ['x']).showBlockedPlaceholder, isTrue);
      const off = CommentFilterConfig();
      expect(
        off.copyWith(keywords: const ['x']).showBlockedPlaceholder,
        isFalse,
      );
    });

    test('toJson / fromJson 往返保留取值', () {
      for (final v in [true, false]) {
        final cfg = CommentFilterConfig(
          keywords: const ['广告'],
          showBlockedPlaceholder: v,
        );
        final back = CommentFilterConfig.fromJson(cfg.toJson());
        expect(back.showBlockedPlaceholder, v);
        expect(back.keywords, ['广告']);
      }
    });

    test('旧配置（JSON 里没有该键）按 false 解析', () {
      final back = CommentFilterConfig.fromJson(const {
        'enabled': true,
        'keywords': ['广告'],
      });
      expect(back.showBlockedPlaceholder, isFalse);
    });

    test('withoutTrigger() 不清掉占位开关（它是显示层字段）', () {
      const cfg = CommentFilterConfig(
        onlyHiddenThread: true,
        boards: ['水区'],
        showBlockedPlaceholder: true,
      );
      final stripped = cfg.withoutTrigger();
      expect(stripped.onlyHiddenThread, isFalse);
      expect(stripped.boards, isEmpty);
      expect(stripped.showBlockedPlaceholder, isTrue);
    });
  });

  group('filterOnlyOpAuthor — 只看楼主', () {
    PostItem p(String uid, {String pid = '', bool isOp = false}) =>
        PostItem(pid: pid, uid: uid, isOp: isOp);

    test('opUid 为空时原样返回（避免把整页筛成空白）', () {
      final posts = [p('1'), p('2')];
      expect(filterOnlyOpAuthor(posts, ''), posts);
      expect(filterOnlyOpAuthor(posts, '').length, 2);
    });

    test('只保留楼主 uid 的楼层', () {
      final posts = [p('100'), p('200'), p('100'), p('300')];
      final r = filterOnlyOpAuthor(posts, '100');
      expect(r.length, 2);
      expect(r.every((x) => x.uid == '100'), isTrue);
    });

    test('isOp 楼层永远保留（即使 uid 与 opUid 不一致）', () {
      // 兼容主帖 uid 解析缺失/被置空的边界：isOp 本身就是楼主标记
      final posts = [p('999', pid: 'a', isOp: true), p('100'), p('200')];
      final r = filterOnlyOpAuthor(posts, '100');
      expect(r.length, 2); // isOp 那条 + uid=100 那条
      expect(r.any((x) => x.isOp), isTrue);
    });

    test('没人匹配时返回空列表（页面走空态文案）', () {
      final posts = [p('200'), p('300')];
      expect(filterOnlyOpAuthor(posts, '100'), isEmpty);
    });

    test('不修改入参列表', () {
      final posts = [p('100'), p('200')];
      filterOnlyOpAuthor(posts, '100');
      expect(posts.length, 2);
    });

    test('空列表原样返回', () {
      expect(filterOnlyOpAuthor(const [], '100'), isEmpty);
    });
  });
}
