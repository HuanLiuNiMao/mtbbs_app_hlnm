import 'package:flutter_test/flutter_test.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/platform/optional/secure_store.dart';
import 'package:mtbbs/services/backup/backup_registry.dart';

/// 备份项声明表的回归测试。
///
/// 守住的四条不变量（都是「改了就会静默丢数据」的类型）：
/// 1. 每个叶子项都有 handler（`BackupRegistry.missing` 为空）；
/// 2. 枚举名唯一（改名 = 用户丢勾选状态）；
/// 3. 包内键名唯一（重名 = 后写的模块覆盖前一个）；
/// 4. `applyOrder` 覆盖全部叶子项，且被依赖项排在依赖方之前。
void main() {
  group('BackupCatalog', () {
    test('叶子项与 handler 一一对应', () {
      expect(BackupRegistry.missing, isEmpty);
      expect(
        BackupRegistry.keys,
        BackupCatalog.leaves.map((e) => e.payloadKey).toSet(),
      );
    });

    test('枚举名唯一', () {
      final names = BackupItemId.values.map((e) => e.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('包内键名唯一', () {
      final keys = BackupCatalog.leaves.map((e) => e.payloadKey!).toList();
      expect(keys.toSet().length, keys.length);
    });

    test('applyOrder 覆盖全部叶子且被依赖项在前', () {
      final leaves = BackupCatalog.leaves.map((e) => e.payloadKey!).toSet();
      expect(BackupCatalog.applyOrder.toSet(), leaves);
      for (final spec in BackupCatalog.leaves) {
        for (final dep in spec.requires) {
          final depKey = BackupCatalog.keyOf(dep);
          final key = spec.payloadKey!;
          expect(
            BackupCatalog.applyOrder.indexOf(depKey) <
                BackupCatalog.applyOrder.indexOf(key),
            isTrue,
            reason: '$key 依赖 $depKey，后者必须排在前面',
          );
        }
      }
    });

    test('分组父不产生 payload', () {
      final group = BackupCatalog.byId(BackupItemId.browseHistory);
      expect(group.isGroup, isTrue);
      expect(group.payloadKey, isNull);
      expect(BackupCatalog.childrenOf(BackupItemId.browseHistory).length, 2);
    });
  });

  group('BackupSelection', () {
    test('勾选依赖项时自动补依赖', () {
      final s = BackupSelection(const {}).toggled(BackupItemId.editorSnapshots);
      expect(s.contains(BackupItemId.editorSnapshots), isTrue);
      expect(s.contains(BackupItemId.editorSettings), isTrue);
    });

    test('取消被依赖项时级联取消依赖方', () {
      final full = BackupSelection({
        for (final e in BackupCatalog.leaves) e.id,
      });
      final s = full.toggled(BackupItemId.editorSettings);
      expect(s.contains(BackupItemId.editorSettings), isFalse);
      expect(s.contains(BackupItemId.editorSnapshots), isFalse);
    });

    test('分组全选 / 半选状态', () {
      final s = BackupSelection({
        BackupItemId.browseHistoryUser,
        BackupItemId.browseHistoryPost,
      });
      expect(s.groupFully(BackupItemId.browseHistory), isTrue);
      expect(s.groupPartial(BackupItemId.browseHistory), isFalse);

      final half = BackupSelection({BackupItemId.browseHistoryUser});
      expect(half.groupFully(BackupItemId.browseHistory), isFalse);
      expect(half.groupPartial(BackupItemId.browseHistory), isTrue);
    });

    test('toPayloadKeys 按 applyOrder 排序', () {
      final keys = BackupSelection({
        BackupItemId.accountCookies,
        BackupItemId.siteSettings,
        BackupItemId.shortcuts,
      }).toPayloadKeys();
      expect(keys, ['site_settings', 'shortcuts', 'account_cookies']);
    });

    test('反选 = 补集', () {
      final all = BackupSelection(const {}).all;
      expect(all.count, BackupCatalog.leaves.length);
      expect(all.inverted.count, 0);
    });
  });

  group('BackupSettings 持久化', () {
    test('空文档回落默认值', () {
      final s = BackupSettings.fromMap(null);
      expect(s.selected, BackupCatalog.defaults);
      expect(s.logKeepDays, 30);
      expect(s.webEnabled, isFalse);
    });

    test('未知枚举名被丢弃，已知名保留', () {
      final s = BackupSettings.fromMap({
        'selected': ['appSettings', 'notExist'],
      });
      expect(s.selected, {BackupItemId.appSettings});
    });

    test('空 selected 回落默认（不出现「一项都没勾」的死状态）', () {
      final s = BackupSettings.fromMap({'selected': <String>[]});
      expect(s.selected, BackupCatalog.defaults);
    });

    test('toMap / fromMap 往返一致', () {
      const src = BackupSettings(
        selected: {BackupItemId.appSettings, BackupItemId.siteSettings},
        webEnabled: true,
        web: WebBackupConfig(
          url: 'https://nas.local/backup',
          method: 'PUT',
          headerName: 'X-Api-Key',
          headerValue: 'secret',
          schedule: BackupSchedulePolicy(
            interval: 60,
            unit: BackupIntervalUnit.minutes,
          ),
          wifiOnly: true,
          includeLogs: true,
        ),
        logKeepDays: 7,
        lastBackupAt: '2026-11-01T10:00:00.000',
      );
      final back = BackupSettings.fromMap(src.toMap());
      expect(back.selected, src.selected);
      expect(back.webEnabled, isTrue);
      expect(back.web.method, 'PUT');
      expect(back.web.intervalMinutes, 60);
      expect(back.web.includeLogs, isTrue);
      expect(back.logKeepDays, 7);
      expect(back.lastBackupAt, src.lastBackupAt);
    });

    test('WebBackupConfig.usable 只认 http/https', () {
      const base = WebBackupConfig();
      expect(base.copyWith(url: 'https://nas.local/x').usable, isTrue);
      expect(base.copyWith(url: 'http://127.0.0.1:8080/x').usable, isTrue);
      expect(base.copyWith(url: 'ftp://nas.local/x').usable, isFalse);
      expect(base.copyWith(url: 'nas.local').usable, isFalse);
      expect(base.copyWith(url: '').usable, isFalse);
    });
    test('旧文档只有 intervalMinutes 时换算成 schedule（分钟）', () {
      final cfg = WebBackupConfig.fromMap({'url': 'https://a.b/c', 'intervalMinutes': 90});
      expect(cfg.schedule.interval, 90);
      expect(cfg.schedule.unit, BackupIntervalUnit.minutes);
      expect(cfg.scheduled, isTrue);
      expect(cfg.intervalMinutes, 90);
    });
    test('schedule 单位换算 / 0 表示关闭', () {
      const off = BackupSchedulePolicy();
      expect(off.enabled, isFalse);
      expect(off.intervalMinutes, 0);
      const weekly = BackupSchedulePolicy(
        interval: 1,
        unit: BackupIntervalUnit.weeks,
      );
      expect(weekly.intervalMinutes, 7 * 24 * 60);
      expect(weekly.enabled, isTrue);
      expect(weekly.label, '1 周');
    });
    test('加密模式下 headerValue 不写进设置文档', () {
      const cfg = WebBackupConfig(
        headerName: 'Authorization',
        headerValue: 'Bearer SECRET',
        secretMode: SecretStoreMode.secure,
      );
      expect(cfg.toMap()['headerValue'], '');
      expect(cfg.toMap()['secretMode'], 'secure');
    });
  });
}
