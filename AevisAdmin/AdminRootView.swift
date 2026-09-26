import SwiftUI
import UIKit

// MARK: - 分区定义

/// 管理端有哪几块。**一套定义，两种摆法**：
/// 手机上按 `tab` 归到底栏，iPad 上全部摊在侧栏里。
/// 加一块新东西时只改这里，两个端一起生效。
enum AdminSection: String, CaseIterable, Identifiable, Hashable {
    case overview, diag, users, codes, devices, blocks, bot, account

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "总览"
        case .diag: return "崩溃现场"
        case .users: return "账号"
        case .codes: return "注册码"
        case .devices: return "换机申请"
        case .blocks: return "封禁"
        case .bot: return "机器人"
        case .account: return "后台账号"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .diag: return "exclamationmark.triangle.fill"
        case .users: return "person.2.fill"
        case .codes: return "ticket.fill"
        case .devices: return "arrow.triangle.2.circlepath"
        case .blocks: return "hand.raised.fill"
        case .bot: return "cpu.fill"
        case .account: return "key.fill"
        }
    }

    /// 手机上归到哪个底栏。
    var tab: AdminTab {
        switch self {
        case .overview: return .home
        case .diag: return .diag
        case .users: return .users
        default: return .more
        }
    }
}

enum AdminTab: String, CaseIterable, Identifiable {
    case home, diag, users, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "总览"
        case .diag: return "崩溃"
        case .users: return "账号"
        case .more: return "更多"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "chart.bar.fill"
        case .diag: return "exclamationmark.triangle.fill"
        case .users: return "person.2.fill"
        case .more: return "ellipsis.circle.fill"
        }
    }

    /// 「更多」那一栏里装的是哪几块。
    var sections: [AdminSection] {
        switch self {
        case .home: return [.overview]
        case .diag: return [.diag]
        case .users: return [.users]
        case .more: return [.codes, .devices, .blocks, .bot, .account]
        }
    }
}

// MARK: - 根视图

struct AdminRootView: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            AdminSplitView()
        } else {
            AdminTabsView()
        }
    }
}

// MARK: - 手机：底栏

struct AdminTabsView: View {
    @EnvironmentObject private var store: AdminStore
    @State private var tab: AdminTab = .home

    var body: some View {
        TabView(selection: $tab) {
            ForEach(AdminTab.allCases) { item in
                NavigationStack {
                    // 底栏这一格对应几块内容，直接竖着摞起来 ——
                    // 「总览 / 崩溃 / 账号」是一块，「更多」是入口列表。
                    if item == .more {
                        MoreView()
                    } else {
                        AdminStackedSections(sections: item.sections)
                    }
                }
                .tabItem { Label(item.title, systemImage: item.symbol) }
                .tag(item)
            }
        }
    }
}

/// 把同一格里的几块内容**连成一个滚动页**。
///
/// 为什么不各自成一个 ScrollView：底栏那一格点进去应该是"一页到底"，
/// 嵌套滚动在手机上很难用。所以这里只留最外层一个滚动容器。
struct AdminStackedSections: View {
    var sections: [AdminSection]
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        AdminPage(title: sections.first?.title ?? "") {
            ForEach(sections) { section in
                AdminSectionBody(section: section)
            }
        }
    }
}

// MARK: - iPad：侧栏

struct AdminSplitView: View {
    @EnvironmentObject private var store: AdminStore
    @State private var section: AdminSection = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("管理") {
                    ForEach([AdminSection.overview, .diag, .users]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("发放与售后") {
                    ForEach([AdminSection.codes, .devices, .blocks]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("设置") {
                    ForEach([AdminSection.bot, .account]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationTitle("Aevis 管理")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    SignOutButton()
                }
            }
        } detail: {
            NavigationStack {
                AdminPage(title: section.title) {
                    AdminSectionBody(section: section)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - 内容分发

/// 每一块的实际内容 —— 手机和 iPad 用的是同一份。
struct AdminSectionBody: View {
    var section: AdminSection

    var body: some View {
        switch section {
        case .overview: OverviewSection()
        case .diag: DiagSection()
        case .users: UsersSection()
        case .codes: CodesSection()
        case .devices: DevicesSection()
        case .blocks: BlocksSection()
        case .bot: BotSection()
        case .account: AccountSection()
        }
    }
}

// MARK: - 「更多」

struct MoreView: View {
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        List {
            Section("发放与售后") {
                ForEach([AdminSection.codes, .devices, .blocks]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            }
            Section("设置") {
                ForEach([AdminSection.bot, .account]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            }
            Section {
                if let at = store.refreshedAt {
                    HStack {
                        Text("上次刷新")
                        Spacer()
                        Text(AdminFormat.when(Int(at.timeIntervalSince1970)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                }
                Text(store.base)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } header: {
                Text("服务器")
            }
            Section {
                SignOutButton(fullWidth: true)
            }
        }
        .navigationTitle("更多")
        .navigationDestination(for: AdminSection.self) { item in
            AdminPage(title: item.title) {
                AdminSectionBody(section: item)
            }
        }
    }
}

/// 退出登录。iPad 的侧栏底部和手机的「更多」里都要用。
struct SignOutButton: View {
    var fullWidth: Bool = false
    @EnvironmentObject private var store: AdminStore

    var body: some View {
        Button(role: .destructive) {
            store.signOut()
        } label: {
            Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 14.5))
                .frame(maxWidth: fullWidth ? .infinity : nil, alignment: fullWidth ? .center : .leading)
        }
    }
}
