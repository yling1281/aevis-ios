//
//  Swift 侧访问共享 C++ 底层（shared-core/aevis_core.cpp）
//
//  用户 2026-11-13：「苹果应该也是底层用 C++」——
//  UI 继续用 SwiftUI 原生，域名 / 积分格式 / 账号归一化走同一份 C++，
//  保证跟安卓显示一模一样。
//

import Foundation

enum AevisCore {

    /// 共享核心版本（不是 App 版本）。
    static var version: String {
        String(cString: aevis_core_version())
    }

    /// 后端根地址（不带尾斜杠）。
    static var apiBase: String {
        String(cString: aevis_api_base())
    }

    /// 1234567 -> "1,234,567"（与安卓同一个实现）。
    static func points(_ value: Int) -> String {
        var buf = [CChar](repeating: 0, count: 40)
        let n = aevis_format_points(Int64(value), &buf, Int32(buf.count))
        guard n >= 0 else { return "0" }
        return String(cString: buf)
    }

    /// 去首尾空白 + 转小写。
    static func normalizeAccount(_ raw: String) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = raw.withCString { cs in
            aevis_normalize_account(cs, &buf, Int32(buf.count))
        }
        guard n >= 0 else { return raw }
        return String(cString: buf)
    }
}
