#!/bin/bash
# 应用待办补丁。已经打过的不重复打。
#
# 🔴 为什么要「补末尾换行 + 修孤立空行」
#   1. GitHub 存文本文件时会剥掉末尾那个换行，而 `git apply` 要求补丁以换行结尾，
#      缺了就报 `corrupt patch at ...` —— 2026-10-19 四个补丁全栽在这上面。
#   2. hunk 里的**上下文空行**是「一个空格 + 换行」，肉眼看不见、内容过网络也容易被吞成
#      真正的空行；一空 `git apply` 同样报 corrupt。
#      下面用 python 精确修：补丁里任何「孤立空行」都改成「空格行」。
#      判据要看它前一行 —— 只有跟在 `@@`/非 `+`/`-` 行之后的空行才是上下文行。
set -u

cd "$(dirname "$0")/.." || exit 1

fix_patch() {
  local patch="$1"
  [ -f "$patch" ] || return 1
  # ① 补末尾换行
  [ -n "$(tail -c1 "$patch")" ] && printf '\n' >> "$patch"
  # ② 孤立空行 → 空格行（上下文行的正确形态）
  python3 - "$patch" <<'PYEOF'
import sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8', newline='') as f:
    lines = f.read().split('\n')
out, fixed = [], 0
for i, ln in enumerate(lines):
    if ln == '' and i + 1 < len(lines):
        # 后面还有内容 ⇒ 这是文件中间的孤立空行 ⇒ 上下文行
        out.append(' ')
        fixed += 1
    else:
        out.append(ln)
if fixed:
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write('\n'.join(out))
    print('   修正上下文空行 %d 处' % fixed)
PYEOF
}

apply_one() {
  local patch="$1"
  if [ ! -f "$patch" ]; then
    echo "跳过：$patch 不存在"
    return 0
  fi
  fix_patch "$patch"

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