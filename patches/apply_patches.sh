#!/bin/bash
# 应用待办补丁。已经打过的不重复打。
#
# 🔴 为什么需要这两步「修补丁」
#   1. GitHub 存文本文件时会剥掉末尾那个换行，而 `git apply` 要求补丁以换行结尾，
#      缺了就报 `corrupt patch at ...`。
#   2. hunk 里的**上下文空行**正确形态是「一个空格 + 换行」，肉眼看不见，
#      过一趟网络/编辑器很容易被吞成真正的空行 —— 一空 `git apply` 同样报 corrupt。
#      下面把「文件中间的孤立空行」补成「空格行」，这就是上下文行该有的样子。
#
# 依赖顺序：
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

  # ① 末尾补换行（GitHub 会剥掉）
  if [ -n "$(tail -c1 "$patch")" ]; then
    printf '\n' >> "$patch"
  fi

  # ② 文件中间的孤立空行 → 空格行（上下文行）
  #    sed 的地址 'a0<空行>'：空行出现在第 1 行之后（文件头两行是 --- / +++，不算）。
  #    末尾那个换行不算行，所以不受影响。
  if grep -qx '' "$patch"; then
    sed -i '' 's/^$/ /' "$patch" 2>/dev/null || sed -i 's/^$/ /' "$patch"
  fi

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
apply_one patches/cloud-card.patch
apply_one patches/cloudcard-fix.patch
apply_one patches/login-page.patch

echo
echo "接下来："
echo "  xcodegen generate"