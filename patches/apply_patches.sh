#!/bin/bash
# 应用待办补丁。已经打过的不重复打。
#
# 🔴 为什么需要「修补丁」这一步（2026-10-19 亲历，四个补丁全打不上）
#   GitHub / 编辑器 / 网络传输会破坏补丁里的**空白**：
#   1. 末尾那个换行被剥掉 → `git apply` 报 `corrupt patch at ...`
#   2. hunk 里的**上下文空行**（「一个空格 + 换行」）被吞成真空行 → 同样报 corrupt
#   3. 更隐蔽的：上下文空行被写成 `-`（看着像删除行）→ hunk 的行数计数对不上 → 还是 corrupt
#   下面把三种都修掉。判据统一用 awk：只在 hunk 内、且后一行是缩进上下文时，
#   才把「孤立的空行或 `-`」改回「空格」。
#
# 依赖顺序：
#   brand-accent   →  引入 ProviderPreset.aevis（CloudCard 会用它）
#   no-apikey      →  把 ProviderPreset 压成只剩 .aevis（内部自洽，可独立应用）
#   cloud-card     →  注册 CloudCard 到设置页
#   login-page     →  独立，不依赖上面
#
# ⚠️ brand-accent 与 no-apikey 都改 AppSettings.swift，改的是**不同段落**，
#    两个都打没问题；但顺序别颠倒：先加 `case .aevis`，再删掉其它 case。
#
# ⚠️ 少了一个：cloudcard-fix —— CloudCard.swift 已经直接改成修好的版本，
#    那个补丁删掉了（再留着会重复应用）。

set -u

cd "$(dirname "$0")/.." || exit 1

# 修掉被破坏的空白。三种坏法见上面注释。
fix_blank() {
  awk '
    /^@@/            { inhunk = 1 }
    inhunk == 1 {
      # 孤立空行 / 被误写成 "-" 的上下文空行 → 还原成「一个空格」
      if ($0 == "" || $0 == "-") {
        # 只有「后面紧跟一行以空格开头的上下文」时才是该修的那行
        if ((getline nxt) > 0) {
          if (nxt ~ /^ /) { print " "; print nxt; next }
          print "-"; print nxt; next
        }
        print "-"; next
      }
    }
    { print }
  ' "$1" > "$1.fixed" && mv "$1.fixed" "$1"
}

apply_one() {
  local patch="$1"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    return 0
  fi

  # ① 末尾补换行（GitHub 会剥掉它）
  if [ -n "$(tail -c1 "$patch")" ]; then
    printf '\n' >> "$patch"
  fi
  # ② 修 hunk 里的空白
  fix_blank "$patch"

  if git apply --reverse --check "$patch" 2>/dev/null; then
    echo "跳过：$(basename "$patch") 已经打过"
    return 0
  fi
  if git apply --check "$patch" 2>/dev/null; then
    git apply "$patch" && echo "已应用：$(basename "$patch")"
  else
    echo "⚠️  打不上：$(basename "$patch")"
    echo "    （文件可能已经改过 —— 手动对照 patches/README.md 改）"
  fi
}

apply_one patches/brand-accent.patch
apply_one patches/no-apikey.patch
apply_one patches/cloud-card.patch
apply_one patches/login-page.patch

echo
echo "接下来："
echo "  xcodegen generate"