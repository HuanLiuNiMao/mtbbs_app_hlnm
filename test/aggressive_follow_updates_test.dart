import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/settings/app_settings.dart';

/// 「激进跟随更新」的解析语义。
///
/// 核心命题只有一句：**用户存过值的开关不动，没存过的才跟随激进模式**。
/// 这一条同时保证了「不改旧设置」和「新增开关默认开」，两条要求都靠它。
void main() {
  group('boolOrNewFeature 三分支', () {
    test('键存在 → 用用户存的值（false 就是 false）', () {
      expect(
        boolOrNewFeature({'x': false}, 'x', fallback: true, aggressive: true),
        isFalse,
      );
    });

    test('键存在且为 true → true', () {
      expect(
        boolOrNewFeature({'x': true}, 'x', fallback: false, aggressive: false),
        isTrue,
      );
    });

    test('键缺失 + 激进开 → 默认开', () {
      expect(
        boolOrNewFeature({}, 'x', fallback: false, aggressive: true),
        isTrue,
      );
    });

    test('键缺失 + 激进关 → 用代码默认值', () {
      expect(
        boolOrNewFeature({}, 'x', fallback: false, aggressive: false),
        isFalse,
      );
    });

    test('键缺失 + 激进关闭 + 默认本就是开 → 仍旧开', () {
      expect(
        boolOrNewFeature({}, 'x', fallback: true, aggressive: false),
        isTrue,
      );
    });

    test('老版本存的字符串 "true" 不被当布尔值，按缺失处理', () {
      // JSON 文档跨多版本，值类型不可信；宁可当作新功能重问一次
      expect(
        boolOrNewFeature({'x': 'true'}, 'x', fallback: false, aggressive: true),
        isTrue,
      );
      expect(
        boolOrNewFeature(
          {'x': 'true'},
          'x',
          fallback: false,
          aggressive: false,
        ),
        isFalse,
      );
    });

    test('数字 1 / null 同样按缺失处理', () {
      expect(
        boolOrNewFeature({'x': 1}, 'x', fallback: false, aggressive: true),
        isTrue,
      );
      expect(
        boolOrNewFeature({'x': null}, 'x', fallback: false, aggressive: true),
        isTrue,
      );
    });
  });

  group('AppSettings.fromMap 接线', () {
    test('激进开 + 空文档 → 所有布尔开关都解析成 true', () {
      final s = AppSettings.fromMap({
        'advanced': {'aggressiveFollowUpdates': true},
      });
      // 这两个开关的代码默认值是 false，激进模式下应被抬成 true
      expect(s.appearance.pureBlackTheme, isTrue);
      expect(s.share.contentOnly, isTrue);
      // 这些本来就默认 true，激进模式不该把它们关掉
      expect(s.appearance.showAvatars, isTrue);
      expect(s.reading.autoDetectUrls, isTrue);
      expect(s.notice.checkEnabled, isTrue);
      expect(s.editor.editorStartupCheck, isTrue);
      expect(s.editor.toolbarShortcutWhenHidden, isTrue);
    });

    test('激进关 + 空文档 → 回到各自的代码默认值（含默认为 true 的）', () {
      final s = AppSettings.fromMap({
        'advanced': {'aggressiveFollowUpdates': false},
      });
      // 默认为 false 的两个开关
      expect(s.appearance.pureBlackTheme, isFalse);
      expect(s.share.contentOnly, isFalse);
      // 默认为 true —— 激进关不该把它们压成 false
      expect(s.appearance.showAvatars, isTrue);
      expect(s.startup.doubleBackExit, isTrue);
      expect(s.storage.threadCacheEnabled, isTrue);
      expect(s.notice.checkEnabled, isTrue);
      expect(s.reading.autoDetectUrls, isTrue);
      expect(s.editor.editorStartupCheck, isTrue);
    });

    test('激进开 + 用户存过的 false → 仍旧是 false（旧开关不动）', () {
      final s = AppSettings.fromMap({
        'advanced': {'aggressiveFollowUpdates': true},
        'appearance': {'pureBlackTheme': false, 'showAvatars': false},
        'startup': {'doubleBackExit': false},
      });
      expect(s.appearance.pureBlackTheme, isFalse);
      expect(s.appearance.showAvatars, isFalse);
      expect(s.startup.doubleBackExit, isFalse);
      // 同一个子文档里没存过的键仍然跟随激进模式
      // （AppearanceSettings 里 maxImageWidth 不是布尔，这里用别处验证）
    });

    test('只影响同层缺失键，不影响同子文档里已有的键', () {
      final s = AppSettings.fromMap({
        'advanced': {'aggressiveFollowUpdates': true},
        'editor': {'threadMiniEditor': false},
      });
      expect(s.editor.threadMiniEditor, isFalse);
      expect(s.editor.editorStartupCheck, isTrue);
      expect(s.editor.toolbarShortcutWhenHidden, isTrue);
    });

    test('aggressiveFollowUpdates 自身不会被激进模式感染', () {
      // 否则一旦打开就再也关不掉：文档里存 false，解析时又被抬成 true
      final s = AppSettings.fromMap({
        'advanced': {'aggressiveFollowUpdates': false},
      });
      expect(s.advanced.aggressiveFollowUpdates, isFalse);
    });

    test('advanced 子文档整个缺失时，按激进关处理（不会误开）', () {
      final s = AppSettings.fromMap({});
      expect(s.advanced.aggressiveFollowUpdates, isFalse);
      expect(s.appearance.pureBlackTheme, isFalse);
    });

    test('默认值本身是 false', () {
      expect(AdvancedSettings.defaults().aggressiveFollowUpdates, isFalse);
    });

    test('toMap / fromMap 往返保持', () {
      const advanced = AdvancedSettings(
        autoCheckUpdate: true,
        skippedUpdateVersion: '',
        lastUpdateCheckAt: 0,
        developerMode: false,
        aggressiveFollowUpdates: true,
      );
      final original = AppSettings.defaults().copyWith(advanced: advanced);
      final map = original.toMap();
      expect(map['advanced']['aggressiveFollowUpdates'], isTrue);
      final restored = AppSettings.fromMap(map);
      expect(restored.advanced.aggressiveFollowUpdates, isTrue);
    });
  });
}
