import CommonCrypto
import Foundation

/// 网易云 weapi 加密。
///
/// **为什么不能用系统 API 做 RSA**：网易的 RSA 不是标准 PKCS1 填充，
/// 而是「直接向前补 0」的裸运算（`encSecKey = int(hex(倒序key)) ^ 65537 mod N`）。
/// 苹果的 `SecKeyAlgorithm.rsaEncryptionRaw` 明确不允许用于加密操作，
/// 所以必须自己做大数运算。
///
/// 这里的大数运算**只做加、减、比较、右移一位**，刻意不做除法 ——
/// 因为指数恒为 65537（= 2^16 + 1），模幂只需「平方 16 次再乘一次」，
/// 而模乘可以用倍加法实现，全程避开了最容易写错的大数除法。
///
/// 算法结构已用 Python 对拍验证过（见 `tools/netease_crypto_reference.py`，
/// 200 组随机密钥与 `pow()` 完全一致）。
enum NeteaseCrypto {

    // MARK: - 常量（来自多个开源实现的一致记录，非臆测）

    static let presetKey = "0CoJUm6Qyw8W8jud"
    static let iv = "0102030405060708"
    static let base62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    static let rsaExponent: UInt32 = 0x010001

    static let modulus = Big(
        hex: "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725"
            + "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec"
            + "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8"
            + "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
    )

    // MARK: - 对外

    /// 把参数加密成网易要的 `params` 与 `encSecKey`。
    static func weapi(params: [String: Any]) -> [String: String]? {
        guard let json = try? JSONSerialization.data(withJSONObject: params),
              let text = String(data: json, encoding: .utf8) else {
            return nil
        }
        let secret = randomSecretKey()

        // 第一层：用固定 presetKey 加密原文
        guard let first = aesCBC(text, key: presetKey) else { return nil }
        let firstBase64 = first.base64EncodedString()

        // 第二层：用随机 key 加密第一层的 base64 字符串
        guard let second = aesCBC(firstBase64, key: secret) else { return nil }

        return [
            "params": second.base64EncodedString(),
            "encSecKey": encSecKey(secret)
        ]
    }

    /// 16 位 base62 随机串。每次都不同 —— 同密钥的请求会被服务端丢掉。
    static func randomSecretKey() -> String {
        String((0..<16).map { _ in base62.randomElement() ?? "a" })
    }

    /// `encSecKey = int(hex(倒序 secretKey)) ^ 65537 mod N`，左侧补 0 到 256 位十六进制。
    static func encSecKey(_ secret: String) -> String {
        let reversed = String(secret.reversed())
        let message = Big(hex: reversed.data(using: .utf8)!.map { String(format: "%02x", $0) }.joined())
        let encrypted = message.power(rsaExponent, modulus: modulus)
        return encrypted.hexString(paddedTo: 256)
    }

    // MARK: - AES-128-CBC（用系统 CommonCrypto，不自己实现）

