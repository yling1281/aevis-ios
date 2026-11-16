import SwiftUI

/// 设置（2026-11-17，134 骨架）：主题跟随系统 / 字号 / 弹窗开关。
/// 与安卓 120/126/133 的口径一致：主题三档、字号三档、消息弹窗独立开关。
struct SettingsView: View {
    @EnvironmentObject private var session: Session

    @AppStorage("themeMode") private var themeMode = 0   // 0 跟随系统 / 1 浅色 / 2 深色
    @AppStorage("msgSize") private var msgSize = 1
    @AppStorage("msgBanner") private var msgBanner = true

    var body: some View {
        NavigationStack {
            Form {
                Section("主题") {
                    Picker("主题", selection: $themeMode) {
                        Text("跟随系统").tag(0)
                        Text("浅色").tag(1)
                        Text("深色").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("消息大小") {
                    Picker("字号", selection: $msgSize) {
                        Text("小").tag(0)
                        Text("标准").tag(1)
                        Text("大").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("通知") {
                    Toggle("新消息弹窗", isOn: $msgBanner)
                }

                Section {
                    Button("退出登录", role: .destructive) {
                        session.signOut()
                    }
                }
            }
            .navigationTitle("设置")
            .preferredColorScheme(
                themeMode == 1 ? .light : (themeMode == 2 ? .dark : nil)
            )
        }
    }
}
