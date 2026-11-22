import SwiftUI
import UIKit
import Foundation

/// 服务器状态（2026-11-22 新增，照用户给的「服务器状态」参考图做）。
///
/// 两块内容都是**真实数据**，没有假按钮：
/// 1. 服务器：`APIClient.lines` 的每条线路（陕西 / 北京 / 香港，名字和条数都直接读 APIClient），
///    逐条 `APIClient.lineLatency(_:)` 实测延迟；
///    点某行 = `APIClient.setActiveLine(id)`（持久化键 `apiLineId`，与 APIClient 内部一致）。
///    「自动选择」= 按 `APIClient.lines` 的回落顺序自动切，标记存 `apiAutoLine`。
/// 2. 模型：`GET /v1/models/status`（服务端 `srv_edit/aevis_providers.py` 里就是给官网
///    「模型状态」用的公开接口，不返回任何 key）。按 DeepSeek / 双子星(gemini) / Claude
///    三组展示，每组最多 6 行（优先有探测数据的），不把 162 个模型全铺满。
///
/// 本文件自己发请求（不改 APIClient，别的地方在用），复用 `APIClient.session`
/// （直连这条带自签证书 pinning，自己新建 URLSession 会 SSL 失败）。
struct ServerStatusView: View {
    @EnvironmentObject private var session: Session

    /// 自动选择（按回落顺序切）。用户点了具体线路就置 false。
    @AppStorage("apiAutoLine") private var autoLine = true

    // 线路延迟：只存成功的，缺 = 不通
    @State private var latencies: [String: Int] = [:]
    @State private var probed = false
    @State private var probing = false
    @State private var activeID = APIClient.activeLine.id

    // 模型状态（按 DeepSeek / 双子星 / Claude 三组展示）
    @State private var groups: [ModelGroup] = []
    @State private var modelsLoading = true
    @State private var modelsFailed = false
    @State private var modelsLoadedAt = ""

    // MARK: - 数据模型

    private struct ModelStatus: Identifiable {
        let id: String          // model 名
        let rate: Double        // 0...1（history 汇总）
        let total: Int          // history 里总请求数
        let probes: Int         // 服务端探测次数
        let hasData: Bool       // false = 24 小时内没有任何探测记录
        let bars: [Bar]         // 每个 history 桶（30 分钟一格，共 48 格 = 24 小时）
    }

    /// 一个统计桶。`empty`（total == 0）是没有探测记录，不是"挂了"，
    /// 所以画浅灰底，不按 0% 涂红 —— 服务端这类空桶的 rate 也是 0，直接用会全部变红。
    private struct Bar: Identifiable {
        let id: Int
        let rate: Double
        let empty: Bool
    }

    /// 一组模型（DeepSeek / 双子星 / Claude）。`matched` = 该关键词命中的模型总数。
    private struct ModelGroup: Identifiable {
        let id: String
        let title: String
        let matched: Int
        let models: [ModelStatus]
    }

    /// 分组规则：model 名（不区分大小写）包含 key 就归到这组。
    /// DeepSeek / 双子星(gemini) / Claude 是我们实际在卖的三个模型家族。
    private let groupSpecs: [(id: String, title: String, key: String)] = [
        ("deepseek", "DeepSeek", "deepseek"),
        ("gemini",   "双子星",    "gemini"),
        ("claude",   "Claude",   "claude")
    ]

    private let goodGreen = Color.hex(0x36B36B)
    /// 次优（80–200ms）：黄绿，与登录页线路胶囊同一套四档阈值
    private let limeGreen = Color.hex(0x84B93A)
    private let warnOrange = Color.hex(0xE2932F)
    private let badRed = Color.hex(0xE0484D)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                currentCard

                groupCard(title: "服务器") {
                    autoRow
                    ForEach(APIClient.lines) { line in
                        divider
                        lineRow(line)
                    }
                }

                groupCard(title: "模型", trailing: "近 24 小时 · 30 分钟/格") {
                    modelsSection
                }

