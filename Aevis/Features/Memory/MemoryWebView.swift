import SwiftUI

/// 记忆网：把一条条记忆真的**连起来**，画成一张网。
///
/// 不是给列表换张皮 —— 这里真的用 `Canvas` 手画节点和连线：
/// 每条记忆是一个节点，`linkIDs` 里连着的记忆之间拉一条线。
///
/// 布局是一次性的力导向：先从四簇起手（按 kind 摆在四个方位，簇内绕圈），
/// 再迭代 80 次（两两斥力 + 有连线的弹簧引力 + 一点点向心力），算完就冻住。
/// 记忆一多（> 300）就不跑力导向、改画一个简单圆环，免得卡住。
///
/// 坐标一路都在归一化空间（0...1）里算，画的时候才乘画布尺寸 + 平移 + 缩放。
struct MemoryWebView: View {
    @ObservedObject private var memory = MemoryStore.shared
    @ObservedObject private var settings = AppSettings.shared

    /// 归一化坐标。键是记忆 id。
    @State private var positions: [String: CGPoint] = [:]
    /// 上一次算布局时用的 id 列表 —— 拓扑没变就不重算。
    @State private var lastIDs: [String] = []

    /// 当前选中的节点。选中后高亮它和它的一级邻居。
    @State private var selectedID: String?

    // 平移 / 缩放。pan 是实时的，panAtStart 是这一轮手势开始前的落点。
    @State private var pan: CGSize = .zero
    @State private var panAtStart: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var zoomAtStart: CGFloat = 1

    var body: some View {
        ZStack {
            AevisBackground()
            Group {
                if memory.items.isEmpty {
                    emptyState
                } else {
                    webBody
                }
            }
        }
        .navigationTitle("记忆网")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onAppear { rebuildLayout() }
        .onChange(of: memory.items.count) { _, _ in
            reloadSelection()
            rebuildLayout()
        }
        .onChange(of: memory.items.map { $0.id }) { _, _ in
            reloadSelection()
            rebuildLayout()
        }
    }

    // MARK: - 主体

