import 'dart:convert';
import 'dart:ui';

import 'package:mtbbs/config/site_config.dart';
import 'package:mtbbs/core/app/app_capabilities.dart';
import 'package:mtbbs/core/app/site_store.dart';
import 'package:mtbbs/core/settings/settings_repository.dart';
import 'package:mtbbs/core/utils/database_helper.dart';
import 'package:mtbbs/core/utils/logger.dart';
import 'package:mtbbs/models/backup/backup_item.dart';
import 'package:mtbbs/models/settings/backup_settings.dart';
import 'package:mtbbs/services/backup/backup_service.dart';
import 'package:mtbbs/services/backup/backup_web_client.dart';
import 'package:mtbbs/services/backup/backup_settings_store.dart';
import 'package:workmanager/workmanager.dart';

/// 后台任务的 taskName（传给 `executeTask` 的值，用于区分本应用注册的多个任务）
const String kBackupTaskName = 'mtbbs.backup.upload';

/// 周期任务的 uniqueName（同名任务只会存在一个，改配置时按此名更新）
const String kBackupPeriodicUniqueName = 'mtbbs.backup.periodic';

/// 周期任务 tag（便于将来按 tag 批量取消）
const String kBackupTaskTag = 'mtbbs.backup';

/// 后台回调入口 —— **必须是顶层函数**，且标 `@pragma('vm:entry-point')`。
///
/// AOT 编译会按调用图裁剪未引用代码，后台 isolate 的入口不在主 isolate
/// 的调用图里，没有这个注解会被裁掉，表现为「任务注册成功但永远不执行」。
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    // 后台 isolate 是全新堆，插件通道需要显式注册一层
    // （Flutter 3.7+ 的 DartPluginRegistrant 负责把原生插件接到这个 isolate）。
    DartPluginRegistrant.ensureInitialized();
    if (taskName != kBackupTaskName) {
      // 不是本模块的任务：仍要返回 true，否则系统会按失败重试别人的任务
      AppLogger.w('BACKUP', '后台任务 $taskName 不属于备份模块，忽略');
      return true;
    }
    try {
      return await runScheduledBackup();
    } catch (e, st) {
      AppLogger.e('BACKUP', '后台备份异常: $e\n$st');
      // 返回 true：把失败交给应用层日志与 UI 提示，不让系统按退避策略
      // 无限重试（用户服务器挂掉时，重试风暴只会更糟）。
      return true;
    }
  });
}

/// 在后台 isolate 里执行一次「导出 + 上传」。
///
/// 关键点：后台 isolate **没有**主 isolate 的内存状态——
/// `SettingsProvider._backup`、`SiteStore._sites` 都是默认值/空列表。
/// 因此这里必须：
/// 1. 从 `DatabaseHelper` 读站点列表（`app_sites` KV），填 `SiteStore`；
/// 2. `SettingsRepository.instance.loadAll(hosts)` 把应用设置读进内存；
/// 3. 从 `BackupSettingsStore` 读到的备份配置判断是否该跑、跑哪些项。
///
/// 全部读盘完成后再做网络请求，期间不碰任何 UI 对象。
/// 返回 true 表示「本次任务已正常处理」（含「按配置跳过」），
/// 只有真正需要系统重试的错误才返回 false——见上面的调用点。
Future<bool> runScheduledBackup() async {
  final sites = await _loadSites();
  final hosts = [for (final s in sites) s.host];
  await SettingsRepository.instance.loadAll(hosts);

  final backup = await BackupSettingsStore.instance.load();
  final web = backup.web;

  if (!backup.webEnabled || !web.usable || !web.scheduled) {
    AppLogger.i('BACKUP', '后台备份跳过：Web 备份未启用 / 地址无效 / 未开定时');
    return true;
  }
  if (backup.selected.isEmpty) {
    AppLogger.w('BACKUP', '后台备份跳过：没有勾选任何备份项');
    return true;
  }

  final startedAt = DateTime.now();
  // 收集器依赖 `BackupContext.current()`，它会读 `SiteStore.instance.sites`。
  // 后台 isolate 里 SiteStore 是空的，必须先填，否则「按站点遍历」的项全是 0 条。
  SiteStore.instance.replaceSites(sites);
  BackupService.instance.keepDays = backup.logKeepDays;

  String detail = '';
  var ok = false;
  try {
    final result = await BackupService.instance.exportToJson(
      BackupSelection(backup.selected),
      trigger: 'scheduled',
      includeLogs: web.includeLogs,
    );
    final upload = await BackupWebClient.instance.upload(result.json, web);
    ok = upload.ok;
    detail = upload.ok
        ? 'HTTP ${upload.statusCode ?? 200}'
        : upload.message;
    AppLogger.i(
      'BACKUP',
      '后台备份${ok ? '成功' : '失败'}：$detail'
          '（${result.totalCount} 条 / ${result.durationMs}ms）',
    );
  } catch (e) {
    detail = e.toString();
    AppLogger.e('BACKUP', '后台备份失败: $e');
  }

  await _writeBackRunResult(at: startedAt, ok: ok, detail: detail);
  return true;
}

