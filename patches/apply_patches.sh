#!/bin/bash
# 应用待办补丁。已经打过的不重复打。
#
# ⚠️ 顺序有依赖：brand-accent 先来（它引入 ProviderPreset.aevis），
#    cloud-card 后面（CloudCard 引用 AevisCloud）。反了会编译失败。
set -u

cd "$(dirname "$0")/.." || exit 1

apply_one() {
  local patch="$1"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    return 0
  fi
  if git apply --reverse --check "$patch" 2>/dev/null; then
    echo "跳过：$(basename "$patch") 已经打过"
    return 0
  fi
  if git apply --check "$patch" 2>/dev/null; then
    git apply "$patch" && echo "已应用：$(basename "$patch")"
  else
    echo "⚠️  打不上：$(basename "$patch")（文件可能已经改过，手动对照 README 改）"
  fi
}

apply_one patches/brand-accent.patch
apply_one patches/cloud-card.patch

echo
echo "接下来："
echo "  xcodegen generate"