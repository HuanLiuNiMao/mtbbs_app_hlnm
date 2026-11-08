import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/core/utils/content_filter.dart';
import 'package:mtbbs/models/thread_detail.dart';

/// 评论屏蔽回归测试
///
/// 覆盖本轮改造的三件事：
/// 1. 屏蔽词两种触发方式（仅隐藏贴 / 分板块）的语义；
/// 2. 内置默认词表已删除（缺省不再预填任何词）；
/// 3. 「消息 → 我的帖子」用的单条 bbcode 判定与列表判定同口径。
void main() {
  PostItem post(String bbcode, {bool isOp = false}) =>
      PostItem(bbcode: bbcode, isOp: isOp);

  CommentFilterConfig cfg({
    bool enabled = true,
    bool onlyHiddenThread = false,
    bool modeBlock = true,
    List<String> boards = const [],
    List<String> keywords = const ['谢谢分享'],
  }) => CommentFilterConfig(
    enabled: enabled,
    onlyHiddenThread: onlyHiddenThread,
    modeBlock: modeBlock,
    boards: boards,
    keywords: keywords,
  );

  group('配置默认值', () {
    test('没有内置屏蔽词（内置词表已删除）', () {
      const f = CommentFilterConfig();
      expect(f.keywords, isEmpty);
      expect(f.isNoop, isTrue);
      expect(f.isGlobalTrigger, isTrue);
      expect(f.enabled, isTrue);
    });

    test('JSON 往返保持字段', () {
      final f = cfg(
        enabled: false,
        onlyHiddenThread: true,
        modeBlock: false,
        boards: ['水区'],
        keywords: ['111', 'aaa'],
      );
      final back = CommentFilterConfig.fromJson(f.toJson());
      expect(back.enabled, isFalse);
      expect(back.onlyHiddenThread, isTrue);
      expect(back.modeBlock, isFalse);
      expect(back.boards, ['水区']);
      expect(back.keywords, ['111', 'aaa']);
    });
  });

  group('触发方式 · 全局（不设置任何触发方式）', () {
    test('任何主题都应用屏蔽词', () {
      final f = cfg();
      expect(commentFilterApplies(f, boardName: '技术'), isTrue);
      expect(commentFilterApplies(f), isTrue);
      expect(filterPostItems([post('谢谢分享')], f, boardName: '技术'), isEmpty);
    });
  });

  group('触发方式 · 仅隐藏贴', () {
    test('隐藏贴才屏蔽', () {
      final f = cfg(onlyHiddenThread: true);
      expect(commentFilterApplies(f, isHiddenThread: true), isTrue);
      expect(commentFilterApplies(f, isHiddenThread: false), isFalse);
      expect(commentFilterApplies(f), isFalse); // 拿不到标记 → 不屏蔽
      expect(filterPostItems([post('谢谢分享')], f, isHiddenThread: true), isEmpty);
      expect(
        filterPostItems([post('谢谢分享')], f, isHiddenThread: false),
        hasLength(1),
      );
    });
  });

  group('触发方式 · 分板块', () {
    test('黑名单：名单内才屏蔽', () {
      final f = cfg(boards: ['水区'], modeBlock: true);
      expect(commentFilterApplies(f, boardName: '水区'), isTrue);
      expect(commentFilterApplies(f, boardName: '技术'), isFalse);
      expect(commentFilterApplies(f), isFalse);
    });

    test('白名单：名单外才屏蔽', () {
      final f = cfg(boards: ['技术'], modeBlock: false);
      expect(commentFilterApplies(f, boardName: '技术'), isFalse);
      expect(commentFilterApplies(f, boardName: '水区'), isTrue);
    });
  });

  group('两种触发方式是「或」关系', () {
    test('任一命中即生效', () {
      final f = cfg(onlyHiddenThread: true, boards: ['水区']);
      expect(
        commentFilterApplies(f, boardName: '技术', isHiddenThread: true),
        isTrue,
      );
      expect(
        commentFilterApplies(f, boardName: '水区', isHiddenThread: false),
        isTrue,
      );
      expect(
        commentFilterApplies(f, boardName: '技术', isHiddenThread: false),
        isFalse,
      );
    });
  });

  group('总开关关闭', () {
    test('任何情况都不过滤', () {
      final f = cfg(enabled: false);
      expect(
        commentFilterApplies(f, boardName: '水区', isHiddenThread: true),
        isFalse,
      );
      expect(
        filterPostItems([post('谢谢分享')], f, isHiddenThread: true),
        hasLength(1),
      );
    });
  });

  group('既有豁免规则保持不变', () {
    test('楼主帖不屏蔽', () {
      final f = cfg();
      expect(filterPostItems([post('谢谢分享', isOp: true)], f), hasLength(1));
    });

    test('回复别人的楼层不屏蔽', () {
      final f = cfg();
      final code = '[quote]引用某人的话[/quote]谢谢分享';
      expect(filterPostItems([post(code)], f), hasLength(1));
    });

    test('引用块是「回复可见」提示时，仍按正常规则屏蔽', () {
      final f = cfg();
      final code = '[quote]查看本帖隐藏内容[/quote]谢谢分享';
      expect(filterPostItems([post(code)], f), isEmpty);
    });

    test('超长正文不屏蔽', () {
      final f = cfg();
      expect(
        filterPostItems([post('谢谢分享，这是一条足够长的正常回复内容超过十个字')], f),
        hasLength(1),
      );
    });

    test('纯 ASCII 短评直接屏蔽（灌水特征）', () {
      final f = cfg(keywords: const []);
      expect(filterPostItems([post('aaaa')], f), hasLength(1)); // 无词 → 不过滤
      final f2 = cfg(keywords: const ['zzz']);
      expect(filterPostItems([post('aaaa')], f2), isEmpty);
    });
  });

  group('单条 bbcode 判定（消息预览用）', () {
    test('与列表判定同口径', () {
      final f = cfg();
      expect(shouldBlockCommentBbcode('谢谢分享', f), isTrue);
      expect(shouldBlockCommentBbcode('谢谢分享，这是一条足够长的正常回复内容超过十个字', f), isFalse);
      expect(shouldBlockCommentBbcode('', f), isFalse);
    });

    test('触发方式设置后，拿不到上下文时保守不屏蔽', () {
      final f = cfg(onlyHiddenThread: true);
      expect(shouldBlockCommentBbcode('谢谢分享', f), isFalse);
      expect(shouldBlockCommentBbcode('谢谢分享', f, isHiddenThread: true), isTrue);

      final g = cfg(boards: ['水区']);
      expect(shouldBlockCommentBbcode('谢谢分享', g), isFalse);
      expect(shouldBlockCommentBbcode('谢谢分享', g, boardName: '水区'), isTrue);
      expect(shouldBlockCommentBbcode('谢谢分享', g, boardName: '技术'), isFalse);
    });

    test('withoutTrigger：消息页这类拿不到上下文的调用点仍按屏蔽词过滤', () {
      final f = cfg(onlyHiddenThread: true, boards: ['水区']);
      // 原样判定：触发条件拿不到上下文 → 不屏蔽
      expect(shouldBlockCommentBbcode('谢谢分享', f), isFalse);
      // 去掉触发方式后：按「全局生效」语义，屏蔽词照常命中
      expect(shouldBlockCommentBbcode('谢谢分享', f.withoutTrigger()), isTrue);
      // 开关关闭时仍不屏蔽（withoutTrigger 不动 enabled）
      final off = cfg(enabled: false, onlyHiddenThread: true);
      expect(shouldBlockCommentBbcode('谢谢分享', off.withoutTrigger()), isFalse);
      // 没有屏蔽词时也不屏蔽
      expect(
        shouldBlockCommentBbcode(
          'aaaa',
          cfg(keywords: const []).withoutTrigger(),
        ),
        isFalse,
      );
    });

    test('无屏蔽词时永不禁言', () {
      final f = cfg(keywords: const []);
      expect(shouldBlockCommentBbcode('aaaa', f), isFalse);
    });
  });

  group('我的帖子提醒：整条隐藏', () {
    test('默认（不保留提示）命中即整条隐藏', () {
      final f = cfg();
      expect(isMypostEntryBlocked('谢谢分享', f), isTrue);
      expect(shouldHideMypostEntry('谢谢分享', f), isTrue);
    });

    test('打开「命中后保留提示」→ 不隐藏（改为渲染一行提示）', () {
      final f = cfg().copyWith(showBlockedPlaceholder: true);
      expect(isMypostEntryBlocked('谢谢分享', f), isTrue);
      expect(shouldHideMypostEntry('谢谢分享', f), isFalse);
    });

    test('预览未到 / 为空时不动（不隐藏）', () {
      final f = cfg();
      expect(isMypostEntryBlocked(null, f), isFalse);
      expect(isMypostEntryBlocked('', f), isFalse);
      expect(shouldHideMypostEntry(null, f), isFalse);
    });

    test('未命中屏蔽词不隐藏', () {
      final f = cfg();
      expect(isMypostEntryBlocked('谢谢分享，这是一条足够长的正常回复内容', f), isFalse);
      expect(shouldHideMypostEntry('这是一条正常回复', f), isFalse);
    });

    test('触发方式不参与判定（消息页拿不到板块/隐藏贴）', () {
      final f = cfg(onlyHiddenThread: true, boards: ['水区']);
      // 原样判定会因拿不到上下文而不屏蔽
      expect(shouldBlockCommentBbcode('谢谢分享', f), isFalse);
      // 提醒条目按「全局生效」判定 → 照常隐藏
      expect(shouldHideMypostEntry('谢谢分享', f), isTrue);
    });

    test('总开关关闭 / 无屏蔽词时不隐藏', () {
      expect(shouldHideMypostEntry('谢谢分享', cfg(enabled: false)), isFalse);
      expect(
        shouldHideMypostEntry('谢谢分享', cfg(keywords: const [])),
        isFalse,
      );
    });

    test('「回复别人」的引用楼层不隐藏', () {
      final f = cfg();
      expect(shouldHideMypostEntry('[quote]引用某人的话[/quote]谢谢分享', f), isFalse);
    });
  });

  group('隐藏贴判据', () {
    test('未回复的 locked 占位算隐藏贴', () {
      const code =
          '[appdata]{"type":"locked","message":"🔒 请回复可见"}[/appdata]\n';
      expect(isHiddenThreadBbcode(code), isTrue);
    });

    test('[hide] 块算隐藏贴', () {
      expect(isHiddenThreadBbcode('[hide]正文[/hide]'), isTrue);
      expect(isHiddenThreadBbcode('[hide=1]正文[/hide]'), isTrue);
    });

    test('普通帖子不算隐藏贴', () {
      expect(isHiddenThreadBbcode('就是一段普通正文'), isFalse);
      expect(isHiddenThreadBbcode(''), isFalse);
    });
  });
}
