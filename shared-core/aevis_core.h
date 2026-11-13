// Aevis 共享底层（C++17）
//
// 用户 2026-11-13：「安卓用它原生的加点 C++ 吧，底层用 C++，苹果应该也是底层用 C++」
// 所以两端 UI 各用官方原生（Android = Kotlin + Compose，iOS = SwiftUI），
// 但下面这些东西走同一份 C++：
//   · API 域名 / 版本号（一处改，两端都变）
//   · 积分千分位格式化（两端显示必须一模一样）
//   · 账号字符串归一化（去空格 + 小写）
//
// 约束：纯 C++17，不依赖平台头文件；对外只暴露 extern "C"，方便 JNI 和 ObjC++ 调。
#ifndef AEVIS_CORE_H
#define AEVIS_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/// 共享核心版本（不是 App 版本）。
const char* aevis_core_version(void);

/// 后端根地址（不带尾斜杠）。
const char* aevis_api_base(void);

/// 积分格式化：1234567 -> "1,234,567"。返回写入长度；缓冲区不够返回 -1。
int aevis_format_points(long long value, char* out, int cap);

/// 账号归一化：去首尾空白 + 转小写。返回写入长度；不够返回 -1。
int aevis_normalize_account(const char* in, char* out, int cap);

#ifdef __cplusplus
}
#endif

#endif  // AEVIS_CORE_H
