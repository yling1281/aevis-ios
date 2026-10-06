import ActivityKit
import Foundation

/// ta的消息 —— 灵动岛（Live Activity）的数据契约。
///
/// ⚠️ 这个文件**主 App 和 AevisLive 扩件都要编**（照 AevisBroadcast 收
///    `ScreenShareStore.swift` 的做法），所以**不能依赖 UIKit、不能依赖主 App
///    的任何类型** —— 两边都是独立进程、各自编一份，契约只有这一份。
///
/// 数据形态很简单：`name` 是ta叫什么，`text` 是ta说了什么。
/// `text` 为**空字符串 = 挂机态**（只显示一个「ta在」的小标记）。
struct AevisMessageAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// ta叫什么。
        var name: String
        /// ta说了什么；空字符串表示挂机态（ta只是"在"，没说话）。
        var text: String
        /// 这句话的时间（锁屏上显示）。
        var at: Date
    }

    /// 这个活动是什么时候起的（用来判断"挂了多久、要不要重开"）。
    var startedAt: Date
}
