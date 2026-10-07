import Foundation
import SwiftUI
import WebKit

/// ta 的「手上浏览器」—— 全 App 唯一一份、可以被工具驱动的浏览器。
///
/// 为什么需要它：`InAppBrowserView` 里那个 `WebEngine` 是页面自己 `@StateObject`
/// 建出来的，外面拿不到它的 `WKWebView`，所以工具只能「抓 HTML」，不能真的点。
/// 这里把那一个引擎提到单例上，**页面和工具共用同一份** ——
/// 用户看得见 ta 在点哪，也能随时自己上手（付款那一步必须他本人点）。
///
/// ⚠️ 故意**不给类标 `@MainActor`**：这个单例会在 View 的属性初始化里被取到
///    （`MainTabView` 那行 `@ObservedObject`）。需要主线程的地方给**方法**单独标
///    `@MainActor` —— 跟 `CallService` / `AppIconStore` 一个路子。
final class BrowserSession: ObservableObject {

    static let shared = BrowserSession()

    /// 浏览器面板是不是开着。ta 一开始操作就会把它弹出来。
    @Published private(set) var isPresented: Bool = false
    /// 面板标题。
    @Published private(set) var titleHint: String = "浏览器"

    /// 唯一那个引擎。
    ///
    /// ⚠️ `lazy` 不是随手写的：`WebEngine` 的初始化里**会建 `WKWebView`**，
    ///    那必须在主线程上发生。写成 `lazy` 之后，它是在第一次被主线程上的
    ///    `@MainActor` 方法或视图访问时才建出来，而不是单例一被摸到就在未知线程上建。
    lazy var engine = WebEngine()

    private init() {}

    // MARK: - 打开

    /// 弹出面板、真的打开一个地址，等它加载完。
    ///
    /// 返回一句中文，直接交给模型 —— 里面带上最终地址和标题，让 ta 知道到底落在哪儿了。
    @MainActor
    func open(url: URL, title: String?) async -> String {
        if let hint = title, !hint.isEmpty {
            titleHint = hint
        } else {
            titleHint = "浏览器"
        }
        isPresented = true
        engine.load(url)
        await waitForReady()

        let pageTitle = engine.title.isEmpty
            ? (url.host ?? url.absoluteString)
            : engine.title
        let address = engine.currentURL?.absoluteString ?? url.absoluteString
        return "已经打开了 \(address)，标题是「\(pageTitle)」。"
    }

    // MARK: - 看当前页

    /// 把当前页面「看得见、能点 / 能填」的东西列出来（带编号）。
    ///
    /// 编号由 JS 打在 `data-aevis-idx` 上，所以**两次调用之间是稳定的** ——
    /// 可以「先 read 再 click 第 7 个」。整串控制在 2000 字以内，省 token。
    @MainActor
    func readPage(limit: Int) async -> String {
        let listing = min(max(limit, 1), 60)
        // 收集上限：至少多收 1 个，好判定「还有更多」；上限 150。
        // 直接用**原始** limit 算（不是 listing），这样 limit 调大时收集量真的会变。
        let collecting = min(max(limit, 61), 150)
        let result = try? await js(Self.readPageScript(cap: collecting))
        guard let raw = result as? String,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "页面还没渲染好，再读一次。"
        }

        let pageTitle = (object["title"] as? String) ?? ""
        let pageURL = (object["url"] as? String) ?? ""
        let text = (object["text"] as? String) ?? ""
        let items = (object["items"] as? [[String: Any]]) ?? []

        var lines: [String] = []
        lines.append("标题：\(pageTitle.isEmpty ? "（没有标题）" : pageTitle)")
        lines.append("地址：\(pageURL)")
        lines.append("可点 / 可填的（\(items.count) 个）：")

        let shown = Array(items.prefix(listing))
        if shown.isEmpty {
            lines.append("（这一页好像没什么能点的，往下翻翻或者换一页看看）")
        }
        for item in shown {
            let index = (item["i"] as? Int) ?? -1
            let kind = (item["kind"] as? String) ?? "tap"
            let label = (item["label"] as? String) ?? ""
            lines.append("[\(index)] \(kind) \(label)")
        }
        if items.count > shown.count {
            lines.append("（还有更多，往下翻再看）")
        }