/// 把本次结果写回设置文档（后台 isolate 只能落库，主 isolate 下次读取才可见）
Future<void> _writeBackRunResult({
  required DateTime at,
  required bool ok,
  required String detail,
}) async {
  final iso = at.toIso8601String();
  final result = ok ? 'ok' : 'failed: $detail';
  try {
    // 备份配置已迁到独立 KV 键，不再经过 `AppSettings`。
    await BackupSettingsStore.instance.update((cur) {
      final web = cur.web;
      return cur.copyWith(
        // Web 配置与调度策略里各留一份：UI 读前者，后台任务读后者，
        // 两处同源写入，避免出现「页面显示上次时间、实际判断用另一个字段」。
        web: web.copyWith(
          lastRunAt: iso,
          lastResult: result,
          schedule: web.schedule.copyWith(
            lastRunAt: iso,
            lastResult: result,
          ),
        ),
        lastBackupAt: ok ? iso : cur.lastBackupAt,
      );
    });
  } catch (e) {
    AppLogger.w('BACKUP', '回写后台备份结果失败: $e');
  }
}

/// 读站点列表（后台 isolate 专用）。
///
/// 只做一件事：把 `app_sites` 里的 JSON 解析成 `List<Site>`。
/// 解析失败 / 首次运行时回退内置默认站点——备份依旧可跑，
/// 只是「按站点遍历」的项会落到默认站点上。
Future<List<Site>> _loadSites() async {
  try {
    final raw = await DatabaseHelper.instance.getSitesRaw();
    if (raw != null && raw.isNotEmpty) {
      final list = jsonDecode(raw) as List<dynamic>;
      final sites = list
          .map((j) => Site.fromJson(j as Map<String, dynamic>))
          .toList();
      if (sites.isNotEmpty) return sites;
    }
  } catch (e) {
    AppLogger.w('BACKUP', '后台读取站点列表失败，回退默认站点: $e');
  }
  return SiteConfig.defaultSites();
}

/// Web 定时备份的系统级调度器。
///
/// 为什么用 WorkManager 而不是 `Timer.periodic`：
/// 用户要的是「一周备份一次」——Timer 只在 App 进程存活时走，手机重启/
/// 清理后台之后就不再执行，等于没有。WorkManager 把周期任务注册进系统
/// 的 JobScheduler，**App 不在前台、进程被杀也会被系统唤起**。
///
/// 代价与限制（已在 UI 文案里写明，不做虚假承诺）：
/// - Android 周期任务最小 15 分钟，且系统会做省电合并，实际触发时间可能
///   比设定值晚（Doze / App Standby）。「一周一次」通常会在那一周的
///   某个合适时机执行，而不是精确到秒；
/// - 鸿蒙没有 workmanager 实现 → [AppCapability.backgroundTask] 为 false，
///   定时入口隐藏，手动上传不受影响；
/// - iOS 的周期任务由系统按用户使用习惯决定，可能长时间不跑。
class BackupScheduler {
  BackupScheduler._();

  static final BackupScheduler instance = BackupScheduler._();

  /// `initialize` 是否已完成（重复调用会抛异常，必须幂等）
  bool _initialized = false;

  /// 当前已注册的周期（分钟）；0 = 未注册
  ///
  /// 用于判断「配置没变就别重复 register」——WorkManager 的 register
  /// 在 `update` 策略下会写数据库并可能重置下一次执行时间，
  /// 用户每点一次开关都重排一次并不合适。
  int _registeredMinutes = 0;

  /// 上次注册时用的约束指纹（周期不变但约束变了也要重注册）
  String _registeredConstraints = '';

  bool get isSupported =>
      AppCapabilities.isAvailable(AppCapability.backgroundTask);

  /// 启动时调用一次（`main` 里）。可重复调用。
  Future<void> init() async {
    if (!isSupported) {
      AppLogger.i('BACKUP', '当前平台无后台任务能力，跳过 WorkManager 初始化');
      return;
    }
    if (_initialized) return;
    try {
      await Workmanager().initialize(backupCallbackDispatcher);
      _initialized = true;
      AppLogger.i('BACKUP', 'WorkManager 已初始化');
    } catch (e) {
      // 典型：鸿蒙 / 桌面 / 插件未注册。关掉能力位，UI 隐藏定时入口。
      AppLogger.w('BACKUP', 'WorkManager 初始化失败，关闭后台备份能力: $e');
      AppCapabilities.disable(AppCapability.backgroundTask);
    }
  }

