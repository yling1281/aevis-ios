#include "aevis_core.h"

#include <cctype>
#include <cstdio>
#include <cstring>

namespace {

const char* kVersion = "1.0.0";
const char* kApiBase = "https://aevis.cn/prod-api/aevis";

// 倒着写，最后整体反转 —— 避免额外分配。
int write_reversed(const char* src, int len, char* out, int cap) {
    if (cap <= len) return -1;
    for (int i = 0; i < len; ++i) out[i] = src[len - 1 - i];
    out[len] = '\0';
    return len;
}

}  // namespace

extern "C" const char* aevis_core_version(void) { return kVersion; }

extern "C" const char* aevis_api_base(void) { return kApiBase; }

extern "C" int aevis_format_points(long long value, char* out, int cap) {
    if (!out || cap <= 0) return -1;
    if (value < 0) {
        // 负分不出现，按 0 处理，省得两端显示成 "-1,234"
        value = 0;
    }
    char tmp[32];
    int n = 0;
    do {
        int digit = static_cast<int>(value % 10);
        if (n > 0 && n % 4 == 3) tmp[n++] = ',';
        tmp[n++] = static_cast<char>('0' + digit);
        value /= 10;
    } while (value > 0 && n < 28);
    return write_reversed(tmp, n, out, cap);
}

extern "C" int aevis_normalize_account(const char* in, char* out, int cap) {
    if (!in || !out || cap <= 0) return -1;
    int n = 0;
    const char* p = in;
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') ++p;
    const char* end = p + std::strlen(p);
    while (end > p && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) --end;
    for (; p < end; ++p) {
        if (n + 1 >= cap) return -1;
        out[n++] = static_cast<char>(std::tolower(static_cast<unsigned char>(*p)));
    }
    out[n] = '\0';
    return n;
}
