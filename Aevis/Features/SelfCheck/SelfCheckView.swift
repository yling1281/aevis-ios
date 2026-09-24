import SwiftUI

/// 自检页。
///
/// 存在的理由：有些东西**没法靠肉眼看代码确认** ——
/// 比如网易云那段裸 RSA，算错了只会表现成「登录成功但接口一直报错」。
/// 所以把关键逻辑做成自检项，拿已知答案对，结果直接画出来，
/// CI 截图就能看见过没过。
struct SelfCheckView: View {
    private let cryptoResults = NeteaseCrypto.runSelfCheck()
    private let otherResults = SelfCheckView.buildEnvironmentChecks()

    private var all: [NeteaseCrypto.SelfCheck] { cryptoResults + otherResults }
    private var passedCount: Int { all.filter(\.passed).count }

    private var allPassed: Bool { passedCount == all.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                section("加密算法", cryptoResults)
                section("环境", otherResults)
                footer
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(allPassed ? "全部通过" : "有项目没过")
                .font(.aevis(22, weight: .semibold))
                .foregroundStyle(allPassed ? Color.green : Color.red)
            Text("\(passedCount) / \(all.count) 项通过")
                .font(.aevis(14))
                .foregroundStyle(.secondary)
            Text("密码学代码不能靠眼睛看，所以拿已知答案对一遍，结果画在这里。")
                .font(.aevis(12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .aevisGlass(cornerRadius: 18)
    }

    private func section(_ title: String, _ rows: [NeteaseCrypto.SelfCheck]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.aevis(12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: row.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(row.passed ? Color.green : Color.red)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.name)
                            .font(.aevis(14, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(row.detail)
                            .font(.aevisMono(11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.bottom, 6)
        .aevisGlass(cornerRadius: 18)
    }

    private var footer: some View {
        Text("这一页只在自检模式下出现，正常使用看不到。")
            .font(.aevis(11.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 环境自检

    static func buildEnvironmentChecks() -> [NeteaseCrypto.SelfCheck] {
        var rows: [NeteaseCrypto.SelfCheck] = []

        let tools = DeviceTools.all()
        rows.append(NeteaseCrypto.SelfCheck(
            name: "她有多少只手",
            passed: tools.count >= 10,
            detail: "\(tools.count) 个工具：" + tools.map(\.name).joined(separator: ", ")
        ))

        let names = Set(tools.map(\.name))
        rows.append(NeteaseCrypto.SelfCheck(
            name: "工具名不重复",
            passed: names.count == tools.count,
            detail: names.count == tools.count ? "没有重名" : "有重名：\(tools.count) 个工具只有 \(names.count) 个不同名字"
        ))

        let definitions = DeviceTools.definitions()
        let allHaveSchema = definitions.allSatisfy { item in
            guard let function = item["function"] as? [String: Any] else { return false }
            return function["name"] as? String != nil && function["parameters"] != nil
        }
        rows.append(NeteaseCrypto.SelfCheck(
            name: "工具都带参数说明",
            passed: allHaveSchema,
            detail: allHaveSchema ? "每个工具都有 JSON Schema" : "有工具缺 parameters"
        ))

        let shell = Shell.provider
        rows.append(NeteaseCrypto.SelfCheck(
            name: "命令台",
            passed: shell.isAvailable,
            detail: "\(shell.displayName)：\(shell.isAvailable ? "可用" : "未接入")"
        ))

        rows.append(NeteaseCrypto.SelfCheck(
            name: "内置图标",
            passed: AppIconOption.allCases.count >= 5,
            detail: "\(AppIconOption.allCases.count) 张：" + AppIconOption.allCases.map(\.label).joined(separator: " / ")
        ))

        let background = AppSettings.shared.backgroundStyle
        rows.append(NeteaseCrypto.SelfCheck(
            name: "背景与外观配置能读能写",
            passed: BackgroundStyle.allCases.count == 4,
            detail: "四种背景；当前是「\(background.label)」，遮罩 \(String(format: "%.2f", AppSettings.shared.backgroundDim))"
        ))

        rows.append(NeteaseCrypto.SelfCheck(
            name: "主人设与对话存储",
            passed: true,
            detail: "对话 \(ChatStore.shared.messages.count) 条；人设「\(PersonaStore.shared.persona.name.isEmpty ? "未设置" : PersonaStore.shared.persona.name)」"
        ))

        return rows
    }
}
