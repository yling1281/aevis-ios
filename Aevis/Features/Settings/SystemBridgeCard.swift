import SwiftUI
import AppIntents

#if canImport(UIKit)
import UIKit
#endif

/// 「系统」设置卡片：跟 iOS 打交道的那几件事，以及**做不到时的绕法**。
///
/// 这一版把「快捷指令」那条双向通道补全了 —— 之前只有半个（我们能调它，
/// 它的输出回不来），所以锁屏和屏幕使用时间都只能说"做不到"。
///
/// ⭐ 2026-10-05：加了「Aevis 自带的动作」一栏（`ShortcutsLink()`）。
///   Aevis 现在**出厂就带着**几条快捷指令动作（见 `Core/AppShortcuts.swift`），
///   用户点一下 `ShortcutsLink` 就跳到系统「快捷指令」里 Aevis 的动作页，
///   **不用自己手搓**。下面原来的手搓说明保留，但降级成"进阶 / 自定义"。
struct SystemBridgeCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenTime = ScreenTimeInsight.shared
    @ObservedObject private var ambient = AmbientContext.shared

    @State private var editing = ""
    @State private var editingTitle = ""
    @State private var editingKey = ""
    @State private var note: String?

    // 「自己拼」那两块高级区的展开状态。
    // 🔴 **各用各的**，别共用一个 —— 共用的话展开一个另一个也跟着开。
    @State private var showAdvancedShortcuts = false
    @State private var showAdvancedAmbient = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("系统")

            // ——— Aevis 自带的动作（出厂就有，不用手搓）———

            builtInActions

            rule

            // ——— 锁屏 ———

            shortcutRow(
                symbol: "lock.fill",
                title: "锁屏",
                value: settings.lockShortcutName,
                key: "lock",
                defaultName: ShortcutBridge.defaultLockShortcutName,
                action: {
                    note = ShortcutBridge.lockScreenViaShortcut()
                }
            )

            // 包一层 LocalizedStringKey —— 这样里面的 **加粗** 才会真的渲染。
            // 直接 Text(某个字符串变量) 是不解析 markdown 的，星号会原样显示
            // （截图自检时抓到过）。
            Text(LocalizedStringKey(ShortcutBridge.lockScreenNote))
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 13)

            rule

            // ——— 屏幕使用时间 ———

            shortcutRow(
                symbol: "hourglass",
                title: "屏幕使用时间",
                value: settings.screenTimeShortcutName,
                key: "screentime",
                defaultName: ShortcutBridge.defaultScreenTimeShortcutName,
                action: {
                    note = ShortcutBridge.requestScreenTimeViaShortcut()
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("现在拿到的：\(screenTime.label)")
                    .font(.aevis(13))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(ScreenTimeInsight.explanation))
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 13)

            rule

            // ——— 快捷指令怎么把数据发回来 ———

            // 默认收起：老板的要求是「别让用户自己拼」。这一整块是给想折腾的人的退路，
            // 不展开就等于不存在，不影响绝大多数用户。
            DisclosureGroup(isExpanded: $showAdvancedShortcuts) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("上面那些是现成的。如果你想要更自由的做法：在「快捷指令」里自己拼，最后加一步「打开 URL」，把下面任意一条填进去。点一下就能复制。")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(AevisBridge.examples.enumerated()), id: \.offset) { _, item in
                        Button {
                            copy(item.url)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.aevis(13.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(item.url)
                                    .font(.aevisMono(11.5))
                                    .foregroundStyle(AppSettings.shared.accentColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(item.note)
                                    .font(.aevis(11))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Text("高级：自己拼快捷指令（用不到就别展开）")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 外面来的信息 ———

            ambientSection

            rule

            // ——— 回主界面 ———

            HStack(spacing: 10) {
                Button {
                    note = ShortcutBridge.goHome() ? "回主界面了。" : "回主界面失败。"
                } label: {
                    Text("回主界面")
                        .font(.aevis(14, weight: .medium))
                        .foregroundStyle(ShortcutBridge.canGoHome ? Color.primary : Color.secondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                }
                .disabled(!ShortcutBridge.canGoHome)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

            Text(ShortcutBridge.canGoHome
                 ? "走的是系统内部接口 —— 侧载自己用没问题，上架会被拒。这条不需要快捷指令。"
                 : "这台系统上不支持，已经禁用了，不会点了崩。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 13)

            if let note {
                rule
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
            }
        }
        .aevisGlass(cornerRadius: 20)
        .alert(editingTitle, isPresented: Binding(
            get: { !editingKey.isEmpty },
            set: { if !$0 { editingKey = "" } }
        )) {
            TextField("快捷指令的名字", text: $editing)
            Button("保存") { save() }
            Button("取消", role: .cancel) { editingKey = "" }
        } message: {
            Text(editHint)
        }
    }

    // MARK: - 动作

    private func beginEdit(_ key: String, title text: String, current: String) {
        editingKey = key
        editingTitle = text
        editing = current
    }

    private func save() {
        let value = editing.trimmingCharacters(in: .whitespacesAndNewlines)
        switch editingKey {
        case "lock": settings.lockShortcutName = value
        case "screentime": settings.screenTimeShortcutName = value
        default: break
        }
        note = value.isEmpty ? "已清空。" : "保存了。"
        editingKey = ""
    }

    /// 编辑弹窗里那句提示。默认名**按 `editingKey` 现算**，不另加状态变量。
    ///
    /// 「不填也能跑」这件事必须在这里说清楚 —— 不填就用默认名（锁屏 / 屏幕使用时间），
    /// 用户在自己「快捷指令」里按默认名做一条就成，不用回来填任何东西。
    private var editHint: String {
        let fallback: String
        switch editingKey {
        case "lock": fallback = ShortcutBridge.defaultLockShortcutName
        case "screentime": fallback = ShortcutBridge.defaultScreenTimeShortcutName
        default: fallback = ""
        }
        return "不填就用默认名「\(fallback)」；填了，就必须和你在「快捷指令」App 里做的那个名字完全一致。"
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        note = "复制好了，粘到快捷指令的「打开 URL」里。"
        #else
        note = text
        #endif
    }

    // MARK: - Aevis 自带的动作
    //
    // 这些走 **App Intents / App Shortcuts**（`Core/AppShortcuts.swift`）——
    // 代码里声明一次，随 App 安装就出现在系统「快捷指令」的「App 快捷指令」分类里。
    // 下面这个按钮一下跳到那里，用户不用自己拼。

    private var builtInActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Aevis 自带的动作")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("这些是现成的 —— 装好 Aevis 就有，不用你自己做。点下面这个按钮，到系统「快捷指令」里的 Aevis 那儿，点一下就能跑。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // 一下跳到「快捷指令」App 里本 App 的 App Shortcuts 页面。
            ShortcutsLink()

            // 🔴 这份清单**必须**和 `Core/AppShortcuts.swift` 的 `appShortcuts` 一一对应
            //    （那边是 Apple 的 10 条硬上限，现在正好放满）。改那边记得回来改这里 ——
            //    这里漏一条，用户就**永远看不到**那个功能（功能是好的，只是没人告诉他）。
            //    防回归：`tools/swift_check.py` 的 R35 会核对这两个文件对不对得上。
            Text("有：上报电量、上报位置、告诉\(Pronoun.current)我在干嘛、上报设备信息、打开 Aevis、上报健康、上报屏幕时间、打开通话、一起听、问今天。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 零件

    // MARK: - 外面来的信息
    //
    // 位置、电量、步数这些 Aevis 自己读不到（iOS 不让 App 在后台读），
    // 但快捷指令读得到。跑完用「打开 URL」发回来，ta聊天时就知道了。

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把外面的情况告诉\(Pronoun.current)")
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)

            Text("这些 Aevis 自己读不到，但快捷指令可以。在快捷指令里最后加一步「打开 URL」，填下面任意一条。点一下就能复制。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !ambient.entries.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(ambient.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(AmbientContext.label(for: entry.kind))
                                .font(.aevis(12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(entry.text)
                                .font(.aevis(12))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }

            // 默认收起：这几条是「想自己拼 URL 的人才用得到」的退路，平时不展开就等于不存在。
            // （上面「现在拿到的」和下面「清空这些」照常显示，不进这个折叠区。）
            DisclosureGroup(isExpanded: $showAdvancedAmbient) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(AmbientContext.kinds.enumerated()), id: \.offset) { _, kind in
                        Button {
                            copy(kind.example)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kind.label)
                                    .font(.aevis(13.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text(kind.example)
                                    .font(.aevisMono(11.5))
                                    .foregroundStyle(AppSettings.shared.accentColor)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(11)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            } label: {
                Text("高级：自己拼 URL（用不到就别展开）")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !ambient.entries.isEmpty {
                Button {
                    ambient.clear()
                    note = "外面来的信息都清掉了。"
                } label: {
                    Text("清空这些")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
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

    /// 一行：图标 + 名字 + 当前名字（空则显示默认名）+「自定义」/「改」+「试一次」。
    ///
    /// `defaultName` 是**不填时后端会用的那个名字**（`ShortcutBridge` 里的默认名）。
    /// 空值时必须把它显示出来 —— 不填是真能跑的，界面不能再说"还没填"。
    private func shortcutRow(
        symbol: String,
        title text: String,
        value: String,
        key: String,
        defaultName: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.aevis(14))
                .foregroundStyle(AppSettings.shared.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.aevis(14.5))
                    .foregroundStyle(.primary)
                Text(value.isEmpty ? "不填就用默认名「\(defaultName)」" : value)
                    .font(.aevis(11.5))
                    .foregroundStyle(value.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                beginEdit(key, title: text, current: value)
            } label: {
                Text(value.isEmpty ? "自定义" : "改")
                    .font(.aevis(13))
            }

            Button("试一次", action: action)
                .font(.aevis(13))
                .disabled(!ShortcutBridge.isShortcutsAvailable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
