import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/settings/app_settings.dart';

void main() {
  group('EditorSettings \u60ac\u6d6e\u7a97\u5b57\u6bb5', () {
    test(
      '\u9ed8\u8ba4\u503c\uff1a\u5173\u95ed / \u5168\u5e94\u7528 / 52dp / 3 \u79d2',
      () {
        final d = EditorSettings.defaults();
        expect(d.editorFabEnabled, isFalse);
        expect(d.editorFabBrowserOnly, isFalse);
        expect(d.editorFabSize, 52);
        expect(d.editorFabSnapSeconds, 3);
      },
    );

    test(
      '\u8001\u6587\u6863\u6ca1\u6709\u8fd9\u4e9b\u952e\u65f6\u7528\u9ed8\u8ba4\u503c',
      () {
        final r = EditorSettings.fromMap(const {});
        expect(r.editorFabEnabled, isFalse);
        expect(r.editorFabBrowserOnly, isFalse);
        expect(r.editorFabSize, 52);
        expect(r.editorFabSnapSeconds, 3);
      },
    );

    test('toMap / fromMap \u5f80\u8fd4\u4e00\u81f4', () {
      const s = EditorSettings(
        threadMiniEditor: false,
        editorStartupCheck: false,
        toolbarShortcutWhenHidden: false,
        quickReplies: [],
        toolbarItems: [],
        customFormats: [],
        formatPresets: [],
        shortcuts: {},
        toolbarShortcuts: {},
        minSnapshotWordCount: 20,
        autoSaveInterval: 60,
        maxAutoSnapshots: 5,
        editorFabEnabled: true,
        editorFabBrowserOnly: true,
        editorFabSize: 64,
        editorFabSnapSeconds: 8,
      );
      final r = EditorSettings.fromMap(s.toMap());
      expect(r.editorFabEnabled, isTrue);
      expect(r.editorFabBrowserOnly, isTrue);
      expect(r.editorFabSize, 64);
      expect(r.editorFabSnapSeconds, 8);
    });

    group('\u8fb9\u957f\u94b3\u4f4d', () {
      test('\u8fc7\u5c0f\u94b3\u5230 36', () {
        expect(
          EditorSettings.editorFabSizeValue(10, 52),
          EditorSettings.minEditorFabSize,
        );
      });

      test('\u8fc7\u5927\u94b3\u5230 72', () {
        expect(
          EditorSettings.editorFabSizeValue(500, 52),
          EditorSettings.maxEditorFabSize,
        );
      });

      test('\u533a\u95f4\u5185\u539f\u6837\u8fd4\u56de', () {
        expect(EditorSettings.editorFabSizeValue(48, 52), 48);
      });

      test('\u975e\u6570\u503c\u56de fallback', () {
        expect(EditorSettings.editorFabSizeValue('48', 52), 52);
        expect(EditorSettings.editorFabSizeValue(null, 52), 52);
        expect(EditorSettings.editorFabSizeValue(<String, dynamic>{}, 52), 52);
      });

      test('int \u4e5f\u80fd\u63a5\u53d7', () {
        expect(EditorSettings.editorFabSizeValue(60, 52), 60.0);
      });
    });

    test('\u8d34\u8fb9\u79d2\u6570\u94b3\u5230 0\u201330', () {
      expect(
        EditorSettings.fromMap(const {
          'editorFabSnapSeconds': -5,
        }).editorFabSnapSeconds,
        0,
      );
      expect(
        EditorSettings.fromMap(const {
          'editorFabSnapSeconds': 999,
        }).editorFabSnapSeconds,
        EditorSettings.maxEditorFabSnapSeconds,
      );
    });

    test('\u8d34\u8fb9\u79d2\u6570\u5e26\u5c0f\u6570\u65f6\u53d6\u6574', () {
      expect(
        EditorSettings.fromMap(const {
          'editorFabSnapSeconds': 7.9,
        }).editorFabSnapSeconds,
        7,
      );
    });

    test('\u8d34\u8fb9\u79d2\u6570\u975e\u6570\u503c\u56de\u9ed8\u8ba4', () {
      expect(
        EditorSettings.fromMap(const {
          'editorFabSnapSeconds': 'abc',
        }).editorFabSnapSeconds,
        3,
      );
    });

    group('\u6fc0\u8fdb\u8ddf\u968f\u66f4\u65b0', () {
      test(
        '\u6fc0\u8fdb\u5f00 + \u7a7a\u6587\u6863 \u2192 \u60ac\u6d6e\u7a97\u5f00\u5173\u88ab\u62ac\u6210 true',
        () {
          final r = EditorSettings.fromMap(const {}, aggressive: true);
          expect(r.editorFabEnabled, isTrue);
          expect(r.editorFabBrowserOnly, isTrue);
        },
      );

      test(
        '\u6fc0\u8fdb\u5f00\u4f46\u7528\u6237\u5df2\u5173 \u2192 \u4e0d\u88ab\u8986\u76d6',
        () {
          final r = EditorSettings.fromMap(const {
            'editorFabEnabled': false,
          }, aggressive: true);
          expect(r.editorFabEnabled, isFalse);
        },
      );

      test(
        '\u6fc0\u8fdb\u5f00\u4e0d\u5f71\u54cd\u6570\u503c\u7c7b\u5b57\u6bb5',
        () {
          final r = EditorSettings.fromMap(const {}, aggressive: true);
          expect(r.editorFabSize, 52);
          expect(r.editorFabSnapSeconds, 3);
        },
      );
    });
  });

  group('\u6574\u4f53 AppSettings \u4f20\u9012\u6fc0\u8fdb\u5f00\u5173', () {
    test(
      'aggressiveFollowUpdates \u4ece advanced \u5b50\u6587\u6863\u8bfb\u5230\u5e76\u4f5c\u7528\u5230 editor',
      () {
        final a = AppSettings.fromMap(const {
          'advanced': {'aggressiveFollowUpdates': true},
        });
        expect(a.advanced.aggressiveFollowUpdates, isTrue);
        expect(a.editor.editorFabEnabled, isTrue);
      },
    );

    test('\u9ed8\u8ba4\u4e0d\u6fc0\u8fdb', () {
      final a = AppSettings.fromMap(const {});
      expect(a.advanced.aggressiveFollowUpdates, isFalse);
      expect(a.editor.editorFabEnabled, isFalse);
    });
  });
}
