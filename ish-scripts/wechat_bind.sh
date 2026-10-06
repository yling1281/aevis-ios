#!/bin/sh
# =============================================================================
# 微信机器人（腾讯官方 ClawBot / iLink 通道）—— 在 App 内置的真 Linux 里跑
# -----------------------------------------------------------------------------
# 老板的原话：「微信的扫码的话，要本地的，就是不经过电脑和服务器。它不是有
# Linux 控制台吗？用 Linux」。
# 所以这个脚本的全部存在意义就是：**把 iLink 的扫码绑定 + 长轮询，搬进 App
# 里那个真 Alpine（iSH）**，既不过我们的账号服务器，也不过任何一台电脑。
#
# 🔴 分工：本脚本**只负责要数据、把原始响应落盘**。
#    解析 JSON、画二维码、判断绑定状态这些**全交给宿主（Swift）做** ——
#    guest 里没有 jq，用 sed 硬解 JSON 又脆；宿主拿到原文自己解，最稳。
#
# 🔴 没有 PTY ⇒ 本脚本**绝对不许读 stdin**（读一下就把整个 shell 永久卡死）。
# 🔴 命令之间不共享 cd / export（宿主每次都是新开子 shell）⇒ 脚本内部无所谓，
#    但**从宿主发起的每条命令都得自带完整路径**。
#
# 宿主怎么调（每条都是一次独立调用）：
#   wechat_bind.sh install       装 curl（没有才装，幂等）
#   wechat_bind.sh net           出网自检（打一次 iLink 首页）
#   wechat_bind.sh qrcode        取绑定二维码（POST get_bot_qrcode）
#   wechat_bind.sh status        查一次扫码状态（票从 ticket.txt 读）
#   wechat_bind.sh poll          长轮询（宿主用 nohup … & 拉起来，本进程常驻）
#   wechat_bind.sh stop          让 poll 循环退出
#
# 所有产物都在 /root/wechat/ 下（iSH 的 fakefs 会持久化，重装 App 后还在）：
#   bind.log       每一步的真实输出（含 apk 装包那步）
#   qrcode.json    get_bot_qrcode 的原始响应
#   status.json    get_qrcode_status 的原始响应
#   updates.jsonl  getupdates 的原始响应，一行一条，**只追加**（宿主增量读）
#   cursor.txt     增量游标 get_updates_buf（落盘 ⇒ 断了能接着拉）
#   ticket.txt     当前二维码票（status 用）
#   token.txt / uin.txt   宿主写进来的凭证
#   frozen         打上就是「账号被冻结（ret=-14）」，宿主看到就停轮询
#   stop           poll 循环看到它就退出
# =============================================================================

BASE="${AEVIS_WX_BASE:-https://ilinkai.weixin.qq.com}"
DIR="/root/wechat"
LOG="$DIR/bind.log"
QR="$DIR/qrcode.json"
STATUS="$DIR/status.json"
UPDATES="$DIR/updates.jsonl"
CURSOR="$DIR/cursor.txt"
TICKET="$DIR/ticket.txt"
TOKENFILE="$DIR/token.txt"
UINFILE="$DIR/uin.txt"
FROZEN="$DIR/frozen"
STOP="$DIR/stop"
BODY="$DIR/req.json"
RESP="$DIR/resp.json"

mkdir -p "$DIR"

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "$(stamp) $*" >> "$LOG"; }

# 装了 curl 就不重复装；apk 的真实输出也留在日志里，方便宿主判「到底装没装上」。
ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    log "curl 已在：$(command -v curl)"
    return 0
  fi
  log "没有 curl，跑 apk add --no-cache curl（走已配好的清华 / 阿里镜像）"
  apk add --no-cache curl >> "$LOG" 2>&1
  if command -v curl >/dev/null 2>&1; then
    log "curl 装好了：$(command -v curl)"
    return 0
  fi
  log "curl 还是没装上 —— 看上面 apk 的输出"
  return 1
}

# 统一读写的小工具（都带 -m，绝不给一个请求无限等）
uniq_uin() { if [ -f "$UINFILE" ]; then cat "$UINFILE"; else echo "0"; fi; }
uniq_token() { if [ -f "$TOKENFILE" ]; then cat "$TOKENFILE"; fi; }

