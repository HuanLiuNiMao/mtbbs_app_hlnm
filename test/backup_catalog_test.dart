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

    test('账号与 Cookie 是两个独立项，可各自单独勾选', () {
      // 从空集开始勾：只勾账号，不应把 Cookie 一起带上
      // （否则「只搬账号不搬凭据」这个诉求做不到）
      final onlyAccounts = const BackupSelection({})
          .toggled(BackupItemId.accountCookies);
      expect(onlyAccounts.contains(BackupItemId.accountCookies), isTrue);
      expect(onlyAccounts.contains(BackupItemId.cookies), isFalse);
      expect(
        onlyAccounts.contains(BackupItemId.siteSettings),
        isTrue,
        reason: 'requires 会级联带上站点设置',
      );

      // 反过来：只勾 Cookie，不应把账号列表一起带上
      final onlyCookies = const BackupSelection({})
          .toggled(BackupItemId.cookies);
      expect(onlyCookies.contains(BackupItemId.cookies), isTrue);
      expect(onlyCookies.contains(BackupItemId.accountCookies), isFalse);
      // 同样要带站点设置（否则没有 host → baseUrl 可查）
      expect(onlyCookies.contains(BackupItemId.siteSettings), isTrue);
    });

    test('Cookie 项是敏感的，账号列表不是', () {
      expect(BackupCatalog.byId(BackupItemId.cookies).sensitive, isTrue);
      expect(BackupCatalog.byId(BackupItemId.accountCookies).sensitive, isFalse);
    });

    test('cookies 排在 account_cookies 之后（导入顺序）', () {
      final order = BackupCatalog.applyOrder;
      expect(
        order.indexOf('account_cookies') < order.indexOf('cookies'),
        isTrue,
      );
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
    test('isDueAt：关闭时永不到期', () {
      const off = BackupSchedulePolicy();
      expect(off.isDueAt(DateTime(2026, 11, 8)), isFalse);
    });

    test('isDueAt：从未跑过立刻到期', () {
      const fresh = BackupSchedulePolicy(
        interval: 1,
        unit: BackupIntervalUnit.days,
      );
      expect(fresh.isDueAt(DateTime(2026, 11, 8)), isTrue);
    });

    test('isDueAt：未满一个周期不到期，满了才到期', () {
      final now = DateTime(2026, 11, 8, 12, 0);
      final schedule = BackupSchedulePolicy(
        interval: 1,
        unit: BackupIntervalUnit.days,
        lastRunAt: now.subtract(const Duration(hours: 23)).toIso8601String(),
      );
      expect(schedule.isDueAt(now), isFalse, reason: '差 1 小时未满一天');
      expect(
        schedule.copyWith(
          lastRunAt: now.subtract(const Duration(hours: 24)).toIso8601String(),
        ).isDueAt(now),
        isTrue,
      );
    });

    test('isDueAt：容忍 1 分钟抖动（59 分钟也算到期）', () {
      final now = DateTime(2026, 11, 8, 12, 0);
      final schedule = BackupSchedulePolicy(
        interval: 1,
        unit: BackupIntervalUnit.hours,
        lastRunAt: now.subtract(const Duration(minutes: 59)).toIso8601String(),
      );
      expect(
        schedule.isDueAt(now),
        isTrue,
        reason: '严格比较会让差 59 秒那次整体跳过一整轮',
      );
    });

    test('isDueAt：失败也算「跑过」（避免重试风暴）', () {
      final now = DateTime(2026, 11, 8, 12, 0);
      final schedule = BackupSchedulePolicy(
        interval: 1,
        unit: BackupIntervalUnit.hours,
        lastRunAt: now.subtract(const Duration(minutes: 10)).toIso8601String(),
        lastResult: 'failed: timeout',
      );
      expect(
        schedule.isDueAt(now),
        isFalse,
        reason: '上次失败但未到周期，不该立刻重试',
      );
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
    test('LocalBackupConfig 空文档回落默认（关闭 / 保留 5 份）', () {
      final c = LocalBackupConfig.fromMap(null);
      expect(c.enabled, isFalse);
      expect(c.keepCount, 5);
      expect(c.scheduled, isFalse);
      expect(c.lastFileName, '');
    });

    test('LocalBackupConfig.scheduled 需要开关与周期同时有效', () {
      const on = LocalBackupConfig(enabled: true);
      expect(on.scheduled, isFalse, reason: '只开开关、周期为 0 不算定时');
      final withSchedule = on.copyWith(
        schedule: const BackupSchedulePolicy(
          interval: 1,
          unit: BackupIntervalUnit.days,
        ),
      );
      expect(withSchedule.scheduled, isTrue);
      expect(
        withSchedule.copyWith(enabled: false).scheduled,
        isFalse,
        reason: '关掉开关后即便周期还在也不该跑',
      );
    });

    test('effectiveKeepCount 钳到 1..100，0 表示不清理', () {
      const base = LocalBackupConfig();
      expect(base.copyWith(keepCount: 0).effectiveKeepCount, 0);
      expect(base.copyWith(keepCount: -3).effectiveKeepCount, 0);
      expect(base.copyWith(keepCount: 5).effectiveKeepCount, 5);
      expect(base.copyWith(keepCount: 999).effectiveKeepCount, 100);
    });

    test('本地配置 toMap / fromMap 往返一致', () {
      const src = LocalBackupConfig(
        enabled: true,
        keepCount: 3,
        schedule: BackupSchedulePolicy(
          interval: 12,
          unit: BackupIntervalUnit.hours,
          requireCharging: true,
        ),
        lastRunAt: '2026-11-08T01:02:03.000',
        lastResult: 'ok',
        lastFileName: 'mtbbs_auto_20261108_010203.json',
      );
      final back = LocalBackupConfig.fromMap(src.toMap());
      expect(back.enabled, isTrue);
      expect(back.keepCount, 3);
      expect(back.schedule.intervalMinutes, 12 * 60);
      expect(back.schedule.requireCharging, isTrue);
      expect(back.lastFileName, src.lastFileName);
    });

    test('BackupSettings 缺 local 键时回默认（旧文档兼容）', () {
      final s = BackupSettings.fromMap({'webEnabled': true});
      expect(s.local.enabled, isFalse);
      expect(s.local.keepCount, 5);
    });

    test('BackupSettings 带 local 的往返一致', () {
      const src = BackupSettings(
        selected: {BackupItemId.cookies},
        local: LocalBackupConfig(enabled: true, keepCount: 8),
      );
      final back = BackupSettings.fromMap(src.toMap());
      expect(back.local.enabled, isTrue);
      expect(back.local.keepCount, 8);
      expect(back.selected, src.selected);
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
