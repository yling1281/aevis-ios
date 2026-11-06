//
//  FusionPhoneAuth.swift
//  Aevis
//
//  阿里云融合认证（号码认证 / 一键登录）的薄封装。
//
//  为什么是薄封装：SDK 自带一套授权页 UI，只允许通过 model 改样式，
//  不让我们换整个布局。所以这里只做三件事 —— 初始化、拉起、把
//  maskToken 抛给上层。手机号**只能由服务端**用 AccessKey 去换，
//  客户端拿到的 maskToken 不是手机号。
//
//  调用顺序（跟官方 Demo 一致，顺序错了取不到号）：
//    1. 后端 `/v1/auth/phone/token` 拿 authToken
//    2. prepare(scheme:authToken:)
//    3. start(from:) 拉起授权页
//    4. 回调里把 maskToken 交给后端 `/v1/auth/phone/verify`
//    5. 页面销毁时 release()
//

import Foundation
import UIKit
import AlicomFusionAuth

final class FusionPhoneAuth: NSObject {

    static let shared = FusionPhoneAuth()

    /// SDK 内置模板：一键登录。短信是 100002、图形是 100004。
    static let templateOneKey = "100001"

    /// 融合认证方案 Code（iOS）。2026-11-02 控制台创建。
    ///
    /// ⚠️ 别跟另外两套混了：FA = 融合认证（我们用这个）、
    ///    FC = 号码认证、FG = 图形认证。
    static let schemeCode = "FA000000009767884275"

    private var handler: AlicomFusionAuthHandler?
    private var scheme = ""
    private var token: AlicomFusionAuthToken?
    private var onToken: ((String) -> Void)?
    private var onFail: ((String, String) -> Void)?

    private override init() { super.init() }

    /// 初始化好了没有。
    var isReady: Bool { handler != nil && !scheme.isEmpty }

    /// 初始化。`authToken` 从后端拿。
    func prepare(scheme: String, authToken: String) {
        guard !scheme.isEmpty, !authToken.isEmpty else {
            NSLog("[Fusion] prepare 跳过：scheme 或 authToken 为空（后端还没配 AccessKey？）")
            return
        }
        self.scheme = scheme
        let t = AlicomFusionAuthToken(tokenStr: authToken)
        token = t

        if handler == nil {
            handler = AlicomFusionAuthHandler(token: t, schemeCode: scheme)
            handler?.setFusionAuthDelegate(self)
        } else {
            handler?.update(t)
        }
        NSLog("[Fusion] prepare ok")
    }

    /// 拉起授权页。
    func start(from vc: UIViewController,
               onToken: @escaping (String) -> Void,
               onFail: @escaping (String, String) -> Void) {
        guard let h = handler else {
            onFail("NOT_READY", "号码认证还没准备好")
            return
        }
        self.onToken = onToken
        self.onFail = onFail
        h.setFusionAuthDelegate(self)
        h.startScene(withTemplateId: Self.templateOneKey, viewController: vc)
    }

    /// 切到别的登录方式时收掉授权页。
    func stop() {
        handler?.stopScene(withTemplateId: Self.templateOneKey)
    }

    /// 释放（会销毁 handler，下次要重新 prepare）。
    func release() {
        handler?.destroy()
        handler = nil
        token = nil
        scheme = ""
        onToken = nil
        onFail = nil
    }
}

// MARK: - 业务回调（全部必选，少一个编译就过不去）

extension FusionPhoneAuth: AlicomFusionAuthDelegate {

    func onSDKTokenUpdate(_ handler: AlicomFusionAuthHandler) -> AlicomFusionAuthToken {
        // 手上这个还能用就先给它；真过期了上层会重新 prepare。
        token ?? AlicomFusionAuthToken(tokenStr: "")
    }

    func onSDKTokenAuthSuccess(_ handler: AlicomFusionAuthHandler) {
        NSLog("[Fusion] token 鉴权成功")
    }

    func onSDKTokenAuthFailure(_ handler: AlicomFusionAuthHandler,
                               fail failToken: AlicomFusionAuthToken,
                               error: AlicomFusionEvent) {
        NSLog("[Fusion] token 鉴权失败：\(error.errorMsg ?? "")")
        onFail?("TOKEN_FAIL", error.errorMsg ?? "鉴权失败")
    }

    /// 一键登录成功：`maskToken` 是取号凭证，不是手机号。
    func onVerifySuccess(_ handler: AlicomFusionAuthHandler,
                         nodeName: String,
                         maskToken: String,
                         event: AlicomFusionEvent) {
        NSLog("[Fusion] 取号成功 node=\(nodeName) token=\(maskToken.prefix(8))…")
        if maskToken.isEmpty {
            onFail?("EMPTY_TOKEN", "取号成功但没拿到凭证")
        } else {
            onToken?(maskToken)
        }
    }

    /// 中途节点校验（换绑手机号时第一次验证码才会走这里）。我们不做换绑，直接放行。
    func onHalfwayVerifySuccess(_ handler: AlicomFusionAuthHandler,
                                nodeName: String,
                                maskToken: String,
                                event: AlicomFusionEvent,
                                resultBlock: @escaping (Bool) -> Void) {
        if !maskToken.isEmpty { onToken?(maskToken) }
        resultBlock(true)
    }

    func onVerifyFailed(_ handler: AlicomFusionAuthHandler,
                        nodeName: String,
                        error: AlicomFusionEvent) {
        NSLog("[Fusion] 取号失败：\(error.errorMsg ?? "")")
        onFail?("VERIFY_FAIL", error.errorMsg ?? "取号失败")
    }

    func onTemplateFinish(_ handler: AlicomFusionAuthHandler, event: AlicomFusionEvent) {
        // 授权页关掉了（用户返回 / 切了别的方式）。不算错误，交给上层判断。
        NSLog("[Fusion] 授权页结束")
    }

    func onGetPhoneNumber(forVerification handler: AlicomFusionAuthHandler,
                          event: AlicomFusionEvent) -> String {
        ""
    }

    /// 点协议富文本 —— 用系统浏览器打开，别在 SDK 里内嵌。
    func onProtocolClick(_ handler: AlicomFusionAuthHandler,
                         protocolName: String,
                         protocolUrl: String,
                         event: AlicomFusionEvent) {
        guard let url = URL(string: protocolUrl) else { return }
        UIApplication.shared.open(url)
    }

    func onVerifyInterrupt(_ handler: AlicomFusionAuthHandler, event: AlicomFusionEvent) {
        NSLog("[Fusion] 取号中断")
    }
}
