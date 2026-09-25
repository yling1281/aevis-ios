import Foundation

/// 编译时注入进来的第三方凭据。
///
/// ## 为什么单独一个文件，而且仓库里这份的值永远是空的
///
/// 这个仓库是**公开**的。AppKey / SecretKey 要是直接写在这儿推上去，
/// 等于把钥匙挂在门上 —— 谁都能 fork 下来抄走。
///
/// 所以：**仓库里这份永远是空值**，真正的值在 CI 编译前由
/// GitHub Actions 的 Secrets（加密存储、不随代码公开）就地写进来，
/// 只存在于**构建产物**里，不落在仓库的任何一次提交里。
///
/// 本地开发、或者没配 Secrets 的时候，它就是空的 ——
/// App 照样能编、能跑，只是要去「设置 → 百度网盘」自己填一次。
///
/// ## 值是谁写进来的
/// `scripts/inject_secrets.py` 会用环境变量替换下面两行的字符串。
/// 改格式的话记得同步改那个脚本。
///
/// ## 以后有了服务器怎么办
/// 把 SecretKey 挪到服务端，App 这边只保留 AppKey、或者干脆什么都不留，
/// 由服务端换 token —— 那时候这个文件就可以整个删掉。
enum BuiltInSecrets {

    /// 百度网盘开放平台的应用 AppKey。
    /// 它本身不算机密（授权页的 URL 里就带着），但也不该白送。
    static let baiduPanAppKey = ""

    /// 百度网盘开放平台的 SecretKey。
    /// ⚠️ 这个是真正的机密：有它就能以这个应用的身份换 token。
    /// **绝不能**出现在公开仓库里。
    static let baiduPanSecretKey = ""

    /// 账号后端的「发码钥匙」。
    ///
    /// QQ 机器人拿它去调 `/api/bot/ticket` 和 `/api/bot/claim`，
    /// 证明"这个请求是我们自己的 App 发的" —— 没有它，任何人编一个群 openid
    /// 就能换到注册码，"只有群里的人能注册"这个门槛就白设了。
    ///
    /// ⚠️ 这里**默认留空**是有意的：正常路径是用户从自己的管理后台
    /// （account.lingyan.cyou/admin）复制出来，填进 App 的设置里。
    /// 那比让他去 GitHub 配一个 Secret 容易得多。
    /// 配了 CI Secret（`AEVIS_ACCOUNT_BOT_KEY`）的话，这里会被自动填上，
    /// 用户就一次都不用填。
    static let accountBotKey = ""
}
