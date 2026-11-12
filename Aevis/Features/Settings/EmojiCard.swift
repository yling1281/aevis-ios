import SwiftUI
import UniformTypeIdentifiers

/// 「表情」设置卡片。
///
/// 两件事：开关（ta能不能发表情）+ 换成自己的表情图。
///
/// 关于版权：微信和 QQ 的表情图片是腾讯的资源，不该打包进一个要发给朋友的 App。
/// 但表情的**名字**是通用的（两家都叫 `[微笑]`、`[呲牙]`），所以 Aevis 认名字，
/// 默认显示成意思对得上的表情符号；你有自己的图就导进来换成图。
struct EmojiCard: View {

    @ObservedObject private var emoji = EmojiPack.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var importing = false
    @State private var note: String?
    @State private var showAll = false
    @State private var remoteURLs = ""
    @State private var remoteNote: String?
    @State private var importingRemote = false
    /// 发现里的表情包（2026-11-12）：创作者上传的，可以一键导进来。
    @State private var plazaPacks: [PlazaPack] = []
    @State private var loadingPlaza = false
    @State private var plazaError: String?

    struct PlazaPack: Identifiable {
        let id: String
        let name: String
        let intro: String
        let cover: String
        let items: [String]
        var count: Int { items.count }
    }

    private var importedCount: Int { emoji.custom.count }

    /// 把 `/v1/emoji/list` 的相对路径补成绝对地址。
    private func absolute(_ u: String) -> String {
        let v = u.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { return "" }
        return v.hasPrefix("http") ? v : (AevisHosts.accountBase + v)
    }

