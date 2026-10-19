#!/bin/bash
# 应用待办补丁。已经打过的不重复打。
#
# 依赖关系：
#   brand-accent   →  引入 ProviderPreset.aevis（CloudCard 会用它）
#   cloud-card     →  注册 CloudCard 到设置页
#   cloudcard-fix  →  修 CloudCard 里的造码死循环（依赖 cloud-card）
#   login-page     →  独立，不依赖上面，放最后最稳
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
apply_one patches/cloudcard-fix.patch
apply_one patches/login-page.patch

echo
echo "接下来："
echo "  xcodegen generate"