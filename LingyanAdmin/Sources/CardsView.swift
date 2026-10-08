import SwiftUI

/// 卡密查询：粘一串卡密，看它有没有被用、绑在哪台设备上、什么时候到期。
/// 两个接口都是**只读**的，不会消费卡密。
struct CardsView: View {
    @State private var code = ""
    @State private var busy = false
    @State private var state: LoadState = .idle
    @State private var verify: [String: Any] = [:]
    @State private var check: [String: Any] = [:]
    @State private var hasResult = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("LY-XXXX-XXXX-XXXX", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled(true)
                        .font(.callout.monospaced())
                    Button {
                        Task { await look(verifyOnly: false) }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(busy ? "查询中…" : "查询").font(.callout.weight(.semibold))
                            Spacer()
                        }
                    }
                    .disabled(busy || code.trimmingCharacters(in: .whitespaces).count < 4)
                } header: {
                    Text("卡密")
                } footer: {
                    Text("只查询，不会把卡密用掉。")
                        .font(.caption2)
                }

                if hasResult {
                    StateBanner(state: state) { Task { await look(verifyOnly: false) } }

                    if state == .done {
                        Section("能不能用") {
                            HStack(spacing: 8) {
                                Image(systemName: verify.b("valid") ? "checkmark.seal.fill" : "xmark.seal.fill")
                                    .foregroundStyle(verify.b("valid") ? .green : .orange)
                                Text(verify.b("valid") ? "可以激活" : (verify.s("reason").isEmpty ? "不可用" : verify.s("reason")))
                                    .font(.footnote)
                            }
                            if verify.b("valid") {
                                KVRow(k: "套餐", v: verify.s("plan_name"))
                                KVRow(k: "天数", v: verify.i("days") > 0 ? "\(verify.i("days")) 天" : "—")
                                KVRow(k: "金额", v: verify.d("amount") > 0 ? "¥\(verify.d("amount"))" : "—")
                            }
                        }

                        Section("档案") {
                            if check.b("exists") {
                                KVRow(k: "状态", v: statusText(check.s("status")))
                                KVRow(k: "套餐", v: check.s("plan_name"))
                                KVRow(k: "账号", v: check.s("username"))
                                KVRow(k: "设备码", v: check.s("device_code"), mono: true)
                                KVRow(k: "绑定于", v: Fmt.time(check.s("bound_at")))
                                KVRow(k: "到期", v: Fmt.day(check.s("expires_at")))
                            } else {
                                Text("服务器里没有这串卡密").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("卡密")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func statusText(_ s: String) -> String {
        switch s {
        case "unused": return "未使用"
        case "bound": return "已绑定（已使用）"
        case "disabled": return "已停用"
        case "": return "—"
        default: return s
        }
    }

    private func look(verifyOnly: Bool) async {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard c.count >= 4 else { return }
        busy = true
        hasResult = true
        state = .loading

        if AppConfig.isDemo {
            verify = ["ok": true, "valid": false, "already": true, "reason": "卡密已被使用",
                      "plan_name": "年付·专业版", "device_code": "A1B2-C3D4-E5F6-7788",
                      "expires_at": "2027-10-08"]
            check = ["ok": true, "exists": true, "status": "bound", "plan_name": "年付·专业版",
                     "days": 365, "device_code": "A1B2-C3D4-E5F6-7788", "username": "零砚",
                     "expires_at": "2027-10-08", "bound_at": "2026-10-01T09:20:00"]
            state = .done
            busy = false
            return
        }

        do {
            verify = try await API.shared.post("/api/v1/card/verify", body: ["card_code": c])
            if !verifyOnly {
                check = try await API.shared.get("/api/v1/card/check", query: ["card_code": c])
            }
            state = .done
        } catch {
            let e = error as? APIError
            state = .fail(e?.message ?? error.localizedDescription, e?.status ?? 0)
        }
        busy = false
    }
}