    private func loadPlaza() async {
        await MainActor.run { loadingPlaza = true; plazaError = nil }
        guard let url = URL(string: AevisHosts.accountBase + "/v1/emoji/list") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = obj["data"] as? [String: Any],
                  let rows = d["rows"] as? [[String: Any]] else {
                await MainActor.run { loadingPlaza = false; plazaError = "读取失败" }
                return
            }
            let packs = rows.map { r -> PlazaPack in
                let raw = (r["items"] as? [String]) ?? []
                return PlazaPack(
                    id: (r["id"] as? String) ?? UUID().uuidString,
                    name: (r["name"] as? String) ?? "",
                    intro: (r["intro"] as? String) ?? "",
                    cover: absolute((r["cover_url"] as? String) ?? ""),
                    items: raw.map { self.absolute($0) }
                )
            }
            await MainActor.run { plazaPacks = packs; loadingPlaza = false }
        } catch {
            await MainActor.run { loadingPlaza = false; plazaError = "网络异常" }
        }
    }

    private func importPack(_ p: PlazaPack) {
        guard !p.items.isEmpty else { return }
        Task {
            await MainActor.run { note = "正在导入「\(p.name)」…" }
            let r = await emoji.importRemoteURLs(p.items)
            await MainActor.run {
                if r.added.isEmpty {
                    note = "「\(p.name)」没导进来（\(r.failed.count) 张失败）"
                } else {
                    note = "「\(p.name)」导入 \(r.added.count) 张" +
                        (r.failed.isEmpty ? "" : "，\(r.failed.count) 张失败")
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title("表情")

            toggleRow(
                "让\(Pronoun.current)发表情",
                subtitle: "\(Pronoun.current)写 [微笑] 这样的名字，聊天里会显示成真表情",
                isOn: $emoji.enabled
            )

            rule

            // ——— 发送频率 ———

            VStack(alignment: .leading, spacing: 10) {
                Text("表情发送频率")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Picker("表情发送频率", selection: $settings.emojiFrequency) {
                    ForEach(EmojiFrequency.allCases, id: \.rawValue) { freq in
                        Text(freq.label).tag(freq)
                    }
                }
                .pickerStyle(.segmented)

                Text("这决定写进提示词里的那句「怎么发表情」，不影响表情包本身。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 换成自己的图 ———

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        importing = true
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.aevis(13, weight: .medium))
                            Text("导入表情图")
                                .font(.aevis(14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }

                    if importedCount > 0 {
                        Button {
                            emoji.removeAllCustom()
                            note = "导入的表情都清掉了，回到内置的表情符号。"
                        } label: {
                            Text("全部还原")
                                .font(.aevis(13.5))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 9)
                                .aevisGlass(cornerRadius: 14)
                        }
                    }

                    Spacer(minLength: 0)
                }

                Text(explanation)
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let note {
                    Text(note)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 从图床批量导入 ———

            VStack(alignment: .leading, spacing: 10) {
                Text("从图床批量导入")
                    .font(.aevis(12.5, weight: .medium))
                    .foregroundStyle(.secondary)

                TextEditor(text: $remoteURLs)
                    .font(.aevis(13))
                    .frame(height: 80)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )

                HStack(spacing: 10) {
                    Button {
                        importingRemote = true
                        Task { @MainActor in
                            let lines = remoteURLs
                                .split(whereSeparator: { $0.isNewline })
                                .map { String($0) }
                            let outcome = await emoji.importRemoteURLs(lines)
                            var parts: [String] = []
                            if !outcome.added.isEmpty {
                                parts.append("导入了 \(outcome.added.count) 个："
                                             + outcome.added.prefix(6).joined(separator: "、"))
                            }
                            if !outcome.failed.isEmpty {
                                parts.append("这些没成："
                                             + outcome.failed.prefix(3).joined(separator: "；"))
                            }
                            remoteNote = parts.isEmpty ? "没有可导入的网址。" : parts.joined(separator: "\n")
                            importingRemote = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if importingRemote {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(importingRemote ? "导入中…" : "开始导入")
                                .font(.aevis(14, weight: .medium))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .aevisGlass(cornerRadius: 14)
                    }
                    .disabled(importingRemote)

                    Spacer(minLength: 0)
                }

                Text("一行一个图床图片地址。URL 最后一段文件名当表情名，比如 .../微笑.png → [微笑]；下载后会统一转成 PNG 存到本机。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if let remoteNote {
                    Text(remoteNote)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 表情长什么样 ———

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("内置 \(EmojiPack.builtinCount) 个")
                        .font(.aevis(12.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    if importedCount > 0 {
                        Text("· 已换 \(importedCount) 张")
                            .font(.aevis(12.5, weight: .medium))
                            .foregroundStyle(AppSettings.shared.accentColor)
                    }

                    Spacer(minLength: 0)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showAll.toggle()
                        }
                    } label: {
                        Text(showAll ? "收起来" : "看全部")
                            .font(.aevis(12.5))
                            .foregroundStyle(AppSettings.shared.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 52), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(showAll ? emoji.items : Array(emoji.items.prefix(18))) { item in
                        cell(item)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            rule

            // ——— 发现里的表情包（2026-11-12）———
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("发现里的表情包")
                        .font(.aevis(12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        Task { await loadPlaza() }
                    } label: {
                        Text(loadingPlaza ? "加载中…" : "刷新")
                            .font(.aevis(12.5))
                            .foregroundStyle(settings.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(loadingPlaza)
                }

                if let plazaError {
                    Text(plazaError)
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                } else if plazaPacks.isEmpty {
                    Text(loadingPlaza ? "正在读…" : "还没有人上传过表情包")
                        .font(.aevis(11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(plazaPacks.prefix(6)) { p in
                        HStack(spacing: 10) {
                            if let u = URL(string: p.cover), !p.cover.isEmpty {
                                AsyncImage(url: u) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.12)
                                    }
                                }
                                .frame(width: 38, height: 38)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.aevis(13, weight: .medium))
                                Text("\(p.count) 张\(p.intro.isEmpty ? "" : " · " + p.intro)")
                                    .font(.aevis(11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button {
                                importPack(p)
                            } label: {
                                Text("导入")
                                    .font(.aevis(12.5, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(settings.accentColor.opacity(0.14)))
                                    .foregroundStyle(settings.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .aevisGlass(cornerRadius: 20)
        .task { await loadPlaza() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result)
        }
    }

    // MARK: - 一格表情

    @ViewBuilder
    private func cell(_ item: EmojiPack.Item) -> some View {
        VStack(spacing: 4) {
            #if canImport(UIKit)
            if let image = emoji.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            } else {
                Text(item.emoji)
                    .font(.aevis(24))
            }
            #else
            Text(item.emoji)
                .font(.aevis(24))
            #endif

            Text(item.name)
                .font(.aevis(9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(item.isCustom ? 0.09 : 0.05))
        )
        .contextMenu {
            if item.isCustom {
                Button(role: .destructive) {
                    emoji.removeCustom(item.name)
                    note = "「\(item.name)」还原成内置的表情符号了。"
                } label: {
                    Label("删掉这张图", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let outcome = emoji.importImages(from: urls)
            var lines: [String] = []
            if !outcome.added.isEmpty {
                let names = outcome.added.prefix(6).joined(separator: "、")
                lines.append("换上了 \(outcome.added.count) 个：\(names)")
            }
            if !outcome.failed.isEmpty {
                let names = outcome.failed.prefix(3).joined(separator: "；")
                lines.append("这些没成：\(names)")
            }
            note = lines.isEmpty ? "没选中文件。" : lines.joined(separator: "\n")
        case .failure(let error):
            note = "导入失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 文案

    private var explanation: String {
        """
        图片的文件名就是表情名 —— 把 微笑.png 导进来，\(Pronoun.current)写 [微笑] 时显示的就是这张图。
        长按某一格可以只删掉那一张。
        """
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
        .padding(.vertical, 12)
    }
}
