import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// 「转发朋友圈」—— 聊天页加号里点进来的那一页。
///
/// 用户原话（2026-09-28）：
/// 「朋友圈的话，告诉你点朋友圈的话是转发朋友圈」
///
/// 所以这个入口**不是"去看朋友圈"**（看朋友圈在「发现」那一页），
/// 而是**挑一条聊天内容发到朋友圈**。以前点它直接跳去看朋友圈，
/// 跟他想要的完全不是一回事。
struct ShareToMomentsSheet: View {

    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var personaStore: PersonaStore
    @ObservedObject private var moments = MomentStore.shared

    @Environment(\.dismiss) private var dismiss

    /// 选中的那条消息。
    @State private var picked: ChatMessage.ID?
    /// 转发时想补一句（可空）。
    @State private var extra = ""
    @State private var note: String?

    private var persona: Persona { personaStore.persona }

    /// 能转的：纯文字、非空、不是通话记录。
    /// 只给最近 30 条 —— 翻三个月前的要一直滑，没人这么干。
    private var candidates: [ChatMessage] {
        let good = chat.messages.filter {
            $0.kind == .text
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Array(good.suffix(30).reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("挑一条，转发到朋友圈")
                        .font(.aevis(13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    if candidates.isEmpty {
                        Text("还没有能转的消息。先聊两句吧。")
                            .font(.aevis(14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .aevisGlass(cornerRadius: 16)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, message in
                                row(message, divider: index > 0)
                            }
                        }
                        .aevisGlass(cornerRadius: 16)
                    }

                    if picked != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("再补一句？（不写也行）")
                                .font(.aevis(12.5))
                                .foregroundStyle(.secondary)
                            TextField("说点什么…", text: $extra, axis: .vertical)
                                .lineLimit(1...3)
                                .font(.aevis(14.5))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                )
                        }
                        .padding(14)
                        .aevisGlass(cornerRadius: 16)
                    }

                    if let note {
                        Text(note)
                            .font(.aevis(12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }

                    Button {
                        post()
                    } label: {
                        Text(picked == nil ? "先挑一条" : "发到朋友圈")
                            .font(.aevis(15, weight: .medium))
                            .foregroundStyle(picked == nil ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .aevisGlass(cornerRadius: 16)
                    }
                    .buttonStyle(.plain)
                    .disabled(picked == nil)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("转发朋友圈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 一条消息

    private func row(_ message: ChatMessage, divider: Bool) -> some View {
        let isMine = message.role == .user
        let selected = picked == message.id
        return Button {
            picked = selected ? nil : message.id
        } label: {
            VStack(spacing: 0) {
                if divider {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.leading, 14)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isMine ? "我" : (persona.name.isEmpty ? "ta" : persona.name))
                            .font(.aevis(11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(message.text)
                            .font(.aevis(14.5))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.aevis(17))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.35))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 发出去

    private func post() {
        guard let id = picked,
              let message = chat.messages.first(where: { $0.id == id }) else { return }

        let tail = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = tail.isEmpty ? message.text : message.text + "\n" + tail

        #if canImport(UIKit)
        let picture = message.imageData.flatMap { UIImage(data: $0) }
        let posted = moments.post(text: body, author: .me, image: picture)
        #else
        let posted = moments.post(text: body, author: .me)
        #endif

        if posted != nil {
            note = "转过去了。\(Pronoun.current)在朋友圈里看得到。"
            picked = nil
            extra = ""
        } else {
            note = "这条转不了（内容是空的）。"
        }
    }
}