        lines.append("")
        lines.append("页面上的字（最多 1000 字）：")
        lines.append(text.count > 1000 ? String(text.prefix(1000)) + "……" : text)

        var output = lines.joined(separator: "\n")
        if output.count > 2000 {
            output = String(output.prefix(2000)) + "……"
        }
        return output
    }

    // MARK: - 点

    /// 点第 `index` 个可点元素（编号来自 `readPage`）。
    ///
    /// ⚠️ 付款 / 下单那一类按钮在**这层的 JS 里**就拦死 —— 不能只靠提示词。
    ///    拦到之后返回的话必须让 ta 明白「这一步要用户自己点」，别自己想办法绕过。
    @MainActor
    func click(index: Int) async -> String {
        let result = try? await js(Self.clickScript, args: ["idx": index])
        guard let raw = result as? String,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "点了第 \(index) 个，但页面没回应。用 browser_read 重新看一遍再试。"
        }

        let ok = (object["ok"] as? Bool) ?? false
        let reason = (object["reason"] as? String) ?? ""
        let label = (object["label"] as? String) ?? ""

        if ok {
            // 点了多半会跳页，等它加载好再交出去。
            await waitForReady(timeout: 15)
            return label.isEmpty ? "点了第 \(index) 个。" : "点了「\(label)」。"
        }
        if reason == "blocked" {
            let what = label.isEmpty ? "" : "「\(label)」"
            return "这一步是付款/下单，我不能替你点（怕点错了真扣你钱）。"
                + "页面已经停在待付款了，你让他自己点一下\(what)。"
        }
        if reason == "notfound" {
            return "页面上找不到编号 \(index) 了（可能刚刷新过）。用 browser_read 重新看一遍再点。"
        }
        return "这个元素点不动（\(reason)）。用 browser_read 重新看一遍。"
    }

    // MARK: - 填

    /// 往第 `index` 个输入框里填字（编号来自 `readPage`）。
    ///
    /// 返回那句「已经填了」是**真的填进去了**；填字不跳页，所以这里不等加载。
    @MainActor
    func type(index: Int, text: String) async -> String {
        let result = try? await js(Self.typeScript, args: ["idx": index, "text": text])
        guard let raw = result as? String,
              let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "想往第 \(index) 个框里填字，但页面没回应。用 browser_read 重新看一遍。"
        }

        let ok = (object["ok"] as? Bool) ?? false
        let reason = (object["reason"] as? String) ?? ""
        if ok {
            return "已经往第 \(index) 个框里填了「\(text)」。"
        }
        if reason == "password" {
            return "那是个密码框 / 验证码 / 支付相关的框，这种我不填。要填让他自己来。"
        }
        if reason == "paypage" {
            return "这一页是付款页，我一个字都不往上填。要付钱让他自己来。"
        }
        if reason == "empty" {
            return "这个框还是空的（没填进去），别跟他说填好了。换个框，或者让他自己填。"
        }
        if reason == "nofill" {
            return "这个框没吃进去（页面没真正接受这几个字），别跟他说填好了。"
                + "换个框，或者让他自己填。"
        }
        if reason == "notfound" {
            return "页面上找不到编号 \(index) 的输入框了，用 browser_read 重新看一遍。"
        }
        return "这个框填不进去（\(reason)）。"
    }

    // MARK: - 翻页

    /// 把页面往下 / 往上翻，喂懒加载。
    @MainActor
    func scroll(direction: String, times: Int) async -> String {
        let dir = direction.lowercased() == "up" ? "up" : "down"
        let count = min(max(times, 1), 5)
        _ = try? await js(Self.scrollScript, args: ["dir": dir, "times": count])
        // 翻完会有新内容懒加载出来，等一等再看。
        await waitForReady(timeout: 12)
        return dir == "up" ? "往上翻了 \(count) 屏。" : "往下翻了 \(count) 屏。"
    }

    // MARK: - 后退

    /// 后退一页。
    @MainActor
    func back() async -> String {
        guard engine.canGoBack else {
            return "这已经是能退到的第一页了，退不回去。"
        }
        let before = engine.currentURL?.absoluteString ?? ""
        engine.goBack()
        await waitForReady(timeout: 15)
        let after = engine.currentURL?.absoluteString ?? ""
        if !before.isEmpty, before == after {
            return "点了后退，但页面地址没变（可能被站内脚本拦住了）。"
        }
        return "后退了一页，现在是 \(after.isEmpty ? "上一页" : after)。"
    }

    // MARK: - 收起

    /// 把浏览器面板收起来（给面板上那个「收起」按钮用）。
    ///
    /// ⚠️ 同步方法：它只改一个 `@Published` 开关，调用点是按钮动作（本来就在主线程）。
    func close() {
        isPresented = false
    }

    // MARK: - 底层

    /// 跑一段 JS，参数由 WebKit 自己序列化。
    ///
    /// ⚠️ 用 `callAsyncJavaScript` 而不是 `evaluateJavaScript`：前者把参数当成
    ///    函数参数注入（省掉全部字符串转义问题），而且 body 里可以直接写 `await`。
    /// ⚠️ 它的 async 版返回的是 `Any?`（脚本没显式 `return` 时是 nil），
    ///    这里统一兜成 `NSNull`，省得调用点到处拆双层可选。
    @MainActor
    private func js(_ body: String, args: [String: Any] = [:]) async throws -> Any {
        // ⚠️ 显式标 `Any?` 接住：Apple 这个 async 版的返回类型在 SDK 里
        //    写成 `Any` 还是 `Any?` 有过反复，标上 `Any?` 两种都能编过
        //    （非可选值会自动提升成可选），不用赌。
        let raw: Any? = try await engine.webView.callAsyncJavaScript(
            body,
            arguments: args,
            contentWorld: .page
        )
        return raw ?? NSNull()
    }

    /// 等页面真的加载好。
    ///
    /// ⚠️ 先等 400ms 再查 —— `load()` 刚发出去那一刻 `document.readyState`
    ///    还是**上一页**的残留状态，立刻查会查到「complete」而误判成「已经加载完」。
    ///    超时也**不报错**：让 `readPage` 把当时看到的页面交出去，比什么都不给强。
    @MainActor
    private func waitForReady(timeout: Double = 25) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = (try? await js("return document.readyState")) as? String
            if state == "complete" { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        // 首屏 JS 渲染完再交出去，免得给模型一张空页面。
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    // MARK: - 注入的脚本

    /// 「看当前页」的脚本：给每个可见的交互元素打上 `data-aevis-idx` 编号。
    ///
    /// `cap` 是**最多收多少个**（比展示上限大一点，这样才能判定「还有更多」）。
    private static func readPageScript(cap: Int) -> String {
        return #"""
        const sel = 'a,button,input,textarea,select,[role=button],[role=link],[contenteditable=true]';
        function vis(el) {
          if (!el || !el.getBoundingClientRect) return false;
          const r = el.getBoundingClientRect();
          if (r.width < 2 || r.height < 2) return false;
          const s = window.getComputedStyle(el);
          if (s.visibility === 'hidden' || s.display === 'none') return false;
          if (parseFloat(s.opacity || '1') < 0.05) return false;
          return true;
        }
        const out = [];
        const all = document.querySelectorAll(sel);
        let n = 0;
        for (let i = 0; i < all.length && n < \#(cap); i++) {
          const el = all[i];
          if (!vis(el)) continue;
          const tag = el.tagName.toLowerCase();
          let label = '';
          if (tag === 'input' || tag === 'textarea' || tag === 'select') {
            label = el.getAttribute('placeholder') || el.getAttribute('aria-label') || el.getAttribute('name') || '';
            if (el.type === 'password') label = '密码框 ' + label;
          } else {
            label = (el.innerText || el.getAttribute('aria-label') || el.title || '').replace(/\s+/g, ' ').trim();
          }
          label = label.slice(0, 40);
          if (!label) continue;
          el.setAttribute('data-aevis-idx', String(n));
          const isField = (tag === 'input' || tag === 'textarea' || tag === 'select' || el.isContentEditable === true);
          out.push({ i: n, kind: (isField ? 'field' : 'tap'), label: label });
          n++;
        }
        const text = (document.body ? (document.body.innerText || '') : '').replace(/\n{3,}/g, '\n\n').trim();
        return JSON.stringify({ title: document.title || '', url: location.href, text: text.slice(0, 2500), items: out });
        """#
    }

    /// 「点」的脚本 —— 钱的红线就在这一段。付款 / 下单那一类按钮在**这里**就拦死，
    /// 不往下发任何事件。
    ///
    /// 两层判据，任意一层命中 ⇒ 返回 `blocked`、一个事件都不派发：
    /// ① 按钮文字命中支付 / 下单词表（`stop`）；
    /// ② 当前像"付款页"（`location.href` **或** `document.title` 命中 cashier / 收银 /
    ///    支付宝 / 微信支付 / 付款 / alipay / wxpay / tenpay）—— 付款页上除了一组
    ///    "退出类"导航词（返回 / 取消 / 上一步 / 关闭 / 后退 / 继续购物 / 再逛逛 / 回到首页）
    ///    外**什么都不许点**。看标题是因为**单页应用跳收银台时 URL 常常不变**，只看 URL 会漏；
    ///    英文片段（alipay / wxpay / tenpay）是补支付宝、微信的**独立收银域**
    ///    （mbillexprod.alipay.com / payapp.weixin.qq.com / wx.tenpay.com）；
    ///    这条也顺带盖住了"支付密码键盘"那些纯数字按钮（它们不在白名单里）。
    ///
    /// ⚠️ 为什么 `收银台` / `立即结算` **故意不在 `stop` 词表里**：它们是**导航词**，
    ///    本身不扣钱，却是走到"待付款"页的必经一步。拦了它们，ta 就到不了待付款，
    ///    跟"把页面停在待付款、让用户自己点付款"的需求**自相矛盾**。
    /// ⚠️ `提交订单` 也拦 —— 它本身不划钱，但**有些平台开了免密支付，提交订单就等于扣钱**。
    ///    ⇒ 宁可让 ta 停在「确认订单」页，把最后「提交订单 + 付款」两步都交给用户自己点。
    ///    这是保守取舍，不是遗漏。
    /// ⚠️ 这段 JS **只拦 AI（工具调用），不拦用户本人**：用户的点击直接命中 WebView，
    ///    根本不经过我们的脚本。所以这里可以放心收紧 —— 别误以为它连用户一起拦，
    ///    然后把它放宽。
    private static let clickScript = #"""
    const el = document.querySelector('[data-aevis-idx="' + idx + '"]');
    if (!el) return JSON.stringify({ ok: false, reason: 'notfound' });
    const label = (el.innerText || el.value || el.getAttribute('placeholder') || '').replace(/\s+/g, ' ').trim().slice(0, 40);
    const stop = ['立即支付', '确认付款', '提交订单', '确认下单', '立即下单', '去支付', '去付款', '一键支付', '立即购买并支付', '立即付款', '马上支付', '同意并支付', '确认并支付', '提交支付', '确认支付', '免密支付', '支付订单', '立刻付款', '确认收货'];
    for (let i = 0; i < stop.length; i++) {
      if (label.indexOf(stop[i]) >= 0) return JSON.stringify({ ok: false, reason: 'blocked', label: label });
    }
    const page = ((location.href || '') + ' ' + (document.title || '')).toLowerCase();
    if (/cashier|收银|支付宝|微信支付|付款|alipay|wxpay|tenpay/.test(page)) {
      const safe = ['返回', '取消', '上一步', '关闭', '后退', '继续购物', '再逛逛', '回到首页'];
      let allowed = false;
      for (let j = 0; j < safe.length; j++) {
        if (label.indexOf(safe[j]) >= 0) { allowed = true; break; }
      }
      if (!allowed) return JSON.stringify({ ok: false, reason: 'blocked', label: label });
    }
    el.scrollIntoView({ block: 'center' });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2;
    const opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
    ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (t) {
      let ev;
      if (t.indexOf('pointer') === 0 && window.PointerEvent) { ev = new PointerEvent(t, opts); }
      else { ev = new MouseEvent(t, opts); }
      try { el.dispatchEvent(ev); } catch (e) {}
    });
    try { if (el.click) el.click(); } catch (e) {}
    return JSON.stringify({ ok: true, label: label });
    """#

    /// 「填字」的脚本。
    ///
    /// 必须做对的几件事，否则就是「假装完成」：
    /// ① React / Vue 那种站点**必须**走原生 setter + 手动派发 `input` 事件 ——
    ///    直接 `el.value = x` 它读不到值；
    /// ② `contenteditable` 的框（富文本框）没有 `value`，得走 `execCommand('insertText')`
    ///    或直接写 `textContent`，不能拿 `el.value` 糊；
    /// ③ 成功判据**分层**（关键，别一刀切）：
    ///    - `input` / `textarea` / `select`：只要读回来**非空**就算成功。手机号框会加分隔符、
    ///      金额框会加千分位、有 `maxlength` 的会截断 —— 读回来跟填进去的不一样是**正常的**，
    ///      拿"内容相等"判会把正常框误报成失败（那是另一种"假失败"）；
    ///    - `contenteditable`：才用严格判据（读回来必须**含**这几个字）—— 富文本框本来就不该被格式化。
    ///
    /// 另外，密码框 / 验证码 / 支付相关的框一律不填（避免代替用户做支付相关的事）。
    private static let typeScript = #"""
    const el = document.querySelector('[data-aevis-idx="' + idx + '"]');
    if (!el) return JSON.stringify({ ok: false, reason: 'notfound' });
    const idt = [el.getAttribute('name'), el.getAttribute('id'), el.getAttribute('placeholder'), el.getAttribute('aria-label'), el.getAttribute('autocomplete')].join(' ').toLowerCase();
    let sensitive = (el.type === 'password') || /password|passwd|pwd|密码|支付|pay|verif|验证|otp|captcha|sms|动态|安全码|cvv|cvc|card|cc-number|cc-exp|cc-name|卡号|银行卡|信用卡|储蓄卡|有效期/.test(idt);
    if (!sensitive && /\bcode\b/.test(idt) && !/post|zip|邮编|邮政|promo|coupon|优惠|折扣/.test(idt)) { sensitive = true; }
    if (sensitive) return JSON.stringify({ ok: false, reason: 'password' });
    const here = (location.href || '').toLowerCase();
    if (/cashier|收银/.test(here)) return JSON.stringify({ ok: false, reason: 'paypage' });
    el.scrollIntoView({ block: 'center' });
    try { el.focus(); } catch (e) {}
    const tag = el.tagName.toLowerCase();
    const isFormField = (tag === 'input' || tag === 'textarea' || tag === 'select');
    let done = false;
    if (!isFormField && el.isContentEditable) {
      el.textContent = '';
      try { document.execCommand('insertText', false, text); } catch (e) {}
      if (!el.textContent) { el.textContent = text; }
      el.dispatchEvent(new InputEvent('input', { bubbles: true }));
      done = true;
    } else if (isFormField) {
      let proto = null;
      if (tag === 'textarea') proto = window.HTMLTextAreaElement.prototype;
      else if (tag === 'input') proto = window.HTMLInputElement.prototype;
      if (proto) {
        const d = Object.getOwnPropertyDescriptor(proto, 'value');
        if (d && d.set) { d.set.call(el, text); done = true; }
      }
      if (!done) { el.value = text; done = true; }
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    const isEditable = (!isFormField && el.isContentEditable);
    const readback = isEditable ? String(el.textContent || '') : String(el.value || '');
    if (!done || !readback) {
      return JSON.stringify({ ok: false, reason: 'empty', value: readback.slice(0, 40) });
    }
    if (isEditable && readback.indexOf(text) < 0) {
      return JSON.stringify({ ok: false, reason: 'nofill', value: readback.slice(0, 40) });
    }
    return JSON.stringify({ ok: true, value: readback.slice(0, 40) });
    """#

    /// 「翻页」的脚本。这里用了 `await` —— `callAsyncJavaScript` 的 body 就是个
    /// async 函数体，合法。
    private static let scrollScript = #"""
    const step = dir === 'up' ? -1 : 1;
    for (let i = 0; i < times; i++) {
      window.scrollBy(0, step * Math.round(window.innerHeight * 0.9));
      await new Promise(function (r) { setTimeout(r, 350); });
    }
    return JSON.stringify({ ok: true, y: Math.round(window.scrollY) });
    """#
}
