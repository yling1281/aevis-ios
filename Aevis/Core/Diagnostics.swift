import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Darwin)
import Darwin
#endif

/// 环境自检：M0 阶段用来验证「装到手机上到底能不能跑、跑成什么样」。
enum Diagnostics {

    static var osVersion: String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return "-"
        #endif
    }

    /// 硬件代号，例如 iPhone15,3 对应 iPhone 14 Pro Max。
    static var machine: String {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown"
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return "unknown" }
            return String(cString: base)
        }
        #else
        return "unknown"
        #endif
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var commit: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AevisCommit") as? String ?? "dev"
        return raw.count > 7 ? String(raw.prefix(7)) : raw
    }

    /// 是否带有描述文件（说明已经被签过名）。
    static var isSigned: Bool {
        Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    }

    /// 当前系统是否支持 iOS 26 的液态玻璃。
    static var supportsLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 是否已经有内置 Linux 沙箱（M4 之后会变成 true）。
    static var hasLinuxSandbox: Bool { false }
}
