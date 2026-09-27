//
//  AdminBrand.swift
//  AevisAdmin
//
//  管理端的**名字只有这一处来源**：`project.yml` 里的 `ADMIN_BRAND`
//  （经 Info.plist 的 `AEAdminBrand` / `CFBundleDisplayName` 传进来）。
//
//  界面上任何地方显示自己叫什么，都从这儿取 —— **不要在 Swift 里写死名字**，
//  否则换名字时一定会漏掉一处（"管理端"三个字散在登录页、导航栏、导出诊断里）。
//
//  为什么非得绕 Info.plist 一道：**桌面图标名是编译期定死的，运行期改不了**。
//  所以"改一处、全跟着变"只能是——构建配置和代码读同一份值。
//
//  ⚠️ 这个文件里**故意不出现任何品牌名**（连兜底也不写死）。
//     兜底用的是中性的"管理端 / 管理"两个字 —— 它只在"构建配置坏了"时才会出现，
//     正常构建永远读得到真名字；这样换名字时这里一行都不用动。
//
//  换名字：`python tools/rename_admin.py 新名字`
//

import Foundation

enum AdminBrand {

    /// 品牌名本身（比如 `Aevis`）。读不到就返回空串 —— 下面各自有兜底。
    static let name: String = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AEAdminBrand") as? String
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // `$(ADMIN_BRAND)` 没被替换掉 = 构建配置坏了（比如有人把那个设置删了）。
        // 这种情况当"没读到"处理，别把一串美元符号显示到界面上。
        return trimmed.contains("$(") ? "" : trimmed
    }()

    /// 桌面图标名 / 登录页大标题，比如 `Aevis 管理端`。
    static var displayName: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !trimmed.contains("$(") { return trimmed }
        return name.isEmpty ? "管理端" : name + " 管理端"
    }

    /// 导航栏标题，比如 `Aevis 管理`（比桌面名短一点，侧栏里放得下）。
    static var navTitle: String { name.isEmpty ? "管理" : name + " 管理" }
}
