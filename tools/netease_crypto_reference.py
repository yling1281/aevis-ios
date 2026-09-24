#!/usr/bin/env python3
"""网易云 weapi 加密里那段「裸 RSA」的算法验证。

为什么要单独验：网易的 RSA **不是标准 PKCS1 填充**，而是直接向前补 0 的裸运算
（`encSecKey = int(hex(倒序的key)) ^ 65537 mod N`）。
苹果的 Security 框架**不支持裸 RSA 加密**（SecKeyAlgorithm.rsaEncryptionRaw
不能用于 encrypt 操作），所以必须在 Swift 里自己写大数运算。

自己写大数运算 + 完全没法在 Windows 上跑 Swift 测试 = 风险极高。
所以：**先在 Python 里把算法结构验一遍**，验过了再一比一搬到 Swift。
这里用的是和 Swift 版**完全相同的结构**（平方 16 次再乘一次），
而不是图省事直接用 Python 的 pow()，否则验的就不是同一个东西。

用法:
    python3 tools/netease_crypto_reference.py
"""

import hashlib
import secrets

# —— 网易云的固定常量（来自多个开源实现的一致记录，非臆测）——
AES_PRESET_KEY = "0CoJUm6Qyw8W8jud"
AES_IV = "0102030405060708"
BASE62 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
RSA_EXPONENT = 0x010001
RSA_MODULUS_HEX = (
    "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725"
    "152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ec"
    "bda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d8"
    "13cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"
)
RSA_MODULUS = int(RSA_MODULUS_HEX, 16)
KEY_LENGTH = 16


def random_secret_key() -> str:
    """16 位 base62 随机串。网易要求每次不同，否则同密钥的请求会被服务端丢掉。"""
    return "".join(secrets.choice(BASE62) for _ in range(KEY_LENGTH))


def rsa_encrypt_schoolbook(message: int, exponent: int, modulus: int) -> int:
    """与 Swift 版结构完全一致的模幂：只做「平方 16 次 + 乘 1 次」。
    因为指数恒为 65537 = 2^16 + 1，不需要通用的 square-and-multiply。"""
    assert exponent == 65537, "这个实现只支持 65537"

    result = message % modulus
    for _ in range(16):
        result = (result * result) % modulus
    result = (result * message) % modulus
    return result


def enc_sec_key(secret_key: str) -> str:
    """把 secretKey 倒序 → 当十六进制数 → 裸 RSA → 左侧补 0 到 256 位十六进制。"""
    reversed_text = secret_key[::-1]
    message = int(reversed_text.encode("utf-8").hex(), 16)
    encrypted = rsa_encrypt_schoolbook(message, RSA_EXPONENT, RSA_MODULUS)
    return "%0256x" % encrypted


def main():
    print("=== 1. 模幂结构与 Python 内置 pow() 对拍 ===")
    ok = True
    for _ in range(200):
        secret = random_secret_key()
        message = int(secret[::-1].encode("utf-8").hex(), 16)

        mine = rsa_encrypt_schoolbook(message, RSA_EXPONENT, RSA_MODULUS)
        reference = pow(message, RSA_EXPONENT, RSA_MODULUS)
        if mine != reference:
            print("  不一致！secret=%s" % secret)
            ok = False
            break
    print("  200 组随机密钥全部一致" if ok else "  失败")

    print("\n=== 2. 边界：message 大于 modulus / 等于 0 ===")
    big = RSA_MODULUS * 3 + 12345
    print("  大于 modulus 时取模正确:",
          rsa_encrypt_schoolbook(big, RSA_EXPONENT, RSA_MODULUS) == pow(big, RSA_EXPONENT, RSA_MODULUS))
    print("  0 的结果为 0:",
          rsa_encrypt_schoolbook(0, RSA_EXPONENT, RSA_MODULUS) == 0)

    print("\n=== 3. encSecKey 的输出形状 ===")
    sample = "0123456789abcdef"
    key = enc_sec_key(sample)
    print("  输入 secretKey :", sample)
    print("  encSecKey      :", key)
    print("  长度 256 位十六进制:", len(key) == 256)
    print("  全是十六进制字符   :", all(c in "0123456789abcdef" for c in key))
    print("  与参考实现一致     :",
          int(key, 16) == pow(int(sample[::-1].encode("utf-8").hex(), 16), RSA_EXPONENT, RSA_MODULUS))

    print("\n=== 4. 第一层 AES 的确定性检查（不依赖第三方库）===")
    # AES 在 Swift 里用系统 CommonCrypto，不需要自己实现；
    # 这里只确认「同一输入两次加密结果不同」这一条网易要求的行为 ——
    # 随机密钥每次都必须不同。
    keys = {random_secret_key() for _ in range(1000)}
    print("  1000 次随机密钥里有 %d 个不同的（应为 1000）" % len(keys))
    print("  长度都是 16:", all(len(k) == 16 for k in keys))

    print("\n=== 结论 ===")
    print("算法结构可以照搬到 Swift。Swift 版需要自己实现的只有：")
    print("  大整数（比较/加/减/右移一位/十六进制互转）—— 因为苹果不支持裸 RSA")
    print("  AES-128-CBC 与 MD5 直接用系统 CommonCrypto，不要自己写")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
