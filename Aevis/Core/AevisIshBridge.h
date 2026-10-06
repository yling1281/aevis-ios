// AevisIshBridge.h —— Swift 看 iSH 宿主入口层的那一眼。
//
// 这是全工程**唯一**的桥接头（`SWIFT_OBJC_BRIDGING_HEADER` 指向它）。
// 它**不**包含 iSH 的任何内部头 —— 只含 `ish-embed/ish_embed.h` 这一个对外契约头。
//
// ⚠️ `ish_embed.h` 不在仓库里：它是出包 CI 从固定 tag `ish-vendor` 下载后解到
//    `vendor/ish/`，再靠 `HEADER_SEARCH_PATHS` 找到的。
// ⚠️ 调用方**不要**再去 include `kernel/…` / `fs/…` 那些头 —— App 里没有它们。
//    真正要用的入口都从 `ish_embed.h` 走（它自己会收敛所需的最小集合）。
// ⚠️ 本文件只做「转发」，不写任何逻辑 —— 逻辑在 iSH 的 C 侧（已编进 libaevisish.a）。
#ifndef AEVIS_ISH_BRIDGE_H
#define AEVIS_ISH_BRIDGE_H

#include "ish_embed.h"

#endif /* AEVIS_ISH_BRIDGE_H */