case "$1" in

  install)
    ensure_curl
    echo "install 结束，日志：$LOG"
    ;;

  net)
    # 出网自检：把 http_code（或 curl 的报错）原样吐到 stdout，宿主照显。
    ensure_curl
    code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE" 2>&1)
    echo "curl $BASE"
    echo "结果=$code"
    ;;

  qrcode)
    ensure_curl
    rm -f "$QR"
    code=$(curl -sS -m 30 -X POST \
        -H "iLink-App-Id: bot" \
        -H "Content-Type: application/json" \
        -o "$QR" -w '%{http_code}' \
        "$BASE/ilink/bot/get_bot_qrcode?bot_type=3" 2>>"$LOG")
    log "get_bot_qrcode http=$code"
    if [ -f "$QR" ]; then log "body: $(cat "$QR")"; fi
    echo "http_code=$code"
    if [ -f "$QR" ]; then cat "$QR"; fi
    ;;

  status)
    ensure_curl
    ticket="$2"
    if [ -z "$ticket" ]; then ticket=$(cat "$TICKET" 2>/dev/null); fi
    rm -f "$STATUS"
    code=$(curl -sS -m 30 -G \
        -H "iLink-App-Id: bot" \
        -H "Content-Type: application/json" \
        --data-urlencode "qrcode=$ticket" \
        -o "$STATUS" -w '%{http_code}' \
        "$BASE/ilink/bot/get_qrcode_status" 2>>"$LOG")
    log "get_qrcode_status http=$code"
    if [ -f "$STATUS" ]; then log "body: $(cat "$STATUS")"; fi
    echo "http_code=$code"
    if [ -f "$STATUS" ]; then cat "$STATUS"; fi
    ;;

  poll)
    ensure_curl || exit 1
    rm -f "$FROZEN" "$STOP"
    log "poll 起来（token 文件存在=$([ -f "$TOKENFILE" ] && echo yes || echo no)）"
    # ⚠️ 故意**不删 cursor.txt**：fakefs 是持久的，断了要能接着拉（断了能续）。
    #    换绑定（新 token）时由宿主负责把旧游标清掉。
    while [ ! -f "$STOP" ]; do
      buf=""
      if [ -f "$CURSOR" ]; then buf=$(cat "$CURSOR"); fi
      # 请求体里**只有 get_updates_buf**（增量游标）。
      printf '{"get_updates_buf":"%s"}' "$buf" > "$BODY"
      code=$(curl -sS -m 45 -X POST \
          -H "Authorization: Bearer $(uniq_token)" \
          -H "iLink-App-Id: bot" \
          -H "X-WECHAT-UIN: $(uniq_uin)" \
          -H "Content-Type: application/json" \
          -d @"$BODY" \
          -o "$RESP" -w '%{http_code}' \
          "$BASE/ilink/bot/getupdates" 2>>"$LOG")
      if [ ! -s "$RESP" ]; then
        echo "$(stamp) getupdates 空响应 http=$code"
        log "getupdates 空响应 http=$code"
        sleep 2
        continue
      fi
      # 追加到 updates.jsonl（宿主只读新增部分）。
      # ⚠️ 用 tr 去掉换行，保证**一条响应就是一行**（宿主按行解 JSON）。
      tr -d '\n' < "$RESP" >> "$UPDATES"
      printf '\n' >> "$UPDATES"
      echo "$(stamp) getupdates ok http=$code"
      # ret=-14 ⇒ 该账号冻结 1 小时、没有 refresh、只能重新扫码。
      #   ⚠️ **探测到就停**，绝不死刷（死刷只会一直撞墙，还可能延长冻结）。
      if grep -q '"ret"[[:space:]]*:[[:space:]]*-14' "$RESP"; then
        echo "ret=-14 检测于 $(stamp)" >> "$FROZEN"
        cat "$RESP" >> "$FROZEN"
        log "账号被冻结（ret=-14），停止轮询"
        break
      fi
      # 抽新的游标并落盘（下次请求接着用）。
      newbuf=$(sed -n 's/.*"get_updates_buf"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | tail -n 1)
      if [ -n "$newbuf" ]; then printf '%s' "$newbuf" > "$CURSOR"; fi
      sleep 1
    done
    log "poll 结束"
    ;;

  stop)
    mkdir -p "$DIR"
    : > "$STOP"
    echo "stop 已下达"
    ;;

  *)
    echo "用法：wechat_bind.sh install|net|qrcode|status|poll|stop"
    ;;
esac