    private var webBody: some View {
        VStack(spacing: 12) {
            webCanvas

            if memory.items.count == 1 {
                Text("再多记几条，网才织得起来")
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
            }

            if let status = memory.statusLine, !status.isEmpty {
                Text(status)
                    .font(.aevis(11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            if let item = selectedItem {
                selectionCard(item)
            }

            legend
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 画布本体。就一个 `Canvas`，节点和线都在里面手画。
    private var webCanvas: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                renderWeb(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            // ⚠️ 用 `SpatialTapGesture`（iOS 16 起就有）而不是
            //    `onTapGesture(coordinateSpace:perform:)` —— 后者是 iOS 17 才加的重载，
            //    而本机**没有 Xcode、编译不了**，宁可挑门槛更低的那个，少一次翻车。
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        handleTap(value.location, size: proxy.size)
                    }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aevisGlass(cornerRadius: 22)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "circle.grid.3x3")
                .font(.aevis(34))
                .foregroundStyle(settings.accentColor.opacity(0.7))
            Text("还什么都没记住。先去聊几轮，或者回列表自己加一条。")
                .font(.aevis(13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .aevisGlass(cornerRadius: 22)
        .padding(16)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(MemoryItem.Kind.allCases) { kind in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: kind))
                        .frame(width: 8, height: 8)
                    Text(kind.label)
                        .font(.aevis(11.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("\(memory.items.count) 条")
                .font(.aevis(11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 选中的卡片

    private var selectedItem: MemoryItem? {
        guard let selectedID else { return nil }
        return memory.items.first { $0.id == selectedID }
    }

    private func neighborItems(of item: MemoryItem) -> [MemoryItem] {
        let linked = Set(item.linkIDs)
        return memory.items.filter { linked.contains($0.id) }
    }

    private func selectionCard(_ item: MemoryItem) -> some View {
        let neighbors = neighborItems(of: item)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: item.kind.symbol)
                    .font(.aevis(13))
                    .foregroundStyle(color(for: item.kind))
                Text(item.kind.label)
                    .font(.aevis(12))
                    .foregroundStyle(.secondary)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.aevis(11))
                        .foregroundStyle(settings.accentColor)
                }
                Spacer(minLength: 8)
                Button {
                    memory.togglePin(item)
                } label: {
                    Image(systemName: item.pinned ? "pin.slash" : "pin")
                        .font(.aevis(13))
                        .foregroundStyle(settings.accentColor)
                }
                .buttonStyle(.plain)
            }

            Text(item.text)
                .font(.aevis(14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if neighbors.isEmpty {
                Text("这条还没连上别的。重新织一次网就有了。")
                    .font(.aevis(11.5))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(neighbors) { neighbor in
                            Button {
                                selectedID = neighbor.id
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(color(for: neighbor.kind))
                                        .frame(width: 7, height: 7)
                                    Text(neighbor.text)
                                        .font(.aevis(12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.primary.opacity(0.06))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aevisGlass(cornerRadius: 18)
    }

    // MARK: - 顶部按钮

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                resetView()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel("复位")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await memory.weaveLinks(config: settings.llm, force: true) }
            } label: {
                if memory.weaving {
                    ProgressView()
                } else {
                    Text("重新织网")
                }
            }
            .disabled(memory.weaving || memory.items.count < 2)
        }
    }

    private func resetView() {
        pan = .zero
        panAtStart = .zero
        zoom = 1
        zoomAtStart = 1
    }

    // MARK: - 手势

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                pan = CGSize(
                    width: panAtStart.width + value.translation.width,
                    height: panAtStart.height + value.translation.height
                )
            }
            .onEnded { _ in
                panAtStart = pan
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = min(3.0, max(0.4, zoomAtStart * value.magnification))
            }
            .onEnded { _ in
                zoomAtStart = zoom
            }
    }

    /// 点画布：落在某个节点附近就选中它，点空白就取消选中。
    private func handleTap(_ point: CGPoint, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var hit: String?
        var best = CGFloat.greatestFiniteMagnitude
        for item in memory.items {
            guard let node = screenPoint(item.id, size: size, center: center) else { continue }
            let dx = node.x - point.x
            let dy = node.y - point.y
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < best {
                best = distance
                hit = item.id
            }
        }
        if let hit, best <= 26 {
            selectedID = hit
        } else {
            selectedID = nil
        }
    }

    // MARK: - 画

    private func renderWeb(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        let items = memory.items
        guard !items.isEmpty else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let accent = settings.accentColor
        let alive = Set(items.map { $0.id })

        let selected = selectedID
        let neighbors: Set<String> = {
            guard let selected,
                  let item = items.first(where: { $0.id == selected }) else { return [] }
            return Set(item.linkIDs)
        }()

        // 1) 线先画，压在节点下面。
        var painted = Set<String>()
        for item in items {
            guard let from = screenPoint(item.id, size: size, center: center) else { continue }
            for other in item.linkIDs where alive.contains(other) {
                let key = item.id < other ? item.id + "|" + other : other + "|" + item.id
                if painted.contains(key) { continue }
                painted.insert(key)
                guard let to = screenPoint(other, size: size, center: center) else { continue }

                var alpha = 0.30
                var width: CGFloat = 1
                if selected != nil {
                    if item.id == selected || other == selected {
                        alpha = 0.95
                        width = 2.2
                    } else {
                        alpha = 0.05
                        width = 1
                    }
                }
                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(accent.opacity(alpha)), lineWidth: width)
            }
        }

        // 2) 节点。
        for item in items {
            guard let point = screenPoint(item.id, size: size, center: center) else { continue }
            let active = selected == nil || item.id == selected || neighbors.contains(item.id)
            let nodeAlpha = active ? 1.0 : 0.22
            let radius = nodeRadius(for: item) * zoom
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            // 选中时，焦点和它的一级邻居都加一圈高亮。
            if selected != nil && active {
                let focused = (item.id == selected)
                context.stroke(
                    Path(ellipseIn: rect.insetBy(dx: -3.5, dy: -3.5)),
                    with: .color(accent.opacity(focused ? 0.75 : 0.4)),
                    lineWidth: focused ? 2.2 : 1.4
                )
            }

            let tint = color(for: item.kind)
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(nodeAlpha)))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.primary.opacity(0.20 * nodeAlpha)),
                lineWidth: 0.8
            )

            let symbol = Text(Image(systemName: item.kind.symbol))
                .font(.aevis(max(7, radius * 1.05)))
                .foregroundColor(Color.white.opacity(nodeAlpha))
            context.draw(symbol, at: point, anchor: .center)
        }
    }

