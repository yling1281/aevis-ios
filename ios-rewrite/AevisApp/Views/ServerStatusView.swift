import SwiftUI
import UIKit
import Foundation

/// 服务器状态（2026-11-22 新增，照用户给的「服务器状态」参考图做）。
///
/// 两块内容都是**真实数据**，没有假按钮：
/// 1. 服务器：`APIClient.lines` 的每条线路（直连 / 北京，名字和条数都直接读 APIClient），
///    逐条 `APIClient.lineLatency(_:)` 实测延迟，列表按实测毫秒升序展示（不通置后）；
///    点某行 = `APIClient.setActiveLine(id)`（持久化键 `apiLineId`，与 APIClient 内部一致）。
///    「自动选择」= 按 `APIClient.lines` 的回落顺序自动切，标记存 `apiAutoLine`。
/// 2. 模型：`GET /v1/models/status`（服务端 `srv_edit/aevis_providers.py` 里就是给官网
///    「模型状态」用的公开接口，不返回任何 key）。按 DeepSeek / 双子星(gemini) / Claude
///    三组展示，每组最多 6 张卡（优先有探测数据的），不把 162 个模型全铺满。
///    每个模型一张磨砂卡：模型名 + 实时状态标签 + 成功率 / 「平均响应」（后端给了才显示）/
///    一排细竖条（一根 = 一个时间点，绿=正常 红=异常）。
///
/// **实时状态与成功率分开看**（用户反馈过「模型挂了还显示正常」）：
/// - 状态标签（正常/波动/异常/未监控）来自 `rows[].providers[].alive`，监控每 60 秒探一次；
/// - 百分比与竖条优先用 `recent`（近 30 分钟逐点 1/0），没有 `recent` 才回落 `history`
///   （30 分钟一桶，近 24 小时）；两种范围会在标题右上角如实写出；
/// - 顶部「数据更新于…」用非空探测桶的 `t + bucket_sec` 判断，不用接口的 `at`（那是请求时刻）。
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
    /// 探测数据覆盖到的最后时刻（epoch 秒）= 所有非空 history 桶里 `t + bucket_sec` 的最大值。
    ///
    /// 为什么不用接口的 `data.at`：实测生产接口里 `at` 是**服务端处理请求的时刻**（`_now()`），
    /// 永远是「刚刚」，拿它算滞后永远不会变橙（超 10 分钟那条分支等于死代码），反而会告诉用户
    /// 「数据是新的」。history 的 `t` 是真实探测桶的起始时间（epoch，跨时区安全），
    /// 非空桶的 `t + bucket_sec` 才是「数据实际覆盖到哪一刻」，监控停了它就不动了。
    @State private var probeCoverageEnd: Int?

    // MARK: - 数据模型

    private struct ModelStatus: Identifiable {
        let id: String          // model 名
        let live: LiveStatus    // 实时状态（来自 providers[].alive，最近一次探测）
        let rate: Double        // 0...1，时间范围内的成功率
        let samples: [Bool]     // 竖条：true = 正常（绿），false = 异常（红），按时间从左到右
        let rangeLabel: String  // 这批 samples 的时间范围："近 30 分钟" / "近 24 小时"
        let avgLatency: Double? // 平均响应秒数；服务端没给就是 nil，界面上不显示这一行
        let total: Int          // 时间范围内的总请求数（用于排序）
        let probes: Int         // 服务端探测次数
        let hasData: Bool       // false = 没有任何时间序列数据
        let coverageMinutes: Int // 服务端 coverage_minutes：实际有探测数据的分钟数（老服务端 0）
        let recentSource: String // 服务端 recent_source："provider_aggregate"（老服务端空串）
    }

    /// 实时状态。**不用 history 推**：history 是 30 分钟聚合，模型刚挂时那一桶还是绿的，
    /// 最多滞后半小时（用户就是这么发现「挂了还显示正常」的）。
    /// 这里取 `rows[].providers[].alive`，那个是监控进程每 60 秒探一次的最新结论。
    private enum LiveStatus: Equatable {
        case ok          // 至少一条 alive，且没有失败计数
        case unstable    // 至少一条 alive，但最近失败过（正在恢复）
        case down        // 一条 alive 都没有（全挂了）
        case unknown     // providers 为空：没有可判断的数据，不能当正常

        var text: String {
            switch self {
            case .ok:       return "正常"
            case .unstable: return "波动"
            case .down:     return "异常"
            case .unknown:  return "未监控"
            }
        }
    }

    /// 一组模型（DeepSeek / 双子星 / Claude）。
    /// `matched` = 该关键词命中的模型总数；四个 count 是**整组**的实时状态汇总
    /// （不是只统计列出来的几行），这样没调用数据的模型也不会被藏起来。
    private struct ModelGroup: Identifiable {
        let id: String
        let title: String
        let matched: Int
        let okCount: Int
        let unstableCount: Int
        let downCount: Int
        let unknownCount: Int
        let models: [ModelStatus]
    }

    /// 分组规则：model 名（不区分大小写）包含 key 就归到这组。
    /// DeepSeek / 双子星(gemini) / Claude 是我们实际在卖的三个模型家族。
    private let groupSpecs: [(id: String, title: String, key: String)] = [
        ("deepseek", "DeepSeek", "deepseek"),
        ("gemini",   "双子星",    "gemini"),
        ("claude",   "Claude",   "claude")
    ]

    // 状态语义色：与登录页线路四档（LK）同一套色值，浅色/深色各一套。
    // 两边都是「同一个意思同一种绿」，避免用户连着看发现两页配色不一致。
    // （暂时各自复制在这里，没有抽公共常量；若以后统一到 AE / GlassComponents，两边一起换引用即可。）
    private let goodGreen = Color.adaptive(dark: Color.hex(0x6FCF97), light: Color.hex(0x1E7A4E))
    /// 次优（80–200ms）：黄绿
    private let limeGreen = Color.adaptive(dark: Color.hex(0xB7D06A), light: Color.hex(0x6B8F1B))
    private let warnOrange = Color.adaptive(dark: Color.hex(0xF0B36B), light: Color.hex(0xB26A00))
    private let badRed = Color.adaptive(dark: Color.hex(0xF08A84), light: Color.hex(0xC0392B))
    /// 模型百分比 < 95% 时的橙色（参考图指定 #E2932F）
    private let percentWarn = Color.hex(0xE2932F)

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                currentCard

                freshnessRow

                groupCard(title: "服务器") {
                    autoRow
                    ForEach(displayLines) { line in
                        divider
                        lineRow(line)
                    }
                }

                modelsBlock

                hint("模型左侧标签（正常 / 波动 / 异常 / 未监控）按服务端最近一次探测的 providers 判定，是「此刻还能不能用」；右侧百分比与竖条是时间范围内的成功率（有 recent 用近 30 分钟，否则回落 history 的近 24 小时），两者不是一回事。延迟超过 3 秒记为不通。")
                if usesProviderAggregate {
                    hint("百分比与竖条为 provider 级聚合：按模型挂载渠道的探测逐分钟合并，非逐模型对话探测。")
                }
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

    // MARK: - 数据时间（页面顶部）

    /// 模型状态的数据时间：用「探测桶覆盖到的最后时刻」（history 里非空桶的 `t + bucket_sec`），
    /// 不是接口的 `data.at`（那个是请求时刻，永远显示「刚刚」）。
    /// 超过 10 分钟标橙，提示监控可能停了；完全没有探测数据时明确写「暂无探测数据」。
    @ViewBuilder
    private var freshnessRow: some View {
        if modelsLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在获取模型数据…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else if modelsFailed {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(warnOrange)
                Text("模型数据获取失败，下方标签可能不是最新")
                    .font(.system(size: 11.5))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else if hasFreshnessInfo {
            let minutes = freshMinutes
            let stale = (minutes ?? 0) > 10
            HStack(spacing: 6) {
                Image(systemName: stale ? "clock.badge.exclamationmark" : "clock")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(stale ? warnOrange : AE.textSecondary)
                Text(freshnessText(minutes, stale: stale))
                    .font(.system(size: 11.5))
                    .foregroundStyle(stale ? warnOrange : AE.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        } else {
            EmptyView()
        }
    }

    /// 距数据覆盖时刻的分钟数；没有探测数据时返回 nil
    private var freshMinutes: Int? {
        guard let end = probeCoverageEnd else { return nil }
        return max(0, Int(Date().timeIntervalSince1970) - end) / 60
    }

    /// 有没有可展示的数据时间（= 至少有一个非空探测桶）
    private var hasFreshnessInfo: Bool {
        probeCoverageEnd != nil
    }

    private func freshnessText(_ minutes: Int?, stale: Bool) -> String {
        guard let m = minutes else {
            // 全表 24 小时内没有任何探测记录：别拿接口的 at 充数，直接说没有数据
            return "暂无探测数据（监控可能未运行）"
        }
        let base: String
        if m <= 0 {
            base = "数据刚刚更新"
        } else if m < 60 {
            base = "数据更新于 \(m) 分钟前"
        } else if m < 60 * 24 {
            base = "数据更新于 \(m / 60) 小时前"
        } else {
            base = "数据更新于 \(m / 60 / 24) 天前"
        }
        return stale ? base + " · 可能已滞后" : base
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

                // 「最快」按实测动态判定 displayLines.first；不写回 line.note（它保持静态语义）。
                // 其余短注（备用等）照旧显示，与登录页线路胶囊文案保持一致。
                if isFastest(line) {
                    Text("最快")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(goodGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(goodGreen.opacity(0.14), in: Capsule())
                } else if !line.note.isEmpty && line.note != "最快" {
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

    /// 模型区：标题行（左「模型」右时间范围）+ 三组卡片。
    /// 每个模型是**独立磨砂卡**（20 圆角 / 16 内边距 / 10 间距，照参考图），
    /// 所以这一块不再套 `groupCard`，避免卡片套卡片。
    private var modelsBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("模型")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(AE.textSecondary)
                Spacer()
                if !groups.isEmpty {
                    Text(seriesRangeLabel)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AE.textSecondary)
                }
            }
            .padding(.horizontal, 4)

            modelsSection
        }
    }

    @ViewBuilder
    private var modelsSection: some View {
        if modelsLoading {
            // 顶部 freshnessRow 已经有「正在获取模型数据…」文案，这里只留一个居中转圈
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .frame(height: 44)
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
            .padding(16)
            .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.18)
        } else if groups.isEmpty {
            Text("暂无模型数据")
                .font(.system(size: 13))
                .foregroundStyle(AE.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 48)
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { g in
                    modelGroupBlock(g)
                }
            }
        }
    }

    /// 一组（DeepSeek / 双子星 / Claude）：组名 + 命中数 + 整组实时状态汇总，
    /// 下面最多 6 张模型卡。
    private func modelGroupBlock(_ g: ModelGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(g.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AE.textPrimary)
                Text("\(g.matched) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(AE.textSecondary)
                Spacer(minLength: 4)
                countsRow(g)
            }
            .padding(.horizontal, 4)

            if g.models.isEmpty {
                Text("暂无调用记录（实时状态见组头汇总）")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 10) {
                    ForEach(g.models) { m in
                        modelCard(m)
                    }
                }
            }
        }
    }

    /// 「正常 3 · 波动 19 · 异常 15」——只显示非零项，颜色与标签一致。
    /// 用 HStack 而不是 Text 拼接，避免 `.foregroundColor` 在 iOS 17 上的弃用告警。
    private func countsRow(_ g: ModelGroup) -> some View {
        var items: [(String, Color)] = []
        if g.okCount > 0 { items.append(("正常 \(g.okCount)", goodGreen)) }
        if g.unstableCount > 0 { items.append(("波动 \(g.unstableCount)", warnOrange)) }
        if g.downCount > 0 { items.append(("异常 \(g.downCount)", badRed)) }
        if g.unknownCount > 0 { items.append(("未监控 \(g.unknownCount)", AE.textSecondary)) }

        return HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 {
                    Text("·")
                        .font(.system(size: 10.5))
                        .foregroundStyle(AE.textSecondary)
                }
                Text(pair.element.0)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(pair.element.1)
                    .lineLimit(1)
            }
        }
        .minimumScaleFactor(0.85)
    }

    /// 单个模型卡（照参考图）：模型名 / 右侧「实时状态胶囊 + 百分比」/ 平均响应（有才显示）/ 竖条序列。
    private func modelCard(_ m: ModelStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 2.9 窄屏适配：名字 + 状态胶囊 + 百分比挤不下时换成两行，
            // 不让三者互相压扁；深色下颜色沿用各语义色的 adaptive 版本。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(displayName(m.id))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AE.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Spacer(minLength: 8)

                    statusBadge(m.live)

                    Text(m.hasData ? percentText(m.rate) : "—")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(m.hasData ? percentColor(m.rate) : AE.textSecondary)
                        .layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(displayName(m.id))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AE.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Spacer(minLength: 4)
                        statusBadge(m.live)
                    }
                    Text(m.hasData ? percentText(m.rate) : "—")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(m.hasData ? percentColor(m.rate) : AE.textSecondary)
                }
            }

            // 只有服务端给了 avg_latency_sec 才显示，没给就不占位、不编数字
            if let avg = m.avgLatency {
                Text("平均响应 \(latencySecondsText(avg))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(AE.textSecondary)
            }

            seriesBars(m.samples)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: AE.cardRadius, material: .regular, tintOpacity: 0.20)
        .shadow(color: AE.shadowColor, radius: 8, y: 3)
    }

    /// 一根根细竖条：目标 3pt 宽、14pt 高、圆角 1.5，从左到右是时间顺序。
    /// 根数不写死（recent 有几个点画几根 / history 有几个非空桶画几根）；
    /// 根数少时把多余宽度摊进间距把整行铺满，根数多时自动变细以免溢出。
    /// 算每根竖条的宽度与间距：根数少时把富余宽度摊进间距，根数多时自动变细，整行铺满不溢出。
    /// ⚠️ 必须放在普通函数里：ViewBuilder 闭包内不允许 `var` 与赋值语句
    /// （会报 `'buildExpression' is unavailable: this expression does not conform to 'View'`）。
    private func barMetrics(count n: Int, usable: CGFloat) -> (w: CGFloat, gap: CGFloat) {
        guard n > 0 else { return (3, 2) }
        var barW: CGFloat = 3
        var gap: CGFloat = 2
        let needed = barW * CGFloat(n) + gap * CGFloat(n - 1)
        if needed > usable {
            gap = 1
            barW = max(1, (usable - gap * CGFloat(n - 1)) / CGFloat(n))
        } else {
            gap = min(8, (usable - barW * CGFloat(n)) / CGFloat(max(n - 1, 1)))
        }
        return (barW, gap)
    }

    private func seriesBars(_ samples: [Bool]) -> some View {
        GeometryReader { geo in
            let usable = max(geo.size.width, 1)
            let m = barMetrics(count: samples.count, usable: usable)

            ZStack(alignment: .leading) {
                // 一条很淡的轴线：数据点还少（后端刚开始按分钟记，很多模型只有 1–2 格）时，
                // 也不至于看起来像「卡片空了一行」，能看出这是条时间轴。
                RoundedRectangle(cornerRadius: 1)
                    .fill(AE.textSecondary.opacity(0.10))
                    .frame(width: usable, height: 2)

                HStack(spacing: m.gap) {
                    if samples.isEmpty {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(AE.textSecondary.opacity(0.14))
                            .frame(width: usable, height: 14)
                    } else {
                        ForEach(Array(samples.enumerated()), id: \.offset) { pair in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(pair.element ? goodGreen : badRed)
                                .frame(width: m.w, height: 14)
                        }
                    }
                }
                .frame(width: usable, alignment: .leading)
            }
            .frame(width: usable, height: 14, alignment: .leading)
        }
        .frame(height: 14)
    }

    /// 实时状态小胶囊。颜色与延迟四档同一套语义色。
    private func statusBadge(_ s: LiveStatus) -> some View {
        let tint = statusColor(s)
        return Text(s.text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .fixedSize()
    }

    private func statusColor(_ s: LiveStatus) -> Color {
        switch s {
        case .ok:       return goodGreen
        case .unstable: return warnOrange
        case .down:     return badRed
        case .unknown:  return AE.textSecondary
        }
    }

    /// 百分比配色：≥95% 用主文字色（墨色），低于 95% 用橙色
    private func percentColor(_ rate: Double) -> Color {
        rate >= 0.95 ? AE.textPrimary : percentWarn
    }

    /// 平均响应：一位小数 + 秒
    private func latencySecondsText(_ sec: Double) -> String {
        String(format: "%.1f 秒", sec)
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

    /// 展示排序（纯视图语义，与回落顺序完全解耦 —— 不改 `APIClient.orderedLines` 一行）：
    /// 1. 有实测延迟（`latencies`）的按毫秒升序；同毫秒按 `APIClient.lines` 原序，稳定不跳；
    /// 2. 不通/未测的排在后面，彼此仍保持 `APIClient.lines` 原序。
    /// 只喂给线路列表的 `ForEach`；`select(_:)` / `currentLine` / `activeID` / 失败记忆全部按 id
    /// 工作，不受展示顺序影响 —— 用户手动选择不会被「最快」标识覆盖。
    private var displayLines: [APIClient.Line] {
        APIClient.lines.enumerated().sorted { a, b in
            let ma = latencies[a.element.id]
            let mb = latencies[b.element.id]
            switch (ma, mb) {
            case let (la?, lb?):
                return la == lb ? a.offset < b.offset : la < lb
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.offset < b.offset
            }
        }.map { $0.element }
    }

    /// 动态「最快」：只有排在第一且确有实测延迟的行才显示，不改写 `line.note`。
    private func isFastest(_ line: APIClient.Line) -> Bool {
        guard latencies[line.id] != nil else { return false }
        return displayLines.first?.id == line.id
    }

    /// 地域描述按线路**名字**匹配（不写死 id，线路表改名/增删这里自动跟上）
    /// 只出纯地名：直连 / 北京，不上屏 IP 或工程词；无匹配时原样返回名字。
    private func regionText(for line: APIClient.Line) -> String {
        let n = line.name
        if n.contains("北京") { return "中国·北京" }
        if n.contains("直连") { return "直连" }
        return n
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

    /// 延迟四档（与登录页线路选择同一套阈值）：
    /// ≤80ms 绿 / 80–200ms 黄绿 / 200–500ms 橙 / >500ms 红；不通整段红。
    private func latencyColor(for line: APIClient.Line) -> Color {
        guard let ms = latencies[line.id] else {
            return probed ? badRed : AE.textSecondary
        }
        if ms <= 80 { return goodGreen }
        if ms <= 200 { return limeGreen }
        if ms <= 500 { return warnOrange }
        return badRed
    }

    /// 卡片右上角的大号百分比：整数即可（参考图就是 100% / 98% 这种）
    private func percentText(_ rate: Double) -> String {
        String(format: "%.0f%%", rate * 100)
    }

    /// 顶部右侧的时间范围：按实际数据源写（有 recent 用「近 30 分钟」，否则「近 24 小时」）。
    /// 混着出现时两个都写，不统一成一个，避免骗人。
    private var seriesRangeLabel: String {
        let labels = Set(groups.flatMap { $0.models }.map { $0.rangeLabel })
        if labels.isEmpty { return "近 24 小时" }
        if labels.count == 1 { return labels.first ?? "近 24 小时" }
        return "近 30 分钟 / 近 24 小时"
    }

    /// 服务端是否下发了「provider 级聚合」口径（方案 A 新增可选字段）。
    /// 老服务端缺字段时不显示这条说明，保持向后兼容。
    private var usesProviderAggregate: Bool {
        groups.flatMap { $0.models }.contains { $0.recentSource == "provider_aggregate" }
    }

    /// 我们实际在用的三个模型（probes 常为 0，但必须列出来）
    private static func isCoreModel(_ id: String) -> Bool {
        switch id.lowercased() {
        case "deepseek-flash", "deepseek-chat", "deepseek-reasoner": return true
        default: return false
        }
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
        // 先把「当前生效线路」对齐一次：APIClient.activeLine 现算 UserDefaults，
        // 别处（登录页线路半窗 / request 自动回落）改过 apiLineId 后 SwiftUI 不会自动重绘，
        // 所以每次进页 / 点刷新都重新读一遍，避免顶部卡还停在旧线路上。
        activeID = APIClient.activeLine.id
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
            let data = (json["data"] as? [String: Any]) ?? json
            // 真实数据覆盖时刻：所有非空 history 桶的 t + bucket_sec 取最大
            // （接口的 data.at 是请求时刻，永远是「刚刚」，不能用来判断滞后）
            let coverage = latestProbeCoverageEnd(data)
            await MainActor.run {
                groups = parsed
                probeCoverageEnd = coverage
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

    /// 探测数据覆盖到的最后时刻（epoch 秒）：所有「非空」history 桶的 `t + bucket_sec` 取最大。
    ///
    /// `t` 是桶起始时间（epoch，服务端 `probe_history` 生成），跨时区无歧义；
    /// 空桶（total == 0）不算，否则没探测过的时段也会被当成「有数据」。
    /// 全部为空时返回 nil，界面显示「暂无探测数据」。
    private func latestProbeCoverageEnd(_ data: [String: Any]) -> Int? {
        let bucket = (data["bucket_sec"] as? NSNumber)?.intValue ?? 1800
        let rows = (data["rows"] as? [[String: Any]]) ?? []
        var newest: Int?
        for row in rows {
            for h in (row["history"] as? [[String: Any]]) ?? [] {
                let total = (h["total"] as? NSNumber)?.intValue ?? 0
                guard total > 0 else { continue }
                let t = (h["t"] as? NSNumber)?.intValue ?? 0
                guard t > 0 else { continue }
                let end = t + bucket
                if newest == nil || end > newest! { newest = end }
            }
        }
        return newest
    }

    // MARK: - 解析

    /// 把 162 个 model 行按 DeepSeek / 双子星 / Claude 分组。
    ///
    /// 行列表（每组最多 6 行）只放「有调用数据」+「我们实际在用的 deepseek 三个」：
    /// 没有 history 的模型，各种排序都只能按名字挑，容易挑出一堆恰好全挂的名字，
    /// 看起来像整组都坏了（实测 Gemini/Claude 组就会这样）。
    /// 所以这类模型的实时状态改用**组头汇总**呈现（正常 X · 波动 Y · 异常 Z），
    /// 统计的是整组，不遗漏。
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
            let candidates = parsed.filter { $0.id.lowercased().contains(spec.key) }

            // 整组实时状态汇总
            var ok = 0, unstable = 0, down = 0, unknown = 0
            for m in candidates {
                switch m.live {
                case .ok:       ok += 1
                case .unstable: unstable += 1
                case .down:     down += 1
                case .unknown:  unknown += 1
                }
            }

            var list = candidates.filter { $0.hasData || Self.isCoreModel($0.id) }
            list.sort { a, b in
                if a.probes != b.probes { return a.probes > b.probes }
                // 探测数都为 0 时，先列我们实际在用的三个
                let pa = Self.isCoreModel(a.id) ? 0 : 1
                let pb = Self.isCoreModel(b.id) ? 0 : 1
                if pa != pb { return pa < pb }
                if a.total != b.total { return a.total > b.total }
                return a.id < b.id      // 同分时按名字，保证每次刷新顺序一致
            }
            return ModelGroup(
                id: spec.id,
                title: spec.title,
                matched: matchedCount[spec.id] ?? 0,
                okCount: ok,
                unstableCount: unstable,
                downCount: down,
                unknownCount: unknown,
                models: Array(list.prefix(6))
            )
        }
    }

    /// 解析一行模型。时间序列按契约降级：
    /// 1. `recent`（近 30 分钟，1=正常 0=异常）→ 竖条与百分比都用它，范围「近 30 分钟」
    /// 2. 没有 `recent` → 用 `history`（30 分钟一桶，共 24 小时），只取有探测量的桶，
    ///    桶内全成功算绿、否则红；范围「近 24 小时」
    /// 3. 两者都没有 → `hasData = false`，卡片显示「—」和一条灰色占位条
    ///
    /// `avg_latency_sec` 有才显示「平均响应」，没有就 nil（界面不占位、不编数字）。
    private func build(_ row: [String: Any]) -> ModelStatus? {
        let model = (row["model"] as? String) ?? ""
        guard !model.isEmpty else { return nil }

        let avg = (row["avg_latency_sec"] as? NSNumber)?.doubleValue

        var samples: [Bool] = []
        var rate = 0.0
        var total = 0
        var range = ""

        // 1) recent：近 30 分钟逐点序列（契约 1=正常 / 0=异常；按 ≥0.5 判绿，兼容 0.0~1.0 的写法）
        if let raw = row["recent"] as? [Any], !raw.isEmpty {
            let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
            if values.count == raw.count, !values.isEmpty {
                samples = values.map { $0 >= 0.5 }
                let ok = samples.filter { $0 }.count
                rate = Double(ok) / Double(values.count)
                total = values.count
                range = "近 30 分钟"
            }
        }

        // 2) 降级：history 30 分钟一桶（空桶跳过，不把「没探测过」画成红）
        if samples.isEmpty {
            let history = (row["history"] as? [[String: Any]]) ?? []
            var okSum = 0
            var totalSum = 0
            var histSamples: [Bool] = []
            for h in history {
                let t = (h["total"] as? NSNumber)?.intValue ?? 0
                guard t > 0 else { continue }
                let ok = (h["ok"] as? NSNumber)?.intValue ?? 0
                okSum += ok
                totalSum += t
                histSamples.append(ok >= t)     // 一格里全成功才绿
            }
            if totalSum > 0 {
                samples = histSamples
                rate = Double(okSum) / Double(totalSum)
                total = totalSum
                range = "近 24 小时"
            }
        }

        let probes = (row["probes"] as? NSNumber)?.intValue ?? total
        // 方案 A 新增可选字段：老服务端没有这两个键时给 0 / ""，客户端照旧降级，不崩、不 forcing update。
        let coverageMinutes = (row["coverage_minutes"] as? NSNumber)?.intValue ?? 0
        let recentSource = (row["recent_source"] as? String) ?? ""

        return ModelStatus(
            id: model,
            live: liveStatus(row),
            rate: min(max(rate, 0), 1),
            samples: samples,
            rangeLabel: range.isEmpty ? "近 24 小时" : range,
            avgLatency: avg,
            total: total,
            probes: probes,
            hasData: !samples.isEmpty,
            coverageMinutes: coverageMinutes,
            recentSource: recentSource
        )
    }

    /// 实时状态判定（来自 `rows[].providers[]`，监控每 60 秒探一次）。
    ///
    /// ⚠️ 不按「任一 alive == false 就异常」：实测生产 162 个模型里有 133 个至少挂着一个
    /// 已废弃的 provider（如「线路一」2026-11-16 后就没成功过，却仍挂在模型上），
    /// 照字面判会把 82% 的模型涂红，其中大多数其实靠备用线路正常服务。
    /// 所以按「**还有没有可用线路**」判：
    /// - providers 为空              → 未监控（灰，绝不显示正常）
    /// - 没有任何 provider alive      → 异常（红，真的没有路可走）
    /// - 有 alive，但 alive 的 provider 有 fail_count → 波动（黄，最近失败过、正在恢复）
    /// - 其余（至少一条 alive 且干净）→ 正常（绿）
    /// 挂掉的冗余线路不直接决定颜色；它们的影响体现在「可用线路是否只剩 0 条」。
    private func liveStatus(_ row: [String: Any]) -> LiveStatus {
        let providers = (row["providers"] as? [[String: Any]]) ?? []
        guard !providers.isEmpty else { return .unknown }

        var aliveCount = 0
        var aliveFailSum = 0
        for p in providers {
            guard (p["alive"] as? Bool) == true else { continue }
            aliveCount += 1
            aliveFailSum += (p["fail_count"] as? NSNumber)?.intValue ?? 0
        }
        if aliveCount == 0 { return .down }
        return aliveFailSum > 0 ? .unstable : .ok
    }
}
