part of 'settings_provider.dart';

/// [SettingsProvider] 的备份/恢复设置写操作。
///
/// 勾选项与 Web 服务器配置都写进 `AppSettings.backup`（settings_app 文档），
/// 不新增 SharedPreferences（AGENTS.md 铁律 5）。
extension SettingsBackup on SettingsProvider {
  BackupSettings get backupSettings => _backup;

  /// 当前勾选项（UI 与服务层共用）
  BackupSelection get backupSelection => BackupSelection(_backup.selected);

  /// 勾选项变更（复选框每次点击都会调用，内部做去重判断）
  Future<void> setBackupSelection(Set<BackupItemId> ids) async {
    if (_sameIds(_backup.selected, ids)) return;
    _backup = _backup.copyWith(selected: Set.of(ids));
    await _persistApp();
    _notify();
  }

  Future<void> setBackupWebEnabled(bool value) async {
    if (_backup.webEnabled == value) return;
    _backup = _backup.copyWith(webEnabled: value);
    await _persistApp();
    _notify();
    // 开关直接影响「是否排定时任务」，必须同步一次调度
    await BackupScheduler.instance.sync(_backup);
  }

  /// 整份 Web 服务器配置（地址/方法/鉴权/间隔/仅 Wi-Fi/带日志）
  ///
  /// 会顺带同步系统调度：地址或周期变了要重排，关掉了要取消。
  Future<void> setWebBackupConfig(WebBackupConfig config) async {
    _backup = _backup.copyWith(web: config);
    await _persistApp();
    _notify();
    await BackupScheduler.instance.sync(_backup);
  }

  /// 定时策略变更（数值 / 单位 / 充电与电量约束）
  Future<void> setBackupSchedule(BackupSchedulePolicy schedule) =>
      setWebBackupConfig(_backup.web.copyWith(schedule: schedule));

  /// 切换鉴权头值的存储方式。
  ///
  /// 两个方向都要搬值，否则用户会看到「切到加密后上传 401」或
  /// 「切回明文后令牌变成空」：
  /// - plain → secure：把明文值写进密钥库，然后**清空**明文字段；
  /// - secure → plain：把密钥库里的值搬回明文字段（读不到就留空，让用户重填）。
  ///
  /// 返回是否成功。目标方式不可用（如鸿蒙无密钥库）时返回 false 且不改设置。
  Future<bool> setWebBackupSecretMode(SecretStoreMode mode) async {
    final web = _backup.web;
    if (web.secretMode == mode) return true;
    if (mode == SecretStoreMode.secure) {
      if (!SecretStore.available) return false;
      final plain = web.headerValue.trim();
      if (plain.isNotEmpty) {
        final ok = await SecretStore.write(BackupWebClient.secretKey, plain);
        if (!ok) return false;
      }
      await setWebBackupConfig(web.copyWith(secretMode: mode, headerValue: ''));
      return true;
    }
    // secure → plain
    final secret = await SecretStore.read(BackupWebClient.secretKey);
    await setWebBackupConfig(
      web.copyWith(secretMode: mode, headerValue: secret ?? ''),
    );
    // 明文里已经有一份了，密钥库里的可以删掉（避免两处并存分不清哪份生效）
    await SecretStore.delete(BackupWebClient.secretKey);
    return true;
  }

  /// 记录一次 Web 上传结果（lastRunAt / lastResult）
  Future<void> markWebBackupRun({
    required DateTime at,
    required String result,
  }) async {
    _backup = _backup.copyWith(
      web: _backup.web.copyWith(
        lastRunAt: at.toIso8601String(),
        lastResult: result,
        // 调度策略里也留一份：后台任务读的是 schedule.lastRunAt，
        // UI 读的是 web.lastRunAt，两处都写才能保证「上次执行」处处可见。
        schedule: _backup.web.schedule.copyWith(
          lastRunAt: at.toIso8601String(),
          lastResult: result,
        ),
      ),
    );
    await _persistApp();
    _notify();
  }

  /// 记录上次成功备份时间（任意来源）
  Future<void> markBackupDone(DateTime at) async {
    _backup = _backup.copyWith(lastBackupAt: at.toIso8601String());
    await _persistApp();
    _notify();
  }

  /// 运行日志保留天数（0 = 不保留）
  Future<void> setBackupLogKeepDays(int days) async {
    final next = days.clamp(0, 365);
    if (_backup.logKeepDays == next) return;
    _backup = _backup.copyWith(logKeepDays: next);
    await _persistApp();
    _notify();
  }

  /// 把备份设置同步给服务层（`BackupService` 不读 provider，避免循环依赖）。
  ///
  /// 两件事：日志保留天数、系统级定时调度的同步。
  /// 启动时 / 改设置后 / 导入设置后都要调用，否则调度器会拿旧配置跑。
  ///
  /// 注：不再需要「上传结果回写回调」——定时任务跑在 WorkManager 的
  /// **独立 isolate** 里，主 isolate 的闭包它根本拿不到；结果由后台
  /// 直接写 `settings_app` 文档，主 isolate 下次 `load()` 时自然读到。
  void applyBackupRuntimeConfig() {
    BackupService.instance.keepDays = _backup.logKeepDays;
    // 系统级调度是异步的，这里不阻塞（applyRuntimeConfig 是同步签名）
    unawaited(BackupScheduler.instance.sync(_backup));
  }

  static bool _sameIds(Set<BackupItemId> a, Set<BackupItemId> b) =>
      a.length == b.length && a.containsAll(b);
}