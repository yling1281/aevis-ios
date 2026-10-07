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
#   wechat_bind.sh send          发一条消息（请求体从 send_body.json 读）
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
#   send_body.json   宿主拼好的 sendmessage 请求体（本脚本**不解析**，原样 -d @ 发出去）
#   send_result.json sendmessage 的原始响应
#   frozen         -14 会话超时（session timeout，**不是封号**）的留痕（含 errmsg），宿主读到就提示重新扫码
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
SENDBODY="$DIR/send_body.json"
SENDRESULT="$DIR/send_result.json"
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
    #    换绑定（新 token）时由宿主负责把旧游标清掉（见 WeChatBotService.saveBinding）。
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
      #
      # 🔴 失败判据（本机 curl 真打腾讯接口实测）：iLink **成功用顶层 `ret`、
      #    失败用顶层 `errcode`**：
      #      无 token / token 失效 → getupdates 返回
      #        {"errcode":-14,"errmsg":"session timeout"}   （HTTP 200，约 42 字节）
      #      sendmessage 无 token 同样是这一条。
      #    🔴 `-14` 的真实含义是**会话超时（session timeout）**，**不是**「账号被封」！
      #       这里原来那句「ret=-14 ⇒ 冻结 1 小时、只能重新扫码」是**没有任何出处的
      #       二手说法**（本机全仓无佐证），已作废 —— 别再改回去。
      #    ⚠️ 只在**响应开头**匹配**顶层**字段名（`[^{]*` 保证不跨进嵌套对象），
      #       绝不 `grep` 整个响应体去找 `-14` —— 否则嵌套结构里的 ret=-14 会误判。
      #    ⚠️ `-14` 后面必须紧跟 `,` 或 `}`（JSON 里数字后面只可能是这两个之一），
      #       否则 `-140` 会被当成 `-14` —— 所以尾部锚一个 `[[:space:]]*[,}]`。
      #    ⚠️ 用两条 BRE（不用 `|` 扩展正则），busybox grep 也稳。
      if grep -q \
           -e '^[[:space:]]*{[^{]*"errcode"[[:space:]]*:[[:space:]]*-14[[:space:]]*[,}]' \
           -e '^[[:space:]]*{[^{]*"ret"[[:space:]]*:[[:space:]]*-14[[:space:]]*[,}]' \
           "$RESP"; then
        # 把 errmsg 一起落进 frozen，宿主好如实把原因显示出来。
        errmsg=$(sed -n 's/.*"errmsg"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | head -n 1)
        {
          echo "time=$(stamp)"
          echo "errmsg=$errmsg"
          echo "note=顶层 -14 = 会话超时（session timeout），不是封号；需要重新扫码"
          printf 'raw=%s\n' "$(cat "$RESP")"
        } > "$FROZEN"
        log "getupdates 返回 -14（会话超时，非封号）errmsg=[$errmsg]，退避 30 秒后继续"
        echo "$(stamp) getupdates -14 会话超时 http=$code"
        # 🔴 退避，绝不死刷（每秒锤一次 getupdates 最容易被风控盯上）；
        #    也**不永久 break** —— 保留「不快刷」的原则，但不「一停到底」。
        sleep 30
        continue
      fi
      # 正常响应 ⇒ 清掉可能残留的 frozen（上一轮 -14 过、这一轮已经好了）。
      if [ -f "$FROZEN" ]; then rm -f "$FROZEN"; fi
      # 抽新的游标并落盘（下次请求接着用）。
      newbuf=$(sed -n 's/.*"get_updates_buf"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | tail -n 1)
      if [ -n "$newbuf" ] && [ "$newbuf" != "$buf" ]; then
        printf '%s' "$newbuf" > "$CURSOR"
        sleep 1
      else
        # 🔴 P0-1：响应非空、却**抽不到新游标**（空、或游标没前进）—— 这条路径以前
        #    只 `sleep 1`，会变成「约每秒锤一次 getupdates」（最容易被风控盯上）。
        #    这里退避 8 秒，并写进日志留痕。
        log "getupdates 响应里没有新游标（http=$code，空或未前进）⇒ 退避 8 秒，避免每秒锤一次"
        echo "$(stamp) getupdates 无新游标 http=$code，退避 8 秒"
        sleep 8
      fi
    done
    log "poll 结束"
    ;;

  send)
    ensure_curl || exit 1
    rm -f "$SENDRESULT"
    code=$(curl -sS -m 30 -X POST \
        -H "Authorization: Bearer $(uniq_token)" \
        -H "AuthorizationType: ilink_bot_token" \
        -H "iLink-App-Id: bot" \
        -H "iLink-App-ClientVersion: 1" \
        -H "X-WECHAT-UIN: $(uniq_uin)" \
        -H "Content-Type: application/json" \
        -d @"$SENDBODY" \
        -o "$SENDRESULT" -w '%{http_code}' \
        "$BASE/ilink/bot/sendmessage" 2>>"$LOG")
    log "sendmessage http=$code"
    if [ -f "$SENDRESULT" ]; then log "body: $(cat "$SENDRESULT")"; fi
    echo "http_code=$code"
    if [ -f "$SENDRESULT" ]; then cat "$SENDRESULT"; fi
    ;;

  stop)
    mkdir -p "$DIR"
    : > "$STOP"
    echo "stop 已下达"
    ;;

  *)
    echo "用法：wechat_bind.sh install|net|qrcode|status|poll|send|stop"
    ;;
esac
