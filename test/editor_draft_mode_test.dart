import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mtbbs/core/parser/page_fetcher.dart';
import 'package:mtbbs/models/editor_snapshot.dart';
import 'package:mtbbs/pages/editor/editor_submit.dart';
import 'package:mtbbs/providers/editor_history_provider.dart';
import 'package:mtbbs/widgets/bbcode/bbcode_controller.dart';

/// 纯编辑（草稿）模式 —— 用户需求：「不要依附于现有的板块，我只是想要一个编辑功能」。
///
/// 这条链路原来会把 `fid=''` 发给服务端，被回「指定的板块不存在」。
/// 这里锁定几个关键不变量：草稿不抓页面、不提交、session key 自成一组。
void main() {
  group('EditorType.draft 作为纯编辑模式', () {
    test('枚举里存在 draft，且与发帖区分开', () {
      expect(EditorType.values, contains(EditorType.draft));
      expect(EditorType.draft, isNot(EditorType.post));
    });

    test('generateKey 生成 draft_ 前缀的独立会话（每次进来都是新草稿）', () {
      final k1 = EditorHistoryProvider.generateKey(EditorType.draft);
      final k2 = EditorHistoryProvider.generateKey(EditorType.draft);
      expect(k1.startsWith('draft_'), isTrue);
      expect(k2.startsWith('draft_'), isTrue);
      // 时间戳 + 随机数，两次必然不同（否则多份草稿会互相覆盖）
      expect(k1, isNot(k2));
    });

    test('发帖 key 是 post_ 前缀，不会被当成草稿', () {
      final key = EditorHistoryProvider.generateKey(EditorType.post);
      expect(key.startsWith('post_'), isTrue);
      expect(key.startsWith('draft_'), isFalse);
    });
  });

  group('草稿模式不碰服务端', () {
    late BBCodeController contentCtl;
    late TextEditingController titleCtl;

    setUp(() {
      contentCtl = BBCodeController();
      titleCtl = TextEditingController();
    });

    tearDown(() {
      contentCtl.dispose();
      titleCtl.dispose();
    });

    EditorSubmitHelper helperFor(EditorType type) => EditorSubmitHelper(
      editorType: type,
      widgetFid: '',
      widgetTid: '',
      widgetPid: '',
      titleCtl: titleCtl,
      contentCtl: contentCtl,
      isEdit: false,
      isPost: false,
      isReply: false,
    );

    test('fetchPage 直接返回 success=true，不发网络请求', () async {
      // 若真的发请求，这里会因为没有网络/站点配置而抛异常或返回 failure。
      final data = await helperFor(EditorType.draft).fetchPage();
      expect(data.success, isTrue);
      expect(data.fid, isEmpty);
      expect(data.formhash, isEmpty);
    });

    test('fetchPage 不会把 fid 补成别的东西', () async {
      final data = await helperFor(EditorType.draft).fetchPage();
      expect(data.fid, '');
      expect(data.tid, '');
      expect(data.pid, '');
    });

    test('submit 在草稿模式下不发请求、直接失败并给出原因', () async {
      final result = await helperFor(
        EditorType.draft,
      ).submit(const PageFormData(success: true), '标题', '正文');
      expect(result.success, isFalse);
      expect(result.message, contains('纯编辑'));
    });

    test('submit 用空 fid 也不会走到 submitNewPost', () async {
      // 关键回归点：曾经这里会带着 fid='' 提交，服务端回「指定的板块不存在」。
      // 现在无论 pageData 怎么填，草稿都必须被拦住。
      final result = await helperFor(EditorType.draft).submit(
        const PageFormData(success: true, fid: '', tid: '', pid: ''),
        '标题',
        '正文',
      );
      expect(result.success, isFalse);
      expect(result.message, isNot(contains('板块不存在')));
    });
  });
}
