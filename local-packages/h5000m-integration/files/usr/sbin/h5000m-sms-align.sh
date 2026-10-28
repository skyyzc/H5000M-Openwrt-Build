#!/bin/sh
# h5000m-sms-align.sh —— 把 qmodem.sms 库里的短信对齐进 higorosd 的 received.json
#
# 为什么要它
#   设备上有两套短信栈：qmodem-smsd 把收到的短信写 /etc/qmodem/sms.sqlite3，
#   而 HigoOS(higorosd) 只认自己的 /etc/qmodem/2_1_received.json。新栈收完还会
#   把短信从 SIM 删掉（auto_delete），海狗那条轮询链路于是永远看不到新短信。
#   实测 2026-10-22：库里 9 条、海狗只有 1 条（10/14 原厂固件时期收的）。
#
# 它做什么
#   每 2 分钟：ubus call qmodem.sms list 取全量 -> 按 (sender,timestamp) 与
#   received.json 合并 -> 有新增才写回（原子替换）并重启 higorosd。
#   重启是必须的：higorosd 只在启动时读一次这个文件，之后每次 list_sms 都用
#   内存内容把文件覆写回去（2026-10-22 实测），改文件不重启等于白改。
#
# 边界
#   - 不碰 /etc/higoros/（那是 higorosd 的领地，多放文件会被当成设备台账）
#   - 升级中让路；重启限频 120s，避免连续新短信把面板反复打断
#   - 文件解析失败就跳过本轮，绝不用空数据覆盖
set -u

SEC=2_1
F=/etc/qmodem/2_1_received.json
LOG=/tmp/h5000m-sms-align.log
STAMP=/tmp/h5000m-sms-align.last
MIN_GAP=120

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >>"$LOG"; }

# 升级/恢复中让路
[ -f /tmp/.h5000m-upgrade ] && exit 0

command -v jq >/dev/null 2>&1 || { log "jq 不存在，跳过"; exit 0; }

SRC=$(ubus call qmodem.sms list "{\"modem_id\":\"$SEC\",\"limit\":1000}" 2>/dev/null) || exit 0
[ -n "$SRC" ] || exit 0
printf '%s' "$SRC" | jq -e '.messages' >/dev/null 2>&1 || { log "ubus 返回不含 messages，跳过"; exit 0; }

OLD_N=$(jq -r '(.received // []) | length' "$F" 2>/dev/null || echo 0)
[ -n "$OLD_N" ] || OLD_N=0

# ★ 文件缺失时不能走 --slurpfile（jq 对不存在的 --slurpfile 文件直接报错，
#   v1.2 刷机后实测：日志每 2 分钟刷一次「合并失败」却毫无动作）。
#   先补一份空结构再继续，让合并流程自己把库里的短信灌回去。
if [ ! -s "$F" ] || ! jq -e '.received' "$F" >/dev/null 2>&1; then
	log "received.json 缺失或损坏，先落一份空结构"
	printf '{"received": [], "next_id": 1}' >"$F.tmp" 2>/dev/null \
		&& chmod 600 "$F.tmp" && mv -f "$F.tmp" "$F" \
		|| { log "写空结构失败，跳过本轮"; exit 0; }
	OLD_N=0
fi

MERGED=$(printf '%s' "$SRC" | jq -c --slurpfile old "$F" '
  (($old[0].received) // []) as $o
  | ([.messages[] | select(.type == "received")
      | {sender, timestamp, content, is_read: (.is_read // false)}]) as $n
  | (($o + $n)
     | group_by([.sender, (.timestamp | tostring)])
     | map(.[0])
     | sort_by(.timestamp)) as $merged
  | {received: ($merged | to_entries | map(.value + {
        id: (.key + 1),
        reference: null,
        original_reference: null,
        total: null,
        part: null,
        forwarded: (.value.forwarded // false)})),
     next_id: (($merged | length) + 1)}
' 2>/dev/null)

[ -n "$MERGED" ] || { log "合并失败（jq 报错），保留原文件"; exit 0; }

NEW_N=$(printf '%s' "$MERGED" | jq -r '(.received // []) | length' 2>/dev/null || echo "$OLD_N")

if [ "$NEW_N" -le "$OLD_N" ] 2>/dev/null; then
    exit 0
fi

# 原子写：先落临时文件再 mv，避免 higorosd 读到半个 JSON
printf '%s' "$MERGED" >"$F.tmp" 2>/dev/null || { log "写临时文件失败"; exit 0; }
chmod 600 "$F.tmp"
mv -f "$F.tmp" "$F" || { log "替换文件失败"; exit 0; }
log "对齐：$OLD_N -> $NEW_N 条，准备重启 higorosd"

NOW=$(date +%s)
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
if [ $((NOW - LAST)) -lt "$MIN_GAP" ]; then
    log "距上次重启不足 ${MIN_GAP}s，本轮不重启（下轮自动补）"
    exit 0
fi

echo "$NOW" >"$STAMP"
/etc/init.d/higoros restart >/dev/null 2>&1
sleep 8
if pidof higorosd >/dev/null 2>&1; then
    log "higorosd 已重启，pid=$(pidof higorosd)"
else
    log "★ higorosd 重启后未起来，需人工检查"
fi
exit 0
