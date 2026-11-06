import SwiftUI

/// 全 App 背景。
///
/// 设计说明：
///   · 底色是 `Paper.bg`（米白），**不用渐变**（规范里明确禁止）。
///   · 上面铺一层极淡点阵（24pt 一格、半径 0.9、3% 墨色），
///     远看是干净的米白，近看有纸的颗粒感，不会像纯色那样空。
///   · 点阵用 Canvas 画，不占包体、任何分辨率都清晰。
///
/// 和 Android 的 `PaperBackground`（Compose Canvas）是同一套参数：
/// 24dp 步长、0.9dp 半径、0x08000000 颜色 —— 两端观感一致。
struct PaperBackgroundView<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Paper.bg.ignoresSafeArea()

            Canvas { ctx, size in
                let step: CGFloat = 24
                let r: CGFloat = 0.9
                let dot = Color(red: 0, green: 0, blue: 0, opacity: 0.03)

                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(dot))
                        x += step
                    }
                    y += step
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            content
        }
    }
}

/// 背景贴图修饰符：给已经写好的页面套背景，不用改结构。
extension View {
    /// 铺一层 Paper 主题背景（米白 + 点阵）。
    func paperBackground() -> some View {
        ZStack {
            Paper.bg.ignoresSafeArea()

            Canvas { ctx, size in
                let step: CGFloat = 24
                let r: CGFloat = 0.9
                let dot = Color(red: 0, green: 0, blue: 0, opacity: 0.03)
                var y = step
                while y < size.height {
                    var x = step
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                            with: .color(dot)
                        )
                        x += step
                    }
                    y += step
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            self
        }
    }
}
