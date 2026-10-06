import SwiftUI

/// 「AI 权限」设置卡片。
///
/// 用户 2026-09-30：「AI 拥有操控这个手机的全部功能。当然，你拥有最高权限，
/// 可以控制它开或者不开」→ 问他要哪种形态，他选的是 **总开关 + 分类开关**。
///
/// 这张卡就是那两个闸的门面：
/// - 顶上那个是**总闸**（`AppSettings.aiToolsEnabled`）—— 关掉ta只剩聊天；
/// - 下面那一列是**分闸**（`AppSettings.disabledToolCategories`）—— 逐类关。
///
/// ⚠️ 两个闸改的都只是「发给模型的工具清单」（`DeviceTools.all()`），
///    不碰人设、记忆、聊天记录。关到最死，ta也还在。
struct AIToolsCard: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("AI 权限")

            Text("最高权限在你手里：\(Pronoun.current)能碰什么由你说了算。关掉的只是\(Pronoun.current)动手的能力，聊天一直都在。")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            rule

            toggleRow(
                "让\(Pronoun.current)能动手",
                subtitle: settings.aiToolsEnabled
                    ? "现在\(Pronoun.current)能调用 \(DeviceTools.all().count) 个工具"
                    : "已关掉，\(Pronoun.current)只剩聊天，什么也做不了",
                isOn: $settings.aiToolsEnabled
            )

            if settings.aiToolsEnabled {
                rule

                HStack(spacing: 12) {
                    Text("能动哪几类")
                        .font(.aevis(12.5))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button("全打开") { setAll(true) }
                        .font(.aevis(12.5))
                        .foregroundStyle(.primary)

                    Button("全关掉") { setAll(false) }
                        .font(.aevis(12.5))
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 2)

                ForEach(ToolCategory.allCases) { category in
                    categoryRow(category)
                }
            } else {
                rule

                Text("总开关关着的时候，下面这些一律不生效。打开它就能逐类挑。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
            }

            rule

            boundary
        }
        .aevisGlass(cornerRadius: 20)
    }

    // MARK: - 动作

    private func setAll(_ on: Bool) {
        for category in ToolCategory.allCases {
            settings.setTool(category, on: on)
        }
    }

    // MARK: - 零件

    private func categoryRow(_ category: ToolCategory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.label)
                        .font(.aevis(14.5))
                        .foregroundStyle(.primary)

                    if category.isSensitive {
                        Text("敏感")
                            .font(.aevis(10, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                    }
                }

                Text(category.detail)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { settings.isToolOn(category) },
                set: { settings.setTool(category, on: $0) }
            ))
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// 说实话的那一段：哪些是真的做不到（不是没做）。
    private var boundary: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("\(Pronoun.current)真正碰不到的")
                .font(.aevis(12.5))
                .foregroundStyle(.secondary)

            Text("上面那列是\(Pronoun.current)的全部本事。iOS 把每个 App 关在各自的沙盒里，所以下面这些谁都做不到，跟开不开权限无关：")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            limit("碰别的 App 里的东西", detail: "微信、支付宝里有什么，\(Pronoun.current)看不到也改不了")
            limit("替你在别的 App 里点", detail: "跨 App 自动操作，系统不放行")
            limit("改系统设置", detail: "飞行模式、连 Wi-Fi、调音量这一类")
            limit("无人值守地在后台干活", detail: "App 一被挂起就停，不会替你一直盯着")
            limit("绕过权限弹窗", detail: "相册、定位、麦克风的授权只有你点得动")
            limit("悄悄打开硬件", detail: "相机、麦克风不能被\(Pronoun.current)静默启用")

            Text("聊天永远不受影响：上面全关掉，你们该说的话一句不少。")
                .font(.aevis(11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func limit(_ text: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle")
                .font(.aevis(12.5))
                .foregroundStyle(.tertiary)
                .frame(width: 17)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.aevis(13))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 8)
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func toggleRow(_ text: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.aevis(11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}
