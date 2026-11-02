import SwiftUI
import UIKit
import AevisShared

// ============================================================================
// KMP 共享 UI 的 iOS 入口。
// 整个 Paper 界面（24 屏）都由 AevisShared.framework 里的 Compose 渲染，
// Swift 这边只负责把它塞进一个 UIViewController。
//
// 用法：
//   PaperHostView()                      // 全屏接入
//   .ignoresSafeArea()                   // 由 Compose 自己处理安全区
// ============================================================================

struct PaperHostView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        PaperRootControllerKt.PaperRootController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// 临时开关：想对比新旧 UI 时改这里，不用动别的文件。
enum PaperSwitch {
    static let useSharedUI = true
}

struct PaperHostScreen: View {
    var body: some View {
        if PaperSwitch.useSharedUI {
            PaperHostView()
                .ignoresSafeArea(.container, edges: .bottom)
        } else {
            Text("共享 UI 已关闭")
        }
    }
}
