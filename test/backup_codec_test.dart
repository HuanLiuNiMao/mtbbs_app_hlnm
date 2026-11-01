import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/services/backup/backup_pack.dart';

/// 备份包编解码与向后兼容的回归测试。
void main() {
  BackupPack makePack(Map<String, dynamic> modules) => BackupPack(
    createdAt: DateTime(2026, 11, 1),
    appVersion: '26.10.26',
    appBuild: 2070,
    enabledItems: modules.keys.toSet(),
    modules: modules,
  );

  group('BackupCodec v2', () {
    test('encode / decode 往返', () {
      final pack = makePack({
        'app_settings': {
          'appearance': {'themeMode': 'dark'},
        },
        'shortcuts': {
          'hosts': {
            'bbs.binmt.cc': [
              {'name': 'A', 'url': 'https://a'},
            ],
          },
        },
      });
      final text = BackupCodec.encode(pack);
      final back = BackupCodec.decode(text);
      expect(back.packVersion, BackupPack.version);
      expect(back.modules.keys.toSet(), pack.modules.keys.toSet());
      expect(back.enabledItems, pack.enabledItems);
    });

    test('未知模块静默跳过，不中断', () {
      final doc = {
        'format': BackupPack.format,
        'version': 2,
        'createdAt': '2026-11-01T00:00:00.000',
        'modules': {
          'app_settings': {'a': 1},
          'future_module': {'b': 2},
        },
      };
      final pack = BackupCodec.decode(jsonEncode(doc));
      expect(pack.modules.keys, ['app_settings']);
    });

    test('版本高于本机 → 拒绝', () {
      final doc = {
        'format': BackupPack.format,
        'version': BackupPack.version + 1,
        'modules': <String, dynamic>{},
      };
      expect(
        () => BackupCodec.decode(jsonEncode(doc)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('缺 version → 拒绝', () {
      final doc = {'format': BackupPack.format, 'modules': <String, dynamic>{}};
      expect(
        () => BackupCodec.decode(jsonEncode(doc)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('不是 JSON / 不是备份文件 → BackupFormatException', () {
      expect(
        () => BackupCodec.decode('not json'),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupCodec.decode(jsonEncode({'format': 'other'})),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('缺 enabledItems 时按 modules 推断', () {
      final doc = {
        'format': BackupPack.format,
        'version': 2,
        'modules': {
          'app_settings': {'a': 1},
        },
      };
      final pack = BackupCodec.decode(jsonEncode(doc));
      expect(pack.enabledItems, {'app_settings'});
    });
  });

  group('旧格式兼容', () {
    test('mtbbs.settings → app_settings + site_settings', () {
      final doc = {
        'format': BackupCodec.legacySettingsFormat,
        'exportedAt': '2026-10-01T00:00:00.000',
        'app': {
          'appearance': {'themeMode': 'light'},
        },
        'sites': {
          'bbs.binmt.cc': {
            'network': {'referer': 'x'},
          },
        },
      };
      final pack = BackupCodec.decode(jsonEncode(doc));
      expect(pack.packVersion, 1);
      expect(pack.modules.keys.toSet(), {'app_settings', 'site_settings'});
      expect(pack.modules['site_settings']['bbs.binmt.cc'], isA<Map>());
    });

    test('mtbbs.cookies → account_cookies', () {
      final doc = {
        'format': BackupCodec.legacyCookiesFormat,
        'exportedAt': '2026-10-01T00:00:00.000',
        'hosts': ['bbs.binmt.cc'],
      };
      final pack = BackupCodec.decode(jsonEncode(doc));
      expect(pack.modules.keys, ['account_cookies']);
    });
  });

  group('detectKind', () {
    test('识别三种格式', () {
      expect(
        BackupCodec.detectKind(
          jsonEncode({'format': BackupPack.format, 'version': 2}),
        ),
        '备份包 v2',
      );
      expect(
        BackupCodec.detectKind(
          jsonEncode({'format': BackupCodec.legacySettingsFormat}),
        ),
        '旧版设置（v1）',
      );
      expect(
        BackupCodec.detectKind(
          jsonEncode({'format': BackupCodec.legacyCookiesFormat}),
        ),
        '旧版账号 Cookie（v1）',
      );
      expect(BackupCodec.detectKind('{}'), isNull);
    });
  });

  group('sortKeys / keyOf', () {
    test('未知键排最后且不丢', () {
      final sorted = BackupCatalog.sortKeys(['zzz', 'app_settings']);
      expect(sorted.first, 'app_settings');
      expect(sorted.last, 'zzz');
    });
  });
}