    static func aesCBC(_ text: String, key: String) -> Data? {
        let keyBytes = Array(key.utf8)
        let ivBytes = Array(iv.utf8)
        guard keyBytes.count == kCCKeySizeAES128, ivBytes.count == kCCBlockSizeAES128 else {
            return nil
        }
        let data = Data(text.utf8)

        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0

        let status = output.withUnsafeMutableBytes { outputBuffer -> CCCryptorStatus in
            guard let outputBase = outputBuffer.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
            return data.withUnsafeBytes { dataBuffer -> CCCryptorStatus in
                guard let dataBase = dataBuffer.baseAddress else { return CCCryptorStatus(kCCMemoryFailure) }
                return keyBytes.withUnsafeBufferPointer { keyPointer in
                    ivBytes.withUnsafeBufferPointer { ivPointer in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPointer.baseAddress, kCCKeySizeAES128,
                            ivPointer.baseAddress,
                            dataBase, data.count,
                            outputBase, outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return output.prefix(moved)
    }

    // MARK: - 大整数
    //
    // 只实现模幂需要的那几个操作。**故意不做除法**：
    // 65537 = 2^16 + 1，所以模幂是「平方 16 次再乘一次」，
    // 而模乘用倍加法（结果 = 反复两倍相加）就能算，全程只需要加减比较。

    struct Big {
        /// 小端序，每个 limb 32 位；末尾不保留多余零。
        private(set) var limbs: [UInt32]

        static let zero = Big(limbs: [])

        init(limbs: [UInt32]) {
            var trimmed = limbs
            while let last = trimmed.last, last == 0 {
                trimmed.removeLast()
            }
            self.limbs = trimmed
        }

        init(hex: String) {
            var text = hex
            if text.hasPrefix("0x") { text.removeFirst(2) }
            if text.count % 2 == 1 { text = "0" + text }

            // 从右往左每 8 个十六进制字符切一个 limb
            var result: [UInt32] = []
            var index = text.count
            while index > 0 {
                let start = max(0, index - 8)
                let slice = String(Array(text)[start..<index])
                result.append(UInt32(slice, radix: 16) ?? 0)
                index = start
            }
            self.init(limbs: result)
        }

        var isZero: Bool { limbs.isEmpty }

        var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

        /// 右移一位（相当于除以 2）。
        var halved: Big {
            var result = [UInt32](repeating: 0, count: limbs.count)
            var carry: UInt32 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let value = limbs[index]
                result[index] = (value >> 1) | (carry << 31)
                carry = value & 1
            }
            return Big(limbs: result)
        }

        /// 比较大小：a < b 返回 true。
        static func less(_ a: Big, _ b: Big) -> Bool {
            if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
            for index in stride(from: a.limbs.count - 1, through: 0, by: -1) where a.limbs[index] != b.limbs[index] {
                return a.limbs[index] < b.limbs[index]
            }
            return false
        }

        /// 加法，超出 2^1024 的进位用 Bool 返回。
        static func add(_ a: Big, _ b: Big) -> (sum: Big, carry: Bool) {
            let count = max(a.limbs.count, b.limbs.count)
            var result = [UInt32](repeating: 0, count: count)
            var carry: UInt64 = 0

            for index in 0..<count {
                let left = index < a.limbs.count ? UInt64(a.limbs[index]) : 0
                let right = index < b.limbs.count ? UInt64(b.limbs[index]) : 0
                let total = left + right + carry
                result[index] = UInt32(total & 0xFFFF_FFFF)
                carry = total >> 32
            }
            return (Big(limbs: result), carry == 1)
        }

        /// 减法，要求 a >= b。
        static func subtract(_ a: Big, _ b: Big) -> Big {
            var result = [UInt32](repeating: 0, count: a.limbs.count)
            var borrow: Int64 = 0
            for index in 0..<a.limbs.count {
                let left = Int64(a.limbs[index])
                let right = index < b.limbs.count ? Int64(b.limbs[index]) : 0
                var value = left - right - borrow
                if value < 0 {
                    value += 0x1_0000_0000
                    borrow = 1
                } else {
                    borrow = 0
                }
                result[index] = UInt32(value)
            }
            return Big(limbs: result)
        }

        /// (a + b) mod m。因为 a、b 都小于 m，和最多到 2m-2，减一次就够。
        static func addMod(_ a: Big, _ b: Big, _ m: Big) -> Big {
            let (sum, carry) = add(a, b)
            if carry || !less(sum, m) {
                return subtract(sum, m)
            }
            return sum
        }

        /// (a × b) mod m，用倍加法：把 b 按二进制拆开，反复把 a 两倍相加。
        /// 前提：a、b 都已经小于 m。
        static func multiplyMod(_ a: Big, _ b: Big, _ m: Big) -> Big {
            var result = Big.zero
            var addend = a
            var multiplier = b

            while !multiplier.isZero {
                if multiplier.isOdd {
                    result = addMod(result, addend, m)
                }
                addend = addMod(addend, addend, m)
                multiplier = multiplier.halved
            }
            return result
        }

        /// self ^ 65537 mod m。指数固定，所以不需要通用的快速幂。
        func power(_ exponent: UInt32, modulus: Big) -> Big {
            guard exponent == 65537 else { return .zero }
            var result = self
            for _ in 0..<16 {
                result = Big.multiplyMod(result, result, modulus)
            }
            result = Big.multiplyMod(result, self, modulus)
            return result
        }

        /// 小写十六进制，左侧补 0 到指定长度。
        func hexString(paddedTo length: Int) -> String {
            guard !limbs.isEmpty else { return String(repeating: "0", count: length) }
            var text = String(limbs[limbs.count - 1], radix: 16)
            for index in stride(from: limbs.count - 2, through: 0, by: -1) {
                text += String(format: "%08x", limbs[index])
            }
            if text.count < length {
                text = String(repeating: "0", count: length - text.count) + text
            }
            return String(text.suffix(length))
        }
    }

    // MARK: - 自检
    //
    // 这段会在「自检模式」下跑一遍，结果直接画在屏幕上 ——
    // 密码学代码没法靠肉眼看，必须拿已知答案对。

    struct SelfCheck {
        var name: String
        var passed: Bool
        var detail: String
    }

    /// 已知答案向量：由 Python 参考实现算出（见 tools/netease_crypto_reference.py）。
    static let knownSecret = "0123456789abcdef"
    static let knownEncSecKey =
        "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b9"
        + "49debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de9"
        + "48206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520e"
        + "a826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52"

    static func runSelfCheck() -> [SelfCheck] {
        var results: [SelfCheck] = []

        // 1) 裸 RSA 与已知向量对比 —— 这是整块里最可能写错的地方
        let computed = encSecKey(knownSecret)
        results.append(SelfCheck(
            name: "裸 RSA 对已知向量",
            passed: computed == knownEncSecKey,
            detail: computed == knownEncSecKey
                ? "encSecKey 完全一致（256 位十六进制）"
                : "不一致。算出来：\(computed.prefix(32))…"
        ))

        // 2) 大整数基础运算
        let a = Big(hex: "ffffffffffffffff")
        let b = Big(hex: "1")
        let (sum, carry) = Big.add(a, b)
        results.append(SelfCheck(
            name: "大整数进位",
            passed: sum.hexString(paddedTo: 17) == "10000000000000000" && carry,
            detail: "ffffffffffffffff + 1 = \(sum.hexString(paddedTo: 17))"
        ))

        // 3) 右移
        let shifted = Big(hex: "100000000").halved
        results.append(SelfCheck(
            name: "大整数右移",
            passed: shifted.hexString(paddedTo: 9) == "080000000",
            detail: "100000000 >> 1 = \(shifted.hexString(paddedTo: 9))"
        ))

        // 4) 加密输出形状
        let params = weapi(params: ["s": "测试", "type": 1, "limit": 30, "offset": 0])
        let paramsLength = params?["params"]?.count ?? 0
        let keyLength = params?["encSecKey"]?.count ?? 0
        results.append(SelfCheck(
            name: "weapi 输出形状",
            passed: paramsLength > 0 && keyLength == 256,
            detail: "params \(paramsLength) 字符，encSecKey \(keyLength) 字符"
        ))

        // 5) 两次加密不应相同（随机密钥生效）
        let first = weapi(params: ["s": "测试"])?["params"]
        let second = weapi(params: ["s": "测试"])?["params"]
        results.append(SelfCheck(
            name: "随机密钥生效",
            passed: first != nil && second != nil && first != second,
            detail: first == second ? "两次结果一样，说明密钥没随机" : "两次密文不同，符合预期"
        ))

        return results
    }
}
