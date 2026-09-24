import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 可选的桌面图标。
///
/// **iOS 的硬限制：只能在 App 内置的图标之间切换，
/// 不能用相册里的图当桌面图标。** 所以这里提供一组预置图标。
/// 资源名要和 `scripts/make_icon.py` 里生成的 appiconset 名字一一对应。
enum AppIconOption: String, CaseIterable, Identifiable {
    case primary = ""
    case blue = "AppIcon-Blue"
    case teal = "AppIcon-Teal"
    case rose = "AppIcon-Rose"
    case amber = "AppIcon-Amber"
    case green = "AppIcon-Green"
    case ink = "AppIcon-Ink"

    var id: String { rawValue }

    /// 传给 setAlternateIconName 的名字。nil 表示回到主图标。
    var alternateName: String? {
        self == .primary ? nil : rawValue
    }

    var label: String {
        switch self {
        case .primary: return "紫"
        case .blue: return "蓝"
        case .teal: return "青"
        case .rose: return "玫红"
        case .amber: return "橙"
        case .green: return "绿"
        case .ink: return "墨"
        }
    }

    /// 预览用的主色，和图标脚本里的配色对应。
    var previewColor: Color {
        switch self {
        case .primary: return Color(red: 0.42, green: 0.35, blue: 0.95)
        case .blue: return Color(red: 0.20, green: 0.48, blue: 0.96)
        case .teal: return Color(red: 0.13, green: 0.64, blue: 0.58)
        case .rose: return Color(red: 0.88, green: 0.32, blue: 0.52)
        case .amber: return Color(red: 0.92, green: 0.55, blue: 0.18)
        case .green: return Color(red: 0.40, green: 0.62, blue: 0.20)
        case .ink: return Color(red: 0.34, green: 0.35, blue: 0.42)
        }
    }
}

/// 桌面图标的切换。
///
/// 故意不加 `@MainActor`：这个单例会在 View 的属性初始化里被取到，
/// 加隔离反而会在 Swift 5 语言模式下报「非隔离上下文访问主线程属性」。
/// 实际调用点都在主线程（按钮动作、View 构建）。
final class AppIconStore: ObservableObject {
    static let shared = AppIconStore()

    @Published private(set) var current: AppIconOption = .primary
    @Published private(set) var message: String?

    private init() {
        refresh()
    }

    var isSupported: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.supportsAlternateIcons
        #else
        return false
        #endif
    }

    func refresh() {
        #if canImport(UIKit)
        let name = UIApplication.shared.alternateIconName ?? ""
        current = AppIconOption(rawValue: name) ?? .primary
        #endif
    }

    func apply(_ option: AppIconOption) {
        #if canImport(UIKit)
        guard UIApplication.shared.supportsAlternateIcons else {
            message = "这台设备或这个系统版本不支持换图标。"
            return
        }
        guard option != current else { return }

        message = nil
        UIApplication.shared.setAlternateIconName(option.alternateName) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    // 最常见的原因：这个图标名没被编进 Assets，会被系统拒绝
                    self.message = "换图标失败：\(error.localizedDescription)"
                } else {
                    self.message = "已经换成「\(option.label)」了，看主屏幕。"
                }
                self.refresh()
            }
        }
        #else
        message = "当前平台不支持。"
        #endif
    }
}
