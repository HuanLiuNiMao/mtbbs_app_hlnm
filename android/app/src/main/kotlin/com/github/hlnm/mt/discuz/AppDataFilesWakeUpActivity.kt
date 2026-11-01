package com.github.hlnm.mt.discuz

import android.app.Activity
import android.os.Bundle

/**
 * 空 Activity，唯一用途是「把本应用进程拉起来」。
 *
 * 背景：provider（[AppDataFilesProvider]）跑在本应用进程里，进程被系统回收后
 * 第三方查询会拿到 "provider not found"。MT 管理器在查询前会先尝试启动这样一个
 * Activity 唤醒进程，因此这里保留一个空实现（与 MT 注入文件提供器时的做法一致）。
 *
 * 不显示任何界面、`onCreate` 里立刻 finish；manifest 里配了
 * `excludeFromRecents` + `noHistory`，不在最近任务里留痕。
 *
 * 该组件默认 `android:enabled="false"`，与 provider 一起由
 * [AppDataFilesBridge] 在开关打开时启用——否则任何应用都能凭空拉起我们的进程。
 */
class AppDataFilesWakeUpActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        finish()
    }
}