  /// 按当前设置同步调度状态。**幂等**，可在设置变更后任意次调用。
  ///
  /// - 关掉定时 / 地址无效 / Web 未启用 → 取消已注册任务；
  /// - 周期与约束都没变 → 什么都不做（避免无谓重排）；
  /// - 其它情况 → 重新注册（`ExistingPeriodicWorkPolicy.update`，
  ///   原地改间隔，不打断正在跑的那次）。
  Future<void> sync(BackupSettings settings) async {
    if (!isSupported) return;
    await init();
    if (!isSupported) return;

    final web = settings.web;
    final on = settings.webEnabled && web.usable && web.scheduled;
    if (!on) {
      await cancel();
      return;
    }
    final minutes = _effectiveMinutes(web.schedule);
    final constraints = _constraintKey(web);
    if (_registeredMinutes == minutes && _registeredConstraints == constraints) {
      // 配置没变：只更新一下内存里的最近结果，不重排任务
      AppLogger.i('BACKUP', '定时备份配置未变化（每 $minutes 分钟），跳过重注册');
      return;
    }
    await _register(web: web, minutes: minutes);
  }

  /// 取消已注册的周期任务（关掉定时 / 退出登录后清理时调用）
  Future<void> cancel() async {
    if (!isSupported || !_initialized) {
      _registeredMinutes = 0;
      _registeredConstraints = '';
      return;
    }
    try {
      await Workmanager().cancelByUniqueName(kBackupPeriodicUniqueName);
      if (_registeredMinutes != 0) {
        AppLogger.i('BACKUP', '已取消定时备份任务');
      }
    } catch (e) {
      AppLogger.w('BACKUP', '取消定时备份任务失败: $e');
    } finally {
      _registeredMinutes = 0;
      _registeredConstraints = '';
    }
  }

  /// 调试用：立刻排一次一次性任务（不受周期限制），验证链路是否通。
  Future<bool> runNow(WebBackupConfig web) async {
    if (!isSupported) return false;
    await init();
    if (!isSupported) return false;
    try {
      await Workmanager().registerOneOffTask(
        '$kBackupPeriodicUniqueName.manual',
        kBackupTaskName,
        constraints: _constraintsOf(web),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        tag: kBackupTaskTag,
      );
      AppLogger.i('BACKUP', '已排入一次性后台备份任务');
      return true;
    } catch (e) {
      AppLogger.w('BACKUP', '排入一次性后台备份失败: $e');
      return false;
    }
  }

  // ==================== 内部 ====================

  Future<void> _register({
    required WebBackupConfig web,
    required int minutes,
  }) async {
    try {
      await Workmanager().registerPeriodicTask(
        kBackupPeriodicUniqueName,
        kBackupTaskName,
        frequency: Duration(minutes: minutes),
        constraints: _constraintsOf(web),
        // update：Android 推荐值。已有同名任务时原地改参数，
        // 不会像 replace 那样把正在运行的那次掐掉。
        existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        // 失败退避：指数增长，首次 15 分钟起。周期任务本身会按 frequency
        // 重跑，退避主要用于「系统提前终止」这类场景的补偿。
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 15),
        tag: kBackupTaskTag,
      );
      _registeredMinutes = minutes;
      _registeredConstraints = _constraintKey(web);
      AppLogger.i(
        'BACKUP',
        '定时备份已注册：每 $minutes 分钟'
            '${web.wifiOnly ? ' · 仅 Wi-Fi' : ''}'
            '${web.schedule.requireCharging ? ' · 需充电' : ''}'
            '${web.schedule.requireBatteryNotLow ? ' · 电量不低' : ''}',
      );
    } catch (e) {
      AppLogger.w('BACKUP', '注册定时备份失败: $e');
    }
  }

  /// WorkManager 的周期下限是 15 分钟（Android 硬限制），小于它系统会自动抬到 15。
  ///
  /// 这里主动做同样的钳制，让「日志里写的周期」= 「系统实际周期」。
  int _effectiveMinutes(BackupSchedulePolicy schedule) {
    final m = schedule.intervalMinutes;
    return m < 15 ? 15 : m;
  }

  Constraints _constraintsOf(WebBackupConfig web) => Constraints(
    // 仅 Wi-Fi → unmetered；否则只要有网就行
    networkType: web.wifiOnly ? NetworkType.unmetered : NetworkType.connected,
    requiresCharging: web.schedule.requireCharging,
    requiresBatteryNotLow: web.schedule.requireBatteryNotLow,
  );

  String _constraintKey(WebBackupConfig web) =>
      '${web.wifiOnly}|${web.schedule.requireCharging}|'
      '${web.schedule.requireBatteryNotLow}';

  /// 测试用：清掉内存状态（不取消系统任务）
  void resetForTest() {
    _initialized = false;
    _registeredMinutes = 0;
    _registeredConstraints = '';
  }
}