                hint("延迟来自本机实时探测，超过 3 秒记为不通。模型可用率取 history 里 ok/total 汇总（服务端给 48 格，每格 30 分钟；浅灰格 = 该时段没有探测记录）。")
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 40)
        }
        .background(Color.paper)
        .navigationTitle("服务器状态")
        .navigationBarTitleDisplayMode(.inline)
        // 从设置 tab push 进来时收起底部原生 TabBar（系统不会自动收，由目的页声明）；
        // 返回设置页会自动恢复。与 ChatView 同一写法。
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if probing || modelsLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .disabled(probing || modelsLoading)
            }
        }
        .task { await refreshAll() }
    }

    // MARK: - 顶部：当前状态

    private var currentCard: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(currentLineName)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(AE.textPrimary)
                Text(regionText(for: currentLine))
                    .font(.system(size: 12))
                    .foregroundStyle(AE.textSecondary)
            }

            Spacer(minLength: 6)

            if autoLine {
                Text("自动")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(AE.accentSoft, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    // MARK: - 服务器分组

    private var autoRow: some View {
        Button {
            selectAuto()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AE.accent)
                    .frame(width: 22)
                Text("自动选择")
                    .font(.system(size: 15.5))
                    .foregroundStyle(AE.textPrimary)
                Spacer(minLength: 8)
                if autoLine {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AE.accent)
                }
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func lineRow(_ line: APIClient.Line) -> some View {
        Button {
            select(line)
        } label: {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor(for: line))
                    .frame(width: 8, height: 8)

                Text(line.name)
                    .font(.system(size: 15.5))
                    .foregroundStyle(AE.textPrimary)

                // 短注（最快/默认/备用）：与登录页线路胶囊文案保持一致
                if !line.note.isEmpty {
                    Text(line.note)
                        .font(.system(size: 11))
                        .foregroundStyle(AE.textSecondary)
                }

                if activeID == line.id {
                    Text("使用中")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(AE.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(AE.accentSoft, in: Capsule())
                }

                Spacer(minLength: 8)

                Text(latencyText(for: line))
                    .font(.system(size: 12.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(latencyColor(for: line))

                if activeID == line.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(AE.accent)
                }
            }
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 模型分组

    @ViewBuilder
    private var modelsSection: some View {
        if modelsLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在获取模型状态…")
                    .font(.system(size: 13))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }
            .frame(height: 60)
        } else if modelsFailed {
            VStack(alignment: .leading, spacing: 10) {
                Text("状态获取失败")
                    .font(.system(size: 13.5))
                    .foregroundStyle(AE.textSecondary)
                Button {
                    Task { await loadModels() }
                } label: {
                    Text("重试")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AE.accent)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(AE.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if groups.isEmpty {
            Text("暂无模型数据")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { pair in
                    if pair.offset > 0 { divider }
                    modelGroupBlock(pair.element)
                }
                if !modelsLoadedAt.isEmpty {
                    Text("更新于 \(shortStamp(modelsLoadedAt))")
                        .font(.system(size: 11))
                        .foregroundStyle(AE.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 一组（DeepSeek / 双子星 / Claude）：组名 + 命中数量，下面最多 6 行模型。
    /// 该组一个可用数据都没有时写「暂无监控数据」，不硬凑 0%。
    private func modelGroupBlock(_ g: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(g.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Text("\(g.matched) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }

            if g.models.isEmpty {
                Text("暂无监控数据")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 11) {
                    ForEach(g.models) { m in
                        modelRow(m)
                    }
                }
            }
        }
    }

    private func modelRow(_ m: ModelStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayName(m.id))
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(AE.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                Text(m.hasData ? percentText(m.rate) : "—")
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(m.hasData ? barColor(m.rate) : AE.textSecondary)
            }

            barStrip(m.bars, height: 14)
        }
    }

    /// 绿/橙/红小方块条：每块 = 一个 30 分钟桶。
    private func barStrip(_ bars: [Bar], height: CGFloat = 18) -> some View {
        GeometryReader { geo in
            let n = max(bars.count, 1)
            let gap: CGFloat = 1.5
            let w = max(1.5, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(spacing: gap) {
                if bars.isEmpty {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(AE.textSecondary.opacity(0.16))
                        .frame(width: geo.size.width, height: height)
                } else {
                    ForEach(bars) { bar in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(bar.empty ? AE.textSecondary.opacity(0.16) : barColor(bar.rate))
                            .frame(width: w, height: height)
                    }
                }
            }
        }
        .frame(height: height)
    }

    // MARK: - 通用小组件

    @ViewBuilder
    private func groupCard<Content: View>(
        title: String, trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 2)

            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
                .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.18)
                .shadow(color: AE.shadowColor, radius: 8, y: 3)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(AE.textSecondary.opacity(0.14))
            .frame(height: 0.7)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(AE.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
    }

    // MARK: - 展示文案

    private var currentLine: APIClient.Line {
        APIClient.lines.first(where: { $0.id == activeID }) ?? APIClient.activeLine
    }

    private var currentLineName: String {
        autoLine ? "自动选择 · \(currentLine.name)" : currentLine.name
    }

    /// 地域描述按线路**名字**匹配（不写死 id，线路表改名/增删这里自动跟上）
    private func regionText(for line: APIClient.Line) -> String {
        let n = line.name
        if n.contains("香港") { return "中国·香港" }
        if n.contains("陕西") { return "中国·陕西" }
        if n.contains("北京") { return "中国·北京" }
        if n.contains("直连") { return "直连" }
        return line.note.isEmpty ? n : line.note
    }

    private var statusDotColor: Color {
        if !probed { return AE.textSecondary.opacity(0.4) }
        return latencies[currentLine.id] != nil ? goodGreen : badRed
    }

    private func dotColor(for line: APIClient.Line) -> Color {
        guard probed else { return AE.textSecondary.opacity(0.35) }
        return latencies[line.id] != nil ? goodGreen : badRed
    }

    private func latencyText(for line: APIClient.Line) -> String {
        if probing && latencies.isEmpty { return "…" }
        guard probed else { return "—" }
        if let ms = latencies[line.id] { return "\(ms) ms" }
        return "不通"
    }

    private func latencyColor(for line: APIClient.Line) -> Color {
        guard let ms = latencies[line.id] else {
            return probed ? badRed : AE.textSecondary
        }
        if ms < 300 { return goodGreen }
        if ms < 900 { return warnOrange }
        return badRed
    }

    private func percentText(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }

    /// 服务端 `at` 是 "2026-11-22 20:24:00"，只取 "11-22 20:24" 显示
    private func shortStamp(_ raw: String) -> String {
        guard raw.count >= 16 else { return raw }
        let start = raw.index(raw.startIndex, offsetBy: 5)
        let end = raw.index(raw.startIndex, offsetBy: 16)
        return String(raw[start..<end])
    }

    private func barColor(_ rate: Double) -> Color {
        if rate >= 0.99 { return goodGreen }
        if rate >= 0.9 { return warnOrange }
        return badRed
    }

    /// deepseek-flash → DeepSeek Flash（只做展示，id 仍用于匹配）
    private func displayName(_ id: String) -> String {
        id.split(separator: "-").map { part -> String in
            let s = String(part)
            if s.lowercased() == "deepseek" { return "DeepSeek" }
            return String(s.prefix(1)).uppercased() + String(s.dropFirst())
        }
        .joined(separator: " ")
    }

    // MARK: - 切换线路

    private func selectAuto() {
        autoLine = true
        // 自动 = 清掉所有失败标记，从回落顺序第一条重新开始试
        for l in APIClient.lines { APIClient.clearLineFailed(l.id) }
        APIClient.setActiveLine(APIClient.lines[0].id)
        activeID = APIClient.activeLine.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await loadModels() }   // 换线路后模型状态要重新拉
    }

    private func select(_ line: APIClient.Line) {
        autoLine = false
        APIClient.setActiveLine(line.id)
        activeID = APIClient.activeLine.id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await loadModels() }
    }

    // MARK: - 网络

    private func refreshAll() async {
        // 依次跑：先测线路，再按（可能已切换的）当前线路拉模型状态。
        // 用串行而不是 async let，避免在 View 里捕获 self 进并发闭包。
        await probeAll()
        await loadModels()
    }

    private func probeAll() async {
        await MainActor.run { probing = true }
        let lines = APIClient.lines
        var result: [String: Int] = [:]
        await withTaskGroup(of: (String, Int?).self) { group in
            for l in lines {
                group.addTask { (l.id, await APIClient.lineLatency(l)) }
            }
            for await (id, ms) in group {
                if let ms { result[id] = ms }
            }
        }
        let finalResult = result
        await MainActor.run {
            latencies = finalResult
            probed = true
            probing = false
        }
    }

    private func loadModels() async {
        await MainActor.run { modelsLoading = true; modelsFailed = false }
        do {
            let json = try await fetchModelStatus()
            let parsed = parseModels(json)
            // `at` 在 data 里（信封结构），顶层没有
            let data = (json["data"] as? [String: Any]) ?? json
            let stamp = (data["at"] as? String) ?? ""
            await MainActor.run {
                groups = parsed
                modelsLoadedAt = stamp
                modelsLoading = false
            }
        } catch {
            await MainActor.run {
                modelsFailed = true
                modelsLoading = false
            }
        }
    }

    /// 轻量 GET /v1/models/status。不改 APIClient（别人在用），但复用它的 session，
    /// 这样直连那条的自签证书 pinning 仍然生效。
    private func fetchModelStatus() async throws -> [String: Any] {
        let line = APIClient.activeLine
        guard !line.base.isEmpty, let url = URL(string: line.base + "/v1/models/status") else {
            throw APIError.http(0, "线路暂不可用")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = session.token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await APIClient.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw APIError.http(code, "状态接口返回 \(code)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decode("models/status 不是 JSON")
        }
        if let biz = (root["code"] as? NSNumber)?.intValue, biz != 200 && biz != 0 {
            throw APIError.http(biz, (root["msg"] as? String) ?? "状态接口失败")
        }
        return root
    }

    // MARK: - 解析

    /// 把 162 个 model 行按 DeepSeek / 双子星 / Claude 分组。
    /// 每组最多 6 行，优先「真有探测数据」的（probes > 0 且 history 有量），再按调用量排序；
    /// 没数据的模型不列出来（否则一堆 0% 红条会误导），整组都没数据时就显示「暂无监控数据」。
    private func parseModels(_ root: [String: Any]) -> [ModelGroup] {
        let data = (root["data"] as? [String: Any]) ?? root
        let rows = (data["rows"] as? [[String: Any]]) ?? []

        // 先全部解析一遍，避免重复计算 history
        var parsed: [ModelStatus] = []
        var matchedCount: [String: Int] = [:]
        for row in rows {
            guard let model = (row["model"] as? String)?.lowercased(),
                  !model.isEmpty else { continue }
            for spec in groupSpecs where model.contains(spec.key) {
                matchedCount[spec.id, default: 0] += 1
            }
            if let m = build(row) { parsed.append(m) }
        }

        return groupSpecs.map { spec in
            var list = parsed.filter { $0.id.lowercased().contains(spec.key) && $0.hasData }
            // 探测次数多的排前面，其次按总调用量
            list.sort { a, b in
                if a.probes != b.probes { return a.probes > b.probes }
                return a.total > b.total
            }
            return ModelGroup(
                id: spec.id,
                title: spec.title,
                matched: matchedCount[spec.id] ?? 0,
                models: Array(list.prefix(6))
            )
        }
    }

    private func build(_ row: [String: Any]) -> ModelStatus? {
        let model = (row["model"] as? String) ?? ""
        guard !model.isEmpty else { return nil }
        let history = (row["history"] as? [[String: Any]]) ?? []
        guard !history.isEmpty else { return nil }

        var okSum = 0
        var totalSum = 0
        var rateSum = 0.0
        var bars: [Bar] = []

        for (i, h) in history.enumerated() {
            let ok = (h["ok"] as? NSNumber)?.intValue ?? 0
            let total = (h["total"] as? NSNumber)?.intValue ?? 0
            let rate = (h["rate"] as? NSNumber)?.doubleValue ?? 0
            okSum += ok
            totalSum += total
            rateSum += rate
            bars.append(Bar(id: i, rate: min(max(rate, 0), 1), empty: total == 0))
        }

        let rate = totalSum > 0 ? Double(okSum) / Double(totalSum)
                               : rateSum / Double(history.count)
        let probes = (row["probes"] as? NSNumber)?.intValue ?? totalSum

        // 图片里条子大约 40 段；服务端给 48 段，只画最近 40 个桶
        let shown = bars.count > 40 ? Array(bars.suffix(40)) : bars
        return ModelStatus(id: model, rate: min(max(rate, 0), 1), total: totalSum,
                           probes: probes, hasData: totalSum > 0, bars: shown)
    }
}
