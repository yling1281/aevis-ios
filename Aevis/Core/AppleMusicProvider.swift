import Foundation
import MusicKit

/// Apple Music 接入（2026-10-31 新增）。
///
/// 用户说「苹果音乐也可以加，现在也有权限」—— 走系统 MusicKit：
/// 不引第三方、不自己管 JWT，授权交给系统（用户的 Apple Music 订阅）。
///
/// ⚠️ MusicKit 是 **App ID 上的 App Service**（在 developer.apple.com 的
///   Identifiers → 你的 App ID → App Services 里打开 MusicKit），
///   **不是 entitlement 文件里的一行**—— Apple 官方明确说 `com.apple.developer.musickit`
///   是个常见幻觉，别写进 .entitlements。Info.plist 里放 `NSAppleMusicUsageDescription` 即可。
///   另外**模拟器不支持 MusicKit**，必须真机跑。
@MainActor
final class AppleMusicProvider: ObservableObject {
    static let shared = AppleMusicProvider()

    @Published private(set) var authStatus: MusicAuthorization.Status = .notDetermined
    @Published private(set) var canPlay = false

    private init() {}

    func refreshStatus() {
        authStatus = MusicAuthorization.currentStatus
        Task { await updatePlayability() }
    }

    func requestAuthorization() async {
        authStatus = await MusicAuthorization.request()
        await updatePlayability()
    }

    private func updatePlayability() async {
        if let subscription = try? await MusicSubscription.current {
            canPlay = subscription.canPlayCatalogContent
        }
    }

    /// 搜歌（catalog 搜索，不需要会员也能搜）。
    func search(_ term: String, limit: Int = 20) async throws -> [Song] {
        var request = MusicCatalogSearchRequest(term: term)
        request.types = [.songs]
        request.limit = limit
        let response = try await request.response()
        return Array(response.songs)
    }
}
