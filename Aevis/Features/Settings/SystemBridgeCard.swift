import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「系统」设置卡片：跟 iOS 打交道的那几件事，以及**做不到时的绕法**。
///
/// 这一版把「快捷指令」那条双向通道补全了 —— 之前只有半个（我们能调它，
/// 它的输出回不来），所以锁屏和屏幕使用时间都只能说"做不到"。
struct SystemBridgeCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var screenTime = ScreenTimeInsight.shared
    @ObservedObject private var ambient = AmbientContext.shared

    @State private var editing = ""
    @State private var editingTitle = ""
    @State private var editingKey = ""
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("系统")

            // ——— 锁屏 ———

            shortcutRow(
                symbol: "lock.fill",
                title: "锁屏",
                value: settings.lockShortcutName,
                key: "lock",
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

            VStack(alignment: .leading, spacing: 10) {
                Text("让快捷指令把数据发回来")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("在快捷指令里最后加一步「打开 URL」，把下面任意一条填进去。点一下就能复制。")
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
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 外面来的信息 ———

            ambientSection

            rule

            // ——— 通用快捷指令 ———

            shortcutRow(
                symbol: "wand.and.stars",
                title: "常用快捷指令",
                value: settings.shortcutName,
                key: "any",
                action: {
                    let name = settings.shortcutName
                    note = ShortcutBridge.runShortcut(named: name)
                        ? "跑了「\(name)」。"
                        : "没跑起来，检查名字。"
                }
            )

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
            Text("要和你在「快捷指令」App 里做的那个名字完全一致。")
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
        default: settings.shortcutName = value
        }
        note = value.isEmpty ? "已清空。" : "保存了。"
        editingKey = ""
    }

    private func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        note = "复制好了，粘到快捷指令的「打开 URL」里。"
        #else
        note = text
        #endif
    }

    // MARK: - 零件

    // MARK: - 外面来的信息
    //
    // 位置、电量、步数这些 Aevis 自己读不到（iOS 不让 App 在后台读），
    // 但快捷指令读得到。跑完用「打开 URL」发回来，她聊天时就知道了。

    private var ambientSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("把外面的情况告诉她")
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

    /// 一行：图标 + 名字 + 当前填的指令名 + 「填」/「试一次」两个按钮。
    private func shortcutRow(
        symbol: String,
        title text: String,
        value: String,
        key: String,
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
                Text(value.isEmpty ? "还没填快捷指令名" : value)
                    .font(.aevis(11.5))
                    .foregroundStyle(value.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                beginEdit(key, title: text, current: value)
            } label: {
                Text(value.isEmpty ? "填" : "改")
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
