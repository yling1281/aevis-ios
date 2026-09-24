import SwiftUI

/// 「主动消息」设置卡片：让 TA 自己找你，还能推到 Bark。
struct ProactiveSettingsCard: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var personaStore = PersonaStore.shared

    @State private var editingBark = false
    @State private var barkDraft = ""
    @State private var note: String?
    @State private var working = false

    private var persona: Persona { personaStore.persona }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("主动消息")

            toggleRow("让 TA 主动找你", subtitle: "打开后会用系统通知，App 没开也照样到点弹出来", isOn: $settings.proactiveEnabled)

            if settings.proactiveEnabled {
                rule
                fixedSection
                rule
                randomSection
                rule
                linesSection
                rule
                barkSection
            }
        }
        .aevisGlass(cornerRadius: 20)
        .alert("Bark 推送地址", isPresented: $editingBark) {
            TextField("https://api.day.app/你的KEY", text: $barkDraft)
            Button("保存") {
                settings.barkURL = barkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                note = settings.barkURL.isEmpty ? "已清空 Bark 地址。" : "Bark 地址已保存。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("打开 Bark App，首页就能看到属于你的地址。")
        }
        .onChange(of: settings.proactiveEnabled) { _, on in
            guard on else { return }
            Task { await reschedule(regenerate: true) }
        }
    }

    // MARK: - 定时

    private var fixedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow("定时发消息", subtitle: "每天在下面这几个时间点给你发一条", isOn: $settings.fixedTimesEnabled)
                .padding(.horizontal, -16)

            if settings.fixedTimesEnabled {
                ForEach(0..<settings.fixedTimes.count, id: \.self) { index in
                    HStack {
                        Text("第 \(index + 1) 条")
                            .font(.aevis(13.5))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        DatePicker(
                            "",
                            selection: timeBinding(index),
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .onChange(of: settings.fixedTimes) { _, _ in
            Task { await reschedule(regenerate: false) }
        }
        .onChange(of: settings.fixedTimesEnabled) { _, _ in
            Task { await reschedule(regenerate: false) }
        }
    }

    // MARK: - 不定时

    private var randomSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow("不定时发消息", subtitle: "一天里挑几个随机时刻，不知道什么时候会来", isOn: $settings.randomEnabled)
                .padding(.horizontal, -16)

            if settings.randomEnabled {
                HStack {
                    Text("每天")
                        .font(.aevis(13.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Stepper(value: $settings.randomPerDay, in: 1...6) {
                        Text("\(settings.randomPerDay) 条")
                            .font(.aevis(13.5))
                            .foregroundStyle(.primary)
                    }
                    .labelsHidden()
                }

                Text("每次打开 App 时会为接下来 24 小时重新随机排一批 —— 本地通知只能在排程时定下时间，做不到真正的实时随机。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .onChange(of: settings.randomEnabled) { _, _ in
            Task { await reschedule(regenerate: false) }
        }
        .onChange(of: settings.randomPerDay) { _, _ in
            Task { await reschedule(regenerate: false) }
        }
    }

    // MARK: - 她会说什么

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            label("她会说什么")

            if settings.proactiveLines.isEmpty {
                Text("还没有准备话术。点下面按钮让她写一批。")
                    .font(.aevis(12.5))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(settings.proactiveLines.prefix(3).enumerated()), id: \.offset) { _, line in
                        Text("「\(line)」")
                            .font(.aevis(13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if settings.proactiveLines.count > 3 {
                        Text("…还有 \(settings.proactiveLines.count - 3) 句")
                            .font(.aevis(11.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await reschedule(regenerate: true) }
                } label: {
                    HStack(spacing: 7) {
                        if working {
                            ProgressView().controlSize(.small)
                        }
                        Text(working ? "正在写…" : "让她重新写一批")
                            .font(.aevis(14, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .aevisGlass(cornerRadius: 14)
                }
                .disabled(working)

                Spacer(minLength: 0)
            }

            if let note {
                Text(note)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(settings.isConfigured
                 ? "话术由她按自己的人设写，存在这台手机上。主动消息在后台不会调用模型 —— 所以是「提前写好、到点取用」。"
                 : "还没填 API Key，先用内置的几句通用话术。填上 Key 之后可以让她按自己的人设写。")
                .font(.aevis(11.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - Bark

    private var barkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow("推到 Bark", subtitle: "她说话时同时推一条到 Bark，通知会留在 Bark 的历史里", isOn: $settings.barkEnabled)
                .padding(.horizontal, -16)

            if settings.barkEnabled {
                HStack(spacing: 10) {
                    Button {
                        barkDraft = settings.barkURL
                        editingBark = true
                    } label: {
                        Text(settings.barkURL.isEmpty ? "填 Bark 地址" : "改 Bark 地址")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }

                    Button(action: testBark) {
                        Text("测试推送")
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 9)
                            .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(settings.barkURL.isEmpty)

                    Spacer(minLength: 0)
                }

                if !settings.barkURL.isEmpty {
                    Text(settings.barkURL)
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("Bark 是另一个 App 提供的推送通道。好处是消息会留在通知历史里；但它需要 App 在运行时才发得出去，所以真正的定时仍然靠上面那两条本地通知。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    // MARK: - 动作

    private func reschedule(regenerate: Bool) async {
        working = regenerate
        note = nil
        defer { working = false }

        if regenerate {
            settings.proactiveLines = []
            let lines = await ProactiveService.shared.linePool(persona: persona, settings: settings)
            note = lines.isEmpty ? "没写出话术，先用内置的。" : "写好了 \(lines.count) 句。"
        }

        let granted = await ProactiveService.shared.ensureAuthorization()
        if !granted {
            note = "系统通知权限没开，主动消息发不出来。去「设置 → 通知 → Aevis」里打开。"
            return
        }

        await ProactiveService.shared.reschedule()

        if settings.barkEnabled, !settings.barkURL.isEmpty {
            await pushBark("（这是一条测试，说明 Bark 通道通了）")
        }
    }

    private func testBark() {
        note = nil
        Task { await pushBark("测试推送，看到我就是通了。") }
    }

    private func pushBark(_ text: String) async {
        guard !settings.barkURL.isEmpty else { return }
        do {
            try await ProactiveService.shared.sendBark(
                text: text,
                title: persona.name.isEmpty ? "Aevis" : persona.name,
                urlString: settings.barkURL
            )
            if note == nil { note = "Bark 推送成功，去看手机通知。" }
        } catch {
            note = error.localizedDescription
        }
    }

    // MARK: - 时间转换

    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                guard settings.fixedTimes.indices.contains(index) else { return Date() }
                return Self.date(from: settings.fixedTimes[index]) ?? Date()
            },
            set: { newValue in
                guard settings.fixedTimes.indices.contains(index) else { return }
                settings.fixedTimes[index] = Self.string(from: newValue)
            }
        )
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func date(from text: String) -> Date? {
        formatter.date(from: text)
    }

    private static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    // MARK: - 零件

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

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.aevis(12.5))
            .foregroundStyle(.secondary)
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