    /// 归一化坐标 → 屏幕坐标（乘画布尺寸 + 绕中心缩放 + 平移）。
    private func screenPoint(_ id: String, size: CGSize, center: CGPoint) -> CGPoint? {
        guard let normalized = positions[id] else { return nil }
        let baseX = normalized.x * size.width
        let baseY = normalized.y * size.height
        return CGPoint(
            x: center.x + (baseX - center.x) * zoom + pan.width,
            y: center.y + (baseY - center.y) * zoom + pan.height
        )
    }

    /// 连线越多，点画得越大 —— 一眼能看出哪几条是这张网的枢纽。
    private func nodeRadius(for item: MemoryItem) -> CGFloat {
        6 + min(9, CGFloat(item.linkIDs.count) * 1.4)
    }

    /// 4 个 kind 各一个能分辨的颜色。
    private func color(for kind: MemoryItem.Kind) -> Color {
        switch kind {
        case .fact:
            return Color(red: 0.36, green: 0.60, blue: 0.98)
        case .preference:
            return Color(red: 0.95, green: 0.45, blue: 0.60)
        case .event:
            return Color(red: 0.42, green: 0.78, blue: 0.45)
        case .promise:
            return Color(red: 0.95, green: 0.68, blue: 0.28)
        }
    }

    // MARK: - 布局

    private func reloadSelection() {
        if let selectedID, !memory.items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func rebuildLayout() {
        let items = memory.items
        let ids = items.map { $0.id }
        if ids == lastIDs && !positions.isEmpty { return }
        lastIDs = ids

        guard !items.isEmpty else {
            positions = [:]
            return
        }
        positions = items.count > 300 ? ringLayout(items) : forceLayout(items)
    }

    /// 超过 300 条时用这个 —— 简单圆环，算得飞快，不会把界面卡住。
    private func ringLayout(_ items: [MemoryItem]) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        let count = max(1, items.count)
        for (index, item) in items.enumerated() {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            result[item.id] = CGPoint(
                x: 0.5 + 0.40 * cos(angle),
                y: 0.5 + 0.40 * sin(angle)
            )
        }
        return result
    }

