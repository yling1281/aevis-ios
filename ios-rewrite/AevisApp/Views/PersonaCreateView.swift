import SwiftUI

/// 自己搓一个人设（2026-11-24）：人设广场的「创建」入口。
///
/// 后端已有 `POST /v1/psquare/publish`（需 X-Account），所以这是**真创建**而不是本地占位：
/// 提交后 AI 审核通过即 status="listing"（广场可见、非推荐位），未过返回 rejected + 原因。
/// 最少只要求名字；标签/设定/头像 URL 都可选。头像用远程 URL，走广场列表同一套解析。
struct PersonaCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: Session

    /// 创建成功后回调（广场页据此刷新列表）
    var onCreated: ((APIClient.PersonaCreateResult) -> Void)? = nil

    @State private var name = ""
    @State private var tagline = ""
    @State private var personality = ""
    @State private var avatarURL = ""
    @State private var sending = false
    @State private var tip = ""

    var body: some View {
        ZStack {
            GlassBackdrop()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("创建人设")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(AE.textPrimary)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AE.textSecondary)
                            .frame(width: 28, height: 28)
                            .background(AE.accentSoft, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        field("名字 *", text: $name, placeholder: "例：深夜电台的主持人")
                        field("一句话标签", text: $tagline, placeholder: "温柔、慢热、爱讲冷笑话")
                        field("人设设定", text: $personality, placeholder: "性格、身份、说话方式…", height: 90)
                        field("头像链接（可选）", text: $avatarURL, placeholder: "https://…")

                        Text("提交后由服务端审核；通过后会出现在人设广场，未通过会返回原因。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(AE.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if !tip.isEmpty {
                            Text(tip)
                                .font(.system(size: 12))
                                .foregroundStyle(AE.brandPurple)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button { Task { await submit() } } label: {
                            Text(sending ? "提交中…" : "提交到人设广场")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 46)
                                .background(name.trimmingCharacters(in: .whitespaces).isEmpty
                                            || sending ? AE.accentDeep.opacity(0.45) : AE.accentDeep,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(sending || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .glassSheetBackground()
    }

    private func field(
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        height: CGFloat = 44
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AE.textSecondary)
            TextField(placeholder, text: text, axis: height > 60 ? .vertical : .horizontal)
                .font(.system(size: 14))
                .foregroundStyle(AE.textPrimary)
                .padding(.horizontal, 12)
                .frame(height: height, alignment: .top)
                .glassCard(cornerRadius: 12, material: .thin, tintOpacity: 0.14)
        }
    }

    @MainActor
    private func submit() async {
        guard !sending else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { tip = "请填写名字"; return }
        guard !session.email.isEmpty else {
            tip = "请先登录后再创建人设"
            return
        }
        sending = true
        tip = ""
        do {
            let result = try await APIClient.createPersona(
                name: n,
                tagline: tagline.trimmingCharacters(in: .whitespacesAndNewlines),
                personality: personality.trimmingCharacters(in: .whitespacesAndNewlines),
                avatarURL: avatarURL.trimmingCharacters(in: .whitespacesAndNewlines),
                account: session.email
            )
            sending = false
            onCreated?(result)
            tip = result.listed ? "已提交，审核通过，广场可见" : "已提交，但未通过审核：\(result.reason)"
            if result.listed {
                try? await Task.sleep(nanoseconds: 600_000_000)
                dismiss()
            }
        } catch {
            sending = false
            tip = "提交失败：\(error.localizedDescription)"
        }
    }
}
