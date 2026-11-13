package com.aevis.android.core

/**
 * 共享 C++ 底层（`shared-core/aevis_core.cpp`）。
 *
 * 用户 2026-11-13：「安卓用它原生的加点 C++，底层用 C++，苹果也是」——
 * UI 各用官方原生（Kotlin/Compose、SwiftUI），域名 / 积分格式 / 账号归一化
 * 走同一份 C++，保证两端显示和口径完全一致。
 */
object NativeCore {

    init {
        System.loadLibrary("aevis")
    }

    /** 共享核心版本（不是 App 版本）。 */
    external fun version(): String

    /** 后端根地址（不带尾斜杠）。 */
    external fun apiBase(): String

    /** 1234567 -> "1,234,567" */
    external fun formatPoints(value: Long): String

    /** 去首尾空白 + 转小写。 */
    external fun normalizeAccount(raw: String): String

    /** Kotlin 侧兜底：C++ 库没编进来时也别让页面崩。 */
    fun formatPointsSafe(value: Long?): String {
        val v = value ?: return "—"
        return try { formatPoints(v) } catch (t: Throwable) { v.toString() }
    }
}