    /// 力导向：一次算完就冻住，不做每帧动画。
    ///
    /// - 初始：按 kind 分四簇摆在四个方位，簇内绕圈排开；
    /// - 迭代 80 次：两两斥力 + 有连线的弹簧引力 + 一点点向心力；
    /// - 全程夹在 [0.06, 0.94]，不让节点飘出画布。
    private func forceLayout(_ items: [MemoryItem]) -> [String: CGPoint] {
        var point: [String: CGPoint] = [:]

        let kinds = MemoryItem.Kind.allCases
        for (slot, kind) in kinds.enumerated() {
            let group = items.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            let bearing = Double(slot) * (2 * Double.pi / Double(kinds.count)) - Double.pi / 2
            let cx = 0.5 + 0.26 * cos(bearing)
            let cy = 0.5 + 0.26 * sin(bearing)
            let ring = min(0.15, 0.05 + 0.012 * Double(group.count))
            for (index, item) in group.enumerated() {
                let angle = 2 * Double.pi * Double(index) / Double(max(1, group.count))
                // ⚠️ 先 `% 100` 再 `abs`：直接 `abs(hashValue)` 在 hashValue 恰好是
                //    `Int.min` 时会**当场崩**（取绝对值溢出）。先取模就绕开了。
                let jitter = Double(abs(item.id.hashValue % 100)) / 100.0 * 0.03
                point[item.id] = CGPoint(
                    x: CGFloat(cx + (ring + jitter) * cos(angle)),
                    y: CGFloat(cy + (ring + jitter) * sin(angle))
                )
            }
        }

        // 邻接表（只认确实还在的记忆）。
        let alive = Set(items.map { $0.id })
        var adjacency: [String: Set<String>] = [:]
        for item in items {
            for other in item.linkIDs where alive.contains(other) {
                adjacency[item.id, default: []].insert(other)
                adjacency[other, default: []].insert(item.id)
            }
        }

        let ideal = 0.12        // 理想间距
        let restLength = 0.22   // 弹簧自然长度
        let damping = 0.12      // 每次移动的最大步长
        let pull = 0.012        // 向心力

        for _ in 0..<80 {
            var fx: [String: Double] = [:]
            var fy: [String: Double] = [:]
            for item in items {
                fx[item.id] = 0
                fy[item.id] = 0
            }

            // 两两斥力。
            for i in 0..<items.count {
                let a = items[i].id
                guard let pa = point[a] else { continue }
                for j in (i + 1)..<items.count {
                    let b = items[j].id
                    guard let pb = point[b] else { continue }
                    var dx = Double(pa.x - pb.x)
                    var dy = Double(pa.y - pb.y)
                    var distSq = dx * dx + dy * dy
                    if distSq < 0.0002 {
                        dx = 0.012
                        dy = 0.012
                        distSq = dx * dx + dy * dy
                    }
                    let dist = distSq.squareRoot()
                    let force = (ideal * ideal) / distSq
                    let ux = dx / dist * force
                    let uy = dy / dist * force
                    fx[a, default: 0] += ux
                    fy[a, default: 0] += uy
                    fx[b, default: 0] -= ux
                    fy[b, default: 0] -= uy
                }
            }

            // 有连线的弹簧引力。
            for i in 0..<items.count {
                let a = items[i].id
                guard let pa = point[a], let links = adjacency[a] else { continue }
                for b in links where a < b {
                    guard let pb = point[b] else { continue }
                    var dx = Double(pa.x - pb.x)
                    var dy = Double(pa.y - pb.y)
                    var dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 0.0001 {
                        dx = 0.012
                        dy = 0.012
                        dist = (dx * dx + dy * dy).squareRoot()
                    }
                    let force = (dist - restLength) * 0.9
                    let ux = dx / dist * force
                    let uy = dy / dist * force
                    fx[a, default: 0] -= ux
                    fy[a, default: 0] -= uy
                    fx[b, default: 0] += ux
                    fy[b, default: 0] += uy
                }
            }

            // 向心力 + 落位。
            for item in items {
                let a = item.id
                guard let p = point[a] else { continue }
                let towardX = (0.5 - Double(p.x)) * pull
                let towardY = (0.5 - Double(p.y)) * pull
                let stepX = max(-damping, min(damping, (fx[a] ?? 0) + towardX))
                let stepY = max(-damping, min(damping, (fy[a] ?? 0) + towardY))
                let nx = min(0.94, max(0.06, Double(p.x) + stepX))
                let ny = min(0.94, max(0.06, Double(p.y) + stepY))
                point[a] = CGPoint(x: CGFloat(nx), y: CGFloat(ny))
            }
        }

        return point
    }
}
